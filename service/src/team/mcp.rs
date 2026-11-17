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
    eprintln!("nvim_ade_server: mcp is only implemented on unix-like systems");
    ExitCode::from(1)
}

#[cfg(unix)]
struct Socket {
    reader: BufReader<std::os::unix::net::UnixStream>,
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
        let mut socket = Self {
            reader: BufReader::new(stream),
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
            let mut response = String::new();
            match self.reader.read_line(&mut response) {
                Ok(0) => {
                    self.connected = false;
                    return Err("the service connection is closed".to_string());
                }
                Ok(_) => {}
                Err(error) => {
                    self.connected = false;
                    return Err(format!("the service connection is closed: {error}"));
                }
            }
            let Ok(value) = serde_json::from_str::<Value>(response.trim_end()) else {
                continue;
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
                return Err(message);
            }
            return Ok(value.get("result").cloned().unwrap_or(Value::Null));
        }
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
                Ok(json!({
                    "protocolVersion": version,
                    "capabilities": { "tools": {} },
                    "serverInfo": {
                        "name": "nvim_ade_server",
                        "version": crate::SERVER_VERSION,
                    },
                }))
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

    fn templates(&mut self) -> Vec<Value> {
        self.socket
            .as_mut()
            .and_then(|socket| socket.request("bus.status", json!({})).ok())
            .and_then(|value| value.get("templates").cloned())
            .and_then(|value| value.as_array().cloned())
            .unwrap_or_default()
    }

    fn tools_list(&mut self) -> Value {
        let leader = self.role() == "leader";
        let mut tools = Vec::new();
        if leader {
            let templates = self.templates();
            let mut schema = json!({
                "type": "object",
                "properties": {
                    "template": { "type": "string" },
                    "name": { "type": "string" },
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
            "description": "Ask the person a question and wait for an answer.",
            "inputSchema": {
                "type": "object",
                "properties": {
                    "question": { "type": "string" },
                    "options": { "type": "array", "items": { "type": "string" } },
                },
                "required": ["question"],
            },
        }));
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
        let leader = self.role() == "leader";
        let (method, call) = match name {
            "team_spawn" if leader => (
                "bus.spawn",
                json!({
                    "template": arguments.get("template"),
                    "name": arguments.get("name"),
                    "task": arguments.get("task"),
                }),
            ),
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
            "team_spawn" | "bus_read" => {
                return Ok(error_result("this tool is only available to the leader"))
            }
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
