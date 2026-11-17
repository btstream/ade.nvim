//! Team orchestration: the I/O half of PROTOCOL.md section 18.
//!
//! The state machine lives in [`crate::team`]. This module owns the parts that
//! need the hub: spawning worker processes, sending service-originated ACP
//! requests, routing their responses to the driver, brokering watchers and
//! broadcasting `team.*` notifications.

use super::*;
use crate::team::{
    AnswerEffect, ItemKind, Kind, Role, SpawnOutcome, TeamError, TeamEvent, INVALID_TEAM_PARAM,
    MAX_BODY_BYTES,
};

#[derive(Debug)]
pub enum ServiceCall {
    Initialize {
        team: String,
        participant: String,
        server: Value,
        model: Option<String>,
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
            "bus.spawn" => {
                if role != Role::Leader {
                    Err(TeamError::not_allowed("team_spawn is leader only"))
                } else {
                    self.bus_spawn(&team, params)
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
            Err(error) => self.send_to(conn, &failure(id, error.code, &error.message)),
        }
    }

    pub(crate) fn handle_team_method(
        &mut self,
        conn: u64,
        method: &str,
        params: &Value,
        id: &Value,
    ) {
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
            Err(error) => self.send_to(conn, &failure(id, error.code, &error.message)),
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
        let session = required_team_string(params, "sessionId")?;
        let token_id = required_team_string(params, "token_id")?;
        let entry = self.teams.bind_leader(&instance, &session, &token_id)?;
        Ok(entry)
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
        let task = params.get("task").and_then(Value::as_str);
        let refs = team_refs(params)?;
        let id = self
            .teams
            .send_message(&team, "human", &to, kind, &body, task, refs)?;
        if kind == Kind::Control && body == "cancel" {
            self.cancel_participant_turn(&team, &to);
        }
        Ok((json!({ "id": id }), true))
    }

    fn team_read(&mut self, params: &Value) -> Result<Value, TeamError> {
        let team = required_team_string(params, "team")?;
        let participant = required_team_string(params, "participant")?;
        let since = params.get("since").and_then(Value::as_u64);
        self.teams.read(&team, &participant, since)
    }

    fn team_answer(&mut self, params: &Value) -> Result<(Value, bool), TeamError> {
        let request = required_team_string(params, "request")?;
        let text = params
            .get("text")
            .and_then(Value::as_str)
            .map(str::to_string);
        let option = params
            .get("option")
            .and_then(Value::as_str)
            .map(str::to_string);
        let allow = params.get("allow").and_then(Value::as_bool);
        let before = self.teams.item_by_id(&request);
        let (effect, team) = self.teams.answer(&request, text, option, allow)?;
        let spawned = matches!(&effect, AnswerEffect::Spawn(_));
        match effect {
            AnswerEffect::Spawn(spawn) => {
                self.team_spawn_notice(&team, &request, allow == Some(true), &spawn.name);
                self.start_worker(&spawn);
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
        self.teams.unwatch(&team, &participant, conn)?;
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
            let participant = required_team_string(params, "participant")?;
            let replay = params
                .get("replay")
                .and_then(Value::as_bool)
                .unwrap_or(false);
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
        let task = params.get("task").and_then(Value::as_str);
        let refs = team_refs(params)?;
        let id = self
            .teams
            .send_message(team, name, &to, kind, &body, task, refs)?;
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
        let since = params.get("since").and_then(Value::as_u64);
        Ok((self.teams.read(team, &participant, since)?, false))
    }

    fn bus_spawn(&mut self, team: &str, params: &Value) -> Result<(Value, bool), TeamError> {
        let template = required_team_string(params, "template")?;
        let name = params.get("name").and_then(Value::as_str);
        let task = params.get("task").and_then(Value::as_str);
        match self.teams.request_spawn(team, &template, name, task)? {
            SpawnOutcome::Started(spawn) => {
                self.start_worker(&spawn);
                Ok((json!({ "status": "started", "name": spawn.name }), true))
            }
            SpawnOutcome::Awaiting { request, name: _ } => Ok((
                json!({
                    "status": "awaiting_approval",
                    "request": request,
                }),
                false,
            )),
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

    fn start_worker(&mut self, spawn: &crate::team::SpawnRequest) {
        let Some((_template_name, template, cwd)) =
            self.teams.spawn_details(&spawn.team, &spawn.name)
        else {
            return;
        };
        let mut key = template.key.clone();
        key.cwd = cwd;
        key.capabilities = crate::team::worker_capabilities();
        #[cfg(unix)]
        let spawned = self.spawn_worker(key.clone(), template.env.clone(), template.launch.clone());
        #[cfg(not(unix))]
        let spawned = self.spawn_worker(key.clone(), template.env.clone());
        let instance = match spawned {
            Ok(instance) => instance,
            Err(error) => {
                self.teams
                    .worker_start_failed(&spawn.team, &spawn.name, &error);
                return;
            }
        };
        self.teams
            .worker_instance_set(&spawn.team, &spawn.name, &instance);
        let Some((_token_id, token)) =
            self.teams
                .create_worker_token(&spawn.team, &spawn.name, &instance)
        else {
            self.teams
                .worker_start_failed(&spawn.team, &spawn.name, "cannot create worker token");
            return;
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
            model: template.model.clone(),
        };
        if !self.send_service_request(&instance, "initialize", params, call) {
            self.teams.revoke_instance_tokens(&instance);
            self.stop_worker_instance(&instance);
            self.teams.worker_start_failed(
                &spawn.team,
                &spawn.name,
                "agent is not accepting messages",
            );
        }
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
            } => {
                if let Some(error) = message.get("error") {
                    let reason = error_message(error);
                    self.teams.revoke_instance_tokens(instance);
                    self.stop_worker_instance(instance);
                    self.teams.worker_start_failed(&team, &participant, &reason);
                    self.drain_team_events();
                    return;
                }
                let Some(cwd) = self.teams.team(&team).map(|team| team.cwd.clone()) else {
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
                    self.send_service_request(
                        instance,
                        "session/set_config_option",
                        params,
                        ServiceCall::SetModel {
                            team: team.clone(),
                            participant: participant.clone(),
                        },
                    );
                } else {
                    self.team_deliveries();
                }
                self.drain_team_events();
            }
            ServiceCall::SetModel { team, participant } => {
                let _ = (team, participant);
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
                let error = if cancelled {
                    Some("cancelled".to_string())
                } else {
                    error
                };
                self.teams
                    .turn_finished(instance, success, error, String::new());
                self.drain_team_events();
                self.release_held_prompts(instance, &session);
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
        for request in requests {
            let params = json!({
                "sessionId": request.session,
                "prompt": request.blocks,
            });
            let Some((agent_id, frame, seq, event)) = self
                .instances
                .get_mut(&request.instance)
                .map(|handle| handle.relay.service_prompt(&request.session, params))
            else {
                continue;
            };
            if let Some(event) = event {
                self.record_events(&request.instance, vec![event]);
            }
            let Some(handle) = self.instances.get_mut(&request.instance) else {
                continue;
            };
            if !handle.control.send_frame(frame) {
                continue;
            }
            self.driver.insert(
                (request.instance.clone(), agent_id),
                ServiceCall::Prompt {
                    team: request.team.clone(),
                    participant: request.participant.clone(),
                    session: request.session.clone(),
                },
            );
            let started = json!({
                "jsonrpc": "2.0",
                "method": "_ade/turn_started",
                "params": {
                    "sessionId": request.session,
                    "origin": "bus",
                    "prompt": request.blocks,
                },
            });
            for conn in self.delivery_conns(&request.instance) {
                self.send_tunnel_recv(conn, &request.instance, seq, &started);
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
        let Some(team) = self.teams.team_of_instance(instance) else {
            return false;
        };
        if !team.is_leader_instance(instance) {
            return false;
        }
        if !self.bus_prompt_active(instance, session) {
            return false;
        }
        let key = (instance.to_string(), session.to_string());
        self.held_prompts
            .entry(key)
            .or_default()
            .push_back((conn, message.clone()));
        if self
            .held_prompts
            .contains_key(&(instance.to_string(), session.to_string()))
        {
            let first = self
                .held_prompts
                .get(&(instance.to_string(), session.to_string()))
                .is_some_and(|queue| queue.len() == 1);
            if first {
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
                tokio::spawn(async move {
                    tokio::time::sleep(Duration::from_secs(30)).await;
                    let _ = sender
                        .send(Command::TeamDeadline { instance, session })
                        .await;
                });
            }
        }
        true
    }

    pub(crate) fn team_deadline(&mut self, instance: &str, session: &str) {
        if self
            .held_prompts
            .contains_key(&(instance.to_string(), session.to_string()))
        {
            self.release_held_prompts(instance, session);
        }
    }

    fn release_held_prompts(&mut self, instance: &str, session: &str) {
        let Some(queue) = self
            .held_prompts
            .remove(&(instance.to_string(), session.to_string()))
        else {
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
        let mut conns = self
            .instances
            .get(instance)
            .map(|handle| handle.attached.clone())
            .unwrap_or_default();
        conns.extend(self.teams.watcher_conns(instance));
        conns.sort_unstable();
        conns.dedup();
        conns
    }

    pub(crate) fn is_watcher(&self, conn: u64, instance: &str) -> bool {
        self.teams.watches(conn, instance)
    }

    fn answer_pending(&mut self, instance: &str, agent_id: u64, result: Value) {
        let retractions = self
            .instances
            .get_mut(instance)
            .map(|handle| handle.relay.answer_pending(agent_id))
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

    fn send_to_frontends(&self, value: &Value) {
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

    pub(crate) fn drain_team_events(&mut self) {
        for event in self.teams.drain_events() {
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
        Some("cancelled") => (false, Some("cancelled".to_string())),
        Some("error") => {
            let message = message
                .get("result")
                .and_then(|result| result.get("error"))
                .map(error_message)
                .unwrap_or_else(|| "error".to_string());
            (false, Some(message))
        }
        Some(other) => (false, Some(other.to_string())),
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
