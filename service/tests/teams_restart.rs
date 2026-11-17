#![cfg(unix)]
//! Teams across a real service restart (PROTOCOL.md 18.15).
//!
//! Each test starts `nvim_ade_server` in a temporary directory, builds a team
//! with the scriptable agent, stops the process (graceful shutdown or SIGKILL),
//! starts a new one in the same directory, and checks the suspended team and
//! its resume.

mod common;

use std::io::Write;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::time::{Duration, Instant};

use serde_json::{json, Value};

use common::{Client, TempDir, TestServer};

const WAIT: Duration = Duration::from_secs(30);

fn fixture(name: &str) -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("tests")
        .join("fixtures")
        .join(name)
}

fn git_available() -> bool {
    std::process::Command::new("git")
        .arg("--version")
        .stdout(std::process::Stdio::null())
        .stderr(std::process::Stdio::null())
        .status()
        .map(|status| status.success())
        .unwrap_or(false)
}

fn git(dir: &Path, args: &[&str]) {
    let output = std::process::Command::new("git")
        .arg("-C")
        .arg(dir)
        .args(args)
        .env("GIT_AUTHOR_NAME", "ade test")
        .env("GIT_AUTHOR_EMAIL", "test@example.invalid")
        .env("GIT_COMMITTER_NAME", "ade test")
        .env("GIT_COMMITTER_EMAIL", "test@example.invalid")
        .output()
        .expect("git");
    assert!(
        output.status.success(),
        "git {args:?}: {}",
        String::from_utf8_lossy(&output.stderr)
    );
}

fn init_repo(repo: &Path) {
    git(repo, &["init", "-q"]);
    git(repo, &["config", "user.name", "ade test"]);
    git(repo, &["config", "user.email", "test@example.invalid"]);
    std::fs::write(repo.join("root.txt"), "root\n").expect("file");
    git(repo, &["add", "-A"]);
    git(repo, &["commit", "-q", "-m", "initial"]);
}

fn agent() -> String {
    fixture("team_agent.py").to_string_lossy().to_string()
}

fn child_env(server: &TestServer, log: &Path, gate: &Path) -> Value {
    json!({
        "PATH": std::env::var("PATH").unwrap_or_default(),
        "HOME": server.dir().to_string_lossy(),
        "NVIM_ADE_SERVER_DIR": server.dir().to_string_lossy(),
        "TEAM_AGENT_LOG": log.to_string_lossy(),
        "TEAM_AGENT_GATE": gate.to_string_lossy(),
        "TEAM_AGENT_TEMPLATE": "dev",
    })
}

struct Fixture {
    dir: TempDir,
    work: PathBuf,
    log: PathBuf,
    gate: PathBuf,
}

impl Fixture {
    fn new(label: &str) -> Self {
        let dir = TempDir::new(label);
        let work = dir.path().join("work");
        std::fs::create_dir_all(&work).expect("work dir");
        let log = dir.path().join("team-agent.log");
        let gate = dir.path().join("team-agent.gate");
        Self {
            dir,
            work,
            log,
            gate,
        }
    }

    fn start(&self, label: &str, env: &[(&str, &str)]) -> TestServer {
        self.start_with(label, env, "600")
    }

    fn start_with(&self, label: &str, env: &[(&str, &str)], idle: &str) -> TestServer {
        TestServer::start_in_dir(self.dir.clone(), label, &["--idle-timeout", idle], env)
    }

    fn config(&self, server: &TestServer, load_session: bool) -> Value {
        let mut env = child_env(server, &self.log, &self.gate);
        env["TEAM_AGENT_LOAD_SESSION"] = json!(if load_session { "1" } else { "0" });
        json!({
            "max_workers": 3,
            "spawn_confirm": { "auto": ["dev"] },
            "limits": { "max_turns_per_task": 30, "max_turns_total": 200 },
            "templates": {
                "dev": {
                    "key": { "agent": "team-test", "command": "python3", "args": [agent()] },
                    "env": env,
                    "role": "Do the task carefully and report."
                }
            }
        })
    }

    fn configure(&self, client: &mut Client, cwd: &Path, server: &TestServer, load: bool) {
        let configured = client.request(
            2,
            "team.configure",
            json!({"cwd": cwd.to_string_lossy(), "config": self.config(server, load)}),
        );
        assert!(configured["result"].is_object(), "configure: {configured}");
    }

    /// Attach a leader and bind it. `existing_session` loads that id (a
    /// resumed leader); otherwise a new session is created.
    fn attach_leader(
        &self,
        server: &TestServer,
        client: &mut Client,
        cwd: &Path,
        existing_session: Option<&str>,
    ) -> (String, String, String, Value) {
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
                "env": child_env(server, &self.log, &self.gate),
            }),
        );
        let instance = attached["result"]["instance"]
            .as_str()
            .unwrap_or_else(|| panic!("attach: {attached}"))
            .to_string();
        tunnel_call(
            client,
            &instance,
            10,
            "initialize",
            json!({"protocolVersion": 1, "clientCapabilities": {}}),
        );
        let leader = client.request(
            3,
            "team.leader_server",
            json!({"instance": instance, "cwd": cwd.to_string_lossy()}),
        );
        let entry = leader["result"]["server"].clone();
        let token_id = leader["result"]["token_id"]
            .as_str()
            .expect("token id")
            .to_string();
        let token = entry["env"][0]["value"]
            .as_str()
            .expect("token")
            .to_string();
        let (method, params) = match existing_session {
            Some(session) => (
                "session/load",
                json!({
                    "sessionId": session,
                    "cwd": cwd.to_string_lossy(),
                    "mcpServers": [entry],
                }),
            ),
            None => (
                "session/new",
                json!({"cwd": cwd.to_string_lossy(), "mcpServers": [entry]}),
            ),
        };
        let session_response = tunnel_call(client, &instance, 11, method, params);
        let session = session_response["result"]["sessionId"]
            .as_str()
            .expect("session id")
            .to_string();
        let bound = client.request(
            4,
            "team.bind_leader",
            json!({"instance": instance, "sessionId": session, "token_id": token_id}),
        );
        (instance, session, token, bound)
    }

    fn connect(&self, server: &TestServer) -> Client {
        let mut client = server.connect();
        let hello = client.hello(&server.token(), nvim_ade_server::API_VERSION);
        assert!(hello["result"].is_object(), "hello: {hello}");
        client
    }

    /// Build the first team: configure, attach the leader, start w1.
    fn first_team(
        &self,
        server: &TestServer,
        client: &mut Client,
        task: &str,
    ) -> (String, String, String) {
        self.configure(client, &self.work, server, true);
        let (_instance, session, _token, bound) =
            self.attach_leader(server, client, &self.work, None);
        let team = bound["result"]["team"]["id"]
            .as_str()
            .unwrap_or_else(|| panic!("bind: {bound}"))
            .to_string();
        let spawned = client.request(
            5,
            "team.spawn",
            json!({"team": team, "template": "dev", "name": "w1", "task": task}),
        );
        assert_eq!(spawned["result"]["name"], "w1", "{spawned}");
        (team.clone(), session, team)
    }

    fn shutdown(server: &mut TestServer) {
        let mut client = server.connect();
        let token = server.token();
        client.hello(&token, nvim_ade_server::API_VERSION);
        let response = client.request(99, "shutdown", json!({}));
        assert!(response.get("result").is_some(), "{response}");
        assert!(server.wait_for_exit(Duration::from_secs(10)).is_some());
    }
}

impl Drop for Fixture {
    fn drop(&mut self) {
        kill_fixture_processes(self.dir.path());
    }
}

fn kill_fixture_processes(dir: &Path) {
    let needle = dir.to_string_lossy().to_string();
    let Ok(entries) = std::fs::read_dir("/proc") else {
        return;
    };
    for entry in entries.flatten() {
        let Ok(pid) = entry.file_name().to_string_lossy().parse::<i32>() else {
            continue;
        };
        let Ok(env) = std::fs::read(format!("/proc/{pid}/environ")) else {
            continue;
        };
        if !String::from_utf8_lossy(&env).contains(&needle) {
            continue;
        }
        let Ok(cmdline) = std::fs::read(format!("/proc/{pid}/cmdline")) else {
            continue;
        };
        let cmdline = String::from_utf8_lossy(&cmdline);
        if cmdline.contains("team_agent.py") || cmdline.contains("nvim_ade_server") {
            unsafe {
                libc::kill(pid, libc::SIGKILL);
            }
        }
    }
}

fn tunnel_call(client: &mut Client, instance: &str, id: i64, method: &str, params: Value) -> Value {
    client.notify(
        "tunnel.send",
        json!({
            "instance": instance,
            "message": {"jsonrpc": "2.0", "id": id, "method": method, "params": params},
        }),
    );
    loop {
        let received = client.next_tunnel_recv(Duration::from_secs(20));
        let message = &received["message"];
        if message.get("id") == Some(&json!(id)) && message.get("method").is_none() {
            return message.clone();
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

fn list(client: &mut Client) -> Value {
    client.request(90, "team.list", json!({}))["result"].clone()
}

fn team_entry(client: &mut Client, id: &str) -> Value {
    list(client)["teams"]
        .as_array()
        .and_then(|teams| teams.iter().find(|team| team["id"] == id).cloned())
        .unwrap_or(Value::Null)
}

fn participant(client: &mut Client, id: &str, name: &str) -> Option<Value> {
    team_entry(client, id)["participants"]
        .as_array()?
        .iter()
        .find(|entry| entry["name"] == name)
        .cloned()
}

fn agent_events(log: &Path) -> Vec<Value> {
    let text = std::fs::read_to_string(log).unwrap_or_default();
    text.lines()
        .filter_map(|line| serde_json::from_str::<Value>(line).ok())
        .collect()
}

fn wait_agent(log: &Path, predicate: impl Fn(&Value) -> bool, label: &str) -> Value {
    wait_for(
        || agent_events(log).into_iter().find(|event| predicate(event)),
        label,
    )
}

fn wait_worker_session(client: &mut Client, team: &str) -> Value {
    wait_for(
        || {
            participant(client, team, "w1").filter(|entry| {
                entry["instance"].as_str().is_some() && entry["sessionId"].as_str().is_some()
            })
        },
        "the worker's session",
    )
}

fn wait_suspended(client: &mut Client, team: &str) -> Value {
    wait_for(
        || {
            let entry = team_entry(client, team);
            (entry["state"] == "suspended").then_some(entry)
        },
        "the suspended team",
    )
}

fn wait_active(client: &mut Client, team: &str) -> Value {
    wait_for(
        || {
            let entry = team_entry(client, team);
            (entry["state"] == "active").then_some(entry)
        },
        "the resumed team",
    )
}

fn leader_texts(client: &mut Client, team: &str) -> Vec<String> {
    let read = client.request(
        91,
        "team.read",
        json!({"team": team, "participant": "leader"}),
    );
    read["result"]["messages"]
        .as_array()
        .map(|messages| {
            messages
                .iter()
                .filter_map(|message| message["body"].as_str().map(str::to_string))
                .collect()
        })
        .unwrap_or_default()
}

fn resume(
    fixture: &Fixture,
    server: &TestServer,
    client: &mut Client,
    team: &str,
    leader_session: &str,
    load: bool,
) -> Value {
    wait_suspended(client, team);
    fixture.configure(client, &fixture.work, server, load);
    let (_instance, session, _token, bound) =
        fixture.attach_leader(server, client, &fixture.work, Some(leader_session));
    assert_eq!(session, leader_session);
    assert_eq!(bound["result"]["team"]["id"], team, "{bound}");
    wait_active(client, team)
}

// ---------------------------------------------------------------------------
// scenarios
// ---------------------------------------------------------------------------

#[test]
fn a_gracefully_stopped_team_comes_back_suspended_and_resumes_with_its_queue() {
    let fixture = Fixture::new("restart-suspend");
    let mut server = fixture.start("a", &[]);
    let mut client = fixture.connect(&server);
    let (team, leader_session, _) = fixture.first_team(&server, &mut client, "do [report]");
    let worker = wait_worker_session(&mut client, &team);
    let worker_session = worker["sessionId"].as_str().unwrap().to_string();
    wait_for(
        || (participant(&mut client, &team, "w1")?["state"] == "idle").then_some(()),
        "the worker to be idle",
    );
    // Pause, then queue: no bus turn is in flight at the restart.
    let paused = client.request(
        6,
        "team.send",
        json!({"team": team, "to": "w1", "kind": "control", "body": "pause"}),
    );
    assert!(paused["result"].is_object(), "{paused}");
    let queued = client.request(
        7,
        "team.send",
        json!({"team": team, "to": "w1", "kind": "task", "body": "queued work [report]"}),
    );
    assert!(queued["result"].is_object(), "{queued}");
    let before = team_entry(&mut client, &team);
    assert_eq!(
        participant(&mut client, &team, "w1").unwrap()["queued"],
        1,
        "{before}"
    );
    Fixture::shutdown(&mut server);
    drop(server);
    let mut restarted = fixture.start("b", &[]);
    let mut second = fixture.connect(&restarted);
    let entry = wait_suspended(&mut second, &team);
    assert!(entry["suspended_at"].as_u64().is_some(), "{entry}");
    assert!(entry["leader"]["instance"].is_null(), "{entry}");
    assert_eq!(entry["leader"]["sessionId"], leader_session, "{entry}");
    let worker = participant(&mut second, &team, "w1").expect("worker");
    assert!(worker["instance"].is_null(), "{worker}");
    assert_eq!(worker["sessionId"], worker_session, "{worker}");
    assert_eq!(worker["queued"], 1, "{worker}");
    assert_eq!(worker["paused"], true, "{worker}");

    resume(
        &fixture,
        &restarted,
        &mut second,
        &team,
        &leader_session,
        true,
    );
    wait_worker_session(&mut second, &team);
    let resumed_queue = second.request(
        96,
        "team.send",
        json!({"team": team, "to": "w1", "kind": "control", "body": "resume"}),
    );
    assert!(resumed_queue["result"].is_object(), "{resumed_queue}");
    let loaded = wait_agent(
        &fixture.log,
        |event| {
            event["event"] == "session"
                && event["method"] == "session/load"
                && event["session"] == worker_session
        },
        "the worker's session/load",
    );
    assert_eq!(loaded["session"], worker_session);
    wait_agent(
        &fixture.log,
        |event| {
            event["event"] == "prompt"
                && event["text"]
                    .as_str()
                    .is_some_and(|text| text.contains("queued work"))
        },
        "the queued message after resume",
    );
    wait_for(
        || {
            let texts = leader_texts(&mut second, &team);
            texts
                .iter()
                .any(|text| text.contains("team resumed after a service restart"))
                .then_some(())
        },
        "the resume notice",
    );
    // The worker's new participant token really drives its MCP tool.
    wait_for(
        || {
            let texts = leader_texts(&mut second, &team);
            texts
                .iter()
                .any(|text| text.contains("worker report"))
                .then_some(())
        },
        "the worker's report through its new token",
    );
    let resumed = wait_active(&mut second, &team);
    assert!(
        resumed["participants"]
            .as_array()
            .is_some_and(|items| items.iter().all(|item| item["instance"].as_str().is_some())),
        "{resumed}"
    );
    let closed = second.request(92, "team.close", json!({"team": team}));
    assert!(closed["result"].is_object(), "{closed}");
    Fixture::shutdown(&mut restarted);
}

#[test]
fn a_sigkilled_team_reports_its_inflight_turn_and_delivers_nothing_twice() {
    let fixture = Fixture::new("restart-sigkill");
    let mut server = fixture.start("a", &[]);
    let mut client = fixture.connect(&server);
    let (team, leader_session, _) = fixture.first_team(&server, &mut client, "do [slow]");
    let worker = wait_for(
        || participant(&mut client, &team, "w1").filter(|entry| entry["state"] == "working"),
        "the running worker",
    );
    let worker_session = worker["sessionId"].as_str().unwrap().to_string();
    let queued = client.request(
        8,
        "team.send",
        json!({"team": team, "to": "w1", "kind": "task", "body": "extra work"}),
    );
    assert!(queued["result"].is_object(), "{queued}");
    wait_agent(
        &fixture.log,
        |event| {
            event["event"] == "prompt"
                && event["text"]
                    .as_str()
                    .is_some_and(|text| text.contains("do [slow]"))
        },
        "the in-flight worker prompt",
    );
    // Wait until the store has the delivery (queue entry + bus_turn), then
    // kill; no wall-clock sleep decides whether the state is durable.
    let db = fixture.dir.path().join("nvim_ade_server.events.sqlite3");
    wait_for(
        || {
            let conn = rusqlite::Connection::open(&db).ok()?;
            let json: String = conn
                .query_row(
                    "SELECT state_json FROM teams WHERE id = ?1",
                    rusqlite::params![team],
                    |row| row.get(0),
                )
                .ok()?;
            let value: Value = serde_json::from_str(&json).ok()?;
            let worker = value["participants"]
                .as_array()?
                .iter()
                .find(|entry| entry["name"] == "w1")?;
            let queued = worker["mailbox"].as_array().is_some_and(|messages| {
                messages
                    .iter()
                    .any(|message| message["body"] == "extra work")
            });
            (worker["bus_turn"] == true && queued).then_some(())
        },
        "the delivery to be durable before SIGKILL",
    );
    server.kill();
    drop(server);
    kill_fixture_processes(fixture.dir.path());

    let mut restarted = fixture.start("b", &[]);
    let mut second = fixture.connect(&restarted);
    let suspended = wait_suspended(&mut second, &team);
    assert!(suspended["suspended_at"].as_u64().is_some());
    resume(
        &fixture,
        &restarted,
        &mut second,
        &team,
        &leader_session,
        true,
    );
    wait_worker_session(&mut second, &team);
    wait_for(
        || {
            let texts = leader_texts(&mut second, &team);
            texts
                .iter()
                .any(|text| text.contains("turn ended: error: the service restarted"))
                .then_some(())
        },
        "the interrupted-turn notice",
    );
    wait_agent(
        &fixture.log,
        |event| {
            event["event"] == "prompt"
                && event["text"]
                    .as_str()
                    .is_some_and(|text| text.contains("extra work"))
        },
        "the queued message after resume",
    );
    // The in-flight task is not delivered a second time.
    let runs = agent_events(&fixture.log)
        .into_iter()
        .filter(|event| {
            event["event"] == "prompt"
                && event["text"]
                    .as_str()
                    .is_some_and(|text| text.contains("do [slow]"))
        })
        .count();
    assert_eq!(runs, 1, "the in-flight prompt must not be re-delivered");
    assert_eq!(
        participant(&mut second, &team, "w1").unwrap()["sessionId"],
        worker_session
    );
    let closed = second.request(93, "team.close", json!({"team": team}));
    assert!(closed["result"].is_object(), "{closed}");
    Fixture::shutdown(&mut restarted);
}

#[test]
fn an_agent_without_load_session_restarts_the_worker_with_a_new_session() {
    let fixture = Fixture::new("restart-no-load");
    let mut server = fixture.start("a", &[]);
    let mut client = fixture.connect(&server);
    let (team, leader_session, _) = fixture.first_team(&server, &mut client, "do [report]");
    let worker_session = wait_worker_session(&mut client, &team)["sessionId"]
        .as_str()
        .unwrap()
        .to_string();
    Fixture::shutdown(&mut server);
    drop(server);

    let mut restarted = fixture.start("b", &[]);
    let mut second = fixture.connect(&restarted);
    wait_suspended(&mut second, &team);
    resume(
        &fixture,
        &restarted,
        &mut second,
        &team,
        &leader_session,
        false,
    );
    wait_for(
        || {
            participant(&mut second, &team, "w1").filter(|entry| {
                entry["instance"].as_str().is_some()
                    && entry["sessionId"].as_str() != Some(worker_session.as_str())
            })
        },
        "the worker's new session",
    );
    let started = wait_agent(
        &fixture.log,
        |event| {
            event["event"] == "session"
                && event["method"] == "session/new"
                && event["pid"].as_u64().is_some_and(|pid| pid != 0)
                && event["cwd"]
                    .as_str()
                    .is_some_and(|cwd| cwd.contains("restart-no-load"))
        },
        "the restarted worker's session/new",
    );
    assert_eq!(started["method"], "session/new");
    wait_for(
        || {
            let texts = leader_texts(&mut second, &team);
            texts
                .iter()
                .any(|text| text.contains("restarted without its history"))
                .then_some(())
        },
        "the no-history notice",
    );
    let closed = second.request(94, "team.close", json!({"team": team}));
    assert!(closed["result"].is_object(), "{closed}");
    Fixture::shutdown(&mut restarted);
}

#[test]
fn a_different_session_is_refused_and_close_removes_the_stored_team() {
    let fixture = Fixture::new("restart-other-session");
    let mut server = fixture.start("a", &[]);
    let mut client = fixture.connect(&server);
    let (team, _leader_session, _) = fixture.first_team(&server, &mut client, "do [ask]");
    let question = wait_for(
        || {
            team_entry(&mut client, &team)["inbox"]
                .as_array()?
                .iter()
                .find(|item| item["kind"] == "question" && item["state"] == "open")
                .cloned()
        },
        "the worker's question",
    );
    Fixture::shutdown(&mut server);
    drop(server);

    let mut restarted = fixture.start("b", &[]);
    let mut second = fixture.connect(&restarted);
    wait_suspended(&mut second, &team);
    let answered = second.request(
        97,
        "team.answer",
        json!({"request": question["id"], "text": "yes"}),
    );
    assert!(answered["result"].is_object(), "{answered}");
    let watched = second.request(98, "team.watch", json!({"team": team, "participant": "w1"}));
    assert_eq!(watched["error"]["code"], -32064, "{watched}");
    let spawned = second.request(
        99,
        "team.spawn",
        json!({"team": team, "template": "dev", "name": "w2"}),
    );
    assert_eq!(spawned["error"]["code"], -32064, "{spawned}");
    fixture.configure(&mut second, &fixture.work, &restarted, true);
    let (_instance, _session, _token, bound) =
        fixture.attach_leader(&restarted, &mut second, &fixture.work, None);
    assert_eq!(bound["error"]["code"], -32061, "{bound}");
    assert_eq!(team_entry(&mut second, &team)["state"], "suspended");
    let closed = second.request(95, "team.close", json!({"team": team}));
    assert!(closed["result"].is_object(), "{closed}");
    assert!(team_entry(&mut second, &team).is_null());
    // A new team in the same cwd does not reuse the closed id.
    let (_instance, _session, _token, next) =
        fixture.attach_leader(&restarted, &mut second, &fixture.work, None);
    let second_team = next["result"]["team"]["id"]
        .as_str()
        .expect("second team")
        .to_string();
    assert_ne!(second_team, team, "{next}");
    let closed = second.request(96, "team.close", json!({"team": second_team}));
    assert!(closed["result"].is_object(), "{closed}");
    Fixture::shutdown(&mut restarted);
    drop(restarted);

    // The stored rows are gone: a third start lists no team, and a new team
    // still continues after the highest id ever stored.
    let mut third = fixture.start("c", &[]);
    let mut last = fixture.connect(&third);
    assert!(
        list(&mut last)["teams"]
            .as_array()
            .is_none_or(|teams| teams.is_empty()),
        "{:?}",
        list(&mut last)
    );
    fixture.configure(&mut last, &fixture.work, &third, true);
    let (_instance, _session, _token, bound) =
        fixture.attach_leader(&third, &mut last, &fixture.work, None);
    let third_team = bound["result"]["team"]["id"].as_str().expect("third team");
    assert_ne!(third_team, team);
    assert_ne!(third_team, second_team);
    Fixture::shutdown(&mut third);
}

#[test]
fn a_missing_worktree_marks_the_worker_exited_on_resume() {
    if !git_available() {
        eprintln!("SKIP: git is not available (missing worktree)");
        return;
    }
    let fixture = Fixture::new("restart-worktree-missing");
    init_repo(&fixture.work);
    let root = fixture.dir.path().join("worktrees");
    let mut server = fixture.start("a", &[]);
    let mut client = fixture.connect(&server);
    let mut config = fixture.config(&server, true);
    config["worktree_root"] = json!(root.to_string_lossy());
    config["templates"]["dev"]["worktree"] = json!(true);
    let configured = client.request(
        2,
        "team.configure",
        json!({"cwd": fixture.work.to_string_lossy(), "config": config}),
    );
    assert!(configured["result"].is_object(), "{configured}");
    let (_instance, leader_session, _token, bound) =
        fixture.attach_leader(&server, &mut client, &fixture.work, None);
    let team = bound["result"]["team"]["id"].as_str().unwrap().to_string();
    let spawned = client.request(
        5,
        "team.spawn",
        json!({"team": team, "template": "dev", "name": "w1", "task": "work"}),
    );
    assert_eq!(spawned["result"]["name"], "w1", "{spawned}");
    let path = wait_for(
        || {
            participant(&mut client, &team, "w1")?["worktree"]["path"]
                .as_str()
                .map(PathBuf::from)
        },
        "the worker's worktree",
    );
    Fixture::shutdown(&mut server);
    drop(server);
    std::fs::remove_dir_all(&path).expect("delete the worktree");

    let mut restarted = fixture.start("b", &[]);
    let mut second = fixture.connect(&restarted);
    resume(
        &fixture,
        &restarted,
        &mut second,
        &team,
        &leader_session,
        true,
    );
    let exited = wait_for(
        || participant(&mut second, &team, "w1").filter(|entry| entry["state"] == "exited"),
        "the worker with the missing worktree",
    );
    assert!(
        exited["reason"]
            .as_str()
            .is_some_and(|reason| reason.contains("worktree")),
        "{exited}"
    );
    wait_for(
        || {
            let texts = leader_texts(&mut second, &team);
            texts
                .iter()
                .any(|text| text.contains("not resumed") && text.contains("w1"))
                .then_some(())
        },
        "the not-resumed notice",
    );
    let closed = second.request(93, "team.close", json!({"team": team}));
    assert!(closed["result"].is_object(), "{closed}");
    Fixture::shutdown(&mut restarted);
}

#[test]
fn an_exited_worker_is_not_resurrected_by_a_restart() {
    let fixture = Fixture::new("restart-exited");
    let mut server = fixture.start("a", &[]);
    let mut client = fixture.connect(&server);
    let (team, leader_session, _) = fixture.first_team(&server, &mut client, "do [report]");
    let worker = wait_worker_session(&mut client, &team);
    let worker_session = worker["sessionId"].as_str().unwrap().to_string();
    let instance = worker["instance"].as_str().unwrap().to_string();
    let stopped = client.request(
        10,
        "agent.stop",
        json!({"instance": instance, "force": true}),
    );
    assert!(stopped["result"].is_object(), "{stopped}");
    let exited = wait_for(
        || participant(&mut client, &team, "w1").filter(|entry| entry["state"] == "exited"),
        "the exited worker",
    );
    let reason = exited["reason"].as_str().unwrap().to_string();
    Fixture::shutdown(&mut server);
    drop(server);
    let mut restarted = fixture.start("b", &[]);
    let mut second = fixture.connect(&restarted);
    resume(
        &fixture,
        &restarted,
        &mut second,
        &team,
        &leader_session,
        true,
    );
    wait_active(&mut second, &team);
    let worker = participant(&mut second, &team, "w1").expect("worker");
    assert_eq!(worker["state"], "exited", "{worker}");
    assert_eq!(worker["reason"], reason, "{worker}");
    assert!(worker["instance"].is_null(), "{worker}");
    // No session was loaded for the exited worker.
    std::thread::sleep(Duration::from_millis(200));
    let loads = agent_events(&fixture.log)
        .into_iter()
        .filter(|event| {
            event["event"] == "session"
                && event["session"] == worker_session
                && event["method"] == "session/load"
        })
        .count();
    assert_eq!(loads, 0, "the exited worker must not be started again");
    let closed = second.request(97, "team.close", json!({"team": team}));
    assert!(closed["result"].is_object(), "{closed}");
    Fixture::shutdown(&mut restarted);
}

#[test]
fn a_removed_worktree_keeps_the_worker_exited_on_resume() {
    if !git_available() {
        eprintln!("SKIP: git is not available (removed worktree)");
        return;
    }
    let fixture = Fixture::new("restart-worktree-removed");
    init_repo(&fixture.work);
    let root = fixture.dir.path().join("worktrees");
    let mut server = fixture.start("a", &[]);
    let mut client = fixture.connect(&server);
    let mut config = fixture.config(&server, true);
    config["worktree_root"] = json!(root.to_string_lossy());
    config["templates"]["dev"]["worktree"] = json!(true);
    let configured = client.request(
        2,
        "team.configure",
        json!({"cwd": fixture.work.to_string_lossy(), "config": config}),
    );
    assert!(configured["result"].is_object(), "{configured}");
    let (_instance, leader_session, _token, bound) =
        fixture.attach_leader(&server, &mut client, &fixture.work, None);
    let team = bound["result"]["team"]["id"].as_str().unwrap().to_string();
    let spawned = client.request(
        5,
        "team.spawn",
        json!({"team": team, "template": "dev", "name": "w1", "task": "work"}),
    );
    assert_eq!(spawned["result"]["name"], "w1", "{spawned}");
    wait_for(
        || {
            participant(&mut client, &team, "w1")?["worktree"]
                .as_object()
                .map(|_| ())
        },
        "the worker's worktree",
    );
    Fixture::shutdown(&mut server);
    drop(server);

    let mut restarted = fixture.start("b", &[]);
    let mut second = fixture.connect(&restarted);
    wait_suspended(&mut second, &team);
    let removed = second.request(
        98,
        "team.remove_worktree",
        json!({"team": team, "participant": "w1", "force": true}),
    );
    assert_eq!(removed["result"]["removed"], true, "{removed}");
    let mut resume_config = fixture.config(&restarted, true);
    resume_config["worktree_root"] = json!(root.to_string_lossy());
    resume_config["templates"]["dev"]["worktree"] = json!(true);
    let configured = second.request(
        99,
        "team.configure",
        json!({"cwd": fixture.work.to_string_lossy(), "config": resume_config}),
    );
    assert!(configured["result"].is_object(), "{configured}");
    let (_instance, _session, _token, bound) = fixture.attach_leader(
        &restarted,
        &mut second,
        &fixture.work,
        Some(&leader_session),
    );
    assert!(bound["result"]["team"].is_object(), "{bound}");
    let worker = wait_for(
        || participant(&mut second, &team, "w1").filter(|entry| entry["state"] == "exited"),
        "the worker with the removed worktree",
    );
    assert!(
        worker["reason"]
            .as_str()
            .is_some_and(|reason| reason.contains("worktree removed")),
        "{worker}"
    );
    let closed = second.request(100, "team.close", json!({"team": team}));
    assert!(closed["result"].is_object(), "{closed}");
    Fixture::shutdown(&mut restarted);
}

#[test]
fn a_failed_session_load_falls_back_and_resends_the_role_card() {
    let fixture = Fixture::new("restart-load-fail");
    let mut server = fixture.start("a", &[]);
    let mut client = fixture.connect(&server);
    let (team, leader_session, _) = fixture.first_team(&server, &mut client, "do [report]");
    let worker_session = wait_worker_session(&mut client, &team)["sessionId"]
        .as_str()
        .unwrap()
        .to_string();
    Fixture::shutdown(&mut server);
    drop(server);

    let mut restarted = fixture.start("b", &[]);
    let mut second = fixture.connect(&restarted);
    wait_suspended(&mut second, &team);
    let mut config = fixture.config(&restarted, true);
    config["templates"]["dev"]["env"]["TEAM_AGENT_LOAD_FAIL"] = json!("1");
    let configured = second.request(
        101,
        "team.configure",
        json!({"cwd": fixture.work.to_string_lossy(), "config": config}),
    );
    assert!(configured["result"].is_object(), "{configured}");
    let (_instance, _session, _token, bound) = fixture.attach_leader(
        &restarted,
        &mut second,
        &fixture.work,
        Some(&leader_session),
    );
    assert!(bound["result"]["team"].is_object(), "{bound}");
    let entry = wait_for(
        || {
            participant(&mut second, &team, "w1").filter(|entry| {
                entry["instance"].as_str().is_some()
                    && entry["sessionId"].as_str() != Some(worker_session.as_str())
            })
        },
        "the worker's fallback session",
    );
    assert_ne!(entry["sessionId"], worker_session, "{entry}");
    wait_agent(
        &fixture.log,
        |event| event["event"] == "load-failed" && event["session"] == worker_session,
        "the failed session/load",
    );
    wait_for(
        || {
            let texts = leader_texts(&mut second, &team);
            texts
                .iter()
                .any(|text| text.contains("restarted without its history"))
                .then_some(())
        },
        "the no-history notice",
    );
    // The next prompt carries the role card again.
    let queued = second.request(
        102,
        "team.send",
        json!({"team": team, "to": "w1", "kind": "task", "body": "after fallback [report]"}),
    );
    assert!(queued["result"].is_object(), "{queued}");
    // The role card must be sent again, not merely be present in the log from
    // the first run.
    wait_for(
        || {
            let cards = agent_events(&fixture.log)
                .into_iter()
                .filter(|event| {
                    event["event"] == "prompt"
                        && event["text"]
                            .as_str()
                            .is_some_and(|text| text.contains("You are w1"))
                })
                .count();
            (cards >= 2).then_some(())
        },
        "the re-sent role card",
    );
    wait_agent(
        &fixture.log,
        |event| {
            event["event"] == "prompt"
                && event["text"]
                    .as_str()
                    .is_some_and(|text| text.contains("after fallback"))
        },
        "the task after the fallback",
    );
    let closed = second.request(103, "team.close", json!({"team": team}));
    assert!(closed["result"].is_object(), "{closed}");
    Fixture::shutdown(&mut restarted);
}

#[test]
fn configure_after_bind_starts_the_resume() {
    let fixture = Fixture::new("restart-configure-late");
    let mut server = fixture.start("a", &[]);
    let mut client = fixture.connect(&server);
    let (team, leader_session, _) = fixture.first_team(&server, &mut client, "do [report]");
    Fixture::shutdown(&mut server);
    drop(server);

    let mut restarted = fixture.start("b", &[]);
    let mut second = fixture.connect(&restarted);
    wait_suspended(&mut second, &team);
    // Bind before any configure: the team stays suspended and gets the token.
    let (_instance, _session, _token, bound) = fixture.attach_leader(
        &restarted,
        &mut second,
        &fixture.work,
        Some(&leader_session),
    );
    assert_eq!(bound["result"]["team"]["state"], "suspended", "{bound}");
    assert_eq!((&team_entry(&mut second, &team))["state"], "suspended");
    fixture.configure(&mut second, &fixture.work, &restarted, true);
    wait_active(&mut second, &team);
    wait_worker_session(&mut second, &team);
    let closed = second.request(104, "team.close", json!({"team": team}));
    assert!(closed["result"].is_object(), "{closed}");
    Fixture::shutdown(&mut restarted);
}

#[test]
fn configure_does_not_resume_after_the_bound_instance_exited() {
    let fixture = Fixture::new("restart-instance-gone");
    let mut server = fixture.start("a", &[]);
    let mut client = fixture.connect(&server);
    let (team, leader_session, _) = fixture.first_team(&server, &mut client, "do [report]");
    Fixture::shutdown(&mut server);
    drop(server);

    let mut restarted = fixture.start("b", &[]);
    let mut second = fixture.connect(&restarted);
    wait_suspended(&mut second, &team);
    let (instance, _session, _token, bound) = fixture.attach_leader(
        &restarted,
        &mut second,
        &fixture.work,
        Some(&leader_session),
    );
    assert_eq!(bound["result"]["team"]["state"], "suspended", "{bound}");
    let stopped = second.request(
        105,
        "agent.stop",
        json!({"instance": instance, "force": true}),
    );
    assert!(stopped["result"].is_object(), "{stopped}");
    std::thread::sleep(Duration::from_millis(100));
    fixture.configure(&mut second, &fixture.work, &restarted, true);
    std::thread::sleep(Duration::from_millis(200));
    assert_eq!(team_entry(&mut second, &team)["state"], "suspended");
    let closed = second.request(106, "team.close", json!({"team": team}));
    assert!(closed["result"].is_object(), "{closed}");
    Fixture::shutdown(&mut restarted);
}

#[test]
fn only_suspended_teams_do_not_block_idle_exit() {
    let fixture = Fixture::new("restart-idle");
    let mut server = fixture.start("a", &[]);
    let mut client = fixture.connect(&server);
    let (team, _leader_session, _) = fixture.first_team(&server, &mut client, "do [report]");
    let _ = team;
    Fixture::shutdown(&mut server);
    drop(server);

    // Restart with a one-second idle timeout and do not connect: the suspended
    // team must not keep the service alive.
    let mut restarted = fixture.start_with("b", &[], "1");
    assert!(
        restarted.wait_for_exit(Duration::from_secs(15)).is_some(),
        "a suspended-only service exits on idle"
    );
}

#[test]
fn a_suspended_team_expires_after_the_configured_ttl() {
    let fixture = Fixture::new("restart-expiry");
    let mut server = fixture.start("a", &[]);
    let mut client = fixture.connect(&server);
    let (team, _leader_session, _) = fixture.first_team(&server, &mut client, "do [report]");
    Fixture::shutdown(&mut server);
    drop(server);

    // First restart records suspended_at and writes it back.
    let mut second = fixture.start("b", &[("NVIM_ADE_SERVER_TEAM_TTL_MS", "600000")]);
    let mut client = fixture.connect(&second);
    wait_suspended(&mut client, &team);
    std::thread::sleep(Duration::from_millis(10));
    Fixture::shutdown(&mut second);
    drop(second);

    // Second restart sees an old suspended_at and deletes the team.
    let mut third = fixture.start("c", &[("NVIM_ADE_SERVER_TEAM_TTL_MS", "1")]);
    let mut last = fixture.connect(&third);
    wait_for(
        || {
            let entry = team_entry(&mut last, &team);
            entry.is_null().then_some(())
        },
        "the expired team",
    );
    Fixture::shutdown(&mut third);
}

fn mcp_call(server: &TestServer, token: &str, tool: &str, arguments: Value) -> Value {
    let mut child = Command::new(common::BINARY)
        .arg("mcp")
        .env("ADE_TEAM_TOKEN", token)
        .env("NVIM_ADE_SERVER_DIR", server.dir())
        .env("HOME", server.dir())
        .env("PATH", std::env::var("PATH").unwrap_or_default())
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .expect("spawn mcp");
    {
        let stdin = child.stdin.as_mut().expect("stdin");
        for frame in [
            json!({"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"test"}}}),
            json!({"jsonrpc":"2.0","method":"notifications/initialized"}),
            json!({"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":tool,"arguments":arguments}}),
        ] {
            writeln!(stdin, "{}", frame).expect("write mcp frame");
        }
    }
    drop(child.stdin.take());
    let output = child.wait_with_output().expect("mcp exits on stdin EOF");
    let stdout = String::from_utf8_lossy(&output.stdout);
    for line in stdout.lines() {
        let Ok(value) = serde_json::from_str::<Value>(line) else {
            continue;
        };
        if value.get("id") == Some(&json!(2)) {
            return value
                .get("result")
                .cloned()
                .unwrap_or_else(|| value.clone());
        }
    }
    panic!(
        "no MCP response: stdout={stdout}\nstderr={}",
        String::from_utf8_lossy(&output.stderr)
    )
}

#[test]
fn a_saved_workflow_outlives_the_team_and_a_suspended_team_refuses_to_start() {
    let fixture = Fixture::new("restart-workflow");
    let mut server = fixture.start("restart-workflow-1", &[]);
    let mut client = fixture.connect(&server);
    fixture.configure(&mut client, &fixture.work, &server, true);
    let (_instance, _session, token, bound) =
        fixture.attach_leader(&server, &mut client, &fixture.work, None);
    let team = bound["result"]["team"]["id"]
        .as_str()
        .unwrap_or_else(|| panic!("bind: {bound}"))
        .to_string();
    let saved = mcp_call(
        &server,
        &token,
        "workflow_save",
        json!({"workflow": {
            "name": "saved_flow",
            "summary": "outlives the team",
            "text": "the flow",
            "team": [{"name": "w9", "template": "dev"}],
        }}),
    );
    assert_eq!(saved["isError"], false, "{saved}");
    let text = saved["content"][0]["text"].as_str().unwrap_or_default();
    let saved: Value = serde_json::from_str(text).expect("workflow_save JSON");
    assert_eq!(saved["name"], "saved_flow");
    Fixture::shutdown(&mut server);

    let mut restarted = fixture.start("restart-workflow-2", &[]);
    let mut client = fixture.connect(&restarted);
    let listed = client.request(2, "team.list", json!({}));
    let suspended = listed["result"]["teams"]
        .as_array()
        .and_then(|teams| teams.iter().find(|entry| entry["id"] == team.as_str()))
        .cloned()
        .expect("the suspended team survived");
    assert_eq!(suspended["state"], "suspended");
    let started = client.request(
        3,
        "team.start",
        json!({"team": team, "workflow": "saved_flow"}),
    );
    assert_eq!(started["error"]["code"], -32061, "{started}");

    let workflows = client.request(
        4,
        "team.workflows",
        json!({"cwd": fixture.work.to_string_lossy()}),
    );
    let names: Vec<(String, String)> = workflows["result"]["workflows"]
        .as_array()
        .expect("workflows")
        .iter()
        .map(|workflow| {
            (
                workflow["name"].as_str().unwrap_or_default().to_string(),
                workflow["scope"].as_str().unwrap_or_default().to_string(),
            )
        })
        .collect();
    assert!(
        names.contains(&("saved_flow".to_string(), "project".to_string())),
        "{names:?}"
    );
    assert!(
        names.contains(&("default".to_string(), "builtin".to_string())),
        "{names:?}"
    );
    Fixture::shutdown(&mut restarted);
}
