//! Integration tests for `nvim_ade_server serve`.
//!
//! Each test starts the real binary against a private temporary directory (see
//! `tests/common/mod.rs`), so no test touches the user's real XDG directories,
//! token, or socket.

mod common;

use std::time::Duration;

use common::{run_second_instance, TempDir, TestServer};
use serde_json::json;

#[test]
fn version_prints_one_json_line() {
    let output = std::process::Command::new(common::BINARY)
        .arg("version")
        // Even `version` must not depend on the environment.
        .env_remove("NVIM_ADE_SERVER_DIR")
        .output()
        .expect("run version");
    assert!(output.status.success(), "exit code: {:?}", output.status);

    let stdout = String::from_utf8(output.stdout).expect("utf-8 stdout");
    let lines: Vec<&str> = stdout.lines().collect();
    assert_eq!(lines.len(), 1, "exactly one line of stdout: {stdout:?}");
    let value: serde_json::Value = serde_json::from_str(lines[0]).expect("JSON output");
    assert_eq!(value["version"], env!("CARGO_PKG_VERSION"));
    assert_eq!(value["api_version"], 3);
}

#[test]
fn mcp_is_a_placeholder_that_fails_clearly() {
    let output = std::process::Command::new(common::BINARY)
        .args(["mcp", "--token", "abc"])
        .env_remove("NVIM_ADE_SERVER_DIR")
        .output()
        .expect("run mcp");
    assert!(!output.status.success(), "mcp must exit non-zero");
    let stderr = String::from_utf8_lossy(&output.stderr);
    assert!(
        stderr.contains("not implemented"),
        "stderr should say it is not implemented: {stderr}"
    );
    assert!(
        !stderr.contains("abc"),
        "the token must not be echoed: {stderr}"
    );
}

#[test]
fn hello_then_ping() {
    let server = TestServer::start("hello-ping");
    let mut client = server.connect();

    let hello = client.hello(&server.token(), 3);
    assert_eq!(hello["jsonrpc"], "2.0");
    assert_eq!(hello["id"], 1);
    assert_eq!(hello["result"]["server_version"], env!("CARGO_PKG_VERSION"));
    assert_eq!(hello["result"]["api_version"], 3);
    assert_eq!(
        hello["result"]["features"],
        json!(nvim_ade_server::protocol::features(true))
    );

    let ping = client.call(2, "ping");
    assert_eq!(ping["id"], 2);
    assert_eq!(ping["result"], json!({}));
}

#[test]
fn ready_line_and_files_have_the_contracted_permissions() {
    let server = TestServer::start("permissions");
    let ready = server.ready();
    assert_eq!(ready["status"], "ready");
    assert_eq!(ready["socket"], server.socket_string());

    let token = server.token();
    assert_eq!(token.len(), 64, "64 hex characters: {token:?}");
    assert!(token.chars().all(|character| character.is_ascii_hexdigit()));

    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        let mode = |path: &std::path::Path| {
            std::fs::metadata(path)
                .expect("path exists")
                .permissions()
                .mode()
                & 0o777
        };
        assert_eq!(mode(server.dir()), 0o700, "service directory");
        assert_eq!(mode(server.socket()), 0o600, "socket");
        assert_eq!(mode(&server.token_path()), 0o600, "token file");
        assert!(server.dir().join("nvim_ade_server.lock").exists());
    }
}

#[test]
fn the_token_is_reused_across_restarts() {
    let dir = TempDir::new("token-restart");
    let first_token = {
        let mut server = TestServer::start_in_dir(
            dir.clone(),
            "token-restart-a",
            &["--idle-timeout", "600"],
            &[],
        );
        let token = server.token();
        let mut client = server.connect();
        client.hello(&token, 3);
        client.call(2, "shutdown");
        assert_eq!(
            server.wait_for_exit(Duration::from_secs(10)),
            Some(0),
            "shutdown exits cleanly"
        );
        token
    };

    let server = TestServer::start_in_dir(
        dir.clone(),
        "token-restart-b",
        &["--idle-timeout", "600"],
        &[],
    );
    assert_eq!(server.token(), first_token, "the token file is reused");
    let mut client = server.connect();
    client.hello(&first_token, 3);
    assert_eq!(client.call(2, "ping")["result"], json!({}));
}

#[test]
fn a_weak_token_file_is_replaced_at_start_up() {
    let dir = TempDir::new("weak-token");
    std::fs::write(dir.join("nvim_ade_server.token"), "abc\n").expect("write weak token");

    let mut server =
        TestServer::start_in_dir(dir.clone(), "weak-token", &["--idle-timeout", "600"], &[]);
    let token = server.token();
    assert_eq!(token.len(), 64, "the new token is well formed: {token:?}");
    assert_ne!(token, "abc");

    let mut client = server.connect();
    client.hello(&token, 3);
    assert_eq!(client.call(2, "ping")["result"], json!({}));

    // The stderr reader runs until the process exits, so stop the server
    // before inspecting what it logged.
    client.call(3, "shutdown");
    assert_eq!(server.wait_for_exit(Duration::from_secs(10)), Some(0));
    assert!(
        server.stderr().contains("replaced token file"),
        "the replacement is logged on stderr: {}",
        server.stderr()
    );
}

#[cfg(unix)]
#[test]
fn an_overly_open_token_file_is_replaced_and_tightened_at_start_up() {
    use std::os::unix::fs::PermissionsExt;

    let dir = TempDir::new("open-token");
    let path = dir.join("nvim_ade_server.token");
    let leaked = "a".repeat(64);
    std::fs::write(&path, format!("{leaked}\n")).expect("write token");
    std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o644)).expect("chmod");

    let server =
        TestServer::start_in_dir(dir.clone(), "open-token", &["--idle-timeout", "600"], &[]);
    let token = server.token();
    assert_ne!(token, leaked, "a possibly leaked token is rotated");
    let mode = std::fs::metadata(&path)
        .expect("metadata")
        .permissions()
        .mode()
        & 0o777;
    assert_eq!(mode, 0o600, "the new token file is private");
}

#[cfg(unix)]
#[test]
fn a_symlinked_token_file_is_replaced_at_start_up() {
    let dir = TempDir::new("symlink-token");
    let target = dir.join("elsewhere");
    let linked = "b".repeat(64);
    std::fs::write(&target, format!("{linked}\n")).expect("write target");
    std::os::unix::fs::symlink(&target, dir.join("nvim_ade_server.token")).expect("symlink");

    let server = TestServer::start_in_dir(
        dir.clone(),
        "symlink-token",
        &["--idle-timeout", "600"],
        &[],
    );
    let token = server.token();
    assert_ne!(token, linked, "the linked token is not trusted");
    assert_eq!(
        std::fs::read_to_string(&target).expect("read target"),
        format!("{linked}\n"),
        "the link target is untouched"
    );
}

#[test]
fn wrong_token_is_rejected_and_the_connection_closes() {
    let server = TestServer::start("bad-token");
    let mut client = server.connect();

    let response = client.hello("deadbeef", 3);
    assert_eq!(response["error"]["code"], -32001);
    assert_eq!(response["error"]["message"], "invalid token");
    assert!(client.is_closed(), "the server closes after a bad token");
}

#[test]
fn wrong_token_of_the_right_shape_is_rejected() {
    let server = TestServer::start("bad-token-shape");
    let mut client = server.connect();
    let response = client.hello(&"a".repeat(64), 3);
    assert_eq!(response["error"]["code"], -32001);
    assert!(client.is_closed());
}

#[test]
fn a_missing_token_is_rejected() {
    let server = TestServer::start("missing-token");
    let mut client = server.connect();
    let response = client.hello_raw(json!({
        "client": "ade.nvim",
        "client_version": "test",
        "api_version": 3,
    }));
    assert_eq!(response["error"]["code"], -32001);
    assert!(client.is_closed());
}

#[test]
fn incompatible_api_version_is_reported() {
    let server = TestServer::start("api-version");
    let mut client = server.connect();

    let response = client.hello(&server.token(), 999);
    assert_eq!(response["error"]["code"], -32002);
    assert_eq!(response["error"]["data"]["server_api_version"], 3);
    // The connection is still usable for a correct hello.
    let hello = client.hello(&server.token(), 3);
    assert_eq!(hello["result"]["api_version"], 3);
}

#[test]
fn methods_before_hello_are_refused() {
    let server = TestServer::start("hello-required");
    let mut client = server.connect();
    let response = client.call(1, "ping");
    assert_eq!(response["error"]["code"], -32003);
    assert_eq!(response["error"]["message"], "hello required");

    let response = client.call(2, "shutdown");
    assert_eq!(response["error"]["code"], -32003);

    // Still running, and still usable after a proper hello.
    let hello = client.hello(&server.token(), 3);
    assert!(hello["result"].is_object());
    assert_eq!(client.call(3, "ping")["result"], json!({}));
}

#[test]
fn unknown_methods_are_method_not_found() {
    let server = TestServer::start("unknown-method");
    let mut client = server.connect();
    client.hello(&server.token(), 3);

    let response = client.call(2, "team.create");
    assert_eq!(response["error"]["code"], -32601);
    assert_eq!(response["error"]["message"], "method not found");
}

#[test]
fn malformed_json_is_a_parse_error_and_keeps_the_connection() {
    let server = TestServer::start("parse-error");
    let mut client = server.connect();

    client.send_raw("{this is not json");
    let response = client.recv().expect("parse error response");
    assert_eq!(response["error"]["code"], -32700);
    assert_eq!(response["id"], serde_json::Value::Null);

    client.hello(&server.token(), 3);
    assert_eq!(client.call(2, "ping")["result"], json!({}));
}

#[test]
fn clients_are_independent() {
    let server = TestServer::start("multi-client");
    let mut first = server.connect();
    let mut second = server.connect();
    first.hello(&server.token(), 3);
    second.hello(&server.token(), 3);
    assert_eq!(first.call(2, "ping")["result"], json!({}));
    assert_eq!(second.call(2, "ping")["result"], json!({}));

    // Dropping the first client leaves the second one working.
    drop(first);
    assert_eq!(second.call(3, "ping")["result"], json!({}));
}

#[test]
fn shutdown_replies_then_exits_and_removes_the_socket() {
    let mut server = TestServer::start("shutdown");
    let mut client = server.connect();
    client.hello(&server.token(), 3);

    let response = client.call(2, "shutdown");
    assert_eq!(response["result"], json!({}));

    let code = server.wait_for_exit(Duration::from_secs(10));
    assert_eq!(code, Some(0), "shutdown exits with 0");
    #[cfg(unix)]
    {
        assert!(
            !server.socket().exists(),
            "the socket file is removed on exit"
        );
    }
}

#[test]
fn a_second_instance_reports_the_first_and_exits_zero() {
    let server = TestServer::start("second-instance");
    let socket = server.socket().to_path_buf();

    let (line, stderr, code) =
        run_second_instance(server.dir(), &socket, &["--idle-timeout", "600"]);
    assert_eq!(code, Some(0), "already_running is not an error: {stderr}");
    assert_eq!(line["status"], "already_running");
    assert_eq!(line["socket"], server.socket_string());

    // The first instance is unaffected.
    let mut client = server.connect();
    client.hello(&server.token(), 3);
    assert_eq!(client.call(2, "ping")["result"], json!({}));
}

#[test]
fn a_second_instance_with_another_socket_still_reports_the_live_one() {
    let server = TestServer::start("second-instance-other-socket");
    let other_socket = server.dir().join("other.sock");

    let (line, stderr, code) =
        run_second_instance(server.dir(), &other_socket, &["--idle-timeout", "600"]);
    assert_eq!(code, Some(0), "already_running is not an error: {stderr}");
    assert_eq!(line["status"], "already_running");
    // The live instance's socket, not the one this invocation asked for.
    assert_eq!(line["socket"], server.socket_string());
}

#[test]
fn a_stale_socket_file_is_cleaned_up() {
    let dir = TempDir::new("stale-socket");
    #[cfg(unix)]
    let socket = common::test_socket_path(dir.path(), "stale-socket");

    // Leave a socket file behind without anything listening on it, the way a
    // crashed service would.
    #[cfg(unix)]
    {
        let listener = std::os::unix::net::UnixListener::bind(&socket).expect("bind stale socket");
        drop(listener);
        assert!(socket.exists(), "stale socket file is left behind");
    }

    let server =
        TestServer::start_in_dir(dir.clone(), "stale-socket", &["--idle-timeout", "600"], &[]);
    assert_eq!(server.ready()["status"], "ready");

    let mut client = server.connect();
    client.hello(&server.token(), 3);
    assert_eq!(client.call(2, "ping")["result"], json!({}));
}

#[test]
fn it_exits_after_the_idle_timeout() {
    let mut server = TestServer::start_with("idle-exit", &["--idle-timeout", "0.5"], &[]);
    let code = server.wait_for_exit(Duration::from_secs(15));
    assert_eq!(code, Some(0), "idle exit is a clean exit");
    #[cfg(unix)]
    {
        assert!(
            !server.socket().exists(),
            "the socket file is removed on idle exit"
        );
    }
    assert!(
        server.stderr().contains("idle"),
        "the reason is logged on stderr: {}",
        server.stderr()
    );
}

#[test]
fn the_idle_timeout_can_come_from_the_environment() {
    let mut server = TestServer::start_with(
        "idle-env",
        &[],
        &[("NVIM_ADE_SERVER_IDLE_TIMEOUT_SECS", "0.5")],
    );
    let code = server.wait_for_exit(Duration::from_secs(15));
    assert_eq!(code, Some(0));
}

#[test]
fn an_open_client_prevents_the_idle_exit() {
    let mut server = TestServer::start_with("idle-busy", &["--idle-timeout", "0.5"], &[]);
    let mut client = server.connect();
    client.hello(&server.token(), 3);
    assert_eq!(
        server.wait_for_exit(Duration::from_millis(1500)),
        None,
        "a connected client keeps the service alive"
    );
    // Disconnecting starts the idle clock again.
    drop(client);
    assert_eq!(server.wait_for_exit(Duration::from_secs(15)), Some(0));
}

#[test]
fn a_serve_failure_prints_one_json_error_line() {
    let dir = TempDir::new("start-failure");
    // A path that cannot become a directory (its parent is a regular file)
    // makes startup fail on every platform.
    let blocker = dir.join("blocker");
    std::fs::write(&blocker, b"not a directory").expect("write blocker");

    let output = std::process::Command::new(common::BINARY)
        .arg("serve")
        .env("NVIM_ADE_SERVER_DIR", blocker.join("service"))
        .env("HOME", dir.path())
        .env_remove("XDG_RUNTIME_DIR")
        .env_remove("XDG_STATE_HOME")
        .output()
        .expect("run serve");

    assert_eq!(output.status.code(), Some(1), "startup failures exit 1");
    let stdout = String::from_utf8_lossy(&output.stdout);
    let lines: Vec<&str> = stdout.lines().collect();
    assert_eq!(lines.len(), 1, "exactly one stdout line: {stdout:?}");
    let value: serde_json::Value = serde_json::from_str(lines[0]).expect("JSON error line");
    assert_eq!(value["status"], "error");
    assert!(
        value["message"]
            .as_str()
            .is_some_and(|message| !message.is_empty()),
        "the error message is filled in: {value}"
    );
}

#[test]
fn print_paths_reports_the_isolated_locations() {
    let dir = TempDir::new("print-paths");
    let output = std::process::Command::new(common::BINARY)
        .args(["serve", "--print-paths"])
        .env("NVIM_ADE_SERVER_DIR", dir.path())
        .env_remove("XDG_RUNTIME_DIR")
        .env_remove("XDG_STATE_HOME")
        .output()
        .expect("run serve --print-paths");

    assert!(output.status.success());
    let value: serde_json::Value =
        serde_json::from_slice(&output.stdout).expect("JSON paths output");
    assert_eq!(value["dir"], dir.path().to_string_lossy().as_ref());
    assert_eq!(
        value["token"],
        dir.join("nvim_ade_server.token").to_string_lossy().as_ref()
    );
}

#[test]
fn without_nvim_ade_server_dir_the_home_fallback_is_used() {
    // Prove the fallback order without touching the real home: HOME (and
    // XDG_RUNTIME_DIR/XDG_STATE_HOME) all point into a temporary directory.
    let dir = TempDir::new("home-fallback");
    let output = std::process::Command::new(common::BINARY)
        .args(["serve", "--print-paths"])
        .env_remove("NVIM_ADE_SERVER_DIR")
        .env_remove("XDG_RUNTIME_DIR")
        .env_remove("XDG_STATE_HOME")
        .env("HOME", dir.path())
        .env("USERPROFILE", dir.path())
        .env("LOCALAPPDATA", dir.path())
        .output()
        .expect("run serve --print-paths");
    assert!(output.status.success());

    let value: serde_json::Value =
        serde_json::from_slice(&output.stdout).expect("JSON paths output");
    let reported = value["dir"].as_str().expect("dir is a string");
    assert!(
        std::path::Path::new(reported).starts_with(dir.path()),
        "the fallback stays inside the temporary home: {reported}"
    );
}

/// Two servers in different directories must not see each other's token: this
/// catches a regression where `NVIM_ADE_SERVER_DIR` was ignored.
#[test]
fn two_servers_in_different_directories_do_not_collide() {
    let first = TestServer::start("isolated-a");
    let second = TestServer::start("isolated-b");
    assert_ne!(first.token(), second.token());
    assert_ne!(first.socket(), second.socket());

    let mut client = second.connect();
    client.hello(&second.token(), 3);
    assert_eq!(client.call(2, "ping")["result"], json!({}));

    // The second server's token must not work on the first server.
    let mut other = first.connect();
    let response = other.hello(&second.token(), 3);
    assert_eq!(response["error"]["code"], -32001);
}

#[test]
fn out_of_range_event_log_max_mb_is_a_startup_error() {
    for value in ["8", "4097", "0"] {
        let dir = TempDir::new("event-log-range");
        let output = std::process::Command::new(common::BINARY)
            .args(["serve", "--event-log-max-mb", value])
            .env("NVIM_ADE_SERVER_DIR", dir.path())
            .env_remove("XDG_RUNTIME_DIR")
            .env_remove("XDG_STATE_HOME")
            .output()
            .expect("run serve");
        assert_eq!(
            output.status.code(),
            Some(1),
            "--event-log-max-mb {value} must be rejected"
        );
        let stdout = String::from_utf8_lossy(&output.stdout);
        let line = stdout.lines().next().expect("one stdout line");
        let parsed: serde_json::Value = serde_json::from_str(line).expect("JSON");
        assert_eq!(parsed["status"], "error");
        assert!(
            parsed["message"]
                .as_str()
                .is_some_and(|message| message.contains("16 and 4096")),
            "the message explains the range: {parsed}"
        );
    }
}

#[test]
fn an_invalid_event_log_value_is_rejected_by_the_parser() {
    let dir = TempDir::new("event-log-enum");
    let output = std::process::Command::new(common::BINARY)
        .args(["serve", "--event-log", "maybe"])
        .env("NVIM_ADE_SERVER_DIR", dir.path())
        .env_remove("XDG_RUNTIME_DIR")
        .env_remove("XDG_STATE_HOME")
        .output()
        .expect("run serve");
    assert_eq!(output.status.code(), Some(2), "clap rejects the value");
    let stderr = String::from_utf8_lossy(&output.stderr);
    assert!(stderr.contains("on") && stderr.contains("off"), "{stderr}");
}

#[test]
fn features_follow_the_event_log_flag() {
    let on = TestServer::start("event-log-on");
    let mut client = on.connect();
    let hello = client.hello(&on.token(), 3);
    assert_eq!(
        hello["result"]["features"],
        json!(nvim_ade_server::protocol::features(true))
    );

    let off = TestServer::start_with(
        "event-log-off",
        &["--idle-timeout", "600", "--event-log", "off"],
        &[],
    );
    let mut client = off.connect();
    let hello = client.hello(&off.token(), 3);
    assert_eq!(
        hello["result"]["features"],
        json!(nvim_ade_server::protocol::features(false))
    );
}
