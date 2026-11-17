//! Integration tests for the SQLite event store.
//!
//! Every test uses a private temporary directory; nothing touches the user's
//! state directory. The store is a plain synchronous API, so no async runtime
//! is needed here.

use std::fs;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex};
use std::time::Instant;

use nvim_ade_server::store::{EventKind, NewEvent, Query, Store};

static COUNTER: AtomicU64 = AtomicU64::new(0);

/// A temporary directory removed when the test ends.
struct TempDir {
    path: PathBuf,
}

impl TempDir {
    fn new(label: &str) -> Self {
        let unique = COUNTER.fetch_add(1, Ordering::Relaxed);
        let path = std::env::temp_dir().join(format!(
            "nvim-ade-store-test-{label}-{}-{unique}",
            std::process::id()
        ));
        fs::create_dir_all(&path).expect("create temporary directory");
        Self { path }
    }

    fn path(&self) -> &Path {
        &self.path
    }

    /// The database path inside the temporary directory. `state/` is created by
    /// `Store::open`, so tests that care about the directory permissions start
    /// from a path that does not exist yet.
    fn db(&self) -> PathBuf {
        self.path.join("state").join("nvim_ade_server.sqlite3")
    }
}

impl Drop for TempDir {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.path);
    }
}

fn event(instance: &str, session: Option<&str>, body: &str) -> NewEvent {
    NewEvent {
        instance_key: instance.to_string(),
        session_id: session.map(str::to_string),
        kind: EventKind::AgentNotification,
        message: body.to_string(),
        ts_ms: 1_700_000_000_000,
    }
}

#[test]
fn seq_is_monotonic_and_independent_per_instance() {
    let store = Store::open_in_memory().expect("open");

    assert_eq!(
        store.append(event("a", Some("s1"), "{}")).expect("append"),
        1
    );
    assert_eq!(
        store.append(event("b", Some("s1"), "{}")).expect("append"),
        1
    );
    assert_eq!(
        store.append(event("a", Some("s1"), "{}")).expect("append"),
        2
    );
    assert_eq!(store.append(event("b", None, "{}")).expect("append"), 2);
    assert_eq!(
        store.append(event("a", Some("s2"), "{}")).expect("append"),
        3
    );

    assert_eq!(store.last_seq("a").expect("last_seq"), 3);
    assert_eq!(store.last_seq("b").expect("last_seq"), 2);
    assert_eq!(store.last_seq("never-seen").expect("last_seq"), 0);
}

#[test]
fn append_batch_returns_seqs_in_input_order() {
    let store = Store::open_in_memory().expect("open");
    let seqs = store
        .append_batch(vec![
            event("a", Some("s"), "1"),
            event("b", Some("s"), "2"),
            event("a", Some("s"), "3"),
        ])
        .expect("append_batch");
    assert_eq!(seqs, vec![1, 1, 2]);

    let empty = store.append_batch(Vec::new()).expect("empty batch");
    assert!(empty.is_empty());
    assert_eq!(store.last_seq("a").expect("last_seq"), 2);
}

#[test]
fn seq_continues_after_reopening_the_database() {
    let dir = TempDir::new("reopen");
    let path = dir.db();
    {
        let store = Store::open(&path).expect("open");
        assert_eq!(
            store.append(event("a", Some("s"), "one")).expect("append"),
            1
        );
        assert_eq!(
            store.append(event("a", Some("s"), "two")).expect("append"),
            2
        );
    }
    {
        let store = Store::open(&path).expect("reopen");
        assert_eq!(store.last_seq("a").expect("last_seq"), 2);
        assert_eq!(
            store
                .append(event("a", Some("s"), "three"))
                .expect("append"),
            3
        );
    }
    let store = Store::open(&path).expect("reopen again");
    let events = store.read(&Query::new("a")).expect("read");
    let seqs: Vec<u64> = events.iter().map(|event| event.seq).collect();
    assert_eq!(seqs, vec![1, 2, 3]);
}

#[test]
fn messages_are_stored_byte_for_byte() {
    let store = Store::open_in_memory().expect("open");
    let messages = [
        r#"{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"s"}}"#,
        "中文、emoji 🚀、组合字符 é 与全角标点「引号」",
        r#"{"escaped":"a\\b\n\t\"quoted\"\u00e9","slash":"/\/"}"#,
        "line one\nline two\r\nline three\ttab",
        "nul:\0:inside",
        "",
    ];
    for (index, message) in messages.iter().enumerate() {
        store
            .append(NewEvent {
                instance_key: "a".to_string(),
                session_id: Some("s".to_string()),
                kind: EventKind::AgentNotification,
                message: (*message).to_string(),
                ts_ms: index as i64,
            })
            .expect("append");
    }

    let events = store.read(&Query::new("a")).expect("read");
    assert_eq!(events.len(), messages.len());
    for (stored, expected) in events.iter().zip(messages) {
        assert_eq!(stored.message, *expected, "message text must round-trip");
    }
}

#[test]
fn a_ten_mebibyte_message_round_trips() {
    let dir = TempDir::new("large");
    let store = Store::open(&dir.db()).expect("open");

    // Valid JSON-ish text: multi-byte characters must not be mangled either.
    let chunk = "中文 🚀 \u{301} \"quoted\" \\ \n";
    let mut large = String::with_capacity(10 * 1024 * 1024 + chunk.len());
    while large.len() < 10 * 1024 * 1024 {
        large.push_str(chunk);
    }
    store
        .append(NewEvent {
            instance_key: "a".to_string(),
            session_id: Some("s".to_string()),
            kind: EventKind::AgentResponse,
            message: large.clone(),
            ts_ms: 7,
        })
        .expect("append");

    let events = store.read(&Query::new("a")).expect("read");
    assert_eq!(events.len(), 1);
    assert_eq!(events[0].message.len(), large.len());
    assert!(events[0].message == large, "10 MiB message must round-trip");
}

#[test]
fn read_honours_after_seq_and_limit() {
    let store = Store::open_in_memory().expect("open");
    for index in 0..10 {
        store
            .append(event("a", Some("s"), &format!("{index}")))
            .expect("append");
    }

    let all = store.read(&Query::new("a")).expect("read");
    assert_eq!(all.len(), 10);
    assert_eq!(all[0].seq, 1);
    assert_eq!(all[9].seq, 10);

    let after = store
        .read(&Query {
            after_seq: 7,
            ..Query::new("a")
        })
        .expect("read after");
    let seqs: Vec<u64> = after.iter().map(|event| event.seq).collect();
    assert_eq!(seqs, vec![8, 9, 10]);

    let limited = store
        .read(&Query {
            limit: Some(3),
            ..Query::new("a")
        })
        .expect("read limited");
    let seqs: Vec<u64> = limited.iter().map(|event| event.seq).collect();
    assert_eq!(seqs, vec![1, 2, 3]);

    let limited_after = store
        .read(&Query {
            after_seq: 2,
            limit: Some(2),
            ..Query::new("a")
        })
        .expect("read limited after");
    let seqs: Vec<u64> = limited_after.iter().map(|event| event.seq).collect();
    assert_eq!(seqs, vec![3, 4]);

    let none = store
        .read(&Query {
            limit: Some(0),
            ..Query::new("a")
        })
        .expect("read zero");
    assert!(none.is_empty());
}

#[test]
fn read_filters_by_session_and_reports_the_stored_fields() {
    let store = Store::open_in_memory().expect("open");
    store
        .append(NewEvent {
            instance_key: "a".to_string(),
            session_id: Some("s1".to_string()),
            kind: EventKind::AgentRequest,
            message: "first".to_string(),
            ts_ms: 11,
        })
        .expect("append");
    store
        .append(NewEvent {
            instance_key: "a".to_string(),
            session_id: Some("s2".to_string()),
            kind: EventKind::FrontendRequest,
            message: "second".to_string(),
            ts_ms: 12,
        })
        .expect("append");
    store
        .append(NewEvent {
            instance_key: "a".to_string(),
            session_id: None,
            kind: EventKind::AgentNotification,
            message: "third".to_string(),
            ts_ms: 13,
        })
        .expect("append");

    let s1 = store
        .read(&Query {
            session_id: Some("s1".to_string()),
            ..Query::new("a")
        })
        .expect("read s1");
    assert_eq!(s1.len(), 1);
    assert_eq!(s1[0].message, "first");
    assert_eq!(s1[0].kind, EventKind::AgentRequest);
    assert_eq!(s1[0].instance_key, "a");
    assert_eq!(s1[0].session_id.as_deref(), Some("s1"));
    assert_eq!(s1[0].ts_ms, 11);

    // `session_id: None` in a query means "all sessions", not "no session".
    let all = store.read(&Query::new("a")).expect("read all");
    assert_eq!(all.len(), 3);
    assert!(all.iter().any(|event| event.session_id.is_none()));
}

#[test]
fn synthetic_events_are_hidden_unless_requested() {
    let store = Store::open_in_memory().expect("open");
    store
        .append(event("a", Some("s"), "agent"))
        .expect("append");
    store
        .append(NewEvent {
            kind: EventKind::Synthetic,
            ..event("a", Some("s"), "prompt")
        })
        .expect("append");
    store
        .append(event("a", Some("s"), "agent again"))
        .expect("append");

    let visible = store.read(&Query::new("a")).expect("read");
    let messages: Vec<&str> = visible.iter().map(|e| e.message.as_str()).collect();
    assert_eq!(messages, vec!["agent", "agent again"]);
    assert_eq!(visible[1].seq, 3, "seq counts synthetic events too");

    let everything = store
        .read(&Query {
            include_synthetic: true,
            ..Query::new("a")
        })
        .expect("read all");
    let messages: Vec<&str> = everything.iter().map(|e| e.message.as_str()).collect();
    assert_eq!(messages, vec!["agent", "prompt", "agent again"]);
}

#[test]
fn prune_under_the_limit_changes_nothing() {
    let store = Store::open_in_memory().expect("open");
    for index in 0..5 {
        store
            .append(event("a", Some("s"), &"x".repeat(1000 + index)))
            .expect("append");
    }
    let report = store.prune("a", 1024 * 1024).expect("prune");
    assert_eq!(report.removed_events, 0);
    assert_eq!(report.removed_bytes, 0);
    assert_eq!(report.sessions_marked_incomplete, 0);
    assert!(store.session_complete("a", "s").expect("complete"));
    assert_eq!(store.read(&Query::new("a")).expect("read").len(), 5);
}

#[test]
fn prune_removes_the_oldest_events_and_marks_the_session_incomplete() {
    let store = Store::open_in_memory().expect("open");
    // 40 events of exactly 1000 bytes each.
    for index in 0..40 {
        store
            .append(event("a", Some("s"), &format!("{index:04}").repeat(250)))
            .expect("append");
    }
    assert!(store.session_complete("a", "s").expect("complete before"));

    let report = store.prune("a", 10_000).expect("prune");
    assert_eq!(report.removed_events, 30);
    assert_eq!(report.removed_bytes, 30_000);
    assert_eq!(report.sessions_marked_incomplete, 1);

    let events = store.read(&Query::new("a")).expect("read");
    assert_eq!(events.len(), 10);
    // The newest events survive, with their original seq values.
    let seqs: Vec<u64> = events.iter().map(|event| event.seq).collect();
    assert_eq!(seqs, (31..=40).collect::<Vec<u64>>());
    assert!(!store.session_complete("a", "s").expect("complete after"));

    // Pruning again right away is a no-op: everything that is left fits.
    let second = store.prune("a", 10_000).expect("prune again");
    assert_eq!(second.removed_events, 0);
    assert_eq!(second.sessions_marked_incomplete, 0);

    // The counter itself is not rewound: the next event continues the sequence.
    assert_eq!(
        store.append(event("a", Some("s"), "next")).expect("append"),
        41
    );
    assert_eq!(store.last_seq("a").expect("last_seq"), 41);
}

#[test]
fn prune_only_marks_sessions_whose_events_were_removed() {
    let store = Store::open_in_memory().expect("open");
    for index in 0..10 {
        store
            .append(event("a", Some("old"), &format!("{index:04}").repeat(250)))
            .expect("append");
    }
    for index in 0..10 {
        store
            .append(event("a", Some("new"), &format!("{index:04}").repeat(250)))
            .expect("append");
    }

    // Keep exactly the bytes of the second session.
    let report = store.prune("a", 10_000).expect("prune");
    assert_eq!(report.removed_events, 10);
    assert_eq!(report.sessions_marked_incomplete, 1);
    assert!(!store.session_complete("a", "old").expect("old"));
    assert!(store.session_complete("a", "new").expect("new"));

    let remaining = store
        .read(&Query {
            session_id: Some("new".to_string()),
            ..Query::new("a")
        })
        .expect("read new");
    assert_eq!(remaining.len(), 10);
    assert_eq!(remaining.first().expect("first").seq, 11);
}

#[test]
fn prune_applies_per_instance() {
    let store = Store::open_in_memory().expect("open");
    for index in 0..10 {
        store
            .append(event("a", Some("s"), &format!("{index}").repeat(1000)))
            .expect("append");
        store
            .append(event("b", Some("s"), &format!("{index}").repeat(1000)))
            .expect("append");
    }
    let report = store.prune("a", 2_000).expect("prune");
    assert_eq!(report.removed_events, 8);
    assert_eq!(store.read(&Query::new("a")).expect("read a").len(), 2);
    assert_eq!(store.read(&Query::new("b")).expect("read b").len(), 10);
    assert!(!store.session_complete("a", "s").expect("a s"));
    assert!(
        store.session_complete("b", "s").expect("b s"),
        "another instance keeps its own completeness"
    );
}

#[test]
fn prune_to_zero_removes_everything_but_keeps_the_counter() {
    let store = Store::open_in_memory().expect("open");
    for index in 0..3 {
        store
            .append(event("a", Some("s"), &format!("{index}").repeat(100)))
            .expect("append");
    }
    let report = store.prune("a", 0).expect("prune");
    assert_eq!(report.removed_events, 3);
    assert!(store.read(&Query::new("a")).expect("read").is_empty());
    assert_eq!(store.last_seq("a").expect("last_seq"), 3);
    assert!(!store.session_complete("a", "s").expect("incomplete"));

    let unknown = store.prune("missing", 0).expect("prune missing");
    assert_eq!(unknown.removed_events, 0);
}

#[test]
fn session_complete_is_false_for_unknown_sessions() {
    let store = Store::open_in_memory().expect("open");
    store
        .append(event("a", Some("known"), "{}"))
        .expect("append");
    assert!(store.session_complete("a", "known").expect("known"));
    assert!(
        !store.session_complete("a", "unknown").expect("unknown"),
        "a session with no logged events has no complete log to replay"
    );
    assert!(!store.session_complete("nope", "known").expect("instance"));
}

#[test]
fn instances_reports_counts_bytes_and_last_seq() {
    let store = Store::open_in_memory().expect("open");
    store.append(event("a", Some("s"), "abc")).expect("append");
    store.append(event("b", Some("s"), "defg")).expect("append");
    store.append(event("a", Some("s"), "中文")).expect("append");

    let instances = store.instances().expect("instances");
    assert_eq!(instances.len(), 2);
    let a = &instances[0];
    assert_eq!(a.instance_key, "a");
    assert_eq!(a.events, 2);
    assert_eq!(a.bytes, 3 + "中文".len() as u64);
    assert_eq!(a.last_seq, 2);
    let b = &instances[1];
    assert_eq!(b.instance_key, "b");
    assert_eq!(b.events, 1);
    assert_eq!(b.bytes, 4);
    assert_eq!(b.last_seq, 1);
}

#[test]
fn forget_instance_removes_only_that_instance() {
    let store = Store::open_in_memory().expect("open");
    store.append(event("a", Some("s"), "a1")).expect("append");
    store.append(event("b", Some("s"), "b1")).expect("append");
    store.append(event("a", Some("s"), "a2")).expect("append");

    store.forget_instance("a").expect("forget");
    assert!(store.read(&Query::new("a")).expect("read a").is_empty());
    assert_eq!(store.read(&Query::new("b")).expect("read b").len(), 1);
    assert_eq!(store.last_seq("a").expect("last a"), 0);
    assert!(!store.session_complete("a", "s").expect("a s"));
    assert!(store.session_complete("b", "s").expect("b s"));
    assert_eq!(store.instances().expect("instances").len(), 1);

    // Forgetting an unknown instance is not an error.
    store.forget_instance("nope").expect("forget missing");
    // The counter starts over for that instance: it has no events any more.
    assert_eq!(
        store
            .append(event("a", Some("s"), "fresh"))
            .expect("append"),
        1
    );
}

#[test]
fn a_garbage_file_is_moved_aside_and_replaced() {
    let dir = TempDir::new("garbage");
    let path = dir.db();
    fs::create_dir_all(path.parent().expect("parent")).expect("mkdir");
    fs::write(&path, b"this is definitely not a sqlite database\n").expect("write garbage");

    let store = Store::open(&path).expect("open replaces the file");
    assert_eq!(
        store.append(event("a", Some("s"), "{}")).expect("append"),
        1
    );
    assert_eq!(store.read(&Query::new("a")).expect("read").len(), 1);
    drop(store);

    let quarantined = quarantine_files(dir.path());
    assert_eq!(
        quarantined.len(),
        1,
        "the old file is kept: {quarantined:?}"
    );
    let name = quarantined[0].file_name().unwrap().to_string_lossy();
    assert!(
        name.starts_with("nvim_ade_server.sqlite3.corrupt-"),
        "unexpected quarantine name: {name}"
    );
    assert!(path.is_file(), "a fresh database is created");
}

#[test]
fn a_truncated_database_is_moved_aside() {
    let dir = TempDir::new("truncated");
    let path = dir.db();
    {
        let store = Store::open(&path).expect("open");
        for index in 0..20 {
            store
                .append(event("a", Some("s"), &format!("{index}").repeat(200)))
                .expect("append");
        }
    }
    // Cut the file in the middle of the header, so SQLite cannot parse it.
    let file = fs::OpenOptions::new()
        .write(true)
        .open(&path)
        .expect("open for truncation");
    file.set_len(100).expect("truncate");
    drop(file);

    let store = Store::open(&path).expect("open replaces the truncated file");
    assert!(store.read(&Query::new("a")).expect("read").is_empty());
    assert_eq!(
        store.append(event("a", Some("s"), "{}")).expect("append"),
        1
    );
    drop(store);
    assert_eq!(quarantine_files(dir.path()).len(), 1);
}

#[test]
fn a_future_schema_version_is_moved_aside() {
    let dir = TempDir::new("version");
    let path = dir.db();
    {
        let store = Store::open(&path).expect("open");
        store.append(event("a", Some("s"), "{}")).expect("append");
    }

    // `user_version` lives at byte 60 of the database header (big endian).
    let mut bytes = fs::read(&path).expect("read database");
    assert_eq!(&bytes[..16], b"SQLite format 3\0");
    bytes[60..64].copy_from_slice(&99i32.to_be_bytes());
    fs::write(&path, &bytes).expect("write database");

    let store = Store::open(&path).expect("open replaces the unknown version");
    assert!(store.read(&Query::new("a")).expect("read").is_empty());
    drop(store);
    assert_eq!(quarantine_files(dir.path()).len(), 1);
}

#[test]
fn an_empty_existing_file_is_initialised_in_place() {
    let dir = TempDir::new("empty");
    let path = dir.db();
    fs::create_dir_all(path.parent().expect("parent")).expect("mkdir");
    fs::write(&path, b"").expect("write empty file");

    let store = Store::open(&path).expect("open");
    assert_eq!(
        store.append(event("a", Some("s"), "{}")).expect("append"),
        1
    );
    drop(store);
    assert!(
        quarantine_files(dir.path()).is_empty(),
        "an empty file is a valid empty database"
    );
}

#[test]
fn a_directory_at_the_database_path_is_a_clear_error() {
    let dir = TempDir::new("dir-at-path");
    let path = dir.db();
    fs::create_dir_all(&path).expect("mkdir at db path");
    let error = Store::open(&path).expect_err("a directory is not a database");
    let message = format!("{error:#}");
    assert!(
        message.contains("not a regular file"),
        "unexpected error: {message}"
    );
}

#[cfg(unix)]
#[test]
fn a_symlinked_database_is_refused() {
    let dir = TempDir::new("symlink");
    let path = dir.db();
    fs::create_dir_all(path.parent().expect("parent")).expect("mkdir");
    let target = dir.path().join("elsewhere.sqlite3");
    {
        let store = Store::open(&target).expect("open target");
        store.append(event("a", Some("s"), "{}")).expect("append");
    }
    std::os::unix::fs::symlink(&target, &path).expect("create symlink");

    let error = Store::open(&path).expect_err("a symlink is not followed");
    assert!(
        format!("{error:#}").contains("symlink"),
        "unexpected error: {error:#}"
    );
    assert!(
        std::fs::symlink_metadata(&path)
            .expect("lstat")
            .file_type()
            .is_symlink(),
        "the link itself is left alone"
    );
    // The target was not modified by the failed open.
    let store = Store::open(&target).expect("reopen target");
    assert_eq!(store.last_seq("a").expect("last_seq"), 1);
}

#[cfg(unix)]
#[test]
fn the_database_is_private() {
    use std::os::unix::fs::PermissionsExt;

    let dir = TempDir::new("permissions");
    let path = dir.db();
    let store = Store::open(&path).expect("open");
    store.append(event("a", Some("s"), "{}")).expect("append");

    let dir_mode = fs::metadata(path.parent().expect("parent"))
        .expect("dir metadata")
        .permissions()
        .mode()
        & 0o777;
    assert_eq!(dir_mode, 0o700, "the store directory is private");

    let file_mode = fs::metadata(&path)
        .expect("file metadata")
        .permissions()
        .mode()
        & 0o777;
    assert_eq!(file_mode, 0o600, "the database file is private");

    // The WAL sidecar must not be world readable either.
    let wal = path.with_extension("sqlite3-wal");
    if wal.exists() {
        let wal_mode = fs::metadata(&wal)
            .expect("wal metadata")
            .permissions()
            .mode()
            & 0o777;
        assert_eq!(wal_mode, 0o600, "the WAL file is private");
    }
}

#[cfg(unix)]
#[test]
fn a_read_only_medium_reports_an_error_instead_of_panicking() {
    use std::os::unix::fs::PermissionsExt;

    let dir = TempDir::new("read-only");
    let path = dir.db();
    {
        let store = Store::open(&path).expect("open");
        store.append(event("a", Some("s"), "{}")).expect("append");
    }
    // WAL needs to create `-wal`/`-shm` next to the database, so a directory
    // without write permission behaves like read-only media. (chmod on the
    // database file itself still succeeds — only ownership matters for that.)
    let parent = path.parent().expect("parent");
    fs::set_permissions(parent, fs::Permissions::from_mode(0o500)).expect("chmod");

    let result = Store::open(&path);
    // Restore the mode first so the temporary directory can be removed.
    fs::set_permissions(parent, fs::Permissions::from_mode(0o700)).expect("chmod back");

    match result {
        Ok(store) => {
            // Running as root ignores the permission bits; then the open simply
            // succeeds and there is nothing to assert.
            eprintln!("note: running with elevated privileges, read-only check skipped");
            let _ = store;
        }
        Err(error) => {
            let message = format!("{error:#}").to_lowercase();
            assert!(
                message.contains("readonly") || message.contains("read-only"),
                "the error must say the medium is read-only: {message}"
            );
        }
    }

    // A permission/medium problem must never destroy the log: nothing was
    // quarantined as corrupt.
    assert!(
        quarantine_files(dir.path()).is_empty(),
        "a read-only medium is not corruption"
    );
    assert!(path.is_file(), "the database is left in place");
}

#[test]
fn concurrent_appends_never_duplicate_or_skip_a_seq() {
    let dir = TempDir::new("concurrent");
    let store = Arc::new(Store::open(&dir.db()).expect("open"));
    let seen: Arc<Mutex<Vec<u64>>> = Arc::new(Mutex::new(Vec::new()));

    let mut threads = Vec::new();
    for worker in 0..8 {
        let store = Arc::clone(&store);
        let seen = Arc::clone(&seen);
        threads.push(std::thread::spawn(move || {
            for index in 0..250 {
                let seq = store
                    .append(event("shared", Some("s"), &format!("{worker}-{index}")))
                    .expect("append");
                seen.lock().expect("lock").push(seq);
            }
        }));
    }
    for thread in threads {
        thread.join().expect("join");
    }

    let mut seqs = seen.lock().expect("lock").clone();
    seqs.sort_unstable();
    assert_eq!(seqs, (1..=2_000).collect::<Vec<u64>>());
    assert_eq!(store.last_seq("shared").expect("last_seq"), 2_000);
    assert_eq!(
        store.read(&Query::new("shared")).expect("read").len(),
        2_000
    );
}

#[test]
fn store_is_send_and_sync() {
    fn assert_send_sync<T: Send + Sync>() {}
    assert_send_sync::<Store>();

    let dir = TempDir::new("send-sync");
    let store = Arc::new(Store::open(&dir.db()).expect("open"));
    let handle = std::thread::spawn(move || store.last_seq("a").expect("last_seq"));
    assert_eq!(handle.join().expect("join"), 0);
}

/// The performance smoke test. It writes 50,000 events of about 2 KiB and reads
/// the newest 1,000. The limits are deliberately loose (see the report for the
/// measured numbers) so a slow CI machine does not turn this into a flaky test.
#[test]
fn performance_smoke() {
    const EVENTS: usize = 50_000;
    const PAYLOAD: usize = 2 * 1024;
    const READ_LAST: usize = 1_000;

    let dir = TempDir::new("perf");
    let store = Store::open(&dir.db()).expect("open");

    let body = "x".repeat(PAYLOAD);
    let mut batch = Vec::with_capacity(EVENTS);
    for index in 0..EVENTS {
        batch.push(NewEvent {
            instance_key: "perf".to_string(),
            session_id: Some("s".to_string()),
            kind: EventKind::AgentNotification,
            // Vary the tail so the rows are not all identical.
            message: format!("{body}{index:08}"),
            ts_ms: 1_700_000_000_000 + index as i64,
        });
    }

    let started = Instant::now();
    let seqs = store.append_batch(batch).expect("append_batch");
    let write_elapsed = started.elapsed();

    assert_eq!(seqs.len(), EVENTS);
    assert_eq!(seqs.first().copied(), Some(1));
    assert_eq!(seqs.last().copied(), Some(EVENTS as u64));

    let started = Instant::now();
    let last = store
        .read(&Query {
            after_seq: (EVENTS - READ_LAST) as u64,
            limit: Some(READ_LAST),
            ..Query::new("perf")
        })
        .expect("read");
    let read_elapsed = started.elapsed();

    assert_eq!(last.len(), READ_LAST);
    assert_eq!(last[0].seq, (EVENTS - READ_LAST + 1) as u64);

    eprintln!(
        "store perf: wrote {EVENTS} events ({:.1} MiB) in {:?}; read last {READ_LAST} in {:?}",
        (EVENTS * PAYLOAD) as f64 / (1024.0 * 1024.0),
        write_elapsed,
        read_elapsed
    );

    assert!(
        write_elapsed.as_secs_f64() < 20.0,
        "writing {EVENTS} events took {write_elapsed:?}"
    );
    assert!(
        read_elapsed.as_millis() < 2_000,
        "reading the last {READ_LAST} events took {read_elapsed:?}"
    );
}

/// Quarantined database files inside `dir`, walked one level deep.
fn quarantine_files(dir: &Path) -> Vec<PathBuf> {
    let mut found = Vec::new();
    collect_quarantine(dir, &mut found, 0);
    found.sort();
    found
}

fn collect_quarantine(dir: &Path, found: &mut Vec<PathBuf>, depth: usize) {
    if depth > 3 {
        return;
    }
    let Ok(entries) = fs::read_dir(dir) else {
        return;
    };
    for entry in entries.flatten() {
        let path = entry.path();
        if path.is_dir() {
            collect_quarantine(&path, found, depth + 1);
        } else if path
            .file_name()
            .map(|name| name.to_string_lossy().contains(".corrupt-"))
            .unwrap_or(false)
        {
            found.push(path);
        }
    }
}

// ---------------------------------------------------------------------------
// Caller-assigned sequence numbers (`append_at`) and the recorder's extensions
// ---------------------------------------------------------------------------

/// A `NewEvent` with an explicit kind, for the synthetic half of the log.
fn synthetic(instance: &str, session: Option<&str>, body: &str) -> NewEvent {
    NewEvent {
        kind: EventKind::Synthetic,
        ..event(instance, session, body)
    }
}

#[test]
fn append_at_uses_the_callers_sequence_numbers() {
    let store = Store::open_in_memory().expect("open");

    store
        .append_at(1, event("a", Some("s"), "first"))
        .expect("append at 1");
    // A gap is allowed: the relay shares one counter with the events it does not
    // record (responses, requests, other notifications).
    store
        .append_at(7, synthetic("a", Some("s"), "prompt"))
        .expect("append at 7");
    store
        .append_at(8, event("a", Some("s"), "second"))
        .expect("append at 8");

    let events = store
        .read(&Query {
            include_synthetic: true,
            ..Query::new("a")
        })
        .expect("read");
    let seqs: Vec<u64> = events.iter().map(|event| event.seq).collect();
    assert_eq!(seqs, vec![1, 7, 8]);
    assert_eq!(events[1].kind, EventKind::Synthetic);
    assert_eq!(store.last_seq("a").expect("last_seq"), 8);
}

#[test]
fn append_at_updates_the_counter_the_plain_append_uses() {
    let store = Store::open_in_memory().expect("open");
    store
        .append_at(5, event("a", Some("s"), "relay"))
        .expect("append at 5");
    // `next_seq` must become max(seq) + 1, so the old API keeps working and
    // never reuses a number.
    assert_eq!(store.last_seq("a").expect("last_seq"), 5);
    assert_eq!(
        store.append(event("a", Some("s"), "next")).expect("append"),
        6
    );
}

#[test]
fn append_at_rejects_a_non_increasing_seq_and_rolls_back() {
    let store = Store::open_in_memory().expect("open");
    store
        .append_at(4, event("a", Some("s"), "four"))
        .expect("append at 4");
    store
        .append_at(6, event("a", Some("s"), "six"))
        .expect("append at 6");

    for repeated in [6, 5, 1] {
        let error = store
            .append_at(repeated, event("a", Some("s"), "rejected"))
            .expect_err("a non-increasing seq must be rejected");
        let message = format!("{error:#}");
        assert!(
            message.contains("seq") && message.contains('6'),
            "the error must name the seq and the current maximum: {message}"
        );
    }

    let events = store.read(&Query::new("a")).expect("read");
    let messages: Vec<&str> = events.iter().map(|e| e.message.as_str()).collect();
    assert_eq!(
        messages,
        vec!["four", "six"],
        "rejected writes leave no trace"
    );

    // The counter is unchanged too: the next caller-assigned number is still
    // whatever the relay decides, and the store accepts it.
    assert_eq!(store.last_seq("a").expect("last_seq"), 6);
    store
        .append_at(7, event("a", Some("s"), "seven"))
        .expect("append at 7");
}

#[test]
fn append_at_is_per_instance() {
    let store = Store::open_in_memory().expect("open");
    store
        .append_at(9, event("a", Some("s"), "a-nine"))
        .expect("a at 9");
    // Another instance has its own counter; 1 is not "decreasing" for it.
    store
        .append_at(1, event("b", Some("s"), "b-one"))
        .expect("b at 1");
    assert_eq!(store.last_seq("a").expect("last a"), 9);
    assert_eq!(store.last_seq("b").expect("last b"), 1);
}

#[test]
fn append_batch_at_is_atomic_and_covers_several_instances() {
    let store = Store::open_in_memory().expect("open");
    store
        // Per-instance numbers increase in the order given; the instances are
        // interleaved freely.
        .append_batch_at(vec![
            (1, event("a", Some("s"), "a1")),
            (1, event("b", Some("s"), "b1")),
            (2, event("a", Some("s"), "a2")),
            (2, event("b", Some("s"), "b2")),
            (5, synthetic("a", Some("s"), "pa")),
        ])
        .expect("append batch at");
    assert_eq!(store.last_seq("a").expect("last a"), 5);
    assert_eq!(store.last_seq("b").expect("last b"), 2);

    // One bad entry rejects the whole batch, including the entries for the
    // other instance that came before it.
    let error = store
        .append_batch_at(vec![
            (6, event("a", Some("s"), "ok")),
            (3, event("b", Some("s"), "ok too")),
            (4, event("a", Some("s"), "stale")),
        ])
        .expect_err("a stale seq must be rejected");
    assert!(format!("{error:#}").contains("seq"));

    let a = store
        .read(&Query {
            include_synthetic: true,
            ..Query::new("a")
        })
        .expect("read a");
    let messages: Vec<&str> = a.iter().map(|e| e.message.as_str()).collect();
    assert_eq!(
        messages,
        vec!["a1", "a2", "pa"],
        "the rejected batch left nothing"
    );
    let b = store.read(&Query::new("b")).expect("read b");
    assert_eq!(b.len(), 2, "the other instance was rolled back too");
    assert_eq!(store.last_seq("a").expect("last a"), 5);
    assert_eq!(store.last_seq("b").expect("last b"), 2);
}

#[test]
fn append_batch_at_accepts_an_empty_batch() {
    let store = Store::open_in_memory().expect("open");
    store.append_batch_at(Vec::new()).expect("empty batch");
    assert_eq!(store.last_seq("a").expect("last_seq"), 0);
}

#[test]
fn append_at_rejects_an_empty_instance_key() {
    let store = Store::open_in_memory().expect("open");
    let error = store
        .append_at(1, event("", Some("s"), "{}"))
        .expect_err("empty instance key");
    assert!(format!("{error:#}").contains("instance_key"));
}

#[test]
fn mark_instance_incomplete_marks_every_known_session() {
    let store = Store::open_in_memory().expect("open");
    store
        .append_at(1, event("a", Some("s1"), "{}"))
        .expect("append");
    store
        .append_at(2, event("a", Some("s2"), "{}"))
        .expect("append");
    store
        .append_at(1, event("b", Some("s1"), "{}"))
        .expect("append");
    assert!(store.session_complete("a", "s1").expect("s1"));

    store.mark_instance_incomplete("a").expect("mark");

    assert!(!store.session_complete("a", "s1").expect("s1"));
    assert!(!store.session_complete("a", "s2").expect("s2"));
    assert!(
        store.session_complete("b", "s1").expect("b s1"),
        "another instance is untouched"
    );
    // Marking again is not an error, and a session that appears afterwards
    // starts complete (a new session's log is fresh).
    store.mark_instance_incomplete("a").expect("mark again");
    store
        .append_at(3, event("a", Some("s3"), "{}"))
        .expect("append");
    assert!(store.session_complete("a", "s3").expect("s3"));

    // An unknown instance is a no-op.
    store
        .mark_instance_incomplete("nope")
        .expect("unknown instance");
}

#[test]
fn instance_bytes_counts_the_stored_messages() {
    let store = Store::open_in_memory().expect("open");
    assert_eq!(store.instance_bytes("a").expect("bytes"), 0);
    store.append(event("a", Some("s"), "abc")).expect("append");
    store.append(event("a", Some("s"), "中文")).expect("append");
    store
        .append(event("b", Some("s"), "other"))
        .expect("append");

    assert_eq!(
        store.instance_bytes("a").expect("bytes"),
        3 + "中文".len() as u64
    );
    assert_eq!(store.instance_bytes("b").expect("bytes"), 5);
    assert_eq!(store.instance_bytes("nope").expect("bytes"), 0);

    // Pruning lowers it: with a 6-byte budget only the 3-byte event goes.
    let report = store.prune("a", 6).expect("prune");
    assert_eq!(report.removed_events, 1);
    assert_eq!(
        store.instance_bytes("a").expect("bytes"),
        "中文".len() as u64
    );
}

#[test]
fn read_session_upto_returns_one_session_including_synthetic() {
    let store = Store::open_in_memory().expect("open");
    store
        .append_at(1, event("a", Some("s1"), "s1-agent"))
        .expect("append");
    store
        .append_at(2, synthetic("a", Some("s1"), "s1-prompt"))
        .expect("append");
    store
        .append_at(3, event("a", Some("s2"), "s2-agent"))
        .expect("append");
    store
        .append_at(4, event("a", Some("s1"), "s1-later"))
        .expect("append");
    store
        .append_at(5, event("a", None, "no session"))
        .expect("append");

    let up_to_2 = store.read_session_upto("a", "s1", 2).expect("read");
    let messages: Vec<&str> = up_to_2.iter().map(|e| e.message.as_str()).collect();
    assert_eq!(messages, vec!["s1-agent", "s1-prompt"]);
    assert_eq!(up_to_2[1].kind, EventKind::Synthetic);

    let all = store.read_session_upto("a", "s1", 100).expect("read");
    let messages: Vec<&str> = all.iter().map(|e| e.message.as_str()).collect();
    assert_eq!(messages, vec!["s1-agent", "s1-prompt", "s1-later"]);

    // Other sessions, session-less events and other instances are excluded.
    let other = store.read_session_upto("a", "s2", 100).expect("read");
    assert_eq!(other.len(), 1);
    assert_eq!(other[0].message, "s2-agent");
    assert!(store
        .read_session_upto("a", "unknown", 100)
        .expect("read")
        .is_empty());
    assert!(store
        .read_session_upto("nope", "s1", 100)
        .expect("read")
        .is_empty());
}

#[test]
fn a_new_session_starts_complete_and_only_pruning_makes_it_incomplete() {
    let store = Store::open_in_memory().expect("open");
    store
        .append_at(1, event("a", Some("old"), &"x".repeat(100)))
        .expect("append");
    assert!(store.session_complete("a", "old").expect("old"));
    // A second session registered after the first is complete from its start.
    store
        .append_at(2, event("a", Some("new"), &"y".repeat(100)))
        .expect("append");
    assert!(store.session_complete("a", "new").expect("new"));

    let report = store.prune("a", 100).expect("prune");
    assert_eq!(report.removed_events, 1);
    assert_eq!(report.sessions_marked_incomplete, 1);
    assert!(!store.session_complete("a", "old").expect("old"));
    assert!(
        store.session_complete("a", "new").expect("new"),
        "the session whose events survived is still complete"
    );

    // A session first seen after a prune is complete again: nothing of it was
    // ever dropped.
    store
        .append_at(3, event("a", Some("fresh"), "{}"))
        .expect("append");
    assert!(store.session_complete("a", "fresh").expect("fresh"));
}

#[test]
fn a_version_one_log_migrates_without_losing_events() {
    let dir = TempDir::new("migrate-v1");
    let path = dir.db();
    fs::create_dir_all(path.parent().expect("parent")).expect("mkdir");
    {
        let store = Store::open(&path).expect("open");
        store
            .append(event("old-instance", Some("old-session"), "kept"))
            .expect("append");
        store
            .save_team("t7", r#"{"id":"t7","cwd":"/p"}"#, 7, 3)
            .expect("save team");
    }
    // Turn the file back into the S4a schema: event tables only, version 1.
    {
        let conn = rusqlite::Connection::open(&path).expect("open raw");
        conn.execute_batch("DROP TABLE teams; DROP TABLE team_meta; PRAGMA user_version = 1;")
            .expect("downgrade");
    }
    let store = Store::open(&path).expect("migrate");
    let events = store.read(&Query::new("old-instance")).expect("read");
    assert_eq!(events.len(), 1);
    assert_eq!(events[0].message, "kept");
    let conn = rusqlite::Connection::open(&path).expect("open raw");
    let version: i64 = conn
        .query_row("PRAGMA user_version", [], |row| row.get(0))
        .expect("version");
    assert_eq!(version, 3);
    let tables: i64 = conn
        .query_row(
            "SELECT count(*) FROM sqlite_master WHERE type = 'table'
             AND name IN ('teams', 'team_meta', 'boards', 'card_history', 'workflows')",
            [],
            |row| row.get(0),
        )
        .expect("tables");
    assert_eq!(tables, 5);
}

#[test]
fn a_version_two_log_with_data_keeps_events_and_teams_when_upgraded() {
    let dir = TempDir::new("migrate-v2");
    let path = dir.db();
    fs::create_dir_all(path.parent().expect("parent")).expect("mkdir");
    {
        let store = Store::open(&path).expect("open");
        store
            .append(event("old-instance", Some("old-session"), "kept"))
            .expect("append");
        store
            .save_team("t7", r#"{"id":"t7","cwd":"/p"}"#, 7, 3)
            .expect("save team");
        store
            .save_board(
                "t7",
                4,
                r#"{"rev":4,"columns":[],"cards":[]}"#,
                &[("T1".to_string(), r#"{"id":"T1"}"#.to_string(), 3, 1)],
                &[],
            )
            .expect("save board");
        store
            .save_workflow("project", "/p", "review", r#"{"name":"review"}"#, 5)
            .expect("save workflow");
    }
    // Turn the file into the v2 schema: the team tables, none of the v3 ones.
    {
        let conn = rusqlite::Connection::open(&path).expect("open raw");
        conn.execute_batch(
            "DROP TABLE boards; DROP TABLE card_history; DROP TABLE workflows; \
             PRAGMA user_version = 2;",
        )
        .expect("downgrade");
    }
    let store = Store::open(&path).expect("migrate");
    let events = store.read(&Query::new("old-instance")).expect("read");
    assert_eq!(events.len(), 1);
    assert_eq!(events[0].message, "kept");
    let teams = store.load_teams().expect("teams");
    assert_eq!(teams.len(), 1);
    assert_eq!(teams[0].0, "t7");
    assert!(store.load_board("t7").expect("board").is_none());
    assert!(store.load_workflows().expect("workflows").is_empty());
    let conn = rusqlite::Connection::open(&path).expect("open raw");
    let version: i64 = conn
        .query_row("PRAGMA user_version", [], |row| row.get(0))
        .expect("version");
    assert_eq!(version, 3);
    let tables: i64 = conn
        .query_row(
            "SELECT count(*) FROM sqlite_master WHERE type = 'table'
             AND name IN ('boards', 'card_history', 'workflows')",
            [],
            |row| row.get(0),
        )
        .expect("tables");
    assert_eq!(tables, 3);
}

#[test]
fn workflows_are_stored_per_scope_and_project_and_survive_reopening() {
    let dir = TempDir::new("workflows");
    let path = dir.db();
    fs::create_dir_all(path.parent().expect("parent")).expect("mkdir");
    let workflow =
        r#"{"name":"review","summary":"by pi","text":"step","team":[],"scope":"project"}"#;
    {
        let store = Store::open(&path).expect("open");
        store
            .save_workflow("project", "/repo/.git", "review", workflow, 1)
            .expect("save");
        store
            .save_workflow("user", "", "review", workflow, 2)
            .expect("save user");
        store
            .save_workflow("project", "/repo/.git", "dev", workflow, 3)
            .expect("save dev");
    }
    let store = Store::open(&path).expect("reopen");
    let rows = store.load_workflows().expect("load");
    assert_eq!(rows.len(), 3, "{rows:?}");
    assert!(rows.iter().any(|(scope, project, name, json)| {
        scope == "project" && project == "/repo/.git" && name == "review" && json == workflow
    }));
    assert!(rows.iter().any(|(scope, project, name, _)| scope == "user"
        && project.is_empty()
        && name == "review"));
    // Replacing keeps one row per key; deleting is exact.
    store
        .save_workflow(
            "project",
            "/repo/.git",
            "review",
            "{\"name\":\"review\"}",
            4,
        )
        .expect("replace");
    assert_eq!(store.load_workflows().expect("load").len(), 3);
    store.delete_workflow("user", "", "review").expect("delete");
    let rows = store.load_workflows().expect("load");
    assert_eq!(rows.len(), 2);
    assert!(rows.iter().all(|(scope, _, _, _)| scope == "project"));
}
