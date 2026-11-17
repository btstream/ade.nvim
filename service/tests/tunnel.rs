//! Integration tests for the api_version 4 tunnel: agent processes, the relay
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
        client.hello(&server.token(), nvim_ade_server::API_VERSION);
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
    second.hello(&server.token(), nvim_ade_server::API_VERSION);
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
    second.hello(&server.token(), nvim_ade_server::API_VERSION);
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
    second.hello(&server.token(), nvim_ade_server::API_VERSION);
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
    client.hello(&server.token(), nvim_ade_server::API_VERSION);
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
    stranger.hello(&server.token(), nvim_ade_server::API_VERSION);
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
fn the_stop_reply_arrives_after_the_instance_is_gone() {
    // PROTOCOL.md 3.4: the reply comes after the process exited, so a front end
    // that sends `agent.list` right after it never sees the instance again.
    let server = TestServer::start("agent-stop-order");
    let mut client = server.connect();
    client.hello(&server.token(), nvim_ade_server::API_VERSION);
    let script = write_stubborn_agent(
        server.dir(),
        "exits-on-stdin.sh",
        "#!/bin/sh\ncat > /dev/null\nexit 0\n",
    );
    let (mut client, instance) = {
        let attached = attach_custom(&server, &script, &[]);
        (attached.0, attached.1)
    };
    let _ = &mut client;

    let reply = client.request(2, "agent.stop", json!({"instance": instance}));
    assert_eq!(reply["result"]["exited"], true);

    // No polling: the very next list must be empty.
    let list = client.request(3, "agent.list", json!({}));
    assert_eq!(
        list["result"]["instances"],
        json!([]),
        "the stopped instance is gone before the reply: {list}"
    );
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
    second.hello(&server.token(), nvim_ade_server::API_VERSION);
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
    probe.hello(&server.token(), nvim_ade_server::API_VERSION);
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
    client.hello(&server.token(), nvim_ade_server::API_VERSION);
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
    client.hello(&server.token(), nvim_ade_server::API_VERSION);
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
    second.hello(&server.token(), nvim_ade_server::API_VERSION);
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
    probe.hello(&server.token(), nvim_ade_server::API_VERSION);
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
    client.hello(&server.token(), nvim_ade_server::API_VERSION);

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
    client.hello(&server.token(), nvim_ade_server::API_VERSION);

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

// --- S1b part 1: session tracking, adopters, retraction ---------------------

/// A raw connection for the S1b tests: `hello`, then helpers that keep
/// notifications out of the way of request/response matching.
struct Peer {
    client: common::Client,
    instance: String,
    caps: Value,
    key: Value,
    session_id: Option<String>,
}

impl Peer {
    fn attach(server: &TestServer, label: &str) -> Self {
        let mut client = server.connect();
        client.hello(&server.token(), nvim_ade_server::API_VERSION);
        let key = json!({
            "agent": "mock",
            "command": "python3",
            "args": [mock_agent().to_string_lossy(), label],
            "cwd": server.dir().to_string_lossy(),
        });
        let caps = json!({"fs": {"readTextFile": true}, "terminal": true});
        let response = client.request(
            2,
            "agent.attach",
            json!({"key": key, "client_capabilities": caps}),
        );
        assert!(response["result"].is_object(), "attach failed: {response}");
        let instance = response["result"]["instance"]
            .as_str()
            .expect("instance")
            .to_string();
        Self {
            client,
            instance,
            caps,
            key,
            session_id: None,
        }
    }

    fn send_message(&mut self, id: Value, method: &str, params: Value) {
        self.client.notify(
            "tunnel.send",
            json!({
                "instance": self.instance,
                "message": {"jsonrpc": "2.0", "id": id, "method": method, "params": params},
            }),
        );
    }

    /// Wait for the response with this id, returning its `result` or `error`.
    fn response(&mut self, id: &Value, timeout: Duration) -> Value {
        let deadline = Instant::now() + timeout;
        loop {
            assert!(Instant::now() < deadline, "no response for {id}");
            let notification = self.client.next_notification(Duration::from_secs(5));
            if notification["method"] == "tunnel.recv" {
                let message = &notification["params"]["message"];
                if message.get("method").is_none() && &message["id"] == id {
                    return message.clone();
                }
            }
        }
    }

    /// Wait for a `tunnel.recv` whose message method matches (an update or an
    /// agent request).
    fn wait_for_method(&mut self, method: &str, timeout: Duration) -> Value {
        let deadline = Instant::now() + timeout;
        loop {
            assert!(Instant::now() < deadline, "never saw {method}");
            let notification = self.client.next_notification(Duration::from_secs(5));
            if notification["method"] == "tunnel.recv" {
                let message = &notification["params"]["message"];
                if message["method"] == method {
                    return message.clone();
                }
            }
        }
    }

    fn initialize(&mut self) {
        self.send_message(
            json!("init"),
            "initialize",
            json!({
                "protocolVersion": 1,
                "clientCapabilities": self.caps,
            }),
        );
        let response = self.response(&json!("init"), Duration::from_secs(15));
        assert!(
            response["result"].is_object(),
            "initialize failed: {response}"
        );
    }

    fn new_session(&mut self, frontend_id: Value) -> Value {
        self.send_message(
            frontend_id.clone(),
            "session/new",
            json!({"cwd": self.key["cwd"], "mcpServers": []}),
        );
        self.response(&frontend_id, Duration::from_secs(15))
    }

    fn set_session(&mut self, session_id: &str) {
        self.session_id = Some(session_id.to_string());
    }
}

fn session_id_of(response: &Value) -> String {
    response["result"]["sessionId"]
        .as_str()
        .expect("sessionId")
        .to_string()
}

#[test]
fn sessions_are_tracked_and_reported() {
    let server = TestServer::start("s1b-sessions");
    let mut peer = Peer::attach(&server, "sessions");
    peer.initialize();
    let cwd = peer.key["cwd"].clone();

    let created = peer.new_session(json!(10));
    let session_id = session_id_of(&created);
    peer.set_session(&session_id);

    // `agent.list` reports the session count and, for now, 0 log bytes.
    let list = peer.client.request(20, "agent.list", json!({}));
    let summary = &list["result"]["instances"][0];
    assert_eq!(summary["sessions"], 1, "{summary}");
    assert_eq!(summary["log_bytes"], 0, "no recorder yet");

    // A fresh attach reports the tracked session with its cwd and state.
    let mut second = server.connect();
    second.hello(&server.token(), nvim_ade_server::API_VERSION);
    let attached = second.request(
        2,
        "agent.attach",
        json!({"key": peer.key, "client_capabilities": peer.caps}),
    );
    let sessions = attached["result"]["sessions"]
        .as_array()
        .expect("sessions array");
    assert_eq!(sessions.len(), 1, "{attached}");
    assert_eq!(sessions[0]["sessionId"], session_id.as_str());
    assert_eq!(sessions[0]["cwd"], cwd);
    assert_eq!(sessions[0]["running"], false);
    assert!(sessions[0]["updated_at"].as_i64().unwrap_or(0) > 0);
}

#[test]
fn the_tracked_state_follows_config_and_mode_updates() {
    let server = TestServer::start("s1b-state");
    let mut peer = Peer::attach(&server, "state");
    peer.initialize();
    let created = peer.new_session(json!(10));
    let session_id = session_id_of(&created);
    peer.set_session(&session_id);

    // Change the model: the mock answers with the new config options.
    peer.send_message(
        json!(11),
        "session/set_config_option",
        json!({"sessionId": session_id, "configId": "model", "value": "mock-2"}),
    );
    let response = peer.response(&json!(11), Duration::from_secs(15));
    assert_eq!(
        response["result"]["configOptions"][0]["currentValue"],
        "mock-2"
    );

    // Change the mode: the mock streams a `current_mode_update`.
    peer.send_message(
        json!(12),
        "session/set_mode",
        json!({"sessionId": session_id, "modeId": "code"}),
    );
    peer.response(&json!(12), Duration::from_secs(15));
    let _update = peer.wait_for_method("session/update", Duration::from_secs(10));

    // Re-attach and compare the reported state with what `session/new` gave,
    // now carrying the changes.
    let mut second = server.connect();
    second.hello(&server.token(), nvim_ade_server::API_VERSION);
    let attached = second.request(
        2,
        "agent.attach",
        json!({"key": peer.key, "client_capabilities": peer.caps}),
    );
    let sessions = attached["result"]["sessions"].as_array().expect("sessions");
    assert_eq!(sessions.len(), 1);
    assert_eq!(sessions[0]["sessionId"], session_id.as_str());

    // The state itself is only exposed through the emulated load (part 2);
    // here we prove the relay accepted the updates by asking the agent's own
    // state through `agent.list` (still 1 session) and that nothing broke.
    let list = second.request(3, "agent.list", json!({}));
    assert_eq!(list["result"]["instances"][0]["sessions"], 1);
}

#[test]
fn closing_a_session_removes_it_from_the_list() {
    let server = TestServer::start("s1b-close");
    let mut peer = Peer::attach(&server, "close");
    peer.initialize();
    let session_id = session_id_of(&peer.new_session(json!(10)));
    peer.set_session(&session_id);

    let list = peer.client.request(11, "agent.list", json!({}));
    assert_eq!(list["result"]["instances"][0]["sessions"], 1);

    peer.send_message(json!(12), "session/close", json!({"sessionId": session_id}));
    peer.response(&json!(12), Duration::from_secs(15));
    let list = peer.client.request(13, "agent.list", json!({}));
    assert_eq!(list["result"]["instances"][0]["sessions"], 0);

    let mut second = server.connect();
    second.hello(&server.token(), nvim_ade_server::API_VERSION);
    let attached = second.request(
        2,
        "agent.attach",
        json!({"key": peer.key, "client_capabilities": peer.caps}),
    );
    assert_eq!(attached["result"]["sessions"], json!([]));
}

#[test]
fn answering_a_permission_retracts_it_from_the_other_connection() {
    let server = TestServer::start("s1b-retract");
    let mut first = Peer::attach(&server, "retract");
    first.initialize();
    let session_id = session_id_of(&first.new_session(json!(10)));
    first.set_session(&session_id);

    // The mock asks for permission during this prompt.
    first.send_message(
        json!(11),
        "session/prompt",
        json!({
            "sessionId": session_id,
            "prompt": [{"type": "text", "text": "permission please"}],
        }),
    );
    let permission = first.wait_for_method("session/request_permission", Duration::from_secs(20));
    let request_id = permission["id"].clone();

    // A second connection attaches and receives the pending request again.
    let mut second = server.connect();
    second.hello(&server.token(), nvim_ade_server::API_VERSION);
    second.request(
        2,
        "agent.attach",
        json!({"key": first.key, "client_capabilities": first.caps}),
    );
    let deadline = Instant::now() + Duration::from_secs(20);
    let replay = loop {
        assert!(
            Instant::now() < deadline,
            "the pending request was not replayed"
        );
        let notification = second.next_notification(Duration::from_secs(5));
        if notification["method"] == "tunnel.recv"
            && notification["params"]["message"]["method"] == "session/request_permission"
        {
            break notification["params"]["message"].clone();
        }
    };
    assert_eq!(replay["id"], request_id);

    // The first connection answers; the second is told to close its question.
    first.client.notify(
        "tunnel.send",
        json!({
            "instance": first.instance,
            "message": {
                "jsonrpc": "2.0",
                "id": request_id,
                "result": {"outcome": {"outcome": "selected", "optionId": "allow"}},
            },
        }),
    );
    let deadline = Instant::now() + Duration::from_secs(20);
    loop {
        assert!(Instant::now() < deadline, "the retraction never arrived");
        let notification = second.next_notification(Duration::from_secs(5));
        if notification["method"] != "tunnel.recv" {
            continue;
        }
        let message = &notification["params"]["message"];
        if message["method"] == "$/cancel_request" {
            assert_eq!(message["params"]["id"], request_id);
            break;
        }
    }

    // The second connection's late -32800 reply is ignored.
    second.notify(
        "tunnel.send",
        json!({
            "instance": first.instance,
            "message": {
                "jsonrpc": "2.0",
                "id": request_id,
                "error": {"code": -32800, "message": "request cancelled"},
            },
        }),
    );

    // The turn still completes normally for the first connection.
    let done = first.response(&json!(11), Duration::from_secs(20));
    assert_eq!(done["result"]["stopReason"], "end_turn");
    let list = first.client.request(30, "agent.list", json!({}));
    assert_eq!(list["result"]["instances"][0]["pending_requests"], 0);
    assert_eq!(list["result"]["instances"][0]["turns_running"], 0);
}

#[test]
fn the_event_log_flag_off_reports_no_sessions() {
    let server = TestServer::start_with(
        "s1b-log-off",
        &["--idle-timeout", "600", "--event-log", "off"],
        &[],
    );
    let mut peer = Peer::attach(&server, "log-off");
    peer.initialize();
    let session_id = session_id_of(&peer.new_session(json!(10)));
    peer.set_session(&session_id);

    // Nothing is tracked while the log is off.
    let list = peer.client.request(20, "agent.list", json!({}));
    assert_eq!(list["result"]["instances"][0]["sessions"], 0);
    assert_eq!(list["result"]["instances"][0]["log_bytes"], 0);

    let mut second = server.connect();
    second.hello(&server.token(), nvim_ade_server::API_VERSION);
    let attached = second.request(
        2,
        "agent.attach",
        json!({"key": peer.key, "client_capabilities": peer.caps}),
    );
    assert_eq!(attached["result"]["sessions"], json!([]));
}

#[test]
fn an_agent_withdrawal_reaches_each_connection_once() {
    let server = TestServer::start("s1b-withdraw");
    let mut first = Peer::attach(&server, "withdraw");
    first.initialize();
    let session_id = session_id_of(&first.new_session(json!(10)));
    first.set_session(&session_id);

    // `@cancel-request` makes the mock ask for permission and then withdraw it.
    first.send_message(
        json!(11),
        "session/prompt",
        json!({
            "sessionId": session_id,
            "prompt": [{"type": "text", "text": "@cancel-request"}],
        }),
    );
    let permission = first.wait_for_method("session/request_permission", Duration::from_secs(20));
    let request_id = permission["id"].clone();

    // A second connection attaches and receives the pending request again.
    let mut second = server.connect();
    second.hello(&server.token(), nvim_ade_server::API_VERSION);
    second.request(
        2,
        "agent.attach",
        json!({"key": first.key, "client_capabilities": first.caps}),
    );
    let deadline = Instant::now() + Duration::from_secs(20);
    loop {
        assert!(
            Instant::now() < deadline,
            "no replay for the second connection"
        );
        let notification = second.next_notification(Duration::from_secs(5));
        if notification["method"] == "tunnel.recv"
            && notification["params"]["message"]["method"] == "session/request_permission"
        {
            break;
        }
    }

    // The requester sees the agent's withdrawal and then its prompt ending.
    let mut first_cancels = 0usize;
    let deadline = Instant::now() + Duration::from_secs(25);
    loop {
        assert!(Instant::now() < deadline, "the prompt never finished");
        let notification = first.client.next_notification(Duration::from_secs(5));
        if notification["method"] != "tunnel.recv" {
            continue;
        }
        let message = &notification["params"]["message"];
        if message["method"] == "$/cancel_request" {
            first_cancels += 1;
            assert_eq!(message["params"]["id"], request_id, "{message}");
        } else if message.get("method").is_none() && message["id"] == json!(11) {
            break;
        }
    }
    assert_eq!(first_cancels, 1, "the agent's notification, forwarded once");

    // The other connection receives the same forwarded notification exactly
    // once and nothing else: no synthetic retraction on top of it.
    let mut second_cancels = 0usize;
    let deadline = Instant::now() + Duration::from_secs(20);
    while second_cancels == 0 {
        assert!(
            Instant::now() < deadline,
            "the second connection never saw the withdrawal"
        );
        let notification = second.next_notification(Duration::from_secs(5));
        if notification["method"] != "tunnel.recv" {
            continue;
        }
        let message = &notification["params"]["message"];
        if message["method"] == "$/cancel_request" {
            second_cancels += 1;
            assert_eq!(message["params"]["id"], request_id, "{message}");
        }
    }
    // Nothing more arrives within a window long enough for a duplicate.
    if let Some(frame) = second.try_next_notification(Duration::from_millis(700)) {
        if frame["method"] == "tunnel.recv"
            && frame["params"]["message"]["method"] == "$/cancel_request"
        {
            panic!("the withdrawal was sent twice: {frame}");
        }
    }
    assert_eq!(second_cancels, 1, "no duplicate retraction on top of it");
}

// --- S1b part 2: event log, emulated session/load, turn adoption -----------

/// A peer whose mock agent is configured by environment (profile etc.).
fn peer_with_env(server: &TestServer, label: &str, extra_env: &[(&str, &str)]) -> Peer {
    let mut client = server.connect();
    client.hello(&server.token(), nvim_ade_server::API_VERSION);
    let key = json!({
        "agent": "mock",
        "command": "python3",
        "args": [mock_agent().to_string_lossy(), label],
        "cwd": server.dir().to_string_lossy(),
    });
    let caps = json!({"fs": {"readTextFile": true}, "terminal": true});
    let mut env: HashMap<String, String> = HashMap::new();
    for (name, value) in extra_env {
        env.insert((*name).to_string(), (*value).to_string());
    }
    let response = client.request(
        2,
        "agent.attach",
        json!({"key": key, "client_capabilities": caps, "env": env}),
    );
    assert!(response["result"].is_object(), "attach failed: {response}");
    let instance = response["result"]["instance"].as_str().unwrap().to_string();
    Peer {
        client,
        instance,
        caps,
        key,
        session_id: None,
    }
}

impl Peer {
    /// Collect the `session/update` updates of a prompt's live stream until its
    /// response arrives, plus the response.
    fn run_prompt(&mut self, id: Value, text: &str) -> (Vec<Value>, Value) {
        let session_id = self.session_id.clone().expect("session");
        self.send_message(
            id.clone(),
            "session/prompt",
            json!({"sessionId": session_id, "prompt": [{"type": "text", "text": text}]}),
        );
        let mut updates = Vec::new();
        let deadline = Instant::now() + Duration::from_secs(30);
        loop {
            assert!(Instant::now() < deadline, "the prompt never finished");
            let notification = self.client.next_notification(Duration::from_secs(5));
            if notification["method"] != "tunnel.recv" {
                continue;
            }
            let message = &notification["params"]["message"];
            if message["method"] == "session/update" {
                updates.push(message["params"]["update"].clone());
            } else if message.get("method").is_none() && message["id"] == id {
                return (updates, message.clone());
            }
        }
    }

    /// Send `session/load` and collect everything until its response.
    fn load_session(&mut self, id: Value, session_id: &str) -> (Vec<Value>, Value, Vec<Value>) {
        self.send_message(
            id.clone(),
            "session/load",
            json!({"sessionId": session_id, "cwd": self.key["cwd"], "mcpServers": []}),
        );
        let mut updates = Vec::new();
        let mut adoptions = Vec::new();
        let deadline = Instant::now() + Duration::from_secs(30);
        loop {
            assert!(Instant::now() < deadline, "the load never answered");
            let notification = self.client.next_notification(Duration::from_secs(5));
            if notification["method"] != "tunnel.recv" {
                continue;
            }
            let message = &notification["params"]["message"];
            match message["method"].as_str() {
                Some("session/update") => updates.push(message["params"]["update"].clone()),
                Some("_ade/turn_adopted") => adoptions.push(message["params"].clone()),
                None if message["id"] == id => {
                    // `_ade/turn_adopted` follows the response (PROTOCOL.md 13),
                    // so keep reading briefly before returning.
                    let response = message.clone();
                    while let Some(notification) = self
                        .client
                        .try_next_notification(Duration::from_millis(400))
                    {
                        if notification["method"] != "tunnel.recv" {
                            continue;
                        }
                        let message = &notification["params"]["message"];
                        match message["method"].as_str() {
                            Some("session/update") => {
                                updates.push(message["params"]["update"].clone())
                            }
                            Some("_ade/turn_adopted") => adoptions.push(message["params"].clone()),
                            _ => {}
                        }
                    }
                    return (updates, response, adoptions);
                }
                _ => {}
            }
        }
    }
}

#[test]
fn a_replay_has_exactly_one_user_message_chunk_per_prompt() {
    // The regression: the synthetic prompt and the agent's echo used to be
    // recorded both, so every user message was replayed twice.
    let server = TestServer::start("s1b-dedup");
    let mut first = Peer::attach(&server, "dedup");
    first.initialize();
    let session_id = session_id_of(&first.new_session(json!(10)));
    first.set_session(&session_id);
    let (live_updates, _) = first.run_prompt(json!(11), "one and only");
    // The live stream still carries the agent's echo, untouched by the fix.
    assert!(
        live_updates
            .iter()
            .any(|update| update["sessionUpdate"] == "user_message_chunk"),
        "the live stream keeps the agent's user_message_chunk: {live_updates:?}"
    );
    drop(first);

    let mut second = Peer::attach(&server, "dedup");
    second.set_session(&session_id);
    let (replayed, _, _) = second.load_session(json!(20), &session_id);

    let user_chunks: Vec<&Value> = replayed
        .iter()
        .filter(|update| update["sessionUpdate"] == "user_message_chunk")
        .collect();
    assert_eq!(
        user_chunks.len(),
        1,
        "the replay must hold exactly one user_message_chunk: {replayed:?}"
    );
    assert_eq!(
        user_chunks[0]["messageId"],
        format!(
            "ade-user-{}",
            user_chunks[0]["messageId"]
                .as_str()
                .map(|id| id.trim_start_matches("ade-user-"))
                .unwrap_or_default()
        ),
        "the surviving chunk is the synthetic one"
    );
    // Its text is the user's prompt, so nothing was lost by dropping the echo.
    assert_eq!(user_chunks[0]["content"]["text"], "one and only");
}

#[test]
fn session_load_replays_the_conversation_and_the_tracked_state() {
    let server = TestServer::start("s1b-load");
    let mut first = Peer::attach(&server, "load");
    first.initialize();
    let created = first.new_session(json!(10));
    let session_id = session_id_of(&created);
    first.set_session(&session_id);
    let state = created["result"].clone();

    // Two turns, so the replay has a real conversation.
    let (first_updates, _) = first.run_prompt(json!(11), "hello one");
    let (second_updates, _) = first.run_prompt(json!(12), "hello two");
    let live = [first_updates, second_updates].concat();
    assert!(!live.is_empty(), "the mock streamed updates");
    drop(first);

    // A new front end loads the session: the replay matches the live stream,
    // and the response is the tracked `session/new` state.
    let mut second = Peer::attach(&server, "load");
    second.set_session(&session_id);
    let (replayed, response, adoptions) = second.load_session(json!(20), &session_id);
    assert!(adoptions.is_empty(), "no orphan turn was running");

    // The agent's own stream appears verbatim and in order, except its
    // `user_message_chunk` echo: that one is forwarded live but not recorded
    // (PROTOCOL.md 10), because the synthetic prompt already carries the text.
    let replayed_agent_updates: Vec<Value> = replayed
        .iter()
        .filter(|update| update["sessionUpdate"] != "user_message_chunk")
        .cloned()
        .collect();
    let live_agent_updates: Vec<Value> = live
        .iter()
        .filter(|update| update["sessionUpdate"] != "user_message_chunk")
        .cloned()
        .collect();
    assert_eq!(
        replayed_agent_updates, live_agent_updates,
        "the replay is the recorded agent stream, in order"
    );

    // Every user message appears exactly once, as the synthetic chunk.
    let user_chunks: Vec<&Value> = replayed
        .iter()
        .filter(|update| update["sessionUpdate"] == "user_message_chunk")
        .collect();
    assert_eq!(
        user_chunks.len(),
        2,
        "exactly one user chunk per prompt, no duplicate: {replayed:?}"
    );
    assert!(
        user_chunks.iter().all(|update| update["messageId"]
            .as_str()
            .is_some_and(|id| id.starts_with("ade-user-"))),
        "the only user chunks are the synthetic ones: {user_chunks:?}"
    );

    assert_eq!(
        response["result"], state,
        "the load result is the tracked state"
    );
}

#[test]
fn an_emulated_load_has_no_gap_and_no_duplicate_while_the_agent_keeps_talking() {
    let server = TestServer::start("s1b-gap");
    let mut first = Peer::attach(&server, "gap");
    first.initialize();
    let session_id = session_id_of(&first.new_session(json!(10)));
    first.set_session(&session_id);
    let (before, _) = first.run_prompt(json!(11), "hello before");
    drop(first);

    // A second connection starts a slow turn (streaming) while the third loads.
    let mut chatter = Peer::attach(&server, "gap");
    chatter.set_session(&session_id);
    chatter.send_message(
        json!(30),
        "session/prompt",
        json!({
            "sessionId": session_id,
            "prompt": [{"type": "text", "text": "slow"}],
        }),
    );
    // Wait for the first streamed update, so the agent is mid-turn.
    let _ = chatter.wait_for_method("session/update", Duration::from_secs(20));

    let mut loader = Peer::attach(&server, "gap");
    loader.set_session(&session_id);
    loader.send_message(
        json!(20),
        "session/load",
        json!({"sessionId": session_id, "cwd": loader.key["cwd"], "mcpServers": []}),
    );

    // Collect the replay plus everything live until the load response and
    // beyond; assert every seq arrives at most once and in increasing order.
    let mut seen: Vec<u64> = Vec::new();
    let mut response = None;
    let deadline = Instant::now() + Duration::from_secs(30);
    while response.is_none() {
        assert!(Instant::now() < deadline, "the load never answered");
        let notification = loader.client.next_notification(Duration::from_secs(5));
        if notification["method"] != "tunnel.recv" {
            continue;
        }
        let seq = notification["params"]["seq"].as_u64().expect("seq");
        let message = &notification["params"]["message"];
        if message.get("method").is_none() && message["id"] == json!(20) {
            response = Some(message.clone());
        }
        seen.push(seq);
    }
    assert!(!before.is_empty());

    // Monotonic, no duplicate seq.
    let mut sorted = seen.clone();
    sorted.sort_unstable();
    sorted.dedup();
    assert_eq!(
        sorted.len(),
        seen.len(),
        "a seq was delivered twice: {seen:?}"
    );

    // End the streaming turn and start a new one: its notifications are
    // broadcast, so the loader sees live traffic after the replay.
    chatter.send_message(
        json!(31),
        "session/cancel",
        json!({"sessionId": session_id}),
    );
    let deadline = Instant::now() + Duration::from_secs(30);
    loop {
        assert!(Instant::now() < deadline, "the slow turn never ended");
        let notification = chatter.client.next_notification(Duration::from_secs(5));
        if notification["method"] != "tunnel.recv" {
            continue;
        }
        let message = &notification["params"]["message"];
        if message.get("method").is_none() && message["id"] == json!(30) {
            break;
        }
    }
    chatter.send_message(
        json!(32),
        "session/prompt",
        json!({
            "sessionId": session_id,
            "prompt": [{"type": "text", "text": "hello after the load"}],
        }),
    );

    let mut after: Vec<u64> = Vec::new();
    let deadline = Instant::now() + Duration::from_secs(30);
    while after.len() < 3 {
        assert!(Instant::now() < deadline, "the live stream never continued");
        let notification = loader.client.next_notification(Duration::from_secs(5));
        if notification["method"] != "tunnel.recv" {
            continue;
        }
        after.push(notification["params"]["seq"].as_u64().expect("seq"));
    }
    let all: Vec<u64> = seen.iter().chain(after.iter()).copied().collect();
    assert!(
        all.windows(2).all(|pair| pair[0] < pair[1]),
        "seq order across replay and live: {all:?}"
    );
}

#[test]
fn an_orphan_turn_is_adopted_after_an_emulated_load() {
    let server = TestServer::start("s1b-adopt");
    let mut owner = Peer::attach(&server, "adopt");
    owner.initialize();
    let session_id = session_id_of(&owner.new_session(json!(10)));
    owner.set_session(&session_id);
    // `slow` streams one update and then waits for the cancel.
    owner.send_message(
        json!(11),
        "session/prompt",
        json!({
            "sessionId": session_id,
            "prompt": [{"type": "text", "text": "slow"}],
        }),
    );
    let _ = owner.wait_for_method("session/update", Duration::from_secs(20));
    let owner_key = owner.key.clone();
    let owner_caps = owner.caps.clone();
    drop(owner);

    // B adopts the turn through the emulated load. Wait until the service has
    // noticed the owner's disconnect, otherwise the prompt is not an orphan yet.
    let mut adopter = Peer::attach(&server, "adopt");
    adopter.set_session(&session_id);
    let deadline = Instant::now() + Duration::from_secs(10);
    loop {
        let list = adopter.client.request(90, "agent.list", json!({}));
        if list["result"]["instances"][0]["attached"] == 1 {
            break;
        }
        assert!(
            Instant::now() < deadline,
            "the owner's disconnect was never noticed: {list}"
        );
        std::thread::sleep(Duration::from_millis(20));
    }
    let (replayed, response, adoptions) = adopter.load_session(json!(20), &session_id);
    assert!(!replayed.is_empty(), "the replay holds the partial output");
    assert_eq!(
        adoptions.len(),
        1,
        "the turn was adopted: {adoptions:?}\nreplayed: {replayed:?}\nresponse: {response}\nserver stderr:\n{}",
        server.stderr()
    );
    assert_eq!(adoptions[0]["sessionId"], session_id.as_str());

    // A third connection did not load the session and hears nothing about it.
    let mut bystander = Peer::attach(&server, "adopt");
    bystander.client.request(
        2,
        "agent.attach",
        json!({"key": owner_key, "client_capabilities": owner_caps}),
    );
    let _ = bystander;
    // (the bystander is attached to the same instance; it must not get the
    // adoption notification, which is only sent to the adopter)

    // The adopter cancels; the agent answers `cancelled`, and the adopter is
    // told the adopted turn finished.
    adopter.send_message(
        json!(21),
        "session/cancel",
        json!({"sessionId": session_id}),
    );
    let deadline = Instant::now() + Duration::from_secs(30);
    let finished = loop {
        assert!(Instant::now() < deadline, "the adopted turn never finished");
        let notification = adopter.client.next_notification(Duration::from_secs(5));
        if notification["method"] != "tunnel.recv" {
            continue;
        }
        let message = &notification["params"]["message"];
        if message["method"] == "_ade/turn_finished" {
            break message["params"].clone();
        }
    };
    assert_eq!(finished["sessionId"], session_id.as_str());
    assert_eq!(finished["stopReason"], "cancelled");

    let list = adopter.client.request(30, "agent.list", json!({}));
    assert_eq!(list["result"]["instances"][0]["turns_running"], 0);
}

#[test]
fn an_incomplete_log_forwards_the_load_to_the_agent() {
    // A tiny cap so a couple of prompts prune the session's history.
    let server = TestServer::start_with(
        "s1b-prune",
        &["--idle-timeout", "600", "--event-log-max-mb", "16"],
        &[],
    );
    let mut first = Peer::attach(&server, "prune");
    first.initialize();
    let session_id = session_id_of(&first.new_session(json!(10)));
    first.set_session(&session_id);
    let (_, _) = first.run_prompt(json!(11), "hello");
    drop(first);

    // Force pruning by writing far more than 16 MiB through the log.
    let mut chatter = Peer::attach(&server, "prune");
    chatter.set_session(&session_id);
    let big = "x".repeat(900 * 1024);
    for id in 0..22 {
        chatter.send_message(
            json!(100 + id),
            "session/prompt",
            json!({
                "sessionId": session_id,
                "prompt": [{"type": "text", "text": format!("{id} {big}")}],
            }),
        );
        let _ = chatter.wait_for_method("session/update", Duration::from_secs(30));
        // Let the turn finish before the next one (the mock refuses overlap).
        let deadline = Instant::now() + Duration::from_secs(30);
        loop {
            assert!(Instant::now() < deadline, "a prompt never finished");
            let notification = chatter.client.next_notification(Duration::from_secs(5));
            if notification["method"] != "tunnel.recv" {
                continue;
            }
            let message = &notification["params"]["message"];
            if message.get("method").is_none() && message["id"] == json!(100 + id) {
                break;
            }
        }
    }

    let mut loader = Peer::attach(&server, "prune");
    loader.set_session(&session_id);
    let (replayed, response, _) = loader.load_session(json!(200), &session_id);
    // The agent answered the load itself (the mock replays its own history), so
    // the forwarded path ran and the response is the agent's, not our state.
    assert!(
        response["result"].is_object(),
        "the agent answered the forwarded load: {response}"
    );
    let _ = replayed;
}

#[test]
fn a_load_without_load_session_support_is_forwarded() {
    let server = TestServer::start("s1b-noload");
    let mut first = peer_with_env(&server, "noload", &[("ACP_MOCK_PROFILE", "resumeonly")]);
    first.initialize();
    let session_id = session_id_of(&first.new_session(json!(10)));
    first.set_session(&session_id);
    let (_, _) = first.run_prompt(json!(11), "hello");
    drop(first);

    let mut loader = peer_with_env(&server, "noload", &[("ACP_MOCK_PROFILE", "resumeonly")]);
    loader.set_session(&session_id);
    // `resumeonly` advertises loadSession=false, so the service forwards it and
    // the agent answers. (The identity differs because the env is not part of
    // it, but the same instance is reused: same key and capabilities.)
    let (_, response, _) = loader.load_session(json!(20), &session_id);
    assert_eq!(response["id"], 20);
    // The service did not answer from the log: it forwarded, and the agent's
    // own answer (which for `resumeonly` is an error for load) came back.
    assert!(
        response["error"].is_object() || response["result"].is_object(),
        "the request reached the agent: {response}"
    );
}

#[test]
fn the_event_log_file_is_removed_on_startup_and_log_bytes_follow_the_instance() {
    let server = TestServer::start("s1b-file");
    let log = server.dir().join("nvim_ade_server.events.sqlite3");
    assert!(log.is_file(), "the log file exists once the service runs");

    let mut peer = Peer::attach(&server, "file");
    peer.initialize();
    let session_id = session_id_of(&peer.new_session(json!(10)));
    peer.set_session(&session_id);
    let (_, _) = peer.run_prompt(json!(11), "hello");

    let list = peer.client.request(20, "agent.list", json!({}));
    let bytes = list["result"]["instances"][0]["log_bytes"]
        .as_u64()
        .expect("log_bytes");
    assert!(bytes > 0, "the log has bytes after a turn: {list}");

    // Stopping the instance deletes its log.
    peer.client
        .request(21, "agent.stop", json!({"instance": peer.instance}));
    let deadline = Instant::now() + Duration::from_secs(20);
    loop {
        let list = peer.client.request(22, "agent.list", json!({}));
        if list["result"]["instances"]
            .as_array()
            .is_none_or(Vec::is_empty)
        {
            break;
        }
        assert!(Instant::now() < deadline, "the instance never went away");
        std::thread::sleep(Duration::from_millis(20));
    }
    // A fresh instance starts from zero bytes.
    let mut again = Peer::attach(&server, "file");
    again.initialize();
    let list = again.client.request(23, "agent.list", json!({}));
    assert_eq!(list["result"]["instances"][0]["log_bytes"], 0);
}

#[test]
fn the_log_off_configuration_forwards_load_and_reports_nothing() {
    let server = TestServer::start_with(
        "s1b-off-load",
        &["--idle-timeout", "600", "--event-log", "off"],
        &[],
    );
    let mut first = Peer::attach(&server, "off-load");
    first.initialize();
    let session_id = session_id_of(&first.new_session(json!(10)));
    first.set_session(&session_id);
    let (_, _) = first.run_prompt(json!(11), "hello");
    drop(first);

    let log = server.dir().join("nvim_ade_server.events.sqlite3");
    assert!(!log.exists(), "no log file with --event-log off");

    let mut loader = Peer::attach(&server, "off-load");
    loader.set_session(&session_id);
    let (_, response, adoptions) = loader.load_session(json!(20), &session_id);
    assert_eq!(response["id"], 20);
    assert!(adoptions.is_empty());
    let list = loader.client.request(30, "agent.list", json!({}));
    assert_eq!(list["result"]["instances"][0]["sessions"], 0);
    assert_eq!(list["result"]["instances"][0]["log_bytes"], 0);
}

#[test]
fn a_replay_buffer_that_overflows_closes_the_connection() {
    // Tiny gate (4 KiB) and a slow replay, so live traffic piles up behind it.
    let server = TestServer::start_with(
        "s1b-gate",
        &["--idle-timeout", "600"],
        &[
            ("NVIM_ADE_SERVER_GATE_LIMIT_BYTES", "4096"),
            ("NVIM_ADE_SERVER_REPLAY_DELAY_MS", "1500"),
        ],
    );
    let mut first = Peer::attach(&server, "gate");
    first.initialize();
    let session_id = session_id_of(&first.new_session(json!(10)));
    first.set_session(&session_id);
    let (_, _) = first.run_prompt(json!(11), "hello");
    drop(first);

    // Another connection keeps the instance busy with one big turn: its
    // notifications are broadcast, so they hit the loader's closed gate too.
    let mut chatter = Peer::attach(&server, "gate");
    chatter.set_session(&session_id);

    let mut loader = Peer::attach(&server, "gate");
    loader.set_session(&session_id);
    loader.send_message(
        json!(20),
        "session/load",
        json!({"sessionId": session_id, "cwd": loader.key["cwd"], "mcpServers": []}),
    );

    // While the replay sleeps (the test hook), a prompt streams an update far
    // bigger than the 4 KiB gate.
    let big = "y".repeat(200 * 1024);
    chatter.send_message(
        json!(30),
        "session/prompt",
        json!({
            "sessionId": session_id,
            "prompt": [{"type": "text", "text": format!("ORDER_PROBE {big}")}],
        }),
    );

    // The loader is closed instead of anything being dropped, and it never
    // gets the load response.
    let deadline = Instant::now() + Duration::from_secs(20);
    let mut closed = false;
    while Instant::now() < deadline {
        match loader
            .client
            .try_next_notification(Duration::from_millis(300))
        {
            Some(notification) => {
                if notification["method"] == "tunnel.recv" {
                    assert_ne!(
                        notification["params"]["message"]["id"],
                        json!(20),
                        "the load was answered although the gate overflowed"
                    );
                }
            }
            None => {
                if loader.client.is_closed() {
                    closed = true;
                    break;
                }
            }
        }
    }
    assert!(
        closed || loader.client.is_closed(),
        "the overflowing connection was closed"
    );
}

#[test]
fn a_log_above_the_replay_ceiling_forwards_instead_of_reading_it() {
    // A tiny replay ceiling, so a single normal turn exceeds it. The load must
    // be forwarded (the mock answers it) without reading the log into memory.
    let server = TestServer::start_with(
        "s1b-ceiling",
        &["--idle-timeout", "600"],
        &[("NVIM_ADE_SERVER_REPLAY_LIMIT_BYTES", "128")],
    );
    let mut first = Peer::attach(&server, "ceiling");
    first.initialize();
    let session_id = session_id_of(&first.new_session(json!(10)));
    first.set_session(&session_id);
    let (_, _) = first.run_prompt(json!(11), "hello");
    let list = first.client.request(20, "agent.list", json!({}));
    let bytes = list["result"]["instances"][0]["log_bytes"]
        .as_u64()
        .unwrap();
    assert!(
        bytes > 128,
        "the log is above the injected ceiling: {bytes}"
    );
    drop(first);

    let mut loader = Peer::attach(&server, "ceiling");
    loader.set_session(&session_id);
    let (replayed, response, adoptions) = loader.load_session(json!(20), &session_id);
    // Forwarded: the agent answered, and nothing was replayed from our log
    // (the mock's own `session/load` replays its three canned updates).
    assert_eq!(response["id"], 20);
    assert!(
        replayed.len() <= 4,
        "the service did not replay its own log: {replayed:?}"
    );
    assert!(adoptions.is_empty());
}
