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
pub const MAX_BYTES: u64 = 4 * 1024 * 1024;
pub const MAX_BYTES_ENV: &str = "NVIM_ADE_SERVER_LOG_MAX_BYTES";

fn max_bytes() -> u64 {
    std::env::var(MAX_BYTES_ENV)
        .ok()
        .and_then(|value| value.parse().ok())
        .filter(|value| *value >= 256)
        .unwrap_or(MAX_BYTES)
}

struct Logger {
    dir: PathBuf,
    file: Option<File>,
    written: u64,
}

static LOGGER: OnceLock<Mutex<Option<Logger>>> = OnceLock::new();

/// `nvim_ade_server.log` under the service directory.
pub fn path(dir: &Path) -> PathBuf {
    dir.join(LOG_NAME)
}

fn open(dir: &Path) -> io::Result<(File, u64)> {
    let path = path(dir);
    // Rotate when the current file is full. The old file is replaced, so at
    // most one previous generation is kept.
    if let Ok(meta) = std::fs::metadata(&path) {
        if meta.len() >= max_bytes() {
            let rotated = dir.join(ROTATED_NAME);
            let _ = std::fs::remove_file(&rotated);
            std::fs::rename(&path, &rotated)?;
        }
    }
    let mut options = OpenOptions::new();
    options.create(true).append(true);
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt;
        options.mode(0o600);
    }
    let file = options.open(&path)?;
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        let _ = std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o600));
    }
    let written = file.metadata().map(|meta| meta.len()).unwrap_or(0);
    Ok((file, written))
}

/// Start writing the service log under `dir`. Safe to call once; later calls
/// update the destination.
pub fn init(dir: &Path) -> io::Result<()> {
    let (file, written) = open(dir)?;
    let logger = LOGGER.get_or_init(|| Mutex::new(None));
    let mut slot = logger
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner());
    *slot = Some(Logger {
        dir: dir.to_path_buf(),
        file: Some(file),
        written,
    });
    Ok(())
}

fn timestamp() -> u128 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|value| value.as_millis())
        .unwrap_or(0)
}

fn rotate(logger: &mut Logger) -> io::Result<()> {
    logger.file.take();
    let path = path(&logger.dir);
    let rotated = logger.dir.join(ROTATED_NAME);
    let _ = std::fs::remove_file(&rotated);
    if path.exists() {
        std::fs::rename(&path, &rotated)?;
    }
    let (file, written) = open(&logger.dir)?;
    logger.file = Some(file);
    logger.written = written;
    Ok(())
}

/// Write one line to stderr and the service log.
pub fn log(args: std::fmt::Arguments<'_>) {
    let line = format!("{args}");
    eprintln!("{line}");
    let Some(lock) = LOGGER.get() else {
        return;
    };
    let mut slot = lock.lock().unwrap_or_else(|poisoned| poisoned.into_inner());
    let Some(logger) = slot.as_mut() else {
        return;
    };
    let entry = format!("[{:?}] {}\n", timestamp(), line);
    if logger.written + entry.len() as u64 > max_bytes() {
        let _ = rotate(logger);
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

    #[test]
    fn rotates_at_the_limit_and_keeps_one_old_file() {
        let dir = std::env::temp_dir().join(format!(
            "ade-log-test-{}-{}",
            std::process::id(),
            timestamp()
        ));
        std::fs::create_dir_all(&dir).expect("dir");
        std::env::set_var(MAX_BYTES_ENV, "1024");
        init(&dir).expect("init");
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
        std::env::remove_var(MAX_BYTES_ENV);
        let _ = std::fs::remove_dir_all(&dir);
    }
}
