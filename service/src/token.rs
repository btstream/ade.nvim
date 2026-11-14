//! The front-end token.
//!
//! The token is generated the first time the service starts and kept in
//! `<dir>/nvim_ade_server.token` with permission 0600, one line of plain text.
//! Every later start reuses it, so a running Neovim can reconnect after the
//! service was restarted.
//!
//! An existing file is only reused when it is safe to do so. It is replaced
//! when it is not a regular file (a symlink is never followed), when its
//! content is not a well-formed token, or when its permissions grant any
//! group/other access — a token readable by someone else may already have
//! leaked, so it is rotated instead of trusted.
//!
//! Randomness comes from `std::random` (nightly, see the crate root) instead
//! of an extra dependency.

#[cfg(unix)]
use std::fs::Permissions;
use std::fs::{self, OpenOptions};
use std::io::Write;
use std::path::Path;

use anyhow::{Context, Result};

/// Length of the hex-encoded token in bytes (32 random bytes).
pub const TOKEN_HEX_LEN: usize = 64;
const TOKEN_BYTES: usize = 32;

/// Why an existing token file was not reused.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Reason {
    /// The path exists but is a symlink; it is never followed.
    Symlink,
    /// The path exists but is not a regular file.
    NotAFile,
    /// Group or other permission bits are set, so the token may have leaked.
    PermissivePermissions,
    /// Empty, truncated, or not 64 hex characters.
    Malformed,
}

impl Reason {
    /// Human-readable explanation for the log line.
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Symlink => "token file is a symlink",
            Self::NotAFile => "token path is not a regular file",
            Self::PermissivePermissions => "token file permissions are too open (expected 0600)",
            Self::Malformed => "token file content is not a valid token",
        }
    }
}

/// What happened to the token file.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum State {
    /// A healthy existing token was reused.
    Reused,
    /// No token file existed; a new one was created.
    Created,
    /// An existing token file could not be trusted; a new one was created.
    Replaced(Reason),
}

/// Generate a new token: 32 random bytes, lowercase hex, no newline.
pub fn generate() -> String {
    let mut bytes = [0u8; TOKEN_BYTES];
    // Fill eight bytes at a time from a random u64; `std::random` has no byte
    // slice distribution yet.
    for chunk in bytes.chunks_mut(8) {
        let value: u64 = std::random::random(..);
        chunk.copy_from_slice(&value.to_le_bytes()[..chunk.len()]);
    }
    let mut token = String::with_capacity(TOKEN_HEX_LEN);
    for byte in bytes {
        use std::fmt::Write as _;
        // Writing into a String cannot fail.
        let _ = write!(token, "{byte:02x}");
    }
    token
}

/// True if `candidate` looks like a token this service would have generated.
pub fn is_well_formed(token: &str) -> bool {
    token.len() == TOKEN_HEX_LEN && token.bytes().all(|byte| byte.is_ascii_hexdigit())
}

/// Compare two tokens without leaking their contents through timing.
pub fn tokens_match(expected: &str, candidate: &str) -> bool {
    let expected = expected.as_bytes();
    let candidate = candidate.as_bytes();
    if expected.len() != candidate.len() {
        return false;
    }
    let mut differing = 0u8;
    for (left, right) in expected.iter().zip(candidate) {
        differing |= left ^ right;
    }
    differing == 0
}

enum Inspection {
    Missing,
    Usable(String),
    Unusable(Reason),
}

/// Look at the token file without following symlinks and without trusting it.
fn inspect(path: &Path) -> Result<Inspection> {
    let metadata = match fs::symlink_metadata(path) {
        Ok(metadata) => metadata,
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => {
            return Ok(Inspection::Missing)
        }
        Err(error) => {
            return Err(error)
                .with_context(|| format!("reading metadata of token file {}", path.display()))
        }
    };

    // `symlink_metadata` does not follow the link, so this catches it before
    // any read happens.
    if metadata.file_type().is_symlink() {
        return Ok(Inspection::Unusable(Reason::Symlink));
    }
    if !metadata.is_file() {
        return Ok(Inspection::Unusable(Reason::NotAFile));
    }

    let contents = match fs::read_to_string(path) {
        Ok(contents) => contents,
        // It disappeared between `symlink_metadata` and the read: treat it as
        // absent rather than failing the start-up.
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => {
            return Ok(Inspection::Missing)
        }
        Err(error) => {
            return Err(error).with_context(|| format!("reading token file {}", path.display()))
        }
    };
    let token = contents.trim();
    if !is_well_formed(token) {
        return Ok(Inspection::Unusable(Reason::Malformed));
    }
    // Content is checked first, so a hand-edited file is always reported as
    // malformed; either way the file is replaced.
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        if metadata.permissions().mode() & 0o077 != 0 {
            return Ok(Inspection::Unusable(Reason::PermissivePermissions));
        }
    }
    Ok(Inspection::Usable(token.to_string()))
}

/// Load an existing, usable token, if there is one.
///
/// Unlike [`load_or_create`], this never writes anything and does not report
/// why an existing file was rejected.
pub fn load(path: &Path) -> Result<Option<String>> {
    match inspect(path)? {
        Inspection::Usable(token) => Ok(Some(token)),
        Inspection::Missing | Inspection::Unusable(_) => Ok(None),
    }
}

/// Load the existing token or create a new one.
///
/// An unusable existing file (see [`Reason`]) is replaced; the returned
/// [`State`] says why so the caller can log it.
pub fn load_or_create(path: &Path) -> Result<(String, State)> {
    match inspect(path)? {
        Inspection::Usable(token) => Ok((token, State::Reused)),
        Inspection::Missing => {
            let token = generate();
            write_private(path, token.as_bytes())
                .with_context(|| format!("writing token file {}", path.display()))?;
            Ok((token, State::Created))
        }
        Inspection::Unusable(reason) => {
            let token = generate();
            // A non-file at the path (typically a directory) would make the
            // rename fail, so remove it first. A symlink is removed with
            // `remove_file`, which deletes the link and not its target.
            if matches!(reason, Reason::NotAFile) {
                remove_intruder(path)?;
            }
            // Replacing the file (rather than tightening it) also removes a
            // symlink: `write_private` renames a fresh file over the path, so
            // the link itself is replaced and its target is never touched.
            write_private(path, token.as_bytes())
                .with_context(|| format!("replacing token file {}", path.display()))?;
            Ok((token, State::Replaced(reason)))
        }
    }
}

/// Remove whatever sits at the token path, without following symlinks.
fn remove_intruder(path: &Path) -> Result<()> {
    let metadata = match fs::symlink_metadata(path) {
        Ok(metadata) => metadata,
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(()),
        Err(error) => {
            return Err(error).with_context(|| format!("reading metadata of {}", path.display()))
        }
    };
    let result = if metadata.is_dir() {
        fs::remove_dir_all(path)
    } else {
        fs::remove_file(path)
    };
    result.with_context(|| format!("removing unsuitable {} ", path.display()))
}

/// Create `path` with permission 0600 and write `contents`, atomically.
///
/// The temporary file is opened with `create_new`, so a symlink planted at the
/// temporary path is removed instead of followed; a symlink at `path` itself is
/// replaced by the rename, again without touching its target.
pub fn write_private(path: &Path, contents: &[u8]) -> Result<()> {
    let temporary = path.with_extension("tmp");
    // Removing the temporary path first drops a stale file or a planted
    // symlink (removing a link does not touch its target).
    match fs::remove_file(&temporary) {
        Ok(()) => {}
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => {}
        Err(error) => {
            return Err(error).with_context(|| format!("removing stale {}", temporary.display()))
        }
    }

    let mut options = OpenOptions::new();
    options.write(true).create_new(true);
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt;
        options.mode(0o600);
    }
    let mut file = options
        .open(&temporary)
        .with_context(|| format!("creating {}", temporary.display()))?;
    // `mode` only applies at creation; make sure it really is 0600 (umask
    // cannot loosen it, but an exotic filesystem might behave differently).
    set_mode(&file, 0o600)?;
    file.write_all(contents)?;
    file.write_all(b"\n")?;
    file.sync_all()?;
    drop(file);

    fs::rename(&temporary, path)
        .with_context(|| format!("renaming {} to {}", temporary.display(), path.display()))?;
    // Tighten the result as well: on some filesystems `rename` keeps the
    // target's permissions, and we never want group/other access.
    set_permissions(path, 0o600)?;
    Ok(())
}

fn set_mode(file: &std::fs::File, mode: u32) -> Result<()> {
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        file.set_permissions(Permissions::from_mode(mode))?;
    }
    #[cfg(not(unix))]
    {
        // Windows has no unix permission bits; the file inherits the service
        // directory's ACL (%LOCALAPPDATA%\ade is user-private).
        let _ = (file, mode);
    }
    Ok(())
}

fn set_permissions(path: &Path, mode: u32) -> Result<()> {
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        fs::set_permissions(path, Permissions::from_mode(mode))
            .with_context(|| format!("setting permissions on {}", path.display()))?;
    }
    #[cfg(not(unix))]
    {
        let _ = (path, mode);
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::path::PathBuf;

    /// A temporary directory removed when the test ends.
    struct TempDir(PathBuf);

    impl TempDir {
        fn new(label: &str) -> Self {
            let path = std::env::temp_dir().join(format!(
                "nvim-ade-token-test-{label}-{}-{}",
                std::process::id(),
                std::time::SystemTime::now()
                    .duration_since(std::time::UNIX_EPOCH)
                    .map(|elapsed| elapsed.as_nanos())
                    .unwrap_or_default()
            ));
            fs::create_dir_all(&path).expect("create temp dir");
            Self(path)
        }

        fn token_path(&self) -> PathBuf {
            self.0.join("nvim_ade_server.token")
        }
    }

    impl Drop for TempDir {
        fn drop(&mut self) {
            let _ = fs::remove_dir_all(&self.0);
        }
    }

    fn write_token(path: &Path, contents: &str) {
        fs::write(path, contents).expect("write token");
    }

    #[cfg(unix)]
    fn set_test_mode(path: &Path, mode: u32) {
        use std::os::unix::fs::PermissionsExt;
        fs::set_permissions(path, Permissions::from_mode(mode)).expect("set mode");
    }

    #[cfg(unix)]
    fn test_mode(path: &Path) -> u32 {
        use std::os::unix::fs::PermissionsExt;
        fs::symlink_metadata(path)
            .expect("metadata")
            .permissions()
            .mode()
            & 0o777
    }

    #[test]
    fn generated_tokens_are_well_formed_and_unique() {
        let first = generate();
        let second = generate();
        assert_eq!(first.len(), TOKEN_HEX_LEN);
        assert!(is_well_formed(&first));
        assert!(is_well_formed(&second));
        assert_ne!(first, second);
    }

    #[test]
    fn malformed_tokens_are_rejected() {
        assert!(!is_well_formed(""));
        assert!(!is_well_formed("abc"));
        assert!(!is_well_formed(&"z".repeat(TOKEN_HEX_LEN)));
        assert!(!is_well_formed(&"a".repeat(TOKEN_HEX_LEN + 1)));
    }

    #[test]
    fn comparison_matches_exactly() {
        let token = generate();
        assert!(tokens_match(&token, &token));
        let mut other = token.clone();
        other.push('0');
        assert!(!tokens_match(&token, &other));
        let mut changed = token.clone();
        changed.replace_range(0..1, if token.starts_with('a') { "b" } else { "a" });
        assert!(!tokens_match(&token, &changed));
        assert!(!tokens_match(&token, ""));
    }

    #[test]
    fn a_new_token_is_created_and_written_with_a_newline() {
        let dir = TempDir::new("create");
        let path = dir.token_path();
        let (token, state) = load_or_create(&path).expect("load or create");
        assert_eq!(state, State::Created);
        assert!(is_well_formed(&token));
        let contents = fs::read_to_string(&path).expect("read token");
        assert_eq!(contents.trim(), token);
        assert_eq!(contents.lines().count(), 1, "one line: {contents:?}");
    }

    #[test]
    fn a_healthy_token_is_reused() {
        let dir = TempDir::new("reuse");
        let path = dir.token_path();
        let (first, _) = load_or_create(&path).expect("first");
        let (second, state) = load_or_create(&path).expect("second");
        assert_eq!(state, State::Reused);
        assert_eq!(first, second);
    }

    #[test]
    fn a_weak_token_is_replaced() {
        let dir = TempDir::new("weak");
        let path = dir.token_path();
        write_token(&path, "abc\n");
        let (token, state) = load_or_create(&path).expect("load or create");
        assert_eq!(state, State::Replaced(Reason::Malformed));
        assert!(is_well_formed(&token));
        assert_eq!(fs::read_to_string(&path).expect("reread").trim(), token);
    }

    #[test]
    fn an_empty_token_file_is_replaced() {
        let dir = TempDir::new("empty");
        let path = dir.token_path();
        write_token(&path, "");
        let (token, state) = load_or_create(&path).expect("load or create");
        assert_eq!(state, State::Replaced(Reason::Malformed));
        assert!(is_well_formed(&token));
    }

    #[test]
    fn a_truncated_token_is_replaced() {
        let dir = TempDir::new("truncated");
        let path = dir.token_path();
        let token = generate();
        write_token(&path, &token[..32]);
        let (new_token, state) = load_or_create(&path).expect("load or create");
        assert_eq!(state, State::Replaced(Reason::Malformed));
        assert_ne!(new_token, token);
    }

    #[cfg(unix)]
    #[test]
    fn an_overly_open_token_file_is_replaced_and_tightened() {
        let dir = TempDir::new("permissions");
        let path = dir.token_path();
        let leaked = generate();
        write_token(&path, &leaked);
        set_test_mode(&path, 0o644);

        let (token, state) = load_or_create(&path).expect("load or create");
        assert_eq!(state, State::Replaced(Reason::PermissivePermissions));
        assert_ne!(token, leaked, "a possibly leaked token must be rotated");
        assert_eq!(test_mode(&path), 0o600, "the new file is private");
    }

    #[cfg(unix)]
    #[test]
    fn a_group_readable_token_file_is_replaced() {
        let dir = TempDir::new("group-readable");
        let path = dir.token_path();
        write_token(&path, &generate());
        set_test_mode(&path, 0o640);

        let (_, state) = load_or_create(&path).expect("load or create");
        assert_eq!(state, State::Replaced(Reason::PermissivePermissions));
    }

    #[cfg(unix)]
    #[test]
    fn a_symlinked_token_file_is_replaced_without_touching_the_target() {
        let dir = TempDir::new("symlink");
        let target = dir.0.join("elsewhere");
        let token = generate();
        fs::write(&target, format!("{token}\n")).expect("write target");
        let path = dir.token_path();
        std::os::unix::fs::symlink(&target, &path).expect("create symlink");

        let (new_token, state) = load_or_create(&path).expect("load or create");
        assert_eq!(state, State::Replaced(Reason::Symlink));
        assert_ne!(new_token, token, "the linked token is not trusted");
        assert!(
            !fs::symlink_metadata(&path)
                .expect("metadata")
                .file_type()
                .is_symlink(),
            "the symlink is replaced by a regular file"
        );
        assert_eq!(
            fs::read_to_string(&target).expect("read target"),
            format!("{token}\n"),
            "the link target is left untouched"
        );
    }

    #[test]
    fn a_directory_at_the_token_path_is_replaced() {
        let dir = TempDir::new("directory");
        let path = dir.token_path();
        fs::create_dir(&path).expect("create directory");
        let (token, state) = load_or_create(&path).expect("load or create");
        assert_eq!(state, State::Replaced(Reason::NotAFile));
        assert!(is_well_formed(&token));
        assert!(path.is_file());
    }

    #[test]
    fn load_does_not_create_anything() {
        let dir = TempDir::new("load-missing");
        let path = dir.token_path();
        assert_eq!(load(&path).expect("load"), None);
        assert!(!path.exists(), "load must not create a token file");
    }

    #[test]
    fn load_ignores_a_weak_token() {
        let dir = TempDir::new("load-weak");
        let path = dir.token_path();
        write_token(&path, "abc");
        assert_eq!(load(&path).expect("load"), None);
    }

    #[cfg(unix)]
    #[test]
    fn write_private_does_not_follow_a_symlink_at_the_temporary_path() {
        let dir = TempDir::new("temp-symlink");
        let target = dir.0.join("victim");
        fs::write(&target, b"original").expect("write victim");
        let temporary = dir.token_path().with_extension("tmp");
        std::os::unix::fs::symlink(&target, &temporary).expect("plant symlink");

        write_private(&dir.token_path(), b"secret").expect("write");
        assert_eq!(
            fs::read_to_string(&target).expect("read victim"),
            "original",
            "the planted symlink target must not be written through"
        );
        assert_eq!(
            fs::read_to_string(dir.token_path()).expect("read token"),
            "secret\n"
        );
    }
}
