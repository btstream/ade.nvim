//! Command line entry point of `nvim_ade_server`.
//!
//! stdout is reserved for one line of JSON per run (see `.acp-work/contract.md`);
//! logs go to stderr. The output shapes live in [`nvim_ade_server::output`].

use std::path::PathBuf;
use std::process::ExitCode;
use std::time::Duration;

use anyhow::Result;
use clap::{Parser, Subcommand};

use nvim_ade_server::output::{
    print_line, AlreadyRunningOutput, ErrorOutput, PathsOutput, VersionOutput,
};
use nvim_ade_server::paths::Paths;
use nvim_ade_server::server::{self, ServeOptions, ServeStatus};
use nvim_ade_server::team::mcp;
use nvim_ade_server::SERVER_VERSION;

/// Exit code for a failed start (the contract fixes this at 1).
const EXIT_FAILURE: u8 = 1;
#[derive(Debug, Parser)]
#[command(
    name = "nvim_ade_server",
    version = SERVER_VERSION,
    about = "Background service for ade.nvim",
    disable_help_subcommand = true
)]
struct Cli {
    #[command(subcommand)]
    command: Command,
}

/// `--event-log on|off`.
#[derive(Debug, Clone, Copy, PartialEq, Eq, clap::ValueEnum)]
enum EventLogFlag {
    On,
    Off,
}

impl EventLogFlag {
    fn enabled(self) -> bool {
        matches!(self, Self::On)
    }
}

#[derive(Debug, Subcommand)]
enum Command {
    /// Run the service.
    Serve {
        /// Override the socket path (unix) or named pipe (Windows).
        #[arg(long, value_name = "PATH")]
        socket: Option<PathBuf>,

        /// Exit after this many seconds without any client (default: 1800,
        /// or NVIM_ADE_SERVER_IDLE_TIMEOUT_SECS).
        #[arg(long, value_name = "SECONDS")]
        idle_timeout: Option<f64>,

        /// Print the resolved paths as JSON and exit, without binding anything.
        #[arg(long)]
        print_paths: bool,

        /// Event log for conversation replay (PROTOCOL.md section 10).
        #[arg(long, value_name = "on|off", default_value = "on")]
        event_log: EventLogFlag,

        /// Per-instance event log cap in MiB (16 to 4096).
        #[arg(long, value_name = "MB", default_value_t = server::DEFAULT_EVENT_LOG_MAX_MB)]
        event_log_max_mb: u64,
    },

    /// Print the service version and the protocol version as JSON.
    Version,

    /// MCP server for a team participant (reads ADE_TEAM_TOKEN).
    Mcp,
}

fn main() -> ExitCode {
    match Cli::parse().command {
        Command::Version => match print_line(&VersionOutput::current()) {
            Ok(()) => ExitCode::SUCCESS,
            Err(error) => fail(&error, false),
        },
        Command::Mcp => mcp::run(),
        Command::Serve {
            socket,
            idle_timeout,
            print_paths,
            event_log,
            event_log_max_mb,
        } => {
            if print_paths {
                return match print_paths_json(socket) {
                    Ok(()) => ExitCode::SUCCESS,
                    Err(error) => fail(&error, false),
                };
            }
            match server::validate_event_log_max_mb(event_log_max_mb) {
                Ok(max_mb) => serve(socket, idle_timeout, event_log.enabled(), max_mb),
                Err(error) => fail(&error, true),
            }
        }
    }
}

fn print_paths_json(socket: Option<PathBuf>) -> Result<()> {
    let paths = match socket {
        Some(socket) => Paths::with_socket(socket)?,
        None => Paths::resolve()?,
    };
    print_line(&PathsOutput {
        dir: paths.dir().display().to_string(),
        socket: paths.socket().display().to_string(),
        token: paths.token_file().display().to_string(),
        lock: paths.lock_file().display().to_string(),
    })
}

fn serve(
    socket: Option<PathBuf>,
    idle_timeout: Option<f64>,
    event_log: bool,
    event_log_max_mb: u64,
) -> ExitCode {
    let options = ServeOptions {
        socket,
        // A non-positive or non-finite timeout means "exit as soon as idle".
        idle_timeout: idle_timeout.map(|seconds| {
            Duration::from_secs_f64(if seconds.is_finite() && seconds > 0.0 {
                seconds
            } else {
                0.0
            })
        }),
        stop_timeouts: None,
        event_log,
        event_log_max_mb,
    };

    let runtime = match tokio::runtime::Builder::new_multi_thread()
        .enable_all()
        .build()
    {
        Ok(runtime) => runtime,
        Err(error) => {
            return fail(
                &anyhow::anyhow!("cannot start the async runtime: {error}"),
                true,
            )
        }
    };

    match runtime.block_on(server::serve(options)) {
        Ok(ServeStatus::AlreadyRunning { socket }) => {
            match print_line(&AlreadyRunningOutput::new(socket)) {
                Ok(()) => ExitCode::SUCCESS,
                Err(error) => fail(&error, false),
            }
        }
        Ok(ServeStatus::Exited { socket }) => {
            eprintln!("nvim_ade_server: stopped, socket {socket} removed");
            ExitCode::SUCCESS
        }
        Err(error) => fail(&error, true),
    }
}

/// Report a failure: the chain on stderr, then — for `serve`, which promises a
/// single status line — the JSON error line on stdout. Always exits 1.
fn fail(error: &anyhow::Error, is_serve: bool) -> ExitCode {
    eprintln!("nvim_ade_server: {error:#}");
    if is_serve {
        let message = format!("{error:#}");
        // A failure to print the error line is worth a second stderr note but
        // cannot change the exit code.
        if let Err(write_error) = print_line(&ErrorOutput::new(&message)) {
            eprintln!("nvim_ade_server: cannot write the error line: {write_error}");
        }
    }
    ExitCode::from(EXIT_FAILURE)
}
