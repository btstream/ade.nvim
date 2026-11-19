//! Team boards (PROTOCOL.md 19.2-19.4).
//!
//! A board is pure state: [`Board::apply_leader`] and [`Board::apply_worker`]
//! validate a write as a whole and either apply it or leave the board
//! untouched. Persistence, the 10-second worker coalescing timer and the
//! front-end notification are driven by `hub::teams`; [`Board::take_persist`]
//! turns the current state plus the last persisted state into one store job
//! (board row, card history rows and cleared history).

use std::collections::{BTreeMap, HashMap, HashSet, VecDeque};

use serde::{Deserialize, Serialize};
use serde_json::{json, Value};

use super::{Team, TeamError, Teams};

/// A board serialised as JSON is at most 256 KiB.
pub const MAX_BOARD_BYTES: usize = 256 * 1024;
/// At most 200 cards that are not archived.
pub const MAX_CARDS: usize = 200;
/// At most 500 archived cards; older ones are dropped.
pub const MAX_ARCHIVED: usize = 500;
/// At most 16 columns.
pub const MAX_COLUMNS: usize = 16;
/// One column title is 1..40 characters.
pub const MAX_COLUMN_CHARS: usize = 40;
/// One card title is 1..200 characters.
pub const MAX_TITLE_CHARS: usize = 200;
/// One stage is 1..40 characters.
pub const MAX_STAGE_CHARS: usize = 40;
/// A card body is at most 8 KiB.
pub const MAX_CARD_BODY_BYTES: usize = 8 * 1024;
/// A board workflow text is at most 4 KiB.
pub const MAX_WORKFLOW_BYTES: usize = 4 * 1024;
/// At most 12 fields per card; keys 1..32, values up to 120 characters.
pub const MAX_FIELDS: usize = 12;
pub const MAX_FIELD_KEY_CHARS: usize = 32;
pub const MAX_FIELD_VALUE_CHARS: usize = 120;
/// The card summary line used by `team.send {card}` is cut at this many chars.
pub const MAX_SUMMARY_CHARS: usize = 400;
/// Each card keeps its 20 newest history versions.
pub const HISTORY_VERSIONS: usize = 20;
/// Worker writes coalesce for 10 s by default; tests shorten it.
pub const DEFAULT_FLUSH_MS: u64 = 10_000;

/// How long worker board writes are coalesced before persisting and notifying.
pub fn flush_interval_ms() -> u64 {
    std::env::var("NVIM_ADE_SERVER_BOARD_FLUSH_MS")
        .ok()
        .and_then(|value| value.trim().parse::<u64>().ok())
        .filter(|value| *value > 0)
        .unwrap_or(DEFAULT_FLUSH_MS)
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Card {
    pub id: String,
    pub title: String,
    pub column: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub owner: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub stage: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub body: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub fields: Option<BTreeMap<String, String>>,
    pub archived: bool,
    pub updated_by: String,
    pub updated_at: u64,
}

impl Card {
    fn outline(&self) -> Value {
        json!({
            "id": self.id,
            "title": self.title,
            "column": self.column,
            "owner": self.owner,
            "stage": self.stage,
        })
    }
}

#[derive(Debug, Clone, Default, Serialize, Deserialize)]
#[serde(default)]
pub struct Board {
    pub rev: u64,
    pub workflow_name: Option<String>,
    pub workflow: Option<String>,
    pub columns: Vec<String>,
    pub cards: Vec<Card>,
    /// Newest first, at most [`HISTORY_VERSIONS`] per card.
    #[serde(skip)]
    history: HashMap<String, VecDeque<Card>>,
    /// The card values as last persisted, for computing history.
    #[serde(skip)]
    persisted: HashMap<String, Card>,
    #[serde(skip)]
    persisted_rev: u64,
    /// The stored JSON could not be read. The board is shown empty and every
    /// write is refused so the database row is never overwritten.
    #[serde(skip)]
    pub unavailable: bool,
}

/// One board write ready for the store thread.
#[derive(Debug, Clone)]
pub struct BoardPersist {
    pub rev: u64,
    pub json: String,
    /// `(card id, old card JSON, old board rev, ts_ms)`.
    pub history: Vec<(String, String, i64, i64)>,
    /// Cards whose history was deleted (archived or removed).
    pub cleared: Vec<String>,
}

/// A card as addressed by one `upsert` entry. `None` means "not given".
#[derive(Debug, Default)]
struct CardPatch {
    id: String,
    title: Option<String>,
    column: Option<String>,
    owner: Option<Option<String>>,
    stage: Option<Option<String>>,
    body: Option<Option<String>>,
    fields: Option<FieldsPatch>,
}

#[derive(Debug)]
enum FieldsPatch {
    Clear,
    Merge(BTreeMap<String, Option<String>>),
}

impl Board {
    pub fn card(&self, id: &str) -> Option<&Card> {
        self.cards.iter().find(|card| card.id == id)
    }

    pub fn to_json(&self) -> Value {
        let mut value = serde_json::to_value(self).unwrap_or_else(|_| json!({}));
        if self.unavailable {
            value["unavailable"] = json!(true);
        }
        value
    }

    /// The leader's view in `bus.status` (19.3).
    pub fn status(&self) -> Value {
        let cards: Vec<Value> = self
            .cards
            .iter()
            .filter(|card| !card.archived)
            .map(Card::outline)
            .collect();
        let mut archived: BTreeMap<String, u64> = BTreeMap::new();
        for card in self.cards.iter().filter(|card| card.archived) {
            *archived
                .entry(card.stage.clone().unwrap_or_default())
                .or_insert(0) += 1;
        }
        let mut out = json!({
            "rev": self.rev,
            "workflow_name": self.workflow_name,
            "columns": self.columns,
            "cards": cards,
            "archived": archived,
        });
        if self.unavailable {
            out["unavailable"] = json!(true);
        }
        out
    }

    /// `team.list`'s `stages`: counts per stage, in first-card order.
    pub fn stages(&self) -> Value {
        let mut order: Vec<(String, u64, u64)> = Vec::new();
        let mut index: HashMap<&str, usize> = HashMap::new();
        for card in &self.cards {
            let stage = card.stage.as_deref().unwrap_or("");
            let slot = *index.entry(stage).or_insert_with(|| {
                order.push((stage.to_string(), 0, 0));
                order.len() - 1
            });
            if card.archived {
                order[slot].2 += 1;
            } else {
                order[slot].1 += 1;
            }
        }
        json!(order
            .into_iter()
            .map(|(stage, open, archived)| {
                json!({ "stage": stage, "open": open, "archived": archived })
            })
            .collect::<Vec<_>>())
    }

    /// The `team.send {card}` summary line (19.3), one line, cut at 400 chars.
    pub fn summary_line(card: &Card) -> String {
        let owner = card.owner.as_deref().unwrap_or("-");
        let mut line = format!(
            "[card {} · {} · {} · {}",
            card.id,
            one_line(&card.title),
            one_line(&card.column),
            one_line(owner)
        );
        if let Some(fields) = &card.fields {
            for (key, value) in fields {
                line.push_str(" · ");
                line.push_str(&one_line(key));
                line.push('=');
                line.push_str(&one_line(value));
            }
        }
        line.push(']');
        line.chars().take(MAX_SUMMARY_CHARS).collect()
    }

    /// Apply one `bus.board_update` atomically. The board is unchanged on any
    /// error.
    pub fn apply_leader(
        &mut self,
        params: &Value,
        workers: &HashSet<String>,
        now: u64,
    ) -> Result<u64, TeamError> {
        if self.unavailable {
            return Err(TeamError::not_allowed("board unavailable"));
        }
        let object = params
            .as_object()
            .ok_or_else(|| TeamError::invalid("board_update params must be an object"))?;
        let mut next = self.writable_clone();

        // 1. workflow_name / workflow.
        if let Some(value) = object.get("workflow_name") {
            next.workflow_name = parse_optional_string(value, "workflow_name")?;
        }
        if let Some(value) = object.get("workflow") {
            let workflow = parse_optional_string(value, "workflow")?;
            if let Some(text) = &workflow {
                if text.len() > MAX_WORKFLOW_BYTES {
                    return Err(TeamError::invalid("workflow is longer than 4 KiB"));
                }
            }
            next.workflow = workflow;
        }

        // 2. columns replaces the list.
        if let Some(value) = object.get("columns") {
            let columns = parse_columns(value)?;
            next.columns = columns;
        }

        // 3. upsert, 4. archive, 5. remove. An id may appear only once across
        // the three lists.
        let upserts = parse_patches(object.get("upsert"))?;
        let archive = parse_ids(object.get("archive"), "archive")?;
        let remove = parse_ids(object.get("remove"), "remove")?;
        let mut seen: HashSet<String> = HashSet::new();
        for patch in &upserts {
            if !seen.insert(patch.id.clone()) {
                return Err(TeamError::invalid(format!(
                    "card {} is listed twice",
                    patch.id
                )));
            }
        }
        for id in archive.iter().chain(remove.iter()) {
            if !seen.insert(id.clone()) {
                return Err(TeamError::invalid(format!("card {id} is listed twice")));
            }
        }

        for patch in upserts {
            next.upsert(patch, workers, now)?;
        }
        for id in archive {
            let card = next
                .cards
                .iter_mut()
                .find(|card| card.id == id)
                .ok_or_else(|| TeamError::invalid(format!("unknown card {id}")))?;
            card.archived = true;
            card.updated_by = "leader".to_string();
            card.updated_at = now;
        }
        for id in remove {
            let index = next
                .cards
                .iter()
                .position(|card| card.id == id)
                .ok_or_else(|| TeamError::invalid(format!("unknown card {id}")))?;
            next.cards.remove(index);
        }

        next.enforce_limits()?;
        next.rev += 1;
        self.adopt(next);
        Ok(self.rev)
    }

    /// Step 4 of `team.start` (19.7): the service writes the workflow onto a
    /// board that has none. One atomic write; `None` when the board already
    /// names a workflow (nothing is written then).
    pub fn apply_workflow(
        &mut self,
        name: &str,
        text: &str,
        columns: Option<&[String]>,
    ) -> Result<Option<u64>, TeamError> {
        if self.unavailable {
            // 19.7 step 4: an unavailable board is left alone and the start
            // goes on (the leader still needs the notice).
            return Ok(None);
        }
        if self.workflow_name.is_some() {
            return Ok(None);
        }
        let mut next = self.writable_clone();
        next.workflow_name = Some(name.to_string());
        next.workflow = Some(text.to_string());
        // The workflow's columns only fill an empty board: what the leader
        // already put there wins.
        if next.columns.is_empty() {
            if let Some(columns) = columns {
                if !columns.is_empty() {
                    next.columns = columns.to_vec();
                }
            }
        }
        next.enforce_limits()?;
        next.rev += 1;
        self.adopt(next);
        Ok(Some(self.rev))
    }

    /// Apply one `bus.card_update` atomically (19.2). The board is unchanged on
    /// any error.
    pub fn apply_worker(
        &mut self,
        owner: &str,
        params: &Value,
        now: u64,
    ) -> Result<u64, TeamError> {
        if self.unavailable {
            return Err(TeamError::not_allowed("board unavailable"));
        }
        let object = params
            .as_object()
            .ok_or_else(|| TeamError::invalid("card_update params must be an object"))?;
        let card_id = object
            .get("card")
            .and_then(Value::as_str)
            .ok_or_else(|| TeamError::invalid("card must be a string"))?;
        let index = self
            .cards
            .iter()
            .position(|card| card.id == card_id)
            .ok_or_else(|| TeamError::invalid(format!("unknown card {card_id}")))?;
        let card = &self.cards[index];
        if card.archived {
            return Err(TeamError::not_allowed("card is archived"));
        }
        if card.owner.as_deref() != Some(owner) {
            return Err(TeamError::not_allowed("not your card"));
        }

        let mut next = self.writable_clone();
        if let Some(value) = object.get("body") {
            let body = parse_optional_string(value, "body")?;
            if let Some(text) = &body {
                if text.len() > MAX_CARD_BODY_BYTES {
                    return Err(TeamError::invalid("body is longer than 8 KiB"));
                }
            }
            next.cards[index].body = body;
        }
        if let Some(value) = object.get("fields") {
            let patch = parse_fields(value)?;
            apply_fields(&mut next.cards[index].fields, patch)?;
        }
        if let Some(value) = object.get("archive") {
            match value {
                Value::Bool(true) => next.cards[index].archived = true,
                Value::Bool(false) => {
                    return Err(TeamError::invalid("archive must be true when given"))
                }
                _ => return Err(TeamError::invalid("archive must be a boolean")),
            }
        }
        next.cards[index].updated_by = owner.to_string();
        next.cards[index].updated_at = now;
        next.enforce_limits()?;
        next.rev += 1;
        self.adopt(next);
        Ok(self.rev)
    }

    /// Clear `owner` from every card (19.12): a refused or orphaned spawn
    /// item. One write, attributed to the service. `None` when no card used
    /// the name (or the board is unavailable).
    pub fn clear_owner(
        &mut self,
        owner: &str,
        now: u64,
    ) -> Result<Option<(u64, Vec<String>)>, TeamError> {
        if self.unavailable {
            return Ok(None);
        }
        let cards: Vec<String> = self
            .cards
            .iter()
            .filter(|card| card.owner.as_deref() == Some(owner))
            .map(|card| card.id.clone())
            .collect();
        if cards.is_empty() {
            return Ok(None);
        }
        let mut next = self.writable_clone();
        for card in &mut next.cards {
            if card.owner.as_deref() == Some(owner) {
                card.owner = None;
                card.updated_by = "service".to_string();
                card.updated_at = now;
            }
        }
        next.enforce_limits()?;
        next.rev += 1;
        self.adopt(next);
        Ok(Some((self.rev, cards)))
    }

    /// A clone of only what a write may change. History and the persisted
    /// bookkeeping are not copied (they can hold every card version).
    fn writable_clone(&self) -> Board {
        Board {
            rev: self.rev,
            workflow_name: self.workflow_name.clone(),
            workflow: self.workflow.clone(),
            columns: self.columns.clone(),
            cards: self.cards.clone(),
            unavailable: self.unavailable,
            ..Board::default()
        }
    }

    /// Copy back the writable half after a successful write.
    fn adopt(&mut self, next: Board) {
        self.rev = next.rev;
        self.workflow_name = next.workflow_name;
        self.workflow = next.workflow;
        self.columns = next.columns;
        self.cards = next.cards;
    }

    fn upsert(
        &mut self,
        patch: CardPatch,
        workers: &HashSet<String>,
        now: u64,
    ) -> Result<(), TeamError> {
        if let Some(Some(owner)) = &patch.owner {
            if !workers.contains(owner) {
                return Err(TeamError::invalid(format!(
                    "owner {owner} is not a worker of the team"
                )));
            }
        }
        if let Some(Some(stage)) = &patch.stage {
            if stage.is_empty() || stage.chars().count() > MAX_STAGE_CHARS {
                return Err(TeamError::invalid("stage must be 1..40 characters"));
            }
        }
        if let Some(Some(body)) = &patch.body {
            if body.len() > MAX_CARD_BODY_BYTES {
                return Err(TeamError::invalid("body is longer than 8 KiB"));
            }
        }
        if let Some(title) = &patch.title {
            if title.is_empty() || title.chars().count() > MAX_TITLE_CHARS {
                return Err(TeamError::invalid("title must be 1..200 characters"));
            }
        }
        if let Some(column) = &patch.column {
            if column.is_empty() {
                return Err(TeamError::invalid("column must not be empty"));
            }
        }

        if let Some(card) = self.cards.iter_mut().find(|card| card.id == patch.id) {
            if card.archived {
                return Err(TeamError::not_allowed("card is archived"));
            }
            if let Some(title) = patch.title {
                card.title = title;
            }
            if let Some(column) = patch.column {
                card.column = column;
            }
            if let Some(owner) = patch.owner {
                card.owner = owner;
            }
            if let Some(stage) = patch.stage {
                card.stage = stage;
            }
            if let Some(body) = patch.body {
                card.body = body;
            }
            if let Some(fields) = patch.fields {
                apply_fields(&mut card.fields, fields)?;
            }
            card.updated_by = "leader".to_string();
            card.updated_at = now;
            return Ok(());
        }

        let title = patch
            .title
            .ok_or_else(|| TeamError::invalid("a new card needs a title"))?;
        let column = patch
            .column
            .ok_or_else(|| TeamError::invalid("a new card needs a column"))?;
        let mut fields = None;
        if let Some(patch) = patch.fields {
            apply_fields(&mut fields, patch)?;
        }
        self.cards.push(Card {
            id: patch.id,
            title,
            column,
            owner: patch.owner.flatten(),
            stage: patch.stage.flatten(),
            body: patch.body.flatten(),
            fields,
            archived: false,
            updated_by: "leader".to_string(),
            updated_at: now,
        });
        Ok(())
    }

    /// Refuse a write that breaks a limit; drop the oldest archived cards past
    /// 500. Called on a candidate board before it replaces the current one.
    fn enforce_limits(&mut self) -> Result<(), TeamError> {
        if self.cards.iter().filter(|card| !card.archived).count() > MAX_CARDS {
            return Err(TeamError::invalid("board has more than 200 cards"));
        }
        let archived: Vec<(u64, usize)> = self
            .cards
            .iter()
            .enumerate()
            .filter(|(_, card)| card.archived)
            .map(|(index, card)| (card.updated_at, index))
            .collect();
        if archived.len() > MAX_ARCHIVED {
            let mut oldest = archived;
            oldest.sort_unstable();
            let drop: HashSet<usize> = oldest
                .into_iter()
                .take(self.cards.iter().filter(|card| card.archived).count() - MAX_ARCHIVED)
                .map(|(_, index)| index)
                .collect();
            let mut index = 0;
            self.cards.retain(|_| {
                let keep = !drop.contains(&index);
                index += 1;
                keep
            });
        }
        for card in self.cards.iter().filter(|card| !card.archived) {
            if !self.columns.iter().any(|column| column == &card.column) {
                return Err(TeamError::invalid(format!(
                    "column {} is not on the board",
                    card.column
                )));
            }
        }
        let bytes = serde_json::to_vec(self)
            .map_err(|_| TeamError::invalid("board cannot be serialized"))?
            .len();
        if bytes > MAX_BOARD_BYTES {
            return Err(TeamError::invalid("board is larger than 256 KiB"));
        }
        Ok(())
    }

    /// Build the store job for the current state and remember it as persisted.
    /// `None` means there is nothing new to write.
    pub fn take_persist(&mut self, now: u64) -> Option<BoardPersist> {
        if self.unavailable || self.rev == self.persisted_rev {
            return None;
        }
        let mut history = Vec::new();
        let mut cleared: HashSet<String> = HashSet::new();
        let mut present: HashSet<String> = HashSet::new();
        for card in &self.cards {
            present.insert(card.id.clone());
            if card.archived {
                if self.history.remove(&card.id).is_some()
                    || self.persisted.remove(&card.id).is_some()
                {
                    cleared.insert(card.id.clone());
                }
                continue;
            }
            if let Some(old) = self.persisted.get(&card.id) {
                if old != card {
                    if let Ok(json) = serde_json::to_string(old) {
                        history.push((
                            card.id.clone(),
                            json,
                            self.persisted_rev as i64,
                            now as i64,
                        ));
                    }
                    let versions = self.history.entry(card.id.clone()).or_default();
                    versions.push_front(old.clone());
                    versions.truncate(HISTORY_VERSIONS);
                }
            }
        }
        for id in self.persisted.keys() {
            if !present.contains(id) {
                cleared.insert(id.clone());
                self.history.remove(id);
            }
        }
        self.persisted.clear();
        for card in self.cards.iter().filter(|card| !card.archived) {
            self.persisted.insert(card.id.clone(), card.clone());
        }
        // The in-memory persisted state advances before the store thread has
        // confirmed the write. A failed database write therefore loses this
        // delta; journaling failures was judged not worth the complexity.
        self.persisted_rev = self.rev;
        let json = serde_json::to_string(self).unwrap_or_default();
        Some(BoardPersist {
            rev: self.rev,
            json,
            history,
            cleared: cleared.into_iter().collect(),
        })
    }

    /// A board whose stored JSON could not be read. Writes are refused so an
    /// empty board never replaces the row.
    pub fn unavailable() -> Board {
        Board {
            unavailable: true,
            ..Board::default()
        }
    }

    /// Restore a board and its history from the database. An unreadable board
    /// is reported to the caller, which keeps the row untouched.
    pub fn from_stored(
        rev: u64,
        json: &str,
        rows: Vec<(String, String, i64)>,
    ) -> Result<Board, String> {
        let mut board: Board = serde_json::from_str(json).map_err(|error| format!("{error}"))?;
        board.rev = rev;
        board.persisted_rev = rev;
        board.persisted = board
            .cards
            .iter()
            .filter(|card| !card.archived)
            .map(|card| (card.id.clone(), card.clone()))
            .collect();
        let mut history: HashMap<String, VecDeque<Card>> = HashMap::new();
        let mut rows = rows;
        rows.sort_by_key(|row| std::cmp::Reverse(row.2));
        for (id, json, _) in rows {
            let Some(card) = board.card(&id) else {
                continue;
            };
            if card.archived {
                continue;
            }
            let Ok(version) = serde_json::from_str::<Card>(&json) else {
                continue;
            };
            history.entry(id).or_default().push_back(version);
        }
        for versions in history.values_mut() {
            versions.truncate(HISTORY_VERSIONS);
        }
        board.history = history;
        Ok(board)
    }

    /// Newest first. Empty for an archived card.
    pub fn history_of(&self, id: &str) -> Vec<Card> {
        match self.card(id) {
            Some(card) if !card.archived => self
                .history
                .get(id)
                .map(|versions| versions.iter().cloned().collect())
                .unwrap_or_default(),
            _ => Vec::new(),
        }
    }

    pub fn is_dirty(&self) -> bool {
        !self.unavailable && self.rev != self.persisted_rev
    }
}

fn one_line(text: &str) -> String {
    text.replace(['\n', '\r'], " ")
}

fn parse_optional_string(value: &Value, field: &str) -> Result<Option<String>, TeamError> {
    match value {
        Value::Null => Ok(None),
        Value::String(text) => Ok(Some(text.clone())),
        _ => Err(TeamError::invalid(format!(
            "{field} must be a string or null"
        ))),
    }
}

fn parse_columns(value: &Value) -> Result<Vec<String>, TeamError> {
    let Value::Array(items) = value else {
        return Err(TeamError::invalid("columns must be an array"));
    };
    if items.len() > MAX_COLUMNS {
        return Err(TeamError::invalid("columns has more than 16 entries"));
    }
    let mut columns = Vec::new();
    let mut seen = HashSet::new();
    for item in items {
        let Some(title) = item.as_str() else {
            return Err(TeamError::invalid("columns must be strings"));
        };
        if title.is_empty() || title.chars().count() > MAX_COLUMN_CHARS {
            return Err(TeamError::invalid(
                "a column title must be 1..40 characters",
            ));
        }
        if !seen.insert(title.to_string()) {
            return Err(TeamError::invalid(format!("duplicate column {title}")));
        }
        columns.push(title.to_string());
    }
    Ok(columns)
}

fn parse_patches(value: Option<&Value>) -> Result<Vec<CardPatch>, TeamError> {
    let Some(value) = value else {
        return Ok(Vec::new());
    };
    if value.is_null() {
        return Ok(Vec::new());
    }
    let Value::Array(items) = value else {
        return Err(TeamError::invalid("upsert must be an array"));
    };
    items.iter().map(parse_patch).collect()
}

fn parse_patch(value: &Value) -> Result<CardPatch, TeamError> {
    let object = value
        .as_object()
        .ok_or_else(|| TeamError::invalid("upsert entries must be objects"))?;
    let id = object
        .get("id")
        .and_then(Value::as_str)
        .ok_or_else(|| TeamError::invalid("a card needs an id"))?;
    validate_id(id)?;
    for field in ["archived", "updated_by", "updated_at"] {
        if object.contains_key(field) {
            return Err(TeamError::invalid(format!(
                "{field} cannot be written here"
            )));
        }
    }
    let mut patch = CardPatch {
        id: id.to_string(),
        ..CardPatch::default()
    };
    if let Some(value) = object.get("title") {
        let title = value
            .as_str()
            .ok_or_else(|| TeamError::invalid("title must be a string"))?;
        patch.title = Some(title.to_string());
    }
    if let Some(value) = object.get("column") {
        let column = value
            .as_str()
            .ok_or_else(|| TeamError::invalid("column must be a string"))?;
        patch.column = Some(column.to_string());
    }
    for (field, slot) in [
        ("owner", &mut patch.owner),
        ("stage", &mut patch.stage),
        ("body", &mut patch.body),
    ] {
        if let Some(value) = object.get(field) {
            *slot = Some(parse_optional_string(value, field)?);
        }
    }
    if let Some(value) = object.get("fields") {
        patch.fields = Some(parse_fields(value)?);
    }
    Ok(patch)
}

fn parse_fields(value: &Value) -> Result<FieldsPatch, TeamError> {
    if value.is_null() {
        return Ok(FieldsPatch::Clear);
    }
    let object = value
        .as_object()
        .ok_or_else(|| TeamError::invalid("fields must be an object"))?;
    let mut fields = BTreeMap::new();
    for (key, value) in object {
        validate_field_key(key)?;
        let value = match value {
            Value::Null => None,
            Value::String(text) => {
                if text.chars().count() > MAX_FIELD_VALUE_CHARS {
                    return Err(TeamError::invalid(format!(
                        "field {key} is longer than 120 characters"
                    )));
                }
                Some(text.clone())
            }
            _ => {
                return Err(TeamError::invalid(format!(
                    "field {key} must be a string or null"
                )))
            }
        };
        fields.insert(key.clone(), value);
    }
    Ok(FieldsPatch::Merge(fields))
}

fn apply_fields(
    target: &mut Option<BTreeMap<String, String>>,
    patch: FieldsPatch,
) -> Result<(), TeamError> {
    match patch {
        FieldsPatch::Clear => {
            *target = None;
            Ok(())
        }
        FieldsPatch::Merge(changes) => {
            let mut fields = target.take().unwrap_or_default();
            for (key, value) in changes {
                match value {
                    Some(value) => {
                        fields.insert(key, value);
                    }
                    None => {
                        fields.remove(&key);
                    }
                }
            }
            if fields.len() > MAX_FIELDS {
                return Err(TeamError::invalid("fields has more than 12 entries"));
            }
            *target = if fields.is_empty() {
                None
            } else {
                Some(fields)
            };
            Ok(())
        }
    }
}

fn parse_ids(value: Option<&Value>, field: &str) -> Result<Vec<String>, TeamError> {
    let Some(value) = value else {
        return Ok(Vec::new());
    };
    if value.is_null() {
        return Ok(Vec::new());
    }
    let Value::Array(items) = value else {
        return Err(TeamError::invalid(format!("{field} must be an array")));
    };
    let mut ids = Vec::new();
    for item in items {
        let Some(id) = item.as_str() else {
            return Err(TeamError::invalid(format!("{field} must contain strings")));
        };
        validate_id(id)?;
        ids.push(id.to_string());
    }
    Ok(ids)
}

fn validate_id(id: &str) -> Result<(), TeamError> {
    let bytes = id.as_bytes();
    if bytes.is_empty() || bytes.len() > 32 {
        return Err(TeamError::invalid(
            "card id must match [A-Za-z0-9][A-Za-z0-9_.-]{0,31}",
        ));
    }
    if !bytes[0].is_ascii_alphanumeric() {
        return Err(TeamError::invalid(
            "card id must match [A-Za-z0-9][A-Za-z0-9_.-]{0,31}",
        ));
    }
    if !bytes
        .iter()
        .all(|byte| byte.is_ascii_alphanumeric() || matches!(byte, b'_' | b'.' | b'-'))
    {
        return Err(TeamError::invalid(
            "card id must match [A-Za-z0-9][A-Za-z0-9_.-]{0,31}",
        ));
    }
    Ok(())
}

fn validate_field_key(key: &str) -> Result<(), TeamError> {
    if key.is_empty() || key.chars().count() > MAX_FIELD_KEY_CHARS {
        return Err(TeamError::invalid("field keys must be 1..32 characters"));
    }
    Ok(())
}

// -- methods on the team registry ------------------------------------------

impl Teams {
    fn team_board(&self, team_id: &str) -> Result<&Team, TeamError> {
        self.team(team_id)
            .ok_or_else(|| TeamError::unknown("unknown team"))
    }

    pub fn board(&self, team_id: &str) -> Result<Value, TeamError> {
        let team = self.team_board(team_id)?;
        Ok(json!({ "board": team.board.to_json() }))
    }

    pub fn card_history(&self, team_id: &str, card: &str) -> Result<Value, TeamError> {
        let team = self.team_board(team_id)?;
        if team.board.card(card).is_none() {
            return Err(TeamError::invalid(format!("unknown card {card}")));
        }
        Ok(json!({ "versions": team.board.history_of(card) }))
    }

    pub fn board_update(
        &mut self,
        team_id: &str,
        params: &Value,
        now: u64,
    ) -> Result<u64, TeamError> {
        let team = self
            .teams
            .get_mut(team_id)
            .ok_or_else(|| TeamError::unknown("unknown team"))?;
        if team.closed {
            return Err(TeamError::unknown("team closed"));
        }
        // 19.12: a card may be assigned to a name awaiting approval, so an
        // open spawn item's name is a valid owner until it is answered.
        let mut owners: HashSet<String> =
            team.workers().map(|worker| worker.name.clone()).collect();
        owners.extend(
            team.inbox
                .iter()
                .filter(|item| {
                    item.kind == super::ItemKind::Spawn && item.state == super::ItemState::Open
                })
                .filter_map(|item| item.name.clone()),
        );
        team.board.apply_leader(params, &owners, now)
    }

    /// Step 4 of `team.start` (19.7): write the workflow onto an unnamed board.
    /// Returns the new rev when something was written.
    pub fn start_board_workflow(
        &mut self,
        team_id: &str,
        workflow: &super::workflow::Workflow,
    ) -> Result<Option<u64>, TeamError> {
        let team = self
            .teams
            .get_mut(team_id)
            .ok_or_else(|| TeamError::unknown("unknown team"))?;
        if team.closed {
            return Err(TeamError::unknown("team closed"));
        }
        team.board
            .apply_workflow(&workflow.name, &workflow.text, workflow.columns.as_deref())
    }

    pub fn card_update(
        &mut self,
        team_id: &str,
        owner: &str,
        params: &Value,
        now: u64,
    ) -> Result<u64, TeamError> {
        let team = self
            .teams
            .get_mut(team_id)
            .ok_or_else(|| TeamError::unknown("unknown team"))?;
        if team.closed {
            return Err(TeamError::unknown("team closed"));
        }
        team.board.apply_worker(owner, params, now)
    }

    /// Prefix `body` with the card summary line and default `task` to the card
    /// id (19.3).
    pub fn card_message(
        &self,
        team_id: &str,
        card: &str,
        body: &str,
        task: Option<&str>,
    ) -> Result<(String, Option<String>), TeamError> {
        let team = self.team_board(team_id)?;
        let card = team
            .board
            .card(card)
            .ok_or_else(|| TeamError::invalid(format!("unknown card {card}")))?;
        let line = Board::summary_line(card);
        let task = task.map(str::to_string).or_else(|| Some(card.id.clone()));
        Ok((format!("{line}\n{body}"), task))
    }

    /// Persist the board if it changed since the last write. Clears a pending
    /// worker flush.
    pub fn take_board_persist(&mut self, team_id: &str, now: u64) -> Option<BoardPersist> {
        let team = self.teams.get_mut(team_id)?;
        team.board_flush_at = None;
        team.board.take_persist(now)
    }

    /// Teams whose worker coalescing timer has fired.
    pub fn due_board_flushes(&self, now: u64) -> Vec<String> {
        self.teams
            .values()
            .filter(|team| team.board_flush_at.is_some_and(|at| at <= now))
            .map(|team| team.id.clone())
            .collect()
    }

    /// Teams with an in-memory write not persisted yet.
    pub fn pending_boards(&self) -> Vec<String> {
        self.teams
            .values()
            .filter(|team| team.board.is_dirty())
            .map(|team| team.id.clone())
            .collect()
    }

    /// Mark a team's board unreadable after a database error. The row is left
    /// untouched and writes are refused from now on.
    pub fn mark_board_unavailable(&mut self, team_id: &str) {
        if let Some(team) = self.teams.get_mut(team_id) {
            team.board = Board::unavailable();
            team.board_flush_at = None;
        }
    }

    pub fn restore_board(
        &mut self,
        team_id: &str,
        rev: u64,
        json: &str,
        rows: Vec<(String, String, i64)>,
    ) -> Result<(), String> {
        let board = match Board::from_stored(rev, json, rows) {
            Ok(board) => board,
            Err(error) => {
                if let Some(team) = self.teams.get_mut(team_id) {
                    team.board = Board::unavailable();
                    team.board_flush_at = None;
                }
                return Err(error);
            }
        };
        if let Some(team) = self.teams.get_mut(team_id) {
            team.board = board;
            team.board_flush_at = None;
        }
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn workers(names: &[&str]) -> HashSet<String> {
        names.iter().map(|name| name.to_string()).collect()
    }

    fn board_with(columns: &[&str], cards: &[(&str, &str, &str, Option<&str>)]) -> Board {
        Board {
            columns: columns.iter().map(|column| column.to_string()).collect(),
            cards: cards
                .iter()
                .map(|(id, title, column, owner)| Card {
                    id: id.to_string(),
                    title: title.to_string(),
                    column: column.to_string(),
                    owner: owner.map(str::to_string),
                    stage: None,
                    body: None,
                    fields: None,
                    archived: false,
                    updated_by: "leader".to_string(),
                    updated_at: 0,
                })
                .collect(),
            ..Board::default()
        }
    }

    fn leader(board: &mut Board, params: Value) -> Result<u64, TeamError> {
        board.apply_leader(&params, &workers(&["w1", "w2"]), 100)
    }

    fn worker(board: &mut Board, owner: &str, params: Value) -> Result<u64, TeamError> {
        board.apply_worker(owner, &params, 200)
    }

    #[test]
    fn leader_upserts_merges_and_clears_null_fields() {
        let mut board = board_with(&["todo", "doing"], &[]);
        let rev = leader(
            &mut board,
            json!({"upsert": [{
                "id": "T1", "title": "one", "column": "todo", "owner": "w1",
                "stage": "S1", "body": "b", "fields": {"branch": "ade/w1"}
            }]}),
        )
        .expect("create");
        assert_eq!(rev, 1);
        let card = board.card("T1").expect("card");
        assert_eq!(card.owner.as_deref(), Some("w1"));
        assert_eq!(card.updated_by, "leader");
        assert_eq!(card.updated_at, 100);

        let rev = leader(
            &mut board,
            json!({"upsert": [{"id": "T1", "owner": null, "stage": null, "body": null,
                "fields": {"branch": null, "tests": "42"}}]}),
        )
        .expect("merge");
        assert_eq!(rev, 2);
        let card = board.card("T1").expect("card");
        assert_eq!(card.owner, None);
        assert_eq!(card.stage, None);
        assert_eq!(card.body, None);
        assert_eq!(
            card.fields.as_ref().and_then(|fields| fields.get("tests")),
            Some(&"42".to_string())
        );
        assert!(card
            .fields
            .as_ref()
            .is_some_and(|fields| !fields.contains_key("branch")));
        assert_eq!(card.title, "one", "absent fields are kept");
    }

    #[test]
    fn leader_applies_workflow_columns_upsert_archive_remove_in_order() {
        let mut board = board_with(&[], &[]);
        leader(
            &mut board,
            json!({"workflow_name": "default", "workflow": "text"}),
        )
        .expect("workflow");
        leader(&mut board, json!({"columns": ["todo"]})).expect("columns");
        leader(
            &mut board,
            json!({"upsert": [{"id": "T1", "title": "one", "column": "todo"}]}),
        )
        .expect("card");
        // columns will be removed after archive; the card is archived by then.
        leader(&mut board, json!({"columns": [], "archive": ["T1"]}))
            .expect("archive and clear columns");
        assert!(board.card("T1").expect("card").archived);

        let rev = leader(&mut board, json!({"remove": ["T1"]})).expect("remove");
        assert_eq!(rev, 5);
        assert!(board.card("T1").is_none());
        assert_eq!(board.workflow_name.as_deref(), Some("default"));
        assert_eq!(board.workflow.as_deref(), Some("text"));
    }

    #[test]
    fn leader_rejects_unknown_ids_duplicates_and_unknown_columns_atomically() {
        let mut board = board_with(&["todo"], &[("T1", "one", "todo", None)]);
        let before = board.to_json();
        for params in [
            json!({"archive": ["missing"]}),
            json!({"remove": ["missing"]}),
            json!({"upsert": [{"id": "T2", "title": "two", "column": "todo"}], "remove": ["T2"]}),
            json!({"upsert": [{"id": "T2", "title": "two", "column": "todo"},
                              {"id": "T2", "title": "three", "column": "todo"}]}),
            json!({"columns": []}),
            json!({"upsert": [{"id": "T1", "title": "x", "column": "nope"}]}),
        ] {
            let result = leader(&mut board, params.clone());
            assert!(result.is_err(), "accepted {params}");
            assert_eq!(board.to_json(), before, "board changed by {params}");
        }
        assert_eq!(board.rev, 0, "a refused write does not bump rev");
    }

    #[test]
    fn leader_validates_card_fields_and_ownership() {
        let mut board = board_with(&["todo"], &[]);
        for (params, mention) in [
            (
                json!({"upsert": [{"id": "", "title": "x", "column": "todo"}]}),
                "card id",
            ),
            (
                json!({"upsert": [{"id": "_x", "title": "x", "column": "todo"}]}),
                "card id",
            ),
            (
                json!({"upsert": [{"id": "T1", "title": "", "column": "todo"}]}),
                "title",
            ),
            (
                json!({"upsert": [{"id": "T1", "title": "x", "column": "todo",
                                 "owner": "nobody"}]}),
                "not a worker",
            ),
            (
                json!({"upsert": [{"id": "T1", "title": "x", "column": "todo",
                                 "stage": ""}]}),
                "stage",
            ),
            (
                json!({"upsert": [{"id": "T1", "title": "x", "column": "todo",
                                 "body": "x".repeat(MAX_CARD_BODY_BYTES + 1)}]}),
                "body",
            ),
            (
                json!({"upsert": [{"id": "T1", "title": "x", "column": "todo",
                                 "fields": {"a": "x".repeat(121)}}]}),
                "field",
            ),
            (json!({"columns": ["a", "a"]}), "duplicate column"),
            (json!({"columns": [""]}), "column title"),
            (
                json!({"columns": (0..17).map(|n| format!("c{n}")).collect::<Vec<_>>()}),
                "columns",
            ),
            (
                json!({"workflow": "x".repeat(MAX_WORKFLOW_BYTES + 1)}),
                "workflow",
            ),
            (
                json!({"upsert": [{"id": "T1", "title": "x", "column": "todo",
                                 "archived": false}]}),
                "archived",
            ),
            (
                json!({"upsert": [{"id": "T1", "title": "x", "column": "todo",
                                 "updated_by": "leader"}]}),
                "updated_by",
            ),
        ] {
            let error = leader(&mut board, params.clone()).expect_err(&format!("{params}"));
            assert!(
                error.message.contains(mention),
                "{params}: {}",
                error.message
            );
            assert_eq!(board.rev, 0);
        }
    }

    #[test]
    fn worker_permission_matrix() {
        let mut board = board_with(
            &["todo"],
            &[
                ("T1", "one", "todo", Some("w1")),
                ("T2", "two", "todo", Some("w2")),
                ("T3", "three", "todo", None),
            ],
        );
        for params in [
            json!({"card": "T2", "body": "x"}),
            json!({"card": "T2", "fields": {"a": "b"}}),
            json!({"card": "T2", "archive": true}),
        ] {
            let error = worker(&mut board, "w1", params.clone()).expect_err(&format!("{params}"));
            assert_eq!(error.code, super::super::NOT_ALLOWED, "{params}");
            assert_eq!(error.message, "not your card", "{params}");
        }
        let error = worker(&mut board, "w1", json!({"card": "missing", "body": "x"}))
            .expect_err("unknown card");
        assert_eq!(error.code, super::super::INVALID_TEAM_PARAM);
        let error = worker(&mut board, "w1", json!({"card": "T1", "archive": false}))
            .expect_err("archive false");
        assert_eq!(error.code, super::super::INVALID_TEAM_PARAM);
        assert!(error.message.contains("archive"), "{}", error.message);
        // The owner may write body, merge fields and archive its own card.
        worker(
            &mut board,
            "w1",
            json!({"card": "T1", "body": "mine", "fields": {"a": "b"}}),
        )
        .expect("owner write");
        let card = board.card("T1").expect("card");
        assert_eq!(card.body.as_deref(), Some("mine"));
        assert_eq!(card.updated_by, "w1");
        assert_eq!(card.updated_at, 200);
        worker(&mut board, "w1", json!({"card": "T1", "archive": true})).expect("archive");
        assert!(board.card("T1").expect("card").archived);
        // An archived card cannot be written even by its owner.
        let error =
            worker(&mut board, "w1", json!({"card": "T1", "body": "x"})).expect_err("archived");
        assert_eq!(error.code, super::super::NOT_ALLOWED);
    }

    #[test]
    fn non_owner_worker_cannot_write_any_field() {
        let mut board = board_with(&["todo"], &[("T1", "one", "todo", Some("w1"))]);
        for params in [
            json!({"card": "T1", "body": "x"}),
            json!({"card": "T1", "fields": {"k": "v"}}),
            json!({"card": "T1", "archive": true}),
        ] {
            let error = worker(&mut board, "w2", params.clone()).expect_err(&format!("{params}"));
            assert_eq!(error.code, super::super::NOT_ALLOWED);
            assert_eq!(error.message, "not your card");
        }
        assert_eq!(board.rev, 0);
    }

    #[test]
    fn upserting_an_archived_card_is_not_allowed() {
        let mut board = board_with(&["todo"], &[("T1", "one", "todo", Some("w1"))]);
        board.cards[0].archived = true;
        let error = leader(&mut board, json!({"upsert": [{"id": "T1", "body": "x"}]}))
            .expect_err("archived");
        assert_eq!(error.code, super::super::NOT_ALLOWED);
    }

    #[test]
    fn card_and_column_limits() {
        let mut board = board_with(&["todo"], &[]);
        for n in 0..MAX_COLUMNS {
            board.columns.push(format!("c{n}"));
        }
        let error = leader(
            &mut board,
            json!({"columns": (0..=MAX_COLUMNS).map(|n| format!("c{n}")).collect::<Vec<_>>()}),
        )
        .expect_err("columns");
        assert!(error.message.contains("16"));

        let mut board = board_with(&["todo"], &[]);
        let cards: Vec<Value> = (0..=MAX_CARDS)
            .map(|n| json!({"id": format!("T{n}"), "title": "x", "column": "todo"}))
            .collect();
        let error = leader(&mut board, json!({"upsert": cards})).expect_err("cards");
        assert!(error.message.contains("200"));
    }

    #[test]
    fn more_than_500_archived_cards_drop_the_oldest() {
        let mut board = board_with(&["todo"], &[]);
        for n in 0..501 {
            board.cards.push(Card {
                id: format!("A{n}"),
                title: "archived".to_string(),
                column: "todo".to_string(),
                owner: None,
                stage: Some("S".to_string()),
                body: None,
                fields: None,
                archived: true,
                updated_by: "leader".to_string(),
                updated_at: n,
            });
        }
        leader(&mut board, json!({"workflow_name": "x"})).expect("write");
        let archived: Vec<&Card> = board.cards.iter().filter(|card| card.archived).collect();
        assert_eq!(archived.len(), MAX_ARCHIVED);
        assert!(board.card("A0").is_none(), "oldest archived card dropped");
        assert!(board.card("A500").is_some());
    }

    #[test]
    fn board_size_limit() {
        let mut board = board_with(&["todo"], &[]);
        let body = "x".repeat(MAX_CARD_BODY_BYTES);
        let mut cards = Vec::new();
        for n in 0..40 {
            cards
                .push(json!({"id": format!("T{n}"), "title": "x", "column": "todo", "body": body}));
        }
        let error = leader(&mut board, json!({"upsert": cards})).expect_err("size");
        assert!(error.message.contains("256 KiB"));
    }

    #[test]
    fn history_keeps_twenty_and_clears_on_archive() {
        let mut board = board_with(&["todo"], &[]);
        leader(
            &mut board,
            json!({"upsert": [{"id": "T1", "title": "v0", "column": "todo", "owner": "w1"}]}),
        )
        .expect("create");
        board.take_persist(0).expect("first persist");
        for n in 1..=25 {
            worker(
                &mut board,
                "w1",
                json!({"card": "T1", "body": format!("v{n}")}),
            )
            .expect("write");
            board.take_persist(n as u64).expect("persist");
        }
        let versions = board.history_of("T1");
        assert_eq!(versions.len(), HISTORY_VERSIONS);
        assert_eq!(versions[0].body.as_deref(), Some("v24"), "newest first");
        assert_eq!(versions[19].body.as_deref(), Some("v5"));
        // Coalesced worker writes only store the previously persisted version.
        let before = board.card("T1").cloned().expect("card");
        worker(&mut board, "w1", json!({"card": "T1", "body": "a"})).expect("a");
        worker(&mut board, "w1", json!({"card": "T1", "body": "b"})).expect("b");
        board.take_persist(100).expect("coalesced persist");
        let versions = board.history_of("T1");
        assert_eq!(
            versions[0], before,
            "only the last persisted version is stored"
        );
        assert_eq!(versions.len(), HISTORY_VERSIONS);
        // Archiving clears the history and a persisted diff clears the rows.
        worker(&mut board, "w1", json!({"card": "T1", "archive": true})).expect("archive");
        assert!(board.history_of("T1").is_empty());
        let persist = board.take_persist(101).expect("archive persist");
        assert!(persist.cleared.contains(&"T1".to_string()));
    }

    #[test]
    fn removing_a_card_clears_its_history() {
        let mut board = board_with(&["todo"], &[("T1", "one", "todo", Some("w1"))]);
        leader(&mut board, json!({"workflow_name": "x"})).expect("persist");
        board.take_persist(0).expect("first");
        worker(&mut board, "w1", json!({"card": "T1", "body": "x"})).expect("write");
        board.take_persist(1).expect("second");
        leader(&mut board, json!({"remove": ["T1"]})).expect("remove");
        let persist = board.take_persist(2).expect("remove persist");
        assert!(persist.cleared.contains(&"T1".to_string()));
        assert!(persist.history.is_empty());
    }

    #[test]
    fn summary_line_format_and_truncation() {
        let mut fields = BTreeMap::new();
        fields.insert("z".to_string(), "last".to_string());
        fields.insert("a".to_string(), "first".to_string());
        let card = Card {
            id: "T3".to_string(),
            title: "fix\nreconnect".to_string(),
            column: "review".to_string(),
            owner: None,
            stage: None,
            body: Some("long body".to_string()),
            fields: Some(fields),
            archived: false,
            updated_by: "w1".to_string(),
            updated_at: 1,
        };
        let line = Board::summary_line(&card);
        assert_eq!(
            line,
            "[card T3 · fix reconnect · review · - · a=first · z=last]"
        );
        let long = Card {
            title: "x".repeat(500),
            ..card
        };
        assert_eq!(
            Board::summary_line(&long).chars().count(),
            MAX_SUMMARY_CHARS
        );
    }

    #[test]
    fn status_is_the_leader_outline_and_stages_follow_card_order() {
        let mut board = board_with(&["todo"], &[]);
        leader(
            &mut board,
            json!({"upsert": [
                {"id": "T1", "title": "one", "column": "todo", "owner": "w1", "stage": "S1"},
                {"id": "T2", "title": "two", "column": "todo", "stage": "S2"},
                {"id": "T3", "title": "three", "column": "todo", "stage": "S1"}
            ]}),
        )
        .expect("cards");
        leader(&mut board, json!({"archive": ["T2", "T3"]})).expect("archive");
        let status = board.status();
        assert_eq!(status["rev"], 2);
        assert_eq!(status["cards"].as_array().map(Vec::len), Some(1));
        assert_eq!(status["cards"][0]["id"], "T1");
        assert_eq!(status["archived"]["S1"], 1);
        assert_eq!(status["archived"]["S2"], 1);
        let stages = board.stages();
        assert_eq!(
            stages,
            json!([
                {"stage": "S1", "open": 1, "archived": 1},
                {"stage": "S2", "open": 0, "archived": 1}
            ])
        );
    }

    #[test]
    fn restore_keeps_rev_and_history() {
        let mut board = board_with(&["todo"], &[("T1", "one", "todo", Some("w1"))]);
        leader(&mut board, json!({"workflow_name": "x"})).expect("write");
        let persist = board.take_persist(0).expect("persist");
        worker(&mut board, "w1", json!({"card": "T1", "body": "v1"})).expect("write");
        let later = board.take_persist(1).expect("persist");
        assert_eq!(later.history.len(), 1);
        let rows: Vec<(String, String, i64)> = later
            .history
            .iter()
            .map(|(id, json, rev, _)| (id.clone(), json.clone(), *rev))
            .collect();
        let restored = Board::from_stored(later.rev, &later.json, rows).expect("stored board");
        assert_eq!(restored.rev, later.rev);
        assert!(!restored.is_dirty());
        assert_eq!(restored.history_of("T1").len(), 1);
        assert_eq!(restored.history_of("T1")[0].title, "one");
        assert_eq!(persist.rev + 1, later.rev);
    }

    #[test]
    fn an_unreadable_stored_board_is_read_only() {
        assert!(Board::from_stored(1, "not json", Vec::new()).is_err());
        let mut board = Board::unavailable();
        let error = leader(&mut board, json!({})).expect_err("read-only board");
        assert_eq!(error.code, super::super::NOT_ALLOWED);
        assert!(error.message.contains("unavailable"));
        let error = worker(&mut board, "w1", json!({"card": "T1"})).expect_err("read-only");
        assert_eq!(error.code, super::super::NOT_ALLOWED);
        assert!(board.take_persist(0).is_none());
        assert!(!board.is_dirty());
        assert_eq!(board.to_json()["unavailable"], true);
        assert_eq!(board.status()["unavailable"], true);
        // 19.7 step 4: an unavailable board is skipped, not an error.
        assert_eq!(
            board.apply_workflow("flow", "text", None).expect("skip"),
            None
        );
        assert_eq!(board.rev, 0);
    }

    #[test]
    fn rev_increases_even_when_nothing_changed() {
        let mut board = board_with(&["todo"], &[("T1", "one", "todo", Some("w1"))]);
        let rev = leader(&mut board, json!({})).expect("no-op leader write");
        assert_eq!(rev, 1);
        let rev = worker(&mut board, "w1", json!({"card": "T1"})).expect("no-op worker write");
        assert_eq!(rev, 2);
    }
}
