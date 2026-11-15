//! Integration tests for the api_version 2 tunnel: agent processes, the relay
//! rules, `agent.*` methods and the notifications.
//!
//! Everything here is unix-only: the tests drive real processes and signals,
//! and the mock agent is a Python script. Every path lives in a private
//! temporary directory (see `common/mod.rs`).

#![cfg(unix)]

mod common;

use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::time::{Duration, Instant};

use common::{TempDir, TestServer};
use serde_json::{json, Value};

/// Path of `tests/mock_agent.py` in the repository root.
fn mock_agent() -> PathBuf {
    let mut path = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
    path.pop();
    path.push("tests");
    path.push("mock_agent.py");
    assert!(path.is_file(), "mock agent not found at {}", path.display());
    path
}

struct Agent {
    client: common::Client,
    instance: String,
    pid: u64,
}

impl Agent {
    /// Attach with a fresh key, sending `initialize` and waiting for its
    /// response.
    fn attach(server: &TestServer, label: &str) -> Self {
        Self::attach_with(server, label, HashMap::new())
    }

    fn attach_with(server: &TestServer, label: &str, env: HashMap<String, String>) -> Self {
        let mut client = server.connect();
        client.hello(&server.token(), 2);
        let key = json!({
            "agent": "mock",
            "command": "python3",
            "args": [mock_agent().to_string_lossy(), label],
            "cwd": server.dir().to_string_lossy(),
        });
        let mut params = json!({
            "key": key,
            "client_capabilities": {"fs": {"readTextFile": true}, "terminal": true},
        });
        if !env.is_empty() {
            params["env"] = json!(env);
        }
        let response = client.request(2, "agent.attach", params);
        assert!(response["result"].is_object(), "attach failed: {response}");
        let instance = response["result"]["instance"]
            .as_str()
            .expect("instance id")
            .to_string();
        let pid = response["result"]["pid"].as_u64().expect("pid");
        let initialized = response["result"]["initialized"].as_bool().unwrap();
        assert!(!initialized, "a fresh instance is not initialized");
        Self {
            client,
            instance,
            pid,
        }
    }

    fn send(&mut self, message: Value) {
        self.client.notify(
            "tunnel.send",
            json!({"instance": self.instance, "message": message}),
        );
    }

    fn request(&mut self, id: Value, method: &str, params: Value) {
        self.send(json!({"jsonrpc": "2.0", "id": id, "method": method, "params": params}));
    }

    /// Wait for the next `tunnel.recv` for this instance and return its message.
    fn recv(&mut self) -> Value {
        let notification = self.client.next_notification(Duration::from_secs(15));
        match notification["method"].as_str() {
            Some("tunnel.recv") => {
                assert_eq!(notification["params"]["instance"], self.instance);
                notification["params"]["message"].clone()
            }
            Some("tunnel.error" | "agent.exited") => {
                panic!("unexpected notification: {notification}")
            }
            other => panic!("unexpected notification {other:?}: {notification}"),
        }
    }

    /// Receive messages until one has the given id (and no method).
    fn recv_response(&mut self, id: &Value) -> Value {
        loop {
            let message = self.recv();
            if message.get("method").is_none() && &message["id"] == id {
                return message;
            }
        }
    }

    fn initialize(&mut self, frontend_id: Value) -> Value {
        self.request(
            frontend_id.clone(),
            "initialize",
            json!({
                "protocolVersion": 1,
                "clientCapabilities": {"fs": {"readTextFile": true}, "terminal": true},
            }),
        );
        self.recv_response(&frontend_id)
    }
}

fn number_of_files(dir: &Path) -> usize {
    std::fs::read_dir(dir)
        .map(|entries| entries.count())
        .unwrap_or(0)
}

#[test]
fn attach_initializes_and_maps_ids_back() {
    let server = TestServer::start("agent-initialize");
    let mut agent = Agent::attach(&server, "init");

    let response = agent.initialize(json!("hello-1"));
    assert_eq!(response["id"], "hello-1");
    assert_eq!(response["result"]["protocolVersion"], 1);
    assert!(response["result"]["agentCapabilities"].is_object());

    // The instance is listed with the documented fields.
    let list = agent.client.request(3, "agent.list", json!({}));
    let instances = list["result"]["instances"].as_array().expect("instances");
    assert_eq!(instances.len(), 1);
    let summary = &instances[0];
    assert_eq!(summary["instance"], agent.instance);
    assert_eq!(summary["agent"], "mock");
    assert_eq!(summary["pid"], agent.pid);
    assert_eq!(summary["initialized"], true);
    assert_eq!(summary["attached"], 1);
    assert_eq!(summary["turns_running"], 0);
    assert_eq!(summary["pending_requests"], 0);
    assert!(summary["started_at"].as_u64().unwrap_or(0) > 0);
    assert_eq!(summary["cwd"], server.dir().to_string_lossy().as_ref());
}

#[test]
fn a_second_attach_reuses_the_instance_and_caches_initialize() {
    let server = TestServer::start("agent-reuse");
    let mut first = Agent::attach(&server, "shared");
    let result = first.initialize(json!(1));
    let cached = result["result"].clone();

    // A second connection with the same key finds the running instance.
    let mut second = server.connect();
    second.hello(&server.token(), 2);
    let response = second.request(
        2,
        "agent.attach",
        json!({
            "key": {
                "agent": "mock",
                "command": "python3",
                "args": [mock_agent().to_string_lossy(), "shared"],
                "cwd": server.dir().to_string_lossy(),
            },
            "client_capabilities": {"fs": {"readTextFile": true}, "terminal": true},
        }),
    );
    assert_eq!(response["result"]["created"], false);
    assert_eq!(response["result"]["initialized"], true);
    assert_eq!(response["result"]["attached"], 2);
    assert_eq!(response["result"]["instance"], first.instance);

    // Its `initialize` is answered from the cache, without the agent seeing it.
    second.notify(
        "tunnel.send",
        json!({
            "instance": first.instance,
            "message": {
                "jsonrpc": "2.0",
                "id": 77,
                "method": "initialize",
                "params": {
                    "clientCapabilities": {"fs": {"readTextFile": true}, "terminal": true},
                },
            },
        }),
    );
    let reply = second.next_tunnel_recv(Duration::from_secs(10));
    assert_eq!(reply["message"]["id"], 77);
    assert_eq!(reply["message"]["result"], cached);
}

#[test]
fn two_connections_get_their_own_responses() {
    let server = TestServer::start("agent-two-conns");
    let mut first = Agent::attach(&server, "two");
    first.initialize(json!(1));

    let mut second = server.connect();
    second.hello(&server.token(), 2);
    second.request(
        2,
        "agent.attach",
        json!({
            "key": {
                "agent": "mock",
                "command": "python3",
                "args": [mock_agent().to_string_lossy(), "two"],
                "cwd": server.dir().to_string_lossy(),
            },
            "client_capabilities": {"fs": {"readTextFile": true}, "terminal": true},
        }),
    );

    // Same front-end id on both connections; the service must keep them apart.
    first.request(
        json!("same"),
        "session/new",
        json!({"cwd": server.dir().to_string_lossy(), "mcpServers": []}),
    );
    second.notify(
        "tunnel.send",
        json!({
            "instance": first.instance,
            "message": {
                "jsonrpc": "2.0",
                "id": "same",
                "method": "session/new",
                "params": {"cwd": server.dir().to_string_lossy(), "mcpServers": []},
            },
        }),
    );

    let first_reply = first.recv_response(&json!("same"));
    let second_reply = second.next_tunnel_recv(Duration::from_secs(10))["message"].clone();
    assert_eq!(first_reply["id"], "same");
    assert_eq!(second_reply["id"], "same");
    assert!(first_reply["result"]["sessionId"].is_string());
    assert!(second_reply["result"]["sessionId"].is_string());
}

#[test]
fn permission_requests_reach_the_primary_and_move_with_it() {
    let server = TestServer::start("agent-permission");
    let mut first = Agent::attach(&server, "perm");
    first.initialize(json!(1));

    // The prompt triggers a permission request from the mock agent.
    let session = first.client.request(3, "agent.list", json!({}));
    assert!(session["result"].is_object());
    first.request(
        json!(10),
        "session/new",
        json!({"cwd": server.dir().to_string_lossy(), "mcpServers": []}),
    );
    let new_session = first.recv_response(&json!(10));
    let session_id = new_session["result"]["sessionId"]
        .as_str()
        .unwrap()
        .to_string();
    first.request(
        json!(11),
        "session/prompt",
        json!({
            "sessionId": session_id,
            "prompt": [{"type": "text", "text": "please ask for permission"}],
        }),
    );

    // Both the prompt updates and the permission request arrive; only the
    // primary (here: the only connection) gets the request.
    let mut permission = None;
    for _ in 0..20 {
        let message = first.recv();
        if message["method"] == "session/request_permission" {
            permission = Some(message);
            break;
        }
    }
    let permission = permission.expect("a permission request");
    let permission_id = permission["id"].clone();
    assert_eq!(permission_id, json!(9001));

    // Answer it: the agent finishes the turn.
    first.send(json!({"jsonrpc": "2.0", "id": permission_id, "result": {
        "outcome": {"outcome": "selected", "optionId": "allow"}
    }}));
    let done = first.recv_response(&json!(11));
    assert_eq!(done["result"]["stopReason"], "end_turn");

    let list = first.client.request(5, "agent.list", json!({}));
    assert_eq!(list["result"]["instances"][0]["pending_requests"], 0);
    assert_eq!(list["result"]["instances"][0]["turns_running"], 0);
}

#[test]
fn a_pending_permission_is_replayed_to_a_reconnecting_frontend() {
    let server = TestServer::start("agent-permission-replay");
    let mut first = Agent::attach(&server, "perm-replay");
    first.initialize(json!(1));
    first.request(
        json!(10),
        "session/new",
        json!({"cwd": server.dir().to_string_lossy(), "mcpServers": []}),
    );
    let session_id = first.recv_response(&json!(10))["result"]["sessionId"]
        .as_str()
        .unwrap()
        .to_string();
    first.request(
        json!(11),
        "session/prompt",
        json!({
            "sessionId": session_id,
            "prompt": [{"type": "text", "text": "permission please"}],
        }),
    );

    // Wait until the permission request is pending, then drop the front end.
    let instance = first.instance.clone();
    loop {
        let message = first.recv();
        if message["method"] == "session/request_permission" {
            break;
        }
    }
    drop(first);

    // The agent keeps running; the request stays pending. The disconnect is
    // processed asynchronously, so wait for the service to notice it.
    let mut second = server.connect();
    second.hello(&server.token(), 2);
    let deadline = Instant::now() + Duration::from_secs(10);
    let summary = loop {
        let list = second.request(2, "agent.list", json!({}));
        let summary = list["result"]["instances"][0].clone();
        if summary["attached"] == 0 {
            break summary;
        }
        assert!(
            Instant::now() < deadline,
            "the service never noticed the disconnect: {summary}"
        );
        std::thread::sleep(Duration::from_millis(20));
    };
    assert_eq!(summary["instance"], instance);
    assert_eq!(summary["pending_requests"], 1);

    let attach = second.request(
        3,
        "agent.attach",
        json!({
            "key": {
                "agent": "mock",
                "command": "python3",
                "args": [mock_agent().to_string_lossy(), "perm-replay"],
                "cwd": server.dir().to_string_lossy(),
            },
            "client_capabilities": {"fs": {"readTextFile": true}, "terminal": true},
        }),
    );
    assert_eq!(attach["result"]["created"], false);
    assert_eq!(attach["result"]["pid"], agent_pid(&summary));

    // The pending request is delivered again to the new primary.
    let deadline = Instant::now() + Duration::from_secs(15);
    loop {
        let replay = second.next_tunnel_recv(Duration::from_secs(15));
        if replay["message"]["method"] == "session/request_permission" {
            assert_eq!(replay["message"]["id"], 9001);
            break;
        }
        assert!(
            Instant::now() < deadline,
            "the permission request was not replayed"
        );
    }
}

fn agent_pid(summary: &Value) -> u64 {
    summary["pid"].as_u64().expect("pid")
}

#[test]
fn cancelling_translates_the_request_id() {
    let server = TestServer::start("agent-cancel");
    let mut agent = Agent::attach(&server, "cancel");
    agent.initialize(json!(1));
    agent.request(
        json!(20),
        "session/new",
        json!({"cwd": server.dir().to_string_lossy(), "mcpServers": []}),
    );
    let session_id = agent.recv_response(&json!(20))["result"]["sessionId"]
        .as_str()
        .unwrap()
        .to_string();
    // A slow turn that only ends on cancellation.
    agent.request(
        json!(21),
        "session/prompt",
        json!({
            "sessionId": session_id,
            "prompt": [{"type": "text", "text": "slow"}],
        }),
    );
    // The mock streams "working" before waiting for the cancel.
    loop {
        let message = agent.recv();
        if message["method"] == "session/update" {
            break;
        }
    }
    agent.client.notify(
        "tunnel.send",
        json!({
            "instance": agent.instance,
            "message": {"jsonrpc": "2.0", "method": "$/cancel_request", "params": {"id": 21}},
        }),
    );
    let done = agent.recv_response(&json!(21));
    assert_eq!(done["result"]["stopReason"], "cancelled");

    let list = agent.client.request(9, "agent.list", json!({}));
    assert_eq!(list["result"]["instances"][0]["turns_running"], 0);
}

#[test]
fn agent_exit_reports_stderr_and_then_rejects_sends() {
    let server = TestServer::start("agent-exit");
    let mut agent = Agent::attach(&server, "exit");
    agent.initialize(json!(1));

    // The mock exits when stdin closes; ask the service to stop it cleanly.
    let instance = agent.instance.clone();
    let stop = agent
        .client
        .request(2, "agent.stop", json!({"instance": instance}));
    assert_eq!(stop["result"]["exited"], true);
    assert_eq!(stop["result"]["code"], 0);

    // `agent.exited` reaches the attached connection.
    let exited = agent.client.next_notification(Duration::from_secs(10));
    assert_eq!(exited["method"], "agent.exited");
    assert_eq!(exited["params"]["instance"], instance);
    assert!(exited["params"].get("stderr_tail").is_some());

    // The instance is gone: sends are rejected.
    agent.client.notify(
        "tunnel.send",
        json!({
            "instance": instance,
            "message": {"jsonrpc": "2.0", "id": 1, "method": "session/new", "params": {}},
        }),
    );
    let error = agent.client.next_notification(Duration::from_secs(10));
    assert_eq!(error["method"], "tunnel.error");
    assert_eq!(error["params"]["code"], -32020);

    let list = agent.client.request(3, "agent.list", json!({}));
    assert_eq!(list["result"]["instances"], json!([]));
}

/// A small script whose behaviour is chosen by its first argument.
fn write_stubborn_agent(dir: &Path, name: &str, script: &str) -> PathBuf {
    let path = dir.join(name);
    std::fs::write(&path, script).expect("write agent script");
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o755)).expect("chmod");
    }
    path
}

fn attach_custom(server: &TestServer, command: &Path, args: &[&str]) -> (common::Client, String) {
    let mut client = server.connect();
    client.hello(&server.token(), 2);
    let response = client.request(
        2,
        "agent.attach",
        json!({
            "key": {
                "agent": "custom",
                "command": command.to_string_lossy(),
                "args": args,
                "cwd": server.dir().to_string_lossy(),
            },
            "client_capabilities": {},
        }),
    );
    assert!(response["result"].is_object(), "attach failed: {response}");
    (
        client,
        response["result"]["instance"].as_str().unwrap().to_string(),
    )
}

#[test]
fn stop_escalates_through_sigterm_and_sigkill() {
    let server = TestServer::start_with(
        "agent-stop-escalation",
        &["--idle-timeout", "600"],
        &[("NVIM_ADE_SERVER_STOP_TIMEOUT_MS", "300")],
    );
    let script = write_stubborn_agent(
        server.dir(),
        "ignores-signals.sh",
        "#!/bin/sh\ntrap '' TERM INT\nwhile true; do sleep 0.05; done\n",
    );
    let (mut client, instance) = attach_custom(&server, &script, &[]);

    let started = Instant::now();
    let response = client.request(2, "agent.stop", json!({"instance": instance}));
    assert_eq!(response["result"]["exited"], true, "response: {response}");
    assert_eq!(response["result"]["signal"], "SIGKILL");
    assert!(
        started.elapsed() < Duration::from_secs(10),
        "the stop sequence finished, elapsed {:?}",
        started.elapsed()
    );
}

#[test]
fn stop_force_skips_the_graceful_steps() {
    let server = TestServer::start("agent-stop-force");
    let script = write_stubborn_agent(
        server.dir(),
        "ignores-signals.sh",
        "#!/bin/sh\ntrap '' TERM INT\nwhile true; do sleep 0.05; done\n",
    );
    let (mut client, instance) = attach_custom(&server, &script, &[]);
    let started = Instant::now();
    let response = client.request(
        2,
        "agent.stop",
        json!({"instance": instance, "force": true}),
    );
    assert_eq!(response["result"]["signal"], "SIGKILL");
    assert!(
        started.elapsed() < Duration::from_secs(5),
        "force does not wait for the grace periods, elapsed {:?}",
        started.elapsed()
    );
}

#[test]
fn stop_kills_children_of_the_agent() {
    let server = TestServer::start_with(
        "agent-stop-children",
        &["--idle-timeout", "600"],
        &[("NVIM_ADE_SERVER_STOP_TIMEOUT_MS", "300")],
    );
    let pid_file = server.dir().join("child.pid");
    let script = write_stubborn_agent(
        server.dir(),
        "spawns-child.sh",
        &format!(
            "#!/bin/sh\ntrap '' TERM INT\nsleep 60 &\necho $! > {}\nwait\n",
            pid_file.display()
        ),
    );
    let (mut client, instance) = attach_custom(&server, &script, &[]);

    // Wait until the child exists.
    let deadline = Instant::now() + Duration::from_secs(10);
    let child_pid = loop {
        if let Ok(text) = std::fs::read_to_string(&pid_file) {
            if let Ok(pid) = text.trim().parse::<u32>() {
                break pid;
            }
        }
        assert!(Instant::now() < deadline, "the agent never started a child");
        std::thread::sleep(Duration::from_millis(20));
    };

    let response = client.request(2, "agent.stop", json!({"instance": instance}));
    assert_eq!(response["result"]["exited"], true);

    // The child is gone too (the whole process group was signalled).
    let deadline = Instant::now() + Duration::from_secs(10);
    loop {
        let alive = PathBuf::from(format!("/proc/{child_pid}")).exists();
        if !alive {
            break;
        }
        assert!(
            Instant::now() < deadline,
            "the child process {child_pid} survived the stop"
        );
        std::thread::sleep(Duration::from_millis(20));
    }
}

#[test]
fn large_messages_survive_and_too_long_agent_lines_are_dropped() {
    let server = TestServer::start("agent-large");
    let script = write_stubborn_agent(
        server.dir(),
        "echo-agent.py",
        r#"#!/usr/bin/env python3
import json, sys
for line in sys.stdin:
    message = json.loads(line)
    if message.get("method") == "big":
        payload = message["params"]["payload"]
        sys.stdout.write(json.dumps({"jsonrpc": "2.0", "id": message["id"], "result": {"length": len(payload)}}) + "\n")
        sys.stdout.flush()
    elif message.get("method") == "huge":
        # A line above the 32 MiB agent limit, then a normal response.
        sys.stdout.write("x" * (33 * 1024 * 1024))
        sys.stdout.write("\n")
        sys.stdout.flush()
        sys.stdout.write(json.dumps({"jsonrpc": "2.0", "id": message["id"], "result": {"ok": True}}) + "\n")
        sys.stdout.flush()
"#,
    );
    let (mut client, instance) = attach_custom(&server, &script, &[]);

    // 8 MiB there and back, intact.
    let payload = "a".repeat(8 * 1024 * 1024);
    client.notify(
        "tunnel.send",
        json!({
            "instance": instance,
            "message": {"jsonrpc": "2.0", "id": 1, "method": "big", "params": {"payload": payload}},
        }),
    );
    let reply = client.next_tunnel_recv(Duration::from_secs(30));
    assert_eq!(reply["message"]["result"]["length"], 8 * 1024 * 1024);

    // A 33 MiB agent line is dropped and reported, and the next message works.
    client.notify(
        "tunnel.send",
        json!({
            "instance": instance,
            "message": {"jsonrpc": "2.0", "id": 10, "method": "huge", "params": {}},
        }),
    );
    let error = client.next_notification(Duration::from_secs(30));
    assert_eq!(error["method"], "tunnel.error");
    assert_eq!(error["params"]["code"], -32025);
    // The error is reported, and the agent's next line still arrives (the
    // response to the very same request).
    let reply = client.next_tunnel_recv(Duration::from_secs(30));
    assert_eq!(reply["message"]["id"], 10);
    assert_eq!(reply["message"]["result"]["ok"], true);
}

#[test]
fn tunnel_send_requires_an_attached_connection() {
    let server = TestServer::start("tunnel-not-attached");
    let mut owner = Agent::attach(&server, "owner");
    owner.initialize(json!(1));

    let mut stranger = server.connect();
    stranger.hello(&server.token(), 2);
    stranger.notify(
        "tunnel.send",
        json!({
            "instance": owner.instance,
            "message": {"jsonrpc": "2.0", "id": 1, "method": "session/new", "params": {}},
        }),
    );
    let error = stranger.next_notification(Duration::from_secs(10));
    assert_eq!(error["method"], "tunnel.error");
    assert_eq!(error["params"]["code"], -32024);
    assert_eq!(error["params"]["id"], 1);
}

#[test]
fn detach_keeps_the_agent_running_and_reconnect_finds_it() {
    let server = TestServer::start("agent-detach");
    let mut first = Agent::attach(&server, "detach");
    first.initialize(json!(1));
    let instance = first.instance.clone();
    let pid = first.pid;

    let detached = first
        .client
        .request(3, "agent.detach", json!({"instance": instance}));
    assert_eq!(detached["result"], json!({}));

    // Still running, now with no attached connection.
    let list = first.client.request(4, "agent.list", json!({}));
    let summary = &list["result"]["instances"][0];
    assert_eq!(summary["instance"], instance);
    assert_eq!(summary["attached"], 0);
    assert_eq!(summary["pid"], pid);
    drop(first);

    // A new connection attaches to the same instance, created = false.
    let mut second = server.connect();
    second.hello(&server.token(), 2);
    let attached = second.request(
        2,
        "agent.attach",
        json!({
            "key": {
                "agent": "mock",
                "command": "python3",
                "args": [mock_agent().to_string_lossy(), "detach"],
                "cwd": server.dir().to_string_lossy(),
            },
            "client_capabilities": {"fs": {"readTextFile": true}, "terminal": true},
        }),
    );
    assert_eq!(attached["result"]["created"], false);
    assert_eq!(attached["result"]["instance"], instance);
    assert_eq!(attached["result"]["pid"], pid);
    assert_eq!(attached["result"]["initialized"], true);
}

#[test]
fn shutting_down_stops_every_agent() {
    let server = TestServer::start("agent-shutdown");
    let agent = Agent::attach(&server, "shutdown");
    let pid = agent.pid;
    let mut client = agent.client;
    client.call(2, "shutdown");

    // The service exits and the agent is gone.
    let deadline = Instant::now() + Duration::from_secs(15);
    loop {
        let alive = PathBuf::from(format!("/proc/{pid}")).exists();
        if !alive {
            break;
        }
        assert!(Instant::now() < deadline, "agent {pid} still running");
        std::thread::sleep(Duration::from_millis(20));
    }
}

#[test]
fn idle_exit_waits_for_a_running_turn() {
    let server = TestServer::start_with("idle-busy-turn", &["--idle-timeout", "1"], &[]);
    let mut agent = Agent::attach(&server, "idle-busy");
    agent.initialize(json!(1));
    agent.request(
        json!(10),
        "session/new",
        json!({"cwd": server.dir().to_string_lossy(), "mcpServers": []}),
    );
    let session_id = agent.recv_response(&json!(10))["result"]["sessionId"]
        .as_str()
        .unwrap()
        .to_string();
    // "slow" runs for about 5 s: the service must not exit while it runs.
    agent.request(
        json!(11),
        "session/prompt",
        json!({
            "sessionId": session_id,
            "prompt": [{"type": "text", "text": "slow"}],
        }),
    );
    // Wait for the first streamed update, so the turn is definitely running.
    loop {
        let message = agent.recv();
        if message["method"] == "session/update" {
            break;
        }
    }
    drop(agent.client);

    // Give the idle timeout several chances to fire.
    std::thread::sleep(Duration::from_millis(1500));
    let mut probe = server.connect();
    probe.hello(&server.token(), 2);
    let list = probe.request(2, "agent.list", json!({}));
    assert!(
        !list["result"]["instances"].as_array().unwrap().is_empty(),
        "the busy instance kept the service alive"
    );
    assert_eq!(list["result"]["instances"][0]["turns_running"], 1);
}

#[test]
fn env_replaces_the_service_environment_completely() {
    let server = TestServer::start("agent-env");
    let dir = TempDir::new("agent-env-sink");
    let report = dir.join("env.json");
    let script = write_stubborn_agent(
        server.dir(),
        "report-env.py",
        &format!(
            r#"#!/usr/bin/env python3
import json, os, sys
with open({:?}, "w") as handle:
    json.dump({{"agent": os.environ.get("AGENT_VISIBLE"), "leaked": os.environ.get("NVIM_ADE_SERVER_DIR"), "path": os.environ.get("PATH")}}, handle)
for line in sys.stdin:
    message = json.loads(line)
    if message.get("method") == "ping":
        sys.stdout.write(json.dumps({{"jsonrpc": "2.0", "id": message["id"], "result": {{}}}}) + "\n")
        sys.stdout.flush()
"#,
            report.display().to_string()
        ),
    );

    let mut client = server.connect();
    client.hello(&server.token(), 2);
    let mut env = HashMap::new();
    env.insert("AGENT_VISIBLE", "yes");
    let response = client.request(
        2,
        "agent.attach",
        json!({
            "key": {
                "agent": "custom",
                "command": script.to_string_lossy(),
                "args": [],
                "cwd": server.dir().to_string_lossy(),
            },
            "client_capabilities": {},
            "env": env,
        }),
    );
    assert!(response["result"].is_object(), "attach failed: {response}");

    // Wait for the script to write its report.
    let deadline = Instant::now() + Duration::from_secs(10);
    let text = loop {
        if let Ok(text) = std::fs::read_to_string(&report) {
            break text;
        }
        assert!(
            Instant::now() < deadline,
            "the agent never wrote its report"
        );
        std::thread::sleep(Duration::from_millis(20));
    };
    let parsed: Value = serde_json::from_str(&text).expect("report is JSON");
    assert_eq!(parsed["agent"], "yes", "the given env is visible");
    assert_eq!(
        parsed["leaked"],
        Value::Null,
        "the service env is not passed on"
    );
    assert_eq!(
        parsed["path"],
        Value::Null,
        "env is complete, not inherited"
    );
}

#[test]
fn agent_list_starts_empty_and_never_touches_other_servers() {
    let server = TestServer::start("agent-list-empty");
    let mut client = server.connect();
    client.hello(&server.token(), 2);
    let list = client.request(2, "agent.list", json!({}));
    assert_eq!(list["result"]["instances"], json!([]));
    // The service directory holds its socket, token and lock, nothing else.
    assert!(number_of_files(server.dir()) >= 3);
}

#[test]
fn a_repeated_attach_does_not_replay_pending_requests() {
    let server = TestServer::start("agent-replay-once");
    let mut agent = Agent::attach(&server, "replay-once");
    agent.initialize(json!(1));
    agent.request(
        json!(10),
        "session/new",
        json!({"cwd": server.dir().to_string_lossy(), "mcpServers": []}),
    );
    let session_id = agent.recv_response(&json!(10))["result"]["sessionId"]
        .as_str()
        .unwrap()
        .to_string();
    agent.request(
        json!(11),
        "session/prompt",
        json!({
            "sessionId": session_id,
            "prompt": [{"type": "text", "text": "permission please"}],
        }),
    );
    // Deliver the permission request to this connection.
    loop {
        let message = agent.recv();
        if message["method"] == "session/request_permission" {
            break;
        }
    }

    let key = json!({
        "agent": "mock",
        "command": "python3",
        "args": [mock_agent().to_string_lossy(), "replay-once"],
        "cwd": server.dir().to_string_lossy(),
    });
    // Attaching again from the same connection must not replay the request:
    // the front end already has it and would show a second permission prompt.
    let again = agent.client.request(
        20,
        "agent.attach",
        json!({
            "key": key,
            "client_capabilities": {"fs": {"readTextFile": true}, "terminal": true},
        }),
    );
    assert_eq!(again["result"]["created"], false);
    assert_eq!(
        again["result"]["attached"], 1,
        "attached is not counted twice"
    );
    // A notification would arrive here if the pending set had been replayed.
    if let Some(frame) = agent
        .client
        .try_next_notification(Duration::from_millis(700))
    {
        assert_ne!(
            frame["method"], "tunnel.recv",
            "re-attaching replayed a pending request: {frame}"
        );
    }
}

#[test]
fn a_new_connection_still_receives_pending_requests() {
    let server = TestServer::start("agent-replay-new");
    let mut first = Agent::attach(&server, "replay-new");
    first.initialize(json!(1));
    first.request(
        json!(10),
        "session/new",
        json!({"cwd": server.dir().to_string_lossy(), "mcpServers": []}),
    );
    let session_id = first.recv_response(&json!(10))["result"]["sessionId"]
        .as_str()
        .unwrap()
        .to_string();
    first.request(
        json!(11),
        "session/prompt",
        json!({
            "sessionId": session_id,
            "prompt": [{"type": "text", "text": "permission please"}],
        }),
    );
    loop {
        let message = first.recv();
        if message["method"] == "session/request_permission" {
            break;
        }
    }

    let mut second = server.connect();
    second.hello(&server.token(), 2);
    let attached = second.request(
        2,
        "agent.attach",
        json!({
            "key": {
                "agent": "mock",
                "command": "python3",
                "args": [mock_agent().to_string_lossy(), "replay-new"],
                "cwd": server.dir().to_string_lossy(),
            },
            "client_capabilities": {"fs": {"readTextFile": true}, "terminal": true},
        }),
    );
    assert_eq!(attached["result"]["attached"], 2);
    let replay = second.next_tunnel_recv(Duration::from_secs(15));
    assert_eq!(replay["message"]["method"], "session/request_permission");
    assert_eq!(replay["message"]["id"], 9001);
}

#[test]
fn a_turn_that_outlives_its_connection_keeps_the_service_alive_until_it_ends() {
    // Short idle timeout: only a running turn can keep the service up.
    let server = TestServer::start_with("idle-turn-ends", &["--idle-timeout", "1"], &[]);
    let mut agent = Agent::attach(&server, "turn-ends");
    agent.initialize(json!(1));
    agent.request(
        json!(10),
        "session/new",
        json!({"cwd": server.dir().to_string_lossy(), "mcpServers": []}),
    );
    let session_id = agent.recv_response(&json!(10))["result"]["sessionId"]
        .as_str()
        .unwrap()
        .to_string();
    // `slow` streams one update and then waits about 5 s.
    agent.request(
        json!(11),
        "session/prompt",
        json!({
            "sessionId": session_id,
            "prompt": [{"type": "text", "text": "slow"}],
        }),
    );
    loop {
        let message = agent.recv();
        if message["method"] == "session/update" {
            break;
        }
    }
    let pid = agent.pid;
    // The front end goes away; the turn keeps running.
    drop(agent.client);

    let mut probe = server.connect();
    probe.hello(&server.token(), 2);
    let deadline = Instant::now() + Duration::from_secs(10);
    loop {
        let list = probe.request(2, "agent.list", json!({}));
        let summary = list["result"]["instances"][0].clone();
        if summary["attached"] != 0 {
            assert!(
                Instant::now() < deadline,
                "the disconnect was never noticed: {summary}"
            );
            std::thread::sleep(Duration::from_millis(20));
            continue;
        }
        if summary["turns_running"] == 1 {
            break;
        }
        assert!(
            Instant::now() < deadline,
            "the turn disappeared before it finished: {summary}"
        );
        std::thread::sleep(Duration::from_millis(20));
    }
    // The prompt finishes on its own; the response has no connection left, but
    // the turn must stop counting, so the service can go idle.
    let deadline = Instant::now() + Duration::from_secs(30);
    loop {
        let list = probe.request(3, "agent.list", json!({}));
        let summary = list["result"]["instances"][0].clone();
        if summary["turns_running"] == 0 {
            break;
        }
        assert!(
            Instant::now() < deadline,
            "the turn never finished: {summary}"
        );
        std::thread::sleep(Duration::from_millis(50));
    }
    drop(probe);

    // Nothing is connected and nothing is running: the idle timeout fires and
    // the service stops the agent and exits.
    let deadline = Instant::now() + Duration::from_secs(20);
    loop {
        let alive = PathBuf::from(format!("/proc/{pid}")).exists() || server.socket().exists();
        if !alive {
            break;
        }
        assert!(
            Instant::now() < deadline,
            "the idle timeout never stopped the service (agent pid {pid})"
        );
        std::thread::sleep(Duration::from_millis(50));
    }
}

/// An agent that answers `ping` and refuses to exit on its own: it ignores
/// SIGTERM and keeps running after stdin closes, so `agent.stop` has to use its
/// full escalation and the instance survives long enough to be observed.
fn slow_to_die_agent(server: &TestServer) -> PathBuf {
    write_stubborn_agent(
        server.dir(),
        "slow-to-die.py",
        r#"#!/usr/bin/env python3
import json, signal, sys, time

# Ignore SIGTERM: only SIGKILL ends this process (unless it is asked politely).
signal.signal(signal.SIGTERM, signal.SIG_IGN)

def reply(msg_id, result):
    sys.stdout.write(json.dumps({"jsonrpc": "2.0", "id": msg_id, "result": result}) + "\n")
    sys.stdout.flush()

while True:
    line = sys.stdin.readline()
    if not line:
        # stdin closed: keep running, so agent.stop has to escalate.
        time.sleep(60)
        continue
    line = line.strip()
    if not line:
        continue
    message = json.loads(line)
    if message.get("method") == "ping":
        reply(message["id"], {"echo": message["id"]})
"#,
    )
}

fn attach_key(server: &TestServer, client: &mut common::Client, command: &Path) -> Value {
    client.request(
        100,
        "agent.attach",
        json!({
            "key": {
                "agent": "stubborn",
                "command": command.to_string_lossy(),
                "args": [],
                "cwd": server.dir().to_string_lossy(),
            },
            "client_capabilities": {},
        }),
    )
}

fn list_instances(client: &mut common::Client, id: i64) -> Vec<Value> {
    let list = client.request(id, "agent.list", json!({}));
    list["result"]["instances"]
        .as_array()
        .cloned()
        .unwrap_or_default()
}

/// Process ids currently in `instances`, by instance id.
fn pids_by_instance(instances: &[Value]) -> HashMap<String, u64> {
    instances
        .iter()
        .filter_map(|instance| {
            Some((
                instance["instance"].as_str()?.to_string(),
                instance["pid"].as_u64()?,
            ))
        })
        .collect()
}

fn process_alive(pid: u64) -> bool {
    PathBuf::from(format!("/proc/{pid}")).exists()
}

#[test]
fn stop_frees_the_identity_immediately() {
    let server = TestServer::start_with(
        "agent-stop-identity",
        &["--idle-timeout", "600"],
        &[("NVIM_ADE_SERVER_STOP_TIMEOUT_MS", "600")],
    );
    let script = slow_to_die_agent(&server);
    let mut client = server.connect();
    client.hello(&server.token(), 2);

    let attached = attach_key(&server, &mut client, &script);
    let old_instance = attached["result"]["instance"].as_str().unwrap().to_string();
    let old_pid = attached["result"]["pid"].as_u64().unwrap();
    assert_eq!(attached["result"]["created"], true);

    // The old instance answers before the stop.
    client.notify(
        "tunnel.send",
        json!({
            "instance": old_instance,
            "message": {"jsonrpc": "2.0", "id": "before", "method": "ping", "params": {}},
        }),
    );
    assert_eq!(
        client.next_tunnel_recv(Duration::from_secs(10))["message"]["id"],
        "before"
    );

    // Ask for the stop and do not wait for the reply: the identity must be
    // free right now.
    client.send(&json!({
        "jsonrpc": "2.0",
        "id": 20,
        "method": "agent.stop",
        "params": {"instance": old_instance},
    }));

    let attached = attach_key(&server, &mut client, &script);
    assert_eq!(
        attached["result"]["created"], true,
        "attach after stop must create a new instance: {attached}"
    );
    let new_instance = attached["result"]["instance"].as_str().unwrap().to_string();
    let new_pid = attached["result"]["pid"].as_u64().unwrap();
    assert_ne!(new_instance, old_instance);
    assert_ne!(new_pid, old_pid, "the new instance runs a new process");

    // Both instances are listed until the old one exits; only the old one is
    // stopping.
    let instances = list_instances(&mut client, 30);
    let pids = pids_by_instance(&instances);
    assert!(
        pids.contains_key(&old_instance),
        "the stopping instance is listed: {instances:?}"
    );
    assert!(pids.contains_key(&new_instance));
    let old = instances
        .iter()
        .find(|instance| instance["instance"] == old_instance.as_str())
        .expect("old instance");
    let new = instances
        .iter()
        .find(|instance| instance["instance"] == new_instance.as_str())
        .expect("new instance");
    assert_eq!(
        old["stopping"], true,
        "the stopped instance is marked: {old}"
    );
    assert_eq!(new["stopping"], false);

    // `tunnel.send` is still accepted for the stopping instance (its stdin is
    // already closed, so it may not answer any more): the service must not
    // report -32020/-32024 for it.
    client.notify(
        "tunnel.send",
        json!({
            "instance": old_instance,
            "message": {"jsonrpc": "2.0", "id": "during", "method": "ping", "params": {}},
        }),
    );

    // The new instance is fully functional, the old one exits, and the stop
    // reply arrives — in any order, so collect until all three are seen.
    client.notify(
        "tunnel.send",
        json!({
            "instance": new_instance,
            "message": {"jsonrpc": "2.0", "id": "new", "method": "ping", "params": {}},
        }),
    );
    let mut saw_new_reply = false;
    let mut saw_exited_old = false;
    let mut stop_reply = None;
    let deadline = Instant::now() + Duration::from_secs(30);
    while !(saw_new_reply && saw_exited_old && stop_reply.is_some()) {
        assert!(
            Instant::now() < deadline,
            "did not see the new reply ({saw_new_reply}), the old exit ({saw_exited_old}) \
             or the stop reply ({stop_reply:?})"
        );
        let Some(frame) = client.try_next_notification(Duration::from_secs(5)) else {
            continue;
        };
        match frame["method"].as_str() {
            Some("agent.exited") => {
                assert_eq!(
                    frame["params"]["instance"], old_instance,
                    "agent.exited must name the old instance: {frame}"
                );
                saw_exited_old = true;
            }
            Some("tunnel.error") => {
                assert!(
                    frame["params"]["code"] != -32020 && frame["params"]["code"] != -32024,
                    "the stopping instance must stay reachable: {frame}"
                );
            }
            Some("tunnel.recv") => {
                let instance = frame["params"]["instance"].as_str().unwrap_or_default();
                let message = &frame["params"]["message"];
                if message["id"] == "new" {
                    assert_eq!(instance, new_instance);
                    saw_new_reply = true;
                } else if instance == old_instance {
                    // In-flight traffic for the stopping instance is fine, but
                    // nothing may be sent on its behalf to the new instance.
                    assert_ne!(instance, new_instance);
                }
            }
            _ => {
                if frame["id"] == 20 {
                    assert_eq!(frame["result"]["exited"], true);
                    stop_reply = Some(frame);
                }
            }
        }
    }

    // Only the new instance is left.
    let instances = list_instances(&mut client, 40);
    let pids = pids_by_instance(&instances);
    assert!(!pids.contains_key(&old_instance));
    assert!(pids.contains_key(&new_instance));

    // Clean up: stop the new instance too.
    client.request(50, "agent.stop", json!({"instance": new_instance}));
}

#[test]
fn repeated_stop_and_attach_cycles_do_not_leak_processes() {
    let server = TestServer::start_with(
        "agent-stop-cycles",
        &["--idle-timeout", "600"],
        &[("NVIM_ADE_SERVER_STOP_TIMEOUT_MS", "300")],
    );
    let script = slow_to_die_agent(&server);
    let mut client = server.connect();
    client.hello(&server.token(), 2);

    let mut seen: Vec<(String, u64)> = Vec::new();
    let mut current = attach_key(&server, &mut client, &script);
    assert_eq!(current["result"]["created"], true);

    for cycle in 0..2 {
        let instance = current["result"]["instance"].as_str().unwrap().to_string();
        let pid = current["result"]["pid"].as_u64().unwrap();
        seen.push((instance.clone(), pid));

        // Stop and immediately attach again: no waiting for the stop reply.
        client.send(&json!({
            "jsonrpc": "2.0",
            "id": 200 + cycle,
            "method": "agent.stop",
            "params": {"instance": instance},
        }));
        let next = attach_key(&server, &mut client, &script);
        assert_eq!(
            next["result"]["created"], true,
            "cycle {cycle}: attach after stop creates a new instance: {next}"
        );
        let next_pid = next["result"]["pid"].as_u64().unwrap();
        assert_ne!(next_pid, pid, "cycle {cycle}: a new process");
        current = next;
    }

    let last_instance = current["result"]["instance"].as_str().unwrap().to_string();
    let last_pid = current["result"]["pid"].as_u64().unwrap();
    seen.push((last_instance.clone(), last_pid));

    // The new instance works after all those cycles.
    client.notify(
        "tunnel.send",
        json!({
            "instance": last_instance,
            "message": {"jsonrpc": "2.0", "id": "alive", "method": "ping", "params": {}},
        }),
    );
    loop {
        let recv = client.next_tunnel_recv(Duration::from_secs(10));
        if recv["message"]["id"] == "alive" {
            break;
        }
    }

    // Every earlier process is reaped; nothing is leaked.
    let deadline = Instant::now() + Duration::from_secs(45);
    for (instance, pid) in &seen[..seen.len() - 1] {
        loop {
            if !process_alive(*pid) {
                break;
            }
            assert!(
                Instant::now() < deadline,
                "instance {instance} (pid {pid}) was leaked"
            );
            std::thread::sleep(Duration::from_millis(20));
        }
    }
    // Only the last instance remains.
    let instances = list_instances(&mut client, 300);
    let pids = pids_by_instance(&instances);
    assert_eq!(pids.len(), 1, "only one instance is left: {instances:?}");
    assert!(pids.contains_key(&last_instance));

    client.request(301, "agent.stop", json!({"instance": last_instance}));
    let deadline = Instant::now() + Duration::from_secs(20);
    loop {
        if !process_alive(seen[seen.len() - 1].1) {
            break;
        }
        assert!(Instant::now() < deadline, "the last agent was leaked");
        std::thread::sleep(Duration::from_millis(20));
    }
    assert!(
        list_instances(&mut client, 302).is_empty(),
        "no instance is left after the last stop"
    );
}
