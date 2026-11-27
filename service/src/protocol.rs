//! JSON-RPC 2.0 with one message per line, plus the small set of service
//! methods that do not need the hub (`hello`, `ping`, `shutdown`).
//!
//! Everything else (`agent.*`, `tunnel.send`) is dispatched by
//! [`crate::server`] into [`crate::hub`]. The relay rules themselves live in
//! [`crate::relay`].

use std::io;

use serde_json::{json, Value};
use tokio::io::{AsyncBufRead, AsyncBufReadExt, AsyncWrite, AsyncWriteExt};

use crate::team::{ParticipantAuth, SharedTokens, PARTICIPANT_METHOD};

/// Standard JSON-RPC errors.
pub const PARSE_ERROR: i64 = -32700;
pub const INVALID_REQUEST: i64 = -32600;
pub const METHOD_NOT_FOUND: i64 = -32601;
pub const INVALID_PARAMS: i64 = -32602;
pub const INTERNAL_ERROR: i64 = -32603;

/// Service errors, fixed by `service/PROTOCOL.md` section 4.
pub const INVALID_TOKEN: i64 = -32001;
pub const INCOMPATIBLE_API_VERSION: i64 = -32002;
pub const HELLO_REQUIRED: i64 = -32003;
pub const UNKNOWN_INSTANCE: i64 = -32020;
pub const SPAWN_FAILED: i64 = -32022;
pub const CAPABILITIES_DIFFER: i64 = -32023;
pub const NOT_ATTACHED: i64 = -32024;
pub const FRAME_REJECTED: i64 = -32025;
/// The agent does not support `session/list` (PROTOCOL.md 21.6).
pub const SESSIONS_LIST_UNSUPPORTED: i64 = -32070;
/// Listing timed out (PROTOCOL.md 21.6).
pub const SESSIONS_LIST_TIMEOUT: i64 = -32071;
/// The agent process exited during the listing (PROTOCOL.md 21.6).
pub const SESSIONS_LIST_EXITED: i64 = -32072;
/// The agent does not support `session/delete` (PROTOCOL.md 21.8).
pub const SESSIONS_DELETE_UNSUPPORTED: i64 = -32073;
/// The session is in use by a running instance (PROTOCOL.md 21.8).
pub const SESSIONS_DELETE_IN_USE: i64 = -32074;

/// Maximum length of one line in either direction (PROTOCOL.md section 2).
pub const MAX_MESSAGE_BYTES: usize = 64 * 1024 * 1024;

/// Features advertised by `hello` with the event log disabled.
#[cfg(unix)]
pub const FEATURES: &[&str] = &["tunnel", "install", "policy", "sessions", "sessions.delete"];
#[cfg(not(unix))]
pub const FEATURES: &[&str] = &["tunnel", "policy", "sessions", "sessions.delete"];
/// Features advertised by `hello` with the event log enabled (PROTOCOL.md 3.1
/// and 10). `"sessions"` is present in both cases (PROTOCOL.md 21).
#[cfg(unix)]
pub const FEATURES_WITH_LOG: &[&str] = &[
    "tunnel",
    "install",
    "policy",
    "log",
    "teams",
    "sessions",
    "sessions.delete",
];
#[cfg(not(unix))]
pub const FEATURES_WITH_LOG: &[&str] = &[
    "tunnel",
    "policy",
    "log",
    "teams",
    "sessions",
    "sessions.delete",
];

/// The `features` list for one service configuration.
pub fn features(log_enabled: bool) -> &'static [&'static str] {
    if log_enabled {
        FEATURES_WITH_LOG
    } else {
        FEATURES
    }
}

/// One line read from a peer.
#[derive(Debug, PartialEq)]
pub enum Line {
    /// End of stream.
    Eof,
    /// A line, without its terminating newline.
    Text(String),
    /// A line longer than the limit; it has been consumed and must be
    /// discarded. The value is the number of bytes read (at least the limit).
    TooLong(usize),
}

/// Read one `\n`-terminated line, consuming at most `max` bytes of content.
///
/// An over-long line is consumed up to and including its newline, so the
/// stream can be read again afterwards.
pub async fn read_line_limited<R>(reader: &mut R, max: usize) -> io::Result<Line>
where
    R: AsyncBufRead + Unpin,
{
    let mut line = Vec::new();
    let mut overflow_total = 0usize;
    loop {
        let available = reader.fill_buf().await?;
        if available.is_empty() {
            return if overflow_total > 0 {
                Ok(Line::TooLong(overflow_total))
            } else if line.is_empty() {
                Ok(Line::Eof)
            } else {
                strip_carriage_return(&mut line);
                Ok(Line::Text(to_text(line)?))
            };
        }

        match available.iter().position(|byte| *byte == b'\n') {
            Some(position) => {
                if overflow_total > 0 || line.len() + position > max {
                    let total = overflow_total + line.len() + position;
                    reader.consume(position + 1);
                    return Ok(Line::TooLong(total));
                }
                line.extend_from_slice(&available[..position]);
                reader.consume(position + 1);
                strip_carriage_return(&mut line);
                return Ok(Line::Text(to_text(line)?));
            }
            None => {
                if overflow_total > 0 || line.len() + available.len() > max {
                    overflow_total += line.len() + available.len();
                    line.clear();
                    let length = available.len();
                    reader.consume(length);
                    continue;
                }
                line.extend_from_slice(available);
                let length = available.len();
                reader.consume(length);
            }
        }
    }
}

fn strip_carriage_return(line: &mut Vec<u8>) {
    if line.last() == Some(&b'\r') {
        line.pop();
    }
}

fn to_text(line: Vec<u8>) -> io::Result<String> {
    String::from_utf8(line)
        .map_err(|_| io::Error::new(io::ErrorKind::InvalidData, "message is not UTF-8"))
}

/// Read one message line for the front-end connection.
///
/// `Ok(None)` is a clean end of stream; an over-long or non-UTF-8 line is an
/// [`io::ErrorKind::InvalidData`] error, because the stream cannot be
/// resynchronised with the peer's expectations.
pub async fn read_message<R>(reader: &mut R, max: usize) -> io::Result<Option<String>>
where
    R: AsyncBufRead + Unpin,
{
    match read_line_limited(reader, max).await? {
        Line::Eof => Ok(None),
        Line::Text(text) => Ok(Some(text)),
        Line::TooLong(bytes) => Err(io::Error::new(
            io::ErrorKind::InvalidData,
            format!("message exceeds {max} bytes (read {bytes})"),
        )),
    }
}

/// Write a value as one line and flush it.
pub async fn write_message<W>(writer: &mut W, value: &Value) -> io::Result<()>
where
    W: AsyncWrite + Unpin,
{
    let mut bytes = serde_json::to_vec(value)
        .map_err(|error| io::Error::new(io::ErrorKind::InvalidData, error))?;
    bytes.push(b'\n');
    writer.write_all(&bytes).await?;
    writer.flush().await
}

/// A JSON-RPC success response.
pub fn success(id: &Value, result: Value) -> Value {
    json!({ "jsonrpc": "2.0", "id": id, "result": result })
}

/// A JSON-RPC error response.
pub fn failure(id: &Value, code: i64, message: &str) -> Value {
    json!({
        "jsonrpc": "2.0",
        "id": id,
        "error": { "code": code, "message": message },
    })
}

/// Per-connection state: whether `hello` succeeded yet.
#[derive(Debug, Default)]
pub struct Handshake {
    authenticated: bool,
    client: Option<String>,
    client_version: Option<String>,
    /// Set for a team participant connection (`hello.participant_token`).
    participant: Option<ParticipantAuth>,
}

impl Handshake {
    pub fn is_authenticated(&self) -> bool {
        self.authenticated
    }

    pub fn client(&self) -> Option<&str> {
        self.client.as_deref()
    }

    pub fn client_version(&self) -> Option<&str> {
        self.client_version.as_deref()
    }

    pub fn participant(&self) -> Option<&ParticipantAuth> {
        self.participant.as_ref()
    }
}

/// What to do with one front-end frame.
#[derive(Debug, PartialEq)]
pub enum Local {
    /// Send this response, keep the connection open.
    Reply(Value),
    /// Send this response, then close the connection.
    Close(Value),
    /// Send this response, then shut the service down.
    Shutdown(Value),
    /// Not a local method: hand it to the hub.
    Route,
}

/// Handle the methods that do not need the hub.
///
/// `frame` must be a JSON object. Anything without a `method`, or with an
/// unknown method, is routed so the caller reports the right error.
pub fn handle_local(handshake: &mut Handshake, token: &str, frame: &Value) -> Local {
    handle_local_with(handshake, token, frame, true)
}

/// Like [`handle_local`], with an explicit event-log setting for `features`.
pub fn handle_local_with(
    handshake: &mut Handshake,
    token: &str,
    frame: &Value,
    log_enabled: bool,
) -> Local {
    handle_local_with_tokens(handshake, token, frame, log_enabled, None)
}

/// Like [`handle_local_with`], with the team participant token registry.
pub fn handle_local_with_tokens(
    handshake: &mut Handshake,
    token: &str,
    frame: &Value,
    log_enabled: bool,
    participants: Option<&SharedTokens>,
) -> Local {
    let Some(object) = frame.as_object() else {
        return Local::Reply(failure(&Value::Null, PARSE_ERROR, "parse error"));
    };
    let id = object.get("id").cloned().unwrap_or(Value::Null);
    let is_notification = !object.contains_key("id");

    if let Some(version) = object.get("jsonrpc") {
        if version != "2.0" {
            return reject(is_notification, &id, INVALID_REQUEST, "invalid request");
        }
    }

    let Some(method) = object.get("method").and_then(Value::as_str) else {
        return reject(is_notification, &id, INVALID_REQUEST, "invalid request");
    };

    if method != "hello" && !handshake.authenticated {
        return reject(is_notification, &id, HELLO_REQUIRED, "hello required");
    }

    if handshake.participant.is_some() && method != "hello" && !method.starts_with("bus.") {
        return reject(
            is_notification,
            &id,
            PARTICIPANT_METHOD,
            "method not available on a participant connection",
        );
    }

    match method {
        "hello" => hello(
            handshake,
            token,
            object,
            &id,
            is_notification,
            log_enabled,
            participants,
        ),
        "ping" => Local::Reply(success(&id, json!({}))),
        "shutdown" => {
            if is_notification {
                // A notification shutdown still stops the service; it just has
                // no reply.
                Local::Shutdown(Value::Null)
            } else {
                Local::Shutdown(success(&id, json!({})))
            }
        }
        _ => Local::Route,
    }
}

/// An error frame, or nothing at all when the frame was a notification
/// (JSON-RPC: a notification is never answered).
fn reject(is_notification: bool, id: &Value, code: i64, message: &str) -> Local {
    if is_notification {
        Local::Reply(Value::Null)
    } else {
        Local::Reply(failure(id, code, message))
    }
}

fn hello(
    handshake: &mut Handshake,
    token: &str,
    object: &serde_json::Map<String, Value>,
    id: &Value,
    is_notification: bool,
    log_enabled: bool,
    participants: Option<&SharedTokens>,
) -> Local {
    let Some(params) = object.get("params").and_then(Value::as_object) else {
        return reject(is_notification, id, INVALID_PARAMS, "invalid params");
    };
    let participant_token = params.get("participant_token").and_then(Value::as_str);
    let participant = match participant_token {
        Some(candidate) => {
            let Some(participants) = participants else {
                return Local::Close(failure(id, INVALID_TOKEN, "invalid token"));
            };
            match crate::team::authenticate(participants, candidate) {
                Some(auth) => Some(auth),
                None => return Local::Close(failure(id, INVALID_TOKEN, "invalid token")),
            }
        }
        None => {
            let Some(candidate) = params.get("token").and_then(Value::as_str) else {
                // A missing token is as bad as a wrong one: the contract closes
                // the connection in both cases.
                return Local::Close(failure(id, INVALID_TOKEN, "invalid token"));
            };
            if !crate::token::tokens_match(token, candidate) {
                return Local::Close(failure(id, INVALID_TOKEN, "invalid token"));
            }
            None
        }
    };
    let Some(requested) = params.get("api_version").and_then(Value::as_i64) else {
        return reject(is_notification, id, INVALID_PARAMS, "invalid params");
    };
    if requested != crate::API_VERSION {
        if is_notification {
            return Local::Reply(Value::Null);
        }
        return Local::Reply(json!({
            "jsonrpc": "2.0",
            "id": id,
            "error": {
                "code": INCOMPATIBLE_API_VERSION,
                "message": "incompatible api_version",
                "data": { "server_api_version": crate::API_VERSION },
            },
        }));
    }

    handshake.authenticated = true;
    handshake.client = params
        .get("client")
        .and_then(Value::as_str)
        .map(str::to_string);
    handshake.client_version = params
        .get("client_version")
        .and_then(Value::as_str)
        .map(str::to_string);
    handshake.participant = participant;

    if is_notification {
        return Local::Reply(Value::Null);
    }
    let mut result = json!({
        "server_version": crate::SERVER_VERSION,
        "api_version": crate::API_VERSION,
        "features": if handshake.participant.is_some() { json!([]) } else { json!(features(log_enabled)) },
    });
    if let Some(participant) = &handshake.participant {
        result["participant"] = json!({
            "token_id": participant.token_id,
            "role": participant.role.as_str(),
            "name": participant.name,
            "team": participant.team,
        });
    }
    Local::Reply(success(id, result))
}

/// The JSON-RPC error code of a failing response, if it is one.
pub fn error_code(response: &Value) -> Option<i64> {
    response
        .get("error")
        .and_then(|error| error.get("code"))
        .and_then(Value::as_i64)
}

#[cfg(test)]
mod tests {
    use super::*;

    const TOKEN: &str = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef";

    fn hello_frame(token: &str, api_version: i64) -> Value {
        json!({
            "jsonrpc": "2.0",
            "id": 1,
            "method": "hello",
            "params": {
                "token": token,
                "client": "ade.nvim",
                "client_version": "0.0.0",
                "api_version": api_version,
            }
        })
    }

    fn reply(local: &Local) -> &Value {
        match local {
            Local::Reply(value) | Local::Close(value) | Local::Shutdown(value) => value,
            Local::Route => panic!("expected a response, got Route"),
        }
    }

    #[tokio::test]
    async fn framing_splits_on_newlines() {
        let mut reader = b"{\"a\":1}\n{\"b\":2}\n".as_slice();
        assert_eq!(
            read_message(&mut reader, 1024).await.unwrap().as_deref(),
            Some("{\"a\":1}")
        );
        assert_eq!(
            read_message(&mut reader, 1024).await.unwrap().as_deref(),
            Some("{\"b\":2}")
        );
        assert_eq!(read_message(&mut reader, 1024).await.unwrap(), None);
    }

    #[tokio::test]
    async fn framing_accepts_a_final_line_without_newline() {
        let mut reader = b"{\"a\":1}".as_slice();
        assert_eq!(
            read_message(&mut reader, 1024).await.unwrap().as_deref(),
            Some("{\"a\":1}")
        );
        assert_eq!(read_message(&mut reader, 1024).await.unwrap(), None);
    }

    #[tokio::test]
    async fn framing_strips_carriage_returns() {
        let mut reader = b"{\"a\":1}\r\n".as_slice();
        assert_eq!(
            read_message(&mut reader, 1024).await.unwrap().as_deref(),
            Some("{\"a\":1}")
        );
    }

    #[tokio::test]
    async fn framing_reports_oversized_lines_and_recovers() {
        let big = vec![b'x'; 20];
        let mut input = big;
        input.push(b'\n');
        input.extend_from_slice(b"ok\n");
        let mut reader = input.as_slice();
        assert_eq!(
            read_line_limited(&mut reader, 10).await.unwrap(),
            Line::TooLong(20)
        );
        assert_eq!(
            read_line_limited(&mut reader, 10).await.unwrap(),
            Line::Text("ok".to_string())
        );
    }

    #[tokio::test]
    async fn framing_reports_oversized_lines_without_a_trailing_newline() {
        let mut input = vec![b'x'; 20];
        let mut reader = input.as_slice();
        assert_eq!(
            read_line_limited(&mut reader, 10).await.unwrap(),
            Line::TooLong(20)
        );
        assert_eq!(read_line_limited(&mut reader, 10).await.unwrap(), Line::Eof);
        input.clear();
    }

    #[tokio::test]
    async fn framing_rejects_invalid_utf8() {
        let mut reader = &b"\xff\xfe\n"[..];
        let error = read_message(&mut reader, 1024).await.unwrap_err();
        assert_eq!(error.kind(), io::ErrorKind::InvalidData);
    }

    #[tokio::test]
    async fn writing_appends_one_newline() {
        let mut output = Vec::new();
        write_message(&mut output, &json!({"ok": true}))
            .await
            .unwrap();
        assert_eq!(output, b"{\"ok\":true}\n");
    }

    #[test]
    fn hello_succeeds_and_reports_the_protocol() {
        let mut handshake = Handshake::default();
        let local = handle_local(
            &mut handshake,
            TOKEN,
            &hello_frame(TOKEN, crate::API_VERSION),
        );
        assert!(handshake.is_authenticated());
        let response = reply(&local);
        assert_eq!(response["result"]["server_version"], crate::SERVER_VERSION);
        assert_eq!(response["result"]["api_version"], crate::API_VERSION);
        assert_eq!(response["result"]["features"], json!(features(true)));
        assert_eq!(handshake.client(), Some("ade.nvim"));
    }

    #[test]
    fn features_depend_on_the_event_log_setting() {
        let mut handshake = Handshake::default();
        let local = handle_local_with(
            &mut handshake,
            TOKEN,
            &hello_frame(TOKEN, crate::API_VERSION),
            false,
        );
        assert_eq!(reply(&local)["result"]["features"], json!(features(false)));

        let mut handshake = Handshake::default();
        let local = handle_local_with(
            &mut handshake,
            TOKEN,
            &hello_frame(TOKEN, crate::API_VERSION),
            true,
        );
        assert_eq!(reply(&local)["result"]["features"], json!(features(true)));
    }

    #[test]
    fn hello_with_a_bad_token_is_rejected_and_closes() {
        let mut handshake = Handshake::default();
        let local = handle_local(&mut handshake, TOKEN, &hello_frame(&"f".repeat(64), 2));
        assert!(!handshake.is_authenticated());
        assert!(matches!(local, Local::Close(_)));
        let response = reply(&local);
        assert_eq!(error_code(response), Some(INVALID_TOKEN));
        assert_eq!(response["error"]["message"], "invalid token");
    }

    #[test]
    fn hello_without_a_token_is_rejected_and_closes() {
        let mut handshake = Handshake::default();
        let frame = json!({"jsonrpc": "2.0", "id": 1, "method": "hello", "params": {}});
        let local = handle_local(&mut handshake, TOKEN, &frame);
        assert!(matches!(local, Local::Close(_)));
        assert_eq!(error_code(reply(&local)), Some(INVALID_TOKEN));
    }

    #[test]
    fn hello_with_an_incompatible_api_version_reports_the_server_version() {
        let mut handshake = Handshake::default();
        let local = handle_local(&mut handshake, TOKEN, &hello_frame(TOKEN, 1));
        assert!(!handshake.is_authenticated());
        assert!(matches!(local, Local::Reply(_)));
        let response = reply(&local);
        assert_eq!(error_code(response), Some(INCOMPATIBLE_API_VERSION));
        assert_eq!(
            response["error"]["data"]["server_api_version"],
            crate::API_VERSION
        );
    }

    #[test]
    fn hello_without_api_version_is_an_invalid_params_error() {
        let mut handshake = Handshake::default();
        let frame = json!({
            "jsonrpc": "2.0",
            "id": 1,
            "method": "hello",
            "params": { "token": TOKEN }
        });
        let local = handle_local(&mut handshake, TOKEN, &frame);
        assert_eq!(error_code(reply(&local)), Some(INVALID_PARAMS));
        assert!(!handshake.is_authenticated());
    }

    #[test]
    fn methods_before_hello_are_rejected() {
        let mut handshake = Handshake::default();
        let frame = json!({"jsonrpc": "2.0", "id": 7, "method": "agent.list"});
        let response = reply(&handle_local(&mut handshake, TOKEN, &frame)).clone();
        assert_eq!(error_code(&response), Some(HELLO_REQUIRED));
        assert_eq!(response["error"]["message"], "hello required");
        assert_eq!(response["id"], 7);
    }

    #[test]
    fn notifications_before_hello_get_no_response() {
        let mut handshake = Handshake::default();
        let frame = json!({"jsonrpc": "2.0", "method": "tunnel.send", "params": {}});
        // Notifications are never answered, errors included.
        assert_eq!(
            handle_local(&mut handshake, TOKEN, &frame),
            Local::Reply(Value::Null)
        );
        assert!(!handshake.is_authenticated());
    }

    #[test]
    fn ping_after_hello_returns_an_empty_object() {
        let mut handshake = Handshake::default();
        handle_local(
            &mut handshake,
            TOKEN,
            &hello_frame(TOKEN, crate::API_VERSION),
        );
        let frame = json!({"jsonrpc": "2.0", "id": "abc", "method": "ping"});
        let local = handle_local(&mut handshake, TOKEN, &frame);
        assert_eq!(reply(&local)["result"], json!({}));
        assert_eq!(reply(&local)["id"], "abc");
    }

    #[test]
    fn shutdown_after_hello_is_a_shutdown() {
        let mut handshake = Handshake::default();
        handle_local(
            &mut handshake,
            TOKEN,
            &hello_frame(TOKEN, crate::API_VERSION),
        );
        let frame = json!({"jsonrpc": "2.0", "id": 9, "method": "shutdown"});
        let local = handle_local(&mut handshake, TOKEN, &frame);
        assert!(matches!(local, Local::Shutdown(_)));
        assert_eq!(reply(&local)["result"], json!({}));
    }

    #[test]
    fn shutdown_before_hello_is_an_error() {
        let mut handshake = Handshake::default();
        let frame = json!({"jsonrpc": "2.0", "id": 9, "method": "shutdown"});
        let local = handle_local(&mut handshake, TOKEN, &frame);
        assert!(!matches!(local, Local::Shutdown(_)));
        assert_eq!(error_code(reply(&local)), Some(HELLO_REQUIRED));
    }

    #[test]
    fn agent_methods_are_routed() {
        let mut handshake = Handshake::default();
        handle_local(
            &mut handshake,
            TOKEN,
            &hello_frame(TOKEN, crate::API_VERSION),
        );
        for method in [
            "agent.attach",
            "agent.detach",
            "agent.stop",
            "agent.list",
            "tunnel.send",
        ] {
            let frame = json!({"jsonrpc": "2.0", "id": 1, "method": method, "params": {}});
            assert_eq!(
                handle_local(&mut handshake, TOKEN, &frame),
                Local::Route,
                "{method} must be routed"
            );
        }
    }

    #[test]
    fn invalid_json_frames_are_parse_errors() {
        let mut handshake = Handshake::default();
        let local = handle_local(&mut handshake, TOKEN, &json!("text"));
        assert_eq!(error_code(reply(&local)), Some(PARSE_ERROR));
    }

    #[test]
    fn a_frame_without_a_method_is_invalid() {
        let mut handshake = Handshake::default();
        let frame = json!({"jsonrpc": "2.0", "id": 1});
        assert_eq!(
            error_code(reply(&handle_local(&mut handshake, TOKEN, &frame))),
            Some(INVALID_REQUEST)
        );
    }
}

#[cfg(test)]
mod big_line_tests {
    use super::*;
    use tokio::io::BufReader;

    /// The limit of PROTOCOL.md section 6, above the one of section 2.
    const AGENT_LIMIT: usize = 32 * 1024 * 1024;

    #[tokio::test]
    async fn a_huge_line_is_dropped_and_reading_resumes() {
        let mut data = vec![b'x'; AGENT_LIMIT + 1];
        data.push(b'\n');
        data.extend_from_slice(b"{\"ok\":1}\n");
        let mut reader = BufReader::with_capacity(8 * 1024, &data[..]);
        let line = read_line_limited(&mut reader, AGENT_LIMIT)
            .await
            .expect("read");
        assert!(matches!(line, Line::TooLong(_)), "got {line:?}");
        let line = read_line_limited(&mut reader, AGENT_LIMIT)
            .await
            .expect("read next");
        assert_eq!(line, Line::Text("{\"ok\":1}".to_string()));
    }
}
