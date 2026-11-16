//! The on-disk store shared with `lua/ade/manager/store.lua` (PROTOCOL.md 16.1).
//!
//! Every path is built from the validated root and re-checked before a read or
//! a delete. JSON files except `package.json` are written to a temporary file in
//! the same directory and renamed over the target; nothing is fsynced (the Lua
//! implementation does not fsync either).

use std::path::{Path, PathBuf};
use std::time::{SystemTime, UNIX_EPOCH};

use serde_json::{json, Value};

use super::{contains, normalize, now_ms, timestamp, valid_install_id};

pub const SCHEMA_VERSION: i64 = 1;

pub fn agent_dir(root: &Path, agent: &str) -> PathBuf {
    root.join(agent)
}

pub fn releases_dir(root: &Path, agent: &str) -> PathBuf {
    agent_dir(root, agent).join("releases")
}

pub fn release_dir(root: &Path, agent: &str, install_id: &str) -> PathBuf {
    releases_dir(root, agent).join(install_id)
}

pub fn pointer_path(root: &Path, agent: &str) -> PathBuf {
    agent_dir(root, agent).join("current.json")
}

pub fn receipt_path(root: &Path, agent: &str, install_id: &str) -> PathBuf {
    release_dir(root, agent, install_id).join("receipt.json")
}

/// A unique temporary name next to `path`, like Lua's `.tmp-<hrtime>`.
fn temp_path(path: &Path) -> PathBuf {
    static COUNTER: std::sync::atomic::AtomicU64 = std::sync::atomic::AtomicU64::new(0);
    let nanos = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|duration| duration.as_nanos())
        .unwrap_or_default();
    let counter = COUNTER.fetch_add(1, std::sync::atomic::Ordering::Relaxed);
    PathBuf::from(format!(
        "{}.tmp-{nanos}-{}-{counter}",
        path.display(),
        std::process::id()
    ))
}

/// Compact JSON through a temporary file and a rename.
pub fn write_json_atomic(path: &Path, value: &Value) -> Result<(), String> {
    let encoded = serde_json::to_vec(value)
        .map_err(|error| format!("unable to encode {}: {error}", path.display()))?;
    let temp = temp_path(path);
    if let Err(error) = std::fs::write(&temp, &encoded) {
        let _ = std::fs::remove_file(&temp);
        return Err(format!("unable to write {}: {error}", temp.display()));
    }
    if let Err(error) = std::fs::rename(&temp, path) {
        let _ = std::fs::remove_file(&temp);
        return Err(format!("unable to replace {}: {error}", path.display()));
    }
    Ok(())
}

/// Read and parse a JSON object. `Ok(None)` means the file does not exist.
pub fn read_json(path: &Path) -> Result<Option<Value>, String> {
    let text = match std::fs::read(path) {
        Ok(bytes) => bytes,
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(None),
        Err(error) => return Err(format!("{} is unreadable: {error}", path.display())),
    };
    if text.is_empty() {
        return Err(format!("{} is empty", path.display()));
    }
    let value: Value = serde_json::from_slice(&text)
        .map_err(|_| format!("{} is not valid JSON", path.display()))?;
    if !value.is_object() {
        return Err(format!("{} does not contain an object", path.display()));
    }
    Ok(Some(value))
}

/// The release directory a receipt lives in, with the containment check.
fn checked_release_dir(root: &Path, agent: &str, install_id: &str) -> Result<PathBuf, String> {
    if !valid_install_id(install_id) {
        return Err(format!("invalid install id {install_id}"));
    }
    let dir = release_dir(root, agent, install_id);
    let Some(normalized) = normalize(&dir.to_string_lossy()) else {
        return Err("invalid release directory".to_string());
    };
    if !contains(root, &normalized) {
        return Err("release directory escapes manager.root".to_string());
    }
    Ok(normalized)
}

/// The live pointer for one agent; `Ok(None)` is "not installed".
pub fn read_pointer(root: &Path, agent: &str) -> Result<Option<String>, String> {
    let path = pointer_path(root, agent);
    let Some(value) = read_json(&path)? else {
        return Ok(None);
    };
    if value.get("schemaVersion").and_then(Value::as_i64) != Some(SCHEMA_VERSION) {
        return Err(format!(
            "unsupported pointer schemaVersion {}",
            value.get("schemaVersion").cloned().unwrap_or(Value::Null)
        ));
    }
    let install_id = value
        .get("installId")
        .and_then(Value::as_str)
        .filter(|id| valid_install_id(id))
        .ok_or_else(|| "pointer has an invalid installId".to_string())?;
    Ok(Some(install_id.to_string()))
}

/// Point one agent at `install_id`; the only commit step (16.1).
pub fn write_pointer(
    root: &Path,
    agent: &str,
    install_id: &str,
    package: &str,
    version: &str,
) -> Result<(), String> {
    if !valid_install_id(install_id) {
        return Err("invalid install id".to_string());
    }
    let dir = agent_dir(root, agent);
    std::fs::create_dir_all(&dir)
        .map_err(|error| format!("unable to create {}: {error}", dir.display()))?;
    let value = json!({
        "schemaVersion": SCHEMA_VERSION,
        "installId": install_id,
        "updatedAt": timestamp(now_ms()),
        "package": package,
        "version": version,
    });
    write_json_atomic(&pointer_path(root, agent), &value)
}

/// The receipt written into a release directory.
#[derive(Debug, Clone)]
pub struct Receipt {
    pub install_id: String,
    pub package: String,
    pub version: String,
    pub entry: String,
    pub bin: Option<String>,
}

/// A receipt that passed every rule, plus the release directory.
#[derive(Debug, Clone)]
pub struct ValidReceipt {
    pub install_id: String,
    pub package: String,
    pub version: String,
    pub entry: String,
    pub bin: Option<String>,
}

/// Read and validate `releases/<install-id>/receipt.json`.
pub fn read_receipt(
    root: &Path,
    agent: &str,
    install_id: &str,
) -> Result<Option<ValidReceipt>, String> {
    let dir = checked_release_dir(root, agent, install_id)?;
    let path = dir.join("receipt.json");
    let Some(value) = read_json(&path)? else {
        return Ok(None);
    };
    if value.get("schemaVersion").and_then(Value::as_i64) != Some(SCHEMA_VERSION) {
        return Err(format!(
            "unsupported receipt schemaVersion {}",
            value.get("schemaVersion").cloned().unwrap_or(Value::Null)
        ));
    }
    if value.get("agentId").and_then(Value::as_str) != Some(agent) {
        return Err("receipt belongs to a different agent".to_string());
    }
    let receipt_install = value
        .get("installId")
        .and_then(Value::as_str)
        .filter(|id| valid_install_id(id))
        .ok_or_else(|| "receipt has an invalid installId".to_string())?;
    if receipt_install != install_id {
        return Err("receipt belongs to a different release".to_string());
    }
    let package = value
        .get("package")
        .and_then(Value::as_str)
        .filter(|value| !value.is_empty())
        .ok_or_else(|| "receipt has no package name".to_string())?;
    let version = value
        .get("version")
        .and_then(Value::as_str)
        .filter(|value| !value.is_empty())
        .ok_or_else(|| "receipt has no version".to_string())?;
    let entry = value
        .get("entry")
        .and_then(Value::as_str)
        .filter(|value| !value.is_empty())
        .ok_or_else(|| "receipt has no entrypoint".to_string())?;
    let Some(entry_path) = normalize(&dir.join(entry).to_string_lossy()) else {
        return Err("receipt entrypoint escapes the release directory".to_string());
    };
    if !contains(&dir, &entry_path) || entry_path == dir {
        return Err("receipt entrypoint escapes the release directory".to_string());
    }
    Ok(Some(ValidReceipt {
        install_id: install_id.to_string(),
        package: package.to_string(),
        version: version.to_string(),
        entry: entry.to_string(),
        bin: value.get("bin").and_then(Value::as_str).map(str::to_string),
    }))
}

/// Write the receipt after verification (16.3).
pub fn write_receipt(root: &Path, agent: &str, receipt: &Receipt) -> Result<(), String> {
    let dir = checked_release_dir(root, agent, &receipt.install_id)?;
    let mut value = serde_json::Map::new();
    value.insert("schemaVersion".to_string(), json!(SCHEMA_VERSION));
    value.insert("agentId".to_string(), json!(agent));
    value.insert("installId".to_string(), json!(receipt.install_id));
    value.insert("package".to_string(), json!(receipt.package));
    value.insert("version".to_string(), json!(receipt.version));
    value.insert("entry".to_string(), json!(receipt.entry));
    if let Some(bin) = &receipt.bin {
        value.insert("bin".to_string(), json!(bin));
    }
    value.insert("runtime".to_string(), json!("node"));
    value.insert("installedAt".to_string(), json!(timestamp(now_ms())));
    value.insert("platform".to_string(), json!(super::platform()));
    value.insert("arch".to_string(), json!(super::arch()));
    write_json_atomic(&dir.join("receipt.json"), &Value::Object(value))
}

/// The persistent state of one agent, as `Store:state` defines it.
#[derive(Debug, Clone)]
pub struct State {
    pub status: Status,
}

#[derive(Debug, Clone)]
pub enum Status {
    NotInstalled,
    Broken {
        install_id: Option<String>,
        error: String,
    },
    Installed {
        install_id: String,
        dir: PathBuf,
        entry: PathBuf,
        package: String,
        version: String,
    },
}

impl State {
    pub fn install_id(&self) -> Option<&str> {
        match &self.status {
            Status::NotInstalled => None,
            Status::Broken { install_id, .. } => install_id.as_deref(),
            Status::Installed { install_id, .. } => Some(install_id),
        }
    }
}

/// Read the state with the same rules as the Lua store (16.1).
pub fn state(root: &Path, agent: &str) -> State {
    let install_id = match read_pointer(root, agent) {
        Ok(Some(id)) => id,
        Ok(None) => {
            return State {
                status: Status::NotInstalled,
            }
        }
        Err(error) => {
            return State {
                status: Status::Broken {
                    install_id: None,
                    error,
                },
            }
        }
    };
    let receipt = match read_receipt(root, agent, &install_id) {
        Ok(Some(receipt)) => receipt,
        Ok(None) => {
            return State {
                status: Status::Broken {
                    install_id: Some(install_id),
                    error: "receipt.json is missing".to_string(),
                },
            }
        }
        Err(error) => {
            return State {
                status: Status::Broken {
                    install_id: Some(install_id),
                    error,
                },
            }
        }
    };
    let dir = release_dir(root, agent, &install_id);
    let Some(entry) = normalize(&dir.join(&receipt.entry).to_string_lossy()) else {
        return State {
            status: Status::Broken {
                install_id: Some(install_id),
                error: "receipt entrypoint escapes the release directory".to_string(),
            },
        };
    };
    match std::fs::metadata(&entry) {
        Ok(metadata) if metadata.is_file() => State {
            status: Status::Installed {
                install_id,
                dir,
                entry,
                package: receipt.package,
                version: receipt.version,
            },
        },
        _ => State {
            status: Status::Broken {
                install_id: Some(install_id),
                error: format!("entrypoint is missing: {}", receipt.entry),
            },
        },
    }
}

/// Release directory names that are real directories with a valid id (16.1).
pub fn list_install_ids(root: &Path, agent: &str) -> Vec<String> {
    let dir = releases_dir(root, agent);
    let mut out = Vec::new();
    let Ok(entries) = std::fs::read_dir(&dir) else {
        return out;
    };
    for entry in entries.flatten() {
        let name = entry.file_name();
        let Some(name) = name.to_str() else { continue };
        if !valid_install_id(name) {
            continue;
        }
        let Ok(file_type) = entry.file_type() else {
            continue;
        };
        if file_type.is_dir() {
            out.push(name.to_string());
        }
    }
    out.sort();
    out
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::install::normalize;

    struct TempDir(PathBuf);

    impl TempDir {
        fn new(label: &str) -> Self {
            static COUNTER: std::sync::atomic::AtomicU64 = std::sync::atomic::AtomicU64::new(0);
            let unique = COUNTER.fetch_add(1, std::sync::atomic::Ordering::Relaxed);
            let path = std::env::temp_dir().join(format!(
                "nvim-ade-store-{label}-{}-{unique}",
                std::process::id()
            ));
            let _ = std::fs::remove_dir_all(&path);
            std::fs::create_dir_all(&path).expect("create temp dir");
            Self(path)
        }
    }

    impl Drop for TempDir {
        fn drop(&mut self) {
            let _ = std::fs::remove_dir_all(&self.0);
        }
    }

    fn receipt(release: &Path, install_id: &str, entry: &str) {
        std::fs::create_dir_all(release.join("node_modules/pkg/dist")).expect("dirs");
        std::fs::write(release.join("node_modules/pkg/dist/index.js"), "1").expect("entry");
        let value = json!({
            "schemaVersion": 1,
            "agentId": "pi",
            "installId": install_id,
            "package": "pkg",
            "version": "1.2.3",
            "entry": entry,
            "runtime": "node",
        });
        write_json_atomic(&release.join("receipt.json"), &value).expect("receipt");
    }

    #[test]
    fn not_installed_without_a_pointer() {
        let dir = TempDir::new("empty");
        assert!(matches!(state(&dir.0, "pi").status, Status::NotInstalled));
    }

    #[test]
    fn installed_requires_pointer_receipt_and_entry() {
        let dir = TempDir::new("installed");
        let release = release_dir(&dir.0, "pi", "rel-1");
        receipt(&release, "rel-1", "node_modules/pkg/dist/index.js");
        write_pointer(&dir.0, "pi", "rel-1", "pkg", "1.2.3").expect("pointer");
        let first = state(&dir.0, "pi");
        match first.status {
            Status::Installed {
                install_id,
                version,
                entry,
                ..
            } => {
                assert_eq!(install_id, "rel-1");
                assert_eq!(version, "1.2.3");
                assert_eq!(
                    entry,
                    normalize(
                        &release
                            .join("node_modules/pkg/dist/index.js")
                            .to_string_lossy()
                    )
                    .unwrap()
                );
            }
            other => panic!("expected installed, got {other:?}"),
        }
        std::fs::remove_file(release.join("node_modules/pkg/dist/index.js")).expect("remove");
        match state(&dir.0, "pi").status {
            Status::Broken { error, install_id } => {
                assert_eq!(install_id.as_deref(), Some("rel-1"));
                assert!(error.contains("entrypoint is missing"), "{error}");
            }
            other => panic!("expected broken, got {other:?}"),
        }
    }

    #[test]
    fn escaping_entry_is_broken() {
        let dir = TempDir::new("escape");
        let release = release_dir(&dir.0, "pi", "rel-1");
        receipt(&release, "rel-1", "../../../usr/bin/env");
        write_pointer(&dir.0, "pi", "rel-1", "pkg", "1.2.3").expect("pointer");
        match state(&dir.0, "pi").status {
            Status::Broken { error, .. } => {
                assert!(error.contains("escapes the release directory"), "{error}")
            }
            other => panic!("expected broken, got {other:?}"),
        }
    }

    #[test]
    fn schema_and_json_errors_are_broken() {
        let dir = TempDir::new("schema");
        std::fs::create_dir_all(agent_dir(&dir.0, "pi")).expect("agent dir");
        std::fs::write(
            pointer_path(&dir.0, "pi"),
            r#"{"schemaVersion":99,"installId":"rel-1"}"#,
        )
        .expect("pointer");
        match state(&dir.0, "pi").status {
            Status::Broken { install_id, error } => {
                assert_eq!(install_id, None);
                assert!(error.contains("schemaVersion"), "{error}");
            }
            other => panic!("expected broken, got {other:?}"),
        }
        std::fs::write(pointer_path(&dir.0, "pi"), "{not json").expect("pointer");
        match state(&dir.0, "pi").status {
            Status::Broken { error, .. } => assert!(error.contains("not valid JSON"), "{error}"),
            other => panic!("expected broken, got {other:?}"),
        }
    }

    #[test]
    fn atomic_writes_never_create_directories() {
        let dir = TempDir::new("no-create");
        let missing = dir.0.join("missing/record.json");
        assert!(write_json_atomic(&missing, &json!({"heartbeat": 1})).is_err());
        assert!(
            !dir.0.join("missing").exists(),
            "a heartbeat must not recreate its directory"
        );
    }

    #[test]
    fn only_valid_directories_are_releases() {
        let dir = TempDir::new("list");
        let releases = releases_dir(&dir.0, "pi");
        std::fs::create_dir_all(releases.join("rel-2")).expect("dir");
        std::fs::create_dir_all(releases.join("rel-1")).expect("dir");
        std::fs::create_dir_all(releases.join("UPPER")).expect("dir");
        std::fs::write(releases.join("file"), "x").expect("file");
        assert_eq!(list_install_ids(&dir.0, "pi"), vec!["rel-1", "rel-2"]);
    }
}
