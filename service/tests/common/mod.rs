//! Shared helpers for the integration tests.
//!
//! Every test runs the real `nvim_ade_server serve` binary against a private
//! temporary directory passed through `NVIM_ADE_SERVER_DIR` and `--socket`, so
//! the tests never read or write the user's real XDG directories, token, or
//! socket.

#![allow(dead_code)]

use std::io::{BufRead, BufReader, Read, Write};
use std::path::{Path, PathBuf};
use std::process::{Child, Command, Stdio};
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use serde_json::Value;

pub const BINARY: &str = env!("CARGO_BIN_EXE_nvim_ade_server");

static COUNTER: AtomicU64 = AtomicU64::new(0);

fn unique_name(label: &str) -> String {
    let unique = COUNTER.fetch_add(1, Ordering::Relaxed);
    format!(
        "nvim-ade-server-test-{label}-{}-{unique}",
        std::process::id()
    )
}

/// A temporary directory that is removed when the last handle is dropped.
#[derive(Clone)]
pub struct TempDir {
    path: Arc<PathBuf>,
}

impl TempDir {
    pub fn new(label: &str) -> Self {
        let path = std::env::temp_dir().join(unique_name(label));
        std::fs::create_dir_all(&path).expect("create temporary directory");
        Self {
            path: Arc::new(path),
        }
    }

    pub fn path(&self) -> &Path {
        self.path.as_path()
    }

    pub fn join(&self, name: &str) -> PathBuf {
        self.path.join(name)
    }
}

impl Drop for TempDir {
    fn drop(&mut self) {
        if Arc::strong_count(&self.path) == 1 {
            let _ = std::fs::remove_dir_all(self.path.as_path());
        }
    }
}

/// A running `serve` process plus everything needed to talk to it.
pub struct TestServer {
    child: Child,
    stderr: Arc<Mutex<String>>,
    dir: TempDir,
    socket: PathBuf,
    ready: Option<Value>,
}

impl TestServer {
    /// Start a server in a fresh directory with a long idle timeout, and wait
    /// for the `ready` line.
    pub fn start(label: &str) -> Self {
        Self::start_with(label, &["--idle-timeout", "600"], &[])
    }

    /// Like [`Self::start`] but with extra arguments and environment variables.
    pub fn start_with(label: &str, extra_args: &[&str], env: &[(&str, &str)]) -> Self {
        let dir = TempDir::new(label);
        Self::start_in_dir(dir, label, extra_args, env)
    }

    /// Start in a caller-provided directory; used for stale socket and token
    /// reuse tests.
    pub fn start_in_dir(
        dir: TempDir,
        label: &str,
        extra_args: &[&str],
        env: &[(&str, &str)],
    ) -> Self {
        let socket = test_socket_path(dir.path(), label);
        let mut server = Self::spawn(dir, socket, extra_args, env);
        server.wait_ready();
        server
    }

    fn spawn(dir: TempDir, socket: PathBuf, extra_args: &[&str], env: &[(&str, &str)]) -> Self {
        let mut command = Command::new(BINARY);
        command
            .arg("serve")
            .arg("--socket")
            .arg(&socket)
            .args(extra_args)
            // The point of the isolation: never fall back to real XDG paths or
            // the real home directory, even if a code path forgot to look at
            // `NVIM_ADE_SERVER_DIR`.
            .env("NVIM_ADE_SERVER_DIR", dir.path())
            .env("HOME", dir.path())
            .env("USERPROFILE", dir.path())
            .env("LOCALAPPDATA", dir.path())
            .env_remove("XDG_RUNTIME_DIR")
            .env_remove("XDG_STATE_HOME")
            .stdin(Stdio::null())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped());
        for (key, value) in env {
            command.env(key, value);
        }

        let mut child = command.spawn().expect("spawn nvim_ade_server serve");

        let stderr = Arc::new(Mutex::new(String::new()));
        if let Some(mut pipe) = child.stderr.take() {
            let sink = Arc::clone(&stderr);
            std::thread::spawn(move || {
                let mut buffer = String::new();
                let _ = pipe.read_to_string(&mut buffer);
                *sink.lock().expect("stderr lock") = buffer;
            });
        }

        Self {
            child,
            stderr,
            dir,
            socket,
            ready: None,
        }
    }

    /// Read and validate the `ready` line printed on stdout.
    pub fn wait_ready(&mut self) -> Value {
        let stdout = self.child.stdout.take().expect("server stdout");
        let mut reader = BufReader::new(stdout);
        let mut line = String::new();
        reader.read_line(&mut line).expect("read ready line");
        let value: Value = serde_json::from_str(line.trim()).unwrap_or_else(|error| {
            panic!(
                "ready line is not JSON ({error}): {line:?}\nserver stderr:\n{}",
                self.stderr()
            )
        });
        assert_eq!(value["status"], "ready", "unexpected status line: {line}");
        assert_eq!(value["socket"], self.socket_string());
        assert_eq!(
            value["pid"].as_u64(),
            Some(u64::from(self.child.id())),
            "ready line reports the server pid"
        );
        // Keep draining stdout so a blocking write in the server can never
        // stall the test.
        std::thread::spawn(move || {
            let mut sink = String::new();
            let _ = reader.read_to_string(&mut sink);
        });
        self.ready = Some(value.clone());
        value
    }

    pub fn ready(&self) -> &Value {
        self.ready.as_ref().expect("server is ready")
    }

    pub fn dir(&self) -> &Path {
        self.dir.path()
    }

    pub fn socket(&self) -> &Path {
        &self.socket
    }

    pub fn socket_string(&self) -> String {
        self.socket.to_string_lossy().to_string()
    }

    pub fn token_path(&self) -> PathBuf {
        self.dir.join("nvim_ade_server.token")
    }

    pub fn token(&self) -> String {
        std::fs::read_to_string(self.token_path())
            .expect("token file exists")
            .trim()
            .to_string()
    }

    pub fn stderr(&self) -> String {
        self.stderr.lock().expect("stderr lock").clone()
    }

    /// Connect a new client to this server.
    pub fn connect(&self) -> Client {
        Client::connect(&self.socket).unwrap_or_else(|error| {
            panic!(
                "connect to {}: {error}\nserver stderr:\n{}",
                self.socket.display(),
                self.stderr()
            )
        })
    }

    /// Wait for the process to exit on its own and return its exit code.
    pub fn wait_for_exit(&mut self, timeout: Duration) -> Option<i32> {
        let deadline = Instant::now() + timeout;
        loop {
            match self.child.try_wait().expect("query child status") {
                Some(status) => return status.code(),
                None if Instant::now() >= deadline => return None,
                None => std::thread::sleep(Duration::from_millis(20)),
            }
        }
    }
}

impl Drop for TestServer {
    fn drop(&mut self) {
        let _ = self.child.kill();
        let _ = self.child.wait();
        // Allow the OS to release the socket before the directory disappears.
        let _ = std::fs::remove_file(&self.socket);
    }
}

/// Unix uses a socket file inside the temp dir; Windows uses a unique pipe name.
pub fn test_socket_path(dir: &Path, label: &str) -> PathBuf {
    #[cfg(unix)]
    {
        let _ = label;
        dir.join("nvim_ade_server.sock")
    }
    #[cfg(windows)]
    {
        let _ = dir;
        PathBuf::from(format!(r"\\.\pipe\{}", unique_name(label)))
    }
}

/// A front-end client: line-delimited JSON-RPC over the service socket.
pub struct Client {
    reader: BufReader<Box<dyn Read + Send>>,
    writer: Box<dyn Write + Send>,
}

impl Client {
    pub fn connect(path: &Path) -> std::io::Result<Self> {
        #[cfg(unix)]
        {
            let stream = std::os::unix::net::UnixStream::connect(path)?;
            stream.set_read_timeout(Some(Duration::from_secs(10)))?;
            let reader = stream.try_clone()?;
            Ok(Self {
                reader: BufReader::new(Box::new(reader)),
                writer: Box::new(stream),
            })
        }
        #[cfg(windows)]
        {
            let pipe = std::fs::OpenOptions::new()
                .read(true)
                .write(true)
                .open(path)?;
            let reader = pipe.try_clone()?;
            Ok(Self {
                reader: BufReader::new(Box::new(reader)),
                writer: Box::new(pipe),
            })
        }
    }

    pub fn send(&mut self, value: &Value) {
        let mut bytes = serde_json::to_vec(value).expect("serialize request");
        bytes.push(b'\n');
        self.writer.write_all(&bytes).expect("write request");
        self.writer.flush().expect("flush request");
    }

    /// Send a raw line (used for malformed input).
    pub fn send_raw(&mut self, line: &str) {
        self.writer.write_all(line.as_bytes()).expect("write raw");
        self.writer.write_all(b"\n").expect("write newline");
        self.writer.flush().expect("flush raw");
    }

    /// Read one response line. `None` means the server closed the connection.
    pub fn recv(&mut self) -> Option<Value> {
        let mut line = String::new();
        match self.reader.read_line(&mut line) {
            Ok(0) => None,
            Ok(_) => Some(
                serde_json::from_str(line.trim())
                    .unwrap_or_else(|error| panic!("invalid JSON response {line:?}: {error}")),
            ),
            Err(error) if error.kind() == std::io::ErrorKind::WouldBlock => {
                panic!("timed out waiting for a response")
            }
            // A named pipe client sees a closed server as a broken pipe rather
            // than an end of file.
            Err(error)
                if error.kind() == std::io::ErrorKind::BrokenPipe
                    || error.kind() == std::io::ErrorKind::UnexpectedEof =>
            {
                None
            }
            Err(error) => panic!("read response: {error}"),
        }
    }

    /// True if the server closed the connection (clean end of stream).
    pub fn is_closed(&mut self) -> bool {
        self.recv().is_none()
    }

    pub fn hello(&mut self, token: &str, api_version: i64) -> Value {
        self.hello_raw(serde_json::json!({
            "token": token,
            "client": "ade.nvim",
            "client_version": "test",
            "api_version": api_version,
        }))
    }

    pub fn hello_raw(&mut self, params: Value) -> Value {
        self.send(&serde_json::json!({
            "jsonrpc": "2.0",
            "id": 1,
            "method": "hello",
            "params": params,
        }));
        self.recv().expect("hello response")
    }

    pub fn call(&mut self, id: i64, method: &str) -> Value {
        self.send(&serde_json::json!({
            "jsonrpc": "2.0",
            "id": id,
            "method": method,
        }));
        self.recv().expect("method response")
    }
}

/// Start a second `serve` process against an existing server's directory and
/// socket, returning its stdout line, stderr, and exit code.
pub fn run_second_instance(
    dir: &Path,
    socket: &Path,
    extra_args: &[&str],
) -> (Value, String, Option<i32>) {
    let output = Command::new(BINARY)
        .arg("serve")
        .arg("--socket")
        .arg(socket)
        .args(extra_args)
        .env("NVIM_ADE_SERVER_DIR", dir)
        .env("HOME", dir)
        .env("USERPROFILE", dir)
        .env("LOCALAPPDATA", dir)
        .env_remove("XDG_RUNTIME_DIR")
        .env_remove("XDG_STATE_HOME")
        .stdin(Stdio::null())
        .output()
        .expect("run second instance");

    let stderr = String::from_utf8_lossy(&output.stderr).to_string();
    let stdout = String::from_utf8_lossy(&output.stdout);
    let line = stdout
        .lines()
        .next()
        .unwrap_or_else(|| panic!("no stdout from the second instance; stderr:\n{stderr}"));
    let value: Value = serde_json::from_str(line)
        .unwrap_or_else(|error| panic!("second instance stdout is not JSON: {line:?}: {error}"));
    (value, stderr, output.status.code())
}
