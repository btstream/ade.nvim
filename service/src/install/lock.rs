//! Cross-process lock and release leases (PROTOCOL.md 16.2).
//!
//! The formats are shared with `lua/ade/manager/lock.lua`: `pid` is written as a
//! JSON string, `heartbeat` as an integer, and readers accept a number or a
//! numeric string for both. The lock is the directory itself; the lease is one
//! file per running release.

use std::path::{Path, PathBuf};

use serde_json::{json, Value};
use tokio::sync::watch;

use super::store::{read_json, write_json_atomic};
use super::{
    boot_time_ms, hostname, now_ms, timestamp, valid_install_id, ALIVE_STALE_MS, BOOT_GRACE_MS,
    STALE_MS,
};

pub fn locks_dir(root: &Path, agent: &str) -> PathBuf {
    root.join(".locks").join(agent)
}

pub fn leases_dir(root: &Path, agent: &str) -> PathBuf {
    root.join(".leases").join(agent)
}

pub fn pid_string() -> String {
    std::process::id().to_string()
}

/// Read a pid or heartbeat that may be a number or a numeric string.
fn numeric(value: Option<&Value>) -> Option<i64> {
    match value? {
        Value::Number(number) => number.as_i64().or_else(|| {
            number
                .as_f64()
                .filter(|value| value.is_finite() && value.fract() == 0.0)
                .map(|value| value as i64)
        }),
        Value::String(text) => text.trim().parse().ok(),
        _ => None,
    }
}

/// Whether `pid` exists, or exists but cannot be signalled.
#[cfg(unix)]
fn process_state(pid: i64) -> ProcessState {
    if pid <= 0 || pid > i64::from(i32::MAX) {
        return ProcessState::Gone;
    }
    let result = unsafe { libc::kill(pid as i32, 0) };
    if result == 0 {
        return ProcessState::Running;
    }
    let errno = std::io::Error::last_os_error().raw_os_error().unwrap_or(0);
    if errno == libc::ESRCH {
        ProcessState::Gone
    } else {
        ProcessState::CannotSignal
    }
}

#[cfg(not(unix))]
fn process_state(pid: i64) -> ProcessState {
    // No signal(2) probe off unix; keep the conservative answer.
    if pid > 0 {
        ProcessState::CannotSignal
    } else {
        ProcessState::Gone
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum ProcessState {
    Running,
    CannotSignal,
    Gone,
}

/// Liveness of one record (16.2): returns `live` and the reason.
pub fn alive(record: Option<&Value>, path: &Path, now: i64, boot: i64) -> (bool, String) {
    let Some(record) = record else {
        return (true, "lock file is unreadable".to_string());
    };
    if record.get("host").and_then(Value::as_str) != Some(hostname().as_str()) {
        return (
            true,
            format!(
                "held by another host ({})",
                record.get("host").and_then(Value::as_str).unwrap_or("?")
            ),
        );
    }
    let Some(owner) = numeric(record.get("pid")).filter(|pid| *pid > 0) else {
        return (true, "lock file has no pid".to_string());
    };
    let heartbeat = numeric(record.get("heartbeat")).unwrap_or(0);
    let aged = |reason: String| {
        if heartbeat <= 0 {
            return (true, reason);
        }
        if heartbeat > now {
            return (true, reason);
        }
        if heartbeat < boot - BOOT_GRACE_MS {
            return (false, "recorded before this boot".to_string());
        }
        let stopped = now - heartbeat;
        if stopped > ALIVE_STALE_MS {
            return (false, format!("heartbeat stopped {}s ago", stopped / 1000));
        }
        (true, reason)
    };
    match process_state(owner) {
        ProcessState::Running => aged(format!("pid {owner} is running")),
        ProcessState::CannotSignal => aged(format!("pid {owner} exists but cannot be signalled")),
        ProcessState::Gone => {
            if heartbeat > 0 && heartbeat <= now && now - heartbeat > STALE_MS {
                (false, "abandoned".to_string())
            } else {
                (
                    true,
                    format!("pid {owner} is gone; lock {} is recent", path.display()),
                )
            }
        }
    }
}

/// Whether the record at `path` is still ours (host, pid and the identifying
/// field the caller checks).
fn ours(path: &Path, expected: &[(&str, &str)]) -> bool {
    let Ok(Some(record)) = read_json(path) else {
        return false;
    };
    if record.get("host").and_then(Value::as_str) != Some(hostname().as_str()) {
        return false;
    }
    if numeric(record.get("pid")) != Some(i64::from(std::process::id())) {
        return false;
    }
    expected
        .iter()
        .all(|(key, value)| record.get(*key).and_then(Value::as_str) == Some(*value))
}

fn mkdir_private(path: &Path) -> std::io::Result<()> {
    let mut builder = std::fs::DirBuilder::new();
    #[cfg(unix)]
    {
        use std::os::unix::fs::DirBuilderExt;
        builder.mode(0o700);
    }
    builder.create(path)
}

/// The exclusive per-agent lock.
#[derive(Debug)]
pub struct AgentLock {
    dir: PathBuf,
    acquired_at: String,
    heartbeat: watch::Sender<bool>,
}

impl AgentLock {
    /// Whether the owner record still names this process and acquisition.
    pub fn is_ours(&self) -> bool {
        ours(
            &self.dir.join("owner.json"),
            &[("acquiredAt", self.acquired_at.as_str())],
        )
    }

    /// Remove the lock directory while the record is still ours.
    fn cleanup(&self) {
        if ours(&self.dir.join("owner.json"), &[]) {
            let _ = std::fs::remove_dir_all(&self.dir);
        }
    }

    /// Remove the lock directory while the record is still ours.
    pub fn release(self) {
        let _ = self.heartbeat.send(true);
        self.cleanup();
    }
}

impl Drop for AgentLock {
    fn drop(&mut self) {
        // A panicking job must not leave this directory behind for two minutes.
        let _ = self.heartbeat.send(true);
        self.cleanup();
    }
}

/// Take the lock, reclaiming an abandoned one (16.2).
pub fn acquire(root: &Path, agent: &str, action: &str) -> Result<AgentLock, String> {
    let locks = root.join(".locks");
    std::fs::create_dir_all(&locks)
        .map_err(|error| format!("unable to create {}: {error}", locks.display()))?;
    let dir = locks_dir(root, agent);
    if let Err(error) = mkdir_private(&dir) {
        if error.kind() != std::io::ErrorKind::AlreadyExists
            && error.kind() != std::io::ErrorKind::PermissionDenied
        {
            return Err(format!(
                "another instance is using this agent: unable to create {} ({error})",
                dir.display()
            ));
        }
        let owner_path = dir.join("owner.json");
        let first = read_json(&owner_path).ok().flatten();
        let (live, reason) = alive(first.as_ref(), &dir, now_ms(), boot_time_ms(now_ms()));
        if live {
            if reason == "lock file is unreadable" {
                return Err(format!(
                    "another instance is using this agent: {reason}; remove {} manually if no process is using it",
                    dir.display()
                ));
            }
            return Err(format!("another instance is using this agent: {reason}"));
        }
        // Re-read before deleting: a second process may have reclaimed it.
        let second = read_json(&owner_path).ok().flatten();
        if first != second {
            return Err(
                "another instance is using this agent: the lock changed while reclaiming"
                    .to_string(),
            );
        }
        let _ = std::fs::remove_file(&owner_path);
        let _ = std::fs::remove_dir_all(&dir);
        mkdir_private(&dir).map_err(|error| {
            format!(
                "unable to reclaim an abandoned lock at {}: {error}",
                dir.display()
            )
        })?;
    }

    let acquired_at = timestamp(now_ms());
    let owner = json!({
        "host": hostname(),
        "pid": pid_string(),
        "acquiredAt": acquired_at,
        "heartbeat": now_ms(),
        "action": action,
    });
    let owner_path = dir.join("owner.json");
    if let Err(error) = write_json_atomic(&owner_path, &owner) {
        let _ = std::fs::remove_dir_all(&dir);
        return Err(format!("unable to record the lock owner: {error}"));
    }

    let (heartbeat, mut stop) = watch::channel(false);
    let path = owner_path.clone();
    let expected_at = acquired_at.clone();
    let lock_dir = dir.clone();
    tokio::spawn(async move {
        let mut interval = tokio::time::interval(super::heartbeat_interval());
        interval.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Delay);
        interval.tick().await;
        loop {
            tokio::select! {
                _ = stop.changed() => return,
                _ = interval.tick() => {
                    if !ours(&path, &[("acquiredAt", expected_at.as_str())]) {
                        crate::svc_log!(
                            "nvim_ade_server: lock {} was reclaimed; heartbeat stopped",
                            lock_dir.display()
                        );
                        return;
                    }
                    let Ok(Some(mut value)) = read_json(&path) else {
                        return;
                    };
                    if let Some(object) = value.as_object_mut() {
                        object.insert("heartbeat".to_string(), json!(now_ms()));
                    }
                    let _ = write_json_atomic(&path, &value);
                }
            }
        }
    });

    Ok(AgentLock {
        dir,
        acquired_at,
        heartbeat,
    })
}

/// A lease the service holds for a release it is running (16.2/16.4).
pub struct ReleaseLease {
    path: PathBuf,
    install_id: String,
    heartbeat: watch::Sender<bool>,
}

impl ReleaseLease {
    pub fn path(&self) -> &Path {
        &self.path
    }
}

impl Drop for ReleaseLease {
    fn drop(&mut self) {
        let _ = self.heartbeat.send(true);
        if ours(&self.path, &[("installId", self.install_id.as_str())]) {
            let _ = std::fs::remove_file(&self.path);
        }
    }
}

/// Write a lease for one release the service runs.
pub fn lease(
    root: &Path,
    agent: &str,
    install_id: &str,
    instance: &str,
) -> Result<ReleaseLease, String> {
    if !valid_install_id(install_id) {
        return Err("invalid install id".to_string());
    }
    if !instance
        .bytes()
        .all(|byte| byte.is_ascii_alphanumeric() || matches!(byte, b'_' | b'-'))
    {
        return Err("invalid instance id".to_string());
    }
    let dir = leases_dir(root, agent);
    std::fs::create_dir_all(&dir)
        .map_err(|error| format!("unable to create {}: {error}", dir.display()))?;
    let path = dir.join(format!("lease-{}-{instance}.json", pid_string()));
    let value = json!({
        "host": hostname(),
        "pid": pid_string(),
        "installId": install_id,
        "heartbeat": now_ms(),
        "startedAt": timestamp(now_ms()),
    });
    write_json_atomic(&path, &value)?;

    let (heartbeat, mut stop) = watch::channel(false);
    let heartbeat_path = path.clone();
    let expected = install_id.to_string();
    tokio::spawn(async move {
        let mut interval = tokio::time::interval(super::heartbeat_interval());
        interval.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Delay);
        interval.tick().await;
        loop {
            tokio::select! {
                _ = stop.changed() => return,
                _ = interval.tick() => {
                    if !ours(&heartbeat_path, &[("installId", expected.as_str())]) {
                        return;
                    }
                    let Ok(Some(mut value)) = read_json(&heartbeat_path) else {
                        return;
                    };
                    if let Some(object) = value.as_object_mut() {
                        object.insert("heartbeat".to_string(), json!(now_ms()));
                    }
                    let _ = write_json_atomic(&heartbeat_path, &value);
                }
            }
        }
    });

    Ok(ReleaseLease {
        path,
        install_id: install_id.to_string(),
        heartbeat,
    })
}

/// Live leases for one agent; stale files are removed while scanning.
fn live_leases(root: &Path, agent: &str) -> (Vec<Value>, Vec<String>) {
    let dir = leases_dir(root, agent);
    let mut live = Vec::new();
    let mut unknown = Vec::new();
    let entries = match std::fs::read_dir(&dir) {
        Ok(entries) => entries,
        Err(_) => return (live, unknown),
    };
    let now = now_ms();
    let boot = boot_time_ms(now);
    for entry in entries.flatten() {
        let name = entry.file_name();
        let Some(name) = name.to_str() else { continue };
        if !(name.starts_with("lease-") && name.ends_with(".json")) {
            continue;
        }
        let Ok(file_type) = entry.file_type() else {
            continue;
        };
        if !file_type.is_file() {
            continue;
        }
        let path = entry.path();
        let record = read_json(&path).ok().flatten();
        let (is_live, reason) = alive(record.as_ref(), &path, now, boot);
        if !is_live {
            let _ = std::fs::remove_file(&path);
            continue;
        }
        if reason.contains("cannot be signalled") {
            unknown.push(format!("{name}: {reason}"));
            continue;
        }
        let install_id = match record.as_ref().and_then(|value| value.get("installId")) {
            Some(Value::String(install_id)) => Some(install_id.clone()),
            _ => None,
        };
        match install_id {
            Some(install_id) => {
                let mut record = record.unwrap_or(Value::Null);
                if let Some(object) = record.as_object_mut() {
                    object.insert("_name".to_string(), json!(name));
                    object.insert("installId".to_string(), json!(install_id));
                }
                live.push(record);
            }
            None => unknown.push(format!("{name}: {reason}")),
        }
    }
    (live, unknown)
}

/// Whether a release is in use, with the reason `install.uninstall` reports.
pub fn in_use(root: &Path, agent: &str, install_id: &str) -> Option<String> {
    let (live, unknown) = live_leases(root, agent);
    for lease in &live {
        if lease.get("installId").and_then(Value::as_str) == Some(install_id) {
            let pid = lease
                .get("pid")
                .and_then(|value| numeric(Some(value)))
                .unwrap_or(0);
            return Some(format!("in use by pid {pid}"));
        }
    }
    unknown
        .first()
        .map(|entry| format!("cannot verify use: {entry}"))
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::install::now_ms;

    fn record(pid: i64, heartbeat: i64) -> Value {
        json!({
            "host": hostname(),
            "pid": pid.to_string(),
            "heartbeat": heartbeat,
            "installId": "rel-1",
        })
    }

    #[test]
    fn numbers_may_be_json_numbers_strings_or_integral_floats() {
        assert_eq!(
            numeric(Some(&json!(1_700_000_000_000i64))),
            Some(1_700_000_000_000)
        );
        assert_eq!(
            numeric(Some(&json!("1700000000000"))),
            Some(1_700_000_000_000)
        );
        assert_eq!(
            numeric(Some(&json!(1_700_000_000_000.0))),
            Some(1_700_000_000_000)
        );
        assert_eq!(numeric(Some(&json!(1.5))), None);
        assert_eq!(numeric(Some(&json!("x"))), None);
    }

    #[test]
    fn missing_records_and_foreign_hosts_stay_live() {
        let path = Path::new("/root/.locks/pi");
        assert!(alive(None, path, 1_000, 0).0);
        let mut value = record(std::process::id() as i64, 1_000);
        value["host"] = json!("elsewhere");
        assert!(alive(Some(&value), path, 1_000, 0).0);
        let value = json!({ "host": hostname(), "pid": "x", "heartbeat": 1 });
        assert!(alive(Some(&value), path, 1_000, 0).0);
    }

    #[test]
    fn live_pid_truth_table_matches_the_lua_lock_cases() {
        let path = Path::new("/root/.locks/pi");
        let now = 1_700_000_000_000;
        let boot = now - 3_600_000;
        let own = std::process::id() as i64;
        // Fresh heartbeat: live.
        assert!(alive(Some(&record(own, now - 60_000)), path, now, boot).0);
        // Older than ten minutes: stale.
        let (live, reason) = alive(Some(&record(own, now - 15 * 60_000)), path, now, boot);
        assert!(!live);
        assert!(reason.contains("heartbeat stopped"), "{reason}");
        // Before this boot (pid reuse): stale.
        let (live, reason) = alive(Some(&record(own, boot - 120_000)), path, now, boot);
        assert!(!live);
        assert!(reason.contains("before this boot"), "{reason}");
        // No heartbeat or a future one: conservative.
        assert!(alive(Some(&record(own, 0)), path, now, boot).0);
        assert!(alive(Some(&record(own, now + 10_000)), path, now, boot).0);
    }

    #[test]
    fn gone_pid_truth_table_matches_the_lua_lock_cases() {
        let path = Path::new("/root/.locks/pi");
        let now = 1_700_000_000_000;
        let boot = now - 60_000;
        // A pid that cannot exist.
        let gone = 2_000_000_000;
        assert!(alive(Some(&record(gone, now - 1_000)), path, now, boot).0);
        let (live, reason) = alive(Some(&record(gone, now - 10 * 60_000)), path, now, boot);
        assert!(!live);
        assert_eq!(reason, "abandoned");
        // No heartbeat, or one in the future, is never stolen.
        assert!(alive(Some(&record(gone, 0)), path, now, boot).0);
        assert!(alive(Some(&record(gone, now + 1_000)), path, now, boot).0);
    }

    #[test]
    fn cannot_signal_is_live() {
        let path = Path::new("/root/.locks/pi");
        let now = now_ms();
        let boot = boot_time_ms(now);
        let value = record(1, now);
        let (live, reason) = alive(Some(&value), path, now, boot);
        // pid 1 may be signalable in containers; the rule is "live either way".
        assert!(live, "{reason}");
    }

    struct TempDir(PathBuf);

    impl TempDir {
        fn new(label: &str) -> Self {
            static COUNTER: std::sync::atomic::AtomicU64 = std::sync::atomic::AtomicU64::new(0);
            let unique = COUNTER.fetch_add(1, std::sync::atomic::Ordering::Relaxed);
            let path = std::env::temp_dir().join(format!(
                "nvim-ade-lock-{label}-{}-{unique}",
                std::process::id()
            ));
            let _ = std::fs::remove_dir_all(&path);
            std::fs::create_dir_all(&path).expect("temp dir");
            Self(path)
        }
    }

    impl Drop for TempDir {
        fn drop(&mut self) {
            let _ = std::fs::remove_dir_all(&self.0);
        }
    }

    #[tokio::test]
    async fn acquire_serialises_reclaims_and_releases() {
        let root = TempDir::new("acquire");
        let lock = acquire(&root.0, "pi", "install").expect("first acquire");
        assert!(root.0.join(".locks/pi/owner.json").exists());
        assert!(lock.is_ours());
        let error = acquire(&root.0, "pi", "update").unwrap_err();
        assert!(
            error.contains("another instance is using this agent"),
            "{error}"
        );
        lock.release();
        assert!(!root.0.join(".locks/pi").exists());
        let again = acquire(&root.0, "pi", "install").expect("reacquire after release");
        again.release();

        // A record from before this boot is abandoned (pid reuse); acquire
        // reclaims the directory instead of refusing.
        std::fs::create_dir_all(root.0.join(".locks/pi")).expect("lock dir");
        write_json_atomic(
            &root.0.join(".locks/pi/owner.json"),
            &json!({
                "host": hostname(),
                "pid": pid_string(),
                "acquiredAt": "2026-11-16T10:20:30Z",
                "heartbeat": 1,
                "action": "install",
            }),
        )
        .expect("stale owner");
        let reclaimed = acquire(&root.0, "pi", "install").expect("reclaim stale lock");
        assert!(reclaimed.is_ours());
        reclaimed.release();
    }

    #[test]
    fn lease_scan_reports_in_use_and_deletes_abandoned_files() {
        let root = TempDir::new("leases");
        let dir = leases_dir(&root.0, "pi");
        std::fs::create_dir_all(&dir).expect("lease dir");
        let now = now_ms();
        let write = |name: &str, value: Value| {
            let path = dir.join(name);
            write_json_atomic(&path, &value).expect("lease");
        };
        write(
            "lease-live.json",
            json!({
                "host": hostname(),
                "pid": pid_string(),
                "installId": "rel-1",
                "heartbeat": now + 600_000,
                "startedAt": "2026-11-16T10:20:30Z",
            }),
        );
        write(
            "lease-stale.json",
            json!({
                "host": hostname(),
                "pid": "2000000000",
                "installId": "rel-1",
                "heartbeat": 1,
                "startedAt": "2026-11-16T10:20:30Z",
            }),
        );
        let reason = in_use(&root.0, "pi", "rel-1").expect("in use");
        assert!(reason.contains("in use by pid"), "{reason}");
        assert!(in_use(&root.0, "pi", "rel-2").is_none());
        assert!(
            !dir.join("lease-stale.json").exists(),
            "abandoned leases are removed while scanning"
        );

        // A live lease without an installId blocks every release of the agent.
        write(
            "lease-unknown.json",
            json!({
                "host": hostname(),
                "pid": pid_string(),
                "heartbeat": now + 600_000,
                "startedAt": "2026-11-16T10:20:30Z",
            }),
        );
        let reason = in_use(&root.0, "pi", "rel-2").expect("unverifiable");
        assert!(reason.contains("cannot verify use"), "{reason}");

        std::fs::remove_file(dir.join("lease-live.json")).expect("remove live");
        std::fs::remove_file(dir.join("lease-unknown.json")).expect("remove unknown");
        assert!(in_use(&root.0, "pi", "rel-1").is_none());
    }
}
