//! The instance hub: owns agent instances and connected front ends, and
//! dispatches `agent.*` methods and `tunnel.send` frames.
//!
//! The hub is one task. Connection tasks send it [`Command`]s and the runtime
//! sends [`RuntimeEvent`]s, so no state needs a lock: [`crate::relay`] and the
//! instance table are only touched from here, which keeps the relay rules
//! easy to reason about.

use std::collections::HashMap;
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::Arc;
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use serde_json::{json, Value};
use tokio::sync::{mpsc, watch, Notify};

use crate::protocol::{
    failure, success, FRAME_REJECTED, INVALID_PARAMS, INVALID_REQUEST, METHOD_NOT_FOUND,
    NOT_ATTACHED, SPAWN_FAILED, UNKNOWN_INSTANCE,
};
use crate::relay::{parse_env, AgentAction, FrontendAction, InstanceKey, Relay};
use crate::runtime::{self, Exited, ProcControl, RuntimeEvent, SpawnSpec, StopTimeouts};

/// Maximum bytes queued for one connection (PROTOCOL.md section 7).
pub const MAX_OUTBOX_BYTES: usize = 64 * 1024 * 1024;
/// Frames that may sit in the writer queue before the connection counts as
/// unable to keep up.
const OUTBOX_FRAMES: usize = 1024;

/// Frames queued for one connection, serialised and newline-terminated.
#[derive(Debug, Clone)]
pub struct Outbox {
    frames: mpsc::Sender<Vec<u8>>,
    queued: Arc<AtomicUsize>,
    closer: watch::Sender<bool>,
    limit: usize,
}

impl Outbox {
    /// Create the queue and the receiving side used by the writer task.
    pub fn new(closer: watch::Sender<bool>) -> (Self, OutboxReceiver) {
        Self::with_limit(closer, MAX_OUTBOX_BYTES)
    }

    pub fn with_limit(closer: watch::Sender<bool>, limit: usize) -> (Self, OutboxReceiver) {
        let (frames, receiver) = mpsc::channel(OUTBOX_FRAMES);
        let queued = Arc::new(AtomicUsize::new(0));
        (
            Self {
                frames,
                queued: Arc::clone(&queued),
                closer,
                limit,
            },
            OutboxReceiver {
                frames: receiver,
                queued,
            },
        )
    }

    /// Number of bytes still queued for this connection.
    pub fn queued_bytes(&self) -> usize {
        self.queued.load(Ordering::Relaxed)
    }

    /// Whether every queued frame has been written out.
    pub fn is_empty(&self) -> bool {
        self.queued_bytes() == 0
    }

    /// Queue one JSON-RPC message.
    ///
    /// Returns false when the connection is being closed: the queue would
    /// exceed its limit, or the writer is gone. The caller treats that as the
    /// connection having ended.
    pub fn send(&self, value: &Value) -> bool {
        let mut bytes = match serde_json::to_vec(value) {
            Ok(bytes) => bytes,
            Err(error) => {
                eprintln!("nvim_ade_server: cannot serialize a frame: {error}");
                return true;
            }
        };
        bytes.push(b'\n');

        let total = self.queued.fetch_add(bytes.len(), Ordering::AcqRel) + bytes.len();
        if total > self.limit {
            let _ = self.closer.send(true);
            return false;
        }
        if self.frames.try_send(bytes).is_err() {
            // Either the writer is gone or the frame queue is saturated; both
            // mean this connection cannot keep up.
            let _ = self.closer.send(true);
            return false;
        }
        true
    }
}

/// The receiving side of one connection's queue, used by its writer task.
///
/// Dropping the byte count as frames are written keeps [`Outbox::is_empty`]
/// meaningful for a graceful close.
#[derive(Debug)]
pub struct OutboxReceiver {
    frames: mpsc::Receiver<Vec<u8>>,
    queued: Arc<AtomicUsize>,
}

impl OutboxReceiver {
    /// Next serialised frame, or `None` when the connection is gone.
    pub async fn recv(&mut self) -> Option<Vec<u8>> {
        let bytes = self.frames.recv().await?;
        self.queued.fetch_sub(bytes.len(), Ordering::AcqRel);
        Some(bytes)
    }
}

/// Instructions from connection tasks to the hub.
#[derive(Debug)]
pub enum Command {
    Register {
        conn: u64,
        outbox: Outbox,
    },
    Frame {
        conn: u64,
        frame: Value,
    },
    Disconnected {
        conn: u64,
    },
    /// Stop every instance. The hub notifies [`Hub::stopped`] when done.
    Shutdown,
}

/// Events from the hub to the server loop.
#[derive(Debug, PartialEq, Eq)]
pub enum HubEvent {
    /// Whether any instance has a running turn or a pending request.
    Busy(bool),
}

/// Pending agent requests to deliver, each with the `seq` it arrived with.
type Replay = Vec<(u64, Value)>;

/// One connection, one instance and the pending messages to replay to it.
type MovedPrimary = (String, u64, Replay);

/// Result of `agent.attach`: the reply, then the pending requests to replay.
type AttachOutcome = (Value, Replay);

/// A method error: code and message.
type MethodError = (i64, String);

struct Instance {
    id: String,
    key: InstanceKey,
    pid: u32,
    started_at: u64,
    control: ProcControl,
    exited: Arc<Exited>,
    relay: Relay,
    /// Attached connections in attach order; the last one is the primary.
    attached: Vec<u64>,
}

impl Instance {
    fn primary(&self) -> Option<u64> {
        self.attached.last().copied()
    }
}

/// The hub task. Feed it through [`Command`] and runtime events.
pub struct Hub {
    commands: mpsc::Receiver<Command>,
    runtime_events: mpsc::UnboundedReceiver<RuntimeEvent>,
    runtime_sender: mpsc::UnboundedSender<RuntimeEvent>,
    events: mpsc::UnboundedSender<HubEvent>,
    stopped: Arc<Notify>,
    timeouts: StopTimeouts,
    conns: HashMap<u64, Outbox>,
    by_identity: HashMap<String, String>,
    instances: HashMap<String, Instance>,
    next_instance: u64,
    busy: bool,
    closing: bool,
}

impl Hub {
    pub fn new(
        commands: mpsc::Receiver<Command>,
        events: mpsc::UnboundedSender<HubEvent>,
        stopped: Arc<Notify>,
        timeouts: StopTimeouts,
    ) -> Self {
        let (runtime_sender, runtime_events) = mpsc::unbounded_channel::<RuntimeEvent>();
        Self {
            commands,
            runtime_events,
            runtime_sender,
            events,
            stopped,
            timeouts,
            conns: HashMap::new(),
            by_identity: HashMap::new(),
            instances: HashMap::new(),
            next_instance: 0,
            busy: false,
            closing: false,
        }
    }

    /// Run until every sender is gone (the server drops them on exit).
    pub async fn run(mut self) {
        loop {
            tokio::select! {
                command = self.commands.recv() => {
                    let Some(command) = command else { return };
                    self.handle_command(command);
                }
                event = self.runtime_events.recv() => {
                    let Some(event) = event else { return };
                    self.handle_runtime(event);
                }
            }
        }
    }

    fn handle_command(&mut self, command: Command) {
        match command {
            Command::Register { conn, outbox } => {
                self.conns.insert(conn, outbox);
            }
            Command::Disconnected { conn } => {
                self.conns.remove(&conn);
                self.detach_everywhere(conn);
            }
            Command::Frame { conn, frame } => {
                if self.closing {
                    self.reject_while_closing(conn, &frame);
                    return;
                }
                self.handle_frame(conn, frame);
            }
            Command::Shutdown => {
                if self.closing {
                    return;
                }
                self.closing = true;
                let instances: Vec<(String, ProcControl, Arc<Exited>)> = self
                    .instances
                    .iter()
                    .map(|(id, instance)| {
                        (
                            id.clone(),
                            instance.control.clone(),
                            Arc::clone(&instance.exited),
                        )
                    })
                    .collect();
                let timeouts = self.timeouts;
                let stopped = Arc::clone(&self.stopped);
                tokio::spawn(async move {
                    Self::stop_all(instances, timeouts).await;
                    stopped.notify_waiters();
                });
            }
        }
    }

    /// While the service is stopping, no new work is accepted.
    fn reject_while_closing(&self, conn: u64, frame: &Value) {
        let Some(object) = frame.as_object() else {
            return;
        };
        let id = object.get("id").cloned();
        match object.get("method").and_then(Value::as_str) {
            Some("tunnel.send") => {
                let instance = object
                    .get("params")
                    .and_then(|params| params.get("instance"))
                    .and_then(Value::as_str)
                    .unwrap_or_default();
                self.send_tunnel_error(
                    conn,
                    instance,
                    FRAME_REJECTED,
                    "the service is shutting down",
                    id,
                );
            }
            Some(_) => {
                if let Some(id) = id {
                    self.send_to(
                        conn,
                        &failure(&id, SPAWN_FAILED, "the service is shutting down"),
                    );
                }
            }
            None => {}
        }
    }

    async fn stop_all(instances: Vec<(String, ProcControl, Arc<Exited>)>, timeouts: StopTimeouts) {
        let mut tasks = Vec::with_capacity(instances.len());
        for (id, control, exited) in instances {
            tasks.push(tokio::spawn(async move {
                control.stop(false, timeouts).await;
                let patience = timeouts.after_stdin + timeouts.after_term + Duration::from_secs(5);
                match exited.wait(patience).await {
                    Some(info) => eprintln!(
                        "nvim_ade_server: stopped agent instance {id} (code {:?}, signal {:?})",
                        info.code, info.signal
                    ),
                    None => eprintln!("nvim_ade_server: agent instance {id} did not exit in time"),
                }
            }));
        }
        for task in tasks {
            let _ = task.await;
        }
    }

    fn handle_frame(&mut self, conn: u64, frame: Value) {
        let Some(object) = frame.as_object() else {
            self.send_to(
                conn,
                &failure(&Value::Null, INVALID_REQUEST, "invalid request"),
            );
            return;
        };
        let Some(method) = object.get("method").and_then(Value::as_str) else {
            // A response sent to the service has no meaning; it is only valid
            // inside `tunnel.send`.
            if object.get("id").is_some() {
                self.send_to(
                    conn,
                    &failure(&request_id(&frame), INVALID_PARAMS, "invalid request"),
                );
            }
            return;
        };
        let method = method.to_string();
        let params = object.get("params").cloned().unwrap_or(Value::Null);
        let id = request_id(&frame);
        let is_request = object.get("id").is_some();

        match method.as_str() {
            "agent.attach" => match self.attach(conn, &params) {
                Ok((result, replay)) => {
                    let instance = result["instance"].as_str().unwrap_or_default().to_string();
                    if is_request {
                        self.send_to(conn, &success(&id, result));
                    }
                    for (seq, message) in replay {
                        self.send_tunnel_recv(conn, &instance, seq, &message);
                    }
                }
                Err((code, message)) => {
                    if is_request {
                        self.send_to(conn, &failure(&id, code, &message));
                    }
                }
            },
            "agent.detach" => match self.detach(conn, &params) {
                Ok(()) => {
                    if is_request {
                        self.send_to(conn, &success(&id, json!({})));
                    }
                }
                Err((code, message)) => {
                    if is_request {
                        self.send_to(conn, &failure(&id, code, &message));
                    }
                }
            },
            "agent.stop" => self.agent_stop(conn, &params, &id, is_request),
            "agent.list" => {
                if is_request {
                    let instances: Vec<Value> =
                        self.instances.values().map(instance_summary).collect();
                    self.send_to(conn, &success(&id, json!({ "instances": instances })));
                }
            }
            "tunnel.send" => self.tunnel_send(conn, &params),
            _ => {
                if is_request {
                    self.send_to(conn, &failure(&id, METHOD_NOT_FOUND, "method not found"));
                }
            }
        }
    }

    /// Attach `conn` to the instance for `params`. Returns the reply and the
    /// pending requests to replay; the caller sends the reply first, so the
    /// front end has the instance id before the replayed notifications.
    fn attach(&mut self, conn: u64, params: &Value) -> Result<AttachOutcome, MethodError> {
        let key = InstanceKey::from_params(params)
            .map_err(|error| (INVALID_PARAMS, error.to_string()))?;
        let env = parse_env(params).map_err(|error| (INVALID_PARAMS, error.to_string()))?;

        let identity = key.identity();
        let (instance_id, created) = match self.by_identity.get(&identity).cloned() {
            Some(instance_id) => (instance_id, false),
            None => (
                self.spawn(identity, key, env)
                    .map_err(|error| (SPAWN_FAILED, error))?,
                true,
            ),
        };

        let Some(instance) = self.instances.get_mut(&instance_id) else {
            return Err((UNKNOWN_INSTANCE, "unknown instance".to_string()));
        };
        // Only a connection that was not attached yet gets the pending set
        // replayed. A connection attaching again already knows those requests;
        // replaying them would make the front end show a second permission
        // prompt for the same agent request.
        let was_attached = instance.attached.contains(&conn);
        touch_attached(&mut instance.attached, conn);
        let attached = instance.attached.len();
        let initialized = instance.relay.initialized();
        let pid = instance.pid;

        // A connection that attaches becomes primary and receives the whole
        // pending set, in arrival order (PROTOCOL.md 5.4). Replaying does not
        // remove them: they stay pending until answered, and each keeps the
        // `seq` it was first delivered with.
        let replay = attach_replay(was_attached, instance.relay.pending_messages());
        self.update_busy();
        Ok((
            json!({
                "instance": instance_id,
                "created": created,
                "pid": pid,
                "initialized": initialized,
                "attached": attached,
            }),
            replay,
        ))
    }

    fn spawn(
        &mut self,
        identity: String,
        key: InstanceKey,
        env: Option<Vec<(String, String)>>,
    ) -> Result<String, String> {
        self.next_instance += 1;
        let instance_id = format!("i{}", self.next_instance);
        let spec = SpawnSpec {
            command: key.command.clone(),
            args: key.args.clone(),
            cwd: key.cwd.clone().into(),
            env,
        };
        let exited = Exited::new();
        let started = runtime::start(
            instance_id.clone(),
            spec,
            self.timeouts,
            self.runtime_sender.clone(),
            Arc::clone(&exited),
        )
        .map_err(|error| error.to_string())?;

        eprintln!(
            "nvim_ade_server: spawned agent instance {instance_id} (pid {})",
            started.pid
        );
        self.by_identity.insert(identity, instance_id.clone());
        self.instances.insert(
            instance_id.clone(),
            Instance {
                id: instance_id.clone(),
                key: key.clone(),
                pid: started.pid,
                started_at: now_ms(),
                control: started.control,
                exited,
                relay: Relay::new(key.capabilities),
                attached: Vec::new(),
            },
        );
        Ok(instance_id)
    }

    fn detach(&mut self, conn: u64, params: &Value) -> Result<(), MethodError> {
        let Some(instance_id) = params.get("instance").and_then(Value::as_str) else {
            return Err((INVALID_PARAMS, "instance is required".to_string()));
        };
        let Some(instance) = self.instances.get_mut(instance_id) else {
            return Err((UNKNOWN_INSTANCE, "unknown instance".to_string()));
        };
        instance.attached.retain(|attached| *attached != conn);
        // A new primary (if any) receives the pending requests again. They
        // stay pending until answered, keeping their original `seq`.
        let replay = instance.relay.pending_messages();
        let primary = instance.primary();
        let instance_id = instance_id.to_string();
        if let Some(primary) = primary {
            for (seq, message) in replay {
                self.send_tunnel_recv(primary, &instance_id, seq, &message);
            }
        }
        self.update_busy();
        Ok(())
    }

    fn agent_stop(&mut self, conn: u64, params: &Value, id: &Value, is_request: bool) {
        let Some(instance_id) = params.get("instance").and_then(Value::as_str) else {
            if is_request {
                self.send_to(conn, &failure(id, INVALID_PARAMS, "instance is required"));
            }
            return;
        };
        let Some(instance) = self.instances.get(instance_id) else {
            if is_request {
                self.send_to(conn, &failure(id, UNKNOWN_INSTANCE, "unknown instance"));
            }
            return;
        };
        let control = instance.control.clone();
        let exited = Arc::clone(&instance.exited);
        let force = params
            .get("force")
            .and_then(Value::as_bool)
            .unwrap_or(false);
        let timeouts = self.timeouts;
        let outbox = self.conns.get(&conn).cloned();
        let id = id.clone();
        let name = instance_id.to_string();
        // The reply is sent after the process exited, so the wait happens off
        // the hub loop (it can take seconds).
        tokio::spawn(async move {
            control.stop(force, timeouts).await;
            let patience = if force {
                Duration::from_secs(10)
            } else {
                timeouts.after_stdin + timeouts.after_term + Duration::from_secs(5)
            };
            let info = exited.wait(patience).await.unwrap_or_default();
            if is_request {
                if let Some(outbox) = outbox {
                    outbox.send(&success(
                        &id,
                        json!({
                            "exited": true,
                            "code": info.code,
                            "signal": info.signal,
                        }),
                    ));
                }
            }
            eprintln!("nvim_ade_server: agent.stop finished for {name}");
        });
    }

    fn detach_everywhere(&mut self, conn: u64) {
        let mut moved: Vec<MovedPrimary> = Vec::new();
        for instance in self.instances.values_mut() {
            if !instance.attached.contains(&conn) {
                continue;
            }
            instance.attached.retain(|attached| *attached != conn);
            let Some(primary) = instance.primary() else {
                continue;
            };
            // The pending set stays pending; the new primary receives it again.
            moved.push((
                instance.id.clone(),
                primary,
                instance.relay.pending_messages(),
            ));
        }
        for (instance_id, primary, replay) in moved {
            for (seq, message) in replay {
                self.send_tunnel_recv(primary, &instance_id, seq, &message);
            }
            eprintln!(
                "nvim_ade_server: instance {instance_id} primary is now connection {primary}"
            );
        }
        self.update_busy();
    }

    fn tunnel_send(&mut self, conn: u64, params: &Value) {
        let instance_param = params.get("instance").and_then(Value::as_str);
        let message = params.get("message").cloned();
        let message_id = message
            .as_ref()
            .and_then(|message| message.get("id"))
            .cloned();
        let instance = instance_param.unwrap_or_default();

        if message.is_none() {
            self.send_tunnel_error(
                conn,
                instance,
                FRAME_REJECTED,
                "tunnel.send needs a message",
                message_id,
            );
            return;
        }
        let Some(instance_id) = instance_param else {
            self.send_tunnel_error(
                conn,
                "",
                FRAME_REJECTED,
                "tunnel.send needs an instance",
                message_id,
            );
            return;
        };
        let Some(message) = message else {
            return;
        };
        let Some(handle) = self.instances.get(instance_id) else {
            self.send_tunnel_error(
                conn,
                instance_id,
                UNKNOWN_INSTANCE,
                "unknown instance",
                message_id,
            );
            return;
        };
        if !handle.attached.contains(&conn) {
            self.send_tunnel_error(
                conn,
                instance_id,
                NOT_ATTACHED,
                "connection not attached to the instance",
                message_id,
            );
            return;
        }
        let Some(object) = message.as_object() else {
            self.send_tunnel_error(
                conn,
                instance_id,
                FRAME_REJECTED,
                "message must be a JSON object",
                message_id,
            );
            return;
        };
        if object.get("method").is_none() && object.get("id").is_none() {
            self.send_tunnel_error(
                conn,
                instance_id,
                FRAME_REJECTED,
                "message is neither a request, a notification nor a response",
                message_id,
            );
            return;
        }

        let action = {
            let handle = self.instances.get_mut(instance_id).expect("checked above");
            handle.relay.frontend_message(conn, &message)
        };
        match action {
            FrontendAction::Forward(frame) => {
                let handle = self.instances.get(instance_id).expect("checked above");
                if !handle.control.send_frame(frame) {
                    self.send_tunnel_error(
                        conn,
                        instance_id,
                        FRAME_REJECTED,
                        "the agent is not accepting messages",
                        message_id,
                    );
                }
            }
            FrontendAction::Reply(response, seq) => {
                // A local answer carries the seq of the agent message it is
                // derived from (the cached `initialize` result).
                self.send_tunnel_recv(conn, instance_id, seq, &response);
            }
            FrontendAction::Drop => {}
        }
        self.update_busy();
    }

    fn handle_runtime(&mut self, event: RuntimeEvent) {
        match event {
            RuntimeEvent::Stdout { instance, text } => self.agent_line(&instance, &text),
            RuntimeEvent::StdoutTooLong { instance } => {
                let attached = match self.instances.get(&instance) {
                    Some(handle) => handle.attached.clone(),
                    None => return,
                };
                for conn in attached {
                    self.send_tunnel_error(
                        conn,
                        &instance,
                        FRAME_REJECTED,
                        "agent message exceeded the maximum line length",
                        None,
                    );
                }
            }
            RuntimeEvent::Exited { instance } => self.instance_exited(&instance),
        }
        self.update_busy();
    }

    fn agent_line(&mut self, instance_id: &str, text: &str) {
        let Ok(value) = serde_json::from_str::<Value>(text) else {
            eprintln!(
                "nvim_ade_server: agent {instance_id} wrote a line that is not JSON; dropped"
            );
            return;
        };
        if !value.is_object() {
            eprintln!(
                "nvim_ade_server: agent {instance_id} wrote a JSON value that is not an object; dropped"
            );
            return;
        }
        let Some(instance) = self.instances.get_mut(instance_id) else {
            return;
        };
        let attached = instance.attached.clone();
        let action = instance.relay.agent_message(&value, &attached);
        match action {
            AgentAction::Response { conn, seq, message } => {
                self.send_tunnel_recv(conn, instance_id, seq, &message);
            }
            AgentAction::Notification { seq, message } => {
                for conn in attached {
                    self.send_tunnel_recv(conn, instance_id, seq, &message);
                }
            }
            AgentAction::Request {
                seq,
                message,
                target: Some(conn),
            } => {
                self.send_tunnel_recv(conn, instance_id, seq, &message);
            }
            // No attached connection: the request stays in the pending set.
            AgentAction::Request { target: None, .. } => {}
            AgentAction::Drop => {}
            AgentAction::Invalid => {
                eprintln!(
                    "nvim_ade_server: agent {instance_id} wrote a frame that cannot be relayed; dropped"
                );
            }
        }
    }

    fn instance_exited(&mut self, instance_id: &str) {
        let Some(instance) = self.instances.remove(instance_id) else {
            return;
        };
        self.by_identity.remove(&instance.key.identity());
        let info = instance.exited.get().unwrap_or_default();
        for conn in &instance.attached {
            self.send_to(
                *conn,
                &json!({
                    "jsonrpc": "2.0",
                    "method": "agent.exited",
                    "params": {
                        "instance": instance_id,
                        "code": info.code,
                        "signal": info.signal,
                        "stderr_tail": info.stderr_tail,
                    },
                }),
            );
        }
        eprintln!(
            "nvim_ade_server: agent instance {instance_id} exited (code {:?}, signal {:?})",
            info.code, info.signal
        );
    }

    fn update_busy(&mut self) {
        let busy = self.instances.values().any(|instance| {
            instance.relay.turns_running() > 0 || instance.relay.pending_requests() > 0
        });
        if busy != self.busy {
            self.busy = busy;
            let _ = self.events.send(HubEvent::Busy(busy));
        }
    }

    fn send_to(&self, conn: u64, value: &Value) {
        if let Some(outbox) = self.conns.get(&conn) {
            outbox.send(value);
        }
    }

    fn send_tunnel_recv(&self, conn: u64, instance: &str, seq: u64, message: &Value) {
        self.send_to(
            conn,
            &json!({
                "jsonrpc": "2.0",
                "method": "tunnel.recv",
                "params": {
                    "instance": instance,
                    "seq": seq,
                    "message": message,
                },
            }),
        );
    }

    fn send_tunnel_error(
        &self,
        conn: u64,
        instance: &str,
        code: i64,
        message: &str,
        id: Option<Value>,
    ) {
        let mut params = json!({
            "instance": instance,
            "code": code,
            "message": message,
        });
        if let Some(id) = id {
            params["id"] = id;
        }
        self.send_to(
            conn,
            &json!({
                "jsonrpc": "2.0",
                "method": "tunnel.error",
                "params": params,
            }),
        );
    }
}

/// What to replay to a connection that just called `agent.attach`.
///
/// A connection that was already attached has seen these requests; replaying
/// them would make the front end ask the same permission question twice.
fn attach_replay(was_attached: bool, pending: Replay) -> Replay {
    if was_attached {
        Vec::new()
    } else {
        pending
    }
}

/// Record that `conn` is attached now. Re-attaching moves the connection to
/// the end, so the most recently attached connection stays primary
/// (PROTOCOL.md 5.3).
fn touch_attached(attached: &mut Vec<u64>, conn: u64) {
    attached.retain(|existing| *existing != conn);
    attached.push(conn);
}

fn request_id(frame: &Value) -> Value {
    frame.get("id").cloned().unwrap_or(Value::Null)
}

fn instance_summary(instance: &Instance) -> Value {
    json!({
        "instance": instance.id,
        "agent": instance.key.agent,
        "command": instance.key.command,
        "args": instance.key.args,
        "cwd": instance.key.cwd,
        "pid": instance.pid,
        "started_at": instance.started_at,
        "initialized": instance.relay.initialized(),
        "attached": instance.attached.len(),
        "turns_running": instance.relay.turns_running(),
        "pending_requests": instance.relay.pending_requests(),
    })
}

fn now_ms() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|elapsed| elapsed.as_millis() as u64)
        .unwrap_or(0)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn outbox(limit: usize) -> (Outbox, OutboxReceiver) {
        let (closer, _watch) = watch::channel(false);
        Outbox::with_limit(closer, limit)
    }

    #[tokio::test]
    async fn outbox_queues_frames_in_order() {
        let (outbox, mut receiver) = outbox(1024);
        assert!(outbox.send(&json!({"a": 1})));
        assert!(outbox.send(&json!({"b": 2})));
        assert!(!outbox.is_empty());
        assert_eq!(receiver.recv().await.unwrap(), b"{\"a\":1}\n");
        assert_eq!(receiver.recv().await.unwrap(), b"{\"b\":2}\n");
        assert!(outbox.is_empty());
    }

    #[test]
    fn outbox_closes_the_connection_when_the_limit_is_exceeded() {
        let (closer, watch) = watch::channel(false);
        let (outbox, _receiver) = Outbox::with_limit(closer, 8);
        assert!(outbox.send(&json!({"a": 1})));
        // This frame pushes the queue over the 8-byte limit.
        assert!(!outbox.send(&json!({"bb": 2})));
        assert!(*watch.borrow());
    }

    #[test]
    fn only_a_newly_attached_connection_gets_the_pending_set() {
        let pending: Replay = vec![
            (
                1,
                json!({"jsonrpc": "2.0", "id": 9001, "method": "session/request_permission"}),
            ),
            (
                2,
                json!({"jsonrpc": "2.0", "id": 9002, "method": "elicitation/create"}),
            ),
        ];
        assert_eq!(attach_replay(false, pending.clone()), pending);
        assert!(
            attach_replay(true, pending).is_empty(),
            "re-attaching must not replay pending requests"
        );
    }

    #[test]
    fn re_attaching_moves_the_connection_to_the_primary_position() {
        let mut attached = Vec::new();
        touch_attached(&mut attached, 1);
        touch_attached(&mut attached, 2);
        assert_eq!(attached, vec![1, 2]);
        // Attaching again makes connection 1 the most recent one.
        touch_attached(&mut attached, 1);
        assert_eq!(attached, vec![2, 1]);
        assert_eq!(attached.len(), 2, "a connection is attached only once");
    }

    #[test]
    fn instance_summary_has_every_documented_field() {
        let instance = Instance {
            id: "i1".to_string(),
            key: InstanceKey {
                agent: "claude".to_string(),
                command: "claude-agent-acp".to_string(),
                args: vec!["--acp".to_string()],
                cwd: "/tmp/p".to_string(),
                capabilities: json!({}),
            },
            pid: 42,
            started_at: 1234,
            control: ProcControl::dummy(42),
            exited: Exited::new(),
            relay: Relay::new(json!({})),
            attached: vec![1, 2],
        };
        let summary = instance_summary(&instance);
        for field in [
            "instance",
            "agent",
            "command",
            "args",
            "cwd",
            "pid",
            "started_at",
            "initialized",
            "attached",
            "turns_running",
            "pending_requests",
        ] {
            assert!(summary.get(field).is_some(), "missing {field}");
        }
        assert_eq!(summary["attached"], 2);
        assert_eq!(summary["turns_running"], 0);
        assert_eq!(summary["pending_requests"], 0);
    }
}
