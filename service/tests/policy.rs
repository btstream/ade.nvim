//! Integration tests for the server-side permission policy (PROTOCOL.md 17).

#![cfg(unix)]

mod common;

use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};
use std::time::{Duration, Instant};

use common::TestServer;
use serde_json::{json, Value};

fn fixture(name: &str) -> PathBuf {
    let mut path = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
    path.push("tests");
    path.push("fixtures");
    path.push(name);
    path
}

fn child_env(extra: &[(&str, &str)]) -> Value {
    let mut map = serde_json::Map::new();
    for (key, value) in std::env::vars() {
        map.insert(key, Value::String(value));
    }
    for (key, value) in extra {
        map.insert((*key).to_string(), Value::String((*value).to_string()));
    }
    Value::Object(map)
}

struct Agent {
    client: common::Client,
    instance: String,
    next_id: i64,
    session: String,
}

enum Event {
    Tunnel(Value),
    Applied(Value),
}

impl Agent {
    /// Attach a client to the fixture agent. The same `label` gives the same
    /// instance identity, so two calls create a second attachment to one agent.
    fn attach(server: &TestServer, label: &str, extra_env: &[(&str, &str)]) -> Self {
        let mut client = server.connect();
        let hello = client.hello(&server.token(), 4);
        assert!(hello["result"].is_object(), "hello: {hello}");
        let key = json!({
            "agent": "policy",
            "command": "python3",
            "args": [fixture("policy_agent.py").to_string_lossy(), label],
            "cwd": server.dir().to_string_lossy(),
        });
        let response = client.request(
            2,
            "agent.attach",
            json!({
                "key": key,
                "client_capabilities": {},
                "env": child_env(extra_env),
            }),
        );
        assert!(response["result"].is_object(), "attach: {response}");
        let instance = response["result"]["instance"]
            .as_str()
            .expect("instance")
            .to_string();
        let mut agent = Self {
            client,
            instance,
            next_id: 100,
            session: String::new(),
        };
        agent.initialize();
        agent
    }

    fn initialize(&mut self) {
        self.next_id += 1;
        let id = self.next_id;
        self.send_request(
            id,
            "initialize",
            json!({"protocolVersion": 1, "clientCapabilities": {}}),
        );
        self.wait_response(id);
    }

    fn send_request(&mut self, id: i64, method: &str, params: Value) {
        self.client.notify(
            "tunnel.send",
            json!({
                "instance": self.instance,
                "message": {"jsonrpc": "2.0", "id": id, "method": method, "params": params},
            }),
        );
    }

    fn send_notification(&mut self, method: &str, params: Value) {
        self.client.notify(
            "tunnel.send",
            json!({
                "instance": self.instance,
                "message": {"jsonrpc": "2.0", "method": method, "params": params},
            }),
        );
    }

    fn next_event(&mut self, timeout: Duration) -> Option<Event> {
        let notification = self.client.next_notification(timeout);
        match notification["method"].as_str() {
            Some("tunnel.recv") => {
                assert_eq!(notification["params"]["instance"], self.instance);
                Some(Event::Tunnel(notification["params"]["message"].clone()))
            }
            Some("policy.applied") => Some(Event::Applied(notification["params"].clone())),
            Some("tunnel.error") => panic!("tunnel.error: {notification}"),
            Some("agent.exited") => panic!("agent.exited: {notification}"),
            Some(other) => panic!("unexpected notification {other}: {notification}"),
            None => None,
        }
    }

    fn next_tunnel(&mut self, timeout: Duration) -> Value {
        let deadline = Instant::now() + timeout;
        loop {
            let remaining = deadline.saturating_duration_since(Instant::now());
            match self.next_event(remaining) {
                Some(Event::Tunnel(message)) => return message,
                Some(Event::Applied(_)) => continue,
                None => panic!("timed out waiting for a tunnel message"),
            }
        }
    }

    fn next_applied(&mut self, timeout: Duration) -> Value {
        let deadline = Instant::now() + timeout;
        loop {
            let remaining = deadline.saturating_duration_since(Instant::now());
            match self.next_event(remaining) {
                Some(Event::Applied(params)) => return params,
                Some(Event::Tunnel(_)) => continue,
                None => panic!("timed out waiting for policy.applied"),
            }
        }
    }

    fn wait_response(&mut self, id: i64) -> Value {
        loop {
            let message = self.next_tunnel(Duration::from_secs(20));
            if message.get("method").is_none() && message["id"] == json!(id) {
                return message;
            }
        }
    }

    fn request(&mut self, method: &str, params: Value) -> Value {
        self.next_id += 1;
        let id = self.next_id;
        self.send_request(id, method, params);
        self.wait_response(id)
    }

    fn new_session(&mut self) -> String {
        let response = self.request(
            "session/new",
            json!({"cwd": "/tmp/policy", "mcpServers": []}),
        );
        self.session = response["result"]["sessionId"]
            .as_str()
            .expect("sessionId")
            .to_string();
        self.session.clone()
    }

    fn prompt(&mut self, text: &str) -> i64 {
        self.next_id += 1;
        let id = self.next_id;
        self.send_request(
            id,
            "session/prompt",
            json!({
                "sessionId": self.session,
                "prompt": [{"type": "text", "text": text}],
            }),
        );
        id
    }

    fn recv_permission(&mut self) -> (Value, Value) {
        loop {
            let message = self.next_tunnel(Duration::from_secs(20));
            if message.get("method") == Some(&json!("session/request_permission")) {
                return (message["id"].clone(), message["params"].clone());
            }
        }
    }

    fn answer(&mut self, id: Value, option: &str) {
        self.client.notify(
            "tunnel.send",
            json!({
                "instance": self.instance,
                "message": {
                    "jsonrpc": "2.0",
                    "id": id,
                    "result": {"outcome": {"outcome": "selected", "optionId": option}},
                },
            }),
        );
    }

    fn pending_requests(&mut self) -> u64 {
        let response = self.client.request(90, "agent.list", json!({}));
        response["result"]["instances"]
            .as_array()
            .and_then(|instances| {
                instances
                    .iter()
                    .find(|instance| instance["instance"] == self.instance)
            })
            .and_then(|instance| instance["pending_requests"].as_u64())
            .unwrap_or(0)
    }

    fn turns_running(&mut self) -> u64 {
        let response = self.client.request(91, "agent.list", json!({}));
        response["result"]["instances"]
            .as_array()
            .and_then(|instances| {
                instances
                    .iter()
                    .find(|instance| instance["instance"] == self.instance)
            })
            .and_then(|instance| instance["turns_running"].as_u64())
            .unwrap_or(0)
    }

    fn policy_set(&mut self, set: Value) -> Value {
        self.next_id += 1;
        self.client
            .request(self.next_id, "policy.set", json!({"set": set}))
    }

    fn policy_list(&mut self) -> Vec<Value> {
        self.next_id += 1;
        let response = self.client.request(self.next_id, "policy.list", json!({}));
        response["result"]["sets"]
            .as_array()
            .cloned()
            .unwrap_or_default()
    }

    fn policy_clear(&mut self, name: &str) -> Value {
        self.next_id += 1;
        self.client
            .request(self.next_id, "policy.clear", json!({"name": name}))
    }

    fn stop(&mut self) {
        let response = self
            .client
            .request(80, "agent.stop", json!({"instance": self.instance}));
        assert!(response["error"].is_null(), "stop: {response}");
    }

    fn shutdown(&mut self) {
        let _ = self.client.request(99, "shutdown", json!({}));
    }
}

fn unique(name: &str) -> PathBuf {
    static COUNTER: AtomicU64 = AtomicU64::new(0);
    std::env::temp_dir().join(format!(
        "ade-policy-{name}-{}-{}",
        std::process::id(),
        COUNTER.fetch_add(1, Ordering::Relaxed)
    ))
}

fn wait_until<F>(label: &str, mut check: F)
where
    F: FnMut() -> bool,
{
    let deadline = Instant::now() + Duration::from_secs(20);
    while Instant::now() < deadline {
        if check() {
            return;
        }
        std::thread::sleep(Duration::from_millis(20));
    }
    panic!("timed out waiting for {label}");
}

fn log_events(path: &Path) -> Vec<Value> {
    std::fs::read_to_string(path)
        .ok()
        .map(|text| {
            text.lines()
                .filter_map(|line| serde_json::from_str(line).ok())
                .collect()
        })
        .unwrap_or_default()
}

fn wait_permission(path: &Path, index: u64) -> Value {
    wait_until(&format!("permission {index} in {}", path.display()), || {
        log_events(path)
            .into_iter()
            .any(|event| event["event"] == "permission" && event["index"] == index)
    });
    log_events(path)
        .into_iter()
        .find(|event| event["event"] == "permission" && event["index"] == index)
        .expect("permission event")
}

#[test]
fn auto_answers_without_a_front_end_and_records_a_replay_event() {
    let server = TestServer::start("policy-no-frontend");
    let log = unique("no-frontend");
    let gate = unique("no-frontend-gate");
    let env = [
        ("POLICY_AGENT_LOG", log.to_str().unwrap()),
        ("POLICY_AGENT_GATE", gate.to_str().unwrap()),
    ];
    let mut agent = Agent::attach(&server, "no-frontend", &env);
    agent.new_session();
    let response = agent.policy_set(json!({
        "name": "config", "keep": "service",
        "rules": [{"kinds": ["edit"], "choose": ["allow_once"]}],
    }));
    assert!(response["result"].is_object(), "{response}");
    agent.prompt("permission-gate");
    // The agent waits for the gate; detach first, so the request arrives with
    // no front end attached.
    agent
        .client
        .request(50, "agent.detach", json!({"instance": agent.instance}));
    std::fs::write(&gate, "go").expect("gate");
    let event = wait_permission(&log, 1);
    assert_eq!(event["outcome"], "selected", "{event}");
    assert_eq!(event["optionId"], "allow", "{event}");
    wait_until("the agent prompt to finish", || agent.turns_running() == 0);

    // Re-attach and load the session: the synthetic policy update is replayed.
    let response = agent.client.request(
        51,
        "agent.attach",
        json!({
            "key": {
                "agent": "policy",
                "command": "python3",
                "args": [fixture("policy_agent.py").to_string_lossy(), "no-frontend"],
                "cwd": server.dir().to_string_lossy(),
            },
            "client_capabilities": {},
            "env": child_env(&env),
        }),
    );
    assert!(response["result"].is_object(), "{response}");
    agent.next_id += 1;
    let load_id = agent.next_id;
    agent.send_request(
        load_id,
        "session/load",
        json!({"sessionId": agent.session, "cwd": "/tmp/policy", "mcpServers": []}),
    );
    let mut saw_policy = false;
    loop {
        let message = agent.next_tunnel(Duration::from_secs(20));
        if message.get("method") == Some(&json!("session/update")) {
            let update = &message["params"]["update"];
            if update["sessionUpdate"] == "_ade_policy" {
                assert_eq!(update["set"], "config");
                assert_eq!(update["outcome"], "selected");
                assert_eq!(update["optionId"], "allow");
                assert_eq!(update["kind"], "allow_once");
                assert_eq!(update["toolCall"]["kind"], "edit");
                saw_policy = true;
            }
        }
        if message.get("method").is_none() && message["id"] == json!(load_id) {
            break;
        }
    }
    assert!(saw_policy, "the policy event must be replayed");
    let _ = std::fs::remove_file(&log);
    let _ = std::fs::remove_file(&gate);
}

#[test]
fn a_question_is_relayed_and_never_answered_by_policy() {
    let server = TestServer::start("policy-question");
    let mut agent = Agent::attach(&server, "question", &[]);
    agent.new_session();
    agent.policy_set(json!({
        "name": "all", "keep": "service",
        "rules": [{"choose": ["allow_once"]}],
    }));
    agent.prompt("question");
    let (id, params) = agent.recv_permission();
    assert_eq!(params["toolCall"]["rawInput"]["method"], "select");
    assert_eq!(agent.pending_requests(), 1, "a question stays pending");
    // No policy.applied: the request must reach the front end instead.
    assert!(
        agent
            .client
            .try_next_notification(Duration::from_millis(200))
            .is_none(),
        "a question must not be answered by policy"
    );
    agent.answer(id, "a");
    agent.wait_response(agent.next_id);
}

#[test]
fn turn_end_binds_one_prompt_and_other_connections_are_unaffected() {
    let server = TestServer::start("policy-turn");
    let log = unique("turn");
    let gate = unique("turn-gate");
    let env = [
        ("POLICY_AGENT_LOG", log.to_str().unwrap()),
        ("POLICY_AGENT_GATE", gate.to_str().unwrap()),
    ];
    let mut first = Agent::attach(&server, "turn", &env);
    first.new_session();
    first.policy_set(json!({
        "name": "inline", "session": first.session.clone(), "until": "turn_end",
        "priority": 100, "fallback": "cancelled",
        "rules": [{"kinds": ["edit"], "choose": ["allow_once"]}],
    }));
    first.prompt("turn-two");
    wait_permission(&log, 1);

    // A second connection's prompt for the same session is not the set's
    // bound prompt: its request must be relayed.
    let mut second = Agent::attach(&server, "turn", &env);
    second.new_session();
    second.prompt("permission");
    let (id, params) = second.recv_permission();
    assert_eq!(params["toolCall"]["kind"], "edit");
    second.answer(id, "allow");
    second.wait_response(second.next_id);

    std::fs::write(&gate, "go").expect("gate");
    let event = wait_permission(&log, 2);
    assert_eq!(event["outcome"], "selected", "{event}");

    // The prompt is answered: the set is gone, a later request is relayed.
    first.wait_response(first.next_id);
    wait_until("turn_end set removal", || first.policy_list().is_empty());
    // The primary is the second connection, so the relayed request goes there;
    // the set is gone, so it is relayed instead of auto-answered.
    first.prompt("permission");
    let (id, _) = second.recv_permission();
    second.answer(id, "allow");
    first.wait_response(first.next_id);
    let _ = std::fs::remove_file(&log);
    let _ = std::fs::remove_file(&gate);
}

#[test]
fn a_set_installed_during_a_prompt_binds_to_that_prompt() {
    let server = TestServer::start("policy-late-bind");
    let log = unique("late-bind");
    let gate = unique("late-bind-gate");
    let env = [
        ("POLICY_AGENT_LOG", log.to_str().unwrap()),
        ("POLICY_AGENT_GATE", gate.to_str().unwrap()),
    ];
    let mut agent = Agent::attach(&server, "late-bind", &env);
    agent.new_session();
    // The prompt is already running (and waits for the gate) when the set
    // arrives; both frames are on one connection, so the service sees the
    // prompt first.
    let prompt = agent.prompt("permission-gate");
    agent.policy_set(json!({
        "name": "inline", "session": agent.session.clone(), "until": "turn_end",
        "rules": [{"kinds": ["edit"], "choose": ["allow_once"]}],
    }));
    let sets = agent.policy_list();
    assert_eq!(sets[0]["bound"], true, "{sets:?}");
    std::fs::write(&gate, "go").expect("gate");
    let event = wait_permission(&log, 1);
    assert_eq!(event["outcome"], "selected", "{event}");
    agent.wait_response(prompt);
    let _ = std::fs::remove_file(&log);
    let _ = std::fs::remove_file(&gate);
}

#[test]
fn an_exited_instance_drops_its_bound_turn_sets() {
    let server = TestServer::start("policy-exit");
    let log = unique("exit");
    let gate = unique("exit-gate");
    let env = [
        ("POLICY_AGENT_LOG", log.to_str().unwrap()),
        ("POLICY_AGENT_GATE", gate.to_str().unwrap()),
    ];
    let mut owner = Agent::attach(&server, "exit", &env);
    owner.new_session();
    let session = owner.session.clone();
    owner.policy_set(json!({
        "name": "inline", "session": session.clone(), "until": "turn_end",
        "rules": [{"kinds": ["edit"], "choose": ["allow_once"]}],
    }));
    owner.prompt("turn-two");
    wait_permission(&log, 1);
    owner.stop();
    wait_until("bound set removal on exit", || {
        owner.policy_list().is_empty()
    });

    // A new instance on the same session id must not inherit the old rules.
    let mut next = Agent::attach(&server, "exit", &env);
    next.session = session;
    assert!(next.policy_list().is_empty());
    next.prompt("permission");
    let (id, _) = next.recv_permission();
    assert_eq!(next.pending_requests(), 1);
    next.answer(id, "allow");
    next.wait_response(next.next_id);
    let _ = std::fs::remove_file(&log);
    let _ = std::fs::remove_file(&gate);
}

#[test]
fn cancel_makes_the_bound_turn_cancelling() {
    let server = TestServer::start("policy-cancel");
    let log = unique("cancel");
    let gate = unique("cancel-gate");
    let env = [
        ("POLICY_AGENT_LOG", log.to_str().unwrap()),
        ("POLICY_AGENT_GATE", gate.to_str().unwrap()),
    ];
    let mut agent = Agent::attach(&server, "cancel", &env);
    agent.new_session();
    agent.policy_set(json!({
        "name": "inline", "session": agent.session.clone(), "until": "turn_end",
        "rules": [{"choose": ["allow_once"]}],
    }));
    agent.prompt("turn-two");
    wait_permission(&log, 1);
    agent.send_notification("session/cancel", json!({"sessionId": agent.session}));
    std::fs::write(&gate, "go").expect("gate");
    let event = wait_permission(&log, 2);
    assert_eq!(event["outcome"], "cancelled", "{event}");
    assert!(event["optionId"].is_null(), "{event}");
    let _ = std::fs::remove_file(&log);
    let _ = std::fs::remove_file(&gate);
}

#[test]
fn a_lost_connection_drops_connection_sets_but_keeps_a_bound_turn() {
    let server = TestServer::start("policy-close");
    let log = unique("close");
    let gate = unique("close-gate");
    let env = [
        ("POLICY_AGENT_LOG", log.to_str().unwrap()),
        ("POLICY_AGENT_GATE", gate.to_str().unwrap()),
    ];
    let mut owner = Agent::attach(&server, "close", &env);
    owner.new_session();
    owner.policy_set(json!({
        "name": "connection", "rules": [{"choose": ["allow_once"]}],
    }));
    owner.policy_set(json!({
        "name": "service", "keep": "service", "rules": [{"choose": ["allow_once"]}],
    }));
    owner.policy_set(json!({
        "name": "inline", "session": owner.session.clone(), "until": "turn_end",
        "rules": [{"choose": ["allow_once"]}],
    }));
    owner.prompt("turn-two");
    wait_permission(&log, 1);

    let mut watcher = Agent::attach(&server, "close", &env);
    watcher.session = owner.session.clone();
    drop(owner.client);
    let deadline = Instant::now() + Duration::from_secs(10);
    while Instant::now() < deadline && watcher.policy_list().len() > 2 {
        std::thread::sleep(Duration::from_millis(20));
    }
    let sets = watcher.policy_list();
    let names: Vec<&str> = sets.iter().filter_map(|set| set["name"].as_str()).collect();
    assert!(names.contains(&"service"), "{sets:?}");
    assert!(!names.contains(&"connection"), "{sets:?}");
    let inline = sets
        .iter()
        .find(|set| set["name"] == "inline")
        .expect("bound turn survives");
    assert_eq!(inline["bound"], true, "{inline}");

    std::fs::write(&gate, "go").expect("gate");
    let event = wait_permission(&log, 2);
    assert_eq!(
        event["outcome"], "selected",
        "the adopted prompt keeps its rules"
    );
    wait_until("bound turn removal", || watcher.policy_list().len() == 1);
    let _ = std::fs::remove_file(&log);
    let _ = std::fs::remove_file(&gate);
}

#[test]
fn applied_is_broadcast_with_the_documented_fields() {
    let server = TestServer::start("policy-applied");
    let mut first = Agent::attach(&server, "applied", &[]);
    first.new_session();
    first.policy_set(json!({
        "name": "config", "keep": "service",
        "rules": [{"kinds": ["edit"], "choose": ["allow_once"]}],
    }));
    let mut second = Agent::attach(&server, "applied", &[]);
    second.session = first.session.clone();
    first.prompt("permission");
    let applied = first.next_applied(Duration::from_secs(20));
    assert_eq!(applied["instance"], first.instance);
    assert_eq!(applied["sessionId"], first.session);
    assert_eq!(applied["set"], "config");
    assert_eq!(applied["outcome"], "selected");
    assert_eq!(applied["optionId"], "allow");
    assert_eq!(applied["kind"], "allow_once");
    assert_eq!(applied["toolCall"]["kind"], "edit");
    let other = second.next_applied(Duration::from_secs(20));
    assert_eq!(other["optionId"], "allow");
    // The request was answered by policy: nothing was added to the pending set.
    assert_eq!(first.pending_requests(), 0);
}

#[test]
fn priority_and_agent_filters_pick_the_right_set() {
    let server = TestServer::start("policy-filters");
    let mut agent = Agent::attach(&server, "filters", &[]);
    agent.new_session();
    agent.policy_set(json!({
        "name": "wrong-agent", "agent": "other", "priority": 1000,
        "rules": [{"choose": ["allow_once"]}],
    }));
    agent.policy_set(json!({
        "name": "right-agent", "agent": "policy", "priority": 10,
        "rules": [{"choose": ["reject_once"]}],
    }));
    agent.prompt("permission");
    let applied = agent.next_applied(Duration::from_secs(20));
    assert_eq!(applied["set"], "right-agent");
    assert_eq!(applied["optionId"], "reject");
    assert_eq!(applied["kind"], "reject_once");
}

#[test]
fn a_large_tool_call_is_omitted_from_the_replayed_policy_event() {
    let server = TestServer::start("policy-large");
    let mut agent = Agent::attach(&server, "large", &[]);
    agent.new_session();
    agent.policy_set(json!({
        "name": "config", "keep": "service",
        "rules": [{"kinds": ["edit"], "choose": ["allow_once"]}],
    }));
    agent.prompt("large:70k");
    let applied = agent.next_applied(Duration::from_secs(20));
    assert!(
        applied["toolCall"]["rawInput"]
            .as_str()
            .unwrap_or_default()
            .len()
            > 64 * 1024,
        "policy.applied carries the unchanged toolCall"
    );
    agent.next_id += 1;
    let load_id = agent.next_id;
    agent.send_request(
        load_id,
        "session/load",
        json!({"sessionId": agent.session, "cwd": "/tmp/policy", "mcpServers": []}),
    );
    let mut saw = false;
    loop {
        let message = agent.next_tunnel(Duration::from_secs(20));
        if message.get("method") == Some(&json!("session/update")) {
            let update = &message["params"]["update"];
            if update["sessionUpdate"] == "_ade_policy" {
                assert_eq!(update["toolCall"]["rawInput"], "[omitted]");
                assert_eq!(update["toolCall"]["content"], "[omitted]");
                saw = true;
            }
        }
        if message.get("method").is_none() && message["id"] == json!(load_id) {
            break;
        }
    }
    assert!(
        saw,
        "the large policy event must still be replayed, with omissions"
    );
}

#[test]
fn validation_list_and_clear() {
    let server = TestServer::start("policy-list");
    let mut agent = Agent::attach(&server, "list", &[]);
    agent.new_session();
    let invalid = agent.policy_set(json!({
        "name": "bad", "rules": [{"choose": ["maybe"]}],
    }));

    assert_eq!(invalid["error"]["code"], -32050, "{invalid}");
    assert!(invalid["error"]["message"]
        .as_str()
        .unwrap_or_default()
        .contains("choose"));
    assert!(agent.policy_list().is_empty());

    agent.policy_set(json!({"name": "mine", "rules": [{"choose": ["allow_once"]}]}));
    let sets = agent.policy_list();
    assert_eq!(sets.len(), 1, "{sets:?}");
    assert!(sets[0]["owner"].is_number(), "{sets:?}");
    assert!(sets[0]["installed_at"].is_number(), "{sets:?}");
    assert_eq!(sets[0]["bound"], false);

    let cleared = agent.policy_clear("mine");
    assert_eq!(cleared["result"]["removed"], true);
    let cleared = agent.policy_clear("mine");
    assert_eq!(cleared["result"]["removed"], false);
    agent.shutdown();
}

#[test]
fn session_filter_mismatch_is_relayed() {
    let server = TestServer::start("policy-session");
    let mut agent = Agent::attach(&server, "session-filter", &[]);
    agent.new_session();
    agent.policy_set(json!({
        "name": "other-session", "session": "not-this-one",
        "rules": [{"choose": ["allow_once"]}],
    }));
    agent.prompt("permission");
    let (id, _) = agent.recv_permission();
    assert_eq!(agent.pending_requests(), 1);
    agent.answer(id, "allow");
    agent.wait_response(agent.next_id);
}
