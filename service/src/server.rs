//! The `serve` subcommand: bind the socket, guard against duplicates, and run
//! the connection loop.

use std::fs::{File, OpenOptions, TryLockError};
use std::io;
use std::path::PathBuf;
use std::sync::Arc;
use std::time::Duration;

use anyhow::{bail, Context, Result};
use serde_json::Value;
use tokio::io::{AsyncWriteExt, BufReader};
use tokio::sync::{mpsc, watch, Notify};

use crate::hub::{Command, Hub, HubEvent, Outbox};
use crate::paths::Paths;
use crate::protocol::{self, Local};
use crate::recorder::Recorder;
use crate::runtime::StopTimeouts;
use crate::team::{self, SharedTokens};
use crate::transport::{self, Listener, Stream};
use crate::{token, API_VERSION};

/// Environment variable that overrides the idle timeout, in seconds (fractions
/// allowed, handy for tests).
pub const IDLE_TIMEOUT_ENV: &str = "NVIM_ADE_SERVER_IDLE_TIMEOUT_SECS";

/// Default idle timeout (PROTOCOL.md section 8).
pub const DEFAULT_IDLE_TIMEOUT: Duration = Duration::from_secs(1800);

/// Event log file in the service directory (PROTOCOL.md section 10).
pub const EVENT_LOG_FILE_NAME: &str = "nvim_ade_server.events.sqlite3";

/// Default per-instance event log cap (PROTOCOL.md section 15).
pub const DEFAULT_EVENT_LOG_MAX_MB: u64 = 256;
/// Allowed range of `--event-log-max-mb` (PROTOCOL.md section 15).
pub const MIN_EVENT_LOG_MAX_MB: u64 = 16;
pub const MAX_EVENT_LOG_MAX_MB: u64 = 4096;

/// Validate `--event-log-max-mb`; out-of-range values are a start-up error.
pub fn validate_event_log_max_mb(value: u64) -> Result<u64> {
    if !(MIN_EVENT_LOG_MAX_MB..=MAX_EVENT_LOG_MAX_MB).contains(&value) {
        bail!(
            "--event-log-max-mb must be between {MIN_EVENT_LOG_MAX_MB} and {MAX_EVENT_LOG_MAX_MB}, got {value}"
        );
    }
    Ok(value)
}

#[derive(Debug, Clone)]
pub struct ServeOptions {
    /// Explicit socket path (`--socket`), if any.
    pub socket: Option<PathBuf>,
    /// Idle timeout; `None` means "use the environment or the default".
    pub idle_timeout: Option<Duration>,
    /// Stop timings for agent processes; `None` uses the environment/default.
    pub stop_timeouts: Option<StopTimeouts>,
    /// Event log setting (`--event-log`), default on (PROTOCOL.md 15).
    pub event_log: bool,
    /// Per-instance event log cap in MiB (`--event-log-max-mb`).
    pub event_log_max_mb: u64,
}

impl ServeOptions {
    pub fn new(socket: Option<PathBuf>, idle_timeout: Option<Duration>) -> Self {
        Self {
            socket,
            idle_timeout,
            stop_timeouts: None,
            event_log: true,
            event_log_max_mb: DEFAULT_EVENT_LOG_MAX_MB,
        }
    }
}

pub enum ServeStatus {
    /// Another live instance already owns the lock.
    AlreadyRunning { socket: String },
    /// This instance ran and exited (shutdown or idle timeout).
    Exited { socket: String },
}

/// Resolve the idle timeout: explicit option, then environment, then default.
pub fn idle_timeout(explicit: Option<Duration>) -> Result<Duration> {
    idle_timeout_from(explicit, |key| std::env::var(key).ok())
}

fn idle_timeout_from<F>(explicit: Option<Duration>, lookup: F) -> Result<Duration>
where
    F: Fn(&str) -> Option<String>,
{
    if let Some(timeout) = explicit {
        return Ok(timeout);
    }
    match lookup(IDLE_TIMEOUT_ENV) {
        Some(value) if !value.trim().is_empty() => {
            let seconds = parse_seconds(value.trim()).with_context(|| {
                format!("{IDLE_TIMEOUT_ENV} must be a number of seconds, got {value:?}")
            })?;
            Ok(seconds)
        }
        _ => Ok(DEFAULT_IDLE_TIMEOUT),
    }
}

fn parse_seconds(value: &str) -> Result<Duration> {
    let seconds: f64 = value
        .parse()
        .with_context(|| format!("{value:?} is not a number"))?;
    if !seconds.is_finite() || seconds < 0.0 {
        bail!("{value:?} is not a valid duration");
    }
    Ok(Duration::from_secs_f64(seconds))
}

/// Run the service until shutdown or idle timeout.
///
/// Prints the single status line that the contract requires on stdout; all
/// other output goes to stderr.
pub async fn serve(options: ServeOptions) -> Result<ServeStatus> {
    let paths = match &options.socket {
        Some(socket) => Paths::with_socket(socket.clone())?,
        None => Paths::resolve()?,
    };
    let timeout = idle_timeout(options.idle_timeout)?;
    let stop_timeouts = options.stop_timeouts.unwrap_or_else(StopTimeouts::from_env);
    validate_event_log_max_mb(options.event_log_max_mb)?;

    prepare_dir(&paths)?;
    let lock = match acquire_lock(&paths)? {
        Some(lock) => lock,
        None => {
            // Report the socket of the instance that owns the lock, which is
            // not necessarily the one this invocation would have used.
            let socket = live_socket(&paths);
            return Ok(ServeStatus::AlreadyRunning { socket });
        }
    };
    // Only the instance holding the lock owns the log file: a second `serve`
    // must not rotate the running service's log before exiting.
    if let Err(error) = crate::logging::init(paths.dir(), crate::logging::MAX_BYTES) {
        eprintln!("nvim_ade_server: cannot open the service log: {error}");
    }
    // The lock file records our socket, so a second `serve` (possibly started
    // with a different `--socket`) can report the real one. This happens after
    // the lock is held, so nobody else writes here.
    record_socket(&lock, &paths);

    clear_stale_socket(&paths)?;

    // The token is created before the socket is bound, so a client that sees
    // "ready" can always read it.
    let (token, token_state) = token::load_or_create(&paths.token_file())?;
    match token_state {
        token::State::Reused => {}
        token::State::Created => {
            crate::svc_log!(
                "nvim_ade_server: generated token {}",
                paths.token_file().display()
            );
        }
        token::State::Replaced(reason) => {
            crate::svc_log!(
                "nvim_ade_server: replaced token file {} ({}); clients must re-read it",
                paths.token_file().display(),
                reason.as_str()
            );
        }
    }

    // The event log is opened before the socket is announced, so a front end
    // that sees "ready" can rely on replay working (PROTOCOL.md 10).
    let recorder = if options.event_log {
        let path = paths.dir().join(EVENT_LOG_FILE_NAME);
        let max_bytes = options.event_log_max_mb * 1024 * 1024;
        Recorder::open(&path, max_bytes)
            .with_context(|| format!("opening the event log {}", path.display()))?
    } else {
        Recorder::disabled()
    };

    let mut listener = Listener::bind(paths.socket())
        .with_context(|| format!("binding socket {}", socket_string(&paths)))?;
    let socket = socket_string(&paths);
    announce_ready(&socket)?;
    crate::svc_log!(
        "nvim_ade_server {} (api {}) listening on {}",
        crate::SERVER_VERSION,
        API_VERSION,
        socket
    );

    let shutdown = Arc::new(Notify::new());
    let stopped = Arc::new(Notify::new());
    let (hub_commands, hub_commands_rx) = mpsc::channel::<Command>(256);
    let (hub_events, mut hub_events_rx) = mpsc::unbounded_channel::<HubEvent>();
    let tokens = team::new_shared_tokens();

    let hub = Hub::new(
        hub_commands_rx,
        hub_commands.clone(),
        hub_events,
        Arc::clone(&stopped),
        stop_timeouts,
    )
    .with_limits(crate::hub::Limits::from_env())
    .with_teams(Arc::clone(&tokens))
    .with_event_log(options.event_log, options.event_log_max_mb, recorder);
    let hub_task = tokio::spawn(hub.run());

    let (events_tx, mut events_rx) = mpsc::unbounded_channel::<ConnectionEvent>();
    let mut active: usize = 0;
    let mut next_conn: u64 = 0;
    let mut busy = false;
    // No client has connected yet, so the idle clock starts now.
    let mut idle_since = Some(tokio::time::Instant::now());
    let shutting_down = false;

    let termination = termination_signal();
    tokio::pin!(termination);

    loop {
        // Idle only when no connection is open and nothing is in flight.
        let idle_deadline = if active == 0 && !busy {
            idle_since.map(|since| since + timeout)
        } else {
            idle_since = None;
            None
        };
        let sleeping = async {
            match idle_deadline {
                Some(deadline) => tokio::time::sleep_until(deadline).await,
                None => std::future::pending().await,
            }
        };

        tokio::select! {
            biased;

            _ = shutdown.notified() => {
                crate::svc_log!("nvim_ade_server: shutting down");
                break;
            }

            _ = &mut termination => {
                crate::svc_log!("nvim_ade_server: terminated by a signal");
                break;
            }

            accepted = listener.accept(), if !shutting_down => {
                match accepted {
                    Ok(stream) => {
                        next_conn += 1;
                        active += 1;
                        idle_since = None;
                        spawn_connection(
                            next_conn,
                            stream,
                            token.clone(),
                            shutdown.clone(),
                            hub_commands.clone(),
                            events_tx.clone(),
                            options.event_log,
                            Arc::clone(&tokens),
                        );
                    }
                    Err(error) => {
                        crate::svc_log!("nvim_ade_server: accept failed: {error}");
                        // A transient failure (e.g. a client that vanished
                        // mid-handshake) must not kill the service; a broken
                        // listener must not spin forever either.
                        tokio::time::sleep(Duration::from_millis(100)).await;
                    }
                }
            }

            event = events_rx.recv() => {
                match event {
                    Some(ConnectionEvent::Closed { counted: true }) => {
                        active = active.saturating_sub(1);
                        if active == 0 {
                            idle_since = Some(tokio::time::Instant::now());
                        }
                    }
                    Some(ConnectionEvent::Participant) => {
                        active = active.saturating_sub(1);
                        if active == 0 && !busy {
                            idle_since = Some(tokio::time::Instant::now());
                        }
                    }
                    _ => {}
                }
            }

            event = hub_events_rx.recv() => {
                match event {
                    Some(HubEvent::Busy(value)) => {
                        busy = value;
                        if busy {
                            idle_since = None;
                        } else if active == 0 {
                            idle_since = Some(tokio::time::Instant::now());
                        }
                    }
                    None => {}
                }
            }

            _ = sleeping => {
                crate::svc_log!(
                    "nvim_ade_server: idle for {}s, exiting",
                    duration_secs(timeout)
                );
                break;
            }
        }
    }

    // Run the stop sequence for every instance before the socket goes away.
    stop_instances(&hub_commands, &stopped).await;
    listener.cleanup();
    drop(hub_commands);
    let _ = hub_task.await;
    drop(lock);
    Ok(ServeStatus::Exited { socket })
}

/// Ask the hub to stop every instance and wait until it is done.
async fn stop_instances(commands: &mpsc::Sender<Command>, stopped: &Notify) {
    let notified = stopped.notified();
    tokio::pin!(notified);
    if commands.send(Command::Shutdown).await.is_ok() {
        let _ = notified.await;
    }
}

fn duration_secs(duration: Duration) -> String {
    let seconds = duration.as_secs_f64();
    if seconds.fract() == 0.0 {
        format!("{}", seconds as u64)
    } else {
        format!("{seconds}")
    }
}

/// Resolves when the process is asked to terminate, so the socket is removed
/// even when the service is stopped from outside (logout, `kill`, Ctrl+C).
#[cfg(unix)]
async fn termination_signal() {
    use tokio::signal::unix::{signal, SignalKind};
    let mut terminate = match signal(SignalKind::terminate()) {
        Ok(stream) => stream,
        Err(error) => {
            crate::svc_log!("nvim_ade_server: cannot watch SIGTERM: {error}");
            return std::future::pending().await;
        }
    };
    let mut interrupt = match signal(SignalKind::interrupt()) {
        Ok(stream) => stream,
        Err(error) => {
            crate::svc_log!("nvim_ade_server: cannot watch SIGINT: {error}");
            return std::future::pending().await;
        }
    };
    tokio::select! {
        _ = terminate.recv() => {}
        _ = interrupt.recv() => {}
    }
}

#[cfg(windows)]
async fn termination_signal() {
    // Ctrl+C, Ctrl+Break and console close all surface as an error here.
    let _ = tokio::signal::ctrl_c().await;
}

#[allow(clippy::too_many_arguments)]
fn spawn_connection(
    conn: u64,
    stream: Stream,
    token: String,
    shutdown: Arc<Notify>,
    hub: mpsc::Sender<Command>,
    events: mpsc::UnboundedSender<ConnectionEvent>,
    event_log: bool,
    tokens: SharedTokens,
) {
    tokio::spawn(async move {
        let counted = match handle_connection(
            conn, stream, &token, &shutdown, &hub, &events, event_log, &tokens,
        )
        .await
        {
            Ok(counted) => counted,
            Err(error) => {
                crate::svc_log!("nvim_ade_server: connection error: {error}");
                false
            }
        };
        let _ = hub.send(Command::Disconnected { conn }).await;
        let _ = events.send(ConnectionEvent::Closed { counted });
    });
}

#[allow(clippy::too_many_arguments)]
async fn handle_connection(
    conn: u64,
    stream: Stream,
    token: &str,
    shutdown: &Notify,
    hub: &mpsc::Sender<Command>,
    events: &mpsc::UnboundedSender<ConnectionEvent>,
    event_log: bool,
    tokens: &SharedTokens,
) -> io::Result<bool> {
    let (reader, writer) = tokio::io::split(stream);
    let mut reader = BufReader::new(reader);

    // The writer task owns the outbound side: the hub and this task only
    // queue bytes, so frames from both are written one after another.
    let (close_tx, close_rx) = watch::channel(false);
    let (outbox, mut outbox_rx) = Outbox::new(close_tx.clone(), conn);
    let mut writer = writer;
    let writer_task = tokio::spawn(async move {
        while let Some(bytes) = outbox_rx.recv().await {
            if writer.write_all(&bytes).await.is_err() || writer.flush().await.is_err() {
                crate::svc_log!(
                    "nvim_ade_server: connection {conn} closed: writing to the client failed"
                );
                return;
            }
        }
    });

    let mut handshake = protocol::Handshake::default();
    let mut reported: Option<Option<String>> = None;
    let mut counted = true;
    let _ = hub
        .send(Command::Register {
            conn,
            outbox: outbox.clone(),
        })
        .await;

    let mut close_rx = close_rx;
    #[allow(unused_assignments)]
    let mut close_reason = "connection ended";
    let result = loop {
        // The hub closes the connection when its outbound queue would exceed
        // its limit; that must end the connection even while no frame arrives.
        let line = tokio::select! {
            biased;
            changed = close_rx.changed() => {
                let _ = changed;
                close_reason = "the service closed the connection";
                break Ok(());
            }
            line = protocol::read_message(&mut reader, protocol::MAX_MESSAGE_BYTES) => line,
        };

        let line = match line {
            Ok(Some(line)) => line,
            Ok(None) => {
                close_reason = "the client closed the connection";
                break Ok(());
            }
            // A client that goes away mid-line is a normal disconnect, not an
            // error worth reporting.
            Err(error)
                if error.kind() == io::ErrorKind::BrokenPipe
                    || error.kind() == io::ErrorKind::UnexpectedEof
                    || error.kind() == io::ErrorKind::ConnectionReset =>
            {
                close_reason = "the client closed the connection";
                break Ok(());
            }
            Err(error) if error.kind() == io::ErrorKind::InvalidData => {
                crate::svc_log!(
                    "nvim_ade_server: connection {conn} closed: invalid frame: {error}"
                );
                close_reason = "invalid frame (line too long or malformed)";
                break Ok(());
            }
            Err(error) => {
                crate::svc_log!("nvim_ade_server: connection {conn} read failed: {error}");
                close_reason = "read error";
                break Err(error);
            }
        };
        if line.trim().is_empty() {
            continue;
        }

        let frame: Value = match serde_json::from_str(&line) {
            Ok(frame) => frame,
            Err(_) => {
                // The stream is still in sync, so report and keep going.
                outbox.send(&parse_error());
                continue;
            }
        };

        let was_authenticated = handshake.is_authenticated();
        match protocol::handle_local_with_tokens(
            &mut handshake,
            token,
            &frame,
            event_log,
            Some(tokens),
        ) {
            Local::Reply(response) => {
                if handshake.is_authenticated() && !was_authenticated {
                    log_authenticated(&handshake);
                }
                if handshake.is_authenticated() {
                    let current = handshake
                        .participant()
                        .map(|participant| participant.token_id.clone());
                    if reported.as_ref() != Some(&current) {
                        reported = Some(current.clone());
                        if current.is_some() && counted {
                            counted = false;
                            let _ = events.send(ConnectionEvent::Participant);
                        }
                        let _ = hub
                            .send(Command::Authenticated {
                                conn,
                                participant: current,
                            })
                            .await;
                    }
                }
                // A null response means "no reply" (notification).
                if !response.is_null() {
                    outbox.send(&response);
                }
            }
            Local::Close(response) => {
                outbox.send(&response);
                flush_outbox(&outbox).await;
                close_reason = "the client requested close";
                break Ok(());
            }
            Local::Shutdown(response) => {
                if !response.is_null() {
                    outbox.send(&response);
                }
                flush_outbox(&outbox).await;
                shutdown.notify_one();
                close_reason = "the service is shutting down";
                break Ok(());
            }
            Local::Route => {
                if handshake.is_authenticated() && !was_authenticated {
                    log_authenticated(&handshake);
                }
                if handshake.is_authenticated() {
                    let current = handshake
                        .participant()
                        .map(|participant| participant.token_id.clone());
                    if reported.as_ref() != Some(&current) {
                        reported = Some(current.clone());
                        if current.is_some() && counted {
                            counted = false;
                            let _ = events.send(ConnectionEvent::Participant);
                        }
                        let _ = hub
                            .send(Command::Authenticated {
                                conn,
                                participant: current,
                            })
                            .await;
                    }
                }
                if hub.send(Command::Frame { conn, frame }).await.is_err() {
                    close_reason = "the hub is gone";
                    break Ok(());
                }
            }
        }
    };

    crate::svc_log!("nvim_ade_server: connection {conn} closed: {close_reason}");
    // The hub may still hold a clone of the outbox; closing the watch makes
    // every later send fail, and aborting the writer releases the socket.
    flush_outbox(&outbox).await;
    close_tx.send(true).ok();
    cancel_writer(writer_task).await;
    result.map(|()| counted)
}

/// Wait (briefly) until every queued frame was written.
async fn flush_outbox(outbox: &Outbox) {
    let _ = tokio::time::timeout(Duration::from_millis(200), async {
        while !outbox.is_empty() {
            tokio::time::sleep(Duration::from_millis(2)).await;
        }
    })
    .await;
}

async fn cancel_writer(task: tokio::task::JoinHandle<()>) {
    task.abort();
    let _ = task.await;
}

fn log_authenticated(handshake: &protocol::Handshake) {
    crate::svc_log!(
        "nvim_ade_server: client {} ({}) authenticated",
        handshake.client().unwrap_or("unknown"),
        handshake.client_version().unwrap_or("unknown")
    );
}

fn parse_error() -> Value {
    serde_json::json!({
        "jsonrpc": "2.0",
        "id": null,
        "error": { "code": protocol::PARSE_ERROR, "message": "parse error" },
    })
}

/// Create the directory with permission 0700.
///
/// Default locations are always tightened. A directory chosen explicitly (via
/// `NVIM_ADE_SERVER_DIR`) is tightened when the service created it, or when it
/// holds nothing but the service's own files; a shared directory the user
/// pointed at by accident (for example `/tmp`) is left alone.
fn prepare_dir(paths: &Paths) -> Result<()> {
    let dir = paths.dir();
    let existed = dir.exists();
    std::fs::create_dir_all(dir)
        .with_context(|| format!("creating service directory {}", dir.display()))?;
    if !existed || paths.private_dir() || contains_only_service_files(dir) {
        set_dir_permissions(dir)?;
    }
    Ok(())
}

fn contains_only_service_files(dir: &std::path::Path) -> bool {
    let entries = match std::fs::read_dir(dir) {
        Ok(entries) => entries,
        Err(_) => return false,
    };
    let known = [
        crate::paths::SOCKET_FILE_NAME,
        crate::paths::TOKEN_FILE_NAME,
        crate::paths::LOCK_FILE_NAME,
        "nvim_ade_server.token.tmp",
        crate::logging::LOG_NAME,
        crate::logging::ROTATED_NAME,
    ];
    entries.filter_map(Result::ok).all(|entry| {
        let name = entry.file_name();
        known
            .iter()
            .any(|candidate| name.to_string_lossy() == *candidate)
    })
}

#[cfg(unix)]
fn set_dir_permissions(dir: &std::path::Path) -> Result<()> {
    use std::os::unix::fs::PermissionsExt;
    std::fs::set_permissions(dir, std::fs::Permissions::from_mode(0o700))
        .with_context(|| format!("setting permissions on {}", dir.display()))
}

#[cfg(not(unix))]
fn set_dir_permissions(_dir: &std::path::Path) -> Result<()> {
    Ok(())
}

/// Try to own the instance. `Ok(None)` means another process holds the lock.
fn acquire_lock(paths: &Paths) -> Result<Option<File>> {
    let path = paths.lock_file();
    let file = OpenOptions::new()
        .create(true)
        .read(true)
        .write(true)
        .truncate(false)
        .open(&path)
        .with_context(|| format!("opening lock file {}", path.display()))?;
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        let _ = file.set_permissions(std::fs::Permissions::from_mode(0o600));
    }
    match file.try_lock() {
        Ok(()) => Ok(Some(file)),
        Err(TryLockError::WouldBlock) => Ok(None),
        Err(TryLockError::Error(error)) => {
            Err(error).with_context(|| format!("locking {}", path.display()))
        }
    }
}

/// Write our socket path into the lock file we hold, so a second instance can
/// report it. Failure is not fatal: the second instance then falls back to the
/// path it would have used itself.
fn record_socket(lock: &File, paths: &Paths) {
    use std::io::{Seek, SeekFrom, Write};
    let mut handle = lock;
    let _ = handle.set_len(0);
    let _ = handle.seek(SeekFrom::Start(0));
    let _ = writeln!(handle, "{}", paths.socket().display());
    let _ = handle.flush();
}

/// The socket of the running instance, read from the lock file, falling back to
/// the default location for this invocation.
fn live_socket(paths: &Paths) -> String {
    if let Ok(contents) = std::fs::read_to_string(paths.lock_file()) {
        let line = contents.lines().next().unwrap_or("").trim();
        if !line.is_empty() {
            return line.to_string();
        }
    }
    socket_string(paths)
}

/// We hold the lock, so any socket file still lying around is stale. If it
/// unexpectedly answers, another instance is alive without the lock — report
/// that instead of stealing the socket.
fn clear_stale_socket(paths: &Paths) -> Result<()> {
    let socket = paths.socket();
    if transport::is_pipe_path(socket) || !socket.exists() {
        return Ok(());
    }
    #[cfg(unix)]
    {
        match std::os::unix::net::UnixStream::connect(socket) {
            Ok(_) => bail!(
                "socket {} is in use by another process that does not hold the lock",
                socket.display()
            ),
            Err(_) => {
                std::fs::remove_file(socket)
                    .with_context(|| format!("removing stale socket {}", socket.display()))?;
                crate::svc_log!("nvim_ade_server: removed stale socket {}", socket.display());
            }
        }
    }
    Ok(())
}

fn socket_string(paths: &Paths) -> String {
    transport::socket_display(paths.socket())
}

/// Write the `ready` line to stdout and flush it, so the parent process that
/// waits on the pipe sees it immediately.
fn announce_ready(socket: &str) -> Result<()> {
    crate::output::print_line(&crate::output::ReadyOutput::new(
        socket.to_string(),
        std::process::id(),
    ))
}

enum ConnectionEvent {
    /// The connection authenticated as a participant (MCP): an ordinary chat's
    /// MCP socket must not keep the service from idle-exiting (20.1).
    Participant,
    Closed {
        counted: bool,
    },
}

#[cfg(test)]
mod tests {
    use super::*;

    fn env(pairs: &[(&str, &str)]) -> impl Fn(&str) -> Option<String> {
        let map: std::collections::HashMap<String, String> = pairs
            .iter()
            .map(|(key, value)| ((*key).to_string(), (*value).to_string()))
            .collect();
        move |key| map.get(key).cloned()
    }

    #[test]
    fn idle_timeout_defaults_to_thirty_minutes() {
        let timeout = idle_timeout_from(None, env(&[])).expect("default");
        assert_eq!(timeout, Duration::from_secs(1800));
        assert_eq!(timeout, DEFAULT_IDLE_TIMEOUT);
    }

    #[test]
    fn idle_timeout_reads_the_environment() {
        let timeout =
            idle_timeout_from(None, env(&[(IDLE_TIMEOUT_ENV, "2.5")])).expect("env value");
        assert_eq!(timeout, Duration::from_secs_f64(2.5));
    }

    #[test]
    fn idle_timeout_explicit_option_wins() {
        let timeout = idle_timeout_from(
            Some(Duration::from_secs(1)),
            env(&[(IDLE_TIMEOUT_ENV, "30")]),
        )
        .expect("explicit value");
        assert_eq!(timeout, Duration::from_secs(1));
    }

    #[test]
    fn idle_timeout_rejects_garbage() {
        assert!(idle_timeout_from(None, env(&[(IDLE_TIMEOUT_ENV, "soon")])).is_err());
        assert!(idle_timeout_from(None, env(&[(IDLE_TIMEOUT_ENV, "-1")])).is_err());
        assert!(idle_timeout_from(None, env(&[(IDLE_TIMEOUT_ENV, "nan")])).is_err());
    }

    #[test]
    fn empty_idle_timeout_env_is_ignored() {
        let timeout = idle_timeout_from(None, env(&[(IDLE_TIMEOUT_ENV, "  ")])).expect("default");
        assert_eq!(timeout, DEFAULT_IDLE_TIMEOUT);
    }
}
