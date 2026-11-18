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
    Workflows {
        cwd: String,
    },
    WorkflowSave {
        team: String,
        value: Value,
        scope: Option<String>,
        replace: bool,
    },
    WorkflowGet {
        team: String,
        name: String,
    },
    WorkflowDelete {
        team: String,
        name: String,
        scope: Option<String>,
    },
    WorkflowDeleteCwd {
        name: String,
        scope: String,
    },
    Start {
        team: String,
        workflow: String,
        task: Option<String>,
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
        if matches!(
            method,
            "bus.workflow_save" | "bus.workflow_get" | "bus.workflow_delete"
        ) {
            if role != Role::Leader {
                self.send_error(
                    conn,
                    id,
                    &TeamError::not_allowed("workflow tools are leader only"),
                );
            } else {
                self.bus_workflow(conn, id, method, &team, params);
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
        if method == "team.workflows" || method == "team.workflow_delete" || method == "team.start"
        {
            self.team_deferred(conn, id, method, params);
            return;
        }
        let result = match method {
            "team.configure" => self.team_configure(params).map(|value| (value, false)),
            "team.leader_server" => self.team_leader_server(params).map(|value| (value, false)),
            "team.bind_leader" => self.team_bind_leader(params).map(|value| (value, true)),
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
        self.teams.configure(&cwd, config)?;
        if let Some((team, instance, session)) = self.teams.config_resume(&cwd) {
            if let Some(handle) = self.instances.get(&instance) {
                let agent = handle.key.agent.clone();
                self.teams.start_resume(&team, &instance, &session, &agent);
                self.resume_team(&team);
            } else {
                // The instance that bound before configure is gone; stay
                // suspended and wait for a new bind.
                self.teams.clear_pending_resume(&team);
            }
        }
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
        let Some(handle) = self.instances.get(&instance) else {
            return Err(TeamError::new(UNKNOWN_INSTANCE, "unknown instance"));
        };
        let agent = handle.key.agent.clone();
        let session = required_team_string(params, "sessionId")?;
        let token_id = required_team_string(params, "token_id")?;
        match self
            .teams
            .bind_leader(&instance, &session, &token_id, &agent)?
        {
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
            let spawn = SpawnRequest {
                team: team_id.to_string(),
                name: name.clone(),
                template: template_name,
                model: resume_model,
                role: resume_role,
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
            self.interrupt_generation
                .insert((team.clone(), to.clone()), generation);
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
        // Pending worker writes are flushed before the team (and its board)
        // goes away (19.2).
        self.flush_pending_board(&team, false);
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

    /// `bus.spawn`: a worktree spawn answers after git finished, so the reply
    /// is sent here instead of returning a value.
    fn bus_spawn(&mut self, conn: u64, id: &Value, team: &str, params: &Value) {
        let mut assigned_name: Option<String> = None;
        let result = (|| -> Result<Option<(Value, bool)>, TeamError> {
            let template = required_team_string(params, "template")?;
            let name = optional_string(params, "name")?;
            let model = optional_string(params, "model")?;
            let role = optional_string(params, "role")?;
            let task = optional_string(params, "task")?;
            let label = optional_string(params, "label")?;
            match self.teams.request_spawn_labeled(
                team,
                &template,
                name.as_deref(),
                model.as_deref(),
                role.as_deref(),
                task.as_deref(),
                label.as_deref(),
            )? {
                SpawnOutcome::Started(spawn) => {
                    assigned_name = Some(spawn.name.clone());
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
                SpawnOutcome::Awaiting { request, name } => {
                    assigned_name = Some(name);
                    Ok(Some((
                        json!({
                            "status": "awaiting_approval",
                            "request": request,
                        }),
                        false,
                    )))
                }
            }
        })();
        match result {
            Ok(Some((value, delivery))) => {
                // An awaiting approval reply names the request, not the worker;
                // the activity line still has to show the assigned name.
                let mut noted = value.clone();
                if let (Some(name), Some(object)) = (&assigned_name, noted.as_object_mut()) {
                    object.entry("name").or_insert_with(|| json!(name));
                }
                self.teams.note_bus_call(
                    team,
                    "leader",
                    "bus.spawn",
                    params,
                    &noted,
                    crate::team::now_ms(),
                );
                self.drain_team_events();
                if delivery {
                    self.team_deliveries();
                }
                self.send_to(conn, &success(id, value));
            }
            Ok(None) => {
                // The worktree spawn answers later; the call itself is still
                // the leader's latest activity, named after the worker the
                // service actually assigned.
                let named = assigned_name
                    .as_ref()
                    .map(|name| json!({ "name": name }))
                    .unwrap_or(Value::Null);
                self.teams.note_bus_call(
                    team,
                    "leader",
                    "bus.spawn",
                    params,
                    &named,
                    crate::team::now_ms(),
                );
                self.drain_team_events();
            }
            Err(error) => self.send_error(conn, id, &error),
        }
    }

    /// `team.spawn` (18.13): the person starts a worker, no inbox item.
    fn team_spawn(&mut self, conn: u64, id: &Value, params: &Value) {
        let result = (|| -> Result<SpawnRequest, TeamError> {
            let team = required_team_string(params, "team")?;
            let template = required_team_string(params, "template")?;
            let name = optional_string(params, "name")?;
            let model = optional_string(params, "model")?;
            let role = optional_string(params, "role")?;
            let task = optional_string(params, "task")?;
            let label = optional_string(params, "label")?;
            self.teams.request_spawn_human_labeled(
                &team,
                &template,
                name.as_deref(),
                model.as_deref(),
                role.as_deref(),
                task.as_deref(),
                label.as_deref(),
            )
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
                    let team = required_team_string(params, "team")?;
                    let workflow = required_team_string(params, "workflow")?;
                    let task = optional_string(params, "task")?;
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

    /// `bus.workflow_save/get/delete` from a leader (19.5).
    fn bus_workflow(&mut self, conn: u64, id: &Value, method: &str, team: &str, params: &Value) {
        let result = (|| -> Result<(String, DeferredTeam), TeamError> {
            let cwd = self
                .teams
                .team(team)
                .ok_or_else(|| TeamError::unknown("unknown team"))?
                .cwd
                .clone();
            let call = match method {
                "bus.workflow_save" => {
                    let value = params
                        .get("workflow")
                        .cloned()
                        .ok_or_else(|| TeamError::invalid("workflow is required"))?;
                    if !value.is_object() {
                        return Err(TeamError::invalid("workflow must be an object"));
                    }
                    // `scope` is accepted both inside the workflow and next to
                    // it; the protocol describes it either way.
                    let scope = params
                        .get("scope")
                        .and_then(Value::as_str)
                        .or_else(|| value.get("scope").and_then(Value::as_str))
                        .map(str::to_string);
                    let replace = optional_bool(params, "replace")?.unwrap_or(false);
                    DeferredTeam::WorkflowSave {
                        team: team.to_string(),
                        value,
                        scope,
                        replace,
                    }
                }
                "bus.workflow_get" => DeferredTeam::WorkflowGet {
                    team: team.to_string(),
                    name: required_team_string(params, "name")?,
                },
                "bus.workflow_delete" => DeferredTeam::WorkflowDelete {
                    team: team.to_string(),
                    name: required_team_string(params, "name")?,
                    scope: optional_string(params, "scope")?,
                },
                _ => return Err(TeamError::new(METHOD_NOT_FOUND, "method not found")),
            };
            Ok((cwd, call))
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
            DeferredTeam::Status { team, name } => match self.teams.status(&team, &name, project) {
                Ok(value) => self.send_to(conn, &success(id, value)),
                Err(error) => self.send_error(conn, id, &error),
            },
            DeferredTeam::Workflows { cwd } => {
                let value = self.teams.workflows_for_cwd(&cwd, project);
                self.send_to(conn, &success(id, value));
            }
            DeferredTeam::WorkflowSave {
                team,
                value,
                scope,
                replace,
            } => {
                if !self.recorder.enabled() {
                    self.send_error(conn, id, &TeamError::not_allowed("no database"));
                    return;
                }
                let scope = match stored_scope(scope.as_deref()) {
                    Ok(scope) => scope,
                    Err(error) => {
                        self.send_error(conn, id, &error);
                        return;
                    }
                };
                match self
                    .teams
                    .workflow_save(&team, project, &value, scope, replace)
                {
                    Ok(stored) => {
                        self.persist_workflow(&stored, project);
                        self.send_to(conn, &success(id, json!({ "name": stored.name })));
                    }
                    Err(error) => self.send_error(conn, id, &error),
                }
            }
            DeferredTeam::WorkflowGet { team, name } => {
                match self.teams.workflow_get(&team, project, &name) {
                    Ok(value) => self.send_to(conn, &success(id, value)),
                    Err(error) => self.send_error(conn, id, &error),
                }
            }
            DeferredTeam::WorkflowDelete { team, name, scope } => {
                if !self.recorder.enabled() {
                    self.send_error(conn, id, &TeamError::not_allowed("no database"));
                    return;
                }
                let scope = match scope.map(|scope| stored_scope(Some(&scope))).transpose() {
                    Ok(scope) => scope,
                    Err(error) => {
                        self.send_error(conn, id, &error);
                        return;
                    }
                };
                match self.teams.workflow_delete(&team, project, &name, scope) {
                    Ok(removed) => {
                        self.forget_workflow(&removed, project);
                        self.send_to(conn, &success(id, json!({})));
                    }
                    Err(error) => self.send_error(conn, id, &error),
                }
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

    pub(crate) fn worker_interrupt_deadline(
        &mut self,
        team: &str,
        participant: &str,
        generation: u64,
    ) {
        let key = (team.to_string(), participant.to_string());
        if self.interrupt_generation.get(&key) != Some(&generation) {
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
