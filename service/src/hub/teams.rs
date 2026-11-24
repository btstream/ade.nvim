//! Team orchestration: the I/O half of PROTOCOL.md section 18.
//!
//! The state machine lives in [`crate::team`]. This module owns the parts that
//! need the hub: spawning worker processes, sending service-originated ACP
//! requests, routing their responses to the driver, brokering watchers and
//! broadcasting `team.*` notifications.

use super::*;
use crate::team::{
    brief, workflow, worktree, AnswerEffect, ItemKind, Kind, Role, SpawnOutcome, SpawnPlan,
    SpawnRequest, TeamError, TeamEvent, INVALID_TEAM_PARAM, MAX_BODY_BYTES,
};

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum SpawnReplyKind {
    /// `bus.spawn` from the leader's MCP tool.
    Bus,
    /// `team.spawn` from the person's front end.
    Team,
}

#[derive(Debug, Clone, Default)]
pub(crate) struct StartOptions {
    pub reply: Option<(u64, Value, SpawnReplyKind)>,
    /// The approved-spawn request id, for the notice (18.3/18.16).
    pub approved_request: Option<String>,
    /// `team.spawn` announces itself to the leader (18.13).
    pub human_notice: bool,
    /// A stored session to load instead of creating a new one.
    pub resume: Option<String>,
}

#[derive(Debug)]
pub(crate) struct PendingWorktree {
    pub spawn: SpawnRequest,
    pub plan: SpawnPlan,
    pub opts: StartOptions,
    pub cancelled: bool,
}

/// `session.teams {enabled: true}` waiting for a bound token's MCP process to
/// connect: it answers on connect, on timeout, or as soon as the state it
/// depends on goes away (20.5).
#[derive(Debug)]
pub(crate) struct PendingEnable {
    pub conn: u64,
    pub id: Value,
    pub instance: String,
    pub session: String,
    pub agent: String,
    pub cwd: String,
    /// The bound token whose MCP process is awaited.
    pub token_id: String,
    /// Whether the agent can reload a session: the timeout falls back to
    /// `reload: true` only when it can, else to `reload_unsupported`.
    pub can_reload: bool,
}

pub(crate) enum StartResult {
    Started,
    Deferred,
    /// The failure was reported and the spawn must not reply again.
    Replied,
}

/// How a held `session.teams {enabled: true}` decides its answer (20.5).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum EnableDecision {
    /// The bound token's MCP process connected: no reload.
    Connected,
    /// The wait expired with no connection: mark the one-shot reload.
    TimedOut,
    /// The state the wait depended on went away (token revoked, instance
    /// exit, session closed, switch off): answer with the state now, no mark.
    Changed,
}

/// `session.teams` either answers at once or holds the reply until a bound
/// token's MCP process connects or the wait expires (20.5).
enum SessionTeamsOutcome {
    Answer(Value),
    Pending {
        instance: String,
        session: String,
        agent: String,
        cwd: String,
        token_id: String,
        can_reload: bool,
    },
}

/// The effective per-session state whose change is published (20.3/20.5).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct SessionState {
    pub enabled: bool,
    pub injected: bool,
    pub leader: bool,
}

/// A forwarded session request whose token binds only if the agent answers
/// successfully (20.2/20.7).
#[derive(Debug, Clone)]
pub(crate) struct PendingSession {
    pub token_id: String,
    pub cwd: String,
    pub agent: String,
    /// The request method (`session/new`, `session/load`, `session/resume`).
    pub method: String,
    /// The session id the request named (`session/load`/`resume`); `None` for
    /// `session/new`, whose id comes from the response.
    pub session: Option<String>,
    /// The front-end connection that sent the request.
    pub conn: u64,
    /// This request consumed the session's one-shot reload mark: its answer
    /// restarts the session's log (20.5).
    pub forced: bool,
    /// The frame reached the agent's writer: its answer (or the instance's
    /// exit) still matters even when the front end left (20.5/B).
    pub delivered: bool,
}

#[derive(Debug)]
pub enum ServiceCall {
    Initialize {
        team: String,
        participant: String,
        server: Value,
        model: Option<String>,
        /// A stored worker session to `session/load` (18.15).
        resume: Option<String>,
    },
    SessionLoad {
        team: String,
        participant: String,
        model: Option<String>,
        session: String,
        server: Value,
    },
    SessionNew {
        team: String,
        participant: String,
        model: Option<String>,
    },
    SetModel {
        team: String,
        participant: String,
    },
    Prompt {
        team: String,
        participant: String,
        session: String,
        /// The relay sequence of this prompt (19.14).
        seq: u64,
    },
}

#[derive(Debug)]
pub enum TeamResult {
    Watch {
        conn: u64,
        frontend_id: Value,
        instance: String,
        session: String,
        /// `None` means the replay was declined (incomplete or too large).
        messages: Option<Vec<(u64, Value)>>,
    },
    /// A team call that needed the cwd's project key first (19.1): computing it
    /// runs git, so it happens off the hub loop.
    ProjectKey {
        conn: u64,
        frontend_id: Value,
        call: DeferredTeam,
        cwd: String,
        project: String,
        /// Whether git itself answered (only that is worth caching).
        cache: bool,
    },
}

/// A `bus.*`/`team.*` call whose resolution needs a project key (19.1/19.5).
#[derive(Debug)]
pub(crate) enum DeferredTeam {
    Status {
        team: String,
        name: String,
    },
    SessionStatus {
        conn: u64,
        id: Value,
        token_id: String,
        team: String,
    },
    Workflows {
        cwd: String,
    },
    WorkflowDeleteCwd {
        name: String,
        scope: String,
    },
    WorkflowSaveCwd {
        cwd: String,
        value: Value,
        scope: Option<String>,
        replace: bool,
    },
    WorkflowGetCwd {
        cwd: String,
        name: String,
    },
    WorkflowDeleteCwdScope {
        cwd: String,
        name: String,
        scope: Option<String>,
    },
    SetLeader {
        team: String,
        instance: String,
        session: String,
        conn: u64,
        id: Value,
        notice: bool,
    },
    Start {
        team: String,
        workflow: String,
        task: Option<String>,
    },
}

impl Hub {
    // -- session injection (PROTOCOL.md 20.2) ------------------------------

    /// Inject the session server into a forwarded session request and remember
    /// what must be committed when the agent answers (20.2/20.7). A
    /// `session/load` may be answered from the log, so the caller decides
    /// later; this only prepares the request.
    pub(crate) fn prepare_session_request(
        &mut self,
        conn: u64,
        instance: &str,
        message: &mut Value,
    ) -> Option<PendingSession> {
        let method = message.get("method").and_then(Value::as_str)?.to_string();
        if !matches!(
            method.as_str(),
            "session/new" | "session/load" | "session/resume"
        ) {
            return None;
        }
        let handle = self.instances.get(instance)?;
        let cwd = handle.key.cwd.clone();
        let agent = handle.key.agent.clone();
        let session = message
            .get("params")
            .and_then(|params| params.get("sessionId"))
            .and_then(Value::as_str)
            .map(str::to_string);
        let inject = self.should_inject(&session, &cwd, &agent);
        let (token_id, token) = match inject {
            Some(()) => {
                let (token_id, token) =
                    self.teams
                        .issue_session_token(instance, &cwd, &agent, session.as_deref());
                if let Some(params) = message.get_mut("params") {
                    inject_team_server(params, &token);
                }
                (Some(token_id), Some(token))
            }
            None => (None, None),
        };
        let _ = token;
        Some(PendingSession {
            token_id: token_id.unwrap_or_default(),
            cwd,
            agent,
            method,
            session,
            conn,
            forced: false,
            delivered: false,
        })
    }

    /// Inject the session server into a frame the relay forwards, and prepare
    /// the commit its response triggers (20.2).
    pub(crate) fn inject_forwarded_session(
        &mut self,
        conn: u64,
        instance: &str,
        action: &mut crate::relay::FrontendAction,
    ) -> Option<PendingSession> {
        let frame = match action {
            crate::relay::FrontendAction::Forward(frame)
            | crate::relay::FrontendAction::ForwardWith { frame, .. } => frame,
            _ => return None,
        };
        let mut probe = frame.clone();
        let prepared = self.prepare_session_request(conn, instance, &mut probe)?;
        *frame = probe;
        Some(prepared)
    }

    /// Whether a session request gets a token: the cwd is configured and
    /// enabled, and the session's switch is on (20.2). `None` means no token.
    fn should_inject(&self, session: &Option<String>, cwd: &str, agent: &str) -> Option<()> {
        if !self.teams.has_config(cwd) || !self.teams.config_for(cwd).enabled {
            return None;
        }
        match session {
            Some(session) => self.teams.enabled_for(agent, session, cwd).then_some(()),
            None => self.teams.config_for(cwd).session_default.then_some(()),
        }
    }

    /// The switch row is persisted and, being a change, announced (20.5).
    fn remember_switch(&mut self, agent: &str, session: &str, enabled: bool) {
        if self.teams.set_switch(agent, session, enabled) {
            self.recorder.save_session_switch(agent, session, enabled);
        }
    }

    /// A forwarded session request was answered: bind the token on success and
    /// (for a load/resume) resume the stored team; undo it on failure
    /// (20.2/20.7).
    pub(crate) fn finish_session(
        &mut self,
        instance: &str,
        request: &crate::relay::FrontendRequest,
        message: &Value,
    ) {
        let key = (instance.to_string(), request.agent_id);
        let Some(pending) = self.pending_session.get(&key).cloned() else {
            return;
        };
        let failed = message.get("error").is_some();
        let session = message
            .get("result")
            .and_then(|result| result.get("sessionId"))
            .and_then(Value::as_str)
            .map(str::to_string)
            .or_else(|| pending.session.clone())
            .or_else(|| request.session_id.clone());
        if failed || session.is_none() {
            // The agent answered (with an error): this pending is over. Revoke
            // whatever token it still holds, delete the record — never keep a
            // log-only one, which would make later loads look forced forever.
            if let Some(pending) = self.pending_session.remove(&key) {
                let before = pending
                    .session
                    .as_ref()
                    .map(|session| self.session_states(&[(instance.to_string(), session.clone())]));
                self.drop_pending_session_value(pending);
                if let Some(before) = before {
                    self.publish_session_changes(before);
                }
            }
            return;
        }
        let session = session.expect("checked above");
        if pending.token_id.is_empty() {
            // The front end left (or the token was revoked): only the log
            // boundary remains (20.5/B).
            self.pending_session.remove(&key);
            if pending.forced {
                self.mark_log_restarted(instance, &session);
            }
            return;
        }
        // The identity may not have existed before this binding (the MCP process
        // handshook early), so the pre-state is "no tools"; the bound token's
        // connection is what makes it injected (20.3/A).
        let identity = (instance.to_string(), session.clone());
        let before = self.session_states(std::slice::from_ref(&identity));
        if self
            .teams
            .bind_session_token(instance, &session, &pending.token_id, &pending.agent)
            .is_err()
        {
            if let Some(pending) = self.pending_session.remove(&key) {
                self.drop_pending_session_value(pending);
                self.publish_session_changes(before);
            }
            return;
        }
        self.pending_session.remove(&key);
        // The log boundary follows the request that actually forced the load,
        // never the session's current mark (20.5/B).
        if pending.forced {
            self.mark_log_restarted(instance, &session);
        }
        self.publish_session_changes(before);
        if matches!(pending.method.as_str(), "session/load" | "session/resume") {
            self.resume_for_session(instance, &session, &pending.agent, &pending.cwd);
        }
    }

    /// A forced reload replays history the service may already hold: the
    /// session's earlier log is no longer a complete replay source (20.5).
    fn mark_log_restarted(&mut self, instance: &str, session: &str) {
        let Some(handle) = self.instances.get(instance) else {
            return;
        };
        if self.recorder.enabled() {
            self.recorder
                .mark_session_incomplete(&handle.log_key, session);
        }
    }

    /// Undo a forwarded session request that will not be committed: revoke its
    /// token, forget the record and keep the previous binding (20.2).
    pub(crate) fn drop_pending_session(&mut self, key: &(String, u64)) {
        self.undo_pending_session(key);
    }

    /// The single undo path: snapshot the affected session, revoke the token,
    /// then publish the difference so a session that looked injected hears
    /// about losing it (20.2/A).
    ///
    /// A request the agent already received keeps a record of its log boundary
    /// until the agent answers or the instance exits (20.5/B): the token goes,
    /// the forced-load fact stays.
    pub(crate) fn undo_pending_session(&mut self, key: &(String, u64)) {
        let Some(mut pending) = self.pending_session.remove(key) else {
            return;
        };
        let before = pending
            .session
            .as_ref()
            .map(|session| self.session_states(&[(key.0.clone(), session.clone())]));
        if pending.delivered && pending.forced {
            // The front end left while the agent is still working: revoke the
            // token for real (it must not authenticate or authorize again), then
            // keep a log-only record so a late success still restarts the log
            // (20.5/B).
            self.drop_pending_session_value(pending.clone());
            pending.conn = 0;
            pending.token_id.clear();
            self.pending_session.insert(key.clone(), pending);
        } else {
            self.drop_pending_session_value(pending);
        }
        if let Some(before) = before {
            self.publish_session_changes(before);
        }
    }

    /// Revoke a request's token and forget the connection that held it.
    pub(crate) fn drop_pending_session_value(&mut self, pending: PendingSession) {
        if !pending.token_id.is_empty() {
            self.teams.revoke(&pending.token_id);
        }
        // The request's source connection may have handshaked with that token
        // already; nothing else refers to it now.
        self.conn_tokens
            .retain(|_, token| token != &pending.token_id);
    }

    /// `injected` from the single source of truth: a connection holds a token
    /// id whose *current* binding is this session (20.5).
    pub(crate) fn session_injected(&self, instance: &str, session: &str) -> bool {
        self.conn_tokens
            .values()
            .any(|token| match self.teams.session_identity(token) {
                Some((owner, current)) => owner == instance && current == session,
                None => false,
            })
    }

    /// The effective state of `identities` *now*: callers take this before an
    /// operation changes anything, then publish the difference (20.3/20.5).
    pub(crate) fn session_states(
        &self,
        identities: &[(String, String)],
    ) -> Vec<((String, String), SessionState)> {
        identities
            .iter()
            .map(|identity| {
                (
                    identity.clone(),
                    self.session_state(&identity.0, &identity.1),
                )
            })
            .collect()
    }

    /// The effective state of one session: `enabled`, `injected`, `leader` and
    /// the tool set it implies.
    pub(crate) fn session_state(&self, instance: &str, session: &str) -> SessionState {
        let cwd = self
            .instances
            .get(instance)
            .map(|handle| handle.key.cwd.clone());
        let agent = self
            .instances
            .get(instance)
            .map(|handle| handle.key.agent.clone())
            .unwrap_or_default();
        let enabled = cwd
            .as_deref()
            .map(|cwd| self.teams.enabled_for(&agent, session, cwd))
            .unwrap_or_else(|| self.teams.switch(&agent, session).unwrap_or(true));
        let injected = self.session_injected(instance, session);
        let token = self.teams.session_token_of(instance, session);
        let leader = token
            .as_deref()
            .and_then(|token| self.teams.session_role(token).0)
            .is_some_and(|role| role == "leader")
            && self.teams.session_team_entry(instance, session).is_object();
        SessionState {
            enabled,
            injected,
            leader,
        }
    }

    /// Publish the difference between `before` and the current state of the
    /// same identities, to front ends and to the sessions' MCP processes.
    pub(crate) fn publish_session_changes(
        &mut self,
        before: Vec<((String, String), SessionState)>,
    ) {
        for (identity, old) in before {
            let new = self.session_state(&identity.0, &identity.1);
            if new == old {
                continue;
            }
            self.teams.refresh_session_auth(&identity.0, &identity.1);
            let entry = self.teams.session_team_entry(&identity.0, &identity.1);
            self.send_to_frontends(&json!({
                "jsonrpc": "2.0",
                "method": "session.teams_changed",
                "params": {
                    "instance": identity.0,
                    "sessionId": identity.1,
                    "enabled": new.enabled,
                    "injected": new.injected,
                    "leader": entry,
                },
            }));
            self.notify_tools_changed(&identity);
        }
    }

    /// Snapshot `identities`, run `body`, publish what changed.
    pub(crate) fn with_session_changes<R>(
        &mut self,
        identities: Vec<(String, String)>,
        body: impl FnOnce(&mut Self) -> R,
    ) -> R {
        let before = self.session_states(&identities);
        let result = body(self);
        self.publish_session_changes(before);
        result
    }

    /// Every session the service knows in `cwd`: what each instance's relay
    /// tracks (sessions created through it, with or without a team token), the
    /// bound session tokens and the team participants (20.3/20.5).
    pub(crate) fn sessions_of_cwd(&self, cwd: &str) -> Vec<(String, String)> {
        let mut sessions: Vec<(String, String)> = Vec::new();
        for (id, handle) in &self.instances {
            if handle.key.cwd != cwd {
                continue;
            }
            for summary in handle.relay.session_summaries() {
                sessions.push((id.clone(), summary.session_id));
            }
        }
        for (instance, _) in self.teams.token_sessions() {
            if self
                .instances
                .get(&instance)
                .is_some_and(|handle| handle.key.cwd == cwd)
            {
                for session in self.teams.sessions_of_instance(&instance) {
                    sessions.push((instance.clone(), session));
                }
            }
        }
        for (instance, session) in self.teams.participant_sessions() {
            if self
                .instances
                .get(&instance)
                .is_some_and(|handle| handle.key.cwd == cwd)
            {
                sessions.push((instance, session));
            }
        }
        sessions.sort();
        sessions.dedup();
        sessions
    }

    /// Tell a session's MCP process its tool set changed (20.3).
    pub(crate) fn notify_tools_changed(&self, key: &(String, String)) {
        let conns: Vec<u64> = self
            .conn_tokens
            .iter()
            .filter(|(_, token)| {
                self.teams
                    .session_identity(token)
                    .is_some_and(|(instance, session)| instance == key.0 && session == key.1)
            })
            .map(|(conn, _)| *conn)
            .collect();
        for conn in conns {
            self.send_to(
                conn,
                &json!({
                    "jsonrpc": "2.0",
                    "method": "notifications/tools/list_changed",
                }),
            );
        }
    }

    // -- session tools (PROTOCOL.md 20.3) ----------------------------------

    /// The tool names the session's current state allows (empty when the
    /// switch is off).
    pub(crate) fn session_tool_state(
        &self,
        token_id: &str,
    ) -> (bool, bool, Option<String>, Option<String>) {
        // (enabled, leader, team, reason)
        let Some((instance, session, agent)) = self.teams.session_auth(token_id) else {
            return (true, false, None, Some("no_tools".to_string()));
        };
        let cwd = self
            .instances
            .get(instance)
            .map(|handle| handle.key.cwd.clone())
            .or_else(|| self.teams.session_cwd(token_id))
            .unwrap_or_default();
        let enabled = self.teams.enabled_for(agent, session, &cwd);
        if !enabled {
            return (false, false, None, Some("off".to_string()));
        }
        let (role, team) = self.teams.session_role(token_id);
        (true, role.as_deref() == Some("leader"), team, None)
    }

    pub(crate) fn handle_participant(
        &mut self,
        conn: u64,
        token_id: &str,
        method: &str,
        params: &Value,
        id: &Value,
        is_request: bool,
    ) {
        let Some((role, team, name)) = self.teams.token_role(token_id) else {
            if is_request {
                self.send_to(
                    conn,
                    &failure(
                        id,
                        crate::team::UNKNOWN_PARTICIPANT,
                        "team token is no longer valid",
                    ),
                );
            }
            return;
        };
        if role == Role::Session {
            self.handle_session_call(conn, token_id, method, params, id, is_request);
            return;
        }
        let (Some(team), Some(name)) = (team, name) else {
            if is_request {
                self.send_to(
                    conn,
                    &failure(id, crate::team::UNKNOWN_PARTICIPANT, "team not bound"),
                );
            }
            return;
        };
        if self.teams.is_closed(&team) {
            if is_request {
                self.send_to(
                    conn,
                    &failure(id, crate::team::UNKNOWN_PARTICIPANT, "team closed"),
                );
            }
            return;
        }
        if !is_request {
            // Participant connections send requests only; a notification has no
            // reply and no meaning here.
            return;
        }
        if method == "bus.status" {
            // The leader's status carries workflows, which need the project key
            // (19.3); the worker's is unchanged.
            match self.teams.team(&team).map(|team| team.cwd.clone()) {
                Some(cwd) => self.run_or_defer(
                    conn,
                    id,
                    &cwd,
                    DeferredTeam::Status {
                        team: team.clone(),
                        name: name.clone(),
                    },
                ),
                None => self.send_error(conn, id, &TeamError::unknown("unknown team")),
            }
            return;
        }
        let result = match method {
            "bus.send" => self.bus_send(conn, &team, &name, params),
            "bus.ask_human" => self.bus_ask_human(&team, &name, params),
            "bus.board_update" => {
                if role != Role::Leader {
                    Err(TeamError::not_allowed("board_update is leader only"))
                } else {
                    self.bus_board_update(&team, params)
                }
            }
            "bus.card_update" => {
                if role != Role::Worker {
                    Err(TeamError::not_allowed("card_update is worker only"))
                } else {
                    self.bus_card_update(&team, &name, params)
                }
            }
            "bus.read" => {
                if role != Role::Leader {
                    Err(TeamError::not_allowed("bus_read is leader only"))
                } else {
                    self.bus_read(&team, params)
                }
            }
            _ => Err(TeamError::new(METHOD_NOT_FOUND, "method not found")),
        };
        match result {
            Ok((value, delivery)) => {
                self.teams.note_bus_call(
                    &team,
                    &name,
                    method,
                    params,
                    &value,
                    crate::team::now_ms(),
                );
                self.drain_team_events();
                if delivery {
                    self.team_deliveries();
                }
                self.send_to(conn, &success(id, value));
            }
            Err(error) => self.send_error(conn, id, &error),
        }
    }

    /// A `bus.*` call from a session token (20.3): the tool set is re-evaluated
    /// here for every call, never chosen by parameters.
    fn handle_session_call(
        &mut self,
        conn: u64,
        token_id: &str,
        method: &str,
        params: &Value,
        id: &Value,
        is_request: bool,
    ) {
        if !is_request {
            return;
        }
        let (enabled, leader, team, reason) = self.session_tool_state(token_id);
        let refused = |hub: &Self, why: &str| {
            hub.send_error(conn, id, &TeamError::not_allowed(why));
        };
        if method == "bus.status" {
            if enabled && leader {
                if let Some(team) = team.clone() {
                    let cwd = self
                        .teams
                        .team(&team)
                        .map(|entry| entry.cwd.clone())
                        .unwrap_or_default();
                    self.run_or_defer(
                        conn,
                        id,
                        &cwd,
                        DeferredTeam::SessionStatus {
                            conn,
                            id: id.clone(),
                            token_id: token_id.to_string(),
                            team,
                        },
                    );
                    return;
                }
            }
            self.send_to(
                conn,
                &success(id, self.session_status(token_id, enabled, leader)),
            );
            return;
        }
        if !enabled {
            refused(self, "teams are off for this chat");
            return;
        }
        if let Some(reason) = &reason {
            refused(self, reason_text(reason));
            return;
        }
        if method == "bus.spawn" {
            self.session_spawn(conn, id, token_id, params);
            return;
        }
        if matches!(
            method,
            "bus.workflow_save" | "bus.workflow_get" | "bus.workflow_delete"
        ) {
            self.session_workflow(conn, id, token_id, method, params);
            return;
        }
        let team = match (&team, leader) {
            (Some(team), true) => team.clone(),
            _ => {
                refused(self, "this chat does not lead the team");
                return;
            }
        };
        let result = match method {
            "bus.stop_worker" => self.bus_stop_worker(&team, params),
            "bus.send" => self.bus_send(conn, &team, "leader", params),
            "bus.ask_human" => self.bus_ask_human(&team, "leader", params),
            "bus.board_update" => self.bus_board_update(&team, params),
            "bus.card_update" => Err(TeamError::not_allowed("card_update is worker only")),
            "bus.read" => self.bus_read(&team, params),
            _ => Err(TeamError::new(METHOD_NOT_FOUND, "method not found")),
        };
        match result {
            Ok((value, delivery)) => {
                self.teams.note_bus_call(
                    &team,
                    "leader",
                    method,
                    params,
                    &value,
                    crate::team::now_ms(),
                );
                self.drain_team_events();
                if delivery {
                    self.team_deliveries();
                }
                self.send_to(conn, &success(id, value));
            }
            Err(error) => self.send_error(conn, id, &error),
        }
    }

    /// `ensure_team` for a session token; `led_by` queues the handover item
    /// and turns into the documented tool error (20.4).
    fn ensure_session_team(&mut self, token_id: &str) -> Result<String, TeamError> {
        let Some((instance, session, _agent)) = self.teams.session_auth(token_id) else {
            let mut error = TeamError::not_allowed("teams are not available for this chat");
            error.data = Some(json!({ "reason": "no_tools" }));
            return Err(error);
        };
        let instance = instance.to_string();
        let session = session.to_string();
        let handle = self
            .instances
            .get(&instance)
            .ok_or_else(|| TeamError::new(UNKNOWN_INSTANCE, "unknown instance"))?;
        let launch = crate::team::LeaderLaunch {
            cwd: handle.key.cwd.clone(),
            key: handle.key.clone(),
            env: handle.env.clone(),
            #[cfg(unix)]
            launch: handle.launch.clone(),
        };
        let identity = (instance.clone(), session.clone());
        let ensured = self.with_session_changes(vec![identity], |hub| {
            hub.teams.ensure_team(&instance, &session, &launch)
        });
        match ensured {
            Ok(team) => Ok(team),
            Err(error)
                if error.data.as_ref().and_then(|data| data.get("reason"))
                    == Some(&json!("led_by")) =>
            {
                let team = error
                    .data
                    .as_ref()
                    .and_then(|data| data.get("team"))
                    .and_then(Value::as_str)
                    .unwrap_or_default()
                    .to_string();
                self.teams.create_handover(&team, &instance, &session);
                self.drain_team_events();
                self.notify_tools_changed(&(instance.to_string(), session.to_string()));
                Err(TeamError::not_allowed(
                    "the team is led by another chat; the person was asked to hand it over",
                ))
            }
            Err(error) => Err(error),
        }
    }

    fn session_status(&self, token_id: &str, enabled: bool, leader: bool) -> Value {
        let (name, team) = self.teams.session_role(token_id);
        let mut out = json!({
            "self": {
                "role": "session",
                "team": team,
                "name": name,
                "enabled": enabled,
            },
            "enabled": enabled,
            "leader": leader,
        });
        if leader {
            if let Some(team) = team {
                if let Some(entry) = self.teams.team(&team) {
                    out["templates"] =
                        json!(entry.config.templates.keys().cloned().collect::<Vec<_>>());
                }
            }
        }
        out
    }

    /// `bus.spawn` from a session: `ensure_team` first (20.4).
    fn session_spawn(&mut self, conn: u64, id: &Value, token_id: &str, params: &Value) {
        let identity = self
            .teams
            .session_auth(token_id)
            .map(|(instance, session, _)| (instance.to_string(), session.to_string()));
        // A refused handover is reported on this chat's next spawn (20.4/#14):
        // the requesting chat is not a participant, so no bus notice reaches it.
        if let Some((instance, session)) = identity.clone() {
            if self
                .teams
                .take_handover_refusal(&instance, &session)
                .is_some()
            {
                self.send_tool_error(
                    conn,
                    id,
                    &TeamError::not_allowed(
                        "the previous handover request was refused; ask the person again",
                    ),
                );
                return;
            }
        }
        let team = match self.ensure_session_team(token_id) {
            Ok(team) => team,
            Err(error) => {
                self.send_tool_error(conn, id, &error);
                return;
            }
        };
        let team = &team;
        let template = match required_team_string(params, "template") {
            Ok(value) => value,
            Err(error) => {
                self.send_tool_error(conn, id, &error);
                return;
            }
        };
        let name = optional_string(params, "name").ok().flatten();
        let model = optional_string(params, "model").ok().flatten();
        let role = optional_string(params, "role").ok().flatten();
        let task = optional_string(params, "task").ok().flatten();
        let label = optional_string(params, "label").ok().flatten();
        let outcome = self.teams.request_spawn_labeled(
            team,
            &template,
            name.as_deref(),
            model.as_deref(),
            role.as_deref(),
            task.as_deref(),
            label.as_deref(),
        );
        match outcome {
            Ok(SpawnOutcome::Awaiting { request, name }) => {
                let _ = token_id;
                let _ = self.teams.note_bus_call(
                    team,
                    "leader",
                    "bus.spawn",
                    params,
                    &json!({ "name": name }),
                    crate::team::now_ms(),
                );
                self.drain_team_events();
                self.send_to(
                    conn,
                    &success(
                        id,
                        json!({ "status": "awaiting_approval", "request": request }),
                    ),
                );
            }
            Ok(SpawnOutcome::Started(spawn)) => {
                let opts = StartOptions {
                    reply: Some((conn, id.clone(), SpawnReplyKind::Bus)),
                    ..StartOptions::default()
                };
                if matches!(self.start_worker(&spawn, opts), StartResult::Started) {
                    self.teams.note_bus_call(
                        team,
                        "leader",
                        "bus.spawn",
                        params,
                        &json!({ "name": spawn.name }),
                        crate::team::now_ms(),
                    );
                    self.drain_team_events();
                    self.team_deliveries();
                    self.send_to(
                        conn,
                        &success(
                            id,
                            json!({
                                "status": "started",
                                "name": spawn.name,
                                "team": self.teams.entry(team),
                            }),
                        ),
                    );
                }
            }
            Err(error) => self.send_tool_error(conn, id, &error),
        }
    }

    /// `team_stop` (20.6).
    fn bus_stop_worker(&mut self, team: &str, params: &Value) -> Result<(Value, bool), TeamError> {
        let name = required_team_string(params, "name")?;
        let remove = optional_bool(params, "remove")?.unwrap_or(false);
        let (live, start_pending) = self.worker_liveness(team, &name);
        let outcome = self
            .teams
            .stop_worker(team, &name, remove, false, live, start_pending)?;
        self.apply_stop(team, &name, &outcome);
        Ok((json!({}), true))
    }

    /// Complete a `remove: true` whose start ended without a live worker: the
    /// participant is dropped once and only once (20.6).
    pub(crate) fn finish_stopped_start(&mut self, team: &str, participant: &str, lifecycle: u64) {
        let remove = self
            .teams
            .team(team)
            .and_then(|entry| entry.participants.get(participant))
            .is_some_and(|worker| worker.lifecycle == lifecycle && worker.remove_after_exit);
        if remove {
            self.teams.finish_worker_removal(team, participant);
        }
    }

    /// Whether the worker has a live instance and/or a start in flight, from
    /// the hub's own tables (20.6/#7).
    fn worker_liveness(&self, team: &str, name: &str) -> (bool, bool) {
        let instance = self
            .teams
            .team(team)
            .and_then(|entry| entry.participants.get(name))
            .and_then(|worker| worker.instance.clone());
        let live = instance
            .as_deref()
            .is_some_and(|instance| self.instances.contains_key(instance));
        // A cancelled job keeps its record until git returns, and its name
        // stays taken until then (20.6/E).
        let start_pending = self
            .pending_worktrees
            .contains_key(&(team.to_string(), name.to_string()));
        (live, start_pending)
    }

    /// Cancel a start in flight and stop the instance when there is one (20.6).
    pub(crate) fn apply_stop(
        &mut self,
        team: &str,
        name: &str,
        outcome: &crate::team::StopOutcome,
    ) {
        // Cancelling the start answers the caller here and takes the reply
        // away, so the worktree callback can never answer it a second time.
        let reply = self
            .pending_worktrees
            .get_mut(&(team.to_string(), name.to_string()))
            .and_then(|pending| {
                (pending.spawn.lifecycle == outcome.lifecycle).then(|| {
                    pending.cancelled = true;
                    pending.opts.reply.take()
                })
            })
            .flatten();
        if let Some((conn, id, _)) = reply {
            self.send_error(conn, &id, &TeamError::not_allowed("the worker was stopped"));
        }
        if let Some(instance) = &outcome.instance {
            self.stop_worker_instance(instance);
        }
    }

    /// A workflow tool from a session token: no team needed, the cwd's
    /// configuration is the reference (20.3).
    fn session_workflow(
        &mut self,
        conn: u64,
        id: &Value,
        token_id: &str,
        method: &str,
        params: &Value,
    ) {
        let Some(cwd) = self.teams.session_cwd(token_id) else {
            self.send_tool_error(
                conn,
                id,
                &TeamError::not_allowed("teams are not available for this chat"),
            );
            return;
        };
        let result = (|| -> Result<DeferredTeam, TeamError> {
            match method {
                "bus.workflow_save" => {
                    let value = params.get("workflow").cloned().unwrap_or(Value::Null);
                    let scope = params
                        .get("scope")
                        .and_then(Value::as_str)
                        .or_else(|| value.get("scope").and_then(Value::as_str))
                        .map(str::to_string);
                    let replace = optional_bool(params, "replace")?.unwrap_or(false);
                    Ok(DeferredTeam::WorkflowSaveCwd {
                        cwd: cwd.clone(),
                        value,
                        scope,
                        replace,
                    })
                }
                "bus.workflow_get" => Ok(DeferredTeam::WorkflowGetCwd {
                    cwd: cwd.clone(),
                    name: required_team_string(params, "name")?,
                }),
                "bus.workflow_delete" => Ok(DeferredTeam::WorkflowDeleteCwdScope {
                    cwd: cwd.clone(),
                    name: required_team_string(params, "name")?,
                    scope: optional_string(params, "scope")?,
                }),
                _ => Err(TeamError::new(METHOD_NOT_FOUND, "method not found")),
            }
        })();
        match result {
            Ok(call) => self.run_or_defer(conn, id, &cwd, call),
            Err(error) => self.send_tool_error(conn, id, &error),
        }
    }

    /// Session-token tool answers are ordinary JSON-RPC results/errors; the
    /// MCP process turns an error into `isError: true` (20.3).
    fn send_tool_success(&self, conn: u64, id: &Value, value: Value) {
        self.send_to(conn, &success(id, value));
    }

    fn send_tool_error(&self, conn: u64, id: &Value, error: &TeamError) {
        self.send_error(conn, id, error);
    }

    /// `team` or `{instance, sessionId}` (exactly one) to a team id. The pair
    /// form keeps `ensure_team`'s structured error for the front end, which
    /// offers "jump to the leader / hand over / cancel" (20.4); only the MCP
    /// tool turns `led_by` into a handover item.
    fn resolve_team(&mut self, params: &Value) -> Result<String, TeamError> {
        let team = params.get("team").and_then(Value::as_str);
        let instance = params.get("instance").and_then(Value::as_str);
        let session = params.get("sessionId").and_then(Value::as_str);
        let has_pair = instance.is_some() || session.is_some();
        match (team, has_pair) {
            (Some(_), true) | (None, false) => Err(TeamError::invalid(
                "use either team or instance and sessionId",
            )),
            (Some(team), false) => Ok(team.to_string()),
            (None, true) => {
                let instance = required_team_string(params, "instance")?;
                let session = required_team_string(params, "sessionId")?;
                let handle = self
                    .instances
                    .get(&instance)
                    .ok_or_else(|| TeamError::new(UNKNOWN_INSTANCE, "unknown instance"))?;
                let launch = crate::team::LeaderLaunch {
                    cwd: handle.key.cwd.clone(),
                    key: handle.key.clone(),
                    env: handle.env.clone(),
                    #[cfg(unix)]
                    launch: handle.launch.clone(),
                };
                let identity = (instance.clone(), session.clone());
                self.with_session_changes(vec![identity], |hub| {
                    hub.teams.ensure_team(&instance, &session, &launch)
                })
            }
        }
    }

    pub(crate) fn handle_team_method(
        &mut self,
        conn: u64,
        method: &str,
        params: &Value,
        id: &Value,
    ) {
        if method == "team.spawn" {
            self.team_spawn(conn, id, params);
            return;
        }
        if method == "team.stop_worker" {
            let result = (|| -> Result<Value, TeamError> {
                let team = required_team_string(params, "team")?;
                let name = required_team_string(params, "name")?;
                let remove = optional_bool(params, "remove")?.unwrap_or(false);
                let (live, start_pending) = self.worker_liveness(&team, &name);
                let outcome =
                    self.teams
                        .stop_worker(&team, &name, remove, true, live, start_pending)?;
                self.apply_stop(&team, &name, &outcome);
                let _ = outcome;
                Ok(json!({}))
            })();
            match result {
                Ok(value) => {
                    self.drain_team_events();
                    self.team_deliveries();
                    self.send_to(conn, &success(id, value));
                }
                Err(error) => self.send_error(conn, id, &error),
            }
            return;
        }
        if method == "team.set_leader" {
            self.team_set_leader(conn, id, params);
            return;
        }
        if method == "session.teams" {
            self.session_teams(conn, id, params);
            return;
        }
        if method == "team.remove_worktree" {
            self.team_remove_worktree(conn, id, params);
            return;
        }
        if method == "team.workflows" || method == "team.workflow_delete" || method == "team.start"
        {
            self.team_deferred(conn, id, method, params);
            return;
        }
        let result = match method {
            "team.configure" => self.team_configure(params).map(|value| (value, false)),
            "team.list" => Ok((self.teams.list(), false)),
            "team.send" => self.team_send(params),
            "team.read" => self.team_read(params).map(|value| (value, false)),
            "team.board" => self.team_board(params).map(|value| (value, false)),
            "team.card_history" => self.team_card_history(params).map(|value| (value, false)),
            "team.answer" => self.team_answer(params),
            "team.answer_group" => self.team_answer_group(params),
            "team.watch" => {
                self.team_watch(conn, id, params);
                return;
            }
            "team.unwatch" => self.team_unwatch(conn, params).map(|value| (value, false)),
            "team.reset_limits" => self.team_reset_limits(params),
            "team.close" => self.team_close(params).map(|value| (value, false)),
            _ => Err(TeamError::new(METHOD_NOT_FOUND, "method not found")),
        };
        match result {
            Ok((value, deliver)) => {
                self.drain_team_events();
                if deliver {
                    self.team_deliveries();
                }
                self.send_to(conn, &success(id, value));
            }
            Err(error) => self.send_error(conn, id, &error),
        }
    }

    // -- front-end methods -------------------------------------------------

    fn team_configure(&mut self, params: &Value) -> Result<Value, TeamError> {
        let cwd = required_team_string(params, "cwd")?;
        if !std::path::Path::new(&cwd).is_absolute() {
            return Err(TeamError::invalid("cwd must be an absolute path"));
        }
        let config = params
            .get("config")
            .cloned()
            .ok_or_else(|| TeamError::invalid("config is required"))?;
        let identities = self.sessions_of_cwd(&cwd);
        self.with_session_changes(identities, |hub| hub.teams.configure(&cwd, config.clone()))?;
        Ok(json!({}))
    }

    /// Start every stored participant of a resumed team (18.15).
    /// Start every stored participant of a resumed team and return the names
    /// that could not be restarted (18.15). The caller sends the one notice, so
    /// its wording fits the reason the team resumed (20.4/20.8).
    fn resume_team(&mut self, team_id: &str) -> Vec<String> {
        let Some(team) = self.teams.team(team_id) else {
            return Vec::new();
        };
        let names: Vec<String> = team
            .order
            .iter()
            .filter(|name| *name != "leader")
            .filter_map(|name| team.participants.get(name))
            .filter(|participant| participant.state != crate::team::ParticipantState::Exited)
            .map(|participant| participant.name.clone())
            .collect();
        let mut failures: Vec<String> = Vec::new();
        for name in names {
            let Some(team) = self.teams.team(team_id) else {
                return failures;
            };
            let Some(participant) = team.participants.get(&name) else {
                continue;
            };
            // A participant stored with one agent resumes only with a template
            // that starts that same agent: its stored session belongs to a
            // conversation the other adapter never had.
            let template_name = match self.teams.resume_template(team_id, &name) {
                Ok((template_name, _)) => template_name,
                Err(reason) => {
                    self.teams.worker_start_failed(team_id, &name, &reason);
                    failures.push(name.clone());
                    continue;
                }
            };
            let resume_session = participant.session.clone();
            let worktree = participant.worktree.clone();
            let resume_model = participant.model.clone();
            let resume_role = participant.spawn_role.clone();
            let leader_cwd = team.cwd.clone();
            let template_worktree = team
                .config
                .templates
                .get(&template_name)
                .is_some_and(|template| template.worktree);
            if template_worktree && worktree.is_none() {
                self.teams
                    .worker_start_failed(team_id, &name, "worktree removed");
                failures.push(name.clone());
                continue;
            }
            let resume_cwd = if let Some(worktree) = &worktree {
                if !std::path::Path::new(&worktree.cwd).is_dir() {
                    self.teams.worker_start_failed(
                        team_id,
                        &name,
                        &format!("the worktree {} is gone", worktree.cwd),
                    );
                    failures.push(name.clone());
                    continue;
                }
                worktree.cwd.clone()
            } else {
                leader_cwd
            };
            let Some(plan) = self.teams.spawn_plan(team_id, &name) else {
                failures.push(name.clone());
                continue;
            };
            let waiting = self.teams.team(team_id).is_some_and(|team| {
                team.inbox.iter().any(|item| {
                    item.kind == ItemKind::Question
                        && item.from == name
                        && item.state == crate::team::ItemState::Open
                })
            });
            if let Some(participant) = self
                .teams
                .team_mut(team_id)
                .and_then(|team| team.participants.get_mut(&name))
            {
                participant.starting = true;
                participant.set_state(if waiting {
                    crate::team::ParticipantState::WaitingHuman
                } else {
                    crate::team::ParticipantState::Idle
                });
                participant.instance = None;
            }
            let lifecycle = self
                .teams
                .team(team_id)
                .and_then(|team| team.participants.get(&name))
                .map(|participant| participant.lifecycle)
                .unwrap_or_default();
            let spawn = SpawnRequest {
                team: team_id.to_string(),
                name: name.clone(),
                template: template_name,
                model: resume_model,
                role: resume_role,
                task: None,
                lifecycle,
            };
            let opts = StartOptions {
                resume: resume_session,
                ..StartOptions::default()
            };
            if !self.start_worker_now(&spawn, &plan, Some(resume_cwd), &opts) {
                failures.push(name.clone());
            }
        }
        failures
    }

    /// `team.set_leader` (20.4): deferred because the notice needs the status
    /// text with the project key.
    fn team_set_leader(&mut self, conn: u64, id: &Value, params: &Value) {
        let result = (|| -> Result<(String, DeferredTeam), TeamError> {
            let team = required_team_string(params, "team")?;
            let instance = required_team_string(params, "instance")?;
            let session = required_team_string(params, "sessionId")?;
            let cwd = self
                .teams
                .team(&team)
                .ok_or_else(|| TeamError::unknown("unknown team"))?
                .cwd
                .clone();
            Ok((
                cwd,
                DeferredTeam::SetLeader {
                    team,
                    instance,
                    session,
                    conn,
                    id: id.clone(),
                    notice: true,
                },
            ))
        })();
        match result {
            Ok((cwd, call)) => self.run_or_defer(conn, id, &cwd, call),
            Err(error) => self.send_error(conn, id, &error),
        }
    }

    /// Move leadership, resuming a suspended team and filling its built-in
    /// template. Sends the one documented notice to the new leader.
    pub(crate) fn apply_set_leader(
        &mut self,
        team: &str,
        instance: &str,
        session: &str,
    ) -> Result<(), TeamError> {
        let previous = self.teams.team(team).and_then(|entry| {
            entry
                .leader_instance
                .clone()
                .zip(entry.leader_session.clone())
        });
        // A and B may share an instance, so both sides are always in the set.
        let mut identities: Vec<(String, String)> =
            vec![(instance.to_string(), session.to_string())];
        if let Some((old_instance, old_session)) = &previous {
            identities.push((old_instance.clone(), old_session.clone()));
        }
        let suspended = self.teams.is_suspended(team);
        let result = self.with_session_changes(identities, |hub| {
            hub.teams.set_leader(team, instance, session)?;
            if suspended {
                if let Some(handle) = hub.instances.get(instance) {
                    let launch = crate::team::LeaderLaunch {
                        cwd: handle.key.cwd.clone(),
                        key: handle.key.clone(),
                        env: handle.env.clone(),
                        #[cfg(unix)]
                        launch: handle.launch.clone(),
                    };
                    let mut config = hub.teams.config_for(&handle.key.cwd);
                    hub.teams.fill_builtin_config(&mut config, &launch);
                    hub.teams.start_resume_with_config(
                        team,
                        instance,
                        session,
                        &handle.key.agent,
                        config,
                    );
                }
            }
            Ok::<(), TeamError>(())
        });
        result?;
        // Both resume paths share the order: enqueue the one summary first, then
        // drain and deliver, so an idle queue sees it at once (20.4/20.8).
        if suspended {
            let failures = self.resume_team(team);
            self.send_resume_notice(team, &failures);
        } else {
            self.send_leader_notice(team);
        }
        self.drain_team_events();
        self.team_deliveries();
        Ok(())
    }

    fn run_set_leader(&mut self, conn: u64, id: &Value, team: &str, instance: &str, session: &str) {
        match self.apply_set_leader(team, instance, session) {
            Ok(()) => {
                self.drain_team_events();
                self.team_deliveries();
                self.send_to(conn, &success(id, json!({})));
            }
            Err(error) => self.send_error(conn, id, &error),
        }
    }

    /// Whether a session may still take a handover: a bound token, a live
    /// instance and its switch on (20.4).
    fn handover_usable(&self, instance: &str, session: &str) -> bool {
        let Some(token) = self.teams.session_token_of(instance, session) else {
            return false;
        };
        let Some((_, _, agent)) = self.teams.session_auth(&token) else {
            return false;
        };
        let Some(handle) = self.instances.get(instance) else {
            return false;
        };
        self.teams.enabled_for(agent, session, &handle.key.cwd)
    }

    fn send_leader_notice(&mut self, team: &str) {
        let Ok(status) = self.teams.status(team, "leader", "") else {
            return;
        };
        let body = format!(
            "{}\n\n{}",
            crate::team::brief::leader_instructions(),
            status
        );
        let _ = self
            .teams
            .send_message(team, "human", "leader", Kind::Notice, &body, None, vec![]);
    }

    /// The one notice a suspended handover sends: the resume summary, the base
    /// instructions and the current `bus.status` (20.4/20.8).
    fn send_resume_notice(&mut self, team: &str, failures: &[String]) {
        let Ok(status) = self.teams.status(team, "leader", "") else {
            return;
        };
        let mut body = String::from("team resumed after a service restart");
        if !failures.is_empty() {
            body.push_str("; not resumed: ");
            body.push_str(&failures.join(", "));
        }
        body.push_str("\n\n");
        body.push_str(crate::team::brief::leader_instructions());
        body.push_str("\n\n");
        body.push_str(&status.to_string());
        let _ = self
            .teams
            .send_message(team, "human", "leader", Kind::Notice, &body, None, vec![]);
    }

    /// `session.teams` (20.5).
    fn session_teams(&mut self, conn: u64, id: &Value, params: &Value) {
        let result = (|| -> Result<SessionTeamsOutcome, TeamError> {
            let instance = required_team_string(params, "instance")?;
            let session = required_team_string(params, "sessionId")?;
            let (agent, cwd, can_reload) = self.session_teams_context(&instance)?;
            let enabled = self.teams.enabled_for(&agent, &session, &cwd);
            let injected = self.session_injected(&instance, &session);
            let leader = self.teams.session_team_entry(&instance, &session);
            let asked = optional_bool(params, "enabled")?;
            if asked.is_none() {
                // A read-only query never waits, but says when a bound token's
                // MCP process has not connected yet (20.5).
                let pending = !injected
                    && self
                        .teams
                        .unconnected_session_token(&instance, &session)
                        .is_some();
                return Ok(SessionTeamsOutcome::Answer(json!({
                    "enabled": enabled,
                    "injected": injected,
                    "leader": leader,
                    "pending": pending,
                })));
            }
            let wanted = asked.unwrap_or(enabled);
            if !wanted {
                return Ok(SessionTeamsOutcome::Answer(self.disable_session_teams(
                    &instance, &session, &agent, injected, leader, params,
                )?));
            }
            // Validate before persisting, marking or waiting (20.5): a disabled
            // cwd changes nothing, whether or not an MCP process is connected.
            if !self.teams.has_config(&cwd) || !self.teams.config_for(&cwd).enabled {
                let mut error = TeamError::not_allowed("teams are disabled for this cwd");
                error.data = Some(json!({ "reason": "off" }));
                return Err(error);
            }
            if injected {
                return Ok(SessionTeamsOutcome::Answer(
                    self.enable_session_teams(&instance, &session, &agent, &cwd, false),
                ));
            }
            // A bound token whose MCP process has never connected may be about
            // to: hold the answer until it does (no reload needed) or the wait
            // expires (20.5). This runs before the reload-capability check: a
            // connection needs no reload at all.
            if let Some(token_id) = self.teams.unconnected_session_token(&instance, &session) {
                return Ok(SessionTeamsOutcome::Pending {
                    instance,
                    session,
                    agent,
                    cwd,
                    token_id,
                    can_reload,
                });
            }
            if !can_reload {
                let mut error = TeamError::not_allowed("the agent cannot reload a session");
                error.data = Some(json!({ "reason": "reload_unsupported" }));
                return Err(error);
            }
            Ok(SessionTeamsOutcome::Answer(self.enable_session_teams(
                &instance, &session, &agent, &cwd, true,
            )))
        })();
        match result {
            Ok(SessionTeamsOutcome::Answer(value)) => self.send_to(conn, &success(id, value)),
            Ok(SessionTeamsOutcome::Pending {
                instance,
                session,
                agent,
                cwd,
                token_id,
                can_reload,
            }) => self.hold_session_enable(
                conn, id, instance, session, agent, cwd, token_id, can_reload,
            ),
            Err(error) => self.send_error(conn, id, &error),
        }
    }

    /// The instance facts `session.teams` needs: agent, cwd and whether the
    /// agent can reload a session.
    fn session_teams_context(&self, instance: &str) -> Result<(String, String, bool), TeamError> {
        let handle = self
            .instances
            .get(instance)
            .ok_or_else(|| TeamError::new(UNKNOWN_INSTANCE, "unknown instance"))?;
        Ok((
            handle.key.agent.clone(),
            handle.key.cwd.clone(),
            handle.relay.agent_reloads_sessions(),
        ))
    }

    /// `session.teams {enabled: false}`: close the led team when allowed, then
    /// store the switch and drop any unused one-shot mark (20.5).
    fn disable_session_teams(
        &mut self,
        instance: &str,
        session: &str,
        agent: &str,
        injected: bool,
        leader: Value,
        params: &Value,
    ) -> Result<Value, TeamError> {
        let leads = !leader.is_null();
        if leads {
            let close = optional_bool(params, "close")?.unwrap_or(false);
            if !close {
                let mut error = TeamError::not_allowed("the session leads a team");
                error.data = Some(json!({ "reason": "leads_team" }));
                return Err(error);
            }
        }
        let close_team = leads.then(|| {
            leader
                .get("id")
                .and_then(Value::as_str)
                .unwrap_or_default()
                .to_string()
        });
        let identity = (instance.to_string(), session.to_string());
        let agent = agent.to_string();
        let session = session.to_string();
        let value = self.with_session_changes(vec![identity.clone()], |hub| {
            if let Some(team) = close_team {
                hub.close_team(&team)?;
            }
            hub.remember_switch(&agent, &session, false);
            hub.forward_loads.remove(&identity);
            Ok(json!({
                "enabled": false,
                "injected": injected,
                "leader": Value::Null,
            }))
        });
        // Turning the switch off ends any held enable of this session: it
        // answers with the state as it is now (20.5).
        self.release_pending_enable(instance, &session);
        value
    }

    /// `session.teams {enabled: true}` with a decision: store the switch and
    /// mark the one-shot reload when `reload` is set (20.5).
    fn enable_session_teams(
        &mut self,
        instance: &str,
        session: &str,
        agent: &str,
        cwd: &str,
        reload: bool,
    ) -> Value {
        let identity = (instance.to_string(), session.to_string());
        let agent = agent.to_string();
        let session = session.to_string();
        let cwd = cwd.to_string();
        self.with_session_changes(vec![identity.clone()], |hub| {
            hub.remember_switch(&agent, &session, true);
            if reload {
                hub.forward_loads.insert(identity.clone());
            }
            let leader = hub.teams.session_team_entry(&identity.0, &identity.1);
            let injected = hub.session_injected(&identity.0, &identity.1);
            let enabled = hub.teams.enabled_for(&agent, &session, &cwd);
            json!({
                "enabled": enabled,
                "injected": injected,
                "leader": leader,
                "reload": reload,
            })
        })
    }

    /// Hold `session.teams {enabled: true}` until the bound token's MCP process
    /// connects, the wait expires, or the state it waits on goes away (20.5).
    #[allow(clippy::too_many_arguments)]
    fn hold_session_enable(
        &mut self,
        conn: u64,
        id: &Value,
        instance: String,
        session: String,
        agent: String,
        cwd: String,
        token_id: String,
        can_reload: bool,
    ) {
        self.next_pending_enable += 1;
        let generation = self.next_pending_enable;
        let deadline_instance = instance.clone();
        let deadline_session = session.clone();
        self.pending_enables.insert(
            generation,
            PendingEnable {
                conn,
                id: id.clone(),
                instance,
                session,
                agent,
                cwd,
                token_id,
                can_reload,
            },
        );
        let sender = self.command_sender.clone();
        let timeout = team_inject_wait_ms();
        tokio::spawn(async move {
            tokio::time::sleep(Duration::from_millis(timeout)).await;
            let _ = sender
                .send(Command::SessionEnableDeadline {
                    instance: deadline_instance,
                    session: deadline_session,
                    generation,
                })
                .await;
        });
    }

    /// Answer a held `session.teams` and forget its record. `decision` is what
    /// the wait ended with (20.5).
    fn answer_pending_enable(&mut self, pending: PendingEnable, decision: EnableDecision) {
        if !self.conns.contains_key(&pending.conn) {
            return;
        }
        match decision {
            EnableDecision::Connected => {
                let value = self.enable_session_teams(
                    &pending.instance,
                    &pending.session,
                    &pending.agent,
                    &pending.cwd,
                    false,
                );
                self.send_to(pending.conn, &success(&pending.id, value));
            }
            EnableDecision::TimedOut => {
                if !self.teams.has_config(&pending.cwd)
                    || !self.teams.config_for(&pending.cwd).enabled
                {
                    let mut error = TeamError::not_allowed("teams are disabled for this cwd");
                    error.data = Some(json!({ "reason": "off" }));
                    self.send_error(pending.conn, &pending.id, &error);
                    return;
                }
                // The wait ran out with no connection: fall back to the
                // documented answer, which needs a reload the agent must
                // support (20.5).
                if !pending.can_reload {
                    let mut error = TeamError::not_allowed("the agent cannot reload a session");
                    error.data = Some(json!({ "reason": "reload_unsupported" }));
                    self.send_error(pending.conn, &pending.id, &error);
                    return;
                }
                let value = self.enable_session_teams(
                    &pending.instance,
                    &pending.session,
                    &pending.agent,
                    &pending.cwd,
                    true,
                );
                self.send_to(pending.conn, &success(&pending.id, value));
            }
            EnableDecision::Changed => {
                // The premise of the wait went away (the token was revoked, the
                // instance exited, the session closed or the switch was turned
                // off): answer with the state as it is now, without touching
                // the switch and without marking a reload (20.5).
                let leader = self
                    .teams
                    .session_team_entry(&pending.instance, &pending.session);
                let injected = self.session_injected(&pending.instance, &pending.session);
                let enabled =
                    self.teams
                        .enabled_for(&pending.agent, &pending.session, &pending.cwd);
                self.send_to(
                    pending.conn,
                    &success(
                        &pending.id,
                        json!({
                            "enabled": enabled,
                            "injected": injected,
                            "leader": leader,
                            "reload": false,
                        }),
                    ),
                );
            }
        }
    }

    /// A held enable's wait expired: decide by the state now (20.5).
    pub(crate) fn session_enable_deadline(
        &mut self,
        instance: &str,
        session: &str,
        generation: u64,
    ) {
        let Some(pending) = self.pending_enables.remove(&generation) else {
            return;
        };
        if pending.instance != instance || pending.session != session {
            // Stale deadline of a superseded wait; keep the live one.
            self.pending_enables.insert(generation, pending);
            return;
        }
        let injected = self.session_injected(&pending.instance, &pending.session);
        let decision = if injected {
            EnableDecision::Connected
        } else {
            EnableDecision::TimedOut
        };
        self.answer_pending_enable(pending, decision);
    }

    /// The token of a held enable handshaked: answer without a reload (20.5).
    pub(crate) fn note_session_handshake(&mut self, token_id: &str) {
        let waiting: Vec<u64> = self
            .pending_enables
            .iter()
            .filter(|(_, pending)| pending.token_id == token_id)
            .map(|(generation, _)| *generation)
            .collect();
        for generation in waiting {
            let Some(pending) = self.pending_enables.remove(&generation) else {
                continue;
            };
            self.answer_pending_enable(pending, EnableDecision::Connected);
        }
    }

    /// The state a held enable depends on changed (token revoked, instance
    /// exit, session closed, switch off): answer with the state as it is now.
    pub(crate) fn release_pending_enable(&mut self, instance: &str, session: &str) {
        let waiting: Vec<u64> = self
            .pending_enables
            .iter()
            .filter(|(_, pending)| pending.instance == instance && pending.session == session)
            .map(|(generation, _)| *generation)
            .collect();
        for generation in waiting {
            let Some(pending) = self.pending_enables.remove(&generation) else {
                continue;
            };
            self.answer_pending_enable(pending, EnableDecision::Changed);
        }
    }

    /// Every held enable of an instance (its exit revokes the tokens).
    pub(crate) fn release_pending_enables_of(&mut self, instance: &str) {
        let keys: Vec<(String, String)> = self
            .pending_enables
            .values()
            .filter(|pending| pending.instance == instance)
            .map(|pending| (pending.instance.clone(), pending.session.clone()))
            .collect();
        let mut seen = HashSet::new();
        for key in keys {
            if seen.insert(key.clone()) {
                self.release_pending_enable(&key.0, &key.1);
            }
        }
    }

    /// A front-end connection left: its held replies are dropped (20.5).
    pub(crate) fn drop_pending_enables_of(&mut self, conn: u64) {
        self.pending_enables
            .retain(|_, pending| pending.conn != conn);
    }

    /// Resume a stored team when a forwarded load/resume of its stored leader
    /// session was accepted and got a session token (20.7).
    fn resume_for_session(&mut self, instance: &str, session: &str, agent: &str, cwd: &str) {
        let Some(team) = self.teams.team_for_cwd(cwd) else {
            return;
        };
        if !team.suspended || team.leader_session.as_deref() != Some(session) || team.cwd != cwd {
            return;
        }
        let team_id = team.id.clone();
        if self.teams.stored_leader_agent(&team_id).as_deref() != Some(agent) {
            return;
        }
        if self.teams.session_token_of(instance, session).is_none() {
            return;
        }
        // Commit-time re-check: a switch turned off or a cwd disabled while the
        // load was in flight must not resume (20.7/#5).
        if !self.teams.has_config(cwd) || !self.teams.config_for(cwd).enabled {
            return;
        }
        let Some(handle) = self.instances.get(instance) else {
            return;
        };
        if !self.teams.enabled_for(&handle.key.agent, session, cwd) {
            return;
        }
        let launch = crate::team::LeaderLaunch {
            cwd: cwd.to_string(),
            key: handle.key.clone(),
            env: handle.env.clone(),
            #[cfg(unix)]
            launch: handle.launch.clone(),
        };
        let mut config = self.teams.config_for(cwd);
        self.teams.fill_builtin_config(&mut config, &launch);
        let identity = (instance.to_string(), session.to_string());
        self.with_session_changes(vec![identity], |hub| {
            hub.teams
                .start_resume_with_config(&team_id, instance, session, agent, config);
        });
        let failures = self.resume_team(&team_id);
        self.send_resume_notice(&team_id, &failures);
        self.drain_team_events();
        self.team_deliveries();
    }

    fn team_send(&mut self, params: &Value) -> Result<(Value, bool), TeamError> {
        let team = required_team_string(params, "team")?;
        let to = required_team_string(params, "to")?;
        let kind = Kind::parse(
            params
                .get("kind")
                .ok_or_else(|| TeamError::invalid("kind is required"))?,
        )?;
        let mut body = required_team_string(params, "body")?;
        let mut task = optional_string(params, "task")?;
        if let Some(card) = optional_string(params, "card")? {
            let (prefixed, default_task) =
                self.teams
                    .card_message(&team, &card, &body, task.as_deref())?;
            body = prefixed;
            task = task.or(default_task);
        }
        let refs = team_refs(params)?;
        let interrupt = optional_bool(params, "interrupt")?.unwrap_or(false);
        let cc = match params.get("cc") {
            None | Some(Value::Null) => Vec::new(),
            Some(Value::Array(items)) => {
                let mut names = Vec::new();
                for item in items {
                    let Some(name) = item.as_str() else {
                        return Err(TeamError::invalid("cc must contain participant names"));
                    };
                    names.push(name.to_string());
                }
                names
            }
            Some(_) => return Err(TeamError::invalid("cc must be an array")),
        };
        let Some(entry) = self.teams.team(&team) else {
            return Err(TeamError::unknown("unknown team"));
        };
        let role = if to == "human" {
            None
        } else {
            match entry.participants.get(&to) {
                Some(participant) => Some(participant.role),
                None => return Err(TeamError::unknown("unknown participant")),
            }
        };
        if interrupt {
            if kind == Kind::Control {
                return Err(TeamError::invalid(
                    "interrupt is not allowed for control messages",
                ));
            }
            if role != Some(Role::Worker) {
                return Err(TeamError::invalid("interrupt is only allowed for a worker"));
            }
        }
        for name in &cc {
            if name != "leader" || role != Some(Role::Worker) {
                return Err(TeamError::invalid(
                    "cc only accepts \"leader\" and only when to is a worker",
                ));
            }
        }
        let id =
            self.teams
                .send_message(&team, "human", &to, kind, &body, task.as_deref(), refs)?;
        let mut cc_failed = None;
        if interrupt && self.teams.bus_turn_running(&team, &to) {
            let queue_key = (team.clone(), to.clone());
            let mut earlier = self.interrupt_queue.remove(&queue_key).unwrap_or_default();
            earlier.retain(|queued| self.teams.message_queued(&team, &to, *queued));
            let after = earlier.len();
            self.teams.prioritize_message(&team, &to, id, after);
            earlier.push(id);
            self.interrupt_queue.insert(queue_key, earlier);
            self.teams.mark_interrupting(&team, &to);
            let orphaned = self.teams.orphan_open_items(&team, &to);
            for item in orphaned {
                let Some(instance) = item.instance.clone() else {
                    continue;
                };
                let Some(agent_id) = item.agent_id.clone() else {
                    continue;
                };
                let response = if item.kind == ItemKind::Permission {
                    json!({ "outcome": { "outcome": "cancelled" } })
                } else {
                    json!({ "action": "cancel" })
                };
                self.answer_pending(&instance, agent_id, response);
            }
            self.cancel_participant_turn(&team, &to);
            self.next_interrupt_generation += 1;
            let generation = self.next_interrupt_generation;
            let prompt_seq = self.teams.prompt_seq(&team, &to);
            self.interrupt_generation
                .insert((team.clone(), to.clone()), (generation, prompt_seq));
            let sender = self.command_sender.clone();
            let team_for_timer = team.clone();
            let participant_for_timer = to.clone();
            let timeout = std::env::var("NVIM_ADE_SERVER_HELD_TIMEOUT_MS")
                .ok()
                .and_then(|value| value.trim().parse::<u64>().ok())
                .unwrap_or(30_000);
            tokio::spawn(async move {
                tokio::time::sleep(Duration::from_millis(timeout)).await;
                let _ = sender
                    .send(Command::TeamInterruptDeadline {
                        team: team_for_timer,
                        participant: participant_for_timer,
                        generation,
                    })
                    .await;
            });
        }
        for name in cc {
            if name == "leader" {
                let notice = format!("to {to}: {body}");
                if let Err(error) = self.teams.send_message(
                    &team,
                    "human",
                    "leader",
                    Kind::Notice,
                    &notice,
                    task.as_deref(),
                    vec![],
                ) {
                    cc_failed = Some(error.message);
                }
            }
        }
        if kind == Kind::Control && body == "cancel" {
            self.cancel_participant_turn(&team, &to);
        }
        let mut result = json!({ "id": id });
        if let Some(message) = cc_failed {
            result["cc_failed"] = json!(message);
        }
        Ok((result, true))
    }

    fn team_read(&mut self, params: &Value) -> Result<Value, TeamError> {
        let team = required_team_string(params, "team")?;
        let participant = required_team_string(params, "participant")?;
        let since = optional_u64(params, "since")?;
        self.teams.read(&team, &participant, since)
    }

    fn team_board(&mut self, params: &Value) -> Result<Value, TeamError> {
        let team = required_team_string(params, "team")?;
        self.teams.board(&team)
    }

    fn team_card_history(&mut self, params: &Value) -> Result<Value, TeamError> {
        let team = required_team_string(params, "team")?;
        let card = required_team_string(params, "card")?;
        self.teams.card_history(&team, &card)
    }

    fn team_answer(&mut self, params: &Value) -> Result<(Value, bool), TeamError> {
        let request = required_team_string(params, "request")?;
        let text = optional_string(params, "text")?;
        let option = optional_string(params, "option")?;
        let allow = optional_bool(params, "allow")?;
        let answers = match params.get("answers") {
            None | Some(Value::Null) => None,
            Some(value) => Some(crate::team::parse_answers(value)?),
        };
        if answers.is_some() && (text.is_some() || option.is_some()) {
            return Err(TeamError::invalid(
                "use either answers or text/option, not both",
            ));
        }
        // A handover is only answered for a session that can still lead
        // (20.4/J); the item stays open otherwise.
        if let Some(item) = self.teams.item_by_id(&request) {
            if item.kind == crate::team::ItemKind::Handover
                && item.state == crate::team::ItemState::Open
            {
                let instance = item.from_instance.clone().unwrap_or_default();
                let session = item.from_session.clone().unwrap_or_default();
                if !self.handover_usable(&instance, &session) {
                    let mut error = TeamError::not_allowed("the requesting session is gone");
                    error.data = Some(json!({ "reason": "no_tools" }));
                    return Err(error);
                }
            }
        }
        let before = self.teams.item_by_id(&request);
        let (effect, team) = self
            .teams
            .answer_with(&request, answers, text, option, allow)?;
        let spawned = self.apply_answer_effect(&request, effect);
        if let Some(item) = before {
            if item.kind == ItemKind::Spawn && !spawned {
                self.team_spawn_notice(&team, &request, false, item.name.as_deref().unwrap_or(""));
            }
        }
        Ok((json!({}), true))
    }

    fn team_unwatch(&mut self, conn: u64, params: &Value) -> Result<Value, TeamError> {
        let team = required_team_string(params, "team")?;
        let participant = required_team_string(params, "participant")?;
        let instance = self.teams.participant_instance(&team, &participant);
        self.teams.unwatch(&team, &participant, conn)?;
        if let Some(instance) = instance {
            if let Some(handle) = self.instances.get_mut(&instance) {
                handle.relay.forget_delivered(conn);
            }
        }
        Ok(json!({}))
    }

    fn team_reset_limits(&mut self, params: &Value) -> Result<(Value, bool), TeamError> {
        let team = required_team_string(params, "team")?;
        self.teams.reset_limits(&team)?;
        Ok((json!({}), true))
    }

    fn team_close(&mut self, params: &Value) -> Result<Value, TeamError> {
        let team = required_team_string(params, "team")?;
        self.close_team(&team)
    }

    fn close_team(&mut self, team: &str) -> Result<Value, TeamError> {
        // Capture the leader before `teams.close` removes the team. Its session
        // and instance stay alive, but a running prompt (bus or front end) is
        // cancelled like any other turn; held front-end prompts are dropped.
        let leader = self
            .teams
            .team(team)
            .and_then(|row| row.leader_instance.clone().zip(row.leader_session.clone()));
        // Pending worker writes are flushed before the team (and its board)
        // goes away (19.2).
        self.flush_pending_board(team, false);
        let before = leader
            .as_ref()
            .map(|(instance, session)| self.session_states(&[(instance.clone(), session.clone())]))
            .unwrap_or_default();
        let (_entry, workers) = self.teams.close(team)?;
        self.publish_session_changes(before);
        if let Some((instance, session)) = leader {
            let running = self
                .instances
                .get(&instance)
                .map(|handle| {
                    self.bus_prompt_active(&instance, &session)
                        || handle
                            .attached
                            .iter()
                            .any(|conn| handle.relay.prompt_active(*conn, &session))
                })
                .unwrap_or(false);
            if running {
                if let Some(handle) = self.instances.get(&instance) {
                    handle.control.send_frame(json!({
                        "jsonrpc": "2.0",
                        "method": "session/cancel",
                        "params": { "sessionId": session },
                    }));
                }
            }
            self.cancel_held_session(&instance, &session);
            // A re-created team may bind the same leader session; its next bus
            // turn must be able to hold and cancel afresh.
            self.held_timed_out.remove(&(instance, session));
        }
        self.interrupt_queue
            .retain(|(id, _), _| id.as_str() != team);
        self.interrupt_generation
            .retain(|(id, _), _| id.as_str() != team);
        for instance in workers {
            let Some(handle) = self.instances.get(&instance) else {
                continue;
            };
            let control = handle.control.clone();
            let timeouts = self.timeouts;
            tokio::spawn(async move {
                control.stop(false, timeouts).await;
            });
        }
        Ok(json!({}))
    }

    /// `team.watch` answers later when a replay is requested.
    fn team_watch(&mut self, conn: u64, id: &Value, params: &Value) {
        let result = (|| -> Result<(), TeamError> {
            let team = required_team_string(params, "team")?;
            if self.teams.is_suspended(&team) {
                return Err(TeamError::unknown("suspended"));
            }
            let participant = required_team_string(params, "participant")?;
            let replay = optional_bool(params, "replay")?.unwrap_or(false);
            if replay && self.gates.contains_key(&conn) {
                return Err(TeamError::invalid("a replay is already in progress"));
            }
            let (instance, session) = self.teams.watch(&team, &participant, conn)?;
            if replay {
                self.gates.insert(conn, Gate::new(self.limits.gate_bytes));
            }
            let pending = self
                .instances
                .get(&instance)
                .map(|handle| handle.relay.pending_messages())
                .unwrap_or_default();
            for (seq, message) in &pending {
                self.send_tunnel_recv_direct(conn, &instance, *seq, message);
                if let Some(handle) = self.instances.get_mut(&instance) {
                    if let Some(request_id) = message.get("id").cloned() {
                        handle.relay.mark_delivered(&request_id, conn);
                    }
                }
            }
            if !replay {
                let value =
                    json!({ "instance": instance, "sessionId": session, "replayed": false });
                self.send_to(conn, &success(id, value));
                return Ok(());
            }
            let Some(handle) = self.instances.get(&instance) else {
                let value =
                    json!({ "instance": instance, "sessionId": session, "replayed": false });
                self.send_to(conn, &success(id, value));
                self.release_gate(conn);
                return Ok(());
            };
            let log_key = handle.log_key.clone();
            let current_seq = handle.relay.current_seq();
            if self.recorder.bytes(&log_key) > self.limits.replay_bytes {
                let value =
                    json!({ "instance": instance, "sessionId": session, "replayed": false });
                self.send_to(conn, &success(id, value));
                self.release_gate(conn);
                return Ok(());
            }
            let recorder = self.recorder.clone();
            let sender = self.team_sender.clone();
            let frontend_id = id.clone();
            let instance_for_task = instance.clone();
            let session_for_task = session.clone();
            tokio::spawn(async move {
                let replay = recorder
                    .read_session(&log_key, &session_for_task, current_seq)
                    .await;
                let messages = match replay {
                    Ok(replay) if replay.complete => Some(Relay::replay_messages(&replay.events)),
                    _ => None,
                };
                let _ = sender.send(TeamResult::Watch {
                    conn,
                    frontend_id,
                    instance: instance_for_task,
                    session: session_for_task,
                    messages,
                });
            });
            Ok(())
        })();
        if let Err(error) = result {
            self.send_to(conn, &failure(id, error.code, &error.message));
        }
    }

    pub(crate) fn finish_team_result(&mut self, result: TeamResult) {
        match result {
            TeamResult::Watch {
                conn,
                frontend_id,
                instance,
                session,
                messages,
            } => {
                if !self.conns.contains_key(&conn) {
                    self.gates.remove(&conn);
                    return;
                }
                let replayed = messages.is_some();
                if let Some(messages) = messages {
                    for (seq, message) in &messages {
                        self.send_tunnel_recv_direct(conn, &instance, *seq, message);
                    }
                }
                self.send_to(
                    conn,
                    &success(
                        &frontend_id,
                        json!({ "instance": instance, "sessionId": session, "replayed": replayed }),
                    ),
                );
                self.release_gate(conn);
            }
            TeamResult::ProjectKey {
                conn,
                frontend_id,
                call,
                cwd,
                project,
                cache,
            } => {
                if cache {
                    self.teams.set_project_key(&cwd, &project);
                }
                self.run_deferred(conn, &frontend_id, call, &project);
            }
        }
    }

    // -- participant bus methods ------------------------------------------

    fn bus_send(
        &mut self,
        conn: u64,
        team: &str,
        name: &str,
        params: &Value,
    ) -> Result<(Value, bool), TeamError> {
        let _ = conn;
        let to = required_team_string(params, "to")?;
        let kind = Kind::parse(
            params
                .get("kind")
                .ok_or_else(|| TeamError::invalid("kind is required"))?,
        )?;
        let body = required_team_string(params, "body")?;
        let task = optional_string(params, "task")?;
        let refs = team_refs(params)?;
        let id = self
            .teams
            .send_message(team, name, &to, kind, &body, task.as_deref(), refs)?;
        if kind == Kind::Control && body == "cancel" {
            self.cancel_participant_turn(team, &to);
        }
        Ok((json!({ "id": id }), true))
    }

    fn bus_ask_human(
        &mut self,
        team: &str,
        name: &str,
        params: &Value,
    ) -> Result<(Value, bool), TeamError> {
        if let Some(questions) = params.get("questions").filter(|value| !value.is_null()) {
            if params.get("question").is_some_and(|value| !value.is_null())
                || params.get("options").is_some_and(|value| !value.is_null())
            {
                return Err(TeamError::invalid(
                    "use either question/options or questions, not both",
                ));
            }
            let questions = crate::team::parse_questions(questions)?;
            let request = self
                .teams
                .ask_human_questions(team, name, questions, None)?;
            return Ok((json!({ "request": request }), true));
        }
        let question = required_team_string(params, "question")?;
        if question.is_empty() || question.len() > MAX_BODY_BYTES {
            return Err(TeamError::invalid("question must be 1..64 KiB"));
        }
        let options = match params.get("options") {
            None | Some(Value::Null) => None,
            Some(Value::Array(items)) => {
                let mut options = Vec::new();
                for item in items {
                    let Some(option) = item.as_str() else {
                        return Err(TeamError::invalid("options must be strings"));
                    };
                    options.push(option.to_string());
                }
                Some(options)
            }
            Some(_) => return Err(TeamError::invalid("options must be an array")),
        };
        let request = self.teams.ask_human(team, name, &question, options)?;
        Ok((json!({ "request": request }), true))
    }

    fn bus_read(&mut self, team: &str, params: &Value) -> Result<(Value, bool), TeamError> {
        let participant = required_team_string(params, "participant")?;
        let since = optional_u64(params, "since")?;
        Ok((self.teams.read(team, &participant, since)?, false))
    }

    /// `bus.board_update` (leader, 19.2): one atomic write, persisted and
    /// announced at once. A worker write still waiting for its timer is
    /// flushed first.
    fn bus_board_update(&mut self, team: &str, params: &Value) -> Result<(Value, bool), TeamError> {
        self.flush_pending_board(team, true);
        let rev = self
            .teams
            .board_update(team, params, crate::team::now_ms())?;
        self.persist_board(team);
        self.announce_board(team, rev);
        Ok((json!({ "rev": rev }), false))
    }

    /// `bus.card_update` (owner worker, 19.2): applied at once, persisted and
    /// announced by the coalescing timer.
    fn bus_card_update(
        &mut self,
        team: &str,
        name: &str,
        params: &Value,
    ) -> Result<(Value, bool), TeamError> {
        let now = crate::team::now_ms();
        let rev = self.teams.card_update(team, name, params, now)?;
        if let Some(current) = self.teams.team_mut(team) {
            if current.board_flush_at.is_none() {
                current.board_flush_at = Some(now + crate::team::board::flush_interval_ms());
            }
        }
        Ok((json!({ "rev": rev }), false))
    }

    fn announce_board(&self, team: &str, rev: u64) {
        self.send_to_frontends(&json!({
            "jsonrpc": "2.0",
            "method": "team.board_changed",
            "params": { "team": team, "rev": rev },
        }));
    }

    /// Write the board if it changed since the last persistence. Returns the
    /// persisted rev.
    fn persist_board(&mut self, team: &str) -> Option<u64> {
        let persist = self.teams.take_board_persist(team, crate::team::now_ms())?;
        let rev = persist.rev;
        self.recorder.save_board(
            team,
            persist.rev,
            persist.json,
            persist.history,
            persist.cleared,
        );
        Some(rev)
    }

    fn flush_pending_board(&mut self, team: &str, announce: bool) {
        if let Some(rev) = self.persist_board(team) {
            if announce {
                self.announce_board(team, rev);
            }
        }
    }

    pub(crate) fn flush_due_boards(&mut self) {
        let now = crate::team::now_ms();
        for team in self.teams.due_board_flushes(now) {
            self.flush_pending_board(&team, true);
        }
    }

    pub(crate) fn flush_all_boards(&mut self, announce: bool) {
        for team in self.teams.pending_boards() {
            self.flush_pending_board(&team, announce);
        }
    }

    /// `team.spawn` (18.13): the person starts a worker, no inbox item.
    fn team_spawn(&mut self, conn: u64, id: &Value, params: &Value) {
        let result = (|| -> Result<(SpawnRequest, String), TeamError> {
            let team = self.resolve_team(params)?;
            let template = required_team_string(params, "template")?;
            let name = optional_string(params, "name")?;
            let model = optional_string(params, "model")?;
            let role = optional_string(params, "role")?;
            let task = optional_string(params, "task")?;
            let label = optional_string(params, "label")?;
            let spawn = self.teams.request_spawn_human_labeled(
                &team,
                &template,
                name.as_deref(),
                model.as_deref(),
                role.as_deref(),
                task.as_deref(),
                label.as_deref(),
            )?;
            Ok((spawn, team))
        })();
        match result {
            Ok((spawn, team)) => {
                self.drain_team_events();
                let opts = StartOptions {
                    reply: Some((conn, id.clone(), SpawnReplyKind::Team)),
                    human_notice: true,
                    ..StartOptions::default()
                };
                if matches!(self.start_worker(&spawn, opts), StartResult::Started) {
                    let mut value = Self::spawn_value(&spawn.name, SpawnReplyKind::Team, None);
                    if let Some(entry) = self.teams.entry(&team) {
                        value["team"] = entry;
                    }
                    self.send_to(conn, &success(id, value));
                }
                self.drain_team_events();
                self.team_deliveries();
            }
            Err(error) => self.send_error(conn, id, &error),
        }
    }

    /// `team.remove_worktree` (18.16): allowed for an exited worker only.
    fn team_remove_worktree(&mut self, conn: u64, id: &Value, params: &Value) {
        let result = (|| -> Result<worktree::WorktreeInfo, TeamError> {
            let team = required_team_string(params, "team")?;
            let participant = required_team_string(params, "participant")?;
            let force = optional_bool(params, "force")?.unwrap_or(false);
            let entry = self
                .teams
                .team(&team)
                .ok_or_else(|| TeamError::unknown("unknown team"))?;
            let worker = entry
                .participants
                .get(&participant)
                .ok_or_else(|| TeamError::unknown("unknown participant"))?;
            if worker.role != Role::Worker {
                return Err(TeamError::not_allowed("only a worker has a worktree"));
            }
            if worker.state != crate::team::ParticipantState::Exited && !entry.suspended {
                return Err(TeamError::not_allowed("the worker is still running"));
            }
            let info = worker
                .worktree
                .clone()
                .ok_or_else(|| TeamError::invalid("the worker has no worktree"))?;
            if self
                .pending_removals
                .contains_key(&(team.clone(), participant.clone()))
            {
                return Err(TeamError::invalid("a removal is already in progress"));
            }
            self.pending_removals
                .insert((team.clone(), participant.clone()), (conn, id.clone()));
            let sender = self.command_sender.clone();
            let team_for_git = team.clone();
            let participant_for_git = participant.clone();
            let toplevel = info.toplevel.clone();
            let path = info.path.clone();
            let branch = info.branch.clone();
            tokio::spawn(async move {
                let result = worktree::remove(&toplevel, &path, &branch, force).await;
                let _ = sender
                    .send(Command::TeamWorktree {
                        team: team_for_git,
                        participant: participant_for_git,
                        lifecycle: 0,
                        outcome: WorktreeOutcome::Remove(result),
                    })
                    .await;
            });
            // The actual reply is sent when git finishes.
            Ok(info)
        })();
        if let Err(error) = result {
            self.send_error(conn, id, &error);
        }
    }

    /// `team.workflows`, `team.workflow_delete` and `team.start` (19.5/19.7):
    /// they need the cwd's project key, which is computed off the hub loop.
    fn team_deferred(&mut self, conn: u64, id: &Value, method: &str, params: &Value) {
        let result = (|| -> Result<(String, DeferredTeam), TeamError> {
            match method {
                "team.workflows" => {
                    let cwd = absolute_cwd(params)?;
                    Ok((cwd.clone(), DeferredTeam::Workflows { cwd }))
                }
                "team.workflow_delete" => {
                    let cwd = absolute_cwd(params)?;
                    let name = required_team_string(params, "name")?;
                    let scope = required_team_string(params, "scope")?;
                    Ok((cwd, DeferredTeam::WorkflowDeleteCwd { name, scope }))
                }
                "team.start" => {
                    let workflow = required_team_string(params, "workflow")?;
                    let task = optional_string(params, "task")?;
                    let team = self.resolve_team(params)?;
                    let cwd = self
                        .teams
                        .team(&team)
                        .ok_or_else(|| TeamError::unknown("unknown team"))?
                        .cwd
                        .clone();
                    Ok((
                        cwd,
                        DeferredTeam::Start {
                            team,
                            workflow,
                            task,
                        },
                    ))
                }
                _ => Err(TeamError::new(METHOD_NOT_FOUND, "method not found")),
            }
        })();
        match result {
            Ok((cwd, call)) => self.run_or_defer(conn, id, &cwd, call),
            Err(error) => self.send_error(conn, id, &error),
        }
    }

    /// Run a deferred call now if the project key is cached, else compute it in
    /// a task and answer from [`TeamResult::ProjectKey`].
    fn run_or_defer(&mut self, conn: u64, id: &Value, cwd: &str, call: DeferredTeam) {
        if let Some(project) = self.teams.project_key(cwd).map(str::to_string) {
            self.run_deferred(conn, id, call, &project);
            return;
        }
        let sender = self.team_sender.clone();
        let cwd = cwd.to_string();
        let frontend_id = id.clone();
        tokio::spawn(async move {
            let (project, cache) = match workflow::git_project_key(&cwd).await {
                Some(project) => (project, true),
                // A git failure is not cached: the next call tries again.
                None => (workflow::canonical_cwd(&cwd), false),
            };
            let _ = sender.send(TeamResult::ProjectKey {
                conn,
                frontend_id,
                call,
                cwd,
                project,
                cache,
            });
        });
    }

    fn run_deferred(&mut self, conn: u64, id: &Value, call: DeferredTeam, project: &str) {
        match call {
            DeferredTeam::SessionStatus {
                conn,
                id,
                token_id,
                team,
            } => {
                let (agent, session) = self
                    .teams
                    .session_auth(&token_id)
                    .map(|(_, session, agent)| (agent.to_string(), session.to_string()))
                    .unwrap_or_default();
                match self.teams.status(&team, "leader", project) {
                    Ok(mut value) => {
                        value["enabled"] = json!(true);
                        value["leader"] = json!(true);
                        value["injected"] = json!(self.session_injected(&team, &session));
                        let _ = &agent;
                        self.send_tool_success(conn, &id, value);
                    }
                    Err(error) => self.send_tool_error(conn, &id, &error),
                }
            }
            DeferredTeam::Status { team, name } => match self.teams.status(&team, &name, project) {
                Ok(value) => self.send_to(conn, &success(id, value)),
                Err(error) => self.send_error(conn, id, &error),
            },
            DeferredTeam::Workflows { cwd } => {
                let value = self.teams.workflows_for_cwd(&cwd, project);
                self.send_to(conn, &success(id, value));
            }
            DeferredTeam::WorkflowDeleteCwd { name, scope } => {
                if !self.recorder.enabled() {
                    self.send_error(conn, id, &TeamError::not_allowed("no database"));
                    return;
                }
                let scope = match stored_scope(Some(&scope)) {
                    Ok(scope) => scope,
                    Err(error) => {
                        self.send_error(conn, id, &error);
                        return;
                    }
                };
                match self.teams.workflow_delete_for_cwd(project, &name, scope) {
                    Ok(removed) => {
                        self.forget_workflow(&removed, project);
                        self.send_to(conn, &success(id, json!({})));
                    }
                    Err(error) => self.send_error(conn, id, &error),
                }
            }
            DeferredTeam::WorkflowSaveCwd {
                cwd,
                value,
                scope,
                replace,
            } => {
                if !self.recorder.enabled() {
                    self.send_tool_error(conn, id, &TeamError::not_allowed("no database"));
                    return;
                }
                let scope = match stored_scope(scope.as_deref()) {
                    Ok(scope) => scope,
                    Err(error) => {
                        self.send_tool_error(conn, id, &error);
                        return;
                    }
                };
                match self
                    .teams
                    .workflow_save_for_cwd(&cwd, project, &value, scope, replace)
                {
                    Ok(stored) => {
                        self.persist_workflow(&stored, project);
                        self.send_tool_success(conn, id, json!({ "name": stored.name }));
                    }
                    Err(error) => self.send_tool_error(conn, id, &error),
                }
            }
            DeferredTeam::WorkflowGetCwd { cwd, name } => {
                match self.teams.workflow_get_for_cwd(&cwd, project, &name) {
                    Ok(value) => self.send_tool_success(conn, id, value),
                    Err(error) => self.send_tool_error(conn, id, &error),
                }
            }
            DeferredTeam::WorkflowDeleteCwdScope { cwd, name, scope } => {
                if !self.recorder.enabled() {
                    self.send_tool_error(conn, id, &TeamError::not_allowed("no database"));
                    return;
                }
                let scope = match scope.map(|scope| stored_scope(Some(&scope))).transpose() {
                    Ok(scope) => scope,
                    Err(error) => {
                        self.send_tool_error(conn, id, &error);
                        return;
                    }
                };
                match self
                    .teams
                    .workflow_delete_for_cwd_scope(&cwd, project, &name, scope)
                {
                    Ok(removed) => {
                        self.forget_workflow(&removed, project);
                        self.send_tool_success(conn, id, json!({}));
                    }
                    Err(error) => self.send_tool_error(conn, id, &error),
                }
            }
            DeferredTeam::SetLeader {
                team,
                instance,
                session,
                conn,
                id,
                notice,
            } => {
                let _ = notice;
                self.run_set_leader(conn, &id, &team, &instance, &session);
            }
            DeferredTeam::Start {
                team,
                workflow,
                task,
            } => self.team_start_now(conn, id, &team, &workflow, task, project),
        }
    }

    /// The database key of a stored workflow: `("user", "", name)` or
    /// `("project", <project key>, name)`.
    fn workflow_db_key(stored: &workflow::Workflow, project: &str) -> (String, String, String) {
        let project = if stored.scope == workflow::Scope::User {
            String::new()
        } else {
            project.to_string()
        };
        (
            stored.scope.as_str().to_string(),
            project,
            stored.name.clone(),
        )
    }

    fn persist_workflow(&self, stored: &workflow::Workflow, project: &str) {
        let (scope, project, name) = Self::workflow_db_key(stored, project);
        let json = serde_json::to_string(stored).unwrap_or_else(|_| "{}".to_string());
        self.recorder
            .save_workflow(&scope, &project, &name, json, workflow::updated_ms());
    }

    fn forget_workflow(&self, stored: &workflow::Workflow, project: &str) {
        let (scope, project, name) = Self::workflow_db_key(stored, project);
        self.recorder.delete_workflow(&scope, &project, &name);
    }

    /// `team.start` (19.7): steps 1, 2, 3 and 5; step 4 is the board hook.
    fn team_start_now(
        &mut self,
        conn: u64,
        id: &Value,
        team_id: &str,
        name: &str,
        task: Option<String>,
        project: &str,
    ) {
        let result = (|| -> Result<Value, TeamError> {
            if let Some(task) = &task {
                if task.len() > MAX_BODY_BYTES {
                    return Err(TeamError::invalid("task is longer than 64 KiB"));
                }
            }
            if self.teams.team(team_id).is_none() {
                return Err(TeamError::unknown("unknown team"));
            }
            if self.teams.is_suspended(team_id) {
                return Err(TeamError::not_allowed("team suspended"));
            }
            let workflow = self.teams.resolve_workflow(team_id, project, name)?;
            let (participants, reserved, live, max_workers, config) = {
                let team = self.teams.team(team_id).expect("checked above");
                (
                    team.participants
                        .keys()
                        .cloned()
                        .collect::<HashSet<String>>(),
                    team.reserved_names.clone(),
                    team.live_workers() as u64,
                    team.config.max_workers,
                    team.config.clone(),
                )
            };
            let mut skipped = Vec::new();
            let mut pending: Vec<workflow::WorkflowMember> = Vec::new();
            for member in &workflow.team {
                if participants.contains(&member.name) {
                    skipped.push(member.name.clone());
                } else {
                    pending.push(member.clone());
                }
            }
            if live + pending.len() as u64 > max_workers {
                return Err(TeamError::not_allowed(format!(
                    "the workflow needs {} workers, the team allows {max_workers}",
                    live + pending.len() as u64
                )));
            }
            let mut seen: HashSet<String> = HashSet::new();
            for member in &pending {
                if !crate::team::valid_name(&member.name)
                    || member.name == "leader"
                    || member.name == "human"
                {
                    return Err(TeamError::invalid(format!(
                        "member name {} is not a valid worker name",
                        member.name
                    )));
                }
                if !seen.insert(member.name.clone()) || reserved.contains(&member.name) {
                    return Err(TeamError::invalid(format!(
                        "name {} is already in use",
                        member.name
                    )));
                }
                let Some(template) = config.templates.get(&member.template) else {
                    return Err(TeamError::not_allowed(format!(
                        "unknown template {}",
                        member.template
                    )));
                };
                if let Some(model) = &member.model {
                    if !template.models.is_empty()
                        && !template.models.iter().any(|allowed| allowed == model)
                    {
                        return Err(TeamError::invalid(format!(
                            "model {model} is not allowed by template {}",
                            member.template
                        )));
                    }
                }
            }
            let mut started = Vec::new();
            for member in &pending {
                let spawn = self.teams.request_spawn_human_labeled(
                    team_id,
                    &member.template,
                    Some(&member.name),
                    member.model.as_deref(),
                    member.role.as_deref(),
                    member.task.as_deref(),
                    member.label.as_deref(),
                )?;
                let name = spawn.name.clone();
                if !matches!(
                    self.start_worker(&spawn, StartOptions::default()),
                    StartResult::Replied
                ) {
                    started.push(name);
                }
            }
            self.start_board_hook(team_id, &workflow)?;
            let members: Vec<(workflow::WorkflowMember, String)> = workflow
                .team
                .iter()
                .map(|member| {
                    let agent = config
                        .templates
                        .get(&member.template)
                        .map(|template| template.key.agent.clone())
                        .unwrap_or_default();
                    (member.clone(), agent)
                })
                .collect();
            let body = brief::start_notice(&workflow, &members, task.as_deref());
            // A team.start whose notice cannot be queued is not a success: the
            // leader would never learn the workflow it is supposed to follow.
            self.teams.send_message(
                team_id,
                "human",
                "leader",
                Kind::Notice,
                &body,
                None,
                vec![],
            )?;
            Ok(json!({
                "workflow": workflow.name,
                "started": started,
                "skipped": skipped,
                "team": self.teams.entry(team_id),
            }))
        })();
        match result {
            Ok(value) => {
                self.drain_team_events();
                self.team_deliveries();
                self.send_to(conn, &success(id, value));
            }
            Err(error) => {
                // Members started before the failure must reach the front end
                // and their first prompts at once.
                self.drain_team_events();
                self.team_deliveries();
                self.send_error(conn, id, &error);
            }
        }
    }

    /// Step 4 of `team.start` (19.7): write the workflow onto the board.
    ///
    /// When the board has no `workflow_name`, `workflow_name`, `workflow`
    /// (the text) and — when the board has no columns and the workflow has
    /// them — `columns` are written as one service write, then persisted and
    /// announced like a leader write.
    fn start_board_hook(
        &mut self,
        team: &str,
        workflow: &workflow::Workflow,
    ) -> Result<(), TeamError> {
        // A pending worker write must reach the database before this one.
        self.flush_pending_board(team, true);
        let Some(rev) = self.teams.start_board_workflow(team, workflow)? else {
            return Ok(());
        };
        self.persist_board(team);
        self.announce_board(team, rev);
        Ok(())
    }

    fn team_answer_group(&mut self, params: &Value) -> Result<(Value, bool), TeamError> {
        let group = required_team_string(params, "group")?;
        let allow = optional_bool(params, "allow")?;
        let (answers, failed) = self.teams.answer_group(&group, allow)?;
        let mut answered = Vec::new();
        for (id, effect) in answers {
            // Exactly what team.answer does, including the approval notice
            // (and its dirty-tree warning) for each started worker.
            let spawned = self.apply_answer_effect(&id, effect);
            if !spawned {
                if let Some(item) = self.teams.item_by_id(&id) {
                    if item.kind == ItemKind::Spawn {
                        self.team_spawn_notice(
                            &item.team,
                            &id,
                            false,
                            item.name.as_deref().unwrap_or(""),
                        );
                    }
                }
            }
            answered.push(id);
        }
        let failed: Vec<Value> = failed
            .iter()
            .map(|(id, error)| json!({ "id": id, "code": error.code, "message": error.message }))
            .collect();
        Ok((json!({ "answered": answered, "failed": failed }), true))
    }

    /// Apply one answered inbox item. `team.answer` and `team.answer_group`
    /// share this so both start workers with the approval notice (19.6).
    /// Returns whether the item was a spawn.
    fn apply_answer_effect(&mut self, request: &str, effect: AnswerEffect) -> bool {
        match effect {
            AnswerEffect::Spawn(spawn) => {
                // The approval notice waits for the worktree result so a
                // dirty tree can be named (18.16).
                self.start_worker(
                    &spawn,
                    StartOptions {
                        approved_request: Some(request.to_string()),
                        ..StartOptions::default()
                    },
                );
                true
            }
            AnswerEffect::Permission {
                instance,
                agent_id,
                response,
            } => {
                self.answer_pending(&instance, agent_id, response);
                false
            }
            AnswerEffect::Request {
                instance,
                agent_id,
                result,
            } => {
                self.answer_pending(&instance, agent_id, result);
                false
            }
            AnswerEffect::Question | AnswerEffect::Ack => false,
            AnswerEffect::Handover {
                team,
                instance,
                session,
                hand_over,
            } => {
                // The request was validated before the item was answered
                // (`handover_usable`); this only applies the outcome.
                if hand_over {
                    let _ = self.apply_set_leader(&team, &instance, &session);
                } else {
                    // A refusal changes no published state; the requesting
                    // chat learns it on its next spawn (20.4).
                    self.teams.set_handover_refusal(&instance, &session);
                }
                false
            }
        }
    }

    fn team_spawn_notice(&mut self, team: &str, request: &str, approved: bool, name: &str) {
        let body = if approved {
            format!("spawn request {request} approved: {name}")
        } else {
            format!("spawn request {request} refused")
        };
        let _ = self.teams.send_message(
            team,
            "human",
            "leader",
            Kind::Notice,
            &body,
            None,
            vec![request.to_string()],
        );
    }

    // -- worker driver -----------------------------------------------------

    fn stop_worker_instance(&self, instance: &str) {
        let Some(handle) = self.instances.get(instance) else {
            return;
        };
        let control = handle.control.clone();
        let timeouts = self.timeouts;
        tokio::spawn(async move {
            control.stop(false, timeouts).await;
        });
    }

    fn start_worker(&mut self, spawn: &SpawnRequest, opts: StartOptions) -> StartResult {
        let Some(plan) = self.teams.spawn_plan(&spawn.team, &spawn.name) else {
            self.fail_spawn(spawn, &opts, TeamError::unknown("unknown participant"));
            return StartResult::Replied;
        };
        if plan.template.worktree {
            let Some(root) = plan.worktree_root.clone() else {
                self.fail_spawn(
                    spawn,
                    &opts,
                    TeamError::not_allowed("worktree_root is not configured"),
                );
                return StartResult::Replied;
            };
            let team = spawn.team.clone();
            let participant = spawn.name.clone();
            self.pending_worktrees.insert(
                (team.clone(), participant.clone()),
                PendingWorktree {
                    spawn: spawn.clone(),
                    plan: plan.clone(),
                    opts,
                    cancelled: false,
                },
            );
            let cwd = plan.cwd.clone();
            let stamp = plan.stamp.clone();
            let sender = self.command_sender.clone();
            let closing = self.closing_flag.clone();
            let team_for_git = team.clone();
            let name_for_git = participant.clone();
            let lifecycle = spawn.lifecycle;
            tokio::spawn(async move {
                let result =
                    worktree::create(&cwd, &root, &team_for_git, &stamp, &name_for_git).await;
                if closing.load(std::sync::atomic::Ordering::SeqCst) {
                    if let Ok(info) = &result {
                        worktree::discard(&info.toplevel, &info.path, &info.branch).await;
                    }
                    return;
                }
                let _ = sender
                    .send(Command::TeamWorktree {
                        team,
                        participant,
                        lifecycle,
                        outcome: WorktreeOutcome::Spawn(result),
                    })
                    .await;
            });
            return StartResult::Deferred;
        }
        if self.start_worker_now(spawn, &plan, None, &opts) {
            self.announce_start(spawn, &opts, None);
            StartResult::Started
        } else {
            StartResult::Replied
        }
    }

    /// Spawn the process and send `initialize`. Failures are reported through
    /// `fail_spawn` and return false.
    fn start_worker_now(
        &mut self,
        spawn: &SpawnRequest,
        plan: &SpawnPlan,
        cwd: Option<String>,
        opts: &StartOptions,
    ) -> bool {
        let mut key = plan.template.key.clone();
        key.cwd = cwd.unwrap_or_else(|| plan.cwd.clone());
        key.capabilities = crate::team::worker_capabilities();
        #[cfg(unix)]
        let spawned = self.spawn_worker(
            key.clone(),
            plan.template.env.clone(),
            plan.template.launch.clone(),
        );
        #[cfg(not(unix))]
        let spawned = self.spawn_worker(key.clone(), plan.template.env.clone());
        let instance = match spawned {
            Ok(instance) => instance,
            Err(error) => {
                self.fail_spawn(spawn, opts, TeamError::not_allowed(error));
                return false;
            }
        };
        self.teams
            .worker_instance_set(&spawn.team, &spawn.name, &instance);
        let Some((_token_id, token)) =
            self.teams
                .create_worker_token(&spawn.team, &spawn.name, &instance)
        else {
            self.stop_worker_instance(&instance);
            self.fail_spawn(
                spawn,
                opts,
                TeamError::not_allowed("cannot create worker token"),
            );
            return false;
        };
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
        let params = json!({
            "protocolVersion": 1,
            "clientCapabilities": crate::team::worker_capabilities(),
        });
        let call = ServiceCall::Initialize {
            team: spawn.team.clone(),
            participant: spawn.name.clone(),
            server,
            model: spawn.model.clone().or_else(|| plan.template.model.clone()),
            resume: opts.resume.clone(),
        };
        if !self.send_service_request(&instance, "initialize", params, call) {
            self.teams.revoke_instance_tokens(&instance);
            self.stop_worker_instance(&instance);
            self.fail_spawn(
                spawn,
                opts,
                TeamError::not_allowed("agent is not accepting messages"),
            );
            return false;
        }
        true
    }

    /// Report a failed spawn once: the participant becomes exited with the
    /// documented notices and the waiting request gets the error.
    fn fail_spawn(&mut self, spawn: &SpawnRequest, opts: &StartOptions, error: TeamError) {
        self.teams
            .worker_start_failed(&spawn.team, &spawn.name, &error.message);
        if let Some((conn, id, _)) = &opts.reply {
            self.send_error(*conn, id, &error);
        }
        self.drain_team_events();
    }

    fn spawn_value(
        name: &str,
        kind: SpawnReplyKind,
        info: Option<&worktree::WorktreeInfo>,
    ) -> Value {
        let mut value = match kind {
            SpawnReplyKind::Bus => json!({ "status": "started", "name": name }),
            SpawnReplyKind::Team => json!({ "name": name }),
        };
        if let Some(info) = info {
            if let Some(warning) = &info.warning {
                value["warning"] = json!(warning);
            }
        }
        value
    }

    fn announce_start(
        &mut self,
        spawn: &SpawnRequest,
        opts: &StartOptions,
        info: Option<&worktree::WorktreeInfo>,
    ) {
        let warning = info.and_then(|info| info.warning.as_deref());
        if let Some(request) = &opts.approved_request {
            let mut body = format!("spawn request {request} approved: {}", spawn.name);
            if warning.is_some() {
                body.push_str(" (warning: dirty_tree)");
            }
            let _ = self.teams.send_message(
                &spawn.team,
                "human",
                "leader",
                Kind::Notice,
                &body,
                None,
                vec![request.clone()],
            );
        }
        if opts.human_notice {
            let body = format!(
                "worker {} started from template {}",
                spawn.name, spawn.template
            );
            let _ = self.teams.send_message(
                &spawn.team,
                "human",
                "leader",
                Kind::Notice,
                &body,
                None,
                vec![],
            );
        }
    }

    pub(crate) fn team_worktree(
        &mut self,
        team: &str,
        participant: &str,
        lifecycle: u64,
        outcome: WorktreeOutcome,
    ) {
        match outcome {
            WorktreeOutcome::Spawn(result) => {
                // The job is found by its own lifecycle id, never by name: a
                // cancelled-but-running job keeps its record until this callback
                // returns, and a newer worker of the same name has its own
                // (20.6/E).
                let key = (team.to_string(), participant.to_string());
                let matches = self
                    .pending_worktrees
                    .get(&key)
                    .is_some_and(|pending| pending.spawn.lifecycle == lifecycle);
                if !matches {
                    // Nobody is waiting for this lifecycle any more: clean up
                    // only what this job created.
                    if let Ok(info) = result {
                        let discarded = info.clone();
                        tokio::spawn(async move {
                            worktree::discard(
                                &discarded.toplevel,
                                &discarded.path,
                                &discarded.branch,
                            )
                            .await;
                        });
                    }
                    self.drain_team_events();
                    return;
                }
                let Some(pending) = self.pending_worktrees.remove(&key) else {
                    return;
                };
                let stale = self
                    .teams
                    .team(team)
                    .and_then(|entry| entry.participants.get(participant))
                    .is_none_or(|worker| {
                        worker.lifecycle != pending.spawn.lifecycle
                            || worker.state == crate::team::ParticipantState::Exited
                    });
                if pending.cancelled || stale {
                    let team_gone = self.teams.team(team).is_none();
                    // A removal waiting for this lifecycle completes only once
                    // the directory is really gone; without a git result there is
                    // nothing to discard and the hand is over now (20.6).
                    // Only the request that is still waiting gets the reply; a
                    // stop already answered it and took the reply away.
                    let reply = pending.opts.reply.clone();
                    let mut hold = false;
                    if let Ok(info) = result {
                        // The name stays taken until the directory and branch
                        // are really gone, so a same-name retry cannot collide
                        // with the cleanup (20.6/E).
                        hold = true;
                        let discarded = info.clone();
                        let sender = self.command_sender.clone();
                        let team_owner = team.to_string();
                        let name_owner = participant.to_string();
                        let closed_flag = self.closing_flag.clone();
                        tokio::spawn(async move {
                            worktree::discard(
                                &discarded.toplevel,
                                &discarded.path,
                                &discarded.branch,
                            )
                            .await;
                            if !closed_flag.load(std::sync::atomic::Ordering::SeqCst) {
                                let _ = sender
                                    .send(Command::WorktreeDiscarded {
                                        team: team_owner,
                                        participant: name_owner,
                                        lifecycle,
                                    })
                                    .await;
                            }
                        });
                    }
                    if hold {
                        // Keep the record until the discard reports back; the
                        // participant and its name stay until then too.
                        self.pending_worktrees.insert(key.clone(), pending);
                    } else {
                        // No directory was created: the removal completes now.
                        self.finish_stopped_start(team, participant, lifecycle);
                    }
                    if let Some((conn, id, _)) = reply {
                        let error = if team_gone {
                            TeamError::unknown("team closed")
                        } else {
                            TeamError::not_allowed("the worker was stopped")
                        };
                        self.send_error(conn, &id, &error);
                    }
                    self.drain_team_events();
                    return;
                }
                match result {
                    Ok(info) => {
                        self.teams
                            .worktree_prepared(team, participant, info.clone());
                        if self.teams.team(team).is_none() {
                            // The team closed while git ran: the new worktree
                            // belongs to nobody.
                            crate::svc_log!(
                                "nvim_ade_server: discarding worktree {} of closed team {team}",
                                info.path
                            );
                            let discarded = info.clone();
                            tokio::spawn(async move {
                                worktree::discard(
                                    &discarded.toplevel,
                                    &discarded.path,
                                    &discarded.branch,
                                )
                                .await;
                            });
                            if let Some((conn, id, _)) = &pending.opts.reply {
                                self.send_error(*conn, id, &TeamError::unknown("team closed"));
                            }
                            return;
                        }
                        if let Some(relative) = &info.missing_subdir {
                            let body =
                                worktree::missing_subdir_notice(participant, relative, &info.path);
                            let _ = self.teams.send_message(
                                team,
                                "human",
                                "leader",
                                Kind::Notice,
                                &body,
                                None,
                                vec![],
                            );
                        }
                        let cwd = info.cwd.clone();
                        if self.start_worker_now(
                            &pending.spawn,
                            &pending.plan,
                            Some(cwd),
                            &pending.opts,
                        ) {
                            self.announce_start(&pending.spawn, &pending.opts, Some(&info));
                            if let Some((conn, id, kind)) = &pending.opts.reply {
                                let mut value =
                                    Self::spawn_value(&pending.spawn.name, *kind, Some(&info));
                                if let Some(entry) = self.teams.entry(&pending.spawn.team) {
                                    value["team"] = entry;
                                }
                                self.send_to(*conn, &success(id, value));
                            }
                        }
                    }
                    Err(error) => {
                        let lifecycle = pending.spawn.lifecycle;
                        self.finish_stopped_start(team, participant, lifecycle);
                        self.fail_spawn(&pending.spawn, &pending.opts, error)
                    }
                }
            }
            WorktreeOutcome::Remove(result) => {
                let Some((conn, id)) = self
                    .pending_removals
                    .remove(&(team.to_string(), participant.to_string()))
                else {
                    return;
                };
                match result {
                    Ok(report) => {
                        if report.removed {
                            // The directory is gone; do not leave a record that
                            // makes every retry fail (18.16).
                            self.teams.worktree_removed(team, participant);
                            self.drain_team_events();
                        }
                        match report.error {
                            Some(error) => self.send_error(conn, &id, &error),
                            None => self.send_to(
                                conn,
                                &success(
                                    &id,
                                    json!({
                                        "removed": report.removed,
                                        "branch_kept": report.branch_kept,
                                        "branch": report.branch,
                                    }),
                                ),
                            ),
                        }
                    }
                    Err(error) => self.send_error(conn, &id, &error),
                }
            }
        }
    }

    fn send_error(&self, conn: u64, id: &Value, error: &TeamError) {
        let mut body = json!({ "code": error.code, "message": error.message });
        if let Some(data) = &error.data {
            body["data"] = data.clone();
        }
        self.send_to(conn, &json!({ "jsonrpc": "2.0", "id": id, "error": body }));
    }

    fn send_service_request(
        &mut self,
        instance: &str,
        method: &str,
        params: Value,
        call: ServiceCall,
    ) -> bool {
        self.send_service_request_id(instance, method, params, call)
            .is_some()
    }

    fn send_service_request_id(
        &mut self,
        instance: &str,
        method: &str,
        params: Value,
        call: ServiceCall,
    ) -> Option<u64> {
        let handle = self.instances.get_mut(instance)?;
        let (agent_id, frame) = handle.relay.service_request(method, params);
        if !handle.control.send_frame(frame) {
            return None;
        }
        self.driver.insert((instance.to_string(), agent_id), call);
        Some(agent_id)
    }

    pub(crate) fn handle_service_response(
        &mut self,
        instance: &str,
        agent_id: u64,
        _seq: u64,
        message: &Value,
    ) {
        let Some(call) = self.driver.remove(&(instance.to_string(), agent_id)) else {
            return;
        };
        match call {
            ServiceCall::Initialize {
                team,
                participant,
                server,
                model,
                resume,
            } => {
                if let Some(error) = message.get("error") {
                    let reason = error_message(error);
                    self.teams.revoke_instance_tokens(instance);
                    self.stop_worker_instance(instance);
                    self.teams.worker_start_failed(&team, &participant, &reason);
                    self.drain_team_events();
                    return;
                }
                // A worktree worker starts in its instance's cwd, not in the
                // team's tree (18.12).
                let Some(cwd) = self
                    .instances
                    .get(instance)
                    .map(|handle| handle.key.cwd.clone())
                else {
                    return;
                };
                let supports_load = message
                    .get("result")
                    .and_then(|result| result.get("agentCapabilities"))
                    .and_then(|capabilities| capabilities.get("loadSession"))
                    .and_then(Value::as_bool)
                    == Some(true);
                if let Some(session) = resume {
                    if supports_load {
                        let params = json!({
                            "sessionId": session,
                            "cwd": cwd,
                            "mcpServers": [server],
                        });
                        let call = ServiceCall::SessionLoad {
                            team: team.clone(),
                            participant: participant.clone(),
                            model,
                            session,
                            server: server.clone(),
                        };
                        if !self.send_service_request(instance, "session/load", params, call) {
                            self.teams.worker_start_failed(
                                &team,
                                &participant,
                                "agent is not accepting messages",
                            );
                        }
                        self.drain_team_events();
                        return;
                    }
                    // The agent cannot load: start a new session, re-send the
                    // role card, and say so.
                    self.teams.worker_without_history(&team, &participant);
                    let _ = self.teams.send_message(
                        &team,
                        "human",
                        "leader",
                        Kind::Notice,
                        &format!("worker {participant} restarted without its history"),
                        None,
                        vec![],
                    );
                }
                let params = json!({ "cwd": cwd, "mcpServers": [server] });
                if !self.send_service_request(
                    instance,
                    "session/new",
                    params,
                    ServiceCall::SessionNew {
                        team: team.clone(),
                        participant: participant.clone(),
                        model,
                    },
                ) {
                    self.teams.worker_start_failed(
                        &team,
                        &participant,
                        "agent is not accepting messages",
                    );
                }
                self.drain_team_events();
            }
            ServiceCall::SessionLoad {
                team,
                participant,
                model,
                session,
                server,
            } => {
                if let Some(error) = message.get("error") {
                    let reason = error_message(error);
                    self.teams.worker_without_history(&team, &participant);
                    let _ = self.teams.send_message(
                        &team,
                        "human",
                        "leader",
                        Kind::Notice,
                        &format!("worker {participant} restarted without its history: {reason}"),
                        None,
                        vec![],
                    );
                    let Some(cwd) = self
                        .instances
                        .get(instance)
                        .map(|handle| handle.key.cwd.clone())
                    else {
                        return;
                    };
                    let params = json!({ "cwd": cwd, "mcpServers": [server] });
                    if !self.send_service_request(
                        instance,
                        "session/new",
                        params,
                        ServiceCall::SessionNew {
                            team: team.clone(),
                            participant: participant.clone(),
                            model,
                        },
                    ) {
                        self.teams.worker_start_failed(
                            &team,
                            &participant,
                            "agent is not accepting messages",
                        );
                    }
                    self.drain_team_events();
                    return;
                }
                self.teams.worker_session_set(&team, &participant, &session);
                self.teams.worker_started(&team, &participant);
                self.drain_team_events();
                self.team_deliveries();
            }
            ServiceCall::SessionNew {
                team,
                participant,
                model,
            } => {
                if let Some(error) = message.get("error") {
                    let reason = error_message(error);
                    self.teams.revoke_instance_tokens(instance);
                    self.stop_worker_instance(instance);
                    self.teams.worker_start_failed(&team, &participant, &reason);
                    self.drain_team_events();
                    return;
                }
                let Some(session) = message
                    .get("result")
                    .and_then(|result| result.get("sessionId"))
                    .and_then(Value::as_str)
                    .map(str::to_string)
                else {
                    self.teams.revoke_instance_tokens(instance);
                    self.stop_worker_instance(instance);
                    self.teams.worker_start_failed(
                        &team,
                        &participant,
                        "session/new returned no sessionId",
                    );
                    self.drain_team_events();
                    return;
                };
                let config_options = message
                    .get("result")
                    .and_then(|result| result.get("configOptions"))
                    .cloned()
                    .unwrap_or(Value::Null);
                if let Some(model) = &model {
                    let offered = model_values(&config_options);
                    if !offered.iter().any(|value| value == model) {
                        // 19.6: never go on silently with a model the agent does
                        // not offer; stop the worker and tell the leader.
                        self.teams.revoke_instance_tokens(instance);
                        self.stop_worker_instance(instance);
                        let reason = format!("model unavailable: {model}");
                        self.teams.worker_start_failed(&team, &participant, &reason);
                        let listed: Vec<String> = offered.into_iter().take(50).collect();
                        let body = if listed.is_empty() {
                            format!(
                                "worker {participant} cannot use model {model}: \
                                 the agent offers no model values"
                            )
                        } else {
                            format!(
                                "worker {participant} cannot use model {model}: \
                                 the agent offers {}",
                                listed.join(", ")
                            )
                        };
                        let _ = self.teams.send_message(
                            &team,
                            "human",
                            "leader",
                            Kind::Notice,
                            &body,
                            None,
                            vec![],
                        );
                        self.drain_team_events();
                        return;
                    }
                }
                self.teams.worker_session_set(&team, &participant, &session);
                if let Some(model) = model {
                    let params = json!({
                        "sessionId": session,
                        "configId": "model",
                        "value": model,
                    });
                    if !self.send_service_request(
                        instance,
                        "session/set_config_option",
                        params,
                        ServiceCall::SetModel {
                            team: team.clone(),
                            participant: participant.clone(),
                        },
                    ) {
                        self.teams.worker_started(&team, &participant);
                        self.team_deliveries();
                    }
                } else {
                    self.teams.worker_started(&team, &participant);
                    self.team_deliveries();
                }
                self.drain_team_events();
            }
            ServiceCall::SetModel { team, participant } => {
                self.teams.worker_started(&team, &participant);
                self.team_deliveries();
                self.drain_team_events();
            }
            ServiceCall::Prompt {
                team,
                participant,
                session,
                seq,
            } => {
                if !self.teams.prompt_is_current(&team, &participant, seq) {
                    // A forced interrupt deadline already ended this prompt,
                    // or the team closed while it was running: its late
                    // completion must not end the next turn. Prompts held
                    // behind it must not wait forever, unless a newer bus
                    // turn for this session is already running.
                    if !self.bus_prompt_active(instance, &session) {
                        self.release_held_prompts(instance, &session, false);
                    }
                    return;
                }
                let (success, error) = turn_outcome(message);
                let cancelled = message
                    .get("result")
                    .and_then(|result| result.get("stopReason"))
                    .and_then(Value::as_str)
                    == Some("cancelled");
                let success = success && !cancelled;
                // A cancelled turn is a bad end with the documented
                // "turn ended: cancelled" text; the error field is only for
                // JSON-RPC errors / stopReason "error".
                let error = if cancelled { None } else { error };
                self.teams
                    .turn_finished(instance, success, error, String::new());
                self.teams.clear_prompt_seq(&team, &participant);
                self.drain_team_events();
                self.release_held_prompts(instance, &session, false);
                self.team_deliveries();
            }
        }
    }

    pub(crate) fn team_deliveries(&mut self) {
        let alive = |teams: &crate::team::Teams, team: &String, participant: &String| {
            teams.team(team).is_some_and(|entry| {
                entry
                    .participants
                    .get(participant)
                    .is_some_and(|p| p.state != crate::team::ParticipantState::Exited)
            })
        };
        self.interrupt_queue
            .retain(|(team, participant), _| alive(&self.teams, team, participant));
        self.interrupt_generation
            .retain(|(team, participant), _| alive(&self.teams, team, participant));
        let mut busy: HashSet<String> = self
            .instances
            .iter()
            .filter(|(_, instance)| instance.relay.turns_running() > 0)
            .map(|(id, _)| id.clone())
            .collect();
        for (instance, _) in self.held_prompts.keys() {
            busy.insert(instance.clone());
        }
        let requests = self.teams.take_deliveries(&busy);
        if !requests.is_empty() {
            // Only the teams that lost queue entries / marked a bus turn are
            // snapshotted; serialising every team on every delivery would be
            // quadratic in the team count.
            let teams: HashSet<String> = requests
                .iter()
                .map(|request| request.team.clone())
                .collect();
            for team in teams {
                self.persist_team(&team);
            }
        }
        for request in requests {
            let crate::team::DeliveryRequest {
                team,
                participant,
                instance,
                session,
                blocks,
                messages,
                first_prompt,
            } = request;
            let params = json!({
                "sessionId": session,
                "prompt": blocks,
            });
            let Some((agent_id, frame, seq, event)) = self
                .instances
                .get_mut(&instance)
                .map(|handle| handle.relay.service_prompt(&session, params))
            else {
                self.teams
                    .delivery_failed(&team, &participant, messages, first_prompt);
                continue;
            };
            let Some(handle) = self.instances.get_mut(&instance) else {
                self.teams
                    .delivery_failed(&team, &participant, messages, first_prompt);
                continue;
            };
            if !handle.control.send_frame(frame) {
                // Put the messages back and leave the participant idle; no
                // synthetic user_prompt is recorded for a send that failed.
                self.teams
                    .delivery_failed(&team, &participant, messages, first_prompt);
                continue;
            }
            if let Some(event) = event {
                self.record_events(&instance, vec![event]);
            }
            self.driver.insert(
                (instance.clone(), agent_id),
                ServiceCall::Prompt {
                    team: team.clone(),
                    participant: participant.clone(),
                    session: session.clone(),
                    seq,
                },
            );
            self.teams.prompt_started(&team, &participant, seq);
            let started = json!({
                "jsonrpc": "2.0",
                "method": "_ade/turn_started",
                "params": {
                    "sessionId": session,
                    "origin": "bus",
                    "prompt": blocks,
                },
            });
            for conn in self.delivery_conns(&instance) {
                self.send_tunnel_recv(conn, &instance, seq, &started);
            }
        }
        self.drain_team_events();
    }

    /// Front-end prompts on the leader wait for a cancelled bus prompt.
    pub(crate) fn hold_leader_prompt(
        &mut self,
        conn: u64,
        instance: &str,
        session: &str,
        message: &Value,
    ) -> bool {
        // Only a leader of a live team waits behind a bus prompt. After
        // `team.close` the conversation continues as a plain session (there
        // is no bus turn left whose completion could release the prompt),
        // and the held prompts were already dropped by close.
        if !self
            .teams
            .team_of_instance(instance)
            .is_some_and(|team| team.is_leader_instance(instance))
        {
            return false;
        }
        if !self.bus_prompt_active(instance, session) {
            return false;
        }
        let key = (instance.to_string(), session.to_string());
        if self.held_timed_out.contains(&key) {
            // The 30 s grace period already expired for this running bus
            // prompt: forward now instead of a second cancel+hold cycle.
            return false;
        }
        self.held_prompts
            .entry(key.clone())
            .or_default()
            .push_back((conn, message.clone()));
        let first = self
            .held_prompts
            .get(&key)
            .is_some_and(|queue| queue.len() == 1);
        if first {
            self.next_held_generation += 1;
            let generation = self.next_held_generation;
            self.held_generation.insert(key.clone(), generation);
            let cancel = json!({
                "jsonrpc": "2.0",
                "method": "session/cancel",
                "params": { "sessionId": session },
            });
            if let Some(handle) = self.instances.get(instance) {
                handle.control.send_frame(cancel);
            }
            let sender = self.command_sender.clone();
            let instance = instance.to_string();
            let session = session.to_string();
            let timeout = std::env::var("NVIM_ADE_SERVER_HELD_TIMEOUT_MS")
                .ok()
                .and_then(|value| value.trim().parse::<u64>().ok())
                .unwrap_or(30_000);
            tokio::spawn(async move {
                tokio::time::sleep(Duration::from_millis(timeout)).await;
                let _ = sender
                    .send(Command::TeamDeadline {
                        instance,
                        session,
                        generation,
                    })
                    .await;
            });
        }
        true
    }

    pub(crate) fn team_deadline(&mut self, instance: &str, session: &str, generation: u64) {
        let key = (instance.to_string(), session.to_string());
        if self.held_generation.get(&key) != Some(&generation) {
            return;
        }
        if !self.bus_prompt_active(instance, session) {
            return;
        }
        self.held_timed_out.insert(key);
        self.release_held_prompts(instance, session, true);
    }

    pub(crate) fn worker_interrupt_deadline(
        &mut self,
        team: &str,
        participant: &str,
        generation: u64,
    ) {
        let key = (team.to_string(), participant.to_string());
        let Some((saved_generation, prompt_seq)) = self.interrupt_generation.get(&key).copied()
        else {
            return;
        };
        if saved_generation != generation {
            return;
        }
        if self.teams.prompt_seq(team, participant) != prompt_seq {
            // The interrupted turn already ended and a new one started.
            return;
        }
        if !self.teams.bus_turn_running(team, participant) {
            return;
        }
        let Some(instance) = self.teams.participant_instance(team, participant) else {
            return;
        };
        // The agent ignored session/cancel. End the bus turn as 18.11 does, so
        // the queued interrupt (front of the mailbox) can be delivered.
        self.teams
            .turn_finished(&instance, false, None, String::new());
        self.teams.clear_prompt_seq(team, participant);
        self.drain_team_events();
        self.team_deliveries();
    }

    fn release_held_prompts(&mut self, instance: &str, session: &str, timed_out: bool) {
        let key = (instance.to_string(), session.to_string());
        self.held_generation.remove(&key);
        if !timed_out {
            // The bus prompt answered normally: a later bus turn may cancel
            // and hold again with a fresh generation.
            self.held_timed_out.remove(&key);
        }
        let Some(queue) = self.held_prompts.remove(&key) else {
            return;
        };
        for (conn, message) in queue {
            if !self.conns.contains_key(&conn) {
                continue;
            }
            let params = json!({ "instance": instance, "message": message });
            self.tunnel_send_inner(conn, &params, false);
        }
    }

    fn send_held_error(&mut self, conn: u64, instance: &str, message: &Value) {
        let seq = self
            .instances
            .get_mut(instance)
            .map(|handle| handle.relay.allocate_seq())
            .unwrap_or(0);
        let id = message.get("id").cloned().unwrap_or(Value::Null);
        self.send_tunnel_recv(
            conn,
            instance,
            seq,
            &json!({
                "jsonrpc": "2.0",
                "id": id,
                "error": { "code": -32800, "message": "request cancelled" },
            }),
        );
    }

    pub(crate) fn cancel_held_target(&mut self, conn: u64, instance: &str, target: &Value) -> bool {
        let mut removed = Vec::new();
        for (key, queue) in self.held_prompts.iter_mut() {
            if key.0 != instance {
                continue;
            }
            if let Some(position) = queue
                .iter()
                .position(|(owner, message)| *owner == conn && message.get("id") == Some(target))
            {
                removed.push(queue.remove(position).expect("position"));
            }
        }
        let empty: Vec<(String, String)> = self
            .held_prompts
            .iter()
            .filter(|(_, queue)| queue.is_empty())
            .map(|(key, _)| key.clone())
            .collect();
        for key in empty {
            self.held_prompts.remove(&key);
            self.held_generation.remove(&key);
        }
        let found = !removed.is_empty();
        for (owner, message) in removed {
            self.send_held_error(owner, instance, &message);
        }
        found
    }

    pub(crate) fn cancel_held_session(&mut self, instance: &str, session: &str) {
        let key = (instance.to_string(), session.to_string());
        let Some(queue) = self.held_prompts.remove(&key) else {
            return;
        };
        self.held_generation.remove(&key);
        for (conn, message) in queue {
            if self.conns.contains_key(&conn) {
                self.send_held_error(conn, instance, &message);
            }
        }
    }

    /// Every session an instance can affect: its bound tokens, its relay's
    /// tracked sessions and the team participants it runs (20.5/A).
    pub(crate) fn instance_sessions(&self, instance: &str) -> Vec<(String, String)> {
        let mut sessions: Vec<(String, String)> = self
            .conn_tokens
            .values()
            .filter_map(|token| {
                let (owner, session) = self.teams.session_identity(token)?;
                (owner == instance).then_some((owner, session))
            })
            .collect();
        if let Some(handle) = self.instances.get(instance) {
            for summary in handle.relay.session_summaries() {
                sessions.push((instance.to_string(), summary.session_id));
            }
        }
        for session in self.teams.sessions_of_instance(instance) {
            sessions.push((instance.to_string(), session));
        }
        for (owner, session) in self.teams.participant_sessions() {
            if owner == instance {
                sessions.push((owner, session));
            }
        }
        sessions.sort();
        sessions.dedup();
        sessions
    }

    /// Drop the forwarded session requests and one-shot loads of a dying
    /// instance; session state is published by the caller after its tokens are
    /// revoked (20.2/20.5).
    pub(crate) fn cleanup_instance_pending(&mut self, instance: &str) {
        let keys: Vec<(String, u64)> = self
            .pending_session
            .keys()
            .filter(|(owner, _)| owner == instance)
            .cloned()
            .collect();
        for key in keys {
            // The instance is gone: revoke and delete, without publishing per
            // request (the caller publishes one exit diff) and without keeping a
            // log-only record (20.2/20.5).
            if let Some(pending) = self.pending_session.remove(&key) {
                self.drop_pending_session_value(pending);
            }
        }
        self.forward_loads.retain(|(owner, _)| owner != instance);
    }

    pub(crate) fn fail_held_prompts(&mut self, instance: &str) {
        let keys: Vec<(String, String)> = self
            .held_prompts
            .keys()
            .filter(|key| key.0 == instance)
            .cloned()
            .collect();
        for key in keys {
            self.held_generation.remove(&key);
            self.held_timed_out.remove(&key);
            let Some(queue) = self.held_prompts.remove(&key) else {
                continue;
            };
            for (conn, message) in queue {
                if self.conns.contains_key(&conn) {
                    self.send_held_error(conn, instance, &message);
                }
            }
        }
    }

    fn bus_prompt_active(&self, instance: &str, session: &str) -> bool {
        self.driver.iter().any(|((owner, _), call)| {
            owner == instance
                && matches!(call, ServiceCall::Prompt { session: current, .. } if current == session)
        })
    }

    fn cancel_participant_turn(&mut self, team: &str, name: &str) {
        let Some(instance) = self.teams.participant_instance(team, name) else {
            return;
        };
        let Some(handle) = self.instances.get(&instance) else {
            return;
        };
        let Some(session) = self.teams.participant_session(team, name).or_else(|| {
            handle
                .relay
                .session_summaries()
                .into_iter()
                .next()
                .map(|summary| summary.session_id)
        }) else {
            return;
        };
        let frame = json!({
            "jsonrpc": "2.0",
            "method": "session/cancel",
            "params": { "sessionId": session },
        });
        handle.control.send_frame(frame);
    }

    // -- agent events ------------------------------------------------------

    /// A worker's agent sent a request: register it in the shared pending set
    /// and deliver it to every watcher.
    pub(crate) fn note_worker_request(&mut self, instance: &str, message: &Value) {
        let Some(team) = self.teams.team_of_instance(instance) else {
            return;
        };
        let Some(name) = team.is_worker_instance(instance).map(str::to_string) else {
            return;
        };
        let team_id = team.id.clone();
        let permission =
            message.get("method").and_then(Value::as_str) == Some("session/request_permission");
        let session = message
            .get("params")
            .and_then(|params| params.get("sessionId"))
            .and_then(Value::as_str);
        self.teams
            .add_pending_item(&team_id, &name, instance, session, message, permission);
        let seq = self.instances.get(instance).and_then(|handle| {
            message.get("id").and_then(|id| {
                handle
                    .relay
                    .pending_messages()
                    .into_iter()
                    .find(|(_, pending)| pending.get("id") == Some(id))
                    .map(|(seq, _)| seq)
            })
        });
        if let Some(seq) = seq {
            for conn in self.teams.watcher_conns(instance) {
                self.send_tunnel_recv(conn, instance, seq, message);
                if let Some(handle) = self.instances.get_mut(instance) {
                    if let Some(id) = message.get("id").cloned() {
                        handle.relay.mark_delivered(&id, conn);
                    }
                }
            }
        }
        self.drain_team_events();
    }

    pub(crate) fn note_worker_chunk(&mut self, instance: &str, message: &Value) {
        let Some(params) = message.get("params") else {
            return;
        };
        let Some(update) = params.get("update") else {
            return;
        };
        let session = params.get("sessionId").and_then(Value::as_str);
        if self
            .teams
            .observe_activity_update(instance, session, update, crate::team::now_ms())
        {
            self.drain_team_events();
        }
        if update.get("sessionUpdate").and_then(Value::as_str) != Some("agent_message_chunk") {
            return;
        }
        let Some(text) = update
            .get("content")
            .and_then(|content| content.get("text"))
            .and_then(Value::as_str)
        else {
            return;
        };
        self.teams.observe_chunk(instance, session, text);
    }

    pub(crate) fn flush_due_activities(&mut self) {
        self.teams.flush_due_activities(crate::team::now_ms());
        self.drain_team_events();
    }

    pub(crate) fn instance_left_team(&mut self, instance: &str, reason: &str) {
        let before = self.teams.membership(instance);
        self.driver.retain(|(owner, _), _| owner != instance);
        self.held_prompts.retain(|(owner, _), _| owner != instance);
        if let Some((_team, name)) = before {
            if name == "leader" {
                self.teams.leader_exited(instance, reason);
            } else {
                self.teams.worker_exited(instance, reason);
            }
        }
        self.drain_team_events();
        self.team_deliveries();
    }

    pub(crate) fn leader_session_closed(&mut self, instance: &str, session: &str) {
        let agent = self
            .instances
            .get(instance)
            .map(|handle| handle.key.agent.clone());
        let identity = (instance.to_string(), session.to_string());
        let before = self.session_states(std::slice::from_ref(&identity));
        self.teams.leader_session_closed(instance, session);
        self.teams.revoke_session_tokens(instance, session);
        // The session's open turn is over; its spawn group dies with it (19.6).
        self.teams.forget_session_group(instance, session);
        // A closed session consumes its unused one-shot mark (20.5).
        self.forward_loads.remove(&identity);
        // A held enable answers now: its token is gone (20.5).
        self.release_pending_enable(instance, session);
        if let Some(agent) = agent {
            self.recorder.delete_session_switch(&agent, session);
        }
        self.publish_session_changes(before);
        self.notify_tools_changed(&identity);
        self.drain_team_events();
    }

    pub(crate) fn worker_error_response(&self, instance: &str, id: &Value) {
        if let Some(handle) = self.instances.get(instance) {
            handle.control.send_frame(json!({
                "jsonrpc": "2.0",
                "id": id,
                "error": { "code": METHOD_NOT_FOUND, "message": "method not found" },
            }));
        }
    }

    // -- helpers -----------------------------------------------------------

    pub(crate) fn delivery_conns(&self, instance: &str) -> Vec<u64> {
        let Some(handle) = self.instances.get(instance) else {
            return Vec::new();
        };
        // `attached` is in attach order; its last element is the primary
        // (PROTOCOL.md 5.3). Watchers follow it and do not change that order.
        let mut conns = handle.attached.clone();
        if self.teams.membership(instance).is_some() {
            for watcher in self.teams.watcher_conns(instance) {
                if !conns.contains(&watcher) {
                    conns.push(watcher);
                }
            }
        }
        conns
    }

    pub(crate) fn is_watcher(&self, conn: u64, instance: &str) -> bool {
        self.teams.watches(conn, instance)
    }

    fn answer_pending(&mut self, instance: &str, agent_id: Value, result: Value) {
        let retractions = self
            .instances
            .get_mut(instance)
            .map(|handle| handle.relay.answer_pending(&agent_id))
            .unwrap_or_default();
        for retraction in retractions {
            self.send_cancel_request(instance, &retraction);
        }
        if let Some(handle) = self.instances.get(instance) {
            handle.control.send_frame(json!({
                "jsonrpc": "2.0",
                "id": agent_id,
                "result": result,
            }));
        }
    }

    pub(crate) fn send_tunnel_recv_direct(
        &self,
        conn: u64,
        instance: &str,
        seq: u64,
        message: &Value,
    ) {
        self.send_to(
            conn,
            &json!({
                "jsonrpc": "2.0",
                "method": "tunnel.recv",
                "params": { "instance": instance, "seq": seq, "message": message },
            }),
        );
    }

    pub(crate) fn send_to_frontends(&self, value: &Value) {
        let conns: Vec<u64> = self
            .frontend_conns
            .iter()
            .copied()
            .filter(|conn| self.conns.contains_key(conn))
            .collect();
        for conn in conns {
            self.send_to(conn, value);
        }
    }

    fn persist_team(&self, id: &str) {
        if self.persist_paused {
            return;
        }
        let Some(snapshot) = self.teams.snapshot_team(id) else {
            return;
        };
        let (max_team, max_inbox) = self.teams.counters();
        self.recorder.save_team(id, snapshot, max_team, max_inbox);
    }

    pub(crate) fn persist_all_teams(&self) {
        if self.persist_paused {
            return;
        }
        for id in self.teams.team_ids() {
            self.persist_team(&id);
        }
    }

    pub(crate) fn expire_teams(&mut self) {
        // A pending worker write is persisted here even when its 10 s timer has
        // not fired yet. It must be announced too: clearing the timer without
        // `team.board_changed` would hide that rev from the front end.
        self.flush_all_boards(true);
        let ttl = team_ttl_ms();
        let expired = self.teams.expire_suspended(crate::team::now_ms(), ttl);
        for id in expired {
            self.recorder.delete_team(&id);
        }
        self.drain_team_events();
        self.update_busy();
    }

    pub(crate) fn drain_team_events(&mut self) {
        let events = self.teams.drain_events();
        let mut saves: HashSet<String> = HashSet::new();
        let mut deletes: HashSet<String> = HashSet::new();
        for event in &events {
            match event {
                TeamEvent::Changed(id) | TeamEvent::Inbox(id, _) | TeamEvent::Board(id, _) => {
                    saves.insert(id.clone());
                }
                TeamEvent::InboxJson(item) => {
                    if let Some(id) = item["team"].as_str() {
                        saves.insert(id.to_string());
                    }
                }
                TeamEvent::Closed(entry) => {
                    if let Some(id) = entry["id"].as_str() {
                        deletes.insert(id.to_string());
                    }
                }
            }
        }
        if !self.persist_paused {
            for id in saves {
                self.persist_team(&id);
            }
            for id in deletes {
                self.recorder.delete_team(&id);
            }
        }
        for event in events {
            match event {
                TeamEvent::Changed(id) => {
                    if let Some(entry) = self.teams.entry(&id) {
                        self.send_to_frontends(&json!({
                            "jsonrpc": "2.0",
                            "method": "team.changed",
                            "params": { "team": entry },
                        }));
                    }
                }
                TeamEvent::Board(team, rev) => {
                    if self.persist_paused {
                        self.announce_board(&team, rev);
                    } else if let Some(persisted) = self.persist_board(&team) {
                        self.announce_board(&team, persisted);
                    } else {
                        self.announce_board(&team, rev);
                    }
                }
                TeamEvent::Inbox(team, item) => {
                    if let Some(item) = self.teams.item(&team, &item) {
                        self.send_to_frontends(&json!({
                            "jsonrpc": "2.0",
                            "method": "team.inbox",
                            "params": { "item": item.to_json() },
                        }));
                    }
                }
                TeamEvent::InboxJson(item) => {
                    self.send_to_frontends(&json!({
                        "jsonrpc": "2.0",
                        "method": "team.inbox",
                        "params": { "item": item },
                    }));
                }
                TeamEvent::Closed(entry) => {
                    self.send_to_frontends(&json!({
                        "jsonrpc": "2.0",
                        "method": "team.changed",
                        "params": { "team": entry },
                    }));
                }
            }
        }
    }
}

/// Put an `ade-team` server entry into a `session/*` params object's
/// `mcpServers`, replacing one of the same name (20.2).
pub(crate) fn inject_team_server(params: &mut Value, token: &str) {
    if let Some(servers) = params.get_mut("mcpServers") {
        inject_team_server_value(servers, token);
    } else if let Some(object) = params.as_object_mut() {
        object.insert("mcpServers".to_string(), json!([]));
        if let Some(servers) = object.get_mut("mcpServers") {
            inject_team_server_value(servers, token);
        }
    }
}

fn inject_team_server_value(servers: &mut Value, token: &str) {
    if !servers.is_array() {
        *servers = json!([]);
    }
    let entry = json!({
        "name": "ade-team",
        "command": std::env::current_exe()
            .ok()
            .and_then(|path| path.to_str().map(str::to_string))
            .unwrap_or_else(|| "nvim_ade_server".to_string()),
        "args": ["mcp"],
        "env": [{ "name": "ADE_TEAM_TOKEN", "value": token }],
    });
    let Some(items) = servers.as_array_mut() else {
        return;
    };
    items.retain(|item| item.get("name").and_then(Value::as_str) != Some("ade-team"));
    items.push(entry);
}

fn required_team_string(params: &Value, field: &str) -> Result<String, TeamError> {
    params
        .get(field)
        .and_then(Value::as_str)
        .map(str::to_string)
        .ok_or_else(|| TeamError::new(INVALID_TEAM_PARAM, format!("{field} must be a string")))
}

fn optional_string(params: &Value, field: &str) -> Result<Option<String>, TeamError> {
    match params.get(field) {
        None | Some(Value::Null) => Ok(None),
        Some(value) => value
            .as_str()
            .map(|value| Some(value.to_string()))
            .ok_or_else(|| TeamError::invalid(format!("{field} must be a string"))),
    }
}

fn optional_u64(params: &Value, field: &str) -> Result<Option<u64>, TeamError> {
    match params.get(field) {
        None | Some(Value::Null) => Ok(None),
        Some(value) => value
            .as_u64()
            .map(Some)
            .ok_or_else(|| TeamError::invalid(format!("{field} must be a non-negative integer"))),
    }
}

fn optional_bool(params: &Value, field: &str) -> Result<Option<bool>, TeamError> {
    match params.get(field) {
        None | Some(Value::Null) => Ok(None),
        Some(value) => value
            .as_bool()
            .map(Some)
            .ok_or_else(|| TeamError::invalid(format!("{field} must be a boolean"))),
    }
}

fn team_refs(params: &Value) -> Result<Vec<String>, TeamError> {
    match params.get("refs") {
        None | Some(Value::Null) => Ok(Vec::new()),
        Some(Value::Array(items)) => {
            if items.len() > crate::team::MAX_REFS {
                return Err(TeamError::invalid("refs has more than 16 entries"));
            }
            let mut refs = Vec::new();
            for item in items {
                let Some(value) = item.as_str() else {
                    return Err(TeamError::invalid("refs must be strings"));
                };
                if value.len() > crate::team::MAX_REF_BYTES {
                    return Err(TeamError::invalid("a ref is longer than 1 KiB"));
                }
                refs.push(value.to_string());
            }
            Ok(refs)
        }
        Some(_) => Err(TeamError::invalid("refs must be an array")),
    }
}

fn reason_text(reason: &str) -> &'static str {
    match reason {
        "off" => "teams are off for this chat",
        "no_tools" => "teams are not available for this chat",
        _ => "this chat does not lead the team",
    }
}

fn error_message(error: &Value) -> String {
    error
        .get("message")
        .and_then(Value::as_str)
        .map(str::to_string)
        .unwrap_or_else(|| error.to_string())
}

fn turn_outcome(message: &Value) -> (bool, Option<String>) {
    if let Some(error) = message.get("error") {
        return (false, Some(error_message(error)));
    }
    match message
        .get("result")
        .and_then(|result| result.get("stopReason"))
        .and_then(Value::as_str)
    {
        Some("end_turn") | None => (true, None),
        Some("cancelled") => (false, None),
        Some("error") => {
            let message = message
                .get("result")
                .and_then(|result| result.get("error"))
                .map(error_message)
                .unwrap_or_else(|| "error".to_string());
            (false, Some(message))
        }
        // max_tokens, max_turn_requests, refusal, ... are normal ends for the
        // team layer: count the turn and run the report fallback, but do not
        // send a bad-turn notice (18.11 only cancelled/error are bad).
        Some(_) => (true, None),
    }
}

/// The model values an agent's `configOptions` offers (19.6), in order.
fn model_values(config_options: &Value) -> Vec<String> {
    let mut values = Vec::new();
    let Some(options) = config_options.as_array() else {
        return values;
    };
    for option in options {
        if option.get("id").and_then(Value::as_str) != Some("model") {
            continue;
        }
        if let Some(entries) = option.get("options").and_then(Value::as_array) {
            for entry in entries {
                if let Some(value) = entry.get("value").and_then(Value::as_str) {
                    values.push(value.to_string());
                }
                if let Some(children) = entry.get("options").and_then(Value::as_array) {
                    for child in children {
                        if let Some(value) = child.get("value").and_then(Value::as_str) {
                            values.push(value.to_string());
                        }
                    }
                }
            }
        }
        if let Some(entries) = option.get("values").and_then(Value::as_array) {
            for entry in entries {
                if let Some(value) = entry.as_str() {
                    values.push(value.to_string());
                }
            }
        }
    }
    values
}

/// The `scope` a `workflow_save`/`workflow_delete` asked for (19.5).
fn stored_scope(scope: Option<&str>) -> Result<workflow::Scope, TeamError> {
    match scope {
        None => Ok(workflow::Scope::Project),
        Some(scope) => workflow::Scope::parse_stored(scope)
            .ok_or_else(|| TeamError::invalid("scope must be project or user")),
    }
}

/// A required absolute `cwd` parameter (19.5).
fn absolute_cwd(params: &Value) -> Result<String, TeamError> {
    let cwd = required_team_string(params, "cwd")?;
    if !std::path::Path::new(&cwd).is_absolute() {
        return Err(TeamError::invalid("cwd must be an absolute path"));
    }
    Ok(cwd)
}
