# nvim_ade_server

`nvim_ade_server` is the background service behind ade.nvim. It is started by
Neovim, one process per user, and holds ACP agent processes so they outlive the
front end. It relays raw ACP JSON-RPC between an agent and whichever front end
is attached; it is not an ACP client itself.

The protocol (api_version 3) is specified in [`PROTOCOL.md`](PROTOCOL.md). That
document is the contract: socket and token paths are in "Where things live"
below, everything else is there.

## Subcommands

| Command | What it does |
|---|---|
| `nvim_ade_server serve [--socket <path>] [--idle-timeout <secs>] [--print-paths] [--event-log on\|off] [--event-log-max-mb <n>]` | Run the service. `--idle-timeout` overrides `NVIM_ADE_SERVER_IDLE_TIMEOUT_SECS` (default 1800); `--print-paths` prints the resolved paths and exits without binding. `--event-log` (default `on`) and `--event-log-max-mb` (default 256, 16–4096) are the event log flags of PROTOCOL.md section 15. |
| `nvim_ade_server version` | Print `{"version":"0.4.0","api_version":3}` on one line. |
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

Idle exit: when no client is connected **and** no instance has a running turn or
a pending agent request for `--idle-timeout` /
`NVIM_ADE_SERVER_IDLE_TIMEOUT_SECS` seconds (default 1800, fractions allowed),
the service stops every agent, removes the socket and exits 0. `SIGTERM`,
`SIGINT` and `shutdown` do the same.

## Agents

`agent.attach` spawns or finds the instance for a key
(`agent`, `command`, `args`, `cwd`, `client_capabilities`); `env`, when given,
replaces the child environment completely. Instances keep running when the front
end disconnects, so a later `agent.attach` with the same key gets
`created: false`. `agent.list`, `agent.detach` and `agent.stop` manage them.

The relay also tracks the sessions living in each agent (PROTOCOL.md 11):
`session/new`, `session/load` and `session/resume` register one, `session/close`
and `session/delete` forget it, and configuration/mode updates keep its state
current. `agent.attach` reports them (`sessions`, newest activity first) and
`agent.list` counts them (`sessions`, plus `log_bytes`). With `--event-log off`
nothing is tracked, the list is empty and `hello` advertises `"tunnel"` and (on unix) `"install"`.

## Event log and emulated `session/load`

With the log on (the default), the service records what a later front end needs
to rebuild a conversation: the agent's `session/update` notifications, plus
synthetic events for what only the front end said (the prompts, config and mode
changes). The agent's `user_message_chunk` echo is not recorded (the prompt is
already there as a synthetic event), so a replay holds each user message exactly
once; the echo is still delivered live. It lives in `<dir>/nvim_ade_server.events.sqlite3` (0600), capped per
instance by `--event-log-max-mb`, and is deleted with its instance and on every
service start.

A `session/load` for a session the service tracks, whose log is complete and
whose agent advertised `loadSession`, is answered by the service itself: it
replays the recorded updates (in `seq` order, on that connection only), answers
with the tracked `session/new` state, and then switches that connection to live
delivery with no gap and no duplicate. Anything else is forwarded to the agent.

If the session still has a `session/prompt` whose front end went away, the
loading connection **adopts** the turn: it receives `_ade/turn_adopted`, and when
the agent answers, `_ade/turn_finished` with the stop reason (or the error).
Methods starting with `_` are ACP extension methods; clients that do not know
them ignore them.

The log never blocks the relay: writes are asynchronous and a replay reads from
the store on a blocking thread. Both steps are bounded: a load is only emulated
when the instance's log is at most 32 MiB (so one replay always fits the
connection's outbound queue), and live messages held back while a replay is read
are capped at 64 MiB — past either limit the request is forwarded, or the
connection is closed, never silently truncated.

The stop sequence is: close stdin, wait 3 s, `SIGTERM` the process group, wait
3 s, `SIGKILL` the group (`force: true` goes straight to `SIGKILL`). The timeouts
are shortened by `NVIM_ADE_SERVER_STOP_TIMEOUT_MS` (milliseconds, used by the
tests).

`agent.stop` frees the instance's identity **immediately**, before the process
exits: an `agent.attach` with the same key right after it (even before the stop
reply) spawns a new instance with a new id and pid. The stopped instance stays
reachable by its id (`tunnel.send`, `agent.list` with `stopping: true`) until it
exits, and its `agent.exited` goes only to connections attached to that id. The
front end therefore never has to wait for the process to die before starting a
new agent.

Agent stdout is split into lines; a line above 32 MiB is dropped and reported
with `tunnel.error -32025`, and reading resumes after the next newline. Lines
that are not JSON objects go to the service's stderr. The last 64 KiB of stderr
is kept for `agent.exited`.

## Protocol (summary)

[`PROTOCOL.md`](PROTOCOL.md) is normative; this is a short orientation.

JSON-RPC 2.0, one UTF-8 JSON object per line, terminated by `\n`, max 64 MiB.
The current `api_version` is **3** and `hello` reports `features: ["tunnel",
"install", "log"]` on unix (`"install"` is absent on Windows; with
`--event-log off` `"log"` is absent too).

| Method | Direction | Purpose |
|---|---|---|
| `hello`, `ping`, `shutdown` | front end → service | handshake and lifecycle (shutdown stops every agent) |
| `agent.attach / detach / stop / list` | front end → service | agent instances (`attach` takes an optional managed `launch`) |
| `install.resolve / run / uninstall` | front end → service | managed npm installs, unix only (PROTOCOL.md 16) |
| `install.progress` (notification) | service → every front end | install/uninstall progress |
| `$/cancel_request` (notification) | front end → service | cancel that connection's running install request |
| `tunnel.send` (notification) | front end → service | one ACP message for an instance |
| `tunnel.recv`, `tunnel.error`, `agent.exited` (notifications) | service → front end | relayed ACP, rejected frames, process exit |

The service relays ACP messages unchanged apart from: request ids are remapped
per instance (front-end ids never reach the agent), `initialize` is cached for
the instance's life (`-32023` when a later call's capabilities differ from the
attach call), agent-to-client requests go to the most recently attached live
connection ("primary") and are replayed to whoever becomes primary next, and
`$/cancel_request` ids are translated per connection.

Each connection has a 64 MiB outbound queue; a connection that cannot keep up
is closed, while the agent keeps running.

Pending agent requests can be delivered to more than one connection (a new
primary receives them again). When one of them answers — or the agent withdraws
the request — the others receive a standard `$/cancel_request` with the agent's
id, so they can close the question; their late `-32800` reply is ignored.

Errors: `-32020` unknown instance, `-32022` spawn failed, `-32023` initialize
capabilities differ, `-32024` not attached, `-32025` frame rejected, plus the
standard JSON-RPC codes. `-32001` (bad token) closes the connection.

Each connection keeps its own state; several clients can be connected at once
and one disconnecting does not affect the others or the agents. Messages
without an `id` are notifications and never get a response.

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

`cargo test` runs unit tests (paths, token handling, framing, error codes, the
relay rules, the stderr ring, identity canonicalisation) and integration tests
that spawn the real binary in a temporary directory. Every test sets
`NVIM_ADE_SERVER_DIR` (and drops `XDG_RUNTIME_DIR` / `XDG_STATE_HOME`), so the
tests never touch the real service directory, token, socket, or home directory.

`tests/tunnel.rs` (unix only) drives real agents: `../tests/mock_agent.py` for
ACP behaviour, plus tiny shell/Python scripts for stop escalation, process
groups, oversized lines and environment isolation.

Local smoke test without touching your real state:

```sh
TMPDIR_ADEY=$(mktemp -d)
NVIM_ADE_SERVER_DIR=$TMPDIR_ADEY ./target/release/nvim_ade_server serve &
# read $TMPDIR_ADEY/nvim_ade_server.token and talk to
# $TMPDIR_ADEY/nvim_ade_server.sock with one JSON-RPC object per line
```

## Managed installs (unix)

With the `"install"` feature the service installs, updates and removes the npm
adapters into the same `<data>/ade/agents` store the Lua manager uses. The
layout, lock and lease files are normative byte formats shared with
`lua/ade/manager/`; PROTOCOL.md section 16 is the contract. npm runs in its own
process group, its output is capped and its end is kept, it can be cancelled
(SIGTERM, five seconds, SIGKILL) and a timeout kills the group. Installs run
outside the connection's request order, so `ping` and `agent.list` keep being
answered while npm runs; closing the connection does not stop the job.

`agent.attach` accepts `launch = {root, agent, installId}` for a managed
release: the service writes a lease first, re-checks that the release is still
installed, then spawns; the lease heartbeat continues until the instance exits
and is removed with it.

On Windows the feature is absent and the front end keeps its Lua
implementation.

## Nightly features

The crate uses `#![feature(...)]` for a few small things instead of adding
dependencies. Each one is listed here as required:

| Feature | Where | Why |
|---|---|---|
| `random` | `src/lib.rs`, used in `src/token.rs` | `std::random::random` generates the 32 random bytes of the front-end token, so no `rand`/`getrandom` dependency is needed. Remove it once `std::random` is stabilised. |

## Known limitations

Behaviour that is deliberately not implemented in api_version 3 (or not
verified on every platform). None of these break the contract in
[`PROTOCOL.md`](PROTOCOL.md); they are the places where the front end or a later
stage has to compensate.

1. **Grandchildren outlive an agent that exits on its own.** When the agent
   process ends by itself (crash, `exit`, stdin closed), the processes it
   started — for example an MCP server it spawned — are **not** cleaned up.
   Only `agent.stop` and service shutdown signal the whole process group,
   because once the group leader has been reaped the kernel may reuse its pid,
   so `kill(-pid, …)` could reach an unrelated process.
2. **Two Neovims in the same project share one instance.** Instances are keyed
   by `{agent, command, args, cwd, client_capabilities}`, so a second front end
   with the same agent configuration attaches to the *same* agent process. Both
   receive each other's session notifications, and agent→client requests
   (permissions, elicitation) go only to the most recently attached connection
   (the primary). Running two independent conversations needs different keys
   (for example different arguments) until per-session isolation exists.
3. **An answered request is not retracted from other front ends.** A permission
   or elicitation request is sent to the primary only, but a connection that
   received it earlier (as a previous primary, or through a replay) keeps its
   prompt; when someone answers, the others are not told to close it. Retracting
   pending prompts is future work.
4. **Responses are lost while no front end is attached.** A response for a
   connection that has gone away is discarded (PROTOCOL.md 5.2). Replaying what
   was missed is the job of the durable event log (S1b); today a reconnecting
   front end gets pending *requests* back, but not earlier responses or
   notifications.
5. **Windows has no process group or job object.** The child gets
   `CREATE_NEW_PROCESS_GROUP`, but stopping uses `TerminateProcess` on the agent
   only, so its children are not stopped, and there is no SIGTERM/SIGKILL
   escalation. Nothing here has been run on Windows; it is checked with
   `cargo clippy --target x86_64-pc-windows-msvc --all-targets` only. The
   unix-only integration tests (`tests/tunnel.rs`) are skipped there.

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

