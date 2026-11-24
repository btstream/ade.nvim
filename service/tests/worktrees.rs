#![cfg(unix)]
//! Worktrees for workers and person-started workers (PROTOCOL.md 18.12,
//! 18.13, 18.16).
//!
//! Real service binary and real git repositories. When `git` is not installed
//! every scenario prints `SKIP: git is not available` and returns.

mod common;

use std::io::{BufRead, BufReader, Write};
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::sync::mpsc;
use std::time::{Duration, Instant};

use serde_json::{json, Value};
use sha2::{Digest, Sha256};

use common::{Client, TestServer};

const WAIT: Duration = Duration::from_secs(30);

fn fixture(name: &str) -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("tests")
        .join("fixtures")
        .join(name)
}

/// The session token the service injected, from the agent side file.
fn injected_token(server: &TestServer, session: &str) -> String {
    let path = server.dir().join("session-tokens");
    let deadline = std::time::Instant::now() + std::time::Duration::from_secs(20);
    loop {
        if let Ok(text) = std::fs::read_to_string(&path) {
            if let Some(token) = text.lines().rev().find_map(|line| {
                let (known, token) = line.split_once(' ')?;
                (known == session).then(|| token.to_string())
            }) {
                return token;
            }
        }
        if std::time::Instant::now() >= deadline {
            panic!("no injected token for {session}");
        }
        std::thread::sleep(std::time::Duration::from_millis(20));
    }
}

fn agent() -> String {
    fixture("team_agent.py").to_string_lossy().to_string()
}

fn git_available() -> bool {
    Command::new("git")
        .arg("--version")
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .status()
        .map(|status| status.success())
        .unwrap_or(false)
}

fn skip(label: &str) -> bool {
    if git_available() {
        return false;
    }
    eprintln!("SKIP: git is not available ({label})");
    true
}

fn git(dir: &Path, args: &[&str]) -> std::process::Output {
    Command::new("git")
        .arg("-C")
        .arg(dir)
        .args(args)
        .env("GIT_AUTHOR_NAME", "ade test")
        .env("GIT_AUTHOR_EMAIL", "test@example.invalid")
        .env("GIT_COMMITTER_NAME", "ade test")
        .env("GIT_COMMITTER_EMAIL", "test@example.invalid")
        .output()
        .unwrap_or_else(|error| panic!("git {args:?}: {error}"))
}

fn git_ok(dir: &Path, args: &[&str]) -> String {
    let output = git(dir, args);
    assert!(
        output.status.success(),
        "git {args:?} failed: {}",
        String::from_utf8_lossy(&output.stderr)
    );
    String::from_utf8_lossy(&output.stdout).trim().to_string()
}

fn commit_all(repo: &Path, message: &str) {
    git_ok(repo, &["add", "-A"]);
    git_ok(repo, &["commit", "-q", "-m", message]);
}

/// A repository with `root.txt` and `sub/committed.txt` committed.
fn init_repo(repo: &Path) {
    std::fs::create_dir_all(repo).expect("repo dir");
    git_ok(repo, &["init", "-q"]);
    git_ok(repo, &["config", "user.name", "ade test"]);
    git_ok(repo, &["config", "user.email", "test@example.invalid"]);
    git_ok(repo, &["config", "commit.gpgsign", "false"]);
    std::fs::write(repo.join("root.txt"), "root\n").expect("root file");
    std::fs::create_dir_all(repo.join("sub")).expect("sub dir");
    std::fs::write(repo.join("sub/committed.txt"), "committed\n").expect("sub file");
    commit_all(repo, "initial");
}

fn child_env(server: &TestServer, log: &Path, gate: &Path) -> Value {
    let path = std::env::var("PATH").unwrap_or_default();
    json!({
        "PATH": path,
        "HOME": server.dir().to_string_lossy(),
        "NVIM_ADE_SERVER_DIR": server.dir().to_string_lossy(),
        "TEAM_AGENT_LOG": log.to_string_lossy(),
        "TEAM_AGENT_GATE": gate.to_string_lossy(),
        "TEAM_AGENT_TEMPLATE": "dev",
        "TEAM_AGENT_TOKEN_FILE": server.dir().join("session-tokens").to_string_lossy(),
    })
}

#[derive(Clone)]
enum Root {
    /// `<server dir>/worktrees` (the normal case).
    Default,
    /// `<repo>/wt-root`, i.e. inside the toplevel.
    InsideRepo,
    /// A worktree template without `worktree_root`.
    Missing,
}

struct Harness {
    server: TestServer,
    client: Client,
    cwd: PathBuf,
    team: String,
    token: String,
    log: PathBuf,
}

impl Harness {
    fn team(&mut self) -> Value {
        let listed = self.client.request(90, "team.list", json!({}));
        listed["result"]["teams"]
            .as_array()
            .and_then(|teams| teams.iter().find(|team| team["id"] == self.team).cloned())
            .unwrap_or(Value::Null)
    }

    fn participant(&mut self, name: &str) -> Option<Value> {
        self.team()["participants"]
            .as_array()?
            .iter()
            .find(|entry| entry["name"] == name)
            .cloned()
    }

    fn wait_participant(&mut self, name: &str, predicate: impl Fn(&Value) -> bool) -> Value {
        wait_for(
            || self.participant(name).filter(|entry| predicate(entry)),
            &format!("participant {name}"),
        )
    }

    fn client_instance(&mut self) -> String {
        // The harness leader instance is the only attached agent; team.list
        // names it.
        self.team()["leader"]["instance"]
            .as_str()
            .unwrap_or("i1")
            .to_string()
    }

    fn spawn_human(&mut self, name: &str, task: &str) -> Value {
        let team = self.team.clone();
        self.client.request(
            33,
            "team.spawn",
            json!({"team": team, "template": "dev", "name": name, "task": task}),
        )
    }

    fn spawn(&self, name: &str, task: &str) -> Value {
        mcp_call(
            &self.server,
            &self.token,
            "team_spawn",
            json!({"template":"dev","name":name,"task":task}),
        )
    }

    fn read_leader(&mut self) -> Vec<Value> {
        let read = self.client.request(
            91,
            "team.read",
            json!({"team": self.team, "participant": "leader"}),
        );
        read["result"]["messages"]
            .as_array()
            .cloned()
            .unwrap_or_default()
    }

    fn stop_worker(&mut self, name: &str) -> String {
        let entry = self.wait_participant(name, |entry| entry["instance"].as_str().is_some());
        let instance = entry["instance"].as_str().unwrap().to_string();
        let stopped = self.client.request(
            92,
            "agent.stop",
            json!({"instance": instance, "force": true}),
        );
        assert!(stopped["result"].is_object(), "stop: {stopped}");
        self.wait_participant(name, |entry| entry["state"] == "exited");
        instance
    }

    fn worker_cwds(&self) -> Vec<String> {
        let text = std::fs::read_to_string(&self.log).unwrap_or_default();
        let mut sessions = Vec::new();
        for line in text.lines() {
            let Ok(value) = serde_json::from_str::<Value>(line) else {
                continue;
            };
            if value["event"] == "session" {
                sessions.push(value);
            }
        }
        let leader = sessions.first().and_then(|value| value["pid"].as_u64());
        sessions
            .into_iter()
            .filter(|value| value["pid"].as_u64() != leader)
            .filter_map(|value| value["cwd"].as_str().map(str::to_string))
            .collect()
    }

    fn worktree(&mut self, name: &str) -> Value {
        self.wait_participant(name, |entry| entry["worktree"].is_object())["worktree"].clone()
    }

    fn branch_exists(&self, branch: &str) -> bool {
        git(
            &self.cwd,
            &["rev-parse", "--verify", &format!("refs/heads/{branch}")],
        )
        .status
        .success()
    }
}

fn tunnel_call(client: &mut Client, instance: &str, id: u64, method: &str, params: Value) -> Value {
    client.notify(
        "tunnel.send",
        json!({
            "instance": instance,
            "message": {"jsonrpc": "2.0", "id": id, "method": method, "params": params},
        }),
    );
    let deadline = Instant::now() + WAIT;
    loop {
        let frame = client.next_tunnel_recv(Duration::from_millis(200));
        if frame["message"].get("id") == Some(&json!(id))
            && frame["message"].get("method").is_none()
        {
            return frame["message"].clone();
        }
        if Instant::now() >= deadline {
            panic!("no response to {method}");
        }
    }
}

fn wait_for<T>(mut check: impl FnMut() -> Option<T>, label: &str) -> T {
    let deadline = Instant::now() + WAIT;
    loop {
        if let Some(value) = check() {
            return value;
        }
        if Instant::now() >= deadline {
            panic!("timed out waiting for {label}");
        }
        std::thread::sleep(Duration::from_millis(20));
    }
}

struct ChildGuard(std::process::Child);

impl Drop for ChildGuard {
    fn drop(&mut self) {
        let _ = self.0.kill();
        let _ = self.0.wait();
    }
}

fn mcp_session(server: &TestServer, token: &str, frames: &[Value], want: u64) -> Value {
    let child = Command::new(env!("CARGO_BIN_EXE_nvim_ade_server"))
        .arg("mcp")
        .env("ADE_TEAM_TOKEN", token)
        .env("NVIM_ADE_SERVER_DIR", server.dir())
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .spawn()
        .expect("spawn mcp");
    let mut guard = ChildGuard(child);
    {
        let stdin = guard.0.stdin.as_mut().expect("stdin");
        for frame in frames {
            writeln!(stdin, "{frame}").expect("write mcp frame");
        }
    }
    let stdout = guard.0.stdout.take().expect("stdout");
    let mut reader = BufReader::new(stdout);
    let mut line = String::new();
    let deadline = Instant::now() + WAIT;
    loop {
        line.clear();
        if reader.read_line(&mut line).expect("read mcp") == 0 {
            panic!("mcp exited before message {want}");
        }
        let Ok(value) = serde_json::from_str::<Value>(line.trim()) else {
            continue;
        };
        if value["id"] == want {
            return value["result"].clone();
        }
        if Instant::now() >= deadline {
            panic!("timed out waiting for mcp message {want}");
        }
    }
}

fn mcp_call(server: &TestServer, token: &str, tool: &str, arguments: Value) -> Value {
    mcp_session(
        server,
        token,
        &[
            json!({"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"test"}}}),
            json!({"jsonrpc":"2.0","method":"notifications/initialized"}),
            json!({"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":tool,"arguments":arguments}}),
        ],
        2,
    )
}

fn alive(pid: u32) -> bool {
    Path::new(&format!("/proc/{pid}")).exists()
}

fn worktree_root(harness: &Harness) -> PathBuf {
    harness.server.dir().join("worktrees")
}

fn branch_list(cwd: &Path) -> String {
    git_ok(cwd, &["branch", "--list", "ade/*"])
}

fn mcp_text(result: &Value) -> String {
    result["content"][0]["text"]
        .as_str()
        .unwrap_or_default()
        .to_string()
}

// ---------------------------------------------------------------------------
// scenarios
// ---------------------------------------------------------------------------

#[test]
fn a_worktree_worker_runs_in_the_worktree_subdirectory() {
    if skip("a_worktree_worker_runs_in_the_worktree_subdirectory") {
        return;
    }
    let mut harness = Harness::with_worktree("wt-run", |work| {
        init_repo(work);
        work.join("sub")
    });
    let spawned = harness.spawn("w1", "work");
    assert_eq!(spawned["isError"], false, "{spawned}");
    assert!(
        mcp_text(&spawned).contains("started"),
        "{}",
        mcp_text(&spawned)
    );
    let worktree = harness.worktree("w1");
    let branch = worktree["branch"].as_str().expect("branch").to_string();
    let path = PathBuf::from(worktree["path"].as_str().expect("path"));
    assert!(branch.starts_with("ade/t1-"), "{branch}");
    assert!(branch.ends_with("/w1"), "{branch}");
    assert!(
        path.join("sub/committed.txt").is_file(),
        "the worktree holds the committed tree: {}",
        path.display()
    );
    let cwds = wait_for(
        || {
            let values = harness.worker_cwds();
            (!values.is_empty()).then_some(values)
        },
        "the worker session",
    );
    assert_eq!(
        cwds[0],
        path.join("sub").to_string_lossy(),
        "{cwds:?} stderr={}",
        harness.server.stderr()
    );
    let head = git_ok(&harness.cwd, &["rev-parse", "HEAD"]);
    // `team.read` carries the worktree and its base; `team.list` only the
    // path and branch (18.12).
    let read = harness.client.request(
        21,
        "team.read",
        json!({"team": harness.team, "participant": "w1"}),
    );
    assert_eq!(read["result"]["worktree"]["branch"], branch, "{read}");
    assert_eq!(read["result"]["worktree"]["base"], head, "{read}");
}

#[test]
fn a_non_git_cwd_fails_with_not_allowed() {
    if skip("a_non_git_cwd_fails_with_not_allowed") {
        return;
    }
    let mut harness = Harness::with_worktree("wt-nogit", |work| work.to_path_buf());
    let spawned = harness.spawn("w1", "work");
    let text = mcp_text(&spawned);
    assert_eq!(spawned["isError"], true, "{spawned}");
    assert!(text.contains("not inside a git work tree"), "{text}");
    let exited = harness.wait_participant("w1", |entry| entry["state"] == "exited");
    assert!(
        exited["reason"]
            .as_str()
            .is_some_and(|reason| reason.contains("git work tree")),
        "{exited}"
    );
}

#[test]
fn an_unborn_head_fails_with_not_allowed() {
    if skip("an_unborn_head_fails_with_not_allowed") {
        return;
    }
    let harness = Harness::with_worktree("wt-unborn", |work| {
        git_ok(work, &["init", "-q"]);
        work.to_path_buf()
    });
    let spawned = harness.spawn("w1", "work");
    assert_eq!(spawned["isError"], true, "{spawned}");
    assert!(
        mcp_text(&spawned).contains("no commit at HEAD"),
        "{}",
        mcp_text(&spawned)
    );
}

#[test]
fn a_bare_repository_is_refused() {
    if skip("a_bare_repository_is_refused") {
        return;
    }
    let harness = Harness::with_worktree("wt-bare", |work| {
        git_ok(work, &["init", "-q", "--bare"]);
        work.to_path_buf()
    });
    let spawned = harness.spawn("w1", "work");
    assert_eq!(spawned["isError"], true, "{spawned}");
    assert!(
        mcp_text(&spawned).contains("not inside a git work tree"),
        "{}",
        mcp_text(&spawned)
    );
}

#[test]
fn a_detached_head_is_allowed() {
    if skip("a_detached_head_is_allowed") {
        return;
    }
    let harness = Harness::with_worktree("wt-detached", |work| {
        init_repo(work);
        git_ok(work, &["checkout", "-q", "--detach"]);
        work.to_path_buf()
    });
    let spawned = harness.spawn("w1", "work");
    assert_eq!(spawned["isError"], false, "{spawned}");
    assert!(
        mcp_text(&spawned).contains("started"),
        "{}",
        mcp_text(&spawned)
    );
}

#[test]
fn an_existing_branch_is_never_reused() {
    if skip("an_existing_branch_is_never_reused") {
        return;
    }
    let wrapper = std::env::temp_dir().join(format!("ade-fake-git-{}", std::process::id()));
    std::fs::create_dir_all(&wrapper).expect("wrapper dir");
    let real = Command::new("sh")
        .arg("-c")
        .arg("command -v git")
        .output()
        .expect("find git");
    let real = String::from_utf8_lossy(&real.stdout).trim().to_string();
    let script = wrapper.join("git");
    std::fs::write(
        &script,
        format!(
            "#!/bin/sh\ncase \"$*\" in\n  *\"show-ref --verify --quiet refs/heads/\"*) exit 0 ;;\nesac\nexec {real} \"$@\"\n"
        ),
    )
    .expect("fake git");
    std::fs::set_permissions(&script, std::os::unix::fs::PermissionsExt::from_mode(0o755))
        .expect("chmod");
    let path = format!(
        "{}:{}",
        wrapper.display(),
        std::env::var("PATH").unwrap_or_default()
    );
    let mut harness = Harness::with_worktree_env("wt-branch", &[("PATH", &path)], |work| {
        init_repo(work);
        work.to_path_buf()
    });
    let spawned = harness.spawn("w1", "work");
    assert_eq!(spawned["isError"], true, "{spawned}");
    assert!(
        mcp_text(&spawned).contains("already exists"),
        "{}",
        mcp_text(&spawned)
    );
    assert!(harness.participant("w1").is_some());
    let root = harness.server.dir().join("worktrees");
    let entries = std::fs::read_dir(&root).map(|dir| dir.count()).unwrap_or(0);
    assert_eq!(entries, 0, "no worktree may be created");
}

#[test]
fn worker_exit_and_team_close_keep_the_worktree() {
    if skip("worker_exit_and_team_close_keep_the_worktree") {
        return;
    }
    let mut harness = Harness::with_worktree("wt-keep", |work| {
        init_repo(work);
        work.to_path_buf()
    });
    let spawned = harness.spawn("w1", "work");
    assert_eq!(spawned["isError"], false, "{spawned}");
    let worktree = harness.worktree("w1");
    let path = PathBuf::from(worktree["path"].as_str().unwrap());
    let branch = worktree["branch"].as_str().unwrap().to_string();
    harness.wait_participant("w1", |entry| entry["state"] == "idle");
    harness.stop_worker("w1");
    assert!(
        path.is_dir(),
        "the worktree survives the worker: {}",
        path.display()
    );
    let closed = harness
        .client
        .request(22, "team.close", json!({"team": harness.team}));
    assert!(closed["result"].is_object(), "{closed}");
    assert!(
        path.is_dir(),
        "the worktree survives team.close: {}",
        path.display()
    );
    assert!(harness.branch_exists(&branch), "{branch}");
}

#[test]
fn remove_refuses_a_running_worker_and_keeps_an_unmerged_branch() {
    if skip("remove_refuses_a_running_worker_and_keeps_an_unmerged_branch") {
        return;
    }
    let mut harness = Harness::with_worktree("wt-remove", |work| {
        init_repo(work);
        work.join("sub")
    });
    let spawned = harness.spawn("w1", "work");
    assert_eq!(spawned["isError"], false, "{spawned}");
    let worktree = harness.worktree("w1");
    let path = PathBuf::from(worktree["path"].as_str().unwrap());
    let branch = worktree["branch"].as_str().unwrap().to_string();
    harness.wait_participant("w1", |entry| entry["state"] == "idle");
    let refused = harness.client.request(
        23,
        "team.remove_worktree",
        json!({"team": harness.team, "participant": "w1"}),
    );
    assert_eq!(refused["error"]["code"], -32061, "{refused}");

    // A commit that is not in the toplevel: the branch must be kept.
    std::fs::write(path.join("root.txt"), "worker change\n").expect("worker file");
    git_ok(&path, &["add", "-A"]);
    git_ok(&path, &["commit", "-q", "-m", "worker work"]);
    harness.stop_worker("w1");
    let removed = harness.client.request(
        24,
        "team.remove_worktree",
        json!({"team": harness.team, "participant": "w1"}),
    );
    assert_eq!(removed["result"]["removed"], true, "{removed}");
    assert_eq!(removed["result"]["branch_kept"], true, "{removed}");
    assert!(!path.exists(), "the worktree is gone");
    assert!(
        harness.branch_exists(&branch),
        "the unmerged branch is kept"
    );
}

#[test]
fn remove_deletes_a_merged_branch() {
    if skip("remove_deletes_a_merged_branch") {
        return;
    }
    let mut harness = Harness::with_worktree("wt-merged", |work| {
        init_repo(work);
        work.to_path_buf()
    });
    let spawned = harness.spawn("w1", "work");
    assert_eq!(spawned["isError"], false, "{spawned}");
    let worktree = harness.worktree("w1");
    let path = PathBuf::from(worktree["path"].as_str().unwrap());
    let branch = worktree["branch"].as_str().unwrap().to_string();
    harness.wait_participant("w1", |entry| entry["state"] == "idle");
    std::fs::write(path.join("root.txt"), "merged work\n").expect("worker file");
    git_ok(&path, &["add", "-A"]);
    git_ok(&path, &["commit", "-q", "-m", "worker work"]);
    harness.stop_worker("w1");
    git_ok(&harness.cwd, &["merge", "-q", "--no-edit", &branch]);
    let removed = harness.client.request(
        25,
        "team.remove_worktree",
        json!({"team": harness.team, "participant": "w1"}),
    );
    assert_eq!(removed["result"]["removed"], true, "{removed}");
    assert_eq!(removed["result"]["branch_kept"], false, "{removed}");
    assert!(!path.exists());
    assert!(
        !harness.branch_exists(&branch),
        "the merged branch is deleted"
    );
}

#[test]
fn force_removes_a_dirty_worktree() {
    if skip("force_removes_a_dirty_worktree") {
        return;
    }
    let mut harness = Harness::with_worktree("wt-force", |work| {
        init_repo(work);
        work.to_path_buf()
    });
    let spawned = harness.spawn("w1", "work");
    assert_eq!(spawned["isError"], false, "{spawned}");
    let worktree = harness.worktree("w1");
    let path = PathBuf::from(worktree["path"].as_str().unwrap());
    harness.wait_participant("w1", |entry| entry["state"] == "idle");
    harness.stop_worker("w1");
    std::fs::write(path.join("dirty.txt"), "dirty\n").expect("dirty file");
    let refused = harness.client.request(
        26,
        "team.remove_worktree",
        json!({"team": harness.team, "participant": "w1"}),
    );
    assert_eq!(refused["error"]["code"], -32066, "{refused}");
    assert!(
        refused["error"]["data"]["stderr"].as_str().is_some(),
        "git stderr is reported: {refused}"
    );
    assert!(path.exists(), "a refused removal keeps the worktree");
    let forced = harness.client.request(
        27,
        "team.remove_worktree",
        json!({"team": harness.team, "participant": "w1", "force": true}),
    );
    assert_eq!(forced["result"]["removed"], true, "{forced}");
    assert!(!path.exists());
}

#[test]
fn team_spawn_has_no_inbox_item_and_warns_about_a_dirty_tree() {
    if skip("team_spawn_has_no_inbox_item_and_warns_about_a_dirty_tree") {
        return;
    }
    let mut harness = Harness::with_worktree("wt-human", |work| {
        init_repo(work);
        work.to_path_buf()
    });
    // Same checks as bus.spawn, before any worker exists.
    let unknown = harness.client.request(
        30,
        "team.spawn",
        json!({"team": harness.team, "template": "nope"}),
    );
    assert_eq!(unknown["error"]["code"], -32061, "{unknown}");
    let invalid = harness.client.request(
        31,
        "team.spawn",
        json!({"team": harness.team, "template": "dev", "name": "Bad Name"}),
    );
    assert_eq!(invalid["error"]["code"], -32060, "{invalid}");

    // Leave a change that is not committed: the worktree starts from HEAD and
    // the person is told.
    std::fs::write(harness.cwd.join("root.txt"), "uncommitted\n").expect("dirty");
    let spawned = harness.client.request(
        28,
        "team.spawn",
        json!({"team": harness.team, "template": "dev", "name": "w1", "task": "work"}),
    );
    assert_eq!(spawned["result"]["name"], "w1", "{spawned}");
    assert_eq!(spawned["result"]["warning"], "dirty_tree", "{spawned}");
    let worktree = harness.worktree("w1");
    let path = PathBuf::from(worktree["path"].as_str().unwrap());
    assert_eq!(
        std::fs::read_to_string(path.join("root.txt")).expect("worktree root.txt"),
        "root\n",
        "the worktree holds the committed state, not the uncommitted change"
    );
    let team = harness.team();
    assert!(
        !team["inbox"]
            .as_array()
            .is_some_and(|items| items.iter().any(|item| item["kind"] == "spawn")),
        "team.spawn must not create an inbox item: {team}"
    );
    let messages = wait_for(
        || {
            let messages = harness.read_leader();
            messages
                .iter()
                .any(|message| message["body"] == "worker w1 started from template dev")
                .then_some(messages)
        },
        "the leader's start notice",
    );
    assert!(messages
        .iter()
        .any(|message| message["body"] == "worker w1 started from template dev"));
    // The role card says the worktree is the last commit.
    let prompt = wait_for(
        || {
            let text = std::fs::read_to_string(&harness.log).unwrap_or_default();
            text.lines()
                .filter_map(|line| serde_json::from_str::<Value>(line).ok())
                .find(|event| {
                    event["event"] == "prompt"
                        && event["text"]
                            .as_str()
                            .is_some_and(|text| text.contains("last commit"))
                })
        },
        "the dirty-tree role card",
    );
    assert!(prompt["text"].as_str().unwrap().contains("last commit"));
    // The limit still applies to person-started workers.
    let limited = harness.client.request(
        29,
        "team.spawn",
        json!({"team": harness.team, "template": "dev", "name": "w2"}),
    );
    assert_eq!(limited["error"]["code"], -32061, "{limited}");
}

#[test]
fn a_missing_subdirectory_starts_at_the_worktree_root() {
    if skip("a_missing_subdirectory_starts_at_the_worktree_root") {
        return;
    }
    let mut harness = Harness::with_worktree("wt-missingsub", |work| {
        init_repo(work);
        let missing = work.join("missing");
        std::fs::create_dir_all(&missing).expect("missing dir");
        missing
    });
    let spawned = harness.spawn("w1", "work");
    assert_eq!(spawned["isError"], false, "{spawned}");
    let worktree = harness.worktree("w1");
    let path = PathBuf::from(worktree["path"].as_str().unwrap());
    let cwds = wait_for(
        || {
            let values = harness.worker_cwds();
            (!values.is_empty()).then_some(values)
        },
        "the worker session",
    );
    assert_eq!(
        cwds[0],
        path.to_string_lossy(),
        "the worker starts at the root"
    );
    let messages = wait_for(
        || {
            let messages = harness.read_leader();
            messages
                .iter()
                .any(|message| {
                    message["body"]
                        .as_str()
                        .is_some_and(|body| body.contains("does not exist in the worktree"))
                })
                .then_some(messages)
        },
        "the missing-subdirectory notice",
    );
    assert!(messages.iter().any(|message| {
        message["body"]
            .as_str()
            .is_some_and(|body| body.contains("does not exist in the worktree"))
    }));
}

#[test]
fn git_does_not_block_the_hub_and_a_timeout_is_reported() {
    if skip("git_does_not_block_the_hub_and_a_timeout_is_reported") {
        return;
    }
    let real = Command::new("sh")
        .arg("-c")
        .arg("command -v git")
        .output()
        .expect("find git");
    let real = String::from_utf8_lossy(&real.stdout).trim().to_string();
    let wrapper = std::env::temp_dir().join(format!("ade-slow-git-{}", std::process::id()));
    std::fs::create_dir_all(&wrapper).expect("wrapper dir");
    let script = wrapper.join("git");
    std::fs::write(
        &script,
        format!(
            "#!/bin/sh\ncase \"$*\" in\n  *\"worktree add\"*) sleep 3 ;;\nesac\nexec {real} \"$@\"\n"
        ),
    )
    .expect("fake git");
    std::fs::set_permissions(&script, std::os::unix::fs::PermissionsExt::from_mode(0o755))
        .expect("chmod");
    let path = format!(
        "{}:{}",
        wrapper.display(),
        std::env::var("PATH").unwrap_or_default()
    );
    let mut harness = Harness::with_worktree_env("wt-slow", &[("PATH", &path)], |work| {
        init_repo(work);
        work.to_path_buf()
    });
    let token_path = harness.server.token_path();
    let socket = harness.server.socket().to_path_buf();
    // A fresh connection keeps the 10 s default read timeout (the setup's
    // tunnel polling leaves a shorter one on the harness client).
    let mut probe = harness.server.connect();
    let hello = probe.hello(&harness.server.token(), nvim_ade_server::API_VERSION);
    assert!(hello["result"].is_object(), "{hello}");
    let (sent_tx, sent_rx) = mpsc::channel::<()>();
    let spawn = std::thread::spawn(move || {
        let mut client = Client::connect(&socket).expect("second connection");
        let token = std::fs::read_to_string(token_path).expect("token");
        let hello = client.hello(token.trim(), nvim_ade_server::API_VERSION);
        assert!(hello["result"].is_object(), "{hello}");
        // Send without waiting: the hub must accept the next request while git
        // is still in its (wrapped) sleep.
        client.send(&json!({
            "jsonrpc": "2.0",
            "id": 30,
            "method": "team.spawn",
            "params": {"team": "t1", "template": "dev", "name": "w1", "task": "work"},
        }));
        sent_tx.send(()).expect("signal");
        // The reply is deferred until git finishes; this test only needs the
        // request to be in flight while the second connection lists.
        std::thread::sleep(Duration::from_secs(2));
    });
    sent_rx
        .recv_timeout(Duration::from_secs(10))
        .expect("the spawn request was sent");
    let started = Instant::now();
    let listed = probe.request(31, "team.list", json!({}));
    let elapsed = started.elapsed();
    assert!(listed["result"].is_object(), "{listed}");
    assert!(
        elapsed < Duration::from_millis(2000),
        "team.list took {elapsed:?} while git slept; the hub must not block"
    );
    spawn.join().expect("spawn thread");
    harness.wait_participant("w1", |entry| entry["worktree"].is_object());

    // A timeout is -32066 with the git output.
    let slow = wrapper.join("git");
    let timeout_pid = std::env::temp_dir().join(format!("ade-timeout-pid-{}", std::process::id()));
    std::fs::write(
        &slow,
        format!(
            "#!/bin/sh\ncase \"$*\" in\n  *\"worktree add\"*) echo $$ > \"{}\" ; sleep 5 ;;\nesac\nexec {real} \"$@\"\n",
            timeout_pid.display()
        ),
    )
    .expect("fake git");
    let mut timed = Harness::with_worktree_env(
        "wt-timeout",
        &[("PATH", &path), ("NVIM_ADE_SERVER_GIT_TIMEOUT_MS", "200")],
        |work| {
            init_repo(work);
            work.to_path_buf()
        },
    );
    let spawned = timed.spawn_human("w1", "work");
    assert_eq!(spawned["error"]["code"], -32066, "{spawned}");
    assert!(
        spawned["error"]["data"]["stderr"]
            .as_str()
            .is_some_and(|stderr| stderr.contains("timed out")),
        "{spawned}"
    );
    let pid = wait_for(
        || {
            std::fs::read_to_string(&timeout_pid)
                .ok()
                .and_then(|text| text.trim().parse::<u32>().ok())
        },
        "the slow wrapper pid",
    );
    wait_for(
        || (!alive(pid)).then_some(()),
        "the slow wrapper to be gone",
    );
    std::fs::remove_file(timeout_pid).ok();
}

#[test]
fn an_approved_worktree_failure_notifies_the_leader() {
    if skip("an_approved_worktree_failure_notifies_the_leader") {
        return;
    }
    let mut harness = Harness::with_worktree_manual("wt-approved-fail", |work| work.to_path_buf());
    let spawned = harness.spawn("w1", "work");
    assert_eq!(spawned["isError"], false, "{spawned}");
    let text = mcp_text(&spawned);
    let value: Value = serde_json::from_str(&text).expect("spawn result JSON");
    let request = value["request"].as_str().expect("request id").to_string();
    assert_eq!(value["status"], "awaiting_approval", "{value}");
    let answered = harness.client.request(
        40,
        "team.answer",
        json!({"request": request, "allow": true}),
    );
    assert!(answered["result"].is_object(), "{answered}");
    let messages = wait_for(
        || {
            let messages = harness.read_leader();
            messages
                .iter()
                .any(|message| {
                    message["kind"] == "notice"
                        && message["body"]
                            .as_str()
                            .is_some_and(|body| body.contains("git work tree"))
                })
                .then_some(messages)
        },
        "the leader's failed-spawn notice",
    );
    assert!(messages.iter().any(|message| message["kind"] == "notice"));
    let exited = harness.wait_participant("w1", |entry| entry["state"] == "exited");
    assert!(exited["reason"].as_str().is_some(), "{exited}");
}

#[test]
fn an_approved_dirty_worktree_notice_has_the_warning() {
    if skip("an_approved_dirty_worktree_notice_has_the_warning") {
        return;
    }
    let mut harness = Harness::with_worktree_manual("wt-approved-dirty", |work| {
        init_repo(work);
        work.to_path_buf()
    });
    std::fs::write(harness.cwd.join("root.txt"), "uncommitted\n").expect("dirty");
    let spawned = harness.spawn("w1", "work");
    let value: Value = serde_json::from_str(&mcp_text(&spawned)).expect("spawn JSON");
    let request = value["request"].as_str().expect("request id").to_string();
    harness.client.request(
        41,
        "team.answer",
        json!({"request": request, "allow": true}),
    );
    let messages = wait_for(
        || {
            let messages = harness.read_leader();
            messages
                .iter()
                .any(|message| {
                    message["body"].as_str().is_some_and(|body| {
                        body.contains("approved") && body.contains("dirty_tree")
                    })
                })
                .then_some(messages)
        },
        "the dirty-tree approval notice",
    );
    assert!(messages.iter().any(|message| message["body"]
        .as_str()
        .is_some_and(|body| body.contains("(warning: dirty_tree)"))));
}

#[test]
fn a_hung_hook_is_killed_with_its_group_and_the_half_worktree_is_removed() {
    if skip("a_hung_hook_is_killed_with_its_group_and_the_half_worktree_is_removed") {
        return;
    }
    let pid_file = std::env::temp_dir().join(format!("ade-hook-pids-{}", std::process::id()));
    let hook_pid_file = pid_file.clone();
    let hook = hook_pid_file.to_string_lossy().to_string();
    let env = [
        ("NVIM_ADE_SERVER_GIT_TIMEOUT_MS", "500"),
        ("ADE_TEST_HOOK_PID", hook.as_str()),
    ];
    let mut harness = Harness::with_worktree_env("wt-hook", &env, |work| {
        init_repo(work);
        // A post-checkout hook that starts a grandchild and hangs.
        let path = work.join(".git/hooks/post-checkout");
        std::fs::write(
            &path,
            "#!/bin/sh\necho $$ > \"$ADE_TEST_HOOK_PID\"\nsleep 300 &\necho $! >> \"$ADE_TEST_HOOK_PID\"\nsleep 300\n",
        )
        .expect("hook");
        std::fs::set_permissions(&path, std::os::unix::fs::PermissionsExt::from_mode(0o755))
            .expect("chmod");
        work.to_path_buf()
    });
    let spawned = harness.spawn_human("w1", "work");
    assert_eq!(spawned["error"]["code"], -32066, "{spawned}");
    assert!(
        spawned["error"]["data"]["stderr"]
            .as_str()
            .is_some_and(|stderr| stderr.contains("timed out")),
        "{spawned}"
    );
    let pids = wait_for(
        || {
            let text = std::fs::read_to_string(&pid_file).ok()?;
            let pids: Vec<u32> = text
                .lines()
                .filter_map(|line| line.trim().parse().ok())
                .collect();
            (!pids.is_empty()).then_some(pids)
        },
        "the hook's pids",
    );
    for pid in &pids {
        wait_for(
            || (!alive(*pid)).then_some(()),
            &format!("hook pid {pid} to be gone"),
        );
    }
    let root = worktree_root(&harness);
    assert_eq!(
        std::fs::read_dir(&root).map(|dir| dir.count()).unwrap_or(0),
        0,
        "the half-created worktree directory is removed"
    );
    assert!(
        branch_list(&harness.cwd).is_empty(),
        "the branch is removed"
    );

    // With the hook gone the same team can create a worker again.
    std::fs::remove_file(harness.cwd.join(".git/hooks/post-checkout")).ok();
    let again = harness.spawn_human("w2", "work");
    assert_eq!(again["result"]["name"], "w2", "{again}");
    std::fs::remove_file(pid_file).ok();
}

#[test]
fn closing_the_team_discards_a_worktree_created_meanwhile() {
    if skip("closing_the_team_discards_a_worktree_created_meanwhile") {
        return;
    }
    let real = Command::new("sh")
        .arg("-c")
        .arg("command -v git")
        .output()
        .expect("find git");
    let real = String::from_utf8_lossy(&real.stdout).trim().to_string();
    let wrapper = std::env::temp_dir().join(format!("ade-slow-close-git-{}", std::process::id()));
    std::fs::create_dir_all(&wrapper).expect("wrapper dir");
    let marker = std::env::temp_dir().join(format!("ade-slow-close-{}", std::process::id()));
    let script = wrapper.join("git");
    std::fs::write(
        &script,
        format!(
            "#!/bin/sh\ncase \"$*\" in\n  *\"worktree add\"*) touch \"{}\" ; sleep 1 ;;\nesac\nexec {real} \"$@\"\n",
            marker.display()
        ),
    )
    .expect("fake git");
    std::fs::set_permissions(&script, std::os::unix::fs::PermissionsExt::from_mode(0o755))
        .expect("chmod");
    let path = format!(
        "{}:{}",
        wrapper.display(),
        std::env::var("PATH").unwrap_or_default()
    );
    let mut harness = Harness::with_worktree_env("wt-close-mid", &[("PATH", &path)], |work| {
        init_repo(work);
        work.to_path_buf()
    });
    let mut probe = harness.server.connect();
    let hello = probe.hello(&harness.server.token(), nvim_ade_server::API_VERSION);
    assert!(hello["result"].is_object(), "{hello}");
    probe.send(&json!({
        "jsonrpc": "2.0",
        "id": 30,
        "method": "team.spawn",
        "params": {"team": harness.team, "template": "dev", "name": "w1", "task": "work"},
    }));
    wait_for(
        || marker.exists().then_some(()),
        "git worktree add to start",
    );
    let closed = harness
        .client
        .request(31, "team.close", json!({"team": harness.team}));
    assert!(closed["result"].is_object(), "{closed}");
    let reply = wait_for(
        || loop {
            let value = probe.recv()?;
            if value["id"] == 30 {
                return Some(value);
            }
        },
        "the spawn reply after close",
    );
    assert_eq!(reply["error"]["code"], -32064, "{reply}");
    let root = worktree_root(&harness);
    wait_for(
        || {
            let empty = std::fs::read_dir(&root).map(|dir| dir.count()).unwrap_or(0) == 0;
            empty.then_some(())
        },
        "the abandoned worktree to be removed",
    );
    assert!(
        branch_list(&harness.cwd).is_empty(),
        "the abandoned branch is removed: {}",
        branch_list(&harness.cwd)
    );
    std::fs::remove_file(marker).ok();
}

#[test]
fn removal_clears_the_record_when_the_directory_was_deleted_by_hand() {
    if skip("removal_clears_the_record_when_the_directory_was_deleted_by_hand") {
        return;
    }
    let mut harness = Harness::with_worktree("wt-manual-delete", |work| {
        init_repo(work);
        work.to_path_buf()
    });
    let spawned = harness.spawn("w1", "work");
    assert_eq!(spawned["isError"], false, "{spawned}");
    let worktree = harness.worktree("w1");
    let path = PathBuf::from(worktree["path"].as_str().unwrap());
    harness.wait_participant("w1", |entry| entry["state"] == "idle");
    std::fs::write(path.join("root.txt"), "unmerged work\n").expect("worker file");
    git_ok(&path, &["add", "-A"]);
    git_ok(&path, &["commit", "-q", "-m", "worker work"]);
    harness.stop_worker("w1");
    std::fs::remove_dir_all(&path).expect("delete the worktree by hand");
    let removed = harness.client.request(
        34,
        "team.remove_worktree",
        json!({"team": harness.team, "participant": "w1"}),
    );
    assert_eq!(removed["result"]["removed"], true, "{removed}");
    assert_eq!(removed["result"]["branch_kept"], true, "{removed}");
    let entry = harness.participant("w1").expect("worker");
    assert!(entry.get("worktree").is_none(), "{entry}");
    let again = harness.client.request(
        35,
        "team.remove_worktree",
        json!({"team": harness.team, "participant": "w1"}),
    );
    assert_eq!(again["error"]["code"], -32060, "{again}");

    // A branch that is already gone counts as not kept.
    let spawned = harness.spawn("w2", "work");
    assert_eq!(spawned["isError"], false, "{spawned}");
    let worktree = harness.worktree("w2");
    let path = PathBuf::from(worktree["path"].as_str().unwrap());
    let branch = worktree["branch"].as_str().unwrap().to_string();
    harness.wait_participant("w2", |entry| entry["state"] == "idle");
    harness.stop_worker("w2");
    std::fs::remove_dir_all(&path).expect("delete w2's worktree");
    git_ok(&harness.cwd, &["worktree", "prune"]);
    git_ok(&harness.cwd, &["branch", "-D", &branch]);
    let removed = harness.client.request(
        36,
        "team.remove_worktree",
        json!({"team": harness.team, "participant": "w2"}),
    );
    assert_eq!(removed["result"]["removed"], true, "{removed}");
    assert_eq!(removed["result"]["branch_kept"], false, "{removed}");
    assert!(!path.exists());
}

#[test]
fn a_git_timeout_during_rev_parse_is_not_a_parameter_error() {
    if skip("a_git_timeout_during_rev_parse_is_not_a_parameter_error") {
        return;
    }
    let real = Command::new("sh")
        .arg("-c")
        .arg("command -v git")
        .output()
        .expect("find git");
    let real = String::from_utf8_lossy(&real.stdout).trim().to_string();
    let wrapper = std::env::temp_dir().join(format!("ade-slow-rev-git-{}", std::process::id()));
    std::fs::create_dir_all(&wrapper).expect("wrapper dir");
    let pid_file = std::env::temp_dir().join(format!("ade-slow-rev-pid-{}", std::process::id()));
    let script = wrapper.join("git");
    std::fs::write(
        &script,
        format!(
            "#!/bin/sh\ncase \"$*\" in\n  *\"rev-parse --show-toplevel\"*) echo $$ > \"{}\" ; sleep 30 ;;\nesac\nexec {real} \"$@\"\n",
            pid_file.display()
        ),
    )
    .expect("fake git");
    std::fs::set_permissions(&script, std::os::unix::fs::PermissionsExt::from_mode(0o755))
        .expect("chmod");
    let path = format!(
        "{}:{}",
        wrapper.display(),
        std::env::var("PATH").unwrap_or_default()
    );
    let mut harness = Harness::with_worktree_env(
        "wt-rev-timeout",
        &[("PATH", &path), ("NVIM_ADE_SERVER_GIT_TIMEOUT_MS", "200")],
        |work| {
            init_repo(work);
            work.to_path_buf()
        },
    );
    let spawned = harness.spawn_human("w1", "work");
    assert_eq!(spawned["error"]["code"], -32066, "{spawned}");
    assert!(
        spawned["error"]["data"]["stderr"]
            .as_str()
            .is_some_and(|stderr| stderr.contains("timed out")),
        "{spawned}"
    );
    let pid = wait_for(
        || {
            std::fs::read_to_string(&pid_file)
                .ok()
                .and_then(|text| text.trim().parse::<u32>().ok())
        },
        "the wrapper pid",
    );
    wait_for(|| (!alive(pid)).then_some(()), "the wrapper to be gone");
    std::fs::remove_file(pid_file).ok();
}

#[test]
fn a_symlinked_toplevel_is_hashed_canonically() {
    if skip("a_symlinked_toplevel_is_hashed_canonically") {
        return;
    }
    let mut harness = Harness::with_worktree("wt-symlink", |work| {
        init_repo(work);
        let link = work.with_file_name("repo-link");
        std::os::unix::fs::symlink(work, &link).expect("symlink");
        link.join("sub")
    });
    let spawned = harness.spawn("w1", "work");
    assert_eq!(spawned["isError"], false, "{spawned}");
    let worktree = harness.worktree("w1");
    let path = PathBuf::from(worktree["path"].as_str().unwrap());
    let canonical = std::fs::canonicalize(harness.server.dir().join("work")).expect("canonical");
    let mut hasher = Sha256::new();
    hasher.update(canonical.to_string_lossy().as_bytes());
    let digest = hasher.finalize();
    let hash: String = digest
        .iter()
        .take(4)
        .map(|byte| format!("{byte:02x}"))
        .collect();
    let directory = path.parent().and_then(|parent| parent.file_name());
    assert!(
        directory
            .and_then(|name| name.to_str())
            .is_some_and(|name| name.ends_with(&hash)),
        "the worktree directory uses the canonical toplevel hash: {} ({hash})",
        path.display()
    );
    let cwds = wait_for(
        || {
            let values = harness.worker_cwds();
            (!values.is_empty()).then_some(values)
        },
        "the worker session",
    );
    assert_eq!(cwds[0], path.join("sub").to_string_lossy(), "{cwds:?}");
}

#[test]
fn a_worktree_root_inside_the_repository_is_refused() {
    if skip("a_worktree_root_inside_the_repository_is_refused") {
        return;
    }
    let mut harness =
        Harness::with_worktree_root("wt-root-inside", Root::InsideRepo, true, |work| {
            init_repo(work);
            work.to_path_buf()
        });
    let spawned = harness.spawn_human("w1", "work");
    assert_eq!(spawned["error"]["code"], -32060, "{spawned}");
    assert!(
        spawned["error"]["message"]
            .as_str()
            .is_some_and(|message| message.contains("outside")),
        "{spawned}"
    );
}

#[test]
fn a_relative_worktree_root_is_refused() {
    if skip("a_relative_worktree_root_is_refused") {
        return;
    }
    let mut harness = Harness::with_worktree("wt-root-relative", |work| {
        init_repo(work);
        work.to_path_buf()
    });
    let configured = harness.client.request(
        38,
        "team.configure",
        json!({
            "cwd": harness.cwd.to_string_lossy(),
            "config": {
                "worktree_root": "relative/worktrees",
                "templates": {"dev": {"worktree": true}}
            }
        }),
    );
    assert_eq!(configured["error"]["code"], -32060, "{configured}");
}

#[test]
fn a_worktree_template_without_a_root_is_not_allowed() {
    if skip("a_worktree_template_without_a_root_is_not_allowed") {
        return;
    }
    let mut harness = Harness::with_worktree_root("wt-root-missing", Root::Missing, true, |work| {
        init_repo(work);
        work.to_path_buf()
    });
    let spawned = harness.spawn_human("w1", "work");
    assert_eq!(spawned["error"]["code"], -32061, "{spawned}");
    assert!(
        spawned["error"]["message"]
            .as_str()
            .is_some_and(|message| message.contains("worktree_root")),
        "{spawned}"
    );
}

#[test]
fn a_leaderless_team_can_start_a_worker_from_the_front_end() {
    if skip("a_leaderless_team_can_start_a_worker_from_the_front_end") {
        return;
    }
    let mut harness = Harness::with_worktree("wt-leaderless", |work| {
        init_repo(work);
        work.to_path_buf()
    });
    let leader = harness.client_instance();
    let stopped =
        harness
            .client
            .request(37, "agent.stop", json!({"instance": leader, "force": true}));
    assert!(stopped["result"].is_object(), "{stopped}");
    wait_for(
        || {
            let team = harness.team();
            (team["state"] == "leaderless").then_some(team)
        },
        "the leaderless team",
    );
    let spawned = harness.spawn_human("w1", "work");
    assert_eq!(spawned["result"]["name"], "w1", "{spawned}");
    harness.wait_participant("w1", |entry| entry["worktree"].is_object());
    let messages = harness.read_leader();
    assert!(messages.iter().any(|message| message["body"]
        .as_str()
        .is_some_and(|body| body == "worker w1 started from template dev")));
}

// ---------------------------------------------------------------------------
// harness with a worktree template configured from the start
// ---------------------------------------------------------------------------

impl Harness {
    fn with_worktree(label: &str, setup: impl FnOnce(&Path) -> PathBuf) -> Self {
        Self::with_worktree_env(label, &[], setup)
    }

    fn with_worktree_env(
        label: &str,
        env: &[(&str, &str)],
        setup: impl FnOnce(&Path) -> PathBuf,
    ) -> Self {
        // The worktree root lives under the server's temporary directory, and
        // the config is sent before the leader binds, so the team starts with
        // the worktree template.
        Self::new_with_setup(label, env, setup, true, true, Root::Default)
    }

    fn with_worktree_manual(label: &str, setup: impl FnOnce(&Path) -> PathBuf) -> Self {
        Self::new_with_setup(label, &[], setup, true, false, Root::Default)
    }

    fn with_worktree_root(
        label: &str,
        root: Root,
        auto_spawn: bool,
        setup: impl FnOnce(&Path) -> PathBuf,
    ) -> Self {
        Self::new_with_setup(label, &[], setup, true, auto_spawn, root)
    }

    fn new_with_setup(
        label: &str,
        env: &[(&str, &str)],
        setup: impl FnOnce(&Path) -> PathBuf,
        worktree: bool,
        auto_spawn: bool,
        root: Root,
    ) -> Self {
        let server = TestServer::start_with(label, &["--idle-timeout", "600"], env);
        let work = server.dir().join("work");
        std::fs::create_dir_all(&work).expect("work dir");
        let cwd = setup(&work);
        let log = server.dir().join("team-agent.log");
        let gate = server.dir().join("team-agent.gate");
        let env_json = child_env(&server, &log, &gate);
        let mut client = server.connect();
        let hello = client.hello(&server.token(), nvim_ade_server::API_VERSION);
        assert!(hello["result"].is_object(), "hello: {hello}");
        let attached = client.request(
            1,
            "agent.attach",
            json!({
                "key": {
                    "agent": "team-test",
                    "command": "python3",
                    "args": [agent()],
                    "cwd": cwd.to_string_lossy(),
                },
                "client_capabilities": {},
                "env": env_json,
            }),
        );
        let instance = attached["result"]["instance"]
            .as_str()
            .unwrap_or_else(|| panic!("attach: {attached}"))
            .to_string();
        tunnel_call(
            &mut client,
            &instance,
            10,
            "initialize",
            json!({"protocolVersion": 1, "clientCapabilities": {}}),
        );
        let mut template = json!({
            "key": { "agent": "team-test", "command": "python3", "args": [agent()] },
            "env": env_json,
            "role": "Do the task carefully and report.",
        });
        if worktree {
            template["worktree"] = json!(true);
        }
        let mut config = json!({
            "max_workers": 1,
            "spawn_confirm": { "auto": if auto_spawn { json!(["dev"]) } else { json!([]) } },
            "limits": { "max_turns_per_task": 30, "max_turns_total": 200 },
            "templates": { "dev": template }
        });
        if worktree {
            let root = match &root {
                Root::Default => Some(server.dir().join("worktrees")),
                Root::InsideRepo => Some(work.join("wt-root")),
                Root::Missing => None,
            };
            if let Some(root) = root {
                config["worktree_root"] = json!(root.to_string_lossy());
            }
        }
        let configured = client.request(
            2,
            "team.configure",
            json!({ "cwd": cwd.to_string_lossy(), "config": config }),
        );
        assert!(configured["result"].is_object(), "configure: {configured}");
        let session_response = tunnel_call(
            &mut client,
            &instance,
            11,
            "session/new",
            json!({ "cwd": cwd.to_string_lossy(), "mcpServers": [] }),
        );
        let session = session_response["result"]["sessionId"]
            .as_str()
            .expect("session id")
            .to_string();
        // `tunnel_call` polls with a short timeout; later requests may wait for
        // git, so restore the default.
        client.reset_read_timeout();
        // v3: an unknown workflow creates the team and then fails (20.4).
        let created = client.request(
            3,
            "team.start",
            json!({
                "instance": instance,
                "sessionId": session,
                "workflow": "no-such-workflow",
            }),
        );
        assert_eq!(created["error"]["code"], -32060, "{created}");
        let listed = client.request(4, "team.list", json!({}));
        let team = listed["result"]["teams"][0]["id"]
            .as_str()
            .unwrap_or_else(|| panic!("no team: {listed}"))
            .to_string();
        let token = injected_token(&server, &session);
        client.reset_read_timeout();
        Self {
            server,
            client,
            cwd,
            team,
            token,
            log,
        }
    }
}

/// A failing `git worktree add` completes a pending `remove: true` and the name
/// becomes usable again (20.6/#7).
#[test]
fn a_failed_worktree_start_completes_a_pending_removal() {
    if skip("a_failed_worktree_start_completes_a_pending_removal") {
        return;
    }
    let real = Command::new("sh")
        .arg("-c")
        .arg("command -v git")
        .output()
        .expect("find git");
    let real = String::from_utf8_lossy(&real.stdout).trim().to_string();
    static FAIL_SEQ: std::sync::atomic::AtomicU64 = std::sync::atomic::AtomicU64::new(0);
    let unique = FAIL_SEQ.fetch_add(1, std::sync::atomic::Ordering::Relaxed);
    let wrapper =
        std::env::temp_dir().join(format!("ade-fail-git-{}-{unique}", std::process::id()));
    std::fs::create_dir_all(&wrapper).expect("wrapper dir");
    let script = wrapper.join("git");
    // Only `worktree add` fails; everything else runs the real git.
    std::fs::write(
        &script,
        format!(
            "#!/bin/sh\ncase \"$*\" in\n  *\"worktree add\"*) echo 'boom' >&2 ; exit 1 ;;\nesac\nexec {real} \"$@\"\n"
        ),
    )
    .expect("fake git");
    std::fs::set_permissions(&script, std::os::unix::fs::PermissionsExt::from_mode(0o755))
        .expect("chmod");
    let path = format!(
        "{}:{}",
        wrapper.display(),
        std::env::var("PATH").unwrap_or_default()
    );
    let mut harness = Harness::with_worktree_env("wt-fail-remove", &[("PATH", &path)], |work| {
        init_repo(work);
        work.to_path_buf()
    });
    let mut probe = harness.server.connect();
    let hello = probe.hello(&harness.server.token(), nvim_ade_server::API_VERSION);
    assert!(hello["result"].is_object(), "{hello}");
    let start = std::time::Instant::now();
    probe.send(&json!({
        "jsonrpc": "2.0",
        "id": 40,
        "method": "team.spawn",
        "params": {"team": harness.team, "template": "dev", "name": "w1", "task": "work"},
    }));
    // The participant exists before the worktree job runs; waiting for it keeps
    // this test deterministic when tests run in parallel.
    harness.wait_participant("w1", |_| true);
    // Stop it while git is failing, asking for the removal too.
    let stopped = harness.client.request(
        41,
        "team.stop_worker",
        json!({"team": harness.team, "name": "w1", "remove": true}),
    );
    assert!(stopped["result"].is_object(), "{stopped}");
    let reply = wait_for(
        || loop {
            let value = probe.recv()?;
            if value["id"] == 40 {
                return Some(value);
            }
        },
        "the spawn reply for the failed start",
    );
    assert!(
        reply.get("error").is_some() || reply["result"]["isError"] == json!(true),
        "the failed start is reported: {reply}"
    );
    // The name is free again and the team no longer lists w1 as running.
    wait_for(
        || {
            harness.team()["participants"]
                .as_array()
                .map(|participants| {
                    participants
                        .iter()
                        .all(|participant| participant["name"] != "w1")
                        .then_some(())
                })?
        },
        "w1 removed after the failed start",
    );
    assert!(
        start.elapsed() < Duration::from_secs(20),
        "the removal did not wait for a worker that never started"
    );
    std::fs::remove_file(&script).ok();
}

/// A cancelled-but-still-running worktree job keeps the name taken; a same-name
/// spawn waits for it and the old callback never takes over the new worker
/// (20.6/E).
#[test]
fn a_cancelled_worktree_job_keeps_its_name_until_it_returns() {
    if skip("a_cancelled_worktree_job_keeps_its_name_until_it_returns") {
        return;
    }
    let real = Command::new("sh")
        .arg("-c")
        .arg("command -v git")
        .output()
        .expect("find git");
    let real = String::from_utf8_lossy(&real.stdout).trim().to_string();
    static SLOW_SEQ: std::sync::atomic::AtomicU64 = std::sync::atomic::AtomicU64::new(0);
    let unique = SLOW_SEQ.fetch_add(1, std::sync::atomic::Ordering::Relaxed);
    let wrapper = std::env::temp_dir().join(format!("ade-slow-wt-{}-{unique}", std::process::id()));
    std::fs::create_dir_all(&wrapper).expect("wrapper dir");
    let marker = std::env::temp_dir().join(format!(
        "ade-slow-wt-marker-{}-{unique}",
        std::process::id()
    ));
    let script = wrapper.join("git");
    std::fs::write(
        &script,
        format!(
            "#!/bin/sh\ncase \"$*\" in\n  *\"worktree add\"*) touch \"{}\" ; sleep 1 ;;\nesac\nexec {real} \"$@\"\n",
            marker.display()
        ),
    )
    .expect("fake git");
    std::fs::set_permissions(&script, std::os::unix::fs::PermissionsExt::from_mode(0o755))
        .expect("chmod");
    let path = format!(
        "{}:{}",
        wrapper.display(),
        std::env::var("PATH").unwrap_or_default()
    );
    let mut harness = Harness::with_worktree_env("wt-cancel-name", &[("PATH", &path)], |work| {
        init_repo(work);
        work.to_path_buf()
    });
    let mut probe = harness.server.connect();
    let hello = probe.hello(&harness.server.token(), nvim_ade_server::API_VERSION);
    assert!(hello["result"].is_object(), "{hello}");
    probe.send(&json!({
        "jsonrpc": "2.0",
        "id": 50,
        "method": "team.spawn",
        "params": {"team": harness.team, "template": "dev", "name": "w1", "task": "work"},
    }));
    wait_for(|| marker.exists().then_some(()), "the slow git to start");
    // Cancel (and remove) while git is still running.
    let stopped = harness.client.request(
        51,
        "team.stop_worker",
        json!({"team": harness.team, "name": "w1", "remove": true}),
    );
    assert!(stopped["result"].is_object(), "{stopped}");
    // A same-name spawn right away is refused while the job still runs.
    let again = harness.client.request(
        52,
        "team.spawn",
        json!({"team": harness.team, "template": "dev", "name": "w1", "task": "work again"}),
    );
    assert!(
        again.get("error").is_some() || again["result"]["name"] != json!("w1"),
        "the name is not freed while the job runs: {again}"
    );
    // The cancelled job's callback returns and only cleans up after itself.
    std::fs::remove_file(&marker).ok();
    let reply = wait_for(
        || loop {
            let value = probe.recv()?;
            if value["id"] == 50 {
                return Some(value);
            }
        },
        "the cancelled spawn's reply",
    );
    assert!(reply.get("error").is_some(), "{reply}");
    std::fs::remove_file(&script).ok();
}
