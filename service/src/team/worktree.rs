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

use tokio::io::AsyncReadExt;

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

#[derive(Debug, Clone)]
pub struct RemoveReport {
    pub removed: bool,
    pub branch: String,
    pub branch_kept: bool,
    /// The branch step failed after the worktree was already removed; the
    /// participant record is still cleared so a retry is not wedged.
    pub error: Option<TeamError>,
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

/// Kill the whole process group of a timed-out git (its hooks and their
/// children included) and wait until it is gone.
#[cfg(unix)]
fn kill_group_now(pid: u32) {
    // A negative pid addresses the group created by `setpgid(0, 0)`.
    unsafe {
        libc::kill(-(pid as i32), libc::SIGKILL);
    }
}

/// Wait until no member of the group is left. The direct child is reaped by
/// the caller first; this covers hooks and their children.
#[cfg(unix)]
async fn wait_group_gone(pid: u32) {
    let pgid = pid as i32;
    let deadline = tokio::time::Instant::now() + Duration::from_secs(3);
    loop {
        let alive = unsafe { libc::kill(-pgid, 0) } == 0;
        if !alive || tokio::time::Instant::now() >= deadline {
            if alive {
                kill_group_now(pid);
            }
            break;
        }
        tokio::time::sleep(Duration::from_millis(20)).await;
    }
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
    // Stable diagnostics for the "not a repository"/"unborn HEAD" checks; git
    // otherwise localises stderr.
    command.env("LC_ALL", "C");
    command.env("LANG", "C");
    command.stdin(Stdio::null());
    command.stdout(Stdio::piped());
    command.stderr(Stdio::piped());
    command.kill_on_drop(true);
    #[cfg(unix)]
    unsafe {
        // Its own group, so a timed-out hook's children die with it.
        command.pre_exec(|| {
            if libc::setpgid(0, 0) != 0 {
                return Err(std::io::Error::last_os_error());
            }
            Ok(())
        });
    }
    let mut child = command
        .spawn()
        .map_err(|error| git_failed(&format!("cannot run git: {error}"), &error.to_string()))?;
    let pid = child.id();
    let mut stdout_pipe = child.stdout.take().expect("stdout pipe");
    let mut stderr_pipe = child.stderr.take().expect("stderr pipe");
    let stdout_task = tokio::spawn(async move {
        let mut buffer = Vec::new();
        let _ = stdout_pipe.read_to_end(&mut buffer).await;
        buffer
    });
    let stderr_task = tokio::spawn(async move {
        let mut buffer = Vec::new();
        let _ = stderr_pipe.read_to_end(&mut buffer).await;
        buffer
    });
    let timeout = Duration::from_millis(timeout_ms());
    let waited = tokio::time::timeout(timeout, child.wait()).await;
    match waited {
        Ok(Ok(status)) => {
            let stdout = tokio::time::timeout(Duration::from_secs(2), stdout_task)
                .await
                .ok()
                .and_then(Result::ok)
                .unwrap_or_default();
            let stderr = tokio::time::timeout(Duration::from_secs(2), stderr_task)
                .await
                .ok()
                .and_then(Result::ok)
                .unwrap_or_default();
            Ok(GitOutput {
                ok: status.success(),
                stdout: truncated(&stdout),
                stderr: truncated(&stderr),
                timed_out: false,
            })
        }
        Ok(Err(error)) => {
            // The child produced no status; its group may still be alive.
            if let Some(pid) = pid {
                #[cfg(unix)]
                {
                    kill_group_now(pid);
                    wait_group_gone(pid).await;
                }
            }
            Err(git_failed(
                &format!("git {} could not be waited for: {error}", args.join(" ")),
                &error.to_string(),
            ))
        }
        Err(_) => {
            if let Some(pid) = pid {
                #[cfg(unix)]
                kill_group_now(pid);
                // Reap git itself, then wait for the hook's children: a zombie
                // would otherwise count as a live group member forever.
                let _ = tokio::time::timeout(Duration::from_secs(2), child.wait()).await;
                #[cfg(unix)]
                wait_group_gone(pid).await;
            }
            let stdout = tokio::time::timeout(Duration::from_secs(2), stdout_task)
                .await
                .ok()
                .and_then(Result::ok)
                .unwrap_or_default();
            let stderr = tokio::time::timeout(Duration::from_secs(2), stderr_task)
                .await
                .ok()
                .and_then(Result::ok)
                .unwrap_or_default();
            Ok(GitOutput {
                ok: false,
                stdout: truncated(&stdout),
                stderr: format!(
                    "git {} timed out after {:?}{}{}",
                    args.join(" "),
                    timeout,
                    if stderr.is_empty() { "" } else { ": " },
                    truncated(&stderr)
                ),
                timed_out: true,
            })
        }
    }
}

fn failed(output: &GitOutput, args: &[&str]) -> TeamError {
    git_failed(&format!("git {} failed", args.join(" ")), &output.stderr)
}

/// A command whose failure means "this is not a usable repository", with
/// timeouts and all other failures still reported as git errors (18.16).
fn repository_error(
    output: &GitOutput,
    args: &[&str],
    missing_markers: &[&str],
    message: &str,
) -> Result<String, TeamError> {
    if output.timed_out {
        return Err(git_failed(
            &format!("git {} timed out", args.join(" ")),
            &output.stderr,
        ));
    }
    if output.ok {
        return Ok(output.stdout.clone());
    }
    if missing_markers
        .iter()
        .any(|marker| output.stderr.contains(marker))
    {
        return Err(TeamError::not_allowed(message));
    }
    Err(failed(output, args))
}

/// Remove a worktree and its branch, ignoring errors; used when a spawn was
/// abandoned (team closed, service shutting down) or when `worktree add`
/// failed halfway.
pub async fn discard(toplevel: &str, worktree: &str, branch: &str) {
    let toplevel = Path::new(toplevel);
    let _ = git(toplevel, &["worktree", "remove", "--force", worktree]).await;
    let _ = git(toplevel, &["worktree", "prune"]).await;
    if Path::new(worktree).exists() {
        let _ = std::fs::remove_dir_all(worktree);
    }
    // The per-repository parent (`<repo>-<hash8>`) is ours too; remove it when
    // this was the only worktree.
    if let Some(parent) = Path::new(worktree).parent() {
        let _ = std::fs::remove_dir(parent);
    }
    let _ = git(toplevel, &["branch", "-D", branch]).await;
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
    let args = ["rev-parse", "--show-toplevel"];
    let toplevel_raw = git(cwd, &args).await?;
    let toplevel_raw = repository_error(
        &toplevel_raw,
        &args,
        &["not a git repository", "must be run in a work tree"],
        "the team's cwd is not inside a git work tree",
    )?;
    let toplevel = std::fs::canonicalize(toplevel_raw.trim()).map_err(|error| {
        TeamError::not_allowed(format!("cannot resolve the git work tree: {error}"))
    })?;
    let lock = lock_for(&toplevel);
    let _guard = lock.lock().await;

    let bare_args = ["rev-parse", "--is-bare-repository"];
    let bare = git(&toplevel, &bare_args).await?;
    if bare.timed_out {
        return Err(git_failed("git rev-parse timed out", &bare.stderr));
    }
    if !bare.ok {
        return Err(failed(&bare, &bare_args));
    }
    if bare.stdout.trim() == "true" {
        return Err(TeamError::not_allowed("the git repository is bare"));
    }
    let head_args = ["rev-parse", "--verify", "HEAD^{commit}"];
    let head = git(&toplevel, &head_args).await?;
    let base = repository_error(
        &head,
        &head_args,
        &[
            "Needed a single revision",
            "unknown revision",
            "bad revision",
            "ambiguous argument 'HEAD'",
        ],
        "the git repository has no commit at HEAD",
    )?;
    let dirty_args = ["status", "--porcelain"];
    let dirty = git(&toplevel, &dirty_args).await?;
    if !dirty.ok {
        return Err(failed(&dirty, &dirty_args));
    }
    let warning = if dirty.stdout.is_empty() {
        None
    } else {
        Some("dirty_tree".to_string())
    };

    let root = Path::new(worktree_root);
    if let Some(canonical_root) = canonical_with_missing(root) {
        if canonical_root.starts_with(&toplevel) {
            return Err(TeamError::invalid(
                "worktree_root must be outside the git work tree",
            ));
        }
    }
    std::fs::create_dir_all(root).map_err(|error| {
        TeamError::not_allowed(format!("cannot create the worktree root: {error}"))
    })?;
    let (branch, directory) = names(root, &toplevel, team, stamp, name);
    // `symlink_metadata` also notices a dangling symlink, which `exists()`
    // would not.
    if std::fs::symlink_metadata(&directory).is_ok() {
        return Err(TeamError::not_allowed(format!(
            "the worktree directory {} already exists",
            directory.display()
        )));
    }
    let branch_ref = format!("refs/heads/{branch}");
    let existing = git(&toplevel, &["show-ref", "--verify", "--quiet", &branch_ref]).await?;
    if existing.timed_out {
        return Err(git_failed("git show-ref timed out", &existing.stderr));
    }
    if existing.ok {
        return Err(TeamError::not_allowed(format!(
            "the worktree branch {branch} already exists"
        )));
    }
    // `show-ref --quiet` exits 1 for "no such ref"; anything else is a real
    // failure.
    if !existing.stderr.is_empty() || !existing.stdout.is_empty() {
        return Err(git_failed("git show-ref failed", &existing.stderr));
    }

    if let Some(parent) = directory.parent() {
        std::fs::create_dir_all(parent).map_err(|error| {
            TeamError::not_allowed(format!("cannot create {}: {error}", parent.display()))
        })?;
    }
    let directory_text = directory.to_string_lossy().to_string();
    // `base` is the commit the branch records; the worktree must start from
    // exactly that commit, not from a HEAD that may have moved.
    let add = git(
        &toplevel,
        &["worktree", "add", "-b", &branch, &directory_text, &base],
    )
    .await?;
    if !add.ok {
        // A hook may have failed or the command may have timed out after the
        // directory/branch were created: remove only what this call made. The
        // branch was checked absent above under the toplevel lock.
        discard(&toplevel.to_string_lossy(), &directory_text, &branch).await;
        return Err(git_failed("git worktree add failed", &add.stderr));
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

/// Resolve a path that may not exist yet, by canonicalising the nearest
/// existing ancestor and appending the missing components.
fn canonical_with_missing(path: &Path) -> Option<PathBuf> {
    let mut missing = Vec::new();
    let mut current = path;
    loop {
        if std::fs::symlink_metadata(current).is_ok() {
            break;
        }
        missing.push(current.file_name()?.to_os_string());
        current = current.parent()?;
    }
    let mut canonical = std::fs::canonicalize(current).ok()?;
    for component in missing.into_iter().rev() {
        canonical.push(component);
    }
    Some(canonical)
}

/// Remove an exited worker's worktree, then delete the branch when its tip is
/// an ancestor of the toplevel's current HEAD (18.16). A missing worktree or
/// branch is treated as already/otherwise removed; the participant record is
/// cleared by the caller even when only the branch step fails.
pub async fn remove(
    toplevel: &str,
    worktree: &str,
    branch: &str,
    force: bool,
) -> Result<RemoveReport, TeamError> {
    let report = |removed: bool, branch_kept: bool, error: Option<TeamError>| RemoveReport {
        removed,
        branch: branch.to_string(),
        branch_kept,
        error,
    };
    let toplevel = match std::fs::canonicalize(toplevel) {
        Ok(path) => path,
        Err(error) => {
            return Err(TeamError::not_allowed(format!(
                "cannot resolve the git work tree: {error}"
            )))
        }
    };
    let lock = lock_for(&toplevel);
    let _guard = lock.lock().await;

    let existed = std::fs::symlink_metadata(worktree).is_ok();
    if existed {
        let mut args = vec!["worktree", "remove"];
        if force {
            args.push("--force");
        }
        args.push(worktree);
        let removed = git(&toplevel, &args).await?;
        if !removed.ok {
            return Ok(report(
                false,
                true,
                Some(git_failed("git worktree remove failed", &removed.stderr)),
            ));
        }
    } else {
        // Someone deleted the directory by hand: prune the administrative
        // entry and continue with the branch.
        let pruned = git(&toplevel, &["worktree", "prune"]).await?;
        if !pruned.ok {
            return Ok(report(
                false,
                true,
                Some(git_failed("git worktree prune failed", &pruned.stderr)),
            ));
        }
    }

    let branch_ref = format!("refs/heads/{branch}");
    let branch_ref_arg = branch_ref.as_str();
    let branch_args = ["rev-parse", "--verify", branch_ref_arg];
    let exists = git(&toplevel, &branch_args).await?;
    if exists.timed_out {
        return Ok(report(
            true,
            true,
            Some(git_failed("git rev-parse timed out", &exists.stderr)),
        ));
    }
    if !exists.ok {
        let missing = exists.stderr.contains("Needed a single revision")
            || exists.stderr.contains("unknown revision")
            || exists.stderr.contains("bad revision");
        if missing {
            return Ok(report(true, false, None));
        }
        return Ok(report(true, true, Some(failed(&exists, &branch_args))));
    }

    let head_args = ["rev-parse", "--verify", "HEAD^{commit}"];
    let head_output = git(&toplevel, &head_args).await?;
    let head = match repository_error(
        &head_output,
        &head_args,
        &["Needed a single revision", "unknown revision"],
        "the git repository has no commit at HEAD",
    ) {
        Ok(head) => head,
        Err(error) => return Ok(report(true, true, Some(error))),
    };
    let ancestor_args = ["merge-base", "--is-ancestor", branch_ref_arg, head.as_str()];
    let ancestor = git(&toplevel, &ancestor_args).await?;
    if ancestor.timed_out {
        return Ok(report(
            true,
            true,
            Some(git_failed("git merge-base timed out", &ancestor.stderr)),
        ));
    }
    // Exit 1 means "not an ancestor" (keep the branch); other failures are
    // real git errors.
    if !ancestor.ok && !ancestor.stderr.is_empty() {
        return Ok(report(true, true, Some(failed(&ancestor, &ancestor_args))));
    }
    if !ancestor.ok {
        return Ok(report(true, true, None));
    }
    let deleted = git(&toplevel, &["branch", "-D", branch]).await?;
    if !deleted.ok {
        return Ok(report(
            true,
            true,
            Some(git_failed("git branch -D failed", &deleted.stderr)),
        ));
    }
    Ok(report(true, false, None))
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
