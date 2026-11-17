//! Teams and the agent-to-agent bus (PROTOCOL.md section 18).
//!
//! This module is the pure state machine: teams, participants, messages,
//! inbox items, limits and the token registry shared with the connection
//! layer. I/O (spawning agents, sending frames, broadcasts) is done by
//! `hub::teams`, which owns the hub and calls these methods.

pub mod activity;
pub mod board;
pub mod mcp;
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
}

impl Role {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Leader => "leader",
            Self::Worker => "worker",
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
        }
    }
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
            }
            ItemKind::Spawn => {
                out["template"] = json!(self.template);
                out["name"] = json!(self.name);
                if let Some(task) = &self.task {
                    out["task"] = json!(task);
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
    /// Start this worker in a git worktree (18.12).
    pub worktree: bool,
}

#[derive(Debug, Clone)]
pub struct TeamConfig {
    pub max_workers: u64,
    pub spawn_auto: HashSet<String>,
    pub max_turns_per_task: u64,
    pub max_turns_total: u64,
    pub templates: HashMap<String, Template>,
    /// Parent directory for worker worktrees; required when a template asks
    /// for one (18.12).
    pub worktree_root: Option<String>,
}

impl Default for TeamConfig {
    fn default() -> Self {
        Self {
            max_workers: 3,
            spawn_auto: HashSet::new(),
            max_turns_per_task: 30,
            max_turns_total: 200,
            templates: HashMap::new(),
            worktree_root: None,
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
    /// A leader bound while suspended but no configuration had arrived yet.
    pub pending_resume: Option<(String, String)>,
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
    bound: bool,
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

#[derive(Debug, Clone)]
pub struct SpawnRequest {
    pub team: String,
    pub name: String,
    pub template: String,
    pub task: Option<String>,
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

#[derive(Debug)]
pub enum BindOutcome {
    /// A live team, or a new one.
    Active(Value),
    /// A suspended team whose first matching bind starts the resume.
    Resume { team: String, entry: Value },
}

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
        }
    }

    pub fn is_empty(&self) -> bool {
        self.teams.is_empty()
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

    // -- tokens ------------------------------------------------------------

    fn create_token(
        &mut self,
        role: Role,
        instance: Option<String>,
        cwd: Option<String>,
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
                bound: false,
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

    fn revoke(&mut self, token_id: &str) {
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

    // -- leader ------------------------------------------------------------

    pub fn leader_server(
        &mut self,
        instance: &str,
        cwd: &str,
        instance_cwd: &str,
    ) -> Result<(Value, String), TeamError> {
        if cwd != instance_cwd {
            return Err(TeamError::invalid("cwd must equal the instance's cwd"));
        }
        if let Some(team_id) = self.by_cwd.get(cwd) {
            let team = self.teams.get(team_id).expect("cwd index");
            if team.suspended {
                // A suspended team accepts a leader server for any instance in
                // its cwd; the bind decides whether the session matches.
            } else if team.leader_instance.as_deref() != Some(instance) {
                return Err(TeamError::not_allowed("a team already exists for this cwd"));
            }
        }
        let (token_id, token) = self.create_token(
            Role::Leader,
            Some(instance.to_string()),
            Some(cwd.to_string()),
        );
        let command = std::env::current_exe()
            .ok()
            .and_then(|path| path.to_str().map(str::to_string))
            .unwrap_or_else(|| "nvim_ade_server".to_string());
        let server = json!({
            "name": "ade-team",
            "command": command,
            "args": ["mcp"],
            "env": [{ "name": "ADE_TEAM_TOKEN", "value": token }],
        });
        Ok((server, token_id))
    }

    /// Move a suspended team to active once; returns the entry to send. The
    /// caller starts the participants and then calls `finish_resume`.
    pub fn start_resume(&mut self, team_id: &str, instance: &str, session: &str) -> Value {
        let config = self
            .teams
            .get(team_id)
            .map(|team| self.config_for(&team.cwd))
            .unwrap_or_default();
        if let Some(team) = self.teams.get_mut(team_id) {
            team.suspended = false;
            team.suspended_at = None;
            team.pending_resume = None;
            team.leader_instance = Some(instance.to_string());
            team.leader_session = Some(session.to_string());
            team.leaderless = false;
            team.config = config;
            if let Some(leader) = team.participants.get_mut("leader") {
                leader.instance = Some(instance.to_string());
                leader.session = Some(session.to_string());
                leader.set_state(ParticipantState::Idle);
                leader.starting = false;
            }
        }
        self.events.push(TeamEvent::Changed(team_id.to_string()));
        json!({ "team": team_entry(&self.teams[team_id]) })
    }

    /// The token bound for a still-suspended team whose configure has just
    /// arrived.
    pub fn config_resume(&self, cwd: &str) -> Option<(String, String, String)> {
        let team_id = self.by_cwd.get(cwd)?.clone();
        let team = self.teams.get(&team_id)?;
        if !team.suspended || !self.configs.contains_key(cwd) {
            return None;
        }
        let (instance, session) = team.pending_resume.clone()?;
        if team.leader_session.as_deref() != Some(session.as_str()) {
            return None;
        }
        Some((team_id, instance, session))
    }

    pub fn clear_pending_resume(&mut self, team_id: &str) {
        if let Some(team) = self.teams.get_mut(team_id) {
            team.pending_resume = None;
        }
    }

    pub fn clear_instance_pending(&mut self, instance: &str) {
        for team in self.teams.values_mut() {
            if team
                .pending_resume
                .as_ref()
                .is_some_and(|(bound, _)| bound == instance)
            {
                team.pending_resume = None;
            }
        }
    }

    pub fn bind_leader(
        &mut self,
        instance: &str,
        session: &str,
        token_id: &str,
    ) -> Result<BindOutcome, TeamError> {
        let Some(record) = self.token_records.get(token_id) else {
            return Err(TeamError::not_allowed("unknown leader token"));
        };
        if record.role != Role::Leader || record.instance.as_deref() != Some(instance) {
            return Err(TeamError::not_allowed(
                "leader token does not belong to this instance",
            ));
        }
        let cwd = record
            .cwd
            .clone()
            .ok_or_else(|| TeamError::not_allowed("leader token has no cwd"))?;

        if let Some(team_id) = self.by_cwd.get(&cwd).cloned() {
            let suspended = self.teams[&team_id].suspended;
            if suspended {
                if self.teams[&team_id].leader_session.as_deref() != Some(session) {
                    return Err(TeamError::not_allowed(
                        "the resumed session is not the team's leader session",
                    ));
                }
                if !self.configs.contains_key(&cwd) {
                    // A bind before configure is accepted: the token is bound
                    // and the team stays suspended until configure arrives.
                    if let Some(team) = self.teams.get_mut(&team_id) {
                        team.pending_resume = Some((instance.to_string(), session.to_string()));
                    }
                    if let Some(record) = self.token_records.get_mut(token_id) {
                        record.bound = true;
                        record.team = Some(team_id.clone());
                        record.name = Some("leader".to_string());
                    }
                    self.token_entry(token_id);
                    self.events.push(TeamEvent::Changed(team_id.clone()));
                    return Ok(BindOutcome::Active(json!({
                        "team": team_entry(&self.teams[&team_id])
                    })));
                }
                let entry = self.start_resume(&team_id, instance, session);
                if let Some(record) = self.token_records.get_mut(token_id) {
                    record.bound = true;
                    record.team = Some(team_id.clone());
                    record.name = Some("leader".to_string());
                }
                self.token_entry(token_id);
                return Ok(BindOutcome::Resume {
                    team: team_id,
                    entry,
                });
            } else {
                let team = self.teams.get(&team_id).expect("cwd index");
                if team.leader_instance.as_deref() != Some(instance)
                    || team.leader_session.as_deref() != Some(session)
                {
                    return Err(TeamError::not_allowed(
                        "the team already has a different leader session",
                    ));
                }
            }
            if let Some(record) = self.token_records.get_mut(token_id) {
                record.bound = true;
                record.team = Some(team_id.clone());
                record.name = Some("leader".to_string());
            }
            self.token_entry(token_id);
            return Ok(BindOutcome::Active(
                json!({ "team": team_entry(&self.teams[&team_id]) }),
            ));
        }

        self.next_team += 1;
        let id = format!("t{}", self.next_team);
        let config = self.config_for(&cwd);
        let mut team = Team {
            id: id.clone(),
            cwd: cwd.clone(),
            leaderless: false,
            closed: false,
            suspended: false,
            suspended_at: None,
            pending_resume: None,
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
        };
        let mut leader = Participant::new("leader", Role::Leader);
        leader.instance = Some(instance.to_string());
        leader.session = Some(session.to_string());
        team.participants.insert("leader".to_string(), leader);
        let entry = team_entry(&team);
        self.by_cwd.insert(cwd, id.clone());
        self.by_instance
            .insert(instance.to_string(), (id.clone(), "leader".to_string()));
        self.teams.insert(id.clone(), team);
        if let Some(record) = self.token_records.get_mut(token_id) {
            record.bound = true;
            record.team = Some(id.clone());
            record.name = Some("leader".to_string());
        }
        self.token_entry(token_id);
        self.events.push(TeamEvent::Changed(id));
        Ok(BindOutcome::Active(json!({ "team": entry })))
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

    pub fn close(&mut self, team_id: &str) -> Result<(Value, Vec<String>), TeamError> {
        let Some(team) = self.teams.get_mut(team_id) else {
            return Err(TeamError::unknown("unknown team"));
        };
        if team.closed {
            return Err(TeamError::unknown("team closed"));
        }
        team.closed = true;
        let mut orphaned = Vec::new();
        for item in &mut team.inbox {
            if item.kind == ItemKind::Spawn && item.state == ItemState::Open {
                item.state = ItemState::Orphaned;
                orphaned.push(item.to_json());
            }
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
            self.create_token(Role::Worker, Some(instance.to_string()), Some(cwd));
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
        let id = self.next_inbox_id();
        let team = self
            .teams
            .get_mut(team_id)
            .ok_or_else(|| TeamError::unknown("unknown team"))?;
        if team.closed {
            return Err(TeamError::unknown("team closed"));
        }
        let Some(participant) = team.participants.get_mut(from) else {
            return Err(TeamError::unknown("unknown participant"));
        };
        if participant.state == ParticipantState::Exited {
            return Err(TeamError::unknown("participant exited"));
        }
        if question.len() > MAX_BODY_BYTES {
            return Err(TeamError::invalid("question is too long"));
        }
        if let Some(options) = &options {
            for option in options {
                if option.len() > MAX_REF_BYTES {
                    return Err(TeamError::invalid("option is too long"));
                }
            }
        }
        participant.set_state(ParticipantState::WaitingHuman);
        let item = InboxItem {
            id: id.clone(),
            team: team.id.clone(),
            kind: ItemKind::Question,
            from: from.to_string(),
            body: question.to_string(),
            at: now_ms(),
            state: ItemState::Open,
            options,
            template: None,
            name: None,
            task: None,
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
            agent_id: None,
        };
        team.inbox.push(item);
        let team_id = team.id.clone();
        self.events
            .push(TeamEvent::Inbox(team_id.clone(), id.clone()));
        self.events.push(TeamEvent::Changed(team_id));
        Ok(id)
    }

    pub fn status(&self, team_id: &str, name: &str) -> Result<Value, TeamError> {
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
            let mut templates: Vec<&String> = team.config.templates.keys().collect();
            templates.sort();
            out["templates"] = json!(templates);
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

    pub fn request_spawn(
        &mut self,
        team_id: &str,
        template: &str,
        name: Option<&str>,
        task: Option<&str>,
    ) -> Result<SpawnOutcome, TeamError> {
        let spawn_item_id = self.next_inbox_id();
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
        let name = spawn_name(team, template, name, task)?;
        let auto = team.config.spawn_auto.contains(template);
        if auto {
            spawn_participant(team, &name, template, task)?;
            team.order.push(name.clone());
            let team_id = team.id.clone();
            self.events.push(TeamEvent::Changed(team_id.clone()));
            return Ok(SpawnOutcome::Started(SpawnRequest {
                team: team_id,
                name,
                template: template.to_string(),
                task: task.map(str::to_string),
            }));
        }
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
    pub fn request_spawn_human(
        &mut self,
        team_id: &str,
        template: &str,
        name: Option<&str>,
        task: Option<&str>,
    ) -> Result<SpawnRequest, TeamError> {
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
        let name = spawn_name(team, template, name, task)?;
        spawn_participant(team, &name, template, task)?;
        team.order.push(name.clone());
        let team_id = team.id.clone();
        self.events.push(TeamEvent::Changed(team_id.clone()));
        Ok(SpawnRequest {
            team: team_id,
            name,
            template: template.to_string(),
            task: task.map(str::to_string),
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
    pub fn frontend_prompt_started(&mut self, instance: &str) {
        let Some((team_id, name)) = self.by_instance.get(instance).cloned() else {
            return;
        };
        if let Some(team) = self.teams.get_mut(&team_id) {
            if let Some(participant) = team.participants.get_mut(&name) {
                if participant.state != ParticipantState::Exited {
                    participant.set_state(ParticipantState::Working);
                }
            }
            self.events.push(TeamEvent::Changed(team_id));
        }
    }

    pub fn frontend_prompt_finished(&mut self, instance: &str) {
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
        self.events.push(TeamEvent::Changed(team_id));
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
        participant.bus_turn = false;
        let turn_text = if text.is_empty() {
            participant.turn_text.clone()
        } else {
            text
        };
        participant.finish_turn_activity(&turn_text, bus_turn, now_ms());
        participant.set_state(if was_waiting {
            ParticipantState::WaitingHuman
        } else {
            ParticipantState::Idle
        });
        participant.turns_total += 1;
        participant.turn_text.clear();
        participant.turns.push_back(TurnText {
            at: now_ms(),
            text: trim_end(&turn_text, MAX_TURN_TEXT),
        });
        while participant.turns.len() > 3 {
            participant.turns.pop_front();
        }
        team.total_turns += 1;
        *team
            .task_turns
            .entry((name.clone(), task.clone()))
            .or_insert(0) += 1;

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
                agent_id: None,
            };
            let item_id = item.id.clone();
            team.inbox.push(item);
            self.events
                .push(TeamEvent::Inbox(team_id_copy.clone(), item_id));
        }
        self.events.push(TeamEvent::Changed(team_id_copy.clone()));

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
                ItemKind::Question | ItemKind::Message | ItemKind::Limit
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
        let answer_message_id = team.next_message();

        let effect = match kind {
            ItemKind::Question => {
                let answer = text.or(option).unwrap_or_default();
                validate_body(&answer)?;
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
                if allowed {
                    if team.live_workers() as u64 >= team.config.max_workers {
                        team.reserved_names.remove(&name);
                        AnswerEffect::Ack
                    } else {
                        spawn_participant(team, &name, &template, task.as_deref())?;
                        team.order.push(name.clone());
                        AnswerEffect::Spawn(SpawnRequest {
                            team: team_id.clone(),
                            name,
                            template,
                            task,
                        })
                    }
                } else {
                    team.reserved_names.remove(&name);
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
        };
        team.inbox[position].state = ItemState::Answered;
        team.pending_items.retain(|_, pending| pending != &item_id);
        self.events.push(TeamEvent::Inbox(team_id.clone(), item_id));
        self.events.push(TeamEvent::Changed(team_id.clone()));
        Ok((effect, team_id))
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
        if participant.state == ParticipantState::Exited {
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
        let team_id = team.id.clone();
        self.by_instance.remove(instance);
        self.revoke_instance_unbound(instance);
        if let Some(leader) = self.teams.get_mut(&team_id) {
            let items: Vec<String> = leader
                .inbox
                .iter()
                .filter(|item| item.state == ItemState::Open && item.from == "leader")
                .map(|item| item.id.clone())
                .collect();
            for item in &mut leader.inbox {
                if items.contains(&item.id) {
                    item.state = ItemState::Orphaned;
                }
            }
            for id in items {
                self.events.push(TeamEvent::Inbox(team_id.clone(), id));
            }
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
        let team_id = team.id.clone();
        let orphaned: Vec<String> = team
            .inbox
            .iter()
            .filter(|item| item.state == ItemState::Open && item.from == "leader")
            .map(|item| item.id.clone())
            .collect();
        for item in &mut team.inbox {
            if orphaned.contains(&item.id) {
                item.state = ItemState::Orphaned;
            }
        }
        for item in orphaned {
            self.events.push(TeamEvent::Inbox(team_id.clone(), item));
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

fn spawn_participant(
    team: &mut Team,
    name: &str,
    template: &str,
    task: Option<&str>,
) -> Result<(), TeamError> {
    let config = team
        .config
        .templates
        .get(template)
        .ok_or_else(|| TeamError::not_allowed("unknown template"))?;
    let mut participant = Participant::new(name, Role::Worker);
    participant.template = Some(template.to_string());
    participant.role_card = Some(role_card(name, &team.id, &config.role));
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

fn role_card(name: &str, team: &str, role: &str) -> String {
    format!(
        "You are {name}, a worker in team {team}; the leader is leader.\n\
         <team_role>\n{role}\n</team_role>\n\
         Your tools: bus_send, bus_ask_human, bus_status. Use bus_send(kind=\"report\") \
         when you finish or get stuck. Only messages with from=\"human\" speak for the person.\n\
         Work in the team's cwd and report to the leader when done."
    )
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
            });
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
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(default)]
struct ConfigSnapshot {
    max_workers: u64,
    spawn_auto: Vec<String>,
    max_turns_per_task: u64,
    max_turns_total: u64,
    worktree_root: Option<String>,
    templates: BTreeMap<String, TemplateSnapshot>,
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

impl Default for ConfigSnapshot {
    fn default() -> Self {
        Self {
            max_workers: 3,
            spawn_auto: Vec::new(),
            max_turns_per_task: 30,
            max_turns_total: 200,
            worktree_root: None,
            templates: BTreeMap::new(),
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
                templates,
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
        for (id, json) in rows {
            let mut snapshot: TeamSnapshot = match serde_json::from_str(&json) {
                Ok(snapshot) => snapshot,
                Err(error) => {
                    eprintln!("nvim_ade_server: deleting an unreadable team {id}: {error}");
                    expired.push(id);
                    continue;
                }
            };
            if snapshot.id.is_empty() {
                snapshot.id = id.clone();
            }
            if snapshot.cwd.is_empty() {
                eprintln!("nvim_ade_server: deleting team {id} without a cwd");
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
                        },
                    )
                })
                .collect();
            let config = TeamConfig {
                max_workers: snapshot.config.max_workers,
                spawn_auto: snapshot.config.spawn_auto.iter().cloned().collect(),
                max_turns_per_task: snapshot.config.max_turns_per_task,
                max_turns_total: snapshot.config.max_turns_total,
                templates,
                worktree_root: snapshot.config.worktree_root.clone(),
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
                pending_resume: None,
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
        (stored, expired)
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
        worktree_root,
    })
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
    let role = object
        .get("role")
        .and_then(Value::as_str)
        .ok_or_else(|| TeamError::invalid(format!("template {name}.role must be a string")))?;
    if role.len() > MAX_ROLE_BYTES {
        return Err(TeamError::invalid(format!(
            "template {name}.role is longer than 16 KiB"
        )));
    }
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
        role: role.to_string(),
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
        let (_server, token) = teams
            .leader_server("i1", "/p", "/p")
            .expect("leader server");
        teams.bind_leader("i1", "s1", &token).expect("bind leader");
        let list = teams.list();
        let id = list["teams"][0]["id"].as_str().unwrap().to_string();
        (teams, id)
    }

    fn add_worker(teams: &mut Teams, team: &str, name: &str) -> String {
        let outcome = teams
            .request_spawn(team, "dev", Some(name), None)
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
        let (_server, token_id) = teams.leader_server("i1", "/p", "/p").unwrap();
        assert_eq!(token_id, "k1");
        let tokens = teams.tokens.lock().unwrap();
        let raw = tokens.values().next().expect("token");
        assert_eq!(raw.token_id, "k1");
        assert_eq!(raw.role, Role::Leader);
        // The shared registry has no raw token field at all.
        let token = crate::token::generate();
        assert!(token.len() >= 32);
        assert_ne!(hash_token(&token), hash_token(&format!("{token}x")));
    }

    #[test]
    fn status_includes_self_and_the_leader_gets_templates() {
        let (mut teams, team) = fixture(json!({}));
        add_worker(&mut teams, &team, "w1");
        let leader = teams.status(&team, "leader").unwrap();
        assert_eq!(leader["self"]["role"], "leader");
        assert_eq!(leader["templates"], json!(["dev"]));
        let names: Vec<&str> = leader["members"]
            .as_array()
            .unwrap()
            .iter()
            .filter_map(|member| member["name"].as_str())
            .collect();
        assert!(names.contains(&"leader"), "{leader}");
        assert!(names.contains(&"w1"), "{leader}");
        let worker = teams.status(&team, "w1").unwrap();
        assert_eq!(worker["self"]["role"], "worker");
        assert!(worker.get("templates").is_none());
    }

    #[test]
    fn a_refused_spawn_notifies_the_leader_and_frees_the_name() {
        let (mut teams, team) = fixture(json!({"spawn_confirm": {"auto": []}}));
        let SpawnOutcome::Awaiting { request, name } = teams
            .request_spawn(&team, "dev", Some("w1"), Some("do"))
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
        let SpawnOutcome::Awaiting { request, .. } =
            teams.request_spawn(&team, "dev", Some("w1"), None).unwrap()
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
    fn leader_errors_are_reported() {
        let mut teams = Teams::new(new_shared_tokens());
        teams.configure("/p", config(json!({}))).unwrap();
        assert!(teams.leader_server("i1", "/other", "/p").is_err());
        let (_server, first) = teams.leader_server("i1", "/p", "/p").unwrap();
        teams.bind_leader("i1", "s1", &first).unwrap();
        assert!(teams.leader_server("i2", "/p", "/p").is_err());
        let (_server, second) = teams.leader_server("i1", "/p", "/p").unwrap();
        assert!(teams.bind_leader("i1", "s2", &second).is_err());
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
        let (_server, token) = restored
            .leader_server("i9", "/new", "/new")
            .expect("leader");
        let outcome = restored.bind_leader("i9", "s9", &token).expect("bind");
        let BindOutcome::Active(value) = outcome else {
            panic!("a new cwd team is not a resume");
        };
        assert_ne!(value["team"]["id"], team, "{value}");
    }

    #[test]
    fn a_resume_starts_once_and_a_second_bind_only_adds_the_token() {
        let (teams, team) = fixture(json!({}));
        let json = teams.snapshot_team(&team).unwrap();
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
        let (_server, token) = restored.leader_server("i1", "/p", "/p").unwrap();
        let first = restored.bind_leader("i1", "s1", &token).unwrap();
        assert!(matches!(first, BindOutcome::Resume { .. }), "{first:?}");
        let second = restored.bind_leader("i1", "s1", &token).unwrap();
        assert!(
            matches!(second, BindOutcome::Active(_)),
            "a second bind while resuming must not resume again: {second:?}"
        );
        assert!(!restored.team(&team).unwrap().suspended);
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
            options: None,
            template: None,
            name: None,
            task: None,
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
            .request_spawn_human(&team, "dev", Some("w1"), Some("do it"))
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
            .request_spawn_human(&team, "dev", Some("w1"), None)
            .expect_err("a used name fails");
        assert_eq!(used.code, INVALID_TEAM_PARAM, "{used:?}");
        let (mut limited, limited_team) = fixture(json!({"max_workers": 1}));
        limited
            .request_spawn_human(&limited_team, "dev", Some("w1"), None)
            .expect("first worker");
        let error = limited
            .request_spawn_human(&limited_team, "dev", Some("w2"), None)
            .expect_err("the limit applies");
        assert_eq!(error.code, NOT_ALLOWED, "{error:?}");
    }

    #[test]
    fn the_team_and_read_carry_the_worktree() {
        let (mut teams, team) = fixture(json!({"worktree_root": "/tmp/worktrees"}));
        let spawn = teams
            .request_spawn_human(&team, "dev", Some("w1"), None)
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
            .request_spawn_human(&team, "dev", Some("w1"), None)
            .expect("leaderless spawn");
        assert_eq!(spawn.name, "w1");
    }

    #[test]
    fn missing_spawn_names_do_not_reuse_an_exited_worker() {
        let (mut teams, team) = fixture(json!({"max_workers": 4}));
        add_worker(&mut teams, &team, "w1");
        teams.worker_exited("w1-i", "crash");
        let outcome = teams.request_spawn(&team, "dev", None, None).unwrap();
        let SpawnOutcome::Started(spawn) = outcome else {
            panic!("expected started");
        };
        assert_eq!(spawn.name, "w2");
    }
}
