//! JSON-RPC 2.0 with one message per line.
//!
//! Only the small subset needed by S0 is implemented: `hello`, `ping` and
//! `shutdown`, plus the standard JSON-RPC error codes for everything else.
//! Connection state (has this client said hello?) lives in [`Handshake`], so
//! the whole dispatch can be unit tested without sockets.

use std::io;

use serde::Deserialize;
use serde_json::{json, Value};
use tokio::io::{AsyncBufRead, AsyncBufReadExt, AsyncWrite, AsyncWriteExt};

/// Standard JSON-RPC errors.
pub const PARSE_ERROR: i64 = -32700;
pub const INVALID_REQUEST: i64 = -32600;
pub const METHOD_NOT_FOUND: i64 = -32601;
pub const INVALID_PARAMS: i64 = -32602;
pub const INTERNAL_ERROR: i64 = -32603;

/// Service-specific errors, fixed by `.acp-work/contract.md`.
pub const INVALID_TOKEN: i64 = -32001;
pub const INCOMPATIBLE_API_VERSION: i64 = -32002;
pub const HELLO_REQUIRED: i64 = -32003;

/// Upper bound for a single line, so a broken client cannot exhaust memory.
pub const MAX_MESSAGE_BYTES: usize = 1024 * 1024;

/// Read one `\n`-terminated line, enforcing [`MAX_MESSAGE_BYTES`].
///
/// Returns `Ok(None)` on a clean end of stream.
pub async fn read_message<R>(reader: &mut R) -> io::Result<Option<String>>
where
    R: AsyncBufRead + Unpin,
{
    let mut line = Vec::new();
    loop {
        let available = reader.fill_buf().await?;
        if available.is_empty() {
            if line.is_empty() {
                return Ok(None);
            }
            break;
        }
        match available.iter().position(|byte| *byte == b'\n') {
            Some(position) => {
                if line.len() + position > MAX_MESSAGE_BYTES {
                    return Err(io::Error::new(
                        io::ErrorKind::InvalidData,
                        "message exceeds the maximum size",
                    ));
                }
                line.extend_from_slice(&available[..position]);
                reader.consume(position + 1);
                break;
            }
            None => {
                if line.len() + available.len() > MAX_MESSAGE_BYTES {
                    return Err(io::Error::new(
                        io::ErrorKind::InvalidData,
                        "message exceeds the maximum size",
                    ));
                }
                line.extend_from_slice(available);
                let length = available.len();
                reader.consume(length);
            }
        }
    }
    // Tolerate CRLF from clients that add it.
    if line.last() == Some(&b'\r') {
        line.pop();
    }
    let text = String::from_utf8(line)
        .map_err(|_| io::Error::new(io::ErrorKind::InvalidData, "message is not UTF-8"))?;
    Ok(Some(text))
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

/// What the connection loop should do after one request.
#[derive(Debug, Default, PartialEq)]
pub struct Outcome {
    /// Response to send, if the request was not a notification.
    pub response: Option<Value>,
    /// Close this connection after sending the response.
    pub close: bool,
    /// Stop the whole service after sending the response.
    pub shutdown: bool,
}

/// Per-connection state: whether `hello` succeeded yet.
#[derive(Debug, Default)]
pub struct Handshake {
    authenticated: bool,
    client: Option<String>,
    client_version: Option<String>,
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
}

#[derive(Debug, Deserialize)]
struct Request {
    #[serde(default)]
    jsonrpc: Option<String>,
    #[serde(default)]
    id: Option<Value>,
    #[serde(default)]
    method: Option<String>,
    #[serde(default)]
    params: Option<Value>,
}

#[derive(Debug, Deserialize)]
struct HelloParams {
    #[serde(default)]
    token: Option<String>,
    #[serde(default)]
    client: Option<String>,
    #[serde(default)]
    client_version: Option<String>,
    #[serde(default)]
    api_version: Option<Value>,
}

/// How to react to one incoming line.
#[derive(Debug, PartialEq)]
enum Dispatch {
    Reply(Value),
    CloseAfter(Value),
    Shutdown(Value),
}

impl Dispatch {
    fn into_outcome(self) -> Outcome {
        match self {
            Self::Reply(response) => Outcome {
                response: Some(response),
                ..Outcome::default()
            },
            Self::CloseAfter(response) => Outcome {
                response: Some(response),
                close: true,
                ..Outcome::default()
            },
            Self::Shutdown(response) => Outcome {
                response: Some(response),
                shutdown: true,
                ..Outcome::default()
            },
        }
    }
}

fn success(id: &Option<Value>, result: Value) -> Value {
    json!({ "jsonrpc": "2.0", "id": id.clone().unwrap_or(Value::Null), "result": result })
}

fn failure(id: &Option<Value>, code: i64, message: &str, data: Option<Value>) -> Value {
    let mut error = json!({ "code": code, "message": message });
    if let Some(data) = data {
        error["data"] = data;
    }
    json!({ "jsonrpc": "2.0", "id": id.clone().unwrap_or(Value::Null), "error": error })
}

/// Handle one line of input. `expected_token` is the token of this service
/// instance; `api_version` is the protocol version the service speaks.
pub fn handle_line(
    handshake: &mut Handshake,
    expected_token: &str,
    api_version: i64,
    line: &str,
) -> Outcome {
    let request: Request = match serde_json::from_str(line) {
        Ok(request) => request,
        Err(_) => {
            return Outcome {
                response: Some(failure(
                    &None,
                    PARSE_ERROR,
                    "parse error",
                    Some(json!({ "detail": "invalid JSON" })),
                )),
                ..Outcome::default()
            }
        }
    };

    let id = request.id.clone();
    let is_notification = id.is_none();
    let dispatch = match route(handshake, expected_token, api_version, request) {
        Ok(dispatch) => dispatch,
        // A bad token closes the connection right after the error response.
        Err((INVALID_TOKEN, message, data)) => {
            Dispatch::CloseAfter(failure(&id, INVALID_TOKEN, message, data))
        }
        Err((code, message, data)) => Dispatch::Reply(failure(&id, code, message, data)),
    };
    let mut outcome = dispatch.into_outcome();
    // A notification never gets a response, not even an error one.
    if is_notification {
        outcome.response = None;
    }
    outcome
}

type RouteError = (i64, &'static str, Option<Value>);

fn route(
    handshake: &mut Handshake,
    expected_token: &str,
    api_version: i64,
    request: Request,
) -> Result<Dispatch, RouteError> {
    let id = request.id.clone();
    let method = match request.method {
        Some(method) => method,
        None => {
            return Err((INVALID_REQUEST, "invalid request", None));
        }
    };
    if let Some(version) = &request.jsonrpc {
        if version != "2.0" {
            return Err((INVALID_REQUEST, "invalid request", None));
        }
    }

    if method != "hello" && !handshake.authenticated {
        return Err((
            HELLO_REQUIRED,
            "hello required",
            Some(json!({ "hint": "send hello before any other method" })),
        ));
    }

    match method.as_str() {
        "hello" => {
            let params = request
                .params
                .ok_or((INVALID_PARAMS, "invalid params", None))?;
            let params: HelloParams = serde_json::from_value(params)
                .map_err(|_| (INVALID_PARAMS, "invalid params", None))?;
            let token = params.token.unwrap_or_default();
            if !crate::token::tokens_match(expected_token, &token) {
                return Err((INVALID_TOKEN, "invalid token", None));
            }
            let requested = match params.api_version {
                Some(Value::Number(number)) => number.as_i64(),
                Some(_) => None,
                None => None,
            };
            let requested = match requested {
                Some(version) => version,
                None => return Err((INVALID_PARAMS, "invalid params", None)),
            };
            if requested != api_version {
                return Err((
                    INCOMPATIBLE_API_VERSION,
                    "incompatible api_version",
                    Some(json!({ "server_api_version": api_version })),
                ));
            }
            handshake.authenticated = true;
            handshake.client = params.client;
            handshake.client_version = params.client_version;
            Ok(Dispatch::Reply(success(
                &id,
                json!({
                    "server_version": crate::SERVER_VERSION,
                    "api_version": api_version,
                    "features": [],
                }),
            )))
        }
        "ping" => Ok(Dispatch::Reply(success(&id, json!({})))),
        "shutdown" => Ok(Dispatch::Shutdown(success(&id, json!({})))),
        _ => Err((METHOD_NOT_FOUND, "method not found", None)),
    }
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

    fn hello(token: &str, api_version: i64) -> String {
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
        .to_string()
    }

    fn reply(outcome: &Outcome) -> &Value {
        outcome.response.as_ref().expect("has a response")
    }

    #[tokio::test]
    async fn framing_splits_on_newlines() {
        let input = b"{\"a\":1}\n{\"b\":2}\n";
        let mut reader = input.as_slice();
        assert_eq!(
            read_message(&mut reader).await.unwrap().as_deref(),
            Some("{\"a\":1}")
        );
        assert_eq!(
            read_message(&mut reader).await.unwrap().as_deref(),
            Some("{\"b\":2}")
        );
        assert_eq!(read_message(&mut reader).await.unwrap(), None);
    }

    #[tokio::test]
    async fn framing_accepts_a_final_line_without_newline() {
        let mut reader = b"{\"a\":1}".as_slice();
        assert_eq!(
            read_message(&mut reader).await.unwrap().as_deref(),
            Some("{\"a\":1}")
        );
        assert_eq!(read_message(&mut reader).await.unwrap(), None);
    }

    #[tokio::test]
    async fn framing_strips_carriage_returns() {
        let mut reader = b"{\"a\":1}\r\n".as_slice();
        assert_eq!(
            read_message(&mut reader).await.unwrap().as_deref(),
            Some("{\"a\":1}")
        );
    }

    #[tokio::test]
    async fn framing_rejects_oversized_lines() {
        let mut input = vec![b'x'; MAX_MESSAGE_BYTES + 2];
        input.push(b'\n');
        let mut reader = input.as_slice();
        let error = read_message(&mut reader).await.unwrap_err();
        assert_eq!(error.kind(), io::ErrorKind::InvalidData);
    }

    #[tokio::test]
    async fn framing_rejects_invalid_utf8() {
        let mut reader = &b"\xff\xfe\n"[..];
        let error = read_message(&mut reader).await.unwrap_err();
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
    fn hello_succeeds_and_reports_versions() {
        let mut handshake = Handshake::default();
        let outcome = handle_line(&mut handshake, TOKEN, 1, &hello(TOKEN, 1));
        assert!(handshake.is_authenticated());
        assert!(!outcome.close);
        let response = reply(&outcome);
        assert_eq!(response["result"]["server_version"], crate::SERVER_VERSION);
        assert_eq!(response["result"]["api_version"], 1);
        assert_eq!(response["result"]["features"], json!([]));
        assert_eq!(handshake.client(), Some("ade.nvim"));
    }

    #[test]
    fn hello_with_a_bad_token_is_rejected_and_closes() {
        let mut handshake = Handshake::default();
        let bad = "f".repeat(64);
        let outcome = handle_line(&mut handshake, TOKEN, 1, &hello(&bad, 1));
        assert!(!handshake.is_authenticated());
        assert!(outcome.close);
        let response = reply(&outcome);
        assert_eq!(error_code(response), Some(INVALID_TOKEN));
        assert_eq!(response["error"]["message"], "invalid token");
    }

    #[test]
    fn hello_with_an_incompatible_api_version_reports_the_server_version() {
        let mut handshake = Handshake::default();
        let outcome = handle_line(&mut handshake, TOKEN, 1, &hello(TOKEN, 2));
        assert!(!handshake.is_authenticated());
        assert!(!outcome.close);
        let response = reply(&outcome);
        assert_eq!(error_code(response), Some(INCOMPATIBLE_API_VERSION));
        assert_eq!(response["error"]["data"]["server_api_version"], 1);
    }

    #[test]
    fn hello_without_api_version_is_an_invalid_params_error() {
        let mut handshake = Handshake::default();
        let line = json!({
            "jsonrpc": "2.0",
            "id": 1,
            "method": "hello",
            "params": { "token": TOKEN }
        })
        .to_string();
        let outcome = handle_line(&mut handshake, TOKEN, 1, &line);
        assert_eq!(error_code(reply(&outcome)), Some(INVALID_PARAMS));
        assert!(!handshake.is_authenticated());
    }

    #[test]
    fn methods_before_hello_are_rejected() {
        let mut handshake = Handshake::default();
        let line = json!({"jsonrpc": "2.0", "id": 7, "method": "ping"}).to_string();
        let outcome = handle_line(&mut handshake, TOKEN, 1, &line);
        let response = reply(&outcome);
        assert_eq!(error_code(response), Some(HELLO_REQUIRED));
        assert_eq!(response["error"]["message"], "hello required");
        assert_eq!(response["id"], 7);
    }

    #[test]
    fn ping_after_hello_returns_an_empty_object() {
        let mut handshake = Handshake::default();
        handle_line(&mut handshake, TOKEN, 1, &hello(TOKEN, 1));
        let line = json!({"jsonrpc": "2.0", "id": "abc", "method": "ping"}).to_string();
        let outcome = handle_line(&mut handshake, TOKEN, 1, &line);
        assert_eq!(reply(&outcome)["result"], json!({}));
        assert_eq!(reply(&outcome)["id"], "abc");
    }

    #[test]
    fn shutdown_after_hello_sets_the_shutdown_flag() {
        let mut handshake = Handshake::default();
        handle_line(&mut handshake, TOKEN, 1, &hello(TOKEN, 1));
        let line = json!({"jsonrpc": "2.0", "id": 9, "method": "shutdown"}).to_string();
        let outcome = handle_line(&mut handshake, TOKEN, 1, &line);
        assert!(outcome.shutdown);
        assert_eq!(reply(&outcome)["result"], json!({}));
    }

    #[test]
    fn shutdown_before_hello_is_an_error() {
        let mut handshake = Handshake::default();
        let line = json!({"jsonrpc": "2.0", "id": 9, "method": "shutdown"}).to_string();
        let outcome = handle_line(&mut handshake, TOKEN, 1, &line);
        assert!(!outcome.shutdown);
        assert_eq!(error_code(reply(&outcome)), Some(HELLO_REQUIRED));
    }

    #[test]
    fn unknown_methods_report_method_not_found() {
        let mut handshake = Handshake::default();
        handle_line(&mut handshake, TOKEN, 1, &hello(TOKEN, 1));
        let line = json!({"jsonrpc": "2.0", "id": 3, "method": "team.create"}).to_string();
        let outcome = handle_line(&mut handshake, TOKEN, 1, &line);
        let response = reply(&outcome);
        assert_eq!(error_code(response), Some(METHOD_NOT_FOUND));
        assert_eq!(response["error"]["message"], "method not found");
    }

    #[test]
    fn invalid_json_is_a_parse_error() {
        let mut handshake = Handshake::default();
        let outcome = handle_line(&mut handshake, TOKEN, 1, "{not json");
        let response = reply(&outcome);
        assert_eq!(error_code(response), Some(PARSE_ERROR));
        assert_eq!(response["id"], Value::Null);
    }

    #[test]
    fn a_request_without_a_method_is_invalid() {
        let mut handshake = Handshake::default();
        let outcome = handle_line(&mut handshake, TOKEN, 1, "{\"jsonrpc\":\"2.0\",\"id\":1}");
        assert_eq!(error_code(reply(&outcome)), Some(INVALID_REQUEST));
    }

    #[test]
    fn notifications_get_no_response() {
        let mut handshake = Handshake::default();
        handle_line(&mut handshake, TOKEN, 1, &hello(TOKEN, 1));
        let line = json!({"jsonrpc": "2.0", "method": "ping"}).to_string();
        let outcome = handle_line(&mut handshake, TOKEN, 1, &line);
        assert_eq!(outcome.response, None);
    }
}
