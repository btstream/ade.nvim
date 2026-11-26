//! Relay rules for one agent instance (PROTOCOL.md sections 5, 11, 13 and 14).
//!
//! This module is pure state and has no I/O: it decides what to forward, what
//! to answer locally, and which connection receives an agent message. It also
//! tracks the sessions living in the agent process, adopts an orphaned turn
//! and computes the retractions of a request. The process and socket handling
//! live in [`crate::runtime`] and [`crate::hub`].

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

/// Wall-clock milliseconds, the default `updated_at` source.
fn system_now_ms() -> i64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|elapsed| elapsed.as_millis() as i64)
        .unwrap_or(0)
}

/// A session the relay knows to be live in the agent process (PROTOCOL.md 11).
#[derive(Debug, Clone)]
pub struct Session {
    pub id: String,
    pub cwd: String,
    /// The `session/new` result, kept current by the updates below.
    pub state: Value,
    /// Time of the last event for this session (unix ms).
    pub updated_at: i64,
    /// False once the log lost an event of this session (PROTOCOL.md 10).
    pub complete: bool,
}

impl Session {
    fn summary(&self, running: bool) -> SessionSummary {
        SessionSummary {
            session_id: self.id.clone(),
            cwd: self.cwd.clone(),
            running,
            updated_at: self.updated_at,
        }
    }

    /// Replace `state.configOptions` (a `config_option_update` update, or a
    /// successful `session/set_config_option`).
    fn set_config_options(&mut self, config_options: &Value) {
        if let Value::Object(state) = &mut self.state {
            state.insert("configOptions".to_string(), config_options.clone());
        } else {
            self.state = json!({ "configOptions": config_options });
        }
    }

    /// Set `state.modes.currentModeId` (a `current_mode_update` update).
    fn set_current_mode(&mut self, mode_id: &Value) {
        let Value::Object(state) = &mut self.state else {
            self.state = json!({ "modes": { "currentModeId": mode_id.clone() } });
            return;
        };
        let modes = state
            .entry("modes".to_string())
            .or_insert_with(|| json!({}));
        if !modes.is_object() {
            *modes = json!({});
        }
        if let Value::Object(modes) = modes {
            modes.insert("currentModeId".to_string(), mode_id.clone());
        }
    }
}

/// One session as `agent.attach` reports it (PROTOCOL.md 3.2).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SessionSummary {
    pub session_id: String,
    pub cwd: String,
    pub running: bool,
    pub updated_at: i64,
}

impl SessionSummary {
    pub fn to_json(&self) -> Value {
        json!({
            "sessionId": self.session_id,
            "cwd": self.cwd,
            "running": self.running,
            "updated_at": self.updated_at,
        })
    }
}

/// A connection that just adopted an orphaned turn (PROTOCOL.md 13).
#[derive(Debug, Clone, PartialEq)]
pub struct Adopted {
    pub session_id: String,
    /// `seq` for the `_ade/turn_adopted` message.
    pub seq: u64,
}

/// A connection that must be told a pending request is no longer needed
/// (PROTOCOL.md 14).
#[derive(Debug, Clone, PartialEq)]
pub struct Retracted {
    pub conn: ConnId,
    /// `seq` for the `$/cancel_request` message.
    pub seq: u64,
    /// The agent's id of the request.
    pub id: Value,
}

#[derive(Debug, Clone, PartialEq, Eq)]
enum Origin {
    Frontend {
        conn: ConnId,
        frontend_id: Value,
    },
    /// A request the service sent itself (the team driver). Its response is
    /// consumed by the team layer and never forwarded.
    Service,
}

#[derive(Debug)]
struct Outgoing {
    origin: Origin,
    method: String,
    /// `params.sessionId`, when the request carried one.
    session_id: Option<String>,
    /// `params.cwd`, when the request carried one (session/new, load, resume).
    cwd: Option<String>,
}

#[derive(Debug)]
struct PendingAgent {
    id_key: String,
    /// The agent's id, so a retraction can echo it (PROTOCOL.md 14).
    id: Value,
    /// `seq` of the agent message that carried the request. A replay keeps it:
    /// `seq` traces the agent's stdout order, and a replay is not new output.
    seq: u64,
    message: Value,
    /// Connections this request was delivered to, in delivery order. Used to
    /// retract the request from the others when one of them answers it.
    delivered: Vec<ConnId>,
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
    /// Like `Forward`, but other connections that received the answered agent
    /// request must first be told it is gone (PROTOCOL.md 14), and/or the frame
    /// produced events to record (PROTOCOL.md 10).
    ForwardWith {
        frame: Value,
        retractions: Vec<Retracted>,
        events: Vec<PendingEvent>,
    },
    /// The service answers this `session/load` itself (PROTOCOL.md 12), after
    /// the hub confirmed the session's log is complete.
    LoadCandidate(LoadCandidate),
}

impl FrontendAction {
    fn with_retractions(self, retractions: Vec<Retracted>) -> Self {
        self.with(retractions, Vec::new())
    }

    /// Attach recorded events (and retractions) to a forward.
    fn with(self, retractions: Vec<Retracted>, events: Vec<PendingEvent>) -> Self {
        if retractions.is_empty() && events.is_empty() {
            return self;
        }
        match self {
            Self::Forward(frame) => Self::ForwardWith {
                frame,
                retractions,
                events,
            },
            Self::ForwardWith {
                frame,
                retractions: existing,
                events: existing_events,
            } => Self::ForwardWith {
                frame,
                retractions: [existing, retractions].concat(),
                events: [existing_events, events].concat(),
            },
            other => other,
        }
    }

    /// The forwarding outcome, independent of retractions (tests).
    pub fn forwarded(&self) -> Option<&Value> {
        match self {
            Self::Forward(frame) => Some(frame),
            Self::ForwardWith { frame, .. } => Some(frame),
            _ => None,
        }
    }

    /// Events this frame must record (PROTOCOL.md 10).
    pub fn events(&self) -> &[PendingEvent] {
        match self {
            Self::ForwardWith { events, .. } => events,
            _ => &[],
        }
    }

    /// Retractions that must be sent before the forwarded frame (tests).
    pub fn retractions(&self) -> &[Retracted] {
        match self {
            Self::ForwardWith { retractions, .. } => retractions,
            _ => &[],
        }
    }
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
    /// The response to a request the service sent itself (team driver).
    ServiceResponse {
        agent_id: u64,
        seq: u64,
        message: Value,
    },
    /// Nothing to deliver (for example a response whose connection is gone).
    Drop,
    /// A message that is not valid JSON-RPC; logged and dropped.
    Invalid,
}

/// A response that ended an orphaned turn adopted by some connections
/// (PROTOCOL.md 13). The response itself still needs its normal delivery (or
/// is dropped when its requester is gone).
#[derive(Debug, Clone, PartialEq)]
pub struct FinishedTurn {
    pub session_id: String,
    /// `{sessionId, stopReason}` or `{sessionId, error}`.
    pub params: Value,
    pub adopters: Vec<ConnId>,
    /// `seq` for each `_ade/turn_finished` message.
    pub seq: u64,
    /// True for an adopted front-end turn (which must stop counting); false
    /// for a bus turn, whose held human prompt may already have a new outgoing
    /// entry for the same session (18.11).
    pub adoption: bool,
}

/// One event the relay wants recorded (PROTOCOL.md 10). The recorder stamps it
/// with the instance key and writes it; `seq` comes from the relay.
#[derive(Debug, Clone, PartialEq)]
pub struct PendingEvent {
    pub seq: u64,
    pub session_id: Option<String>,
    /// `AgentNotification` or `Synthetic`.
    pub synthetic: bool,
    /// Raw JSON text, stored verbatim.
    pub message: String,
}

/// A `session/load` that may be answered from the event log (PROTOCOL.md 12).
///
/// The relay checks everything it knows (the log is on, the session is tracked
/// and complete, the agent advertised `loadSession`); the hub then asks the
/// recorder whether the *log* is complete. If it is not, the hub forwards the
/// original request instead (`Relay::forward_request`).
#[derive(Debug, Clone, PartialEq)]
pub struct LoadCandidate {
    /// The front end's request id, for the response.
    pub frontend_id: Value,
    pub session_id: String,
    /// Upper bound of `seq` for the replay: events recorded while the replay
    /// is read belong to the live stream, not to it.
    pub up_to_seq: u64,
    /// The tracked state, used as the response `result`.
    pub state: Value,
    /// The original frame, forwarded to the agent if the log is incomplete.
    pub frame: Value,
}

/// A `session/prompt` response: its turn_end policy sets are removed.
#[derive(Debug, Clone, PartialEq)]
pub struct PromptFinished {
    pub conn: ConnId,
    pub session_id: String,
}

/// One agent request delivered to a connection (the hub tracks these for
/// retraction, PROTOCOL.md 14).
#[derive(Debug, Clone, PartialEq)]
pub struct Delivery {
    pub id: Value,
    pub conn: ConnId,
}

/// Everything that has to be sent because of one agent frame.
#[derive(Debug, Clone, Default, PartialEq)]
pub struct AgentOutcome {
    pub action: Option<AgentAction>,
    /// Connections whose pending request this frame withdraws: each gets
    /// `$/cancel_request` with the agent's id (PROTOCOL.md 14).
    pub retractions: Vec<Retracted>,
    /// Set when the frame answered a `session/prompt` of an adopted session.
    pub finished_turn: Option<FinishedTurn>,
    /// The connection whose `session/prompt` this frame answered (policy turn
    /// bookkeeping, PROTOCOL.md 17.3).
    pub prompt_finished: Option<PromptFinished>,
    /// Events to record for this frame (PROTOCOL.md 10).
    pub events: Vec<PendingEvent>,
    /// The same requests the action delivers, so the hub can remember them.
    pub delivered: Vec<Delivery>,
    /// A front end closed or deleted this session successfully.
    pub closed_session: Option<String>,
    /// The same, but only for a successful `session/delete`: the catalog row
    /// must go (PROTOCOL.md 21.4). `session/close` leaves it in place.
    pub deleted_session: Option<String>,
    /// The front-end request this frame answers (20.2 token binding).
    pub frontend_request: Option<FrontendRequest>,
}

/// The front-end request a response answers.
#[derive(Debug, Clone, PartialEq)]
pub struct FrontendRequest {
    pub conn: ConnId,
    pub frontend_id: Value,
    pub method: String,
    pub agent_id: u64,
    pub session_id: Option<String>,
}

impl AgentOutcome {
    /// Attach recorded events to an outcome.
    fn with_events(mut self, events: Vec<PendingEvent>) -> Self {
        self.events = events;
        self
    }
}

impl AgentOutcome {
    fn with(action: AgentAction) -> Self {
        Self {
            action: Some(action),
            ..Self::default()
        }
    }
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
    /// Sessions known to live in the agent process (PROTOCOL.md 11), keyed by
    /// session id. Empty when the event log is disabled.
    sessions: HashMap<String, Session>,
    /// Whether the event log is enabled; when it is not, no session is tracked
    /// and `agent.attach` never reports one (PROTOCOL.md 3.2 and 10).
    log_enabled: bool,
    /// Connections that adopted the orphaned prompt of a session (PROTOCOL.md
    /// 13), by session id.
    adopters: HashMap<String, Vec<ConnId>>,
    /// Clock used for `updated_at`; replaceable so tests stay deterministic.
    now: fn() -> i64,
}

impl Relay {
    pub fn new(capabilities: Value) -> Self {
        Self::with_log(capabilities, true)
    }

    /// `log_enabled` mirrors the `"log"` feature: with it off, no session is
    /// tracked, `agent.attach` reports no sessions and `session/load` is
    /// always forwarded (PROTOCOL.md 3.2, 10, 12).
    pub fn with_log(capabilities: Value, log_enabled: bool) -> Self {
        Self {
            capabilities,
            next_agent_id: 0,
            outgoing: HashMap::new(),
            by_frontend: HashMap::new(),
            pending: Vec::new(),
            pending_ids: HashSet::new(),
            initialize: None,
            seq: 0,
            sessions: HashMap::new(),
            log_enabled,
            adopters: HashMap::new(),
            now: system_now_ms,
        }
    }

    /// Replace the clock used for `updated_at` (tests).
    pub fn set_clock(&mut self, now: fn() -> i64) {
        self.now = now;
    }

    pub fn log_enabled(&self) -> bool {
        self.log_enabled
    }

    /// The current `seq`, the upper bound for a replay that must not include
    /// anything recorded later (PROTOCOL.md 12).
    pub fn current_seq(&self) -> u64 {
        self.seq
    }

    /// Allocate the next `seq` for a message the service produces itself (the
    /// response to an emulated `session/load`, for example). Numbers increase
    /// strictly, so a response never repeats a replayed event's number
    /// (PROTOCOL.md 3.7).
    pub fn allocate_seq(&mut self) -> u64 {
        self.seq += 1;
        self.seq
    }

    /// The `initialize` result the agent returned, once it succeeded.
    pub fn initialize_result(&self) -> Option<&Value> {
        self.initialize.as_ref().map(|(_, result)| result)
    }

    /// Forget a service request that will never be answered (a timed-out
    /// catalog listing). A late response for it is then an unknown id and is
    /// dropped like any other unmapped response.
    pub fn forget_service_request(&mut self, agent_id: u64) {
        self.outgoing.remove(&agent_id);
    }

    /// Sessions known to live in the instance, newest activity first
    /// (PROTOCOL.md 3.2).
    pub fn session_summaries(&self) -> Vec<SessionSummary> {
        if !self.log_enabled {
            return Vec::new();
        }
        let mut summaries: Vec<SessionSummary> = self
            .sessions
            .values()
            .map(|session| session.summary(self.session_running(&session.id)))
            .collect();
        summaries.sort_by(|left, right| {
            right
                .updated_at
                .cmp(&left.updated_at)
                .then_with(|| left.session_id.cmp(&right.session_id))
        });
        summaries
    }

    /// Number of tracked sessions, for `agent.list`.
    pub fn session_count(&self) -> usize {
        self.sessions.len()
    }

    /// Whether `session_id` is tracked and complete, which is the relay part of
    /// the emulated `session/load` condition (PROTOCOL.md 12).
    pub fn session_is_complete(&self, session_id: &str) -> bool {
        self.sessions
            .get(session_id)
            .is_some_and(|session| session.complete)
    }

    /// The tracked state of a session, as the emulated `session/load` answers
    /// (PROTOCOL.md 12).
    pub fn session_state(&self, session_id: &str) -> Option<Value> {
        self.sessions
            .get(session_id)
            .map(|session| session.state.clone())
    }

    /// Whether the session has a `session/prompt` whose requesting connection
    /// is gone (PROTOCOL.md 13).
    pub fn has_orphan_turn(&self, session_id: &str, attached: &[ConnId]) -> bool {
        self.outgoing.values().any(|outgoing| {
            outgoing.method == "session/prompt"
                && outgoing.session_id.as_deref() == Some(session_id)
                && match &outgoing.origin {
                    Origin::Frontend { conn, .. } => !attached.contains(conn),
                    Origin::Service => false,
                }
        })
    }

    /// Make `conn` an adopter of the session's orphaned turn. Returns the
    /// `_ade/turn_adopted` to send, or `None` when there is nothing to adopt or
    /// the connection already adopted it.
    pub fn adopt(
        &mut self,
        conn: ConnId,
        session_id: &str,
        attached: &[ConnId],
    ) -> Option<Adopted> {
        if !self.has_orphan_turn(session_id, attached) {
            return None;
        }
        let adopters = self.adopters.entry(session_id.to_string()).or_default();
        if adopters.contains(&conn) {
            return None;
        }
        adopters.push(conn);
        self.seq += 1;
        Some(Adopted {
            session_id: session_id.to_string(),
            seq: self.seq,
        })
    }

    /// Drop a connection from the delivered sets of pending requests (an
    /// unwatched or closed watcher must not receive later retractions).
    pub fn forget_delivered(&mut self, conn: ConnId) {
        for pending in &mut self.pending {
            pending.delivered.retain(|delivered| *delivered != conn);
        }
    }

    /// Drop `conn` from every session it adopted (its connection closed).
    pub fn forget_adopter(&mut self, conn: ConnId) {
        for adopters in self.adopters.values_mut() {
            adopters.retain(|adopter| *adopter != conn);
        }
        self.adopters.retain(|_, adopters| !adopters.is_empty());
    }

    /// Record that `conn` received the pending request with this id, so it can
    /// be retracted later (PROTOCOL.md 14).
    pub fn mark_delivered(&mut self, id: &Value, conn: ConnId) {
        let Some(pending) = self.pending.iter_mut().find(|pending| pending.id == *id) else {
            return;
        };
        if !pending.delivered.contains(&conn) {
            pending.delivered.push(conn);
        }
    }

    /// Remove a `session/prompt` from the running set because its turn was
    /// taken over: `turns_running` must drop (PROTOCOL.md 13).
    pub fn forget_turn(&mut self, session_id: &str) {
        self.outgoing.retain(|_, outgoing| {
            !(outgoing.method == "session/prompt"
                && outgoing.session_id.as_deref() == Some(session_id))
        });
    }

    /// Whether any `session/prompt` of this session is still in flight, from
    /// any connection (attached, detached/orphan) or the service itself
    /// (20.9 delivery gate).
    pub fn session_prompt_active(&self, session_id: &str) -> bool {
        self.outgoing.values().any(|outgoing| {
            outgoing.method == "session/prompt"
                && outgoing.session_id.as_deref() == Some(session_id)
        })
    }

    /// Whether a prompt the *person* started is still in flight for this
    /// session: a front-end prompt of any connection (attached or orphan). A
    /// service-sent prompt (bus turn, closing notice) is not "foreign" here.
    pub fn foreign_prompt_active(&self, session_id: &str) -> bool {
        self.outgoing.values().any(|outgoing| {
            outgoing.method == "session/prompt"
                && outgoing.session_id.as_deref() == Some(session_id)
                && matches!(outgoing.origin, Origin::Frontend { .. })
        })
    }

    /// Whether `conn` has a `session/prompt` in flight for this session.
    pub fn prompt_active(&self, conn: ConnId, session_id: &str) -> bool {
        self.outgoing.values().any(|outgoing| {
            outgoing.method == "session/prompt"
                && outgoing.session_id.as_deref() == Some(session_id)
                && matches!(&outgoing.origin, Origin::Frontend { conn: owner, .. } if *owner == conn)
        })
    }

    /// Record one synthetic `_ade_policy` event (PROTOCOL.md 17.4). The `seq`
    /// is allocated even when the log is off, so agent-frame numbering stays
    /// monotonic; `None` means there is nothing to record.
    pub fn policy_event(&mut self, session_id: &str, update: Value) -> Option<PendingEvent> {
        self.seq += 1;
        let seq = self.seq;
        self.touch_session(session_id);
        if !self.log_enabled {
            return None;
        }
        Some(PendingEvent {
            seq,
            session_id: Some(session_id.to_string()),
            synthetic: true,
            message: json!({
                "sessionId": session_id,
                "update": update,
            })
            .to_string(),
        })
    }

    fn session_running(&self, session_id: &str) -> bool {
        self.outgoing.values().any(|outgoing| {
            outgoing.method == "session/prompt"
                && outgoing.session_id.as_deref() == Some(session_id)
        })
    }

    /// Forward `frame` for the agent without marking it as a load candidate.
    /// Used by the hub when the recorder says the session's log is incomplete,
    /// or when the emulated load is not possible after all.
    pub fn forward_request(&mut self, conn: ConnId, frame: &Value) -> FrontendAction {
        let Some(object) = frame.as_object() else {
            return FrontendAction::Drop;
        };
        let Some(method) = object.get("method").and_then(Value::as_str) else {
            return FrontendAction::Drop;
        };
        let Some(id) = object.get("id") else {
            return FrontendAction::Drop;
        };
        let method = method.to_string();
        let id = id.clone();
        // Skip the `session/load` candidate check: this is the fallback path.
        let mut forwarded = frame.clone();
        self.next_agent_id += 1;
        let agent_id = self.next_agent_id;
        forwarded["id"] = json!(agent_id);
        let params = object.get("params");
        self.outgoing.insert(
            agent_id,
            Outgoing {
                origin: Origin::Frontend {
                    conn,
                    frontend_id: id.clone(),
                },
                method,
                session_id: params
                    .and_then(|params| params.get("sessionId"))
                    .and_then(Value::as_str)
                    .map(str::to_string),
                cwd: params
                    .and_then(|params| params.get("cwd"))
                    .and_then(Value::as_str)
                    .map(str::to_string),
            },
        );
        self.by_frontend.insert((conn, id_key(&id)), agent_id);
        FrontendAction::Forward(forwarded)
    }

    /// Send a request the service makes to the agent (PROTOCOL.md 18.3).
    ///
    /// It uses the same agent-side id counter as front-end requests, but the
    /// response is marked [`AgentAction::ServiceResponse`] and is never
    /// forwarded to a connection.
    pub fn service_request(&mut self, method: &str, params: Value) -> (u64, Value) {
        self.next_agent_id += 1;
        let agent_id = self.next_agent_id;
        let frame = json!({
            "jsonrpc": "2.0",
            "id": agent_id,
            "method": method,
            "params": params,
        });
        let session_id = params
            .get("sessionId")
            .and_then(Value::as_str)
            .map(str::to_string);
        let cwd = params
            .get("cwd")
            .and_then(Value::as_str)
            .map(str::to_string);
        self.outgoing.insert(
            agent_id,
            Outgoing {
                origin: Origin::Service,
                method: method.to_string(),
                session_id,
                cwd,
            },
        );
        (agent_id, frame)
    }

    /// A bus-delivered prompt (18.4): allocate its agent id, a synthetic
    /// `user_prompt` event and the `seq` the `_ade/turn_started` notification
    /// uses. The caller records the event and sends the frame.
    pub fn service_prompt(
        &mut self,
        session_id: &str,
        params: Value,
    ) -> (u64, Value, u64, Option<PendingEvent>) {
        self.touch_session(session_id);
        self.seq += 1;
        let seq = self.seq;
        let event = if self.log_enabled {
            Some(PendingEvent {
                seq,
                session_id: Some(session_id.to_string()),
                synthetic: true,
                message: user_prompt_event(Some(&params)),
            })
        } else {
            None
        };
        let (agent_id, frame) = self.service_request("session/prompt", params);
        (agent_id, frame, seq, event)
    }

    /// The `tunnel.recv` messages for a replay: each recorded event in its
    /// replay form, in `seq` order (PROTOCOL.md 10 and 12).
    ///
    /// Returns `(seq, message)` pairs; the caller sends them to the requesting
    /// connection only.
    pub fn replay_messages(events: &[crate::store::Event]) -> Vec<(u64, Value)> {
        let mut messages = Vec::new();
        for event in events {
            let Ok(parsed) = serde_json::from_str::<Value>(&event.message) else {
                continue;
            };
            match event.kind {
                crate::store::EventKind::Synthetic => {
                    for message in replay_form(event.seq, &parsed) {
                        messages.push((event.seq, message));
                    }
                }
                _ => messages.push((event.seq, parsed)),
            }
        }
        messages
    }

    /// Answer a pending agent request from the team layer (18.5/18.11): the
    /// item is gone, every watcher that received it is told to retract it, and
    /// the caller sends the response frame itself.
    pub fn answer_pending(&mut self, agent_id: &Value) -> Vec<Retracted> {
        let key = id_key(agent_id);
        let retractions = self.retractions_except(&key, u64::MAX);
        self.remove_pending(&key);
        retractions
    }

    /// Retract the pending request `key` from every connection that received it
    /// except `answerer` (PROTOCOL.md 14 covers only the answer case; an agent
    /// withdrawal is the forwarded `$/cancel_request` itself).
    fn retractions_except(&mut self, key: &str, answerer: ConnId) -> Vec<Retracted> {
        let Some(pending) = self.pending.iter().find(|pending| pending.id_key == key) else {
            return Vec::new();
        };
        let id = pending.id.clone();
        let targets: Vec<ConnId> = pending
            .delivered
            .iter()
            .copied()
            .filter(|conn| *conn != answerer)
            .collect();
        let mut retractions = Vec::with_capacity(targets.len());
        for conn in targets {
            self.seq += 1;
            retractions.push(Retracted {
                conn,
                seq: self.seq,
                id: id.clone(),
            });
        }
        retractions
    }

    /// Whether the instance already has a cached `initialize` result.
    pub fn initialized(&self) -> bool {
        self.initialize.is_some()
    }

    /// Whether the agent advertised `loadSession` in its `initialize` result
    /// (PROTOCOL.md 12).
    pub fn agent_loads_sessions(&self) -> bool {
        self.initialize
            .as_ref()
            .map(|(_, result)| {
                result
                    .get("agentCapabilities")
                    .and_then(|caps| caps.get("loadSession"))
                    .and_then(Value::as_bool)
                    .unwrap_or(false)
            })
            .unwrap_or(false)
    }

    /// Whether the agent can reload a session: `loadSession` or a resume
    /// capability, either a boolean or an object (20.5).
    pub fn agent_reloads_sessions(&self) -> bool {
        self.agent_loads_sessions() || self.agent_resumes_sessions()
    }

    /// Whether the agent advertised `sessionCapabilities.resume`.
    pub fn agent_resumes_sessions(&self) -> bool {
        self.initialize
            .as_ref()
            .map(|(_, result)| {
                result
                    .get("agentCapabilities")
                    .and_then(|caps| caps.get("sessionCapabilities"))
                    .and_then(|caps| caps.get("resume"))
                    .map(|resume| resume.as_bool() == Some(true) || resume.is_object())
                    .unwrap_or(false)
            })
            .unwrap_or(false)
    }

    /// The `seq` of the last agent message seen, for diagnostics and tests.
    pub fn last_seq(&self) -> u64 {
        self.seq
    }

    /// Number of `session/prompt` requests the agent has not answered yet.
    pub fn turns_running(&self) -> usize {
        self.outgoing
            .values()
            .filter(|outgoing| {
                outgoing.method == "session/prompt"
                    && matches!(outgoing.origin, Origin::Frontend { .. })
            })
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
            None => self.frontend_response(conn, message, object),
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
        let params = object.get("params");
        self.outgoing.insert(
            agent_id,
            Outgoing {
                origin: Origin::Frontend {
                    conn,
                    frontend_id: id.clone(),
                },
                method: method.to_string(),
                // Remember the request's own session id and cwd: a successful
                // `session/new`/`load`/`resume` response registers the session
                // with them (PROTOCOL.md 11).
                session_id: params
                    .and_then(|params| params.get("sessionId"))
                    .and_then(Value::as_str)
                    .map(str::to_string),
                cwd: params
                    .and_then(|params| params.get("cwd"))
                    .and_then(Value::as_str)
                    .map(str::to_string),
            },
        );
        self.by_frontend.insert((conn, id_key(id)), agent_id);

        // A prompt makes the session "running" immediately, and the front end's
        // own words are recorded as a synthetic event (PROTOCOL.md 10 and 11).
        let mut events = Vec::new();
        if method == "session/prompt" {
            if let Some(session_id) = self
                .outgoing
                .get(&agent_id)
                .and_then(|outgoing| outgoing.session_id.clone())
            {
                self.touch_session(&session_id);
                if self.log_enabled {
                    self.seq += 1;
                    events.push(PendingEvent {
                        seq: self.seq,
                        session_id: Some(session_id),
                        synthetic: true,
                        message: user_prompt_event(params),
                    });
                }
            }
        }
        // A `session/load` the service can answer from the log is not forwarded
        // (PROTOCOL.md 12). Everything the relay knows is checked here; the hub
        // asks the recorder whether the log itself is complete.
        if method == "session/load" && self.log_enabled {
            let session_id = object
                .get("params")
                .and_then(|params| params.get("sessionId"))
                .and_then(Value::as_str);
            if let Some(session_id) = session_id {
                if self.session_is_complete(session_id) && self.agent_loads_sessions() {
                    if let Some(state) = self.session_state(session_id) {
                        // The request is answered locally, so it leaves the
                        // outgoing table again.
                        self.outgoing.remove(&agent_id);
                        self.by_frontend.remove(&(conn, id_key(id)));
                        return FrontendAction::LoadCandidate(LoadCandidate {
                            frontend_id: id.clone(),
                            session_id: session_id.to_string(),
                            up_to_seq: self.seq,
                            state,
                            frame: message.clone(),
                        });
                    }
                }
            }
        }
        FrontendAction::Forward(forwarded).with(Vec::new(), events)
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
        conn: ConnId,
        message: &Value,
        object: &Map<String, Value>,
    ) -> FrontendAction {
        let Some(id) = object.get("id") else {
            return FrontendAction::Drop;
        };
        let key = id_key(id);
        if !self.pending_ids.contains(&key) {
            // Already answered by another connection, withdrawn by the agent,
            // or never pending: dropped silently (PROTOCOL.md 5.1 and 14).
            return FrontendAction::Drop;
        }
        // The answerer is not told to retract; the other connections that saw
        // this request are (PROTOCOL.md 14).
        let retractions = self.retractions_except(&key, conn);
        self.remove_pending(&key);
        FrontendAction::Forward(message.clone()).with_retractions(retractions)
    }

    /// Handle one frame received from the agent (PROTOCOL.md 5.2, 5.5, 11, 13
    /// and 14).
    ///
    /// Every object the agent writes takes the next `seq` (section 3.7), even
    /// when the resulting action is not delivered.
    pub fn agent_message(&mut self, message: &Value, attached: &[ConnId]) -> AgentAction {
        self.agent_message_full(message, attached)
            .action
            .unwrap_or(AgentAction::Drop)
    }

    /// Like [`Self::agent_message`], plus everything else the frame causes:
    /// retractions and an adopted turn finishing.
    pub fn agent_message_full(&mut self, message: &Value, attached: &[ConnId]) -> AgentOutcome {
        let Some(object) = message.as_object() else {
            return AgentOutcome::with(AgentAction::Invalid);
        };
        self.seq += 1;
        let seq = self.seq;
        let outcome = match object.get("method") {
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
                                id: id.clone(),
                                seq,
                                message: message.clone(),
                                delivered: Vec::new(),
                            });
                        }
                        AgentOutcome::with(AgentAction::Request {
                            seq,
                            message: message.clone(),
                            target: attached.last().copied(),
                        })
                    }
                    None => {
                        if method == "$/cancel_request" {
                            if let Some(target) =
                                object.get("params").and_then(|params| params.get("id"))
                            {
                                // Withdrawn by the agent. The notification itself
                                // is forwarded to every attached connection, so it
                                // is the retraction: no synthetic one is generated
                                // (PROTOCOL.md 14 covers only an answer by another
                                // connection). The request leaves the pending set.
                                self.remove_pending(&id_key(target));
                            }
                        }
                        let events = self.observe_update(&method, object, seq);
                        AgentOutcome::with(AgentAction::Notification {
                            seq,
                            message: message.clone(),
                        })
                        .with_events(events)
                    }
                }
            }
            Some(_) => AgentOutcome::with(AgentAction::Invalid),
            None => return self.agent_response(message, object, attached, seq),
        };
        outcome
    }

    /// Register or update a session from an agent notification (PROTOCOL.md 11)
    /// and return the events to record (PROTOCOL.md 10): a `session/update`
    /// itself, plus the synthetic config/mode events it carries.
    fn observe_update(
        &mut self,
        method: &str,
        object: &Map<String, Value>,
        seq: u64,
    ) -> Vec<PendingEvent> {
        if method != "session/update" {
            return Vec::new();
        }
        let Some(params) = object.get("params").and_then(Value::as_object) else {
            return Vec::new();
        };
        let Some(update) = params.get("update").and_then(Value::as_object) else {
            return Vec::new();
        };
        let Some(session_id) = params.get("sessionId").and_then(Value::as_str) else {
            return Vec::new();
        };
        let session_id = session_id.to_string();

        let mut events = Vec::new();
        // The agent's own update, verbatim, except its `user_message_chunk`
        // echo: the prompt is already in the log as the synthetic
        // `user_prompt`, and recording both would replay every user message
        // twice (PROTOCOL.md 10). The echo is still forwarded live.
        let echoed_user_message =
            update.get("sessionUpdate").and_then(Value::as_str) == Some("user_message_chunk");
        if self.log_enabled && !echoed_user_message {
            events.push(PendingEvent {
                seq,
                session_id: Some(session_id.clone()),
                synthetic: false,
                message: object_message(object),
            });
        }

        let Some(session) = self.sessions.get_mut(&session_id) else {
            return events;
        };
        match update.get("sessionUpdate").and_then(Value::as_str) {
            Some("config_option_update") => {
                if let Some(config_options) = update.get("configOptions") {
                    session.set_config_options(config_options);
                    if self.log_enabled {
                        self.seq += 1;
                        events.push(PendingEvent {
                            seq: self.seq,
                            session_id: Some(session_id.clone()),
                            synthetic: true,
                            message: json!({
                                "sessionId": session_id,
                                "update": {
                                    "sessionUpdate": "config_option_update",
                                    "configOptions": config_options,
                                },
                            })
                            .to_string(),
                        });
                    }
                }
            }
            Some("current_mode_update") => {
                if let Some(mode_id) = update.get("currentModeId") {
                    session.set_current_mode(mode_id);
                    if self.log_enabled {
                        self.seq += 1;
                        events.push(PendingEvent {
                            seq: self.seq,
                            session_id: Some(session_id.clone()),
                            synthetic: true,
                            message: json!({
                                "sessionId": session_id,
                                "update": {
                                    "sessionUpdate": "current_mode_update",
                                    "currentModeId": mode_id,
                                },
                            })
                            .to_string(),
                        });
                    }
                }
            }
            _ => {}
        }
        events
    }

    fn agent_response(
        &mut self,
        message: &Value,
        object: &Map<String, Value>,
        attached: &[ConnId],
        seq: u64,
    ) -> AgentOutcome {
        let Some(agent_id) = object.get("id").and_then(Value::as_u64) else {
            return AgentOutcome::with(AgentAction::Invalid);
        };
        let Some(outgoing) = self.outgoing.remove(&agent_id) else {
            // A response with no mapping is not something a front end can use.
            return AgentOutcome::with(AgentAction::Invalid);
        };
        let origin = outgoing.origin.clone();
        let frontend = match &origin {
            Origin::Frontend { conn, frontend_id } => Some((*conn, frontend_id.clone())),
            Origin::Service => None,
        };
        if let Some((conn, frontend_id)) = &frontend {
            self.by_frontend.remove(&(*conn, id_key(frontend_id)));
        }

        // The first successful `initialize` is cached for the instance's life.
        if outgoing.method == "initialize" {
            if let Some(result) = object.get("result") {
                self.initialize = Some((seq, result.clone()));
            }
        }

        // Session bookkeeping for the methods that change the session table
        // (PROTOCOL.md 11).
        let closed_session = self.track_session_response(&outgoing, object);
        // A successful delete is also a catalog change (PROTOCOL.md 21.4);
        // `session/close` is not.
        let deleted_session = match outgoing.method.as_str() {
            "session/delete" if object.get("result").is_some() => outgoing.session_id.clone(),
            _ => None,
        };

        let mut outcome = AgentOutcome {
            closed_session,
            deleted_session,
            frontend_request: frontend
                .as_ref()
                .map(|(conn, frontend_id)| FrontendRequest {
                    conn: *conn,
                    frontend_id: frontend_id.clone(),
                    method: outgoing.method.clone(),
                    agent_id,
                    session_id: outgoing.session_id.clone(),
                }),
            ..AgentOutcome::default()
        };
        // Synthetic config/mode events for the replay log (PROTOCOL.md 10).
        // The team layer's own requests and responses are not logged (18.11).
        if self.log_enabled && frontend.is_some() {
            if let Some(session_id) = &outgoing.session_id {
                let synthetic = match outgoing.method.as_str() {
                    "session/set_config_option" => object
                        .get("result")
                        .and_then(|result| result.get("configOptions"))
                        .map(|config_options| {
                            json!({
                                "sessionId": session_id,
                                "update": {
                                    "sessionUpdate": "config_option_update",
                                    "configOptions": config_options,
                                },
                            })
                        }),
                    "session/set_mode" => object
                        .get("params")
                        .and_then(|params| params.get("modeId"))
                        .map(|mode_id| {
                            json!({
                                "sessionId": session_id,
                                "update": {
                                    "sessionUpdate": "current_mode_update",
                                    "currentModeId": mode_id,
                                },
                            })
                        }),
                    _ => None,
                };
                if let Some(synthetic) = synthetic {
                    self.seq += 1;
                    outcome.events.push(PendingEvent {
                        seq: self.seq,
                        session_id: Some(session_id.clone()),
                        synthetic: true,
                        message: synthetic.to_string(),
                    });
                }
            }
        }

        // A prompt that finished ends the turn for its adopters, whether or not
        // its requester is still there (PROTOCOL.md 13). A bus prompt is not an
        // adoption: its `_ade/turn_finished` goes to every attached/watching
        // connection (18.4 and 18.11).
        if outgoing.method == "session/prompt" {
            if let Some(session_id) = &outgoing.session_id {
                match &frontend {
                    Some((conn, _)) => {
                        outcome.prompt_finished = Some(PromptFinished {
                            conn: *conn,
                            session_id: session_id.clone(),
                        });
                        if let Some(adopters) = self.adopters.remove(session_id) {
                            outcome.finished_turn = Some(FinishedTurn {
                                session_id: session_id.clone(),
                                params: finished_params(session_id, object),
                                adopters,
                                seq,
                                adoption: true,
                            });
                        }
                    }
                    None => {
                        outcome.finished_turn = Some(FinishedTurn {
                            session_id: session_id.clone(),
                            params: finished_params(session_id, object),
                            adopters: attached.to_vec(),
                            seq,
                            adoption: false,
                        });
                    }
                }
            }
        }

        match origin {
            Origin::Frontend { conn, frontend_id } => {
                // Answers for an `agent.attach` session summary need the current
                // table.
                if !attached.contains(&conn) {
                    outcome.action = Some(AgentAction::Drop);
                    return outcome;
                }
                let mut mapped = message.clone();
                mapped["id"] = frontend_id;
                outcome.action = Some(AgentAction::Response {
                    conn,
                    seq,
                    message: mapped,
                });
            }
            Origin::Service => {
                outcome.action = Some(AgentAction::ServiceResponse {
                    agent_id,
                    seq,
                    message: message.clone(),
                });
            }
        }
        outcome
    }

    /// Register, refresh or forget a session from a successful response
    /// (PROTOCOL.md 11).
    fn track_session_response(
        &mut self,
        outgoing: &Outgoing,
        object: &Map<String, Value>,
    ) -> Option<String> {
        if !self.log_enabled {
            return None;
        }
        let Some(result) = object.get("result") else {
            // Failed requests change nothing.
            return None;
        };
        let now = (self.now)();
        match outgoing.method.as_str() {
            "session/new" => {
                let session_id = result.get("sessionId").and_then(Value::as_str)?;
                let cwd = outgoing.cwd.clone().unwrap_or_default();
                self.sessions.insert(
                    session_id.to_string(),
                    Session {
                        id: session_id.to_string(),
                        cwd,
                        state: result.clone(),
                        updated_at: now,
                        complete: true,
                    },
                );
            }
            "session/load" | "session/resume" => {
                let Some(session_id) = &outgoing.session_id else {
                    return None;
                };
                let cwd = outgoing.cwd.clone().unwrap_or_default();
                self.sessions.insert(
                    session_id.clone(),
                    Session {
                        id: session_id.clone(),
                        cwd,
                        state: result.clone(),
                        updated_at: now,
                        complete: true,
                    },
                );
            }
            "session/close" | "session/delete" => {
                if let Some(session_id) = &outgoing.session_id {
                    let session_id = session_id.clone();
                    self.sessions.remove(&session_id);
                    self.adopters.remove(&session_id);
                    return Some(session_id);
                }
            }
            "session/set_config_option" => {
                let Some(session_id) = &outgoing.session_id else {
                    return None;
                };
                let config_options = result.get("configOptions")?;
                if let Some(session) = self.sessions.get_mut(session_id) {
                    session.set_config_options(config_options);
                    session.updated_at = now;
                }
            }
            "session/set_mode" => {
                if let Some(session_id) = &outgoing.session_id {
                    self.touch_session_at(session_id, now);
                }
            }
            _ => {}
        }
        None
    }

    fn touch_session(&mut self, session_id: &str) {
        let now = (self.now)();
        self.touch_session_at(session_id, now);
    }

    fn touch_session_at(&mut self, session_id: &str, now: i64) {
        if let Some(session) = self.sessions.get_mut(session_id) {
            session.updated_at = now;
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

/// The params of `_ade/turn_finished` (PROTOCOL.md 13): the stop reason from
/// the response, or the JSON-RPC error object with `stopReason: "error"`.
/// The raw text of an agent notification, for the event log.
fn object_message(object: &Map<String, Value>) -> String {
    Value::Object(object.clone()).to_string()
}

fn finished_params(session_id: &str, object: &Map<String, Value>) -> Value {
    if let Some(error) = object.get("error") {
        return json!({ "sessionId": session_id, "stopReason": "error", "error": error });
    }
    let stop_reason = object
        .get("result")
        .and_then(|result| result.get("stopReason"))
        .cloned()
        .unwrap_or(Value::Null);
    json!({ "sessionId": session_id, "stopReason": stop_reason })
}

/// The replay form of a synthetic event (PROTOCOL.md 10): one
/// `user_message_chunk` update per prompt content block, or one update for the
/// config/mode events.
///
/// Every message carries the event's `seq`: the replay is the event, split into
/// the updates an ACP client expects.
fn replay_form(seq: u64, event: &Value) -> Vec<Value> {
    let Some(object) = event.as_object() else {
        return Vec::new();
    };
    if let Some(blocks) = object.get("blocks").and_then(Value::as_array) {
        let session_id = object.get("sessionId").cloned().unwrap_or(Value::Null);
        return blocks
            .iter()
            .map(|block| {
                json!({
                    "jsonrpc": "2.0",
                    "method": "session/update",
                    "params": {
                        "sessionId": session_id,
                        "update": {
                            "sessionUpdate": "user_message_chunk",
                            "messageId": format!("ade-user-{seq}"),
                            "content": block,
                        },
                    },
                })
            })
            .collect();
    }
    // A config/mode event stores the update object it replays as.
    match object.get("update") {
        Some(update) => vec![json!({
            "jsonrpc": "2.0",
            "method": "session/update",
            "params": {
                "sessionId": object.get("sessionId").cloned().unwrap_or(Value::Null),
                "update": update,
            },
        })],
        None => Vec::new(),
    }
}

/// The synthetic `user_prompt` event of a `session/prompt` (PROTOCOL.md 10).
///
/// The replay form is stored: one `user_message_chunk` update per prompt
/// content block. A block above 1 MiB is replaced so the event stays small.
fn user_prompt_event(params: Option<&Value>) -> String {
    let session_id = params
        .and_then(|params| params.get("sessionId"))
        .cloned()
        .unwrap_or(Value::Null);
    let blocks: Vec<Value> = params
        .and_then(|params| params.get("prompt"))
        .and_then(Value::as_array)
        .map(|blocks| blocks.iter().map(omitted_block).collect())
        .unwrap_or_default();
    json!({
        "sessionId": session_id,
        "blocks": blocks,
    })
    .to_string()
}

/// A prompt content block in its replay form: keep it, or replace a large one.
fn omitted_block(block: &Value) -> Value {
    const LIMIT: usize = 1024 * 1024;
    if block.to_string().len() > LIMIT {
        return json!({
            "type": "text",
            "text": "[content omitted from the replay log]",
        });
    }
    block.clone()
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
        let forwarded = relay
            .frontend_message(A, &request)
            .forwarded()
            .expect("forwarded")
            .clone();
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
        let forwarded = relay
            .frontend_message(A, &request(json!(1), "session/new", json!({})))
            .forwarded()
            .expect("forwarded")
            .clone();
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
        let forwarded = relay
            .frontend_message(A, &request(json!(1), "session/prompt", json!({})))
            .forwarded()
            .expect("forwarded")
            .clone();
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
        let forwarded = relay
            .frontend_message(A, &request(json!(1), "session/prompt", json!({})))
            .forwarded()
            .expect("forwarded")
            .clone();
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
        let forwarded = relay
            .frontend_message(A, &initialize)
            .forwarded()
            .expect("first initialize is forwarded")
            .clone();
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
        let forwarded = relay
            .frontend_message(
                A,
                &json!({
                    "jsonrpc": "2.0",
                    "id": 1,
                    "method": "initialize",
                    "params": {"clientCapabilities": capabilities},
                }),
            )
            .forwarded()
            .expect("forwarded")
            .clone();
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
        let forwarded = relay
            .frontend_message(A, &initialize)
            .forwarded()
            .expect("forwarded")
            .clone();
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

    // --- session tracking (PROTOCOL.md 11) -----------------------------------

    fn session_new(relay: &mut Relay, conn: ConnId, id: Value, cwd: &str) -> u64 {
        let request = json!({
            "jsonrpc": "2.0",
            "id": id,
            "method": "session/new",
            "params": {"cwd": cwd, "mcpServers": []},
        });
        let forwarded = relay
            .frontend_message(conn, &request)
            .forwarded()
            .expect("session/new is forwarded")
            .clone();
        let agent_id = forwarded["id"].as_u64().expect("agent id");
        relay.agent_message(
            &json!({
                "jsonrpc": "2.0",
                "id": agent_id,
                "result": {
                    "sessionId": "sess_1",
                    "configOptions": [{"id": "model", "currentValue": "m2"}],
                    "modes": {"currentModeId": "ask"},
                },
            }),
            &[conn],
        );
        agent_id
    }

    #[test]
    fn session_new_registers_the_session_with_its_state_and_cwd() {
        let mut relay = Relay::new(json!({}));
        session_new(&mut relay, A, json!(1), "/tmp/project");

        let summaries = relay.session_summaries();
        assert_eq!(summaries.len(), 1);
        assert_eq!(summaries[0].session_id, "sess_1");
        assert_eq!(summaries[0].cwd, "/tmp/project");
        assert!(!summaries[0].running);
        let state = relay.session_state("sess_1").expect("tracked");
        assert_eq!(state["configOptions"][0]["currentValue"], "m2");
        assert_eq!(state["modes"]["currentModeId"], "ask");
        assert!(relay.session_is_complete("sess_1"));
    }

    #[test]
    fn sessions_are_newest_first() {
        let mut relay = Relay::new(json!({}));
        relay.set_clock(|| 100);
        session_new(&mut relay, A, json!(1), "/tmp/a");
        // A second session with a later timestamp and a different id.
        relay.set_clock(|| 200);
        let request = json!({
            "jsonrpc": "2.0", "id": 2, "method": "session/load",
            "params": {"sessionId": "sess_2", "cwd": "/tmp/b"},
        });
        let forwarded = relay
            .frontend_message(A, &request)
            .forwarded()
            .expect("forwarded")
            .clone();
        let agent_id = forwarded["id"].as_u64().expect("agent id");
        relay.agent_message(
            &json!({"jsonrpc": "2.0", "id": agent_id, "result": {}}),
            &[A],
        );

        let ids: Vec<String> = relay
            .session_summaries()
            .into_iter()
            .map(|summary| summary.session_id)
            .collect();
        assert_eq!(ids, vec!["sess_2", "sess_1"]);
    }

    #[test]
    fn config_options_and_mode_updates_keep_the_state_current() {
        let mut relay = Relay::new(json!({}));
        session_new(&mut relay, A, json!(1), "/tmp/p");

        relay.agent_message(
            &json!({
                "jsonrpc": "2.0",
                "method": "session/update",
                "params": {
                    "sessionId": "sess_1",
                    "update": {
                        "sessionUpdate": "config_option_update",
                        "configOptions": [{"id": "model", "currentValue": "m3"}],
                    },
                },
            }),
            &[A],
        );
        assert_eq!(
            relay.session_state("sess_1").unwrap()["configOptions"][0]["currentValue"],
            "m3"
        );

        relay.agent_message(
            &json!({
                "jsonrpc": "2.0",
                "method": "session/update",
                "params": {
                    "sessionId": "sess_1",
                    "update": {"sessionUpdate": "current_mode_update", "currentModeId": "code"},
                },
            }),
            &[A],
        );
        assert_eq!(
            relay.session_state("sess_1").unwrap()["modes"]["currentModeId"],
            "code"
        );
        // The rest of the state is untouched.
        assert_eq!(
            relay.session_state("sess_1").unwrap()["configOptions"][0]["currentValue"],
            "m3"
        );
    }

    #[test]
    fn a_set_config_option_response_replaces_the_state() {
        let mut relay = Relay::new(json!({}));
        session_new(&mut relay, A, json!(1), "/tmp/p");

        let request = json!({
            "jsonrpc": "2.0", "id": 2, "method": "session/set_config_option",
            "params": {"sessionId": "sess_1", "configId": "model", "value": "m4"},
        });
        let forwarded = relay
            .frontend_message(A, &request)
            .forwarded()
            .expect("forwarded")
            .clone();
        let agent_id = forwarded["id"].as_u64().expect("agent id");
        relay.agent_message(
            &json!({
                "jsonrpc": "2.0",
                "id": agent_id,
                "result": {"configOptions": [{"id": "model", "currentValue": "m4"}]},
            }),
            &[A],
        );
        assert_eq!(
            relay.session_state("sess_1").unwrap()["configOptions"][0]["currentValue"],
            "m4"
        );
    }

    #[test]
    fn close_and_delete_forget_the_session() {
        for method in ["session/close", "session/delete"] {
            let mut relay = Relay::new(json!({}));
            session_new(&mut relay, A, json!(1), "/tmp/p");
            let request = json!({
                "jsonrpc": "2.0", "id": 2, "method": method,
                "params": {"sessionId": "sess_1"},
            });
            let forwarded = relay
                .frontend_message(A, &request)
                .forwarded()
                .expect("forwarded")
                .clone();
            let agent_id = forwarded["id"].as_u64().expect("agent id");
            relay.agent_message(
                &json!({"jsonrpc": "2.0", "id": agent_id, "result": {}}),
                &[A],
            );
            assert_eq!(relay.session_count(), 0, "{method} forgets the session");
        }
    }

    #[test]
    fn a_failed_session_new_is_not_tracked() {
        let mut relay = Relay::new(json!({}));
        let request = json!({
            "jsonrpc": "2.0", "id": 1, "method": "session/new",
            "params": {"cwd": "/tmp/p", "mcpServers": []},
        });
        let forwarded = relay
            .frontend_message(A, &request)
            .forwarded()
            .expect("forwarded")
            .clone();
        let agent_id = forwarded["id"].as_u64().expect("agent id");
        relay.agent_message(
            &json!({"jsonrpc": "2.0", "id": agent_id, "error": {"code": -1, "message": "no"}}),
            &[A],
        );
        assert_eq!(relay.session_count(), 0);
    }

    #[test]
    fn a_session_is_running_while_its_prompt_is_unanswered() {
        let mut relay = Relay::new(json!({}));
        session_new(&mut relay, A, json!(1), "/tmp/p");

        let request = json!({
            "jsonrpc": "2.0", "id": 2, "method": "session/prompt",
            "params": {"sessionId": "sess_1", "prompt": [{"type": "text", "text": "hi"}]},
        });
        let forwarded = relay
            .frontend_message(A, &request)
            .forwarded()
            .expect("forwarded")
            .clone();
        assert!(relay.session_summaries()[0].running);
        let agent_id = forwarded["id"].as_u64().expect("agent id");
        relay.agent_message(
            &json!({"jsonrpc": "2.0", "id": agent_id, "result": {"stopReason": "end_turn"}}),
            &[A],
        );
        assert!(!relay.session_summaries()[0].running);
    }

    #[test]
    fn sessions_are_not_tracked_with_the_log_disabled() {
        let mut relay = Relay::with_log(json!({}), false);
        session_new(&mut relay, A, json!(1), "/tmp/p");
        assert!(relay.session_summaries().is_empty());
        assert_eq!(relay.session_count(), 0);
        assert!(!relay.session_is_complete("sess_1"));
    }

    #[test]
    fn the_agents_user_message_echo_is_forwarded_but_not_recorded() {
        let mut relay = Relay::new(json!({}));
        session_new(&mut relay, A, json!(1), "/tmp/project");

        // The agent echoes the user's text back as an update.
        let echo = json!({
            "jsonrpc": "2.0",
            "method": "session/update",
            "params": {
                "sessionId": "sess_1",
                "update": {
                    "sessionUpdate": "user_message_chunk",
                    "messageId": "u1",
                    "content": {"type": "text", "text": "hello"},
                },
            },
        });
        let outcome = relay.agent_message_full(&echo, &[A]);

        // Live delivery is unchanged: every attached connection still gets it.
        match &outcome.action {
            Some(AgentAction::Notification { message, .. }) => assert_eq!(message, &echo),
            other => panic!("the echo must still be forwarded: {other:?}"),
        }
        // Nothing is recorded for it (the synthetic prompt already is).
        assert!(
            outcome.events.is_empty(),
            "the agent echo must not reach the log: {:?}",
            outcome.events
        );

        // A different update of the same shape is still recorded.
        let tool = json!({
            "jsonrpc": "2.0",
            "method": "session/update",
            "params": {
                "sessionId": "sess_1",
                "update": {"sessionUpdate": "tool_call", "toolCallId": "c1", "title": "Read"},
            },
        });
        let outcome = relay.agent_message_full(&tool, &[A]);
        assert_eq!(outcome.events.len(), 1, "other updates are recorded");
        assert!(!outcome.events[0].synthetic);
        assert!(outcome.events[0].message.contains("tool_call"));
    }

    #[test]
    fn a_prompt_records_exactly_one_user_message_event() {
        let mut relay = Relay::new(json!({}));
        session_new(&mut relay, A, json!(1), "/tmp/project");
        let request = json!({
            "jsonrpc": "2.0",
            "id": 2,
            "method": "session/prompt",
            "params": {
                "sessionId": "sess_1",
                "prompt": [{"type": "text", "text": "hello"}],
            },
        });
        let action = relay.frontend_message(A, &request);
        let events = action.events();
        assert_eq!(events.len(), 1, "one synthetic prompt event");
        assert!(events[0].synthetic);
        assert_eq!(events[0].session_id.as_deref(), Some("sess_1"));

        // Replay form: the single synthetic event becomes one user chunk.
        let stored = crate::store::Event {
            seq: events[0].seq,
            instance_key: "k".to_string(),
            session_id: Some("sess_1".to_string()),
            kind: crate::store::EventKind::Synthetic,
            message: events[0].message.clone(),
            ts_ms: 0,
        };
        let replayed = Relay::replay_messages(&[stored]);
        assert_eq!(replayed.len(), 1, "one user chunk, not two");
        assert_eq!(
            replayed[0].1["params"]["update"]["sessionUpdate"],
            "user_message_chunk"
        );
    }

    #[test]
    fn user_message_echo_is_not_recorded_when_a_prompt_is_in_flight() {
        // The whole point: prompt (synthetic) + echo (skipped) = one copy.
        let mut relay = Relay::new(json!({}));
        session_new(&mut relay, A, json!(1), "/tmp/project");
        let request = json!({
            "jsonrpc": "2.0",
            "id": 2,
            "method": "session/prompt",
            "params": {"sessionId": "sess_1", "prompt": [{"type": "text", "text": "hi"}]},
        });
        let prompt_events = relay.frontend_message(A, &request).events().to_vec();
        assert_eq!(prompt_events.len(), 1);

        let echo = json!({
            "jsonrpc": "2.0",
            "method": "session/update",
            "params": {
                "sessionId": "sess_1",
                "update": {
                    "sessionUpdate": "user_message_chunk",
                    "messageId": "u1",
                    "content": {"type": "text", "text": "hi"},
                },
            },
        });
        assert!(relay.agent_message_full(&echo, &[A]).events.is_empty());

        // Replayed user chunks: exactly one, the synthetic one.
        let stored: Vec<crate::store::Event> = prompt_events
            .iter()
            .map(|event| crate::store::Event {
                seq: event.seq,
                instance_key: "k".to_string(),
                session_id: event.session_id.clone(),
                kind: if event.synthetic {
                    crate::store::EventKind::Synthetic
                } else {
                    crate::store::EventKind::AgentNotification
                },
                message: event.message.clone(),
                ts_ms: 0,
            })
            .collect();
        let replayed = Relay::replay_messages(&stored);
        let user_chunks = replayed
            .iter()
            .filter(|(_, message)| {
                message["params"]["update"]["sessionUpdate"] == "user_message_chunk"
            })
            .count();
        assert_eq!(user_chunks, 1, "the user message is replayed once");
    }

    // --- turn adoption (PROTOCOL.md 13) --------------------------------------

    fn prompt(relay: &mut Relay, conn: ConnId, id: Value) -> u64 {
        let request = json!({
            "jsonrpc": "2.0", "id": id, "method": "session/prompt",
            "params": {"sessionId": "sess_1", "prompt": [{"type": "text", "text": "go"}]},
        });
        let forwarded = relay
            .frontend_message(conn, &request)
            .forwarded()
            .expect("forwarded")
            .clone();
        forwarded["id"].as_u64().expect("agent id")
    }

    #[test]
    fn an_orphan_turn_can_be_adopted_once() {
        let mut relay = Relay::new(json!({}));
        session_new(&mut relay, A, json!(1), "/tmp/p");
        let agent_id = prompt(&mut relay, A, json!(2));
        assert_eq!(relay.turns_running(), 1);

        // A's connection is gone; B attaches and adopts.
        assert!(relay.has_orphan_turn("sess_1", &[B]));
        let adopted = relay.adopt(B, "sess_1", &[B]).expect("adopted");
        assert_eq!(adopted.session_id, "sess_1");
        assert!(adopted.seq > 0);
        // Adopting twice is a no-op.
        assert_eq!(relay.adopt(B, "sess_1", &[B]), None);
        assert!(!relay.has_orphan_turn("sess_1", &[A, B]));

        // The response ends the turn: the adopter hears about it.
        let outcome = relay.agent_message_full(
            &json!({"jsonrpc": "2.0", "id": agent_id, "result": {"stopReason": "end_turn"}}),
            &[B],
        );
        let finished = outcome.finished_turn.expect("finished turn");
        assert_eq!(finished.session_id, "sess_1");
        assert_eq!(finished.adopters, vec![B]);
        assert_eq!(finished.params["stopReason"], "end_turn");
        assert_eq!(relay.turns_running(), 0);
    }

    #[test]
    fn nobody_can_adopt_a_turn_whose_front_end_is_still_attached() {
        let mut relay = Relay::new(json!({}));
        session_new(&mut relay, A, json!(1), "/tmp/p");
        prompt(&mut relay, A, json!(2));
        assert!(!relay.has_orphan_turn("sess_1", &[A, B]));
        assert_eq!(relay.adopt(B, "sess_1", &[A, B]), None);
    }

    #[test]
    fn an_error_response_reports_stop_reason_error() {
        let mut relay = Relay::new(json!({}));
        session_new(&mut relay, A, json!(1), "/tmp/p");
        let agent_id = prompt(&mut relay, A, json!(2));
        relay.adopt(B, "sess_1", &[B]);

        let outcome = relay.agent_message_full(
            &json!({
                "jsonrpc": "2.0",
                "id": agent_id,
                "error": {"code": -32000, "message": "boom"},
            }),
            &[B],
        );
        let finished = outcome.finished_turn.expect("finished turn");
        assert_eq!(finished.params["stopReason"], "error");
        assert_eq!(finished.params["error"]["code"], -32000);
    }

    #[test]
    fn forgetting_a_stale_turn_clears_the_counter() {
        let mut relay = Relay::new(json!({}));
        session_new(&mut relay, A, json!(1), "/tmp/p");
        prompt(&mut relay, A, json!(2));
        assert_eq!(relay.turns_running(), 1);
        relay.forget_turn("sess_1");
        assert_eq!(relay.turns_running(), 0);
    }

    // --- retraction (PROTOCOL.md 14) -----------------------------------------

    fn permission_request(relay: &mut Relay, attached: &[ConnId]) -> Value {
        let request = json!({
            "jsonrpc": "2.0",
            "id": 9001,
            "method": "session/request_permission",
            "params": {"sessionId": "sess_1"},
        });
        match relay.agent_message(&request, attached) {
            AgentAction::Request {
                seq,
                message,
                target,
            } => {
                assert_eq!(target, attached.last().copied());
                assert!(seq > 0);
                message
            }
            other => panic!("unexpected {other:?}"),
        }
    }

    #[test]
    fn answering_a_request_retracts_it_from_the_other_connections() {
        let mut relay = Relay::new(json!({}));
        let request = permission_request(&mut relay, &[A]);
        // B attaches later and receives the pending request again.
        let replay = relay.pending_messages();
        assert_eq!(replay.len(), 1);
        assert_eq!(replay[0].1["id"], 9001);
        relay.mark_delivered(&json!(9001), A);
        relay.mark_delivered(&json!(9001), B);

        let answer =
            json!({"jsonrpc": "2.0", "id": 9001, "result": {"outcome": {"outcome": "selected"}}});
        let action = relay.frontend_message(A, &answer);
        assert_eq!(action.forwarded(), Some(&answer));
        let retractions = action.retractions();
        assert_eq!(retractions.len(), 1, "only B is told, not the answerer");
        assert_eq!(retractions[0].conn, B);
        assert_eq!(retractions[0].id, json!(9001));
        assert!(retractions[0].seq > 0);
        assert_eq!(relay.pending_requests(), 0);
        // `request` is only used to make the intent explicit in this test.
        assert_eq!(request["method"], "session/request_permission");
    }

    #[test]
    fn retraction_is_not_sent_to_a_connection_that_never_saw_the_request() {
        let mut relay = Relay::new(json!({}));
        permission_request(&mut relay, &[A]);
        relay.mark_delivered(&json!(9001), A);

        let answer = json!({"jsonrpc": "2.0", "id": 9001, "result": {}});
        let action = relay.frontend_message(A, &answer);
        assert!(action.forwarded().is_some());
        assert!(
            action.retractions().is_empty(),
            "A is the answerer, B never saw it"
        );
    }

    #[test]
    fn an_agent_withdrawal_is_forwarded_as_the_only_cancel_notification() {
        let mut relay = Relay::new(json!({}));
        permission_request(&mut relay, &[A]);
        relay.mark_delivered(&json!(9001), A);
        relay.mark_delivered(&json!(9001), B);

        let cancel = json!({
            "jsonrpc": "2.0",
            "method": "$/cancel_request",
            "params": {"id": 9001},
        });
        let outcome = relay.agent_message_full(&cancel, &[A, B]);

        // The agent's own notification is forwarded once to every attached
        // connection and is itself the retraction: no synthetic second one.
        match &outcome.action {
            Some(AgentAction::Notification { seq, message }) => {
                assert_eq!(*seq, 2, "the notification keeps its agent seq");
                assert_eq!(message, &cancel);
            }
            other => panic!("unexpected {other:?}"),
        }
        assert!(
            outcome.retractions.is_empty(),
            "the forwarded notification is the retraction: {:?}",
            outcome.retractions
        );
        assert_eq!(relay.pending_requests(), 0);
    }

    /// Total `$/cancel_request` messages each connection would receive for one
    /// agent frame: the forwarded notification plus any retraction.
    fn cancel_messages_per_conn(
        outcome: &AgentOutcome,
        attached: &[ConnId],
    ) -> std::collections::BTreeMap<ConnId, usize> {
        let mut counts = std::collections::BTreeMap::new();
        if let Some(AgentAction::Notification { message, .. }) = &outcome.action {
            if message["method"] == "$/cancel_request" {
                for conn in attached {
                    *counts.entry(*conn).or_insert(0) += 1;
                }
            }
        }
        for retraction in &outcome.retractions {
            *counts.entry(retraction.conn).or_insert(0) += 1;
        }
        counts
    }

    #[test]
    fn an_agent_withdrawal_reaches_every_connection_exactly_once() {
        let mut relay = Relay::new(json!({}));
        permission_request(&mut relay, &[A]);
        relay.mark_delivered(&json!(9001), A);
        relay.mark_delivered(&json!(9001), B);

        let cancel = json!({
            "jsonrpc": "2.0",
            "method": "$/cancel_request",
            "params": {"id": 9001},
        });
        let outcome = relay.agent_message_full(&cancel, &[A, B]);
        let counts = cancel_messages_per_conn(&outcome, &[A, B]);
        assert_eq!(counts.get(&A), Some(&1), "A gets exactly one: {counts:?}");
        assert_eq!(counts.get(&B), Some(&1), "B gets exactly one: {counts:?}");
    }

    #[test]
    fn a_late_answer_after_retraction_is_dropped() {
        let mut relay = Relay::new(json!({}));
        permission_request(&mut relay, &[A]);
        relay.mark_delivered(&json!(9001), A);
        relay.mark_delivered(&json!(9001), B);
        let answer = json!({"jsonrpc": "2.0", "id": 9001, "result": {}});
        relay.frontend_message(A, &answer);

        // B replies with -32800 after being told the request is gone.
        let late = json!({
            "jsonrpc": "2.0",
            "id": 9001,
            "error": {"code": -32800, "message": "request cancelled"},
        });
        assert_eq!(relay.frontend_message(B, &late), FrontendAction::Drop);
    }

    #[test]
    fn a_forgotten_service_request_does_not_leak_and_its_late_answer_is_ignored() {
        let mut relay = Relay::new(json!({}));
        let (agent_id, _frame) = relay.service_request("session/list", json!({}));
        assert_eq!(relay.outgoing.len(), 1, "the request is tracked");

        relay.forget_service_request(agent_id);
        assert!(relay.outgoing.is_empty(), "nothing is left behind");

        // The agent answered anyway: the unmapped id is dropped safely.
        let late = json!({"jsonrpc": "2.0", "id": agent_id, "result": {"sessions": []}});
        let outcome = relay.agent_message_full(&late, &[]);
        assert_eq!(outcome.action, Some(AgentAction::Invalid));
        assert_eq!(relay.pending_requests(), 0);
    }
}
