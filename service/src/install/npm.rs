//! npm invocation for managed installs (PROTOCOL.md 16.3).
//!
//! Everything is argv-based and runs in its own process group (unix). The
//! parent keeps the end of the output and can stop the group with SIGTERM and,
//! after five seconds, SIGKILL.

use std::path::{Path, PathBuf};
use std::time::Duration;

use tokio::io::BufReader;
use tokio::process::{Child, Command};
use tokio::sync::{mpsc, watch};

use super::{valid_package, valid_version, MAX_OUTPUT_LINE};

pub const INSTALL_ARGS: &[&str] = &[
    "install",
    "--no-audit",
    "--no-fund",
    "--omit=dev",
    "--loglevel=notice",
    "--progress=false",
];

/// Write the synthetic manifest npm installs from (16.1).
pub fn write_manifest(dir: &Path, package: &str, version: &str) -> Result<(), String> {
    if !valid_package(package) || !valid_version(version) {
        return Err(
            "refusing to write a manifest with an unvalidated package or version".to_string(),
        );
    }
    let manifest = serde_json::json!({
        "name": "ade-nvim-managed",
        "private": true,
        "version": "0.0.0",
        "description": "Installed by ade.nvim; do not edit.",
        "dependencies": { package: version },
    });
    let path = dir.join("package.json");
    let encoded = serde_json::to_vec(&manifest)
        .map_err(|error| format!("unable to encode the manifest: {error}"))?;
    std::fs::write(&path, encoded)
        .map_err(|error| format!("unable to write {}: {error}", path.display()))
}

/// What the installed package's own `package.json` says (16.3).
pub struct Installed {
    pub version: String,
}

/// Verify `node_modules/<package>/package.json` names the requested package and
/// carries a usable version.
pub fn read_installed(dir: &Path, package: &str) -> Result<Installed, String> {
    let path = dir.join("node_modules").join(package).join("package.json");
    let text = std::fs::read(&path).map_err(|_| "the package was not installed".to_string())?;
    let value: serde_json::Value = serde_json::from_slice(&text)
        .map_err(|_| "the installed package.json is unreadable".to_string())?;
    if value.get("name").and_then(serde_json::Value::as_str) != Some(package) {
        return Err(format!(
            "installed package is {}, expected {package}",
            value
                .get("name")
                .and_then(serde_json::Value::as_str)
                .unwrap_or("?")
        ));
    }
    let version = value
        .get("version")
        .and_then(serde_json::Value::as_str)
        .filter(|version| valid_version(version))
        .ok_or_else(|| "the installed package has an unusable version".to_string())?;
    Ok(Installed {
        version: version.to_string(),
    })
}

/// One npm run's captured output.
pub struct Output {
    pub code: i32,
    /// The last [`super::FAILURE_LOG_BYTES`] bytes of the kept output (stderr
    /// when npm wrote any, exactly like the Lua runner's `tail`).
    pub tail: String,
    /// The last bytes of stdout, used to parse `npm view` (its JSON answer).
    pub stdout: String,
}

pub enum InstallOutcome {
    Ok(Output),
    Cancelled,
    Failed {
        message: String,
        log: Option<String>,
    },
}

/// Why one npm process did not produce usable output.
pub enum RunError {
    Cancelled,
    Failed {
        message: String,
        log: Option<String>,
    },
}

pub enum ResolveOutcome {
    Version(String),
    Cancelled,
    Failed { code: i64, message: String },
}

/// Reject an `npm` executable that is a command line instead of one program.
pub fn valid_npm(value: &str) -> bool {
    if value.is_empty() || value.chars().any(char::is_whitespace) {
        return false;
    }
    !value.contains('/') || Path::new(value).is_absolute()
}

fn build(npm: &str, args: &[&str], cwd: &Path, env: &[(String, String)]) -> Command {
    let mut command = Command::new(npm);
    command
        .args(args)
        .current_dir(cwd)
        .env_clear()
        .envs(env.iter().map(|(key, value)| (key, value)))
        .stdin(std::process::Stdio::null())
        .stdout(std::process::Stdio::piped())
        .stderr(std::process::Stdio::piped());
    #[cfg(unix)]
    {
        command.process_group(0);
    }
    #[cfg(windows)]
    {
        const CREATE_NEW_PROCESS_GROUP: u32 = 0x0000_0200;
        command.creation_flags(CREATE_NEW_PROCESS_GROUP);
    }
    command
}

#[cfg(unix)]
const SIGTERM: i32 = libc::SIGTERM;
#[cfg(unix)]
const SIGKILL: i32 = libc::SIGKILL;
#[cfg(not(unix))]
const SIGTERM: i32 = 15;
#[cfg(not(unix))]
const SIGKILL: i32 = 9;

#[cfg(unix)]
fn signal_group(pgid: i32, signal: i32) {
    // The child leads its own process group (process_group(0)).
    unsafe {
        libc::kill(-pgid, signal);
    }
}

#[cfg(not(unix))]
fn signal_group(_pgid: i32, _signal: i32) {}

/// Keeps the last `max` bytes of everything npm printed.
struct Log {
    bytes: Vec<u8>,
    max: usize,
}

impl Log {
    fn new(max: usize) -> Self {
        Self {
            bytes: Vec::new(),
            max: max.max(1),
        }
    }

    fn push_line(&mut self, line: &str) {
        self.bytes.extend_from_slice(line.as_bytes());
        self.bytes.push(b'\n');
        if self.bytes.len() > self.max {
            let excess = self.bytes.len() - self.max;
            self.bytes.drain(..excess);
        }
    }

    fn tail(&self, limit: usize) -> String {
        let mut start = self.bytes.len().saturating_sub(limit);
        while start < self.bytes.len() && std::str::from_utf8(&self.bytes[start..]).is_err() {
            start += 1;
        }
        String::from_utf8_lossy(&self.bytes[start..]).to_string()
    }
}

/// Upper bound for one npm output line; longer lines are drained and skipped.
const MAX_NPM_LINE: usize = 1024 * 1024;

/// Read one stream into `(is_stderr, line)` messages, with a hard line cap.
fn spawn_reader<R>(
    stream: R,
    is_stderr: bool,
    sender: mpsc::UnboundedSender<(bool, String)>,
) -> tokio::task::JoinHandle<()>
where
    R: tokio::io::AsyncRead + Unpin + Send + 'static,
{
    tokio::spawn(async move {
        let mut reader = BufReader::new(stream);
        loop {
            match crate::protocol::read_line_limited(&mut reader, MAX_NPM_LINE).await {
                Ok(crate::protocol::Line::Eof) | Err(_) => return,
                Ok(crate::protocol::Line::TooLong(_)) => continue,
                Ok(crate::protocol::Line::Text(text)) => {
                    // `read_line_limited` strips one trailing CR; npm also uses
                    // CR for progress lines, which are removed everywhere.
                    let text = text.replace('\r', "");
                    if sender.send((is_stderr, text)).is_err() {
                        return;
                    }
                }
            }
        }
    })
}

/// Stop the whole process group: SIGTERM, five seconds, SIGKILL.
///
/// The group id is captured at spawn time: once the leader is reaped,
/// `child.id()` is `None`, but `kill(-pgid, ...)` still reaches descendants that
/// ignored SIGTERM or are holding the pipes open.
async fn stop_group(pgid: Option<i32>) {
    if let Some(pgid) = pgid {
        signal_group(pgid, SIGTERM);
        tokio::time::sleep(Duration::from_secs(5)).await;
        signal_group(pgid, SIGKILL);
    }
}

async fn reap(child: &mut Child) {
    let _ = tokio::time::timeout(Duration::from_secs(2), child.wait()).await;
}

/// Wait for the reader tasks to see EOF, aborting any that are still held open
/// by a descendant after the process group was killed.
async fn finish_readers(readers: Vec<tokio::task::JoinHandle<()>>) {
    for mut reader in readers {
        if tokio::time::timeout(Duration::from_secs(2), &mut reader)
            .await
            .is_err()
        {
            reader.abort();
            let _ = reader.await;
        }
    }
}

/// Run npm and keep draining both pipes while it runs.
#[allow(clippy::too_many_arguments)]
async fn run(
    npm: &str,
    args: &[&str],
    cwd: &Path,
    env: &[(String, String)],
    timeout: Duration,
    max_log_bytes: usize,
    cancel: &mut watch::Receiver<bool>,
    on_line: Option<&(dyn Fn(String) + Send + Sync)>,
) -> Result<Output, RunError> {
    let echo = format!("$ {npm} {}", args.join(" "));
    if let Some(on_line) = on_line {
        on_line(echo);
    }
    let mut child = build(npm, args, cwd, env)
        .spawn()
        .map_err(|error| RunError::Failed {
            message: format!("unable to start {npm}: {error}"),
            log: None,
        })?;
    let pgid = child.id().map(|pid| pid as i32);
    let stdout = child.stdout.take();
    let stderr = child.stderr.take();
    let (lines_tx, mut lines_rx) = mpsc::unbounded_channel::<(bool, String)>();
    let mut readers = Vec::new();
    if let Some(stdout) = stdout {
        readers.push(spawn_reader(stdout, false, lines_tx.clone()));
    }
    if let Some(stderr) = stderr {
        readers.push(spawn_reader(stderr, true, lines_tx.clone()));
    }
    drop(lines_tx);

    // The reader handles are kept inside `spawn_reader`; there is no useful
    // join value, so the timeout/abort path only needs the line channel to
    // close. A descendant holding a pipe open would otherwise keep this loop
    // waiting after the group was killed.
    let mut log = Log::new(max_log_bytes);
    let mut stdout_log = Log::new(max_log_bytes);
    let mut stderr_log = Log::new(max_log_bytes);
    let mut cancelled = false;
    let mut timed_out = false;
    let deadline = tokio::time::Instant::now() + timeout;
    let mut status = None;
    let mut lines_closed = false;
    let mut drain_deadline: Option<tokio::time::Instant> = None;
    loop {
        let drain = async {
            match drain_deadline {
                Some(deadline) => tokio::time::sleep_until(deadline).await,
                None => std::future::pending().await,
            }
        };
        tokio::select! {
            line = lines_rx.recv(), if !lines_closed => {
                match line {
                    Some((stderr, line)) => {
                        consume_line(&mut log, &mut stdout_log, &mut stderr_log, stderr, &line, on_line)
                    }
                    None => lines_closed = true,
                }
            }
            changed = cancel.changed() => {
                match changed {
                    Ok(()) if *cancel.borrow() => cancelled = true,
                    // The hub went away or the job was dropped: stop the child
                    // rather than leaving it running.
                    Err(_) => cancelled = true,
                    Ok(()) => continue,
                }
                stop_group(pgid).await;
                reap(&mut child).await;
                break;
            }
            _ = tokio::time::sleep_until(deadline) => {
                timed_out = true;
                stop_group(pgid).await;
                reap(&mut child).await;
                break;
            }
            result = child.wait(), if status.is_none() => {
                status = Some(result.ok());
                // A descendant may still hold the pipes: do not wait forever.
                drain_deadline = Some(tokio::time::Instant::now() + Duration::from_secs(2));
            }
            _ = drain => break,
        }
        if lines_closed && status.is_some() {
            break;
        }
    }
    // Drain whatever the readers still had buffered.
    while let Ok((stderr, line)) = lines_rx.try_recv() {
        consume_line(
            &mut log,
            &mut stdout_log,
            &mut stderr_log,
            stderr,
            &line,
            on_line,
        );
    }
    finish_readers(readers).await;
    let tail = if stderr_log.bytes.is_empty() {
        log.tail(super::FAILURE_LOG_BYTES)
    } else {
        stderr_log.tail(super::FAILURE_LOG_BYTES)
    };
    if cancelled {
        return Err(RunError::Cancelled);
    }
    if timed_out {
        return Err(RunError::Failed {
            message: format!("npm timed out after {} ms", timeout.as_millis()),
            log: Some(tail),
        });
    }
    let code = status
        .flatten()
        .and_then(|status| status.code())
        .unwrap_or(-1);
    Ok(Output {
        code,
        tail,
        stdout: stdout_log.tail(max_log_bytes),
    })
}

fn consume_line(
    log: &mut Log,
    stdout_log: &mut Log,
    stderr_log: &mut Log,
    is_stderr: bool,
    line: &str,
    on_line: Option<&(dyn Fn(String) + Send + Sync)>,
) {
    if line.is_empty() {
        return;
    }
    log.push_line(line);
    if is_stderr {
        stderr_log.push_line(line);
    } else {
        stdout_log.push_line(line);
    }
    if let Some(on_line) = on_line {
        let mut cut = line.len().min(MAX_OUTPUT_LINE);
        while cut > 0 && !line.is_char_boundary(cut) {
            cut -= 1;
        }
        on_line(line[..cut].to_string());
    }
}

/// `npm install` into a release directory (16.3).
#[allow(clippy::too_many_arguments)]
pub async fn install(
    npm: &str,
    env: &[(String, String)],
    dir: &Path,
    package: &str,
    version: &str,
    timeout: Duration,
    max_log_bytes: usize,
    cancel: &mut watch::Receiver<bool>,
    on_line: &(dyn Fn(String) + Send + Sync),
) -> InstallOutcome {
    if let Err(message) = write_manifest(dir, package, version) {
        return InstallOutcome::Failed { message, log: None };
    }
    match run(
        npm,
        INSTALL_ARGS,
        dir,
        env,
        timeout,
        max_log_bytes,
        cancel,
        Some(on_line),
    )
    .await
    {
        Ok(output) if output.code == 0 => InstallOutcome::Ok(output),
        Ok(output) => InstallOutcome::Failed {
            message: format!("npm install failed with exit code {}", output.code),
            log: Some(output.tail),
        },
        Err(RunError::Cancelled) => InstallOutcome::Cancelled,
        Err(RunError::Failed { message, log }) => InstallOutcome::Failed { message, log },
    }
}

/// `npm view <package>@<spec> version --json` (16.3).
pub async fn resolve(
    npm: &str,
    env: &[(String, String)],
    root: &Path,
    package: &str,
    spec: &str,
    timeout: Duration,
    cancel: &mut watch::Receiver<bool>,
) -> ResolveOutcome {
    if !valid_package(package) {
        return ResolveOutcome::Failed {
            code: super::INVALID_PARAMETER,
            message: "invalid package name".to_string(),
        };
    }
    // `npm view` needs an existing cwd; use the nearest ancestor when the root
    // does not exist yet (16.3).
    let cwd = existing_ancestor(root);
    let spec_arg = format!("{package}@{spec}");
    let args = ["view", spec_arg.as_str(), "version", "--json"];
    match run(
        npm,
        &args,
        &cwd,
        env,
        timeout,
        super::DEFAULT_MAX_LOG_BYTES,
        cancel,
        None,
    )
    .await
    {
        Ok(output) => match parse_version(&output.stdout) {
            Ok(version) => ResolveOutcome::Version(version),
            Err(message) => ResolveOutcome::Failed {
                code: super::RESOLVE_FAILED,
                message,
            },
        },
        Err(RunError::Cancelled) => ResolveOutcome::Cancelled,
        Err(RunError::Failed { message, .. }) => {
            let code = if message.starts_with("unable to start") {
                super::INSTALL_FAILED
            } else {
                super::RESOLVE_FAILED
            };
            ResolveOutcome::Failed { code, message }
        }
    }
}

fn existing_ancestor(root: &Path) -> PathBuf {
    let mut current = Some(root);
    while let Some(path) = current {
        if path.is_dir() {
            return path.to_path_buf();
        }
        current = path.parent();
    }
    PathBuf::from("/")
}

/// `npm view` prints a JSON string (or an array); only the value matters.
fn preview(text: &str) -> &str {
    let mut end = text.len().min(80);
    while end > 0 && !text.is_char_boundary(end) {
        end -= 1;
    }
    &text[..end]
}

fn parse_version(stdout: &str) -> Result<String, String> {
    let text = stdout.trim();
    if text.is_empty() {
        return Err("npm view returned no version".to_string());
    }
    let value: serde_json::Value = serde_json::from_str(text)
        .map_err(|_| format!("npm view returned an unusable version: {}", preview(text)))?;
    let value = match value {
        serde_json::Value::Array(items) => {
            items.first().cloned().unwrap_or(serde_json::Value::Null)
        }
        other => other,
    };
    match value {
        serde_json::Value::String(version) if valid_version(&version) && version != "latest" => {
            Ok(version)
        }
        _ => Err(format!(
            "npm view returned an unusable version: {}",
            preview(text)
        )),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn npm_must_be_one_program() {
        assert!(valid_npm("npm"));
        assert!(valid_npm("/usr/bin/npm"));
        assert!(!valid_npm(""));
        assert!(!valid_npm("npm install"));
        assert!(!valid_npm("./npm"));
    }

    #[test]
    fn resolve_parses_a_string_and_an_array() {
        assert_eq!(parse_version("\"1.2.3\"\n").unwrap(), "1.2.3");
        assert_eq!(parse_version("[\"1.2.3\",\"1.2.4\"]").unwrap(), "1.2.3");
        assert!(parse_version("").is_err());
        assert!(parse_version("\"latest\"").is_err());
        assert!(parse_version("nonsense").is_err());
    }

    #[test]
    fn preview_cuts_at_a_character_boundary() {
        let text = format!("{}{}", "a".repeat(79), "é");
        assert_eq!(preview(&text), "a".repeat(79));
        assert!(std::str::from_utf8(preview(&text).as_bytes()).is_ok());
    }

    #[test]
    fn logs_keep_the_end() {
        let mut log = Log::new(10);
        log.push_line("0123456789");
        log.push_line("abc");
        assert!(log.bytes.len() <= 10);
        assert!(log.tail(10).contains("abc"));
    }
}
