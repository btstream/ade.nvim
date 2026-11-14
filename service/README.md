# nvim_ade_server

`nvim_ade_server` is the background service behind ade.nvim. It is started by
Neovim, one process per user, and manages ACP agents on the front end's behalf.
This is the S0 skeleton: the process, the socket, the token, and the `hello`
handshake. Agent runtime, persistence, teams and MCP come in later stages.

See `.acp-work/design.md` for the design and `.acp-work/contract.md` for the
exact front-end contract (paths, stdout lines, error codes).

## Subcommands

| Command | What it does |
|---|---|
| `nvim_ade_server serve [--socket <path>] [--idle-timeout <secs>] [--print-paths]` | Run the service. `--idle-timeout` overrides `NVIM_ADE_SERVER_IDLE_TIMEOUT_SECS` (default 600); `--print-paths` prints the resolved paths and exits without binding. |
| `nvim_ade_server version` | Print `{"version":"0.1.0","api_version":1}` on one line. |
| `nvim_ade_server mcp --token <t>` | Placeholder for the per-agent MCP server; prints "not implemented yet" to stderr and exits 3. |

`serve` prints exactly one line on stdout:

```json
{"status":"ready","socket":"/run/user/1000/ade/nvim_ade_server.sock","pid":1234}
{"status":"already_running","socket":"/run/user/1000/ade/nvim_ade_server.sock"}
{"status":"error","message":"..."}
```

`ready` and `already_running` exit 0; `error` exits 1. Everything else
(including logs) goes to stderr.

## Where things live

The service directory `<dir>` is the first available of:

1. `$NVIM_ADE_SERVER_DIR` (tests and advanced users, highest priority);
2. `$XDG_RUNTIME_DIR/ade`;
3. `$XDG_STATE_HOME/ade`;
4. `~/.local/state/ade`.

On Windows `<dir>` is `%LOCALAPPDATA%\ade` and the socket is the named pipe
`\\.\pipe\nvim_ade_server-<username>`.

| Path | Purpose |
|---|---|
| `<dir>/nvim_ade_server.sock` | Front-end socket (permission 0600). |
| `<dir>/nvim_ade_server.token` | Front-end token, one line, permission 0600. Created once and reused while it stays trustworthy. |
| `<dir>/nvim_ade_server.lock` | Single-instance lock (an OS file lock, so it is released automatically if the process dies). The running instance also writes its socket path here, so a second `serve` can report the live socket. |

`<dir>` itself is 0700.

`--socket` only moves the socket; the token and lock file stay in `<dir>`, so
the front end always finds the token where the contract says.

Token rotation: an existing token file is **replaced** (and a line is written to
stderr) when it is a symlink (never followed), not a regular file, not a
well-formed 64-hex-character token, or readable by group/other on unix
(`mode & 0o077 != 0`) — a token others could read may already have leaked, so
it is rotated instead of trusted. The new file is always written 0600.

Single instance: the service takes the lock before binding. A second `serve`
prints `already_running` with the live socket path and exits 0. A socket file
left behind by a crashed instance is detected (nothing listens on it) and
removed before binding.

Idle exit: with no connected client for `--idle-timeout` /
`NVIM_ADE_SERVER_IDLE_TIMEOUT_SECS` seconds (default 600, fractions allowed),
the service removes the socket and exits 0. `SIGTERM`/`SIGINT` do the same.

## Protocol

JSON-RPC 2.0, one UTF-8 JSON object per line, terminated by `\n`. The current
`api_version` is **1** (integer). Version compatibility is negotiated with
`hello`; on a mismatch the front end should prompt for a service update and
fall back to the direct backend.

| Method | Params | Result |
|---|---|---|
| `hello` | `{ token, client, client_version, api_version }` | `{ server_version, api_version, features: [] }` |
| `ping` | — | `{}` |
| `shutdown` | — | `{}`, then the service exits |

Any other method returns `-32601 Method not found`.

Errors:

| Code | Meaning |
|---|---|
| `-32700` | Parse error (the connection stays open). |
| `-32600` | Invalid request (no method, or `jsonrpc` is not `"2.0"`). |
| `-32601` | Method not found. |
| `-32602` | Invalid params (for example `hello` without `api_version`). |
| `-32001` | `invalid token`; the service closes the connection afterwards. |
| `-32002` | Incompatible `api_version`; `data.server_api_version` carries the supported version. The connection stays open. |
| `-32003` | `hello required`: any method other than `hello` before a successful `hello`. |

Each connection keeps its own state; several clients can be connected at once
and one disconnecting does not affect the others. Messages without an `id`
are notifications and never get a response.

## Building and testing

The toolchain is pinned in `rust-toolchain.toml` (currently
`nightly-2026-05-28`, with `rustfmt` and `clippy`). Both CI workflows read the
channel from that file, so **upgrading the nightly only requires editing
`rust-toolchain.toml`**.

```sh
cd service
cargo fmt --all -- --check
cargo clippy --all-targets -- -D warnings
cargo test
cargo build --release
```

`cargo test` runs unit tests (path resolution, token handling, framing, error
codes) and integration tests that spawn the real binary in a temporary
directory. Every test sets `NVIM_ADE_SERVER_DIR` (and drops `XDG_RUNTIME_DIR` /
`XDG_STATE_HOME`), so the tests never touch the real service directory, token,
socket, or home directory.

Local smoke test without touching your real state:

```sh
TMPDIR_ADEY=$(mktemp -d)
NVIM_ADE_SERVER_DIR=$TMPDIR_ADEY ./target/release/nvim_ade_server serve &
# read $TMPDIR_ADEY/nvim_ade_server.token and talk to
# $TMPDIR_ADEY/nvim_ade_server.sock with one JSON-RPC object per line
```

## Nightly features

The crate uses `#![feature(...)]` for a few small things instead of adding
dependencies. Each one is listed here as required:

| Feature | Where | Why |
|---|---|---|
| `random` | `src/lib.rs`, used in `src/token.rs` | `std::random::random` generates the 32 random bytes of the front-end token, so no `rand`/`getrandom` dependency is needed. Remove it once `std::random` is stabilised. |

## CI and releases

- `.github/workflows/service.yml`: `fmt`, `clippy` and `test` on Ubuntu,
  macOS and Windows, triggered by changes under `service/`.
- `.github/workflows/service-release.yml`: on pushes to `main` it reads the
  version from `service/Cargo.toml` and, if the release
  `nvim_ade_server-v<version>` does not exist yet, tests and builds the
  binaries, publishes the release with `SHA256SUMS`. Targets:
  `x86_64-unknown-linux-musl`, `aarch64-unknown-linux-musl` (via `cross`),
  `x86_64-apple-darwin`, `aarch64-apple-darwin`, `x86_64-pc-windows-msvc`.
  Assets are `nvim_ade_server-<version>-<target>.tar.gz` (`.zip` on Windows)
  and contain only the binary.

Both workflows read the toolchain channel from `rust-toolchain.toml`, run with
`permissions: contents: read` (only the release job gets `contents: write`),
check out without persisted credentials, and pin third-party actions to a full
commit SHA (the version is in the trailing comment). `actions/*` stay on their
major tag.

### Trying the release build without publishing (`dry_run`)

Run **service-release** manually (`Actions` → `service-release` → `Run
workflow`) with `dry_run` checked. Then:

- `test` and `build` run as usual on all five targets — this is how the musl
  targets built with `cross` (especially `aarch64-unknown-linux-musl`) get
  validated on GitHub before a real release — and the archives are uploaded as
  workflow artifacts (kept 7 days) plus `SHA256SUMS`;
- the `release` job is skipped: no tag, no release, no assets uploaded to a
  release.

Leave `dry_run` unchecked (the default) to publish, and use `force` when the
release already exists but its assets must be rebuilt.

