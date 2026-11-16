#![cfg(unix)]
//! Integration tests for managed installs (PROTOCOL.md section 16).
//!
//! Each test runs the real service against a private temporary store root and a
//! fake npm (`tests/fixtures/fake-npm`) whose behaviour is chosen through `env`.

mod common;

use std::path::{Path, PathBuf};
use std::time::{Duration, Instant};

use serde_json::{json, Value};

use common::{Client, TestServer};
use nvim_ade_server::install::{lock, store};

fn fixture(name: &str) -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("tests")
        .join("fixtures")
        .join(name)
}

fn npm() -> String {
    fixture("fake-npm").to_string_lossy().to_string()
}

struct Root(PathBuf);

impl Root {
    fn new(label: &str) -> Self {
        static COUNTER: std::sync::atomic::AtomicU64 = std::sync::atomic::AtomicU64::new(0);
        let unique = COUNTER.fetch_add(1, std::sync::atomic::Ordering::Relaxed);
        let path = std::env::temp_dir().join(format!(
            "nvim-ade-install-{label}-{}-{unique}",
            std::process::id()
        ));
        let _ = std::fs::remove_dir_all(&path);
        std::fs::create_dir_all(&path).expect("create store root");
        Self(path)
    }

    fn path(&self) -> &Path {
        &self.0
    }
}

impl Drop for Root {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.0);
    }
}

/// A complete environment for npm: everything the test process has, plus the
/// fake's control variables.
fn env_json(extra: &[(&str, &str)]) -> Value {
    let mut map = serde_json::Map::new();
    for (key, value) in std::env::vars() {
        map.insert(key, Value::String(value));
    }
    map.insert("FAKE_NPM_MODE".to_string(), json!("ok"));
    for (key, value) in extra {
        map.insert((*key).to_string(), json!(value));
    }
    Value::Object(map)
}

fn run_params(
    root: &Path,
    agent: &str,
    job: &str,
    action: &str,
    version: &str,
    env: &[(&str, &str)],
) -> Value {
    json!({
        "job": job,
        "root": root,
        "agent": agent,
        "action": action,
        "package": "pkg",
        "entry": "dist/index.js",
        "bin": "pkg",
        "version": version,
        "npm": npm(),
        "env": env_json(env),
        "timeout_ms": 15000,
    })
}

fn uninstall_params(root: &Path, agent: &str, job: &str, install_id: Option<&str>) -> Value {
    let mut params = json!({
        "job": job,
        "root": root,
        "agent": agent,
    });
    if let Some(id) = install_id {
        params["installId"] = json!(id);
    }
    params
}

fn resolve_params(root: &Path, spec: &str, env: &[(&str, &str)]) -> Value {
    json!({
        "root": root,
        "package": "pkg",
        "spec": spec,
        "npm": npm(),
        "env": env_json(env),
        "timeout_ms": 10000,
    })
}

fn connect(server: &TestServer) -> Client {
    let mut client = server.connect();
    let hello = client.hello(&server.token(), 4);
    assert!(hello["result"].is_object(), "hello failed: {hello}");
    client
}

fn send_request(client: &mut Client, id: Value, method: &str, params: Value) {
    client.send(&json!({
        "jsonrpc": "2.0",
        "id": id,
        "method": method,
        "params": params,
    }));
}

/// Read frames until `wanted` responses arrived, collecting progress events.
fn pump(
    client: &mut Client,
    wanted: &[Value],
    progress: &mut Vec<Value>,
) -> serde_json::Map<String, Value> {
    let mut replies = serde_json::Map::new();
    while replies.len() < wanted.len() {
        let frame = client.recv().expect("a frame from the service");
        if frame.get("method") == Some(&json!("install.progress")) {
            progress.push(frame["params"].clone());
            continue;
        }
        if frame.get("method").is_some() {
            continue;
        }
        let Some(id) = frame.get("id") else { continue };
        if wanted.iter().any(|wanted| wanted == id) {
            replies.insert(serde_json::to_string(id).unwrap(), frame);
        }
    }
    replies
}

fn one_request(client: &mut Client, id: Value, method: &str, params: Value) -> (Value, Vec<Value>) {
    send_request(client, id.clone(), method, params);
    let mut progress = Vec::new();
    let replies = pump(client, std::slice::from_ref(&id), &mut progress);
    (replies.into_values().next().expect("response"), progress)
}

fn progress_phases(progress: &[Value]) -> Vec<&str> {
    progress
        .iter()
        .filter_map(|event| event.get("phase").and_then(Value::as_str))
        .collect()
}

fn wait_for<F>(label: &str, mut condition: F)
where
    F: FnMut() -> bool,
{
    let deadline = Instant::now() + Duration::from_secs(20);
    while Instant::now() < deadline {
        if condition() {
            return;
        }
        std::thread::sleep(Duration::from_millis(25));
    }
    panic!("timed out waiting for {label}");
}

fn installed_state(root: &Path, agent: &str) -> Option<(String, String, PathBuf)> {
    match store::state(root, agent).status {
        store::Status::Installed {
            install_id,
            version,
            entry,
            ..
        } => Some((install_id, version, entry)),
        _ => None,
    }
}

fn write_lease(root: &Path, agent: &str, install_id: &str, pid: &str, heartbeat: i64) -> PathBuf {
    let dir = root.join(".leases").join(agent);
    std::fs::create_dir_all(&dir).expect("lease dir");
    let path = dir.join(format!("lease-{pid}-fixture.json"));
    let value = json!({
        "host": nvim_ade_server::install::hostname(),
        "pid": pid,
        "installId": install_id,
        "heartbeat": heartbeat,
        "startedAt": "2026-11-16T10:20:30Z",
    });
    std::fs::write(&path, serde_json::to_vec(&value).unwrap()).expect("write lease");
    path
}

fn write_release(root: &Path, agent: &str, install_id: &str, version: &str) {
    let dir = store::release_dir(root, agent, install_id);
    let entry = dir.join("node_modules/pkg/dist/index.js");
    std::fs::create_dir_all(entry.parent().unwrap()).expect("entry dirs");
    std::fs::write(&entry, "// entry\n").expect("entry file");
    store::write_receipt(
        root,
        agent,
        &store::Receipt {
            install_id: install_id.to_string(),
            package: "pkg".to_string(),
            version: version.to_string(),
            entry: "node_modules/pkg/dist/index.js".to_string(),
            bin: None,
        },
    )
    .expect("receipt");
}

fn write_installed(root: &Path, agent: &str, version: &str) -> String {
    let install_id = "rel-1";
    write_release(root, agent, install_id, version);
    store::write_pointer(root, agent, install_id, "pkg", version).expect("pointer");
    install_id.to_string()
}

/// Terminal progress events for one job (the review's contract).
fn terminals(progress: &[Value], job: &str) -> Vec<String> {
    progress
        .iter()
        .filter(|event| event["job"] == job)
        .filter_map(|event| event["phase"].as_str())
        .filter(|phase| {
            matches!(
                *phase,
                "committed" | "unchanged" | "removed" | "failed" | "cancelled"
            )
        })
        .map(str::to_string)
        .collect()
}

fn assert_terminal(progress: &[Value], job: &str, expected: &str) {
    let terminals = terminals(progress, job);
    assert_eq!(
        terminals,
        vec![expected.to_string()],
        "expected exactly one terminal {expected:?} event for {job}: {progress:?}"
    );
}

fn fake_log(root: &Path) -> Vec<Value> {
    let path = root.join("npm.log");
    let Ok(text) = std::fs::read_to_string(path) else {
        return Vec::new();
    };
    text.lines()
        .filter_map(|line| serde_json::from_str(line).ok())
        .collect()
}

#[test]
fn install_commits_only_after_verifying_and_reports_progress_in_order() {
    let root = Root::new("success");
    let server = TestServer::start("install-success");
    let mut client = connect(&server);
    let (response, progress) = one_request(
        &mut client,
        json!(10),
        "install.run",
        run_params(
            root.path(),
            "pi",
            "job-success",
            "install",
            "1.2.3",
            &[(
                "FAKE_NPM_LOG",
                root.path().join("npm.log").to_str().unwrap(),
            )],
        ),
    );
    assert!(response["error"].is_null(), "install failed: {response}");
    assert_eq!(response["result"]["status"], "committed");
    assert_terminal(&progress, "job-success", "committed");
    let install_id = response["result"]["installId"].as_str().expect("installId");
    let (state_id, version, entry) = installed_state(root.path(), "pi").expect("installed");
    assert_eq!(state_id, install_id);
    assert_eq!(version, "1.2.3");
    assert!(entry.ends_with("node_modules/pkg/dist/index.js"));

    let phases = progress_phases(&progress);
    let checking = phases
        .iter()
        .position(|phase| *phase == "checking")
        .unwrap();
    let installing = phases
        .iter()
        .position(|phase| *phase == "installing")
        .unwrap();
    let verifying = phases
        .iter()
        .position(|phase| *phase == "verifying")
        .unwrap();
    let committed = phases
        .iter()
        .position(|phase| *phase == "committed")
        .unwrap();
    assert!(checking < installing && installing < verifying && verifying < committed);
    assert!(
        progress.iter().any(|event| event["phase"] == "output"
            && event["line"].as_str().unwrap_or_default().starts_with("$ ")
            && event["line"]
                .as_str()
                .unwrap_or_default()
                .contains("install")),
        "the first output line must be the npm command: {progress:?}"
    );

    // Exactly the documented npm argv, in its own process group (the fake saw
    // the direct argv; a shell would have hidden it).
    let calls = fake_log(root.path());
    let install_call = calls
        .iter()
        .find(|call| call["args"][0] == "install")
        .expect("an npm install call");
    assert_eq!(
        install_call["args"],
        json!([
            "install",
            "--no-audit",
            "--no-fund",
            "--omit=dev",
            "--loglevel=notice",
            "--progress=false"
        ])
    );
}

#[test]
fn a_failed_install_removes_only_its_own_directory() {
    let root = Root::new("failure-cleanup");
    let previous = write_installed(root.path(), "pi", "0.9.0");
    let orphan = store::release_dir(root.path(), "pi", "rel-orphan");
    std::fs::create_dir_all(&orphan).expect("orphan");

    let server = TestServer::start("install-failure");
    let mut client = connect(&server);
    let (response, progress) = one_request(
        &mut client,
        json!(11),
        "install.run",
        run_params(
            root.path(),
            "pi",
            "job-fail",
            "install",
            "1.2.3",
            &[("FAKE_NPM_MODE", "fail")],
        ),
    );
    assert_eq!(response["error"]["code"], -32043, "{response}");
    assert!(
        response["error"]["data"]["log"]
            .as_str()
            .unwrap_or_default()
            .contains("npm ERR!"),
        "the kept log must come back: {response}"
    );
    let phases = progress_phases(&progress);
    assert_eq!(phases.last(), Some(&"failed"));
    assert_terminal(&progress, "job-fail", "failed");
    let (state_id, version, _) =
        installed_state(root.path(), "pi").expect("previous stays installed");
    assert_eq!(state_id, previous);
    assert_eq!(version, "0.9.0");
    assert!(
        orphan.exists(),
        "only the directory this run created is removed"
    );
    let releases = store::list_install_ids(root.path(), "pi");
    assert_eq!(releases, vec![previous, "rel-orphan".to_string()]);
}

#[test]
fn wrong_version_and_missing_entry_are_refused() {
    let root = Root::new("verify");
    let server = TestServer::start("install-verify");
    let mut client = connect(&server);

    let (response, _wrong_progress) = one_request(
        &mut client,
        json!(20),
        "install.run",
        run_params(
            root.path(),
            "pi",
            "job-wrong",
            "install",
            "1.2.3",
            &[("FAKE_NPM_MODE", "wrong-version")],
        ),
    );
    assert_eq!(response["error"]["code"], -32043, "{response}");
    assert!(
        response["error"]["message"]
            .as_str()
            .unwrap_or_default()
            .contains("9.9.9"),
        "{response}"
    );
    assert_terminal(&_wrong_progress, "job-wrong", "failed");
    assert!(store::list_install_ids(root.path(), "pi").is_empty());

    let (response, _missing_progress) = one_request(
        &mut client,
        json!(21),
        "install.run",
        run_params(
            root.path(),
            "pi",
            "job-missing",
            "install",
            "1.2.3",
            &[("FAKE_NPM_MODE", "missing-entry")],
        ),
    );
    assert_eq!(response["error"]["code"], -32043, "{response}");
    assert!(
        response["error"]["message"]
            .as_str()
            .unwrap_or_default()
            .contains("entrypoint is missing"),
        "{response}"
    );
    assert_terminal(&_missing_progress, "job-missing", "failed");
    assert!(installed_state(root.path(), "pi").is_none());
}

#[test]
fn update_to_the_same_version_is_unchanged_and_broken_reinstalls() {
    let root = Root::new("update");
    let server = TestServer::start("install-update");
    let mut client = connect(&server);
    let (first, _) = one_request(
        &mut client,
        json!(30),
        "install.run",
        run_params(root.path(), "pi", "job-a", "install", "1.2.3", &[]),
    );
    let first_id = first["result"]["installId"].as_str().unwrap().to_string();

    let (same, progress) = one_request(
        &mut client,
        json!(31),
        "install.run",
        run_params(root.path(), "pi", "job-b", "update", "1.2.3", &[]),
    );
    assert_eq!(same["result"]["status"], "unchanged", "{same}");
    assert_eq!(same["result"]["installId"], first_id);
    assert_terminal(&progress, "job-b", "unchanged");
    assert!(
        !progress_phases(&progress).contains(&"installing"),
        "unchanged must not add a release: {progress:?}"
    );

    // Break the receipt of the current release and update again: a broken agent
    // is reinstalled instead of being called unchanged.
    let receipt = store::receipt_path(root.path(), "pi", &first_id);
    std::fs::write(&receipt, "{broken").expect("break receipt");
    assert!(installed_state(root.path(), "pi").is_none());
    let (fixed, _) = one_request(
        &mut client,
        json!(32),
        "install.run",
        run_params(root.path(), "pi", "job-c", "update", "1.2.3", &[]),
    );
    assert_eq!(fixed["result"]["status"], "committed", "{fixed}");
    assert!(installed_state(root.path(), "pi").is_some());
}

#[test]
fn uninstall_removes_the_pointer_first_and_reports_the_release() {
    let root = Root::new("uninstall");
    let server = TestServer::start("install-uninstall");
    let mut client = connect(&server);
    let (installed, _) = one_request(
        &mut client,
        json!(40),
        "install.run",
        run_params(root.path(), "pi", "job-i", "install", "1.2.3", &[]),
    );
    let install_id = installed["result"]["installId"]
        .as_str()
        .unwrap()
        .to_string();
    let (removed, progress) = one_request(
        &mut client,
        json!(41),
        "install.uninstall",
        uninstall_params(root.path(), "pi", "job-u", Some(&install_id)),
    );
    assert_eq!(removed["result"]["installId"], install_id, "{removed}");
    assert_eq!(progress_phases(&progress), vec!["removed"]);
    assert_terminal(&progress, "job-u", "removed");
    assert!(!store::pointer_path(root.path(), "pi").exists());
    assert!(!store::release_dir(root.path(), "pi", &install_id).exists());
    assert!(installed_state(root.path(), "pi").is_none());
}

#[test]
fn uninstall_refuses_a_release_in_use_and_a_changed_install_id() {
    let root = Root::new("in-use");
    let server = TestServer::start("install-in-use");
    let mut client = connect(&server);
    let (installed, _) = one_request(
        &mut client,
        json!(50),
        "install.run",
        run_params(root.path(), "pi", "job-i", "install", "1.2.3", &[]),
    );
    let install_id = installed["result"]["installId"]
        .as_str()
        .unwrap()
        .to_string();

    let (changed, changed_progress) = one_request(
        &mut client,
        json!(51),
        "install.uninstall",
        uninstall_params(root.path(), "pi", "job-changed", Some("rel-other")),
    );
    assert_eq!(changed["error"]["code"], -32042, "{changed}");
    assert_eq!(changed["error"]["data"]["reason"], "changed");
    assert_terminal(&changed_progress, "job-changed", "failed");

    let lease = write_lease(
        root.path(),
        "pi",
        &install_id,
        &std::process::id().to_string(),
        nvim_ade_server::install::now_ms() + 600_000,
    );
    let (busy, busy_progress) = one_request(
        &mut client,
        json!(52),
        "install.uninstall",
        uninstall_params(root.path(), "pi", "job-busy", Some(&install_id)),
    );
    assert_terminal(&busy_progress, "job-busy", "failed");
    assert_eq!(busy["error"]["code"], -32044, "{busy}");
    assert!(
        busy["error"]["data"]["reason"]
            .as_str()
            .unwrap_or_default()
            .contains("in use by pid"),
        "{busy}"
    );
    assert!(store::release_dir(root.path(), "pi", &install_id).exists());
    std::fs::remove_file(&lease).expect("drop lease");

    let (not_installed, not_installed_progress) = one_request(
        &mut client,
        json!(53),
        "install.uninstall",
        uninstall_params(root.path(), "other", "job-none", None),
    );
    assert_terminal(&not_installed_progress, "job-none", "failed");
    assert_eq!(not_installed["error"]["code"], -32045, "{not_installed}");
}

#[test]
fn prune_keeps_a_leased_release() {
    let root = Root::new("prune");
    let server = TestServer::start("install-prune");
    let mut client = connect(&server);
    let (first, _) = one_request(
        &mut client,
        json!(60),
        "install.run",
        run_params(root.path(), "pi", "job-a", "install", "1.0.0", &[]),
    );
    let old = first["result"]["installId"].as_str().unwrap().to_string();
    write_lease(
        root.path(),
        "pi",
        &old,
        &std::process::id().to_string(),
        nvim_ade_server::install::now_ms() + 600_000,
    );
    let orphan = store::release_dir(root.path(), "pi", "rel-orphan");
    std::fs::create_dir_all(&orphan).expect("orphan");

    let (second, _) = one_request(
        &mut client,
        json!(61),
        "install.run",
        run_params(root.path(), "pi", "job-b", "install", "2.0.0", &[]),
    );
    let new = second["result"]["installId"].as_str().unwrap().to_string();
    assert_ne!(old, new);
    assert!(
        store::release_dir(root.path(), "pi", &old).exists(),
        "a leased release survives prune"
    );
    assert!(!orphan.exists(), "an unleased orphan is pruned");
    let mut releases = store::list_install_ids(root.path(), "pi");
    releases.sort();
    let mut expected = vec![old, new];
    expected.sort();
    assert_eq!(releases, expected);
}

#[test]
fn a_live_lock_from_another_process_blocks_the_install() {
    let root = Root::new("locked");
    let lock_dir = root.path().join(".locks/pi");
    std::fs::create_dir_all(&lock_dir).expect("lock dir");
    std::fs::write(
        lock_dir.join("owner.json"),
        serde_json::to_vec(&json!({
            "host": nvim_ade_server::install::hostname(),
            "pid": "1",
            "acquiredAt": "2026-11-16T10:20:30Z",
            "heartbeat": nvim_ade_server::install::now_ms() + 600_000,
            "action": "install",
        }))
        .unwrap(),
    )
    .expect("owner");
    let server = TestServer::start("install-locked");
    let mut client = connect(&server);
    let (response, _lock_progress) = one_request(
        &mut client,
        json!(70),
        "install.run",
        run_params(root.path(), "pi", "job-locked", "install", "1.2.3", &[]),
    );
    assert_eq!(response["error"]["code"], -32042, "{response}");
    assert_terminal(&_lock_progress, "job-locked", "failed");
    assert!(
        response["error"]["data"]["reason"]
            .as_str()
            .unwrap_or_default()
            .contains("another instance is using this agent"),
        "{response}"
    );
}

#[test]
fn the_same_agent_is_serialised_but_different_agents_run_in_parallel() {
    let root = Root::new("concurrent");
    let server = TestServer::start("install-concurrent");
    let mut client = connect(&server);
    let slow = [("FAKE_NPM_MODE", "slow"), ("FAKE_NPM_SLEEP", "1.5")];
    send_request(
        &mut client,
        json!(80),
        "install.run",
        run_params(root.path(), "pi", "job-pi", "install", "1.2.3", &slow),
    );
    // Wait until the first job is actually running (job registry populated).
    let mut progress: Vec<Value> = Vec::new();
    let mut replies = serde_json::Map::new();
    let deadline = Instant::now() + Duration::from_secs(10);
    while !progress.iter().any(|event| event["phase"] == "installing") {
        assert!(Instant::now() < deadline, "the first install did not start");
        let frame = client.recv().expect("frame");
        if frame.get("method") == Some(&json!("install.progress")) {
            progress.push(frame["params"].clone());
        } else if frame.get("method").is_none() {
            replies.insert("80".to_string(), frame);
        }
    }
    // Same agent: refused at once, with data.reason.
    let (busy, busy_progress) = one_request(
        &mut client,
        json!(81),
        "install.run",
        run_params(root.path(), "pi", "job-pi-2", "install", "1.2.4", &[]),
    );
    assert_eq!(busy["error"]["code"], -32042, "{busy}");
    assert!(busy["error"]["data"]["reason"].is_string());
    assert_terminal(&busy_progress, "job-pi-2", "failed");

    // Different agent: accepted while pi is still installing.
    send_request(
        &mut client,
        json!(82),
        "install.run",
        run_params(root.path(), "claude", "job-claude", "install", "1.2.3", &[]),
    );
    let mut pending = vec![json!(80), json!(82)];
    while !pending.is_empty() {
        let frame = client.recv().expect("frame");
        if frame.get("method") == Some(&json!("install.progress")) {
            progress.push(frame["params"].clone());
            continue;
        }
        let Some(id) = frame.get("id") else { continue };
        if let Some(index) = pending.iter().position(|wanted| wanted == id) {
            replies.insert(id.to_string(), frame);
            pending.remove(index);
        }
    }
    assert!(replies["80"]["error"].is_null(), "{}", replies["80"]);
    assert!(replies["82"]["error"].is_null(), "{}", replies["82"]);
    assert!(installed_state(root.path(), "pi").is_some());
    assert!(installed_state(root.path(), "claude").is_some());
}

#[test]
fn cancel_kills_the_process_group_and_removes_the_release() {
    let root = Root::new("cancel");
    let child_pid_path = root.path().join("child.pid");
    let child_ready_path = root.path().join("child.ready");
    let server = TestServer::start("install-cancel");
    let mut client = connect(&server);
    send_request(
        &mut client,
        json!(90),
        "install.run",
        run_params(
            root.path(),
            "pi",
            "job-cancel",
            "install",
            "1.2.3",
            &[
                ("FAKE_NPM_MODE", "daemon"),
                ("FAKE_NPM_SLEEP", "30"),
                ("FAKE_NPM_CHILD_PID", child_pid_path.to_str().unwrap()),
                ("FAKE_NPM_CHILD_READY", child_ready_path.to_str().unwrap()),
            ],
        ),
    );
    // Wait until the grandchild installed its SIGTERM handler, so the cancel
    // really races the ignore path instead of killing it during startup.
    wait_for("the fake npm child", || {
        child_pid_path.exists() && child_ready_path.exists()
    });
    let child_pid: i32 = std::fs::read_to_string(&child_pid_path)
        .expect("child pid")
        .trim()
        .parse()
        .expect("numeric pid");
    client.notify("$/cancel_request", json!({ "id": 90 }));
    send_request(&mut client, json!(91), "ping", json!({}));
    let mut progress = Vec::new();
    let replies = pump(&mut client, &[json!(90), json!(91)], &mut progress);
    assert!(
        replies["91"]["result"].is_object(),
        "ping after cancel: {}",
        replies["91"]
    );
    let cancelled = &replies["90"];
    assert_eq!(cancelled["error"]["code"], -32800, "{cancelled}");
    let phases = progress_phases(&progress);
    assert_eq!(phases.last(), Some(&"cancelled"), "{progress:?}");
    assert_terminal(&progress, "job-cancel", "cancelled");
    assert!(
        store::list_install_ids(root.path(), "pi").is_empty(),
        "the half-built release must be removed"
    );
    assert!(
        !root.path().join(".locks/pi").exists(),
        "the lock must be released"
    );
    wait_for("the npm process group to die", || unsafe {
        libc::kill(child_pid, 0) != 0
    });
}

#[test]
fn a_timeout_fails_with_the_kept_log() {
    let root = Root::new("timeout");
    let child_pid_path = root.path().join("child.pid");
    let child_ready_path = root.path().join("child.ready");
    let server = TestServer::start("install-timeout");
    let mut client = connect(&server);
    let mut params = run_params(
        root.path(),
        "pi",
        "job-timeout",
        "install",
        "1.2.3",
        &[
            ("FAKE_NPM_MODE", "daemon"),
            ("FAKE_NPM_SLEEP", "30"),
            ("FAKE_NPM_CHILD_PID", child_pid_path.to_str().unwrap()),
            ("FAKE_NPM_CHILD_READY", child_ready_path.to_str().unwrap()),
        ],
    );
    params["timeout_ms"] = json!(1500);
    send_request(&mut client, json!(100), "install.run", params);
    wait_for("the fake npm child", || {
        child_pid_path.exists() && child_ready_path.exists()
    });
    let child_pid: i32 = std::fs::read_to_string(&child_pid_path)
        .expect("pid")
        .trim()
        .parse()
        .unwrap();
    let mut progress = Vec::new();
    let replies = pump(&mut client, &[json!(100)], &mut progress);
    let response = &replies["100"];
    assert_eq!(response["error"]["code"], -32043, "{response}");
    assert!(
        response["error"]["message"]
            .as_str()
            .unwrap_or_default()
            .contains("timed out"),
        "{response}"
    );
    assert_eq!(progress_phases(&progress).last(), Some(&"failed"));
    assert_terminal(&progress, "job-timeout", "failed");
    assert!(store::list_install_ids(root.path(), "pi").is_empty());
    assert!(!root.path().join(".locks/pi").exists());
    wait_for("the timed-out group to die", || unsafe {
        libc::kill(child_pid, 0) != 0
    });
}

#[test]
fn a_large_log_keeps_only_its_end() {
    let root = Root::new("log");
    let server = TestServer::start("install-log");
    let mut client = connect(&server);
    let (response, _) = one_request(
        &mut client,
        json!(110),
        "install.run",
        run_params(
            root.path(),
            "pi",
            "job-log",
            "install",
            "1.2.3",
            &[("FAKE_NPM_MODE", "noisy-fail")],
        ),
    );
    let log = response["error"]["data"]["log"]
        .as_str()
        .expect("data.log")
        .to_string();
    assert!(log.len() <= 4096, "the kept log is capped: {}", log.len());
    assert!(
        log.contains("npm ERR! simulated failure"),
        "the end is kept: {log:?}"
    );
    assert!(!log.contains("noisy line 0 "), "the start was dropped");
}

#[test]
fn ping_and_agent_list_answer_while_an_install_runs() {
    let root = Root::new("responsive");
    let server = TestServer::start("install-responsive");
    let mut client = connect(&server);
    send_request(
        &mut client,
        json!(120),
        "install.run",
        run_params(
            root.path(),
            "pi",
            "job-responsive",
            "install",
            "1.2.3",
            &[("FAKE_NPM_MODE", "slow"), ("FAKE_NPM_SLEEP", "1.0")],
        ),
    );
    // The install has not answered yet: another request on the same connection
    // must still be answered.
    let (ping, _) = one_request(&mut client, json!(121), "ping", json!({}));
    assert_eq!(ping["result"], json!({}), "{ping}");
    let (list, _) = one_request(&mut client, json!(122), "agent.list", json!({}));
    assert!(list["result"]["instances"].is_array(), "{list}");
    // And the install still completes.
    let deadline = Instant::now() + Duration::from_secs(15);
    let mut installed = false;
    while Instant::now() < deadline && !installed {
        let frame = client.recv().expect("frame");
        if frame.get("id") == Some(&json!(120)) {
            assert!(frame["error"].is_null(), "{frame}");
            installed = true;
        }
    }
    assert!(installed);
}

#[test]
fn an_install_keeps_running_after_its_connection_closes() {
    let root = Root::new("disconnect");
    let server = TestServer::start("install-disconnect");
    let mut client = connect(&server);
    send_request(
        &mut client,
        json!(130),
        "install.run",
        run_params(
            root.path(),
            "pi",
            "job-disconnect",
            "install",
            "1.2.3",
            &[("FAKE_NPM_MODE", "slow"), ("FAKE_NPM_SLEEP", "1.0")],
        ),
    );
    // Wait until the npm install really started, then drop the connection.
    let deadline = Instant::now() + Duration::from_secs(10);
    let mut started = false;
    while Instant::now() < deadline && !started {
        let frame = client.recv().expect("frame");
        if frame.get("method") == Some(&json!("install.progress")) {
            started = frame["params"]["phase"] == "installing";
        }
    }
    assert!(started, "the install did not start");
    // A second connection hears the progress of a job it did not start.
    let mut watcher = connect(&server);
    drop(client);
    wait_for("the install to commit without its connection", || {
        installed_state(root.path(), "pi").is_some()
    });
    let mut saw_committed = false;
    let deadline = Instant::now() + Duration::from_secs(10);
    while Instant::now() < deadline && !saw_committed {
        if let Some(frame) = watcher.try_next_notification(Duration::from_millis(200)) {
            if frame["method"] == "install.progress" && frame["params"]["phase"] == "committed" {
                saw_committed = true;
            }
        }
    }
    assert!(
        saw_committed,
        "progress is broadcast to every connection, not only the requester"
    );
}

#[test]
fn shutdown_cancels_a_running_install() {
    let root = Root::new("shutdown");
    let child_pid_path = root.path().join("child.pid");
    let mut server = TestServer::start("install-shutdown");
    let mut client = connect(&server);
    send_request(
        &mut client,
        json!(140),
        "install.run",
        run_params(
            root.path(),
            "pi",
            "job-shutdown",
            "install",
            "1.2.3",
            &[
                ("FAKE_NPM_MODE", "slow"),
                ("FAKE_NPM_SLEEP", "30"),
                ("FAKE_NPM_CHILD_PID", child_pid_path.to_str().unwrap()),
            ],
        ),
    );
    wait_for("the fake npm child", || child_pid_path.exists());
    let child_pid: i32 = std::fs::read_to_string(&child_pid_path)
        .expect("pid")
        .trim()
        .parse()
        .unwrap();
    let shutdown = client.request(141, "shutdown", json!({}));
    assert_eq!(shutdown["result"], json!({}), "{shutdown}");
    assert_eq!(
        server.wait_for_exit(Duration::from_secs(20)),
        Some(0),
        "shutdown must exit cleanly"
    );
    assert!(store::list_install_ids(root.path(), "pi").is_empty());
    assert!(!root.path().join(".locks/pi").exists());
    wait_for("the npm process group to die", || unsafe {
        libc::kill(child_pid, 0) != 0
    });
}

#[test]
fn resolve_returns_the_version_and_reports_unusable_output() {
    let root = Root::new("resolve");
    let server = TestServer::start("install-resolve");
    let mut client = connect(&server);
    let (response, progress) = one_request(
        &mut client,
        json!(150),
        "install.resolve",
        resolve_params(root.path(), "latest", &[("FAKE_NPM_VIEW_VERSION", "2.3.4")]),
    );
    assert_eq!(response["result"]["version"], "2.3.4", "{response}");
    assert!(progress.is_empty(), "resolve has no progress");

    let (bad, _) = one_request(
        &mut client,
        json!(151),
        "install.resolve",
        resolve_params(root.path(), "latest", &[("FAKE_NPM_MODE", "view-fail")]),
    );
    assert_eq!(bad["error"]["code"], -32041, "{bad}");

    // Invalid parameters never start npm.
    let (invalid, _) = one_request(
        &mut client,
        json!(152),
        "install.resolve",
        resolve_params(root.path(), ">=1", &[]),
    );
    assert_eq!(invalid["error"]["code"], -32040, "{invalid}");
}

#[test]
fn attach_writes_a_lease_and_removes_it_when_the_instance_exits() {
    let root = Root::new("launch");
    let server = TestServer::start("install-launch");
    let mut client = connect(&server);
    let (installed, _) = one_request(
        &mut client,
        json!(160),
        "install.run",
        run_params(root.path(), "pi", "job-i", "install", "1.2.3", &[]),
    );
    let install_id = installed["result"]["installId"]
        .as_str()
        .unwrap()
        .to_string();

    let key = json!({
        "agent": "pi",
        "command": "python3",
        "args": ["-c", "import time; time.sleep(30)"],
        "cwd": "/tmp",
    });
    let attach = client.request(
        161,
        "agent.attach",
        json!({
            "key": key,
            "client_capabilities": {},
            "env": env_json(&[]),
            "launch": { "root": root.path(), "agent": "pi", "installId": install_id },
        }),
    );
    assert!(attach["error"].is_null(), "{attach}");
    let instance = attach["result"]["instance"].as_str().unwrap().to_string();
    let lease_dir = root.path().join(".leases/pi");
    wait_for("the attach lease", || {
        std::fs::read_dir(&lease_dir)
            .map(|entries| {
                entries
                    .flatten()
                    .any(|entry| entry.file_name().to_string_lossy().starts_with("lease-"))
            })
            .unwrap_or(false)
    });
    let stop = client.request(162, "agent.stop", json!({ "instance": instance }));
    assert!(stop["error"].is_null(), "{stop}");
    wait_for("the lease to disappear", || {
        std::fs::read_dir(&lease_dir)
            .map(|entries| {
                !entries
                    .flatten()
                    .any(|entry| entry.file_name().to_string_lossy().starts_with("lease-"))
            })
            .unwrap_or(true)
    });

    // The release must still look installed at attach time; a stale installId
    // fails with -32022 and leaves no lease behind.
    let missing = client.request(
        163,
        "agent.attach",
        json!({
            "key": {
                "agent": "pi",
                "command": "python3",
                "args": ["-c", "import time; time.sleep(30)"],
                "cwd": "/tmp/another",
            },
            "client_capabilities": {},
            "env": env_json(&[]),
            "launch": { "root": root.path(), "agent": "pi", "installId": "rel-missing" },
        }),
    );
    assert_eq!(missing["error"]["code"], -32022, "{missing}");
    let invalid = client.request(
        164,
        "agent.attach",
        json!({
            "key": {
                "agent": "pi",
                "command": "python3",
                "args": ["-c", "import time; time.sleep(30)"],
                "cwd": "/tmp/invalid",
            },
            "client_capabilities": {},
            "env": env_json(&[]),
            "launch": { "root": root.path(), "agent": "pi", "installId": "../escape" },
        }),
    );
    assert_eq!(invalid["error"]["code"], -32040, "{invalid}");
    wait_for("no lease for the failed attach", || {
        std::fs::read_dir(&lease_dir)
            .map(|entries| {
                !entries
                    .flatten()
                    .any(|entry| entry.file_name().to_string_lossy().starts_with("lease-"))
            })
            .unwrap_or(true)
    });
}

#[test]
fn a_launch_lease_that_cannot_be_written_fails_the_attach() {
    let root = Root::new("launch-fail");
    let server = TestServer::start("install-launch-fail");
    let mut client = connect(&server);
    let (installed, _) = one_request(
        &mut client,
        json!(170),
        "install.run",
        run_params(root.path(), "pi", "job-i", "install", "1.2.3", &[]),
    );
    let install_id = installed["result"]["installId"]
        .as_str()
        .unwrap()
        .to_string();
    // A file where the lease directory must be makes the write fail.
    std::fs::write(root.path().join(".leases"), "not a directory").expect("blocker");
    let attach = client.request(
        171,
        "agent.attach",
        json!({
            "key": {
                "agent": "pi",
                "command": "python3",
                "args": ["-c", "import time; time.sleep(30)"],
                "cwd": "/tmp",
            },
            "client_capabilities": {},
            "env": env_json(&[]),
            "launch": { "root": root.path(), "agent": "pi", "installId": install_id },
        }),
    );
    assert_eq!(attach["error"]["code"], -32022, "{attach}");
}

#[test]
fn idle_exit_waits_for_a_running_install() {
    let root = Root::new("idle");
    let mut server = TestServer::start_with("install-idle", &["--idle-timeout", "0.4"], &[]);
    let mut client = connect(&server);
    send_request(
        &mut client,
        json!(190),
        "install.run",
        run_params(
            root.path(),
            "pi",
            "job-idle",
            "install",
            "1.2.3",
            &[("FAKE_NPM_MODE", "slow"), ("FAKE_NPM_SLEEP", "1.5")],
        ),
    );
    let deadline = Instant::now() + Duration::from_secs(10);
    let mut started = false;
    while Instant::now() < deadline && !started {
        let frame = client.recv().expect("frame");
        if frame.get("method") == Some(&json!("install.progress")) {
            started = frame["params"]["phase"] == "installing";
        }
    }
    assert!(started, "the install did not start");
    drop(client);
    // No connection is open, but the job keeps the service alive.
    assert_eq!(
        server.wait_for_exit(Duration::from_millis(1200)),
        None,
        "idle exit must wait for the install"
    );
    wait_for("the install to commit", || {
        installed_state(root.path(), "pi").is_some()
    });
    // Once the job ends the idle clock starts and the short timeout fires.
    let exited = {
        let deadline = Instant::now() + Duration::from_secs(15);
        loop {
            if let Some(code) = server.wait_for_exit(Duration::from_millis(200)) {
                break Some(code);
            }
            assert!(
                Instant::now() < deadline,
                "the service did not exit after the job"
            );
        }
    };
    assert_eq!(exited, Some(0));
}

#[test]
fn invalid_install_parameters_are_refused_before_anything_runs() {
    let root = Root::new("params");
    let server = TestServer::start("install-params");
    let mut client = connect(&server);
    let mut params = run_params(root.path(), "pi", "job-x", "install", "1.2.3", &[]);
    params["version"] = json!("^1.0.0");
    let (response, progress) = one_request(&mut client, json!(180), "install.run", params);
    assert_eq!(response["error"]["code"], -32040, "{response}");
    assert!(progress.is_empty());
    assert!(!root.path().join(".locks").exists());
    assert!(fake_log(root.path()).is_empty());

    // An update of a missing install is an early refusal with a terminal event.
    let (missing, progress) = one_request(
        &mut client,
        json!(181),
        "install.run",
        run_params(root.path(), "pi", "job-update-none", "update", "1.2.3", &[]),
    );
    assert_eq!(missing["error"]["code"], -32045, "{missing}");
    assert_terminal(&progress, "job-update-none", "failed");
}

fn wait_for_lock(root: &Path, agent: &str) {
    wait_for("the agent lock", || {
        root.join(".locks").join(agent).join("owner.json").exists()
    });
}

#[test]
fn update_reads_the_store_under_the_lock() {
    let root = Root::new("update-lock");
    let server = TestServer::start_with(
        "install-update-lock",
        &["--idle-timeout", "600"],
        &[("NVIM_ADE_INSTALL_LOCK_DELAY_MS", "400")],
    );
    let mut client = connect(&server);

    // Not installed before the request; another writer commits while the job
    // holds the lock. Reading state outside the lock would answer -32045.
    send_request(
        &mut client,
        json!(200),
        "install.run",
        run_params(root.path(), "pi", "job-a", "update", "1.2.3", &[]),
    );
    wait_for_lock(root.path(), "pi");
    write_installed(root.path(), "pi", "1.2.3");
    let mut progress = Vec::new();
    let replies = pump(&mut client, &[json!(200)], &mut progress);
    assert!(replies["200"]["error"].is_null(), "{}", replies["200"]);
    assert_eq!(
        replies["200"]["result"]["status"], "unchanged",
        "{}",
        replies["200"]
    );
    assert_terminal(&progress, "job-a", "unchanged");

    // Installed v1 before the request; another writer moves the pointer to v2
    // under the lock. The job must see v2 and install v1 instead of returning
    // "unchanged" from its stale pre-lock read.
    send_request(
        &mut client,
        json!(201),
        "install.run",
        run_params(root.path(), "pi", "job-b", "update", "1.2.3", &[]),
    );
    wait_for_lock(root.path(), "pi");
    write_release(root.path(), "pi", "rel-2", "2.0.0");
    store::write_pointer(root.path(), "pi", "rel-2", "pkg", "2.0.0").expect("pointer");
    let mut progress = Vec::new();
    let replies = pump(&mut client, &[json!(201)], &mut progress);
    assert!(replies["201"]["error"].is_null(), "{}", replies["201"]);
    assert_eq!(
        replies["201"]["result"]["status"], "committed",
        "{}",
        replies["201"]
    );
    assert_terminal(&progress, "job-b", "committed");
    assert_eq!(
        installed_state(root.path(), "pi").map(|state| state.1),
        Some("1.2.3".to_string())
    );
}

#[test]
fn uninstall_uses_the_release_it_reads_under_the_lock() {
    let root = Root::new("uninstall-lock");
    let original = write_installed(root.path(), "pi", "1.2.3");
    let server = TestServer::start_with(
        "install-uninstall-lock",
        &["--idle-timeout", "600"],
        &[("NVIM_ADE_INSTALL_LOCK_DELAY_MS", "400")],
    );
    let mut client = connect(&server);
    send_request(
        &mut client,
        json!(210),
        "install.uninstall",
        uninstall_params(root.path(), "pi", "job-u", Some(&original)),
    );
    wait_for_lock(root.path(), "pi");
    write_release(root.path(), "pi", "rel-2", "2.0.0");
    store::write_pointer(root.path(), "pi", "rel-2", "pkg", "2.0.0").expect("pointer");
    let mut progress = Vec::new();
    let replies = pump(&mut client, &[json!(210)], &mut progress);
    assert_eq!(
        replies["210"]["error"]["code"], -32042,
        "{}",
        replies["210"]
    );
    assert_eq!(replies["210"]["error"]["data"]["reason"], "changed");
    assert_terminal(&progress, "job-u", "failed");
    // The new pointer and its release survive untouched.
    assert!(store::release_dir(root.path(), "pi", "rel-2").exists());
    assert!(store::release_dir(root.path(), "pi", &original).exists());
}

#[test]
fn a_panicking_job_reports_failure_and_releases_its_job_and_lock() {
    let root = Root::new("panic");
    let server = TestServer::start_with(
        "install-panic",
        &["--idle-timeout", "600"],
        &[("NVIM_ADE_INSTALL_PANIC", "1")],
    );
    let mut client = connect(&server);
    let (response, progress) = one_request(
        &mut client,
        json!(220),
        "install.run",
        run_params(root.path(), "pi", "job-panic", "install", "1.2.3", &[]),
    );
    assert_eq!(response["error"]["code"], -32043, "{response}");
    assert_terminal(&progress, "job-panic", "failed");
    assert!(
        !root.path().join(".locks/pi").exists(),
        "the lock must be gone after a panic"
    );
    // A new job for the same agent is not refused by a stale in-process guard.
    let (second, _) = one_request(
        &mut client,
        json!(221),
        "install.run",
        run_params(root.path(), "pi", "job-panic-2", "install", "1.2.3", &[]),
    );
    assert_eq!(second["error"]["code"], -32043, "{second}");
}

#[test]
fn heartbeat_does_not_recreate_a_deleted_lease_or_lock() {
    let root = Root::new("heartbeat");
    let server = TestServer::start_with(
        "install-heartbeat",
        &["--idle-timeout", "600"],
        &[("NVIM_ADE_SERVER_HEARTBEAT_MS", "100")],
    );
    let mut client = connect(&server);
    let (installed, _) = one_request(
        &mut client,
        json!(230),
        "install.run",
        run_params(root.path(), "pi", "job-i", "install", "1.2.3", &[]),
    );
    let install_id = installed["result"]["installId"]
        .as_str()
        .unwrap()
        .to_string();
    let attach = client.request(
        231,
        "agent.attach",
        json!({
            "key": {
                "agent": "pi",
                "command": "python3",
                "args": ["-c", "import time; time.sleep(30)"],
                "cwd": "/tmp",
            },
            "client_capabilities": {},
            "env": env_json(&[]),
            "launch": { "root": root.path(), "agent": "pi", "installId": install_id },
        }),
    );
    assert!(attach["error"].is_null(), "{attach}");
    let instance = attach["result"]["instance"].as_str().unwrap().to_string();
    let lease_dir = root.path().join(".leases/pi");
    wait_for("the attach lease", || {
        std::fs::read_dir(&lease_dir)
            .map(|entries| {
                entries
                    .flatten()
                    .any(|entry| entry.file_name().to_string_lossy().starts_with("lease-"))
            })
            .unwrap_or(false)
    });
    let lease = std::fs::read_dir(&lease_dir)
        .expect("lease dir")
        .flatten()
        .map(|entry| entry.path())
        .next()
        .expect("lease file");
    std::fs::remove_file(&lease).expect("delete lease");
    std::thread::sleep(Duration::from_millis(400));
    assert!(!lease.exists(), "a deleted lease must not be recreated");

    // Same for the lock: deleting owner.json while the slow job holds it stops
    // the heartbeat and the job fails before commit (lock lost).
    send_request(
        &mut client,
        json!(232),
        "install.run",
        run_params(
            root.path(),
            "claude",
            "job-slow",
            "install",
            "1.2.3",
            &[("FAKE_NPM_MODE", "slow"), ("FAKE_NPM_SLEEP", "1.5")],
        ),
    );
    wait_for_lock(root.path(), "claude");
    std::fs::remove_file(root.path().join(".locks/claude/owner.json")).expect("delete owner");
    std::thread::sleep(Duration::from_millis(400));
    assert!(
        !root.path().join(".locks/claude/owner.json").exists(),
        "a deleted owner record must not be recreated"
    );
    let mut progress = Vec::new();
    let replies = pump(&mut client, &[json!(232)], &mut progress);
    assert_eq!(
        replies["232"]["error"]["code"], -32043,
        "{}",
        replies["232"]
    );
    assert_terminal(&progress, "job-slow", "failed");
    assert!(installed_state(root.path(), "claude").is_none());

    let stop = client.request(233, "agent.stop", json!({ "instance": instance }));
    assert!(stop["error"].is_null(), "{stop}");
}

#[test]
fn a_pointer_that_cannot_be_removed_leaves_the_release_alone() {
    if unsafe { libc::geteuid() } == 0 {
        eprintln!("SKIP: permissions are not enforced for root");
        return;
    }
    use std::os::unix::fs::PermissionsExt;
    let root = Root::new("pointer-remove");
    let install_id = write_installed(root.path(), "pi", "1.2.3");
    let agent_dir = store::agent_dir(root.path(), "pi");
    let mode = std::fs::metadata(&agent_dir)
        .expect("metadata")
        .permissions();
    std::fs::set_permissions(&agent_dir, std::fs::Permissions::from_mode(0o555))
        .expect("read-only agent dir");
    let server = TestServer::start("install-pointer-remove");
    let mut client = connect(&server);
    let (response, progress) = one_request(
        &mut client,
        json!(245),
        "install.uninstall",
        uninstall_params(root.path(), "pi", "job-rm", Some(&install_id)),
    );
    std::fs::set_permissions(&agent_dir, mode).expect("restore permissions");
    assert_eq!(response["error"]["code"], -32043, "{response}");
    assert_terminal(&progress, "job-rm", "failed");
    assert!(
        store::release_dir(root.path(), "pi", &install_id).exists(),
        "the release must not be deleted when the pointer could not be removed"
    );
}

#[test]
fn a_launch_for_a_missing_root_does_not_create_it() {
    let root = Root::new("launch-root");
    let missing = root.path().join("does-not-exist");
    let server = TestServer::start("install-launch-root");
    let mut client = connect(&server);
    let attach = client.request(
        246,
        "agent.attach",
        json!({
            "key": {
                "agent": "pi",
                "command": "python3",
                "args": ["-c", "import time; time.sleep(30)"],
                "cwd": "/tmp",
            },
            "client_capabilities": {},
            "env": env_json(&[]),
            "launch": { "root": missing, "agent": "pi", "installId": "rel-1" },
        }),
    );
    assert_eq!(attach["error"]["code"], -32022, "{attach}");
    assert!(
        !missing.exists(),
        "a launch must not create the managed root"
    );
}

#[test]
fn a_rewritten_lock_owner_fails_the_install_before_commit() {
    let root = Root::new("lock-lost");
    let server = TestServer::start("install-lock-lost");
    let mut client = connect(&server);
    send_request(
        &mut client,
        json!(240),
        "install.run",
        run_params(
            root.path(),
            "pi",
            "job-lost",
            "install",
            "1.2.3",
            &[("FAKE_NPM_MODE", "slow"), ("FAKE_NPM_SLEEP", "1.0")],
        ),
    );
    wait_for_lock(root.path(), "pi");
    let owner_path = root.path().join(".locks/pi/owner.json");
    let mut owner: Value =
        serde_json::from_slice(&std::fs::read(&owner_path).expect("owner")).expect("owner json");
    owner["acquiredAt"] = json!("2026-11-16T00:00:00Z");
    std::fs::write(&owner_path, serde_json::to_vec(&owner).unwrap()).expect("rewrite owner");
    let mut progress = Vec::new();
    let replies = pump(&mut client, &[json!(240)], &mut progress);
    assert_eq!(
        replies["240"]["error"]["code"], -32043,
        "{}",
        replies["240"]
    );
    assert_terminal(&progress, "job-lost", "failed");
    assert!(
        installed_state(root.path(), "pi").is_none(),
        "no commit on a lost lock"
    );
    assert!(store::list_install_ids(root.path(), "pi").is_empty());
}

#[test]
fn a_stale_lock_is_reclaimed_and_an_unreadable_one_needs_manual_removal() {
    let root = Root::new("stale-lock");
    let lock_dir = root.path().join(".locks/pi");
    std::fs::create_dir_all(&lock_dir).expect("lock dir");
    std::fs::write(
        lock_dir.join("owner.json"),
        serde_json::to_vec(&json!({
            "host": nvim_ade_server::install::hostname(),
            "pid": "2000000000",
            "acquiredAt": "2026-11-16T10:20:30Z",
            "heartbeat": 1,
            "action": "install",
        }))
        .unwrap(),
    )
    .expect("stale owner");
    let server = TestServer::start("install-stale-lock");
    let mut client = connect(&server);
    let (response, _) = one_request(
        &mut client,
        json!(250),
        "install.run",
        run_params(root.path(), "pi", "job-stale", "install", "1.2.3", &[]),
    );
    assert!(response["error"].is_null(), "{response}");
    assert!(installed_state(root.path(), "pi").is_some());

    // A lock directory without owner.json is unreadable and must say how to
    // remove it by hand (16.2).
    std::fs::create_dir_all(root.path().join(".locks/claude")).expect("empty lock dir");
    let (blocked, blocked_progress) = one_request(
        &mut client,
        json!(251),
        "install.run",
        run_params(root.path(), "claude", "job-manual", "install", "1.2.3", &[]),
    );
    assert_eq!(blocked["error"]["code"], -32042, "{blocked}");
    assert!(
        blocked["error"]["message"]
            .as_str()
            .unwrap_or_default()
            .contains("manually"),
        "{blocked}"
    );
    assert_terminal(&blocked_progress, "job-manual", "failed");
}

#[test]
fn a_bare_npm_name_is_found_through_env_path() {
    let root = Root::new("path");
    let server = TestServer::start("install-path");
    let mut client = connect(&server);
    let fake_dir = fixture("fake-npm").parent().unwrap().to_path_buf();
    let path = format!(
        "{}:{}",
        fake_dir.display(),
        std::env::var("PATH").unwrap_or_default()
    );
    let mut params = resolve_params(root.path(), "latest", &[("PATH", &path)]);
    params["npm"] = json!("fake-npm");
    let (response, _) = one_request(&mut client, json!(260), "install.resolve", params);
    assert_eq!(response["result"]["version"], "1.2.3", "{response}");
}

#[test]
fn invalid_environment_names_are_refused() {
    let root = Root::new("env");
    let server = TestServer::start("install-env");
    let mut client = connect(&server);
    let mut params = run_params(root.path(), "pi", "job-env", "install", "1.2.3", &[]);
    params["env"] = json!({ "A=B": "x" });
    let (response, progress) = one_request(&mut client, json!(270), "install.run", params);
    assert_eq!(response["error"]["code"], -32040, "{response}");
    assert!(progress.is_empty());

    let mut params = run_params(root.path(), "pi", "job-env-2", "install", "1.2.3", &[]);
    params["env"] = json!({ "GOOD": "a\u{0}b" });
    let (response, _) = one_request(&mut client, json!(271), "install.run", params);
    assert_eq!(response["error"]["code"], -32040, "{response}");
}

fn copy_tree(from: &Path, to: &Path) {
    std::fs::create_dir_all(to).expect("copy dir");
    for entry in std::fs::read_dir(from).expect("read fixture").flatten() {
        let target = to.join(entry.file_name());
        if entry.file_type().expect("type").is_dir() {
            copy_tree(&entry.path(), &target);
        } else {
            std::fs::copy(entry.path(), &target).expect("copy file");
        }
    }
}

fn rewrite_host(path: &Path) {
    let text = std::fs::read_to_string(path).expect("read record");
    let value: Value = serde_json::from_str(&text).expect("record json");
    let old_host = value["host"].as_str().expect("host").to_string();
    let text = text.replace(
        &format!("\"host\":\"{old_host}\""),
        &format!("\"host\":\"{}\"", nvim_ade_server::install::hostname()),
    );
    std::fs::write(path, text).expect("write record");
}

/// Rewrite only `host` and `heartbeat`, keeping every other byte Lua wrote, so
/// the live-record fixture exercises the "fresh heartbeat" branch instead of
/// only "heartbeat in the future".
fn rewrite_live_record(path: &Path) {
    let text = std::fs::read_to_string(path).expect("read record");
    let value: Value = serde_json::from_str(&text).expect("record json");
    let old_host = value["host"].as_str().expect("host").to_string();
    let old_heartbeat = value["heartbeat"].to_string();
    let text = text
        .replace(
            &format!("\"host\":\"{old_host}\""),
            &format!("\"host\":\"{}\"", nvim_ade_server::install::hostname()),
        )
        .replace(
            &format!("\"heartbeat\":{old_heartbeat}"),
            &format!(
                "\"heartbeat\":{}",
                nvim_ade_server::install::now_ms() - 5_000
            ),
        );
    std::fs::write(path, text).expect("write record");
}

#[test]
fn reads_the_lua_golden_store_and_lock_records() {
    let root = Root::new("lua-golden");
    copy_tree(&fixture("lua"), root.path());
    rewrite_live_record(&root.path().join(".locks/pi/owner.json"));
    rewrite_live_record(&root.path().join(".leases/pi/lease-live.json"));
    rewrite_host(&root.path().join(".leases/pi/lease-stale.json"));
    let expected: Value =
        serde_json::from_slice(&std::fs::read(fixture("lua/expected.json")).unwrap()).unwrap();

    let state = store::state(root.path(), expected["agent"].as_str().unwrap());
    match state.status {
        store::Status::Installed {
            install_id,
            version,
            entry,
            package,
            ..
        } => {
            assert_eq!(install_id, expected["installId"]);
            assert_eq!(version, expected["version"]);
            assert_eq!(package, expected["package"]);
            assert!(entry.ends_with(expected["entry"].as_str().unwrap()));
        }
        other => panic!("Lua's store must read as installed, got {other:?}"),
    }

    let owner_path = root.path().join(".locks/pi/owner.json");
    let owner: Value =
        serde_json::from_slice(&std::fs::read(&owner_path).unwrap()).expect("owner json");
    let now = nvim_ade_server::install::now_ms();
    let boot = nvim_ade_server::install::boot_time_ms(now);
    assert!(lock::alive(Some(&owner), &owner_path, now, boot).0);

    // The live lease names the current release; the stale one is discarded.
    let install_id = expected["installId"].as_str().unwrap();
    assert!(lock::in_use(root.path(), "pi", install_id).is_some());
    std::fs::remove_file(root.path().join(".leases/pi/lease-live.json")).expect("drop live");
    assert!(lock::in_use(root.path(), "pi", install_id).is_none());
    assert!(
        !root.path().join(".leases/pi/lease-stale.json").exists(),
        "scanning removes abandoned leases"
    );
}

fn have_nvim() -> bool {
    std::process::Command::new("nvim")
        .arg("--version")
        .stdout(std::process::Stdio::null())
        .stderr(std::process::Stdio::null())
        .status()
        .map(|status| status.success())
        .unwrap_or(false)
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn lua_reads_a_store_lock_and_lease_written_by_rust() {
    if !have_nvim() {
        eprintln!("SKIP: nvim is not installed (set ADE_REQUIRE_NVIM=1 to make this fail)");
        assert_ne!(
            std::env::var("ADE_REQUIRE_NVIM").ok().as_deref(),
            Some("1"),
            "nvim is required for the Rust -> Lua interop test"
        );
        return;
    }
    let root = Root::new("rust-golden");
    let install_id = write_installed(root.path(), "pi", "0.4.0");
    let _lease = lock::lease(root.path(), "pi", &install_id, "i1").expect("lease");
    let _lock = lock::acquire(root.path(), "pi", "install").expect("lock");

    let repo = Path::new(env!("CARGO_MANIFEST_DIR"))
        .parent()
        .expect("repository root")
        .to_path_buf();
    let script = root.path().join("read.lua");
    std::fs::write(
        &script,
        r#"
local root = vim.env.ADE_INSTALL_ROOT
vim.opt.runtimepath:append(vim.env.ADE_REPO)
local Store = require("ade.manager.store")
local Lock = require("ade.manager.lock")
local store = Store.new({ root = function() return root end })
local lock = Lock.new({ root = function() return root end })
local state = store:state("pi")
local busy, reason = lock:install_in_use("pi", state.install_id)
local tree, tree_reason = Lock.in_use(root)
local owner_path = root .. "/.locks/pi/owner.json"
local handle = assert(io.open(owner_path, "rb"))
local owner = vim.json.decode(handle:read("*a"))
handle:close()
local lock_live, lock_reason = Lock.alive(owner, owner_path)
print(vim.json.encode({
  status = state.status,
  install_id = state.install_id,
  version = state.install and state.install.version,
  entry = state.entry,
  in_use = busy and true or false,
  reason = reason,
  lock_live = lock_live and true or false,
  lock_reason = lock_reason,
  tree_in_use = tree and true or false,
  tree_reason = tree_reason,
}))
"#,
    )
    .expect("write script");
    let output = tokio::task::spawn_blocking({
        let script = script.clone();
        let root = root.path().to_path_buf();
        let repo = repo.clone();
        move || {
            std::process::Command::new("nvim")
                .args(["--headless", "-u", "NONE", "-l"])
                .arg(&script)
                .env("ADE_INSTALL_ROOT", root)
                .env("ADE_REPO", repo)
                .output()
                .expect("run nvim")
        }
    })
    .await
    .expect("nvim task");
    assert!(
        output.status.success(),
        "nvim failed: {}",
        String::from_utf8_lossy(&output.stderr)
    );
    let stdout = String::from_utf8_lossy(&output.stdout);
    let line = stdout
        .lines()
        .rev()
        .find(|line| line.trim_start().starts_with('{'))
        .expect("JSON line from Lua");
    let value: Value = serde_json::from_str(line).expect("Lua JSON");
    assert_eq!(value["status"], "installed", "{value}");
    assert_eq!(value["install_id"], install_id);
    assert_eq!(value["version"], "0.4.0");
    assert_eq!(
        value["in_use"], true,
        "the Rust lease must be visible: {value}"
    );
    assert_eq!(value["tree_in_use"], true, "{value}");
}
