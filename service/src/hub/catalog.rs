//! Session catalog across agents (PROTOCOL.md section 21).
//!
//! `sessions.cached` answers from the event log store; `sessions.refresh`
//! lists one agent at a time with a service-originated `session/list`, either
//! on a live instance that already finished `initialize` or on a temporary
//! unlisted process that is stopped when the listing ends.
//!
//! The running listing is a small state machine keyed by agent id. It is not a
//! team `ServiceCall`: the catalog owns its own driver map, so a listing
//! response never needs the team module. Joining is by agent id only, as the
//! contract says: a second refresh of the same agent waits for the first one.

use std::collections::{HashMap, HashSet};
use std::time::{Duration, Instant};

use serde_json::{json, Map, Value};
use tokio::sync::mpsc;

use crate::protocol::{
    failure, success, INTERNAL_ERROR, INVALID_PARAMS, METHOD_NOT_FOUND, SESSIONS_LIST_EXITED,
    SESSIONS_LIST_TIMEOUT, SESSIONS_LIST_UNSUPPORTED, SPAWN_FAILED,
};
use crate::relay::{parse_env, InstanceKey};

#[cfg(unix)]
use crate::install;

use super::{now_ms, Hub};

/// Default per-agent timeout of `sessions.refresh` (PROTOCOL.md 21.3).
const DEFAULT_TIMEOUT_MS: u64 = 30_000;
/// Lower clamp of `timeout_ms` (PROTOCOL.md 21.3).
const MIN_TIMEOUT_MS: u64 = 1_000;
/// Upper clamp of `timeout_ms` (PROTOCOL.md 21.3).
const MAX_TIMEOUT_MS: u64 = 120_000;
/// `session/list` paging stops after this many requests (PROTOCOL.md 21.3).
const MAX_PAGES: usize = 100;

/// The catalog state owned by the hub: waiting calls, running listings and
/// the responses they expect.
pub(crate) struct Catalog {
    calls: HashMap<u64, RefreshCall>,
    agents: HashMap<String, RunningAgent>,
    driver: HashMap<(String, u64), CatalogCall>,
    next_call: u64,
    sender: mpsc::UnboundedSender<CatalogResult>,
}

impl Catalog {
    pub(crate) fn new() -> (Self, mpsc::UnboundedReceiver<CatalogResult>) {
        let (sender, receiver) = mpsc::unbounded_channel();
        (
            Self {
                calls: HashMap::new(),
                agents: HashMap::new(),
                driver: HashMap::new(),
                next_call: 0,
                sender,
            },
            receiver,
        )
    }

    /// Whether a catalog listing is running: it keeps the service from exiting
    /// while idle (PROTOCOL.md 21.3 "Idle").
    pub(crate) fn busy(&self) -> bool {
        !self.agents.is_empty()
    }
}

/// One `sessions.refresh` request waiting for its agents.
struct RefreshCall {
    conn: u64,
    id: Value,
    /// Agents of this call that have not finished yet.
    remaining: HashSet<String>,
    /// Per-agent results, for the reply.
    results: Map<String, Value>,
}

/// One running listing, keyed by its agent id.
struct RunningAgent {
    /// Calls waiting for this agent, by call id.
    calls: Vec<u64>,
    instance: String,
    /// A temporary process this refresh spawned and must stop afterwards.
    temporary: bool,
    deadline: Instant,
    /// Listed entries, deduplicated by session id (last page wins).
    entries: HashMap<String, Value>,
    /// `session/list` requests sent so far (the page count).
    pages: usize,
    /// Cursors already followed in this listing, to stop on a loop.
    cursors: HashSet<String>,
}

/// A request the service sent itself for the catalog.
#[derive(Debug, Clone)]
enum CatalogCall {
    Initialize { agent: String },
    List { agent: String },
}

impl CatalogCall {
    fn agent(&self) -> &str {
        match self {
            Self::Initialize { agent } | Self::List { agent } => agent,
        }
    }
}

/// A finished store read for `sessions.cached`.
pub(crate) enum CatalogResult {
    Cached {
        conn: u64,
        id: Value,
        result: Result<crate::store::StoredCatalog, String>,
    },
}

/// One agent entry of a `sessions.refresh` call.
struct AgentRequest {
    key: InstanceKey,
    env: Option<Vec<(String, String)>>,
    #[cfg(unix)]
    launch: Option<install::Launch>,
}

/// The capabilities of a temporary catalog instance (PROTOCOL.md 21.3).
fn temporary_capabilities() -> Value {
    json!({
        "fs": { "readTextFile": false, "writeTextFile": false },
        "terminal": false,
    })
}

impl Hub {
    /// Dispatch `sessions.*` (PROTOCOL.md 21.2/21.3).
    pub(crate) fn handle_catalog_method(
        &mut self,
        conn: u64,
        method: &str,
        params: &Value,
        id: &Value,
    ) {
        match method {
            "sessions.cached" => self.catalog_cached(conn, id),
            "sessions.refresh" => self.catalog_refresh(conn, id, params),
            _ => self.send_to(conn, &failure(id, METHOD_NOT_FOUND, "method not found")),
        }
    }

    /// `sessions.cached`: read the store on the blocking pool, answer at once.
    fn catalog_cached(&mut self, conn: u64, id: &Value) {
        let recorder = self.recorder.clone();
        let sender = self.catalog.sender.clone();
        let id = id.clone();
        tokio::spawn(async move {
            let result = recorder
                .load_catalog()
                .await
                .map_err(|error| format!("{error:#}"));
            let _ = sender.send(CatalogResult::Cached { conn, id, result });
        });
    }

    pub(crate) fn finish_catalog_result(&mut self, result: CatalogResult) {
        match result {
            CatalogResult::Cached { conn, id, result } => {
                let (entries, agents) = match result {
                    Ok(catalog) => catalog,
                    Err(error) => {
                        // The contract defines only the success shape; a broken
                        // store must not turn into an undocumented error code.
                        crate::svc_log!(
                            "nvim_ade_server: cannot read the session catalog: {error}"
                        );
                        (Vec::new(), Vec::new())
                    }
                };
                let sessions: Vec<Value> = entries
                    .iter()
                    .filter_map(|(_, json)| match serde_json::from_str(json) {
                        Ok(value) => Some(value),
                        Err(error) => {
                            crate::svc_log!(
                                "nvim_ade_server: dropping an unreadable catalog row: {error}"
                            );
                            None
                        }
                    })
                    .collect();
                let mut states = Map::new();
                for (agent, json) in agents {
                    match serde_json::from_str(&json) {
                        Ok(value) => {
                            states.insert(agent, value);
                        }
                        Err(error) => {
                            crate::svc_log!(
                                "nvim_ade_server: dropping an unreadable catalog state: {error}"
                            );
                        }
                    }
                }
                self.send_to(
                    conn,
                    &success(&id, json!({ "sessions": sessions, "agents": states })),
                );
            }
        }
    }

    /// `sessions.refresh` (PROTOCOL.md 21.3).
    fn catalog_refresh(&mut self, conn: u64, id: &Value, params: &Value) {
        let (requests, timeout) = match parse_refresh(params) {
            Ok(parsed) => parsed,
            Err(message) => {
                self.send_to(conn, &failure(id, INVALID_PARAMS, &message));
                return;
            }
        };

        self.catalog.next_call += 1;
        let call_id = self.catalog.next_call;
        if requests.is_empty() {
            self.send_to(conn, &success(id, json!({ "agents": {} })));
            return;
        }

        let call = RefreshCall {
            conn,
            id: id.clone(),
            remaining: requests
                .iter()
                .map(|request| request.key.agent.clone())
                .collect(),
            results: Map::new(),
        };
        self.catalog.calls.insert(call_id, call);

        for request in &requests {
            let agent = request.key.agent.clone();
            // The timeout runs from the start of this agent's step 1/2, spawn
            // included (PROTOCOL.md 21.3 step 5).
            let deadline = Instant::now() + timeout;
            if let Some(running) = self.catalog.agents.get_mut(&agent) {
                // Joining: the running listing answers with the same result
                // (PROTOCOL.md 21.3 "Joining").
                running.calls.push(call_id);
                continue;
            }
            if let Some(instance) = self.reusable_instance(request) {
                let supported = self
                    .instances
                    .get(&instance)
                    .and_then(|handle| handle.relay.initialize_result())
                    .is_some_and(catalog_capable);
                if !supported {
                    self.fail_catalog_now(
                        &agent,
                        SESSIONS_LIST_UNSUPPORTED,
                        "the agent does not support session/list",
                        vec![call_id],
                    );
                    continue;
                }
                self.catalog.agents.insert(
                    agent.clone(),
                    RunningAgent {
                        calls: vec![call_id],
                        instance,
                        temporary: false,
                        deadline,
                        entries: HashMap::new(),
                        pages: 0,
                        cursors: HashSet::new(),
                    },
                );
                if !self.send_catalog_list(&agent, None) {
                    self.fail_catalog_agent(
                        &agent,
                        SESSIONS_LIST_EXITED,
                        "the agent process exited during the listing",
                    );
                }
                continue;
            }

            match self.spawn_temporary(request) {
                Ok(instance) => {
                    self.catalog.agents.insert(
                        agent.clone(),
                        RunningAgent {
                            calls: vec![call_id],
                            instance,
                            temporary: true,
                            deadline,
                            entries: HashMap::new(),
                            pages: 0,
                            cursors: HashSet::new(),
                        },
                    );
                    if !self.send_catalog_initialize(&agent) {
                        self.fail_catalog_agent(
                            &agent,
                            SESSIONS_LIST_EXITED,
                            "the agent process exited during the listing",
                        );
                    }
                }
                Err(message) => {
                    self.fail_catalog_now(&agent, SPAWN_FAILED, &message, vec![call_id]);
                }
            }
        }
    }

    /// A live, non-stopping listed instance with the same agent, command and
    /// args that already finished `initialize` (PROTOCOL.md 21.3 step 1).
    fn reusable_instance(&self, request: &AgentRequest) -> Option<String> {
        self.by_identity.values().find_map(|id| {
            let instance = self.instances.get(id)?;
            (!instance.stopping
                && !instance.temporary
                && instance.key.agent == request.key.agent
                && instance.key.command == request.key.command
                && instance.key.args == request.key.args
                && instance.relay.initialize_result().is_some())
            .then(|| instance.id.clone())
        })
    }

    fn spawn_temporary(&mut self, request: &AgentRequest) -> Result<String, String> {
        #[cfg(unix)]
        {
            self.spawn_catalog(
                request.key.clone(),
                request.env.clone(),
                request.launch.clone(),
            )
        }
        #[cfg(not(unix))]
        {
            self.spawn_catalog(request.key.clone(), request.env.clone())
        }
    }

    /// Send `initialize` to a temporary instance.
    fn send_catalog_initialize(&mut self, agent: &str) -> bool {
        let Some(instance) = self
            .catalog
            .agents
            .get(agent)
            .map(|running| running.instance.clone())
        else {
            return false;
        };
        let params = json!({
            "protocolVersion": 1,
            "clientCapabilities": temporary_capabilities(),
        });
        let Some(handle) = self.instances.get_mut(&instance) else {
            return false;
        };
        let (agent_id, frame) = handle.relay.service_request("initialize", params);
        if !handle.control.send_frame(frame) {
            return false;
        }
        self.catalog.driver.insert(
            (instance, agent_id),
            CatalogCall::Initialize {
                agent: agent.to_string(),
            },
        );
        true
    }

    /// Send one `session/list` page, without `cwd` on the first one and with
    /// the previous page's cursor afterwards (PROTOCOL.md 21.3 step 4).
    fn send_catalog_list(&mut self, agent: &str, cursor: Option<&str>) -> bool {
        let Some(instance) = self.catalog.agents.get_mut(agent).map(|running| {
            running.pages += 1;
            running.instance.clone()
        }) else {
            return false;
        };
        let params = match cursor {
            Some(cursor) => json!({ "cursor": cursor }),
            None => json!({}),
        };
        let Some(handle) = self.instances.get_mut(&instance) else {
            return false;
        };
        let (agent_id, frame) = handle.relay.service_request("session/list", params);
        if !handle.control.send_frame(frame) {
            return false;
        }
        self.catalog.driver.insert(
            (instance, agent_id),
            CatalogCall::List {
                agent: agent.to_string(),
            },
        );
        true
    }

    /// Handle a response to a catalog request. Returns false when the id does
    /// not belong to the catalog.
    pub(crate) fn handle_catalog_service_response(
        &mut self,
        instance: &str,
        agent_id: u64,
        message: &Value,
    ) -> bool {
        let Some(call) = self
            .catalog
            .driver
            .remove(&(instance.to_string(), agent_id))
        else {
            return false;
        };
        match call {
            CatalogCall::Initialize { agent } => {
                self.catalog_initialize_response(&agent, instance, message)
            }
            CatalogCall::List { agent } => self.catalog_list_response(&agent, instance, message),
        }
        true
    }

    fn catalog_initialize_response(&mut self, agent: &str, instance: &str, message: &Value) {
        if !self
            .catalog
            .agents
            .get(agent)
            .is_some_and(|running| running.instance == instance)
        {
            // Late response of a listing that already failed or timed out.
            return;
        }
        if let Some(error) = message.get("error") {
            let (code, message) = agent_error(error);
            self.fail_catalog_agent(agent, code, &message);
            return;
        }
        if !message.get("result").is_some_and(catalog_capable) {
            self.fail_catalog_agent(
                agent,
                SESSIONS_LIST_UNSUPPORTED,
                "the agent does not support session/list",
            );
            return;
        }
        if !self.send_catalog_list(agent, None) {
            self.fail_catalog_agent(
                agent,
                SESSIONS_LIST_EXITED,
                "the agent process exited during the listing",
            );
        }
    }

    fn catalog_list_response(&mut self, agent: &str, instance: &str, message: &Value) {
        if !self
            .catalog
            .agents
            .get(agent)
            .is_some_and(|running| running.instance == instance)
        {
            return;
        }
        if let Some(error) = message.get("error") {
            let (code, message) = agent_error(error);
            self.fail_catalog_agent(agent, code, &message);
            return;
        }

        let result = message.get("result");
        let page = result
            .and_then(|result| result.get("sessions"))
            .and_then(Value::as_array)
            .cloned()
            .unwrap_or_default();
        let next = result
            .and_then(|result| result.get("nextCursor"))
            .and_then(Value::as_str)
            .filter(|cursor| !cursor.is_empty())
            .map(str::to_string);

        let follow = {
            let Some(running) = self.catalog.agents.get_mut(agent) else {
                return;
            };
            if running.instance != instance {
                return;
            }
            for item in &page {
                if let Some((session_id, entry)) = catalog_entry(agent, item) {
                    // Last page wins for a repeated session id.
                    running.entries.insert(session_id, entry);
                }
            }
            match &next {
                Some(cursor) if running.pages < MAX_PAGES => {
                    // A cursor already followed means the agent loops.
                    running.cursors.insert(cursor.clone())
                }
                _ => false,
            }
        };

        if follow {
            if !self.send_catalog_list(agent, next.as_deref()) {
                self.fail_catalog_agent(
                    agent,
                    SESSIONS_LIST_EXITED,
                    "the agent process exited during the listing",
                );
            }
        } else {
            self.succeed_catalog_agent(agent);
        }
    }

    /// The listing succeeded: replace the cache rows and tell every waiter.
    fn succeed_catalog_agent(&mut self, agent: &str) {
        let Some(running) = self.take_catalog_agent(agent) else {
            return;
        };
        if running.temporary {
            self.stop_catalog_instance(&running.instance);
        }
        let count = running.entries.len();
        let entries: Vec<(String, String)> = running
            .entries
            .iter()
            .map(|(session_id, entry)| (session_id.clone(), entry.to_string()))
            .collect();
        self.recorder
            .replace_catalog(agent, entries, json!({ "listed_at": now_ms() }).to_string());
        let sessions: Vec<Value> = running.entries.into_values().collect();
        let notification = json!({
            "jsonrpc": "2.0",
            "method": "sessions.updated",
            "params": { "agent": agent, "sessions": sessions },
        });
        self.notify_calls(&running.calls, &notification);
        for call_id in running.calls {
            self.complete_catalog_agent(call_id, agent, json!({ "ok": true, "count": count }));
        }
    }

    /// Fail the running listing of one agent (and stop a temporary process).
    fn fail_catalog_agent(&mut self, agent: &str, code: i64, message: &str) {
        let Some(running) = self.take_catalog_agent(agent) else {
            return;
        };
        if running.temporary {
            self.stop_catalog_instance(&running.instance);
        }
        self.fail_catalog_now(agent, code, message, running.calls);
    }

    /// Fail a listing that never started (spawn error, missing capability on a
    /// reused instance).
    fn fail_catalog_now(&mut self, agent: &str, code: i64, message: &str, calls: Vec<u64>) {
        // Cached rows are kept; only the state's `error` changes
        // (PROTOCOL.md 21.3 step 6).
        self.recorder.set_catalog_error(agent, code, message);
        let notification = json!({
            "jsonrpc": "2.0",
            "method": "sessions.updated",
            "params": { "agent": agent, "error": { "code": code, "message": message } },
        });
        self.notify_calls(&calls, &notification);
        let result = json!({ "ok": false, "error": { "code": code, "message": message } });
        for call_id in calls {
            self.complete_catalog_agent(call_id, agent, result.clone());
        }
    }

    /// Remove a running listing and its driver entries.
    fn take_catalog_agent(&mut self, agent: &str) -> Option<RunningAgent> {
        let running = self.catalog.agents.remove(agent)?;
        self.catalog_drop_driver(&running.instance, agent);
        Some(running)
    }

    fn catalog_drop_driver(&mut self, instance: &str, agent: &str) {
        self.catalog
            .driver
            .retain(|(owner, _), call| !(owner == instance && call.agent() == agent));
    }

    /// Tell every waiting call (one notification per connection).
    fn notify_calls(&mut self, calls: &[u64], notification: &Value) {
        let mut seen = HashSet::new();
        for call_id in calls {
            let Some(call) = self.catalog.calls.get(call_id) else {
                continue;
            };
            if seen.insert(call.conn) {
                self.send_to(call.conn, notification);
            }
        }
    }

    /// Mark one agent of one call finished; reply when every agent is done.
    fn complete_catalog_agent(&mut self, call_id: u64, agent: &str, result: Value) {
        let Some(call) = self.catalog.calls.get_mut(&call_id) else {
            return;
        };
        call.remaining.remove(agent);
        call.results.insert(agent.to_string(), result);
        if !call.remaining.is_empty() {
            return;
        }
        let Some(call) = self.catalog.calls.remove(&call_id) else {
            return;
        };
        self.send_to(
            call.conn,
            &success(&call.id, json!({ "agents": call.results })),
        );
    }

    /// A refresh outlived its requesting connections: they are not answered,
    /// but the listing still finishes and updates the cache.
    pub(crate) fn catalog_connection_closed(&mut self, conn: u64) {
        let calls: Vec<u64> = self
            .catalog
            .calls
            .iter()
            .filter(|(_, call)| call.conn == conn)
            .map(|(id, _)| *id)
            .collect();
        for call_id in calls {
            let Some(call) = self.catalog.calls.remove(&call_id) else {
                continue;
            };
            for agent in call.remaining {
                if let Some(running) = self.catalog.agents.get_mut(&agent) {
                    running.calls.retain(|waiting| *waiting != call_id);
                }
            }
        }
    }

    /// An instance exited: a listing on it fails with -32072
    /// (PROTOCOL.md 21.3 step 5).
    pub(crate) fn catalog_instance_exited(&mut self, instance: &str) {
        self.catalog
            .driver
            .retain(|(owner, _), _| owner != instance);
        let agents: Vec<String> = self
            .catalog
            .agents
            .iter()
            .filter(|(_, running)| running.instance == instance)
            .map(|(agent, _)| agent.clone())
            .collect();
        for agent in agents {
            let Some(running) = self.take_catalog_agent(&agent) else {
                continue;
            };
            self.fail_catalog_now(
                &agent,
                SESSIONS_LIST_EXITED,
                "the agent process exited during the listing",
                running.calls,
            );
        }
    }

    /// The expiry tick fails listings past their deadline (PROTOCOL.md 21.3
    /// step 5).
    pub(crate) fn expire_catalog(&mut self) {
        let now = Instant::now();
        let expired: Vec<String> = self
            .catalog
            .agents
            .iter()
            .filter(|(_, running)| now >= running.deadline)
            .map(|(agent, _)| agent.clone())
            .collect();
        for agent in expired {
            self.fail_catalog_agent(&agent, SESSIONS_LIST_TIMEOUT, "the session list timed out");
        }
    }

    /// §21.4: a successful `session/delete` removes the catalog row.
    pub(crate) fn delete_catalog_session(&mut self, agent: &str, session_id: &str) {
        self.recorder.delete_catalog_session(agent, session_id);
    }

    /// Stop a temporary instance with the graceful sequence of 3.4.
    fn stop_catalog_instance(&mut self, instance: &str) {
        let Some(handle) = self.instances.get_mut(instance) else {
            return;
        };
        if handle.stopping {
            return;
        }
        handle.stopping = true;
        let control = handle.control.clone();
        let timeouts = self.timeouts;
        tokio::spawn(async move {
            control.stop(false, timeouts).await;
        });
    }
}

/// Parse `sessions.refresh` params: the per-agent launches and the timeout.
fn parse_refresh(params: &Value) -> Result<(Vec<AgentRequest>, Duration), String> {
    let params = params
        .as_object()
        .ok_or_else(|| "params must be an object".to_string())?;
    let agents = params
        .get("agents")
        .and_then(Value::as_array)
        .ok_or_else(|| "agents must be an array".to_string())?;
    let timeout = match params.get("timeout_ms") {
        None | Some(Value::Null) => DEFAULT_TIMEOUT_MS,
        Some(value) => value
            .as_u64()
            .ok_or_else(|| "timeout_ms must be a non-negative integer".to_string())?
            .clamp(MIN_TIMEOUT_MS, MAX_TIMEOUT_MS),
    };

    let mut requests = Vec::with_capacity(agents.len());
    let mut seen = HashSet::new();
    for (index, item) in agents.iter().enumerate() {
        let object = item
            .as_object()
            .ok_or_else(|| format!("agents[{index}] must be an object"))?;
        let agent = required_string(object, "agent", index)?;
        if !seen.insert(agent.clone()) {
            return Err(format!("duplicate agent id {agent}"));
        }
        let command = required_string(object, "command", index)?;
        let cwd = required_string(object, "cwd", index)?;
        if !std::path::Path::new(&cwd).is_absolute() {
            return Err(format!("agents[{index}].cwd must be an absolute path"));
        }
        let args = match object.get("args") {
            None | Some(Value::Null) => Vec::new(),
            Some(Value::Array(items)) => items
                .iter()
                .map(|item| {
                    item.as_str()
                        .map(str::to_string)
                        .ok_or_else(|| format!("agents[{index}].args must be strings"))
                })
                .collect::<Result<Vec<_>, _>>()?,
            Some(_) => return Err(format!("agents[{index}].args must be an array")),
        };
        let env = parse_env(item).map_err(|error| error.to_string())?;
        #[cfg(unix)]
        let launch = match object.get("launch") {
            Some(value) if !value.is_null() => Some(
                install::parse_launch(value)
                    .map_err(|error| format!("agents[{index}].launch: {error}"))?,
            ),
            _ => None,
        };
        requests.push(AgentRequest {
            key: InstanceKey {
                agent,
                command,
                args,
                cwd,
                // The temporary process is initialized with these capabilities
                // (PROTOCOL.md 21.3 step 2).
                capabilities: temporary_capabilities(),
            },
            env,
            #[cfg(unix)]
            launch,
        });
    }
    Ok((requests, Duration::from_millis(timeout)))
}

fn required_string(
    object: &serde_json::Map<String, Value>,
    field: &str,
    index: usize,
) -> Result<String, String> {
    object
        .get(field)
        .and_then(Value::as_str)
        .filter(|value| !value.is_empty())
        .map(str::to_string)
        .ok_or_else(|| format!("agents[{index}].{field} must be a non-empty string"))
}

/// Whether an `initialize` result advertises `session/list`: any non-null
/// `agentCapabilities.sessionCapabilities.list` value (PROTOCOL.md 21.3
/// step 3).
fn catalog_capable(result: &Value) -> bool {
    result
        .get("agentCapabilities")
        .and_then(|capabilities| capabilities.get("sessionCapabilities"))
        .and_then(|capabilities| capabilities.get("list"))
        .is_some_and(|list| !list.is_null())
}

/// Turn one ACP `SessionInfo` into a catalog entry, or drop it when it could
/// not be loaded (`session/load` needs a string `sessionId` and `cwd`).
fn catalog_entry(agent: &str, item: &Value) -> Option<(String, Value)> {
    let session_id = item.get("sessionId").and_then(Value::as_str)?.to_string();
    let cwd = item.get("cwd").and_then(Value::as_str)?.to_string();
    let mut entry = json!({
        "agent": agent,
        "sessionId": session_id,
        "cwd": cwd,
    });
    if let Some(title) = item
        .get("title")
        .and_then(Value::as_str)
        .filter(|title| !title.is_empty())
    {
        entry["title"] = json!(title);
    }
    if let Some(updated_at) = item.get("updatedAt").and_then(Value::as_str) {
        entry["updatedAt"] = json!(updated_at);
    }
    if let Some(meta) = item.get("_meta").filter(|meta| meta.is_object()) {
        entry["_meta"] = meta.clone();
    }
    Some((session_id, entry))
}

/// `(code, message)` of an agent error object.
fn agent_error(error: &Value) -> (i64, String) {
    let code = error
        .get("code")
        .and_then(Value::as_i64)
        .unwrap_or(INTERNAL_ERROR);
    let message = error
        .get("message")
        .and_then(Value::as_str)
        .unwrap_or("the agent failed")
        .to_string();
    (code, message)
}
