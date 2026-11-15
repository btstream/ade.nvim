//! Relay rules for one agent instance (PROTOCOL.md section 5).
//!
//! This module is pure state and has no I/O: it decides what to forward, what
//! to answer locally, and which connection receives an agent message. The
//! process and socket handling live in [`crate::runtime`] and
//! [`crate::hub`].

use std::collections::{HashMap, HashSet};

use serde_json::{json, Map, Value};

use crate::protocol::CAPABILITIES_DIFFER;

/// Identifier of a front-end connection.
pub type ConnId = u64;

/// Canonical JSON: object keys sorted recursively, arrays in order. Two values
/// have the same canonical form exactly when they are equal as JSON.
pub fn canonical_json(value: &Value) -> String {
    let mut out = String::new();
    write_canonical(value, &mut out);
    out
}

fn write_canonical(value: &Value, out: &mut String) {
    match value {
        Value::Object(map) => {
            let mut keys: Vec<&String> = map.keys().collect();
            keys.sort();
            out.push('{');
            for (index, key) in keys.iter().enumerate() {
                if index > 0 {
                    out.push(',');
                }
                // `to_string` on a key always succeeds and is properly escaped.
                out.push_str(&Value::String((*key).clone()).to_string());
                out.push(':');
                write_canonical(&map[*key], out);
            }
            out.push('}');
        }
        Value::Array(items) => {
            out.push('[');
            for (index, item) in items.iter().enumerate() {
                if index > 0 {
                    out.push(',');
                }
                write_canonical(item, out);
            }
            out.push(']');
        }
        other => out.push_str(&other.to_string()),
    }
}

/// A request id, normalised to text so `1` and `"1"` stay distinct.
pub fn id_key(id: &Value) -> String {
    canonical_json(id)
}

/// Why an `agent.attach` call cannot be used.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct KeyError(pub String);

impl std::fmt::Display for KeyError {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter.write_str(&self.0)
    }
}

/// The instance key of PROTOCOL.md 3.2. Its identity is the canonical JSON of
/// `{agent, command, args, cwd, client_capabilities}`; `env` is not part of it.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct InstanceKey {
    pub agent: String,
    pub command: String,
    pub args: Vec<String>,
    pub cwd: String,
    pub capabilities: Value,
}

impl InstanceKey {
    /// Parse `params.key` and `params.client_capabilities` of `agent.attach`.
    pub fn from_params(params: &Value) -> Result<Self, KeyError> {
        let params = params
            .as_object()
            .ok_or_else(|| KeyError("params must be an object".into()))?;
        let key = params
            .get("key")
            .and_then(Value::as_object)
            .ok_or_else(|| KeyError("key must be an object".into()))?;

        let agent = string_field(key, "agent", "key.agent")?;
        let command = string_field(key, "command", "key.command")?;
        let cwd = string_field(key, "cwd", "key.cwd")?;
        let args = match key.get("args") {
            None | Some(Value::Null) => Vec::new(),
            Some(Value::Array(items)) => {
                let mut args = Vec::with_capacity(items.len());
                for item in items {
                    let Some(arg) = item.as_str() else {
                        return Err(KeyError("key.args must be an array of strings".into()));
                    };
                    args.push(arg.to_string());
                }
                args
            }
            Some(_) => return Err(KeyError("key.args must be an array of strings".into())),
        };
        let capabilities = match params.get("client_capabilities") {
            None | Some(Value::Null) => Value::Object(Map::new()),
            Some(value @ Value::Object(_)) => value.clone(),
            Some(_) => return Err(KeyError("client_capabilities must be an object".into())),
        };

        Ok(Self {
            agent,
            command,
            args,
            cwd,
            capabilities,
        })
    }

    /// Instance identity: canonical JSON of the identity fields.
    pub fn identity(&self) -> String {
        canonical_json(&json!({
            "agent": self.agent,
            "command": self.command,
            "args": self.args,
            "cwd": self.cwd,
            "client_capabilities": self.capabilities,
        }))
    }
}

fn string_field(object: &Map<String, Value>, field: &str, label: &str) -> Result<String, KeyError> {
    match object.get(field).and_then(Value::as_str) {
        Some(value) if !value.is_empty() => Ok(value.to_string()),
        _ => Err(KeyError(format!("{label} must be a non-empty string"))),
    }
}

/// The complete environment for the child, from `params.env`.
///
/// `Ok(None)` means "inherit the service environment" (tests only).
pub fn parse_env(params: &Value) -> Result<Option<Vec<(String, String)>>, KeyError> {
    let Some(env) = params.get("env") else {
        return Ok(None);
    };
    if env.is_null() {
        return Ok(None);
    }
    let env = env
        .as_object()
        .ok_or_else(|| KeyError("env must be an object of strings".into()))?;
    let mut pairs = Vec::with_capacity(env.len());
    for (key, value) in env {
        let Some(value) = value.as_str() else {
            return Err(KeyError("env must be an object of strings".into()));
        };
        pairs.push((key.clone(), value.to_string()));
    }
    Ok(Some(pairs))
}

#[derive(Debug)]
struct Outgoing {
    conn: ConnId,
    frontend_id: Value,
    method: String,
}

#[derive(Debug)]
struct PendingAgent {
    id_key: String,
    /// `seq` of the agent message that carried the request. A replay keeps it:
    /// `seq` traces the agent's stdout order, and a replay is not new output.
    seq: u64,
    message: Value,
}

/// What to do with one front-end frame.
#[derive(Debug, Clone, PartialEq)]
pub enum FrontendAction {
    /// Send this frame to the agent.
    Forward(Value),
    /// Answer the front end directly (never reaches the agent), with the `seq`
    /// of the agent message this answer is derived from.
    Reply(Value, u64),
    /// Drop the frame silently.
    Drop,
}

/// What to do with one agent frame.
#[derive(Debug, Clone, PartialEq)]
pub enum AgentAction {
    /// Deliver to one connection (already mapped back to its id).
    Response {
        conn: ConnId,
        seq: u64,
        message: Value,
    },
    /// Deliver to every attached connection.
    Notification { seq: u64, message: Value },
    /// An agent-to-client request; `target` is the primary connection.
    Request {
        seq: u64,
        message: Value,
        target: Option<ConnId>,
    },
    /// Nothing to deliver (for example a response whose connection is gone).
    Drop,
    /// A message that is not valid JSON-RPC; logged and dropped.
    Invalid,
}

/// Per-instance relay state.
#[derive(Debug)]
pub struct Relay {
    /// Capabilities of the attach call that created the instance.
    capabilities: Value,
    next_agent_id: u64,
    outgoing: HashMap<u64, Outgoing>,
    by_frontend: HashMap<(ConnId, String), u64>,
    pending: Vec<PendingAgent>,
    pending_ids: HashSet<String>,
    /// Cached `initialize` result, with the `seq` of the agent message that
    /// produced it. Local answers reuse that `seq`, so `seq` stays a count of
    /// what the agent wrote (PROTOCOL.md 3.7).
    initialize: Option<(u64, Value)>,
    seq: u64,
}

impl Relay {
    pub fn new(capabilities: Value) -> Self {
        Self {
            capabilities,
            next_agent_id: 0,
            outgoing: HashMap::new(),
            by_frontend: HashMap::new(),
            pending: Vec::new(),
            pending_ids: HashSet::new(),
            initialize: None,
            seq: 0,
        }
    }

    /// Whether the instance already has a cached `initialize` result.
    pub fn initialized(&self) -> bool {
        self.initialize.is_some()
    }

    /// The `seq` of the last agent message seen, for diagnostics and tests.
    pub fn last_seq(&self) -> u64 {
        self.seq
    }

    /// Number of `session/prompt` requests the agent has not answered yet.
    pub fn turns_running(&self) -> usize {
        self.outgoing
            .values()
            .filter(|outgoing| outgoing.method == "session/prompt")
            .count()
    }

    /// Agent-to-client requests nobody answered yet.
    pub fn pending_requests(&self) -> usize {
        self.pending.len()
    }

    /// Pending agent requests, in arrival order, for a newly attached primary.
    /// Each entry carries the `seq` the request was originally delivered with.
    pub fn pending_messages(&self) -> Vec<(u64, Value)> {
        self.pending
            .iter()
            .map(|pending| (pending.seq, pending.message.clone()))
            .collect()
    }

    /// Handle one frame sent by a front end (PROTOCOL.md 5.1 and 5.5).
    pub fn frontend_message(&mut self, conn: ConnId, message: &Value) -> FrontendAction {
        let Some(object) = message.as_object() else {
            return FrontendAction::Drop;
        };

        match object.get("method") {
            Some(Value::String(method)) => {
                let method = method.clone();
                match object.get("id") {
                    Some(id) => self.frontend_request(conn, message, object, &method, id),
                    None => self.frontend_notification(conn, message, object, &method),
                }
            }
            Some(_) => FrontendAction::Drop,
            None => self.frontend_response(message, object),
        }
    }

    fn frontend_request(
        &mut self,
        conn: ConnId,
        message: &Value,
        object: &Map<String, Value>,
        method: &str,
        id: &Value,
    ) -> FrontendAction {
        if method == "initialize" {
            if let Some((cached_seq, cached)) = &self.initialize {
                let cached_seq = *cached_seq;
                let cached = cached.clone();
                let capabilities = object
                    .get("params")
                    .and_then(|params| params.get("clientCapabilities"))
                    .cloned()
                    .unwrap_or(Value::Null);
                if canonical_json(&capabilities) != canonical_json(&self.capabilities) {
                    return FrontendAction::Reply(
                        json!({
                            "jsonrpc": "2.0",
                            "id": id.clone(),
                            "error": {
                                "code": CAPABILITIES_DIFFER,
                                "message": "initialize capabilities differ from the attach call",
                            },
                        }),
                        cached_seq,
                    );
                }
                return FrontendAction::Reply(
                    json!({
                        "jsonrpc": "2.0",
                        "id": id.clone(),
                        "result": cached,
                    }),
                    cached_seq,
                );
            }
        }

        self.next_agent_id += 1;
        let agent_id = self.next_agent_id;
        let mut forwarded = message.clone();
        forwarded["id"] = json!(agent_id);
        self.outgoing.insert(
            agent_id,
            Outgoing {
                conn,
                frontend_id: id.clone(),
                method: method.to_string(),
            },
        );
        self.by_frontend.insert((conn, id_key(id)), agent_id);
        FrontendAction::Forward(forwarded)
    }

    fn frontend_notification(
        &mut self,
        conn: ConnId,
        message: &Value,
        object: &Map<String, Value>,
        method: &str,
    ) -> FrontendAction {
        if method != "$/cancel_request" {
            return FrontendAction::Forward(message.clone());
        }
        // `params.id` is a front-end id of this connection.
        let Some(target) = object.get("params").and_then(|params| params.get("id")) else {
            return FrontendAction::Drop;
        };
        match self.by_frontend.get(&(conn, id_key(target))).copied() {
            Some(agent_id) => FrontendAction::Forward(with_param_id(message, json!(agent_id))),
            None => FrontendAction::Drop,
        }
    }

    fn frontend_response(
        &mut self,
        message: &Value,
        object: &Map<String, Value>,
    ) -> FrontendAction {
        let Some(id) = object.get("id") else {
            return FrontendAction::Drop;
        };
        if self.remove_pending(&id_key(id)) {
            FrontendAction::Forward(message.clone())
        } else {
            FrontendAction::Drop
        }
    }

    /// Handle one frame received from the agent (PROTOCOL.md 5.2 and 5.5).
    ///
    /// Every object the agent writes takes the next `seq` (section 3.7), even
    /// when the resulting action is not delivered.
    pub fn agent_message(&mut self, message: &Value, attached: &[ConnId]) -> AgentAction {
        let Some(object) = message.as_object() else {
            return AgentAction::Invalid;
        };
        self.seq += 1;
        let seq = self.seq;
        match object.get("method") {
            Some(Value::String(method)) => {
                let method = method.clone();
                match object.get("id") {
                    Some(id) => {
                        // Agent-to-client request: remember it and hand it to
                        // the primary connection (none when nobody is attached).
                        let key = id_key(id);
                        if self.pending_ids.insert(key.clone()) {
                            self.pending.push(PendingAgent {
                                id_key: key,
                                seq,
                                message: message.clone(),
                            });
                        }
                        AgentAction::Request {
                            seq,
                            message: message.clone(),
                            target: attached.last().copied(),
                        }
                    }
                    None => {
                        if method == "$/cancel_request" {
                            if let Some(target) =
                                object.get("params").and_then(|params| params.get("id"))
                            {
                                self.remove_pending(&id_key(target));
                            }
                        }
                        AgentAction::Notification {
                            seq,
                            message: message.clone(),
                        }
                    }
                }
            }
            Some(_) => AgentAction::Invalid,
            None => self.agent_response(message, object, attached, seq),
        }
    }

    fn agent_response(
        &mut self,
        message: &Value,
        object: &Map<String, Value>,
        attached: &[ConnId],
        seq: u64,
    ) -> AgentAction {
        let Some(agent_id) = object.get("id").and_then(Value::as_u64) else {
            return AgentAction::Invalid;
        };
        let Some(outgoing) = self.outgoing.remove(&agent_id) else {
            // A response with no mapping is not something a front end can use.
            return AgentAction::Invalid;
        };
        self.by_frontend
            .remove(&(outgoing.conn, id_key(&outgoing.frontend_id)));

        // The first successful `initialize` is cached for the instance's life.
        if outgoing.method == "initialize" {
            if let Some(result) = object.get("result") {
                self.initialize = Some((seq, result.clone()));
            }
        }

        if !attached.contains(&outgoing.conn) {
            return AgentAction::Drop;
        }
        let mut mapped = message.clone();
        mapped["id"] = outgoing.frontend_id;
        AgentAction::Response {
            conn: outgoing.conn,
            seq,
            message: mapped,
        }
    }

    fn remove_pending(&mut self, key: &str) -> bool {
        if !self.pending_ids.remove(key) {
            return false;
        }
        if let Some(position) = self
            .pending
            .iter()
            .position(|pending| pending.id_key == key)
        {
            self.pending.remove(position);
        }
        true
    }
}

/// Clone `message` and set `params.id`, keeping everything else untouched.
fn with_param_id(message: &Value, id: Value) -> Value {
    let mut forwarded = message.clone();
    let mut params = match forwarded.get("params") {
        Some(Value::Object(map)) => map.clone(),
        _ => Map::new(),
    };
    params.insert("id".to_string(), id);
    forwarded["params"] = Value::Object(params);
    forwarded
}

#[cfg(test)]
mod tests {
    use super::*;

    const A: ConnId = 1;
    const B: ConnId = 2;

    #[test]
    fn identity_ignores_key_order() {
        let a = json!({
            "key": {
                "agent": "claude",
                "command": "/bin/claude",
                "args": ["--acp"],
                "cwd": "/tmp/p",
            },
            "client_capabilities": {"b": 1, "a": {"y": 2, "x": 1}},
        });
        let b = json!({
            "client_capabilities": {"a": {"x": 1, "y": 2}, "b": 1},
            "key": {
                "cwd": "/tmp/p",
                "args": ["--acp"],
                "command": "/bin/claude",
                "agent": "claude",
            },
        });
        let left = InstanceKey::from_params(&a).expect("key a");
        let right = InstanceKey::from_params(&b).expect("key b");
        assert_eq!(left.identity(), right.identity());
    }

    #[test]
    fn identity_changes_with_capabilities() {
        let base = json!({
            "key": {"agent": "a", "command": "c", "args": [], "cwd": "/"},
            "client_capabilities": {"fs": {"readTextFile": true}},
        });
        let other = json!({
            "key": {"agent": "a", "command": "c", "args": [], "cwd": "/"},
            "client_capabilities": {"fs": {"readTextFile": false}},
        });
        let left = InstanceKey::from_params(&base).expect("base");
        let right = InstanceKey::from_params(&other).expect("other");
        assert_ne!(left.identity(), right.identity());
    }

    #[test]
    fn identity_is_independent_of_env() {
        let base = json!({
            "key": {"agent": "a", "command": "c", "args": [], "cwd": "/"},
            "client_capabilities": {},
        });
        let with_env = json!({
            "key": {"agent": "a", "command": "c", "args": [], "cwd": "/"},
            "client_capabilities": {},
            "env": {"SECRET": "x"},
        });
        let left = InstanceKey::from_params(&base).expect("base");
        let right = InstanceKey::from_params(&with_env).expect("with env");
        assert_eq!(left.identity(), right.identity());
    }

    #[test]
    fn invalid_keys_are_rejected() {
        assert!(InstanceKey::from_params(&json!({})).is_err());
        assert!(InstanceKey::from_params(&json!({"key": {}})).is_err());
        assert!(InstanceKey::from_params(&json!({
            "key": {"agent": "a", "command": "c", "args": [1], "cwd": "/"}
        }))
        .is_err());
        assert!(InstanceKey::from_params(&json!({
            "key": {"agent": "a", "command": "c", "args": [], "cwd": "/"},
            "client_capabilities": 5
        }))
        .is_err());
    }

    #[test]
    fn env_is_parsed_and_validated() {
        let params = json!({"env": {"A": "1", "B": "2"}});
        let env = parse_env(&params).expect("env").expect("present");
        assert_eq!(
            env,
            vec![
                ("A".to_string(), "1".to_string()),
                ("B".to_string(), "2".to_string())
            ]
        );
        assert!(parse_env(&json!({})).expect("absent").is_none());
        assert!(parse_env(&json!({"env": {"A": 1}})).is_err());
    }

    fn request(id: Value, method: &str, params: Value) -> Value {
        json!({"jsonrpc": "2.0", "id": id, "method": method, "params": params})
    }

    #[test]
    fn frontend_requests_get_distinct_agent_ids() {
        let mut relay = Relay::new(json!({}));
        let first = relay.frontend_message(A, &request(json!(1), "session/new", json!({})));
        let second = relay.frontend_message(B, &request(json!("x"), "session/new", json!({})));
        let FrontendAction::Forward(first) = first else {
            panic!("first must be forwarded")
        };
        let FrontendAction::Forward(second) = second else {
            panic!("second must be forwarded")
        };
        assert_eq!(first["id"], 1);
        assert_eq!(second["id"], 2);
    }

    #[test]
    fn responses_return_to_the_requesting_connection_with_the_frontend_id() {
        let mut relay = Relay::new(json!({}));
        let request = request(json!("abc"), "session/new", json!({}));
        let FrontendAction::Forward(forwarded) = relay.frontend_message(A, &request) else {
            panic!("forwarded")
        };
        let agent_id = forwarded["id"].as_u64().expect("numeric agent id");
        let response = json!({"jsonrpc": "2.0", "id": agent_id, "result": {"sessionId": "s1"}});
        let action = relay.agent_message(&response, &[A, B]);
        match action {
            AgentAction::Response { conn, seq, message } => {
                assert_eq!(conn, A);
                assert_eq!(seq, 1);
                assert_eq!(message["id"], "abc");
                assert_eq!(message["result"]["sessionId"], "s1");
            }
            other => panic!("unexpected {other:?}"),
        }
    }

    #[test]
    fn a_response_for_a_gone_connection_is_dropped() {
        let mut relay = Relay::new(json!({}));
        let FrontendAction::Forward(forwarded) =
            relay.frontend_message(A, &request(json!(1), "session/new", json!({})))
        else {
            panic!("forwarded")
        };
        let agent_id = forwarded["id"].as_u64().expect("agent id");
        let response = json!({"jsonrpc": "2.0", "id": agent_id, "result": {}});
        assert_eq!(relay.agent_message(&response, &[B]), AgentAction::Drop);
        // The request is still forgotten, otherwise a turn started by a front
        // end that has gone away would keep the service alive forever
        // (PROTOCOL.md section 8).
        assert_eq!(relay.turns_running(), 0);
    }

    #[test]
    fn a_prompt_whose_connection_is_gone_stops_counting_as_a_running_turn() {
        let mut relay = Relay::new(json!({}));
        let FrontendAction::Forward(forwarded) =
            relay.frontend_message(A, &request(json!(1), "session/prompt", json!({})))
        else {
            panic!("forwarded")
        };
        assert_eq!(relay.turns_running(), 1);
        let agent_id = forwarded["id"].as_u64().expect("agent id");
        let response = json!({
            "jsonrpc": "2.0",
            "id": agent_id,
            "result": {"stopReason": "end_turn"},
        });
        assert_eq!(relay.agent_message(&response, &[]), AgentAction::Drop);
        assert_eq!(relay.turns_running(), 0);
    }

    #[test]
    fn agent_requests_go_to_the_primary_and_are_replayed_in_order() {
        let mut relay = Relay::new(json!({}));
        let first = json!({"jsonrpc": "2.0", "id": 9001, "method": "session/request_permission"});
        let second = json!({"jsonrpc": "2.0", "id": 9002, "method": "elicitation/create"});

        assert_eq!(
            relay.agent_message(&first, &[A]),
            AgentAction::Request {
                seq: 1,
                message: first.clone(),
                target: Some(A)
            }
        );
        assert_eq!(
            relay.agent_message(&second, &[A]),
            AgentAction::Request {
                seq: 2,
                message: second.clone(),
                target: Some(A)
            }
        );
        assert_eq!(relay.pending_requests(), 2);
        assert_eq!(
            relay.pending_messages(),
            vec![(1, first.clone()), (2, second.clone())]
        );

        // The pending set is replayed to whoever becomes primary next, in the
        // original order and with the original seq.
        assert_eq!(relay.pending_messages(), vec![(1, first), (2, second)]);
    }

    #[test]
    fn agent_requests_without_a_connection_are_kept() {
        let mut relay = Relay::new(json!({}));
        let request = json!({"jsonrpc": "2.0", "id": 7, "method": "session/request_permission"});
        assert_eq!(
            relay.agent_message(&request, &[]),
            AgentAction::Request {
                seq: 1,
                message: request.clone(),
                target: None
            }
        );
        assert_eq!(relay.pending_requests(), 1);
        assert_eq!(relay.pending_messages(), vec![(1, request)]);
    }

    #[test]
    fn answering_a_pending_request_forwards_it_and_forgets_it() {
        let mut relay = Relay::new(json!({}));
        let request = json!({"jsonrpc": "2.0", "id": 42, "method": "session/request_permission"});
        relay.agent_message(&request, &[A]);
        let answer =
            json!({"jsonrpc": "2.0", "id": 42, "result": {"outcome": {"outcome": "selected"}}});
        assert_eq!(
            relay.frontend_message(A, &answer),
            FrontendAction::Forward(answer.clone())
        );
        assert_eq!(relay.pending_requests(), 0);
        // A second answer for the same id is dropped silently.
        assert_eq!(relay.frontend_message(A, &answer), FrontendAction::Drop);
    }

    #[test]
    fn an_agent_cancel_removes_the_pending_request() {
        let mut relay = Relay::new(json!({}));
        let request = json!({"jsonrpc": "2.0", "id": 33, "method": "session/request_permission"});
        relay.agent_message(&request, &[A]);
        let cancel = json!({"jsonrpc": "2.0", "method": "$/cancel_request", "params": {"id": 33}});
        assert_eq!(
            relay.agent_message(&cancel, &[A]),
            AgentAction::Notification {
                seq: 2,
                message: cancel.clone()
            }
        );
        assert_eq!(relay.pending_requests(), 0);
        // The front end's late answer is dropped.
        let answer = json!({"jsonrpc": "2.0", "id": 33, "result": {}});
        assert_eq!(relay.frontend_message(A, &answer), FrontendAction::Drop);
    }

    #[test]
    fn frontend_cancel_is_translated_per_connection() {
        let mut relay = Relay::new(json!({}));
        let FrontendAction::Forward(first) =
            relay.frontend_message(A, &request(json!("fa"), "session/prompt", json!({})))
        else {
            panic!("forwarded")
        };
        let FrontendAction::Forward(second) =
            relay.frontend_message(B, &request(json!("fb"), "session/prompt", json!({})))
        else {
            panic!("forwarded")
        };
        let first_agent = first["id"].as_u64().expect("agent id");
        let second_agent = second["id"].as_u64().expect("agent id");

        let cancel =
            json!({"jsonrpc": "2.0", "method": "$/cancel_request", "params": {"id": "fb"}});
        match relay.frontend_message(B, &cancel) {
            FrontendAction::Forward(forwarded) => {
                assert_eq!(forwarded["params"]["id"], second_agent);
                assert_ne!(forwarded["params"]["id"], first_agent);
            }
            other => panic!("unexpected {other:?}"),
        }

        // A's ids are not visible from B.
        let foreign =
            json!({"jsonrpc": "2.0", "method": "$/cancel_request", "params": {"id": "fa"}});
        assert_eq!(relay.frontend_message(B, &foreign), FrontendAction::Drop);
        // A can cancel its own request.
        match relay.frontend_message(A, &foreign) {
            FrontendAction::Forward(forwarded) => {
                assert_eq!(forwarded["params"]["id"], first_agent);
            }
            other => panic!("unexpected {other:?}"),
        }
    }

    #[test]
    fn turns_running_counts_unanswered_prompts() {
        let mut relay = Relay::new(json!({}));
        assert_eq!(relay.turns_running(), 0);
        let FrontendAction::Forward(forwarded) =
            relay.frontend_message(A, &request(json!(1), "session/prompt", json!({})))
        else {
            panic!("forwarded")
        };
        relay.frontend_message(A, &request(json!(2), "session/new", json!({})));
        assert_eq!(relay.turns_running(), 1);
        let agent_id = forwarded["id"].as_u64().expect("agent id");
        let response =
            json!({"jsonrpc": "2.0", "id": agent_id, "result": {"stopReason": "end_turn"}});
        relay.agent_message(&response, &[A]);
        assert_eq!(relay.turns_running(), 0);
    }

    #[test]
    fn initialize_is_cached_and_answered_locally() {
        let capabilities = json!({"fs": {"readTextFile": true}});
        let mut relay = Relay::new(capabilities.clone());
        let initialize = json!({
            "jsonrpc": "2.0",
            "id": 1,
            "method": "initialize",
            "params": {"clientCapabilities": capabilities, "protocolVersion": 1},
        });
        let FrontendAction::Forward(forwarded) = relay.frontend_message(A, &initialize) else {
            panic!("first initialize is forwarded")
        };
        assert!(!relay.initialized());
        let agent_id = forwarded["id"].as_u64().expect("agent id");
        let result = json!({"protocolVersion": 1, "agentCapabilities": {}});
        relay.agent_message(
            &json!({"jsonrpc": "2.0", "id": agent_id, "result": result.clone()}),
            &[A, B],
        );
        assert!(relay.initialized());

        let second = json!({
            "jsonrpc": "2.0",
            "id": "second",
            "method": "initialize",
            "params": {"clientCapabilities": capabilities},
        });
        match relay.frontend_message(B, &second) {
            FrontendAction::Reply(reply, seq) => {
                assert_eq!(reply["id"], "second");
                assert_eq!(reply["result"], result);
                // The seq of the agent's initialize response is reused.
                assert_eq!(seq, 1);
            }
            other => panic!("unexpected {other:?}"),
        }
    }

    #[test]
    fn initialize_with_other_capabilities_is_rejected() {
        let capabilities = json!({"fs": {"readTextFile": true}});
        let mut relay = Relay::new(capabilities.clone());
        let FrontendAction::Forward(forwarded) = relay.frontend_message(
            A,
            &json!({
                "jsonrpc": "2.0",
                "id": 1,
                "method": "initialize",
                "params": {"clientCapabilities": capabilities},
            }),
        ) else {
            panic!("forwarded")
        };
        let agent_id = forwarded["id"].as_u64().expect("agent id");
        relay.agent_message(
            &json!({"jsonrpc": "2.0", "id": agent_id, "result": {}}),
            &[A],
        );

        let differing = json!({
            "jsonrpc": "2.0",
            "id": 2,
            "method": "initialize",
            "params": {"clientCapabilities": {"fs": {"readTextFile": false}}},
        });
        match relay.frontend_message(B, &differing) {
            FrontendAction::Reply(reply, _seq) => {
                assert_eq!(reply["error"]["code"], CAPABILITIES_DIFFER);
                assert_eq!(reply["id"], 2);
            }
            other => panic!("unexpected {other:?}"),
        }
    }

    #[test]
    fn a_failed_initialize_is_not_cached() {
        let mut relay = Relay::new(json!({}));
        let initialize = json!({
            "jsonrpc": "2.0",
            "id": 1,
            "method": "initialize",
            "params": {"clientCapabilities": {}},
        });
        let FrontendAction::Forward(forwarded) = relay.frontend_message(A, &initialize) else {
            panic!("forwarded")
        };
        let agent_id = forwarded["id"].as_u64().expect("agent id");
        relay.agent_message(
            &json!({"jsonrpc": "2.0", "id": agent_id, "error": {"code": -1, "message": "no"}}),
            &[A],
        );
        assert!(!relay.initialized());
        // The next initialize goes to the agent again.
        let next = json!({
            "jsonrpc": "2.0",
            "id": 2,
            "method": "initialize",
            "params": {"clientCapabilities": {}},
        });
        assert!(matches!(
            relay.frontend_message(B, &next),
            FrontendAction::Forward(_)
        ));
    }

    #[test]
    fn notifications_are_forwarded_unchanged() {
        let mut relay = Relay::new(json!({}));
        let notification = json!({"jsonrpc": "2.0", "method": "session/cancel", "params": {}});
        assert_eq!(
            relay.frontend_message(A, &notification),
            FrontendAction::Forward(notification.clone())
        );
    }

    #[test]
    fn seq_starts_at_one_and_increases_with_agent_messages() {
        let mut relay = Relay::new(json!({}));
        let notification = json!({"jsonrpc": "2.0", "method": "session/update", "params": {}});
        assert_eq!(
            relay.agent_message(&notification, &[A]),
            AgentAction::Notification {
                seq: 1,
                message: notification.clone()
            }
        );
        assert_eq!(
            relay.agent_message(&notification, &[A]),
            AgentAction::Notification {
                seq: 2,
                message: notification
            }
        );
    }

    #[test]
    fn non_object_frames_are_dropped() {
        let mut relay = Relay::new(json!({}));
        assert_eq!(
            relay.frontend_message(A, &json!([1, 2])),
            FrontendAction::Drop
        );
        assert_eq!(relay.agent_message(&json!("x"), &[A]), AgentAction::Invalid);
        assert_eq!(
            relay.agent_message(&json!({"id": "not-a-number"}), &[A]),
            AgentAction::Invalid
        );
    }
}
