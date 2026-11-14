//! The `serve` subcommand: bind the socket, guard against duplicates, and run
//! the connection loop.

use std::fs::{File, OpenOptions, TryLockError};
use std::io;
use std::path::PathBuf;
use std::sync::Arc;
use std::time::Duration;

use anyhow::{bail, Context, Result};
use tokio::io::{AsyncWriteExt, BufReader};
use tokio::sync::{mpsc, Notify};

use crate::paths::Paths;
use crate::protocol::{self, Handshake, Outcome};
use crate::transport::{self, Listener, Stream};
use crate::{token, API_VERSION};

/// Environment variable that overrides the idle timeout, in seconds (fractions
/// allowed, handy for tests).
pub const IDLE_TIMEOUT_ENV: &str = "NVIM_ADE_SERVER_IDLE_TIMEOUT_SECS";

/// Default idle timeout: exit after this long without any client.
pub const DEFAULT_IDLE_TIMEOUT: Duration = Duration::from_secs(600);

#[derive(Debug, Clone)]
pub struct ServeOptions {
    /// Explicit socket path (`--socket`), if any.
    pub socket: Option<PathBuf>,
    /// Idle timeout; `None` means "use the environment or the default".
    pub idle_timeout: Option<Duration>,
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
            eprintln!(
                "nvim_ade_server: generated token {}",
                paths.token_file().display()
            );
        }
        token::State::Replaced(reason) => {
            eprintln!(
                "nvim_ade_server: replaced token file {} ({}); clients must re-read it",
                paths.token_file().display(),
                reason.as_str()
            );
        }
    }

    let mut listener = Listener::bind(paths.socket())
        .with_context(|| format!("binding socket {}", socket_string(&paths)))?;
    let socket = socket_string(&paths);
    announce_ready(&socket)?;
    eprintln!(
        "nvim_ade_server {} (api {}) listening on {}",
        crate::SERVER_VERSION,
        API_VERSION,
        socket
    );

    let shutdown = Arc::new(Notify::new());
    let (events_tx, mut events_rx) = mpsc::unbounded_channel::<ConnectionEvent>();
    let mut active: usize = 0;
    // No client has connected yet, so the idle clock starts now.
    let mut idle_since = Some(tokio::time::Instant::now());

    let termination = termination_signal();
    tokio::pin!(termination);

    loop {
        let deadline = idle_since.map(|since| since + timeout);
        let sleeping = async {
            match deadline {
                Some(deadline) => tokio::time::sleep_until(deadline).await,
                None => std::future::pending().await,
            }
        };

        tokio::select! {
            biased;

            _ = shutdown.notified() => {
                eprintln!("nvim_ade_server: shutting down");
                break;
            }

            _ = &mut termination => {
                eprintln!("nvim_ade_server: terminated by a signal");
                break;
            }

            accepted = listener.accept() => {
                match accepted {
                    Ok(stream) => {
                        active += 1;
                        idle_since = None;
                        spawn_connection(stream, token.clone(), shutdown.clone(), events_tx.clone());
                    }
                    Err(error) => {
                        eprintln!("nvim_ade_server: accept failed: {error}");
                        // A transient failure (e.g. a client that vanished
                        // mid-handshake) must not kill the service; a broken
                        // listener must not spin forever either.
                        tokio::time::sleep(Duration::from_millis(100)).await;
                    }
                }
            }

            event = events_rx.recv() => {
                if let Some(ConnectionEvent::Closed) = event {
                    active = active.saturating_sub(1);
                    if active == 0 {
                        idle_since = Some(tokio::time::Instant::now());
                    }
                }
            }

            _ = sleeping => {
                eprintln!(
                    "nvim_ade_server: no clients for {}s, exiting",
                    duration_secs(timeout)
                );
                break;
            }
        }
    }

    listener.cleanup();
    drop(lock);
    Ok(ServeStatus::Exited { socket })
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
            eprintln!("nvim_ade_server: cannot watch SIGTERM: {error}");
            return std::future::pending().await;
        }
    };
    let mut interrupt = match signal(SignalKind::interrupt()) {
        Ok(stream) => stream,
        Err(error) => {
            eprintln!("nvim_ade_server: cannot watch SIGINT: {error}");
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

fn spawn_connection(
    stream: Stream,
    token: String,
    shutdown: Arc<Notify>,
    events: mpsc::UnboundedSender<ConnectionEvent>,
) {
    tokio::spawn(async move {
        if let Err(error) = handle_connection(stream, &token, &shutdown).await {
            eprintln!("nvim_ade_server: connection error: {error}");
        }
        let _ = events.send(ConnectionEvent::Closed);
    });
}

async fn handle_connection(stream: Stream, token: &str, shutdown: &Notify) -> io::Result<()> {
    let (reader, mut writer) = tokio::io::split(stream);
    let mut reader = BufReader::new(reader);
    let mut handshake = Handshake::default();

    loop {
        let line = match protocol::read_message(&mut reader).await {
            Ok(Some(line)) => line,
            Ok(None) => return Ok(()),
            // A client that goes away mid-line is a normal disconnect, not an
            // error worth reporting.
            Err(error)
                if error.kind() == io::ErrorKind::BrokenPipe
                    || error.kind() == io::ErrorKind::UnexpectedEof
                    || error.kind() == io::ErrorKind::ConnectionReset =>
            {
                return Ok(())
            }
            Err(error) if error.kind() == io::ErrorKind::InvalidData => {
                // Framing errors are per-connection: the stream cannot be
                // resynchronised, so drop this client.
                eprintln!("nvim_ade_server: dropping client: {error}");
                return Ok(());
            }
            Err(error) => return Err(error),
        };
        if line.trim().is_empty() {
            continue;
        }

        let was_authenticated = handshake.is_authenticated();
        let outcome = protocol::handle_line(&mut handshake, token, API_VERSION, &line);
        let close = outcome.close;
        let stopping = outcome.shutdown;
        write_outcome(&mut writer, outcome).await?;
        if !was_authenticated && handshake.is_authenticated() {
            eprintln!(
                "nvim_ade_server: client {} ({}) authenticated",
                handshake.client().unwrap_or("unknown"),
                handshake.client_version().unwrap_or("unknown")
            );
        }
        if stopping {
            // `notify_one` keeps a permit if the main loop is not waiting yet,
            // so this signal cannot be lost.
            shutdown.notify_one();
            return Ok(());
        }
        if close {
            return Ok(());
        }
    }
}

async fn write_outcome<W>(writer: &mut W, outcome: Outcome) -> io::Result<()>
where
    W: tokio::io::AsyncWrite + Unpin,
{
    if let Some(response) = outcome.response {
        protocol::write_message(writer, &response).await?;
    }
    if outcome.close || outcome.shutdown {
        // Half-close so the client sees a clean end of stream.
        writer.shutdown().await?;
    }
    Ok(())
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
                eprintln!("nvim_ade_server: removed stale socket {}", socket.display());
            }
        }
    }
    Ok(())
}

fn socket_string(paths: &Paths) -> String {
    transport::socket_display(paths.socket())
}

/// Write the `ready` line to stdout and flush it, so a parent process waiting
/// on the pipe sees it immediately.
/// Write the `ready` line to stdout and flush it, so the parent process that
/// waits on the pipe sees it immediately.
fn announce_ready(socket: &str) -> Result<()> {
    crate::output::print_line(&crate::output::ReadyOutput::new(
        socket.to_string(),
        std::process::id(),
    ))
}

enum ConnectionEvent {
    Closed,
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
    fn idle_timeout_defaults_to_ten_minutes() {
        let timeout = idle_timeout_from(None, env(&[])).expect("default");
        assert_eq!(timeout, Duration::from_secs(600));
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
