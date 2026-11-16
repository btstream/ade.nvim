//! Managed installs in the service (PROTOCOL.md section 16).
//!
//! The Lua `ade.manager` implementation is the reference for the on-disk
//! formats: both front ends share one store, so the layout, the lock and lease
//! records and the JSON files here are normative (section 16.1/16.2). Anything
//! that differs is a bug, not an implementation detail.
//!
//! The module is compiled on unix only. `hello` advertises the `"install"`
//! feature there and the front end keeps its Lua implementation everywhere
//! else (section 16).

pub mod lock;
pub mod npm;
pub mod store;

use std::path::{Component, Path, PathBuf};
use std::sync::Arc;
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use serde_json::{json, Value};
use tokio::sync::watch;

/// Contract error codes (PROTOCOL.md 16.5).
pub const INVALID_PARAMETER: i64 = -32040;
pub const RESOLVE_FAILED: i64 = -32041;
pub const BUSY: i64 = -32042;
pub const INSTALL_FAILED: i64 = -32043;
pub const IN_USE: i64 = -32044;
pub const NOT_INSTALLED: i64 = -32045;
pub const CANCELLED: i64 = -32800;

/// Heartbeat period for locks and leases (16.2).
pub const HEARTBEAT: Duration = Duration::from_secs(15);

/// Heartbeat period, with a test-only override.
///
/// The protocol fixes 15 s; integration tests shorten it through the
/// environment so "a deleted record is not recreated" is observable quickly.
pub fn heartbeat_interval() -> Duration {
    std::env::var("NVIM_ADE_SERVER_HEARTBEAT_MS")
        .ok()
        .and_then(|value| value.trim().parse::<u64>().ok())
        .filter(|value| *value > 0)
        .map(Duration::from_millis)
        .unwrap_or(HEARTBEAT)
}
/// A record whose pid is gone is abandoned after this heartbeat age.
pub const STALE_MS: i64 = 120_000;
/// A record whose pid exists is abandoned after this heartbeat age.
pub const ALIVE_STALE_MS: i64 = 600_000;
/// Clock allowance around the boot time.
pub const BOOT_GRACE_MS: i64 = 60_000;

/// Default npm timeouts (16.3).
pub const DEFAULT_RUN_TIMEOUT_MS: u64 = 300_000;
pub const DEFAULT_RESOLVE_TIMEOUT_MS: u64 = 60_000;
/// Default output cap for an install run.
pub const DEFAULT_MAX_LOG_BYTES: usize = 1024 * 1024;
/// One `install.progress` output line is cut at this many bytes.
pub const MAX_OUTPUT_LINE: usize = 4096;
/// `data.log` carried by a failed install.
pub const FAILURE_LOG_BYTES: usize = 4000;

/// Wall-clock milliseconds since the epoch (16.2).
pub fn now_ms() -> i64 {
    match SystemTime::now().duration_since(UNIX_EPOCH) {
        Ok(duration) => duration.as_millis() as i64,
        Err(_) => 0,
    }
}

/// The boot time in wall-clock milliseconds: `now - uptime`, so suspend time
/// counts as uptime (16.2).
#[cfg(target_os = "linux")]
pub fn boot_time_ms(now: i64) -> i64 {
    let mut timespec = libc::timespec {
        tv_sec: 0,
        tv_nsec: 0,
    };
    let result = unsafe { libc::clock_gettime(libc::CLOCK_BOOTTIME, &mut timespec) };
    if result != 0 {
        return now;
    }
    let uptime = timespec.tv_sec * 1000 + timespec.tv_nsec / 1_000_000;
    now - uptime
}

#[cfg(target_os = "macos")]
pub fn boot_time_ms(now: i64) -> i64 {
    let mut boottime = libc::timeval {
        tv_sec: 0,
        tv_usec: 0,
    };
    let mut size = std::mem::size_of::<libc::timeval>();
    let mut mib = [libc::CTL_KERN, libc::KERN_BOOTTIME];
    let result = unsafe {
        libc::sysctl(
            mib.as_mut_ptr(),
            mib.len() as u32,
            std::ptr::null_mut(),
            &mut size,
            (&mut boottime as *mut libc::timeval).cast(),
            size,
        )
    };
    if result != 0 {
        return now;
    }
    boottime.tv_sec as i64 * 1000 + boottime.tv_usec as i64 / 1000
}

#[cfg(all(unix, not(any(target_os = "linux", target_os = "macos"))))]
pub fn boot_time_ms(now: i64) -> i64 {
    let mut timespec = libc::timespec {
        tv_sec: 0,
        tv_nsec: 0,
    };
    let result = unsafe { libc::clock_gettime(libc::CLOCK_MONOTONIC, &mut timespec) };
    if result != 0 {
        return now;
    }
    now - (timespec.tv_sec as i64 * 1000 + timespec.tv_nsec as i64 / 1_000_000)
}

/// `gethostname(2)`, or `"unknown"` when it cannot be read (16.2).
pub fn hostname() -> String {
    let mut buffer = [0u8; 256];
    let result = unsafe { libc::gethostname(buffer.as_mut_ptr().cast(), buffer.len()) };
    if result != 0 {
        return "unknown".to_string();
    }
    let end = buffer
        .iter()
        .position(|byte| *byte == 0)
        .unwrap_or(buffer.len());
    match std::str::from_utf8(&buffer[..end]) {
        Ok(name) if !name.is_empty() => name.to_string(),
        _ => "unknown".to_string(),
    }
}

/// The LuaJIT `jit.os` spelling used in receipts (16.1).
pub fn platform() -> &'static str {
    if cfg!(target_os = "linux") {
        "Linux"
    } else if cfg!(target_os = "macos") {
        "OSX"
    } else if cfg!(windows) {
        "Windows"
    } else {
        "Other"
    }
}

/// The LuaJIT `jit.arch` spelling used in receipts (16.1).
pub fn arch() -> &'static str {
    if cfg!(target_arch = "x86_64") {
        "x64"
    } else if cfg!(target_arch = "aarch64") {
        "arm64"
    } else if cfg!(target_arch = "x86") {
        "x86"
    } else {
        "other"
    }
}

/// UTC timestamp in the format both implementations write (16.1).
pub fn timestamp(now_ms: i64) -> String {
    let seconds = now_ms.div_euclid(1000);
    let days = seconds.div_euclid(86_400);
    let time = seconds.rem_euclid(86_400);
    let (year, month, day) = civil_from_days(days);
    format!(
        "{year:04}-{month:02}-{day:02}T{:02}:{:02}:{:02}Z",
        time / 3600,
        (time % 3600) / 60,
        time % 60
    )
}

/// Howard Hinnant's days-to-civil algorithm, so the service needs no date
/// dependency for one timestamp.
fn civil_from_days(days: i64) -> (i64, u32, u32) {
    let z = days + 719_468;
    let era = if z >= 0 { z } else { z - 146_096 } / 146_097;
    let doe = z - era * 146_097;
    let yoe = (doe - doe / 1460 + doe / 36_524 - doe / 146_096) / 365;
    let y = yoe + era * 400;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let day = doy - (153 * mp + 2) / 5 + 1;
    let month = if mp < 10 { mp + 3 } else { mp - 9 };
    let year = if month <= 2 { y + 1 } else { y };
    (year, month as u32, day as u32)
}

/// Lexical normalisation: collapse `.` and `..` without touching the disk.
pub fn normalize(path: &str) -> Option<PathBuf> {
    if path.is_empty() {
        return None;
    }
    let mut out = PathBuf::new();
    for component in Path::new(path).components() {
        match component {
            Component::Prefix(prefix) => out.push(prefix.as_os_str()),
            Component::RootDir => out.push(Component::RootDir.as_os_str()),
            Component::CurDir => {}
            Component::ParentDir => {
                out.pop();
            }
            Component::Normal(part) => out.push(part),
        }
    }
    if out.as_os_str().is_empty() {
        None
    } else {
        Some(out)
    }
}

/// Whether `path` is `root` or below it, compared by component (16.1).
pub fn contains(root: &Path, path: &Path) -> bool {
    let (Some(root), Some(path)) = (
        normalize(&root.to_string_lossy()),
        normalize(&path.to_string_lossy()),
    ) else {
        return false;
    };
    path == root || path.starts_with(&root)
}

/// Validate a `root` and return its normalised form (16.1).
pub fn check_root(root: &str) -> Result<PathBuf, String> {
    let path =
        normalize(root).ok_or_else(|| "manager.root must be an absolute path".to_string())?;
    if !path.is_absolute() {
        return Err(format!(
            "manager.root must be absolute, got {}",
            path.display()
        ));
    }
    if path == Path::new("/") {
        return Err("manager.root must not be the filesystem root".to_string());
    }
    if let Some(home) = home_dir() {
        if path == home {
            return Err("manager.root must not be the home directory".to_string());
        }
    }
    Ok(path)
}

fn home_dir() -> Option<PathBuf> {
    let value = std::env::var("HOME")
        .ok()
        .or_else(|| std::env::var("USERPROFILE").ok())?;
    normalize(&value)
}

/// Agent id rule (16.1).
pub fn valid_agent_id(id: &str) -> bool {
    let bytes = id.as_bytes();
    if bytes.is_empty() || bytes.len() > 64 {
        return false;
    }
    let first = bytes[0];
    if !(first.is_ascii_lowercase() || first.is_ascii_digit()) {
        return false;
    }
    bytes.iter().all(|byte| {
        byte.is_ascii_lowercase() || byte.is_ascii_digit() || *byte == b'_' || *byte == b'-'
    })
}

/// Install id rule (16.1).
pub fn valid_install_id(value: &str) -> bool {
    let bytes = value.as_bytes();
    if bytes.is_empty() || bytes.len() > 96 {
        return false;
    }
    if !(bytes[0].is_ascii_lowercase() || bytes[0].is_ascii_digit()) {
        return false;
    }
    if value.contains("..") || value.contains('/') || value.contains('\\') {
        return false;
    }
    bytes.iter().all(|byte| {
        byte.is_ascii_lowercase() || byte.is_ascii_digit() || matches!(*byte, b'.' | b'_' | b'-')
    })
}

/// npm package rule (16.1).
pub fn valid_package(name: &str) -> bool {
    let bytes = name.as_bytes();
    if bytes.is_empty() || bytes.len() > 128 || bytes[0] == b'-' {
        return false;
    }
    let mut parts = name.split('/');
    let first = parts.next().unwrap_or_default();
    let second = parts.next();
    if parts.next().is_some() {
        return false;
    }
    let unscoped = first.strip_prefix('@').unwrap_or(first);
    if unscoped.is_empty()
        || unscoped == "."
        || unscoped == ".."
        || !unscoped
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || matches!(byte, b'.' | b'_' | b'-'))
    {
        return false;
    }
    match second {
        None => true,
        Some(segment) => {
            !segment.is_empty()
                && segment != "."
                && segment != ".."
                && segment
                    .bytes()
                    .all(|byte| byte.is_ascii_alphanumeric() || matches!(byte, b'.' | b'_' | b'-'))
        }
    }
}

/// Relative path inside a package: `entry` and `bin` (16.1).
pub fn valid_relative(value: &str) -> bool {
    if value.is_empty() || value.starts_with('/') {
        return false;
    }
    if !value.bytes().all(|byte| {
        byte.is_ascii_alphanumeric() || matches!(byte, b'.' | b'_' | b'@' | b'/' | b'-')
    }) {
        return false;
    }
    value
        .split('/')
        .all(|segment| !segment.is_empty() && segment != "." && segment != "..")
}

/// An exact install version (16.1).
pub fn valid_version(value: &str) -> bool {
    let bytes = value.as_bytes();
    if bytes.is_empty() || bytes.len() > 64 || value == "latest" {
        return false;
    }
    if bytes[0] == b'-' || value.contains("..") {
        return false;
    }
    if !bytes
        .iter()
        .all(|byte| byte.is_ascii_alphanumeric() || matches!(*byte, b'.' | b'+' | b'-'))
    {
        return false;
    }
    let mut parts = value.split('.');
    let (Some(major), Some(minor), Some(patch)) = (parts.next(), parts.next(), parts.next()) else {
        return false;
    };
    let numeric = |part: &str| !part.is_empty() && part.bytes().all(|byte| byte.is_ascii_digit());
    numeric(major)
        && numeric(minor)
        && patch
            .bytes()
            .next()
            .is_some_and(|byte| byte.is_ascii_digit())
}

/// A version spec: an exact version or exactly `"latest"`.
pub fn valid_spec(value: &str) -> bool {
    value == "latest" || valid_version(value)
}

/// The front-end-chosen job id for `install.run` / `install.uninstall` (16.3).
pub fn valid_job(value: &str) -> bool {
    let bytes = value.as_bytes();
    if bytes.is_empty() || bytes.len() > 64 {
        return false;
    }
    bytes
        .iter()
        .all(|byte| byte.is_ascii_alphanumeric() || matches!(*byte, b'_' | b'-'))
}

/// Generate a release id: `v<version>-<suffix>` (16.1).
///
/// The suffix only has to be unique in `releases/`; it is derived from the
/// clock, the pid and a counter, then checked against the directory.
pub fn install_id(version: &str, releases: &Path) -> String {
    static COUNTER: std::sync::atomic::AtomicU64 = std::sync::atomic::AtomicU64::new(0);
    let mut cleaned = String::new();
    for character in version.to_ascii_lowercase().chars() {
        if character.is_ascii_alphanumeric() || matches!(character, '.' | '-') {
            cleaned.push(character);
        } else {
            cleaned.push('_');
        }
        if cleaned.len() >= 64 {
            break;
        }
    }
    loop {
        let counter = COUNTER.fetch_add(1, std::sync::atomic::Ordering::Relaxed);
        let nanos = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .map(|duration| duration.as_nanos())
            .unwrap_or_default();
        let mut value = nanos ^ (u128::from(std::process::id()) << 32) ^ u128::from(counter);
        let mut suffix = String::new();
        for _ in 0..24 {
            let digit = (value % 36) as u8;
            let character = if digit < 10 {
                char::from(b'0' + digit)
            } else {
                char::from(b'a' + (digit - 10))
            };
            suffix.push(character);
            value /= 36;
            if value == 0 {
                break;
            }
        }
        let id = format!("v{cleaned}-{suffix}");
        if valid_install_id(&id) && !releases.join(&id).exists() {
            return id;
        }
    }
}

/// Sends one `install.progress` value to the hub.
#[derive(Clone)]
pub struct Progress(Arc<dyn Fn(Value) + Send + Sync>);

impl Progress {
    pub fn new<F>(send: F) -> Self
    where
        F: Fn(Value) + Send + Sync + 'static,
    {
        Self(Arc::new(send))
    }

    pub fn emit(&self, value: Value) {
        (self.0)(value);
    }
}

/// The terminal outcome of one request; the hub turns it into a response.
#[derive(Debug)]
pub enum Outcome {
    Success(Value),
    Failed {
        code: i64,
        message: String,
        data: Option<Value>,
    },
    Cancelled,
}

impl Outcome {
    pub fn failed(code: i64, message: impl Into<String>) -> Self {
        Self::Failed {
            code,
            message: message.into(),
            data: None,
        }
    }

    pub fn failed_with(code: i64, message: impl Into<String>, data: Value) -> Self {
        Self::Failed {
            code,
            message: message.into(),
            data: Some(data),
        }
    }
}

/// Test-only pause between taking the lock and reading state.
async fn lock_test_delay() {
    if let Ok(value) = std::env::var("NVIM_ADE_INSTALL_LOCK_DELAY_MS") {
        if let Ok(ms) = value.trim().parse::<u64>() {
            tokio::time::sleep(Duration::from_millis(ms)).await;
        }
    }
}

/// Test-only panic after the lock was taken, to exercise job recovery.
fn panic_after_lock() -> bool {
    std::env::var("NVIM_ADE_INSTALL_PANIC").ok().as_deref() == Some("1")
}

/// An `agent.attach` `launch` (16.4), already validated.
#[derive(Debug, Clone)]
pub struct Launch {
    pub root: PathBuf,
    pub agent: String,
    pub install_id: String,
}

/// Parse and validate `params.launch` (16.1/16.4).
pub fn parse_launch(value: &Value) -> Result<Launch, String> {
    let object = value
        .as_object()
        .ok_or_else(|| "launch must be an object".to_string())?;
    let root = object
        .get("root")
        .and_then(Value::as_str)
        .ok_or_else(|| "launch.root must be a string".to_string())?;
    let root = check_root(root)?;
    let agent = object
        .get("agent")
        .and_then(Value::as_str)
        .filter(|value| valid_agent_id(value))
        .ok_or_else(|| "launch.agent is invalid".to_string())?;
    let install_id = object
        .get("installId")
        .and_then(Value::as_str)
        .filter(|value| valid_install_id(value))
        .ok_or_else(|| "launch.installId is invalid".to_string())?;
    Ok(Launch {
        root,
        agent: agent.to_string(),
        install_id: install_id.to_string(),
    })
}

/// Everything `install.run` needs, already validated by the caller.
pub struct RunRequest {
    pub job: String,
    pub root: PathBuf,
    pub agent: String,
    pub action: String,
    pub package: String,
    pub entry: String,
    pub bin: Option<String>,
    pub version: String,
    pub npm: String,
    pub env: Vec<(String, String)>,
    pub timeout: Duration,
    pub max_log_bytes: usize,
}

/// Everything `install.uninstall` needs.
pub struct UninstallRequest {
    pub job: String,
    pub root: PathBuf,
    pub agent: String,
    pub install_id: Option<String>,
}

/// Everything `install.resolve` needs.
pub struct ResolveRequest {
    pub root: PathBuf,
    pub package: String,
    pub spec: String,
    pub npm: String,
    pub env: Vec<(String, String)>,
    pub timeout: Duration,
}

/// `install.run`: take the lock, build a release, commit atomically, prune.
pub async fn run(
    request: RunRequest,
    mut cancel: watch::Receiver<bool>,
    progress: &Progress,
) -> Outcome {
    let base = |phase: &str, extra: Value| {
        let mut value = json!({
            "job": request.job,
            "agent": request.agent,
            "action": request.action,
            "phase": phase,
        });
        if let (Some(object), Some(more)) = (value.as_object_mut(), extra.as_object()) {
            for (key, item) in more {
                object.insert(key.clone(), item.clone());
            }
        }
        value
    };
    let failed_with_log = |message: String, log: Option<String>| {
        let log = log.unwrap_or_default();
        let data = if log.is_empty() {
            Value::Null
        } else {
            json!({ "log": log })
        };
        Outcome::Failed {
            code: INSTALL_FAILED,
            message,
            data: if data.is_null() { None } else { Some(data) },
        }
    };

    // Everything that reads the store happens under the lock (16.3); two
    // front ends may otherwise both decide they are up to date.
    let lock = match lock::acquire(&request.root, &request.agent, &request.action) {
        Ok(lock) => lock,
        Err(reason) => {
            progress.emit(base("failed", json!({ "message": reason })));
            return Outcome::failed_with(BUSY, reason.clone(), json!({ "reason": reason }));
        }
    };
    lock_test_delay().await;
    if panic_after_lock() {
        panic!("NVIM_ADE_INSTALL_PANIC: simulated install panic");
    }
    let state = store::state(&request.root, &request.agent);
    if request.action == "update" {
        if let store::Status::NotInstalled = state.status {
            lock.release();
            let message = format!("{} is not installed; use install", request.agent);
            progress.emit(base("failed", json!({ "message": message })));
            return Outcome::failed(NOT_INSTALLED, message);
        }
        if let store::Status::Installed {
            version,
            install_id,
            ..
        } = &state.status
        {
            if version == &request.version {
                lock.release();
                progress.emit(base(
                    "unchanged",
                    json!({ "version": version, "installId": install_id }),
                ));
                return Outcome::Success(json!({
                    "status": "unchanged",
                    "installId": install_id,
                    "version": version,
                }));
            }
        }
    }

    progress.emit(base("checking", Value::Null));
    if *cancel.borrow() {
        lock.release();
        progress.emit(base("cancelled", Value::Null));
        return Outcome::Cancelled;
    }

    let releases = store::releases_dir(&request.root, &request.agent);
    if let Err(error) = std::fs::create_dir_all(&releases) {
        lock.release();
        let message = format!("unable to create {}: {error}", releases.display());
        progress.emit(base("failed", json!({ "message": message })));
        return Outcome::failed(INSTALL_FAILED, message);
    }
    // `create_dir` (not `create_dir_all`): an existing directory is a name
    // collision and must never be reused, so retry the suffix instead.
    let (install_id, dir) = loop {
        let candidate = install_id(&request.version, &releases);
        let dir = releases.join(&candidate);
        match std::fs::create_dir(&dir) {
            Ok(()) => break (candidate, dir),
            Err(error) if error.kind() == std::io::ErrorKind::AlreadyExists => continue,
            Err(error) => {
                lock.release();
                let message = format!("unable to create {}: {error}", dir.display());
                progress.emit(base("failed", json!({ "message": message })));
                return Outcome::failed(INSTALL_FAILED, message);
            }
        }
    };

    let cleanup = |dir: &Path| {
        let _ = std::fs::remove_dir_all(dir);
    };

    if let Err(error) = npm::write_manifest(&dir, &request.package, &request.version) {
        cleanup(&dir);
        lock.release();
        progress.emit(base("failed", json!({ "message": error })));
        return Outcome::failed(INSTALL_FAILED, error);
    }

    progress.emit(base(
        "installing",
        json!({ "version": request.version, "dir": dir.display().to_string() }),
    ));
    let line_progress = progress.clone();
    let line_base = base;
    let on_line = move |line: String| {
        line_progress.emit(line_base("output", json!({ "line": line })));
    };
    let output = npm::install(
        &request.npm,
        &request.env,
        &dir,
        &request.package,
        &request.version,
        request.timeout,
        request.max_log_bytes,
        &mut cancel,
        &on_line,
    )
    .await;
    let output = match output {
        npm::InstallOutcome::Ok(output) => output,
        npm::InstallOutcome::Cancelled => {
            cleanup(&dir);
            lock.release();
            progress.emit(base("cancelled", Value::Null));
            return Outcome::Cancelled;
        }
        npm::InstallOutcome::Failed { message, log } => {
            cleanup(&dir);
            lock.release();
            progress.emit(base("failed", json!({ "message": message })));
            return failed_with_log(message, log);
        }
    };

    if *cancel.borrow() {
        cleanup(&dir);
        lock.release();
        progress.emit(base("cancelled", Value::Null));
        return Outcome::Cancelled;
    }

    progress.emit(base("verifying", json!({ "version": request.version })));
    let installed = match npm::read_installed(&dir, &request.package) {
        Ok(manifest) => manifest,
        Err(message) => {
            cleanup(&dir);
            lock.release();
            progress.emit(base("failed", json!({ "message": message })));
            return Outcome::failed(INSTALL_FAILED, message);
        }
    };
    if installed.version != request.version {
        let message = format!(
            "npm installed {} but {} was requested",
            installed.version, request.version
        );
        cleanup(&dir);
        lock.release();
        progress.emit(base("failed", json!({ "message": message })));
        return Outcome::failed(INSTALL_FAILED, message);
    }

    let entry_relative = format!("node_modules/{}/{}", request.package, request.entry);
    let entry_path = dir.join(&entry_relative);
    let inside = normalize(&entry_path.to_string_lossy()).is_some_and(|path| contains(&dir, &path));
    let is_file = std::fs::metadata(&entry_path).is_ok_and(|meta| meta.is_file());
    if !inside || !is_file {
        let message = format!("the package entrypoint is missing: {}", request.entry);
        cleanup(&dir);
        lock.release();
        progress.emit(base("failed", json!({ "message": message })));
        return Outcome::failed(INSTALL_FAILED, message);
    }

    let receipt = store::Receipt {
        install_id: install_id.clone(),
        package: request.package.clone(),
        version: request.version.clone(),
        entry: entry_relative,
        bin: request.bin.clone(),
    };
    if let Err(error) = store::write_receipt(&request.root, &request.agent, &receipt) {
        cleanup(&dir);
        lock.release();
        progress.emit(base("failed", json!({ "message": error })));
        return Outcome::failed(INSTALL_FAILED, error);
    }

    if !lock.is_ours() {
        cleanup(&dir);
        lock.release();
        let message = "the install lock was lost before commit".to_string();
        progress.emit(base("failed", json!({ "message": message })));
        return Outcome::failed(INSTALL_FAILED, message);
    }

    if let Err(error) = store::write_pointer(
        &request.root,
        &request.agent,
        &install_id,
        &request.package,
        &request.version,
    ) {
        cleanup(&dir);
        lock.release();
        progress.emit(base("failed", json!({ "message": error })));
        return Outcome::failed(INSTALL_FAILED, error);
    }

    // The commit happened: a cancel from here on is ignored (16.3).
    prune(&request.root, &request.agent, &install_id);
    lock.release();
    let _ = output;
    progress.emit(base(
        "committed",
        json!({ "version": request.version, "dir": dir.display().to_string() }),
    ));
    Outcome::Success(json!({
        "status": "committed",
        "installId": install_id,
        "version": request.version,
        "dir": dir.display().to_string(),
    }))
}

/// `install.uninstall`: pointer first, then the release directory (16.3).
pub async fn uninstall(
    request: UninstallRequest,
    cancel: watch::Receiver<bool>,
    progress: &Progress,
) -> Outcome {
    let base = |phase: &str, extra: Value| {
        let mut value = json!({
            "job": request.job,
            "agent": request.agent,
            "action": "uninstall",
            "phase": phase,
        });
        if let (Some(object), Some(more)) = (value.as_object_mut(), extra.as_object()) {
            for (key, item) in more {
                object.insert(key.clone(), item.clone());
            }
        }
        value
    };

    // Take the lock first and re-read everything under it: another front end
    // may have committed a different release since the caller confirmed.
    let lock = match lock::acquire(&request.root, &request.agent, "uninstall") {
        Ok(lock) => lock,
        Err(reason) => {
            progress.emit(base("failed", json!({ "message": reason })));
            return Outcome::failed_with(BUSY, reason.clone(), json!({ "reason": reason }));
        }
    };
    lock_test_delay().await;
    if panic_after_lock() {
        panic!("NVIM_ADE_INSTALL_PANIC: simulated uninstall panic");
    }
    let state = store::state(&request.root, &request.agent);
    let install_id = match state.status {
        store::Status::NotInstalled => {
            lock.release();
            let message = format!("{} has no manager-owned install", request.agent);
            progress.emit(base("failed", json!({ "message": message })));
            return Outcome::failed(NOT_INSTALLED, message);
        }
        store::Status::Broken {
            install_id: None,
            error,
        } => {
            lock.release();
            progress.emit(base("failed", json!({ "message": error })));
            return Outcome::failed(INSTALL_FAILED, error);
        }
        store::Status::Broken {
            install_id: Some(id),
            ..
        } => id,
        store::Status::Installed { install_id, .. } => install_id,
    };
    if request
        .install_id
        .as_deref()
        .is_some_and(|wanted| wanted != install_id)
    {
        lock.release();
        let message = "the installed release changed".to_string();
        progress.emit(base("failed", json!({ "message": message })));
        return Outcome::failed_with(BUSY, message, json!({ "reason": "changed" }));
    }
    if let Some(reason) = lock::in_use(&request.root, &request.agent, &install_id) {
        lock.release();
        progress.emit(base("failed", json!({ "message": reason })));
        return Outcome::failed_with(IN_USE, reason.clone(), json!({ "reason": reason }));
    }
    if *cancel.borrow() {
        lock.release();
        progress.emit(base("cancelled", Value::Null));
        return Outcome::Cancelled;
    }

    let dir = store::release_dir(&request.root, &request.agent, &install_id);
    let pointer = store::pointer_path(&request.root, &request.agent);
    if let Err(error) = std::fs::remove_file(&pointer) {
        if error.kind() != std::io::ErrorKind::NotFound {
            lock.release();
            let message = format!("unable to remove {}: {error}", pointer.display());
            progress.emit(base("failed", json!({ "message": message })));
            return Outcome::failed_with(
                INSTALL_FAILED,
                message,
                json!({ "installId": install_id }),
            );
        }
    }
    let removed = std::fs::remove_dir_all(&dir).is_ok();
    lock.release();
    if !removed {
        let message = format!(
            "the pointer was removed but files remain in {}",
            dir.display()
        );
        progress.emit(base("failed", json!({ "message": message })));
        return Outcome::failed_with(INSTALL_FAILED, message, json!({ "installId": install_id }));
    }
    progress.emit(base("removed", Value::Null));
    Outcome::Success(json!({ "installId": install_id }))
}

/// `install.resolve`: run `npm view`, parse the version (16.3).
pub async fn resolve(request: ResolveRequest, mut cancel: watch::Receiver<bool>) -> Outcome {
    let output = npm::resolve(
        &request.npm,
        &request.env,
        &request.root,
        &request.package,
        &request.spec,
        request.timeout,
        &mut cancel,
    )
    .await;
    match output {
        npm::ResolveOutcome::Version(version) => Outcome::Success(json!({ "version": version })),
        npm::ResolveOutcome::Cancelled => Outcome::Cancelled,
        npm::ResolveOutcome::Failed { code, message } => Outcome::failed(code, message),
    }
}

/// Delete every release except `keep` that is not in use (16.3).
fn prune(root: &Path, agent: &str, keep: &str) {
    for candidate in store::list_install_ids(root, agent) {
        if candidate == keep {
            continue;
        }
        if lock::in_use(root, agent, &candidate).is_some() {
            continue;
        }
        let dir = store::release_dir(root, agent, &candidate);
        if contains(root, &dir) {
            let _ = std::fs::remove_dir_all(&dir);
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn agent_ids_are_boring() {
        assert!(valid_agent_id("claude"));
        assert!(valid_agent_id("pi-2"));
        assert!(!valid_agent_id("../etc"));
        assert!(!valid_agent_id("a/b"));
        assert!(!valid_agent_id(""));
        assert!(!valid_agent_id(".hidden"));
        assert!(!valid_agent_id(&"a".repeat(65)));
    }

    #[test]
    fn install_ids_cannot_escape() {
        assert!(valid_install_id("v1.2.3-482910334455-5821"));
        assert!(valid_install_id("rel-1"));
        assert!(!valid_install_id("V1"));
        assert!(!valid_install_id("../x"));
        assert!(!valid_install_id("a/b"));
        assert!(!valid_install_id("a\\b"));
        assert!(!valid_install_id(".a"));
        assert!(!valid_install_id(&format!("a{}", "0".repeat(96))));
    }

    #[test]
    fn package_names_match_the_lua_test_list() {
        for good in [
            "opencode",
            "@geohar/pi-acp",
            "@agentclientprotocol/claude-agent-acp",
        ] {
            assert!(valid_package(good), "{good}");
        }
        for bad in [
            "--registry=http://evil",
            "../../etc/passwd",
            "",
            "@/x",
            "@scope/",
            "a/b/c",
        ] {
            assert!(!valid_package(bad), "{bad}");
        }
    }

    #[test]
    fn entries_stay_inside_the_package() {
        assert!(valid_relative("dist/index.js"));
        assert!(valid_relative("bin/cli"));
        assert!(valid_relative("@scope/pkg/index.js"));
        for bad in ["", "/abs", "../x", "a//b", "a/./b", "a/../b", "a b"] {
            assert!(!valid_relative(bad), "{bad}");
        }
    }

    #[test]
    fn versions_are_exact_or_latest() {
        assert!(valid_version("1.2.3"));
        assert!(valid_version("1.2.3-beta.1"));
        assert!(valid_version("1.2.3+build.5"));
        assert!(valid_spec("latest"));
        assert!(!valid_version("latest"));
        for bad in [
            "^1.0.0",
            ">=1",
            "latest-ish",
            "file:../../etc",
            "git+https://x",
            "-1.0.0",
            "",
            "1.0",
            "1.0..2",
        ] {
            assert!(!valid_version(bad), "{bad}");
        }
    }

    #[test]
    fn job_ids_are_short_and_safe() {
        assert!(valid_job("job-1"));
        assert!(valid_job("A_b-9"));
        assert!(!valid_job(""));
        assert!(!valid_job("a b"));
        assert!(!valid_job(&"a".repeat(65)));
    }

    #[test]
    fn root_rejects_dangerous_paths() {
        assert!(check_root("/").is_err());
        assert!(check_root("relative/path").is_err());
        let home = std::env::var("HOME").unwrap_or_default();
        if !home.is_empty() {
            assert!(check_root(&home).is_err());
        }
        assert!(check_root("/tmp/ade-install-root").is_ok());
    }

    #[test]
    fn containment_compares_components() {
        let root = Path::new("/a/agents");
        assert!(contains(root, Path::new("/a/agents/x")));
        assert!(!contains(root, Path::new("/a/agents-evil/x")));
        assert!(!contains(root, Path::new("/a/agents/../escape")));
    }

    #[test]
    fn timestamps_are_utc_seconds() {
        assert_eq!(timestamp(0), "1970-01-01T00:00:00Z");
        assert_eq!(timestamp(1_700_000_000_000), "2023-11-14T22:13:20Z");
    }

    #[test]
    fn generated_install_ids_cut_and_replace() {
        let dir = std::env::temp_dir();
        let id = install_id("1.0.0-RC.1", &dir);
        assert!(id.starts_with("v1.0.0-rc.1-"), "{id}");
        assert!(valid_install_id(&id));
        let id = install_id("1.2.3+build", &dir);
        assert!(id.starts_with("v1.2.3_build-"), "{id}");
        let long = format!("1.{}.{}", "2".repeat(80), "3".repeat(10));
        let id = install_id(&long, &dir);
        assert!(id.len() <= 96, "{id}");
    }
}
