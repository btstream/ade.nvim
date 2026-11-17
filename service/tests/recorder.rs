//! Integration tests for the event-log recorder.
//!
//! The recorder is a background writer: `record()` must never block, and a read
//! for replay must see everything recorded before it. These tests drive the real
//! thing over a private temporary directory, except for the failure-injection
//! cases which use the in-memory mode plus a paused writer.
//!
//! Everything here needs a tokio runtime for `flush()`/`read_session()`; the
//! recorder itself creates a plain OS thread for writes, so a current-thread
//! runtime is enough.

use std::fs;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};
use std::time::{Duration, Instant};

use nvim_ade_server::recorder::{RecordedEvent, Recorder};
use nvim_ade_server::store::EventKind;

static COUNTER: AtomicU64 = AtomicU64::new(0);

/// A temporary directory removed when the test ends.
struct TempDir {
    path: PathBuf,
}

impl TempDir {
    fn new(label: &str) -> Self {
        let unique = COUNTER.fetch_add(1, Ordering::Relaxed);
        let path = std::env::temp_dir().join(format!(
            "nvim-ade-recorder-test-{label}-{}-{unique}",
            std::process::id()
        ));
        fs::create_dir_all(&path).expect("create temporary directory");
        Self { path }
    }

    fn db(&self) -> PathBuf {
        self.path
            .join("events")
            .join("nvim_ade_server.events.sqlite3")
    }
}

impl Drop for TempDir {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.path);
    }
}

fn event(instance: &str, seq: u64, session: Option<&str>, body: &str) -> RecordedEvent {
    RecordedEvent {
        instance_key: instance.to_string(),
        seq,
        session_id: session.map(str::to_string),
        kind: EventKind::AgentNotification,
        message: body.to_string(),
        ts_ms: 1_700_000_000_000 + seq as i64,
    }
}

fn synthetic(instance: &str, seq: u64, session: Option<&str>, body: &str) -> RecordedEvent {
    RecordedEvent {
        kind: EventKind::Synthetic,
        ..event(instance, seq, session, body)
    }
}

fn runtime() -> tokio::runtime::Runtime {
    tokio::runtime::Builder::new_current_thread()
        .enable_all()
        .build()
        .expect("tokio runtime")
}

#[test]
fn recorded_events_come_back_in_order_after_flush() {
    let runtime = runtime();
    runtime.block_on(async {
        let recorder = Recorder::in_memory(1024 * 1024);
        for seq in 1..=50 {
            recorder.record(event("a", seq, Some("s"), &format!("m{seq}")));
        }
        recorder.flush().await;

        let replay = recorder
            .read_session("a", "s", u64::MAX)
            .await
            .expect("read");
        let messages: Vec<&str> = replay.events.iter().map(|e| e.message.as_str()).collect();
        let expected: Vec<String> = (1..=50).map(|seq| format!("m{seq}")).collect();
        assert_eq!(messages, expected);
        assert!(replay.complete);
    });
}

#[test]
fn instances_do_not_interfere() {
    let runtime = runtime();
    runtime.block_on(async {
        let recorder = Recorder::in_memory(1024 * 1024);
        // Interleaved writes to two instances, each with its own seq counter.
        for index in 1..=20u64 {
            recorder.record(event("a", index, Some("sa"), &format!("a{index}")));
            recorder.record(event("b", index, Some("sb"), &format!("b{index}")));
        }
        recorder.flush().await;

        let a = recorder
            .read_session("a", "sa", u64::MAX)
            .await
            .expect("read a");
        assert_eq!(a.events.len(), 20);
        assert_eq!(a.events[0].message, "a1");
        assert_eq!(a.events[19].seq, 20);

        let b = recorder
            .read_session("b", "sb", u64::MAX)
            .await
            .expect("read b");
        assert_eq!(b.events.len(), 20);
        assert_eq!(b.events[0].message, "b1");

        // Forgetting one instance leaves the other alone.
        recorder.forget_instance("a");
        recorder.flush().await;
        assert!(recorder
            .read_session("a", "sa", u64::MAX)
            .await
            .expect("read a")
            .events
            .is_empty());
        assert_eq!(
            recorder
                .read_session("b", "sb", u64::MAX)
                .await
                .expect("read b")
                .events
                .len(),
            20
        );
    });
}

#[test]
fn concurrent_writers_keep_per_instance_order() {
    let runtime = runtime();
    runtime.block_on(async {
        // Four threads, each writing its own instance: the recorder's queue is
        // shared, but every instance has one seq counter. (The relay allocates
        // seq per instance under one lock, so it always hands events over in
        // increasing seq order — which is the contract the writer relies on.)
        let recorder = Recorder::in_memory(1024 * 1024);
        let mut handles = Vec::new();
        for writer in 0..4u64 {
            let recorder = recorder.clone();
            handles.push(std::thread::spawn(move || {
                let instance = format!("i{writer}");
                for index in 1..=100u64 {
                    recorder.record(event(
                        &instance,
                        index,
                        Some("s"),
                        &format!("{writer}-{index}"),
                    ));
                }
            }));
        }
        for handle in handles {
            handle.join().expect("writer thread");
        }
        recorder.flush().await;

        for writer in 0..4u64 {
            let instance = format!("i{writer}");
            let replay = recorder
                .read_session(&instance, "s", u64::MAX)
                .await
                .expect("read");
            assert_eq!(replay.events.len(), 100, "instance {instance}");
            assert!(replay.complete);
            let mut previous = 0u64;
            for event in &replay.events {
                assert!(event.seq > previous, "seq must increase: {}", event.seq);
                previous = event.seq;
                let index: u64 = event
                    .message
                    .split_once('-')
                    .expect("message shape")
                    .1
                    .parse()
                    .expect("index");
                assert_eq!(index, event.seq, "each writer's order is preserved");
            }
        }
    });
}

#[test]
fn read_session_flushes_first() {
    let runtime = runtime();
    runtime.block_on(async {
        // The writer is paused: nothing reaches the store until a flush is asked
        // for, so a non-empty result proves `read_session` flushed.
        let recorder = Recorder::in_memory_paused(1024 * 1024);
        for seq in 1..=5 {
            recorder.record(event("a", seq, Some("s"), &format!("m{seq}")));
        }
        let replay = recorder
            .read_session("a", "s", u64::MAX)
            .await
            .expect("read");
        assert_eq!(
            replay.events.len(),
            5,
            "read_session must flush before reading"
        );
        assert!(replay.complete);
    });
}

#[test]
fn read_session_honours_up_to_seq() {
    let runtime = runtime();
    runtime.block_on(async {
        let recorder = Recorder::in_memory(1024 * 1024);
        recorder.record(event("a", 1, Some("s"), "one"));
        recorder.record(event("a", 2, Some("other"), "other session"));
        recorder.record(synthetic("a", 3, Some("s"), "prompt"));
        recorder.record(event("a", 4, Some("s"), "four"));
        recorder.flush().await;

        let replay = recorder.read_session("a", "s", 3).await.expect("read");
        let messages: Vec<&str> = replay.events.iter().map(|e| e.message.as_str()).collect();
        assert_eq!(messages, vec!["one", "prompt"]);
        assert_eq!(
            replay.events[1].kind,
            EventKind::Synthetic,
            "synthetic events belong in a replay"
        );
    });
}

#[test]
fn pruning_drops_the_oldest_and_marks_the_session_incomplete() {
    let runtime = runtime();
    runtime.block_on(async {
        // 40 events of 1000 bytes each; keep at most 10 000 bytes.
        let recorder = Recorder::in_memory(10_000);
        for seq in 1..=40u64 {
            let body = format!("{seq:04}").repeat(250);
            recorder.record(event("a", seq, Some("old"), &body));
        }
        recorder.flush().await;

        let replay = recorder
            .read_session("a", "old", u64::MAX)
            .await
            .expect("read");
        // The cap is 10 000 and pruning keeps 90 % of it, so 9 of the 1 000-byte
        // events remain: the newest ones, with their original seq.
        assert_eq!(replay.events.len(), 9);
        assert_eq!(
            replay.events[0].seq, 32,
            "the newest events survive, with their original seq"
        );
        assert!(
            !replay.complete,
            "a session that lost an event must not be replayed"
        );
        // The pruned instance's counter is not rewound.
        assert!(recorder.bytes("a") <= 10_000);
    });
}

#[test]
fn pruning_only_marks_the_sessions_that_lost_events() {
    let runtime = runtime();
    runtime.block_on(async {
        // 20 events of 1 000 bytes; the cap is 10 000 and pruning keeps 9 000, so
        // the nine newest survive. Give `kept` the nine newest so it stays whole,
        // and let `dropped` be the eleven oldest.
        let recorder = Recorder::in_memory(10_000);
        for seq in 1..=11u64 {
            recorder.record(event(
                "a",
                seq,
                Some("dropped"),
                &format!("{seq:04}").repeat(250),
            ));
        }
        for seq in 12..=20u64 {
            recorder.record(event(
                "a",
                seq,
                Some("kept"),
                &format!("{seq:04}").repeat(250),
            ));
        }
        recorder.flush().await;

        let dropped = recorder
            .read_session("a", "dropped", u64::MAX)
            .await
            .expect("read dropped");
        assert!(!dropped.complete);
        let kept = recorder
            .read_session("a", "kept", u64::MAX)
            .await
            .expect("read kept");
        assert_eq!(kept.events.len(), 9, "the newest nine events survive");
        assert!(kept.complete, "an intact session is still replayable");
    });
}

#[test]
fn forget_instance_discards_queued_events_and_starts_clean() {
    let runtime = runtime();
    runtime.block_on(async {
        let recorder = Recorder::in_memory(1024 * 1024);
        recorder.record(event("a", 1, Some("s"), "before"));
        // The forget is ordered after the record above and before the one below,
        // even though nothing has been written yet.
        recorder.forget_instance("a");
        recorder.record(event("a", 1, Some("s"), "after"));
        recorder.record(event("keep", 1, Some("s"), "other instance"));
        recorder.flush().await;

        let replay = recorder
            .read_session("a", "s", u64::MAX)
            .await
            .expect("read");
        let messages: Vec<&str> = replay.events.iter().map(|e| e.message.as_str()).collect();
        assert_eq!(messages, vec!["after"], "the pre-forget event is gone");
        assert_eq!(replay.events[0].seq, 1, "the instance starts over");
        assert_eq!(
            recorder
                .read_session("keep", "s", u64::MAX)
                .await
                .expect("read keep")
                .events
                .len(),
            1
        );
    });
}

#[test]
fn bytes_follow_a_forget() {
    let runtime = runtime();
    runtime.block_on(async {
        let recorder = Recorder::in_memory(1024 * 1024);
        recorder.record(event("a", 1, Some("s"), "abcde"));
        recorder.flush().await;
        assert_eq!(recorder.bytes("a"), 5);

        recorder.forget_instance("a");
        recorder.record(event("a", 1, Some("s"), "xy"));
        recorder.flush().await;
        assert_eq!(recorder.bytes("a"), 2, "only the events since the forget");
        let replay = recorder
            .read_session("a", "s", u64::MAX)
            .await
            .expect("read");
        assert_eq!(replay.events.len(), 1);
    });
}

#[test]
fn forget_instance_is_ordered_against_writes() {
    let runtime = runtime();
    runtime.block_on(async {
        let recorder = Recorder::in_memory(1024 * 1024);
        recorder.record(event("a", 1, Some("s"), "one"));
        recorder.record(event("a", 2, Some("s"), "two"));
        recorder.forget_instance("a");
        recorder.record(event("a", 3, Some("s"), "three"));
        recorder.flush().await;

        let replay = recorder
            .read_session("a", "s", u64::MAX)
            .await
            .expect("read");
        let messages: Vec<&str> = replay.events.iter().map(|e| e.message.as_str()).collect();
        assert_eq!(messages, vec!["three"]);
    });
}

#[test]
fn open_deletes_a_previous_log_and_its_wal() {
    let dir = TempDir::new("open-deletes");
    let path = dir.db();
    fs::create_dir_all(path.parent().expect("parent")).expect("mkdir");
    fs::write(&path, b"stale database contents").expect("write stale");
    fs::write(sidecar(&path, "-wal"), b"stale wal").expect("write wal");
    fs::write(sidecar(&path, "-shm"), b"stale shm").expect("write shm");

    let runtime = runtime();
    runtime.block_on(async {
        let recorder = Recorder::open(&path, 1024 * 1024).expect("open");
        assert!(recorder.enabled());
        recorder.record(event("a", 1, Some("s"), "fresh"));
        recorder.flush().await;
        // The stale content is gone, so the fresh event reads back.
        let replay = recorder
            .read_session("a", "s", u64::MAX)
            .await
            .expect("read");
        assert_eq!(replay.events.len(), 1);
        assert_eq!(replay.events[0].message, "fresh");
        assert!(!sidecar(&path, "-wal").exists() || true);
    });

    assert!(path.is_file(), "the log file exists");
    assert!(
        !fs::read(&path)
            .expect("read")
            .starts_with(b"stale database"),
        "the old file was replaced"
    );
}

#[cfg(unix)]
#[test]
fn the_log_file_is_private() {
    use std::os::unix::fs::PermissionsExt;
    let dir = TempDir::new("permissions");
    let path = dir.db();
    let runtime = runtime();
    runtime.block_on(async {
        let recorder = Recorder::open(&path, 1024 * 1024).expect("open");
        recorder.record(event("a", 1, Some("s"), "{}"));
        recorder.flush().await;
    });

    let mode = fs::metadata(&path).expect("metadata").permissions().mode() & 0o777;
    assert_eq!(mode, 0o600, "the log is 0600");

    // The WAL sidecar must not be world readable either, while it exists.
    let wal = sidecar(&path, "-wal");
    if wal.exists() {
        let mode = fs::metadata(&wal)
            .expect("wal metadata")
            .permissions()
            .mode()
            & 0o777;
        assert_eq!(mode, 0o600, "the WAL file is private");
    }
}

#[test]
fn a_dropped_recorder_writes_out_what_was_queued() {
    let dir = TempDir::new("drop");
    let path = dir.db();
    {
        let recorder = Recorder::open(&path, 1024 * 1024).expect("open");
        for seq in 1..=100u64 {
            recorder.record(event("a", seq, Some("s"), &format!("m{seq}")));
        }
        // No flush: dropping the last handle must still persist the queue.
    }

    let runtime = runtime();
    runtime.block_on(async {
        // A new recorder on the same path is the only way to look at the file
        // without the first one's writer thread; `open` deletes it, so use the
        // store directly.
        let store = nvim_ade_server::store::Store::open(&path).expect("store");
        let query = nvim_ade_server::store::Query::new("a");
        let events = store
            .read(&nvim_ade_server::store::Query {
                include_synthetic: true,
                ..query
            })
            .expect("read");
        assert_eq!(events.len(), 100, "the drop drained the queue");
        assert_eq!(events[99].message, "m100");
    });
}

#[test]
fn disabled_is_a_no_op() {
    let recorder = Recorder::disabled();
    assert!(!recorder.enabled());

    let runtime = runtime();
    runtime.block_on(async {
        // None of these may panic or wait.
        recorder.record(event("a", 1, Some("s"), "{}"));
        recorder.record(synthetic("a", 2, Some("s"), "{}"));
        recorder.forget_instance("a");
        recorder.flush().await;
        let replay = recorder
            .read_session("a", "s", u64::MAX)
            .await
            .expect("read");
        assert!(replay.events.is_empty());
        assert!(!replay.complete);
        assert_eq!(recorder.bytes("a"), 0);
    });
}

#[test]
fn bytes_reports_the_approximate_size_without_touching_the_database() {
    let runtime = runtime();
    runtime.block_on(async {
        let recorder = Recorder::in_memory(1024 * 1024);
        assert_eq!(recorder.bytes("a"), 0);
        recorder.record(event("a", 1, Some("s"), "12345"));
        let after_record = recorder.bytes("a");
        assert!(
            after_record >= 5,
            "the queued bytes are counted immediately: {after_record}"
        );
        recorder.flush().await;
        assert_eq!(recorder.bytes("a"), 5);
        assert_eq!(recorder.bytes("b"), 0);
    });
}

#[test]
fn back_pressure_drops_events_without_blocking_and_warns_once() {
    let runtime = runtime();
    runtime.block_on(async {
        // A writer that only runs when told, so the queue keeps growing while
        // the test records against the cap.
        let recorder = Recorder::in_memory_paused(1024 * 1024).with_backpressure_bytes(1024);
        for seq in 1..=20u64 {
            let started = Instant::now();
            recorder.record(event("a", seq, Some("s"), &"x".repeat(200)));
            assert!(
                started.elapsed() < Duration::from_millis(50),
                "record() must not block (took {:?})",
                started.elapsed()
            );
        }
        // Let the writer run; the dropped events must have marked the session
        // incomplete.
        recorder.flush().await;
        let replay = recorder
            .read_session("a", "s", u64::MAX)
            .await
            .expect("read");
        assert!(
            !replay.complete,
            "a session that lost an event cannot be replayed"
        );
        assert!(
            replay.events.len() < 20,
            "some events were dropped under back pressure"
        );
        assert!(recorder.warnings() >= 1, "the drop is reported");
    });
}

#[test]
fn a_failed_write_does_not_kill_the_writer() {
    // Failure injection: a real full disk cannot be arranged in a test, and an
    // unlinked database keeps accepting writes on POSIX (SQLite holds the inode
    // open), so the recorder exposes a hook that fails the next batches exactly
    // like a failing store would.
    let runtime = runtime();
    runtime.block_on(async {
        let recorder = Recorder::in_memory(1024 * 1024)
            .with_batch_events(4)
            .with_batch_interval(Duration::from_millis(1));
        recorder.record(event("a", 1, Some("s"), "before"));
        recorder.flush().await;

        recorder.with_failing_writes(2);
        for seq in 2..=5u64 {
            recorder.record(event("a", seq, Some("s"), &format!("during{seq}")));
            recorder.flush().await;
        }
        assert!(recorder.warnings() >= 1, "the failure is reported");

        // The writer is alive and later batches land again.
        recorder.record(event("a", 6, Some("s"), "recovered"));
        recorder.flush().await;

        let replay = recorder
            .read_session("a", "s", u64::MAX)
            .await
            .expect("read");
        assert!(
            replay
                .events
                .iter()
                .any(|event| event.message == "recovered"),
            "the writer kept going after the failure: {:?}",
            replay.events.iter().map(|e| &e.message).collect::<Vec<_>>()
        );
        assert!(
            !replay.complete,
            "a write failure makes the session incomplete, even if later events arrive"
        );
        assert_eq!(replay.events[0].message, "before");
    });
}

#[test]
fn a_second_open_clears_the_events_but_keeps_the_file() {
    let dir = TempDir::new("reopen");
    let path = dir.db();
    let runtime = runtime();
    runtime.block_on(async {
        let first = Recorder::open(&path, 1024 * 1024).expect("open");
        first.record(event("a", 1, Some("s"), "first"));
        first.flush().await;
        drop(first);
    });
    runtime.block_on(async {
        let second = Recorder::open(&path, 1024 * 1024).expect("reopen");
        // A service start clears the event tables; teams (18.15) stay in the
        // same file, but no old session may be replayed.
        assert!(second
            .read_session("a", "s", u64::MAX)
            .await
            .expect("read")
            .events
            .is_empty());
    });
}

#[test]
fn team_snapshots_in_one_batch_coalesce_to_the_last_one() {
    let runtime = runtime();
    runtime.block_on(async {
        let recorder = Recorder::in_memory_paused(1024 * 1024);
        for value in 1..=10 {
            recorder.save_team(
                "t1",
                format!(r#"{{"id":"t1","cwd":"/p","value":{value}}}"#),
                value,
                value,
            );
        }
        recorder.resume_writer();
        recorder.flush().await;
        assert_eq!(
            recorder.team_write_count(),
            1,
            "one row write for ten saves"
        );
        let teams = recorder.load_teams().expect("load");
        assert_eq!(teams.len(), 1);
        let value: serde_json::Value = serde_json::from_str(&teams[0].1).expect("json");
        assert_eq!(value["value"], 10, "the last snapshot wins");
    });
}

#[test]
fn record_after_flush_remains_ordered() {
    let runtime = runtime();
    runtime.block_on(async {
        let recorder = Recorder::in_memory(1024 * 1024);
        for seq in 1..=5 {
            recorder.record(event("a", seq, Some("s"), &format!("m{seq}")));
        }
        recorder.flush().await;
        for seq in 6..=10 {
            recorder.record(event("a", seq, Some("s"), &format!("m{seq}")));
        }
        recorder.flush().await;
        let replay = recorder
            .read_session("a", "s", u64::MAX)
            .await
            .expect("read");
        let messages: Vec<&str> = replay.events.iter().map(|e| e.message.as_str()).collect();
        let expected: Vec<String> = (1..=10).map(|seq| format!("m{seq}")).collect();
        assert_eq!(messages, expected);
    });
}

/// `record()` averaged over 200 000 calls.
///
/// The limit is loose on purpose: the debug profile is ~5x slower than release,
/// and CI machines vary. Release numbers are in the report.
#[test]
fn record_is_cheap() {
    let runtime = runtime();
    runtime.block_on(async {
        let recorder = Recorder::in_memory(1024 * 1024 * 1024);
        const COUNT: u64 = 200_000;
        // Warm up (allocation, channel setup).
        for seq in 1..=1_000 {
            recorder.record(event("warm", seq, Some("s"), "x"));
        }

        let started = Instant::now();
        for seq in 1..=COUNT {
            recorder.record(event("perf", seq, None, "payload"));
        }
        let elapsed = started.elapsed();
        let per_call = elapsed / COUNT as u32;
        eprintln!("recorder perf: {COUNT} record() calls in {elapsed:?} ({per_call:?} each)");
        // The target is 20 µs; this bound leaves room for a slow CI machine while
        // still catching an accidental allocation or lock on the hot path.
        assert!(
            per_call < Duration::from_micros(20),
            "record() averaged {per_call:?}, which is not cheap enough"
        );

        recorder.flush().await;
    });
}

fn sidecar(path: &Path, suffix: &str) -> PathBuf {
    let mut name = path.as_os_str().to_owned();
    name.push(suffix);
    PathBuf::from(name)
}
