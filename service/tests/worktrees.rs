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

use common::{Client, TestServer};

const WAIT: Duration = Duration::from_secs(30);

fn fixture(name: &str) -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("tests")
        .join("fixtures")
        .join(name)
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
    })
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
            "#!/bin/sh\ncase \"$*\" in\n  *\"worktree add\"*) sleep 1 ;;\nesac\nexec {real} \"$@\"\n"
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
        elapsed < Duration::from_millis(700),
        "team.list took {elapsed:?} while git slept; the hub must not block"
    );
    spawn.join().expect("spawn thread");
    harness.wait_participant("w1", |entry| entry["worktree"].is_object());

    // A timeout is -32066 with the git output.
    let slow = wrapper.join("git");
    std::fs::write(
        &slow,
        format!(
            "#!/bin/sh\ncase \"$*\" in\n  *\"worktree add\"*) sleep 5 ;;\nesac\nexec {real} \"$@\"\n"
        ),
    )
    .expect("fake git");
    let timed = Harness::with_worktree_env(
        "wt-timeout",
        &[("PATH", &path), ("NVIM_ADE_SERVER_GIT_TIMEOUT_MS", "200")],
        |work| {
            init_repo(work);
            work.to_path_buf()
        },
    );
    let spawned = timed.spawn("w1", "work");
    assert_eq!(spawned["isError"], true, "{spawned}");
    assert!(
        mcp_text(&spawned).contains("git worktree add failed"),
        "{}",
        mcp_text(&spawned)
    );
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
        Self::new_with_setup(label, env, setup, true, true)
    }

    fn with_worktree_manual(label: &str, setup: impl FnOnce(&Path) -> PathBuf) -> Self {
        Self::new_with_setup(label, &[], setup, true, false)
    }

    fn new_with_setup(
        label: &str,
        env: &[(&str, &str)],
        setup: impl FnOnce(&Path) -> PathBuf,
        worktree: bool,
        auto_spawn: bool,
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
            config["worktree_root"] = json!(server.dir().join("worktrees").to_string_lossy());
        }
        let configured = client.request(
            2,
            "team.configure",
            json!({ "cwd": cwd.to_string_lossy(), "config": config }),
        );
        assert!(configured["result"].is_object(), "configure: {configured}");
        let leader = client.request(
            3,
            "team.leader_server",
            json!({ "instance": instance, "cwd": cwd.to_string_lossy() }),
        );
        let server_entry = leader["result"]["server"].clone();
        let token_id = leader["result"]["token_id"]
            .as_str()
            .expect("token id")
            .to_string();
        let token = server_entry["env"][0]["value"]
            .as_str()
            .expect("token")
            .to_string();
        let session_response = tunnel_call(
            &mut client,
            &instance,
            11,
            "session/new",
            json!({ "cwd": cwd.to_string_lossy(), "mcpServers": [server_entry] }),
        );
        let session = session_response["result"]["sessionId"]
            .as_str()
            .expect("session id")
            .to_string();
        let bound = client.request(
            4,
            "team.bind_leader",
            json!({ "instance": instance, "sessionId": session, "token_id": token_id }),
        );
        let team = bound["result"]["team"]["id"]
            .as_str()
            .unwrap_or_else(|| panic!("bind: {bound}"))
            .to_string();
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
