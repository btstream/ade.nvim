//! Asynchronous recorder for the event log (PROTOCOL.md sections 10-15).
//!
//! The relay must never wait for a disk. It hands each event to [`Recorder`],
//! which appends it to an in-memory queue and returns immediately; a dedicated
//! writer thread turns the queue into `append_batch_at` transactions on the
//! [`Store`].
//!
//! # The parts that matter
//!
//! - **Order.** One queue and one writer thread: jobs are written in the order
//!   they were handed over, per instance and overall.
//! - **Barrier.** [`Recorder::flush`] pushes a marker into the same queue, so when
//!   it completes every earlier `record`/`forget_instance` is written and
//!   readable. No sleeping, no polling.
//! - **Retention.** After each batch, an instance over its byte cap is pruned to
//!   90 % of the cap. Sessions that lose events become incomplete and are never
//!   replayed (section 12 declines them).
//! - **Back pressure.** `record()` never blocks. Above 64 MiB queued, new events
//!   are dropped and the affected instances are marked incomplete; one warning
//!   line is printed, not one per event.
//! - **Failures.** A failed write does not stop the writer: the error is logged
//!   at most once every 10 s, the instance is marked incomplete, and later
//!   batches are still attempted.
//! - **Disabled.** `--event-log off` gives a recorder with no thread and no file;
//!   every method is a no-op.
//!
//! The recorder is `Clone` (it is one `Arc`), so the relay and the API can hold
//! their own handles.

use std::collections::HashMap;
use std::path::Path;
use std::sync::atomic::{AtomicBool, AtomicUsize, Ordering};
use std::sync::mpsc::{self, Receiver, RecvTimeoutError, Sender};
use std::sync::{Arc, Mutex};
use std::thread::JoinHandle;
use std::time::{Duration, Instant};

use anyhow::{Context, Result};
use tokio::sync::oneshot;

use crate::store::{Event, EventKind, NewEvent, Store};

/// Events per write transaction.
pub const DEFAULT_BATCH_EVENTS: usize = 256;
/// Longest a batch waits for more events before it is written.
pub const DEFAULT_BATCH_INTERVAL: Duration = Duration::from_millis(20);
/// Queued bytes above which new events are dropped instead of buffered.
pub const DEFAULT_BACKPRESSURE_BYTES: usize = 64 * 1024 * 1024;
/// Pruning keeps this fraction of the per-instance cap: 9/10.
const PRUNE_KEEP: u64 = 9;
const PRUNE_SCALE: u64 = 10;
/// How long dropping the last handle waits for the writer to drain, at most.
const SHUTDOWN_TIMEOUT: Duration = Duration::from_secs(5);

/// One event the relay wants recorded.
///
/// `seq` is allocated by the relay (PROTOCOL.md section 3.7), not by the store,
/// so live `tunnel.recv` and the log agree on numbers.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct RecordedEvent {
    /// Instance identity; the log is deleted with the instance.
    pub instance_key: String,
    /// The instance's sequence number for this event.
    pub seq: u64,
    /// The ACP session, when the event belongs to one.
    pub session_id: Option<String>,
    /// Agent notification or a synthetic front-end event.
    pub kind: EventKind,
    /// Raw JSON text, stored verbatim.
    pub message: String,
    /// Unix epoch milliseconds, chosen by the relay.
    pub ts_ms: i64,
}

/// What [`Recorder::read_session`] returns.
#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct Replay {
    /// The session's recorded events, oldest first.
    pub events: Vec<Event>,
    /// Whether the log holds the whole session (nothing pruned or dropped).
    pub complete: bool,
}

/// One queued record: the instance it belongs to, its seq, and the row.
struct Pending {
    instance: String,
    seq: u64,
    event: NewEvent,
}

/// One thing the writer thread has to do, in queue order.
enum Job {
    Record(Pending),
    Forget(String),
    /// Mark every session of the instance incomplete (a dropped event).
    MarkIncomplete(String),
    /// Complete the receiver once every earlier job is written.
    Barrier(oneshot::Sender<()>),
}

/// Tuning knobs. Defaults are the documented values; tests use the `with_*`
/// builders so they never wait for a real 20 ms batch or 10 s warning.
#[derive(Debug, Clone)]
struct Limits {
    batch_events: usize,
    batch_interval: Duration,
    backpressure_bytes: usize,
    warning_interval: Duration,
}

impl Default for Limits {
    fn default() -> Self {
        Self {
            batch_events: DEFAULT_BATCH_EVENTS,
            batch_interval: DEFAULT_BATCH_INTERVAL,
            backpressure_bytes: DEFAULT_BACKPRESSURE_BYTES,
            warning_interval: Duration::from_secs(10),
        }
    }
}

/// State shared by every clone of a recorder.
struct Inner {
    /// The database. `read_session` reads it directly; the writer only writes.
    store: Arc<Store>,
    /// `None` once the last handle is dropped; the writer then drains and exits.
    sender: Mutex<Option<Sender<Job>>>,
    writer: Mutex<Option<JoinHandle<()>>>,
    /// Bytes queued but not yet written, across all instances.
    queued_bytes: AtomicUsize,
    /// Per-instance bytes: queued plus written, deliberately approximate.
    bytes: Mutex<HashMap<String, u64>>,
    /// How many warning lines this recorder has printed.
    warnings: AtomicUsize,
    /// Whether the single back-pressure warning was already printed.
    warned_backpressure: AtomicBool,
    /// Set by the last `Drop`: a paused writer must stop waiting and exit.
    closing: AtomicBool,
    /// Live `Recorder` handles. The writer thread also holds an `Arc<Inner>`, so
    /// `Arc::strong_count` cannot answer "is this the last handle"; this can.
    handles: AtomicUsize,
    /// Batches the writer must pretend to fail, for the write-failure test path.
    /// Zero in normal operation.
    fail_batches: AtomicUsize,
    /// Writer gate: while set, the writer waits before each batch. Only the
    /// documented test hooks ([`Recorder::in_memory_paused`] /
    /// [`Recorder::resume_writer`]) ever set it.
    paused: Arc<(Mutex<bool>, std::sync::Condvar)>,
}

/// Handle to the asynchronous event log.
pub struct Recorder {
    inner: Arc<Inner>,
    enabled: bool,
    max_bytes_per_instance: u64,
    limits: Limits,
}

impl Recorder {
    /// Open the log at `path` and start the writer thread.
    ///
    /// The file is deleted first, together with its `-wal`/`-shm` sidecars
    /// (PROTOCOL.md section 10: a log never survives a service restart, because
    /// no instance does). The store creates the new file with permission 0600.
    ///
    /// `max_bytes_per_instance` is the retention cap for one instance.
    pub fn open(path: &Path, max_bytes_per_instance: u64) -> Result<Recorder> {
        remove_log_files(path)?;
        let store = Store::open(path)
            .with_context(|| format!("opening the event log at {}", path.display()))?;
        Ok(Self::start(
            store,
            max_bytes_per_instance,
            Limits::default(),
        ))
    }

    /// A recorder over an in-memory store, for tests.
    pub fn in_memory(max_bytes_per_instance: u64) -> Recorder {
        let store = Store::open_in_memory().expect("open in-memory event store");
        Self::start(store, max_bytes_per_instance, Limits::default())
    }

    /// A recorder whose writer thread waits until [`Recorder::resume_writer`] is
    /// called.
    ///
    /// A test hook: it proves that `read_session` flushes, and that `record()`
    /// stays non-blocking while the queue grows. The production service never
    /// uses it.
    pub fn in_memory_paused(max_bytes_per_instance: u64) -> Recorder {
        let store = Store::open_in_memory().expect("open in-memory event store");
        let recorder = Self::start(store, max_bytes_per_instance, Limits::default());
        *recorder.inner.paused.0.lock().expect("pause") = true;
        recorder
    }

    /// A recorder that writes nothing: `--event-log off`.
    ///
    /// No thread, no file, no queue; every call is a no-op and `enabled()` is
    /// false.
    pub fn disabled() -> Recorder {
        let store = Store::open_in_memory().expect("open in-memory event store");
        Recorder {
            inner: Arc::new(Inner {
                store: Arc::new(store),
                sender: Mutex::new(None),
                writer: Mutex::new(None),
                queued_bytes: AtomicUsize::new(0),
                bytes: Mutex::new(HashMap::new()),
                warnings: AtomicUsize::new(0),
                warned_backpressure: AtomicBool::new(false),
                closing: AtomicBool::new(false),
                handles: AtomicUsize::new(0),
                fail_batches: AtomicUsize::new(0),
                paused: Arc::new((Mutex::new(false), std::sync::Condvar::new())),
            }),
            enabled: false,
            max_bytes_per_instance: 0,
            limits: Limits::default(),
        }
    }

    /// Whether recording is on.
    pub fn enabled(&self) -> bool {
        self.enabled
    }

    /// Queue one event. Never blocks.
    ///
    /// Events are written in the order they are handed over. Above the back
    /// pressure limit the event is dropped and its instance marked incomplete;
    /// the caller is not told per event.
    pub fn record(&self, event: RecordedEvent) {
        if !self.enabled {
            return;
        }
        let size = event.message.len() as u64;
        let queued = self.inner.queued_bytes.load(Ordering::Relaxed);
        if queued.saturating_add(event.message.len()) > self.limits.backpressure_bytes {
            self.drop_for_backpressure(&event.instance_key);
            return;
        }
        let instance = event.instance_key.clone();
        let pending = Pending {
            instance: instance.clone(),
            seq: event.seq,
            event: NewEvent {
                instance_key: event.instance_key,
                session_id: event.session_id,
                kind: event.kind,
                message: event.message,
                ts_ms: event.ts_ms,
            },
        };
        // Count before handing over: the writer may process the job (and
        // subtract its bytes) before this call returns.
        self.inner
            .queued_bytes
            .fetch_add(size as usize, Ordering::Relaxed);
        self.add_bytes(&instance, size);
        if !self.send(Job::Record(pending)) {
            // The writer is gone; the bytes will never be written.
            self.inner
                .queued_bytes
                .fetch_sub(size as usize, Ordering::Relaxed);
        }
    }

    /// Wait until everything recorded before this call is written and readable.
    ///
    /// A barrier job in the same queue, so it also orders against
    /// [`Recorder::forget_instance`].
    pub async fn flush(&self) {
        if !self.enabled {
            return;
        }
        let (sender, receiver) = oneshot::channel();
        // A flush means "write everything now", so it also lifts a test pause:
        // pausing is about the writer's own timer, not about explicit barriers.
        self.release_pause();
        if !self.send(Job::Barrier(sender)) {
            return;
        }
        // A torn-down writer drops the sender, completing the receiver with an
        // error; there is nothing left to wait for then.
        let _ = receiver.await;
    }

    /// Flush, then read one session's events up to `up_to_seq`.
    ///
    /// Reading touches SQLite, so it runs on the blocking pool.
    pub async fn read_session(
        &self,
        instance_key: &str,
        session_id: &str,
        up_to_seq: u64,
    ) -> Result<Replay> {
        if !self.enabled {
            return Ok(Replay::default());
        }
        self.flush().await;
        let store = Arc::clone(&self.inner.store);
        let instance_key = instance_key.to_string();
        let session_id = session_id.to_string();
        tokio::task::spawn_blocking(move || {
            let events = store.read_session_upto(&instance_key, &session_id, up_to_seq)?;
            let complete = store.session_complete(&instance_key, &session_id)?;
            Ok(Replay { events, complete })
        })
        .await
        .context("reading the event log")?
    }

    /// Queue "delete this instance's log", ordered with the events around it.
    pub fn forget_instance(&self, instance_key: &str) {
        if !self.enabled {
            return;
        }
        self.inner
            .bytes
            .lock()
            .expect("bytes lock")
            .remove(instance_key);
        self.send(Job::Forget(instance_key.to_string()));
    }

    /// Approximate bytes held for one instance (queued plus written).
    ///
    /// An in-memory counter: it never touches the database, and it can be
    /// slightly ahead of what is durable.
    pub fn bytes(&self, instance_key: &str) -> u64 {
        if !self.enabled {
            return 0;
        }
        self.inner
            .bytes
            .lock()
            .expect("bytes lock")
            .get(instance_key)
            .copied()
            .unwrap_or(0)
    }

    /// How many warning lines this recorder has printed.
    ///
    /// Diagnostics for tests; not part of the protocol.
    pub fn warnings(&self) -> usize {
        self.inner.warnings.load(Ordering::Relaxed)
    }

    /// Events per batch, so a test can make the writer run promptly.
    pub fn with_batch_events(mut self, events: usize) -> Recorder {
        self.limits.batch_events = events.max(1);
        self
    }

    /// Batch interval, so a test does not wait for the 20 ms default.
    pub fn with_batch_interval(mut self, interval: Duration) -> Recorder {
        self.limits.batch_interval = interval;
        self
    }

    /// Back-pressure cap, so a test can reach the drop path quickly.
    pub fn with_backpressure_bytes(mut self, bytes: usize) -> Recorder {
        self.limits.backpressure_bytes = bytes.max(1);
        self
    }

    /// Warning rate limit, so a test does not wait 10 s.
    pub fn with_warning_interval(mut self, interval: Duration) -> Recorder {
        self.limits.warning_interval = interval;
        self
    }

    /// Make the next `batches` write attempts fail without touching the store.
    ///
    /// A test hook for the write-failure path: a real full disk is not something
    /// a test can arrange, and an unlinked file keeps accepting writes on POSIX.
    /// The failure is handled exactly like a real one (warning, incomplete mark,
    /// later batches still attempted).
    pub fn with_failing_writes(&self, batches: usize) -> &Self {
        self.inner.fail_batches.store(batches, Ordering::Relaxed);
        self
    }

    /// Let a paused writer thread run (see [`Recorder::in_memory_paused`]).
    pub fn resume_writer(&self) {
        self.release_pause();
    }

    fn release_pause(&self) {
        let (lock, condvar) = &*self.inner.paused;
        let mut paused = lock.lock().expect("pause");
        if *paused {
            *paused = false;
            condvar.notify_all();
        }
    }

    // -- internals ----------------------------------------------------------

    fn start(store: Store, max_bytes_per_instance: u64, limits: Limits) -> Recorder {
        let (sender, receiver) = mpsc::channel::<Job>();
        let inner = Arc::new(Inner {
            store: Arc::new(store),
            sender: Mutex::new(Some(sender)),
            writer: Mutex::new(None),
            queued_bytes: AtomicUsize::new(0),
            bytes: Mutex::new(HashMap::new()),
            warnings: AtomicUsize::new(0),
            warned_backpressure: AtomicBool::new(false),
            closing: AtomicBool::new(false),
            handles: AtomicUsize::new(1),
            fail_batches: AtomicUsize::new(0),
            paused: Arc::new((Mutex::new(false), std::sync::Condvar::new())),
        });

        let writer = Writer {
            store: Arc::clone(&inner.store),
            inner: Arc::clone(&inner),
            limits: limits.clone(),
            max_bytes_per_instance,
            last_warning: None,
            written: HashMap::new(),
            paused: Arc::clone(&inner.paused),
        };
        let handle = std::thread::Builder::new()
            .name("ade-event-log".to_string())
            .spawn(move || writer.run(receiver))
            .expect("spawn the event-log writer thread");
        *inner.writer.lock().expect("writer lock") = Some(handle);

        Recorder {
            inner,
            enabled: true,
            max_bytes_per_instance,
            limits,
        }
    }

    fn send(&self, job: Job) -> bool {
        let sender = self.inner.sender.lock().expect("sender lock");
        let Some(sender) = sender.as_ref() else {
            return false;
        };
        sender.send(job).is_ok()
    }

    fn add_bytes(&self, instance_key: &str, size: u64) {
        let mut bytes = self.inner.bytes.lock().expect("bytes lock");
        *bytes.entry(instance_key.to_string()).or_insert(0) += size;
    }

    fn drop_for_backpressure(&self, instance_key: &str) {
        if !self.inner.warned_backpressure.swap(true, Ordering::Relaxed) {
            self.inner.warnings.fetch_add(1, Ordering::Relaxed);
            eprintln!(
                "nvim_ade_server: warning: event log queue exceeded {} bytes; \
                 dropping events and marking affected sessions incomplete",
                self.limits.backpressure_bytes
            );
        }
        // Land the mark in the database in queue order, so a later replay cannot
        // treat the session as complete.
        self.send(Job::MarkIncomplete(instance_key.to_string()));
    }
}

impl Clone for Recorder {
    fn clone(&self) -> Self {
        self.inner.handles.fetch_add(1, Ordering::Relaxed);
        Recorder {
            inner: Arc::clone(&self.inner),
            enabled: self.enabled,
            max_bytes_per_instance: self.max_bytes_per_instance,
            limits: self.limits.clone(),
        }
    }
}

impl Drop for Recorder {
    fn drop(&mut self) {
        // The writer thread holds its own `Arc<Inner>`, so the shared state only
        // dies with the last *handle*; that is what this counter tracks.
        if self.inner.handles.fetch_sub(1, Ordering::AcqRel) != 1 {
            return;
        }
        // Last handle: let a paused writer notice and stop, then close the queue
        // so it drains what is left and exits.
        self.inner.closing.store(true, Ordering::Relaxed);
        self.release_pause();
        let sender = self.inner.sender.lock().expect("sender lock").take();
        drop(sender);
        let handle = self.inner.writer.lock().expect("writer lock").take();
        let Some(handle) = handle else {
            return;
        };
        // Bounded wait: a wedged filesystem must not hold the service open.
        let started = Instant::now();
        while !handle.is_finished() && started.elapsed() < SHUTDOWN_TIMEOUT {
            std::thread::sleep(Duration::from_millis(1));
        }
        if handle.is_finished() {
            let _ = handle.join();
        }
    }
}

impl std::fmt::Debug for Recorder {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter
            .debug_struct("Recorder")
            .field("enabled", &self.enabled)
            .field("max_bytes_per_instance", &self.max_bytes_per_instance)
            .finish_non_exhaustive()
    }
}

/// The single writer thread.
struct Writer {
    store: Arc<Store>,
    inner: Arc<Inner>,
    limits: Limits,
    max_bytes_per_instance: u64,
    /// Last time a write-failure warning was printed, for the rate limit.
    last_warning: Option<Instant>,
    /// Highest seq already written per instance, so an event that arrives after
    /// a higher number for the same instance can be recognised as late.
    written: HashMap<String, u64>,
    paused: Arc<(Mutex<bool>, std::sync::Condvar)>,
}

impl Writer {
    fn run(mut self, receiver: Receiver<Job>) {
        loop {
            self.wait_when_paused();
            let first = match receiver.recv_timeout(self.limits.batch_interval) {
                Ok(job) => job,
                Err(RecvTimeoutError::Timeout) => continue,
                Err(RecvTimeoutError::Disconnected) => {
                    // Every sender is gone: write what is still queued, then
                    // exit. Nothing arrives after this.
                    self.drain(&receiver);
                    return;
                }
            };

            // One batch: consecutive `Record`s. Any other job ends the batch,
            // and is applied **at its own position in the queue** — a forget or a
            // barrier must not jump ahead of the events recorded after it.
            let mut batch: Vec<Pending> = Vec::new();
            let deadline = Instant::now() + self.limits.batch_interval;
            let mut next = Some(first);
            while let Some(job) = next.take() {
                match job {
                    Job::Record(pending) => {
                        batch.push(pending);
                        if batch.len() >= self.limits.batch_events {
                            self.write(&mut batch);
                            break;
                        }
                        if Instant::now() >= deadline {
                            break;
                        }
                        match receiver.recv_timeout(Duration::from_millis(1)) {
                            Ok(job) => next = Some(job),
                            Err(RecvTimeoutError::Timeout) => break,
                            Err(RecvTimeoutError::Disconnected) => break,
                        }
                    }
                    Job::Forget(instance) => {
                        self.write(&mut batch);
                        self.forget(&instance);
                    }
                    Job::MarkIncomplete(instance) => {
                        self.write(&mut batch);
                        self.mark_incomplete(&instance);
                    }
                    Job::Barrier(sender) => {
                        self.write(&mut batch);
                        self.prune_oversized();
                        let _ = sender.send(());
                    }
                }
            }

            self.write(&mut batch);
            self.prune_oversized();
        }
    }

    /// Write everything still in the queue after the senders were dropped.
    fn drain(&mut self, receiver: &Receiver<Job>) {
        let mut batch: Vec<Pending> = Vec::new();
        while let Ok(job) = receiver.try_recv() {
            match job {
                Job::Record(pending) => {
                    batch.push(pending);
                    if batch.len() >= self.limits.batch_events {
                        self.write(&mut batch);
                    }
                }
                Job::Forget(instance) => {
                    self.write(&mut batch);
                    self.forget(&instance);
                }
                Job::MarkIncomplete(instance) => {
                    self.write(&mut batch);
                    self.mark_incomplete(&instance);
                }
                Job::Barrier(sender) => {
                    self.write(&mut batch);
                    self.prune_oversized();
                    let _ = sender.send(());
                }
            }
        }
        self.write(&mut batch);
        self.prune_oversized();
    }

    /// Wait while a test has the writer paused. Normally this returns at once.
    ///
    /// The wait is bounded per iteration so a test that drops the recorder
    /// without resuming cannot leave the writer blocked past shutdown.
    fn wait_when_paused(&self) {
        let (lock, condvar) = &*self.paused;
        let mut paused = lock.lock().expect("pause");
        while *paused {
            if self.inner.closing.load(Ordering::Relaxed) {
                return;
            }
            let (next, _) = condvar
                .wait_timeout(paused, Duration::from_millis(2))
                .expect("pause wait");
            paused = next;
        }
    }

    /// Write one batch of events in a single transaction.
    fn write(&mut self, batch: &mut Vec<Pending>) {
        if batch.is_empty() {
            return;
        }
        // One transaction must carry each instance's events in increasing seq
        // order (`append_batch_at` enforces that), so sort the batch. Events the
        // relay handed over after a higher number for the same instance can no
        // longer be inserted without breaking the invariant; the relay records in
        // seq order, so this only happens if a caller breaks that contract.
        batch.sort_by(|left, right| {
            left.instance
                .cmp(&right.instance)
                .then_with(|| left.seq.cmp(&right.seq))
        });
        let mut late: Vec<String> = Vec::new();
        batch.retain(|pending| {
            let highest = self.written.get(&pending.instance).copied().unwrap_or(0);
            if pending.seq <= highest {
                if !late.contains(&pending.instance) {
                    late.push(pending.instance.clone());
                }
                false
            } else {
                true
            }
        });
        for instance in &late {
            self.report_failure(
                instance,
                &anyhow::anyhow!(
                    "an event arrived after a higher seq for the same instance; \
                     events must be recorded in seq order"
                ),
            );
        }
        if batch.is_empty() {
            return;
        }

        let mut instances: Vec<String> = batch.iter().map(|p| p.instance.clone()).collect();
        instances.sort_unstable();
        instances.dedup();

        if self.inject_failure() {
            let instances_all: Vec<String> = batch.iter().map(|p| p.instance.clone()).collect();
            let queued: usize = batch.iter().map(|p| p.event.message.len()).sum();
            batch.clear();
            self.inner.queued_bytes.fetch_sub(queued, Ordering::Relaxed);
            for instance in instances_all {
                self.report_failure(
                    &instance,
                    &anyhow::anyhow!("injected write failure (test hook)"),
                );
            }
            return;
        }

        let written: Vec<(String, u64)> = batch
            .iter()
            .map(|pending| (pending.instance.clone(), pending.seq))
            .collect();
        let events: Vec<(u64, NewEvent)> = batch
            .drain(..)
            .map(|pending| (pending.seq, pending.event))
            .collect();
        let queued: usize = events.iter().map(|(_, event)| event.message.len()).sum();

        match self.store.append_batch_at(events) {
            Ok(()) => {
                self.inner.queued_bytes.fetch_sub(queued, Ordering::Relaxed);
                // Remember the new high-water mark for each instance.
                for pending in &written {
                    let entry = self.written.entry(pending.0.clone()).or_insert(0);
                    *entry = (*entry).max(pending.1);
                }
                // `bytes` was already credited in `record`, so a successful write only
                // has to leave it alone; pruning is what recomputes it.
            }
            Err(error) => {
                // The batch was rolled back, so its bytes are no longer queued.
                self.inner.queued_bytes.fetch_sub(queued, Ordering::Relaxed);
                // Every instance in the batch now has a hole in its log.
                for instance in &instances {
                    self.report_failure(instance, &error);
                }
            }
        }
    }

    /// Consume one injected failure, if any (see [`Recorder::with_failing_writes`]).
    fn inject_failure(&self) -> bool {
        let remaining = self.inner.fail_batches.load(Ordering::Relaxed);
        if remaining == 0 {
            return false;
        }
        self.inner
            .fail_batches
            .store(remaining - 1, Ordering::Relaxed);
        true
    }

    fn forget(&mut self, instance: &str) {
        if let Err(error) = self.store.forget_instance(instance) {
            self.report_failure(instance, &error);
        }
        self.written.remove(instance);
        // `bytes` is cleared by the caller, in call order with the `record`s
        // around it; clearing it here as well would also discard events recorded
        // after the forget.
    }

    fn mark_incomplete(&mut self, instance: &str) {
        if let Err(error) = self.store.mark_instance_incomplete(instance) {
            self.report_failure(instance, &error);
        }
    }

    /// Re-read one instance's stored size from the database (after a prune).
    fn recount(&mut self, instance: &str) {
        match self.store.instance_bytes(instance) {
            Ok(bytes) => {
                self.inner
                    .bytes
                    .lock()
                    .expect("bytes lock")
                    .insert(instance.to_string(), bytes);
            }
            Err(error) => self.report_failure(instance, &error),
        }
    }

    /// Prune instances that grew past the cap, down to 90 % of it.
    fn prune_oversized(&mut self) {
        let cap = self.max_bytes_per_instance;
        if cap == 0 {
            return;
        }
        let target = cap / PRUNE_SCALE * PRUNE_KEEP;
        let oversized = {
            let bytes = self.inner.bytes.lock().expect("bytes lock");
            bytes
                .iter()
                .filter(|(_, size)| **size > cap)
                .map(|(instance, _)| instance.clone())
                .collect::<Vec<_>>()
        };
        for instance in oversized {
            match self.store.prune(&instance, target) {
                Ok(_) => self.recount(&instance),
                Err(error) => self.report_failure(&instance, &error),
            }
        }
    }

    /// Print one warning line per rate-limit window, and make sure the instance
    /// can never be replayed.
    fn report_failure(&mut self, instance: &str, error: &anyhow::Error) {
        let now = Instant::now();
        let recent = self
            .last_warning
            .is_some_and(|last| now.duration_since(last) < self.limits.warning_interval);
        if !recent {
            self.last_warning = Some(now);
            self.inner.warnings.fetch_add(1, Ordering::Relaxed);
            eprintln!("nvim_ade_server: warning: event log write failed for {instance}: {error:#}");
        }
        // Whatever happened, the instance's log has a hole now. This call may
        // itself fail (the disk is still broken); the failure is what the
        // warning above reported, and the next batch retries.
        let _ = self.store.mark_instance_incomplete(instance);
    }
}

/// Delete the log and its WAL sidecars, if any, so a new service starts clean.
fn remove_log_files(path: &Path) -> Result<()> {
    use std::io::ErrorKind;
    for candidate in [
        path.to_path_buf(),
        sidecar(path, "-wal"),
        sidecar(path, "-shm"),
    ] {
        match std::fs::remove_file(&candidate) {
            Ok(()) => {}
            Err(error) if error.kind() == ErrorKind::NotFound => {}
            Err(error) => {
                return Err(error).with_context(|| {
                    format!("removing a stale event log at {}", candidate.display())
                })
            }
        }
    }
    Ok(())
}

fn sidecar(path: &Path, suffix: &str) -> std::path::PathBuf {
    let mut name = path.as_os_str().to_owned();
    name.push(suffix);
    std::path::PathBuf::from(name)
}
