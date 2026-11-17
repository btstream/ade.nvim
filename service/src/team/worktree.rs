//! Git worktrees for team workers (PROTOCOL.md 18.12/18.16).
//!
//! Naming is pure and unit-tested here. `create`/`remove` run git without a
//! shell, with the service's environment (minus the GIT_* variables that would
//! redirect it), plus `GIT_TERMINAL_PROMPT=0`, a 60 s timeout and one mutex per
//! canonical toplevel. The hub calls them from a background task so a slow git
//! never blocks the message loop.

use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::process::Stdio;
use std::sync::{Arc, Mutex, OnceLock};
use std::time::Duration;

use serde_json::json;

use super::{now_ms, TeamError};

/// git's stderr in `data.stderr` is capped (18.16).
pub const MAX_STDERR: usize = 4 * 1024;

/// The variables that redirect git to another repository; the service's own
/// values must not leak into a worktree operation.
const STRIPPED_ENV: [&str; 5] = [
    "GIT_DIR",
    "GIT_WORK_TREE",
    "GIT_INDEX_FILE",
    "GIT_OBJECT_DIRECTORY",
    "GIT_COMMON_DIR",
];

#[derive(Debug, Clone, PartialEq)]
pub struct WorktreeInfo {
    /// The worktree root (what `git worktree remove` takes).
    pub path: String,
    /// The worker's cwd: the root plus the team's subdirectory (18.12).
    pub cwd: String,
    pub branch: String,
    /// The commit the branch started from (18.16).
    pub base: String,
    /// Canonical toplevel, kept for removal and the per-toplevel lock.
    pub toplevel: String,
    /// `"dirty_tree"` when the toplevel had uncommitted changes.
    pub warning: Option<String>,
    /// The team's relative subdirectory when it does not exist in the new
    /// worktree (the worker then starts at the worktree root).
    pub missing_subdir: Option<String>,
}

#[derive(Debug, Clone, PartialEq)]
pub struct Removed {
    pub branch: String,
    pub branch_kept: bool,
}

/// `YYYYMMDD-HHMMSS` in UTC (18.12).
pub fn stamp(ms: u64) -> String {
    let seconds = ms / 1000;
    let days = (seconds / 86_400) as i64;
    let time = seconds % 86_400;
    let (year, month, day) = civil_from_days(days);
    format!(
        "{year:04}{month:02}{day:02}-{:02}{:02}{:02}",
        time / 3_600,
        (time % 3_600) / 60,
        time % 60
    )
}

/// Howard Hinnant's civil_from_days; avoids a date-time dependency for one
/// timestamp format.
fn civil_from_days(days: i64) -> (i64, u32, u32) {
    let z = days + 719_468;
    let era = if z >= 0 { z } else { z - 146_096 } / 146_097;
    let doe = (z - era * 146_097) as u64;
    let yoe = (doe - doe / 1_460 + doe / 36_524 - doe / 146_096) / 365;
    let mut year = yoe as i64 + era * 400;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let day = (doy - (153 * mp + 2) / 5 + 1) as u32;
    let month = if mp < 10 { mp + 3 } else { mp - 9 } as u32;
    if month <= 2 {
        year += 1;
    }
    (year, month, day)
}

/// The toplevel's last component, with everything outside `[A-Za-z0-9._-]`
/// replaced by `_`.
pub fn repo_name(toplevel: &Path) -> String {
    let raw = toplevel
        .file_name()
        .and_then(|name| name.to_str())
        .unwrap_or("repo");
    let mut out = String::with_capacity(raw.len());
    for ch in raw.chars() {
        if ch.is_ascii_alphanumeric() || matches!(ch, '.' | '_' | '-') {
            out.push(ch);
        } else {
            out.push('_');
        }
    }
    if out.is_empty() {
        out.push_str("repo");
    }
    out
}

/// The first 8 hex digits of SHA-256 of the canonical toplevel path.
pub fn hash8(toplevel: &Path) -> String {
    use sha2::{Digest, Sha256};
    let mut hasher = Sha256::new();
    hasher.update(toplevel.to_string_lossy().as_bytes());
    let digest = hasher.finalize();
    digest
        .iter()
        .take(4)
        .map(|byte| format!("{byte:02x}"))
        .collect()
}

/// `(branch, directory)` for a worker's worktree.
pub fn names(
    worktree_root: &Path,
    toplevel: &Path,
    team: &str,
    stamp: &str,
    name: &str,
) -> (String, PathBuf) {
    let branch = format!("ade/{team}-{stamp}/{name}");
    let directory = worktree_root
        .join(format!("{}-{}", repo_name(toplevel), hash8(toplevel)))
        .join(format!("{team}-{stamp}-{name}"));
    (branch, directory)
}

/// The team's `cwd` relative to the canonical toplevel, if it is inside it.
pub fn subdir(cwd: &Path, toplevel: &Path) -> Option<PathBuf> {
    let cwd = std::fs::canonicalize(cwd).ok()?;
    let relative = cwd.strip_prefix(toplevel).ok()?;
    Some(relative.to_path_buf())
}

fn lock_for(toplevel: &Path) -> Arc<tokio::sync::Mutex<()>> {
    static LOCKS: OnceLock<Mutex<HashMap<String, Arc<tokio::sync::Mutex<()>>>>> = OnceLock::new();
    let locks = LOCKS.get_or_init(|| Mutex::new(HashMap::new()));
    let key = toplevel.to_string_lossy().to_string();
    let mut map = locks.lock().expect("git lock map");
    map.entry(key)
        .or_insert_with(|| Arc::new(tokio::sync::Mutex::new(())))
        .clone()
}

struct GitOutput {
    ok: bool,
    stdout: String,
    stderr: String,
    timed_out: bool,
}

fn truncated(text: &[u8]) -> String {
    if text.is_empty() {
        return String::new();
    }
    let mut end = text.len().min(MAX_STDERR);
    while end > 0 && std::str::from_utf8(&text[..end]).is_err() {
        end -= 1;
    }
    String::from_utf8_lossy(&text[..end]).trim().to_string()
}

fn git_failed(message: &str, stderr: &str) -> TeamError {
    TeamError::git(message, stderr)
}

fn timeout_ms() -> u64 {
    std::env::var("NVIM_ADE_SERVER_GIT_TIMEOUT_MS")
        .ok()
        .and_then(|value| value.trim().parse::<u64>().ok())
        .filter(|value| *value > 0)
        .unwrap_or(60_000)
}

async fn git(toplevel: &Path, args: &[&str]) -> Result<GitOutput, TeamError> {
    let mut command = tokio::process::Command::new("git");
    command.arg("-C").arg(toplevel).args(args);
    command.env_clear();
    for (key, value) in std::env::vars_os() {
        let name = key.to_string_lossy();
        if !STRIPPED_ENV.contains(&name.as_ref()) {
            command.env(key, value);
        }
    }
    command.env("GIT_TERMINAL_PROMPT", "0");
    command.stdin(Stdio::null());
    command.stdout(Stdio::piped());
    command.stderr(Stdio::piped());
    command.kill_on_drop(true);
    let timeout = Duration::from_millis(timeout_ms());
    match tokio::time::timeout(timeout, command.output()).await {
        Err(_) => Ok(GitOutput {
            ok: false,
            stdout: String::new(),
            stderr: format!("git {} timed out after {:?}", args.join(" "), timeout),
            timed_out: true,
        }),
        Ok(Err(error)) => Err(git_failed(
            &format!("cannot run git: {error}"),
            &error.to_string(),
        )),
        Ok(Ok(output)) => Ok(GitOutput {
            ok: output.status.success(),
            stdout: String::from_utf8_lossy(&output.stdout).trim().to_string(),
            stderr: truncated(&output.stderr),
            timed_out: false,
        }),
    }
}

fn git_output(output: &GitOutput, args: &[&str]) -> Result<String, TeamError> {
    if output.ok {
        Ok(output.stdout.clone())
    } else {
        Err(git_failed(
            &format!("git {} failed", args.join(" ")),
            &output.stderr,
        ))
    }
}

/// Create the worktree and return everything the hub needs to start the
/// worker. Runs in a background task; serialised per canonical toplevel.
pub async fn create(
    team_cwd: &str,
    worktree_root: &str,
    team: &str,
    stamp: &str,
    name: &str,
) -> Result<WorktreeInfo, TeamError> {
    let cwd = Path::new(team_cwd);
    let toplevel_raw = git(cwd, &["rev-parse", "--show-toplevel"]).await?;
    if !toplevel_raw.ok {
        return Err(TeamError::not_allowed(
            "the team's cwd is not inside a git work tree",
        ));
    }
    let toplevel = std::fs::canonicalize(toplevel_raw.stdout.trim()).map_err(|error| {
        TeamError::not_allowed(format!("cannot resolve the git work tree: {error}"))
    })?;
    let lock = lock_for(&toplevel);
    let _guard = lock.lock().await;

    let bare = git(&toplevel, &["rev-parse", "--is-bare-repository"]).await?;
    if bare.ok && bare.stdout.trim() == "true" {
        return Err(TeamError::not_allowed("the git repository is bare"));
    }
    let head = git(&toplevel, &["rev-parse", "--verify", "HEAD^{commit}"]).await?;
    if !head.ok {
        return Err(TeamError::not_allowed(
            "the git repository has no commit at HEAD",
        ));
    }
    let base = git_output(&head, &["rev-parse", "--verify", "HEAD^{commit}"])?;
    let dirty = git(&toplevel, &["status", "--porcelain"]).await?;
    let warning = if !dirty.ok {
        return Err(git_output(&dirty, &["status", "--porcelain"]).unwrap_err());
    } else if !dirty.stdout.is_empty() {
        Some("dirty_tree".to_string())
    } else {
        None
    };

    let root = Path::new(worktree_root);
    std::fs::create_dir_all(root).map_err(|error| {
        TeamError::not_allowed(format!("cannot create the worktree root: {error}"))
    })?;
    let (branch, directory) = names(root, &toplevel, team, stamp, name);
    if directory.exists() {
        return Err(TeamError::not_allowed(format!(
            "the worktree directory {} already exists",
            directory.display()
        )));
    }
    let branch_ref = format!("refs/heads/{branch}");
    let existing = git(&toplevel, &["show-ref", "--verify", "--quiet", &branch_ref]).await?;
    if existing.ok {
        return Err(TeamError::not_allowed(format!(
            "the worktree branch {branch} already exists"
        )));
    }
    if existing.timed_out {
        return Err(git_failed("git show-ref timed out", &existing.stderr));
    }
    // `show-ref --quiet` exits 1 for "no such ref"; anything else is a real
    // failure.
    if !existing.ok && existing.stderr.is_empty() && existing.stdout.is_empty() {
        // Expected absence.
    } else if !existing.ok {
        return Err(git_failed("git show-ref failed", &existing.stderr));
    }

    if let Some(parent) = directory.parent() {
        std::fs::create_dir_all(parent).map_err(|error| {
            TeamError::not_allowed(format!("cannot create {}: {error}", parent.display()))
        })?;
    }
    let directory_text = directory.to_string_lossy().to_string();
    let added = git(
        &toplevel,
        &["worktree", "add", "-b", &branch, &directory_text, "HEAD"],
    )
    .await?;
    if !added.ok {
        return Err(git_failed("git worktree add failed", &added.stderr));
    }

    let relative = subdir(cwd, &toplevel).unwrap_or_default();
    let target = directory.join(&relative);
    let (worker_cwd, missing_subdir) = if relative.as_os_str().is_empty() {
        (directory.clone(), None)
    } else if target.is_dir() {
        (target, None)
    } else {
        (
            directory.clone(),
            Some(relative.to_string_lossy().to_string()),
        )
    };
    Ok(WorktreeInfo {
        path: directory.to_string_lossy().to_string(),
        cwd: worker_cwd.to_string_lossy().to_string(),
        branch,
        base,
        toplevel: toplevel.to_string_lossy().to_string(),
        warning,
        missing_subdir,
    })
}

/// Remove an exited worker's worktree, then delete the branch when its tip is
/// an ancestor of the toplevel's current HEAD (18.16).
pub async fn remove(
    toplevel: &str,
    worktree: &str,
    branch: &str,
    force: bool,
) -> Result<Removed, TeamError> {
    let toplevel = std::fs::canonicalize(toplevel).map_err(|error| {
        TeamError::not_allowed(format!("cannot resolve the git work tree: {error}"))
    })?;
    let lock = lock_for(&toplevel);
    let _guard = lock.lock().await;

    let mut args = vec!["worktree", "remove"];
    if force {
        args.push("--force");
    }
    args.push(worktree);
    let removed = git(&toplevel, &args).await?;
    if !removed.ok {
        return Err(git_failed("git worktree remove failed", &removed.stderr));
    }

    let head_output = git(&toplevel, &["rev-parse", "--verify", "HEAD^{commit}"]).await?;
    let head = git_output(&head_output, &["rev-parse", "--verify", "HEAD^{commit}"])?;
    let ancestor = git(&toplevel, &["merge-base", "--is-ancestor", branch, &head]).await?;
    if ancestor.timed_out {
        return Err(git_failed("git merge-base timed out", &ancestor.stderr));
    }
    // Exit 1 means "not an ancestor" (keep the branch); other failures are
    // real git errors.
    if !ancestor.ok && !ancestor.stderr.is_empty() {
        return Err(git_failed("git merge-base failed", &ancestor.stderr));
    }
    let branch_kept = !ancestor.ok;
    if !branch_kept {
        let deleted = git(&toplevel, &["branch", "-D", branch]).await?;
        if !deleted.ok {
            return Err(git_failed("git branch -D failed", &deleted.stderr));
        }
    }
    Ok(Removed {
        branch: branch.to_string(),
        branch_kept,
    })
}

/// The role-card line a dirty-tree worker gets (18.16).
pub fn dirty_note() -> &'static str {
    "This worktree starts from the last commit; uncommitted changes of the team's tree are not present."
}

/// The leader notice for a missing subdirectory (18.16).
pub fn missing_subdir_notice(name: &str, relative: &str, path: &str) -> String {
    format!(
        "worker {name}: the team's subdirectory {relative} does not exist in the worktree; \
         it starts at {path}"
    )
}

/// A dirty-tree warning on a spawn result.
pub fn warning_json(info: &WorktreeInfo) -> Option<serde_json::Value> {
    info.warning
        .as_ref()
        .map(|warning| json!({ "warning": warning }))
}

pub fn stamp_now() -> String {
    stamp(now_ms())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_stamp_is_utc() {
        assert_eq!(stamp(0), "19700101-000000");
        assert_eq!(stamp(1_700_000_000_000), "20231114-221320");
        assert_eq!(stamp(951_782_400_000), "20000229-000000");
        // Two teams created at different times must not share a stamp (18.12:
        // team ids restart after a service restart).
        assert_ne!(stamp(1_700_000_000_000), stamp(1_700_000_001_000));
    }

    #[test]
    fn the_repo_name_is_sanitized() {
        assert_eq!(repo_name(Path::new("/tmp/my repo!")), "my_repo_");
        assert_eq!(repo_name(Path::new("/tmp/a.b_c-d")), "a.b_c-d");
        assert_eq!(repo_name(Path::new("/")), "repo");
    }

    #[test]
    fn the_hash_is_eight_hex_digits_of_the_path() {
        let hash = hash8(Path::new("/tmp/repo"));
        assert_eq!(hash.len(), 8);
        assert!(hash.chars().all(|ch| ch.is_ascii_hexdigit()));
        assert_ne!(hash, hash8(Path::new("/tmp/other")));
        assert_eq!(hash, hash8(Path::new("/tmp/repo")));
    }

    #[test]
    fn names_follow_the_spec() {
        let (branch, directory) = names(
            Path::new("/data/worktrees"),
            Path::new("/tmp/my repo"),
            "t1",
            "20260101-120000",
            "w1",
        );
        assert_eq!(branch, "ade/t1-20260101-120000/w1");
        assert_eq!(
            directory,
            Path::new("/data/worktrees")
                .join(format!("my_repo-{}", hash8(Path::new("/tmp/my repo"))))
                .join("t1-20260101-120000-w1")
        );
    }

    #[test]
    fn the_subdirectory_is_relative_to_the_toplevel() {
        let root = std::env::temp_dir().join(format!("ade-wt-subdir-{}", std::process::id()));
        let sub = root.join("crates/app");
        std::fs::create_dir_all(&sub).expect("mkdir");
        let canonical = std::fs::canonicalize(&root).expect("canonical");
        assert_eq!(
            subdir(&sub, &canonical).as_deref(),
            Some(Path::new("crates/app"))
        );
        assert_eq!(
            subdir(&canonical, &canonical).as_deref(),
            Some(Path::new(""))
        );
        std::fs::remove_dir_all(&root).ok();
    }

    #[test]
    fn a_dirty_worktree_has_the_role_card_line() {
        let info = WorktreeInfo {
            path: "/w".to_string(),
            cwd: "/w/sub".to_string(),
            branch: "b".to_string(),
            base: "c".to_string(),
            toplevel: "/t".to_string(),
            warning: Some("dirty_tree".to_string()),
            missing_subdir: None,
        };
        assert_eq!(
            warning_json(&info),
            Some(json!({ "warning": "dirty_tree" }))
        );
        assert!(dirty_note().contains("last commit"));
    }
}
