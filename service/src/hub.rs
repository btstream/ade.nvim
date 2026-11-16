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

#[cfg(unix)]
use crate::install::{self, lock as install_lock, store as install_store, Progress};
use crate::policy::{self, Policy};
use crate::protocol::{
    failure, success, FRAME_REJECTED, INVALID_PARAMS, INVALID_REQUEST, METHOD_NOT_FOUND,
    NOT_ATTACHED, SPAWN_FAILED, UNKNOWN_INSTANCE,
};
use crate::recorder::{RecordedEvent, Recorder};
use crate::relay::{
    parse_env, AgentAction, FrontendAction, InstanceKey, LoadCandidate, PendingEvent, Relay,
    Retracted,
};
use crate::runtime::{self, Exited, ProcControl, RuntimeEvent, SpawnSpec, StopTimeouts};
use crate::store::EventKind;

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

    /// Ask the connection's own task to close it (back pressure, or a replay
    /// buffer that overflowed).
    pub fn close(&self) {
        let _ = self.closer.send(true);
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
    /// Every instance stopped during shutdown: the hub can end its loop.
    Stopped,
    /// The stop sequence of one instance finished; reply once the hub has
    /// removed the instance, so `agent.list` right after the reply cannot show
    /// it any more (PROTOCOL.md 3.4).
    StopFinished {
        conn: u64,
        instance: String,
        id: Option<Value>,
        code: Option<i32>,
        signal: Option<String>,
    },
}

/// Events from the hub to the server loop.
#[derive(Debug, PartialEq, Eq)]
pub enum HubEvent {
    /// Whether any instance has a running turn or a pending request.
    Busy(bool),
}

/// Install work running outside the hub loop (16.3).
#[cfg(unix)]
#[derive(Debug)]
pub enum InstallEvent {
    /// One `install.progress` payload, sent to every connection.
    Progress(Value),
    /// The request finished; the hub answers its connection.
    Done {
        key: String,
        conn: u64,
        request_id: Value,
        outcome: install::Outcome,
    },
}

/// One install job (or resolve request) the hub can cancel.
#[cfg(unix)]
struct InstallJob {
    agent: String,
    /// `"run"`, `"uninstall"` or `"resolve"`.
    kind: &'static str,
    cancel: watch::Sender<bool>,
    handle: tokio::task::JoinHandle<()>,
}

/// A `tunnel.recv` held back while a replay is read (PROTOCOL.md 12).
#[derive(Debug, Clone)]
struct GateEntry {
    instance: String,
    seq: u64,
    message: Value,
}

/// The buffered live traffic of one connection that is waiting for a replay.
///
/// Counted in bytes (the JSON text of each message) and capped like the
/// outbound queue: past the cap the connection is closed, never silently
/// thinned out (PROTOCOL.md 7 and 12).
#[derive(Debug)]
struct Gate {
    entries: Vec<GateEntry>,
    bytes: usize,
    limit: usize,
}

impl Gate {
    fn new(limit: usize) -> Self {
        Self {
            entries: Vec::new(),
            bytes: 0,
            limit,
        }
    }

    /// Buffer one message. `Err` means the cap was exceeded: the caller closes
    /// the connection and cancels the replay.
    fn push(&mut self, entry: GateEntry) -> Result<(), ()> {
        let size = entry.message.to_string().len() + entry.instance.len() + 64;
        if self.bytes.saturating_add(size) > self.limit {
            return Err(());
        }
        self.bytes += size;
        self.entries.push(entry);
        Ok(())
    }

    fn take(&mut self) -> Vec<GateEntry> {
        self.bytes = 0;
        std::mem::take(&mut self.entries)
    }
}

/// Default cap for a connection waiting for a replay: the outbound queue's
/// 64 MiB, so the replay plus what it buffered still fits one connection.
pub const MAX_GATE_BYTES: usize = 64 * 1024 * 1024;

/// Default ceiling for emulating `session/load`: above this many log bytes the
/// request is forwarded instead, so a replay always fits the outbound queue
/// (PROTOCOL.md 12).
pub const MAX_REPLAY_LOG_BYTES: u64 = 32 * 1024 * 1024;

/// Environment variable overriding [`MAX_GATE_BYTES`] (tests).
pub const GATE_LIMIT_ENV: &str = "NVIM_ADE_SERVER_GATE_LIMIT_BYTES";
/// Environment variable overriding [`MAX_REPLAY_LOG_BYTES`] (tests).
pub const REPLAY_LIMIT_ENV: &str = "NVIM_ADE_SERVER_REPLAY_LIMIT_BYTES";
/// Test hook: delay the replay by this many milliseconds, so live traffic
/// arrives while the gate is closed (PROTOCOL.md 12 has no such knob).
pub const REPLAY_DELAY_ENV: &str = "NVIM_ADE_SERVER_REPLAY_DELAY_MS";

/// The two bounds of section 12, plus the test-only replay delay.
#[derive(Debug, Clone, Copy)]
pub struct Limits {
    pub gate_bytes: usize,
    pub replay_bytes: u64,
    pub replay_delay: Duration,
}

impl Default for Limits {
    fn default() -> Self {
        Self {
            gate_bytes: MAX_GATE_BYTES,
            replay_bytes: MAX_REPLAY_LOG_BYTES,
            replay_delay: Duration::ZERO,
        }
    }
}

impl Limits {
    /// Read the environment overrides; unset or invalid values keep the default.
    pub fn from_env() -> Self {
        Self::from_lookup(|key| std::env::var(key).ok())
    }

    pub fn from_lookup<F>(lookup: F) -> Self
    where
        F: Fn(&str) -> Option<String>,
    {
        let mut limits = Self::default();
        if let Some(value) = lookup(GATE_LIMIT_ENV).and_then(|v| v.trim().parse().ok()) {
            limits.gate_bytes = value;
        }
        if let Some(value) = lookup(REPLAY_LIMIT_ENV).and_then(|v| v.trim().parse().ok()) {
            limits.replay_bytes = value;
        }
        if let Some(value) = lookup(REPLAY_DELAY_ENV).and_then(|v| v.trim().parse().ok()) {
            limits.replay_delay = Duration::from_millis(value);
        }
        limits
    }
}

/// Outcome of reading the log for an emulated `session/load`.
#[derive(Debug)]
enum LoadResult {
    /// Replay these messages, then answer with `state`, then release the gate.
    Replay {
        conn: u64,
        instance: String,
        messages: Vec<(u64, Value)>,
        state: Value,
        frontend_id: Value,
        session_id: String,
    },
    /// The log cannot answer the load: forward the original request.
    Forward {
        conn: u64,
        instance: String,
        frame: Value,
    },
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
    /// True once `agent.stop` was accepted; the instance stays reachable by id
    /// until the process exits (PROTOCOL.md 3.4).
    stopping: bool,
    /// Lease for a managed release this instance runs (PROTOCOL.md 16.4).
    #[cfg(unix)]
    _lease: Option<install_lock::ReleaseLease>,
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
    /// Whether the event log is on: affects `hello.features`, session tracking
    /// and `agent.attach` (PROTOCOL.md 10 and 12).
    event_log: bool,
    /// Per-instance event log cap in MiB (`--event-log-max-mb`).
    event_log_max_mb: u64,
    /// The event log (PROTOCOL.md 10).
    recorder: Recorder,
    /// Connections whose `tunnel.recv` is buffered while a replay is read, so
    /// the replay and the live stream have no gap and no duplicate
    /// (PROTOCOL.md 12). Keyed by connection.
    gates: HashMap<u64, Gate>,
    /// Bounds of section 12: the gate cap, the replay ceiling and the
    /// test-only replay delay.
    limits: Limits,
    /// Load tasks report here; the hub stays the only state owner.
    load_sender: mpsc::UnboundedSender<LoadResult>,
    /// Replies to `agent.stop` whose instance has not been removed yet.
    pending_stop_replies: HashMap<String, Vec<(u64, Value)>>,
    /// The hub's own command sender, so spawned tasks can report back.
    command_sender: mpsc::Sender<Command>,
    /// Set when the shutdown sequence completed; the run loop then ends.
    finished: bool,
    load_results: mpsc::UnboundedReceiver<LoadResult>,
    /// Install jobs and the requests they answer (PROTOCOL.md 16.3).
    #[cfg(unix)]
    install_jobs: HashMap<String, InstallJob>,
    /// `(connection, serialized request id)` -> job key, for `$/cancel_request`.
    #[cfg(unix)]
    install_requests: HashMap<(u64, String), String>,
    #[cfg(unix)]
    install_events: mpsc::UnboundedReceiver<InstallEvent>,
    #[cfg(unix)]
    install_event_sender: mpsc::UnboundedSender<InstallEvent>,
    /// Permission rules installed by front ends (PROTOCOL.md 17).
    policy: Policy,
}

impl Hub {
    pub fn new(
        commands: mpsc::Receiver<Command>,
        command_sender: mpsc::Sender<Command>,
        events: mpsc::UnboundedSender<HubEvent>,
        stopped: Arc<Notify>,
        timeouts: StopTimeouts,
    ) -> Self {
        let (runtime_sender, runtime_events) = mpsc::unbounded_channel::<RuntimeEvent>();
        let (load_sender, load_results) = mpsc::unbounded_channel::<LoadResult>();
        #[cfg(unix)]
        let (install_event_sender, install_events) = mpsc::unbounded_channel::<InstallEvent>();
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
            event_log: true,
            event_log_max_mb: crate::server::DEFAULT_EVENT_LOG_MAX_MB,
            recorder: Recorder::disabled(),
            gates: HashMap::new(),
            limits: Limits::default(),
            load_sender,
            load_results,
            pending_stop_replies: HashMap::new(),
            command_sender,
            finished: false,
            #[cfg(unix)]
            install_jobs: HashMap::new(),
            #[cfg(unix)]
            install_requests: HashMap::new(),
            #[cfg(unix)]
            install_events,
            #[cfg(unix)]
            install_event_sender,
            policy: Policy::new(),
        }
    }

    /// Override the section 12 bounds (tests, or a future flag).
    pub fn with_limits(mut self, limits: Limits) -> Self {
        self.limits = limits;
        self
    }

    /// Apply the `--event-log` / `--event-log-max-mb` flags (PROTOCOL.md 15)
    /// and install the recorder.
    pub fn with_event_log(mut self, enabled: bool, max_mb: u64, recorder: Recorder) -> Self {
        self.event_log = enabled;
        self.event_log_max_mb = max_mb;
        self.recorder = recorder;
        self
    }

    /// Run until every sender is gone (the server drops them on exit).
    pub async fn run(mut self) {
        // Held locally so the select arm borrows this receiver, not `self`
        // (handler bodies take `&mut self`).
        #[cfg(unix)]
        let mut install_events =
            std::mem::replace(&mut self.install_events, mpsc::unbounded_channel().1);
        loop {
            #[cfg(unix)]
            let install_event = install_events.recv();
            #[cfg(not(unix))]
            let install_event = std::future::pending::<Option<()>>();
            tokio::select! {
                command = self.commands.recv() => {
                    let Some(command) = command else { return };
                    self.handle_command(command);
                    if self.finished {
                        return;
                    }
                }
                event = self.runtime_events.recv() => {
                    let Some(event) = event else { return };
                    self.handle_runtime(event);
                }
                result = self.load_results.recv() => {
                    let Some(result) = result else { return };
                    self.finish_load(result);
                    self.update_busy();
                }
                event = install_event => {
                    #[cfg(unix)]
                    match event {
                        Some(event) => self.handle_install_event(event),
                        None => return,
                    }
                    #[cfg(not(unix))]
                    {
                        let _ = event;
                    }
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
                // A connection that vanishes during a replay must not leave a
                // gate behind (nothing would ever release it).
                self.gates.remove(&conn);
                // The install job keeps running (16.3); only its cancel handle
                // disappears with the connection.
                #[cfg(unix)]
                self.install_requests.retain(|(owner, _), _| *owner != conn);
                self.policy.connection_closed(conn);
                self.detach_everywhere(conn);
            }
            Command::Frame { conn, frame } => {
                if self.closing {
                    self.reject_while_closing(conn, &frame);
                    return;
                }
                self.handle_frame(conn, frame);
            }
            Command::Stopped => {
                self.finished = true;
            }
            Command::StopFinished {
                conn,
                instance,
                id,
                code,
                signal,
            } => {
                // Still present means its exit event has not been processed
                // yet: remember the reply and send it from `instance_exited`.
                if self.instances.contains_key(&instance) {
                    if let Some(id) = id {
                        self.pending_stop_replies
                            .entry(instance)
                            .or_default()
                            .push((conn, id));
                    }
                } else if let Some(id) = id {
                    self.send_to(
                        conn,
                        &success(&id, json!({"exited": true, "code": code, "signal": signal})),
                    );
                }
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
                let sender = self.command_sender.clone();
                #[cfg(unix)]
                let mut jobs: Vec<tokio::task::JoinHandle<()>> = Vec::new();
                #[cfg(unix)]
                {
                    for (_, job) in self.install_jobs.drain() {
                        let _ = job.cancel.send(true);
                        jobs.push(job.handle);
                    }
                    self.install_requests.clear();
                }
                tokio::spawn(async move {
                    // `shutdown` cancels every job first and waits for it, so a
                    // half-built release is gone before the process exits (16.3).
                    #[cfg(unix)]
                    for job in jobs {
                        let _ = job.await;
                    }
                    Self::stop_all(instances, timeouts).await;
                    stopped.notify_waiters();
                    // The hub holds a sender of its own, so it must be told to
                    // end its loop explicitly.
                    let _ = sender.send(Command::Stopped).await;
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
                    self.replay_pending(conn, &instance, replay);
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
                    let instances: Vec<Value> = self
                        .instances
                        .values()
                        .map(|instance| {
                            instance_summary(instance, self.log_bytes(&instance.key.identity()))
                        })
                        .collect();
                    self.send_to(conn, &success(&id, json!({ "instances": instances })));
                }
            }
            "tunnel.send" => self.tunnel_send(conn, &params),
            "policy.set" => {
                if is_request {
                    self.policy_set(conn, &id, &params);
                }
            }
            "policy.clear" => {
                if is_request {
                    self.policy_clear(conn, &id, &params);
                }
            }
            "policy.list" => {
                if is_request {
                    self.send_to(conn, &success(&id, json!({ "sets": self.policy.list() })));
                }
            }
            _ => {
                #[cfg(unix)]
                if self.handle_install(conn, &method, &params, &id, is_request) {
                    return;
                }
                if is_request {
                    self.send_to(conn, &failure(&id, METHOD_NOT_FOUND, "method not found"));
                }
            }
        }
    }

    /// Dispatch the `install.*` methods and cancellation (16.3).
    ///
    /// Returns whether the method belonged to this module. The work itself runs
    /// in a task; the hub keeps answering other requests meanwhile.
    #[cfg(unix)]
    fn handle_install(
        &mut self,
        conn: u64,
        method: &str,
        params: &Value,
        id: &Value,
        is_request: bool,
    ) -> bool {
        match method {
            "install.resolve" => {
                if is_request {
                    self.start_resolve(conn, id, params);
                }
                true
            }
            "install.run" => {
                if is_request {
                    self.start_run(conn, id, params);
                }
                true
            }
            "install.uninstall" => {
                if is_request {
                    self.start_uninstall(conn, id, params);
                }
                true
            }
            "$/cancel_request" => {
                if !is_request {
                    self.cancel_install(conn, params);
                }
                true
            }
            _ => false,
        }
    }

    #[cfg(unix)]
    fn install_error(&self, conn: u64, id: &Value, code: i64, message: &str) {
        self.send_to(conn, &failure(id, code, message));
    }

    /// Broadcast one terminal `install.progress` for an early refusal.
    #[cfg(unix)]
    fn install_terminal(
        &self,
        job: &str,
        agent: &str,
        action: &str,
        phase: &str,
        message: Option<&str>,
    ) {
        let mut params = json!({
            "job": job,
            "agent": agent,
            "action": action,
            "phase": phase,
        });
        if let Some(message) = message {
            params["message"] = json!(message);
        }
        self.broadcast_progress(params);
    }

    #[cfg(unix)]
    fn broadcast_progress(&self, params: Value) {
        let frame = json!({
            "jsonrpc": "2.0",
            "method": "install.progress",
            "params": params,
        });
        let conns: Vec<u64> = self.conns.keys().copied().collect();
        for conn in conns {
            self.send_to(conn, &frame);
        }
    }

    #[cfg(unix)]
    fn start_run(&mut self, conn: u64, id: &Value, params: &Value) {
        let request = match parse_run(params) {
            Ok(request) => request,
            Err(message) => {
                self.install_error(conn, id, install::INVALID_PARAMETER, &message);
                return;
            }
        };
        let key = format!("job:{}", request.job);
        if self.install_jobs.contains_key(&key) {
            self.install_error(
                conn,
                id,
                install::INVALID_PARAMETER,
                &format!("job {} is already running", request.job),
            );
            return;
        }
        if let Some(reason) = self.install_conflict(&request.agent) {
            self.install_terminal(
                &request.job,
                &request.agent,
                &request.action,
                "failed",
                Some(&reason),
            );
            self.send_to(
                conn,
                &install_failure(
                    id,
                    install::BUSY,
                    &reason,
                    Some(json!({ "reason": reason })),
                ),
            );
            return;
        }
        let (sender, receiver) = watch::channel(false);
        let progress_sender = self.install_event_sender.clone();
        let progress = Progress::new(move |value| {
            let _ = progress_sender.send(InstallEvent::Progress(value));
        });
        let events = self.install_event_sender.clone();
        let task_key = key.clone();
        let request_id = id.clone();
        let agent = request.agent.clone();
        let terminal_job = request.job.clone();
        let terminal_agent = request.agent.clone();
        let terminal_action = request.action.clone();
        let handle = tokio::spawn(async move {
            let inner =
                tokio::spawn(async move { install::run(request, receiver, &progress).await });
            let outcome = match inner.await {
                Ok(outcome) => outcome,
                Err(error) => {
                    let message = format!("the install job failed: {error}");
                    let _ = events.send(InstallEvent::Progress(json!({
                        "job": terminal_job,
                        "agent": terminal_agent,
                        "action": terminal_action,
                        "phase": "failed",
                        "message": message,
                    })));
                    install::Outcome::failed(install::INSTALL_FAILED, message)
                }
            };
            let _ = events.send(InstallEvent::Done {
                key: task_key,
                conn,
                request_id,
                outcome,
            });
        });
        self.install_jobs.insert(
            key.clone(),
            InstallJob {
                agent,
                kind: "run",
                cancel: sender,
                handle,
            },
        );
        self.install_requests.insert((conn, id_key(id)), key);
        self.update_busy();
    }

    #[cfg(unix)]
    fn start_uninstall(&mut self, conn: u64, id: &Value, params: &Value) {
        let request = match parse_uninstall(params) {
            Ok(request) => request,
            Err(message) => {
                self.install_error(conn, id, install::INVALID_PARAMETER, &message);
                return;
            }
        };
        let key = format!("job:{}", request.job);
        if self.install_jobs.contains_key(&key) {
            self.install_error(
                conn,
                id,
                install::INVALID_PARAMETER,
                &format!("job {} is already running", request.job),
            );
            return;
        }
        if let Some(reason) = self.install_conflict(&request.agent) {
            self.install_terminal(
                &request.job,
                &request.agent,
                "uninstall",
                "failed",
                Some(&reason),
            );
            self.send_to(
                conn,
                &install_failure(
                    id,
                    install::BUSY,
                    &reason,
                    Some(json!({ "reason": reason })),
                ),
            );
            return;
        }
        let (sender, receiver) = watch::channel(false);
        let progress_sender = self.install_event_sender.clone();
        let progress = Progress::new(move |value| {
            let _ = progress_sender.send(InstallEvent::Progress(value));
        });
        let events = self.install_event_sender.clone();
        let task_key = key.clone();
        let request_id = id.clone();
        let agent = request.agent.clone();
        let terminal_job = request.job.clone();
        let terminal_agent = request.agent.clone();
        let handle = tokio::spawn(async move {
            let inner =
                tokio::spawn(async move { install::uninstall(request, receiver, &progress).await });
            let outcome = match inner.await {
                Ok(outcome) => outcome,
                Err(error) => {
                    let message = format!("the uninstall job failed: {error}");
                    let _ = events.send(InstallEvent::Progress(json!({
                        "job": terminal_job,
                        "agent": terminal_agent,
                        "action": "uninstall",
                        "phase": "failed",
                        "message": message,
                    })));
                    install::Outcome::failed(install::INSTALL_FAILED, message)
                }
            };
            let _ = events.send(InstallEvent::Done {
                key: task_key,
                conn,
                request_id,
                outcome,
            });
        });
        self.install_jobs.insert(
            key.clone(),
            InstallJob {
                agent,
                kind: "uninstall",
                cancel: sender,
                handle,
            },
        );
        self.install_requests.insert((conn, id_key(id)), key);
        self.update_busy();
    }

    #[cfg(unix)]
    fn start_resolve(&mut self, conn: u64, id: &Value, params: &Value) {
        let request = match parse_resolve(params) {
            Ok(request) => request,
            Err(message) => {
                self.install_error(conn, id, install::INVALID_PARAMETER, &message);
                return;
            }
        };
        let key = format!("resolve:{conn}:{}", id_key(id));
        let (sender, receiver) = watch::channel(false);
        let events = self.install_event_sender.clone();
        let task_key = key.clone();
        let request_id = id.clone();
        let handle = tokio::spawn(async move {
            let inner = tokio::spawn(async move { install::resolve(request, receiver).await });
            let outcome = match inner.await {
                Ok(outcome) => outcome,
                Err(error) => install::Outcome::failed(
                    install::INSTALL_FAILED,
                    format!("the resolve job failed: {error}"),
                ),
            };
            let _ = events.send(InstallEvent::Done {
                key: task_key,
                conn,
                request_id,
                outcome,
            });
        });
        self.install_jobs.insert(
            key.clone(),
            InstallJob {
                agent: String::new(),
                kind: "resolve",
                cancel: sender,
                handle,
            },
        );
        self.install_requests.insert((conn, id_key(id)), key);
        self.update_busy();
    }

    #[cfg(unix)]
    fn install_conflict(&self, agent: &str) -> Option<String> {
        self.install_jobs
            .values()
            .find(|job| job.kind != "resolve" && job.agent == agent)
            .map(|_| format!("another operation is already running for {agent}"))
    }

    #[cfg(unix)]
    fn cancel_install(&mut self, conn: u64, params: &Value) {
        let Some(target) = params.get("id") else {
            return;
        };
        let Some(key) = self.install_requests.get(&(conn, id_key(target))) else {
            return;
        };
        if let Some(job) = self.install_jobs.get(key) {
            let _ = job.cancel.send(true);
        }
    }

    #[cfg(unix)]
    fn handle_install_event(&mut self, event: InstallEvent) {
        match event {
            InstallEvent::Progress(params) => self.broadcast_progress(params),
            InstallEvent::Done {
                key,
                conn,
                request_id,
                outcome,
            } => {
                self.install_jobs.remove(&key);
                self.install_requests.retain(|_, value| value != &key);
                let response = install_outcome(&request_id, outcome);
                self.send_to(conn, &response);
                self.update_busy();
            }
        }
    }

    /// `policy.set`: validate, install, and bind a turn_end set to a prompt that
    /// is already running (PROTOCOL.md 17.1/17.3).
    fn policy_set(&mut self, conn: u64, id: &Value, params: &Value) {
        let Some(set) = params.get("set") else {
            self.send_to(
                conn,
                &failure(id, policy::INVALID_RULE_SET, "set is required"),
            );
            return;
        };
        let name = set.get("name").and_then(Value::as_str).map(str::to_string);
        if let Err(error) = self.policy.install(set, conn, now_ms() as i64) {
            self.send_to(conn, &failure(id, policy::INVALID_RULE_SET, &error));
            return;
        }
        if let Some(name) = name {
            if let Some((session, agent)) = self.policy.pending_binding(&name) {
                let running = self
                    .instances
                    .iter()
                    .find(|(_, instance)| {
                        agent
                            .as_deref()
                            .is_none_or(|filter| filter == instance.key.agent)
                            && instance.relay.prompt_active(conn, &session)
                    })
                    .map(|(id, _)| id.clone());
                if let Some(instance_id) = running {
                    self.policy.bind(&name, conn, &instance_id, &session);
                }
            }
        }
        self.send_to(conn, &success(id, json!({})));
    }

    /// `policy.clear`.
    fn policy_clear(&mut self, conn: u64, id: &Value, params: &Value) {
        let Some(name) = params.get("name").and_then(Value::as_str) else {
            self.send_to(
                conn,
                &failure(id, policy::INVALID_RULE_SET, "name is required"),
            );
            return;
        };
        let removed = self.policy.clear(name);
        self.send_to(conn, &success(id, json!({ "removed": removed })));
    }

    /// Attach `conn` to the instance for `params`. Returns the reply and the
    /// pending requests to replay; the caller sends the reply first, so the
    /// front end has the instance id before the replayed notifications.
    fn attach(&mut self, conn: u64, params: &Value) -> Result<AttachOutcome, MethodError> {
        let key = InstanceKey::from_params(params)
            .map_err(|error| (INVALID_PARAMS, error.to_string()))?;
        let env = parse_env(params).map_err(|error| (INVALID_PARAMS, error.to_string()))?;
        #[cfg(unix)]
        let launch = match params.get("launch") {
            Some(value) if !value.is_null() => Some(
                install::parse_launch(value)
                    .map_err(|error| (install::INVALID_PARAMETER, error))?,
            ),
            _ => None,
        };

        let identity = key.identity();
        let (instance_id, created) = match self.by_identity.get(&identity).cloned() {
            Some(instance_id) => (instance_id, false),
            None => {
                #[cfg(unix)]
                let spawned = self.spawn(identity, key, env, launch);
                #[cfg(not(unix))]
                let spawned = self.spawn(identity, key, env);
                (spawned.map_err(|error| (SPAWN_FAILED, error))?, true)
            }
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
        let sessions: Vec<Value> = instance
            .relay
            .session_summaries()
            .iter()
            .map(|session| session.to_json())
            .collect();
        self.update_busy();
        Ok((
            json!({
                "instance": instance_id,
                "created": created,
                "pid": pid,
                "initialized": initialized,
                "attached": attached,
                "sessions": sessions,
            }),
            replay,
        ))
    }

    /// Bytes of event log held for one instance (PROTOCOL.md 3.5).
    fn log_bytes(&self, instance_key: &str) -> u64 {
        self.recorder.bytes(instance_key)
    }

    fn spawn(
        &mut self,
        identity: String,
        key: InstanceKey,
        env: Option<Vec<(String, String)>>,
        #[cfg(unix)] launch: Option<install::Launch>,
    ) -> Result<String, String> {
        self.next_instance += 1;
        let instance_id = format!("i{}", self.next_instance);
        // 16.4: write the lease first, then re-check the release, then spawn.
        // The lease is dropped (and its file removed) on every failure below.
        #[cfg(unix)]
        let lease = match &launch {
            Some(launch) => {
                // A missing root means the release cannot exist; do not create
                // the managed tree from a launch (16.4).
                if !launch.root.is_dir() {
                    return Err(format!(
                        "the managed root {} does not exist",
                        launch.root.display()
                    ));
                }
                Some(
                    install_lock::lease(
                        &launch.root,
                        &launch.agent,
                        &launch.install_id,
                        &instance_id,
                    )
                    .map_err(|error| format!("cannot lease the managed release: {error}"))?,
                )
            }
            None => None,
        };
        #[cfg(unix)]
        if let Some(launch) = &launch {
            let installed = match install_store::state(&launch.root, &launch.agent).status {
                install_store::Status::Installed {
                    install_id,
                    version,
                    ..
                } if install_id == launch.install_id => version,
                _ => {
                    return Err(format!(
                        "{} is not installed at {}",
                        launch.agent, launch.install_id
                    ))
                }
            };
            eprintln!(
                "nvim_ade_server: leasing {} {} for {instance_id}",
                launch.agent, installed
            );
        }
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
        // A fresh process starts from a clean log (PROTOCOL.md 10).
        self.recorder.forget_instance(&identity);
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
                relay: Relay::with_log(key.capabilities, self.event_log),
                attached: Vec::new(),
                stopping: false,
                #[cfg(unix)]
                _lease: lease,
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
            self.replay_pending(primary, &instance_id, replay);
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
        let reply_id = if is_request { Some(id.clone()) } else { None };
        let name = instance_id.to_string();

        // The instance leaves the identity lookup now, not when the process
        // exits: an `agent.attach` with the same key right after this call must
        // create a fresh instance instead of reusing the dying one
        // (PROTOCOL.md 3.4). It stays reachable by its id until it exits.
        let instance = self.instances.get_mut(&name).expect("checked above");
        if !instance.stopping {
            instance.stopping = true;
            let identity = instance.key.identity();
            // The log lives exactly as long as its instance (PROTOCOL.md 10).
            self.recorder.forget_instance(&identity);
            if self
                .by_identity
                .get(&identity)
                .is_some_and(|live| *live == name)
            {
                self.by_identity.remove(&identity);
            }
            eprintln!("nvim_ade_server: stopping agent instance {name}");
        }

        // The reply is sent after the process exited, so the wait happens off
        // the hub loop (it can take seconds). It is queued through the hub so
        // the instance is gone from `agent.list` before the reply goes out.
        let sender = self.command_sender.clone();
        tokio::spawn(async move {
            control.stop(force, timeouts).await;
            let patience = if force {
                Duration::from_secs(10)
            } else {
                timeouts.after_stdin + timeouts.after_term + Duration::from_secs(5)
            };
            let info = exited.wait(patience).await.unwrap_or_default();
            let _ = sender
                .send(Command::StopFinished {
                    conn,
                    instance: name.clone(),
                    id: reply_id,
                    code: info.code,
                    signal: info.signal,
                })
                .await;
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
            self.replay_pending(primary, &instance_id, replay);
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

        let agent = self
            .instances
            .get(instance_id)
            .map(|instance| instance.key.agent.clone())
            .unwrap_or_default();
        let method = object
            .get("method")
            .and_then(Value::as_str)
            .map(str::to_string);
        let session = object
            .get("params")
            .and_then(|params| params.get("sessionId"))
            .and_then(Value::as_str)
            .map(str::to_string);
        let action = {
            let handle = self.instances.get_mut(instance_id).expect("checked above");
            handle.relay.frontend_message(conn, &message)
        };
        // Turn-scoped policy sets bind to the prompt from the installing
        // connection; a forwarded cancel makes them cancelling (17.3). A frame
        // the relay drops never becomes an in-flight prompt, so it must not
        // bind anything that nothing would later remove.
        let forwarded = frontend_forwarded(&action);
        if forwarded {
            if let Some(session) = &session {
                match method.as_deref() {
                    Some("session/prompt") => {
                        self.policy.on_prompt(conn, instance_id, session, &agent)
                    }
                    Some("session/cancel") => self.policy.on_cancel(session),
                    _ => {}
                }
            }
        }
        // A front-end prompt (and any synthetic event) is recorded even when
        // the frame is answered locally (PROTOCOL.md 10).
        let events = action.events().to_vec();
        self.record_events(instance_id, events);
        match action {
            FrontendAction::Forward(frame) => {
                self.send_to_agent(conn, instance_id, frame, message_id);
            }
            FrontendAction::ForwardWith {
                frame,
                retractions,
                // Already recorded above, before the branch.
                events: _,
            } => {
                // The answered request is gone: tell the other connections
                // that received it before forwarding the answer (PROTOCOL.md 14).
                let retractions = retractions.clone();
                for retraction in &retractions {
                    self.send_cancel_request(instance_id, retraction);
                }
                self.send_to_agent(conn, instance_id, frame, message_id);
            }
            FrontendAction::LoadCandidate(candidate) => {
                self.start_emulated_load(conn, instance_id, candidate);
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

    /// Queue one frame for the agent, reporting a dead writer.
    fn send_to_agent(
        &mut self,
        conn: u64,
        instance_id: &str,
        frame: Value,
        message_id: Option<Value>,
    ) {
        let handle = match self.instances.get(instance_id) {
            Some(handle) => handle,
            None => return,
        };
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

    /// Record one event the relay produced (PROTOCOL.md 10).
    fn record_events(&self, instance_id: &str, events: Vec<PendingEvent>) {
        if events.is_empty() {
            return;
        }
        let Some(instance) = self.instances.get(instance_id) else {
            return;
        };
        let key = instance.key.identity();
        let ts_ms = now_ms() as i64;
        for event in events {
            self.recorder.record(RecordedEvent {
                instance_key: key.clone(),
                seq: event.seq,
                session_id: event.session_id,
                kind: if event.synthetic {
                    EventKind::Synthetic
                } else {
                    EventKind::AgentNotification
                },
                message: event.message,
                ts_ms,
            });
        }
    }

    /// Answer a `session/load` from the event log when the log is complete
    /// (PROTOCOL.md 12); otherwise forward the original request.
    ///
    /// Ordering: everything this connection receives from now on is buffered
    /// until the replay and the response are queued, so the replay and the live
    /// stream have no gap. The replay only contains what was recorded up to
    /// `up_to_seq`, so nothing is duplicated either. The read runs on the
    /// blocking pool (inside the recorder), never on the hub task.
    fn start_emulated_load(&mut self, conn: u64, instance_id: &str, candidate: LoadCandidate) {
        let Some(instance) = self.instances.get(instance_id) else {
            return;
        };
        let key = instance.key.identity();
        // The replay must fit the outbound queue: above the ceiling the request
        // is forwarded instead, before anything is read into memory
        // (PROTOCOL.md 12).
        if self.recorder.bytes(&key) > self.limits.replay_bytes {
            eprintln!(
                "nvim_ade_server: log for {instance_id} is too large to replay; forwarding session/load"
            );
            self.forward_load(conn, instance_id, &candidate.frame);
            return;
        }
        // Buffer live traffic before the replay starts, so nothing slips in
        // between the read and the switch-over.
        self.gates.insert(conn, Gate::new(self.limits.gate_bytes));
        let recorder = self.recorder.clone();
        let sender = self.load_sender.clone();
        let instance_id = instance_id.to_string();
        let delay = self.limits.replay_delay;
        tokio::spawn(async move {
            if !delay.is_zero() {
                // Test hook: let live traffic pile up behind the gate.
                tokio::time::sleep(delay).await;
            }
            let replay = recorder
                .read_session(&key, &candidate.session_id, candidate.up_to_seq)
                .await;
            let result = match replay {
                Ok(replay) if replay.complete => LoadResult::Replay {
                    conn,
                    instance: instance_id,
                    messages: crate::relay::Relay::replay_messages(&replay.events),
                    state: candidate.state,
                    frontend_id: candidate.frontend_id,
                    session_id: candidate.session_id,
                },
                Ok(_) => LoadResult::Forward {
                    conn,
                    instance: instance_id,
                    frame: candidate.frame,
                },
                Err(error) => {
                    eprintln!("nvim_ade_server: cannot read the event log: {error}");
                    LoadResult::Forward {
                        conn,
                        instance: instance_id,
                        frame: candidate.frame,
                    }
                }
            };
            let _ = sender.send(result);
        });
    }

    /// Forward a `session/load` to the agent (the emulation is not possible).
    fn forward_load(&mut self, conn: u64, instance_id: &str, frame: &Value) {
        let Some(handle) = self.instances.get_mut(instance_id) else {
            return;
        };
        let action = handle.relay.forward_request(conn, frame);
        let Some(frame) = action.forwarded().cloned() else {
            return;
        };
        if let Some(handle) = self.instances.get(instance_id) {
            if !handle.control.send_frame(frame) {
                self.send_tunnel_error(
                    conn,
                    instance_id,
                    FRAME_REJECTED,
                    "the agent is not accepting messages",
                    None,
                );
            }
        }
    }

    /// Handle the outcome of an emulated load: replay, answer, then release the
    /// gate so live traffic follows in order.
    fn finish_load(&mut self, result: LoadResult) {
        match result {
            LoadResult::Forward {
                conn,
                instance,
                frame,
            } => {
                // The log cannot answer this load: fall back to the relay.
                self.release_gate(conn);
                self.forward_load(conn, &instance, &frame);
            }
            LoadResult::Replay {
                conn,
                instance,
                messages,
                state,
                frontend_id,
                session_id,
            } => {
                for (seq, message) in &messages {
                    self.send_tunnel_recv(conn, &instance, *seq, message);
                }
                // The response carries the tracked state, with the request's
                // id, and its own seq: a replayed number is never reused.
                let response_seq = self
                    .instances
                    .get_mut(&instance)
                    .map(|handle| handle.relay.allocate_seq())
                    .unwrap_or(0);
                self.send_tunnel_recv(conn, &instance, response_seq, &success(&frontend_id, state));
                // A turn whose front end left can be adopted now (PROTOCOL.md
                // 13): the adopter hears about it right after the load reply.
                let adopted = self.instances.get_mut(&instance).and_then(|handle| {
                    let attached = handle.attached.clone();
                    handle.relay.adopt(conn, &session_id, &attached)
                });
                if let Some(adopted) = adopted {
                    self.send_tunnel_recv(
                        conn,
                        &instance,
                        adopted.seq,
                        &json!({
                            "jsonrpc": "2.0",
                            "method": "_ade/turn_adopted",
                            "params": { "sessionId": adopted.session_id },
                        }),
                    );
                }
                self.release_gate(conn);
            }
        }
    }

    /// Send everything buffered for `conn` while a replay was being read.
    fn release_gate(&mut self, conn: u64) {
        let Some(mut gate) = self.gates.remove(&conn) else {
            return;
        };
        for entry in gate.take() {
            self.send_tunnel_recv(conn, &entry.instance, entry.seq, &entry.message);
        }
    }

    /// Close a connection whose replay buffer overflowed, and cancel the replay
    /// (its result is ignored because the gate is gone).
    fn close_gated(&mut self, conn: u64) {
        self.gates.remove(&conn);
        if let Some(outbox) = self.conns.get(&conn) {
            // Same mechanism as back pressure: the connection's own task closes
            // it as soon as it notices.
            outbox.close();
        }
        eprintln!(
            "nvim_ade_server: connection {conn} fell behind during a replay buffer; closing it"
        );
    }

    /// Whether `conn` is waiting for a replay.
    fn gated(&self, conn: u64) -> bool {
        self.gates.contains_key(&conn)
    }

    /// Send the pending agent requests to `conn` and remember that it received
    /// them, so a later answer from someone else can be retracted from it
    /// (PROTOCOL.md 5.4 and 14).
    fn replay_pending(&mut self, conn: u64, instance_id: &str, replay: Replay) {
        for (seq, message) in replay {
            self.send_tunnel_recv(conn, instance_id, seq, &message);
            if let Some(id) = message.get("id").cloned() {
                if let Some(instance) = self.instances.get_mut(instance_id) {
                    instance.relay.mark_delivered(&id, conn);
                }
            }
        }
    }

    /// Tell one connection that a pending request it received is withdrawn
    /// (PROTOCOL.md 14): a standard `$/cancel_request` with the agent's id.
    fn send_cancel_request(&mut self, instance_id: &str, retraction: &Retracted) {
        self.send_tunnel_recv(
            retraction.conn,
            instance_id,
            retraction.seq,
            &json!({
                "jsonrpc": "2.0",
                "method": "$/cancel_request",
                "params": { "id": retraction.id },
            }),
        );
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
        // Permission policy first (PROTOCOL.md 17.2): a decided request is
        // answered here, never added to the pending set and never relayed.
        let is_permission = value.get("method").and_then(Value::as_str)
            == Some("session/request_permission")
            && value.get("id").is_some();
        if is_permission {
            let Some(instance) = self.instances.get(instance_id) else {
                return;
            };
            let agent = instance.key.agent.clone();
            let attached = instance.attached.clone();
            let params = value.get("params").cloned().unwrap_or_else(|| json!({}));
            let session_id = params
                .get("sessionId")
                .and_then(Value::as_str)
                .unwrap_or_default()
                .to_string();
            if let Some(decision) = self
                .policy
                .decide(&params, &agent, instance_id, cfg!(windows))
            {
                let tool_call = params.get("toolCall").cloned().unwrap_or(Value::Null);
                let response = json!({
                    "jsonrpc": "2.0",
                    "id": value.get("id").cloned().unwrap_or(Value::Null),
                    "result": decision.result(),
                });
                if let Some(instance) = self.instances.get_mut(instance_id) {
                    instance.control.send_frame(response);
                }
                if !session_id.is_empty() {
                    let update = policy::log_update(&decision, &tool_call);
                    let event = self
                        .instances
                        .get_mut(instance_id)
                        .and_then(|instance| instance.relay.policy_event(&session_id, update));
                    if let Some(event) = event {
                        self.record_events(instance_id, vec![event]);
                    }
                }
                let applied = json!({
                    "jsonrpc": "2.0",
                    "method": "policy.applied",
                    "params": policy::applied_params(
                        instance_id,
                        &session_id,
                        &decision,
                        &tool_call,
                    ),
                });
                for conn in attached {
                    self.send_to(conn, &applied);
                }
                self.update_busy();
                return;
            }
        }

        let Some(instance) = self.instances.get_mut(instance_id) else {
            return;
        };
        let attached = instance.attached.clone();
        let outcome = instance.relay.agent_message_full(&value, &attached);
        // Record what the agent said before anything is delivered: the log is
        // the source of later replays (PROTOCOL.md 10).
        let events = outcome.events.clone();
        self.record_events(instance_id, events);

        // Retractions come first: a front end must close the question before
        // the agent sees the answer (PROTOCOL.md 14).
        let retractions = outcome.retractions.clone();
        for retraction in &retractions {
            self.send_cancel_request(instance_id, retraction);
        }
        match outcome.action {
            Some(AgentAction::Response { conn, seq, message }) => {
                self.send_tunnel_recv(conn, instance_id, seq, &message);
            }
            Some(AgentAction::Notification { seq, message }) => {
                for conn in attached {
                    self.send_tunnel_recv(conn, instance_id, seq, &message);
                }
            }
            Some(AgentAction::Request {
                seq,
                message,
                target: Some(conn),
            }) => {
                self.send_tunnel_recv(conn, instance_id, seq, &message);
                // Remember that this connection saw the request, so it can be
                // retracted if another one answers (PROTOCOL.md 14).
                if let Some(id) = message.get("id") {
                    let id = id.clone();
                    if let Some(instance) = self.instances.get_mut(instance_id) {
                        instance.relay.mark_delivered(&id, conn);
                    }
                }
            }
            // No attached connection: the request stays in the pending set.
            Some(AgentAction::Request { target: None, .. }) => {}
            Some(AgentAction::Drop) | None => {}
            Some(AgentAction::Invalid) => {
                eprintln!(
                    "nvim_ade_server: agent {instance_id} wrote a frame that cannot be relayed; dropped"
                );
            }
        }

        if let Some(finished) = &outcome.prompt_finished {
            self.policy
                .prompt_finished(finished.conn, &finished.session_id);
        }
        // A prompt that finished while adopted: the adopters hear it and the
        // turn stops counting (PROTOCOL.md 13).
        if let Some(finished) = outcome.finished_turn {
            if let Some(instance) = self.instances.get_mut(instance_id) {
                instance.relay.forget_turn(&finished.session_id);
            }
            for conn in &finished.adopters {
                self.send_tunnel_recv(
                    *conn,
                    instance_id,
                    finished.seq,
                    &json!({
                        "jsonrpc": "2.0",
                        "method": "_ade/turn_finished",
                        "params": finished.params,
                    }),
                );
            }
        }
    }

    fn instance_exited(&mut self, instance_id: &str) {
        let Some(instance) = self.instances.remove(instance_id) else {
            return;
        };
        // A bound turn_end set's prompt can never be answered now (17.3); a
        // later instance with the same session id must not inherit it.
        self.policy.instance_exited(instance_id);
        // A stopped instance was already removed from the identity table, so a
        // newer instance with the same key may be registered there. Only delete
        // an entry that still points at this instance.
        let identity = instance.key.identity();
        self.recorder.forget_instance(&identity);
        forget_identity(&mut self.by_identity, &identity, instance_id);
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
        // `agent.stop` replies wait until the instance is gone, so the very next
        // `agent.list` cannot show it (PROTOCOL.md 3.4).
        for (conn, id) in self
            .pending_stop_replies
            .remove(instance_id)
            .unwrap_or_default()
        {
            self.send_to(conn, &success(&id, stop_reply(&info)));
        }
    }

    fn update_busy(&mut self) {
        let busy = self.instances.values().any(|instance| {
            instance.relay.turns_running() > 0 || instance.relay.pending_requests() > 0
        }) || self.install_busy();
        if busy != self.busy {
            self.busy = busy;
            let _ = self.events.send(HubEvent::Busy(busy));
        }
    }

    /// Whether an install job runs: the idle exit waits for it (PROTOCOL.md 8,
    /// 16.3).
    #[cfg(unix)]
    fn install_busy(&self) -> bool {
        !self.install_jobs.is_empty()
    }

    #[cfg(not(unix))]
    fn install_busy(&self) -> bool {
        false
    }

    fn send_to(&self, conn: u64, value: &Value) {
        if let Some(outbox) = self.conns.get(&conn) {
            outbox.send(value);
        }
    }

    fn send_tunnel_recv(&mut self, conn: u64, instance: &str, seq: u64, message: &Value) {
        if self.gated(conn) {
            let entry = GateEntry {
                instance: instance.to_string(),
                seq,
                message: message.clone(),
            };
            let overflowed = match self.gates.get_mut(&conn) {
                Some(gate) => gate.push(entry).is_err(),
                None => false,
            };
            if overflowed {
                // The waiter cannot keep up: close it like an overflowing
                // outbound queue (PROTOCOL.md 7 and 12) and cancel the replay.
                self.close_gated(conn);
            }
            return;
        }
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

/// Forget the identity entry of `instance` only when it still points at this
/// instance.
///
/// A stopped instance leaves the table before it exits (PROTOCOL.md 3.4), so by
/// the time its exit is processed a newer instance with the same key may own
/// the entry. Blindly removing it would unregister the live instance and make
/// the next `agent.attach` spawn a duplicate.
fn forget_identity(
    by_identity: &mut HashMap<String, String>,
    identity: &str,
    instance_id: &str,
) -> bool {
    if by_identity
        .get(identity)
        .is_some_and(|live| live == instance_id)
    {
        by_identity.remove(identity);
        true
    } else {
        false
    }
}

/// The `agent.stop` result for one exit.
fn stop_reply(info: &crate::runtime::ExitInfo) -> Value {
    json!({
        "exited": true,
        "code": info.code,
        "signal": info.signal,
    })
}

fn request_id(frame: &Value) -> Value {
    frame.get("id").cloned().unwrap_or(Value::Null)
}

/// Whether a front-end frame really goes to the agent.
fn frontend_forwarded(action: &FrontendAction) -> bool {
    matches!(
        action,
        FrontendAction::Forward(_) | FrontendAction::ForwardWith { .. }
    )
}

/// Canonical key for one JSON-RPC id, used to find a running request.
#[cfg(unix)]
fn id_key(id: &Value) -> String {
    serde_json::to_string(id).unwrap_or_default()
}

#[cfg(unix)]
fn required_string(params: &Value, field: &str) -> Result<String, String> {
    params
        .get(field)
        .and_then(Value::as_str)
        .map(str::to_string)
        .ok_or_else(|| format!("{field} must be a string"))
}

#[cfg(unix)]
fn install_env(params: &Value) -> Result<Vec<(String, String)>, String> {
    let object = params
        .get("env")
        .and_then(Value::as_object)
        .ok_or_else(|| "env is required".to_string())?;
    let mut env = Vec::with_capacity(object.len());
    for (key, value) in object {
        if key.is_empty() || key.contains('=') || key.contains('\0') {
            return Err(format!("env key {key:?} is not a valid environment name"));
        }
        let value = value
            .as_str()
            .ok_or_else(|| format!("env.{key} must be a string"))?;
        if value.contains('\0') {
            return Err(format!("env.{key} must not contain NUL"));
        }
        env.push((key.clone(), value.to_string()));
    }
    Ok(env)
}

#[cfg(unix)]
fn positive_option(params: &Value, field: &str) -> Result<Option<u64>, String> {
    match params.get(field) {
        None | Some(Value::Null) => Ok(None),
        Some(value) => value
            .as_u64()
            .filter(|value| *value > 0)
            .map(Some)
            .ok_or_else(|| format!("{field} must be a positive integer")),
    }
}

#[cfg(unix)]
fn parse_run(params: &Value) -> Result<install::RunRequest, String> {
    let job = required_string(params, "job")?;
    if !install::valid_job(&job) {
        return Err("job is invalid".to_string());
    }
    let root = install::check_root(&required_string(params, "root")?)?;
    let agent = required_string(params, "agent")?;
    if !install::valid_agent_id(&agent) {
        return Err("agent is invalid".to_string());
    }
    let action = required_string(params, "action")?;
    if action != "install" && action != "update" {
        return Err("action must be install or update".to_string());
    }
    let package = required_string(params, "package")?;
    if !install::valid_package(&package) {
        return Err("package is invalid".to_string());
    }
    let entry = required_string(params, "entry")?;
    if !install::valid_relative(&entry) {
        return Err("entry is invalid".to_string());
    }
    let bin = match params.get("bin") {
        None | Some(Value::Null) => None,
        Some(value) => {
            let bin = value
                .as_str()
                .filter(|value| install::valid_relative(value))
                .ok_or_else(|| "bin is invalid".to_string())?;
            Some(bin.to_string())
        }
    };
    let version = required_string(params, "version")?;
    if !install::valid_version(&version) {
        return Err("version must be an exact release".to_string());
    }
    let npm = required_string(params, "npm")?;
    if !install::npm::valid_npm(&npm) {
        return Err("npm must be a single executable".to_string());
    }
    let env = install_env(params)?;
    let timeout = positive_option(params, "timeout_ms")?
        .map(Duration::from_millis)
        .unwrap_or(Duration::from_millis(install::DEFAULT_RUN_TIMEOUT_MS));
    let max_log_bytes = positive_option(params, "max_log_bytes")?
        .map(|value| value as usize)
        .unwrap_or(install::DEFAULT_MAX_LOG_BYTES);
    Ok(install::RunRequest {
        job,
        root,
        agent,
        action,
        package,
        entry,
        bin,
        version,
        npm,
        env,
        timeout,
        max_log_bytes,
    })
}

#[cfg(unix)]
fn parse_uninstall(params: &Value) -> Result<install::UninstallRequest, String> {
    let job = required_string(params, "job")?;
    if !install::valid_job(&job) {
        return Err("job is invalid".to_string());
    }
    let root = install::check_root(&required_string(params, "root")?)?;
    let agent = required_string(params, "agent")?;
    if !install::valid_agent_id(&agent) {
        return Err("agent is invalid".to_string());
    }
    let install_id = match params.get("installId") {
        None | Some(Value::Null) => None,
        Some(value) => {
            let id = value
                .as_str()
                .filter(|value| install::valid_install_id(value))
                .ok_or_else(|| "installId is invalid".to_string())?;
            Some(id.to_string())
        }
    };
    Ok(install::UninstallRequest {
        job,
        root,
        agent,
        install_id,
    })
}

#[cfg(unix)]
fn parse_resolve(params: &Value) -> Result<install::ResolveRequest, String> {
    let root = install::check_root(&required_string(params, "root")?)?;
    let package = required_string(params, "package")?;
    if !install::valid_package(&package) {
        return Err("package is invalid".to_string());
    }
    let spec = required_string(params, "spec")?;
    if !install::valid_spec(&spec) {
        return Err("spec must be an exact version or latest".to_string());
    }
    let npm = required_string(params, "npm")?;
    if !install::npm::valid_npm(&npm) {
        return Err("npm must be a single executable".to_string());
    }
    let env = install_env(params)?;
    let timeout = positive_option(params, "timeout_ms")?
        .map(Duration::from_millis)
        .unwrap_or(Duration::from_millis(install::DEFAULT_RESOLVE_TIMEOUT_MS));
    Ok(install::ResolveRequest {
        root,
        package,
        spec,
        npm,
        env,
        timeout,
    })
}

#[cfg(unix)]
fn install_failure(id: &Value, code: i64, message: &str, data: Option<Value>) -> Value {
    let mut frame = failure(id, code, message);
    if let Some(data) = data {
        if let Some(error) = frame.get_mut("error").and_then(Value::as_object_mut) {
            error.insert("data".to_string(), data);
        }
    }
    frame
}

#[cfg(unix)]
fn install_outcome(id: &Value, outcome: install::Outcome) -> Value {
    match outcome {
        install::Outcome::Success(value) => success(id, value),
        install::Outcome::Failed {
            code,
            message,
            data,
        } => install_failure(id, code, &message, data),
        install::Outcome::Cancelled => install_failure(id, install::CANCELLED, "cancelled", None),
    }
}

fn instance_summary(instance: &Instance, log_bytes: u64) -> Value {
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
        "stopping": instance.stopping,
        "sessions": instance.relay.session_count(),
        "log_bytes": log_bytes,
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
    fn a_gate_buffers_until_its_byte_cap() {
        // Each entry costs its message text plus a fixed overhead; a cap of
        // exactly three entries makes the fourth one fail.
        let entry_size = {
            let probe = GateEntry {
                instance: "i1".to_string(),
                seq: 1,
                message: json!({"method": "session/update", "params": {"n": 1}}),
            };
            probe.message.to_string().len() + probe.instance.len() + 64
        };
        let mut gate = Gate::new(entry_size * 3);
        for seq in 1..=3 {
            let entry = GateEntry {
                instance: "i1".to_string(),
                seq,
                message: json!({"method": "session/update", "params": {"n": seq}}),
            };
            gate.push(entry).expect("under the cap");
        }
        assert_eq!(gate.entries.len(), 3);
        assert!(gate.bytes > 0);

        // One more message pushes it over: the caller closes the connection.
        let entry = GateEntry {
            instance: "i1".to_string(),
            seq: 4,
            message: json!({"method": "session/update", "params": {"n": 4}}),
        };
        assert!(gate.push(entry).is_err(), "the cap is enforced");
        assert_eq!(gate.entries.len(), 3, "nothing is dropped silently");

        let taken = gate.take();
        assert_eq!(taken.len(), 3);
        assert_eq!(gate.bytes, 0);
    }

    #[test]
    fn a_single_oversized_message_does_not_pass_a_small_gate() {
        let mut gate = Gate::new(10);
        let entry = GateEntry {
            instance: "i1".to_string(),
            seq: 1,
            message: json!({"payload": "x".repeat(100)}),
        };
        assert!(gate.push(entry).is_err());
        assert!(gate.entries.is_empty());
    }

    #[test]
    fn limits_default_to_64_mib_gate_and_32_mib_replay() {
        let limits = Limits::default();
        assert_eq!(limits.gate_bytes, 64 * 1024 * 1024);
        assert_eq!(limits.replay_bytes, 32 * 1024 * 1024);
        assert!(limits.replay_delay.is_zero());
    }

    #[test]
    fn limits_read_the_environment() {
        let limits = Limits::from_lookup(|key| match key {
            "NVIM_ADE_SERVER_GATE_LIMIT_BYTES" => Some("1024".to_string()),
            "NVIM_ADE_SERVER_REPLAY_LIMIT_BYTES" => Some("2048".to_string()),
            "NVIM_ADE_SERVER_REPLAY_DELAY_MS" => Some("250".to_string()),
            _ => None,
        });
        assert_eq!(limits.gate_bytes, 1024);
        assert_eq!(limits.replay_bytes, 2048);
        assert_eq!(limits.replay_delay, Duration::from_millis(250));
    }

    #[test]
    fn limits_ignore_garbage() {
        let limits = Limits::from_lookup(|_| Some("soon".to_string()));
        assert_eq!(limits.gate_bytes, MAX_GATE_BYTES);
        assert_eq!(limits.replay_bytes, MAX_REPLAY_LOG_BYTES);
    }

    #[test]
    fn forgetting_an_identity_never_unregisters_a_newer_instance() {
        let mut by_identity = HashMap::new();
        by_identity.insert("k".to_string(), "i2".to_string());

        // The old instance i1 exits after i2 took over its identity.
        assert!(!forget_identity(&mut by_identity, "k", "i1"));
        assert_eq!(
            by_identity.get("k"),
            Some(&"i2".to_string()),
            "the live instance must stay registered"
        );

        // The instance that owns the entry may remove it.
        assert!(forget_identity(&mut by_identity, "k", "i2"));
        assert!(by_identity.is_empty());

        // A missing entry is not an error.
        assert!(!forget_identity(&mut by_identity, "k", "i9"));
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
    fn only_forwarded_frames_trigger_policy_turn_hooks() {
        assert!(frontend_forwarded(&FrontendAction::Forward(json!({}))));
        assert!(frontend_forwarded(&FrontendAction::ForwardWith {
            frame: json!({}),
            retractions: Vec::new(),
            events: Vec::new(),
        }));
        assert!(!frontend_forwarded(&FrontendAction::Drop));
        assert!(!frontend_forwarded(&FrontendAction::Reply(json!({}), 1)));
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
            stopping: false,
            #[cfg(unix)]
            _lease: None,
        };
        let summary = instance_summary(&instance, 0);
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
            "stopping",
            "sessions",
            "log_bytes",
        ] {
            assert!(summary.get(field).is_some(), "missing {field}");
        }
        assert_eq!(summary["attached"], 2);
        assert_eq!(summary["turns_running"], 0);
        assert_eq!(summary["pending_requests"], 0);
        assert_eq!(summary["stopping"], false);
        assert_eq!(summary["sessions"], 0);
        assert_eq!(summary["log_bytes"], 0);
    }
}
