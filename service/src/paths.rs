//! Where the service keeps its directory, socket, token and lock file.
//!
//! The order is fixed by `.acp-work/contract.md`:
//!
//! 1. `NVIM_ADE_SERVER_DIR` (tests and advanced users, highest priority);
//! 2. `$XDG_RUNTIME_DIR/ade`;
//! 3. `$XDG_STATE_HOME/ade`;
//! 4. `~/.local/state/ade`.
//!
//! On Windows the directory is `%LOCALAPPDATA%\ade` and the socket is a named
//! pipe instead of a file.

use std::ffi::OsString;
use std::path::{Path, PathBuf};

use anyhow::{bail, Result};

/// Name of the per-user directory inside the XDG base directories.
pub const DIR_NAME: &str = "ade";
pub const SOCKET_FILE_NAME: &str = "nvim_ade_server.sock";
pub const TOKEN_FILE_NAME: &str = "nvim_ade_server.token";
pub const LOCK_FILE_NAME: &str = "nvim_ade_server.lock";
#[cfg(windows)]
const PIPE_PREFIX: &str = r"\\.\pipe\nvim_ade_server";

/// Resolved locations for one service instance.
#[derive(Debug, Clone)]
pub struct Paths {
    dir: PathBuf,
    socket: PathBuf,
    private_dir: bool,
}

impl Paths {
    /// Resolve from the process environment.
    pub fn resolve() -> Result<Self> {
        Self::resolve_from(|key| std::env::var_os(key))
    }

    /// Resolve from an arbitrary environment lookup, so tests never have to
    /// touch the real environment.
    pub fn resolve_from<F>(lookup: F) -> Result<Self>
    where
        F: Fn(&str) -> Option<OsString>,
    {
        if let Some(dir) = non_empty(lookup("NVIM_ADE_SERVER_DIR")) {
            return Ok(Self::from_dir(dir, false));
        }
        let dir = default_dir(&lookup)?;
        Ok(Self::from_dir(dir, true))
    }

    /// Use an explicit socket path (from `--socket`). The service directory —
    /// and therefore the token and lock file — still comes from the normal
    /// order, so the front end always reads the token from `<dir>`.
    pub fn with_socket(socket: PathBuf) -> Result<Self> {
        let mut paths = Self::resolve()?;
        paths.socket = socket;
        Ok(paths)
    }

    /// Replace the socket path of already resolved paths.
    pub fn with_socket_on(mut self, socket: PathBuf) -> Self {
        self.socket = socket;
        self
    }

    fn from_dir(dir: PathBuf, private_dir: bool) -> Self {
        let socket = default_socket(&dir);
        Self {
            dir,
            socket,
            private_dir,
        }
    }

    pub fn dir(&self) -> &Path {
        &self.dir
    }

    pub fn socket(&self) -> &Path {
        &self.socket
    }

    pub fn token_file(&self) -> PathBuf {
        self.dir.join(TOKEN_FILE_NAME)
    }

    pub fn lock_file(&self) -> PathBuf {
        self.dir.join(LOCK_FILE_NAME)
    }

    /// True when the directory comes from the default locations and the
    /// service is therefore allowed to tighten its permissions to 0700.
    pub fn private_dir(&self) -> bool {
        self.private_dir
    }
}

fn non_empty(value: Option<OsString>) -> Option<PathBuf> {
    let value = value?;
    if value.is_empty() {
        return None;
    }
    Some(PathBuf::from(value))
}

#[cfg(unix)]
fn default_socket(dir: &Path) -> PathBuf {
    dir.join(SOCKET_FILE_NAME)
}

#[cfg(windows)]
fn default_socket(_dir: &Path) -> PathBuf {
    let user = std::env::var("USERNAME").unwrap_or_else(|_| "unknown".to_string());
    PathBuf::from(format!("{PIPE_PREFIX}-{user}"))
}

#[cfg(unix)]
fn default_dir<F>(lookup: &F) -> Result<PathBuf>
where
    F: Fn(&str) -> Option<OsString>,
{
    if let Some(dir) = non_empty(lookup("XDG_RUNTIME_DIR")) {
        return Ok(dir.join(DIR_NAME));
    }
    if let Some(dir) = non_empty(lookup("XDG_STATE_HOME")) {
        return Ok(dir.join(DIR_NAME));
    }
    if let Some(home) = non_empty(lookup("HOME")) {
        return Ok(home.join(".local").join("state").join(DIR_NAME));
    }
    bail!(
        "cannot determine the service directory: set NVIM_ADE_SERVER_DIR, \
         XDG_RUNTIME_DIR, XDG_STATE_HOME or HOME"
    )
}

#[cfg(windows)]
fn default_dir<F>(lookup: &F) -> Result<PathBuf>
where
    F: Fn(&str) -> Option<OsString>,
{
    if let Some(dir) = non_empty(lookup("LOCALAPPDATA")) {
        return Ok(dir.join(DIR_NAME));
    }
    if let Some(profile) = non_empty(lookup("USERPROFILE")) {
        return Ok(profile.join("AppData").join("Local").join(DIR_NAME));
    }
    bail!("cannot determine the service directory: set NVIM_ADE_SERVER_DIR or LOCALAPPDATA")
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::collections::HashMap;

    fn env(pairs: &[(&str, &str)]) -> impl Fn(&str) -> Option<OsString> {
        let map: HashMap<String, OsString> = pairs
            .iter()
            .map(|(key, value)| ((*key).to_string(), OsString::from(*value)))
            .collect();
        move |key| map.get(key).cloned()
    }

    #[test]
    fn explicit_dir_wins() {
        let paths = Paths::resolve_from(env(&[
            ("NVIM_ADE_SERVER_DIR", "/tmp/ade-test"),
            ("XDG_RUNTIME_DIR", "/run/user/1000"),
            ("HOME", "/home/user"),
        ]))
        .expect("resolves");
        assert_eq!(paths.dir(), Path::new("/tmp/ade-test"));
        assert_eq!(
            paths.socket(),
            Path::new("/tmp/ade-test").join(SOCKET_FILE_NAME)
        );
        assert!(!paths.private_dir());
    }

    #[test]
    fn empty_explicit_dir_is_ignored() {
        let paths =
            Paths::resolve_from(env(&[("NVIM_ADE_SERVER_DIR", ""), ("HOME", "/home/user")]))
                .expect("resolves");
        assert_eq!(
            paths.dir(),
            Path::new("/home/user").join(".local/state/ade")
        );
    }

    #[test]
    fn token_and_lock_live_in_the_service_dir() {
        let paths =
            Paths::resolve_from(env(&[("NVIM_ADE_SERVER_DIR", "/tmp/x")])).expect("resolves");
        assert_eq!(
            paths.token_file(),
            Path::new("/tmp/x").join(TOKEN_FILE_NAME)
        );
        assert_eq!(paths.lock_file(), Path::new("/tmp/x").join(LOCK_FILE_NAME));
    }

    #[test]
    fn explicit_socket_keeps_the_token_in_the_service_dir() {
        // `--socket` only changes the socket; the token and lock file stay in
        // the directory the front end knows about.
        let dir = std::env::temp_dir().join(format!(
            "nvim-ade-paths-test-{}-{}",
            std::process::id(),
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .map(|elapsed| elapsed.as_nanos())
                .unwrap_or_default()
        ));
        let socket = dir.join("custom.sock");
        let paths = Paths::resolve_from(env(&[(
            "NVIM_ADE_SERVER_DIR",
            dir.to_str().expect("utf-8 temp dir"),
        )]))
        .expect("resolves")
        .with_socket_on(socket.clone());
        assert_eq!(paths.socket(), socket.as_path());
        assert_eq!(paths.dir(), dir.as_path());
        assert_eq!(paths.token_file(), dir.join(TOKEN_FILE_NAME));
    }

    #[test]
    fn missing_everything_is_an_error() {
        assert!(Paths::resolve_from(env(&[])).is_err());
    }

    #[cfg(unix)]
    #[test]
    fn xdg_runtime_dir_wins_over_state_home() {
        let paths = Paths::resolve_from(env(&[
            ("XDG_RUNTIME_DIR", "/run/user/1000"),
            ("XDG_STATE_HOME", "/home/user/.local/state"),
            ("HOME", "/home/user"),
        ]))
        .expect("resolves");
        assert_eq!(paths.dir(), Path::new("/run/user/1000/ade"));
        assert!(paths.private_dir());
    }

    #[cfg(unix)]
    #[test]
    fn xdg_state_home_is_the_fallback() {
        let paths = Paths::resolve_from(env(&[
            ("XDG_STATE_HOME", "/home/user/.local/state"),
            ("HOME", "/home/user"),
        ]))
        .expect("resolves");
        assert_eq!(paths.dir(), Path::new("/home/user/.local/state/ade"));
    }

    #[cfg(unix)]
    #[test]
    fn home_is_the_last_fallback() {
        let paths = Paths::resolve_from(env(&[("HOME", "/home/user")])).expect("resolves");
        assert_eq!(
            paths.dir(),
            Path::new("/home/user").join(".local/state/ade")
        );
    }
}
