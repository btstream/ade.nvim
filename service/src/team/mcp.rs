//! `nvim_ade_server mcp`: MCP over stdio for a team participant.
//!
//! The service hands each worker/leader agent an `mcpServers` entry whose
//! command is this subcommand and whose environment carries
//! `ADE_TEAM_TOKEN`. This process speaks MCP on stdin/stdout and translates the
//! tools to `bus.*` requests on the service socket. The token and the template
//! environment are never printed.

use std::io::{BufRead, BufReader, Write};
use std::process::ExitCode;

use serde_json::{json, Value};

#[cfg(unix)]
pub fn run() -> ExitCode {
    let token = std::env::var("ADE_TEAM_TOKEN").ok();
    let mut mcp = Mcp::new(token);
    mcp.serve();
    ExitCode::SUCCESS
}

#[cfg(not(unix))]
pub fn run() -> ExitCode {
    crate::svc_log!("nvim_ade_server: mcp is only implemented on unix-like systems");
    ExitCode::from(1)
}

#[cfg(unix)]
struct Socket {
    responses: std::sync::mpsc::Receiver<Value>,
    writer: std::os::unix::net::UnixStream,
    next_id: u64,
    connected: bool,
}

#[cfg(unix)]
impl Socket {
    fn connect(token: &str) -> Result<(Self, Value), String> {
        let paths = crate::paths::Paths::resolve().map_err(|error| error.to_string())?;
        let stream = std::os::unix::net::UnixStream::connect(paths.socket())
            .map_err(|error| format!("cannot reach the service: {error}"))?;
        let writer = stream.try_clone().map_err(|error| error.to_string())?;
        // A dedicated reader forwards pushed notifications to stdout at once
        // (`notifications/tools/list_changed`, 20.3); responses go to the
        // request that is waiting for them.
        let (sender, responses) = std::sync::mpsc::channel::<Value>();
        std::thread::spawn(move || {
            let reader = BufReader::new(stream);
            for line in reader.lines() {
                let Ok(line) = line else { break };
                let Ok(value) = serde_json::from_str::<Value>(line.trim_end()) else {
                    continue;
                };
                if value.get("method").is_some() {
                    forward(&value);
                } else if sender.send(value).is_err() {
                    break;
                }
            }
        });
        let mut socket = Self {
            responses,
            writer,
            next_id: 9000,
            connected: true,
        };
        let hello = socket.request(
            "hello",
            json!({
                "participant_token": token,
                "client": "nvim_ade_server-mcp",
                "client_version": crate::SERVER_VERSION,
                "api_version": crate::API_VERSION,
            }),
        )?;
        Ok((socket, hello))
    }

    fn request(&mut self, method: &str, params: Value) -> Result<Value, String> {
        if !self.connected {
            return Err("the service connection is closed".to_string());
        }
        self.next_id += 1;
        let id = self.next_id;
        let frame = json!({
            "jsonrpc": "2.0",
            "id": id,
            "method": method,
            "params": params,
        });
        let mut line = serde_json::to_vec(&frame).map_err(|error| error.to_string())?;
        line.push(b'\n');
        if let Err(error) = self
            .writer
            .write_all(&line)
            .and_then(|_| self.writer.flush())
        {
            self.connected = false;
            return Err(format!("the service connection is closed: {error}"));
        }
        loop {
            let value = match self
                .responses
                .recv_timeout(std::time::Duration::from_millis(50))
            {
                Ok(value) => value,
                Err(std::sync::mpsc::RecvTimeoutError::Timeout) => continue,
                Err(std::sync::mpsc::RecvTimeoutError::Disconnected) => {
                    self.connected = false;
                    return Err("the service connection is closed".to_string());
                }
            };
            if value.get("id").and_then(Value::as_u64) != Some(id) {
                continue;
            }
            if let Some(error) = value.get("error") {
                let message = error
                    .get("message")
                    .and_then(Value::as_str)
                    .map(str::to_string)
                    .unwrap_or_else(|| error.to_string());
                let code = error.get("code").and_then(Value::as_i64);
                return Err(match code {
                    Some(code) => format!("{message} ({code})"),
                    None => message,
                });
            }
            return Ok(value.get("result").cloned().unwrap_or(Value::Null));
        }
    }
}

#[cfg(unix)]
fn forward(value: &Value) {
    let mut stdout = std::io::stdout().lock();
    if serde_json::to_writer(&mut stdout, value).is_ok() {
        let _ = stdout.write_all(b"\n");
        let _ = stdout.flush();
    }
}

#[cfg(unix)]
struct Mcp {
    socket: Option<Socket>,
    role: Option<String>,
    token: Option<String>,
    initialized: bool,
}

#[cfg(unix)]
impl Mcp {
    fn new(token: Option<String>) -> Self {
        let mut mcp = Self {
            socket: None,
            role: None,
            token,
            initialized: false,
        };
        if let Some(token) = mcp.token.clone() {
            if let Ok((socket, hello)) = Socket::connect(&token) {
                mcp.role = hello
                    .get("participant")
                    .and_then(|participant| participant.get("role"))
                    .and_then(Value::as_str)
                    .map(str::to_string);
                mcp.socket = Some(socket);
            }
        }
        mcp
    }

    fn serve(&mut self) {
        let stdin = std::io::stdin();
        let mut reader = stdin.lock();
        loop {
            let mut line = String::new();
            match reader.read_line(&mut line) {
                Ok(0) => return,
                Ok(_) => {}
                Err(error)
                    if matches!(
                        error.kind(),
                        std::io::ErrorKind::WouldBlock | std::io::ErrorKind::TimedOut
                    ) =>
                {
                    // stdin itself is blocking; this only happens on a spurious
                    // wakeup. Keep serving.
                    continue;
                }
                Err(_) => return,
            }
            let line = line.trim_end();
            if line.is_empty() {
                continue;
            }
            let Ok(message) = serde_json::from_str::<Value>(line) else {
                self.write(&json!({
                    "jsonrpc": "2.0",
                    "id": Value::Null,
                    "error": { "code": -32700, "message": "parse error" },
                }));
                continue;
            };
            if message.is_array() {
                self.write(&json!({
                    "jsonrpc": "2.0",
                    "id": Value::Null,
                    "error": { "code": -32600, "message": "batch requests are not supported" },
                }));
                continue;
            }
            self.handle(message);
        }
    }

    fn handle(&mut self, message: Value) {
        let Some(object) = message.as_object() else {
            return;
        };
        let id = object.get("id").cloned();
        let Some(method) = object.get("method").and_then(Value::as_str) else {
            // A response from the MCP client has no meaning here.
            return;
        };
        let params = object.get("params").cloned().unwrap_or(Value::Null);
        let Some(id) = id else {
            // Notifications: initialized and anything unknown.
            return;
        };
        let result = match method {
            "initialize" => {
                self.initialized = true;
                let requested = params
                    .get("protocolVersion")
                    .and_then(Value::as_str)
                    .unwrap_or("2025-06-18");
                let version = if requested == "2025-06-18" || requested == "2025-03-26" {
                    requested
                } else {
                    "2025-06-18"
                };
                let mut result = json!({
                    "protocolVersion": version,
                    "capabilities": { "tools": { "listChanged": true } },
                    "serverInfo": {
                        "name": "nvim_ade_server",
                        "version": crate::SERVER_VERSION,
                    },
                });
                if matches!(self.role(), "leader" | "session") {
                    // 19.8/20.3: a leader and every session token get the base
                    // instructions; workers get none.
                    result["instructions"] = json!(crate::team::brief::leader_instructions());
                }
                Ok(result)
            }
            "ping" => Ok(json!({})),
            "tools/list" => Ok(self.tools_list()),
            "tools/call" => self.tools_call(&params),
            _ => Err((-32601, "method not found".to_string())),
        };
        match result {
            Ok(value) => self.write(&json!({
                "jsonrpc": "2.0",
                "id": id,
                "result": value,
            })),
            Err((code, message)) => self.write(&json!({
                "jsonrpc": "2.0",
                "id": id,
                "error": { "code": code, "message": message },
            })),
        }
    }

    fn role(&mut self) -> &str {
        if self.role.is_none() {
            self.role = Some(
                self.socket
                    .as_mut()
                    .and_then(|socket| socket.request("bus.status", json!({})).ok())
                    .and_then(|value| {
                        value
                            .get("self")
                            .and_then(|self_value| self_value.get("role"))
                            .and_then(Value::as_str)
                            .map(str::to_string)
                    })
                    .unwrap_or_else(|| "worker".to_string()),
            );
        }
        self.role.as_deref().unwrap_or("worker")
    }

    /// The session's current (enabled, leader) state, re-read for every
    /// `tools/list` and `tools/call` (20.3).
    fn session_state(&mut self) -> (bool, bool) {
        let raw = self
            .socket
            .as_mut()
            .and_then(|socket| socket.request("bus.status", json!({})).ok());
        // The hub answers tools with the MCP result envelope; the state is the
        // JSON text inside it.
        let value = raw.and_then(|value| match value.get("content") {
            Some(content) => content
                .as_array()?
                .first()?
                .get("text")?
                .as_str()
                .and_then(|text| serde_json::from_str::<Value>(text).ok()),
            None => Some(value),
        });
        match value {
            Some(value) => (
                value
                    .get("enabled")
                    .and_then(Value::as_bool)
                    .unwrap_or(true),
                value
                    .get("leader")
                    .and_then(Value::as_bool)
                    .unwrap_or(false),
            ),
            None => (true, false),
        }
    }

    fn templates(&mut self) -> Vec<Value> {
        self.socket
            .as_mut()
            .and_then(|socket| socket.request("bus.status", json!({})).ok())
            .and_then(|value| value.get("templates").cloned())
            .and_then(|value| value.as_array().cloned())
            .map(|templates| {
                templates
                    .iter()
                    .filter_map(|template| match template {
                        Value::String(name) => Some(json!(name)),
                        Value::Object(_) => template.get("name").cloned(),
                        _ => None,
                    })
                    .collect()
            })
            .unwrap_or_default()
    }

    fn tools_list(&mut self) -> Value {
        let session = self.role() == "session";
        let (enabled, leader) = if session {
            self.session_state()
        } else {
            (true, self.role() == "leader")
        };
        if session && !enabled {
            return json!({ "tools": [] });
        }
        let mut tools = Vec::new();
        if leader || session {
            let templates = self.templates();
            let mut schema = json!({
                "type": "object",
                "properties": {
                    "template": { "type": "string" },
                    "name": { "type": "string" },
                    "model": {
                        "type": "string",
                        "description": "A model from the template's models list; omitted = the template's model."
                    },
                    "role": {
                        "type": "string",
                        "description": "Extra role text appended to the template's role (max 16 KiB)."
                    },
                    "label": {
                        "type": "string",
                        "description": "A short display label (1..16 characters, one line)."
                    },
                    "task": { "type": "string" },
                },
                "required": ["template"],
            });
            if !templates.is_empty() {
                schema["properties"]["template"]["enum"] = json!(templates);
            }
            tools.push(json!({
                "name": "team_spawn",
                "description": "Start a new worker from a configured template.",
                "inputSchema": schema,
            }));
        }
        let mut kinds = vec!["task", "report", "question", "answer", "review", "notice"];
        if leader {
            kinds.push("control");
        }
        if leader || !session {
            tools.push(json!({
                "name": "bus_send",
                "description": "Send a bus message to the leader, another worker or human.",
                "inputSchema": {
                    "type": "object",
                    "properties": {
                        "to": { "type": "string" },
                        "kind": { "type": "string", "enum": kinds },
                        "body": { "type": "string" },
                        "task": { "type": "string" },
                        "refs": { "type": "array", "items": { "type": "string" } },
                    },
                    "required": ["to", "kind", "body"],
                },
            }));
            tools.push(json!({
            "name": "bus_ask_human",
            "description": "Ask the person one question, or up to four questions at once with `questions`.",
            "inputSchema": {
                "type": "object",
                "properties": {
                    "question": { "type": "string" },
                    "options": { "type": "array", "items": { "type": "string" } },
                    "questions": {
                        "type": "array",
                        "minItems": 1,
                        "maxItems": 4,
                        "items": {
                            "type": "object",
                            "properties": {
                                "header": {
                                    "type": "string",
                                    "description": "Tab label, 1..12 characters, one line."
                                },
                                "question": { "type": "string" },
                                "options": {
                                    "type": "array",
                                    "minItems": 0,
                                    "maxItems": 6,
                                    "items": {
                                        "type": "object",
                                        "properties": {
                                            "label": { "type": "string" },
                                            "description": { "type": "string" }
                                        },
                                        "required": ["label"]
                                    }
                                },
                                "multi_select": { "type": "boolean" }
                            },
                            "required": ["header", "question"]
                        }
                    }
                },
            },
        }));
        }
        tools.push(json!({
            "name": "bus_status",
            "description": "List the team's members, states and current tasks.",
            "inputSchema": { "type": "object", "properties": {} },
        }));
        if leader {
            tools.push(json!({
                "name": "bus_read",
                "description": "Read recent messages and turn text for a participant.",
                "inputSchema": {
                    "type": "object",
                    "properties": {
                        "participant": { "type": "string" },
                        "since": { "type": "integer" },
                    },
                    "required": ["participant"],
                },
            }));
            tools.push(json!({
                "name": "board_update",
                "description": "Update the team board: workflow, columns, cards, archive or remove.",
                "inputSchema": {
                    "type": "object",
                    "additionalProperties": false,
                    "properties": {
                        "workflow_name": {
                            "type": ["string", "null"],
                            "description": "Name of the workflow shown on the board; null clears it."
                        },
                        "workflow": {
                            "type": ["string", "null"],
                            "description": "Workflow text, at most 4 KiB; null clears it."
                        },
                        "columns": {
                            "type": "array",
                            "description": "The complete column list, in display order (up to 16 unique titles, 1..40 characters each).",
                            "items": { "type": "string" },
                            "maxItems": 16
                        },
                        "upsert": {
                            "type": "array",
                            "description": "Create cards (id, title and column required) or merge fields into existing cards.",
                            "items": {
                                "type": "object",
                                "additionalProperties": false,
                                "properties": {
                                    "id": {
                                        "type": "string",
                                        "description": "[A-Za-z0-9][A-Za-z0-9_.-]{0,31}"
                                    },
                                    "title": {
                                        "type": "string",
                                        "description": "1..200 characters; required for a new card."
                                    },
                                    "column": {
                                        "type": "string",
                                        "description": "One of the board columns; required for a new card."
                                    },
                                    "owner": {
                                        "type": ["string", "null"],
                                        "description": "A worker name of the team; null clears it."
                                    },
                                    "stage": {
                                        "type": ["string", "null"],
                                        "description": "1..40 characters; null clears it."
                                    },
                                    "body": {
                                        "type": ["string", "null"],
                                        "description": "Card body, at most 8 KiB; null clears it."
                                    },
                                    "fields": {
                                        "type": ["object", "null"],
                                        "description": "Short key/value pairs; merges by key, a null value deletes the key, null clears all.",
                                        "additionalProperties": { "type": ["string", "null"] }
                                    }
                                },
                                "required": ["id"]
                            }
                        },
                        "archive": {
                            "type": "array",
                            "description": "Archive these cards and delete their history.",
                            "items": { "type": "string" }
                        },
                        "remove": {
                            "type": "array",
                            "description": "Delete these cards and their history.",
                            "items": { "type": "string" }
                        }
                    }
                },
            }));
            tools.push(json!({
                "name": "workflow_save",
                "description": "Save a named workflow for this project (or every project with scope \"user\").",
                "inputSchema": {
                    "type": "object",
                    "properties": {
                        "workflow": {
                            "type": "object",
                            "properties": {
                                "name": { "type": "string", "description": "[a-z0-9][a-z0-9_-]{0,31}" },
                                "summary": { "type": "string", "description": "One line, 1..120 characters." },
                                "text": { "type": "string", "description": "The flow text, up to 4 KiB; omitted = the built-in default flow." },
                                "leader": {
                                    "type": "object",
                                    "properties": {
                                        "agent": { "type": "string" },
                                        "model": { "type": "string" },
                                        "role": { "type": "string" },
                                    },
                                },
                                "team": {
                                    "type": "array",
                                    "maxItems": 8,
                                    "items": {
                                        "type": "object",
                                        "properties": {
                                            "name": { "type": "string" },
                                            "template": { "type": "string" },
                                            "model": { "type": "string" },
                                            "role": { "type": "string" },
                                            "task": { "type": "string" },
                                        },
                                        "required": ["name", "template"],
                                    },
                                },
                                "columns": {
                                    "type": "array",
                                    "maxItems": 16,
                                    "items": { "type": "string" },
                                },
                            },
                            "required": ["name", "summary"],
                        },
                        "scope": { "type": "string", "enum": ["project", "user"] },
                        "replace": { "type": "boolean" },
                    },
                    "required": ["workflow"],
                },
            }));
            tools.push(json!({
                "name": "workflow_get",
                "description": "Read a workflow by name, resolved as config, project, user, builtin.",
                "inputSchema": {
                    "type": "object",
                    "properties": { "name": { "type": "string" } },
                    "required": ["name"],
                },
            }));
            tools.push(json!({
                "name": "workflow_delete",
                "description": "Delete a stored workflow (not a configured or built-in one).",
                "inputSchema": {
                    "type": "object",
                    "properties": {
                        "name": { "type": "string" },
                        "scope": { "type": "string", "enum": ["project", "user"] },
                    },
                    "required": ["name"],
                },
            }));
            tools.push(json!({
                "name": "team_stop",
                "description": "Stop one worker (optionally drop it from the team after it exited).",
                "inputSchema": {
                    "type": "object",
                    "properties": {
                        "name": { "type": "string" },
                        "remove": { "type": "boolean" },
                    },
                    "required": ["name"],
                },
            }));
        }
        if !session {
            tools.push(json!({
                "name": "card_update",
                "description": "Update your own card's body and fields, or archive it.",
                "inputSchema": {
                    "type": "object",
                    "additionalProperties": false,
                    "properties": {
                        "card": {
                            "type": "string",
                            "description": "The card id you own."
                        },
                        "body": {
                            "type": ["string", "null"],
                            "description": "Card body, at most 8 KiB; null clears it."
                        },
                        "fields": {
                            "type": ["object", "null"],
                            "description": "Short key/value pairs; merges by key, a null value deletes the key, null clears all.",
                            "additionalProperties": { "type": ["string", "null"] }
                        },
                        "archive": {
                            "type": "boolean",
                            "description": "true archives the card and deletes its history."
                        }
                    },
                    "required": ["card"]
                },
            }));
        }
        json!({ "tools": tools })
    }

    fn tools_call(&mut self, params: &Value) -> Result<Value, (i64, String)> {
        let Some(name) = params.get("name").and_then(Value::as_str) else {
            return Err((-32602, "name is required".to_string()));
        };
        let arguments = params
            .get("arguments")
            .cloned()
            .unwrap_or_else(|| json!({}));
        let session = self.role() == "session";
        let (enabled, leader) = if session {
            self.session_state()
        } else {
            (true, self.role() == "leader")
        };
        if session && !enabled {
            return Ok(error_result("teams are off for this chat"));
        }
        let can_session = session && enabled;
        let can_spawn = leader || can_session;
        let can_workflow = leader || can_session;
        let (method, call) = match name {
            "team_stop" if leader => (
                "bus.stop_worker",
                json!({
                    "name": arguments.get("name"),
                    "remove": arguments.get("remove"),
                }),
            ),
            "team_spawn" if can_spawn => (
                "bus.spawn",
                json!({
                    "template": arguments.get("template"),
                    "name": arguments.get("name"),
                    "model": arguments.get("model"),
                    "role": arguments.get("role"),
                    "label": arguments.get("label"),
                    "task": arguments.get("task"),
                }),
            ),
            "workflow_save" if can_workflow => {
                let mut call = json!({
                    "workflow": arguments.get("workflow"),
                    "replace": arguments.get("replace"),
                });
                if let Some(scope) = arguments.get("scope") {
                    call["scope"] = scope.clone();
                }
                ("bus.workflow_save", call)
            }
            "workflow_get" if can_workflow => {
                ("bus.workflow_get", json!({ "name": arguments.get("name") }))
            }
            "workflow_delete" if can_workflow => {
                let mut call = json!({ "name": arguments.get("name") });
                if let Some(scope) = arguments.get("scope") {
                    call["scope"] = scope.clone();
                }
                ("bus.workflow_delete", call)
            }
            "bus_send" => (
                "bus.send",
                json!({
                    "to": arguments.get("to"),
                    "kind": arguments.get("kind"),
                    "body": arguments.get("body"),
                    "task": arguments.get("task"),
                    "refs": arguments.get("refs"),
                }),
            ),
            "bus_ask_human" => (
                "bus.ask_human",
                json!({
                    "question": arguments.get("question"),
                    "options": arguments.get("options"),
                    "questions": arguments.get("questions"),
                }),
            ),
            "bus_status" => ("bus.status", json!({})),
            "bus_read" if leader => (
                "bus.read",
                json!({
                    "participant": arguments.get("participant"),
                    "since": arguments.get("since"),
                }),
            ),
            // Both board tools reach the service, which owns the role check and
            // returns the documented -32061. `tools/list` still hides the other
            // role's tool.
            "board_update" => ("bus.board_update", arguments),
            // The hub owns the role check and returns the documented -32061.
            "card_update" => ("bus.card_update", arguments),
            "team_spawn" | "bus_read" | "workflow_save" | "workflow_get" | "workflow_delete"
            | "team_stop" => return Ok(error_result("this chat does not lead the team")),
            _ => return Err((-32602, format!("unknown tool {name}"))),
        };
        let Some(socket) = self.socket.as_mut() else {
            let reason = if self.token.is_none() {
                "ADE_TEAM_TOKEN is not set"
            } else {
                "the service connection is closed"
            };
            return Ok(error_result(reason));
        };
        match socket.request(method, call) {
            // Hub-side tool errors already carry the MCP result shape.
            Ok(value) if value.get("isError").is_some() && value.get("content").is_some() => {
                Ok(value)
            }
            Ok(value) => Ok(json!({
                "content": [{ "type": "text", "text": value.to_string() }],
                "isError": false,
            })),
            Err(message) => Ok(error_result(&message)),
        }
    }

    fn write(&self, value: &Value) {
        let mut stdout = std::io::stdout().lock();
        if serde_json::to_writer(&mut stdout, value).is_ok() {
            let _ = stdout.write_all(b"\n");
            let _ = stdout.flush();
        }
    }
}

#[cfg(unix)]
fn error_result(message: &str) -> Value {
    json!({
        "content": [{ "type": "text", "text": message }],
        "isError": true,
    })
}
