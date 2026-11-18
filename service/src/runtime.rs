//! Agent processes (PROTOCOL.md section 6).
//!
//! One instance is one child process. This module owns the mechanics: spawn
//! with the right environment and process group, read stdout as lines, keep the
//! last 64 KiB of stderr, serialise writes through one queue, and stop the
//! process with the documented sequence.
//!
//! Events are reported to the hub through an [`RuntimeEvent`] channel, so the
//! relay and the API stay free of process handling. The exit details are also
//! stored in [`Exited`], which lets `agent.stop` wait for the process without
//! depending on the hub loop.

use std::collections::VecDeque;
use std::io;
use std::path::PathBuf;
use std::process::Stdio;
use std::sync::{Arc, Mutex};
use std::time::Duration;

use serde_json::Value;
use tokio::io::{AsyncReadExt, AsyncWriteExt, BufReader};
use tokio::process::{Child, ChildStdin, Command};
use tokio::sync::{mpsc, watch};

use crate::protocol::{self, Line};

/// Maximum length of one stdout line from the agent. A longer line is dropped.
///
/// PROTOCOL.md section 6. It is deliberately lower than the front-end limit in
/// section 2, so a hostile agent cannot make the service buffer 64 MiB per line.
#[allow(dead_code)] // kept next to the reader for documentation
pub const MAX_AGENT_LINE_BYTES: usize = 32 * 1024 * 1024;
/// How much of the child's stderr is kept for `agent.exited`.
pub const STDERR_TAIL_BYTES: usize = 64 * 1024;

/// Default stop timings: close stdin, wait 3 s, SIGTERM, wait 3 s, SIGKILL.
pub const DEFAULT_STOP_TIMEOUT: Duration = Duration::from_secs(3);

/// Environment variable that shortens the stop timeouts (tests). Milliseconds.
pub const STOP_TIMEOUT_ENV: &str = "NVIM_ADE_SERVER_STOP_TIMEOUT_MS";

/// How long `agent.stop` waits at each step.
#[derive(Debug, Clone, Copy)]
pub struct StopTimeouts {
    /// Wait this long after closing stdin.
    pub after_stdin: Duration,
    /// Wait this long after SIGTERM before SIGKILL.
    pub after_term: Duration,
}

impl Default for StopTimeouts {
    fn default() -> Self {
        Self {
            after_stdin: DEFAULT_STOP_TIMEOUT,
            after_term: DEFAULT_STOP_TIMEOUT,
        }
    }
}

impl StopTimeouts {
    /// Read [`STOP_TIMEOUT_ENV`] (milliseconds) when set.
    pub fn from_env() -> Self {
        Self::from_lookup(|key| std::env::var(key).ok())
    }

    pub fn from_lookup<F>(lookup: F) -> Self
    where
        F: Fn(&str) -> Option<String>,
    {
        match lookup(STOP_TIMEOUT_ENV).and_then(|value| value.trim().parse::<u64>().ok()) {
            Some(milliseconds) => {
                let timeout = Duration::from_millis(milliseconds);
                Self {
                    after_stdin: timeout,
                    after_term: timeout,
                }
            }
            None => Self::default(),
        }
    }
}

/// How a process ended, as `agent.exited` and `agent.stop` report it.
#[derive(Debug, Clone, Default, PartialEq)]
pub struct ExitInfo {
    pub code: Option<i32>,
    pub signal: Option<String>,
    pub stderr_tail: String,
}

/// Exit details of one instance, filled exactly once.
///
/// `agent.stop` and the shutdown path can both wait for the same exit, so this
/// is a `watch` channel rather than a one-shot signal: every waiter sees the
/// value, whenever it starts waiting.
#[derive(Debug)]
pub struct Exited {
    sender: watch::Sender<Option<ExitInfo>>,
    receiver: watch::Receiver<Option<ExitInfo>>,
}

impl Exited {
    pub fn new() -> Arc<Self> {
        let (sender, receiver) = watch::channel(None);
        Arc::new(Self { sender, receiver })
    }

    fn set(&self, info: ExitInfo) {
        // `send_replace` also works when no receiver is left.
        self.sender.send_replace(Some(info));
    }

    pub fn get(&self) -> Option<ExitInfo> {
        self.receiver.borrow().clone()
    }

    /// Wait until the process exited, or `timeout` elapses.
    pub async fn wait(&self, timeout: Duration) -> Option<ExitInfo> {
        if let Some(info) = self.get() {
            return Some(info);
        }
        let mut receiver = self.receiver.clone();
        let result = tokio::time::timeout(timeout, async {
            loop {
                if receiver.borrow().is_some() {
                    return;
                }
                if receiver.changed().await.is_err() {
                    return;
                }
            }
        })
        .await;
        match result {
            Ok(()) => self.get(),
            Err(_) => self.get(),
        }
    }
}

/// What the hub must do for one instance.
#[derive(Debug)]
pub enum RuntimeEvent {
    /// One line of stdout, without its newline.
    Stdout { instance: String, text: String },
    /// A stdout line exceeded [`MAX_AGENT_LINE_BYTES`] and was dropped.
    StdoutTooLong { instance: String },
    /// The process ended (for any reason) and the instance is gone. The
    /// details are in the instance's [`Exited`].
    Exited { instance: String },
}

/// How to start the child.
#[derive(Debug, Clone)]
pub struct SpawnSpec {
    pub command: String,
    pub args: Vec<String>,
    pub cwd: PathBuf,
    /// Complete environment, or `None` to inherit the service's.
    pub env: Option<Vec<(String, String)>>,
}

/// Handle used to talk to and stop a running instance.
#[derive(Debug, Clone)]
pub struct ProcControl {
    pub pid: u32,
    stop: mpsc::Sender<StopCommand>,
    /// Unbounded on purpose: the queue must never drop a frame, and order is
    /// what matters here (PROTOCOL.md section 6).
    writer: mpsc::UnboundedSender<WriterCommand>,
}

/// A process that has been started.
pub struct Started {
    pub pid: u32,
    pub control: ProcControl,
}

#[derive(Debug)]
enum WriterCommand {
    Frame(Value),
    Close,
}

#[derive(Debug)]
struct StopCommand {
    force: bool,
    timeouts: StopTimeouts,
}

/// Start the child and the tasks that feed [`RuntimeEvent`]s.
pub fn start(
    instance: String,
    spec: SpawnSpec,
    timeouts_default: StopTimeouts,
    events: mpsc::UnboundedSender<RuntimeEvent>,
    exited: Arc<Exited>,
) -> io::Result<Started> {
    let mut child = build_command(&spec).spawn()?;
    let pid = child
        .id()
        .ok_or_else(|| io::Error::other("the child has no process id"))?;

    let stdin = child.stdin.take();
    let stdout = child.stdout.take();
    let stderr = child.stderr.take();
    let tail = Arc::new(Mutex::new(StderrTail::new(STDERR_TAIL_BYTES)));

    if let Some(stdout) = stdout {
        let events = events.clone();
        let instance = instance.clone();
        tokio::spawn(async move {
            read_stdout(&instance, stdout, &events).await;
        });
    }
    if let Some(stderr) = stderr {
        let tail = Arc::clone(&tail);
        tokio::spawn(async move {
            read_stderr(stderr, tail).await;
        });
    }

    let (writer_tx, writer_rx) = mpsc::unbounded_channel::<WriterCommand>();
    if let Some(stdin) = stdin {
        tokio::spawn(async move {
            write_stdin(stdin, writer_rx).await;
        });
    }

    let (stop_tx, stop_rx) = mpsc::channel::<StopCommand>(1);
    tokio::spawn(async move {
        supervise(
            child,
            instance,
            events,
            stop_rx,
            tail,
            exited,
            timeouts_default,
        )
        .await;
    });

    Ok(Started {
        pid,
        control: ProcControl {
            pid,
            stop: stop_tx,
            writer: writer_tx,
        },
    })
}

fn build_command(spec: &SpawnSpec) -> Command {
    let mut command = Command::new(&spec.command);
    command
        .args(&spec.args)
        .current_dir(&spec.cwd)
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped());
    #[cfg(unix)]
    {
        // Own process group: the agent keeps running when the service's
        // terminal goes away, and `agent.stop` can reach its children.
        command.process_group(0);
    }
    #[cfg(windows)]
    {
        const CREATE_NEW_PROCESS_GROUP: u32 = 0x0000_0200;
        command.creation_flags(CREATE_NEW_PROCESS_GROUP);
    }
    match &spec.env {
        Some(pairs) => {
            // `env` is the COMPLETE environment: nothing leaks from the
            // service.
            command.env_clear();
            command.envs(pairs.iter().map(|(key, value)| (key, value)));
        }
        None => {
            // Inherit (tests only; the front end always sends `env`).
        }
    }
    command
}

impl ProcControl {
    /// Queue one frame for the agent. The channel preserves order.
    ///
    /// Returns false when the writer is gone (the agent is exiting).
    pub fn send_frame(&self, frame: Value) -> bool {
        self.writer.send(WriterCommand::Frame(frame)).is_ok()
    }

    /// A control handle detached from any process, for tests that only need
    /// the struct.
    #[cfg(test)]
    pub fn dummy(pid: u32) -> Self {
        let (stop, _stop_rx) = mpsc::channel(1);
        let (writer, _writer_rx) = mpsc::unbounded_channel();
        Self { pid, stop, writer }
    }

    /// Ask the writer task to close stdin, so a well-behaved agent exits.
    pub fn close_stdin(&self) {
        let _ = self.writer.send(WriterCommand::Close);
    }

    /// Stop the process; resolves after the stop sequence was requested.
    /// The actual exit is observed through the instance's [`Exited`].
    pub async fn stop(&self, force: bool, timeouts: StopTimeouts) {
        self.close_stdin();
        let _ = self.stop.send(StopCommand { force, timeouts }).await;
    }
}

async fn write_stdin(mut stdin: ChildStdin, mut commands: mpsc::UnboundedReceiver<WriterCommand>) {
    while let Some(command) = commands.recv().await {
        match command {
            WriterCommand::Frame(value) => {
                let mut bytes = match serde_json::to_vec(&value) {
                    Ok(bytes) => bytes,
                    Err(error) => {
                        crate::svc_log!(
                            "nvim_ade_server: cannot serialize a frame for the agent: {error}"
                        );
                        continue;
                    }
                };
                bytes.push(b'\n');
                if let Err(error) = stdin.write_all(&bytes).await {
                    crate::svc_log!("nvim_ade_server: writing to the agent failed: {error}");
                    return;
                }
                if let Err(error) = stdin.flush().await {
                    crate::svc_log!("nvim_ade_server: flushing to the agent failed: {error}");
                    return;
                }
            }
            WriterCommand::Close => return,
        }
    }
}

async fn read_stdout(
    instance: &str,
    stdout: tokio::process::ChildStdout,
    events: &mpsc::UnboundedSender<RuntimeEvent>,
) {
    let mut reader = BufReader::new(stdout);
    loop {
        match protocol::read_line_limited(&mut reader, MAX_AGENT_LINE_BYTES).await {
            Ok(Line::Text(text)) => {
                if events
                    .send(RuntimeEvent::Stdout {
                        instance: instance.to_string(),
                        text,
                    })
                    .is_err()
                {
                    return;
                }
            }
            Ok(Line::TooLong(_)) => {
                if events
                    .send(RuntimeEvent::StdoutTooLong {
                        instance: instance.to_string(),
                    })
                    .is_err()
                {
                    return;
                }
            }
            Ok(Line::Eof) => return,
            Err(error) if error.kind() == io::ErrorKind::InvalidData => {
                crate::svc_log!("nvim_ade_server: dropping invalid agent stdout line: {error}");
            }
            Err(error) => {
                crate::svc_log!("nvim_ade_server: reading agent stdout failed: {error}");
                return;
            }
        }
    }
}

async fn read_stderr(mut stderr: tokio::process::ChildStderr, tail: Arc<Mutex<StderrTail>>) {
    let mut buffer = [0u8; 8192];
    loop {
        match stderr.read(&mut buffer).await {
            Ok(0) => return,
            Ok(read) => {
                if let Ok(mut tail) = tail.lock() {
                    tail.push(&buffer[..read]);
                }
            }
            Err(error) if error.kind() == io::ErrorKind::Interrupted => continue,
            Err(_) => return,
        }
    }
}

/// Owns the child: waits for its exit and performs stop sequences.
async fn supervise(
    mut child: Child,
    instance: String,
    events: mpsc::UnboundedSender<RuntimeEvent>,
    mut stop_rx: mpsc::Receiver<StopCommand>,
    tail: Arc<Mutex<StderrTail>>,
    exited: Arc<Exited>,
    defaults: StopTimeouts,
) {
    loop {
        tokio::select! {
            status = child.wait() => {
                let info = finish(status, &tail);
                exited.set(info);
                let _ = events.send(RuntimeEvent::Exited { instance });
                return;
            }
            command = stop_rx.recv() => {
                let Some(command) = command else {
                    // Nobody can ask for a stop any more; keep waiting for the
                    // process itself.
                    continue;
                };
                let timeouts = if command.timeouts.after_stdin.is_zero()
                    && command.timeouts.after_term.is_zero()
                {
                    defaults
                } else {
                    command.timeouts
                };
                let status = stop_sequence(&mut child, command.force, timeouts).await;
                let info = finish(status, &tail);
                exited.set(info);
                let _ = events.send(RuntimeEvent::Exited { instance });
                return;
            }
        }
    }
}

fn finish(status: io::Result<std::process::ExitStatus>, tail: &Arc<Mutex<StderrTail>>) -> ExitInfo {
    let (code, signal) = exit_details(status);
    let stderr_tail = tail
        .lock()
        .map(|tail| tail.to_string_lossy())
        .unwrap_or_default();
    ExitInfo {
        code,
        signal,
        stderr_tail,
    }
}

async fn stop_sequence(
    child: &mut Child,
    force: bool,
    timeouts: StopTimeouts,
) -> io::Result<std::process::ExitStatus> {
    if force {
        // Straight to SIGKILL, per PROTOCOL.md 3.4.
        terminate(child, true);
        return child.wait().await;
    }

    // stdin was closed by `ProcControl::stop`; a well-behaved agent exits.
    if let Ok(status) = tokio::time::timeout(timeouts.after_stdin, child.wait()).await {
        return status;
    }
    terminate(child, false);
    if let Ok(status) = tokio::time::timeout(timeouts.after_term, child.wait()).await {
        return status;
    }
    terminate(child, true);
    child.wait().await
}

#[cfg(unix)]
fn terminate(child: &mut Child, force: bool) {
    let Some(pid) = child.id() else {
        return;
    };
    let Some(target) = group_target(pid) else {
        // Refusing to signal is the safe choice: `kill(0, …)` would signal the
        // service's own process group.
        crate::svc_log!(
            "nvim_ade_server: refusing to signal agent pid {pid}: not a usable process group id"
        );
        return;
    };
    let signal = if force { libc::SIGKILL } else { libc::SIGTERM };
    // The child leads its own process group (`process_group(0)`), so a
    // negative pid reaches it and every process it started.
    //
    // SAFETY: `kill` with a negative pid signals a process group. `group_target`
    // guarantees the pid is non-zero and fits in `pid_t`, so `-target` cannot
    // accidentally mean "my own process group" or overflow.
    unsafe {
        libc::kill(-target, signal);
    }
}

/// The process-group id to signal for an agent pid.
///
/// `kill(0, …)` targets the caller's own process group and a value that does
/// not fit `pid_t` would wrap; both are dangerous, so they yield `None`.
#[cfg(unix)]
fn group_target(pid: u32) -> Option<i32> {
    if pid == 0 || pid > i32::MAX as u32 {
        return None;
    }
    Some(pid as i32)
}

#[cfg(not(unix))]
fn terminate(child: &mut Child, _force: bool) {
    // Windows has no SIGTERM and no kill(-pid): TerminateProcess is the only
    // available action, so an unresponsive agent is always killed. Children are
    // not part of a job object yet, so they are not reached; this is noted in
    // the report as unverified/limited.
    let _ = child.start_kill();
}

fn exit_details(status: io::Result<std::process::ExitStatus>) -> (Option<i32>, Option<String>) {
    match status {
        Ok(status) => {
            #[cfg(unix)]
            {
                use std::os::unix::process::ExitStatusExt;
                if let Some(signal) = status.signal() {
                    return (status.code(), Some(signal_name(signal)));
                }
            }
            (status.code(), None)
        }
        Err(error) => {
            crate::svc_log!("nvim_ade_server: waiting for the agent failed: {error}");
            (None, None)
        }
    }
}

#[cfg(unix)]
fn signal_name(signal: i32) -> String {
    match signal {
        libc::SIGTERM => "SIGTERM".to_string(),
        libc::SIGKILL => "SIGKILL".to_string(),
        libc::SIGINT => "SIGINT".to_string(),
        libc::SIGHUP => "SIGHUP".to_string(),
        libc::SIGQUIT => "SIGQUIT".to_string(),
        libc::SIGSEGV => "SIGSEGV".to_string(),
        libc::SIGABRT => "SIGABRT".to_string(),
        libc::SIGPIPE => "SIGPIPE".to_string(),
        other => format!("SIG{other}"),
    }
}

/// The last `capacity` bytes of a stream.
#[derive(Debug)]
pub struct StderrTail {
    bytes: VecDeque<u8>,
    capacity: usize,
}

impl StderrTail {
    pub fn new(capacity: usize) -> Self {
        Self {
            bytes: VecDeque::with_capacity(capacity.min(64 * 1024)),
            capacity,
        }
    }

    pub fn push(&mut self, data: &[u8]) {
        if data.len() >= self.capacity {
            self.bytes.clear();
            self.bytes
                .extend(data[data.len() - self.capacity..].iter().copied());
            return;
        }
        let overflow = (self.bytes.len() + data.len()).saturating_sub(self.capacity);
        for _ in 0..overflow {
            self.bytes.pop_front();
        }
        self.bytes.extend(data.iter().copied());
    }

    pub fn len(&self) -> usize {
        self.bytes.len()
    }

    pub fn is_empty(&self) -> bool {
        self.bytes.is_empty()
    }

    /// Lossy UTF-8 view, as `agent.exited` reports it.
    pub fn to_string_lossy(&self) -> String {
        let bytes: Vec<u8> = self.bytes.iter().copied().collect();
        String::from_utf8_lossy(&bytes).to_string()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn stderr_tail_keeps_only_the_last_bytes() {
        let mut tail = StderrTail::new(8);
        tail.push(b"0123456789");
        assert_eq!(tail.len(), 8);
        assert_eq!(tail.to_string_lossy(), "23456789");
        tail.push(b"ab");
        assert_eq!(tail.to_string_lossy(), "456789ab");
    }

    #[test]
    fn stderr_tail_handles_a_single_oversized_chunk() {
        let mut tail = StderrTail::new(4);
        tail.push(b"0123456789");
        assert_eq!(tail.to_string_lossy(), "6789");
    }

    #[test]
    fn stderr_tail_handles_partial_utf8_lossily() {
        let mut tail = StderrTail::new(4);
        tail.push(&[0xC3]);
        assert!(tail.to_string_lossy().contains('\u{FFFD}'));
    }

    #[cfg(unix)]
    #[test]
    fn a_zero_or_oversized_pid_is_never_signalled() {
        // `kill(0, …)` would signal the service's own process group, and a pid
        // above `i32::MAX` would wrap when negated.
        assert_eq!(group_target(0), None);
        assert_eq!(group_target(i32::MAX as u32 + 1), None);
        assert_eq!(group_target(u32::MAX), None);
    }

    #[cfg(unix)]
    #[test]
    fn a_normal_pid_becomes_a_negative_group_target() {
        assert_eq!(group_target(1), Some(1));
        assert_eq!(group_target(4242), Some(4242));
        assert_eq!(group_target(i32::MAX as u32), Some(i32::MAX));
    }

    #[test]
    fn stop_timeouts_default_to_three_seconds() {
        let timeouts = StopTimeouts::default();
        assert_eq!(timeouts.after_stdin, Duration::from_secs(3));
        assert_eq!(timeouts.after_term, Duration::from_secs(3));
    }

    #[test]
    fn stop_timeouts_read_the_environment() {
        let timeouts = StopTimeouts::from_lookup(|key| {
            if key == STOP_TIMEOUT_ENV {
                Some("50".to_string())
            } else {
                None
            }
        });
        assert_eq!(timeouts.after_stdin, Duration::from_millis(50));
        assert_eq!(timeouts.after_term, Duration::from_millis(50));
    }

    #[test]
    fn stop_timeouts_ignore_garbage() {
        let timeouts = StopTimeouts::from_lookup(|_| Some("soon".to_string()));
        assert_eq!(timeouts.after_stdin, DEFAULT_STOP_TIMEOUT);
    }

    #[tokio::test]
    async fn exited_reports_after_it_is_set() {
        let exited = Exited::new();
        assert_eq!(exited.get(), None);
        exited.set(ExitInfo {
            code: Some(0),
            signal: None,
            stderr_tail: "bye".to_string(),
        });
        let info = exited
            .wait(Duration::from_secs(1))
            .await
            .expect("exit info");
        assert_eq!(info.code, Some(0));
        assert_eq!(info.stderr_tail, "bye");
    }

    #[tokio::test]
    async fn exited_wait_times_out_when_nothing_happens() {
        let exited = Exited::new();
        assert_eq!(exited.wait(Duration::from_millis(20)).await, None);
    }
}
