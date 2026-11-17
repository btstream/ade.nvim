//! Durable event log for the ACP observation layer, backed by SQLite.
//!
//! Every message an agent writes is appended here with a **per-instance**
//! sequence number (`seq`, starting at 1) and the raw JSON text. The log is
//! what lets a reconnecting front end replay what it missed (see
//! `service/PROTOCOL.md` §3.7) without asking the agent again.
//!
//! # Design notes
//!
//! - **Per-instance `seq`.** Each instance (an agent process identity, see
//!   `instance_key`) has its own counter. The counter is stored next to the
//!   instance so it survives restarts and pruning: deleting old events never
//!   rewinds it, and no sequence number is reused. Instances are independent,
//!   so different agents do not contend for one global counter.
//! - **Messages are opaque.** `message` is stored exactly as received and read
//!   back byte for byte: it is never parsed, reformatted, or re-serialized.
//!   Unicode, escapes and embedded NULs survive unchanged.
//! - **Retention.** [`Store::prune`] deletes the oldest events of one instance
//!   until the remaining payload fits the byte budget. Any session that lost
//!   an event is marked *incomplete*: its log can no longer replay the whole
//!   conversation, so [`Store::session_complete`] reports `false` and the
//!   caller must fall back to the agent's own `session/load`.
//! - **Robustness.** A file that is not a SQLite database, is truncated, or
//!   carries an unknown `user_version` is renamed to
//!   `<path>.corrupt-<unix-seconds>` (with a warning on stderr) and a fresh
//!   database is created. Permission and disk errors are reported as errors;
//!   nothing panics.
//!
//! # Blocking
//!
//! Every method blocks on a `Mutex<Connection>` and on file I/O. The type is
//! `Send + Sync`, so it can live in an `Arc`, but **async code must call it
//! from `tokio::task::spawn_blocking`** rather than from a reactor task.
//!
//! # Example
//!
//! ```no_run
//! use nvim_ade_server::store::{EventKind, NewEvent, Query, Store};
//!
//! # fn main() -> anyhow::Result<()> {
//! let store = Store::open(std::path::Path::new("/tmp/nvim_ade_server.sqlite3"))?;
//! let seq = store.append(NewEvent {
//!     instance_key: "agent:opencode:/project".to_string(),
//!     session_id: Some("ses_1".to_string()),
//!     kind: EventKind::AgentNotification,
//!     message: r#"{"jsonrpc":"2.0","method":"session/update"}"#.to_string(),
//!     ts_ms: 1_700_000_000_000,
//! })?;
//! assert_eq!(seq, 1);
//! let events = store.read(&Query::new("agent:opencode:/project"))?;
//! assert_eq!(events.len(), 1);
//! # Ok(())
//! # }
//! ```

use std::fs::{self, OpenOptions};
use std::io::ErrorKind;
use std::path::{Path, PathBuf};
use std::sync::{Mutex, MutexGuard};
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use anyhow::{bail, Context, Result};
use rusqlite::types::Value;
use rusqlite::{params, Connection, ErrorCode, OptionalExtension, TransactionBehavior};

/// Schema version stored in SQLite's `user_version`.
///
/// A file with any other non-zero value is treated as incompatible and moved
/// aside; a zero-length file (version 0) is initialised in place.
///
/// - 1: the S4a event log.
/// - 2: the team tables (18.15).
/// - 3: boards, card history and named workflows (19.11).
pub const SCHEMA_VERSION: i64 = 3;

/// How long a writer waits for another process holding the database lock.
const BUSY_TIMEOUT: Duration = Duration::from_secs(5);

/// What a stored event is.
///
/// The numeric value is what goes into the `kind` column; it must stay stable.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum EventKind {
    /// An ACP notification written by the agent (e.g. `session/update`).
    AgentNotification,
    /// An ACP response written by the agent.
    AgentResponse,
    /// An ACP request written by the agent (e.g. a permission request).
    AgentRequest,
    /// A request the front end sent to the agent.
    FrontendRequest,
    /// A locally generated record, e.g. the prompt the front end sent.
    ///
    /// Hidden from [`Store::read`] unless `include_synthetic` is set.
    Synthetic,
}

impl EventKind {
    /// Every kind, in numeric order.
    pub const ALL: [EventKind; 5] = [
        EventKind::AgentNotification,
        EventKind::AgentResponse,
        EventKind::AgentRequest,
        EventKind::FrontendRequest,
        EventKind::Synthetic,
    ];

    /// The stable value stored in the database.
    pub fn as_i64(self) -> i64 {
        match self {
            EventKind::AgentNotification => 1,
            EventKind::AgentResponse => 2,
            EventKind::AgentRequest => 3,
            EventKind::FrontendRequest => 4,
            EventKind::Synthetic => 5,
        }
    }

    /// Parse a stored value. Values that were never written are rejected rather
    /// than guessed, so a newer writer cannot silently be misread.
    pub fn from_i64(value: i64) -> Result<Self> {
        match value {
            1 => Ok(EventKind::AgentNotification),
            2 => Ok(EventKind::AgentResponse),
            3 => Ok(EventKind::AgentRequest),
            4 => Ok(EventKind::FrontendRequest),
            5 => Ok(EventKind::Synthetic),
            other => bail!("unknown event kind {other} in the event store"),
        }
    }
}

/// An event about to be appended.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct NewEvent {
    /// Instance identity; stable across service restarts.
    pub instance_key: String,
    /// The ACP session the event belongs to, when it has one.
    pub session_id: Option<String>,
    /// What the event is.
    pub kind: EventKind,
    /// Raw JSON text, stored verbatim.
    pub message: String,
    /// Unix epoch milliseconds chosen by the caller (not by the store).
    pub ts_ms: i64,
}

/// An event read back from the store.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Event {
    /// Per-instance sequence number, starting at 1.
    pub seq: u64,
    pub instance_key: String,
    pub session_id: Option<String>,
    pub kind: EventKind,
    /// The raw JSON text, exactly as it was appended.
    pub message: String,
    pub ts_ms: i64,
}

/// Filter for [`Store::read`].
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Query {
    pub instance_key: String,
    /// Only events of this session. `None` means every session.
    pub session_id: Option<String>,
    /// Only events with `seq` greater than this (0 = from the beginning).
    pub after_seq: u64,
    /// At most this many events; `None` = no limit, `Some(0)` = none.
    pub limit: Option<usize>,
    /// Include [`EventKind::Synthetic`] events.
    pub include_synthetic: bool,
}

impl Query {
    /// All events of one instance, from the beginning.
    pub fn new(instance_key: &str) -> Self {
        Self {
            instance_key: instance_key.to_string(),
            session_id: None,
            after_seq: 0,
            limit: None,
            include_synthetic: false,
        }
    }
}

/// What [`Store::prune`] did.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub struct PruneReport {
    /// Number of events deleted.
    pub removed_events: u64,
    /// Sum of the deleted messages' UTF-8 sizes, in bytes.
    pub removed_bytes: u64,
    /// Sessions that became incomplete because of this call (a session that was
    /// already incomplete is not counted again).
    pub sessions_marked_incomplete: u64,
}

/// Summary of one known instance, returned by [`Store::instances`].
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct InstanceInfo {
    pub instance_key: String,
    /// Events currently stored for the instance.
    pub events: u64,
    /// Total UTF-8 size of the stored messages, in bytes.
    pub bytes: u64,
    /// Highest `seq` ever issued to the instance (0 when nothing is stored).
    pub last_seq: u64,
}

/// A stored board and its card history (PROTOCOL.md 19.11).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct StoredBoard {
    pub rev: u64,
    pub json: String,
    /// `(card_id, old card JSON, rev)`, newest first.
    pub history: Vec<(String, String, i64)>,
}

/// SQLite-backed event log.
///
/// Cheap to share: all access goes through one connection guarded by a mutex,
/// so the type is `Send + Sync`. Calls block; see the module docs.
pub struct Store {
    conn: Mutex<Connection>,
    path: Option<PathBuf>,
}

impl Store {
    /// Open (or create) the event log at `path`.
    ///
    /// Creates the parent directory with permission 0700 and the file with
    /// 0600, enables WAL, and creates the schema when the file is new.
    ///
    /// Corruption (not a SQLite file, truncated file, unknown `user_version`)
    /// is recovered from by renaming the old file to
    /// `<path>.corrupt-<unix-seconds>` and creating a fresh database; the
    /// warning goes to stderr. A rename that itself fails is an error. Read-only
    /// media and full disks are reported as errors.
    pub fn open(path: &Path) -> Result<Self> {
        // `symlink_metadata` does not follow the link: a symlink at the store
        // path is refused instead of silently redirecting the database (and its
        // permissions) somewhere else, matching `token.rs`.
        match fs::symlink_metadata(path) {
            Ok(metadata) if metadata.file_type().is_symlink() => {
                bail!("store path {} is a symlink", path.display());
            }
            Ok(metadata) if !metadata.is_file() => {
                bail!("store path {} is not a regular file", path.display());
            }
            Ok(_) => {}
            Err(error) if error.kind() == ErrorKind::NotFound => {}
            Err(error) => {
                return Err(error)
                    .with_context(|| format!("reading metadata of {}", path.display()))
            }
        }
        if let Some(parent) = path.parent() {
            if !parent.as_os_str().is_empty() {
                create_private_dir(parent)?;
            }
        }
        create_private_file(path)?;

        let mut quarantined = false;
        loop {
            match Self::open_validated(path) {
                Ok(store) => return Ok(store),
                Err(failure) if !quarantined && failure.is_corruption() => {
                    quarantine(path, &failure.detail())?;
                    quarantined = true;
                    create_private_file(path)?;
                }
                Err(failure) => return Err(failure.error),
            }
        }
    }

    /// An empty in-memory store, for tests.
    pub fn open_in_memory() -> Result<Self> {
        let conn = Connection::open_in_memory().context("opening in-memory event store")?;
        configure(&conn).context("configuring in-memory event store")?;
        create_schema(&conn).context("creating the event store schema")?;
        Ok(Self {
            conn: Mutex::new(conn),
            path: None,
        })
    }

    /// Append one event and return its sequence number.
    pub fn append(&self, event: NewEvent) -> Result<u64> {
        let mut conn = self.lock()?;
        let tx = conn
            .transaction_with_behavior(TransactionBehavior::Immediate)
            .context("starting an append transaction")?;
        let seq = insert_event(&tx, &event).context("appending an event")?;
        tx.commit().context("committing an append")?;
        Ok(seq)
    }

    /// Append a batch in one transaction; returns the sequence numbers in input
    /// order.
    ///
    /// Either every event is stored or none is: a failure rolls the whole batch
    /// back.
    pub fn append_batch(&self, events: Vec<NewEvent>) -> Result<Vec<u64>> {
        if events.is_empty() {
            return Ok(Vec::new());
        }
        let mut conn = self.lock()?;
        let tx = conn
            .transaction_with_behavior(TransactionBehavior::Immediate)
            .context("starting an append transaction")?;
        let mut seqs = Vec::with_capacity(events.len());
        for event in &events {
            seqs.push(insert_event(&tx, event).context("appending an event batch")?);
        }
        tx.commit().context("committing an event batch")?;
        Ok(seqs)
    }

    /// Append one event with a sequence number chosen by the caller.
    ///
    /// The relay is the authority for `seq`: it shares one counter per instance
    /// between the events it records and those it does not, so the log holds a
    /// subset of the numbers and gaps are normal. The store only enforces that
    /// the numbers of one instance **strictly increase**: a `seq` at or below the
    /// highest already stored is rejected and nothing is written.
    ///
    /// `instances.next_seq` is updated to `max(seq) + 1`, so a later
    /// [`Store::append`] (which allocates its own number) continues after it.
    pub fn append_at(&self, seq: u64, event: NewEvent) -> Result<()> {
        self.append_batch_at(vec![(seq, event)])
    }

    /// A batch of caller-numbered events in one transaction.
    ///
    /// Either every event is stored or none is: a stale `seq` anywhere rolls the
    /// whole batch back, including events for other instances. The numbers must
    /// increase per instance in the order given.
    pub fn append_batch_at(&self, events: Vec<(u64, NewEvent)>) -> Result<()> {
        if events.is_empty() {
            return Ok(());
        }
        let mut conn = self.lock()?;
        let tx = conn
            .transaction_with_behavior(TransactionBehavior::Immediate)
            .context("starting an append transaction")?;
        for (seq, event) in &events {
            insert_event_at(&tx, *seq, event).context("appending an event")?;
        }
        tx.commit().context("committing an event batch")?;
        Ok(())
    }

    /// Mark every session of one instance incomplete.
    ///
    /// Used when the log lost events without pruning them (a dropped event under
    /// back pressure, or a failed write): the sessions are still known but their
    /// history has a hole, so they must not be replayed. Unknown instances and
    /// repeated calls are not errors.
    pub fn mark_instance_incomplete(&self, instance_key: &str) -> Result<()> {
        let mut conn = self.lock()?;
        let Some(instance_id) = find_instance(&conn, instance_key)? else {
            return Ok(());
        };
        let tx = conn
            .transaction_with_behavior(TransactionBehavior::Immediate)
            .context("starting a mark transaction")?;
        tx.execute(
            "UPDATE sessions SET incomplete = 1 WHERE instance_id = ?1",
            params![instance_id],
        )
        .context("marking the sessions incomplete")?;
        tx.commit().context("committing a mark")?;
        Ok(())
    }

    /// Total payload size of one instance's stored messages, in bytes.
    pub fn instance_bytes(&self, instance_key: &str) -> Result<u64> {
        let conn = self.lock()?;
        let Some(instance_id) = find_instance(&conn, instance_key)? else {
            return Ok(0);
        };
        let bytes: i64 = conn
            .query_row(
                "SELECT COALESCE(SUM(length(CAST(message AS BLOB))), 0) \
                 FROM events WHERE instance_id = ?1",
                params![instance_id],
                |row| row.get(0),
            )
            .context("measuring the stored events")?;
        from_i64(bytes, "stored bytes")
    }

    /// Every event of one session with `seq <= up_to_seq`, oldest first.
    ///
    /// Synthetic events are included: a replay needs the prompts the front end
    /// sent, not only what the agent said. A session-less event never matches.
    pub fn read_session_upto(
        &self,
        instance_key: &str,
        session_id: &str,
        up_to_seq: u64,
    ) -> Result<Vec<Event>> {
        let conn = self.lock()?;
        let Some(instance_id) = find_instance(&conn, instance_key)? else {
            return Ok(Vec::new());
        };
        // `u64::MAX` (and anything above i64::MAX) means "no upper bound"; SQLite
        // stores seq as an i64, so clamping is exact rather than lossy.
        let up_to_seq = i64::try_from(up_to_seq).unwrap_or(i64::MAX);
        let mut statement = conn
            .prepare_cached(
                "SELECT seq, kind, message, ts_ms FROM events \
                 WHERE instance_id = ?1 AND session_id = ?2 AND seq <= ?3 \
                 ORDER BY seq ASC",
            )
            .context("preparing a session read")?;
        let mut rows = statement
            .query(params![instance_id, session_id, up_to_seq])
            .context("reading the session")?;
        let mut events = Vec::new();
        while let Some(row) = rows.next().context("reading a session row")? {
            let seq: i64 = row.get(0).context("reading seq")?;
            events.push(Event {
                seq: from_i64(seq, "seq")?,
                instance_key: instance_key.to_string(),
                session_id: Some(session_id.to_string()),
                kind: EventKind::from_i64(row.get(1).context("reading kind")?)?,
                message: row.get(2).context("reading message")?,
                ts_ms: row.get(3).context("reading ts_ms")?,
            });
        }
        Ok(events)
    }

    /// Read events of one instance, oldest first.
    pub fn read(&self, query: &Query) -> Result<Vec<Event>> {
        let conn = self.lock()?;
        let Some(instance_id) = find_instance(&conn, &query.instance_key)? else {
            return Ok(Vec::new());
        };
        let after_seq = to_i64(query.after_seq, "after_seq")?;
        let limit = match query.limit {
            // SQLite treats a negative LIMIT as "no limit".
            None => -1i64,
            Some(limit) => to_i64(limit as u64, "limit")?,
        };

        // Placeholders are appended together with their value so the two can
        // never drift apart.
        let mut sql = String::from(
            "SELECT seq, session_id, kind, message, ts_ms \
             FROM events WHERE instance_id = ? AND seq > ?",
        );
        let mut values = vec![Value::Integer(instance_id), Value::Integer(after_seq)];
        if let Some(session_id) = &query.session_id {
            sql.push_str(" AND session_id = ?");
            values.push(Value::Text(session_id.clone()));
        }
        if !query.include_synthetic {
            sql.push_str(" AND kind <> ?");
            values.push(Value::Integer(EventKind::Synthetic.as_i64()));
        }
        sql.push_str(" ORDER BY seq ASC LIMIT ?");
        values.push(Value::Integer(limit));

        let mut statement = conn.prepare(&sql).context("preparing a read")?;
        let mut rows = statement
            .query(rusqlite::params_from_iter(values.iter()))
            .context("reading events")?;

        let mut events = Vec::new();
        while let Some(row) = rows.next().context("reading an event row")? {
            let seq: i64 = row.get(0).context("reading seq")?;
            events.push(Event {
                seq: from_i64(seq, "seq")?,
                instance_key: query.instance_key.clone(),
                session_id: row.get(1).context("reading session_id")?,
                kind: EventKind::from_i64(row.get(2).context("reading kind")?)?,
                message: row.get(3).context("reading message")?,
                ts_ms: row.get(4).context("reading ts_ms")?,
            });
        }
        Ok(events)
    }

    /// Highest sequence number issued to `instance_key`, or 0 if it has none.
    ///
    /// The counter is not rewound by pruning, so this is also the number of the
    /// next event minus one.
    pub fn last_seq(&self, instance_key: &str) -> Result<u64> {
        let conn = self.lock()?;
        let next: Option<i64> = conn
            .query_row(
                "SELECT next_seq FROM instances WHERE instance_key = ?1",
                params![instance_key],
                |row| row.get(0),
            )
            .optional()
            .context("reading the last sequence number")?;
        match next {
            // `next_seq` is always at least 1, so `next_seq - 1` is the last
            // issued number.
            Some(next) => Ok(from_i64(next - 1, "seq")?),
            None => Ok(0),
        }
    }

    /// Delete the oldest events of `instance_key` until the remaining payload
    /// fits in `max_bytes`, and mark the affected sessions incomplete.
    ///
    /// Payload size is the sum of the stored messages' UTF-8 lengths. Sequence
    /// numbers of the surviving events do not change. A session that loses any
    /// event can no longer be replayed from the log.
    pub fn prune(&self, instance_key: &str, max_bytes: u64) -> Result<PruneReport> {
        let mut conn = self.lock()?;
        let Some(instance_id) = find_instance(&conn, instance_key)? else {
            return Ok(PruneReport::default());
        };

        let tx = conn
            .transaction_with_behavior(TransactionBehavior::Immediate)
            .context("starting a prune transaction")?;

        let total_bytes: i64 = tx
            .query_row(
                "SELECT COALESCE(SUM(length(CAST(message AS BLOB))), 0) \
                 FROM events WHERE instance_id = ?1",
                params![instance_id],
                |row| row.get(0),
            )
            .context("measuring the stored events")?;
        let total_bytes = from_i64(total_bytes, "stored bytes")?;
        // A negative budget was already rejected by the cast to i64 above, so
        // `max_bytes` is the limit.
        if total_bytes <= max_bytes {
            tx.commit().context("committing an empty prune")?;
            return Ok(PruneReport::default());
        }

        // Walk from the oldest event and stop as soon as the rest fits, so the
        // scan never materialises the whole instance.
        let mut report = PruneReport::default();
        let mut remaining = total_bytes;
        let mut last_removed_seq: Option<i64> = None;
        let mut sessions: Vec<String> = Vec::new();
        {
            let mut statement = tx
                .prepare(
                    "SELECT seq, session_id, length(CAST(message AS BLOB)) \
                     FROM events WHERE instance_id = ?1 ORDER BY seq ASC",
                )
                .context("preparing a prune scan")?;
            let mut rows = statement
                .query(params![instance_id])
                .context("scanning events")?;
            while remaining > max_bytes {
                let Some(row) = rows.next().context("scanning an event row")? else {
                    break;
                };
                let seq: i64 = row.get(0).context("reading seq")?;
                let session_id: Option<String> = row.get(1).context("reading session_id")?;
                let bytes = from_i64(row.get(2).context("reading message size")?, "message size")?;
                remaining -= bytes;
                report.removed_events += 1;
                report.removed_bytes += bytes;
                last_removed_seq = Some(seq);
                if let Some(session_id) = session_id {
                    if !sessions.contains(&session_id) {
                        sessions.push(session_id);
                    }
                }
            }
        }
        if let Some(last_removed) = last_removed_seq {
            // Removed events are a contiguous prefix, so one range delete
            // covers all of them.
            tx.execute(
                "DELETE FROM events WHERE instance_id = ?1 AND seq <= ?2",
                params![instance_id, last_removed],
            )
            .context("deleting pruned events")?;
        }
        for session_id in &sessions {
            let marking = tx
                .execute(
                    "INSERT INTO sessions (instance_id, session_id, incomplete) VALUES (?1, ?2, 1) \
                     ON CONFLICT (instance_id, session_id) DO UPDATE SET incomplete = 1 \
                     WHERE sessions.incomplete = 0",
                    params![instance_id, session_id],
                )
                .context("marking a session incomplete")?;
            report.sessions_marked_incomplete += marking as u64;
        }
        tx.commit().context("committing a prune")?;
        Ok(report)
    }

    /// Whether the log for `session_id` is a complete history that can be
    /// replayed.
    ///
    /// `false` when the session has no logged events at all (nothing to replay)
    /// or when [`Store::prune`] removed any of them.
    pub fn session_complete(&self, instance_key: &str, session_id: &str) -> Result<bool> {
        let conn = self.lock()?;
        let Some(instance_id) = find_instance(&conn, instance_key)? else {
            return Ok(false);
        };
        let incomplete: Option<i64> = conn
            .query_row(
                "SELECT incomplete FROM sessions WHERE instance_id = ?1 AND session_id = ?2",
                params![instance_id, session_id],
                |row| row.get(0),
            )
            .optional()
            .context("reading the session state")?;
        Ok(incomplete == Some(0))
    }

    /// Known instances with their event count, payload size and last sequence
    /// number, sorted by `instance_key`.
    pub fn instances(&self) -> Result<Vec<InstanceInfo>> {
        let conn = self.lock()?;
        let mut statement = conn
            .prepare(
                "SELECT i.instance_key, i.next_seq - 1, COUNT(e.seq), \
                        COALESCE(SUM(length(CAST(e.message AS BLOB))), 0) \
                 FROM instances i LEFT JOIN events e ON e.instance_id = i.id \
                 GROUP BY i.id ORDER BY i.instance_key ASC",
            )
            .context("preparing the instance listing")?;
        let mut rows = statement.query([]).context("listing instances")?;
        let mut instances = Vec::new();
        while let Some(row) = rows.next().context("reading an instance row")? {
            let last_seq: i64 = row.get(1).context("reading the last seq")?;
            let events: i64 = row.get(2).context("reading the event count")?;
            let bytes: i64 = row.get(3).context("reading the byte count")?;
            instances.push(InstanceInfo {
                instance_key: row.get(0).context("reading instance_key")?,
                events: from_i64(events, "event count")?,
                bytes: from_i64(bytes, "byte count")?,
                last_seq: from_i64(last_seq, "last seq")?,
            });
        }
        Ok(instances)
    }

    /// Remove every event, session state and counter of one instance.
    ///
    /// Forgetting an unknown instance is not an error.
    pub fn forget_instance(&self, instance_key: &str) -> Result<()> {
        let mut conn = self.lock()?;
        let tx = conn
            .transaction_with_behavior(TransactionBehavior::Immediate)
            .context("starting a forget transaction")?;
        let Some(instance_id) = find_instance(&tx, instance_key)? else {
            tx.commit().context("committing an empty forget")?;
            return Ok(());
        };
        tx.execute(
            "DELETE FROM events WHERE instance_id = ?1",
            params![instance_id],
        )
        .context("deleting events")?;
        tx.execute(
            "DELETE FROM sessions WHERE instance_id = ?1",
            params![instance_id],
        )
        .context("deleting sessions")?;
        tx.execute("DELETE FROM instances WHERE id = ?1", params![instance_id])
            .context("deleting the instance")?;
        tx.commit().context("committing a forget")?;
        Ok(())
    }

    // -- teams (PROTOCOL.md 18.15) ----------------------------------------

    /// Save one team snapshot. The row and the id counters are one
    /// transaction, so a crash cannot leave a team row without its id history.
    pub fn save_team(
        &self,
        id: &str,
        state_json: &str,
        max_team: u64,
        max_inbox: u64,
    ) -> Result<()> {
        let mut conn = self.lock()?;
        let tx = conn
            .transaction_with_behavior(TransactionBehavior::Immediate)
            .context("starting a team transaction")?;
        tx.prepare_cached("INSERT INTO teams (id, state_json) VALUES (?1, ?2) ON CONFLICT(id) DO UPDATE SET state_json = excluded.state_json")
            .context("preparing the team upsert")?
            .execute(params![id, state_json])
            .context("writing a team")?;
        for (key, value) in [("max_team", max_team), ("max_inbox", max_inbox)] {
            tx.prepare_cached("INSERT INTO team_meta (key, value) VALUES (?1, ?2) ON CONFLICT(key) DO UPDATE SET value = excluded.value")
                .context("preparing the team meta upsert")?
                .execute(params![key, value.to_string()])
                .context("writing team meta")?;
        }
        tx.commit().context("committing a team")?;
        Ok(())
    }

    pub fn delete_team(&self, id: &str) -> Result<()> {
        let mut conn = self.lock()?;
        let tx = conn
            .transaction_with_behavior(TransactionBehavior::Immediate)
            .context("starting a team delete")?;
        tx.execute("DELETE FROM teams WHERE id = ?1", params![id])
            .context("deleting a team")?;
        // The board and its history live with the team (19.11).
        tx.execute("DELETE FROM boards WHERE team_id = ?1", params![id])
            .context("deleting a board")?;
        tx.execute("DELETE FROM card_history WHERE team_id = ?1", params![id])
            .context("deleting card history")?;
        tx.commit().context("committing a team delete")?;
        Ok(())
    }

    /// Persist one board and the history changes caused by this write, in one
    /// transaction. `history` entries are `(card_id, old card JSON, old board
    /// rev, ts_ms)`; `cleared` cards lose all their history (archived or
    /// removed).
    pub fn save_board(
        &self,
        team_id: &str,
        rev: u64,
        json: &str,
        history: &[(String, String, i64, i64)],
        cleared: &[String],
    ) -> Result<()> {
        let mut conn = self.lock()?;
        let tx = conn
            .transaction_with_behavior(TransactionBehavior::Immediate)
            .context("starting a board transaction")?;
        tx.prepare_cached(
            "INSERT INTO boards (team_id, rev, json) VALUES (?1, ?2, ?3)
             ON CONFLICT(team_id) DO UPDATE SET rev = excluded.rev, json = excluded.json",
        )
        .context("preparing the board upsert")?
        .execute(params![team_id, to_i64(rev, "board rev")?, json])
        .context("writing a board")?;
        for card in cleared {
            tx.prepare_cached("DELETE FROM card_history WHERE team_id = ?1 AND card_id = ?2")
                .context("preparing a card history delete")?
                .execute(params![team_id, card])
                .context("clearing card history")?;
        }
        for (card, card_json, board_rev, ts_ms) in history {
            tx.prepare_cached(
                "INSERT OR REPLACE INTO card_history (team_id, card_id, rev, json, ts_ms)
                 VALUES (?1, ?2, ?3, ?4, ?5)",
            )
            .context("preparing a card history insert")?
            .execute(params![team_id, card, board_rev, card_json, ts_ms])
            .context("writing card history")?;
            // Keep the 20 newest versions of each card in the same transaction.
            tx.prepare_cached(
                "DELETE FROM card_history
                 WHERE team_id = ?1 AND card_id = ?2 AND rev NOT IN (
                     SELECT rev FROM card_history
                     WHERE team_id = ?1 AND card_id = ?2
                     ORDER BY rev DESC LIMIT 20
                 )",
            )
            .context("preparing a card history prune")?
            .execute(params![team_id, card])
            .context("pruning card history")?;
        }
        tx.commit().context("committing a board")?;
        Ok(())
    }

    /// Read a stored board and its history rows, newest first.
    pub fn load_board(&self, id: &str) -> Result<Option<StoredBoard>> {
        let conn = self.lock()?;
        let board: Option<(i64, String)> = conn
            .query_row(
                "SELECT rev, json FROM boards WHERE team_id = ?1",
                params![id],
                |row| Ok((row.get(0)?, row.get(1)?)),
            )
            .optional()
            .context("reading a board")?;
        let Some((rev, json)) = board else {
            return Ok(None);
        };
        let mut statement = conn
            .prepare(
                "SELECT card_id, json, rev FROM card_history
                 WHERE team_id = ?1 ORDER BY rev DESC",
            )
            .context("preparing a card history load")?;
        let rows = statement
            .query_map(params![id], |row| {
                Ok((row.get(0)?, row.get(1)?, row.get(2)?))
            })
            .context("reading card history")?
            .collect::<std::result::Result<Vec<_>, _>>()
            .context("collecting card history")?;
        Ok(Some(StoredBoard {
            rev: from_i64(rev, "board rev")?,
            json,
            history: rows,
        }))
    }

    pub fn load_teams(&self) -> Result<Vec<(String, String)>> {
        let conn = self.lock()?;
        let mut statement = conn
            .prepare("SELECT id, state_json FROM teams ORDER BY id")
            .context("preparing the team load")?;
        let rows = statement
            .query_map([], |row| Ok((row.get(0)?, row.get(1)?)))
            .context("reading teams")?;
        rows.collect::<std::result::Result<Vec<_>, _>>()
            .context("collecting teams")
    }

    pub fn load_team_meta(&self, key: &str) -> Result<Option<String>> {
        let conn = self.lock()?;
        conn.query_row(
            "SELECT value FROM team_meta WHERE key = ?1",
            params![key],
            |row| row.get(0),
        )
        .optional()
        .context("reading team meta")
    }

    // -- workflows (PROTOCOL.md 19.11) -------------------------------------

    /// Store one named workflow; `project` is `""` for the user scope.
    pub fn save_workflow(
        &self,
        scope: &str,
        project: &str,
        name: &str,
        json: &str,
        updated_ms: u64,
    ) -> Result<()> {
        let updated_ms = to_i64(updated_ms, "updated_ms")?;
        let conn = self.lock()?;
        conn.prepare_cached(
            "INSERT INTO workflows (scope, project, name, json, updated_ms) \
             VALUES (?1, ?2, ?3, ?4, ?5) \
             ON CONFLICT (scope, project, name) DO UPDATE SET \
             json = excluded.json, updated_ms = excluded.updated_ms",
        )
        .context("preparing the workflow upsert")?
        .execute(params![scope, project, name, json, updated_ms])
        .context("writing a workflow")?;
        Ok(())
    }

    pub fn delete_workflow(&self, scope: &str, project: &str, name: &str) -> Result<()> {
        let conn = self.lock()?;
        conn.prepare_cached(
            "DELETE FROM workflows WHERE scope = ?1 AND project = ?2 AND name = ?3",
        )
        .context("preparing the workflow delete")?
        .execute(params![scope, project, name])
        .context("deleting a workflow")?;
        Ok(())
    }

    /// Every stored workflow as `(scope, project, name, json)`.
    pub fn load_workflows(&self) -> Result<Vec<(String, String, String, String)>> {
        let conn = self.lock()?;
        let mut statement = conn
            .prepare(
                "SELECT scope, project, name, json FROM workflows ORDER BY scope, project, name",
            )
            .context("preparing the workflow load")?;
        let rows = statement
            .query_map([], |row| {
                Ok((row.get(0)?, row.get(1)?, row.get(2)?, row.get(3)?))
            })
            .context("reading workflows")?;
        rows.collect::<std::result::Result<Vec<_>, _>>()
            .context("collecting workflows")
    }

    /// Forget every instance and event from the previous service run while
    /// keeping the team rows (section 10/18.15): a new service has no agents,
    /// so old sessions can never be replayed, but teams must survive.
    pub fn clear_events_for_restart(&self) -> Result<()> {
        let mut conn = self.lock()?;
        let tx = conn
            .transaction_with_behavior(TransactionBehavior::Immediate)
            .context("starting the event log reset")?;
        tx.execute_batch("DELETE FROM events; DELETE FROM sessions; DELETE FROM instances;")
            .context("clearing the previous event log")?;
        tx.commit().context("committing the event log reset")?;
        Ok(())
    }

    /// Path of the database file; `None` for an in-memory store.
    pub fn path(&self) -> Option<&Path> {
        self.path.as_deref()
    }

    fn lock(&self) -> Result<MutexGuard<'_, Connection>> {
        self.conn
            .lock()
            .map_err(|_| anyhow::anyhow!("event store mutex is poisoned"))
    }

    /// Open, configure and validate, classifying failures as corruption or not.
    fn open_validated(path: &Path) -> std::result::Result<Self, Failure> {
        let conn = Connection::open(path)
            .context("opening the event store")
            .map_err(Failure::other)?;
        configure(&conn).map_err(Failure::classify)?;

        let version: i64 = conn
            .query_row("PRAGMA user_version", [], |row| row.get(0))
            .context("reading the event store schema version")
            .map_err(Failure::classify)?;
        // Version 1 is the S4a event log; version 2 adds the team tables. Both
        // migrate in place, and existing events are kept.
        if version != 0 && !(1..=SCHEMA_VERSION).contains(&version) {
            return Err(Failure::corrupt(format!(
                "event store schema version {version} is not supported (expected {SCHEMA_VERSION})"
            )));
        }

        // Schema creation can also be the first statement that touches damaged
        // pages, so it is classified too: only SQLite's corruption codes are
        // treated as corruption, never a permission or I/O error.
        create_schema(&conn).map_err(Failure::classify)?;
        if version < SCHEMA_VERSION {
            conn.pragma_update(None, "user_version", SCHEMA_VERSION)
                .context("recording the event store schema version")
                .map_err(Failure::other)?;
        }
        set_private_mode(path).map_err(Failure::other)?;
        Ok(Self {
            conn: Mutex::new(conn),
            path: Some(path.to_path_buf()),
        })
    }
}

impl std::fmt::Debug for Store {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter
            .debug_struct("Store")
            .field("path", &self.path)
            .finish_non_exhaustive()
    }
}

/// Open failure with enough context to decide whether to quarantine the file.
struct Failure {
    error: anyhow::Error,
    corruption: bool,
}

impl Failure {
    fn other(error: anyhow::Error) -> Self {
        Self {
            error,
            corruption: false,
        }
    }

    fn corrupt(detail: impl Into<String>) -> Self {
        Self {
            error: anyhow::anyhow!("{}", detail.into()),
            corruption: true,
        }
    }

    /// Classify a rusqlite error: "file is not a database" and malformed images
    /// mean the file must be replaced. Everything else (permissions, I/O, full
    /// disk) is a real error that must not destroy data.
    fn classify(error: anyhow::Error) -> Self {
        if is_corruption_error(&error) {
            Self {
                error,
                corruption: true,
            }
        } else {
            Self::other(error)
        }
    }

    fn is_corruption(&self) -> bool {
        self.corruption
    }

    fn detail(&self) -> String {
        format!("{:#}", self.error)
    }
}

fn is_corruption_error(error: &anyhow::Error) -> bool {
    let Some(rusqlite::Error::SqliteFailure(code, _)) = error
        .chain()
        .find_map(|cause| cause.downcast_ref::<rusqlite::Error>())
    else {
        return false;
    };
    matches!(
        code.code,
        ErrorCode::NotADatabase | ErrorCode::DatabaseCorrupt
    )
}

/// Create `dir` (and parents) with permission 0700.
///
/// An existing directory is left alone: its mode is the user's choice, and the
/// database file itself is 0600 regardless. Only a directory this function
/// creates is tightened, so pointing the store at an existing layout does not
/// silently change its permissions.
fn create_private_dir(dir: &Path) -> Result<()> {
    match fs::metadata(dir) {
        Ok(metadata) if metadata.is_dir() => return Ok(()),
        Ok(_) => bail!("store directory {} is not a directory", dir.display()),
        Err(error) if error.kind() == ErrorKind::NotFound => {}
        Err(error) => {
            return Err(error)
                .with_context(|| format!("reading metadata of store directory {}", dir.display()))
        }
    }
    fs::create_dir_all(dir)
        .with_context(|| format!("creating store directory {}", dir.display()))?;
    set_mode(dir, 0o700).with_context(|| format!("setting permissions on {}", dir.display()))?;
    Ok(())
}

/// Create the database file with permission 0600 if it does not exist.
///
/// Opening with `create_new` never follows a symlink planted at the path, and
/// the mode is applied atomically at creation, so the database (and the WAL
/// SQLite derives its mode from) is private from the start.
fn create_private_file(path: &Path) -> Result<()> {
    match OpenOptions::new()
        .read(true)
        .write(true)
        .create_new(true)
        .open(path)
    {
        Ok(file) => {
            set_mode(path, 0o600)
                .with_context(|| format!("setting permissions on {}", path.display()))?;
            drop(file);
            Ok(())
        }
        Err(error) if error.kind() == ErrorKind::AlreadyExists => {
            // An existing file keeps its mode; tighten it when it is looser
            // than 0600 (another user may have created it).
            set_private_mode(path)
        }
        Err(error) => {
            Err(error).with_context(|| format!("creating the event store {}", path.display()))
        }
    }
}

/// Set the database (and any existing WAL sidecar) to 0600.
///
/// The mode is only changed when it is not already 0600: on read-only media the
/// chmod would fail even though the file is perfectly usable, and a needless
/// error there would make the whole service refuse to start.
fn set_private_mode(path: &Path) -> Result<()> {
    tighten(path, 0o600)?;
    for suffix in ["-wal", "-shm"] {
        let sidecar = sidecar_path(path, suffix);
        if sidecar.exists() {
            tighten(&sidecar, 0o600)?;
        }
    }
    Ok(())
}

/// Set `mode` unless the file already has exactly that mode.
fn tighten(path: &Path, mode: u32) -> Result<()> {
    if current_mode(path)? == Some(mode) {
        return Ok(());
    }
    set_mode(path, mode)
}

#[cfg(unix)]
fn current_mode(path: &Path) -> Result<Option<u32>> {
    use std::os::unix::fs::PermissionsExt;
    match fs::metadata(path) {
        Ok(metadata) => Ok(Some(metadata.permissions().mode() & 0o777)),
        Err(error) if error.kind() == ErrorKind::NotFound => Ok(None),
        Err(error) => {
            Err(error).with_context(|| format!("reading permissions of {}", path.display()))
        }
    }
}

#[cfg(not(unix))]
fn current_mode(_path: &Path) -> Result<Option<u32>> {
    Ok(None)
}

fn sidecar_path(path: &Path, suffix: &str) -> PathBuf {
    let mut name = path.as_os_str().to_owned();
    name.push(suffix);
    PathBuf::from(name)
}

#[cfg(unix)]
fn set_mode(path: &Path, mode: u32) -> Result<()> {
    use std::os::unix::fs::PermissionsExt;
    fs::set_permissions(path, fs::Permissions::from_mode(mode))
        .with_context(|| format!("chmod {:o} {}", mode, path.display()))
}

#[cfg(not(unix))]
fn set_mode(_path: &Path, _mode: u32) -> Result<()> {
    // Windows has no unix permission bits; the store lives under the service's
    // user-private directory (%LOCALAPPDATA%\ade) and inherits its ACL.
    Ok(())
}

/// Apply the pragmas every connection needs.
fn configure(conn: &Connection) -> Result<()> {
    conn.busy_timeout(BUSY_TIMEOUT)
        .context("setting the SQLite busy timeout")?;
    // WAL is a persistent database property; the statement also validates that
    // the file really is a SQLite database.
    let _: String = conn
        .query_row("PRAGMA journal_mode = WAL", [], |row| row.get(0))
        .context("enabling WAL")?;
    conn.pragma_update(None, "synchronous", "NORMAL")
        .context("setting synchronous=NORMAL")?;
    Ok(())
}

/// Create the tables when they are missing (new file or empty file).
fn create_schema(conn: &Connection) -> Result<()> {
    conn.execute_batch(
        "CREATE TABLE IF NOT EXISTS instances (
             id           INTEGER PRIMARY KEY,
             instance_key TEXT    NOT NULL UNIQUE,
             next_seq     INTEGER NOT NULL
         );
         CREATE TABLE IF NOT EXISTS events (
             instance_id INTEGER NOT NULL,
             seq         INTEGER NOT NULL,
             session_id  TEXT,
             kind        INTEGER NOT NULL,
             message     TEXT    NOT NULL,
             ts_ms       INTEGER NOT NULL,
             PRIMARY KEY (instance_id, seq)
         );
         CREATE INDEX IF NOT EXISTS events_session_seq
             ON events (instance_id, session_id, seq);
         CREATE TABLE IF NOT EXISTS sessions (
             instance_id INTEGER NOT NULL,
             session_id  TEXT    NOT NULL,
             incomplete  INTEGER NOT NULL DEFAULT 0,
             PRIMARY KEY (instance_id, session_id)
         );
         CREATE TABLE IF NOT EXISTS teams (
             id          TEXT PRIMARY KEY,
             state_json  TEXT NOT NULL
         );
         CREATE TABLE IF NOT EXISTS team_meta (
             key   TEXT PRIMARY KEY,
             value TEXT NOT NULL
         );
         CREATE TABLE IF NOT EXISTS boards (
             team_id TEXT PRIMARY KEY,
             rev     INTEGER NOT NULL,
             json    TEXT NOT NULL
         );
         CREATE TABLE IF NOT EXISTS card_history (
             team_id TEXT NOT NULL,
             card_id TEXT NOT NULL,
             rev     INTEGER NOT NULL,
             json    TEXT NOT NULL,
             ts_ms   INTEGER NOT NULL,
             PRIMARY KEY (team_id, card_id, rev)
         );
         CREATE TABLE IF NOT EXISTS workflows (
             scope      TEXT    NOT NULL,
             project    TEXT    NOT NULL,
             name       TEXT    NOT NULL,
             json       TEXT    NOT NULL,
             updated_ms INTEGER NOT NULL,
             PRIMARY KEY (scope, project, name)
         );",
    )
    .context("creating tables")
}

fn find_instance(conn: &Connection, instance_key: &str) -> Result<Option<i64>> {
    conn.query_row(
        "SELECT id FROM instances WHERE instance_key = ?1",
        params![instance_key],
        |row| row.get(0),
    )
    .optional()
    .context("looking up an instance")
}

/// Insert one event and return its sequence number. The caller owns the
/// transaction, so a batch stays atomic.
///
/// Statements are prepared through the connection's statement cache: a batch
/// reuses them instead of re-parsing four SQL strings per event.
fn insert_event(conn: &Connection, event: &NewEvent) -> Result<u64> {
    if event.instance_key.is_empty() {
        bail!("instance_key must not be empty");
    }

    let counter = instance_counter(conn, &event.instance_key)?;
    let (instance_id, next_seq) = match counter {
        Some(found) => found,
        None => {
            conn.prepare_cached("INSERT INTO instances (instance_key, next_seq) VALUES (?1, 1)")
                .context("preparing the instance insert")?
                .execute(params![event.instance_key])
                .context("recording an instance")?;
            instance_counter(conn, &event.instance_key)
                .context("re-reading a just-created instance")?
                .context("a just-created instance is missing")?
        }
    };

    let seq = from_i64(next_seq, "seq")?;
    conn.prepare_cached("UPDATE instances SET next_seq = ?2 WHERE id = ?1")
        .context("preparing the counter update")?
        .execute(params![instance_id, next_seq + 1])
        .context("advancing the instance counter")?;
    conn.prepare_cached(
        "INSERT INTO events (instance_id, seq, session_id, kind, message, ts_ms) \
         VALUES (?1, ?2, ?3, ?4, ?5, ?6)",
    )
    .context("preparing the event insert")?
    .execute(params![
        instance_id,
        next_seq,
        event.session_id,
        event.kind.as_i64(),
        event.message,
        event.ts_ms,
    ])
    .context("inserting the event")?;

    if let Some(session_id) = &event.session_id {
        conn.prepare_cached(
            "INSERT INTO sessions (instance_id, session_id, incomplete) VALUES (?1, ?2, 0) \
             ON CONFLICT (instance_id, session_id) DO NOTHING",
        )
        .context("preparing the session insert")?
        .execute(params![instance_id, session_id])
        .context("recording the session")?;
    }
    Ok(seq)
}

/// `(instance id, next seq)` for `instance_key`, or `None` when it is unknown.
fn instance_counter(conn: &Connection, instance_key: &str) -> Result<Option<(i64, i64)>> {
    conn.prepare_cached("SELECT id, next_seq FROM instances WHERE instance_key = ?1")
        .context("preparing the instance lookup")?
        .query_row(params![instance_key], |row| Ok((row.get(0)?, row.get(1)?)))
        .optional()
        .context("reading the instance counter")
}

/// Insert one event with a caller-chosen sequence number.
///
/// Rejects a number that does not strictly increase for the instance, and
/// advances `next_seq` to `max(seq) + 1` so the store's own allocator (used by
/// [`Store::append`]) cannot hand out a number that is already taken.
fn insert_event_at(conn: &Connection, seq: u64, event: &NewEvent) -> Result<()> {
    if event.instance_key.is_empty() {
        bail!("instance_key must not be empty");
    }
    if seq == 0 {
        bail!("seq must be at least 1 (the relay's counter starts at 1)");
    }
    let seq = to_i64(seq, "seq")?;

    let counter = instance_counter(conn, &event.instance_key)?;
    let instance_id = match counter {
        Some((instance_id, next_seq)) => {
            let highest = next_seq - 1;
            if seq <= highest {
                bail!(
                    "seq {seq} for instance {:?} is not greater than the stored maximum {highest}; \
                     sequence numbers must strictly increase",
                    event.instance_key
                );
            }
            instance_id
        }
        None => {
            conn.prepare_cached("INSERT INTO instances (instance_key, next_seq) VALUES (?1, 1)")
                .context("preparing the instance insert")?
                .execute(params![event.instance_key])
                .context("recording an instance")?;
            instance_counter(conn, &event.instance_key)
                .context("re-reading a just-created instance")?
                .context("a just-created instance is missing")?
                .0
        }
    };

    conn.prepare_cached("UPDATE instances SET next_seq = ?2 WHERE id = ?1")
        .context("preparing the counter update")?
        .execute(params![instance_id, seq + 1])
        .context("advancing the instance counter")?;
    conn.prepare_cached(
        "INSERT INTO events (instance_id, seq, session_id, kind, message, ts_ms) \
         VALUES (?1, ?2, ?3, ?4, ?5, ?6)",
    )
    .context("preparing the event insert")?
    .execute(params![
        instance_id,
        seq,
        event.session_id,
        event.kind.as_i64(),
        event.message,
        event.ts_ms,
    ])
    .context("inserting the event")?;

    if let Some(session_id) = &event.session_id {
        // First sighting of a session registers it as complete; only pruning or
        // an explicit mark makes it incomplete.
        conn.prepare_cached(
            "INSERT INTO sessions (instance_id, session_id, incomplete) VALUES (?1, ?2, 0) \
             ON CONFLICT (instance_id, session_id) DO NOTHING",
        )
        .context("preparing the session insert")?
        .execute(params![instance_id, session_id])
        .context("recording the session")?;
    }
    Ok(())
}

/// Move a corrupt database aside and drop its WAL sidecars.
///
/// The sidecars are deleted rather than renamed: a WAL belonging to a corrupt
/// database must never be picked up by the fresh one, and deleting them also
/// removes the shared-memory file.
fn quarantine(path: &Path, detail: &str) -> Result<()> {
    let stamp = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|elapsed| elapsed.as_secs())
        .unwrap_or_default();
    let mut target = path.with_file_name(format!(
        "{}.corrupt-{stamp}",
        path.file_name()
            .map(|name| name.to_string_lossy().into_owned())
            .unwrap_or_else(|| "store".to_string())
    ));
    // Two corrupt files in the same second must not overwrite each other.
    for attempt in 1..1000 {
        if !target.exists() {
            break;
        }
        target = path.with_file_name(format!(
            "{}.corrupt-{stamp}-{attempt}",
            path.file_name()
                .map(|name| name.to_string_lossy().into_owned())
                .unwrap_or_else(|| "store".to_string())
        ));
    }

    fs::rename(path, &target).with_context(|| {
        format!(
            "moving the corrupt event store {} to {}",
            path.display(),
            target.display()
        )
    })?;
    eprintln!(
        "nvim_ade_server: warning: event store {} was corrupted ({detail}); \
         moved it to {} and started a new one",
        path.display(),
        target.display()
    );

    for suffix in ["-wal", "-shm"] {
        let sidecar = sidecar_path(path, suffix);
        match fs::remove_file(&sidecar) {
            Ok(()) => {}
            Err(error) if error.kind() == ErrorKind::NotFound => {}
            Err(error) => {
                return Err(error)
                    .with_context(|| format!("removing stale sidecar {}", sidecar.display()))
            }
        }
    }
    Ok(())
}

fn to_i64(value: u64, field: &str) -> Result<i64> {
    i64::try_from(value).with_context(|| format!("{field} does not fit in an SQLite integer"))
}

fn from_i64(value: i64, field: &str) -> Result<u64> {
    u64::try_from(value).with_context(|| format!("{field} is negative ({value})"))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn event(instance: &str, session: Option<&str>, message: &str) -> NewEvent {
        NewEvent {
            instance_key: instance.to_string(),
            session_id: session.map(str::to_string),
            kind: EventKind::AgentNotification,
            message: message.to_string(),
            ts_ms: 1,
        }
    }

    #[test]
    fn event_kinds_round_trip_through_their_stored_values() {
        for kind in EventKind::ALL {
            assert_eq!(EventKind::from_i64(kind.as_i64()).expect("kind"), kind);
        }
        assert!(EventKind::from_i64(0).is_err());
        assert!(EventKind::from_i64(6).is_err());
    }

    #[test]
    fn instance_keys_must_not_be_empty() {
        let store = Store::open_in_memory().expect("open");
        let error = store.append(event("", None, "{}")).expect_err("empty key");
        assert!(format!("{error:#}").contains("instance_key"));
    }

    #[test]
    fn a_batch_rolls_back_as_a_whole() {
        let store = Store::open_in_memory().expect("open");
        let batch = vec![
            event("a", Some("s"), "first"),
            // An invalid event in the middle rejects the whole batch.
            event("", Some("s"), "broken"),
        ];
        assert!(store.append_batch(batch).is_err());
        assert!(store.read(&Query::new("a")).expect("read").is_empty());
        assert_eq!(store.last_seq("a").expect("last_seq"), 0);
        assert!(store.instances().expect("instances").is_empty());
    }

    #[test]
    fn unseen_instances_read_as_empty() {
        let store = Store::open_in_memory().expect("open");
        assert!(store.read(&Query::new("nope")).expect("read").is_empty());
        assert_eq!(store.last_seq("nope").expect("last_seq"), 0);
        assert!(!store.session_complete("nope", "s").expect("complete"));
        assert!(store.instances().expect("instances").is_empty());
    }

    #[test]
    fn synthetic_events_are_excluded_from_the_default_read() {
        let store = Store::open_in_memory().expect("open");
        store
            .append(NewEvent {
                kind: EventKind::Synthetic,
                ..event("a", Some("s"), "local")
            })
            .expect("append");
        assert!(store.read(&Query::new("a")).expect("read").is_empty());
    }

    /// A full disk or read-only media must never be mistaken for corruption:
    /// quarantining the file then would throw away a perfectly good log.
    #[test]
    fn only_database_damage_counts_as_corruption() {
        let make = |code| {
            anyhow::Error::new(rusqlite::Error::SqliteFailure(
                rusqlite::ffi::Error {
                    code,
                    extended_code: 0,
                },
                None,
            ))
        };
        assert!(is_corruption_error(&make(ErrorCode::NotADatabase)));
        assert!(is_corruption_error(&make(ErrorCode::DatabaseCorrupt)));
        for code in [
            ErrorCode::DiskFull,
            ErrorCode::ReadOnly,
            ErrorCode::CannotOpen,
            ErrorCode::DatabaseBusy,
            ErrorCode::SystemIoFailure,
            ErrorCode::PermissionDenied,
        ] {
            assert!(!is_corruption_error(&make(code)), "{code:?}");
        }
        assert!(!is_corruption_error(&anyhow::anyhow!("plain io error")));
    }

    /// Zero-length messages hold no payload, so they never need pruning, and a
    /// mix of empty and non-empty messages must still terminate.
    #[test]
    fn pruning_terminates_with_empty_messages() {
        let store = Store::open_in_memory().expect("open");
        for _ in 0..5 {
            store.append(event("a", Some("s"), "")).expect("append");
        }
        let report = store.prune("a", 0).expect("prune");
        assert_eq!(report.removed_events, 0, "empty payloads always fit");
        assert_eq!(store.read(&Query::new("a")).expect("read").len(), 5);

        // Mixing empty messages in must not stall the scan.
        store.append(event("a", Some("s"), "xxxx")).expect("append");
        store.append(event("a", Some("s"), "")).expect("append");
        store.append(event("a", Some("s"), "yyyy")).expect("append");
        let report = store.prune("a", 4).expect("prune");
        // The five leading empties and `xxxx` go (0 + 4 bytes); the empty
        // message between `xxxx` and `yyyy` stays, because the budget is met.
        assert_eq!(report.removed_events, 6);
        assert_eq!(report.removed_bytes, 4);
        let events = store.read(&Query::new("a")).expect("read");
        assert_eq!(events.len(), 2);
        assert_eq!(events[0].message, "");
        assert_eq!(events[1].message, "yyyy");
        assert!(!store.session_complete("a", "s").expect("incomplete"));
    }

    /// Keeping exactly the payload of a session leaves it complete.
    #[test]
    fn a_prune_at_the_exact_size_boundary_keeps_the_session_complete() {
        let store = Store::open_in_memory().expect("open");
        store
            .append(event("a", Some("s"), "12345"))
            .expect("append");
        store
            .append(event("a", Some("s"), "67890"))
            .expect("append");

        let report = store.prune("a", 10).expect("prune");
        assert_eq!(report, PruneReport::default());
        assert!(store.session_complete("a", "s").expect("complete"));
    }

    #[test]
    fn boards_keep_twenty_versions_and_are_deleted_with_their_team() {
        let store = Store::open_in_memory().expect("open");
        let history: Vec<(String, String, i64, i64)> = (1..=25)
            .map(|rev| ("T1".to_string(), format!("{{\"rev\":{rev}}}"), rev, rev))
            .collect();
        store
            .save_board("t1", 25, r#"{"rev":25}"#, &history, &[])
            .expect("save board");
        let board = store.load_board("t1").expect("load").expect("board");
        assert_eq!(board.rev, 25);
        assert_eq!(board.history.len(), 20, "older versions are pruned");
        assert_eq!(board.history[0].2, 25, "newest first");
        assert_eq!(board.history[19].2, 6);

        store
            .save_board("t1", 26, r#"{"rev":26}"#, &[], &["T1".to_string()])
            .expect("clear history");
        let board = store.load_board("t1").expect("load").expect("board");
        assert!(board.history.is_empty(), "archiving clears history");

        store.delete_team("t1").expect("delete team");
        assert!(store.load_board("t1").expect("load").is_none());
    }
}
