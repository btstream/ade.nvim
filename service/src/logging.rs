//! Service log file.
//!
//! Every service log line goes to stderr (which the front end keeps for
//! diagnostics) and, after `init`, to `<dir>/nvim_ade_server.log`. The file is
//! created 0600 and rotated once per 4 MiB to `.log.1`, so a long-running
//! service cannot fill the state directory.
use std::fs::{File, OpenOptions};
use std::io::{self, Write};
use std::path::{Path, PathBuf};
use std::sync::{Mutex, OnceLock};
use std::time::{SystemTime, UNIX_EPOCH};

pub const LOG_NAME: &str = "nvim_ade_server.log";
pub const ROTATED_NAME: &str = "nvim_ade_server.log.1";
const ROTATING_NAME: &str = "nvim_ade_server.log.rotating";
pub const MAX_BYTES: u64 = 4 * 1024 * 1024;

struct Logger {
    dir: PathBuf,
    file: Option<File>,
    written: u64,
    limit: u64,
    rotate_failed: bool,
    retry_at: Option<std::time::Instant>,
}

static LOGGER: OnceLock<Mutex<Option<Logger>>> = OnceLock::new();

/// `nvim_ade_server.log` under the service directory.
pub fn path(dir: &Path) -> PathBuf {
    dir.join(LOG_NAME)
}

fn open(dir: &Path) -> io::Result<(File, u64)> {
    let path = path(dir);
    let mut options = OpenOptions::new();
    options.create(true).append(true);
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt;
        // Never follow a symlink planted in a shared socket directory.
        options.mode(0o600).custom_flags(libc::O_NOFOLLOW);
    }
    let file = options.open(&path)?;
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        // fchmod the opened file: set_permissions(path) would follow a link.
        file.set_permissions(std::fs::Permissions::from_mode(0o600))?;
    }
    let written = file.metadata().map(|meta| meta.len()).unwrap_or(0);
    Ok((file, written))
}

/// Start writing the service log under `dir` with a per-file byte cap.
pub fn init(dir: &Path, limit: u64) -> io::Result<()> {
    let (file, written) = open(dir)?;
    let logger = LOGGER.get_or_init(|| Mutex::new(None));
    let mut slot = logger
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner());
    *slot = Some(Logger {
        dir: dir.to_path_buf(),
        file: Some(file),
        written,
        limit: limit.max(256),
        rotate_failed: false,
        retry_at: None,
    });
    Ok(())
}

/// Replace the destination (tests).
#[cfg(test)]
pub fn reset_for_test() {
    if let Some(lock) = LOGGER.get() {
        let mut slot = lock.lock().unwrap_or_else(|poisoned| poisoned.into_inner());
        *slot = None;
    }
}

fn timestamp() -> String {
    let now = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default();
    let secs = now.as_secs() as i64;
    let millis = now.subsec_millis();
    // Civil date from Unix days (Howard Hinnant's algorithm), UTC.
    let days = secs.div_euclid(86_400);
    let day_secs = secs.rem_euclid(86_400);
    let z = days + 719_468;
    let era = if z >= 0 { z } else { z - 146_096 } / 146_097;
    let doe = z - era * 146_097;
    let yoe = (doe - doe / 1460 + doe / 36_524 - doe / 146_096) / 365;
    let mut year = yoe + era * 400;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let day = doy - (153 * mp + 2) / 5 + 1;
    let month = mp + if mp < 10 { 3 } else { -9 };
    if month <= 2 {
        year += 1;
    }
    format!(
        "{:04}-{:02}-{:02}T{:02}:{:02}:{:02}.{:03}Z",
        year,
        month,
        day,
        day_secs / 3600,
        (day_secs % 3600) / 60,
        day_secs % 60,
        millis
    )
}

fn sanitize(text: &str) -> String {
    let mut out = String::with_capacity(text.len());
    for ch in text.chars() {
        match ch {
            '\n' => out.push_str("\\n"),
            '\r' => out.push_str("\\r"),
            '\t' => out.push_str("\\t"),
            c if c.is_control() => out.push_str(&format!("\\u{{{:x}}}", c as u32)),
            c => out.push(c),
        }
    }
    out
}

fn rotate(logger: &mut Logger) -> io::Result<()> {
    let path = path(&logger.dir);
    let rotated = logger.dir.join(ROTATED_NAME);
    let rotating = logger.dir.join(ROTATING_NAME);
    // Stage the current file first; the old .1 is only removed once the new
    // generation is safely staged.
    let _ = std::fs::remove_file(&rotating);
    if path.exists() {
        std::fs::rename(&path, &rotating)?;
    }
    if rotating.exists() {
        // Replace .1 only after the new generation is staged. Unix rename
        // overwrites; on platforms where it does not, keep a temporary old
        // name and restore it if the replacement fails.
        if std::fs::rename(&rotating, &rotated).is_err() {
            let backup = logger.dir.join("nvim_ade_server.log.old");
            let _ = std::fs::remove_file(&backup);
            if std::fs::rename(&rotated, &backup).is_err() {
                let _ = std::fs::rename(&rotating, &path);
                return Err(io::Error::other("cannot rotate the service log"));
            }
            if std::fs::rename(&rotating, &rotated).is_err() {
                let _ = std::fs::rename(&backup, &rotated);
                let _ = std::fs::rename(&rotating, &path);
                return Err(io::Error::other("cannot rotate the service log"));
            }
            let _ = std::fs::remove_file(&backup);
        }
    }
    match open(&logger.dir) {
        Ok((file, written)) => {
            logger.file = Some(file);
            logger.written = written;
            logger.rotate_failed = false;
            logger.retry_at = None;
            Ok(())
        }
        Err(error) => {
            // Put the old file back so the still-open handle keeps writing to
            // the expected path.
            let _ = std::fs::rename(&rotated, &path);
            Err(error)
        }
    }
}

/// Write one line to stderr and the service log.
pub fn log(args: std::fmt::Arguments<'_>) {
    let line = sanitize(&format!("{args}"));
    eprintln!("{line}");
    let Some(lock) = LOGGER.get() else {
        return;
    };
    let mut slot = lock.lock().unwrap_or_else(|poisoned| poisoned.into_inner());
    let Some(logger) = slot.as_mut() else {
        return;
    };
    let entry = format!("[{}] {}\n", timestamp(), line);
    if logger.file.is_none() {
        return;
    }
    if logger.written + entry.len() as u64 > logger.limit {
        let ready = logger
            .retry_at
            .map(|when| std::time::Instant::now() >= when)
            .unwrap_or(true);
        if ready {
            if let Err(error) = rotate(logger) {
                logger.retry_at =
                    Some(std::time::Instant::now() + std::time::Duration::from_secs(60));
                if !logger.rotate_failed {
                    logger.rotate_failed = true;
                    eprintln!("nvim_ade_server: cannot rotate the service log: {error}");
                }
            }
        }
    }
    if let Some(file) = logger.file.as_mut() {
        if file.write_all(entry.as_bytes()).is_ok() {
            let _ = file.flush();
            logger.written += entry.len() as u64;
        }
    }
}

#[macro_export]
macro_rules! svc_log {
    ($($arg:tt)*) => {
        $crate::logging::log(format_args!($($arg)*))
    };
}

#[cfg(test)]
mod tests {
    use super::*;

    static TEST_LOCK: Mutex<()> = Mutex::new(());

    #[test]
    fn rotates_at_the_limit_and_keeps_one_old_file() {
        let _guard = TEST_LOCK
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner());
        let dir = std::env::temp_dir().join(format!(
            "ade-log-test-{}-{}",
            std::process::id(),
            SystemTime::now()
                .duration_since(UNIX_EPOCH)
                .unwrap_or_default()
                .as_nanos()
        ));
        std::fs::create_dir_all(&dir).expect("dir");
        init(&dir, 1024).expect("init");
        for _ in 0..200 {
            log(format_args!(
                "nvim_ade_server: a fairly long diagnostic line for rotation"
            ));
        }
        let current = path(&dir);
        let rotated = dir.join(ROTATED_NAME);
        assert!(current.exists(), "current log");
        assert!(rotated.exists(), "rotated log");
        assert!(std::fs::metadata(&current).expect("meta").len() <= 4096);
        reset_for_test();
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[cfg(unix)]
    #[test]
    fn refuses_a_symlinked_log_file() {
        let _guard = TEST_LOCK
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner());
        use std::os::unix::fs::symlink;
        let dir = std::env::temp_dir().join(format!(
            "ade-log-link-{}-{}",
            std::process::id(),
            SystemTime::now()
                .duration_since(UNIX_EPOCH)
                .unwrap_or_default()
                .as_nanos()
        ));
        std::fs::create_dir_all(&dir).expect("dir");
        let target = dir.join("target.txt");
        std::fs::write(&target, "untouched").expect("target");
        symlink(&target, path(&dir)).expect("symlink");
        assert!(init(&dir, 1024).is_err(), "a symlink must not be followed");
        assert_eq!(
            "untouched",
            std::fs::read_to_string(&target).expect("target")
        );
        reset_for_test();
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[cfg(unix)]
    #[test]
    fn failed_rotation_keeps_the_old_generation() {
        use std::os::unix::fs::PermissionsExt;
        let _guard = TEST_LOCK
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner());
        let dir = std::env::temp_dir().join(format!(
            "ade-log-rotate-fail-{}-{}",
            std::process::id(),
            SystemTime::now()
                .duration_since(UNIX_EPOCH)
                .unwrap_or_default()
                .as_nanos()
        ));
        std::fs::create_dir_all(&dir).expect("dir");
        let rotated = dir.join(ROTATED_NAME);
        std::fs::write(&rotated, "old generation").expect("old");
        init(&dir, 1024).expect("init");
        std::fs::set_permissions(&dir, std::fs::Permissions::from_mode(0o500)).expect("chmod");
        for _ in 0..100 {
            log(format_args!(
                "nvim_ade_server: rotation failure marker padding padding"
            ));
        }
        assert_eq!(
            "old generation",
            std::fs::read_to_string(&rotated).expect("old")
        );
        std::fs::set_permissions(&dir, std::fs::Permissions::from_mode(0o700)).expect("chmod");
        reset_for_test();
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn escapes_newlines_and_uses_utc_timestamps() {
        let _guard = TEST_LOCK
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner());
        let dir = std::env::temp_dir().join(format!(
            "ade-log-escape-{}-{}",
            std::process::id(),
            SystemTime::now()
                .duration_since(UNIX_EPOCH)
                .unwrap_or_default()
                .as_nanos()
        ));
        std::fs::create_dir_all(&dir).expect("dir");
        init(&dir, 4096).expect("init");
        log(format_args!("MARK-ESCAPE client name\nforged line"));
        reset_for_test();
        let text = std::fs::read_to_string(path(&dir)).expect("log");
        assert!(text.contains("client name\\nforged line"), "{text}");
        assert!(text.contains("T") && text.contains("Z"), "{text}");
        let marked = text
            .lines()
            .filter(|line| line.contains("MARK-ESCAPE"))
            .count();
        assert_eq!(1, marked, "{text}");
        let _ = std::fs::remove_dir_all(&dir);
    }
}
