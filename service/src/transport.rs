//! Listening side of the front-end interface.
//!
//! Unix: a unix domain socket at `<dir>/nvim_ade_server.sock`.
//! Windows: a named pipe `\\.\pipe\nvim_ade_server-<username>`.
//!
//! Both are hidden behind [`Listener`] and the two stream types are unified by
//! the [`Stream`] alias, so the connection handling in [`crate::server`] is the
//! same on every platform.

use std::io;
use std::path::Path;
#[cfg(unix)]
use std::path::PathBuf;

use anyhow::{Context, Result};

/// A connected client.
#[cfg(unix)]
pub type Stream = tokio::net::UnixStream;
#[cfg(windows)]
pub type Stream = tokio::net::windows::named_pipe::NamedPipeServer;

#[cfg(unix)]
pub struct Listener {
    inner: tokio::net::UnixListener,
    path: PathBuf,
}

#[cfg(unix)]
impl Listener {
    /// Bind the socket and tighten its permissions to 0600.
    pub fn bind(path: &Path) -> Result<Self> {
        let inner = tokio::net::UnixListener::bind(path)
            .with_context(|| format!("binding unix socket {}", path.display()))?;
        restrict_socket(path)?;
        Ok(Self {
            inner,
            path: path.to_path_buf(),
        })
    }

    pub async fn accept(&mut self) -> io::Result<Stream> {
        let (stream, _) = self.inner.accept().await?;
        Ok(stream)
    }

    /// Remove the socket file. Called when the service exits.
    pub fn cleanup(&self) {
        match std::fs::remove_file(&self.path) {
            Ok(()) => {}
            Err(error) if error.kind() == io::ErrorKind::NotFound => {}
            Err(error) => {
                eprintln!(
                    "nvim_ade_server: could not remove socket {}: {error}",
                    self.path.display()
                );
            }
        }
    }
}

#[cfg(unix)]
fn restrict_socket(path: &Path) -> Result<()> {
    use std::os::unix::fs::PermissionsExt;
    let permissions = std::fs::Permissions::from_mode(0o600);
    std::fs::set_permissions(path, permissions)
        .with_context(|| format!("setting permissions on socket {}", path.display()))
}

#[cfg(windows)]
pub struct Listener {
    name: String,
    next: Option<tokio::net::windows::named_pipe::NamedPipeServer>,
}

#[cfg(windows)]
impl Listener {
    pub fn bind(path: &Path) -> Result<Self> {
        use tokio::net::windows::named_pipe::ServerOptions;

        let name = path.to_string_lossy().to_string();
        let first = ServerOptions::new()
            .first_pipe_instance(true)
            .reject_remote_clients(true)
            .create(&name)
            .with_context(|| format!("creating named pipe {name}"))?;
        Ok(Self {
            name,
            next: Some(first),
        })
    }

    pub async fn accept(&mut self) -> io::Result<Stream> {
        use tokio::net::windows::named_pipe::ServerOptions;

        let server = self
            .next
            .take()
            .expect("a pipe instance is always prepared before accept");
        server.connect().await?;
        // Prepare the instance for the next client before handing this one to
        // a connection task.
        let next = ServerOptions::new()
            .reject_remote_clients(true)
            .create(&self.name)?;
        self.next = Some(next);
        Ok(server)
    }

    /// Named pipes disappear with the process; nothing to clean up.
    pub fn cleanup(&self) {}
}

/// Where the listener actually listens, for log and status output.
pub fn socket_display(path: &Path) -> String {
    path.display().to_string()
}

#[cfg(windows)]
pub fn is_pipe_path(path: &Path) -> bool {
    path.as_os_str().to_string_lossy().starts_with(r"\\.\pipe\")
}

#[cfg(unix)]
pub fn is_pipe_path(_path: &Path) -> bool {
    false
}
