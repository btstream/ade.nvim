//! The single JSON line each command writes to stdout.
//!
//! The field order follows `.acp-work/contract.md` exactly. The front end
//! parses JSON so order does not matter in practice, but a stable output makes
//! logs and tests easier to read (and `version` is compared as text in tests).

use std::io::Write;

use anyhow::Result;
use serde::Serialize;

use crate::{API_VERSION, SERVER_VERSION};

#[derive(Debug, Serialize)]
pub struct VersionOutput {
    pub version: &'static str,
    pub api_version: i64,
}

#[derive(Debug, Serialize)]
pub struct ReadyOutput {
    pub status: &'static str,
    pub socket: String,
    pub pid: u32,
}

#[derive(Debug, Serialize)]
pub struct AlreadyRunningOutput {
    pub status: &'static str,
    pub socket: String,
}

#[derive(Debug, Serialize)]
pub struct ErrorOutput<'a> {
    pub status: &'static str,
    pub message: &'a str,
}

/// `serve --print-paths` output; not part of the front-end contract.
#[derive(Debug, Serialize)]
pub struct PathsOutput {
    pub dir: String,
    pub socket: String,
    pub token: String,
    pub lock: String,
    pub log: String,
}

impl VersionOutput {
    pub fn current() -> Self {
        Self {
            version: SERVER_VERSION,
            api_version: API_VERSION,
        }
    }
}

impl ReadyOutput {
    pub fn new(socket: String, pid: u32) -> Self {
        Self {
            status: "ready",
            socket,
            pid,
        }
    }
}

impl AlreadyRunningOutput {
    pub fn new(socket: String) -> Self {
        Self {
            status: "already_running",
            socket,
        }
    }
}

impl<'a> ErrorOutput<'a> {
    pub fn new(message: &'a str) -> Self {
        Self {
            status: "error",
            message,
        }
    }
}

/// Serialize `value` as one compact line on stdout and flush it. Flushing
/// matters for `ready`: the front end waits on this line.
pub fn print_line<T: Serialize>(value: &T) -> Result<()> {
    let line = serde_json::to_string(value)?;
    let mut stdout = std::io::stdout().lock();
    writeln!(stdout, "{line}")?;
    stdout.flush()?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn version_has_the_contracted_shape() {
        let line = serde_json::to_string(&VersionOutput::current()).expect("serialize");
        assert_eq!(
            line,
            format!(
                "{{\"version\":\"{}\",\"api_version\":{}}}",
                env!("CARGO_PKG_VERSION"),
                API_VERSION
            )
        );
    }

    #[test]
    fn ready_has_the_contracted_shape() {
        let line =
            serde_json::to_string(&ReadyOutput::new("/tmp/s.sock".to_string(), 42)).expect("ser");
        assert_eq!(
            line,
            "{\"status\":\"ready\",\"socket\":\"/tmp/s.sock\",\"pid\":42}"
        );
    }

    #[test]
    fn already_running_has_the_contracted_shape() {
        let line = serde_json::to_string(&AlreadyRunningOutput::new("/tmp/s.sock".to_string()))
            .expect("serialize");
        assert_eq!(
            line,
            "{\"status\":\"already_running\",\"socket\":\"/tmp/s.sock\"}"
        );
    }

    #[test]
    fn error_has_the_contracted_shape() {
        let line = serde_json::to_string(&ErrorOutput::new("boom")).expect("serialize");
        assert_eq!(line, "{\"status\":\"error\",\"message\":\"boom\"}");
    }
}
