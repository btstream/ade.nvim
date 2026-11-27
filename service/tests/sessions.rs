#![cfg(unix)]
//! Integration tests for the cross-agent session catalog (PROTOCOL.md 21).
//!
//! The real service binary talks to `tests/fixtures/catalog_agent.py`, a
//! scriptable ACP agent that lists sessions, fails in controlled ways or sends
//! client requests. Every test uses a private temporary directory.

mod common;

use std::path::{Path, PathBuf};
use std::time::{Duration, Instant};

use serde_json::{json, Value};

use common::{Client, TestServer};

const WAIT: Duration = Duration::from_secs(20);

fn fixture(name: &str) -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("tests")
        .join("fixtures")
        .join(name)
}

fn agent_script() -> String {
    fixture("catalog_agent.py").to_string_lossy().to_string()
}

fn merge(base: &mut Value, extra: Value) {
    if let (Value::Object(base), Value::Object(extra)) = (base, extra) {
        for (key, value) in extra {
            base.insert(key, value);
        }
    }
}

fn wait_for<T>(mut probe: impl FnMut() -> Option<T>, what: &str) -> T {
    let deadline = Instant::now() + WAIT;
    loop {
        if let Some(value) = probe() {
            return value;
        }
        if Instant::now() >= deadline {
            panic!("timed out waiting for {what}");
        }
        std::thread::sleep(Duration::from_millis(20));
    }
}

struct Server {
    server: TestServer,
    client: Client,
    log: PathBuf,
    work: PathBuf,
}

impl Server {
    fn new(label: &str) -> Self {
        Self::with_env(label, &[], &[])
    }

    fn with_env(label: &str, args: &[&str], env: &[(&str, &str)]) -> Self {
        let server = if args.is_empty() && env.is_empty() {
            TestServer::start(label)
        } else {
            TestServer::start_with(label, args, env)
        };
        let work = server.dir().join("work");
        std::fs::create_dir_all(&work).expect("work dir");
        let log = server.dir().join("catalog-agent.log");
        let mut client = server.connect();
        let hello = client.hello(&server.token(), nvim_ade_server::API_VERSION);
        assert!(hello["result"].is_object(), "hello: {hello}");
        Self {
            server,
            client,
            log,
            work,
        }
    }

    fn env(&self, extra: Value) -> Value {
        let mut env = json!({
            "PATH": std::env::var("PATH").unwrap_or_default(),
            "HOME": self.server.dir().to_string_lossy(),
            "CATALOG_AGENT_LOG": self.log.to_string_lossy(),
        });
        merge(&mut env, extra);
        env
    }

    fn launch(&self, agent: &str, cwd: &Path, env: Value) -> Value {
        json!({
            "agent": agent,
            "command": "python3",
            "args": [agent_script()],
            "cwd": cwd.to_string_lossy(),
            "env": env,
        })
    }

    fn refresh(&mut self, id: i64, agents: Vec<Value>, timeout: Option<u64>) -> Value {
        let mut params = json!({ "agents": agents });
        if let Some(timeout) = timeout {
            params["timeout_ms"] = json!(timeout);
        }
        self.client.request(id, "sessions.refresh", params)
    }

    fn delete(&mut self, id: i64, agent: Value, session: &str, timeout: Option<u64>) -> Value {
        let mut params = json!({ "agent": agent, "sessionId": session });
        if let Some(timeout) = timeout {
            params["timeout_ms"] = json!(timeout);
        }
        self.client.request(id, "sessions.delete", params)
    }

    fn cached(&mut self, id: i64) -> Value {
        let response = self.client.request(id, "sessions.cached", json!({}));
        response.get("result").cloned().unwrap_or(Value::Null)
    }

    /// The `sessions.updated` notifications buffered by the last request.
    fn updated(&mut self) -> Vec<Value> {
        let mut notifications = Vec::new();
        while let Some(frame) = self.client.try_next_notification(Duration::from_millis(20)) {
            if frame["method"] == "sessions.updated" {
                notifications.push(frame["params"].clone());
            }
        }
        notifications
    }

    fn log_events(&self) -> Vec<Value> {
        let Ok(text) = std::fs::read_to_string(&self.log) else {
            return Vec::new();
        };
        text.lines()
            .filter_map(|line| serde_json::from_str(line).ok())
            .collect()
    }

    fn log_count(&self, event: &str) -> usize {
        self.log_events()
            .iter()
            .filter(|value| value["event"] == event)
            .count()
    }

    fn wait_log(&self, event: &str, count: usize) {
        wait_for(
            || (self.log_count(event) >= count).then_some(()),
            &format!("{count} {event} log lines"),
        );
    }

    fn list(&mut self) -> Vec<Value> {
        self.client
            .request(90, "agent.list", json!({}))
            .get("result")
            .and_then(|result| result.get("instances"))
            .and_then(Value::as_array)
            .cloned()
            .unwrap_or_default()
    }
}

fn tunnel_call(client: &mut Client, instance: &str, id: i64, method: &str, params: Value) -> Value {
    client.notify(
        "tunnel.send",
        json!({
            "instance": instance,
            "message": { "jsonrpc": "2.0", "id": id, "method": method, "params": params },
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

fn attach(client: &mut Client, work: &Path, env: Value) -> String {
    attach_agent(client, work, env, "cat")
}

fn attach_agent(client: &mut Client, work: &Path, env: Value, agent: &str) -> String {
    let attached = client.request(
        5,
        "agent.attach",
        json!({
            "key": {
                "agent": agent,
                "command": "python3",
                "args": [agent_script()],
                "cwd": work.to_string_lossy(),
            },
            "client_capabilities": {},
            "env": env,
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
    instance
}

#[test]
fn refresh_lists_pages_and_caches_them() {
    let mut server = Server::new("catalog-happy");
    let pages = json!([
        {
            "sessions": [
                {"sessionId": "s1", "cwd": "/tmp/a", "title": "One",
                 "updatedAt": "2026-01-01T00:00:00Z", "_meta": {"k": 1}},
                // Dropped: session/load needs a string cwd.
                {"sessionId": "broken", "cwd": 7},
            ],
            "nextCursor": "c1"
        },
        {
            "sessions": [
                {"sessionId": "s2", "cwd": "/tmp/b"},
                // The last page wins for a repeated session id.
                {"sessionId": "s1", "cwd": "/tmp/a", "title": "Two",
                 "updatedAt": "2026-01-02T00:00:00Z", "_meta": {"k": 1}}
            ]
        }
    ]);
    let env = server.env(json!({
        "CATALOG_AGENT_PAGES": pages.to_string(),
    }));
    let cwd = server.work.clone();
    let response = server.refresh(2, vec![server.launch("cat", &cwd, env)], Some(5000));
    let result = &response["result"]["agents"]["cat"];
    assert_eq!(result["ok"], true, "{response}");
    assert_eq!(result["count"], 2, "{response}");

    let updates = server.updated();
    assert_eq!(updates.len(), 1, "{updates:?}");
    let sessions = updates[0]["sessions"].as_array().expect("sessions");
    assert_eq!(sessions.len(), 2, "{sessions:?}");
    let one = sessions.iter().find(|entry| entry["sessionId"] == "s1");
    let one = one.expect("s1 listed");
    assert_eq!(one["agent"], "cat");
    assert_eq!(one["cwd"], "/tmp/a");
    assert_eq!(one["title"], "Two");
    assert_eq!(one["_meta"]["k"], 1, "only the first page had _meta");
    let two = sessions.iter().find(|entry| entry["sessionId"] == "s2");
    assert_eq!(two.expect("s2 listed")["title"], Value::Null);
    assert!(
        sessions.iter().all(|entry| entry["sessionId"] != "broken"),
        "an entry without a string cwd is dropped"
    );

    let cached = server.cached(3);
    assert_eq!(
        cached["sessions"].as_array().map(Vec::len),
        Some(2),
        "{cached}"
    );
    assert!(cached["agents"]["cat"]["listed_at"].is_u64(), "{cached}");
    assert_eq!(cached["agents"]["cat"]["can_delete"], true, "{cached}");
    assert!(cached["agents"]["cat"].get("error").is_none(), "{cached}");

    // Paged without cwd first, then with the previous page's cursor.
    let events = server.log_events();
    let lists: Vec<&Value> = events
        .iter()
        .filter(|value| value["event"] == "list")
        .collect();
    assert_eq!(lists.len(), 2, "{events:?}");
    assert!(lists[0]["params"].get("cursor").is_none(), "{lists:?}");
    assert_eq!(lists[1]["params"]["cursor"], "c1");
    server.wait_log("exit", 1);
    assert!(
        server.list().is_empty(),
        "the temporary instance must never appear in agent.list"
    );
}

#[test]
fn a_missing_list_capability_fails_the_agent() {
    let mut server = Server::new("catalog-no-list");
    let env = server.env(json!({"CATALOG_AGENT_NO_LIST": "1"}));
    let cwd = server.work.clone();
    let response = server.refresh(2, vec![server.launch("cat", &cwd, env)], None);
    let result = &response["result"]["agents"]["cat"];
    assert_eq!(result["ok"], false, "{response}");
    assert_eq!(result["error"]["code"], -32070, "{response}");

    let updates = server.updated();
    assert_eq!(updates.len(), 1);
    assert_eq!(updates[0]["error"]["code"], -32070);
    assert_eq!(
        updates[0]["error"]["message"],
        "the agent does not support session/list"
    );

    let cached = server.cached(3);
    assert_eq!(cached["sessions"].as_array().map(Vec::len), Some(0));
    assert_eq!(cached["agents"]["cat"]["error"]["code"], -32070);
    assert!(cached["agents"]["cat"].get("listed_at").is_none());
    server.wait_log("exit", 1);
}

#[test]
fn a_failed_initialize_fails_the_agent_with_its_error() {
    let mut server = Server::new("catalog-init-fail");
    let env = server.env(json!({"CATALOG_AGENT_INIT_FAIL": "1"}));
    let cwd = server.work.clone();
    let response = server.refresh(2, vec![server.launch("cat", &cwd, env)], None);
    let result = &response["result"]["agents"]["cat"];
    assert_eq!(result["ok"], false, "{response}");
    assert_eq!(result["error"]["code"], 500, "{response}");
    assert_eq!(result["error"]["message"], "initialize refused");
    server.wait_log("exit", 1);
}

#[test]
fn a_listing_timeout_fires_without_the_team_tick() {
    // No NVIM_ADE_SERVER_TEAM_EXPIRY_TICK_MS: the catalog has its own timer, so
    // a 30 s "hang" must not stretch timeout_ms to the team tick's hour.
    let mut server = Server::new("catalog-timeout");
    let env = server.env(json!({"CATALOG_AGENT_LIST_DELAY": "30"}));
    let cwd = server.work.clone();
    let started = Instant::now();
    let response = server.refresh(2, vec![server.launch("cat", &cwd, env)], Some(1000));
    let result = &response["result"]["agents"]["cat"];
    assert_eq!(result["ok"], false, "{response}");
    assert_eq!(result["error"]["code"], -32071, "{response}");
    assert!(
        started.elapsed() < Duration::from_secs(5),
        "the catalog timer must fire near timeout_ms, not the hourly team tick"
    );

    let updates = server.updated();
    assert_eq!(updates.len(), 1);
    assert_eq!(updates[0]["error"]["code"], -32071);

    // The temporary process is stopped even though it ignores its closed stdin:
    // the graceful stop escalates to SIGTERM.
    server.wait_log("terminated", 1);
    let cached = server.cached(3);
    assert_eq!(cached["agents"]["cat"]["error"]["code"], -32071);
}

#[test]
fn a_late_list_answer_does_not_win() {
    let mut server = Server::new("catalog-late-answer");
    // The answer arrives 0.5 s after the 1 s deadline.
    let env = server.env(json!({"CATALOG_AGENT_LIST_DELAY": "1.5"}));
    let cwd = server.work.clone();
    let response = server.refresh(2, vec![server.launch("cat", &cwd, env)], Some(1000));
    let result = &response["result"]["agents"]["cat"];
    assert_eq!(result["ok"], false, "{response}");
    assert_eq!(result["error"]["code"], -32071, "{response}");
    server.wait_log("exit", 1);
    let cached = server.cached(3);
    assert_eq!(cached["sessions"].as_array().map(Vec::len), Some(0));
    assert_eq!(cached["agents"]["cat"]["error"]["code"], -32071);
}

#[test]
fn an_agent_exit_during_the_listing_fails_the_agent() {
    let mut server = Server::new("catalog-exit");
    let env = server.env(json!({"CATALOG_AGENT_EXIT_ON_LIST": "1"}));
    let cwd = server.work.clone();
    let response = server.refresh(2, vec![server.launch("cat", &cwd, env)], None);
    let result = &response["result"]["agents"]["cat"];
    assert_eq!(result["ok"], false, "{response}");
    assert_eq!(result["error"]["code"], -32072, "{response}");
    let updates = server.updated();
    assert_eq!(updates[0]["error"]["code"], -32072);
}

#[test]
fn a_list_error_is_passed_through() {
    let mut server = Server::new("catalog-error");
    let env = server.env(json!({"CATALOG_AGENT_LIST_ERROR": "401:auth required"}));
    let cwd = server.work.clone();
    let response = server.refresh(2, vec![server.launch("cat", &cwd, env)], None);
    let result = &response["result"]["agents"]["cat"];
    assert_eq!(result["ok"], false, "{response}");
    assert_eq!(result["error"]["code"], 401, "{response}");
    assert_eq!(result["error"]["message"], "auth required");
    server.wait_log("exit", 1);
}

#[test]
fn an_initialized_instance_is_reused_without_a_second_initialize() {
    let mut server = Server::new("catalog-reuse");
    let env = server.env(json!({}));
    let instance = attach(&mut server.client, &server.work, env.clone());

    let other = server.work.join("elsewhere");
    std::fs::create_dir_all(&other).expect("other cwd");
    let response = server.refresh(2, vec![server.launch("cat", &other, env)], None);
    let result = &response["result"]["agents"]["cat"];
    assert_eq!(result["ok"], true, "{response}");
    assert_eq!(result["count"], 1, "{response}");

    let events = server.log_events();
    assert_eq!(
        events
            .iter()
            .filter(|value| value["event"] == "initialize")
            .count(),
        1,
        "the cached initialize must be reused: {events:?}"
    );
    assert_eq!(
        events
            .iter()
            .filter(|value| value["event"] == "list")
            .count(),
        1,
        "{events:?}"
    );
    // The reused instance is still live and the only one listed.
    let instances = server.list();
    assert_eq!(instances.len(), 1, "{instances:?}");
    assert_eq!(instances[0]["instance"], instance);
    assert_eq!(instances[0]["stopping"], false);
    let cached = server.cached(3);
    assert_eq!(
        cached["agents"]["cat"]["can_delete"], true,
        "can_delete comes from the reused initialize: {cached}"
    );
}

/// Starts a team with one catalog-agent worker (`w1`) and returns the worker's
/// `agent.list` entry. The worker is an unlisted instance whose relay tracks
/// the session id its `session/new` returned.
fn start_team_worker(server: &mut Server, env: Value) -> Value {
    // A different agent id keeps the leader out of a catalog match.
    let leader = attach_agent(&mut server.client, &server.work, env.clone(), "leader");
    let config = json!({
        "max_workers": 3,
        "templates": {
            "dev": {
                "key": {
                    "agent": "cat",
                    "command": "python3",
                    "args": [agent_script()],
                },
                "env": env,
                "role": "list the sessions",
            }
        },
        "workflows": {
            "one": { "summary": "one worker", "team": [{ "name": "w1", "template": "dev" }] }
        },
        "default_workflow": "one",
    });
    let configured = server.client.request(
        6,
        "team.configure",
        json!({ "cwd": server.work.to_string_lossy(), "config": config }),
    );
    assert!(configured["result"].is_object(), "configure: {configured}");
    // Configure first, so session/new injects the team server and binds the
    // session token that team.start needs.
    let session = tunnel_call(
        &mut server.client,
        &leader,
        11,
        "session/new",
        json!({ "cwd": server.work.to_string_lossy(), "mcpServers": [] }),
    );
    let session_id = session["result"]["sessionId"]
        .as_str()
        .unwrap_or_else(|| panic!("session/new: {session}"))
        .to_string();
    let started = server.client.request(
        7,
        "team.start",
        json!({
            "instance": leader,
            "sessionId": session_id,
            "workflow": "one",
        }),
    );
    assert!(started["result"].is_object(), "team.start: {started}");
    // The leader and the worker each initialize and open a session.
    server.wait_log("initialize", 2);
    server.wait_log("session/new", 2);
    wait_for(
        || {
            server
                .list()
                .into_iter()
                .find(|entry| entry["participant"] == "w1")
        },
        "the team worker instance",
    )
}

#[test]
fn an_unlisted_initialized_instance_is_reused() {
    // A team worker is spawned unlisted (via `spawn_worker`); the catalog must
    // still find it by agent/command/args (PROTOCOL 21.3 step 1).
    let mut server = Server::new("catalog-reuse-worker");
    let env = server.env(json!({}));
    let worker = start_team_worker(&mut server, env.clone());
    let worker_pid = worker["pid"].clone();
    let initializations = server.log_count("initialize");
    assert!(initializations >= 2, "{initializations}");

    let other = server.work.join("elsewhere");
    std::fs::create_dir_all(&other).expect("other cwd");
    let response = server.refresh(2, vec![server.launch("cat", &other, env)], None);
    let result = &response["result"]["agents"]["cat"];
    assert_eq!(result["ok"], true, "{response}");
    assert_eq!(result["count"], 1, "{response}");

    // No third process and no second initialize: the list went to the worker.
    assert_eq!(
        server.log_count("initialize"),
        initializations,
        "the worker's cached initialize must be reused: {:?}",
        server.log_events()
    );
    let lists: Vec<Value> = server
        .log_events()
        .into_iter()
        .filter(|value| value["event"] == "list")
        .collect();
    assert_eq!(lists.len(), 1, "{lists:?}");
    assert_eq!(lists[0]["pid"], worker_pid, "the worker listed: {lists:?}");
    // The worker is still running and not stopping.
    let listed = server
        .list()
        .into_iter()
        .find(|entry| entry["participant"] == "w1")
        .expect("worker still listed");
    assert_eq!(listed["stopping"], false);
}

#[test]
fn repeated_timeouts_on_a_reused_instance_ignore_late_answers() {
    let mut server = Server::new("catalog-reuse-timeout");
    let env = server.env(json!({"CATALOG_AGENT_LIST_DELAY": "1.5"}));
    let instance = attach(&mut server.client, &server.work, env.clone());
    let cwd = server.work.clone();

    for id in [2, 3] {
        let response = server.refresh(
            id,
            vec![server.launch("cat", &cwd, env.clone())],
            Some(1000),
        );
        let result = &response["result"]["agents"]["cat"];
        assert_eq!(result["ok"], false, "{response}");
        assert_eq!(result["error"]["code"], -32071, "{response}");
    }

    // The two late answers arrive while this listing runs; they must not touch
    // the newer request.
    let response = server.refresh(4, vec![server.launch("cat", &cwd, env)], Some(5000));
    let result = &response["result"]["agents"]["cat"];
    assert_eq!(result["ok"], true, "{response}");
    assert_eq!(result["count"], 1, "{response}");
    let cached = server.cached(5);
    assert_eq!(
        cached["sessions"].as_array().map(Vec::len),
        Some(1),
        "{cached}"
    );
    assert!(cached["agents"]["cat"].get("error").is_none(), "{cached}");

    // A reused instance is never stopped by a timeout.
    let listed = server.list();
    assert_eq!(listed.len(), 1, "{listed:?}");
    assert_eq!(listed[0]["instance"], instance);
    assert_eq!(listed[0]["stopping"], false);
}

#[test]
fn concurrent_refreshes_of_one_agent_join() {
    let mut first = Server::with_env("catalog-join", &[], &[]);
    let env = first.env(json!({"CATALOG_AGENT_LIST_DELAY": "0.4"}));
    let cwd = first.work.clone();
    let launch = first.launch("cat", &cwd, env);
    let params = json!({ "agents": [launch], "timeout_ms": 5000 });

    let mut second = first.server.connect();
    let hello = second.hello(&first.server.token(), nvim_ade_server::API_VERSION);
    assert!(hello["result"].is_object(), "hello: {hello}");

    first.client.send(&json!({
        "jsonrpc": "2.0", "id": 20, "method": "sessions.refresh", "params": params.clone(),
    }));
    second.send(&json!({
        "jsonrpc": "2.0", "id": 21, "method": "sessions.refresh", "params": params,
    }));

    let notification = first.client.next_notification(WAIT);
    assert_eq!(notification["method"], "sessions.updated");
    assert_eq!(notification["params"]["agent"], "cat");
    let first_response = wait_for(|| first.client.take_response(20), "the first refresh reply");
    assert_eq!(first_response["result"]["agents"]["cat"]["ok"], true);

    let notification = second.next_notification(WAIT);
    assert_eq!(notification["method"], "sessions.updated");
    let second_response = wait_for(|| second.take_response(21), "the joining refresh reply");
    assert_eq!(second_response["result"]["agents"]["cat"]["ok"], true);
    assert_eq!(
        second_response["result"]["agents"]["cat"]["count"],
        first_response["result"]["agents"]["cat"]["count"]
    );

    let events = first.log_events();
    assert_eq!(
        events
            .iter()
            .filter(|value| value["event"] == "initialize")
            .count(),
        1,
        "joining must not start a second process: {events:?}"
    );
    assert_eq!(
        events
            .iter()
            .filter(|value| value["event"] == "list")
            .count(),
        1,
        "{events:?}"
    );
    first.wait_log("exit", 1);
}

#[test]
fn a_successful_delete_removes_the_catalog_row() {
    let mut server = Server::new("catalog-delete");
    let pages = json!([{
        "sessions": [
            {"sessionId": "s1", "cwd": "/tmp/a"},
            {"sessionId": "s2", "cwd": "/tmp/b"}
        ]
    }]);
    let env = server.env(json!({
        "CATALOG_AGENT_PAGES": pages.to_string(),
    }));
    let cwd = server.work.clone();
    let response = server.refresh(2, vec![server.launch("cat", &cwd, env.clone())], None);
    assert_eq!(
        response["result"]["agents"]["cat"]["count"], 2,
        "{response}"
    );
    server.wait_log("exit", 1);

    // `session/close` must not touch the catalog, `session/delete` must.
    let instance = attach(&mut server.client, &server.work, env);
    let closed = tunnel_call(
        &mut server.client,
        &instance,
        30,
        "session/close",
        json!({"sessionId": "s1"}),
    );
    assert!(closed.get("result").is_some(), "{closed}");
    let cached = server.cached(3);
    assert!(
        cached["sessions"]
            .as_array()
            .expect("sessions")
            .iter()
            .any(|entry| entry["sessionId"] == "s1"),
        "a close keeps the row: {cached}"
    );

    let deleted = tunnel_call(
        &mut server.client,
        &instance,
        31,
        "session/delete",
        json!({"sessionId": "s1"}),
    );
    assert!(deleted.get("result").is_some(), "{deleted}");
    let cached = server.cached(4);
    let sessions = cached["sessions"].as_array().expect("sessions");
    assert_eq!(sessions.len(), 1, "{cached}");
    assert_eq!(sessions[0]["sessionId"], "s2");
}

#[test]
fn temporary_instance_client_requests_are_answered_with_method_not_found() {
    let mut server = Server::new("catalog-requests");
    let env = server.env(json!({"CATALOG_AGENT_CLIENT_REQUEST": "1"}));
    let cwd = server.work.clone();
    let response = server.refresh(2, vec![server.launch("cat", &cwd, env)], None);
    assert_eq!(
        response["result"]["agents"]["cat"]["ok"], true,
        "{response}"
    );

    let answered = wait_for(
        || {
            server
                .log_events()
                .into_iter()
                .find(|value| value["event"] == "client_response")
        },
        "the temporary instance's client request to be answered",
    );
    assert_eq!(answered["body"]["code"], -32601, "{answered}");
    assert!(answered["body"].get("result").is_none(), "{answered}");
    server.wait_log("exit", 1);
}

#[test]
fn without_the_event_log_refresh_still_lists_but_caches_nothing() {
    let mut server = Server::with_env("catalog-off", &["--event-log", "off"], &[]);
    let hello = server
        .client
        .hello(&server.server.token(), nvim_ade_server::API_VERSION);
    for feature in ["sessions", "sessions.delete"] {
        assert!(
            hello["result"]["features"]
                .as_array()
                .is_some_and(|features| features.iter().any(|value| value == feature)),
            "the {feature} feature does not need the log: {hello}"
        );
    }
    let env = server.env(json!({}));
    let cwd = server.work.clone();
    let response = server.refresh(2, vec![server.launch("cat", &cwd, env)], None);
    assert_eq!(
        response["result"]["agents"]["cat"]["ok"], true,
        "{response}"
    );

    let cached = server.cached(3);
    assert_eq!(
        cached["sessions"].as_array().map(Vec::len),
        Some(0),
        "{cached}"
    );
    assert!(
        cached["agents"]
            .as_object()
            .is_some_and(|agents| agents.is_empty()),
        "an empty catalog encodes agents as an object: {cached}"
    );
}

#[test]
fn duplicate_agent_ids_are_invalid_params() {
    let mut server = Server::new("catalog-duplicate");
    let env = server.env(json!({}));
    let cwd = server.work.clone();
    let launch = server.launch("cat", &cwd, env);
    let response = server.refresh(2, vec![launch.clone(), launch], None);
    assert_eq!(response["error"]["code"], -32602, "{response}");
    assert!(
        server.log_events().is_empty(),
        "nothing is spawned for an invalid call"
    );
}

#[test]
fn sessions_delete_reuses_an_initialized_instance_and_removes_the_row() {
    let mut server = Server::new("catalog-delete-reuse");
    let env = server.env(json!({}));
    let cwd = server.work.clone();
    let response = server.refresh(2, vec![server.launch("cat", &cwd, env.clone())], None);
    assert_eq!(
        response["result"]["agents"]["cat"]["ok"], true,
        "{response}"
    );
    let cached = server.cached(3);
    assert_eq!(cached["agents"]["cat"]["can_delete"], true, "{cached}");
    assert_eq!(
        cached["sessions"].as_array().map(Vec::len),
        Some(1),
        "{cached}"
    );
    server.wait_log("exit", 1);

    // The listed instance is reused: no second process, no second initialize.
    let instance = attach(&mut server.client, &server.work, env.clone());
    let initializations = server.log_count("initialize");
    let deleted = server.delete(4, server.launch("cat", &cwd, env), "s1", None);
    assert_eq!(deleted["result"], json!({}), "{deleted}");
    assert_eq!(
        server.log_count("initialize"),
        initializations,
        "the delete must reuse the initialized instance"
    );
    assert_eq!(server.log_count("session/delete"), 1);

    let cached = server.cached(5);
    assert_eq!(
        cached["sessions"].as_array().map(Vec::len),
        Some(0),
        "{cached}"
    );
    let listed = server.list();
    assert_eq!(listed.len(), 1, "{listed:?}");
    assert_eq!(listed[0]["instance"], instance);
    assert_eq!(listed[0]["stopping"], false);
}

#[test]
fn sessions_delete_spawns_and_stops_a_temporary_instance() {
    let mut server = Server::new("catalog-delete-temp");
    let env = server.env(json!({}));
    let cwd = server.work.clone();
    server.refresh(2, vec![server.launch("cat", &cwd, env.clone())], None);
    server.wait_log("exit", 1);

    let before = server.log_count("initialize");
    let response = server.delete(3, server.launch("cat", &cwd, env), "s1", None);
    assert_eq!(response["result"], json!({}), "{response}");
    assert_eq!(
        server.log_count("initialize"),
        before + 1,
        "the delete spawns its own temporary instance"
    );
    assert_eq!(server.log_count("session/delete"), 1);
    let cached = server.cached(4);
    assert_eq!(
        cached["sessions"].as_array().map(Vec::len),
        Some(0),
        "{cached}"
    );
    // The refresh's and the delete's temporary processes both stopped.
    server.wait_log("exit", 2);
}

#[test]
fn sessions_delete_without_the_capability_is_rejected() {
    let mut server = Server::new("catalog-delete-capability");
    let env = server.env(json!({"CATALOG_AGENT_NO_DELETE": "1"}));
    let cwd = server.work.clone();
    let response = server.refresh(2, vec![server.launch("cat", &cwd, env.clone())], None);
    assert_eq!(
        response["result"]["agents"]["cat"]["ok"], true,
        "{response}"
    );
    let cached = server.cached(3);
    assert_eq!(cached["agents"]["cat"]["can_delete"], false, "{cached}");

    // Temporary path: the fresh initialize says no delete.
    let response = server.delete(4, server.launch("cat", &cwd, env.clone()), "s1", None);
    assert_eq!(response["error"]["code"], -32073, "{response}");
    assert_eq!(server.log_count("session/delete"), 0);
    server.wait_log("exit", 2);

    // Reuse path: the cached initialize also lacks delete.
    let instance = attach(&mut server.client, &server.work, env.clone());
    let initializations = server.log_count("initialize");
    let response = server.delete(5, server.launch("cat", &cwd, env), "s1", None);
    assert_eq!(response["error"]["code"], -32073, "{response}");
    assert_eq!(server.log_count("initialize"), initializations);
    assert_eq!(server.log_count("session/delete"), 0);
    let listed = server.list();
    assert_eq!(listed.len(), 1, "{listed:?}");
    assert_eq!(listed[0]["instance"], instance);
    assert_eq!(listed[0]["stopping"], false);
}

#[test]
fn sessions_delete_refuses_a_session_in_use() {
    let mut server = Server::new("catalog-delete-in-use");
    let env = server.env(json!({}));
    let cwd = server.work.clone();
    server.refresh(2, vec![server.launch("cat", &cwd, env.clone())], None);
    server.wait_log("exit", 1);

    let instance = attach(&mut server.client, &server.work, env.clone());
    let loaded = tunnel_call(
        &mut server.client,
        &instance,
        20,
        "session/load",
        json!({
            "sessionId": "s1",
            "cwd": server.work.to_string_lossy(),
            "mcpServers": [],
        }),
    );
    assert!(loaded.get("result").is_some(), "{loaded}");

    let deletes = server.log_count("session/delete");
    let response = server.delete(3, server.launch("cat", &cwd, env), "s1", None);
    assert_eq!(response["error"]["code"], -32074, "{response}");
    assert_eq!(response["error"]["message"], "session is in use");
    assert_eq!(
        server.log_count("session/delete"),
        deletes,
        "nothing must reach an agent"
    );
    let cached = server.cached(4);
    assert_eq!(
        cached["sessions"].as_array().map(Vec::len),
        Some(1),
        "an in-use session keeps its row: {cached}"
    );
}

#[test]
fn sessions_delete_passes_an_agent_error_through() {
    let mut server = Server::new("catalog-delete-error");
    let cwd = server.work.clone();
    let list_env = server.env(json!({}));
    server.refresh(2, vec![server.launch("cat", &cwd, list_env)], None);

    let env = server.env(json!({"CATALOG_AGENT_DELETE_ERROR": "409:cannot delete"}));
    let response = server.delete(3, server.launch("cat", &cwd, env), "s1", None);
    assert_eq!(response["error"]["code"], 409, "{response}");
    assert_eq!(response["error"]["message"], "cannot delete");
    let cached = server.cached(4);
    assert_eq!(
        cached["sessions"].as_array().map(Vec::len),
        Some(1),
        "a failed delete keeps the row: {cached}"
    );
}

#[test]
fn sessions_delete_timeout_stops_the_temporary_instance() {
    let mut server = Server::new("catalog-delete-timeout");
    let env = server.env(json!({}));
    let cwd = server.work.clone();
    server.refresh(2, vec![server.launch("cat", &cwd, env.clone())], None);
    server.wait_log("exit", 1);

    let slow = server.env(json!({"CATALOG_AGENT_DELETE_DELAY": "30"}));
    let started = Instant::now();
    let response = server.delete(3, server.launch("cat", &cwd, slow), "s1", Some(1000));
    assert_eq!(response["error"]["code"], -32071, "{response}");
    assert!(
        started.elapsed() < Duration::from_secs(5),
        "the catalog timer must fire near timeout_ms"
    );
    server.wait_log("terminated", 1);
    let cached = server.cached(4);
    assert_eq!(
        cached["sessions"].as_array().map(Vec::len),
        Some(1),
        "a timed-out delete keeps the row: {cached}"
    );
}

#[test]
fn sessions_delete_reports_an_agent_exit() {
    let mut server = Server::new("catalog-delete-exit");
    let env = server.env(json!({"CATALOG_AGENT_EXIT_ON_DELETE": "1"}));
    let cwd = server.work.clone();
    let response = server.delete(2, server.launch("cat", &cwd, env), "s1", None);
    assert_eq!(response["error"]["code"], -32072, "{response}");
}

#[test]
fn sessions_delete_joins_a_running_delete() {
    let mut first = Server::new("catalog-delete-join");
    let env = first.env(json!({"CATALOG_AGENT_DELETE_DELAY": "0.5"}));
    let cwd = first.work.clone();
    first.refresh(2, vec![first.launch("cat", &cwd, env.clone())], None);
    first.wait_log("exit", 1);

    let mut second = first.server.connect();
    let hello = second.hello(&first.server.token(), nvim_ade_server::API_VERSION);
    assert!(hello["result"].is_object(), "hello: {hello}");

    let params = json!({
        "agent": first.launch("cat", &cwd, env),
        "sessionId": "s1",
        "timeout_ms": 5000,
    });
    first.client.send(&json!({
        "jsonrpc": "2.0", "id": 20, "method": "sessions.delete", "params": params.clone(),
    }));
    second.send(&json!({
        "jsonrpc": "2.0", "id": 21, "method": "sessions.delete", "params": params,
    }));
    let first_reply = wait_for(|| first.client.take_response(20), "the first delete reply");
    let joined_reply = wait_for(|| second.take_response(21), "the joined delete reply");
    assert_eq!(first_reply["result"], json!({}), "{first_reply}");
    assert_eq!(joined_reply["result"], json!({}), "{joined_reply}");
    assert_eq!(
        first.log_count("session/delete"),
        1,
        "joining must not send a second session/delete"
    );
    first.wait_log("exit", 2);
}

#[test]
fn a_delete_during_a_refresh_removes_the_row_from_the_result() {
    let mut server = Server::new("catalog-delete-race");
    let cwd = server.work.clone();
    let refresh_env = server.env(json!({"CATALOG_AGENT_LIST_DELAY": "1.2"}));
    let refresh = json!({
        "agents": [server.launch("cat", &cwd, refresh_env)],
        "timeout_ms": 5000,
    });
    server.client.send(&json!({
        "jsonrpc": "2.0", "id": 20, "method": "sessions.refresh", "params": refresh,
    }));
    // The refresh's list request is sleeping in the agent now.
    server.wait_log("list", 1);

    let delete_env = server.env(json!({}));
    let response = server.delete(21, server.launch("cat", &cwd, delete_env), "s1", Some(5000));
    assert_eq!(response["result"], json!({}), "{response}");

    let notification = server.client.next_notification(WAIT);
    assert_eq!(notification["method"], "sessions.updated");
    assert_eq!(notification["params"]["agent"], "cat");
    assert_eq!(
        notification["params"]["sessions"],
        json!([]),
        "the deleted row must not come back: {notification}"
    );
    let reply = wait_for(|| server.client.take_response(20), "the refresh reply");
    assert_eq!(reply["result"]["agents"]["cat"]["ok"], true, "{reply}");
    assert_eq!(reply["result"]["agents"]["cat"]["count"], 0, "{reply}");
    let cached = server.cached(22);
    assert_eq!(
        cached["sessions"].as_array().map(Vec::len),
        Some(0),
        "{cached}"
    );
}

#[test]
fn a_delete_finishes_after_its_connection_closes() {
    let mut server = Server::new("catalog-delete-closed");
    let env = server.env(json!({}));
    let cwd = server.work.clone();
    server.refresh(2, vec![server.launch("cat", &cwd, env.clone())], None);
    server.wait_log("exit", 1);

    let slow = server.env(json!({"CATALOG_AGENT_DELETE_DELAY": "0.8"}));
    let params = json!({
        "agent": server.launch("cat", &cwd, slow),
        "sessionId": "s1",
        "timeout_ms": 5000,
    });
    server.client.send(&json!({
        "jsonrpc": "2.0", "id": 20, "method": "sessions.delete", "params": params,
    }));
    server.client.disconnect();

    let mut observer = server.server.connect();
    let hello = observer.hello(&server.server.token(), nvim_ade_server::API_VERSION);
    assert!(hello["result"].is_object(), "hello: {hello}");
    let cached = wait_for(
        || {
            let cached = observer.request(3, "sessions.cached", json!({}));
            let result = cached.get("result")?.clone();
            (result["sessions"].as_array().map(Vec::len) == Some(0)).then_some(result)
        },
        "the row removed after the connection closed",
    );
    assert_eq!(cached["agents"]["cat"]["can_delete"], true, "{cached}");
}

#[test]
fn idle_exit_waits_for_a_running_delete() {
    let mut server = Server::with_env("catalog-delete-idle", &["--idle-timeout", "0.5"], &[]);
    let env = server.env(json!({}));
    let cwd = server.work.clone();
    server.refresh(2, vec![server.launch("cat", &cwd, env.clone())], None);
    server.wait_log("exit", 1);

    let slow = server.env(json!({"CATALOG_AGENT_DELETE_DELAY": "1.5"}));
    let params = json!({
        "agent": server.launch("cat", &cwd, slow),
        "sessionId": "s1",
        "timeout_ms": 5000,
    });
    let started = Instant::now();
    server.client.send(&json!({
        "jsonrpc": "2.0", "id": 20, "method": "sessions.delete", "params": params,
    }));
    server.client.disconnect();
    let code = server.server.wait_for_exit(Duration::from_secs(15));
    assert!(
        code.is_some(),
        "the service must idle-exit after the delete; stderr:\n{}",
        server.server.stderr()
    );
    assert!(
        started.elapsed() >= Duration::from_millis(1500),
        "idle exit must wait for the running delete (took {:?})",
        started.elapsed()
    );

    let dir = server.server.temp_dir();
    let restarted = TestServer::start_in_dir(dir, "catalog-delete-idle-restart", &[], &[]);
    let mut client = restarted.connect();
    let hello = client.hello(&restarted.token(), nvim_ade_server::API_VERSION);
    assert!(hello["result"].is_object(), "hello: {hello}");
    let cached = client.request(2, "sessions.cached", json!({}));
    assert_eq!(
        cached["result"]["sessions"].as_array().map(Vec::len),
        Some(0),
        "the delete finished before the idle exit: {cached}"
    );
}

#[test]
fn sessions_delete_rejects_invalid_params() {
    let mut server = Server::new("catalog-delete-invalid");
    let launch = server.launch("cat", &server.work, server.env(json!({})));
    let cases = [
        json!({}),
        json!({ "agent": launch }),
        json!({ "agent": launch, "sessionId": "" }),
        json!({ "agent": launch, "sessionId": 7 }),
        // A relative cwd is not a launch the service may spawn.
        json!({
            "agent": {
                "agent": "cat", "command": "python3", "args": [agent_script()],
                "cwd": "relative",
            },
            "sessionId": "s1",
        }),
        json!({ "agent": launch, "sessionId": "s1", "timeout_ms": -1 }),
    ];
    for (index, params) in cases.iter().enumerate() {
        let response = server
            .client
            .request(100 + index as i64, "sessions.delete", params.clone());
        assert_eq!(response["error"]["code"], -32602, "{params}: {response}");
    }
    assert!(
        server.log_events().is_empty(),
        "nothing is spawned for an invalid call"
    );
}

#[test]
fn sessions_delete_refuses_a_session_in_use_on_an_unlisted_instance() {
    let mut server = Server::new("catalog-delete-in-use-worker");
    let env = server.env(json!({}));
    let worker = start_team_worker(&mut server, env.clone());
    let worker_instance = worker["instance"]
        .as_str()
        .expect("worker instance")
        .to_string();
    // The worker is unlisted, but its relay tracks the id its session/new
    // returned: the in-use check must find it.
    let deletes = server.log_count("session/delete");
    let response = server.delete(
        3,
        server.launch("cat", &server.work, env),
        "agent-session",
        None,
    );
    assert_eq!(response["error"]["code"], -32074, "{response}");
    assert_eq!(
        server.log_count("session/delete"),
        deletes,
        "nothing must reach an agent"
    );
    assert!(
        server
            .list()
            .iter()
            .any(|entry| entry["instance"] == worker_instance.as_str()),
        "the worker keeps running"
    );
}

#[test]
fn a_failed_delete_does_not_tombstone_a_running_refresh() {
    let mut server = Server::new("catalog-delete-failed-race");
    let cwd = server.work.clone();
    let refresh_env = server.env(json!({"CATALOG_AGENT_LIST_DELAY": "1.2"}));
    let refresh = json!({
        "agents": [server.launch("cat", &cwd, refresh_env)],
        "timeout_ms": 5000,
    });
    server.client.send(&json!({
        "jsonrpc": "2.0", "id": 20, "method": "sessions.refresh", "params": refresh,
    }));
    server.wait_log("list", 1);

    let delete_env = server.env(json!({"CATALOG_AGENT_DELETE_ERROR": "409:cannot delete"}));
    let deleted = server.delete(21, server.launch("cat", &cwd, delete_env), "s1", Some(5000));
    assert_eq!(deleted["error"]["code"], 409, "{deleted}");

    // A failed delete leaves no tombstone: the refresh still lists the row.
    let notification = server.client.next_notification(WAIT);
    assert_eq!(notification["method"], "sessions.updated");
    assert_eq!(
        notification["params"]["sessions"].as_array().map(Vec::len),
        Some(1),
        "{notification}"
    );
    let reply = wait_for(|| server.client.take_response(20), "the refresh reply");
    assert_eq!(reply["result"]["agents"]["cat"]["count"], 1, "{reply}");
    let cached = server.cached(22);
    assert_eq!(
        cached["sessions"].as_array().map(Vec::len),
        Some(1),
        "{cached}"
    );
}

#[test]
fn a_late_delete_response_on_a_reused_instance_is_ignored() {
    let mut server = Server::new("catalog-delete-late-reuse");
    let env = server.env(json!({}));
    let cwd = server.work.clone();
    server.refresh(2, vec![server.launch("cat", &cwd, env.clone())], None);
    server.wait_log("exit", 1);

    // A listed instance that answers session/delete after the deadline; the
    // delete reuses it (no temporary process).
    let slow = server.env(json!({"CATALOG_AGENT_DELETE_DELAY": "1.5"}));
    let instance = attach(&mut server.client, &server.work, slow);
    let initializations = server.log_count("initialize");
    let response = server.delete(3, server.launch("cat", &cwd, env), "s1", Some(1000));
    assert_eq!(response["error"]["code"], -32071, "{response}");
    assert_eq!(server.log_count("initialize"), initializations, "reused");

    // Drain the tracked notifications, then let the late answer arrive.
    let _ = server.updated();
    server.wait_log("delete_answered", 1);
    assert!(
        server
            .client
            .try_next_notification(Duration::from_millis(300))
            .is_none(),
        "a service response is never delivered to a front end"
    );

    let cached = server.cached(4);
    assert_eq!(
        cached["sessions"].as_array().map(Vec::len),
        Some(1),
        "a late answer must not remove the row: {cached}"
    );
    assert_eq!(cached["agents"]["cat"]["can_delete"], true, "{cached}");
    assert!(cached["agents"]["cat"].get("error").is_none(), "{cached}");
    let listed = server.list();
    assert_eq!(listed.len(), 1, "{listed:?}");
    assert_eq!(listed[0]["instance"], instance);
    assert_eq!(listed[0]["stopping"], false);
}

#[test]
fn joined_deletes_share_a_timeout() {
    let mut first = Server::new("catalog-delete-join-timeout");
    let env = first.env(json!({"CATALOG_AGENT_DELETE_DELAY": "30"}));
    let cwd = first.work.clone();
    let mut second = first.server.connect();
    let hello = second.hello(&first.server.token(), nvim_ade_server::API_VERSION);
    assert!(hello["result"].is_object(), "hello: {hello}");

    let params = json!({
        "agent": first.launch("cat", &cwd, env),
        "sessionId": "s1",
        "timeout_ms": 1000,
    });
    first.client.send(&json!({
        "jsonrpc": "2.0", "id": 20, "method": "sessions.delete", "params": params.clone(),
    }));
    second.send(&json!({
        "jsonrpc": "2.0", "id": 21, "method": "sessions.delete", "params": params,
    }));
    let first_reply = wait_for(|| first.client.take_response(20), "the first delete reply");
    let joined_reply = wait_for(|| second.take_response(21), "the joined delete reply");
    assert_eq!(first_reply["error"]["code"], -32071, "{first_reply}");
    assert_eq!(joined_reply["error"]["code"], -32071, "{joined_reply}");
    assert_eq!(
        first.log_count("session/delete"),
        1,
        "joining must not send a second session/delete"
    );
    first.wait_log("terminated", 1);
}

#[test]
fn a_failed_refresh_keeps_the_previous_can_delete() {
    let mut server = Server::new("catalog-can-delete-kept");
    let env = server.env(json!({}));
    let cwd = server.work.clone();
    let response = server.refresh(2, vec![server.launch("cat", &cwd, env)], None);
    assert_eq!(
        response["result"]["agents"]["cat"]["ok"], true,
        "{response}"
    );
    let first = server.cached(3);
    assert_eq!(first["agents"]["cat"]["can_delete"], true, "{first}");
    let listed_at = first["agents"]["cat"]["listed_at"].clone();

    let failing = server.env(json!({"CATALOG_AGENT_LIST_ERROR": "401:auth required"}));
    let response = server.refresh(4, vec![server.launch("cat", &cwd, failing)], None);
    assert_eq!(
        response["result"]["agents"]["cat"]["ok"], false,
        "{response}"
    );
    let cached = server.cached(5);
    assert_eq!(
        cached["agents"]["cat"]["can_delete"], true,
        "a failure keeps the last successful listing's capability: {cached}"
    );
    assert_eq!(cached["agents"]["cat"]["listed_at"], listed_at, "{cached}");
    assert_eq!(cached["agents"]["cat"]["error"]["code"], 401, "{cached}");
    assert_eq!(
        cached["sessions"].as_array().map(Vec::len),
        Some(1),
        "the cached rows are kept: {cached}"
    );
}
