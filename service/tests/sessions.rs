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
    let attached = client.request(
        5,
        "agent.attach",
        json!({
            "key": {
                "agent": "cat",
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
fn a_listing_timeout_fails_the_agent() {
    let mut server = Server::with_env(
        "catalog-timeout",
        &[],
        &[("NVIM_ADE_SERVER_TEAM_EXPIRY_TICK_MS", "25")],
    );
    let env = server.env(json!({"CATALOG_AGENT_LIST_DELAY": "1.5"}));
    let cwd = server.work.clone();
    let started = Instant::now();
    let response = server.refresh(2, vec![server.launch("cat", &cwd, env)], Some(1000));
    let result = &response["result"]["agents"]["cat"];
    assert_eq!(result["ok"], false, "{response}");
    assert_eq!(result["error"]["code"], -32071, "{response}");
    assert!(
        started.elapsed() < Duration::from_secs(5),
        "the timeout tick must fire well before the 1.5 s late answer"
    );

    let updates = server.updated();
    assert_eq!(updates.len(), 1);
    assert_eq!(updates[0]["error"]["code"], -32071);

    // The late response is ignored and the temporary process stops.
    server.wait_log("exit", 1);
    let cached = server.cached(3);
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
    assert!(
        hello["result"]["features"]
            .as_array()
            .is_some_and(|features| features.iter().any(|feature| feature == "sessions")),
        "the sessions feature does not need the log: {hello}"
    );
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
