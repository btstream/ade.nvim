//! Team orchestration: the I/O half of PROTOCOL.md section 18.
//!
//! The state machine lives in [`crate::team`]. This module owns the parts that
//! need the hub: spawning worker processes, sending service-originated ACP
//! requests, routing their responses to the driver, brokering watchers and
//! broadcasting `team.*` notifications.

use super::*;
use crate::team::{
    worktree, AnswerEffect, ItemKind, Kind, Role, SpawnOutcome, SpawnPlan, SpawnRequest, TeamError,
    TeamEvent, INVALID_TEAM_PARAM, MAX_BODY_BYTES,
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
}

pub(crate) enum StartResult {
    Started,
    Deferred,
    /// The failure was reported and the spawn must not reply again.
    Replied,
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
}

impl Hub {
    // -- routing -----------------------------------------------------------

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
        if method == "bus.spawn" {
            if role != Role::Leader {
                self.send_error(
                    conn,
                    id,
                    &TeamError::not_allowed("team_spawn is leader only"),
                );
            } else {
                self.bus_spawn(conn, id, &team, params);
            }
            return;
        }
        let result = match method {
            "bus.send" => self.bus_send(conn, &team, &name, params),
            "bus.ask_human" => self.bus_ask_human(&team, &name, params),
            "bus.status" => self.teams.status(&team, &name).map(|value| (value, false)),
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
                self.drain_team_events();
                if delivery {
                    self.team_deliveries();
                }
                self.send_to(conn, &success(id, value));
            }
            Err(error) => self.send_error(conn, id, &error),
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
        if method == "team.remove_worktree" {
            self.team_remove_worktree(conn, id, params);
            return;
        }
        let result = match method {
            "team.configure" => self.team_configure(params).map(|value| (value, false)),
            "team.leader_server" => self.team_leader_server(params).map(|value| (value, false)),
            "team.bind_leader" => self.team_bind_leader(params).map(|value| (value, true)),
            "team.list" => Ok((self.teams.list(), false)),
            "team.send" => self.team_send(params),
            "team.read" => self.team_read(params).map(|value| (value, false)),
            "team.answer" => self.team_answer(params),
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
        self.teams.configure(&cwd, config)?;
        Ok(json!({}))
    }

    fn team_leader_server(&mut self, params: &Value) -> Result<Value, TeamError> {
        let instance = required_team_string(params, "instance")?;
        let cwd = required_team_string(params, "cwd")?;
        let Some(handle) = self.instances.get(&instance) else {
            return Err(TeamError::new(UNKNOWN_INSTANCE, "unknown instance"));
        };
        let instance_cwd = handle.key.cwd.clone();
        let (server, token_id) = self.teams.leader_server(&instance, &cwd, &instance_cwd)?;
        Ok(json!({ "server": server, "token_id": token_id }))
    }

    fn team_bind_leader(&mut self, params: &Value) -> Result<Value, TeamError> {
        let instance = required_team_string(params, "instance")?;
        if !self.instances.contains_key(&instance) {
            return Err(TeamError::new(UNKNOWN_INSTANCE, "unknown instance"));
        }
        let session = required_team_string(params, "sessionId")?;
        let token_id = required_team_string(params, "token_id")?;
        match self.teams.bind_leader(&instance, &session, &token_id)? {
            crate::team::BindOutcome::Active(entry) => Ok(entry),
            crate::team::BindOutcome::Resume { team, entry } => {
                self.resume_team(&team);
                Ok(entry)
            }
        }
    }

    /// Start every stored participant of a resumed team (18.15).
    fn resume_team(&mut self, team_id: &str) {
        let Some(team) = self.teams.team(team_id) else {
            return;
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
                return;
            };
            let Some(participant) = team.participants.get(&name) else {
                continue;
            };
            let template_name = participant.template.clone().unwrap_or_default();
            if !team.config.templates.contains_key(&template_name) {
                self.teams.worker_start_failed(
                    team_id,
                    &name,
                    &format!("template {template_name} is no longer configured"),
                );
                failures.push(name.clone());
                continue;
            }
            let resume_session = participant.session.clone();
            let worktree = participant.worktree.clone();
            let leader_cwd = team.cwd.clone();
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
            if let Some(participant) = self
                .teams
                .team_mut(team_id)
                .and_then(|team| team.participants.get_mut(&name))
            {
                participant.starting = true;
                participant.state = crate::team::ParticipantState::Idle;
                participant.instance = None;
            }
            let spawn = SpawnRequest {
                team: team_id.to_string(),
                name: name.clone(),
                template: template_name,
                task: None,
            };
            let opts = StartOptions {
                resume: resume_session,
                ..StartOptions::default()
            };
            if !self.start_worker_now(&spawn, &plan, Some(resume_cwd), &opts) {
                failures.push(name.clone());
            }
        }
        let mut body = "team resumed after a service restart".to_string();
        if !failures.is_empty() {
            body.push_str("; not resumed: ");
            body.push_str(&failures.join(", "));
        }
        let _ = self.teams.send_message(
            team_id,
            "human",
            "leader",
            Kind::Notice,
            &body,
            None,
            vec![],
        );
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
        let body = required_team_string(params, "body")?;
        let task = optional_string(params, "task")?;
        let refs = team_refs(params)?;
        let id =
            self.teams
                .send_message(&team, "human", &to, kind, &body, task.as_deref(), refs)?;
        if kind == Kind::Control && body == "cancel" {
            self.cancel_participant_turn(&team, &to);
        }
        Ok((json!({ "id": id }), true))
    }

    fn team_read(&mut self, params: &Value) -> Result<Value, TeamError> {
        let team = required_team_string(params, "team")?;
        let participant = required_team_string(params, "participant")?;
        let since = optional_u64(params, "since")?;
        self.teams.read(&team, &participant, since)
    }

    fn team_answer(&mut self, params: &Value) -> Result<(Value, bool), TeamError> {
        let request = required_team_string(params, "request")?;
        let text = optional_string(params, "text")?;
        let option = optional_string(params, "option")?;
        let allow = optional_bool(params, "allow")?;
        let before = self.teams.item_by_id(&request);
        let (effect, team) = self.teams.answer(&request, text, option, allow)?;
        let spawned = matches!(&effect, AnswerEffect::Spawn(_));
        match effect {
            AnswerEffect::Spawn(spawn) => {
                // The approval notice waits for the worktree result so a
                // dirty tree can be named (18.16).
                self.start_worker(
                    &spawn,
                    StartOptions {
                        approved_request: Some(request.clone()),
                        ..StartOptions::default()
                    },
                );
            }
            AnswerEffect::Permission {
                instance,
                agent_id,
                response,
            } => {
                self.answer_pending(&instance, agent_id, response);
            }
            AnswerEffect::Request {
                instance,
                agent_id,
                result,
            } => {
                self.answer_pending(&instance, agent_id, result);
            }
            AnswerEffect::Question | AnswerEffect::Ack => {}
        }
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
        let (_entry, workers) = self.teams.close(&team)?;
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

    /// `bus.spawn`: a worktree spawn answers after git finished, so the reply
    /// is sent here instead of returning a value.
    fn bus_spawn(&mut self, conn: u64, id: &Value, team: &str, params: &Value) {
        let result = (|| -> Result<Option<(Value, bool)>, TeamError> {
            let template = required_team_string(params, "template")?;
            let name = optional_string(params, "name")?;
            let task = optional_string(params, "task")?;
            match self
                .teams
                .request_spawn(team, &template, name.as_deref(), task.as_deref())?
            {
                SpawnOutcome::Started(spawn) => {
                    let opts = StartOptions {
                        reply: Some((conn, id.clone(), SpawnReplyKind::Bus)),
                        ..StartOptions::default()
                    };
                    match self.start_worker(&spawn, opts) {
                        StartResult::Started => Ok(Some((
                            Self::spawn_value(&spawn.name, SpawnReplyKind::Bus, None),
                            true,
                        ))),
                        StartResult::Deferred | StartResult::Replied => Ok(None),
                    }
                }
                SpawnOutcome::Awaiting { request, name: _ } => Ok(Some((
                    json!({
                        "status": "awaiting_approval",
                        "request": request,
                    }),
                    false,
                ))),
            }
        })();
        match result {
            Ok(Some((value, delivery))) => {
                self.drain_team_events();
                if delivery {
                    self.team_deliveries();
                }
                self.send_to(conn, &success(id, value));
            }
            Ok(None) => {}
            Err(error) => self.send_error(conn, id, &error),
        }
    }

    /// `team.spawn` (18.13): the person starts a worker, no inbox item.
    fn team_spawn(&mut self, conn: u64, id: &Value, params: &Value) {
        let result = (|| -> Result<SpawnRequest, TeamError> {
            let team = required_team_string(params, "team")?;
            let template = required_team_string(params, "template")?;
            let name = optional_string(params, "name")?;
            let task = optional_string(params, "task")?;
            self.teams
                .request_spawn_human(&team, &template, name.as_deref(), task.as_deref())
        })();
        match result {
            Ok(spawn) => {
                self.drain_team_events();
                let opts = StartOptions {
                    reply: Some((conn, id.clone(), SpawnReplyKind::Team)),
                    human_notice: true,
                    ..StartOptions::default()
                };
                if matches!(self.start_worker(&spawn, opts), StartResult::Started) {
                    self.send_to(
                        conn,
                        &success(
                            id,
                            Self::spawn_value(&spawn.name, SpawnReplyKind::Team, None),
                        ),
                    );
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
                },
            );
            let cwd = plan.cwd.clone();
            let stamp = plan.stamp.clone();
            let sender = self.command_sender.clone();
            let closing = self.closing_flag.clone();
            let team_for_git = team.clone();
            let name_for_git = participant.clone();
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
            model: plan.template.model.clone(),
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
        outcome: WorktreeOutcome,
    ) {
        match outcome {
            WorktreeOutcome::Spawn(result) => {
                let Some(pending) = self
                    .pending_worktrees
                    .remove(&(team.to_string(), participant.to_string()))
                else {
                    return;
                };
                match result {
                    Ok(info) => {
                        self.teams
                            .worktree_prepared(team, participant, info.clone());
                        if self.teams.team(team).is_none() {
                            // The team closed while git ran: the new worktree
                            // belongs to nobody.
                            eprintln!(
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
                                let value =
                                    Self::spawn_value(&pending.spawn.name, *kind, Some(&info));
                                self.send_to(*conn, &success(id, value));
                            }
                        }
                    }
                    Err(error) => self.fail_spawn(&pending.spawn, &pending.opts, error),
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
        let Some(handle) = self.instances.get_mut(instance) else {
            return false;
        };
        let (agent_id, frame) = handle.relay.service_request(method, params);
        if !handle.control.send_frame(frame) {
            return false;
        }
        self.driver.insert((instance.to_string(), agent_id), call);
        true
    }

    pub(crate) fn handle_service_response(
        &mut self,
        instance: &str,
        agent_id: u64,
        seq: u64,
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
                    // The agent cannot load: start a new session and say so.
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
                self.teams.worker_session_set(&team, &participant, &session);
                let wants_model = model
                    .as_deref()
                    .is_some_and(|model| offers_model(&config_options, model));
                if let (Some(model), true) = (model, wants_model) {
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
            } => {
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
                self.drain_team_events();
                self.release_held_prompts(instance, &session, false);
                let _ = (team, participant, seq);
                self.team_deliveries();
            }
        }
    }

    pub(crate) fn team_deliveries(&mut self) {
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
            // The dequeue and the bus-turn mark must be durable before the
            // prompt can run, or a restart would deliver it twice (18.15).
            self.persist_all_teams();
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
                    team,
                    participant,
                    session: session.clone(),
                },
            );
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
        // Any service prompt on an attached instance is a leader bus prompt;
        // after `team.close` the team is gone but the running prompt is still
        // cancelled/handled the same way.
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
        let session = params.get("sessionId").and_then(Value::as_str);
        self.teams.observe_chunk(instance, session, text);
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
        self.teams.leader_session_closed(instance, session);
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
                TeamEvent::Changed(id) | TeamEvent::Inbox(id, _) => {
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

fn offers_model(config_options: &Value, model: &str) -> bool {
    let Some(options) = config_options.as_array() else {
        return false;
    };
    for option in options {
        if option.get("id").and_then(Value::as_str) != Some("model") {
            continue;
        }
        if let Some(values) = option.get("options").and_then(Value::as_array) {
            for entry in values {
                if entry.get("value").and_then(Value::as_str) == Some(model) {
                    return true;
                }
                if let Some(children) = entry.get("options").and_then(Value::as_array) {
                    if children
                        .iter()
                        .any(|child| child.get("value").and_then(Value::as_str) == Some(model))
                    {
                        return true;
                    }
                }
            }
        }
        if let Some(values) = option.get("values").and_then(Value::as_array) {
            if values.iter().any(|value| value.as_str() == Some(model)) {
                return true;
            }
        }
    }
    false
}
