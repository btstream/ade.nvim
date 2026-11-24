//! Teams and the agent-to-agent bus (PROTOCOL.md section 18).
//!
//! This module is the pure state machine: teams, participants, messages,
//! inbox items, limits and the token registry shared with the connection
//! layer. I/O (spawning agents, sending frames, broadcasts) is done by
//! `hub::teams`, which owns the hub and calls these methods.

pub mod activity;
pub mod board;
pub mod brief;
pub mod mcp;
pub mod workflow;
pub mod worktree;

use std::collections::{BTreeMap, HashMap, HashSet, VecDeque};
use std::sync::{Arc, Mutex};

use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use std::time::{SystemTime, UNIX_EPOCH};

use crate::relay::InstanceKey;

/// Error codes from PROTOCOL.md 18.10.
pub const INVALID_TEAM_PARAM: i64 = -32060;
pub const NOT_ALLOWED: i64 = -32061;
pub const WATCHER_REQUEST: i64 = -32062;
pub const UNKNOWN_INBOX: i64 = -32063;
pub const UNKNOWN_PARTICIPANT: i64 = -32064;
pub const PARTICIPANT_METHOD: i64 = -32065;
/// A git command for a worktree failed (18.16).
pub const GIT_FAILED: i64 = -32066;

/// Message body limit (18.1).
pub const MAX_BODY_BYTES: usize = 64 * 1024;
/// `refs`: at most 16 strings of at most 1 KiB (18.1).
pub const MAX_REFS: usize = 16;
pub const MAX_REF_BYTES: usize = 1024;
/// One delivery carries at most 128 KiB of message text (18.4).
pub const MAX_DELIVERY_BYTES: usize = 128 * 1024;
/// A role card is at most 16 KiB (18.2).
pub const MAX_ROLE_BYTES: usize = 16 * 1024;
/// `bus.read` / `team.read`: at most 100 messages (18.11).
pub const MAX_READ_MESSAGES: usize = 100;
/// The text of the last three bus turns, 64 KiB in total (18.11).
pub const MAX_TURN_TEXT: usize = 64 * 1024;
/// At most this many stored workflows per (scope, project) (19.5).
pub const MAX_STORED_WORKFLOWS: usize = 100;

#[derive(Debug, Clone)]
pub struct TeamError {
    pub code: i64,
    pub message: String,
    /// Extra `error.data` (18.16: git's stderr).
    pub data: Option<Value>,
}

impl TeamError {
    pub fn new(code: i64, message: impl Into<String>) -> Self {
        Self {
            code,
            message: message.into(),
            data: None,
        }
    }

    pub fn git(message: impl Into<String>, stderr: &str) -> Self {
        let mut error = Self::new(GIT_FAILED, message);
        if !stderr.trim().is_empty() {
            error.data = Some(json!({ "stderr": stderr }));
        }
        error
    }

    pub fn invalid(message: impl Into<String>) -> Self {
        Self::new(INVALID_TEAM_PARAM, message)
    }

    pub fn not_allowed(message: impl Into<String>) -> Self {
        Self::new(NOT_ALLOWED, message)
    }

    pub fn unknown(message: impl Into<String>) -> Self {
        Self::new(UNKNOWN_PARTICIPANT, message)
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Role {
    Leader,
    Worker,
    /// A session's own token (20.2): the chat may build or lead a team.
    Session,
}

impl Role {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Leader => "leader",
            Self::Worker => "worker",
            Self::Session => "session",
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ParticipantState {
    Idle,
    Working,
    WaitingHuman,
    Exited,
}

impl ParticipantState {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Idle => "idle",
            Self::Working => "working",
            Self::WaitingHuman => "waiting_human",
            Self::Exited => "exited",
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Kind {
    Task,
    Report,
    Question,
    Answer,
    Review,
    Notice,
    Control,
}

impl Kind {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Task => "task",
            Self::Report => "report",
            Self::Question => "question",
            Self::Answer => "answer",
            Self::Review => "review",
            Self::Notice => "notice",
            Self::Control => "control",
        }
    }

    pub fn parse(value: &Value) -> Result<Self, TeamError> {
        match value.as_str() {
            Some("task") => Ok(Self::Task),
            Some("report") => Ok(Self::Report),
            Some("question") => Ok(Self::Question),
            Some("answer") => Ok(Self::Answer),
            Some("review") => Ok(Self::Review),
            Some("notice") => Ok(Self::Notice),
            Some("control") => Ok(Self::Control),
            _ => Err(TeamError::invalid(
                "kind must be task, report, question, answer, review, notice or control",
            )),
        }
    }
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Message {
    pub id: u64,
    pub from: String,
    pub to: String,
    pub kind: Kind,
    pub task: String,
    pub body: String,
    pub refs: Vec<String>,
    pub at: u64,
}

impl Message {
    pub fn to_json(&self, team: &str) -> Value {
        let mut out = json!({
            "id": self.id,
            "team": team,
            "from": self.from,
            "to": self.to,
            "kind": self.kind.as_str(),
            "body": self.body,
            "at": self.at,
        });
        if self.task != "_" {
            out["task"] = json!(self.task);
        }
        if !self.refs.is_empty() {
            out["refs"] = json!(self.refs);
        }
        out
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ItemState {
    Open,
    Answered,
    Orphaned,
}

impl ItemState {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Open => "open",
            Self::Answered => "answered",
            Self::Orphaned => "orphaned",
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ItemKind {
    Question,
    Spawn,
    Permission,
    Request,
    Message,
    Limit,
    /// Another chat leads this cwd's team (20.4); answered `move` or `refuse`.
    Handover,
}

impl ItemKind {
    pub fn as_str(&self) -> &'static str {
        match self {
            Self::Question => "question",
            Self::Spawn => "spawn",
            Self::Permission => "permission",
            Self::Request => "request",
            Self::Message => "message",
            Self::Limit => "limit",
            Self::Handover => "handover",
        }
    }
}

/// One option of a 19.13 question.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct QuestionOption {
    pub label: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub description: Option<String>,
}

/// One 19.13 question. The 18.5 form is normalised to one of these.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Question {
    pub header: String,
    pub question: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub options: Option<Vec<QuestionOption>>,
    #[serde(default)]
    pub multi_select: bool,
}

impl Question {
    pub fn to_json(&self) -> Value {
        let mut out = json!({
            "header": self.header,
            "question": self.question,
            "multi_select": self.multi_select,
        });
        if let Some(options) = &self.options {
            out["options"] = json!(options);
        }
        out
    }
}

/// One answer to a 19.13 question (`team.answer.answers`).
#[derive(Debug, Clone, Default)]
pub struct QuestionAnswer {
    pub selected: Vec<String>,
    pub text: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct InboxItem {
    pub id: String,
    pub team: String,
    pub kind: ItemKind,
    pub from: String,
    pub body: String,
    pub at: u64,
    pub state: ItemState,
    // question
    pub options: Option<Vec<String>>,
    // spawn
    pub template: Option<String>,
    pub name: Option<String>,
    pub task: Option<String>,
    /// The spawn's model and role (19.6).
    #[serde(default)]
    pub model: Option<String>,
    #[serde(default)]
    pub role: Option<String>,
    /// The spawn's display label (19.12).
    #[serde(default)]
    pub label: Option<String>,
    /// The normalised questions of a question item (19.13).
    #[serde(default)]
    pub questions: Option<Vec<Question>>,
    /// The template's agent, for the inbox display (19.6).
    #[serde(default)]
    pub agent: Option<String>,
    /// The spawn group (19.6); items from one leader prompt share it.
    #[serde(default)]
    pub group: Option<String>,
    // permission / request
    pub instance: Option<String>,
    pub session: Option<String>,
    pub tool_call: Option<Value>,
    pub tool_options: Option<Value>,
    pub method: Option<String>,
    pub params: Option<Value>,
    // message / limit
    pub message_id: Option<u64>,
    pub participant: Option<String>,
    pub scope: Option<String>,
    pub limit_task: Option<String>,
    /// A `handover` item (20.4): the requesting session and the current leader.
    #[serde(default)]
    pub from_instance: Option<String>,
    #[serde(default)]
    pub from_session: Option<String>,
    #[serde(default)]
    pub leader_instance: Option<String>,
    #[serde(default)]
    pub leader_session: Option<String>,
    /// The agent-side request id, for permission/request items. Never exposed.
    pub agent_id: Option<Value>,
}

impl InboxItem {
    pub fn to_json(&self) -> Value {
        let mut out = json!({
            "id": self.id,
            "team": self.team,
            "kind": self.kind.as_str(),
            "from": self.from,
            "body": self.body,
            "at": self.at,
            "state": self.state.as_str(),
        });
        match self.kind {
            ItemKind::Question => {
                if let Some(options) = &self.options {
                    out["options"] = json!(options);
                }
                if let Some(questions) = &self.questions {
                    out["questions"] =
                        json!(questions.iter().map(Question::to_json).collect::<Vec<_>>());
                }
            }
            ItemKind::Spawn => {
                out["template"] = json!(self.template);
                out["name"] = json!(self.name);
                if let Some(task) = &self.task {
                    out["task"] = json!(task);
                }
                if let Some(model) = &self.model {
                    out["model"] = json!(model);
                }
                if let Some(role) = &self.role {
                    out["role"] = json!(role);
                }
                if let Some(label) = &self.label {
                    out["label"] = json!(label);
                }
                if let Some(agent) = &self.agent {
                    out["agent"] = json!(agent);
                }
                if let Some(group) = &self.group {
                    out["group"] = json!(group);
                }
            }
            ItemKind::Permission => {
                out["instance"] = json!(self.instance);
                out["sessionId"] = json!(self.session);
                out["toolCall"] = self.tool_call.clone().unwrap_or(Value::Null);
                out["options"] = self.tool_options.clone().unwrap_or_else(|| json!([]));
            }
            ItemKind::Request => {
                out["instance"] = json!(self.instance);
                out["method"] = json!(self.method);
                out["params"] = self.params.clone().unwrap_or(Value::Null);
            }
            ItemKind::Message => {
                out["message"] = json!(self.message_id);
            }
            ItemKind::Limit => {
                if let Some(participant) = &self.participant {
                    out["participant"] = json!(participant);
                }
                out["scope"] = json!(self.scope);
                if let Some(task) = &self.limit_task {
                    out["task"] = json!(task);
                }
            }
            ItemKind::Handover => {
                out["from"] = json!({
                    "instance": self.from_instance,
                    "sessionId": self.from_session,
                });
                out["leader"] = json!({
                    "instance": self.leader_instance,
                    "sessionId": self.leader_session,
                });
            }
        }
        out
    }
}

#[derive(Debug, Clone)]
pub struct Template {
    pub key: InstanceKey,
    pub env: Option<Vec<(String, String)>>,
    #[cfg(unix)]
    pub launch: Option<crate::install::Launch>,
    pub model: Option<String>,
    pub role: String,
    /// Models a spawn may ask for; empty = any model the agent offers (19.1).
    pub models: Vec<String>,
    /// How the agent reaches the team tools (19.6).
    pub tool_style: ToolStyle,
    /// Start this worker in a git worktree (18.12).
    pub worktree: bool,
}

/// `template.tool_style` (19.1/19.6).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub enum ToolStyle {
    #[default]
    Direct,
    /// The agent calls MCP tools through its own `mcp` proxy tool.
    McpProxy,
}

impl ToolStyle {
    pub fn parse(value: &str) -> Option<Self> {
        match value {
            "direct" => Some(Self::Direct),
            "mcp_proxy" => Some(Self::McpProxy),
            _ => None,
        }
    }
}

#[derive(Debug, Clone)]
pub struct TeamConfig {
    pub max_workers: u64,
    pub spawn_auto: HashSet<String>,
    pub max_turns_per_task: u64,
    pub max_turns_total: u64,
    pub templates: HashMap<String, Template>,
    /// Read-only workflows from the person's setup (19.1).
    pub workflows: HashMap<String, workflow::Workflow>,
    /// The default workflow name (a `workflows` key or `"default"`).
    pub default_workflow: Option<String>,
    /// Parent directory for worker worktrees; required when a template asks
    /// for one (18.12).
    pub worktree_root: Option<String>,
    /// Whether the service injects the team server into sessions of this cwd
    /// (20.2; default true).
    pub enabled: bool,
    /// The default per-session switch (20.5; default true).
    pub session_default: bool,
    /// `templates` was empty: one `worker` template is built from the leader
    /// instance at team creation (20.4).
    pub builtin_worker: bool,
}

impl Default for TeamConfig {
    fn default() -> Self {
        Self {
            max_workers: 3,
            spawn_auto: HashSet::new(),
            max_turns_per_task: 30,
            max_turns_total: 200,
            templates: HashMap::new(),
            workflows: HashMap::new(),
            default_workflow: None,
            worktree_root: None,
            enabled: true,
            session_default: true,
            builtin_worker: false,
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct TurnText {
    pub at: u64,
    pub text: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Participant {
    pub name: String,
    pub role: Role,
    pub template: Option<String>,
    pub role_card: Option<String>,
    pub instance: Option<String>,
    pub session: Option<String>,
    pub state: ParticipantState,
    pub reason: Option<String>,
    pub paused: bool,
    /// `paused` was set by a limit, not by a human/leader `control pause`.
    /// `team.reset_limits` clears only this kind (18.8/18.11).
    pub paused_by_limit: bool,
    pub task: String,
    pub task_sender: Option<String>,
    pub turns_total: u64,
    pub mailbox: VecDeque<Message>,
    pub first_prompt: bool,
    pub starting: bool,
    /// A bus-delivered `session/prompt` is in flight. `waiting_human` replaces
    /// the visible state while a question is open, so this flag is what stops
    /// a second delivery into the same running turn (18.4/18.5).
    pub bus_turn: bool,
    pub turn_text: String,
    pub turn_task: String,
    pub turn_sender: Option<String>,
    pub reported: bool,
    pub turns: VecDeque<TurnText>,
    /// The worktree this worker runs in (18.12); kept after the worker exits.
    pub worktree: Option<worktree::WorktreeInfo>,
    /// Latest extracted one-line activity (19.9); not persisted.
    #[serde(skip)]
    pub activity: Option<activity::Activity>,
    /// The activity-only notification gate (19.9).
    #[serde(skip)]
    pub activity_throttle: activity::ActivityThrottle,
    /// A non-fallback activity source was seen during this bus turn.
    #[serde(skip)]
    pub turn_activity: bool,
    /// When `state` last changed, in ms since the epoch (19.9).
    #[serde(skip)]
    pub state_since: u64,
    /// The model a spawn asked for (19.6); re-applied when the worker resumes.
    #[serde(default)]
    pub model: Option<String>,
    /// The role a spawn appended to the template's role card (19.6).
    #[serde(default)]
    pub spawn_role: Option<String>,
    /// The template's agent id (19.12); the leader stores its instance agent.
    #[serde(default)]
    pub agent: Option<String>,
    /// The spawn's display label (19.12).
    #[serde(default)]
    pub label: Option<String>,
    /// The prompt id of a human-interrupted turn (19.14): do not count it
    /// against the turn limits.
    #[serde(skip)]
    pub interrupting: Option<u64>,
    /// The prompt id currently running for this participant (19.14).
    #[serde(skip)]
    pub prompt_seq: Option<u64>,
    /// Identifies this start attempt across async worktree callbacks (20.6).
    #[serde(skip)]
    pub lifecycle: u64,
    /// `team.stop_worker remove: true`: drop the participant once it exited.
    #[serde(skip)]
    pub remove_after_exit: bool,
}

impl Participant {
    fn new(name: &str, role: Role) -> Self {
        Self {
            name: name.to_string(),
            role,
            template: None,
            role_card: None,
            instance: None,
            session: None,
            state: ParticipantState::Idle,
            reason: None,
            paused: false,
            paused_by_limit: false,
            task: "_".to_string(),
            task_sender: None,
            turns_total: 0,
            mailbox: VecDeque::new(),
            first_prompt: false,
            starting: false,
            bus_turn: false,
            turn_text: String::new(),
            turn_task: "_".to_string(),
            turn_sender: None,
            reported: false,
            turns: VecDeque::new(),
            worktree: None,
            activity: None,
            activity_throttle: activity::ActivityThrottle::default(),
            turn_activity: false,
            state_since: now_ms(),
            model: None,
            spawn_role: None,
            agent: None,
            label: None,
            interrupting: None,
            prompt_seq: None,
            lifecycle: 0,
            remove_after_exit: false,
        }
    }

    pub fn queued(&self) -> usize {
        self.mailbox.len()
    }
}

#[derive(Debug)]
pub struct Team {
    pub id: String,
    pub cwd: String,
    pub leaderless: bool,
    pub closed: bool,
    /// Loaded from disk after a service restart and not resumed yet (18.15).
    pub suspended: bool,
    pub suspended_at: Option<u64>,
    pub leader_instance: Option<String>,
    pub leader_session: Option<String>,
    pub participants: HashMap<String, Participant>,
    /// Leader first, then workers in creation order.
    pub order: Vec<String>,
    pub reserved_names: HashSet<String>,
    pub config: TeamConfig,
    pub inbox: Vec<InboxItem>,
    pub messages: Vec<Message>,
    pub next_message: u64,
    pub task_turns: HashMap<(String, String), u64>,
    pub total_turns: u64,
    pub total_limit_hit: bool,
    pub task_limit_hit: HashSet<(String, String)>,
    pub watchers: HashMap<String, Vec<u64>>,
    /// (instance, serialized agent request id) -> inbox item id.
    pub pending_items: HashMap<(String, String), String>,
    /// Creation time in ms; worktree names embed its UTC stamp (18.12).
    pub created_at: u64,
    /// The team's board (19.2).
    pub board: board::Board,
    /// When the pending worker board write is persisted and announced (19.2).
    pub board_flush_at: Option<u64>,
    /// The spawn group of a prompt the leader is running (19.6).
    pub current_group: Option<String>,
    /// Pending (not yet started) spawn names -> lifecycle id (20.6).
    pub pending_lifecycles: HashMap<String, u64>,
}

impl Team {
    fn next_message(&mut self) -> u64 {
        self.next_message += 1;
        self.next_message
    }

    pub fn participant(&self, name: &str) -> Option<&Participant> {
        self.participants.get(name)
    }

    pub fn participant_mut(&mut self, name: &str) -> Option<&mut Participant> {
        self.participants.get_mut(name)
    }

    pub fn workers(&self) -> impl Iterator<Item = &Participant> {
        self.order
            .iter()
            .filter_map(|name| self.participants.get(name))
            .filter(|participant| participant.role == Role::Worker)
    }

    pub fn live_workers(&self) -> usize {
        self.workers()
            .filter(|participant| participant.state != ParticipantState::Exited)
            .count()
    }

    pub fn is_worker_instance(&self, instance: &str) -> Option<&str> {
        self.workers()
            .find(|participant| participant.instance.as_deref() == Some(instance))
            .map(|participant| participant.name.as_str())
    }

    pub fn is_leader_instance(&self, instance: &str) -> bool {
        self.leader_instance.as_deref() == Some(instance)
    }
}

#[derive(Debug, Clone, PartialEq)]
pub enum TeamEvent {
    Changed(String),
    /// A board write from the state layer (19.12); the hub persists and
    /// announces it like a `bus.board_update`.
    Board(String, u64),
    Inbox(String, String),
    /// An item whose team is already gone (the last `team.inbox` before the
    /// closing `team.changed`).
    InboxJson(Value),
    Closed(Value),
}

#[derive(Debug, Clone)]
pub struct ParticipantAuth {
    pub token_id: String,
    pub role: Role,
    pub team: Option<String>,
    pub name: Option<String>,
}

pub type TokenHash = [u8; 32];
pub type SharedTokens = Arc<Mutex<HashMap<TokenHash, ParticipantAuth>>>;

pub fn new_shared_tokens() -> SharedTokens {
    Arc::new(Mutex::new(HashMap::new()))
}

/// A token is kept only as a SHA-256 hash. The service never needs to look at
/// it again after writing it into the agent's environment.
pub fn hash_token(token: &str) -> TokenHash {
    use sha2::{Digest, Sha256};
    let mut hasher = Sha256::new();
    hasher.update(token.as_bytes());
    hasher.finalize().into()
}

fn hashes_match(left: &TokenHash, right: &TokenHash) -> bool {
    let mut differing = 0u8;
    for (left, right) in left.iter().zip(right) {
        differing |= left ^ right;
    }
    differing == 0
}

pub fn authenticate(tokens: &SharedTokens, token: &str) -> Option<ParticipantAuth> {
    let candidate = hash_token(token);
    let map = tokens.lock().ok()?;
    // Hash-map lookup would compare keys with an early exit; iterate and
    // compare in constant time instead. The table is tiny (tokens per team).
    map.iter()
        .find(|(hash, _)| hashes_match(hash, &candidate))
        .map(|(_, auth)| auth.clone())
}

#[derive(Debug)]
struct TokenRecord {
    hash: TokenHash,
    role: Role,
    team: Option<String>,
    name: Option<String>,
    instance: Option<String>,
    cwd: Option<String>,
    /// The ACP session a session token is bound to (20.2).
    session: Option<String>,
    /// The agent the instance ran when the token was issued (leaders only).
    agent: Option<String>,
    bound: bool,
    /// The token was presented in a successful `hello`: its MCP process has
    /// connected at least once (20.5).
    handshaked: bool,
}

#[derive(Debug)]
pub struct DeliveryRequest {
    pub team: String,
    pub participant: String,
    pub instance: String,
    pub session: String,
    pub blocks: Vec<Value>,
    /// Consumed messages, so a failed send can put them back at the front.
    pub messages: Vec<Message>,
    pub first_prompt: bool,
}

#[derive(Debug)]
pub struct TurnEffects {
    /// Participants that may now receive another delivery.
    pub delivery_team: Option<String>,
}

#[derive(Debug, Clone)]
pub struct SpawnPlan {
    pub template: Template,
    pub cwd: String,
    pub stamp: String,
    pub worktree_root: Option<String>,
}

/// The leader launch a built-in `worker` template is copied from (20.4).
#[derive(Debug, Clone)]
pub struct LeaderLaunch {
    pub cwd: String,
    pub key: InstanceKey,
    pub env: Option<Vec<(String, String)>>,
    #[cfg(unix)]
    pub launch: Option<crate::install::Launch>,
}

#[derive(Debug, Clone)]
pub struct SpawnRequest {
    pub team: String,
    pub name: String,
    pub template: String,
    /// The spawn's model (19.6); falls back to the template's `model`.
    pub model: Option<String>,
    /// The spawn's role, appended to the template's role card (19.6).
    pub role: Option<String>,
    pub task: Option<String>,
    /// The participant lifecycle this request starts (20.6).
    pub lifecycle: u64,
}

#[derive(Debug)]
pub struct StopOutcome {
    /// The live instance to stop, if any.
    pub instance: Option<String>,
    /// Lifecycle of the start attempt that must not go on.
    pub lifecycle: u64,
    pub remove: bool,
    /// A start of that lifecycle was in flight.
    pub start_pending: bool,
}

#[derive(Debug)]
pub enum SpawnOutcome {
    Started(SpawnRequest),
    Awaiting { request: String, name: String },
}

#[derive(Debug)]
pub enum AnswerEffect {
    Question,
    Spawn(SpawnRequest),
    /// A `handover` item (20.4); `move` runs `team.set_leader`.
    Handover {
        team: String,
        instance: String,
        session: String,
        hand_over: bool,
    },
    Permission {
        instance: String,
        agent_id: Value,
        response: Value,
    },
    Request {
        instance: String,
        agent_id: Value,
        result: Value,
    },
    Ack,
}

/// The items a group answer answered, with their effects (19.6).
pub type GroupAnswers = Vec<(String, AnswerEffect)>;
/// The items a group answer failed to answer, with their errors (19.6).
pub type GroupFailures = Vec<(String, TeamError)>;

pub struct Teams {
    pub tokens: SharedTokens,
    token_records: HashMap<String, TokenRecord>,
    configs: HashMap<String, TeamConfig>,
    teams: HashMap<String, Team>,
    by_cwd: HashMap<String, String>,
    /// instance -> (team id, participant name); O(1) membership for every agent
    /// frame instead of scanning all teams.
    by_instance: HashMap<String, (String, String)>,
    next_team: u64,
    next_token: u64,
    next_inbox: u64,
    closed_teams: HashSet<String>,
    events: Vec<TeamEvent>,
    /// The next spawn group number (19.6).
    next_group: u64,
    /// The spawn group of each leader session's currently running front-end
    /// prompt, keyed by `(instance, session)`. It exists before a team does, so
    /// a team created mid-turn inherits the turn's group (19.6).
    session_groups: HashMap<(String, String), String>,
    /// The next participant lifecycle id (20.6).
    next_lifecycle: u64,
    /// Stored (project and user) workflows (19.5).
    workflows: workflow::StoredWorkflows,
    /// cwd -> project key, so git runs at most once per cwd.
    project_keys: HashMap<String, String>,
    /// Explicit per-session switch state (20.5), keyed by (agent, sessionId).
    /// Absent means the cwd configuration's `session_default`.
    session_switches: HashMap<(String, String), bool>,
    /// Sessions whose handover was refused (20.4).
    handover_refusals: HashSet<(String, String)>,
    /// Tests inspect the board of a closed team after it is removed.
    #[cfg(test)]
    closed_boards: HashMap<String, board::Board>,
    #[cfg(test)]
    closed_reserved: HashMap<String, HashSet<String>>,
}

impl Teams {
    pub fn new(tokens: SharedTokens) -> Self {
        Self {
            tokens,
            token_records: HashMap::new(),
            configs: HashMap::new(),
            teams: HashMap::new(),
            by_cwd: HashMap::new(),
            by_instance: HashMap::new(),
            next_team: 0,
            next_token: 0,
            next_inbox: 0,
            closed_teams: HashSet::new(),
            events: Vec::new(),
            next_group: 0,
            session_groups: HashMap::new(),
            next_lifecycle: 0,
            workflows: workflow::StoredWorkflows::new(),
            project_keys: HashMap::new(),
            session_switches: HashMap::new(),
            handover_refusals: HashSet::new(),
            #[cfg(test)]
            closed_boards: HashMap::new(),
            #[cfg(test)]
            closed_reserved: HashMap::new(),
        }
    }

    pub fn is_empty(&self) -> bool {
        self.teams.is_empty()
    }

    /// The board a closed team had after its spawn cleanup (tests only).
    #[cfg(test)]
    pub fn closed_board(&self, team: &str) -> Option<&board::Board> {
        self.closed_boards.get(team)
    }

    #[cfg(test)]
    pub fn closed_reserved_names(&self, team: &str) -> Option<&HashSet<String>> {
        self.closed_reserved.get(team)
    }

    pub fn is_closed(&self, team: &str) -> bool {
        self.closed_teams.contains(team)
    }

    pub fn team_count(&self) -> usize {
        self.teams.len()
    }

    pub fn team(&self, id: &str) -> Option<&Team> {
        self.teams.get(id)
    }

    pub fn team_mut(&mut self, id: &str) -> Option<&mut Team> {
        self.teams.get_mut(id)
    }

    pub fn team_for_cwd(&self, cwd: &str) -> Option<&Team> {
        self.by_cwd.get(cwd).and_then(|id| self.teams.get(id))
    }

    pub fn membership(&self, instance: &str) -> Option<(String, String)> {
        self.by_instance.get(instance).cloned()
    }

    pub fn team_of_instance(&self, instance: &str) -> Option<&Team> {
        let (team, _) = self.by_instance.get(instance)?;
        self.teams.get(team)
    }

    pub fn drain_events(&mut self) -> Vec<TeamEvent> {
        std::mem::take(&mut self.events)
    }

    pub fn entry(&self, id: &str) -> Option<Value> {
        self.teams.get(id).map(team_entry)
    }

    pub fn item_by_id(&self, item: &str) -> Option<InboxItem> {
        self.teams
            .values()
            .flat_map(|team| team.inbox.iter())
            .find(|entry| entry.id == item)
            .cloned()
    }

    pub fn participant_session(&self, team_id: &str, name: &str) -> Option<String> {
        self.teams
            .get(team_id)?
            .participants
            .get(name)?
            .session
            .clone()
    }

    pub fn item(&self, team: &str, item: &str) -> Option<InboxItem> {
        self.teams
            .get(team)
            .and_then(|team| team.inbox.iter().find(|entry| entry.id == item))
            .cloned()
    }

    // -- configuration -----------------------------------------------------

    pub fn configure(&mut self, cwd: &str, config: Value) -> Result<(), TeamError> {
        let config = parse_config(&config)?;
        self.configs.insert(cwd.to_string(), config);
        Ok(())
    }

    pub fn config_for(&self, cwd: &str) -> TeamConfig {
        self.configs.get(cwd).cloned().unwrap_or_default()
    }

    // -- workflows (PROTOCOL.md 19.5) --------------------------------------

    /// The configuration in force for a cwd: the running team's, else the last
    /// stored one (19.5).
    fn config_for_cwd(&self, cwd: &str) -> TeamConfig {
        match self.team_for_cwd(cwd) {
            Some(team) => team.config.clone(),
            None => self.config_for(cwd),
        }
    }

    /// The cached project key of a cwd (19.1).
    pub fn project_key(&self, cwd: &str) -> Option<&str> {
        self.project_keys.get(cwd).map(String::as_str)
    }

    pub fn set_project_key(&mut self, cwd: &str, project: &str) {
        self.project_keys
            .insert(cwd.to_string(), project.to_string());
    }

    /// Replace the stored workflows, as loaded at startup.
    pub fn restore_workflows(&mut self, rows: Vec<(String, String, String, String)>) {
        self.workflows = workflow::StoredWorkflows::new();
        self.workflows.load(rows);
    }

    /// `team.workflows {cwd}` (19.5): every visible name once, resolved.
    pub fn workflows_for_cwd(&self, cwd: &str, project: &str) -> Value {
        let config = self.config_for_cwd(cwd);
        let workflows: Vec<Value> = workflow::list(&config, &self.workflows, project)
            .iter()
            .map(workflow::Workflow::to_json)
            .collect();
        json!({ "workflows": workflows })
    }

    /// `bus.status`'s short workflow list for a leader (19.3).
    pub fn workflow_short_list(&self, team_id: &str, project: &str) -> Vec<Value> {
        match self.teams.get(team_id) {
            Some(team) => workflow::short_list(&team.config, &self.workflows, project),
            None => Vec::new(),
        }
    }

    /// Resolve a workflow for a team (19.1).
    pub fn resolve_workflow(
        &self,
        team_id: &str,
        project: &str,
        name: &str,
    ) -> Result<workflow::Workflow, TeamError> {
        let team = self
            .teams
            .get(team_id)
            .ok_or_else(|| TeamError::unknown("unknown team"))?;
        workflow::resolve(&team.config, &self.workflows, project, name)
            .ok_or_else(|| TeamError::invalid(format!("unknown workflow {name}")))
    }

    /// `bus.workflow_save` (19.5). Returns the stored workflow.
    pub fn workflow_save(
        &mut self,
        team_id: &str,
        project: &str,
        value: &Value,
        scope: workflow::Scope,
        replace: bool,
    ) -> Result<workflow::Workflow, TeamError> {
        let team = self
            .teams
            .get(team_id)
            .ok_or_else(|| TeamError::unknown("unknown team"))?;
        if team.closed {
            return Err(TeamError::unknown("team closed"));
        }
        let stored = workflow::parse_workflow(value, scope, Some(&team.config))?;
        if team.config.workflows.contains_key(&stored.name) {
            return Err(TeamError::not_allowed("workflow exists"));
        }
        if self.workflows.get(scope, project, &stored.name).is_some() && !replace {
            return Err(TeamError::not_allowed("workflow exists"));
        }
        if self.workflows.count(scope, project) >= MAX_STORED_WORKFLOWS
            && self.workflows.get(scope, project, &stored.name).is_none()
        {
            return Err(TeamError::not_allowed("too many workflows"));
        }
        self.workflows.insert(project, stored.clone());
        Ok(stored)
    }

    /// `bus.workflow_save` from a session token (20.3): the cwd's
    /// configuration is the reference, a running team or the stored one.
    pub fn workflow_save_for_cwd(
        &mut self,
        cwd: &str,
        project: &str,
        value: &Value,
        scope: workflow::Scope,
        replace: bool,
    ) -> Result<workflow::Workflow, TeamError> {
        let config = self.config_for_cwd(cwd);
        let stored = workflow::parse_workflow(value, scope, Some(&config))?;
        if config.workflows.contains_key(&stored.name) {
            return Err(TeamError::not_allowed("workflow exists"));
        }
        if self.workflows.get(scope, project, &stored.name).is_some() && !replace {
            return Err(TeamError::not_allowed("workflow exists"));
        }
        if self.workflows.count(scope, project) >= MAX_STORED_WORKFLOWS
            && self.workflows.get(scope, project, &stored.name).is_none()
        {
            return Err(TeamError::not_allowed("too many workflows"));
        }
        self.workflows.insert(project, stored.clone());
        Ok(stored)
    }

    pub fn workflow_get_for_cwd(
        &self,
        cwd: &str,
        project: &str,
        name: &str,
    ) -> Result<Value, TeamError> {
        let config = self.config_for_cwd(cwd);
        let resolved = workflow::resolve(&config, &self.workflows, project, name)
            .ok_or_else(|| TeamError::invalid(format!("unknown workflow {name}")))?;
        Ok(json!({ "workflow": resolved.to_json() }))
    }

    pub fn workflow_delete_for_cwd_scope(
        &mut self,
        cwd: &str,
        project: &str,
        name: &str,
        scope: Option<workflow::Scope>,
    ) -> Result<workflow::Workflow, TeamError> {
        let config = self.config_for_cwd(cwd);
        match scope {
            Some(scope) => self
                .workflows
                .remove(scope, project, name)
                .ok_or_else(|| TeamError::not_allowed("no such workflow")),
            None => {
                if config.workflows.contains_key(name) {
                    return Err(TeamError::not_allowed("workflow is configured"));
                }
                for scope in [workflow::Scope::Project, workflow::Scope::User] {
                    if let Some(removed) = self.workflows.remove(scope, project, name) {
                        return Ok(removed);
                    }
                }
                Err(TeamError::not_allowed("no such workflow"))
            }
        }
    }

    /// `bus.workflow_get` (19.5).
    pub fn workflow_get(
        &self,
        team_id: &str,
        project: &str,
        name: &str,
    ) -> Result<Value, TeamError> {
        let resolved = self.resolve_workflow(team_id, project, name)?;
        Ok(json!({ "workflow": resolved.to_json() }))
    }

    /// `bus.workflow_delete` (19.5): without a scope the stored workflow the
    /// name resolves to; a config or builtin one, or no stored one, is
    /// `-32061`. Returns the removed record for the database.
    pub fn workflow_delete(
        &mut self,
        team_id: &str,
        project: &str,
        name: &str,
        scope: Option<workflow::Scope>,
    ) -> Result<workflow::Workflow, TeamError> {
        let team = self
            .teams
            .get(team_id)
            .ok_or_else(|| TeamError::unknown("unknown team"))?;
        match scope {
            Some(scope) => self
                .workflows
                .remove(scope, project, name)
                .ok_or_else(|| TeamError::not_allowed("no such workflow")),
            None => {
                if team.config.workflows.contains_key(name) {
                    return Err(TeamError::not_allowed("workflow is configured"));
                }
                for scope in [workflow::Scope::Project, workflow::Scope::User] {
                    if let Some(removed) = self.workflows.remove(scope, project, name) {
                        return Ok(removed);
                    }
                }
                Err(TeamError::not_allowed("no such workflow"))
            }
        }
    }

    /// `team.workflow_delete {cwd, name, scope}` (19.5).
    pub fn workflow_delete_for_cwd(
        &mut self,
        project: &str,
        name: &str,
        scope: workflow::Scope,
    ) -> Result<workflow::Workflow, TeamError> {
        self.workflows
            .remove(scope, project, name)
            .ok_or_else(|| TeamError::not_allowed("no such workflow"))
    }

    // -- spawn groups (PROTOCOL.md 19.6) -----------------------------------

    fn new_group(&mut self) -> String {
        self.next_group += 1;
        format!("g{}", self.next_group)
    }

    /// Start a group for a leader prompt that has no group yet.
    pub fn begin_leader_group(&mut self, team_id: &str) {
        let needs_group = self
            .teams
            .get(team_id)
            .is_some_and(|team| team.current_group.is_none());
        if !needs_group {
            return;
        }
        let group = self.new_group();
        if let Some(team) = self.teams.get_mut(team_id) {
            team.current_group = Some(group);
        }
    }

    /// Close the leader's current prompt group; later items get their own.
    pub fn finish_leader_group(&mut self, team_id: &str) {
        if let Some(team) = self.teams.get_mut(team_id) {
            team.current_group = None;
        }
    }

    /// The group a new spawn item belongs to (19.6): the leader session's
    /// current turn group — which exists even before the team does — else the
    /// team's group (a bus prompt), else a fresh one.
    fn next_spawn_group(&mut self, team_id: &str) -> Option<String> {
        let team = self.teams.get(team_id)?;
        let leader = match (team.leader_instance.clone(), team.leader_session.clone()) {
            (Some(instance), Some(session)) => Some((instance, session)),
            _ => None,
        };
        if let Some((instance, session)) = leader {
            // A turn is open for the leader session (even if it spawned
            // nothing yet): its group is allocated now and shared by the rest
            // of the turn (19.6).
            let key = (instance.clone(), session.clone());
            if self.session_groups.contains_key(&key) {
                if let Some(group) = self
                    .session_groups
                    .get(&key)
                    .filter(|group| !group.is_empty())
                    .cloned()
                {
                    return Some(group);
                }
                // A team that already existed when the turn started has its
                // group (19.6); the turn adopts it.
                let existing = self
                    .teams
                    .get(team_id)
                    .and_then(|team| team.current_group.clone());
                let group = match existing {
                    Some(group) => group,
                    None => self.new_group(),
                };
                self.session_groups.insert(key, group.clone());
                if let Some(team) = self.teams.get_mut(team_id) {
                    if team.current_group.is_none() {
                        team.current_group = Some(group.clone());
                    }
                }
                return Some(group);
            }
        }
        let current = self.teams.get(team_id)?.current_group.clone();
        match current {
            Some(group) => Some(group),
            None => Some(self.new_group()),
        }
    }

    // -- tokens ------------------------------------------------------------

    fn create_token(
        &mut self,
        role: Role,
        instance: Option<String>,
        cwd: Option<String>,
        agent: Option<String>,
    ) -> (String, String) {
        self.next_token += 1;
        let token_id = format!("k{}", self.next_token);
        let token = crate::token::generate();
        let hash = hash_token(&token);
        if let Ok(mut map) = self.tokens.lock() {
            map.insert(
                hash,
                ParticipantAuth {
                    token_id: token_id.clone(),
                    role,
                    team: None,
                    name: None,
                },
            );
        }
        self.token_records.insert(
            token_id.clone(),
            TokenRecord {
                hash,
                role,
                team: None,
                name: None,
                instance,
                cwd,
                session: None,
                agent,
                bound: false,
                handshaked: false,
            },
        );
        (token_id, token)
    }

    fn token_entry(&mut self, token_id: &str) {
        let Some(record) = self.token_records.get(token_id) else {
            return;
        };
        if let Ok(mut map) = self.tokens.lock() {
            if let Some(auth) = map.get_mut(&record.hash) {
                auth.team = record.team.clone();
                auth.name = record.name.clone();
            }
        }
    }

    pub fn revoke(&mut self, token_id: &str) {
        if let Some(record) = self.token_records.remove(token_id) {
            if let Ok(mut map) = self.tokens.lock() {
                map.remove(&record.hash);
            }
        }
    }

    /// Stop new participant handshakes for a closed team but keep the token
    /// records so an already-connected participant gets "team closed" (18.11).
    fn revoke_team_hashes(&mut self, team: &str) {
        if let Ok(mut map) = self.tokens.lock() {
            for record in self
                .token_records
                .values()
                .filter(|record| record.role != Role::Session)
                .filter(|record| record.team.as_deref() == Some(team))
            {
                map.remove(&record.hash);
            }
        }
    }

    fn revoke_instance_unbound(&mut self, instance: &str) {
        let ids: Vec<String> = self
            .token_records
            .iter()
            .filter(|(_, record)| record.instance.as_deref() == Some(instance) && !record.bound)
            .map(|(id, _)| id.clone())
            .collect();
        for id in ids {
            self.revoke(&id);
        }
    }

    fn role_for_token(&self, token_id: &str) -> Option<(Role, Option<String>, Option<String>)> {
        let record = self.token_records.get(token_id)?;
        Some((record.role, record.team.clone(), record.name.clone()))
    }

    // -- session switches and tokens (PROTOCOL.md 20.2/20.5) ---------------

    /// The stored explicit switch, if any.
    pub fn switch(&self, agent: &str, session: &str) -> Option<bool> {
        self.session_switches
            .get(&(agent.to_string(), session.to_string()))
            .copied()
    }

    /// Whether the session's switch is on: its stored value, else the cwd
    /// configuration's `session_default` (true without a configuration).
    pub fn enabled_for(&self, agent: &str, session: &str, cwd: &str) -> bool {
        let config = self.config_for(cwd);
        if self.configs.contains_key(cwd) && !config.enabled {
            return false;
        }
        self.switch(agent, session)
            .unwrap_or(config.session_default)
    }

    /// Store a switch; returns whether it changed.
    pub fn set_switch(&mut self, agent: &str, session: &str, enabled: bool) -> bool {
        let key = (agent.to_string(), session.to_string());
        if self.session_switches.get(&key) == Some(&enabled) {
            return false;
        }
        self.session_switches.insert(key, enabled);
        true
    }

    pub fn restore_switches(&mut self, rows: Vec<(String, String, bool)>) {
        for (agent, session, enabled) in rows {
            self.session_switches.insert((agent, session), enabled);
        }
    }

    /// Issue a session token. `session` is set for load/resume (bound at
    /// once); a `session/new` token is bound by its response.
    pub fn issue_session_token(
        &mut self,
        instance: &str,
        cwd: &str,
        agent: &str,
        session: Option<&str>,
    ) -> (String, String) {
        let (token_id, token) = self.create_token(
            Role::Session,
            Some(instance.to_string()),
            Some(cwd.to_string()),
            Some(agent.to_string()),
        );
        if let Some(record) = self.token_records.get_mut(&token_id) {
            record.session = session.map(str::to_string);
            record.bound = session.is_some();
        }
        if let Some(session) = session {
            self.bind_session_record(instance, session, &token_id);
        }
        (token_id, token)
    }

    fn bind_session_record(&mut self, instance: &str, session: &str, token_id: &str) {
        let Some(record) = self.token_records.get_mut(token_id) else {
            return;
        };
        if record.role != Role::Session || record.instance.as_deref() != Some(instance) {
            return;
        }
        record.session = Some(session.to_string());
        record.bound = true;
        self.token_entry(token_id);
    }

    /// Bind a `session/new` token to the successful response's session id and
    /// resume a stored team led by it (20.2/20.7). `Err` when the token does
    /// not belong to `(instance, session)`.
    pub fn bind_session_token(
        &mut self,
        instance: &str,
        session: &str,
        token_id: &str,
        agent: &str,
    ) -> Result<(), TeamError> {
        let Some(record) = self.token_records.get(token_id) else {
            return Err(TeamError::not_allowed("unknown session token"));
        };
        if record.role != Role::Session
            || record.instance.as_deref() != Some(instance)
            || record.agent.as_deref() != Some(agent)
            || record
                .session
                .as_deref()
                .is_some_and(|known| known != session)
        {
            return Err(TeamError::not_allowed(
                "session token does not belong to this session",
            ));
        }
        self.bind_session_record(instance, session, token_id);
        Ok(())
    }

    /// Revoke every session token bound to `(instance, session)`.
    pub fn revoke_session_tokens(&mut self, instance: &str, session: &str) {
        let ids: Vec<String> = self
            .token_records
            .iter()
            .filter(|(_, record)| {
                record.role == Role::Session
                    && record.instance.as_deref() == Some(instance)
                    && record.session.as_deref() == Some(session)
            })
            .map(|(id, _)| id.clone())
            .collect();
        for id in ids {
            self.revoke(&id);
        }
    }

    /// The session a session token belongs to, with its instance and agent.
    pub fn session_auth(&self, token_id: &str) -> Option<(&str, &str, &str)> {
        let record = self.token_records.get(token_id)?;
        if record.role != Role::Session || !record.bound {
            return None;
        }
        Some((
            record.instance.as_deref()?,
            record.session.as_deref()?,
            record.agent.as_deref()?,
        ))
    }

    pub fn session_cwd(&self, token_id: &str) -> Option<String> {
        self.token_records.get(token_id)?.cwd.clone()
    }

    /// Every session a team participant knows: (instance, session).
    pub fn participant_sessions(&self) -> Vec<(String, String)> {
        let mut out = Vec::new();
        for team in self.teams.values() {
            for participant in team.participants.values() {
                if let (Some(instance), Some(session)) =
                    (participant.instance.clone(), participant.session.clone())
                {
                    out.push((instance, session));
                }
            }
        }
        out
    }

    /// Every session identity with a bound session token.
    pub fn token_sessions(&self) -> Vec<(String, String)> {
        self.token_records
            .values()
            .filter(|record| record.role == Role::Session && record.bound)
            .filter_map(|record| Some((record.instance.clone()?, record.session.clone()?)))
            .collect()
    }

    /// The sessions of one instance that hold a bound session token.
    pub fn sessions_of_instance(&self, instance: &str) -> Vec<String> {
        self.token_records
            .values()
            .filter(|record| {
                record.role == Role::Session
                    && record.bound
                    && record.instance.as_deref() == Some(instance)
            })
            .filter_map(|record| record.session.clone())
            .collect()
    }

    /// The session a token id is currently bound to, if any.
    pub fn session_identity(&self, token_id: &str) -> Option<(String, String)> {
        let record = self.token_records.get(token_id)?;
        if record.role != Role::Session || !record.bound {
            return None;
        }
        Some((record.instance.clone()?, record.session.clone()?))
    }

    /// The bound session token id of `(instance, session)`, if one exists.
    pub fn session_token_of(&self, instance: &str, session: &str) -> Option<String> {
        self.token_records
            .iter()
            .find(|(_, record)| {
                record.role == Role::Session
                    && record.bound
                    && record.instance.as_deref() == Some(instance)
                    && record.session.as_deref() == Some(session)
            })
            .map(|(id, _)| id.clone())
    }

    /// A bound session token of `(instance, session)` when no token of that
    /// session's MCP process has ever connected: enabling teams for it is worth
    /// waiting for (20.5). Tokens that already handshook once prove the agent
    /// wires the injected server; their later disconnects are real.
    pub fn unconnected_session_token(&self, instance: &str, session: &str) -> Option<String> {
        let mut candidate = None;
        let mut any_handshaked = false;
        for (id, record) in &self.token_records {
            if record.role != Role::Session
                || !record.bound
                || record.instance.as_deref() != Some(instance)
                || record.session.as_deref() != Some(session)
            {
                continue;
            }
            if record.handshaked {
                any_handshaked = true;
                break;
            }
            candidate = Some(id.clone());
        }
        if any_handshaked {
            None
        } else {
            candidate
        }
    }

    /// Record that a token's MCP process connected at least once. Returns
    /// whether this was the first handshake.
    pub fn note_handshake(&mut self, token_id: &str) -> bool {
        match self.token_records.get_mut(token_id) {
            Some(record) if !record.handshaked => {
                record.handshaked = true;
                true
            }
            _ => false,
        }
    }

    /// The team entry the session leads, if any (`session.teams.leader`).
    pub fn session_team_entry(&self, instance: &str, session: &str) -> Value {
        let Some((team, _)) = self.by_instance.get(instance) else {
            return Value::Null;
        };
        let Some(entry) = self.teams.get(team) else {
            return Value::Null;
        };
        if entry.leader_session.as_deref() == Some(session)
            && entry.leader_instance.as_deref() == Some(instance)
            && !entry.closed
        {
            team_entry(entry)
        } else {
            Value::Null
        }
    }

    /// The session's team role and team (20.2): `leader` only while it really
    /// leads its cwd's team.
    pub fn session_role(&self, token_id: &str) -> (Option<String>, Option<String>) {
        let Some((instance, session, _)) = self.session_auth(token_id) else {
            return (None, None);
        };
        let Some((team, _)) = self.by_instance.get(instance) else {
            return (None, None);
        };
        let Some(entry) = self.teams.get(team) else {
            return (None, None);
        };
        if entry.leader_session.as_deref() == Some(session)
            && entry.leader_instance.as_deref() == Some(instance)
            && !entry.closed
        {
            (Some("leader".to_string()), Some(team.clone()))
        } else {
            (None, Some(team.clone()))
        }
    }

    /// Refresh the shared auth entry of every token of a session (the hello
    /// result reads it).
    pub fn refresh_session_auth(&mut self, instance: &str, session: &str) {
        let ids: Vec<String> = self
            .token_records
            .iter()
            .filter(|(_, record)| {
                record.role == Role::Session
                    && record.instance.as_deref() == Some(instance)
                    && record.session.as_deref() == Some(session)
            })
            .map(|(id, _)| id.clone())
            .collect();
        for id in ids {
            let (name, team) = self.session_role(&id);
            if let Some(record) = self.token_records.get_mut(&id) {
                record.name = name;
                record.team = team;
            }
            self.token_entry(&id);
        }
    }

    // -- leader ------------------------------------------------------------

    /// Fill a built-in `worker` template from the leader's own launch.
    fn fill_builtin_worker(config: &mut TeamConfig, launch: &LeaderLaunch) {
        if !config.builtin_worker {
            return;
        }
        let Some(template) = config.templates.get_mut("worker") else {
            return;
        };
        if !template.key.agent.is_empty() {
            return;
        }
        template.key = launch.key.clone();
        template.key.cwd = launch.cwd.clone();
        template.env = launch.env.clone();
        #[cfg(unix)]
        {
            template.launch = launch.launch.clone();
        }
        template.worktree = true;
    }

    /// Create a team for `cwd` with this session as its leader (20.4).
    fn create_team(
        &mut self,
        instance: &str,
        session: &str,
        agent: &str,
        cwd: &str,
        config: TeamConfig,
    ) -> String {
        self.next_team += 1;
        let id = format!("t{}", self.next_team);
        // A team created in the middle of a leader prompt inherits that turn's
        // spawn group, so every spawn of the turn shares it (19.6). A turn that
        // has not spawned yet has no group; the first spawn allocates it.
        let current_group = self
            .session_groups
            .get(&(instance.to_string(), session.to_string()))
            .filter(|group| !group.is_empty())
            .cloned();
        let mut team = Team {
            id: id.clone(),
            cwd: cwd.to_string(),
            leaderless: false,
            closed: false,
            suspended: false,
            suspended_at: None,
            leader_instance: Some(instance.to_string()),
            leader_session: Some(session.to_string()),
            participants: HashMap::new(),
            order: vec!["leader".to_string()],
            reserved_names: HashSet::new(),
            config,
            inbox: Vec::new(),
            messages: Vec::new(),
            next_message: 0,
            task_turns: HashMap::new(),
            total_turns: 0,
            total_limit_hit: false,
            task_limit_hit: HashSet::new(),
            watchers: HashMap::new(),
            pending_items: HashMap::new(),
            created_at: now_ms(),
            board: board::Board::default(),
            board_flush_at: None,
            current_group,
            pending_lifecycles: HashMap::new(),
        };
        let mut leader = Participant::new("leader", Role::Leader);
        leader.instance = Some(instance.to_string());
        leader.session = Some(session.to_string());
        leader.agent = Some(agent.to_string());
        team.participants.insert("leader".to_string(), leader);
        self.by_cwd.insert(cwd.to_string(), id.clone());
        self.by_instance
            .insert(instance.to_string(), (id.clone(), "leader".to_string()));
        self.teams.insert(id.clone(), team);
        self.events.push(TeamEvent::Changed(id.clone()));
        id
    }

    /// The session a bound session token belongs to; `Err` with the documented
    /// reason data when it holds none or the switch is off (20.4 step 1).
    fn ensure_session(&self, instance: &str, session: &str) -> Result<(String, String), TeamError> {
        let found = self.token_records.values().find(|record| {
            record.role == Role::Session
                && record.bound
                && record.instance.as_deref() == Some(instance)
                && record.session.as_deref() == Some(session)
        });
        let Some(record) = found else {
            let mut error = TeamError::not_allowed("this chat has no team tools (no_tools)");
            error.data = Some(json!({ "reason": "no_tools" }));
            return Err(error);
        };
        let (Some(agent), Some(cwd)) = (record.agent.clone(), record.cwd.clone()) else {
            let mut error = TeamError::not_allowed("this chat has no team tools (no_tools)");
            error.data = Some(json!({ "reason": "no_tools" }));
            return Err(error);
        };
        if !self.enabled_for(&agent, session, &cwd) {
            let mut error = TeamError::not_allowed("teams are off for this chat");
            error.data = Some(json!({ "reason": "off" }));
            return Err(error);
        }
        Ok((agent, cwd))
    }

    /// The single path to a team (20.4). Returns the team id when this session
    /// leads it; `led_by` carries the current leader.
    pub fn ensure_team(
        &mut self,
        instance: &str,
        session: &str,
        launch: &LeaderLaunch,
    ) -> Result<String, TeamError> {
        let (agent, cwd) = self.ensure_session(instance, session)?;
        let mut config = self.config_for(&cwd);
        Self::fill_builtin_worker(&mut config, launch);
        if let Some(team_id) = self.by_cwd.get(&cwd).cloned() {
            let team = self.teams.get(&team_id).expect("cwd index");
            if team.leader_instance.as_deref() == Some(instance)
                && team.leader_session.as_deref() == Some(session)
            {
                return Ok(team_id);
            }
            let mut error = TeamError::not_allowed("the team is led by another chat");
            error.data = Some(json!({
                "reason": "led_by",
                "team": team_id,
                "leader": {
                    "instance": team.leader_instance,
                    "sessionId": team.leader_session,
                },
            }));
            return Err(error);
        }
        Ok(self.create_team(instance, session, &agent, &cwd, config))
    }

    /// Bind a session token to a live, leaderless or suspended team (20.4
    /// `team.set_leader`). `Err` as in [`Self::ensure_team`].
    pub fn set_leader(
        &mut self,
        team_id: &str,
        instance: &str,
        session: &str,
    ) -> Result<(), TeamError> {
        let (agent, cwd) = self.ensure_session(instance, session)?;
        let team = self
            .teams
            .get(team_id)
            .ok_or_else(|| TeamError::unknown("unknown team"))?;
        if team.cwd != cwd {
            return Err(TeamError::invalid("the session is not in the team's cwd"));
        }
        let previous = team.leader_instance.clone();
        let old_session = team.leader_session.clone();
        if let Some(previous) = &previous {
            if previous != instance
                && self
                    .by_instance
                    .get(previous)
                    .is_some_and(|(_, name)| name == "leader")
            {
                self.by_instance.remove(previous);
            }
        }
        let team = self.teams.get_mut(team_id).expect("checked above");
        team.leader_instance = Some(instance.to_string());
        team.leader_session = Some(session.to_string());
        team.leaderless = false;
        let leader = team
            .participants
            .entry("leader".to_string())
            .or_insert_with(|| Participant::new("leader", Role::Leader));
        leader.instance = Some(instance.to_string());
        leader.session = Some(session.to_string());
        leader.agent = Some(agent.clone());
        leader.set_state(ParticipantState::Idle);
        leader.reason = None;
        self.by_instance.insert(
            instance.to_string(),
            (team_id.to_string(), "leader".to_string()),
        );
        if let (Some(old_instance), Some(old_session)) =
            (previous.as_deref(), old_session.as_deref())
        {
            self.refresh_session_auth(old_instance, old_session);
        }
        self.refresh_session_auth(instance, session);
        self.events.push(TeamEvent::Changed(team_id.to_string()));
        Ok(())
    }

    pub fn start_resume_with_config(
        &mut self,
        team_id: &str,
        instance: &str,
        session: &str,
        agent: &str,
        config: TeamConfig,
    ) -> Value {
        if let Some(team) = self.teams.get_mut(team_id) {
            team.suspended = false;
            team.suspended_at = None;
            team.leader_instance = Some(instance.to_string());
            team.leader_session = Some(session.to_string());
            team.leaderless = false;
            team.config = config;
            if let Some(leader) = team.participants.get_mut("leader") {
                leader.instance = Some(instance.to_string());
                leader.session = Some(session.to_string());
                leader.agent = Some(agent.to_string());
                leader.set_state(ParticipantState::Idle);
                leader.starting = false;
            }
        }
        self.by_instance.insert(
            instance.to_string(),
            (team_id.to_string(), "leader".to_string()),
        );
        self.refresh_session_auth(instance, session);
        self.events.push(TeamEvent::Changed(team_id.to_string()));
        json!({ "team": team_entry(&self.teams[team_id]) })
    }

    /// `start_resume` with the stored configuration, for callers that already
    /// know the resuming agent matches it (tests, and the cwd's plain config).
    pub fn start_resume(
        &mut self,
        team_id: &str,
        instance: &str,
        session: &str,
        agent: &str,
    ) -> Value {
        let config = self
            .teams
            .get(team_id)
            .map(|team| self.config_for(&team.cwd))
            .unwrap_or_default();
        self.start_resume_with_config(team_id, instance, session, agent, config)
    }

    /// The token bound for a still-suspended team whose configure has just
    /// arrived.
    pub fn has_config(&self, cwd: &str) -> bool {
        self.configs.contains_key(cwd)
    }

    pub fn stored_leader_agent(&self, team_id: &str) -> Option<String> {
        self.teams
            .get(team_id)?
            .participants
            .get("leader")
            .and_then(|leader| leader.agent.clone())
    }

    /// Fill an already loaded configuration's built-in template from an
    /// instance launch.
    pub fn fill_builtin_config(&self, config: &mut TeamConfig, launch: &LeaderLaunch) {
        Self::fill_builtin_worker(config, launch);
    }

    /// Remove a participant once it exited (20.6 `remove: true`).
    pub fn finish_worker_removal(&mut self, team_id: &str, name: &str) {
        if let Some(team) = self.teams.get_mut(team_id) {
            team.participants.remove(name);
            team.order.retain(|entry| entry != name);
            team.reserved_names.remove(name);
        }
        self.events.push(TeamEvent::Changed(team_id.to_string()));
    }

    /// The handover refusal of a session, if one is waiting.
    pub fn take_handover_refusal(&mut self, instance: &str, session: &str) -> Option<String> {
        self.handover_refusals
            .remove(&(instance.to_string(), session.to_string()))
            .then(|| "the previous handover request was refused".to_string())
    }

    pub fn set_handover_refusal(&mut self, instance: &str, session: &str) {
        self.handover_refusals
            .insert((instance.to_string(), session.to_string()));
    }

    // -- front-end methods -------------------------------------------------

    pub fn list(&self) -> Value {
        let mut teams: Vec<Value> = self.teams.values().map(team_entry).collect();
        teams.sort_by(|left, right| {
            left.get("id")
                .and_then(Value::as_str)
                .cmp(&right.get("id").and_then(Value::as_str))
        });
        json!({ "teams": teams })
    }

    /// 19.12: clear `owner` from the cards of a refused/orphaned spawn and
    /// tell the leader which cards changed.
    fn clear_owners_after_spawn(
        &mut self,
        team_id: &str,
        name: &str,
        reason: &str,
        notify_leader: bool,
    ) {
        let now = now_ms();
        let Some(team) = self.teams.get_mut(team_id) else {
            return;
        };
        match team.board.clear_owner(name, now) {
            Ok(Some((rev, cards))) => {
                self.events.push(TeamEvent::Board(team_id.to_string(), rev));
                if notify_leader {
                    let body = format!(
                        "owner cleared on {}: spawn request {name} {reason}",
                        cards.join(", ")
                    );
                    let _ = self.send_message(
                        team_id,
                        "human",
                        "leader",
                        Kind::Notice,
                        &body,
                        None,
                        vec![],
                    );
                }
            }
            Ok(None) => {}
            Err(error) => {
                crate::svc_log!(
                    "nvim_ade_server: cannot clear owner {name} of team {team_id}: {}",
                    error.message
                );
                if notify_leader {
                    let body = format!(
                        "cannot clear owner {name}: {} (cards may still name it)",
                        error.message
                    );
                    let _ = self.send_message(
                        team_id,
                        "human",
                        "leader",
                        Kind::Notice,
                        &body,
                        None,
                        vec![],
                    );
                }
            }
        }
    }

    pub fn close(&mut self, team_id: &str) -> Result<(Value, Vec<String>), TeamError> {
        let Some(team) = self.teams.get_mut(team_id) else {
            return Err(TeamError::unknown("unknown team"));
        };
        if team.closed {
            return Err(TeamError::unknown("team closed"));
        }
        team.closed = true;
        team.current_group = None;
        let mut orphaned = Vec::new();
        let mut orphaned_spawns = Vec::new();
        for item in &mut team.inbox {
            if item.kind == ItemKind::Spawn && item.state == ItemState::Open {
                item.state = ItemState::Orphaned;
                orphaned_spawns.push(item.name.clone());
                orphaned.push(item.to_json());
            }
        }
        // 19.12: an orphaned spawn no longer owns cards and its name is free
        // again. The board row is deleted with the team, so this is memory
        // only and needs no notice.
        let now = now_ms();
        for name in orphaned_spawns.into_iter().flatten() {
            team.reserved_names.remove(&name);
            let _ = team.board.clear_owner(&name, now);
        }
        let workers: Vec<String> = team
            .workers()
            .filter_map(|participant| participant.instance.clone())
            .collect();
        // Messages queued for the leader are dropped before the last entry is
        // built, so the closed notification does not show them as still queued.
        if let Some(leader) = team.participants.get_mut("leader") {
            leader.mailbox.clear();
        }
        #[cfg(test)]
        self.closed_boards
            .insert(team_id.to_string(), team.board.clone());
        #[cfg(test)]
        self.closed_reserved
            .insert(team_id.to_string(), team.reserved_names.clone());
        let mut entry = team_entry(team);
        entry["state"] = json!("closed");
        let id = team.id.clone();
        for participant in team.participants.values() {
            if let Some(instance) = &participant.instance {
                self.by_instance.remove(instance);
            }
        }
        self.teams.remove(&id);
        self.by_cwd.retain(|_, value| *value != *id);
        // Keep the token records so a participant connection gets the
        // documented "team closed" answer instead of "unknown token"; the
        // worker instances are stopped and revoke their own tokens on exit.
        self.closed_teams.insert(id.clone());
        self.revoke_team_hashes(&id);
        for item in orphaned {
            self.events.push(TeamEvent::InboxJson(item));
        }
        self.events.push(TeamEvent::Closed(entry.clone()));
        Ok((entry, workers))
    }

    // -- messages ----------------------------------------------------------

    #[allow(clippy::too_many_arguments)]
    /// Whether `name` currently has a bus prompt in flight (19.14).
    pub fn bus_turn_running(&self, team_id: &str, name: &str) -> bool {
        self.teams
            .get(team_id)
            .and_then(|team| team.participants.get(name))
            .is_some_and(|participant| participant.bus_turn)
    }

    /// Move the just-queued message to the front of `name`'s mailbox (19.14).
    /// Mark the running turn as human-interrupted so its end is not counted
    /// against the limits (19.14).
    pub fn mark_interrupting(&mut self, team_id: &str, name: &str) {
        if let Some(participant) = self
            .teams
            .get_mut(team_id)
            .and_then(|team| team.participants.get_mut(name))
        {
            participant.interrupting = participant.prompt_seq;
        }
    }

    /// The prompt id currently running for `name`, if any (19.14).
    pub fn prompt_seq(&self, team_id: &str, name: &str) -> Option<u64> {
        self.teams
            .get(team_id)
            .and_then(|team| team.participants.get(name))
            .and_then(|participant| participant.prompt_seq)
    }

    /// Remember the prompt id a delivery started (19.14).
    pub fn prompt_started(&mut self, team_id: &str, name: &str, seq: u64) {
        if let Some(participant) = self
            .teams
            .get_mut(team_id)
            .and_then(|team| team.participants.get_mut(name))
        {
            participant.prompt_seq = Some(seq);
        }
    }

    /// Whether `seq` is still the running prompt for `name` (19.14). Late
    /// completions after a forced end are dropped with this.
    pub fn prompt_is_current(&self, team_id: &str, name: &str, seq: u64) -> bool {
        self.prompt_seq(team_id, name) == Some(seq)
    }

    pub fn clear_prompt_seq(&mut self, team_id: &str, name: &str) {
        if let Some(participant) = self
            .teams
            .get_mut(team_id)
            .and_then(|team| team.participants.get_mut(name))
        {
            participant.prompt_seq = None;
        }
    }

    /// Orphan open questions/permissions/requests from `name` (19.14): the
    /// cancelled prompt will not answer them.
    pub fn orphan_open_items(&mut self, team_id: &str, name: &str) -> Vec<InboxItem> {
        let Some(team) = self.teams.get_mut(team_id) else {
            return Vec::new();
        };
        let mut out = Vec::new();
        for item in &mut team.inbox {
            if item.state == ItemState::Open
                && item.from == name
                && matches!(
                    item.kind,
                    ItemKind::Question | ItemKind::Permission | ItemKind::Request
                )
            {
                item.state = ItemState::Orphaned;
                out.push(item.clone());
                self.events
                    .push(TeamEvent::Inbox(team_id.to_string(), item.id.clone()));
            }
        }
        if !out.is_empty() {
            // The relay-side requests are answered with a cancel; the team's
            // pending map must forget them too (19.14).
            let orphaned: std::collections::HashSet<&str> =
                out.iter().map(|item| item.id.as_str()).collect();
            team.pending_items
                .retain(|_, pending| !orphaned.contains(pending.as_str()));
            self.events.push(TeamEvent::Changed(team_id.to_string()));
        }
        out
    }

    /// Whether `id` is still queued for `name`.
    pub fn message_queued(&self, team_id: &str, name: &str, id: u64) -> bool {
        self.teams
            .get(team_id)
            .and_then(|team| team.participants.get(name))
            .is_some_and(|participant| participant.mailbox.iter().any(|message| message.id == id))
    }

    /// Move the just-queued message in front of the earlier interrupts but
    /// after everything else already urgent (19.14).
    pub fn prioritize_message(&mut self, team_id: &str, name: &str, id: u64, after: usize) {
        let Some(team) = self.teams.get_mut(team_id) else {
            return;
        };
        let Some(participant) = team.participants.get_mut(name) else {
            return;
        };
        let Some(index) = participant
            .mailbox
            .iter()
            .position(|message| message.id == id)
        else {
            return;
        };
        let message = participant.mailbox.remove(index).expect("found above");
        let at = after.min(participant.mailbox.len());
        participant.mailbox.insert(at, message);
        self.events.push(TeamEvent::Changed(team_id.to_string()));
    }

    #[allow(clippy::too_many_arguments)]
    pub fn send_message(
        &mut self,
        team_id: &str,
        from: &str,
        to: &str,
        kind: Kind,
        body: &str,
        task: Option<&str>,
        refs: Vec<String>,
    ) -> Result<u64, TeamError> {
        let inbox_id = self.next_inbox_id();
        let team = self
            .teams
            .get_mut(team_id)
            .ok_or_else(|| TeamError::unknown("unknown team"))?;
        if team.closed {
            return Err(TeamError::unknown("team closed"));
        }
        validate_name(to)?;
        if to == from {
            return Err(TeamError::invalid("a participant cannot message itself"));
        }
        let from_role = if from == "human" {
            None
        } else {
            let participant = team
                .participants
                .get(from)
                .ok_or_else(|| TeamError::unknown("unknown sender"))?;
            Some(participant.role)
        };
        if from_role == Some(Role::Worker) && kind == Kind::Control {
            return Err(TeamError::invalid("workers cannot send control"));
        }
        if from_role == Some(Role::Leader) && kind == Kind::Control && to == "human" {
            return Err(TeamError::invalid("control to human is refused"));
        }
        if from == "human" && kind == Kind::Control && to == "human" {
            return Err(TeamError::invalid("control to human is refused"));
        }
        let task = task.unwrap_or("_");
        validate_task(task)?;
        validate_body(body)?;
        validate_refs(&refs)?;
        if to != "human" {
            let Some(target) = team.participants.get(to) else {
                return Err(TeamError::unknown("unknown participant"));
            };
            if target.state == ParticipantState::Exited && !(to == "leader" && team.leaderless) {
                return Err(TeamError::unknown("participant exited"));
            }
        }

        let id = team.next_message();
        let at = now_ms();
        let message = Message {
            id,
            from: from.to_string(),
            to: to.to_string(),
            kind,
            task: task.to_string(),
            body: body.to_string(),
            refs,
            at,
        };
        if kind == Kind::Control && !matches!(body, "pause" | "resume" | "cancel") {
            return Err(TeamError::invalid(
                "control body must be cancel, pause or resume",
            ));
        }
        if kind == Kind::Report && from != "human" {
            if let Some(participant) = team.participants.get_mut(from) {
                if participant.turn_sender.as_deref() == Some(to) && participant.bus_turn {
                    participant.reported = true;
                }
            }
        }
        team.messages.push(message.clone());
        if kind == Kind::Control {
            match body {
                "pause" | "resume" => {
                    if let Some(target) = team.participants.get_mut(to) {
                        target.paused = body == "pause";
                        target.paused_by_limit = false;
                        if body == "resume" {
                            team.task_limit_hit.retain(|(name, _)| name != to);
                            team.total_limit_hit = false;
                        }
                    }
                    let team_id = team.id.clone();
                    self.events.push(TeamEvent::Changed(team_id));
                }
                "cancel" => {}
                _ => {
                    return Err(TeamError::invalid(
                        "control body must be cancel, pause or resume",
                    ))
                }
            }
            return Ok(id);
        }
        if to == "human" {
            let item = InboxItem {
                id: inbox_id,
                team: team.id.clone(),
                kind: ItemKind::Message,
                from: from.to_string(),
                body: body.to_string(),
                at,
                state: ItemState::Open,
                options: None,
                template: None,
                name: None,
                task: None,
                model: None,
                role: None,
                label: None,
                questions: None,
                agent: None,
                group: None,
                instance: None,
                session: None,
                tool_call: None,
                tool_options: None,
                method: None,
                params: None,
                message_id: Some(id),
                participant: None,
                scope: None,
                limit_task: None,
                from_instance: None,
                from_session: None,
                leader_instance: None,
                leader_session: None,
                agent_id: None,
            };
            let item_id = item.id.clone();
            team.inbox.push(item);
            let team_id = team.id.clone();
            self.events.push(TeamEvent::Inbox(team_id, item_id));
        } else {
            let leaderless = team.leaderless && to == "leader";
            let target = team
                .participants
                .get_mut(to)
                .ok_or_else(|| TeamError::unknown("unknown participant"))?;
            if target.state == ParticipantState::Exited && !leaderless {
                return Err(TeamError::unknown("participant exited"));
            }
            target.mailbox.push_back(message);
            let team_id = team.id.clone();
            self.events.push(TeamEvent::Changed(team_id));
        }
        Ok(id)
    }

    pub fn next_inbox_id(&mut self) -> String {
        self.next_inbox += 1;
        format!("i{}", self.next_inbox)
    }

    /// A participant token for a worker (18.6). The raw token is returned once,
    /// for the `mcpServers` entry; only its hash is kept.
    pub fn create_worker_token(
        &mut self,
        team_id: &str,
        name: &str,
        instance: &str,
    ) -> Option<(String, String)> {
        let cwd = self.teams.get(team_id)?.cwd.clone();
        let (token_id, token) =
            self.create_token(Role::Worker, Some(instance.to_string()), Some(cwd), None);
        if let Some(record) = self.token_records.get_mut(&token_id) {
            record.team = Some(team_id.to_string());
            record.name = Some(name.to_string());
            record.bound = true;
        }
        self.token_entry(&token_id);
        Some((token_id, token))
    }

    /// Register a worker request in the shared pending set (18.7/18.11).
    pub fn add_pending_item(
        &mut self,
        team_id: &str,
        name: &str,
        instance: &str,
        session: Option<&str>,
        message: &Value,
        permission: bool,
    ) -> Option<String> {
        let id = self.next_inbox_id();
        let agent_id = message.get("id").cloned();
        let params = message.get("params").cloned().unwrap_or(Value::Null);
        let tool_call = params.get("toolCall").cloned().unwrap_or(Value::Null);
        let options = params.get("options").cloned().unwrap_or_else(|| json!([]));
        let method = message
            .get("method")
            .and_then(Value::as_str)
            .unwrap_or("")
            .to_string();
        let body = if permission {
            tool_call
                .get("title")
                .and_then(Value::as_str)
                .or_else(|| tool_call.get("kind").and_then(Value::as_str))
                .unwrap_or("permission")
                .to_string()
        } else {
            method.clone()
        };
        let pending_key = agent_id
            .as_ref()
            .map(|id| (instance.to_string(), crate::relay::id_key(id)));
        let item = InboxItem {
            id: id.clone(),
            team: team_id.to_string(),
            kind: if permission {
                ItemKind::Permission
            } else {
                ItemKind::Request
            },
            from: name.to_string(),
            body,
            at: now_ms(),
            state: ItemState::Open,
            options: None,
            template: None,
            name: None,
            task: None,
            model: None,
            role: None,
            label: None,
            questions: None,
            agent: None,
            group: None,
            instance: Some(instance.to_string()),
            session: session.map(str::to_string),
            tool_call: if permission { Some(tool_call) } else { None },
            tool_options: if permission { Some(options) } else { None },
            method: if permission { None } else { Some(method) },
            params: if permission { None } else { Some(params) },
            message_id: None,
            participant: None,
            scope: None,
            limit_task: None,
            from_instance: None,
            from_session: None,
            leader_instance: None,
            leader_session: None,
            agent_id,
        };
        let team = self.teams.get_mut(team_id)?;
        if let Some(key) = pending_key {
            team.pending_items.insert(key, id.clone());
        }
        team.inbox.push(item);
        self.events
            .push(TeamEvent::Inbox(team_id.to_string(), id.clone()));
        self.events.push(TeamEvent::Changed(team_id.to_string()));
        Some(id)
    }

    pub fn ask_human(
        &mut self,
        team_id: &str,
        from: &str,
        question: &str,
        options: Option<Vec<String>>,
    ) -> Result<String, TeamError> {
        if question.is_empty() || question.len() > MAX_BODY_BYTES {
            return Err(TeamError::invalid("question must be 1..64 KiB"));
        }
        if let Some(options) = &options {
            if options.len() > 6 {
                return Err(TeamError::invalid("options must have at most 6 entries"));
            }
            let single_hint = options.len() == 1;
            let mut seen = HashSet::new();
            for option in options {
                // A single 18.5 option becomes a text hint, as before: keep its
                // old 1 KiB allowance instead of the 19.13 label limits.
                if single_hint {
                    if option.is_empty() || option.len() > MAX_REF_BYTES || !is_one_line(option) {
                        return Err(TeamError::invalid(
                            "the option hint must be one line of 1..1024 bytes",
                        ));
                    }
                    continue;
                }
                if option.is_empty()
                    || option.chars().count() > 60
                    || !is_one_line(option)
                    || option.contains(", ")
                {
                    return Err(TeamError::invalid(
                        "options must be one line of 1..60 characters without ', '",
                    ));
                }
                if !seen.insert(option.as_str()) {
                    return Err(TeamError::invalid(format!(
                        "option {option} is already used"
                    )));
                }
            }
        }
        // 19.13: the 18.5 form is one question with the header "Question".
        // One legacy option is not a choice: keep it as a text hint.
        let single = options
            .as_ref()
            .filter(|options| options.len() == 1)
            .map(|options| options[0].clone());
        let normalized_question = match &single {
            Some(option) => format!("{question}\n{option}"),
            None => question.to_string(),
        };
        let normalized_options =
            options
                .as_ref()
                .filter(|options| options.len() >= 2)
                .map(|options| {
                    options
                        .iter()
                        .map(|label| QuestionOption {
                            label: label.clone(),
                            description: None,
                        })
                        .collect()
                });
        let questions = vec![Question {
            header: "Question".to_string(),
            question: normalized_question,
            options: normalized_options,
            multi_select: false,
        }];
        self.ask_human_questions(team_id, from, questions, options)
    }

    /// `bus.ask_human` with 19.13 `questions`; `legacy_options` keeps the 18.5
    /// top-level `options` on the inbox item.
    pub fn ask_human_questions(
        &mut self,
        team_id: &str,
        from: &str,
        questions: Vec<Question>,
        legacy_options: Option<Vec<String>>,
    ) -> Result<String, TeamError> {
        if questions.is_empty() || questions.len() > 4 {
            return Err(TeamError::invalid("questions must have 1..4 entries"));
        }
        {
            let team = self
                .teams
                .get(team_id)
                .ok_or_else(|| TeamError::unknown("unknown team"))?;
            if team.closed {
                return Err(TeamError::unknown("team closed"));
            }
            let Some(participant) = team.participants.get(from) else {
                return Err(TeamError::unknown("unknown participant"));
            };
            if participant.state == ParticipantState::Exited {
                return Err(TeamError::unknown("participant exited"));
            }
        }
        let id = self.next_inbox_id();
        let team = self.teams.get_mut(team_id).expect("checked above");
        let Some(participant) = team.participants.get_mut(from) else {
            unreachable!("checked above")
        };
        let body = questions
            .first()
            .map(|question| question.question.clone())
            .unwrap_or_default();
        participant.set_state(ParticipantState::WaitingHuman);
        let item = InboxItem {
            id: id.clone(),
            team: team.id.clone(),
            kind: ItemKind::Question,
            from: from.to_string(),
            body,
            at: now_ms(),
            state: ItemState::Open,
            options: legacy_options,
            template: None,
            name: None,
            task: None,
            model: None,
            role: None,
            label: None,
            agent: None,
            group: None,
            questions: Some(questions),
            instance: None,
            session: None,
            tool_call: None,
            tool_options: None,
            method: None,
            params: None,
            message_id: None,
            participant: None,
            scope: None,
            limit_task: None,
            from_instance: None,
            from_session: None,
            leader_instance: None,
            leader_session: None,
            agent_id: None,
        };
        team.inbox.push(item);
        let team_id = team.id.clone();
        self.events
            .push(TeamEvent::Inbox(team_id.clone(), id.clone()));
        self.events.push(TeamEvent::Changed(team_id));
        Ok(id)
    }

    pub fn status(&self, team_id: &str, name: &str, project: &str) -> Result<Value, TeamError> {
        let team = self
            .teams
            .get(team_id)
            .ok_or_else(|| TeamError::unknown("unknown team"))?;
        if team.closed {
            return Err(TeamError::unknown("team closed"));
        }
        let self_participant = team
            .participants
            .get(name)
            .ok_or_else(|| TeamError::unknown("unknown participant"))?;
        let mut members = Vec::new();
        for entry in &team.order {
            let Some(participant) = team.participants.get(entry) else {
                continue;
            };
            members.push(json!({
                "name": participant.name,
                "role": participant.role.as_str(),
                "state": participant.state.as_str(),
                "paused": participant.paused,
                "task": participant.task,
                "queued": participant.queued(),
            }));
        }
        let mut out = json!({
            "self": {
                "name": self_participant.name,
                "role": self_participant.role.as_str(),
                "state": self_participant.state.as_str(),
                "paused": self_participant.paused,
            },
            "members": members,
        });
        if self_participant.role == Role::Leader {
            let mut templates: Vec<Value> = team
                .config
                .templates
                .iter()
                .map(|(name, template)| {
                    json!({
                        "name": name,
                        "agent": template.key.agent,
                        "models": template.models,
                    })
                })
                .collect();
            templates.sort_by(|left, right| left["name"].as_str().cmp(&right["name"].as_str()));
            out["templates"] = json!(templates);
            out["workflows"] = json!(self.workflow_short_list(team_id, project));
            out["workers_left"] = json!(team
                .config
                .max_workers
                .saturating_sub(team.live_workers() as u64));
            out["board"] = team.board.status();
        }
        Ok(out)
    }

    pub fn read(
        &self,
        team_id: &str,
        participant: &str,
        since: Option<u64>,
    ) -> Result<Value, TeamError> {
        let team = self
            .teams
            .get(team_id)
            .ok_or_else(|| TeamError::unknown("unknown team"))?;
        if !team.participants.contains_key(participant) {
            return Err(TeamError::unknown("unknown participant"));
        }
        let since = since.unwrap_or(0);
        let mut messages: Vec<&Message> = team
            .messages
            .iter()
            .filter(|message| {
                message.id > since && (message.from == participant || message.to == participant)
            })
            .collect();
        if messages.len() > MAX_READ_MESSAGES {
            messages = messages.split_off(messages.len() - MAX_READ_MESSAGES);
        }
        let messages: Vec<Value> = messages
            .iter()
            .map(|message| message.to_json(&team.id))
            .collect();
        let participant_entry = team.participants.get(participant).expect("checked above");
        let mut turns: Vec<Value> = Vec::new();
        let mut total = 0usize;
        for turn in participant_entry.turns.iter().rev() {
            let text = turn.text.clone();
            if total + text.len() > MAX_TURN_TEXT && !turns.is_empty() {
                break;
            }
            total += text.len();
            turns.push(json!({ "at": turn.at, "text": text }));
            if turns.len() == 3 {
                break;
            }
        }
        turns.reverse();
        let mut out = json!({ "messages": messages, "turns": turns });
        if let Some(worktree) = &participant_entry.worktree {
            out["worktree"] = json!({
                "path": worktree.path,
                "branch": worktree.branch,
                "base": worktree.base,
            });
        }
        Ok(out)
    }

    // -- spawning ----------------------------------------------------------

    #[allow(clippy::too_many_arguments)]
    pub fn request_spawn(
        &mut self,
        team_id: &str,
        template: &str,
        name: Option<&str>,
        model: Option<&str>,
        role: Option<&str>,
        task: Option<&str>,
    ) -> Result<SpawnOutcome, TeamError> {
        self.request_spawn_labeled(team_id, template, name, model, role, task, None)
    }

    /// `bus.spawn` with the 19.12 `label`.
    #[allow(clippy::too_many_arguments)]
    pub fn request_spawn_labeled(
        &mut self,
        team_id: &str,
        template: &str,
        name: Option<&str>,
        model: Option<&str>,
        role: Option<&str>,
        task: Option<&str>,
        label: Option<&str>,
    ) -> Result<SpawnOutcome, TeamError> {
        if let Some(label) = label {
            validate_label(label)?;
        }
        let group = self.next_spawn_group(team_id);
        let spawn_item_id = self.next_inbox_id();
        self.next_lifecycle += 1;
        let lifecycle = self.next_lifecycle;
        let team = self
            .teams
            .get_mut(team_id)
            .ok_or_else(|| TeamError::unknown("unknown team"))?;
        if team.closed {
            return Err(TeamError::unknown("team closed"));
        }
        if team.suspended {
            return Err(TeamError::unknown("suspended"));
        }
        validate_spawn_choice(team, template, model, role)?;
        let name = spawn_name(team, template, name, task)?;
        team.pending_lifecycles.insert(name.clone(), lifecycle);
        let auto = team.config.spawn_auto.contains(template);
        if auto {
            spawn_participant(team, &name, template, model, role, task, label, lifecycle)?;
            team.order.push(name.clone());
            let team_id = team.id.clone();
            self.events.push(TeamEvent::Changed(team_id.clone()));
            return Ok(SpawnOutcome::Started(SpawnRequest {
                team: team_id,
                name,
                template: template.to_string(),
                model: model.map(str::to_string),
                role: role.map(str::to_string),
                task: task.map(str::to_string),
                lifecycle,
            }));
        }
        let agent = team
            .config
            .templates
            .get(template)
            .map(|template| template.key.agent.clone());
        team.reserved_names.insert(name.clone());
        let item = InboxItem {
            id: spawn_item_id.clone(),
            team: team.id.clone(),
            kind: ItemKind::Spawn,
            from: "leader".to_string(),
            body: format!("spawn {name} from template {template}"),
            at: now_ms(),
            state: ItemState::Open,
            options: None,
            template: Some(template.to_string()),
            name: Some(name.clone()),
            task: task.map(str::to_string),
            model: model.map(str::to_string),
            role: role.map(str::to_string),
            label: label.map(str::to_string),
            questions: None,
            agent,
            group,
            instance: None,
            session: None,
            tool_call: None,
            tool_options: None,
            method: None,
            params: None,
            message_id: None,
            participant: None,
            scope: None,
            limit_task: None,
            from_instance: None,
            from_session: None,
            leader_instance: None,
            leader_session: None,
            agent_id: None,
        };
        team.inbox.push(item);
        let team_id = team.id.clone();
        self.events
            .push(TeamEvent::Inbox(team_id, spawn_item_id.clone()));
        Ok(SpawnOutcome::Awaiting {
            request: spawn_item_id,
            name,
        })
    }

    /// `team.spawn` (18.13): the person starts a worker without the inbox.
    #[allow(clippy::too_many_arguments)]
    pub fn request_spawn_human(
        &mut self,
        team_id: &str,
        template: &str,
        name: Option<&str>,
        model: Option<&str>,
        role: Option<&str>,
        task: Option<&str>,
    ) -> Result<SpawnRequest, TeamError> {
        self.request_spawn_human_labeled(team_id, template, name, model, role, task, None)
    }

    /// `team.spawn`/`team.start` with the 19.12 `label`.
    #[allow(clippy::too_many_arguments)]
    pub fn request_spawn_human_labeled(
        &mut self,
        team_id: &str,
        template: &str,
        name: Option<&str>,
        model: Option<&str>,
        role: Option<&str>,
        task: Option<&str>,
        label: Option<&str>,
    ) -> Result<SpawnRequest, TeamError> {
        if let Some(label) = label {
            validate_label(label)?;
        }
        self.next_lifecycle += 1;
        let lifecycle = self.next_lifecycle;
        let team = self
            .teams
            .get_mut(team_id)
            .ok_or_else(|| TeamError::unknown("unknown team"))?;
        if team.closed {
            return Err(TeamError::unknown("team closed"));
        }
        if team.suspended {
            return Err(TeamError::unknown("suspended"));
        }
        validate_spawn_choice(team, template, model, role)?;
        let name = spawn_name(team, template, name, task)?;
        spawn_participant(team, &name, template, model, role, task, label, lifecycle)?;
        team.order.push(name.clone());
        let team_id = team.id.clone();
        self.events.push(TeamEvent::Changed(team_id.clone()));
        Ok(SpawnRequest {
            team: team_id,
            name,
            template: template.to_string(),
            model: model.map(str::to_string),
            role: role.map(str::to_string),
            task: task.map(str::to_string),
            lifecycle,
        })
    }

    /// The driver starts an approved/auto worker. The participant already
    /// exists in `starting` state; this returns the template details.
    pub fn spawn_details(&self, team_id: &str, name: &str) -> Option<(String, Template, String)> {
        let team = self.teams.get(team_id)?;
        let participant = team.participants.get(name)?;
        let template_name = participant.template.clone()?;
        let template = team.config.templates.get(&template_name)?.clone();
        Some((template_name, template, team.cwd.clone()))
    }

    /// The worker template a resumed participant may use, or the reason it may
    /// not resume.
    ///
    /// A stored participant ran one agent. After a restart the front end
    /// supplies a template again; if that template now starts a different
    /// agent, the stored session belongs to a conversation the new adapter never
    /// had, so the participant stays exited instead of being resumed with it.
    pub fn resume_template(&self, team_id: &str, name: &str) -> Result<(String, Template), String> {
        let team = self
            .teams
            .get(team_id)
            .ok_or_else(|| "unknown team".to_string())?;
        let participant = team
            .participants
            .get(name)
            .ok_or_else(|| format!("unknown participant {name}"))?;
        let template_name = participant
            .template
            .clone()
            .ok_or_else(|| format!("worker {name} has no template"))?;
        let template = team
            .config
            .templates
            .get(&template_name)
            .ok_or_else(|| format!("template {template_name} is no longer configured"))?;
        if let Some(stored) = &participant.agent {
            if stored != &template.key.agent {
                return Err(format!(
                    "template {template_name} now starts agent {}, the worker ran {stored}",
                    template.key.agent
                ));
            }
        }
        Ok((template_name, template.clone()))
    }

    /// Everything the driver needs to place a worker (18.12).
    pub fn spawn_plan(&self, team_id: &str, name: &str) -> Option<SpawnPlan> {
        let team = self.teams.get(team_id)?;
        let participant = team.participants.get(name)?;
        let template_name = participant.template.clone()?;
        let template = team.config.templates.get(&template_name)?.clone();
        Some(SpawnPlan {
            template,
            cwd: team.cwd.clone(),
            stamp: worktree::stamp(team.created_at),
            worktree_root: team.config.worktree_root.clone(),
        })
    }

    /// A resumed worker starts a fresh session: its next prompt carries the
    /// role card again (18.15).
    pub fn worker_without_history(&mut self, team_id: &str, name: &str) {
        if let Some(team) = self.teams.get_mut(team_id) {
            if let Some(participant) = team.participants.get_mut(name) {
                participant.first_prompt = true;
            }
            self.events.push(TeamEvent::Changed(team_id.to_string()));
        }
    }

    pub fn worktree_prepared(&mut self, team_id: &str, name: &str, info: worktree::WorktreeInfo) {
        let Some(team) = self.teams.get_mut(team_id) else {
            return;
        };
        let Some(participant) = team.participants.get_mut(name) else {
            return;
        };
        if info.warning.as_deref() == Some("dirty_tree") {
            if let Some(card) = &mut participant.role_card {
                card.push('\n');
                card.push_str(worktree::dirty_note());
            }
        }
        if let Some(relative) = &info.missing_subdir {
            if let Some(card) = &mut participant.role_card {
                card.push('\n');
                card.push_str(&format!(
                    "The team's subdirectory {relative} is missing here; you are at the worktree root."
                ));
            }
        }
        participant.worktree = Some(info);
        self.events.push(TeamEvent::Changed(team_id.to_string()));
    }

    pub fn worktree_removed(&mut self, team_id: &str, name: &str) {
        if let Some(team) = self.teams.get_mut(team_id) {
            if let Some(participant) = team.participants.get_mut(name) {
                participant.worktree = None;
            }
        }
        self.events.push(TeamEvent::Changed(team_id.to_string()));
    }

    pub fn worktree_info(&self, team_id: &str, name: &str) -> Option<worktree::WorktreeInfo> {
        self.teams
            .get(team_id)?
            .participants
            .get(name)?
            .worktree
            .clone()
    }

    pub fn created_at(&self, team_id: &str) -> Option<u64> {
        self.teams.get(team_id).map(|team| team.created_at)
    }

    pub fn worker_instance_set(&mut self, team_id: &str, name: &str, instance: &str) {
        if let Some(team) = self.teams.get_mut(team_id) {
            if let Some(participant) = team.participants.get_mut(name) {
                participant.instance = Some(instance.to_string());
            }
        }
        self.by_instance.insert(
            instance.to_string(),
            (team_id.to_string(), name.to_string()),
        );
    }

    pub fn worker_session_set(&mut self, team_id: &str, name: &str, session: &str) {
        if let Some(team) = self.teams.get_mut(team_id) {
            if let Some(participant) = team.participants.get_mut(name) {
                participant.session = Some(session.to_string());
            }
            self.events.push(TeamEvent::Changed(team_id.to_string()));
        }
    }

    /// A front-end prompt on a team member starts/ends; this is only the
    /// visible state (deliveries already use the relay's turn count).
    pub fn frontend_prompt_started(&mut self, instance: &str, session: &str) {
        // A prompt opens the turn of its session; the spawn group itself is
        // only allocated when the turn really spawns (19.6).
        self.session_groups
            .entry((instance.to_string(), session.to_string()))
            .or_default();
        let Some((team_id, name)) = self.by_instance.get(instance).cloned() else {
            return;
        };
        let mut leader = false;
        if let Some(team) = self.teams.get_mut(&team_id) {
            if let Some(participant) = team.participants.get_mut(&name) {
                if participant.state != ParticipantState::Exited {
                    participant.set_state(ParticipantState::Working);
                }
                leader = participant.role == Role::Leader;
            }
            self.events.push(TeamEvent::Changed(team_id.clone()));
        }
        if leader || name == "leader" {
            // A prompt from the front end opens a spawn group too (19.6).
            self.begin_leader_group(&team_id);
        }
    }

    fn finish_session_group(&mut self, instance: &str, session: &str) {
        self.session_groups
            .remove(&(instance.to_string(), session.to_string()));
        let Some((team_id, name)) = self.by_instance.get(instance).cloned() else {
            return;
        };
        if name != "leader" {
            return;
        }
        if let Some(team) = self.teams.get_mut(&team_id) {
            team.current_group = None;
        }
    }

    /// Forget the open turns of an instance: its prompts can never finish (a
    /// new instance with the same key must not inherit them).
    pub fn forget_session_groups(&mut self, instance: &str) {
        self.session_groups.retain(|key, _| key.0 != instance);
    }

    /// Forget one session's open turn (the session closed).
    pub fn forget_session_group(&mut self, instance: &str, session: &str) {
        self.session_groups
            .remove(&(instance.to_string(), session.to_string()));
    }

    pub fn frontend_prompt_finished(&mut self, instance: &str, session: &str) {
        self.finish_session_group(instance, session);
        let Some((team_id, name)) = self.by_instance.get(instance).cloned() else {
            return;
        };
        let Some(team) = self.teams.get_mut(&team_id) else {
            return;
        };
        let waiting = team.inbox.iter().any(|item| {
            item.kind == ItemKind::Question && item.from == name && item.state == ItemState::Open
        });
        if let Some(participant) = team.participants.get_mut(&name) {
            if participant.state != ParticipantState::Exited {
                participant.set_state(if waiting {
                    ParticipantState::WaitingHuman
                } else {
                    ParticipantState::Idle
                });
            }
        }
        let leader = team
            .participants
            .get(&name)
            .is_some_and(|participant| participant.role == Role::Leader);
        self.events.push(TeamEvent::Changed(team_id.clone()));
        if leader || name == "leader" {
            self.finish_leader_group(&team_id);
        }
    }

    /// The worker's session and optional model configuration are ready; only
    /// now may the first prompt be delivered (18.3).
    pub fn worker_started(&mut self, team_id: &str, name: &str) {
        if let Some(team) = self.teams.get_mut(team_id) {
            if let Some(participant) = team.participants.get_mut(name) {
                participant.starting = false;
            }
            self.events.push(TeamEvent::Changed(team_id.to_string()));
        }
    }

    pub fn worker_start_failed(&mut self, team_id: &str, name: &str, reason: &str) {
        let Some(team) = self.teams.get_mut(team_id) else {
            return;
        };
        let Some(participant) = team.participants.get_mut(name) else {
            return;
        };
        participant.set_state(ParticipantState::Exited);
        participant.prompt_seq = None;
        participant.reason = Some(reason.to_string());
        participant.starting = false;
        participant.bus_turn = false;
        participant.mailbox.clear();
        let leader = team.leader_instance.clone();
        let sender = participant.task_sender.clone();
        let task = participant.task.clone();
        let notice = format!("worker {name} exited: {reason}");
        let _ = leader;
        let team_id = team_id.to_string();
        let _ = self.send_message(
            &team_id,
            name,
            "leader",
            Kind::Notice,
            &notice,
            Some(&task),
            vec![task.clone()],
        );
        if let Some(sender) = sender {
            if sender != "leader" {
                let _ = self.send_message(
                    &team_id,
                    name,
                    &sender,
                    Kind::Notice,
                    &notice,
                    Some(&task),
                    vec![task.clone()],
                );
            }
        }
        self.events.push(TeamEvent::Changed(team_id));
    }

    // -- delivery ----------------------------------------------------------

    pub fn take_deliveries(&mut self, frontend_busy: &HashSet<String>) -> Vec<DeliveryRequest> {
        let team_ids: Vec<String> = self.teams.keys().cloned().collect();
        let mut out = Vec::new();
        for team_id in team_ids {
            let names: Vec<String> = match self.teams.get(&team_id) {
                Some(team) => team.order.clone(),
                None => continue,
            };
            for name in names {
                let busy = match self.teams.get(&team_id) {
                    Some(team) => team
                        .participants
                        .get(&name)
                        .and_then(|participant| participant.instance.clone())
                        .is_some_and(|instance| frontend_busy.contains(&instance)),
                    None => false,
                };
                if busy {
                    continue;
                }
                if let Some(delivery) = self.deliver(&team_id, &name) {
                    if delivery.participant == "leader" {
                        // A bus prompt on the leader opens a spawn group (19.6).
                        self.begin_leader_group(&team_id);
                    }
                    out.push(delivery);
                }
            }
        }
        out
    }

    fn deliver(&mut self, team_id: &str, name: &str) -> Option<DeliveryRequest> {
        let team = self.teams.get_mut(team_id)?;
        if team.suspended {
            return None;
        }
        let participant = team.participants.get_mut(name)?;
        if participant.state != ParticipantState::Idle
            || participant.paused
            || participant.starting
            || participant.bus_turn
            || participant.instance.is_none()
            || participant.session.is_none()
        {
            return None;
        }
        let mut blocks = Vec::new();
        if participant.first_prompt {
            if let Some(card) = &participant.role_card {
                blocks.push(json!({ "type": "text", "text": card }));
            }
        }
        let mut used = 0usize;
        let mut taken: Vec<Message> = Vec::new();
        while let Some(message) = participant.mailbox.front() {
            let text = format_message(message);
            if !taken.is_empty() && used + text.len() > MAX_DELIVERY_BYTES {
                break;
            }
            used += text.len();
            let message = participant.mailbox.pop_front().expect("front");
            blocks.push(json!({ "type": "text", "text": text }));
            if message.kind == Kind::Task {
                participant.task = message.task.clone();
                participant.task_sender = Some(message.from.clone());
            }
            taken.push(message);
        }
        if blocks.is_empty() || (taken.is_empty() && !participant.first_prompt) {
            return None;
        }
        let first_prompt = participant.first_prompt;
        participant.first_prompt = false;
        participant.set_state(ParticipantState::Working);
        participant.bus_turn = true;
        participant.prompt_seq = None;
        participant.turn_text.clear();
        participant.turn_task = participant.task.clone();
        participant.turn_sender = participant.task_sender.clone();
        participant.reported = false;
        participant.turn_activity = false;
        let instance = participant.instance.clone()?;
        let session = participant.session.clone()?;
        self.events.push(TeamEvent::Changed(team_id.to_string()));
        Some(DeliveryRequest {
            team: team_id.to_string(),
            participant: name.to_string(),
            instance,
            session,
            blocks,
            messages: taken,
            first_prompt,
        })
    }

    /// The prompt could not be sent. Put the consumed messages back in front
    /// and leave the participant ready for the next delivery.
    pub fn delivery_failed(
        &mut self,
        team_id: &str,
        name: &str,
        messages: Vec<Message>,
        first_prompt: bool,
    ) {
        let Some(team) = self.teams.get_mut(team_id) else {
            return;
        };
        let Some(participant) = team.participants.get_mut(name) else {
            return;
        };
        for message in messages.into_iter().rev() {
            participant.mailbox.push_front(message);
        }
        participant.first_prompt |= first_prompt;
        participant.set_state(ParticipantState::Idle);
        participant.bus_turn = false;
        participant.reported = false;
        self.events.push(TeamEvent::Changed(team_id.to_string()));
    }

    pub fn observe_chunk(&mut self, instance: &str, session: Option<&str>, text: &str) {
        let Some(team) = self.teams.values_mut().find(|team| {
            team.is_worker_instance(instance).is_some() || team.is_leader_instance(instance)
        }) else {
            return;
        };
        let name = if let Some(name) = team.is_worker_instance(instance) {
            name.to_string()
        } else {
            "leader".to_string()
        };
        let Some(participant) = team.participants.get_mut(&name) else {
            return;
        };
        if session.is_some_and(|session| participant.session.as_deref() != Some(session)) {
            return;
        }
        if participant.bus_turn {
            participant.turn_text.push_str(text);
        }
    }

    #[allow(clippy::too_many_arguments)]
    pub fn turn_finished(
        &mut self,
        instance: &str,
        success: bool,
        error: Option<String>,
        text: String,
    ) -> Option<String> {
        let team_id = self
            .teams
            .values()
            .find(|team| {
                team.is_worker_instance(instance).is_some() || team.is_leader_instance(instance)
            })
            .map(|team| team.id.clone())?;
        let task_item_id = self.next_inbox_id();
        let total_item_id = self.next_inbox_id();
        let team = self.teams.get_mut(&team_id)?;
        let name = if let Some(name) = team.is_worker_instance(instance) {
            name.to_string()
        } else if team.is_leader_instance(instance) {
            "leader".to_string()
        } else {
            return None;
        };
        let participant = team.participants.get_mut(&name)?;
        let role = participant.role;
        let task = participant.turn_task.clone();
        let sender = participant.turn_sender.clone();
        let reported = participant.reported;
        let was_waiting = participant.state == ParticipantState::WaitingHuman;
        let bus_turn = participant.bus_turn;
        let turn_seq = participant.prompt_seq;
        let interrupted = participant.interrupting == turn_seq && turn_seq.is_some();
        participant.interrupting = None;
        participant.prompt_seq = None;
        participant.bus_turn = false;
        let turn_text = if text.is_empty() {
            participant.turn_text.clone()
        } else {
            text
        };
        participant.finish_turn_activity(&turn_text, bus_turn, now_ms());
        participant.set_state(if was_waiting && !interrupted {
            ParticipantState::WaitingHuman
        } else {
            ParticipantState::Idle
        });
        if !interrupted {
            participant.turns_total += 1;
        }
        participant.turn_text.clear();
        participant.turns.push_back(TurnText {
            at: now_ms(),
            text: trim_end(&turn_text, MAX_TURN_TEXT),
        });
        while participant.turns.len() > 3 {
            participant.turns.pop_front();
        }
        if !interrupted {
            team.total_turns += 1;
            *team
                .task_turns
                .entry((name.clone(), task.clone()))
                .or_insert(0) += 1;
        }

        let mut notices: Vec<(String, String, Kind, String, String, Vec<String>)> = Vec::new();
        if !success {
            if role == Role::Worker {
                if let Some(sender) = sender.clone() {
                    let body = match &error {
                        Some(message) if !message.is_empty() => {
                            format!("turn ended: error: {message}")
                        }
                        _ => "turn ended: cancelled".to_string(),
                    };
                    notices.push((
                        name.clone(),
                        sender,
                        Kind::Notice,
                        body,
                        task.clone(),
                        vec![],
                    ));
                }
            }
        } else if role == Role::Worker && !reported {
            if let Some(sender) = sender.clone() {
                let body = trim_end(&turn_text, MAX_BODY_BYTES);
                notices.push((
                    name.clone(),
                    sender,
                    Kind::Report,
                    body,
                    task.clone(),
                    vec![],
                ));
            }
        }
        let _ = role;

        // Limits.
        let per_task_limit = team.config.max_turns_per_task;
        let total_limit = team.config.max_turns_total;
        let task_count = *team
            .task_turns
            .get(&(name.clone(), task.clone()))
            .unwrap_or(&0);
        let mut task_limit = false;
        if role == Role::Worker && task_count >= per_task_limit {
            if let Some(participant) = team.participants.get_mut(&name) {
                if !participant.paused {
                    participant.paused = true;
                    participant.paused_by_limit = true;
                }
            }
            if team.task_limit_hit.insert((name.clone(), task.clone())) {
                task_limit = true;
            }
        }
        let mut total_hit = false;
        if team.total_turns >= total_limit && !team.total_limit_hit {
            team.total_limit_hit = true;
            total_hit = true;
            for participant in team.participants.values_mut() {
                if !participant.paused {
                    participant.paused = true;
                    participant.paused_by_limit = true;
                }
            }
        }
        let team_id_copy = team.id.clone();
        if task_limit {
            let item = InboxItem {
                id: task_item_id.clone(),
                team: team_id_copy.clone(),
                kind: ItemKind::Limit,
                from: "service".to_string(),
                body: format!("turn limit reached for task {task}"),
                at: now_ms(),
                state: ItemState::Open,
                options: None,
                template: None,
                name: None,
                task: None,
                model: None,
                role: None,
                label: None,
                questions: None,
                agent: None,
                group: None,
                instance: None,
                session: None,
                tool_call: None,
                tool_options: None,
                method: None,
                params: None,
                message_id: None,
                participant: Some(name.clone()),
                scope: Some("task".to_string()),
                limit_task: Some(task.clone()),
                from_instance: None,
                from_session: None,
                leader_instance: None,
                leader_session: None,
                agent_id: None,
            };
            let item_id = item.id.clone();
            team.inbox.push(item);
            self.events
                .push(TeamEvent::Inbox(team_id_copy.clone(), item_id));
        }
        if total_hit {
            let item = InboxItem {
                id: total_item_id.clone(),
                team: team_id_copy.clone(),
                kind: ItemKind::Limit,
                from: "service".to_string(),
                body: format!("total turn limit reached ({})", team.total_turns),
                at: now_ms(),
                state: ItemState::Open,
                options: None,
                template: None,
                name: None,
                task: None,
                model: None,
                role: None,
                label: None,
                questions: None,
                agent: None,
                group: None,
                instance: None,
                session: None,
                tool_call: None,
                tool_options: None,
                method: None,
                params: None,
                message_id: None,
                participant: None,
                scope: Some("total".to_string()),
                limit_task: None,
                from_instance: None,
                from_session: None,
                leader_instance: None,
                leader_session: None,
                agent_id: None,
            };
            let item_id = item.id.clone();
            team.inbox.push(item);
            self.events
                .push(TeamEvent::Inbox(team_id_copy.clone(), item_id));
        }
        self.events.push(TeamEvent::Changed(team_id_copy.clone()));

        if name == "leader" {
            // The leader's prompt ended: later spawns get their own group.
            self.finish_leader_group(&team_id_copy);
        }
        for (from, to, kind, body, task, refs) in notices {
            let _ = self.send_message(&team_id_copy, &from, &to, kind, &body, Some(&task), refs);
        }
        Some(team_id_copy)
    }

    pub fn reset_limits(&mut self, team_id: &str) -> Result<(), TeamError> {
        let team = self
            .teams
            .get_mut(team_id)
            .ok_or_else(|| TeamError::unknown("unknown team"))?;
        if team.closed {
            return Err(TeamError::unknown("team closed"));
        }
        team.task_turns.clear();
        team.task_limit_hit.clear();
        team.total_turns = 0;
        team.total_limit_hit = false;
        for participant in team.participants.values_mut() {
            if participant.paused_by_limit {
                participant.paused = false;
                participant.paused_by_limit = false;
            }
        }
        self.events.push(TeamEvent::Changed(team_id.to_string()));
        Ok(())
    }

    // -- answers -----------------------------------------------------------

    pub fn answer(
        &mut self,
        item_id: &str,
        text: Option<String>,
        option: Option<String>,
        allow: Option<bool>,
    ) -> Result<(AnswerEffect, String), TeamError> {
        self.answer_with(item_id, None, text, option, allow)
    }

    /// `team.answer` with the 19.13 `answers` array.
    pub fn answer_with(
        &mut self,
        item_id: &str,
        answers: Option<Vec<QuestionAnswer>>,
        text: Option<String>,
        option: Option<String>,
        allow: Option<bool>,
    ) -> Result<(AnswerEffect, String), TeamError> {
        let (team_id, position) = self
            .teams
            .iter()
            .find_map(|(id, team)| {
                team.inbox
                    .iter()
                    .position(|item| item.id == item_id)
                    .map(|position| (id.clone(), position))
            })
            .ok_or_else(|| TeamError::new(UNKNOWN_INBOX, "unknown inbox item"))?;
        let item = self.teams[&team_id].inbox[position].clone();
        if item.state != ItemState::Open {
            return Err(TeamError::new(UNKNOWN_INBOX, "inbox item already answered"));
        }
        let team = self.teams.get_mut(&team_id).expect("found above");
        let kind = item.kind.clone();
        if team.suspended
            && !matches!(
                kind,
                ItemKind::Question | ItemKind::Message | ItemKind::Limit | ItemKind::Handover
            )
        {
            return Err(TeamError::not_allowed("team suspended"));
        }
        let from = item.from.clone();
        let item_id = item.id.clone();
        let still_waiting = team.inbox.iter().any(|other| {
            other.id != item_id
                && other.kind == ItemKind::Question
                && other.from == from
                && other.state == ItemState::Open
        });
        let agent_id = item.agent_id.clone();
        let mut refused_spawn: Option<(String, String)> = None;

        let effect = match kind {
            ItemKind::Question => {
                let answer = match answers {
                    Some(answers) => {
                        let questions = item
                            .questions
                            .as_ref()
                            .ok_or_else(|| TeamError::invalid("item has no questions"))?;
                        if answers.len() != questions.len() {
                            return Err(TeamError::invalid(format!(
                                "answers must have {} entries",
                                questions.len()
                            )));
                        }
                        let mut lines = Vec::new();
                        for (question, answer) in questions.iter().zip(answers.iter()) {
                            if !question.multi_select && answer.selected.len() > 1 {
                                return Err(TeamError::invalid(format!(
                                    "{} is not multi-select",
                                    question.header
                                )));
                            }
                            let labels: Vec<&str> = question
                                .options
                                .as_ref()
                                .map(|options| {
                                    options.iter().map(|option| option.label.as_str()).collect()
                                })
                                .unwrap_or_default();
                            for (index, label) in answer.selected.iter().enumerate() {
                                if !labels.contains(&label.as_str()) {
                                    return Err(TeamError::invalid(format!(
                                        "{} has no option {label}",
                                        question.header
                                    )));
                                }
                                if answer.selected[..index].contains(label) {
                                    return Err(TeamError::invalid(format!(
                                        "{} selects {label} twice",
                                        question.header
                                    )));
                                }
                            }
                            let free = answer.text.as_deref().unwrap_or("").trim();
                            if answer.selected.is_empty() && free.is_empty() {
                                return Err(TeamError::invalid(format!(
                                    "{} needs a selected option or text",
                                    question.header
                                )));
                            }
                            let mut line = if answer.selected.is_empty() {
                                format!("{}:", question.header)
                            } else {
                                format!("{}: {}", question.header, answer.selected.join(", "))
                            };
                            if !free.is_empty() {
                                line.push('\n');
                                line.push_str(free);
                            }
                            lines.push(line);
                        }
                        lines.join("\n")
                    }
                    None => {
                        if let Some(questions) = &item.questions {
                            if questions.len() > 1 {
                                return Err(TeamError::invalid(
                                    "answers are required for several questions",
                                ));
                            }
                        }
                        // 18.5 compatibility: `text` wins and is not checked
                        // against the options; `option` is only a selection
                        // when the question has options, else free text.
                        match text {
                            Some(text) => text,
                            None => match option {
                                Some(option) => {
                                    let question = item.questions.as_ref().and_then(|q| q.first());
                                    let has_options = question.is_some_and(|question| {
                                        question
                                            .options
                                            .as_ref()
                                            .is_some_and(|options| !options.is_empty())
                                    });
                                    if has_options {
                                        let known = question
                                            .and_then(|question| question.options.as_ref())
                                            .is_some_and(|options| {
                                                options.iter().any(|entry| entry.label == option)
                                            });
                                        if !known {
                                            return Err(TeamError::invalid(format!(
                                                "the question has no option {option}"
                                            )));
                                        }
                                    }
                                    option
                                }
                                None => String::new(),
                            },
                        }
                    }
                };
                validate_body(&answer)?;
                let answer_message_id = team.next_message();
                if let Some(participant) = team.participants.get_mut(&from) {
                    participant.set_state(if still_waiting {
                        ParticipantState::WaitingHuman
                    } else if participant.bus_turn {
                        ParticipantState::Working
                    } else {
                        ParticipantState::Idle
                    });
                    let message = Message {
                        id: answer_message_id,
                        from: "human".to_string(),
                        to: from.clone(),
                        kind: Kind::Answer,
                        task: "_".to_string(),
                        body: answer,
                        refs: vec![],
                        at: now_ms(),
                    };
                    team.messages.push(message.clone());
                    participant.mailbox.push_front(message);
                }
                AnswerEffect::Question
            }
            ItemKind::Spawn => {
                let allowed = allow.unwrap_or(false);
                let template = item.template.clone().unwrap_or_default();
                let name = item.name.clone().unwrap_or_default();
                let task = item.task.clone();
                let model = item.model.clone();
                let role = item.role.clone();
                if allowed {
                    if team.live_workers() as u64 >= team.config.max_workers {
                        team.reserved_names.remove(&name);
                        refused_spawn = Some((name, "refused: worker limit".to_string()));
                        AnswerEffect::Ack
                    } else {
                        let lifecycle = team.pending_lifecycles.remove(&name).unwrap_or_default();
                        spawn_participant(
                            team,
                            &name,
                            &template,
                            model.as_deref(),
                            role.as_deref(),
                            task.as_deref(),
                            item.label.as_deref(),
                            lifecycle,
                        )?;
                        team.order.push(name.clone());
                        AnswerEffect::Spawn(SpawnRequest {
                            team: team_id.clone(),
                            name,
                            template,
                            model,
                            role,
                            task,
                            lifecycle,
                        })
                    }
                } else {
                    team.reserved_names.remove(&name);
                    refused_spawn = Some((name, "refused".to_string()));
                    AnswerEffect::Ack
                }
            }
            ItemKind::Permission => {
                let outcome = match option {
                    Some(option) => {
                        json!({ "outcome": { "outcome": "selected", "optionId": option } })
                    }
                    None => json!({ "outcome": { "outcome": "cancelled" } }),
                };
                AnswerEffect::Permission {
                    instance: item.instance.clone().unwrap_or_default(),
                    agent_id: agent_id.ok_or_else(|| TeamError::unknown("no pending request"))?,
                    response: outcome,
                }
            }
            ItemKind::Request => {
                let text = text.ok_or_else(|| TeamError::invalid("text is required"))?;
                let result: Value = serde_json::from_str(&text)
                    .map_err(|_| TeamError::invalid("text must be a JSON result"))?;
                AnswerEffect::Request {
                    instance: item.instance.clone().unwrap_or_default(),
                    agent_id: agent_id
                        .clone()
                        .ok_or_else(|| TeamError::unknown("no pending request"))?,
                    result,
                }
            }
            ItemKind::Message | ItemKind::Limit => AnswerEffect::Ack,
            ItemKind::Handover => {
                let picked = option.or_else(|| text.filter(|text| !text.is_empty()));
                match picked.as_deref() {
                    Some("move") | Some("refuse") => {}
                    _ => return Err(TeamError::invalid("answer move or refuse")),
                }
                AnswerEffect::Handover {
                    team: team_id.clone(),
                    instance: item.from_instance.clone().unwrap_or_default(),
                    session: item.from_session.clone().unwrap_or_default(),
                    hand_over: picked.as_deref() == Some("move"),
                }
            }
        };
        team.inbox[position].state = ItemState::Answered;
        if matches!(kind, ItemKind::Permission | ItemKind::Request) {
            let still_waiting = team.inbox.iter().any(|other| {
                other.id != item_id
                    && other.state == ItemState::Open
                    && other.from == from
                    && matches!(
                        other.kind,
                        ItemKind::Question | ItemKind::Permission | ItemKind::Request
                    )
            });
            if let Some(participant) = team.participants.get_mut(&from) {
                if participant.state == ParticipantState::WaitingHuman && !still_waiting {
                    participant.set_state(if participant.bus_turn {
                        ParticipantState::Working
                    } else {
                        ParticipantState::Idle
                    });
                }
            }
        }
        team.pending_items.retain(|_, pending| pending != &item_id);
        self.events.push(TeamEvent::Inbox(team_id.clone(), item_id));
        self.events.push(TeamEvent::Changed(team_id.clone()));
        if let Some((name, reason)) = refused_spawn {
            self.clear_owners_after_spawn(&team_id, &name, &reason, true);
        }
        Ok((effect, team_id))
    }

    /// `team.answer_group {group, allow}` (19.6): answer every open item of
    /// the group as `team.answer` would, in creation order. An item that fails
    /// stays open and is returned in the failed list; the others take effect.
    pub fn answer_group(
        &mut self,
        group: &str,
        allow: Option<bool>,
    ) -> Result<(GroupAnswers, GroupFailures), TeamError> {
        let ids: Vec<String> = self
            .teams
            .values()
            .flat_map(|team| team.inbox.iter())
            .filter(|item| item.state == ItemState::Open && item.group.as_deref() == Some(group))
            .map(|item| item.id.clone())
            .collect();
        if ids.is_empty() {
            return Err(TeamError::new(
                UNKNOWN_INBOX,
                "no open inbox item in that group",
            ));
        }
        // Not atomic on purpose: an item that cannot be answered is skipped so
        // the effects of the items already answered are never lost (their
        // workers would stay in `starting` forever). The skipped items stay
        // open and are reported in `failed`.
        let mut answered = Vec::new();
        let mut failed = Vec::new();
        for id in ids {
            match self.answer(&id, None, None, allow) {
                Ok((effect, _)) => answered.push((id, effect)),
                Err(error) => failed.push((id, error)),
            }
        }
        if answered.is_empty() {
            if let Some((_, error)) = failed.first() {
                return Err(error.clone());
            }
        }
        Ok((answered, failed))
    }

    pub fn mark_item_answered_by_instance(
        &mut self,
        instance: &str,
        id_key: &str,
    ) -> Option<String> {
        for team in self.teams.values_mut() {
            if let Some(item_id) = team
                .pending_items
                .remove(&(instance.to_string(), id_key.to_string()))
            {
                if let Some(item) = team.inbox.iter_mut().find(|item| item.id == item_id) {
                    if item.state == ItemState::Open {
                        item.state = ItemState::Answered;
                        let team_id = team.id.clone();
                        self.events
                            .push(TeamEvent::Inbox(team_id.clone(), item_id.clone()));
                        self.events.push(TeamEvent::Changed(team_id));
                    }
                }
                return Some(item_id);
            }
        }
        None
    }

    /// Create the `handover` item of a session that asked for a team led by
    /// another chat (20.4).
    pub fn create_handover(&mut self, team_id: &str, instance: &str, session: &str) -> String {
        let leader = self
            .teams
            .get(team_id)
            .map(|team| (team.leader_instance.clone(), team.leader_session.clone()))
            .unwrap_or((None, None));
        let id = self.next_inbox_id();
        let item = InboxItem {
            id: id.clone(),
            team: team_id.to_string(),
            kind: ItemKind::Handover,
            from: "human".to_string(),
            body: "the team is led by another chat; hand it over?".to_string(),
            at: now_ms(),
            state: ItemState::Open,
            options: Some(vec!["move".to_string(), "refuse".to_string()]),
            template: None,
            name: None,
            task: None,
            model: None,
            role: None,
            label: None,
            questions: None,
            agent: None,
            group: None,
            instance: None,
            session: None,
            tool_call: None,
            tool_options: None,
            method: None,
            params: None,
            message_id: None,
            participant: None,
            scope: None,
            limit_task: None,
            from_instance: Some(instance.to_string()),
            from_session: Some(session.to_string()),
            leader_instance: leader.0,
            leader_session: leader.1,
            agent_id: None,
        };
        self.add_inbox_item(team_id, item);
        id
    }

    pub fn add_inbox_item(&mut self, team_id: &str, item: InboxItem) -> Option<String> {
        let team = self.teams.get_mut(team_id)?;
        let id = item.id.clone();
        team.inbox.push(item);
        self.events
            .push(TeamEvent::Inbox(team_id.to_string(), id.clone()));
        Some(id)
    }

    // -- watchers and participant exits -----------------------------------

    pub fn watch(
        &mut self,
        team_id: &str,
        participant: &str,
        conn: u64,
    ) -> Result<(String, String), TeamError> {
        let team = self
            .teams
            .get(team_id)
            .ok_or_else(|| TeamError::unknown("unknown team"))?;
        let Some(worker) = team.participants.get(participant) else {
            return Err(TeamError::unknown("unknown participant"));
        };
        if worker.role != Role::Worker {
            return Err(TeamError::not_allowed("only workers can be watched"));
        }
        let Some(instance) = worker.instance.clone() else {
            return Err(TeamError::unknown("participant has no instance"));
        };
        let Some(session) = worker.session.clone() else {
            return Err(TeamError::unknown("participant has no session"));
        };
        let team = self.teams.get_mut(team_id).expect("checked above");
        let watchers = team.watchers.entry(participant.to_string()).or_default();
        if !watchers.contains(&conn) {
            watchers.push(conn);
        }
        Ok((instance, session))
    }

    pub fn unwatch(
        &mut self,
        team_id: &str,
        participant: &str,
        conn: u64,
    ) -> Result<(), TeamError> {
        let team = self
            .teams
            .get_mut(team_id)
            .ok_or_else(|| TeamError::unknown("unknown team"))?;
        if let Some(watchers) = team.watchers.get_mut(participant) {
            watchers.retain(|entry| *entry != conn);
        }
        Ok(())
    }

    pub fn forget_connection(&mut self, conn: u64) {
        for team in self.teams.values_mut() {
            for watchers in team.watchers.values_mut() {
                watchers.retain(|entry| *entry != conn);
            }
        }
    }

    pub fn watches(&self, conn: u64, instance: &str) -> bool {
        self.teams.values().any(|team| {
            team.watchers.iter().any(|(name, watchers)| {
                watchers.contains(&conn)
                    && team
                        .participants
                        .get(name)
                        .and_then(|participant| participant.instance.as_deref())
                        == Some(instance)
            })
        })
    }

    pub fn watcher_conns(&self, instance: &str) -> Vec<u64> {
        let Some((team_id, name)) = self.by_instance.get(instance) else {
            return Vec::new();
        };
        self.teams
            .get(team_id)
            .and_then(|team| team.watchers.get(name))
            .cloned()
            .unwrap_or_default()
    }

    pub fn participant_instance(&self, team_id: &str, name: &str) -> Option<String> {
        self.teams
            .get(team_id)?
            .participants
            .get(name)?
            .instance
            .clone()
    }

    pub fn worker_exited(&mut self, instance: &str, reason: &str) {
        let Some(team) = self
            .teams
            .values_mut()
            .find(|team| team.is_worker_instance(instance).is_some())
        else {
            return;
        };
        let Some(name) = team.is_worker_instance(instance).map(str::to_string) else {
            return;
        };
        let Some(participant) = team.participants.get_mut(&name) else {
            return;
        };
        self.by_instance.remove(instance);
        // The start (if any) is over: no callback will come for it again.
        participant.starting = false;
        if participant.state == ParticipantState::Exited {
            // A `stop_worker remove: true` waits for the real exit (20.6).
            if participant.remove_after_exit {
                let id = team.id.clone();
                self.finish_worker_removal(&id, &name);
            }
            return;
        }
        participant.set_state(ParticipantState::Exited);
        participant.reason = Some(reason.to_string());
        participant.bus_turn = false;
        participant.mailbox.clear();
        let task = participant.task.clone();
        let sender = participant.task_sender.clone();
        let closed = team.closed;
        for item in &mut team.inbox {
            if item.state == ItemState::Open && item.from == name {
                item.state = ItemState::Orphaned;
                let team_id = team.id.clone();
                self.events.push(TeamEvent::Inbox(team_id, item.id.clone()));
            }
        }
        let team_id = team.id.clone();
        if !closed {
            let notice = format!("worker {name} exited: {reason}");
            let _ = self.send_message(
                &team_id,
                &name,
                "leader",
                Kind::Notice,
                &notice,
                Some(&task),
                vec![task.clone()],
            );
            if let Some(sender) = sender {
                if sender != "leader" {
                    let _ = self.send_message(
                        &team_id,
                        &name,
                        &sender,
                        Kind::Notice,
                        &notice,
                        Some(&task),
                        vec![task.clone()],
                    );
                }
            }
        }
        let remove = self
            .teams
            .values()
            .find(|team| team.is_worker_instance(instance).is_some())
            .and_then(|team| team.participants.get(&name))
            .is_some_and(|participant| participant.remove_after_exit);
        if remove {
            self.finish_worker_removal(&team_id, &name);
        }
        self.revoke_instance_unbound(instance);
        let ids: Vec<String> = self
            .token_records
            .iter()
            .filter(|(_, record)| record.instance.as_deref() == Some(instance))
            .map(|(id, _)| id.clone())
            .collect();
        for id in ids {
            self.revoke(&id);
        }
        self.events.push(TeamEvent::Changed(team_id));
    }

    /// `team.stop_worker` (20.6): stop one worker, optionally dropping it from
    /// the team after it exited. Returns the instance to stop.
    /// `team.stop_worker` (20.6). Liveness comes from the caller's instance
    /// table and the pending start it owns, never from the UI state (20.6/#7).
    pub fn stop_worker(
        &mut self,
        team_id: &str,
        name: &str,
        remove: bool,
        notify_leader: bool,
        live: bool,
        start_pending: bool,
    ) -> Result<StopOutcome, TeamError> {
        let Some(team) = self.teams.get_mut(team_id) else {
            return Err(TeamError::unknown("unknown team"));
        };
        if name == "leader" || name == "human" {
            return Err(TeamError::invalid(format!("{name} is not a worker")));
        }
        let Some(participant) = team.participants.get_mut(name) else {
            return Err(TeamError::unknown("unknown participant"));
        };
        if participant.role != Role::Worker {
            return Err(TeamError::invalid(format!("{name} is not a worker")));
        }
        let instance = participant.instance.clone();
        let lifecycle = participant.lifecycle;
        let stopping_instance = live.then(|| instance.clone()).flatten();
        let closed = team.closed;
        if participant.state != ParticipantState::Exited {
            participant.set_state(ParticipantState::Exited);
            participant.reason = Some("stopped".to_string());
            participant.bus_turn = false;
            participant.mailbox.clear();
            for item in &mut team.inbox {
                if item.state == ItemState::Open && item.from == name {
                    item.state = ItemState::Orphaned;
                    self.events
                        .push(TeamEvent::Inbox(team_id.to_string(), item.id.clone()));
                }
            }
        }
        participant.remove_after_exit = remove;
        // A participant with no live instance and no start in flight has already
        // exited: the removal is complete right away (20.6). A start that is
        // still running completes it through its callback.
        let alive = stopping_instance.is_some() || start_pending;
        let drop_now = remove && !alive;
        if drop_now {
            team.participants.remove(name);
            team.order.retain(|entry| entry != name);
            team.reserved_names.remove(name);
            team.pending_lifecycles.remove(name);
        }
        if let Some(instance) = &instance {
            let ids: Vec<String> = self
                .token_records
                .iter()
                .filter(|(_, record)| record.instance.as_deref() == Some(instance))
                .map(|(id, _)| id.clone())
                .collect();
            for id in ids {
                self.revoke(&id);
            }
        }
        if !closed && notify_leader {
            let _ = self.send_message(
                team_id,
                "human",
                "leader",
                Kind::Notice,
                &format!("worker {name} stopped by the person"),
                None,
                vec![],
            );
        }
        self.events.push(TeamEvent::Changed(team_id.to_string()));
        Ok(StopOutcome {
            instance: stopping_instance,
            lifecycle,
            remove,
            start_pending,
        })
    }

    pub fn leader_exited(&mut self, instance: &str, reason: &str) {
        let Some(team) = self
            .teams
            .values_mut()
            .find(|team| team.leader_instance.as_deref() == Some(instance))
        else {
            self.revoke_instance_unbound(instance);
            return;
        };
        team.leaderless = true;
        if let Some(leader) = team.participants.get_mut("leader") {
            leader.set_state(ParticipantState::Exited);
            leader.reason = Some(reason.to_string());
        }
        team.current_group = None;
        let team_id = team.id.clone();
        self.by_instance.remove(instance);
        self.revoke_instance_unbound(instance);
        let mut orphaned_spawns = Vec::new();
        if let Some(leader) = self.teams.get_mut(&team_id) {
            let items: Vec<String> = leader
                .inbox
                .iter()
                .filter(|item| item.state == ItemState::Open && item.from == "leader")
                .map(|item| item.id.clone())
                .collect();
            orphaned_spawns = leader
                .inbox
                .iter()
                .filter(|item| items.contains(&item.id) && item.kind == ItemKind::Spawn)
                .filter_map(|item| item.name.clone())
                .collect();
            for item in &mut leader.inbox {
                if items.contains(&item.id) {
                    item.state = ItemState::Orphaned;
                }
            }
            for name in &orphaned_spawns {
                leader.reserved_names.remove(name);
            }
            for id in items {
                self.events.push(TeamEvent::Inbox(team_id.clone(), id));
            }
        }
        for name in orphaned_spawns {
            self.clear_owners_after_spawn(&team_id, &name, "orphaned", true);
        }
        self.events.push(TeamEvent::Changed(team_id));
    }

    pub fn leader_session_closed(&mut self, instance: &str, session: &str) {
        let Some(team) = self.teams.values_mut().find(|team| {
            team.leader_instance.as_deref() == Some(instance)
                && team.leader_session.as_deref() == Some(session)
        }) else {
            return;
        };
        team.leaderless = true;
        if let Some(leader) = team.participants.get_mut("leader") {
            leader.set_state(ParticipantState::Exited);
            leader.reason = Some("session closed".to_string());
        }
        team.current_group = None;
        let team_id = team.id.clone();
        let orphaned: Vec<String> = team
            .inbox
            .iter()
            .filter(|item| item.state == ItemState::Open && item.from == "leader")
            .map(|item| item.id.clone())
            .collect();
        let orphaned_spawns: Vec<String> = team
            .inbox
            .iter()
            .filter(|item| orphaned.contains(&item.id) && item.kind == ItemKind::Spawn)
            .filter_map(|item| item.name.clone())
            .collect();
        for item in &mut team.inbox {
            if orphaned.contains(&item.id) {
                item.state = ItemState::Orphaned;
            }
        }
        for name in &orphaned_spawns {
            team.reserved_names.remove(name);
        }
        for item in orphaned {
            self.events.push(TeamEvent::Inbox(team_id.clone(), item));
        }
        for name in orphaned_spawns {
            self.clear_owners_after_spawn(&team_id, &name, "orphaned", true);
        }
        self.revoke_instance_tokens(instance);
        self.events.push(TeamEvent::Changed(team_id));
    }

    pub fn revoke_instance_tokens(&mut self, instance: &str) {
        let ids: Vec<String> = self
            .token_records
            .iter()
            .filter(|(_, record)| record.instance.as_deref() == Some(instance))
            .map(|(id, _)| id.clone())
            .collect();
        for id in ids {
            self.revoke(&id);
        }
    }

    pub fn token_role(&self, token_id: &str) -> Option<(Role, Option<String>, Option<String>)> {
        self.role_for_token(token_id)
    }

    pub fn team_id_of_cwd(&self, cwd: &str) -> Option<String> {
        self.by_cwd.get(cwd).cloned()
    }
}

fn spawn_name(
    team: &Team,
    template: &str,
    name: Option<&str>,
    task: Option<&str>,
) -> Result<String, TeamError> {
    if !team.config.templates.contains_key(template) {
        return Err(TeamError::not_allowed("unknown template"));
    }
    if team.live_workers() as u64 >= team.config.max_workers {
        return Err(TeamError::not_allowed("worker limit reached"));
    }
    if let Some(task) = task {
        validate_body(task)?;
    }
    match name {
        Some(name) => {
            validate_name(name)?;
            if name == "leader" || name == "human" {
                return Err(TeamError::invalid("that name is reserved"));
            }
            if team.participants.contains_key(name) || team.reserved_names.contains(name) {
                return Err(TeamError::invalid("name is already in use"));
            }
            Ok(name.to_string())
        }
        None => Ok(lowest_free_name(team)),
    }
}

/// Validate a spawn's model and role against its template (19.6).
fn validate_spawn_choice(
    team: &Team,
    template: &str,
    model: Option<&str>,
    role: Option<&str>,
) -> Result<(), TeamError> {
    let Some(config) = team.config.templates.get(template) else {
        return Err(TeamError::not_allowed("unknown template"));
    };
    if let Some(model) = model {
        if !config.models.is_empty() && !config.models.iter().any(|allowed| allowed == model) {
            return Err(TeamError::invalid(format!(
                "model {model} is not allowed by template {template}"
            )));
        }
    }
    if role.is_some_and(|role| role.len() > MAX_ROLE_BYTES) {
        return Err(TeamError::invalid("role is longer than 16 KiB"));
    }
    Ok(())
}

#[allow(clippy::too_many_arguments)]
fn spawn_participant(
    team: &mut Team,
    name: &str,
    template: &str,
    model: Option<&str>,
    role: Option<&str>,
    task: Option<&str>,
    label: Option<&str>,
    lifecycle: u64,
) -> Result<(), TeamError> {
    validate_spawn_choice(team, template, model, role)?;
    let config = team
        .config
        .templates
        .get(template)
        .ok_or_else(|| TeamError::not_allowed("unknown template"))?;
    let mut participant = Participant::new(name, Role::Worker);
    participant.lifecycle = lifecycle;
    participant.template = Some(template.to_string());
    participant.role_card = Some(brief::role_card(
        name,
        &team.id,
        &config.role,
        role.unwrap_or(""),
        config.tool_style,
    ));
    participant.model = model.map(str::to_string).or_else(|| config.model.clone());
    participant.spawn_role = role.map(str::to_string);
    participant.agent = Some(config.key.agent.clone());
    participant.label = label.map(str::to_string);
    participant.first_prompt = true;
    participant.starting = true;
    if let Some(task) = task {
        validate_body(task)?;
        let id = team.next_message();
        let message = Message {
            id,
            from: "leader".to_string(),
            to: name.to_string(),
            kind: Kind::Task,
            task: "_".to_string(),
            body: task.to_string(),
            refs: Vec::new(),
            at: now_ms(),
        };
        team.messages.push(message.clone());
        participant.mailbox.push_back(message);
    }
    team.participants.insert(name.to_string(), participant);
    team.reserved_names.remove(name);
    Ok(())
}

fn lowest_free_name(team: &Team) -> String {
    let mut n = 1u64;
    loop {
        let name = format!("w{n}");
        if !team.participants.contains_key(&name) && !team.reserved_names.contains(&name) {
            return name;
        }
        n += 1;
    }
}

pub fn format_message(message: &Message) -> String {
    let mut attrs = format!(
        "from=\"{}\" kind=\"{}\"",
        message.from,
        message.kind.as_str()
    );
    if message.task != "_" {
        attrs.push_str(&format!(" task=\"{}\"", message.task));
    }
    let mut inner = escape_text(&message.body);
    for reference in &message.refs {
        inner.push_str(&format!("<ref>{}</ref>", escape_text(reference)));
    }
    format!("<bus {attrs}>{inner}</bus>")
}

pub fn escape_text(text: &str) -> String {
    text.replace('&', "&amp;").replace('<', "&lt;")
}

fn trim_end(text: &str, limit: usize) -> String {
    if text.len() <= limit {
        return text.to_string();
    }
    let mut start = text.len() - limit;
    while start < text.len() && !text.is_char_boundary(start) {
        start += 1;
    }
    text[start..].to_string()
}

pub fn now_ms() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|elapsed| elapsed.as_millis() as u64)
        .unwrap_or(0)
}

/// "One line": no control characters and no Unicode line separators.
pub(crate) fn is_one_line(text: &str) -> bool {
    !text
        .chars()
        .any(|ch| ch.is_control() || ch == '\u{2028}' || ch == '\u{2029}')
}

/// A display label for a participant (19.12): 1..16 characters, one line.
pub fn validate_label(label: &str) -> Result<(), TeamError> {
    if label.is_empty() || label.chars().count() > 16 || !is_one_line(label) {
        return Err(TeamError::invalid(
            "label must be one line of 1..16 characters",
        ));
    }
    Ok(())
}

fn only_keys(
    object: &serde_json::Map<String, Value>,
    allowed: &[&str],
    what: &str,
) -> Result<(), TeamError> {
    for key in object.keys() {
        if !allowed.contains(&key.as_str()) {
            return Err(TeamError::invalid(format!(
                "{what} has unknown field {key}"
            )));
        }
    }
    Ok(())
}

fn question_string(
    object: &serde_json::Map<String, Value>,
    key: &str,
    what: &str,
) -> Result<String, TeamError> {
    object
        .get(key)
        .and_then(Value::as_str)
        .map(str::to_string)
        .ok_or_else(|| TeamError::invalid(format!("{what}.{key} must be a string")))
}

/// Parse the 19.13 `questions` array.
pub fn parse_questions(value: &Value) -> Result<Vec<Question>, TeamError> {
    let items = value
        .as_array()
        .ok_or_else(|| TeamError::invalid("questions must be an array"))?;
    if items.is_empty() || items.len() > 4 {
        return Err(TeamError::invalid("questions must have 1..4 entries"));
    }
    let mut questions = Vec::new();
    for (index, item) in items.iter().enumerate() {
        let what = format!("questions[{index}]");
        let object = item
            .as_object()
            .ok_or_else(|| TeamError::invalid(format!("{what} must be an object")))?;
        only_keys(
            object,
            &["header", "question", "options", "multi_select"],
            &what,
        )?;
        let header = question_string(object, "header", &what)?;
        if header.is_empty() || header.chars().count() > 12 || !is_one_line(&header) {
            return Err(TeamError::invalid(format!(
                "{what}.header must be one line of 1..12 characters"
            )));
        }
        let question = question_string(object, "question", &what)?;
        if question.is_empty() || question.len() > 4 * 1024 {
            return Err(TeamError::invalid(format!(
                "{what}.question is longer than 4 KiB"
            )));
        }
        let multi_select = match object.get("multi_select") {
            None | Some(Value::Null) => false,
            Some(Value::Bool(value)) => *value,
            Some(_) => {
                return Err(TeamError::invalid(format!(
                    "{what}.multi_select must be a boolean"
                )))
            }
        };
        let options = match object.get("options") {
            None | Some(Value::Null) => None,
            Some(Value::Array(options)) => {
                if !options.is_empty() && !(2..=6).contains(&options.len()) {
                    return Err(TeamError::invalid(format!(
                        "{what}.options must have 0 or 2..6 entries"
                    )));
                }
                let mut parsed = Vec::new();
                for (option_index, option) in options.iter().enumerate() {
                    let at = format!("{what}.options[{option_index}]");
                    let object = option
                        .as_object()
                        .ok_or_else(|| TeamError::invalid(format!("{at} must be an object")))?;
                    only_keys(object, &["label", "description"], &at)?;
                    let label = question_string(object, "label", &at)?;
                    if label.is_empty()
                        || label.chars().count() > 60
                        || !is_one_line(&label)
                        || label.contains(", ")
                    {
                        return Err(TeamError::invalid(format!(
                            "{at}.label must be one line of 1..60 characters without ', '"
                        )));
                    }
                    if parsed
                        .iter()
                        .any(|option: &QuestionOption| option.label == label)
                    {
                        return Err(TeamError::invalid(format!(
                            "{at}.label {label} is already used"
                        )));
                    }
                    let description = match object.get("description") {
                        None | Some(Value::Null) => None,
                        Some(Value::String(text)) if text.chars().count() <= 200 => {
                            Some(text.clone())
                        }
                        Some(Value::String(_)) => {
                            return Err(TeamError::invalid(format!(
                                "{at}.description is longer than 200 characters"
                            )))
                        }
                        Some(_) => {
                            return Err(TeamError::invalid(format!(
                                "{at}.description must be a string"
                            )))
                        }
                    };
                    parsed.push(QuestionOption { label, description });
                }
                Some(parsed)
            }
            Some(_) => {
                return Err(TeamError::invalid(format!(
                    "{what}.options must be an array"
                )))
            }
        };
        questions.push(Question {
            header,
            question,
            options,
            multi_select,
        });
    }
    Ok(questions)
}

/// Parse `team.answer.answers` (19.13).
pub fn parse_answers(value: &Value) -> Result<Vec<QuestionAnswer>, TeamError> {
    let items = value
        .as_array()
        .ok_or_else(|| TeamError::invalid("answers must be an array"))?;
    let mut answers = Vec::new();
    for (index, item) in items.iter().enumerate() {
        let what = format!("answers[{index}]");
        let object = item
            .as_object()
            .ok_or_else(|| TeamError::invalid(format!("{what} must be an object")))?;
        only_keys(object, &["selected", "text"], &what)?;
        let selected = match object.get("selected") {
            None | Some(Value::Null) => Vec::new(),
            Some(Value::Array(values)) => {
                let mut labels = Vec::new();
                for value in values {
                    let Some(label) = value.as_str() else {
                        return Err(TeamError::invalid(format!(
                            "{what}.selected must be strings"
                        )));
                    };
                    if labels.iter().any(|known: &String| known == label) {
                        return Err(TeamError::invalid(format!(
                            "{what}.selected {label} is already used"
                        )));
                    }
                    labels.push(label.to_string());
                }
                labels
            }
            Some(_) => {
                return Err(TeamError::invalid(format!(
                    "{what}.selected must be an array"
                )))
            }
        };
        let text = match object.get("text") {
            None | Some(Value::Null) => None,
            Some(Value::String(text)) => Some(text.clone()),
            Some(_) => return Err(TeamError::invalid(format!("{what}.text must be a string"))),
        };
        answers.push(QuestionAnswer { selected, text });
    }
    Ok(answers)
}

fn team_entry(team: &Team) -> Value {
    let participants: Vec<Value> = team
        .order
        .iter()
        .filter_map(|name| team.participants.get(name))
        .map(|participant| {
            let task_count = *team
                .task_turns
                .get(&(participant.name.clone(), participant.task.clone()))
                .unwrap_or(&0);
            let template = participant
                .template
                .as_ref()
                .and_then(|name| team.config.templates.get(name));
            let agent = participant
                .agent
                .clone()
                .or_else(|| template.map(|template| template.key.agent.clone()));
            let model = participant
                .model
                .clone()
                .or_else(|| template.and_then(|template| template.model.clone()));
            let label = participant
                .label
                .clone()
                .or_else(|| participant.template.clone())
                .unwrap_or_else(|| "leader".to_string());
            let mut out = json!({
                "name": participant.name,
                "role": participant.role.as_str(),
                "state": participant.state.as_str(),
                "instance": participant.instance,
                "sessionId": participant.session,
                "task": participant.task,
                "queued": participant.queued(),
                "paused": participant.paused,
                "turns": { "task": task_count, "total": participant.turns_total },
                "activity": participant.activity,
                "state_since": participant.state_since,
                "agent": agent,
                "model": model,
                "label": label,
            });
            // 19.12: `template` is absent for the leader, not null.
            if let Some(template) = &participant.template {
                out["template"] = json!(template);
            }
            if let Some(reason) = &participant.reason {
                out["reason"] = json!(reason);
            }
            if let Some(worktree) = &participant.worktree {
                out["worktree"] = json!({
                    "path": worktree.path,
                    "branch": worktree.branch,
                });
            }
            out
        })
        .collect();
    let inbox: Vec<Value> = team.inbox.iter().map(InboxItem::to_json).collect();
    let leader = if team.leaderless {
        Value::Null
    } else {
        json!({
            "instance": team.leader_instance,
            "sessionId": team.leader_session,
        })
    };
    let mut entry = json!({
        "id": team.id,
        "cwd": team.cwd,
        "state": if team.suspended {
            "suspended"
        } else if team.leaderless {
            "leaderless"
        } else {
            "active"
        },
        "leader": leader,
        "participants": participants,
        "inbox": inbox,
        "limits": {
            "max_turns_per_task": team.config.max_turns_per_task,
            "max_turns_total": team.config.max_turns_total,
            "turns_total": team.total_turns,
        },
        "board_rev": team.board.rev,
        "workflow_name": team.board.workflow_name,
        "stages": team.board.stages(),
    });
    if let Some(at) = team.suspended_at {
        entry["suspended_at"] = json!(at);
    }
    entry
}

// -- persistence (PROTOCOL.md 18.15) ---------------------------------------

#[derive(Debug, Clone, Default, Serialize, Deserialize)]
#[serde(default)]
struct TemplateSnapshot {
    model: Option<String>,
    role: String,
    worktree: bool,
    models: Vec<String>,
    tool_style: ToolStyle,
}

impl Serialize for ToolStyle {
    fn serialize<S: serde::Serializer>(&self, serializer: S) -> Result<S::Ok, S::Error> {
        serializer.serialize_str(match self {
            Self::Direct => "direct",
            Self::McpProxy => "mcp_proxy",
        })
    }
}

impl<'de> Deserialize<'de> for ToolStyle {
    fn deserialize<D: serde::Deserializer<'de>>(deserializer: D) -> Result<Self, D::Error> {
        let value = String::deserialize(deserializer)?;
        Ok(Self::parse(&value).unwrap_or_default())
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(default)]
struct ConfigSnapshot {
    max_workers: u64,
    spawn_auto: Vec<String>,
    max_turns_per_task: u64,
    max_turns_total: u64,
    worktree_root: Option<String>,
    #[serde(default = "default_true")]
    enabled: bool,
    #[serde(default = "default_true")]
    session_default: bool,
    #[serde(default)]
    builtin_worker: bool,
    templates: BTreeMap<String, TemplateSnapshot>,
    workflows: BTreeMap<String, workflow::Workflow>,
    default_workflow: Option<String>,
}

#[derive(Debug, Default, Serialize, Deserialize)]
#[serde(default)]
struct TeamSnapshot {
    id: String,
    cwd: String,
    created_at: u64,
    suspended_at: Option<u64>,
    config: ConfigSnapshot,
    leader_instance: Option<String>,
    leader_session: Option<String>,
    participants: Vec<Participant>,
    messages: Vec<Message>,
    inbox: Vec<InboxItem>,
    next_message: u64,
    task_turns: Vec<(String, String, u64)>,
    total_turns: u64,
    order: Vec<String>,
    reserved_names: Vec<String>,
}

fn default_true() -> bool {
    true
}

impl Default for ConfigSnapshot {
    fn default() -> Self {
        Self {
            max_workers: 3,
            spawn_auto: Vec::new(),
            max_turns_per_task: 30,
            max_turns_total: 200,
            worktree_root: None,
            enabled: true,
            session_default: true,
            builtin_worker: false,
            templates: BTreeMap::new(),
            workflows: BTreeMap::new(),
            default_workflow: None,
        }
    }
}

impl Team {
    fn snapshot(&self) -> String {
        let templates: BTreeMap<String, TemplateSnapshot> = self
            .config
            .templates
            .iter()
            .map(|(name, template)| {
                (
                    name.clone(),
                    TemplateSnapshot {
                        model: template.model.clone(),
                        role: template.role.clone(),
                        worktree: template.worktree,
                        models: template.models.clone(),
                        tool_style: template.tool_style,
                    },
                )
            })
            .collect();
        let messages: Vec<Message> = self
            .messages
            .iter()
            .rev()
            .take(200)
            .rev()
            .cloned()
            .collect();
        let inbox: Vec<InboxItem> = self
            .inbox
            .iter()
            .filter(|item| item.state == ItemState::Open)
            .cloned()
            .map(|mut item| {
                if matches!(item.kind, ItemKind::Permission | ItemKind::Request) {
                    // These are always orphaned after a restart; the agent
                    // request they refer to no longer exists, so its payload
                    // does not belong on disk.
                    item.tool_call = None;
                    item.tool_options = None;
                    item.method = None;
                    item.params = None;
                    item.agent_id = None;
                    item.instance = None;
                    item.session = None;
                }
                item
            })
            .collect();
        let snapshot = TeamSnapshot {
            id: self.id.clone(),
            cwd: self.cwd.clone(),
            created_at: self.created_at,
            suspended_at: self.suspended_at,
            config: ConfigSnapshot {
                max_workers: self.config.max_workers,
                spawn_auto: self.config.spawn_auto.iter().cloned().collect(),
                max_turns_per_task: self.config.max_turns_per_task,
                max_turns_total: self.config.max_turns_total,
                worktree_root: self.config.worktree_root.clone(),
                enabled: self.config.enabled,
                session_default: self.config.session_default,
                builtin_worker: self.config.builtin_worker,
                templates,
                workflows: self
                    .config
                    .workflows
                    .iter()
                    .map(|(name, workflow)| (name.clone(), workflow.clone()))
                    .collect(),
                default_workflow: self.config.default_workflow.clone(),
            },
            leader_instance: self.leader_instance.clone(),
            leader_session: self.leader_session.clone(),
            participants: self
                .order
                .iter()
                .filter_map(|name| self.participants.get(name))
                .cloned()
                .collect(),
            messages,
            inbox,
            next_message: self.next_message,
            task_turns: self
                .task_turns
                .iter()
                .map(|((name, task), count)| (name.clone(), task.clone(), *count))
                .collect(),
            total_turns: self.total_turns,
            order: self.order.clone(),
            reserved_names: self.reserved_names.iter().cloned().collect(),
        };
        serde_json::to_string(&snapshot).unwrap_or_else(|_| "{}".to_string())
    }
}

impl Teams {
    pub fn team_ids(&self) -> Vec<String> {
        self.teams.keys().cloned().collect()
    }

    pub fn snapshot_team(&self, id: &str) -> Option<String> {
        self.teams.get(id).map(Team::snapshot)
    }

    pub fn counters(&self) -> (u64, u64) {
        (self.next_team, self.next_inbox)
    }

    /// Load stored teams after a service restart. Returns the ids that are
    /// stored again as suspended (their `suspended_at` may have been set now)
    /// and the ids that expired and must be deleted.
    pub fn restore(
        &mut self,
        rows: Vec<(String, String)>,
        max_team: u64,
        max_inbox: u64,
        now: u64,
        expiry_ms: Option<u64>,
    ) -> (Vec<String>, Vec<String>) {
        let mut stored = Vec::new();
        let mut expired = Vec::new();
        let mut highest_team = max_team;
        let mut highest_inbox = max_inbox;
        let mut highest_group = 0u64;
        for (id, json) in rows {
            let mut snapshot: TeamSnapshot = match serde_json::from_str(&json) {
                Ok(snapshot) => snapshot,
                Err(error) => {
                    crate::svc_log!("nvim_ade_server: deleting an unreadable team {id}: {error}");
                    expired.push(id);
                    continue;
                }
            };
            if snapshot.id.is_empty() {
                snapshot.id = id.clone();
            }
            if snapshot.cwd.is_empty() {
                crate::svc_log!("nvim_ade_server: deleting team {id} without a cwd");
                expired.push(id);
                continue;
            }
            if let Some(number) = id
                .strip_prefix('t')
                .and_then(|rest| rest.parse::<u64>().ok())
            {
                highest_team = highest_team.max(number);
            }
            for item in &snapshot.inbox {
                if let Some(number) = item
                    .id
                    .strip_prefix('i')
                    .and_then(|rest| rest.parse::<u64>().ok())
                {
                    highest_inbox = highest_inbox.max(number);
                }
                // Open spawn items keep their group across a restart; the
                // counter must continue after them, or a new item would reuse
                // an id and `team.answer_group` would answer both (19.6).
                if let Some(number) = item
                    .group
                    .as_deref()
                    .and_then(|group| group.strip_prefix('g'))
                    .and_then(|rest| rest.parse::<u64>().ok())
                {
                    highest_group = highest_group.max(number);
                }
            }
            let suspended_at = snapshot.suspended_at.unwrap_or(now);
            if snapshot.suspended_at.is_some()
                && expiry_ms.is_some_and(|ttl| now.saturating_sub(suspended_at) > ttl)
            {
                expired.push(id);
                continue;
            }
            let templates: HashMap<String, Template> = snapshot
                .config
                .templates
                .iter()
                .map(|(name, template)| {
                    (
                        name.clone(),
                        Template {
                            key: InstanceKey {
                                agent: String::new(),
                                command: String::new(),
                                args: Vec::new(),
                                cwd: snapshot.cwd.clone(),
                                capabilities: Value::Null,
                            },
                            env: None,
                            #[cfg(unix)]
                            launch: None,
                            model: template.model.clone(),
                            role: template.role.clone(),
                            worktree: template.worktree,
                            models: template.models.clone(),
                            tool_style: template.tool_style,
                        },
                    )
                })
                .collect();
            // A front end may have configured this cwd before the restore (the
            // hub sends `team.configure` after every hello). That configuration
            // carries the live template keys and is what resumes the team, so
            // it wins over the stored snapshot, whose template keys are empty by
            // design (18.15: `key` is never written).
            let pending = self.configs.get(&snapshot.cwd).cloned();
            let config = if let Some(live) = pending {
                let mut live = live;
                if live.templates.is_empty() {
                    live.templates = templates;
                }
                live
            } else {
                TeamConfig {
                    max_workers: snapshot.config.max_workers,
                    spawn_auto: snapshot.config.spawn_auto.iter().cloned().collect(),
                    max_turns_per_task: snapshot.config.max_turns_per_task,
                    max_turns_total: snapshot.config.max_turns_total,
                    templates,
                    workflows: snapshot.config.workflows.into_iter().collect(),
                    default_workflow: snapshot.config.default_workflow,
                    worktree_root: snapshot.config.worktree_root.clone(),
                    enabled: snapshot.config.enabled,
                    session_default: snapshot.config.session_default,
                    builtin_worker: snapshot.config.builtin_worker,
                }
            };
            let mut participants = HashMap::new();
            let mut crashed = Vec::new();
            for mut participant in snapshot.participants {
                participant.instance = None;
                participant.starting = false;
                if participant.bus_turn {
                    crashed.push((
                        participant.name.clone(),
                        participant.turn_task.clone(),
                        participant.turn_sender.clone(),
                    ));
                }
                participant.bus_turn = false;
                participant.reported = false;
                participant.state = match participant.state {
                    ParticipantState::Working => ParticipantState::Idle,
                    other => other,
                };
                // Recovered participants start their state clock at restore
                // time (19.9).
                participant.state_since = now;
                participant.activity = None;
                participant.activity_throttle = activity::ActivityThrottle::default();
                participant.turn_activity = false;
                participants.insert(participant.name.clone(), participant);
            }
            let inbox: Vec<InboxItem> = snapshot
                .inbox
                .into_iter()
                .map(|mut item| {
                    if matches!(item.kind, ItemKind::Permission | ItemKind::Request) {
                        item.state = ItemState::Orphaned;
                    }
                    // A question stored before 19.13 has no `questions`; make
                    // it answerable with the new `answers` form.
                    if item.kind == ItemKind::Question && item.questions.is_none() {
                        item.questions = Some(vec![Question {
                            header: "Question".to_string(),
                            question: item.body.clone(),
                            options: item.options.as_ref().map(|options| {
                                options
                                    .iter()
                                    .map(|label| QuestionOption {
                                        label: label.clone(),
                                        description: None,
                                    })
                                    .collect()
                            }),
                            multi_select: false,
                        }]);
                    }
                    item
                })
                .collect();
            let task_turns: HashMap<(String, String), u64> = snapshot
                .task_turns
                .into_iter()
                .map(|(name, task, count)| ((name, task), count))
                .collect();
            let leaderless = participants
                .get("leader")
                .is_none_or(|leader| leader.state == ParticipantState::Exited);
            let team = Team {
                id: snapshot.id.clone(),
                cwd: snapshot.cwd.clone(),
                leaderless,
                closed: false,
                suspended: true,
                suspended_at: Some(suspended_at),
                leader_instance: None,
                leader_session: snapshot.leader_session.clone(),
                participants,
                order: snapshot.order,
                reserved_names: snapshot.reserved_names.into_iter().collect(),
                config,
                inbox,
                messages: snapshot.messages,
                next_message: snapshot.next_message,
                task_turns,
                total_turns: snapshot.total_turns,
                total_limit_hit: false,
                task_limit_hit: HashSet::new(),
                watchers: HashMap::new(),
                pending_items: HashMap::new(),
                created_at: snapshot.created_at,
                board: board::Board::default(),
                board_flush_at: None,
                current_group: None,
                pending_lifecycles: HashMap::new(),
            };
            self.by_cwd.insert(team.cwd.clone(), team.id.clone());
            self.teams.insert(team.id.clone(), team);
            for (name, task, sender) in crashed {
                let _ = self.send_message(
                    &snapshot.id,
                    &name,
                    "leader",
                    Kind::Notice,
                    "turn ended: error: the service restarted",
                    Some(&task),
                    sender.into_iter().collect(),
                );
            }
            stored.push(snapshot.id);
        }
        self.next_team = self.next_team.max(highest_team);
        self.next_inbox = self.next_inbox.max(highest_inbox);
        self.next_group = self.next_group.max(highest_group);
        (stored, expired)
    }

    /// After a restart, a leaderless team cannot answer its open spawn items.
    /// Orphan them, release their names and clear the cards they own (19.12).
    pub fn orphan_leaderless_spawns(&mut self) {
        let ids: Vec<String> = self
            .teams
            .iter()
            .filter(|(_, team)| team.leaderless && !team.closed)
            .map(|(id, _)| id.clone())
            .collect();
        for id in ids {
            let mut names = Vec::new();
            if let Some(team) = self.teams.get_mut(&id) {
                for item in &mut team.inbox {
                    if item.kind == ItemKind::Spawn && item.state == ItemState::Open {
                        item.state = ItemState::Orphaned;
                        names.push(item.name.clone());
                        self.events
                            .push(TeamEvent::Inbox(id.clone(), item.id.clone()));
                    }
                }
                for name in names.iter().flatten() {
                    team.reserved_names.remove(name);
                }
            }
            if names.is_empty() {
                continue;
            }
            for name in names.into_iter().flatten() {
                self.clear_owners_after_spawn(&id, &name, "orphaned", false);
            }
            self.events.push(TeamEvent::Changed(id));
        }
    }

    pub fn is_suspended(&self, team: &str) -> bool {
        self.teams.get(team).is_some_and(|team| team.suspended)
    }

    pub fn has_active(&self) -> bool {
        self.teams.values().any(|team| !team.suspended)
    }

    /// Remove teams suspended longer than the TTL; worktrees are kept.
    pub fn expire_suspended(&mut self, now: u64, ttl: u64) -> Vec<String> {
        let expired: Vec<String> = self
            .teams
            .values()
            .filter(|team| {
                team.suspended
                    && team
                        .suspended_at
                        .is_some_and(|at| now.saturating_sub(at) > ttl)
            })
            .map(|team| team.id.clone())
            .collect();
        for id in &expired {
            if let Some(team) = self.teams.get(id) {
                let mut entry = team_entry(team);
                entry["state"] = json!("closed");
                self.events.push(TeamEvent::Closed(entry));
            }
            if let Some(team) = self.teams.remove(id) {
                self.by_cwd.retain(|_, value| *value != *id);
                self.closed_teams.insert(id.clone());
                let _ = team;
            }
        }
        expired
    }
}

// -- validation ------------------------------------------------------------

pub fn valid_name(name: &str) -> bool {
    let bytes = name.as_bytes();
    if bytes.is_empty() || bytes.len() > 32 {
        return false;
    }
    if !(bytes[0].is_ascii_lowercase() || bytes[0].is_ascii_digit()) {
        return false;
    }
    bytes.iter().all(|byte| {
        byte.is_ascii_lowercase() || byte.is_ascii_digit() || *byte == b'_' || *byte == b'-'
    })
}

pub fn validate_name(name: &str) -> Result<(), TeamError> {
    if !valid_name(name) {
        return Err(TeamError::invalid(
            "name must match [a-z0-9][a-z0-9_-]{0,31}",
        ));
    }
    Ok(())
}

pub fn valid_task(task: &str) -> bool {
    !task.is_empty()
        && task.len() <= 64
        && task
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || matches!(byte, b'_' | b'.' | b':' | b'-'))
}

pub fn validate_task(task: &str) -> Result<(), TeamError> {
    if !valid_task(task) {
        return Err(TeamError::invalid("task must match [A-Za-z0-9_.:-]{1,64}"));
    }
    Ok(())
}

pub fn validate_body(body: &str) -> Result<(), TeamError> {
    if body.len() > MAX_BODY_BYTES {
        return Err(TeamError::invalid("body is longer than 64 KiB"));
    }
    Ok(())
}

pub fn validate_refs(refs: &[String]) -> Result<(), TeamError> {
    if refs.len() > MAX_REFS {
        return Err(TeamError::invalid("refs has more than 16 entries"));
    }
    if refs.iter().any(|reference| reference.len() > MAX_REF_BYTES) {
        return Err(TeamError::invalid("a ref is longer than 1 KiB"));
    }
    Ok(())
}

fn parse_config(value: &Value) -> Result<TeamConfig, TeamError> {
    let object = value
        .as_object()
        .ok_or_else(|| TeamError::invalid("config must be an object"))?;
    let max_workers = match object.get("max_workers") {
        None | Some(Value::Null) => 3,
        Some(value) => value
            .as_u64()
            .filter(|value| (1..=8).contains(value))
            .ok_or_else(|| TeamError::invalid("max_workers must be 1..8"))?,
    };
    let mut templates = HashMap::new();
    if let Some(table) = object.get("templates").and_then(Value::as_object) {
        for (name, template) in table {
            if !valid_name(name) {
                return Err(TeamError::invalid(format!("invalid template name {name}")));
            }
            templates.insert(name.clone(), parse_template(name, template)?);
        }
    }
    if let Some(templates_value) = object.get("templates") {
        if !templates_value.is_object() {
            return Err(TeamError::invalid("templates must be an object"));
        }
    }
    // 20.4: an empty template table still gets the built-in `worker`, which is
    // filled from the leader instance's own launch at team creation. It has to
    // be present here so workflows and `spawn_confirm.auto` can name it.
    let builtin_worker = templates.is_empty();
    if builtin_worker {
        templates.insert(
            "worker".to_string(),
            Template {
                key: InstanceKey {
                    agent: String::new(),
                    command: String::new(),
                    args: Vec::new(),
                    cwd: String::new(),
                    capabilities: Value::Null,
                },
                env: None,
                #[cfg(unix)]
                launch: None,
                model: None,
                role: String::new(),
                models: Vec::new(),
                tool_style: ToolStyle::Direct,
                worktree: true,
            },
        );
    }
    // Workflows validate against the templates of this same configuration
    // (19.1), so they are parsed after them.
    let templates_for_workflows = TeamConfig {
        templates: templates.clone(),
        ..Default::default()
    };
    let mut workflows = HashMap::new();
    match object.get("workflows") {
        None | Some(Value::Null) => {}
        Some(value) => {
            let table = value
                .as_object()
                .ok_or_else(|| TeamError::invalid("workflows must be an object"))?;
            for (name, workflow) in table {
                if !valid_name(name) {
                    return Err(TeamError::invalid(format!(
                        "workflows.{name} name must match [a-z0-9][a-z0-9_-]{{0,31}}"
                    )));
                }
                let mut value = workflow.clone();
                if let Value::Object(object) = &mut value {
                    match object.get("name") {
                        None | Some(Value::Null) => {
                            object.insert("name".to_string(), json!(name));
                        }
                        Some(Value::String(inner)) if inner == name => {}
                        Some(_) => {
                            return Err(TeamError::invalid(format!(
                                "workflows.{name}.name must equal its key"
                            )))
                        }
                    }
                }
                let parsed = workflow::parse_workflow(
                    &value,
                    workflow::Scope::Config,
                    Some(&templates_for_workflows),
                )
                .map_err(|error| {
                    TeamError::invalid(format!("workflows.{name}: {}", error.message))
                })?;
                workflows.insert(name.clone(), parsed);
            }
        }
    }
    let default_workflow = match object.get("default_workflow") {
        None | Some(Value::Null) => None,
        Some(value) => {
            let name = value
                .as_str()
                .ok_or_else(|| TeamError::invalid("default_workflow must be a string"))?;
            if name != "default" && !workflows.contains_key(name) {
                return Err(TeamError::invalid(format!(
                    "default_workflow {name} is not a configured workflow"
                )));
            }
            Some(name.to_string())
        }
    };
    let mut spawn_auto = HashSet::new();
    if let Some(confirm) = object.get("spawn_confirm") {
        let confirm = confirm
            .as_object()
            .ok_or_else(|| TeamError::invalid("spawn_confirm must be an object"))?;
        if let Some(auto) = confirm.get("auto") {
            let auto = auto
                .as_array()
                .ok_or_else(|| TeamError::invalid("spawn_confirm.auto must be an array"))?;
            for entry in auto {
                let name = entry.as_str().ok_or_else(|| {
                    TeamError::invalid("spawn_confirm.auto entries must be strings")
                })?;
                if !templates.contains_key(name) {
                    return Err(TeamError::invalid(format!(
                        "unknown template {name} in spawn_confirm.auto"
                    )));
                }
                spawn_auto.insert(name.to_string());
            }
        }
    }
    let mut max_turns_per_task = 30;
    let mut max_turns_total = 200;
    if let Some(limits) = object.get("limits") {
        let limits = limits
            .as_object()
            .ok_or_else(|| TeamError::invalid("limits must be an object"))?;
        if let Some(value) = limits.get("max_turns_per_task") {
            max_turns_per_task = value.as_u64().ok_or_else(|| {
                TeamError::invalid("limits.max_turns_per_task must be an integer")
            })?;
        }
        if let Some(value) = limits.get("max_turns_total") {
            max_turns_total = value
                .as_u64()
                .ok_or_else(|| TeamError::invalid("limits.max_turns_total must be an integer"))?;
        }
    }
    let enabled = match object.get("enabled") {
        None | Some(Value::Null) => true,
        Some(value) => value
            .as_bool()
            .ok_or_else(|| TeamError::invalid("enabled must be a boolean"))?,
    };
    let session_default = match object.get("session_default") {
        None | Some(Value::Null) => true,
        Some(value) => value
            .as_bool()
            .ok_or_else(|| TeamError::invalid("session_default must be a boolean"))?,
    };
    let worktree_root = match object.get("worktree_root") {
        None | Some(Value::Null) => None,
        Some(value) => {
            let root = value
                .as_str()
                .ok_or_else(|| TeamError::invalid("worktree_root must be a string"))?;
            if root.is_empty() || !std::path::Path::new(root).is_absolute() {
                return Err(TeamError::invalid("worktree_root must be an absolute path"));
            }
            Some(root.to_string())
        }
    };
    Ok(TeamConfig {
        max_workers,
        spawn_auto,
        max_turns_per_task,
        max_turns_total,
        templates,
        workflows,
        default_workflow,
        worktree_root,
        enabled,
        session_default,
        builtin_worker,
    })
}

/// A parsed configuration for the unit tests of sibling modules.
#[cfg(test)]
pub(crate) fn parse_config_for_tests(value: &Value) -> TeamConfig {
    parse_config(value).expect("test configuration")
}

fn parse_template(name: &str, value: &Value) -> Result<Template, TeamError> {
    let object = value
        .as_object()
        .ok_or_else(|| TeamError::invalid(format!("template {name} must be an object")))?;
    let key = object
        .get("key")
        .and_then(Value::as_object)
        .ok_or_else(|| TeamError::invalid(format!("template {name}.key must be an object")))?;
    let field = |name: &str| -> Result<String, TeamError> {
        key.get(name)
            .and_then(Value::as_str)
            .filter(|value| !value.is_empty())
            .map(str::to_string)
            .ok_or_else(|| {
                TeamError::invalid(format!("template {name}.key.{name} must be a string"))
            })
    };
    let agent = field("agent")?;
    let command = field("command")?;
    let args = match key.get("args") {
        None | Some(Value::Null) => Vec::new(),
        Some(Value::Array(items)) => {
            let mut args = Vec::new();
            for item in items {
                let Some(arg) = item.as_str() else {
                    return Err(TeamError::invalid(format!(
                        "template {name}.key.args must be strings"
                    )));
                };
                args.push(arg.to_string());
            }
            args
        }
        Some(_) => {
            return Err(TeamError::invalid(format!(
                "template {name}.key.args must be an array"
            )))
        }
    };
    let env = match object.get("env") {
        None | Some(Value::Null) => None,
        Some(env) => {
            let env = env.as_object().ok_or_else(|| {
                TeamError::invalid(format!("template {name}.env must be an object"))
            })?;
            let mut pairs = Vec::new();
            for (key, value) in env {
                let Some(value) = value.as_str() else {
                    return Err(TeamError::invalid(format!(
                        "template {name}.env values must be strings"
                    )));
                };
                pairs.push((key.clone(), value.to_string()));
            }
            Some(pairs)
        }
    };
    #[cfg(unix)]
    let launch = match object.get("launch") {
        None | Some(Value::Null) => None,
        Some(value) => Some(
            crate::install::parse_launch(value)
                .map_err(|error| TeamError::invalid(format!("template {name}.{error}")))?,
        ),
    };
    let model = match object.get("model") {
        None | Some(Value::Null) => None,
        Some(value) => Some(
            value
                .as_str()
                .ok_or_else(|| {
                    TeamError::invalid(format!("template {name}.model must be a string"))
                })?
                .to_string(),
        ),
    };
    let worktree = match object.get("worktree") {
        None | Some(Value::Null) => false,
        Some(value) => value.as_bool().ok_or_else(|| {
            TeamError::invalid(format!("template {name}.worktree must be a boolean"))
        })?,
    };
    let role = match object.get("role") {
        None | Some(Value::Null) => String::new(),
        Some(value) => value
            .as_str()
            .ok_or_else(|| TeamError::invalid(format!("template {name}.role must be a string")))?
            .to_string(),
    };
    if role.len() > MAX_ROLE_BYTES {
        return Err(TeamError::invalid(format!(
            "template {name}.role is longer than 16 KiB"
        )));
    }
    let models = match object.get("models") {
        None | Some(Value::Null) => Vec::new(),
        Some(value) => {
            let items = value.as_array().ok_or_else(|| {
                TeamError::invalid(format!("template {name}.models must be an array"))
            })?;
            let mut models = Vec::new();
            for item in items {
                let Some(model) = item.as_str() else {
                    return Err(TeamError::invalid(format!(
                        "template {name}.models must be strings"
                    )));
                };
                models.push(model.to_string());
            }
            models
        }
    };
    let tool_style = match object.get("tool_style") {
        None | Some(Value::Null) => ToolStyle::Direct,
        Some(value) => value.as_str().and_then(ToolStyle::parse).ok_or_else(|| {
            TeamError::invalid(format!(
                "template {name}.tool_style must be direct or mcp_proxy"
            ))
        })?,
    };
    let capabilities = json!({
        "fs": { "readTextFile": false, "writeTextFile": false },
        "terminal": false,
    });
    Ok(Template {
        key: InstanceKey {
            agent,
            command,
            args,
            cwd: String::new(),
            capabilities,
        },
        env,
        #[cfg(unix)]
        launch,
        model,
        role,
        models,
        tool_style,
        worktree,
    })
}

/// The fixed client capabilities the service sends for a worker's
/// `initialize` (18.3).
pub fn worker_capabilities() -> Value {
    json!({
        "fs": { "readTextFile": false, "writeTextFile": false },
        "terminal": false,
    })
}

impl Team {
    pub fn config(&self) -> &TeamConfig {
        &self.config
    }

    pub fn template(&self, name: &str) -> Option<&Template> {
        self.config.templates.get(name)
    }

    pub fn worker_for_instance(&self, instance: &str) -> Option<&Participant> {
        self.workers()
            .find(|participant| participant.instance.as_deref() == Some(instance))
    }

    pub fn leader(&self) -> Option<&Participant> {
        self.participants.get("leader")
    }

    pub fn reserved_name(&self, name: &str) -> bool {
        self.reserved_names.contains(name)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn config(extra: Value) -> Value {
        let mut base = json!({
            "max_workers": 3,
            "spawn_confirm": { "auto": ["dev"] },
            "limits": { "max_turns_per_task": 30, "max_turns_total": 200 },
            "templates": {
                "dev": {
                    "key": { "agent": "a", "command": "c", "args": [] },
                    "env": { "A": "b" },
                    "role": "role",
                }
            }
        });
        if let (Value::Object(base), Value::Object(extra)) = (&mut base, extra) {
            for (key, value) in extra {
                base.insert(key, value);
            }
        }
        base
    }

    fn fixture(extra: Value) -> (Teams, String) {
        let mut teams = Teams::new(new_shared_tokens());
        teams.configure("/p", config(extra)).expect("configure");
        session(&mut teams, "i1", "/p", "s1");
        let id = teams
            .ensure_team("i1", "s1", &launch("/p"))
            .expect("ensure team");
        (teams, id)
    }

    fn add_worker(teams: &mut Teams, team: &str, name: &str) -> String {
        let outcome = teams
            .request_spawn(team, "dev", Some(name), None, None, None)
            .expect("spawn");
        assert!(matches!(outcome, SpawnOutcome::Started(_)), "{outcome:?}");
        let instance = format!("{name}-i");
        teams.worker_instance_set(team, name, &instance);
        teams.worker_session_set(team, name, &format!("{name}-s"));
        teams.worker_started(team, name);
        instance
    }

    fn deliver(teams: &mut Teams, team: &str, name: &str) -> Vec<Value> {
        teams
            .take_deliveries(&HashSet::new())
            .into_iter()
            .find(|request| request.team == team && request.participant == name)
            .map(|request| request.blocks)
            .unwrap_or_default()
    }

    fn messages(teams: &Teams, team: &str, participant: &str) -> Vec<Value> {
        teams.read(team, participant, None).unwrap()["messages"]
            .as_array()
            .cloned()
            .unwrap_or_default()
    }

    #[test]
    fn names_tasks_bodies_and_refs_are_validated() {
        assert!(valid_name("w1"));
        assert!(valid_name("a-b_c"));
        assert!(!valid_name("W1"));
        assert!(!valid_name(""));
        assert!(!valid_name("a b"));
        assert!(valid_task("T3"));
        assert!(valid_task("_"));
        assert!(valid_task("a.b:c-d"));
        assert!(!valid_task("a b"));
        assert!(validate_body(&"x".repeat(MAX_BODY_BYTES)).is_ok());
        assert!(validate_body(&"x".repeat(MAX_BODY_BYTES + 1)).is_err());
        assert!(validate_refs(&vec!["x".to_string(); MAX_REFS]).is_ok());
        assert!(validate_refs(&vec!["x".to_string(); MAX_REFS + 1]).is_err());
        assert!(validate_refs(&["x".repeat(MAX_REF_BYTES + 1)]).is_err());

        let mut teams = Teams::new(new_shared_tokens());
        assert!(teams.configure("/p", json!({"max_workers": 0})).is_err());
        assert!(teams.configure("/p", json!({"max_workers": 9})).is_err());
        assert!(teams
            .configure("/p", json!({"spawn_confirm": {"auto": ["missing"]}}),)
            .is_err());
        assert!(teams
            .configure(
                "/p",
                json!({"templates": {"bad name": {"key": {"agent": "a", "command": "c"}, "role": "r"}}}),
            )
            .is_err());
    }

    #[test]
    fn messages_escape_body_and_refs_as_children() {
        let message = Message {
            id: 1,
            from: "w1".to_string(),
            to: "leader".to_string(),
            kind: Kind::Task,
            task: "_".to_string(),
            body: "a&<b>".to_string(),
            refs: vec!["<r>&".to_string()],
            at: 0,
        };
        assert_eq!(
            format_message(&message),
            "<bus from=\"w1\" kind=\"task\">a&amp;&lt;b><ref>&lt;r>&amp;</ref></bus>"
        );
        let mut message = message;
        message.task = "T3".to_string();
        assert_eq!(
            format_message(&message),
            "<bus from=\"w1\" kind=\"task\" task=\"T3\">a&amp;&lt;b><ref>&lt;r>&amp;</ref></bus>"
        );
    }

    #[test]
    fn delivery_batches_128_kib_and_keeps_the_rest() {
        let (mut teams, team) = fixture(json!({}));
        add_worker(&mut teams, &team, "w1");
        for index in 0..3 {
            teams
                .send_message(
                    &team,
                    "leader",
                    "w1",
                    Kind::Task,
                    &format!("{index}:{}", "x".repeat(60 * 1024)),
                    Some("T1"),
                    vec![],
                )
                .expect("send");
        }
        let blocks = deliver(&mut teams, &team, "w1");
        assert_eq!(blocks.len(), 3, "role card plus two full messages");
        assert!(blocks[0]["text"].as_str().unwrap().contains("You are w1"));
        assert_eq!(teams.team(&team).unwrap().participants["w1"].queued(), 1);
        teams.turn_finished("w1-i", true, None, String::new());
        let blocks = deliver(&mut teams, &team, "w1");
        assert_eq!(blocks.len(), 1);
        assert!(blocks[0]["text"].as_str().unwrap().contains("2:"));
    }

    #[test]
    fn report_fallback_is_suppressed_by_an_explicit_report() {
        let (mut teams, team) = fixture(json!({}));
        let instance = add_worker(&mut teams, &team, "w1");
        teams
            .send_message(&team, "leader", "w1", Kind::Task, "do", Some("T1"), vec![])
            .expect("send");
        deliver(&mut teams, &team, "w1");
        teams.observe_chunk(&instance, Some("w1-s"), "the answer");
        teams.turn_finished(&instance, true, None, String::new());
        let reports = messages(&teams, &team, "leader")
            .into_iter()
            .filter(|message| message["kind"] == "report" && message["from"] == "w1")
            .collect::<Vec<_>>();
        assert_eq!(reports.len(), 1);
        assert_eq!(reports[0]["body"], "the answer");

        teams
            .send_message(
                &team,
                "leader",
                "w1",
                Kind::Task,
                "again",
                Some("T2"),
                vec![],
            )
            .expect("send");
        deliver(&mut teams, &team, "w1");
        teams
            .send_message(&team, "w1", "leader", Kind::Report, "own", None, vec![])
            .expect("report");
        teams.observe_chunk(&instance, Some("w1-s"), "ignored");
        teams.turn_finished(&instance, true, None, String::new());
        let reports = messages(&teams, &team, "leader")
            .into_iter()
            .filter(|message| message["kind"] == "report" && message["from"] == "w1")
            .collect::<Vec<_>>();
        assert_eq!(reports.len(), 2, "only the explicit report was added");
        assert_eq!(reports[1]["body"], "own");
    }

    #[test]
    fn limits_pause_and_reset() {
        let (mut teams, team) = fixture(json!({"limits": {"max_turns_per_task": 1}}));
        let instance = add_worker(&mut teams, &team, "w1");
        teams
            .send_message(&team, "leader", "w1", Kind::Task, "one", Some("T1"), vec![])
            .expect("send");
        deliver(&mut teams, &team, "w1");
        teams.turn_finished(&instance, true, None, String::new());
        let entry = &teams.team(&team).unwrap().participants["w1"];
        assert!(entry.paused);
        assert!(teams
            .team(&team)
            .unwrap()
            .inbox
            .iter()
            .any(|item| item.kind == ItemKind::Limit && item.scope.as_deref() == Some("task")));
        teams.reset_limits(&team).expect("reset");
        assert!(!teams.team(&team).unwrap().participants["w1"].paused);
    }

    #[test]
    fn total_limit_pauses_everyone() {
        let (mut teams, team) = fixture(json!({"limits": {"max_turns_total": 1}}));
        let instance = add_worker(&mut teams, &team, "w1");
        teams
            .send_message(&team, "leader", "w1", Kind::Task, "one", Some("T1"), vec![])
            .expect("send");
        deliver(&mut teams, &team, "w1");
        teams.turn_finished(&instance, true, None, String::new());
        let team = teams.team(&team).unwrap();
        assert!(team
            .participants
            .values()
            .all(|participant| participant.paused));
        assert!(team
            .inbox
            .iter()
            .any(|item| item.kind == ItemKind::Limit && item.scope.as_deref() == Some("total")));
    }

    #[test]
    fn a_report_while_waiting_human_marks_the_turn_reported() {
        let (mut teams, team) = fixture(json!({}));
        add_worker(&mut teams, &team, "w1");
        teams
            .send_message(&team, "leader", "w1", Kind::Task, "do", Some("T1"), vec![])
            .unwrap();
        deliver(&mut teams, &team, "w1");
        teams.ask_human(&team, "w1", "q?", None).unwrap();
        teams
            .send_message(&team, "w1", "leader", Kind::Report, "report", None, vec![])
            .unwrap();
        let participant = &teams.team(&team).unwrap().participants["w1"];
        assert!(
            participant.reported,
            "report while waiting_human must set reported"
        );
    }

    #[test]
    fn a_resumed_total_limit_pauses_again_on_the_next_turn() {
        let (mut teams, team) = fixture(json!({"limits": {"max_turns_total": 1}}));
        add_worker(&mut teams, &team, "w1");
        teams
            .send_message(&team, "leader", "w1", Kind::Task, "one", Some("T1"), vec![])
            .unwrap();
        deliver(&mut teams, &team, "w1");
        teams.turn_finished("w1-i", true, None, String::new());
        assert!(teams.team(&team).unwrap().participants["leader"].paused);
        teams
            .send_message(
                &team,
                "human",
                "leader",
                Kind::Control,
                "resume",
                None,
                vec![],
            )
            .unwrap();
        assert!(!teams.team(&team).unwrap().participants["leader"].paused);
        teams
            .send_message(&team, "human", "leader", Kind::Task, "again", None, vec![])
            .unwrap();
        assert!(!deliver(&mut teams, &team, "leader").is_empty());
        teams.turn_finished("i1", true, None, String::new());
        assert!(
            teams.team(&team).unwrap().participants["leader"].paused,
            "the total limit must pause again after resume"
        );
    }

    #[test]
    fn question_answer_is_delivered_before_other_mail() {
        let (mut teams, team) = fixture(json!({}));
        add_worker(&mut teams, &team, "w1");
        teams
            .send_message(
                &team,
                "leader",
                "w1",
                Kind::Task,
                "queued",
                Some("T1"),
                vec![],
            )
            .expect("send");
        let request = teams
            .ask_human(&team, "w1", "question?", Some(vec!["a".to_string()]))
            .expect("ask");
        assert_eq!(
            teams.team(&team).unwrap().participants["w1"].state,
            ParticipantState::WaitingHuman
        );
        let (effect, _) = teams
            .answer(&request, Some("yes".to_string()), None, None)
            .expect("answer");
        assert!(matches!(effect, AnswerEffect::Question));
        let blocks = deliver(&mut teams, &team, "w1");
        let answer = blocks
            .iter()
            .position(|block| block["text"].as_str().unwrap().contains("kind=\"answer\""))
            .expect("answer block");
        let queued = blocks
            .iter()
            .position(|block| block["text"].as_str().unwrap().contains("queued"))
            .expect("queued block");
        assert!(answer < queued);
        assert_eq!(
            teams.team(&team).unwrap().participants["w1"].state,
            ParticipantState::Working
        );
    }

    #[test]
    fn reset_limits_does_not_clear_a_human_pause() {
        let (mut teams, team) = fixture(json!({"limits": {"max_turns_per_task": 1}}));
        add_worker(&mut teams, &team, "w1");
        teams
            .send_message(&team, "human", "w1", Kind::Control, "pause", None, vec![])
            .unwrap();
        teams.reset_limits(&team).unwrap();
        assert!(
            teams.team(&team).unwrap().participants["w1"].paused,
            "reset_limits must not clear a human pause"
        );
        teams
            .send_message(&team, "human", "w1", Kind::Control, "resume", None, vec![])
            .unwrap();
        assert!(!teams.team(&team).unwrap().participants["w1"].paused);
    }

    #[test]
    fn answering_one_of_two_questions_keeps_waiting() {
        let (mut teams, team) = fixture(json!({}));
        add_worker(&mut teams, &team, "w1");
        let first = teams.ask_human(&team, "w1", "one", None).unwrap();
        let second = teams.ask_human(&team, "w1", "two", None).unwrap();
        teams
            .answer(&first, Some("a".to_string()), None, None)
            .unwrap();
        assert_eq!(
            teams.team(&team).unwrap().participants["w1"].state,
            ParticipantState::WaitingHuman
        );
        teams
            .answer(&second, Some("b".to_string()), None, None)
            .unwrap();
        assert_eq!(
            teams.team(&team).unwrap().participants["w1"].state,
            ParticipantState::Idle
        );
    }

    #[test]
    fn a_question_can_be_answered_with_an_option() {
        let (mut teams, team) = fixture(json!({}));
        add_worker(&mut teams, &team, "w1");
        let request = teams
            .ask_human(
                &team,
                "w1",
                "pick",
                Some(vec!["a".to_string(), "b".to_string()]),
            )
            .unwrap();
        teams
            .answer(&request, None, Some("a".to_string()), None)
            .unwrap();
        let participant = &teams.team(&team).unwrap().participants["w1"];
        assert_eq!(
            participant
                .mailbox
                .front()
                .map(|message| message.body.as_str()),
            Some("a")
        );
    }

    #[test]
    fn control_messages_follow_the_role_rules() {
        let (mut teams, team) = fixture(json!({}));
        add_worker(&mut teams, &team, "w1");
        assert!(teams
            .send_message(&team, "w1", "leader", Kind::Control, "pause", None, vec![])
            .is_err());
        assert!(teams
            .send_message(
                &team,
                "leader",
                "human",
                Kind::Control,
                "pause",
                None,
                vec![]
            )
            .is_err());
        assert!(teams
            .send_message(&team, "human", "w1", Kind::Control, "wat", None, vec![])
            .is_err());
        teams
            .send_message(&team, "human", "w1", Kind::Control, "pause", None, vec![])
            .expect("human pause");
        assert!(teams.team(&team).unwrap().participants["w1"].paused);
        teams
            .send_message(&team, "human", "w1", Kind::Control, "resume", None, vec![])
            .expect("human resume");
        assert!(!teams.team(&team).unwrap().participants["w1"].paused);
    }

    #[test]
    fn tokens_are_random_hashes_and_resolve_their_role() {
        let mut teams = Teams::new(new_shared_tokens());
        let (token_id, _token) = teams.issue_session_token("i1", "/p", "opencode", None);
        assert_eq!(token_id, "k1");
        let tokens = teams.tokens.lock().unwrap();
        let raw = tokens.values().next().expect("token");
        assert_eq!(raw.token_id, "k1");
        assert_eq!(raw.role, Role::Session);
        // The shared registry has no raw token field at all.
        let token = crate::token::generate();
        assert!(token.len() >= 32);
        assert_ne!(hash_token(&token), hash_token(&format!("{token}x")));
    }

    #[test]
    fn status_includes_self_and_the_leader_gets_templates() {
        let (mut teams, team) = fixture(json!({}));
        add_worker(&mut teams, &team, "w1");
        let leader = teams.status(&team, "leader", "/p").unwrap();
        assert_eq!(leader["self"]["role"], "leader");
        assert_eq!(
            leader["templates"],
            json!([{ "name": "dev", "agent": "a", "models": [] }])
        );
        assert_eq!(leader["workflows"][0]["name"], "default");
        assert_eq!(leader["workflows"][0]["scope"], "builtin");
        let names: Vec<&str> = leader["members"]
            .as_array()
            .unwrap()
            .iter()
            .filter_map(|member| member["name"].as_str())
            .collect();
        assert!(names.contains(&"leader"), "{leader}");
        assert!(names.contains(&"w1"), "{leader}");
        let worker = teams.status(&team, "w1", "/p").unwrap();
        assert_eq!(worker["self"]["role"], "worker");
        assert!(worker.get("templates").is_none());
    }

    #[test]
    fn a_refused_spawn_notifies_the_leader_and_frees_the_name() {
        let (mut teams, team) = fixture(json!({"spawn_confirm": {"auto": []}}));
        let SpawnOutcome::Awaiting { request, name } = teams
            .request_spawn(&team, "dev", Some("w1"), None, None, Some("do"))
            .unwrap()
        else {
            panic!("expected approval");
        };
        assert_eq!(name, "w1");
        let (effect, _) = teams.answer(&request, None, None, Some(false)).unwrap();
        assert!(matches!(effect, AnswerEffect::Ack));
        assert!(!teams.team(&team).unwrap().participants.contains_key("w1"));
        let item = teams.item(&team, &request).expect("item");
        assert_eq!(item.state, ItemState::Answered);
    }

    #[test]
    fn closing_a_team_orphans_open_spawn_items() {
        let (mut teams, team) = fixture(json!({"spawn_confirm": {"auto": []}}));
        let SpawnOutcome::Awaiting { request, .. } = teams
            .request_spawn(&team, "dev", Some("w1"), None, None, None)
            .unwrap()
        else {
            panic!("expected approval");
        };
        teams.close(&team).unwrap();
        let events = teams.drain_events();
        assert!(
            events.iter().any(|event| {
                matches!(event, TeamEvent::InboxJson(item) if item["id"] == request)
            }),
            "{events:?}"
        );
        assert!(teams.team(&team).is_none());
        assert!(teams.is_closed(&team));
        assert!(teams.list()["teams"].as_array().unwrap().is_empty());
    }

    #[test]
    fn config_latest_call_wins_without_touching_a_running_team() {
        let (mut teams, team) = fixture(json!({"max_workers": 1}));
        assert_eq!(teams.team(&team).unwrap().config.max_workers, 1);
        teams
            .configure(
                "/p",
                json!({"max_workers": 2, "templates": {"dev": {"key": {"agent": "a", "command": "c"}, "role": "r"}}}),
            )
            .unwrap();
        assert_eq!(teams.config_for("/p").max_workers, 2);
        assert_eq!(teams.team(&team).unwrap().config.max_workers, 1);
    }

    #[test]
    fn waiting_human_is_not_cleared_by_the_turn_answer() {
        let (mut teams, team) = fixture(json!({}));
        let instance = add_worker(&mut teams, &team, "w1");
        teams
            .send_message(
                &team,
                "leader",
                "w1",
                Kind::Task,
                "do [ask]",
                Some("T1"),
                vec![],
            )
            .unwrap();
        let blocks = deliver(&mut teams, &team, "w1");
        assert!(!blocks.is_empty());
        teams.ask_human(&team, "w1", "question?", None).unwrap();
        teams.turn_finished(&instance, true, None, String::new());
        assert_eq!(
            teams.team(&team).unwrap().participants["w1"].state,
            ParticipantState::WaitingHuman
        );
    }

    #[test]
    fn closing_the_leader_session_orphans_items_and_revokes_tokens() {
        let (mut teams, team) = fixture(json!({}));
        let request = teams.ask_human(&team, "leader", "question?", None).unwrap();
        teams.leader_session_closed("i1", "s1");
        assert!(!teams.is_closed(&team));
        assert!(teams.team(&team).unwrap().leaderless);
        assert_eq!(
            teams.item(&team, &request).unwrap().state,
            ItemState::Orphaned
        );
        assert!(teams.token_role("k1").is_none());
    }

    #[test]
    fn a_snapshot_round_trips_and_restores_suspended() {
        let (mut teams, team) = fixture(json!({}));
        add_worker(&mut teams, &team, "w1");
        teams
            .send_message(
                &team,
                "leader",
                "w1",
                Kind::Task,
                "queued work",
                Some("T1"),
                vec![],
            )
            .unwrap();
        let request = teams.ask_human(&team, "w1", "question?", None).unwrap();
        let json = teams.snapshot_team(&team).expect("snapshot");
        let (max_team, max_inbox) = teams.counters();

        let mut restored = Teams::new(new_shared_tokens());
        let (stored, expired) = restored.restore(
            vec![(team.clone(), json)],
            max_team,
            max_inbox,
            now_ms(),
            None,
        );
        assert_eq!(stored, vec![team.clone()]);
        assert!(expired.is_empty());
        let entry = restored.entry(&team).expect("entry");
        assert_eq!(entry["state"], "suspended", "{entry}");
        assert!(entry["suspended_at"].as_u64().is_some(), "{entry}");
        assert!(entry["leader"]["instance"].is_null(), "{entry}");
        assert_eq!(entry["leader"]["sessionId"], "s1");
        let worker = entry["participants"]
            .as_array()
            .and_then(|items| items.iter().find(|item| item["name"] == "w1"))
            .expect("worker");
        assert!(worker["instance"].is_null(), "{worker}");
        assert_eq!(worker["sessionId"], "w1-s");
        assert_eq!(worker["queued"], 1, "{worker}");
        assert_eq!(
            restored.item(&team, &request).unwrap().state,
            ItemState::Open
        );
        // Ids continue after the highest ever stored.
        session(&mut restored, "i9", "/new", "s9");
        let id = restored
            .ensure_team("i9", "s9", &launch("/new"))
            .expect("a new cwd gets a new team");
        assert_ne!(id, team);
    }

    #[test]
    fn a_suspended_team_expires_after_the_ttl() {
        let (teams, team) = fixture(json!({}));
        let now = now_ms();
        let mut json: Value =
            serde_json::from_str(&teams.snapshot_team(&team).unwrap()).expect("snapshot");
        json["suspended_at"] = json!(now.saturating_sub(1000));
        let mut restored = Teams::new(new_shared_tokens());
        let (stored, expired) =
            restored.restore(vec![(team.clone(), json.to_string())], 0, 0, now, Some(500));
        assert!(stored.is_empty());
        assert_eq!(expired, vec![team.clone()]);
        assert!(restored.team(&team).is_none());
    }

    #[test]
    fn permission_payloads_are_not_written_to_the_snapshot() {
        let (mut teams, team) = fixture(json!({}));
        let item = InboxItem {
            id: "i7".to_string(),
            team: team.clone(),
            kind: ItemKind::Permission,
            from: "w1".to_string(),
            body: "permission".to_string(),
            at: 1,
            state: ItemState::Open,
            label: None,
            questions: None,
            options: None,
            template: None,
            name: None,
            task: None,
            model: None,
            role: None,
            agent: None,
            group: None,
            instance: Some("i2".to_string()),
            session: Some("w1-s".to_string()),
            tool_call: Some(json!({"toolCallId": "secret-tool"})),
            tool_options: Some(json!([{"optionId": "allow"}])),
            method: Some("session/request_permission".to_string()),
            params: Some(json!({"secret": "payload"})),
            message_id: None,
            participant: None,
            scope: None,
            limit_task: None,
            from_instance: None,
            from_session: None,
            leader_instance: None,
            leader_session: None,
            agent_id: Some(json!(42)),
        };
        teams.teams.get_mut(&team).unwrap().inbox.push(item.clone());
        let snapshot = teams.snapshot_team(&team).unwrap();
        assert!(!snapshot.contains("secret-tool"));
        assert!(!snapshot.contains("payload"));
        assert!(!snapshot.contains("allow"));
        let value: Value = serde_json::from_str(&snapshot).unwrap();
        let stored = &value["inbox"][0];
        assert!(stored["tool_call"].is_null(), "{stored}");
        assert!(stored["params"].is_null(), "{stored}");
        assert!(stored["agent_id"].is_null(), "{stored}");
    }

    #[test]
    fn permission_and_request_items_are_orphaned_on_restore() {
        let (mut teams, team) = fixture(json!({}));
        let _ = &mut teams;
        let mut json: Value =
            serde_json::from_str(&teams.snapshot_team(&team).expect("snapshot")).expect("json");
        let mut item = json!({
            "id": "i9",
            "team": team,
            "kind": "permission",
            "from": "w1",
            "body": "permission",
            "at": 1,
            "state": "open",
            "agent_id": 7,
        });
        item["kind"] = json!("permission");
        json["inbox"] = json!([item]);
        let mut restored = Teams::new(new_shared_tokens());
        restored.restore(vec![(team.clone(), json.to_string())], 1, 9, now_ms(), None);
        assert_eq!(
            restored.item(&team, "i9").unwrap().state,
            ItemState::Orphaned
        );
    }

    #[test]
    fn worktree_configuration_is_validated() {
        let mut teams = Teams::new(new_shared_tokens());
        let error = teams
            .configure("/p", config(json!({"worktree_root": "relative/path"})))
            .expect_err("a relative root must fail");
        assert_eq!(error.code, INVALID_TEAM_PARAM, "{error:?}");
        assert!(error.message.contains("worktree_root"), "{error:?}");

        let mut templates = json!({
            "dev": {
                "key": { "agent": "a", "command": "c", "args": [] },
                "role": "role",
                "worktree": "yes"
            }
        });
        let error = teams
            .configure("/p", config(json!({"templates": templates.take()})))
            .expect_err("a non-boolean worktree must fail");
        assert_eq!(error.code, INVALID_TEAM_PARAM, "{error:?}");
        assert!(error.message.contains("worktree"), "{error:?}");

        teams
            .configure("/p", config(json!({"worktree_root": "/tmp/worktrees"})))
            .expect("an absolute root is accepted");
        assert_eq!(
            teams.config_for("/p").worktree_root.as_deref(),
            Some("/tmp/worktrees")
        );
    }

    #[test]
    fn a_human_spawn_has_no_inbox_item() {
        let (mut teams, team) = fixture(json!({}));
        let spawn = teams
            .request_spawn_human(&team, "dev", Some("w1"), None, None, Some("do it"))
            .expect("human spawn");
        assert_eq!(spawn.name, "w1");
        assert_eq!(spawn.template, "dev");
        let entry = teams.entry(&team).expect("entry");
        assert!(entry["inbox"]
            .as_array()
            .is_some_and(|items| items.iter().all(|item| item["kind"] != "spawn")));
        assert!(entry["participants"]
            .as_array()
            .is_some_and(|items| items.iter().any(|item| item["name"] == "w1")));
        // The same name and the worker limit still apply.
        let used = teams
            .request_spawn_human(&team, "dev", Some("w1"), None, None, None)
            .expect_err("a used name fails");
        assert_eq!(used.code, INVALID_TEAM_PARAM, "{used:?}");
        let (mut limited, limited_team) = fixture(json!({"max_workers": 1}));
        limited
            .request_spawn_human(&limited_team, "dev", Some("w1"), None, None, None)
            .expect("first worker");
        let error = limited
            .request_spawn_human(&limited_team, "dev", Some("w2"), None, None, None)
            .expect_err("the limit applies");
        assert_eq!(error.code, NOT_ALLOWED, "{error:?}");
    }

    #[test]
    fn the_team_and_read_carry_the_worktree() {
        let (mut teams, team) = fixture(json!({"worktree_root": "/tmp/worktrees"}));
        let spawn = teams
            .request_spawn_human(&team, "dev", Some("w1"), None, None, None)
            .unwrap();
        let info = worktree::WorktreeInfo {
            path: "/tmp/worktrees/repo-12345678/t1-w1".to_string(),
            cwd: "/tmp/worktrees/repo-12345678/t1-w1/sub".to_string(),
            branch: "ade/t1-stamp/w1".to_string(),
            base: "abc".to_string(),
            toplevel: "/tmp/repo".to_string(),
            warning: Some("dirty_tree".to_string()),
            missing_subdir: None,
        };
        teams.worktree_prepared(&team, &spawn.name, info);
        let entry = teams.entry(&team).unwrap();
        let worker = entry["participants"]
            .as_array()
            .and_then(|items| items.iter().find(|item| item["name"] == "w1"))
            .expect("worker");
        assert_eq!(worker["worktree"]["branch"], "ade/t1-stamp/w1", "{worker}");
        assert_eq!(
            worker["worktree"]["path"],
            "/tmp/worktrees/repo-12345678/t1-w1"
        );
        let read = teams.read(&team, "w1", None).unwrap();
        assert_eq!(read["worktree"]["base"], "abc", "{read}");
        teams.worktree_removed(&team, "w1");
        let entry = teams.entry(&team).unwrap();
        let worker = entry["participants"]
            .as_array()
            .and_then(|items| items.iter().find(|item| item["name"] == "w1"))
            .expect("worker");
        assert!(worker.get("worktree").is_none(), "{worker}");
    }

    #[test]
    fn a_leaderless_team_allows_a_human_spawn() {
        let (mut teams, team) = fixture(json!({}));
        teams.leader_session_closed("i1", "s1");
        let spawn = teams
            .request_spawn_human(&team, "dev", Some("w1"), None, None, None)
            .expect("leaderless spawn");
        assert_eq!(spawn.name, "w1");
    }

    #[test]
    fn missing_spawn_names_do_not_reuse_an_exited_worker() {
        let (mut teams, team) = fixture(json!({"max_workers": 4}));
        add_worker(&mut teams, &team, "w1");
        teams.worker_exited("w1-i", "crash");
        let outcome = teams
            .request_spawn(&team, "dev", None, None, None, None)
            .unwrap();
        let SpawnOutcome::Started(spawn) = outcome else {
            panic!("expected started");
        };
        assert_eq!(spawn.name, "w2");
    }

    fn spawn_item_group(teams: &Teams, team: &str, name: &str) -> Option<String> {
        teams
            .team(team)?
            .inbox
            .iter()
            .find(|item| item.kind == ItemKind::Spawn && item.name.as_deref() == Some(name))
            .and_then(|item| item.group.clone())
    }

    #[test]
    fn spawn_groups_follow_the_leader_prompt() {
        let (mut teams, team) = fixture(json!({"spawn_confirm": {"auto": []}, "max_workers": 8}));
        // No leader prompt is running: every item gets a group of its own.
        for name in ["w1", "w2"] {
            let SpawnOutcome::Awaiting { request, .. } = teams
                .request_spawn(&team, "dev", Some(name), None, None, None)
                .unwrap()
            else {
                panic!("expected approval");
            };
            let item = teams.item(&team, &request).expect("item");
            assert!(item.group.is_some(), "{item:?}");
        }
        let own = spawn_item_group(&teams, &team, "w1");
        let other = spawn_item_group(&teams, &team, "w2");
        assert!(own.is_some() && other.is_some());
        assert_ne!(own, other, "items outside a prompt do not share a group");

        // A bus prompt opens a group that its items share...
        teams
            .send_message(&team, "human", "leader", Kind::Task, "do", None, vec![])
            .unwrap();
        let delivered = teams.take_deliveries(&HashSet::new());
        assert!(delivered
            .iter()
            .any(|request| request.participant == "leader"));
        let prompt_group = teams
            .team(&team)
            .unwrap()
            .current_group
            .clone()
            .expect("a leader prompt opens a group");
        for name in ["w3", "w4"] {
            teams
                .request_spawn(&team, "dev", Some(name), None, None, None)
                .unwrap();
            assert_eq!(
                spawn_item_group(&teams, &team, name).as_deref(),
                Some(prompt_group.as_str())
            );
        }

        // ...and the end of the prompt closes it.
        teams.turn_finished("i1", true, None, String::new());
        teams
            .request_spawn(&team, "dev", Some("w5"), None, None, None)
            .unwrap();
        let after = spawn_item_group(&teams, &team, "w5");
        assert!(after.is_some());
        assert_ne!(after.as_deref(), Some(prompt_group.as_str()));
    }

    #[test]
    fn restore_continues_spawn_group_numbers() {
        let (mut teams, team) = fixture(json!({"spawn_confirm": {"auto": []}, "max_workers": 8}));
        let mut groups = Vec::new();
        for name in ["w1", "w2"] {
            let SpawnOutcome::Awaiting { request, .. } = teams
                .request_spawn(&team, "dev", Some(name), None, None, None)
                .unwrap()
            else {
                panic!("expected approval");
            };
            groups.push(teams.item(&team, &request).unwrap().group.unwrap());
        }
        assert_eq!(groups, vec!["g1".to_string(), "g2".to_string()]);
        let rows = vec![(team.clone(), teams.snapshot_team(&team).expect("snapshot"))];
        let mut restored = Teams::new(new_shared_tokens());
        let (stored, expired) = restored.restore(rows, 0, 0, now_ms(), None);
        assert_eq!(stored, vec![team.clone()]);
        assert!(expired.is_empty());
        // A restored team is suspended until its leader resumes it, and the
        // resume takes the configuration the front end sends again.
        restored
            .configure("/p", config(json!({"spawn_confirm": {"auto": []}})))
            .expect("configure");
        restored.start_resume(&team, "i1", "s1", "opencode");
        let SpawnOutcome::Awaiting { request, .. } = restored
            .request_spawn(&team, "dev", Some("w3"), None, None, None)
            .unwrap()
        else {
            panic!("expected approval");
        };
        assert_eq!(
            restored.item(&team, &request).unwrap().group.as_deref(),
            Some("g3"),
            "a restored open item must not share its group with a new one"
        );
    }

    #[test]
    fn a_leader_exit_ends_the_current_spawn_group() {
        let (mut teams, team) = fixture(json!({"spawn_confirm": {"auto": []}, "max_workers": 8}));
        teams
            .send_message(&team, "human", "leader", Kind::Task, "do", None, vec![])
            .unwrap();
        teams.take_deliveries(&HashSet::new());
        assert!(teams.team(&team).unwrap().current_group.is_some());
        teams.leader_exited("i1", "crash");
        assert!(teams.team(&team).unwrap().current_group.is_none());
        let SpawnOutcome::Awaiting { request, .. } = teams
            .request_spawn(&team, "dev", Some("w1"), None, None, None)
            .unwrap()
        else {
            panic!("expected approval");
        };
        assert_eq!(
            teams.item(&team, &request).unwrap().group.as_deref(),
            Some("g2"),
            "a spawn after the leader exits gets a group of its own"
        );
    }

    #[test]
    fn a_closed_leader_session_ends_the_current_spawn_group() {
        let (mut teams, team) = fixture(json!({"spawn_confirm": {"auto": []}, "max_workers": 8}));
        teams
            .send_message(&team, "human", "leader", Kind::Task, "do", None, vec![])
            .unwrap();
        teams.take_deliveries(&HashSet::new());
        let group = teams
            .team(&team)
            .unwrap()
            .current_group
            .clone()
            .expect("group");
        teams.leader_session_closed("i1", "s1");
        // The team stays, the group does not: the next item gets its own.
        assert!(teams.team(&team).unwrap().current_group.is_none());
        let SpawnOutcome::Awaiting { request, .. } = teams
            .request_spawn(&team, "dev", Some("w1"), None, None, None)
            .unwrap()
        else {
            panic!("expected approval");
        };
        let item = teams.item(&team, &request).unwrap();
        assert_ne!(item.group.as_deref(), Some(group.as_str()));
    }

    #[test]
    fn a_frontend_prompt_opens_and_closes_a_group_too() {
        let (mut teams, team) = fixture(json!({"spawn_confirm": {"auto": []}, "max_workers": 8}));
        teams
            .request_spawn(&team, "dev", Some("w1"), None, None, None)
            .unwrap();
        let before = spawn_item_group(&teams, &team, "w1");
        teams.frontend_prompt_started("i1", "s1");
        let group = teams.team(&team).unwrap().current_group.clone();
        assert!(group.is_some() && group != before);
        teams
            .request_spawn(&team, "dev", Some("w2"), None, None, None)
            .unwrap();
        assert_eq!(spawn_item_group(&teams, &team, "w2"), group);
        teams.frontend_prompt_finished("i1", "s1");
        assert!(teams.team(&team).unwrap().current_group.is_none());
    }

    /// The first front-end prompt of a new chat arrives before any team exists
    /// (v3 creates teams lazily). Spawns of that same turn must still share one
    /// group, so the panel can approve them together (19.6).
    #[test]
    fn a_team_created_mid_turn_inherits_the_turns_spawn_group() {
        let mut teams = Teams::new(new_shared_tokens());
        teams
            .configure("/p", config(json!({"spawn_confirm": {"auto": []}})))
            .expect("configure");
        let (token_id, _) = teams.issue_session_token("i1", "/p", "opencode", Some("s1"));
        assert!(
            teams.session_auth(&token_id).is_some(),
            "bound session token"
        );
        // The prompt starts before `ensure_team` ran: no team exists yet.
        teams.frontend_prompt_started("i1", "s1");
        assert!(teams.is_empty(), "no team was created by the prompt");
        let team = teams
            .ensure_team("i1", "s1", &launch("/p"))
            .expect("ensure team mid-turn");
        let mut groups = Vec::new();
        for name in ["w1", "w2"] {
            let SpawnOutcome::Awaiting { request, .. } = teams
                .request_spawn(&team, "dev", Some(name), None, None, None)
                .expect("spawn")
            else {
                panic!("expected approval");
            };
            groups.push(teams.item(&team, &request).unwrap().group);
        }
        assert!(groups[0].is_some(), "{groups:?}");
        assert_eq!(groups[0], groups[1], "both spawns share one group");
        teams.frontend_prompt_finished("i1", "s1");
        let SpawnOutcome::Awaiting { request, .. } = teams
            .request_spawn(&team, "dev", Some("w3"), None, None, None)
            .expect("spawn")
        else {
            panic!("expected approval");
        };
        let after = teams.item(&team, &request).unwrap().group;
        assert_ne!(after, groups[0], "the next turn gets its own group");
    }

    #[test]
    fn answer_group_answers_every_open_item_in_creation_order() {
        let (mut teams, team) = fixture(json!({"spawn_confirm": {"auto": []}, "max_workers": 8}));
        teams
            .send_message(&team, "human", "leader", Kind::Task, "do", None, vec![])
            .unwrap();
        teams.take_deliveries(&HashSet::new());
        let mut ids = Vec::new();
        for name in ["w1", "w2"] {
            let SpawnOutcome::Awaiting { request, .. } = teams
                .request_spawn(&team, "dev", Some(name), None, None, None)
                .unwrap()
            else {
                panic!("expected approval");
            };
            ids.push(request);
        }
        let group = spawn_item_group(&teams, &team, "w1").expect("group");
        let unknown = teams.answer_group("g999", Some(true)).unwrap_err();
        assert_eq!(unknown.code, UNKNOWN_INBOX);
        let (answers, failed) = teams.answer_group(&group, Some(true)).unwrap();
        assert!(failed.is_empty(), "{failed:?}");
        let answered: Vec<String> = answers.iter().map(|(id, _)| id.clone()).collect();
        assert_eq!(answered, ids, "creation order");
        assert!(answers
            .iter()
            .all(|(_, effect)| matches!(effect, AnswerEffect::Spawn(_))));
        assert!(teams.team(&team).unwrap().participants.contains_key("w1"));
        assert!(teams.team(&team).unwrap().participants.contains_key("w2"));
        assert!(
            teams.answer_group(&group, Some(true)).is_err(),
            "nothing open any more"
        );
    }

    #[test]
    fn stored_workflows_are_capped_per_scope_and_project() {
        let (mut teams, team) = fixture(json!({}));
        for index in 1..=MAX_STORED_WORKFLOWS {
            let workflow = json!({"name": format!("wf{index}"), "summary": "many"});
            teams
                .workflow_save(&team, "/p", &workflow, workflow::Scope::Project, false)
                .unwrap_or_else(|error| panic!("workflow {index}: {error:?}"));
        }
        let extra = json!({"name": "toomany", "summary": "one too many"});
        let error = teams
            .workflow_save(&team, "/p", &extra, workflow::Scope::Project, false)
            .unwrap_err();
        assert_eq!(error.code, NOT_ALLOWED);
        assert_eq!(error.message, "too many workflows");
        // Replacing an existing one is still allowed at the cap.
        let replace = json!({"name": "wf1", "summary": "replaced"});
        teams
            .workflow_save(&team, "/p", &replace, workflow::Scope::Project, true)
            .expect("replace at the cap");
        // Another project has its own budget.
        teams
            .workflow_save(&team, "/other", &extra, workflow::Scope::Project, false)
            .expect("another project's own cap");
    }

    #[test]
    fn answer_group_reports_failed_items_and_answers_the_rest() {
        let (mut teams, team) = fixture(json!({
            "spawn_confirm": {"auto": []},
            "max_workers": 8,
            "templates": {
                "dev": {
                    "key": { "agent": "a", "command": "c", "args": [] },
                    "role": "dev",
                },
                "alt": {
                    "key": { "agent": "a", "command": "c", "args": [] },
                    "role": "alt",
                },
            }
        }));
        teams
            .send_message(&team, "human", "leader", Kind::Task, "do", None, vec![])
            .unwrap();
        teams.take_deliveries(&HashSet::new());
        let mut ids = Vec::new();
        for (name, template) in [("w1", "dev"), ("w2", "alt")] {
            let SpawnOutcome::Awaiting { request, .. } = teams
                .request_spawn(&team, template, Some(name), None, None, None)
                .unwrap()
            else {
                panic!("expected approval");
            };
            ids.push(request);
        }
        let group = teams.item(&team, &ids[0]).unwrap().group.expect("group");

        // The second item's template disappears between the request and the
        // answer: that item fails, the first still starts.
        teams
            .teams
            .get_mut(&team)
            .unwrap()
            .config
            .templates
            .remove("alt");
        let (answers, failed) = teams.answer_group(&group, Some(true)).unwrap();
        assert_eq!(answers.len(), 1, "{failed:?}");
        assert_eq!(answers[0].0, ids[0]);
        assert_eq!(failed.len(), 1);
        assert_eq!(failed[0].0, ids[1]);
        assert_eq!(failed[0].1.code, NOT_ALLOWED);
        assert!(failed[0].1.message.contains("unknown template"));
        assert!(teams.team(&team).unwrap().participants.contains_key("w1"));
        assert!(!teams.team(&team).unwrap().participants.contains_key("w2"));
        assert_eq!(
            teams.item(&team, &ids[1]).unwrap().state,
            ItemState::Open,
            "a failed item stays open"
        );

        // When every remaining item fails, the first error comes back as the
        // call's error and nothing is answered.
        teams
            .teams
            .get_mut(&team)
            .unwrap()
            .config
            .templates
            .remove("dev");
        let error = teams.answer_group(&group, Some(true)).unwrap_err();
        assert_eq!(error.code, NOT_ALLOWED);
        assert_eq!(teams.item(&team, &ids[1]).unwrap().state, ItemState::Open);
    }

    #[test]
    fn workflow_configuration_and_templates_are_validated() {
        let mut teams = Teams::new(new_shared_tokens());
        let bad_workflow = config(json!({
            "workflows": {
                "review": { "summary": "review", "team": [{"name": "w1", "template": "nope"}] }
            }
        }));
        let error = teams.configure("/p", bad_workflow).unwrap_err();
        assert!(error.message.contains("workflows.review"), "{error:?}");

        let bad_model = config(json!({
            "templates": { "dev": {
                "key": { "agent": "a", "command": "c", "args": [] },
                "models": ["m1"],
            } },
            "workflows": {
                "review": { "summary": "review", "team": [{"name": "w1", "template": "dev", "model": "m2"}] }
            }
        }));
        let error = teams.configure("/p", bad_model).unwrap_err();
        assert!(error.message.contains("workflows.review"), "{error:?}");

        let bad_default = config(json!({"default_workflow": "nope"}));
        let error = teams.configure("/p", bad_default).unwrap_err();
        assert!(error.message.contains("default_workflow"), "{error:?}");

        let good = config(json!({
            "templates": {
                "dev": {
                    "key": { "agent": "a", "command": "c", "args": [] },
                    "models": ["m1"],
                    "tool_style": "mcp_proxy",
                }
            },
            "default_workflow": "default",
            "workflows": {
                "review": {
                    "summary": "review",
                    "text": "step",
                    "columns": ["待开发"],
                    "team": [{"name": "w1", "template": "dev", "model": "m1"}]
                }
            }
        }));
        teams.configure("/p", good).expect("valid configuration");
        let config = teams.config_for("/p");
        let dev = &config.templates["dev"];
        assert!(dev.role.is_empty(), "role is optional now");
        assert_eq!(dev.models, vec!["m1"]);
        assert_eq!(dev.tool_style, ToolStyle::McpProxy);
        assert_eq!(config.default_workflow.as_deref(), Some("default"));
        assert_eq!(config.workflows["review"].scope, workflow::Scope::Config);
        assert_eq!(
            config.workflows["review"].team[0].model.as_deref(),
            Some("m1")
        );
    }

    #[test]
    fn participant_entries_carry_agent_model_and_label() {
        let (mut teams, team) = fixture(json!({"spawn_confirm": {"auto": ["dev"]}}));
        let entry = teams.entry(&team).unwrap();
        let leader = &entry["participants"][0];
        assert_eq!(leader["name"], "leader");
        assert_eq!(leader["agent"], "opencode");
        assert_eq!(leader["model"], Value::Null);
        assert_eq!(leader["label"], "leader");
        assert!(
            leader.get("template").is_none(),
            "leader has no template key"
        );

        let outcome = teams
            .request_spawn_labeled(
                &team,
                "dev",
                Some("w1"),
                Some("m1"),
                None,
                None,
                Some("reviewer"),
            )
            .expect("spawn with a label");
        assert!(matches!(outcome, SpawnOutcome::Started(_)), "{outcome:?}");
        let entry = teams.entry(&team).unwrap();
        let worker = entry["participants"]
            .as_array()
            .unwrap()
            .iter()
            .find(|participant| participant["name"] == "w1")
            .expect("w1");
        assert_eq!(worker["template"], "dev");
        assert_eq!(worker["agent"], "a");
        assert_eq!(worker["model"], "m1");
        assert_eq!(worker["label"], "reviewer");

        // Without a label the template name is the display label (19.12).
        teams
            .request_spawn(&team, "dev", Some("w2"), None, None, None)
            .expect("spawn without a label");
        let entry = teams.entry(&team).unwrap();
        let worker = entry["participants"]
            .as_array()
            .unwrap()
            .iter()
            .find(|participant| participant["name"] == "w2")
            .expect("w2");
        assert_eq!(worker["label"], "dev");
    }

    #[test]
    fn a_spawn_blocked_by_max_workers_clears_the_owner() {
        let (mut teams, team) = fixture(json!({
            "max_workers": 2,
            "spawn_confirm": {"auto": []}
        }));
        let SpawnOutcome::Awaiting { request, .. } = teams
            .request_spawn(&team, "dev", Some("w1"), None, None, None)
            .expect("pending spawn")
        else {
            panic!("the spawn must await approval");
        };
        // One live worker fills the limit by the time the request is approved.
        teams
            .request_spawn_human(&team, "dev", Some("w0"), None, None, None)
            .expect("first worker");
        teams.teams.get_mut(&team).unwrap().config.max_workers = 1;
        teams
            .board_update(
                &team,
                &json!({
                    "columns": ["todo"],
                    "upsert": [{"id": "C1", "title": "one", "column": "todo", "owner": "w1"}]
                }),
                1,
            )
            .expect("owner awaiting approval");
        teams
            .answer(&request, None, None, Some(true))
            .expect("approval at the limit");
        let card = &teams.team(&team).unwrap().board.cards[0];
        assert_eq!(card.owner, None, "the failed approval must clear the owner");
        let read = teams.read(&team, "leader", None).unwrap();
        assert!(read["messages"]
            .as_array()
            .unwrap()
            .iter()
            .any(|message| message["kind"] == "notice"
                && message["body"]
                    .as_str()
                    .is_some_and(|body| body.contains("worker limit"))));
    }

    #[test]
    fn leader_exit_orphans_a_spawn_and_releases_its_name_and_owner() {
        let (mut teams, team) = fixture(json!({"spawn_confirm": {"auto": []}}));
        let SpawnOutcome::Awaiting { request, name } = teams
            .request_spawn(&team, "dev", Some("w1"), None, None, None)
            .expect("pending spawn")
        else {
            panic!("the spawn must await approval");
        };
        teams
            .board_update(
                &team,
                &json!({
                    "columns": ["todo"],
                    "upsert": [{"id": "C1", "title": "one", "column": "todo", "owner": "w1"}]
                }),
                1,
            )
            .unwrap();
        teams.leader_exited("i1", "crash");
        let team_ref = teams.team(&team).unwrap();
        assert_eq!(team_ref.board.cards[0].owner, None);
        assert!(!team_ref.reserved_names.contains(&name));
        assert_eq!(
            team_ref
                .inbox
                .iter()
                .find(|item| item.id == request)
                .map(|item| item.state),
            Some(ItemState::Orphaned)
        );
    }

    #[test]
    fn close_orphans_spawns_without_leaving_a_dirty_board() {
        let (mut teams, team) = fixture(json!({"spawn_confirm": {"auto": []}}));
        teams
            .request_spawn(&team, "dev", Some("w1"), None, None, None)
            .expect("pending spawn");
        teams
            .board_update(
                &team,
                &json!({
                    "columns": ["todo"],
                    "upsert": [{"id": "C1", "title": "one", "column": "todo", "owner": "w1"}]
                }),
                1,
            )
            .unwrap();
        teams.close(&team).expect("close");
        assert!(teams.team(&team).is_none());
        let board = teams.closed_board(&team).expect("closed board");
        assert_eq!(board.cards[0].owner, None);
        assert_eq!(board.cards[0].updated_by, "service");
        let reserved = teams.closed_reserved_names(&team).expect("reserved names");
        assert!(!reserved.contains("w1"), "the name must be released");
    }

    #[test]
    fn a_restored_leaderless_team_orphans_spawns_and_clears_owners() {
        let (mut teams, team) = fixture(json!({"spawn_confirm": {"auto": []}}));
        let SpawnOutcome::Awaiting { request, name } = teams
            .request_spawn(&team, "dev", Some("w1"), None, None, None)
            .expect("pending spawn")
        else {
            panic!("the spawn must await approval");
        };
        teams
            .board_update(
                &team,
                &json!({
                    "columns": ["todo"],
                    "upsert": [{"id": "C1", "title": "one", "column": "todo", "owner": "w1"}]
                }),
                1,
            )
            .unwrap();
        let board = teams.team(&team).unwrap().board.clone();
        let board_json = serde_json::to_string(&board).unwrap();
        teams
            .teams
            .get_mut(&team)
            .unwrap()
            .participants
            .get_mut("leader")
            .unwrap()
            .state = ParticipantState::Exited;
        let snapshot = teams.snapshot_team(&team).expect("snapshot");
        let (max_team, max_inbox) = teams.counters();
        let mut restored = Teams::new(new_shared_tokens());
        restored
            .configure("/p", config(json!({"spawn_confirm": {"auto": []}})))
            .unwrap();
        restored.restore(
            vec![(team.clone(), snapshot)],
            max_team,
            max_inbox,
            now_ms(),
            None,
        );
        restored
            .restore_board(&team, board.rev, &board_json, vec![])
            .expect("board");
        restored.orphan_leaderless_spawns();
        let team_ref = restored.team(&team).unwrap();
        assert!(team_ref.leaderless);
        assert!(!team_ref.reserved_names.contains(&name));
        assert_eq!(team_ref.board.cards[0].owner, None);
        assert_eq!(
            team_ref
                .inbox
                .iter()
                .find(|item| item.id == request)
                .map(|item| item.state),
            Some(ItemState::Orphaned)
        );
    }

    #[test]
    fn a_restored_pending_spawn_keeps_its_owner_until_answered() {
        let (mut teams, team) = fixture(json!({"spawn_confirm": {"auto": []}}));
        let SpawnOutcome::Awaiting { request, name } = teams
            .request_spawn(&team, "dev", Some("w1"), None, None, None)
            .expect("pending spawn")
        else {
            panic!("the spawn must await approval");
        };
        teams
            .board_update(
                &team,
                &json!({
                    "columns": ["todo"],
                    "upsert": [{"id": "C1", "title": "one", "column": "todo", "owner": "w1"}]
                }),
                1,
            )
            .unwrap();
        let board = teams.team(&team).unwrap().board.clone();
        let board_json = serde_json::to_string(&board).unwrap();
        let snapshot = teams.snapshot_team(&team).expect("snapshot");
        let (max_team, max_inbox) = teams.counters();
        let mut restored = Teams::new(new_shared_tokens());
        restored
            .configure("/p", config(json!({"spawn_confirm": {"auto": []}})))
            .unwrap();
        restored.restore(
            vec![(team.clone(), snapshot)],
            max_team,
            max_inbox,
            now_ms(),
            None,
        );
        restored
            .restore_board(&team, board.rev, &board_json, vec![])
            .expect("board");
        let team_ref = restored.team(&team).unwrap();
        assert!(team_ref.reserved_names.contains(&name));
        assert_eq!(team_ref.board.cards[0].owner.as_deref(), Some("w1"));
        assert_eq!(
            team_ref
                .inbox
                .iter()
                .find(|item| item.id == request)
                .map(|item| item.state),
            Some(ItemState::Open)
        );
    }

    #[test]
    fn identity_fields_survive_a_restore() {
        let (mut teams, team) = fixture(json!({"spawn_confirm": {"auto": ["dev"]}}));
        teams
            .request_spawn_labeled(
                &team,
                "dev",
                Some("w1"),
                Some("m1"),
                None,
                None,
                Some("reviewer"),
            )
            .expect("spawn");
        let json = teams.snapshot_team(&team).expect("snapshot");
        let (max_team, max_inbox) = teams.counters();
        let mut restored = Teams::new(new_shared_tokens());
        restored.configure("/p", config(json!({}))).unwrap();
        restored.restore(
            vec![(team.clone(), json)],
            max_team,
            max_inbox,
            now_ms(),
            None,
        );
        let entry = restored.entry(&team).unwrap();
        let worker = entry["participants"]
            .as_array()
            .unwrap()
            .iter()
            .find(|participant| participant["name"] == "w1")
            .expect("w1");
        assert_eq!(worker["template"], "dev");
        assert_eq!(worker["agent"], "a");
        assert_eq!(worker["model"], "m1");
        assert_eq!(worker["label"], "reviewer");
    }

    #[test]
    fn labels_are_one_line_and_short() {
        let (mut teams, team) = fixture(json!({"spawn_confirm": {"auto": ["dev"]}}));
        for label in ["", "a\nb", "12345678901234567"] {
            let error = teams
                .request_spawn_labeled(&team, "dev", Some("w1"), None, None, None, Some(label))
                .expect_err(label);
            assert_eq!(error.code, INVALID_TEAM_PARAM, "{error:?}");
        }
    }

    #[test]
    fn questions_are_normalised_validated_and_answered() {
        let (mut teams, team) = fixture(json!({}));
        assert!(parse_questions(&json!([])).is_err());
        assert!(parse_questions(&json!([{"header": "1234567890123", "question": "?"}])).is_err());
        assert!(parse_questions(
            &json!([{"header": "h", "question": "?", "options": [{"label": "one"}]}])
        )
        .is_err());
        assert!(parse_questions(&json!([{"header": "h", "question": "?", "unknown": 1}])).is_err());

        // 18.5 remains one question with the header "Question".
        let legacy = teams
            .ask_human(
                &team,
                "leader",
                "keep the API?",
                Some(vec!["yes".to_string()]),
            )
            .expect("legacy question");
        let entry = teams.entry(&team).unwrap();
        let item = &entry["inbox"][0];
        assert_eq!(item["questions"][0]["header"], "Question");
        // One legacy option is not a choice: it becomes a text hint.
        assert!(item["questions"][0].get("options").is_none());
        assert!(item["questions"][0]["question"]
            .as_str()
            .is_some_and(|question| question.contains("yes")));
        assert_eq!(item["options"][0], "yes");
        teams
            .answer(&legacy, Some("yes".to_string()), None, None)
            .expect("legacy answer");

        let questions = parse_questions(&json!([
            {
                "header": "范围",
                "question": "保留旧 API 吗？",
                "options": [
                    {"label": "保留", "description": "对调用方没有影响"},
                    {"label": "删除"}
                ]
            },
            {
                "header": "测试",
                "question": "跑哪些？",
                "options": [{"label": "单元"}, {"label": "集成"}],
                "multi_select": true
            }
        ]))
        .expect("questions");
        let request = teams
            .ask_human_questions(&team, "leader", questions, None)
            .expect("ask");
        let entry = teams.entry(&team).unwrap();
        let item = entry["inbox"]
            .as_array()
            .unwrap()
            .iter()
            .find(|item| item["id"] == request)
            .expect("question item");
        assert_eq!(item["questions"].as_array().unwrap().len(), 2);
        assert_eq!(item["questions"][0]["header"], "范围");
        assert_eq!(item["questions"][1]["multi_select"], true);

        let answers = parse_answers(&json!([
            {"selected": ["保留"]},
            {"selected": ["单元", "集成"], "text": "再加 e2e"}
        ]))
        .expect("answers");
        teams
            .answer_with(&request, Some(answers), None, None, None)
            .expect("answer");
        let read = teams.read(&team, "leader", None).unwrap();
        let answer = read["messages"]
            .as_array()
            .unwrap()
            .iter()
            .find(|message| {
                message["kind"] == "answer"
                    && message["body"]
                        .as_str()
                        .is_some_and(|body| body.contains("范围"))
            })
            .expect("answer message");
        assert_eq!(answer["body"], "范围: 保留\n测试: 单元, 集成\n再加 e2e");

        // 19.13 validation: non-empty question, unique labels/selected, no
        // control characters, no ", " in a label.
        assert!(parse_questions(&json!([{"header": "h", "question": ""}])).is_err());
        assert!(parse_questions(&json!([{
            "header": "h",
            "question": "q",
            "options": [{"label": "same"}, {"label": "same"}]
        }]))
        .is_err());
        assert!(parse_questions(&json!([{
            "header": "h",
            "question": "q",
            "options": [{"label": "a, b"}, {"label": "c"}]
        }]))
        .is_err());
        assert!(parse_questions(&json!([{
            "header": "h\t",
            "question": "q"
        }]))
        .is_err());
        assert!(parse_answers(&json!([
            {"selected": ["a", "a"]}
        ]))
        .is_err());
        let duplicate_selected = teams
            .ask_human_questions(
                &team,
                "leader",
                parse_questions(&json!([{
                    "header": "h",
                    "question": "q",
                    "options": [{"label": "a"}, {"label": "b"}]
                }]))
                .unwrap(),
                None,
            )
            .unwrap();
        assert!(teams
            .answer_with(
                &duplicate_selected,
                Some(vec![QuestionAnswer {
                    selected: vec!["a".to_string(), "a".to_string()],
                    text: None
                }]),
                None,
                None,
                None
            )
            .is_err());

        // The 18.5 form applies the same checks after normalisation.
        for legacy in [
            (String::new(), None),
            ("q".to_string(), Some(vec![String::new()])),
            (
                "q".to_string(),
                Some(vec!["a".to_string(), "a".to_string()]),
            ),
            (
                "q".to_string(),
                Some(vec!["a, b".to_string(), "c".to_string()]),
            ),
            ("q".to_string(), Some(vec!["a\tb".to_string()])),
        ] {
            assert!(teams
                .ask_human(&team, "leader", &legacy.0, legacy.1)
                .is_err());
        }
        // A single 18.5 option stays a text hint and keeps its old 1 KiB limit.
        let hint = "h".repeat(500);
        assert!(teams
            .ask_human(&team, "leader", "hint?", Some(vec![hint]))
            .is_ok());
        // A rejected ask does not burn an inbox id.
        let before = teams.counters();
        assert!(teams
            .ask_human_questions(
                "nope",
                "leader",
                parse_questions(&json!([{"header": "h", "question": "q"}])).unwrap(),
                None,
            )
            .is_err());
        assert_eq!(before, teams.counters());

        // 18.5 compatibility: `text` wins over `option`; an option on a
        // question without options is free text.
        let legacy = teams
            .ask_human(
                &team,
                "leader",
                "pick",
                Some(vec!["a".to_string(), "b".to_string()]),
            )
            .unwrap();
        teams
            .answer(
                &legacy,
                Some("typed".to_string()),
                Some("nope".to_string()),
                None,
            )
            .expect("text wins, option is not checked");
        let free = teams.ask_human(&team, "leader", "free?", None).unwrap();
        teams
            .answer(&free, None, Some("anything".to_string()), None)
            .expect("option on a question without options is text");

        // Count, labels and single-select are checked; free text always works.
        let request = teams
            .ask_human_questions(
                &team,
                "leader",
                parse_questions(&json!([{
                    "header": "h",
                    "question": "q",
                    "options": [{"label": "a"}, {"label": "b"}]
                }]))
                .unwrap(),
                None,
            )
            .unwrap();
        assert!(teams
            .answer_with(
                &request,
                Some(parse_answers(&json!([])).unwrap()),
                None,
                None,
                None
            )
            .is_err());
        assert!(teams
            .answer_with(
                &request,
                Some(vec![QuestionAnswer {
                    selected: vec!["nope".to_string()],
                    text: None
                }]),
                None,
                None,
                None
            )
            .is_err());
        assert!(teams
            .answer_with(
                &request,
                Some(vec![QuestionAnswer {
                    selected: vec!["a".to_string(), "b".to_string()],
                    text: None
                }]),
                None,
                None,
                None
            )
            .is_err());
        teams
            .answer_with(
                &request,
                Some(vec![QuestionAnswer {
                    selected: Vec::new(),
                    text: Some("自由文本".to_string()),
                }]),
                None,
                None,
                None,
            )
            .expect("free text answer");
    }

    #[test]
    fn a_pending_spawn_can_own_a_card_and_refusal_clears_it() {
        let (mut teams, team) = fixture(json!({"spawn_confirm": {"auto": []}}));
        let SpawnOutcome::Awaiting { request, name } = teams
            .request_spawn(&team, "dev", Some("w1"), None, None, None)
            .expect("spawn")
        else {
            panic!("the spawn must await approval");
        };
        assert_eq!(name, "w1");
        teams
            .board_update(
                &team,
                &json!({
                    "columns": ["todo"],
                    "upsert": [{"id": "C1", "title": "one", "column": "todo", "owner": "w1"}]
                }),
                1,
            )
            .expect("the pending name can own a card");
        // An open spawn reserves the name.
        assert!(teams
            .request_spawn(&team, "dev", Some("w1"), None, None, None)
            .is_err());

        teams
            .answer(&request, None, None, Some(false))
            .expect("refuse");
        let board = teams.entry(&team).unwrap()["board_rev"].clone();
        assert!(board.as_u64().unwrap_or(0) > 0);
        let card = &teams.team(&team).unwrap().board.cards[0];
        assert_eq!(card.owner, None);
        assert_eq!(card.updated_by, "service");
        let events = teams.drain_events();
        assert!(events
            .iter()
            .any(|event| matches!(event, TeamEvent::Board(id, _) if id == &team)));
        let read = teams.read(&team, "leader", None).unwrap();
        assert!(read["messages"]
            .as_array()
            .unwrap()
            .iter()
            .any(|message| message["kind"] == "notice"
                && message["body"]
                    .as_str()
                    .is_some_and(|body| body.contains("owner cleared on C1"))));
    }
    // -- section 20 --------------------------------------------------------

    fn launch(cwd: &str) -> LeaderLaunch {
        LeaderLaunch {
            cwd: cwd.to_string(),
            key: InstanceKey {
                agent: "opencode".to_string(),
                command: "opencode-acp".to_string(),
                args: vec![],
                cwd: cwd.to_string(),
                capabilities: Value::Null,
            },
            env: None,
            #[cfg(unix)]
            launch: None,
        }
    }

    /// Issue and bind a session token the way the hub does, and return its id.
    fn session(teams: &mut Teams, instance: &str, cwd: &str, session: &str) -> String {
        let (token_id, _token) =
            teams.issue_session_token(instance, cwd, "opencode", Some(session));
        token_id
    }

    #[test]
    fn a_chat_alone_creates_no_team_and_ensure_team_creates_one() {
        let mut teams = Teams::new(new_shared_tokens());
        teams.configure("/p", config(json!({}))).expect("configure");
        session(&mut teams, "i1", "/p", "s1");
        assert!(teams.list()["teams"].as_array().unwrap().is_empty());

        let team = teams
            .ensure_team("i1", "s1", &launch("/p"))
            .expect("the first request creates the team");
        let entry = teams.entry(&team).expect("entry");
        assert_eq!(entry["leader"]["sessionId"], "s1");
        // Asking again from the same session returns the same team.
        assert_eq!(teams.ensure_team("i1", "s1", &launch("/p")).unwrap(), team);
    }

    #[test]
    fn another_chat_is_told_to_hand_the_team_over() {
        let (mut teams, team) = fixture(json!({}));
        let second = session(&mut teams, "i2", "/p", "s2");
        let error = teams
            .ensure_team("i2", "s2", &launch("/p"))
            .expect_err("led by another chat");
        assert_eq!(error.code, NOT_ALLOWED);
        let data = error.data.expect("data");
        assert_eq!(data["reason"], "led_by");
        assert_eq!(data["team"], team);
        assert_eq!(data["leader"]["sessionId"], "s1");
        assert_eq!(teams.session_role(&second).0, None);

        // The person answers `move`: the team changes leader and the second
        // chat's tools become the leader set.
        let request = teams.create_handover(&team, "i2", "s2");
        let (effect, _) = teams
            .answer_with(&request, None, None, Some("move".to_string()), None)
            .expect("move");
        let AnswerEffect::Handover {
            instance,
            session,
            hand_over,
            ..
        } = effect
        else {
            panic!("handover effect: {effect:?}");
        };
        assert!(hand_over);
        teams
            .set_leader(&team, &instance, &session)
            .expect("set leader");
        assert_eq!(
            teams.team(&team).unwrap().leader_session.as_deref(),
            Some("s2")
        );
        assert_eq!(teams.session_role(&second).0.as_deref(), Some("leader"));
        assert_eq!(
            teams.team(&team).unwrap().participants["leader"]
                .session
                .as_deref(),
            Some("s2")
        );
    }

    #[test]
    fn an_off_switch_hides_the_tools_and_ensure_team_refuses() {
        let mut teams = Teams::new(new_shared_tokens());
        teams.configure("/p", config(json!({}))).expect("configure");
        session(&mut teams, "i1", "/p", "s1");
        teams.set_switch("opencode", "s1", false);
        let error = teams
            .ensure_team("i1", "s1", &launch("/p"))
            .expect_err("switch off");
        assert_eq!(error.data.unwrap()["reason"], "off");
        // A configuration may be disabled as a whole.
        teams.set_switch("opencode", "s1", true);
        teams
            .configure("/p", config(json!({"enabled": false})))
            .unwrap();
        assert!(!teams.enabled_for("opencode", "s1", "/p"));
        // A session without a token has no tools either.
        let error = teams.ensure_team("i9", "s9", &launch("/p")).unwrap_err();
        assert_eq!(error.data.unwrap()["reason"], "no_tools");
    }

    #[test]
    fn a_stopped_worker_can_be_removed_and_frees_its_name() {
        let (mut teams, team) = fixture(json!({}));
        let instance = add_worker(&mut teams, &team, "w1");
        let returned = teams
            .stop_worker(&team, "w1", false, true, true, false)
            .unwrap();
        assert_eq!(returned.instance.as_deref(), Some(instance.as_str()));
        let worker = &teams.team(&team).unwrap().participants["w1"];
        assert_eq!(worker.state, ParticipantState::Exited);
        assert_eq!(worker.reason.as_deref(), Some("stopped"));
        assert!(teams.read(&team, "leader", None).unwrap()["messages"]
            .as_array()
            .unwrap()
            .iter()
            .any(|message| message["body"]
                .as_str()
                .is_some_and(|body| body.contains("w1 stopped by the person"))));

        let second = add_worker(&mut teams, &team, "w2");
        let stopped = teams
            .stop_worker(&team, "w2", true, true, true, false)
            .unwrap();
        // `remove: true` drops the participant only once it really exited.
        assert!(teams.team(&team).unwrap().participants.contains_key("w2"));
        teams.worker_exited(&second, "stopped");
        assert!(!teams.team(&team).unwrap().participants.contains_key("w2"));
        assert!(!teams.team(&team).unwrap().order.contains(&"w2".to_string()));
        assert!(teams.token_role(&second).is_none());
        assert_eq!(stopped.instance.as_deref(), Some(second.as_str()));
        // The name is free again: a new spawn may take it.
        assert!(teams
            .request_spawn(&team, "dev", Some("w2"), None, None, None)
            .is_ok());
        assert!(teams
            .stop_worker(&team, "leader", false, true, false, false)
            .is_err());
        assert!(teams
            .stop_worker(&team, "nobody", false, true, false, false)
            .is_err());
    }

    #[test]
    fn an_empty_template_table_gets_a_builtin_worker_from_the_leader() {
        let mut teams = Teams::new(new_shared_tokens());
        teams.configure("/p", json!({"templates": {}})).unwrap();
        session(&mut teams, "i1", "/p", "s1");
        let team = teams.ensure_team("i1", "s1", &launch("/p")).unwrap();
        let template = &teams.team(&team).unwrap().config.templates["worker"];
        assert_eq!(template.key.agent, "opencode");
        assert_eq!(template.key.command, "opencode-acp");
        assert!(template.worktree);
        assert_eq!(template.role, "");
        // Workflows and automatic spawns may name it.
        teams
            .configure(
                "/p",
                json!({
                    "templates": {},
                    "spawn_confirm": {"auto": ["worker"]},
                    "workflows": {
                        "flow": {
                            "name": "flow",
                            "summary": "one worker",
                            "team": [{"name": "w1", "template": "worker"}]
                        }
                    }
                }),
            )
            .expect("builtin validation");
    }

    #[test]
    fn a_settled_switch_round_trips_through_the_database_rows() {
        let mut teams = Teams::new(new_shared_tokens());
        teams.restore_switches(vec![
            ("opencode".to_string(), "s1".to_string(), false),
            ("opencode".to_string(), "s2".to_string(), true),
        ]);
        assert_eq!(teams.switch("opencode", "s1"), Some(false));
        assert_eq!(teams.switch("opencode", "s2"), Some(true));
        assert!(!teams.set_switch("opencode", "s2", true));
    }
}
