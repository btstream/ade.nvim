//! Server-side permission policy (PROTOCOL.md section 17).
//!
//! The rules are data: the service decides agent-to-client
//! `session/request_permission` requests itself when a rule the front end
//! installed matches, whether or not a front end is attached. Everything here
//! mirrors the Lua policies in `lua/ade/app/permissions.lua` and
//! `lua/ade/inline/` — the shape and the order of the checks are normative.

use std::path::{Component, Path, PathBuf};

use serde_json::{json, Map, Value};

/// Invalid rule set (PROTOCOL.md 17.5).
pub const INVALID_RULE_SET: i64 = -32050;
/// Maximum number of sets the service keeps.
pub const MAX_SETS: usize = 256;
/// Maximum number of rules in one set.
pub const MAX_RULES: usize = 64;
/// Logged `toolCall` fields are omitted above this encoded size (17.4).
pub const LOG_TOOL_CALL_LIMIT: usize = 64 * 1024;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum OptionKind {
    AllowOnce,
    AllowAlways,
    RejectOnce,
    RejectAlways,
}

impl OptionKind {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::AllowOnce => "allow_once",
            Self::AllowAlways => "allow_always",
            Self::RejectOnce => "reject_once",
            Self::RejectAlways => "reject_always",
        }
    }

    fn parse(value: &str) -> Option<Self> {
        match value {
            "allow_once" => Some(Self::AllowOnce),
            "allow_always" => Some(Self::AllowAlways),
            "reject_once" => Some(Self::RejectOnce),
            "reject_always" => Some(Self::RejectAlways),
            _ => None,
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Keep {
    Connection,
    Service,
}

/// One listed path: a `..` component makes it never match (17.2 step 3).
#[derive(Debug, Clone)]
struct ListedPath {
    path: PathBuf,
    never: bool,
}

#[derive(Debug, Clone)]
pub struct Rule {
    kinds: Option<Vec<String>>,
    paths: Option<Vec<ListedPath>>,
    paths_under: Option<Vec<ListedPath>>,
    choose: Vec<OptionKind>,
    pick_offered: bool,
}

#[derive(Debug, Clone)]
struct Binding {
    conn: u64,
    instance: String,
    session: String,
}

#[derive(Debug, Clone)]
pub struct RuleSet {
    pub name: String,
    priority: i64,
    session: Option<String>,
    agent: Option<String>,
    until_turn_end: bool,
    keep: Keep,
    fallback_cancelled: bool,
    allow_always: bool,
    cwd: Option<PathBuf>,
    rules: Vec<Rule>,
    owner: Option<u64>,
    installed_at: i64,
    installed_seq: u64,
    bound: Option<Binding>,
    cancelling: bool,
}

/// The outcome the service answers the agent with.
#[derive(Debug, Clone, PartialEq)]
pub struct Decision {
    pub set: String,
    pub option_id: Option<String>,
    pub kind: Option<String>,
    pub cancelled: bool,
    pub cancelling: bool,
}

impl Decision {
    /// The JSON-RPC `result` body for the agent.
    pub fn result(&self) -> Value {
        match (&self.option_id, self.cancelled) {
            (Some(option_id), false) => {
                json!({"outcome": {"outcome": "selected", "optionId": option_id}})
            }
            _ => json!({"outcome": {"outcome": "cancelled"}}),
        }
    }
}

#[derive(Debug, Default)]
pub struct Policy {
    sets: Vec<RuleSet>,
    next_seq: u64,
}

impl Policy {
    pub fn new() -> Self {
        Self::default()
    }

    pub fn is_empty(&self) -> bool {
        self.sets.is_empty()
    }

    /// Install (or replace) one set. Validation failure installs nothing.
    pub fn install(&mut self, value: &Value, conn: u64, now: i64) -> Result<(), String> {
        let mut set = parse_set(value, conn, now)?;
        if !self.sets.iter().any(|existing| existing.name == set.name)
            && self.sets.len() >= MAX_SETS
        {
            return Err(format!("too many rule sets (maximum {MAX_SETS})"));
        }
        self.next_seq += 1;
        set.installed_seq = self.next_seq;
        if let Some(index) = self
            .sets
            .iter()
            .position(|existing| existing.name == set.name)
        {
            self.sets[index] = set;
        } else {
            self.sets.push(set);
        }
        Ok(())
    }

    /// `policy.clear`: returns whether a set was removed.
    pub fn clear(&mut self, name: &str) -> bool {
        let before = self.sets.len();
        self.sets.retain(|set| set.name != name);
        before != self.sets.len()
    }

    pub fn list(&self) -> Vec<Value> {
        self.sets
            .iter()
            .map(|set| {
                let owner = if set.keep == Keep::Service {
                    Value::Null
                } else {
                    set.owner.map_or(Value::Null, |conn| json!(conn))
                };
                json!({
                    "name": set.name,
                    "priority": set.priority,
                    "session": set.session.clone(),
                    "agent": set.agent.clone(),
                    "until": if set.until_turn_end { json!("turn_end") } else { Value::Null },
                    "keep": if set.keep == Keep::Service { "service" } else { "connection" },
                    "fallback": if set.fallback_cancelled { json!("cancelled") } else { Value::Null },
                    "allow_always": set.allow_always,
                    "cwd": set.cwd.as_ref().map(|cwd| cwd.display().to_string()),
                    "owner": owner,
                    "installed_at": set.installed_at,
                    "bound": set.until_turn_end && set.bound.is_some(),
                })
            })
            .collect()
    }

    /// Info the hub needs to bind a freshly installed set to a running prompt.
    pub fn pending_binding(&self, name: &str) -> Option<(String, Option<String>)> {
        self.sets
            .iter()
            .find(|set| set.name == name)
            .and_then(|set| {
                if set.until_turn_end && set.bound.is_none() {
                    Some((set.session.clone().unwrap_or_default(), set.agent.clone()))
                } else {
                    None
                }
            })
    }

    /// Bind a set to the prompt that was already running when it was installed.
    pub fn bind(&mut self, name: &str, conn: u64, instance: &str, session: &str) {
        if let Some(set) = self.sets.iter_mut().find(|set| set.name == name) {
            if set.until_turn_end && set.bound.is_none() && set.session.as_deref() == Some(session)
            {
                set.bound = Some(Binding {
                    conn,
                    instance: instance.to_string(),
                    session: session.to_string(),
                });
                set.cancelling = false;
            }
        }
    }

    /// A prompt from `conn` started: bind every waiting turn_end set for it.
    pub fn on_prompt(&mut self, conn: u64, instance: &str, session: &str, agent: &str) {
        for set in &mut self.sets {
            if !set.until_turn_end || set.bound.is_some() {
                continue;
            }
            if set.owner != Some(conn) || set.session.as_deref() != Some(session) {
                continue;
            }
            if set.agent.as_deref().is_some_and(|filter| filter != agent) {
                continue;
            }
            set.bound = Some(Binding {
                conn,
                instance: instance.to_string(),
                session: session.to_string(),
            });
            set.cancelling = false;
        }
    }

    /// The instance exited: a bound prompt can never be answered, so its
    /// turn_end sets are removed (17.3).
    pub fn instance_exited(&mut self, instance: &str) {
        self.sets.retain(|set| {
            !(set.until_turn_end
                && set
                    .bound
                    .as_ref()
                    .is_some_and(|bound| bound.instance == instance))
        });
    }

    /// Prompt answered: its turn_end sets are removed (17.3).
    pub fn prompt_finished(&mut self, conn: u64, session: &str) {
        self.sets.retain(|set| {
            !(set.until_turn_end
                && set
                    .bound
                    .as_ref()
                    .is_some_and(|bound| bound.conn == conn && bound.session == session))
        });
    }

    /// `session/cancel` was forwarded: every active turn_end set of the session
    /// becomes cancelling.
    pub fn on_cancel(&mut self, session: &str) {
        for set in &mut self.sets {
            if set.until_turn_end
                && set
                    .bound
                    .as_ref()
                    .is_some_and(|bound| bound.session == session)
            {
                set.cancelling = true;
            }
        }
    }

    /// The connection closed: drop its connection-owned sets, but keep a bound
    /// turn_end set until its prompt ends.
    pub fn connection_closed(&mut self, conn: u64) {
        self.sets.retain(|set| {
            set.keep == Keep::Service
                || (set.until_turn_end && set.bound.is_some())
                || set.owner != Some(conn)
        });
    }

    /// Decide one permission request, or `None` to relay it.
    pub fn decide(
        &self,
        params: &Value,
        agent: &str,
        instance: &str,
        windows: bool,
    ) -> Option<Decision> {
        if is_question(params) {
            return None;
        }
        let session = params.get("sessionId").and_then(Value::as_str);
        let tool = params.get("toolCall").cloned().unwrap_or_else(|| json!({}));
        let options = params
            .get("options")
            .and_then(Value::as_array)
            .cloned()
            .unwrap_or_default();
        let mut order: Vec<&RuleSet> = self
            .sets
            .iter()
            .filter(|set| {
                active(set)
                    && set.bound_instance(instance)
                    && set.session.as_deref().is_none_or(|id| Some(id) == session)
            })
            .filter(|set| set.agent.as_deref().is_none_or(|filter| filter == agent))
            .collect();
        order.sort_by(|left, right| {
            right
                .priority
                .cmp(&left.priority)
                .then_with(|| right.session.is_some().cmp(&left.session.is_some()))
                .then_with(|| right.installed_seq.cmp(&left.installed_seq))
        });

        // A cancelled turn must not keep acting on its rules: any active
        // cancelling set decides cancelled first.
        if let Some(set) = order.iter().find(|set| set.cancelling) {
            return Some(Decision {
                set: set.name.clone(),
                option_id: None,
                kind: None,
                cancelled: true,
                cancelling: true,
            });
        }

        for set in &order {
            for rule in &set.rules {
                if !rule.matches(&tool, set.cwd.as_deref(), windows) {
                    continue;
                }
                if let Some((option_id, kind)) = rule.choose(&options) {
                    return Some(Decision {
                        set: set.name.clone(),
                        option_id: Some(option_id),
                        kind: Some(kind.as_str().to_string()),
                        cancelled: false,
                        cancelling: false,
                    });
                }
            }
            if set.fallback_cancelled {
                return Some(Decision {
                    set: set.name.clone(),
                    option_id: None,
                    kind: None,
                    cancelled: true,
                    cancelling: false,
                });
            }
        }
        None
    }
}

fn active(set: &RuleSet) -> bool {
    !set.until_turn_end || set.bound.is_some()
}

impl RuleSet {
    fn bound_instance(&self, instance: &str) -> bool {
        !self.until_turn_end
            || self
                .bound
                .as_ref()
                .is_some_and(|bound| bound.instance == instance)
    }
}

/// A question is never answered by policy (17.2 step 1).
pub fn is_question(params: &Value) -> bool {
    let tool = params.get("toolCall").unwrap_or(&Value::Null);
    if tool.get("kind").and_then(Value::as_str) == Some("switch_mode") {
        return true;
    }
    if let Some(method) = tool
        .get("rawInput")
        .and_then(|raw| raw.get("method"))
        .and_then(Value::as_str)
    {
        if method == "select" || method == "confirm" {
            return true;
        }
    }
    let options = params
        .get("options")
        .and_then(Value::as_array)
        .cloned()
        .unwrap_or_default();
    if options.len() < 2 {
        return false;
    }
    let kind = |option: &Value| {
        option
            .get("kind")
            .and_then(Value::as_str)
            .unwrap_or("")
            .to_string()
    };
    let first = kind(&options[0]);
    options.iter().all(|option| kind(option) == first)
}

impl Rule {
    fn matches(&self, tool: &Value, cwd: Option<&Path>, windows: bool) -> bool {
        if let Some(kinds) = &self.kinds {
            let Some(kind) = tool.get("kind").and_then(Value::as_str) else {
                return false;
            };
            if !kinds.iter().any(|candidate| candidate == kind) {
                return false;
            }
        }
        if self.paths.is_some() || self.paths_under.is_some() {
            let Ok(paths) = request_paths(tool, cwd, windows) else {
                return false;
            };
            if paths.is_empty() {
                return false;
            }
            for path in paths {
                let mut passed = false;
                if let Some(listed) = &self.paths {
                    if listed
                        .iter()
                        .filter(|entry| !entry.never)
                        .any(|entry| path_matches(&entry.path, &path, windows))
                    {
                        passed = true;
                    }
                }
                if !passed {
                    if let Some(listed) = &self.paths_under {
                        if listed
                            .iter()
                            .filter(|entry| !entry.never)
                            .any(|entry| path_under(&entry.path, &path, windows))
                        {
                            passed = true;
                        }
                    }
                }
                if !passed {
                    return false;
                }
            }
        }
        true
    }

    /// The option this rule chooses, or `None` when none of its kinds is offered.
    fn choose(&self, options: &[Value]) -> Option<(String, OptionKind)> {
        let offered: Vec<(String, String, OptionKind)> = options
            .iter()
            .filter_map(|option| {
                let option_id = option.get("optionId").and_then(Value::as_str)?;
                let kind_text = option
                    .get("kind")
                    .and_then(Value::as_str)
                    .unwrap_or("")
                    .to_string();
                let kind = OptionKind::parse(&kind_text)?;
                Some((option_id.to_string(), kind_text, kind))
            })
            .collect();
        if self.pick_offered {
            return offered
                .into_iter()
                .find(|(_, _, kind)| self.choose.contains(kind))
                .map(|(id, _, kind)| (id, kind));
        }
        for wanted in &self.choose {
            if let Some((id, _, kind)) = offered.iter().find(|(_, _, kind)| kind == wanted) {
                return Some((id.clone(), *kind));
            }
        }
        None
    }
}

fn parse_set(value: &Value, conn: u64, now: i64) -> Result<RuleSet, String> {
    let object = value
        .as_object()
        .ok_or_else(|| "set must be an object".to_string())?;
    let name = object
        .get("name")
        .and_then(Value::as_str)
        .ok_or_else(|| "name must be a string".to_string())?;
    if name.is_empty() || name.len() > 128 || !name.bytes().all(valid_name_byte) {
        return Err("name must match [A-Za-z0-9_.:-]{1,128}".to_string());
    }
    let priority = match object.get("priority") {
        None | Some(Value::Null) => 0,
        Some(value) => value
            .as_i64()
            .ok_or_else(|| "priority must be an integer".to_string())?,
    };
    let session = optional_string(object, "session")?;
    let agent = optional_string(object, "agent")?;
    let until = optional_string(object, "until")?;
    if let Some(value) = &until {
        if value != "turn_end" {
            return Err("until must be \"turn_end\"".to_string());
        }
        if session.is_none() {
            return Err("until requires session".to_string());
        }
    }
    let keep = match optional_string(object, "keep")?.as_deref() {
        None | Some("connection") => Keep::Connection,
        Some("service") => Keep::Service,
        Some(other) => return Err(format!("keep must be connection or service, got {other}")),
    };
    let fallback = optional_string(object, "fallback")?;
    if let Some(value) = &fallback {
        if value != "cancelled" {
            return Err("fallback must be \"cancelled\"".to_string());
        }
    }
    let allow_always = match object.get("allow_always") {
        None | Some(Value::Null) => false,
        Some(value) => value
            .as_bool()
            .ok_or_else(|| "allow_always must be a boolean".to_string())?,
    };
    let cwd = match object.get("cwd") {
        None | Some(Value::Null) => None,
        Some(value) => {
            let raw = value
                .as_str()
                .ok_or_else(|| "cwd must be a string".to_string())?;
            Some(absolute_path(raw, "cwd")?)
        }
    };
    let rules = object
        .get("rules")
        .and_then(Value::as_array)
        .ok_or_else(|| "rules must be an array".to_string())?;
    if rules.len() > MAX_RULES {
        return Err(format!("rules has more than {MAX_RULES} entries"));
    }
    let mut parsed = Vec::with_capacity(rules.len());
    for (index, rule) in rules.iter().enumerate() {
        parsed.push(parse_rule(rule, index, allow_always)?);
    }
    Ok(RuleSet {
        name: name.to_string(),
        priority,
        session,
        agent,
        until_turn_end: until.is_some(),
        keep,
        fallback_cancelled: fallback.is_some(),
        allow_always,
        cwd,
        rules: parsed,
        owner: Some(conn),
        installed_at: now,
        installed_seq: 0,
        bound: None,
        cancelling: false,
    })
}

fn parse_rule(value: &Value, index: usize, allow_always: bool) -> Result<Rule, String> {
    let object = value
        .as_object()
        .ok_or_else(|| format!("rules[{index}] must be an object"))?;
    let field = |name: &str| format!("rules[{index}].{name}");
    let kinds = match object.get("kinds") {
        None | Some(Value::Null) => None,
        Some(value) => {
            let list = string_list(value, &field("kinds"))?;
            if list.is_empty() {
                return Err(format!("{} must not be empty", field("kinds")));
            }
            Some(list)
        }
    };
    let paths = match object.get("paths") {
        None | Some(Value::Null) => None,
        Some(value) => {
            let list = string_list(value, &field("paths"))?;
            if list.is_empty() {
                return Err(format!("{} must not be empty", field("paths")));
            }
            let mut out = Vec::with_capacity(list.len());
            for path in list {
                out.push(listed_path(&path, &field("paths"))?);
            }
            Some(out)
        }
    };
    let paths_under = match object.get("paths_under") {
        None | Some(Value::Null) => None,
        Some(value) => {
            let list = string_list(value, &field("paths_under"))?;
            if list.is_empty() {
                return Err(format!("{} must not be empty", field("paths_under")));
            }
            let mut out = Vec::with_capacity(list.len());
            for path in list {
                out.push(listed_path(&path, &field("paths_under"))?);
            }
            Some(out)
        }
    };
    let choose = object
        .get("choose")
        .ok_or_else(|| format!("{} is required", field("choose")))?;
    let choose_list = string_list(choose, &field("choose"))?;
    if choose_list.is_empty() {
        return Err(format!("{} must not be empty", field("choose")));
    }
    let mut choose = Vec::new();
    for kind in choose_list {
        let parsed = OptionKind::parse(&kind)
            .ok_or_else(|| format!("{} has an unknown option kind {kind}", field("choose")))?;
        if parsed == OptionKind::AllowAlways && !allow_always {
            return Err(format!(
                "{} contains allow_always but allow_always is not true",
                field("choose")
            ));
        }
        choose.push(parsed);
    }
    let pick_offered = match optional_string(object, "pick")?.as_deref() {
        None | Some("choose") => false,
        Some("offered") => true,
        Some(other) => {
            return Err(format!(
                "{} must be choose or offered, got {other}",
                field("pick")
            ))
        }
    };
    Ok(Rule {
        kinds,
        paths,
        paths_under,
        choose,
        pick_offered,
    })
}

fn valid_name_byte(byte: u8) -> bool {
    byte.is_ascii_alphanumeric() || matches!(byte, b'_' | b'.' | b':' | b'-')
}

fn optional_string(object: &Map<String, Value>, field: &str) -> Result<Option<String>, String> {
    match object.get(field) {
        None | Some(Value::Null) => Ok(None),
        Some(value) => value
            .as_str()
            .map(|text| Some(text.to_string()))
            .ok_or_else(|| format!("{field} must be a string")),
    }
}

fn string_list(value: &Value, field: &str) -> Result<Vec<String>, String> {
    let list = value
        .as_array()
        .ok_or_else(|| format!("{field} must be an array"))?;
    let mut out = Vec::with_capacity(list.len());
    for entry in list {
        let text = entry
            .as_str()
            .ok_or_else(|| format!("{field} must contain strings"))?;
        if text.contains('\0') {
            return Err(format!("{field} must not contain NUL"));
        }
        out.push(text.to_string());
    }
    Ok(out)
}

/// A path that must be absolute for the running platform.
pub fn absolute_path(raw: &str, field: &str) -> Result<PathBuf, String> {
    if raw.contains('\0') {
        return Err(format!("{field} must not contain NUL"));
    }
    if has_unc_prefix(raw, cfg!(windows)) {
        // A UNC path is absolute on Windows but never matches (17.2); keeping
        // it installed lets `policy.list` round-trip what the front end sent.
        if cfg!(windows) {
            return Ok(PathBuf::from(raw));
        }
        return Err(format!("{field} must be an absolute path"));
    }
    let Some(path) = normalize_path(raw, cfg!(windows)) else {
        return Err(format!("{field} must be an absolute path"));
    };
    Ok(PathBuf::from(path))
}

/// A rule path: absolute, but a `..` component makes it never match.
fn listed_path(raw: &str, field: &str) -> Result<ListedPath, String> {
    if has_parent_component(raw, cfg!(windows)) {
        if !is_absolute(raw, cfg!(windows)) {
            return Err(format!("{field} must be an absolute path"));
        }
        return Ok(ListedPath {
            path: PathBuf::from(raw),
            never: true,
        });
    }
    Ok(ListedPath {
        path: absolute_path(raw, field)?,
        never: false,
    })
}

/// Lexical normalisation used by the path rules.
///
/// `windows = true` treats `\` as a separator, lowercases the drive letter and
/// rejects UNC/`\\?\` paths (they never match, 17.2). It is a parameter so the
/// Windows rules can be unit-tested on any host.
pub fn normalize_path(raw: &str, windows: bool) -> Option<String> {
    if raw.is_empty() || raw.contains('\0') || has_unc_prefix(raw, windows) {
        return None;
    }
    let text = if windows {
        raw.replace('\\', "/")
    } else {
        raw.to_string()
    };
    let absolute = if windows {
        let bytes = text.as_bytes();
        if bytes.len() >= 3
            && bytes[0].is_ascii_alphabetic()
            && bytes[1] == b':'
            && bytes[2] == b'/'
        {
            true
        } else {
            text.starts_with('/')
        }
    } else {
        text.starts_with('/')
    };
    if !absolute {
        return None;
    }
    let (prefix, rest) = if windows {
        let bytes = text.as_bytes();
        if bytes.len() >= 2 && bytes[1] == b':' {
            (Some(text[..2].to_ascii_lowercase()), &text[2..])
        } else {
            (None, text.as_str())
        }
    } else {
        (None, text.as_str())
    };
    let mut parts: Vec<&str> = Vec::new();
    for component in rest.split('/') {
        match component {
            "" | "." => {}
            ".." => {
                parts.pop();
            }
            other => parts.push(other),
        }
    }
    let joined = parts.join("/");
    match prefix {
        Some(prefix) => Some(format!("{prefix}/{joined}")),
        None => Some(format!("/{joined}")),
    }
}

fn has_unc_prefix(raw: &str, windows: bool) -> bool {
    if !windows {
        return false;
    }
    raw.starts_with(r"\\") || raw.starts_with("//")
}

/// Paths named by one request, resolved and normalised. `Err` means an entry is
/// unusable: the rule with a path condition must not match (17.2 step 3).
fn request_paths(tool: &Value, cwd: Option<&Path>, windows: bool) -> Result<Vec<PathBuf>, ()> {
    let mut paths = Vec::new();
    let mut push = |value: Option<&Value>| -> Result<(), ()> {
        let text = value.and_then(Value::as_str).ok_or(())?;
        if text.is_empty()
            || text.contains('\0')
            || has_unc_prefix(text, windows)
            || has_parent_component(text, windows)
        {
            return Err(());
        }
        let joined = if is_absolute(text, windows) {
            text.to_string()
        } else {
            let cwd = cwd.ok_or(())?;
            let cwd_text = cwd.display().to_string();
            let separator = if cwd_text.ends_with('/') { "" } else { "/" };
            format!("{cwd_text}{separator}{text}")
        };
        let normalized = normalize_path(&joined, windows).ok_or(())?;
        paths.push(PathBuf::from(normalized));
        Ok(())
    };
    if let Some(locations) = tool.get("locations").and_then(Value::as_array) {
        for location in locations {
            push(location.get("path"))?;
        }
    }
    if let Some(content) = tool.get("content").and_then(Value::as_array) {
        for entry in content {
            if entry.get("type").and_then(Value::as_str) == Some("diff") {
                push(entry.get("path"))?;
            }
        }
    }
    Ok(paths)
}

fn has_parent_component(raw: &str, windows: bool) -> bool {
    if windows {
        raw.split(['/', '\\']).any(|part| part == "..")
    } else {
        raw.split('/').any(|part| part == "..")
    }
}

fn is_absolute(raw: &str, windows: bool) -> bool {
    if windows {
        let bytes = raw.as_bytes();
        (raw.starts_with('/')
            || (bytes.len() >= 3
                && bytes[0].is_ascii_alphabetic()
                && bytes[1] == b':'
                && (bytes[2] == b'/' || bytes[2] == b'\\')))
            && !has_unc_prefix(raw, windows)
    } else {
        raw.starts_with('/')
    }
}

/// `paths`: same file, regular, single link, same realpath.
fn path_matches(listed: &Path, request: &Path, windows: bool) -> bool {
    if has_unc_prefix(&listed.display().to_string(), windows)
        || has_unc_prefix(&request.display().to_string(), windows)
    {
        return false;
    }
    let Ok(metadata) = std::fs::symlink_metadata(request) else {
        return false;
    };
    if !metadata.is_file() || links(&metadata) > 1 {
        return false;
    }
    // Equality is by realpath, like the Lua `is_copy_path`; a symlinked
    // directory spelling is fine, a symlink or hard link is not.
    match (
        std::fs::canonicalize(listed),
        std::fs::canonicalize(request),
    ) {
        (Ok(left), Ok(right)) => same_path(&left, &right, windows),
        _ => false,
    }
}

/// `paths_under`: the realpath (or the nearest existing ancestor) is inside the
/// listed directory's realpath.
fn path_under(listed: &Path, request: &Path, windows: bool) -> bool {
    if has_unc_prefix(&listed.display().to_string(), windows)
        || has_unc_prefix(&request.display().to_string(), windows)
    {
        return false;
    }
    let Ok(directory) = std::fs::canonicalize(listed) else {
        return false;
    };
    let mut current = Some(request.to_path_buf());
    while let Some(path) = current {
        if let Ok(real) = std::fs::canonicalize(&path) {
            let real = strip_verbatim(&real);
            let directory = strip_verbatim(&directory);
            return same_path(&real, &directory, windows)
                || path_components_inside(&real, &directory, windows);
        }
        // A dangling symlink is not "a file not created yet": the write would
        // follow it outside the directory.
        match std::fs::symlink_metadata(&path) {
            Ok(metadata) => {
                if metadata.file_type().is_symlink() {
                    return false;
                }
                return false;
            }
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => {
                current = path.parent().map(Path::to_path_buf);
            }
            Err(_) => return false,
        }
    }
    false
}

fn same_path(left: &Path, right: &Path, windows: bool) -> bool {
    if !windows {
        return left == right;
    }
    let left = left.display().to_string();
    let right = right.display().to_string();
    match (drive_of(&left), drive_of(&right)) {
        (Some(left_drive), Some(right_drive)) => {
            left_drive.eq_ignore_ascii_case(right_drive) && left[2..] == right[2..]
        }
        _ => left == right,
    }
}

/// Windows canonicalize returns a `\\?\` verbatim path; compare without it.
fn strip_verbatim(path: &Path) -> PathBuf {
    let text = path.to_string_lossy();
    let stripped = text
        .strip_prefix(r"\\?\")
        .or_else(|| text.strip_prefix("//?/"));
    match stripped {
        Some(stripped) => PathBuf::from(stripped),
        None => path.to_path_buf(),
    }
}

fn drive_of(path: &str) -> Option<&str> {
    let bytes = path.as_bytes();
    if bytes.len() >= 2 && bytes[0].is_ascii_alphabetic() && bytes[1] == b':' {
        Some(&path[..1])
    } else {
        None
    }
}

fn path_components_inside(path: &Path, directory: &Path, windows: bool) -> bool {
    let components = |value: &Path| -> Vec<String> {
        value
            .components()
            .filter_map(|component| match component {
                Component::Normal(part) => Some(part.to_string_lossy().to_string()),
                Component::Prefix(prefix) => {
                    Some(prefix.as_os_str().to_string_lossy().to_ascii_lowercase())
                }
                _ => None,
            })
            .collect()
    };
    let path = components(path);
    let directory = components(directory);
    if path.len() <= directory.len() {
        return false;
    }
    path[..directory.len()]
        .iter()
        .zip(&directory)
        .enumerate()
        .all(|(index, (left, right))| {
            if windows && index == 0 && drive_of(left).is_some() {
                left.eq_ignore_ascii_case(right)
            } else {
                left == right
            }
        })
}

#[cfg(unix)]
fn links(metadata: &std::fs::Metadata) -> u64 {
    use std::os::unix::fs::MetadataExt;
    metadata.nlink()
}

#[cfg(not(unix))]
fn links(_metadata: &std::fs::Metadata) -> u64 {
    1
}

/// The event-log `update` for one decision (17.4). Large `toolCall` fields are
/// replaced, not the whole request.
pub fn log_update(decision: &Decision, tool_call: &Value) -> Value {
    let mut tool = tool_call.clone();
    if tool.to_string().len() > LOG_TOOL_CALL_LIMIT {
        if let Some(object) = tool.as_object_mut() {
            object.insert("rawInput".to_string(), json!("[omitted]"));
            object.insert("content".to_string(), json!("[omitted]"));
        }
    }
    json!({
        "sessionUpdate": "_ade_policy",
        "set": decision.set.clone(),
        "outcome": if decision.cancelled { "cancelled" } else { "selected" },
        "optionId": decision.option_id.clone(),
        "kind": decision.kind.clone(),
        "toolCall": tool,
    })
}

/// The `policy.applied` params (17.4).
pub fn applied_params(
    instance: &str,
    session_id: &str,
    decision: &Decision,
    tool_call: &Value,
) -> Value {
    json!({
        "instance": instance,
        "sessionId": session_id,
        "set": decision.set.clone(),
        "outcome": if decision.cancelled { "cancelled" } else { "selected" },
        "optionId": decision.option_id.clone(),
        "kind": decision.kind.clone(),
        "toolCall": tool_call,
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    fn set(value: Value) -> Value {
        value
    }

    fn install(policy: &mut Policy, value: Value) {
        policy.install(&value, 1, 100).expect("set installs");
    }

    fn request(kind: &str, options: Value) -> Value {
        json!({
            "sessionId": "s1",
            "toolCall": {"kind": kind},
            "options": options,
        })
    }

    #[test]
    fn questions_are_the_lua_truth_table() {
        let single = json!({"toolCall": {"kind": "execute"}, "options": [{"kind": "allow_once"}]});
        assert!(!is_question(&single));
        let two_same = json!({"toolCall": {"kind": "edit"}, "options": [
            {"kind": "allow_once"}, {"kind": "allow_once"}]});
        assert!(is_question(&two_same));
        let mixed = json!({"toolCall": {"kind": "edit"}, "options": [
            {"kind": "allow_once"}, {"kind": "reject_once"}]});
        assert!(!is_question(&mixed));
        let missing_kinds = json!({"toolCall": {"kind": "edit"}, "options": [
            {"optionId": "a"}, {"optionId": "b"}]});
        assert!(is_question(&missing_kinds));
        let switch = json!({"toolCall": {"kind": "switch_mode"}, "options": []});
        assert!(is_question(&switch));
        for method in ["select", "confirm"] {
            let raw = json!({"toolCall": {"kind": "other", "rawInput": {"method": method}}, "options": []});
            assert!(is_question(&raw), "{method}");
        }
        assert!(!is_question(
            &json!({"toolCall": {"kind": "read"}, "options": []})
        ));
    }

    #[test]
    fn choose_and_offered_pick_different_options() {
        let options = json!([
            {"optionId": "always", "kind": "allow_always"},
            {"optionId": "once", "kind": "allow_once"},
        ]);
        let mut policy = Policy::new();
        install(
            &mut policy,
            set(json!({
                "name": "ordered", "allow_always": true,
                "rules": [{"choose": ["allow_once", "allow_always"]}],
            })),
        );
        let decision = policy
            .decide(&request("edit", options.clone()), "a", "i1", false)
            .unwrap();
        assert_eq!(decision.option_id.as_deref(), Some("once"));

        let mut policy = Policy::new();
        install(
            &mut policy,
            set(json!({
                "name": "offered", "allow_always": true,
                "rules": [{"choose": ["allow_once", "allow_always"], "pick": "offered"}],
            })),
        );
        let decision = policy
            .decide(&request("edit", options), "a", "i1", false)
            .unwrap();
        assert_eq!(decision.option_id.as_deref(), Some("always"));
    }

    #[test]
    fn fallback_and_priority_order() {
        let mut policy = Policy::new();
        install(
            &mut policy,
            set(json!({
                "name": "low", "priority": 0, "fallback": "cancelled",
                "rules": [{"choose": ["reject_once"]}],
            })),
        );
        install(
            &mut policy,
            set(json!({
                "name": "high", "priority": 10,
                "rules": [{"choose": ["allow_once"]}],
            })),
        );
        let options = json!([
            {"optionId": "allow", "kind": "allow_once"},
            {"optionId": "reject", "kind": "reject_once"},
        ]);
        let decision = policy
            .decide(&request("edit", options.clone()), "a", "i1", false)
            .unwrap();
        assert_eq!(decision.set, "high");
        assert_eq!(decision.option_id.as_deref(), Some("allow"));

        let mut policy = Policy::new();
        install(
            &mut policy,
            set(json!({
                "name": "no-match", "fallback": "cancelled",
                "rules": [{"choose": ["reject_once"], "kinds": ["execute"]}],
            })),
        );
        let decision = policy
            .decide(&request("edit", options), "a", "i1", false)
            .unwrap();
        assert_eq!(decision.set, "no-match");
        assert!(decision.cancelled);
    }

    #[test]
    fn session_and_agent_filters_and_question_skip() {
        let mut policy = Policy::new();
        install(
            &mut policy,
            set(json!({
                "name": "filtered", "session": "other", "agent": "pi",
                "rules": [{"choose": ["allow_once"]}],
            })),
        );
        let options = json!([{"optionId": "a", "kind": "allow_once"}]);
        assert!(policy
            .decide(&request("edit", options.clone()), "pi", "i1", false)
            .is_none());
        let mut params = request("edit", options);
        params["sessionId"] = json!("other");
        assert!(policy.decide(&params, "claude", "i1", false).is_none());
        assert!(policy.decide(&params, "pi", "i1", false).is_some());
    }

    #[test]
    fn session_sets_are_consulted_before_sessionless_ones() {
        let options = json!([{"optionId": "allow", "kind": "allow_once"}]);
        let mut policy = Policy::new();
        install(
            &mut policy,
            set(json!({"name": "plain", "priority": 0,
                "rules": [{"choose": ["reject_once"]}]})),
        );
        install(
            &mut policy,
            set(json!({"name": "session", "session": "s1", "priority": 0,
                "rules": [{"choose": ["allow_once"]}]})),
        );
        let params = json!({"sessionId": "s1", "toolCall": {"kind": "edit"},
            "options": [{"optionId": "allow", "kind": "allow_once"},
                        {"optionId": "reject", "kind": "reject_once"}]});
        let decision = policy.decide(&params, "a", "i1", false).unwrap();
        assert_eq!(decision.set, "session");
        assert_eq!(decision.option_id.as_deref(), Some("allow"));
        let _ = options;
    }

    #[test]
    fn validation_rejects_each_documented_case() {
        let mut policy = Policy::new();
        let cases = [
            json!({"name": "!bad", "rules": []}),
            json!({"name": "empty", "rules": [{"choose": []}]}),
            json!({"name": "kind", "rules": [{"choose": ["maybe"]}]}),
            json!({"name": "always", "rules": [{"choose": ["allow_always"]}]}),
            json!({"name": "until", "until": "turn_end", "rules": []}),
            json!({"name": "turn", "until": "later", "session": "s", "rules": []}),
            json!({"name": "cwd", "cwd": "relative", "rules": []}),
            json!({"name": "path", "rules": [{"paths": ["relative"], "choose": ["allow_once"]}]}),
            json!({"name": "under", "rules": [{"paths_under": ["x"], "choose": ["allow_once"]}]}),
            json!({"name": "keep", "keep": "forever", "rules": []}),
            json!({"name": "fallback", "fallback": "allow", "rules": []}),
            json!({"name": "pick", "rules": [{"choose": ["allow_once"], "pick": "first"}]}),
            json!({"name": "kinds", "rules": [{"kinds": [], "choose": ["allow_once"]}]}),
            json!({"name": "rules", "rules": vec![json!({}); 65]}),
        ];
        for value in cases {
            assert!(policy.install(&value, 1, 0).is_err(), "{value}");
        }
        assert!(policy.is_empty());
    }

    #[test]
    fn too_many_sets_are_refused_but_replacing_is_fine() {
        let mut policy = Policy::new();
        for index in 0..MAX_SETS {
            install(
                &mut policy,
                json!({"name": format!("set-{index}"), "rules": []}),
            );
        }
        assert!(policy
            .install(&json!({"name": "overflow", "rules": []}), 1, 0)
            .is_err());
        install(&mut policy, json!({"name": "set-0", "rules": []}));
    }

    #[test]
    fn relative_paths_use_the_set_cwd_and_never_match_without_one() {
        let dir = std::env::temp_dir().join(format!("ade-policy-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).expect("dir");
        let file = dir.join("a.lua");
        std::fs::write(&file, "x").expect("file");
        let options = json!([{"optionId": "allow", "kind": "allow_once"}]);
        let mut policy = Policy::new();
        install(
            &mut policy,
            set(json!({
                "name": "cwd", "cwd": dir.display().to_string(),
                "rules": [{"paths": [file.display().to_string()], "choose": ["allow_once"]}],
            })),
        );
        let params = json!({
            "sessionId": "s1",
            "toolCall": {"kind": "edit", "locations": [{"path": "a.lua"}]},
            "options": options.clone(),
        });
        assert!(policy.decide(&params, "a", "i1", false).is_some());
        let mut without = params.clone();
        without["toolCall"]["locations"] = json!([{"path": "b.lua"}]);
        assert!(policy.decide(&without, "a", "i1", false).is_none());

        let mut policy = Policy::new();
        install(
            &mut policy,
            set(json!({"name": "no-cwd", "rules": [{
                "paths": [file.display().to_string()], "choose": ["allow_once"],
            }]})),
        );
        assert!(
            policy.decide(&params, "a", "i1", false).is_none(),
            "a relative request needs cwd"
        );
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[cfg(unix)]
    #[test]
    fn symlinks_and_hardlinks_do_not_pass_paths() {
        use std::os::unix::fs::symlink;
        let dir = std::env::temp_dir().join(format!("ade-policy-links-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).expect("dir");
        let private = dir.join("copy.txt");
        std::fs::write(&private, "x").expect("private");
        let outside = dir.join("outside.txt");
        std::fs::write(&outside, "x").expect("outside");
        let link = dir.join("link.txt");
        symlink(&outside, &link).expect("symlink");
        let options = json!([{"optionId": "allow", "kind": "allow_once"}]);
        let mut policy = Policy::new();
        install(
            &mut policy,
            set(json!({"name": "paths", "rules": [{
                "paths": [private.display().to_string()],
                "choose": ["allow_once"],
            }]})),
        );
        let decide = |path: &Path| {
            policy.decide(
                &json!({
                    "sessionId": "s1",
                    "toolCall": {"kind": "edit", "locations": [{"path": path.display().to_string()}]},
                    "options": options,
                }),
                "a", "i1", false,
            )
        };
        assert!(decide(&private).is_some());
        assert!(
            decide(&outside).is_none(),
            "another regular file must not pass"
        );
        let hard = dir.join("hard.txt");
        std::fs::hard_link(&private, &hard).expect("hard link");
        assert!(
            decide(&link).is_none(),
            "a symlink to the private file must not pass"
        );
        assert!(decide(&hard).is_none(), "a hard link must not pass");
        assert!(
            decide(&private).is_none(),
            "the listed path with nlink > 1 must not pass either"
        );

        // A symlinked directory spelling resolves to the same realpath.
        std::fs::create_dir_all(dir.join("real")).expect("real dir");
        let real_file = dir.join("real/file.txt");
        std::fs::write(&real_file, "x").expect("real file");
        symlink(dir.join("real"), dir.join("alias")).expect("dir symlink");
        let mut policy = Policy::new();
        install(
            &mut policy,
            set(json!({"name": "real", "rules": [{
                "paths": [dir.join("alias/file.txt").display().to_string()],
                "choose": ["allow_once"],
            }]})),
        );
        let decision = policy.decide(
            &json!({
                "sessionId": "s1",
                "toolCall": {"kind": "edit", "locations": [{"path": real_file.display().to_string()}]},
                "options": [{"optionId": "allow", "kind": "allow_once"}],
            }),
            "a", "i1", false,
        );
        assert!(decision.is_some(), "realpath equality must pass");
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[cfg(unix)]
    #[test]
    fn paths_under_use_the_nearest_existing_ancestor() {
        let dir = std::env::temp_dir().join(format!("ade-policy-under-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(dir.join("sub")).expect("dir");
        let options = json!([{"optionId": "allow", "kind": "allow_once"}]);
        let mut policy = Policy::new();
        install(
            &mut policy,
            set(json!({"name": "under", "rules": [{
                "paths_under": [dir.display().to_string()],
                "choose": ["allow_once"],
            }]})),
        );
        let decide = |path: &Path| {
            policy.decide(
                &json!({
                    "sessionId": "s1",
                    "toolCall": {"kind": "edit", "locations": [{"path": path.display().to_string()}]},
                    "options": options,
                }),
                "a", "i1", false,
            )
        };
        assert!(decide(&dir.join("sub/new.txt")).is_some());
        assert!(decide(&dir.join("missing/deeper/new.txt")).is_some());
        assert!(decide(&dir.parent().unwrap().join("elsewhere.txt")).is_none());
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[cfg(unix)]
    #[test]
    fn paths_under_reject_dangling_symlinks() {
        use std::os::unix::fs::symlink;
        let dir = std::env::temp_dir().join(format!("ade-policy-dangling-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).expect("dir");
        let outside_target = dir.parent().unwrap().join("ade-policy-missing-target");
        let _ = std::fs::remove_file(&outside_target);
        let outer = dir.join("outer");
        symlink(&outside_target, &outer).expect("outside dangling");
        let inner = dir.join("inner");
        symlink(dir.join("missing"), &inner).expect("inside dangling");
        let options = json!([{"optionId": "allow", "kind": "allow_once"}]);
        let mut policy = Policy::new();
        install(
            &mut policy,
            set(json!({"name": "under", "rules": [{
                "paths_under": [dir.display().to_string()],
                "choose": ["allow_once"],
            }]})),
        );
        let decide = |path: &Path| {
            policy.decide(
                &json!({
                    "sessionId": "s1",
                    "toolCall": {"kind": "edit", "locations": [{"path": path.display().to_string()}]},
                    "options": options,
                }),
                "a",
                "i1",
                false,
            )
        };
        assert!(
            decide(&outer).is_none(),
            "a dangling link outside must not pass"
        );
        assert!(
            decide(&inner).is_none(),
            "a dangling link inside must not pass either"
        );
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn parent_components_never_match() {
        let dir = std::env::temp_dir().join(format!("ade-policy-dotdot-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).expect("dir");
        let file = dir.join("file.txt");
        std::fs::write(&file, "x").expect("file");
        let options = json!([{"optionId": "allow", "kind": "allow_once"}]);
        let mut policy = Policy::new();
        let indirect = dir
            .join("../")
            .join(dir.file_name().unwrap())
            .join("file.txt");
        install(
            &mut policy,
            set(json!({"name": "rule-dotdot", "rules": [{
                "paths": [indirect.display().to_string()],
                "choose": ["allow_once"],
            }]})),
        );
        let request = |path: &Path| {
            json!({
                "sessionId": "s1",
                "toolCall": {"kind": "edit", "locations": [{"path": path.display().to_string()}]},
                "options": options,
            })
        };
        assert!(
            policy.decide(&request(&file), "a", "i1", false).is_none(),
            "a rule path with .. never matches"
        );

        let mut policy = Policy::new();
        install(
            &mut policy,
            set(json!({"name": "request-dotdot", "rules": [{
                "paths": [file.display().to_string()],
                "choose": ["allow_once"],
            }]})),
        );
        let dotted = dir.join("sub/../file.txt");
        assert!(
            policy.decide(&request(&dotted), "a", "i1", false).is_none(),
            "a request path with .. never matches"
        );
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn windows_paths_are_pure_and_drive_case_insensitive() {
        assert_eq!(
            normalize_path(r"C:\Work\..\Temp\.\a.txt", true).as_deref(),
            Some("c:/Temp/a.txt")
        );
        assert_eq!(
            normalize_path("/a/./b/../c", false).as_deref(),
            Some("/a/c")
        );
        assert!(normalize_path(r"C:relative", true).is_none());
        assert!(normalize_path(r"\\server\share\a", true).is_none());
        assert!(normalize_path(r"\\?\C:\a", true).is_none());
        assert!(normalize_path("relative", false).is_none());
    }

    #[test]
    fn windows_equality_only_ignores_the_drive_letter() {
        assert!(same_path(
            Path::new("C:/Work/a"),
            Path::new("c:/Work/a"),
            true
        ));
        assert!(!same_path(
            Path::new("C:/Work/a"),
            Path::new("c:/work/a"),
            true
        ));
        assert!(!same_path(Path::new("/a"), Path::new("/A"), false));
    }

    #[test]
    fn verbatim_prefixes_are_stripped_and_absolutes_are_platform_aware() {
        assert_eq!(
            strip_verbatim(Path::new(r"\\?\C:\Work\a"))
                .display()
                .to_string(),
            r"C:\Work\a"
        );
        assert!(
            is_absolute("/foo", true),
            "a root-relative Windows path is absolute"
        );
        assert!(is_absolute(r"C:\foo", true));
        assert!(!is_absolute("foo/bar", true));
    }

    #[test]
    fn windows_request_paths_resolve_and_reject_unc() {
        let tool = json!({"kind": "edit", "locations": [{"path": "sub\\a.txt"}]});
        let paths = request_paths(&tool, Some(Path::new("C:/Work")), true).expect("resolved");
        assert_eq!(paths[0].to_string_lossy(), "c:/Work/sub/a.txt");
        let unc = json!({"kind": "edit", "locations": [{"path": "\\\\server\\share\\a"}]});
        assert!(request_paths(&unc, Some(Path::new("C:/Work")), true).is_err());
        assert!(
            request_paths(&tool, None, true).is_err(),
            "relative paths need cwd"
        );
    }

    #[test]
    fn turn_end_binding_and_cancel_lifecycle() {
        let options = json!([{"optionId": "allow", "kind": "allow_once"}]);
        let mut policy = Policy::new();
        install(
            &mut policy,
            set(json!({
                "name": "inline", "session": "s1", "until": "turn_end", "owner": 7,
                "rules": [{"choose": ["allow_once"]}],
            })),
        );
        policy
            .install(
                &json!({
                    "name": "inline2", "session": "s1", "until": "turn_end",
                    "rules": [{"choose": ["allow_once"]}],
                }),
                7,
                1,
            )
            .unwrap();
        let params = json!({"sessionId": "s1", "toolCall": {"kind": "edit"}, "options": options});
        assert!(
            policy.decide(&params, "a", "i1", false).is_none(),
            "unbound until set is inactive"
        );
        policy.on_prompt(7, "i1", "s1", "a");
        assert!(
            policy.decide(&params, "a", "i2", false).is_none(),
            "a bound set only applies to its instance"
        );
        assert!(policy.decide(&params, "a", "i1", false).is_some());
        policy.on_cancel("s1");
        let decision = policy.decide(&params, "a", "i1", false).unwrap();
        assert!(decision.cancelled && decision.cancelling);
        policy.prompt_finished(7, "s1");
        assert!(policy.decide(&params, "a", "i1", false).is_none());

        // An instance that exits can never answer its bound prompt.
        policy
            .install(
                &json!({"name": "gone", "session": "s1", "until": "turn_end",
                    "rules": [{"choose": ["allow_once"]}]}),
                7,
                1,
            )
            .unwrap();
        policy.on_prompt(7, "i3", "s1", "a");
        assert!(policy.decide(&params, "a", "i3", false).is_some());
        policy.instance_exited("i3");
        assert!(policy.decide(&params, "a", "i3", false).is_none());
    }

    #[test]
    fn connection_close_keeps_only_service_and_bound_turn_end_sets() {
        let mut policy = Policy::new();
        policy
            .install(&json!({"name": "conn", "rules": []}), 1, 0)
            .unwrap();
        policy
            .install(
                &json!({"name": "service", "keep": "service", "rules": []}),
                1,
                0,
            )
            .unwrap();
        policy
            .install(
                &json!({"name": "turn", "session": "s", "until": "turn_end", "rules": []}),
                1,
                0,
            )
            .unwrap();
        policy.on_prompt(1, "i1", "s", "a");
        policy.connection_closed(1);
        let names: Vec<String> = policy
            .list()
            .iter()
            .map(|set| set["name"].as_str().unwrap().to_string())
            .collect();
        assert_eq!(names, vec!["service".to_string(), "turn".to_string()]);
    }

    #[test]
    fn log_update_omits_large_tool_call_fields() {
        let decision = Decision {
            set: "s".to_string(),
            option_id: Some("a".to_string()),
            kind: Some("allow_once".to_string()),
            cancelled: false,
            cancelling: false,
        };
        let small = json!({"kind": "edit"});
        let update = log_update(&decision, &small);
        assert_eq!(update["toolCall"], small);
        let large = json!({"kind": "edit", "rawInput": "x".repeat(70 * 1024), "content": []});
        let update = log_update(&decision, &large);
        assert_eq!(update["toolCall"]["rawInput"], "[omitted]");
        assert_eq!(update["toolCall"]["content"], "[omitted]");
    }
}
