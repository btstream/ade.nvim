# nvim_ade_server protocol (api_version 6, service 0.7.1)

This is the contract between the Neovim front end (`lua/ade/service/`) and the
service (`service/src/`). Both sides implement it as written; a deviation is a
bug in the implementation or in this document, never a local decision.

## 1. Role of the service in api_version 2

The service holds ACP agent processes so that they outlive Neovim, and relays
raw ACP JSON-RPC between the agent and whichever front end is attached.

It is **not** an ACP client. It does not decode `session/update`, does not
decide permissions and does not manage sessions: the Lua `Client` keeps all of
that. The service only understands the few things listed in section 5. Every
other byte of an ACP message (`_meta`, vendor extensions, unknown fields) is
passed through untouched, which is why the relay works for any ACP agent.

Later stages move more into the service (durable event log and replay, managed
installs, permission policy, teams). Those add methods and bump `api_version`;
they do not change what is written here.

## 2. Transport

- One unix socket (named pipe on Windows) per user, see `service/README.md`
  for paths. Authentication is the `hello` token.
- JSON-RPC 2.0, **one message per line**, UTF-8, terminated by `\n`.
  The service accepts `\r\n` and a final line without a newline.
- Maximum line length in either direction: **64 MiB**. A longer line closes
  the connection (the stream cannot be resynchronised).
- Every method except `hello` requires a successful `hello` first
  (error `-32003`).

## 3. Methods and notifications

`->` is front end to service, `<-` is service to front end.

### 3.1 `hello` (unchanged semantics, new version)

`-> {token, client, client_version, api_version}`
`<- {server_version, api_version, features}`

`api_version` is `6`. `features` contains `"tunnel"`, `"policy"` (section 17),
`"teams"` (section 18),
`"install"` on unix (section 16), and `"log"` when the event log is enabled (section 10). Errors are unchanged:
`-32001` bad token (connection closed), `-32002` incompatible api_version with
`data = {server_api_version}`, `-32003` hello required.

`ping` and `shutdown` are unchanged. `shutdown` now also stops every agent
instance (section 6).

### 3.2 `agent.attach`

`-> {key, client_capabilities, env, launch?}`

`launch` (api_version 3) marks an agent started from a managed release; see
section 16.4. It is not part of the identity.

```
key = {
  "agent":   string,     // agent id, display only ("claude", "opencode", ...)
  "command": string,     // executable, already resolved by the front end
  "args":    string[],
  "cwd":     string      // absolute working directory of the agent process
}
client_capabilities: object   // ACP clientCapabilities the front end will send in `initialize`
env: object<string,string>?   // COMPLETE environment for the child
```

The **instance identity** is the canonical JSON of
`{agent, command, args, cwd, client_capabilities}` (object keys sorted).
`env` is not part of the identity: it is volatile and may hold secrets.

- If no instance with that identity is running: spawn the child (section 6),
  `created = true`.
- Otherwise reuse the running instance, `created = false`; `env` is ignored.
- The calling connection becomes **attached** to the instance and receives its
  notifications. A connection may attach to several instances.
- `env`, when present, replaces the child's environment completely (the
  service does not leak its own environment into the agent). When absent the
  child inherits the service's environment (tests only).

`<- {instance, created, pid, initialized, attached}`

- `instance`: opaque string id, valid until the instance exits.
- `initialized`: whether the instance already has a cached `initialize` result.
- `attached`: number of connections attached after this call.
- `sessions`: the sessions the service knows to be live in this instance
  (section 11), newest activity first:
  `[{sessionId, cwd, running, updated_at /* unix ms */}]`. Empty for a
  freshly created instance and whenever the event log is disabled.

Errors: `-32022` spawn failed (`message` carries the OS error).

### 3.3 `agent.detach`

`-> {instance}` `<- {}`

The connection stops receiving this instance's messages. The agent keeps
running. Closing the connection detaches implicitly from everything.
Error `-32020` unknown instance.

### 3.4 `agent.stop`

`-> {instance, force?}` `<- {exited: true, code, signal}`

Terminates the agent and removes the instance. The instance leaves the
identity lookup **immediately**, when the request is processed, not when the
process exits: an `agent.attach` with the same identity sent right after
`agent.stop` (even before the stop reply arrives) creates a **new** instance
with a new id and a new process, never the dying one. The old instance stays
reachable by its id (for `tunnel.send` in flight, `agent.list`, with
`stopping: true`) until it exits; its `agent.exited` goes only to the
connections attached to the old id. Sequence (unix): close the
child's stdin, wait up to 3 s, `SIGTERM` the process group, wait up to 3 s,
`SIGKILL` the group. `force = true` skips straight to `SIGKILL`. The reply is
sent after the process exited. All attached connections receive
`agent.exited`. Error `-32020` unknown instance.

### 3.5 `agent.list`

`-> {}` `<- {instances: [...]}`, each:

```
{ instance, agent, command, args, cwd, pid, started_at /* unix ms */,
  initialized, attached, turns_running, pending_requests, stopping,
  sessions /* count */, log_bytes }
```

- `turns_running`: pending `session/prompt` requests (sent by a front end,
  not yet answered by the agent).
- `pending_requests`: agent-to-client requests not yet answered by a front end
  (section 5.4).
- `stopping`: true while an `agent.stop` is in progress for this instance.

### 3.6 `tunnel.send` (notification, `->`)

`-> {instance, message}` where `message` is one ACP JSON-RPC object
(request, notification or response). It is a JSON-RPC **notification**
(no `id`), so it is never answered; failures are reported with
`tunnel.error`.

The service forwards it to the agent according to section 5. The connection
must be attached to `instance`, otherwise `tunnel.error` with `-32024`.

### 3.7 `tunnel.recv` (notification, `<-`)

`<- {instance, seq, message}` where `message` is one ACP JSON-RPC object
received from the agent (after id mapping, section 5).

`seq` is a per-instance counter starting at 1. Every message the agent writes
(response, notification or request) takes the next number, in stdout order, and
so does every event the service records itself (section 10). Numbers therefore
increase strictly but may skip. Delivery to one connection preserves that
order. It is the key of the event log (section 10) and is otherwise used only
for tracing.

### 3.8 `agent.exited` (notification, `<-`)

`<- {instance, code, signal, stderr_tail}`

Sent once to every attached connection when the agent process ends for any
reason (including `agent.stop`). `code` is the exit code or null, `signal` the
signal name or null, `stderr_tail` the last 64 KiB of the child's stderr
(lossy UTF-8). The instance is gone afterwards; `tunnel.send` to it returns
`tunnel.error -32020`.

### 3.9 `tunnel.error` (notification, `<-`)

`<- {instance, code, message, id?}`

Reports a `tunnel.send` that was rejected. `id` echoes the frame's request id
when there was one. Codes: `-32020` unknown instance, `-32024` not attached,
`-32025` frame rejected (`message` explains: not an object, an
unsupported shape, agent line too long).

## 4. Error codes

| Code | Meaning |
|---|---|
| -32001 | invalid token (connection closed) |
| -32002 | incompatible api_version |
| -32003 | hello required |
| -32020 | unknown instance |
| -32022 | spawn failed |
| -32023 | `initialize` capabilities differ from the attach call |
| -32024 | connection not attached to the instance |
| -32025 | frame rejected |
| -32040 to -32045 | managed installs, section 16.5 |
| -32800 | request cancelled (section 16.3) |
| -32050 | invalid policy rule set (section 17) |
| -32060 to -32066 | teams, sections 18.10 and 18.16 |
| -32601, -32700, -32600, -32602 | standard JSON-RPC errors |

## 5. Relay rules (per instance)

Each instance owns a counter that produces the ids the **agent** sees.

### 5.1 Front end to agent

| Message | Handling |
|---|---|
| Request (`method` and `id`) | Assign `agent_id` = next integer (starting at 1). Remember `agent_id -> (connection, frontend_id, method)`. Forward with `id = agent_id`. |
| `initialize` request | Special, see 5.5. |
| Notification (`method`, no `id`) | Forward unchanged, except `$/cancel_request`: its `params.id` is a front-end id, translate it to the matching `agent_id` of **this connection**; if there is none, drop it. |
| Response (no `method`) | It answers an agent request previously relayed (5.3): forward unchanged (same id) and forget the pending request. If that id is not pending (already answered by another connection) drop it silently. |

### 5.2 Agent to front end

| Message | Handling |
|---|---|
| Response (`id`, `result` or `error`, no `method`) | Look up `agent_id`; replace with `frontend_id` and send to **that connection only** as `tunnel.recv`. If the connection is gone, discard it. Forget the mapping. |
| Notification | Send to **every** attached connection. `$/cancel_request` with `params.id` of a pending agent request: also remove it from the pending set (5.4). |
| Request (`method` and `id`) | Relay to the **primary** connection (5.3) and add it to the pending set (5.4). |

### 5.3 Primary connection

Agent-to-client requests (permission, elicitation, fs, terminal, ...) need
exactly one answerer. The primary is the **most recently attached** live
connection of the instance. If the primary detaches or disconnects, the next
most recent attached connection becomes primary and receives every pending
request again, in the original order.

### 5.4 Pending agent requests

The set of agent requests that no front end has answered yet, in arrival
order, with the original agent ids. While the instance has no attached
connection the set just grows. When a connection attaches, it becomes primary
and receives the whole set in order (each as a normal `tunnel.recv`; the
Lua `Client` treats them as fresh requests).

### 5.5 `initialize`

The first `initialize` request of an instance is forwarded normally. If the
agent answers with a `result`, the service caches it. Every later
`initialize` request (a new front end attaching to a live instance) is
answered from the cache with `tunnel.recv {message: {id: frontend_id,
result: cached}}`, without contacting the agent. A cached result is never
invalidated while the instance lives.

If `params.clientCapabilities` of a later request is not canonically equal to
`client_capabilities` of the attach call that created the instance, answer
with an error response `-32023`.

A first `initialize` that failed is not cached; the next one is forwarded.

### 5.6 Everything else

`session/new`, `session/load`, `session/prompt`, `session/cancel`,
`session/set_*`, `authenticate`, vendor methods: forwarded as 5.1 says, with no
interpretation. The service only records `session/prompt` requests to count
`turns_running`.

## 6. Agent process

- Spawned with stdin, stdout and stderr piped, `cwd` from the key, environment
  from `env` (cleared first when present), in its **own process group** on unix
  (a new session or process group on Windows), so it survives the front end and
  `agent.stop` can reach its children.
- stdout is split into lines. A line longer than **32 MiB** is dropped and
  reported with `tunnel.error -32025` to the attached connections; reading
  resumes after the next newline. Lines that are not valid JSON objects are
  logged to the service's stderr and dropped.
- stderr is kept in a ring of the last 64 KiB; it is not forwarded live.
- Writes to the agent are serialised through one queue per instance, in the
  order frames arrive from any connection.
- Closing the service (`shutdown`, signal, idle exit) stops every instance with
  the `agent.stop` sequence before the process exits.

## 7. Connection back pressure

Each connection has an outbound queue capped at **64 MiB** (bytes only; the
number of queued messages is not limited). When it would be
exceeded the service closes that connection, writing the reason and the queued
size to its log (the agent is unaffected and keeps
running; the front end reconnects and re-attaches). Nothing is dropped
silently within a live connection. (Catching up on what was missed is the job
of the event log, a later stage.)

## 8. Idle exit

The service exits when **all** hold for `idle_timeout` seconds (default 1800,
`--idle-timeout`, `NVIM_ADE_SERVER_IDLE_TIMEOUT_SECS`):

- no client connection is open;
- no instance has `turns_running > 0`;
- no instance has `pending_requests > 0`.
- no install job is running (section 16.3).
- no team is active (section 18; suspended teams do not count).

On exit it stops all agents (section 6) and removes its socket.
An instance with a running turn or a pending request keeps the service alive
indefinitely.

## 9. Lifecycle summary (front end view)

1. `ensure()` the service, connect, `hello`.
2. `agent.attach` with the resolved command, args, cwd, capabilities, env.
3. Send the usual ACP `initialize` through `tunnel.send` (the service answers
   from cache when the instance is already initialized), then the normal ACP
   conversation.
4. Leaving on purpose: `agent.detach` (agent keeps running). Agent is broken
   or the user asks to stop it: `agent.stop`. Neither needs to be awaited
   before the next `agent.attach`: requests on one connection are processed in
   order, and a stopped instance is already gone from the identity lookup. The
   only reason to wait is the editor exiting, so the frame is flushed to the
   socket before the process ends.
5. Reconnecting later: `agent.attach` with the same key finds the running
   instance (`created = false`); pending permission requests arrive again.

## 10. Event log (feature `"log"`)

The service records what a later front end needs to rebuild a conversation: the
agent's `session/update` notifications, and **synthetic** events for what only
the front end said. Nothing else is recorded (no responses, no requests, no
other notifications).

| Recorded event | When | Replayed as |
|---|---|---|
| agent `session/update` | the agent writes it, **except** `user_message_chunk` (see below) | itself, unchanged |
| synthetic `user_prompt` | a front end sends `session/prompt` | one `user_message_chunk` update per prompt content block |
| synthetic `config` | a `session/set_config_option` response carries `configOptions`, or an update replaces them | a `config_option_update` update with the full list |
| synthetic `mode` | a `session/set_mode` succeeds | a `current_mode_update` update |

Rules:

- The log belongs to **one instance** and lives exactly as long as it: it is
  deleted when the instance stops or exits. The database file itself is kept
  across a service restart because teams are stored in it (18.15), but every
  instance, event and session row is cleared when the service starts: no
  instance survives a restart, so a stale session would describe nothing.
- File: `<dir>/nvim_ade_server.events.sqlite3`, mode 0600, in the service
  directory (the runtime directory when there is one, so it normally never
  reaches persistent storage).
- Every event carries the instance's next `seq` (section 3.7), allocated by the
  relay, not by the database, so that live `tunnel.recv` and the log agree.
- Cap: `--event-log-max-mb` per instance (default 256). When exceeded, the oldest
  events are dropped; every session that lost an event becomes **incomplete**
  (section 12 declines to replay it).
- A synthetic `user_prompt` event is limited to 8 MiB: a content block larger than
  1 MiB is replaced by a text block `[content omitted from the replay log]`.
- The agent's `user_message_chunk` updates are **not** recorded. ACP agents echo
  the user's prompt back as `user_message_chunk`, and the front end's prompt is
  already in the log as the synthetic `user_prompt`; recording both would replay
  every user message twice. The echo is still delivered to the front end live; it
  is only left out of the log, so the replay has exactly one copy of each user
  message (the synthetic event).
- `--event-log off` disables recording entirely: `features` has no `"log"`,
  `attach` returns no sessions, and section 12 never applies.
- Writing the log never blocks the relay. A read for replay first waits until
  everything recorded before it is readable.

## 11. Session tracking

The relay watches ACP traffic just enough to know which sessions live in the
agent process:

- `session/new` response: the session id is `result.sessionId`, its `cwd` is the
  request's `params.cwd`, its **state** is the whole `result`.
- `session/load` and `session/resume` responses (success): the session id and
  `cwd` come from the request, the state is the response `result` (it may be
  empty).
- `session/close` and `session/delete` responses (success): the session is
  forgotten.

The **state** is kept current: a `config_option_update` replaces
`state.configOptions`; a `current_mode_update` sets `state.modes.currentModeId`;
a successful `session/set_config_option` replaces `state.configOptions` with the
response's `configOptions`.

`running` is true while a `session/prompt` for that session is unanswered.
`updated_at` is the time of the last recorded event for the session.

A session is **complete** when the log holds every event since the service first
saw it and none was pruned. A session the service first saw through
`session/load` is complete from that load on (the agent's replay is itself
logged).

## 12. Emulated `session/load`

When a front end sends `session/load` and **all** of these hold:

- the instance has the `"log"` feature enabled;
- the session id is one the instance tracks (section 11) and is complete;
- the agent advertised `loadSession` in its `initialize` result;
- the instance's recorded bytes are at most **32 MiB** (a replay can never be
  larger than that), so one replay always fits the connection's outbound queue
  and a bounded amount of memory;

the service does **not** forward the request. It answers it itself:

1. it relays, in `seq` order and as ordinary `tunnel.recv` messages to the
   requesting connection only, the replay form (section 10) of every recorded
   event of that session;
2. it sends the response: the tracked **state** (section 11) as `result`, with
   the request's id;
3. it switches the connection to live delivery with **no gap and no
   duplicate**: events recorded while the replay was being read are delivered
   after it, in order.

In every other case (`session/load` of an unknown or incomplete session, log
disabled, no `loadSession`, a log larger than 32 MiB, or a log that cannot be
read) the request is forwarded to the agent as before.

While a connection waits for its replay, the live messages for it are buffered.
That buffer is capped like the outbound queue (64 MiB): past it the service
closes the connection instead of dropping anything.

Replay messages carry `seq` equal to the event they replay; synthetic events
use their own numbers.

## 13. Turn adoption

If the session has a `session/prompt` in flight whose requesting connection is
gone (its front end left, crashed or was killed), the front end that just
loaded the session (section 12) can take that turn over:

- after the load response, the service sends `tunnel.recv` with the ACP
  notification `_ade/turn_adopted` and `params = {sessionId}`;
- the connection becomes an **adopter** of that session;
- when the agent answers the in-flight `session/prompt`, the service sends
  every adopter the notification `_ade/turn_finished` with
  `params = {sessionId, stopReason}` (`stopReason` from the response, or
  `"error"` with `error` set to the JSON-RPC error object);
- the prompt is then finished for the service too (`turns_running` drops).

If nobody adopted the session, the response is discarded as before.
Notifications whose method starts with `_` are ACP extension methods; a front
end that does not know them ignores them.

## 14. Retracting a request

A pending agent request (section 5.4) can have been **delivered** to more than
one connection (a new primary receives the whole set again). When one
connection answers it, or the agent withdraws it, the service sends every
**other** connection that was delivered it the standard notification
`$/cancel_request` with `params = {id}` (the agent's id of that request), so
its front end can close the question. That front end replies with a
`-32800` error response to the request; the service ignores it because the
request is no longer pending.

## 15. Service flags and files

| Flag | Default | Meaning |
|---|---|---|
| `--event-log <on\|off>` | `on` | section 10 |
| `--event-log-max-mb <n>` | `256` | per-instance cap, 16 to 4096 |

The flags apply when the service starts; a front end that finds a service
already running does not change them.

## 16. Managed installs (feature `"install"`, api_version 3)

The service installs, updates and removes the npm-packaged ACP adapters that
`lua/ade/manager/` manages in the direct backend, **into the same store on
disk**. Both implementations must keep working against one store at the same
time (a direct-mode Neovim next to a service-mode one), so the layout, the
lock files and the lease files below are normative byte formats, not
implementation details. `lua/ade/manager/{store,lock,npm,install}.lua` is the
reference; where this section and that code disagree, fix one of them.

The front end keeps the registry (which agents are managed, their package,
entry point, notes) and the confirmation dialog. It sends the package
description with every request; the service validates every field itself and
never trusts a path it did not build.

`"install"` is in `features` on unix only. On Windows (and whenever the
feature is absent) the front end keeps using the Lua implementation.

### 16.1 Validation and store layout

All patterns in this section are **ASCII** (`\d` is `[0-9]`, `\w` is
`[A-Za-z0-9_]`). A failure is `-32040` with a message naming the field.

- `root`: absolute, after lexical normalisation not `/` and not the user's home
  directory. The front end additionally refuses its own working directory (the
  service's working directory means nothing). It is sent with every request;
  the service has no default.
- agent id: `^[a-z0-9][a-z0-9_-]*$`, at most 64 bytes.
- `package`: at most 128 bytes, no leading `-`, `^@?[\w.-]+/?[\w.-]*$`, and no
  path segment equal to `.` or `..`.
- `entry`, `bin`: `^[A-Za-z0-9._@/-]+$`, not starting with `/`, every
  `/`-separated segment non-empty and not `.` or `..`. `bin` may be absent.
- version (`install.run`, a resolved version): `^\d+\.\d+\.\d+`, only
  `[0-9A-Za-z.+-]`, no `..`, not starting with `-`, at most 64 bytes, not
  `latest`. A spec (`install.resolve`) is such a version or exactly `"latest"`.
- install id: at most 96 bytes, `^[a-z0-9][a-z0-9._-]*$`, no `..`. The service
  generates `v<version>-<suffix>`: the version lowercased with every character
  outside `[a-z0-9.-]` replaced by `_`, cut to 64 bytes; the suffix is
  `[a-z0-9]{1,24}` and unique in `releases/`. Nothing parses an install id.

```
<root>/
  <id>/
    current.json                the ONLY commit point (pointer)
    releases/<install-id>/      one release; npm installs straight into it
      package.json              synthetic manifest
      node_modules/...          produced by npm
      receipt.json              written after verification
  .locks/<id>/owner.json        exclusive per-agent lock (the directory is the lock)
  .leases/<id>/lease-*.json     shared "in use" records
```

- `current.json`: `{"schemaVersion":1, "installId", "updatedAt", "package",
  "version"}`; `updatedAt` is UTC `YYYY-MM-DDTHH:MM:SSZ`. Readers use only
  `schemaVersion` (must be the number 1) and `installId` (valid install id).
- `receipt.json`: `{"schemaVersion":1, "agentId", "installId", "package",
  "version", "entry", "bin"?, "runtime":"node", "installedAt", "platform",
  "arch"}`. `agentId` equals the agent directory name, `installId` equals the
  release directory name and the pointer's `installId`. `entry` is
  `node_modules/<package>/<registry entry>`, relative to the release
  directory. `platform`/`arch` use the LuaJIT spellings (`Linux`, `OSX`;
  `x64`, `arm64`). Readers ignore unknown fields (Lua may add `nodeVersion`).
- `package.json`: `{"name":"ade-nvim-managed", "private":true,
  "version":"0.0.0", "description":"Installed by ade.nvim; do not edit.",
  "dependencies":{"<package>":"<exact version>"}}`.
- Every JSON file except `package.json` is written to `<path>.tmp-<unique>`
  and renamed over the target; compact JSON.
- State (as the Lua `Store:state`): no `current.json` is `not_installed`; an
  unreadable or invalid pointer, a missing or invalid receipt, or an entry that
  is not a regular file (symlinks followed) is `broken`; otherwise
  `installed`. After writing a receipt and pointer the service checks the
  release with these same rules before it reports success.
- Releases are the entries of `releases/` that are real directories (not
  symlinks) with a valid install id name; everything else there is ignored and
  never deleted.

### 16.2 Locks and leases

Constants (shared with `lua/ade/manager/lock.lua`): heartbeat every **15 s**;
a record whose pid is gone is abandoned once its heartbeat is older than
**120 s**; a record whose pid exists is abandoned once its heartbeat is older
than **600 s**, or older than the boot time minus **60 s** (pid reuse). Times
are wall-clock milliseconds since the epoch; the boot time is now minus the
system uptime (including suspend). `host` is `gethostname(2)`.

Writers write `pid` as a JSON **string** and `heartbeat` as an integer.
Readers accept a number or a numeric string for both; a pid that is not a
positive integer counts as "no pid".

- **Lock** (one per agent; install, update and uninstall take it): create
  `<root>/.locks/<id>` with an atomic `mkdir` (mode 0700; parents with
  `mkdir -p`). If it exists, read `owner.json` and apply the liveness rule:
  live means fail at once with `-32042`; abandoned means read `owner.json`
  again, and only if it is unchanged remove the directory and `mkdir` once
  more (`-32042` if that fails). `owner.json` = `{"host", "pid",
  "acquiredAt", "heartbeat", "action"}`. The heartbeat rewrites the file only
  while `host`, `pid` and `acquiredAt` are still ours; otherwise the lock is
  lost. Release removes the directory only while the record is ours.
- **Lease** (one file per running release): `<root>/.leases/<id>/lease-<pid>-
  <instance>.json` with `<instance>` in `[A-Za-z0-9_-]+`, content `{"host",
  "pid", "installId", "heartbeat", "startedAt"}`. A lease deleted by someone
  else is not recreated.
- **Liveness** of a record, in order: unreadable or empty -> live; other host
  -> live; no pid -> live; pid exists (signal 0 succeeds or fails with anything
  but "no such process") -> live unless the heartbeat is older than the boot
  time minus 60 s or older than 600 s (a heartbeat <= 0 or in the future is
  live); pid gone -> abandoned only when `0 < heartbeat` and it is older than
  120 s, otherwise live.
- **In use**: a release is in use when a live lease names its `installId`. A
  live lease **without** `installId`, or one whose pid exists but cannot be
  signalled, makes every release of that agent in use. Abandoned lease files
  are deleted while scanning.
- A lock directory whose `owner.json` was never written (a crash between
  `mkdir` and the write) is unreadable and therefore live forever; it has to
  be removed by hand. The error message says so.

### 16.3 Methods

`install.*` requests run **outside the request order** of their connection:
the service answers other requests on that connection (and on every other)
while an install runs. `job` is a front-end-chosen string
(`[A-Za-z0-9_-]{1,64}`), unique among the jobs running in the service
(`-32040` otherwise); it ties the progress notifications to the request.

`install.resolve`
`-> {root, package, spec, npm, env, timeout_ms?}` `<- {version}`
Runs `<npm> view <package>@<spec> version --json` with `cwd` = `root`, or its
nearest existing ancestor when `root` does not exist yet. The exit code is
ignored; stdout must decode to a version string (or an array whose first
element is one) that passes the version rule, else `-32041`. `timeout_ms`
defaults to 60000. Takes no lock and writes nothing.

`install.run`
`-> {job, root, agent, action, package, entry, bin?, version, npm, env,
timeout_ms?, max_log_bytes?}`
`<- {status: "committed", installId, version, dir}` or
`<- {status: "unchanged", installId, version}`
- `action` is `"install"` or `"update"`; `version` is exact. `update` of an
  agent that is `not_installed` is `-32045`. `update` when the state is
  `installed` with the same version returns `unchanged` and touches nothing;
  a `broken` agent is reinstalled. `install` always builds a new release
  (this is how a broken release is repaired).
- Steps: take the lock; create the release directory; write `package.json`;
  run `<npm> install --no-audit --no-fund --omit=dev --loglevel=notice
  --progress=false` with `cwd` = the release directory; verify that
  `node_modules/<package>/package.json` has `name == package` and
  `version == version`, and that the entry is a regular file inside the
  release; write `receipt.json`; **check that the lock is still ours**; write
  `current.json` (commit); prune; release the lock.
- Any failure before the commit removes only the directory this request
  created, never touches `current.json`, and is `-32043` with
  `data = {log}` (the last 4000 bytes of the kept output, cut at a UTF-8
  boundary). A lost lock is such a failure.
- Prune: after the commit delete every other release (16.1) that is not in use
  (16.2). Releases in use are kept for a later install to prune.
- `timeout_ms` defaults to 300000; `max_log_bytes` (default 1 MiB) caps the
  output kept, keeping the **end**. An `output` line longer than 4096 bytes is
  cut.

`install.uninstall`
`-> {job, root, agent, installId?}` `<- {installId}`
Takes the lock. `not_installed` is `-32045`; an unreadable or invalid
`current.json` is `-32043` and removes nothing. When `installId` is given and
the current release is a different one, `-32042` with `reason = "changed"`
(the person confirmed something else). A release in use is `-32044` with the
reason. Otherwise remove `current.json` **first**, then the release
directory; when the directory cannot be removed completely the answer is
`-32043` with `data = {installId}` (the leftovers are pruned by a later
install). Other releases, `.leases`, credentials and the agent's own
configuration are not touched.

`install.progress` (notification, `<-`, sent to **every** connection, so other
front ends can show the agent as busy)
`{job, agent, action, phase, line?, version?, dir?, message?}`
`phase` for a run: `checking`, then `installing` (with `version`, `dir`), then
`output` events (one npm output `line` each, carriage returns stripped, empty
lines skipped; the first is the command line `"$ npm install ..."`), then
`verifying`, then `committed`. For an uninstall: `removed`.

Every `install.run` and `install.uninstall` that passed validation ends with
exactly one terminal event: `committed`, `unchanged`, `removed`, `failed`
(with `message`) or `cancelled`, sent before the response — including early
refusals (`-32042`, `-32044`, `-32045`, `changed`).

**Cancellation**: the front end sends `$/cancel_request {id}` where `id` is the
JSON-RPC id of its own running `install.resolve`, `install.run` or
`install.uninstall` request on that connection; unknown or finished ids are
ignored. npm's process group gets SIGTERM, then SIGKILL after 5 s; once it has
exited the release directory is removed, the lock released, and the request
answered with `-32800`. Once `current.json` has been renamed it is too late
and the cancel is ignored.

A job keeps running when the connection that started it closes (its progress
still goes to the other connections). `shutdown` cancels every job first. The
idle exit (section 8) waits while any job runs.

`npm` is an executable the front end resolved: a name containing `/` must be
absolute; a bare name is looked up in `env.PATH`. It is run directly, never
through a shell, in its own process group. `env` is required and is the
complete environment for npm (as in `agent.attach`); the front end sends its
whole environment so npm sees the user's `PATH`, `HOME` and `npm_config_*`.
An npm that cannot be started is `-32043` with the reason.

A second `install.run` or `install.uninstall` for the same agent while one is
running, in this service or in any other process holding the lock, is
`-32042` with `data = {reason}` at once; there is no queue. Different agents
proceed in parallel.

Confirmation happens in the front end between `install.resolve` and
`install.run` (or before `install.uninstall`), so no lock is held while a
person decides. `install.run` and `install.uninstall` re-check everything
under the lock.

### 16.4 Leases for agents the service runs

`agent.attach` accepts an optional `launch = {root, agent, installId}` next to
`key` (validated as in 16.1, `-32040` otherwise). It is not part of the
identity. When an instance is **created** with `launch`, the service first
writes the lease of 16.2 for that release, then checks that the release is
still `installed` (receipt valid, entry a regular file), and only then spawns
the agent; if the lease cannot be written or the release is gone, the attach
fails with `-32022` and the lease is removed. The lease keeps its heartbeat
until the instance exits; then the file is removed. The front end does not
hold its own lease for agents that run in the service.

### 16.5 Error codes

| Code | Meaning |
|---|---|
| -32040 | invalid parameter (root, agent id, package, version, entry, npm, job, launch) |
| -32041 | npm could not resolve the version |
| -32042 | another operation holds this agent, or the release changed (`data.reason`) |
| -32043 | install or uninstall failed (`data.log` when npm ran) |
| -32044 | the release is in use (`data.reason`) |
| -32045 | nothing to do: not installed |
| -32800 | the request was cancelled (`$/cancel_request`) |

### 16.6 Deliberate differences from the Lua implementation

- No lock is held while the person confirms; two front ends that both confirm
  find out at `install.run` (`-32042`).
- npm can be cancelled while it runs, and is stopped as a process group.
- A lock lost during an install fails the install instead of committing.
- npm gets exactly the environment the front end sends.
- Leases of service-run agents belong to the service and survive Neovim
  exiting (in the Lua code they belonged to Neovim and disappeared with it).
- `install.uninstall` reports a corrupt pointer as `-32043` instead of a
  separate pre-check.

## 17. Permission policy (feature `"policy"`, api_version 4)

The service answers an agent's `session/request_permission` itself when a rule
the front end installed decides it, **whether or not a front end is
attached**, so an agent keeps working while nobody watches. A request no rule
decides is relayed exactly as before (section 5.4). The rules are data; the
service runs no front-end code. Sessions, prompts and everything else stay in
the front end's `Client`.

Trust boundary: the service, like the Lua policies it replaces, trusts the
`toolCall.kind`, locations and diff paths **the agent declares**. A rule is a
statement about declared requests, not a sandbox.

When the service offers `"policy"`, the front end installs its rules here and
does **not** run its own automatic answers (`permissions.auto_allow`, the inline
turn policy) for that connection. Without the feature (an older service) the
front end keeps its Lua policies.

### 17.1 Rule sets

```
rule_set = {
  "name":         string,          // [A-Za-z0-9_.:-]{1,128}
  "priority":     integer?,        // default 0; higher is consulted first
  "session":      string?,         // only requests with this params.sessionId
  "agent":        string?,         // only instances whose key.agent is this
  "until":        "turn_end"?,     // see 17.3; requires "session"
  "keep":         "connection" | "service"?,  // default "connection"
  "fallback":     "cancelled"?,    // see 17.2 step 5
  "allow_always": boolean?,        // default false; required for allow_always in choose
  "cwd":          string?,         // absolute; resolves relative request paths
  "rules":        rule[]           // 0..64 entries
}
rule = {
  "kinds":       string[]?,        // non-empty; toolCall.kind must be one of these
  "paths":       string[]?,        // non-empty; absolute files (17.2)
  "paths_under": string[]?,        // non-empty; absolute directories (17.2)
  "choose":      string[],         // non-empty; option kinds: allow_once,
                                   //   allow_always, reject_once, reject_always
  "pick":        "choose" | "offered"?   // default "choose"
}
```

Unknown fields in a set or rule are ignored (forward compatibility).

- `policy.set {set}` `<- {}` installs a set, replacing a set with the same
  name. `policy.clear {name}` `<- {removed}`. `policy.list {}` `<- {sets}` where
  each set also carries `owner` (connection id or `null`), `installed_at` and
  `bound` (17.3). Invalid input is `-32050` with a message naming the field and
  nothing is installed: an empty list, an unknown option kind, `allow_always` in
  `choose` without `"allow_always": true`, `until` without `session`, a
  relative `cwd`/path, more than 256 sets in the service.
- Ownership: a set with `keep = "connection"` belongs to the connection that
  installed it and is removed when that connection closes, **except** a
  `turn_end` set whose prompt is running, which lives until that prompt ends
  (an adopted turn keeps its rules, section 13). `keep = "service"` sets live
  until they are cleared or the service exits. Sets are never written to disk;
  a front end installs its `keep = "service"` sets again after every `hello`.
  Any authenticated front end may replace or clear any set (one user, one trust
  domain).

### 17.2 Deciding a request

When an agent sends `session/request_permission` (a missing `toolCall` is an
empty object):

1. **Questions are never answered by policy.** The request is a question when
   any holds: `toolCall.kind == "switch_mode"`; `toolCall.rawInput.method` is
   `"select"` or `"confirm"`; it has at least two `options` and all of them have
   the same `kind` (a missing kind counts as the empty string). A question is
   relayed.
2. Candidate sets: those whose `session` (if any) equals the request's
   `sessionId`, whose `agent` (if any) equals the instance's `key.agent`, and
   which are **active** (a `turn_end` set only while its bound prompt runs,
   17.3). Order: higher `priority` first; at equal priority, sets with `session`
   before sets without; then the most recently installed first.
3. In each set, rules in order. A rule **matches** when every condition it has
   holds:
   - `kinds`: `toolCall.kind` is a string in the list;
   - `paths` / `paths_under`: the request names at least one path — each
     `toolCall.locations[].path` and each `toolCall.content[]` entry with
     `type == "diff"` contributes its `path` — and every named path passes. An
     entry without a string path, an empty string, a NUL byte, or a request
     with no paths does not match. A relative path resolves against the set's
     `cwd`; without `cwd` a relative path does not match. Paths are normalised
     lexically (`\` becomes `/` on Windows; `.` is dropped) **but a path with a
     `..` component never matches**, whether it is a request path or a listed
     path: lexical `..` before a symlink is not what the kernel resolves. On
     Windows a drive letter compares case-insensitively, a canonical path's
     `\\?\` prefix is ignored, and UNC or `\\?\` paths never match.
     - `paths`: equality is by `realpath` (like the Lua `is_copy_path`);
       additionally `lstat` reports a regular file with one link and its
       `realpath` equals the listed path's `realpath`. (This is the inline
       private copy: a symlink or hard link placed there by the agent does not
       pass.)
     - `paths_under`: the `realpath` of the path, or of its nearest existing
       ancestor for a file not created yet, is inside the `realpath` of a
       listed directory, component-wise and **strictly** (the directory itself
       is not inside). A dangling symlink encountered while walking up does not
       match; only components that really do not exist are skipped.
     When a rule has both, a path may pass either.
   A rule without conditions matches every non-question request.
4. A matching rule decides when one of its `choose` kinds is offered:
   - `pick = "choose"`: the first kind in `choose` order that is offered, and
     the first option of that kind;
   - `pick = "offered"`: the first option in the agent's order whose kind is in
     `choose` (this is how `permissions.auto_allow` has always behaved).
   A matching rule none of whose kinds is offered does not decide.
5. If no rule of a set decided and the set has `fallback = "cancelled"`, the set
   decides with `{"outcome": {"outcome": "cancelled"}}`. Otherwise the search
   continues with the next set.
6. Decided: the service answers the agent, does **not** add the request to the
   pending set, and sends `policy.applied` (17.4). Not decided: relay as in
   section 5.4.

The decision is made once, when the request arrives; installing a set later
does not answer requests already pending. A front end that receives a request
the service already answered (a redelivery race) gets nothing to answer: the
service drops responses for ids that are not pending (section 5.1).

### 17.3 Turn-scoped sets (`until = "turn_end"`)

A `turn_end` set is **bound** to one prompt: the next `session/prompt` for its
`session` that arrives **on the connection that installed the set**, or the
prompt from that connection for that session that is already running when the
set is installed. Until then it is inactive (it decides nothing). It is active
while the bound prompt runs and is removed when that prompt is answered
(section 13). The front end sends `policy.set` and waits for its response
before it sends the prompt; the service handles one connection's frames in
order, so the set is in place before the agent sees the prompt.

When the service forwards a `session/cancel` for a session, every active
`turn_end` set of that session becomes **cancelling**: from then until its
prompt is answered it decides every non-question request with
`{"outcome": {"outcome": "cancelled"}}`, whatever its rules say. (A cancelled
turn must not keep acting on the rules it was given.) If several sets are
cancelling, `policy.applied.set` is the first one in the candidate order above.

A permission request carries no prompt identifier, only `sessionId`. A bound
`turn_end` set therefore applies to every non-question request for its session
**on its bound instance** while that prompt runs; the same session id on another
instance is unaffected. If the bound instance exits, its turn_end sets are
removed: their prompt can never be answered, so nothing may inherit them.

`turn_end` sets are not re-installed after a reconnect; their prompt either
still runs (and the set is still there) or is gone.

### 17.4 Notification and log

`policy.applied` (notification, `<-`, to every connection attached to the
instance) `{instance, sessionId, set, outcome, optionId, kind, toolCall}`:
`outcome` is `"selected"` or `"cancelled"`, `optionId` and `kind` are `null`
for `cancelled`, `toolCall` is the request's `toolCall` unchanged.

A request without `sessionId` can still be decided by a set without a
`session`; there is no session to attach the event to, so it is not recorded.

With the event log enabled the decision is recorded as a synthetic `policy`
event for the session and replayed (section 12) as a `session/update` with
`update = {"sessionUpdate": "_ade_policy", "set", "outcome", "optionId",
"kind", "toolCall"}`, where `toolCall.rawInput` and `toolCall.content` are
replaced by `"[omitted]"` when the encoded `toolCall` exceeds 64 KiB. A front
end with the `"policy"` feature must accept `_ade_policy` (it may show it);
ACP lets clients ignore unknown session updates.

### 17.5 Error codes

| Code | Meaning |
|---|---|
| -32050 | invalid rule set (`message` names the field) |

### 17.6 Expressing the front end's existing policies

- `permissions.auto_allow = {k1, k2, ...}` (non-empty): one set
  `{name = "config", keep = "service", priority = 0,
  allow_always = <k contains allow_always>, rules = {{choose = {k1, k2, ...},
  pick = "offered"}}}`; an empty `auto_allow` means `policy.clear {"config"}`.
- An inline turn: `{name = "inline:<session>", session, until = "turn_end",
  priority = 100, fallback = "cancelled", cwd = <session cwd>, rules = ...}`
  with, in order: edits of the private copy (`kinds = {"edit"}`,
  `paths = {<copy>}`, `choose = {"allow_once", "reject_once"}`); when
  `inline.allow_writes`, all edits (`kinds = {"edit"}`, same `choose`); the
  always-allowed kinds and the configured extra kinds (`kinds = {...}`, same
  `choose`); finally everything else (`choose = {"reject_once"}`). An offered
  `allow_always` is never a substitute for `allow_once`.

## 18. Teams (feature `"teams"`, api_version 5)

A **team** is one leader agent and up to `max_workers` worker agents that talk
through a **bus** the service owns, with the person (`human`) as a participant.
Neovim shows the team and answers for the human; the team keeps running when
Neovim exits. Without a team nothing in this section happens: a single agent
behaves exactly as before.

`"teams"` is offered only together with `"log"` (section 10): a front end that
was away rebuilds what the team did from the event log. While any **active**
team exists the service does not idle-exit (section 8). Teams are persisted and
come back after a service restart as suspended teams (18.15). Worktrees for workers, teams started from configuration and recovery
after a restart are stage S4c; everything else here is S4a (service) and S4b
(front end).

Trust: any connection that passed `hello` with the user token may configure
and drive teams, exactly as it may attach agents (one user, one trust domain).
Participant connections (18.6) may only use `bus.*`.

### 18.1 Participants and messages

- A team has an id (`t1`, `t2`, ...) and a `cwd` (absolute); there is at most
  one team per `cwd`. Participants: the leader (name `leader`), workers and
  the implicit `human`. Worker names match `[a-z0-9][a-z0-9_-]{0,31}`, are
  unique in the team and are not `leader` or `human` (`-32060`).
- A participant is an agent instance plus one ACP session in it. State:
  `idle`, `working` (a prompt of its session is running), `waiting_human`,
  `paused` or `exited` (with a `reason`).
- A **message** is `{id, team, from, to, kind, task?, body, refs?, at}`.
  `kind` is `task`, `report`, `question`, `answer`, `review`, `notice` or
  `control`. `task` matches `[A-Za-z0-9_.:-]{1,64}`; messages without one count
  as task `_`. `body` is text up to 64 KiB; `refs` up to 16 strings of up to
  1 KiB. Only `human` and the leader may send `control`.
- Each participant has a FIFO **mailbox**. Messages are ordered by the time the
  service accepted them.

### 18.2 Configuration and the leader

`team.configure {cwd, config}` `<- {}` stores the configuration used by the
next team created for `cwd` (latest call wins; a running team keeps its own):

```
config = {
  "max_workers":   integer,                   // 1..8, default 3
  "spawn_confirm": { "auto": string[] },      // template names; each must exist
  "limits": { "max_turns_per_task": integer,  // default 30
              "max_turns_total":    integer },// default 200
  "templates": {
    "<name>": {                               // [a-z0-9][a-z0-9_-]{0,31}
      "key":    { "agent", "command", "args" }, // resolved by the front end as for agent.attach
      "env":    object<string,string>,        // complete environment, as for agent.attach
      "launch": object?,                      // section 16.4
      "model":  string?,                      // section 18.3
      "role":   string                        // role card text, up to 16 KiB
    }
  }
}
```

The front end resolves each template's command, arguments, environment and
managed release exactly as for its own agent; the service starts nothing the
person could not have started from Neovim, and only from `templates`.

**Leader.** `team.leader_server {instance, cwd}` `<- {server, token_id}`: a
new participant token (18.6) for a future leader and the MCP server entry to
put in ACP's `mcpServers`:
`{"name": "ade-team", "command": <absolute path of the service binary>,
"args": ["mcp"], "env": [{"name": "ADE_TEAM_TOKEN", "value": <token>}]}`.
`cwd` must equal the instance's `key.cwd`, and no team may exist for `cwd`
unless its leader is this instance (`-32061`). The front end sends that entry
with `session/new`, `session/load` or `session/resume`, and after a successful
response calls `team.bind_leader {instance, sessionId, token_id}` `<- {team}`.
Binding creates the team for `cwd` (with the stored configuration) or, if the
team already has this session as leader, only adds the token. A token that is
never bound expires when its instance exits. A bound token stays valid while
the team lives.

Binding is by `sessionId`: after an emulated `session/load` (section 12) the
agent keeps the MCP server it already has and nothing needs to be re-bound.
When the leader's session is closed or deleted, or its instance exits, the team
is `leaderless`: workers go on, messages to `leader` queue, and `team.close`
ends it.

### 18.3 Workers

`bus.spawn` (tool `team_spawn`, leader only) `{template, name?, task?}`: the
template must exist and the team must have fewer than `max_workers` live
workers (`-32061`); a missing name becomes `w1`, `w2`, ... Then:

- template in `spawn_confirm.auto`: the worker starts now; the result is
  `{status: "started", name}`;
- otherwise a `spawn` inbox item (18.5) is created and the result is
  `{status: "awaiting_approval", request}` at once. When the person answers,
  the leader receives `kind = "notice"` from `human` with
  `body = "spawn request <request> approved: <name>"` (or `refused`) and
  `refs = [<request>]`.

Starting a worker: the service spawns the template as a new instance
(`cwd` = the team's cwd; S4c: a worktree) that is **not** in the identity table
(no front end can reach it through `agent.attach`), applies `launch` (16.4),
and itself sends `initialize` (protocol version 1, `clientCapabilities` =
`{"fs": {"readTextFile": false, "writeTextFile": false}, "terminal": false}`),
then `session/new {cwd, mcpServers: [<the worker's ade-team server>]}`, then,
when `model` is set and the session's `configOptions` offer an option with id
`model` whose values include it, `session/set_config_option`. Its first prompt
carries the role card (18.4) and the task, if any. A worker whose `initialize`
or `session/new` fails becomes `exited` with the error as reason and the
leader gets a `notice`.

Requests the service sends to an agent use the instance's agent-side id
counter (section 5.1) and are marked as the service's own; their responses are
consumed by the team layer and never forwarded. Requests a worker's agent sends:

- `session/request_permission`: section 17; undecided, it becomes a
  `permission` inbox item and is relayed to watchers (18.7);
- `fs/*` and `terminal/*`: answered `-32601` at once (the capabilities said
  no);
- anything else: relayed to watchers like a pending request (section 5.4) and
  shown as a `request` inbox item.

### 18.4 Delivery

- Queued messages are delivered when the participant's session has no prompt
  running, it is not `waiting_human` or `paused`, and it is not `exited`. The
  service sends one `session/prompt` itself with one text block per message,
  oldest first, up to 128 KiB in total (the rest waits for the next delivery):
  `<bus from="leader" kind="task" task="T3">body</bus>`. In bodies and refs,
  `&` becomes `&amp;` and `<` becomes `&lt;`, so no message can contain a
  `<bus ...>` of its own.
- A worker's first prompt starts with its **role card**: its name, team and
  leader, the template's `role`, the tools it has (18.6), that it reports with
  `bus_send(kind="report")` when done or stuck, and that only messages with
  `from="human"` speak for the person.
- `notice`, `task`, `report`, `question`, `answer` and `review` are delivered
  as prompts. `control` is not: body `cancel` sends `session/cancel` for the
  target's running prompt (also while it is `waiting_human`), `pause` and
  `resume` set and clear `paused`. Other bodies are refused (`-32060`).
- Each delivered prompt is recorded as a synthetic `user_prompt` (section 10)
  and attached or watching connections receive `tunnel.recv` with
  `_ade/turn_started {sessionId, origin: "bus", prompt}` (`prompt` is the
  content blocks); when it is answered they receive `_ade/turn_finished`
  (section 13).
- **The leader's session is also driven by the person.** Bus messages to the
  leader are delivered only while no prompt of that session runs. When a front
  end's `session/prompt` for the leader arrives while a bus prompt runs, the
  service sends `session/cancel` for that session, waits for the bus prompt's
  response, then relays the front end's prompt (the person comes first). The
  cancelled turn's messages are not delivered again.
- **Report fallback**: a bus-delivered turn of a worker is the time from the
  service's `session/prompt` to its response. If the worker did not send a
  `report` to the sender of its current task during that turn, the service
  sends that sender a `report` whose body is the text of the turn's
  `agent_message_chunk` updates for that session (thoughts excluded; at most
  64 KiB, the end kept). A worker's current task is the `task` label of the
  last `task` message delivered to it, and its sender.
- Messages to `human` become `message` inbox items. Messages to an `exited`
  participant are refused (`-32064`).

### 18.5 Inbox

- `bus.ask_human` (tool `bus_ask_human`) `{question, options?}` returns at
  once; the asker becomes `waiting_human` and a `question` item is created.
- Inbox items: `{id, team, kind, from, body, options?, at, state}` with `kind`
  `question`, `spawn`, `permission`, `request`, `message` or `limit`, and
  `state` `open`, `answered` or `orphaned` (its participant exited). They are
  sent to every connection as `team.inbox {item}` and listed by `team.list`;
  they wait for as long as it takes.
- `team.answer {request, text?, option?, allow?}` answers an open item once
  (`-32063` otherwise): a question's answer goes to the asker as
  `kind = "answer"` from `human`, delivered before its other queued messages,
  and the asker returns to `idle`; `spawn` takes `allow`; `permission` takes
  the `option` id (or none for `cancelled`) and is sent to the agent as the
  response; `request` takes a JSON `result` in `text`; `message` and `limit`
  items accept any answer as an acknowledgement. A watcher that answers a
  permission or request directly closes its item too.

### 18.6 Participant connections and the MCP server

`nvim_ade_server mcp` reads `ADE_TEAM_TOKEN` from its environment, connects to
the service socket and sends `hello {participant_token, api_version}`. Such a
connection may call only `bus.*` (anything else `-32065`); `features` in its
`hello` result is empty. The result also carries
`participant {token_id, role, name, team}` (name/team are null before
`team.bind_leader`) so the MCP server can filter `tools/list` before the token is
bound. The role (leader or worker) comes from the token,
never from parameters. When the socket closes the `mcp` process answers
further tool calls with an error and exits once stdin closes; it does not
reconnect.

The MCP side is MCP over stdio: newline-delimited JSON-RPC 2.0, one message
per line. It answers `initialize` with the protocol version the client asked
for when it is `2025-06-18` or `2025-03-26`, otherwise `2025-06-18`, with
`capabilities: {"tools": {}}` and `serverInfo: {"name": "nvim_ade_server",
"version"}`; it accepts `notifications/initialized`, answers `ping`,
`tools/list` and `tools/call`, and `-32601` for anything else. A worker's
`tools/list` does not contain the leader-only tools.

| Tool | Who | `bus.*` method | Input |
|---|---|---|---|
| `team_spawn` | leader | `bus.spawn` | `template` (string, enum of the team's templates), `name?`, `task?` (string, sent as the first `task` message body) |
| `bus_send` | all | `bus.send` | `to` (participant or `human`), `kind` (enum without `control` for workers), `body`, `task?`, `refs?` |
| `bus_ask_human` | all | `bus.ask_human` | `question`, `options?` (strings) |
| `bus_status` | all | `bus.status` | none: members, states, current tasks, queued counts, and for the leader the templates and how many workers it may still start |
| `bus_read` | leader | `bus.read` | `participant`, `since?` (message id): its recent messages and the text of its last 3 turns, at most 64 KiB |

A tool result carries the method's result as JSON text; a method error becomes
`isError: true` with the error message, so the agent can act on it.

### 18.7 Watching a worker

`team.watch {team, participant}` `<- {instance, sessionId}` makes the
connection a **watcher** of that participant's instance: it receives
`tunnel.recv` for everything the agent sends (notifications, and requests that
are pending as in section 5.4, redelivered on watch) and may answer those
requests with `tunnel.send`. Any request frame a watcher sends is refused
(`-32062`): the person talks to a worker through `team.send`. `team.unwatch
{team, participant}` ends it; closing the connection too. A front end replays
what happened before it watched with an emulated `session/load` on the watch
(section 12 applies, so the log must hold the session).

### 18.8 Limits

- `max_workers` counts workers that are not `exited`.
- `max_turns_per_task`: bus-delivered turns of a worker for one task label
  (`_` included). `max_turns_total`: bus-delivered turns of all participants of
  the team. Reaching either pauses the participant (or, for the total, every
  participant) and creates a `limit` item. `team.send {kind: "control", body:
  "resume"}` from the person clears `paused`; `team.reset_limits {team}`
  resets the counters.

### 18.9 Front-end methods and notifications

| Method | Result |
|---|---|
| `team.configure {cwd, config}` | `{}` (18.2) |
| `team.leader_server {instance, cwd}` | `{server, token_id}` (18.2) |
| `team.bind_leader {instance, sessionId, token_id}` | `{team}` (18.2) |
| `team.list {}` | `{teams: [{id, cwd, state: "active" or "leaderless", leader: {instance, sessionId}, participants: [{name, role, state, reason?, instance, sessionId, task, queued, turns}], inbox: [item], limits}]}` |
| `team.send {team, to, kind, body, task?, refs?}` | `{id}`: a message from `human` (queued if the target is working) |
| `team.read {team, participant, since?}` | as `bus.read` |
| `team.answer {request, ...}` | `{}` (18.5) |
| `team.watch` / `team.unwatch` | 18.7 |
| `team.reset_limits {team}` | `{}` (18.8) |
| `team.close {team}` | `{}`: stops every worker and ends the team; the leader's tools then answer "team closed" |

Notifications to every connection: `team.changed {team}` (one entry of
`team.list`, also when a participant exits, with its `reason`) and
`team.inbox {item}`. `agent.list` entries of team members carry `team` and
`participant`.

### 18.10 Error codes

| Code | Meaning |
|---|---|
| -32060 | invalid team parameter (`message` names the field) |
| -32061 | not allowed: unknown template, worker limit, leader-only, team exists for this cwd |
| -32062 | a watcher sent a request; use `team.send` |
| -32063 | unknown or already answered inbox item |
| -32064 | unknown team or participant, or the participant exited |
| -32065 | method not available on a participant connection |

### 18.11 Clarifications (normative; they take precedence over 18.1–18.10)

**States.** A participant's `state` is `idle`, `working`, `waiting_human` or
`exited`; `paused` is a separate boolean that only stops deliveries. `team.list`
participants carry `paused`, and `turns = {task, total}` (bus-delivered turns
for the current task label, and in total). `team.reset_limits` resets the
counters and clears `paused` for limits it caused.

**Ids.** Message ids are integers increasing per team (`bus.read.since` takes
one). Inbox item ids are `i<n>` and token ids `k<n>`, unique in the service.

**Results.** `bus.send` → `{id}`; `bus.ask_human` → `{request}`; `bus.status` →
`{self: {name, role, state, paused}, members: [{name, role, state, paused,
task, queued}], templates?: [name], workers_left?: n}` (the last two for the
leader); `bus.read` and `team.read` → `{messages: [message], turns: [{at,
text}]}` where `messages` are those to or from the participant after `since`
(at most 100) and `turns` the `agent_message_chunk` text of its last 3
bus-delivered turns, 64 KiB in total, the end kept.

**Who may send what.** Workers may `bus_send` to the leader, to other workers
and to `human`, any kind but `control`. The leader may send any kind to anyone
but itself; `control` to `human` is refused (`-32060`). The service checks the
role of the token for every `bus.*` call, whatever `tools/list` showed. Only
values the service validated appear in `<bus ...>` attributes (names, kinds,
task labels contain no quotes). Role cards come from the front end's
configuration and are not escaped.

**First prompt.** A worker's first prompt is one `session/prompt`: the role
card block, then the `<bus kind="task">` block of `team_spawn`'s `task` if
any, then anything else queued.

**Inbox items per kind** (besides `{id, team, kind, from, body, at, state}`):
`question {options?}`, `spawn {template, name, task?}`, `permission {instance,
sessionId, toolCall, options}`, `request {instance, method, params}`,
`message {message}` (the message id), `limit {participant?, scope: "task" |
"total", task?}`. `team.inbox {item}` is sent again whenever an item's
`state` changes. Answers are taken in the order the service receives them:
the first wins, a later `team.answer` gets `-32063`, a later `tunnel.send`
response is dropped silently (section 5.1).

**Ordering.** Notifications caused by a request (`team.inbox`, `team.changed`,
deliveries) are sent before that request's response. `team.changed` is sent
whenever the participant's entry in `team.list` changes, including `queued`;
when the team ends, a last `team.changed` has `state: "closed"`.

**Bus turns are not adoption.** `_ade/turn_started` / `_ade/turn_finished`
(the latter with section 13's shape) go to every connection attached to the
leader's instance or watching the participant; `_ade/turn_adopted` is never
sent for a bus prompt. Section 17's `turn_end` sets bind only to prompts of
front ends, never to bus prompts; on a worker session only sets without
`until` can apply.

**The person's prompt on the leader.** While the service waits for a bus
prompt it cancelled (18.4), the front end's prompt is held: it is not running,
not counted in `turns_running`, and further front-end prompts queue behind it
in arrival order, all before any bus delivery. The service's own
`session/cancel` does not make section 17 sets cancelling. If the bus prompt
was already answered when the front end's prompt arrives, no cancel is sent.
If the agent has not answered the cancelled bus prompt after 30 s, the held
prompts are relayed anyway. A held prompt whose connection closes is dropped.

**Turns that end badly.** A bus turn answered with `stopReason: "cancelled"` or
with an error counts towards the limits, triggers no report fallback, and the
sender of the participant's current task receives a `notice` from the service
(`from` is the participant's name, body `"turn ended: cancelled"` or
`"turn ended: error: <message>"`). The leader's turns never produce a report
fallback. Nothing is delivered again.

**A worker that exits** (crash, stop, `team.close`): its queued messages are
dropped; the sender of its current task and the leader receive a `notice`
(`"worker <name> exited: <reason>"`, `refs = [<task>]`); its open inbox items
become `orphaned` (answers get `-32063`); its tokens stop working. A missing
name for `team_spawn` takes the lowest free `w<n>`.

**`team.close`**: the team stops accepting `bus.*` (`"team closed"`), open
`spawn` items become `orphaned`, workers are stopped, messages queued for the
leader are dropped, then the last `team.changed`. The stop of each worker is
initiated before that notification; the command does not wait for the processes
to exit, and the team is gone from `team.list` afterwards. The leader's session
and instance stay (the person keeps the conversation), but a prompt of the
leader's session that is running when the team closes is cancelled
(`session/cancel`, as in 18.11), whether it came from the bus or from a front
end, and prompts held for it are dropped. `team.bind_leader` for an existing team with a
different session is `-32061`: to change the leader, close the team.

**Watchers.** For a worker instance the watchers play the role of the attached
connections of sections 5.3–5.4 and 14: every pending agent request is sent to
every watcher (and redelivered on `team.watch`), the first answer wins, the
others get `$/cancel_request` (section 14). With no watcher a request waits as
an inbox item; inbox and watchers share one pending set. Watchers do not count
in `attached`. A watcher sends no requests at all (`-32062`); instead
`team.watch {team, participant, replay?}` with `replay: true` sends, before
its response, the replay section 12 would produce (`tunnel.recv` with the
recorded updates). A session the service created is complete from its
`session/new` (the team layer's own requests and responses are not logged).
If the replay would exceed section 12's ceiling the result is
`{instance, sessionId, replayed: false}` and nothing is sent.

**Secrets.** Participant tokens are at least 128 random bits, kept only as
hashes, and never written to the event log (which records no request params,
section 10) or to the service's stderr; neither are template environments.
`team.list` never contains templates or environments. A worker's token stops
working when its session or instance ends. Participant connections receive
no notifications at all (`team.changed`, `team.inbox`, `tunnel.recv`).

**Shapes settled during implementation.** `team.bind_leader` returns
`{team: <the team's team.list entry>}`. In a delivered prompt each ref follows
the body as a child element: `<bus from="leader" kind="task" task="T3">body<ref>src/x.rs</ref></bus>`
(refs escaped like bodies). A message whose task is `_` has no `task`
attribute; `team_spawn`'s `task` is sent with task `_`. `bus.status.members`
lists every participant including the caller, never `human`. A `team.list`
entry's `limits` is `{max_turns_per_task, max_turns_total, turns_total}`.
`team.watch` always returns `{instance, sessionId, replayed}` (`replayed` is
false when no replay was asked for or it was too large). A closed team is
gone from `team.list` once its last `team.changed` was sent. Worker names are
unique for the team's lifetime: a default name never reuses an exited
worker's name.

### 18.12 Worktrees for workers (S4c)

A template may set `"worktree": true`, and `config` may carry
`"worktree_root"` (absolute; the front end sends
`stdpath("data") .. "/ade/worktrees"`). Starting a worker of such a template:

- the team's `cwd` must be inside a git work tree (`git -C <cwd> rev-parse
  --show-toplevel`), and `worktree_root` must be set; otherwise the spawn fails
  (`-32061`, and a `notice` to the leader for an approved request);
- the service runs, without a shell and with the template's environment,
  `git -C <toplevel> worktree add -b ade/<team>-<stamp>/<name> <worktree_root>/<repo>-<hash8>/<team>-<stamp>-<name> HEAD`,
  where `<repo>` is the toplevel's last path component (characters outside
  `[A-Za-z0-9._-]` replaced by `_`) and `<hash8>` the first 8 hex digits of
  SHA-256 of the toplevel's absolute path, and `<stamp>` the team's creation
  time in UTC as `YYYYMMDD-HHMMSS` (the stamp keeps names unique even if two
  teams share an id across separate event logs). An existing branch or directory of
  that name is an error (`-32061`), never reused;
- the worker's `cwd` is the worktree directory, plus the same relative
  subdirectory the team's `cwd` has inside the toplevel.

The worktree and its branch are **kept** when the worker exits or the team
closes: they hold the worker's work. `team.list` participants carry
`worktree: {path, branch}`. `team.remove_worktree {team, participant, force?}`
`<- {}` removes an exited worker's worktree (`git worktree remove [--force]`)
and deletes its branch only when it is merged into the toplevel's current
`HEAD` (`git branch -d`); a running worker is `-32061`, a failing git command
`-32060` with git's stderr (at most 4 KiB) in `data.stderr`. While a team
lives, `team.read` of a worker also returns `worktree`.

### 18.13 Workers started by the person (S4c)

`team.spawn {team, template, name?, task?}` `<- {name}` starts a worker on
behalf of `human`: no inbox item, no confirmation (the person asked), the
same limits as 18.3. The leader receives a `notice` from `human`
(`"worker <name> started from template <template>"`). Automatic workflow
startup uses `team.start` instead (19.7).

### 18.14 Version restarts and teams (S4c)

A front end that finds a service of another version (its version check) must
treat a service with any team as **busy**: it must not restart it, whatever
the instances' states. `agent.list` result entries are unchanged; the front
end learns about teams with `team.list` when the service offers `"teams"`.

### 18.15 Recovery after a service restart (S4c)

Teams are stored in the event log database (section 10, mode 0600) and come
back after a restart of the service as **suspended** teams. Template `key`,
`env` and `launch` are never written: a suspended team resumes only when a
front end supplies its configuration again. Message bodies **are** written
(the queue and the last 200 messages of each team); README states this.

**Stored**, in the same transaction as each change (written by the store's own
thread, never on the delivery path): per team `id`, `cwd`, creation stamp,
`state`, the configuration without template `key`/`env`/`launch`, the leader's
`sessionId` and agent id; per participant name, template, `sessionId`,
worktree and `base`, state, `paused`, current task and sender, turn counters;
queued messages; the last 200 messages; open inbox items. A delivery removes
its messages from the queue and marks the participant's bus turn in the same
transaction, queued before the prompt is sent. The write itself is
asynchronous: a SIGKILL between queueing that transaction and writing it may
deliver the prompt **once more** after the restart (at-least-once, never a
loss). New tables are added with a schema migration (the existing event log is
kept, never renamed away). Team ids are never reused: new teams continue after
the highest id ever stored.

**After a restart** every stored team that was not closed is `suspended`:
`team.list` shows it with `state: "suspended"`, `suspended_at` (milliseconds
since the epoch, like every `at`), `leader: {instance: null, sessionId}`, and
participants with `instance: null`. While suspended: `team.send` queues,
`team.answer` works for `question`, `message` and `limit` items,
`team.remove_worktree` works, `team.close` removes the team and all its stored
rows; `team.watch`, `team.spawn` and `bus.*` are `-32064` ("suspended").

**Resuming.** Front ends send `team.configure` after every `hello`. For a
suspended team, `team.leader_server {instance, cwd}` is allowed for any
instance whose `key.cwd` is the team's `cwd`. The team resumes, atomically and
once, at the first `team.bind_leader` whose `sessionId` equals the stored
leader session while a configuration for that `cwd` is present (another
session is `-32061`; while the resume runs, a bind of the same session only
adds its token). The front end restores the leader's conversation as usual
(section 12 or the agent's own `session/load`); when that produced a different
session, the team stays suspended and the person can close it from the panel.

Resuming starts, for each participant that was not `exited`, its template as
in 18.3 (`cwd` = its stored worktree, which must still exist), sends
`initialize`, then `session/load {sessionId, cwd, mcpServers: [new server]}`
when the agent advertises `loadSession`. If the agent does not advertise it,
or the load fails, the service sends `session/new` instead and the leader gets
a `notice` that the worker restarted without its history. New tokens are
issued. A participant whose template is no longer configured, whose worktree
is gone, or whose start fails becomes `exited` with that reason. Each
participant's entry changes from `instance: null` to its new instance as it
starts (one `team.changed` each); the team's state becomes `active` first.
The leader receives one `notice` from the service: `"team resumed after a
service restart"`, listing workers that could not be resumed.

What was in flight at the restart: a bus turn that was running ends as an
error (`"turn ended: error: the service restarted"`, 18.11), held prompts are
gone, `permission` and `request` items become `orphaned`, other open items
stay open, and queued messages are delivered once the participants run again.

**Expiry.** A team suspended for more than 7 days is removed (with all its
rows) when the service starts and on an hourly check; its worktrees and
branches are kept, as always.

Front ends no longer treat a reconnect as the end of every team: they show
suspended teams (with `x` to close them) and do not block the leader injection
for a suspended team's `cwd` (`leader.instance` is null).

### 18.16 S4c clarifications (normative; take precedence over 18.12–18.14)

**What a worktree starts from.** `HEAD` must resolve to a commit
(`git rev-parse --verify HEAD^{commit}`); an unborn branch or a bare
repository is `-32061`. A detached `HEAD` is allowed. The worktree holds the
**committed** state only: uncommitted and untracked changes of the team's tree
are not in it. When `git status --porcelain` of the toplevel is not empty, the
spawn result (and the `notice` for an approved request) carries
`warning: "dirty_tree"`, and the worker's role card says that it starts from
the last commit. Inside a submodule the toplevel is the submodule's; the new
worktree's own submodules are not initialised. If the team's subdirectory
does not exist in the worktree, the worker's `cwd` is the worktree root and the
leader gets a `notice`. The toplevel is canonicalised (symlinks resolved)
before hashing.

**Running git.** git runs with the **service's** environment minus `GIT_DIR`,
`GIT_WORK_TREE`, `GIT_INDEX_FILE`, `GIT_OBJECT_DIRECTORY`,
`GIT_COMMON_DIR`, plus `GIT_TERMINAL_PROMPT=0`; never through a shell; with a
60 s timeout (hooks included). Commands on the same toplevel are serialised.
A failing or timed-out git command is `-32066` with git's stderr (at most
4 KiB) in `data.stderr`.

**Removing.** Each worker records `base` (the commit its branch started
from). `team.remove_worktree` removes the worktree first (`git worktree
remove`, `--force` when asked); then the branch is deleted
(`git branch -D`) only when its tip is an ancestor of the toplevel's current
`HEAD` (`git merge-base --is-ancestor`). The result is
`{removed: true, branch_kept: bool, branch}`; keeping the branch is not an
error. Allowed for exited workers only (`-32061`).

**`team.spawn`.** Same checks and errors as `bus.spawn`
(`-32061` unknown template or worker limit, `-32060` invalid or used name).
Allowed for a `leaderless` team (the leader's notice queues). Front ends start
the workers of a configured team only for names that are **not** already in
the team's `team.list` participants (whatever their state), so reconnecting or
a second front end never starts them twice.

**Version check (18.14).** The front end asks `team.list` with a 5 s timeout;
a failure or timeout counts as busy, `-32601` (a service without teams) as no
teams; a team whose state is `suspended` (18.15) does not count.

| Code | Meaning |
|---|---|
| -32066 | a git command failed (`data.stderr`) |

## 19. Boards, workflows and team start (W0, api_version 6)

The `"teams"` feature at api_version 6 adds a **board** per team, named
**workflows**, `team.start`, per-spawn `model`/`role`, spawn groups and
participant activity. Section 18 stays in force except where this section
says otherwise. The service has no workflow state machine: it validates,
stores, relays and extracts; what a workflow means is text the leader follows.
Error codes are those of 18.10 and 18.16; no new code is added.

### 19.1 Configuration

`team.configure`'s `config` gains:

```
config = {
  ...,                                        // 18.2, 18.12
  "workflows": { "<name>": workflow },        // optional; read-only workflows from the person's setup
  "default_workflow": string?,                // a name of "workflows" or "default"
  "derived": { "template": string, "agent": string }?,  // a template derived from that agent's own launch
  "templates": {
    "<name>": {
      ...,                                    // 18.2
      "role":       string?,                  // now optional, default ""; up to 16 KiB
      "models":     string[]?,                // allowed spawn models; absent or [] = any
      "tool_style": "direct" | "mcp_proxy"    // optional, default "direct" (19.6)
    }
  }
}
```

**Derived templates.** A front end that derives a template from its own
leader's launch (a fresh installation without `teams.templates`) declares it
with `derived: {template, agent}`: `template` must be a template of this same
configuration whose `key.agent` equals `agent` (`-32060` otherwise).

The service derives a fingerprint from that template's launch (`key`, `env`
and managed release) and keeps the configuration under `(cwd, fingerprint)`.
A leader may only use the entry whose fingerprint equals its own instance's,
so two leaders that share an agent id but start with a different command,
arguments, environment or managed release are told apart (`-32061` for the
other). An explicit configuration declares no `derived`, replaces every derived
entry for its cwd and serves any instance. `derived` is never written to the
event log; a restored team takes its configuration from the front end that
resumes it.

**Recovery.** A restart resume checks the stored team against what the resuming
front end supplies. A team stored for one leader *agent* is refused (`-32061`)
when the resuming bind reports another, whatever the session id says. A stored
participant resumes only under a template that starts the agent it ran; if the
template now starts another one, the participant stays `exited` with that
reason instead of handing its stored session to a different adapter.

**Chat by-products.** A team a session creates by merely chatting has no
worker, card or inbox item. `team.leader_server` and `team.bind_leader` let
another session of the same cwd take such a team over (the bind moves the
leader instance, session and configuration), so asking for a team in a new
session works through ordinary chat. A team with any worker, card or inbox item
keeps its leader: another leader is `-32061`.

A workflow on the wire:

```
workflow = {
  "name":    string,              // [a-z0-9][a-z0-9_-]{0,31}
  "summary": string,              // one line, 1..120 characters
  "text":    string?,             // up to 4 KiB; absent = the built-in default's text
  "leader":  { "agent": string?, "model": string?, "role": string? }?,   // role up to 4 KiB
  "team":    [member],            // 0..8 entries
  "columns": string[]?,           // 1..16 unique titles, each 1..40 characters
  "scope":   "config" | "project" | "user" | "builtin"   // in results only
}
member = { "name": string, "template": string, "model": string?, "role": string?, "task": string? }
```

Validation (`-32060`, `message` names the field): member names are valid
worker names (18.3), unique, and never `leader` or `human`; each `template`
exists in the configuration being validated; a member's `model` is in that
template's `models` when the list is not empty; `role` up to 16 KiB; `task` up
to 64 KiB. The service does not interpret `leader`: it is stored and returned
for the front end (the leader is always the session that bound the team).

The **built-in** workflow `default` always exists (`scope: "builtin"`, empty
`team`, columns `待开发`, `进行中`, `审查中`, `等你决定`) with the text of the
default flow (`docs/w0-team-dashboard-draft.md` 2.1). A configured workflow
named `default` replaces it.

**Resolution.** A name resolves in this order: `config` (the team's
configuration), `project`, `user`, `builtin`. The **project key** is the
canonical path of `git rev-parse --git-common-dir` run in the team's cwd (git
as in 18.16), or the canonical cwd when that fails; worktrees of one
repository therefore share project workflows.

### 19.2 The board

Every team has one board, created empty with the team:

```
board = {
  "rev":           integer,       // 0 when created; +1 per successful write
  "workflow_name": string?,
  "workflow":      string?,       // up to 4 KiB
  "columns":       string[],      // up to 16 unique titles, each 1..40 characters
  "cards":         [card]
}
card = {
  "id":         string,           // [A-Za-z0-9][A-Za-z0-9_.-]{0,31}
  "title":      string,           // 1..200 characters
  "column":     string,           // one of columns (not checked for archived cards)
  "owner":      string?,          // a worker name of the team (any state)
  "stage":      string?,          // 1..40 characters
  "body":       string?,          // up to 8 KiB
  "fields":     object<string,string>?, // up to 12 keys (1..32 chars), values up to 120 chars
  "archived":   boolean,
  "updated_by": string,           // "leader", a worker name, or "service"
  "updated_at": integer           // ms since the epoch
}
```

Limits: at most 200 cards that are not archived; at most 500 archived cards
(beyond that the oldest archived cards, by `updated_at`, are dropped); the
board serialised as JSON at most 256 KiB. A write that would break a limit is
refused with `-32060` and changes nothing.

**`bus.board_update`** (tool `board_update`, leader only, `-32061` otherwise):
`{workflow_name?, workflow?, columns?, upsert?, archive?, remove?}` `<- {rev}`.
Applied in that order as **one** atomic write; the result is validated as a
whole:

- `workflow_name` / `workflow`: replace the value (`null` clears).
- `columns`: replaces the list.
- `upsert: [partial card]`: by `id`. A new card needs `title` and `column`; an
  existing card takes the given fields only (`owner: null`, `stage: null`,
  `body: null` clear; `fields` merges by key and a `null` value deletes the
  key; `fields: null` removes every key). `archived`, `updated_by` and `updated_at` cannot be written here.
  Upserting an archived card is `-32061`.
- `archive: [id]`: sets `archived`; the card's history is deleted (19.4).
- `remove: [id]`: deletes the card and its history.
- Unknown ids in `archive`/`remove`, an id listed twice across `upsert`,
  `archive` and `remove`, an `owner` that is not a worker of the team, or a
  card that is not archived whose `column` is not in `columns` (for example
  after removing a column that still has cards) are `-32060`.

**`bus.card_update`** (tool `card_update`, workers only):
`{card, body?, fields?, archive?}` `<- {rev}`. The card must exist (`-32060`),
not be archived and have the caller as `owner` (`-32061`, message
`"not your card"`). `body` replaces (`null` clears), `fields` merges as above,
`archive: true` archives (19.4); `archive: false` is `-32060`.

The service sets `updated_by` and `updated_at` on every card it changes.
`rev` increases by one per successful call, even when nothing changed.

**Coalescing.** A leader write is persisted and announced at once. Worker
writes take effect in memory at once (`team.board` and `bus.status` see them),
but persistence and `team.board_changed` happen at most once per 10 s per
team: the first worker write starts a 10 s timer, and when it fires the board
is persisted and one notification with the current `rev` is sent. A leader
write while the timer runs flushes it first: the front end then receives two
`team.board_changed`, the flushed `rev` and then the leader's. Pending writes
are flushed (and announced) when the team ends, before the expiry check of
18.15, and when the service shuts down cleanly. The timer is
`NVIM_ADE_SERVER_BOARD_FLUSH_MS` milliseconds (default 10000), for tests.

**`team.board {team}`** `<- {board}` for front ends (`-32064` for an unknown
team). When the stored board cannot be read (bad JSON or a database error at
startup) the board is **unavailable**: it shows as empty with
`"unavailable": true` (in `team.board` and the leader's `bus.status.board`;
the field is absent otherwise), every write is `-32061` (`"board
unavailable"`), and the stored row is never overwritten. **`team.board_changed {team, rev}`** is sent to front-end connections
only. Board changes are never delivered to any participant.

### 19.3 What agents see of the board

There is no tool that reads cards: the board is for the person. `bus.status`
for the **leader** gains:

```
"board": {
  "rev", "workflow_name", "columns",
  "cards":    [{ "id", "title", "column", "owner", "stage" }],  // not archived
  "archived": { "<stage or empty string>": integer }           // archived cards per stage
},
"workflows": [{ "name", "summary", "scope" }],                  // as team.workflows, short
"templates": [{ "name", "agent", "models" }]                     // replaces the list of names
```

`agent` is the template's `key.agent`; `models` is `[]` when any model is
allowed. `bus.status` for workers is unchanged.

**Card messages.** `team.send` gains `card?` (a card id, `-32060` if
unknown). The service prefixes the body with one summary line and a newline,
`[card <id> · <title> · <column> · <owner or -> · k=v · ...]` (the `fields`
in key order, the line cut at 400 characters), and uses `card` as `task`
when `task` is absent. Delivery is otherwise as 18.4: the message queues and
is merged with other queued messages into the leader's next bus turn.

### 19.4 Card history

When a write is **persisted**, the previously persisted version of every card
it changed is stored as history (intermediate in-memory versions of coalesced
worker writes are not). Each card keeps its 20 newest versions; older ones
are deleted in the same transaction. Archiving or removing a card deletes all
of its history. History is never shown to agents.

`team.card_history {team, card}` `<- {versions: [card]}`, newest first; `[]`
for an archived card or a card without history; `-32060` for an unknown card.

### 19.5 Workflow methods

| Method | Who | Params | Result |
|---|---|---|---|
| `bus.workflow_save` (tool `workflow_save`) | leader | `workflow` (without `scope`, plus `scope: "project" \| "user"`, default `"project"`), `replace?` | `{name}` |
| `bus.workflow_get` (tool `workflow_get`) | leader | `name` | `{workflow}` (resolved, 19.1) |
| `bus.workflow_delete` (tool `workflow_delete`) | leader | `name`, `scope?` | `{}` |
| `team.workflows {cwd}` | front end | | `{workflows: [workflow]}` |
| `team.workflow_delete {cwd, name, scope}` | front end | | `{}` |

- `workflow_save` validates against the **team's** configuration (19.1). A
  stored workflow with the same name and scope is `-32061` (`"workflow
  exists"`) unless `replace: true`. A name that resolves to a `config`
  workflow is `-32061` (the configured one would hide it).
- `workflow_get` of an unknown name is `-32060`.
- `workflow_delete` without `scope` deletes the stored workflow that the name
  resolves to; a `config` or `builtin` one, or no stored one, is `-32061`.
- `team.workflows {cwd}` lists every name visible from `cwd` once, the
  resolved one, sorted by name, with the configuration of the running team for
  `cwd` if there is one, else the stored configuration (18.2). Stored
  workflows whose templates no longer exist are still listed.
- At most 100 stored workflows per scope and project; `workflow_save` of a
  new name beyond that is `-32061` (`"too many workflows"`).
- Stored workflows live in the service's database (19.11) and outlive teams.

### 19.6 Spawning with a model and a role

`bus.spawn` and `team.spawn` gain `model?` and `role?`:

- `model` must be in the template's `models` when that list is not empty
  (`-32060`). Without `model`, the template's `model` applies (18.3).
- `role` (up to 16 KiB) is appended to the template's `role` in the role card.
- **Model check.** When a model applies (from the spawn or the template) and
  the `session/new` result's `configOptions` has no option with id `model`
  whose values include it, the service does **not** go on silently: it stops
  the worker (state `exited`, `reason` `"model unavailable: <model>"`) and
  sends the leader a `notice` naming the model and the values the agent offers
  (at most 50). This replaces 18.3's silent skip.
- **Role card** additions (18.4): the board conventions for workers (keep your
  own card's `body`/`fields` current with `card_update`; the card is for the
  person, so reports to the leader carry the details the leader needs; archive
  your card with `card_update {archive: true}` when the leader confirms the
  task is done). For a template with `tool_style: "mcp_proxy"` the card also
  says that team tools are called through the agent's `mcp` proxy tool
  (`mcp({tool: "bus_send", args: {...}})`); the front end sets it for agents
  known to work that way (pi).
- **Spawn items** (18.5) gain `model`, `role`, `agent` (the template's
  `key.agent`) and `group`.

**Spawn groups.** Every inbox `spawn` item carries `group` (`g<n>`, unique in
the service). Items created during one prompt of the leader's session (from
the request to its response, whether the prompt came from the bus or from a
front end) share a group; an item created while no prompt of the leader runs
gets a group of its own. The service tracks that turn per `(instance,
sessionId)` **before** any team exists, so v3's lazy team creation (20.4)
inherits it: when the first front-end prompt of a new chat arrives there is no
team yet, and the `team_spawn` tools of that turn create the team mid-turn. A
team created during a turn adopts the turn's group, so every spawn of that
turn still shares one group. The turn ends with the prompt's response (or the
session closing or the instance exiting), which also ends the group.
`team.answer_group {group, allow}` `<- {answered:
[item ids], failed: [{id, code, message}]}` answers every **open** item of the
group as `team.answer` would, in creation order. An item whose answer fails is
skipped (it stays open and is listed in `failed`); the others take effect.
`-32063` when none is open; when every item fails, the error of the first.

### 19.7 `team.start`

`team.start {team, workflow, task?}` `<- {workflow, started: [name], skipped:
[name]}` starts a team's workflow on behalf of `human`:

1. The name resolves as in 19.1 (`-32060` if unknown); `task` is at most
   64 KiB (`-32060`). A `suspended` team is
   `-32061`; a `leaderless` one is allowed (the notice queues).
2. Members whose name is already a participant (any state) are `skipped`.
   If the remaining members would exceed `max_workers` live workers, nothing
   starts and the result is `-32061`.
3. Each remaining member is started as by `team.spawn` (no confirmation;
   `model`, `role` and `task` from the member), in order.
4. When the board has no `workflow_name`, the service writes `workflow_name`,
   `workflow` (the text), and `columns` (when the workflow has them and the
   board has none) as one write with `updated_by: "service"`. An unavailable
   board (19.2) is left alone and the start goes on.
5. The leader receives one `notice` from `human` whose body is, in this
   order: the base instructions (19.8), `task` if given, the workflow's name,
   summary and text, the members (name, template, agent, model, role), and the
   columns. A body over 64 KiB is cut in the member roles and the text, never
   in the instructions or `task`. If the notice cannot be sent the result is an
   error (the members already started stay).

The front end uses `team.start` for `:Ade team start` and for the automatic
start of `teams.auto_start` (instead of calling `team.spawn` per worker).

### 19.8 Leader instructions

For a **leader** token the MCP server's `initialize` result carries
`instructions`: the base instructions, at most 2 KiB, the same text that
`team.start`'s notice repeats. They say that the agent can build a team; that
it does so only when the person asks or after proposing it and getting
consent; the board conventions (the leader owns columns, cards, owners,
stages and moves; workers write their own cards; cards are for the person and
not a source of details; archive after the person confirms a stage was
committed); that a stage is confirmed with the person once, not per card; and
how named workflows are used and saved (only save when asked; write `leader`
only when the person mentions the leader). Workers get no `instructions`.

### 19.9 Activity

`team.list` participant entries gain `activity` (`{text, at}` or `null`) and
`state_since` (ms since the epoch when `state` last changed; set at restart
for recovered participants). `activity.text` is one line of at most 120
characters, taken from the latest of:

- for workers: a `tool_call` or `tool_call_update` with a `title` (the title,
  prefixed by its status when it is `failed`); the `in_progress` entry of a
  `plan` update; a `bus.*` call it made (`→ leader report T4: <first line of
  the body>`, `asks: <question>`, `card T4 updated`); at the end of a bus turn
  without any of these, the first line of the turn's text;
- for the leader: only its `bus.*` calls (`→ w1 task T4: ...`, `spawn w2`,
  `board updated`).

An activity change alone sends `team.changed` at most once per 2 s per
participant (the last value wins); state changes are sent at once as before.
Activity is not persisted.

`team.list` team entries gain `board_rev`, `workflow_name` and `stages`:
`[{stage, open, archived}]` counted over the board's cards, in order of the
first card of each stage, cards without a stage under `""`.

### 19.10 Tools

| Tool | Who | Method |
|---|---|---|
| `team_spawn` | leader | `bus.spawn`, input gains `model`, `role` |
| `board_update` | leader | `bus.board_update` |
| `workflow_save`, `workflow_get`, `workflow_delete` | leader | `bus.workflow_*` |
| `card_update` | worker | `bus.card_update` |
| `bus_status` | all | `bus.status` (19.3) |

A leader's `tools/list` does not contain `card_update`; a worker's does not
contain the leader tools.

### 19.11 Storage

The event log database (section 10, 18.15) gains three tables, added by a
schema migration as in 18.15 (the existing data is kept):

- `boards (team_id PRIMARY KEY, rev, json)`: the board as last persisted;
- `card_history (team_id, card_id, rev, json, ts_ms, PRIMARY KEY (team_id, card_id, rev))`;
- `workflows (scope, project, name, json, updated_ms, PRIMARY KEY (scope, project, name))`,
  `project` being `""` for `user`.

A team's board and history are deleted with the team (`team.close`, or the
7-day expiry of 18.15). A suspended team keeps its board and gets it back on
resume. Writes go through the store thread as in 18.15 and never block
delivery. Whenever the service runs without that database (the cases where
18.15 stores no teams), boards live in memory only and `workflow_save` is
`-32061` (`"no database"`).

### 19.12 Member labels and owners awaiting approval (W0 v2)

**Labels.** `bus.spawn`, `team.spawn` and workflow members (19.1) gain
`label?`: a short role label for display, 1..16 characters, one line
(`-32060` otherwise). Spawn inbox items carry it too.

**`team.list` participant entries** gain `template` (the template name, absent
for the leader), `agent` (the template's `key.agent`; for the leader the agent
id of its instance), `model` (the model applied by 19.6, or `null`), and
`label` (the spawn's `label`, else the template name; `"leader"` for the
leader). They are persisted with the team and restored with it.

**Owners awaiting approval.** A card's `owner` (19.2) may also be the name of
an **open** `spawn` inbox item of the team. When that item is refused, or
becomes `orphaned`, the service clears `owner` on every card that has it (one
write, `updated_by: "service"`, `team.board_changed`) and sends the leader a
`notice` naming the cards. When it is approved nothing changes. A name used by
an open spawn item is reserved: another spawn with that name is `-32060`
until the item is answered.

### 19.13 Several questions in one `bus.ask_human` (W0 v2)

`bus.ask_human` (tool `bus_ask_human`) accepts either the 18.5 form
`{question, options?}` or:

```
{ "questions": [ {
    "header":       string,     // 1..12 characters, one line (the tab label)
    "question":     string,     // up to 4 KiB
    "options":      [ { "label": string, "description": string? } ]?,  // 0 or 2..6; label 1..60 chars, description up to 200
    "multi_select": boolean?    // default false
} ] }                           // 1..4 entries
```

Anything else is `-32060`. The 18.5 form is normalised to one question with
`header: "Question"` and each option string as a `label`. The `question` inbox
item carries the normalised `questions` (and keeps `body`/`options` for the 18.5
form). The person may always answer a question with free text instead of an
option.

`team.answer` for a question item accepts `answers: [{selected: [label], text?}]`
(one entry per question, in order; `selected` empty when only `text` is given;
`-32060` when the count or a label does not match) as well as the 18.5
`text`/`option`. The asker receives one `answer` message whose body lists, per
question, `<header>: <selected labels joined by ", ">` and the free text on the
next line when given.

### 19.14 Talking to a worker directly (W0 v2)

`team.send` (front ends only) gains:

- `interrupt?: boolean` — only for a `to` that is a worker. When the worker has
  a bus prompt running, the service sends `session/cancel` for it, waits for
  its response (at most 30 s, as for the leader in 18.11), then delivers this
  message **before** anything else queued for the worker. Messages of the
  cancelled turn are not delivered again (as 18.4). When nothing runs it is an
  ordinary send. `interrupt` to the leader or `human` is `-32060`.
- `cc?: ["leader"]` — after the message is accepted, the leader also receives
  a `notice` from `human` whose body is `"to <worker>: <body>"` (`task`
  copied; the `[card …]` prefix of 19.3 kept). Only `"leader"` is allowed in
  `cc`, and only when `to` is a worker (`-32060` otherwise).

## 20. Teams v3: session tools, lazy teams, per-session switch (api_version 7)

This section is normative and takes precedence over sections 18 and 19 where
they disagree. It removes the coupling "creating a session = binding a team":
every chat **can** start a team, but a team exists only once one is asked
for. There is still at most one team per `cwd`.

### 20.1 Removed

- `team.leader_server` and `team.bind_leader` are gone (`-32601`). The front
  end no longer puts anything into `mcpServers`; the service does (20.2).
- `config.derived` (19.1) is gone and ignored if sent; the derived-config
  fingerprints, the "chat by-product" take-over (19.1) and `pending_resume`
  ordering between `team.configure` and a bind are gone.
- A session that merely chats never creates a team, is never persisted as one
  and never keeps the service from idle-exiting.

### 20.2 Session tools (the service injects the MCP server)

`team.configure {cwd, config}` gains `config.enabled` (boolean, default true)
and `config.session_default` (boolean, default true). The front end calls
`team.configure` for a cwd **before** its first session request in that cwd
(and again when its setup changes). With no configuration for a cwd, or
`enabled: false`, nothing below happens for that cwd.

When a front end's `session/new`, `session/load` (forwarded, not emulated) or
`session/resume` for an instance whose `key.cwd` has an enabled
configuration passes through the relay, the service appends to
`params.mcpServers` (creating the array if absent) the entry
`{"name": "ade-team", "command": <absolute path of the service binary>,
"args": ["mcp"], "env": [{"name": "ADE_TEAM_TOKEN", "value": <token>}]}`
with a fresh **session token**. An entry already named `ade-team` in the
request is replaced. Workers keep their own injection (18.3) and are never
given a session token.

- `session/load` / `session/resume`: the token is bound to `(instance,
  sessionId)` immediately (the id is in the request).
- `session/new`: the token is bound when the successful response arrives
  (`result.sessionId`). A failed response revokes it.
- A token is revoked when its session is closed/deleted or its instance
  exits. Tokens are stored only as hashes (as in 18.6).

An emulated `session/load` (section 12) never reaches the agent: the agent
keeps the server it already has, and the existing binding stays valid.

The MCP server's `hello` result now carries `participant {token_id, role,
name, team}` where `role` is `"session"` for a session token; `name`/`team`
are the session's current team role (`"leader"`, `t3`) or null. The role is
re-evaluated at every `tools/list` and `tools/call`; parameters never choose it.

### 20.3 Tools by state

| Session state | `tools/list` |
|---|---|
| switch off (20.5) | empty |
| not the leader of any team | `team_spawn`, `bus_status`, `workflow_get`, `workflow_save`, `workflow_delete` |
| leader of its cwd's team | the full leader set (18.6, 19.10) plus `team_stop` (20.6) |

`initialize` declares `capabilities: {"tools": {"listChanged": true}}`, and
the MCP process sends `notifications/tools/list_changed` when the set
changes (a team is created or closed for this session, leadership moves, the
switch flips). Agents that ignore the notification still get a correct
answer at call time: a tool not in the current set returns `isError: true`
with a one-line reason (`teams are off for this chat`, `this chat does not
lead the team`, ...).

The base instructions (19.8) are now sent to **every** session token's
`initialize`, unchanged in substance: build a team only when the person asks
or agrees.

### 20.4 Lazy team creation and the leader

`Teams::ensure_team(instance, sessionId)` is the single path to a team:

1. the session must hold a bound session token and its switch must be on
   (`-32061`, `data.reason = "no_tools"` / `"off"`);
2. no team for the cwd: a team is created with this session as leader and
   the cwd's configuration (snapshot, as before);
3. the cwd's team is led by this session: it is returned;
4. otherwise `-32061` with `data = {reason: "led_by", team, leader:
   {instance, sessionId}}`.

When `config.templates` is empty the team gets one template named `worker`
(the front end's `BUILTIN_TEMPLATE`) built by the service from the leader
instance's own `key`, `env` and `launch` (as stored by `agent.attach`), with
`worktree: true` and an empty role. Validation of a configuration with empty
`templates` accepts `worker` in workflows and `spawn_confirm.auto`.

Callers of `ensure_team`:

- `bus.spawn` (`team_spawn`) from a session token. On `led_by` the service
  creates an inbox item `{kind: "handover", team, from: {instance,
  sessionId}, leader: {instance, sessionId}}` (answers `"move"` or
  `"refuse"`, 18.5 rules) and the tool result is `isError: true`, text: the
  team is led by another chat and the person was asked to hand it over.
  `"move"` runs `team.set_leader` for the requesting session and sends it a
  `notice`; `"refuse"` sends it a `notice` too.
- `team.spawn` and `team.start` accept **either** `team` **or**
  `{instance, sessionId}` (exactly one form, `-32060`); the second form calls
  `ensure_team` first. Their results gain `team`.

`team.set_leader {team, instance, sessionId}` `<- {}`: moves the leader of a
live, leaderless or suspended team to that session. The session must be in
the team's cwd, hold a bound session token and have its switch on
(`-32061`, `data.reason` as in 20.4). The previous leader's tools fall back
to the non-leader set; the new leader receives one `notice` from `human`
with the base instructions and the current `bus_status` text. A suspended
team is resumed by it (18.15 resume, with this session as leader).

### 20.5 Per-session switch

`session.teams {instance, sessionId, enabled?}` `<- {enabled, injected,
leader: team|null}`:

- without `enabled`: query only;
- `enabled: false`: tools disappear for the session. If the session leads a
  team the call fails with `-32061` `data.reason = "leads_team"` unless
  `close: true` is also given, in which case the team is closed first
  (`team.close`);
- `enabled: true` and `injected: false` (the session was created before teams
  were configured, under the direct backend, or the server process died): the
  result carries `reload: true` and the service marks the session **one-shot
  forward**: the next `session/load` (or `session/resume`) of that session from
  any front end is forwarded to the agent (never emulated, section 12) and gets
  the injection of 20.2 like any forwarded load. The **front end** then performs
  that load through its normal load path (it clears and re-renders the
  transcript from the agent's replay). The service never sends a load itself and
  never swallows or filters any frame. If the agent advertised neither
  `loadSession` nor `sessionCapabilities.resume` (either a boolean `true` or an
  object), the call fails with `-32061`, `data.reason = "reload_unsupported"`,
  and nothing is marked. A failed forwarded load leaves the session as it was
  (the fresh token is revoked; the old binding and server list stay).

A forwarded load or resume that was marked one-shot and answered successfully
restarts that session's log from this load: earlier recorded events are never
replayed again (the session is marked incomplete, so a later `session/load` is
forwarded instead of emulated).

`injected` is true while a bound session token's MCP process is connected.
The switch defaults to `config.session_default`, is stored per
`(agent, sessionId)` in the service database, and survives restarts. Every
change sends `session.teams_changed {instance, sessionId, enabled, injected,
leader}` to every connection.

A read-only query (no `enabled`) never waits. It gains `pending: true` when
the session holds a bound token whose MCP process has never connected: the
server was injected, the agent's MCP process is simply not up yet. The next
`session.teams {enabled: true}` for such a session does not answer at once:
it is **held** until that token's MCP process connects (the reply then has
`injected: true` and no `reload`, so the front end does not reload), or for
at most 10 s (`NVIM_ADE_SERVER_TEAM_INJECT_TIMEOUT_MS` shortens it in tests),
after which it decides as before: still no connection means the one-shot
forward mark and `reload: true`. This is the normal case of a brand-new chat:
`session/new` just returned and the agent is still starting its MCP process,
so enabling teams for the first time does not cost a reload.

While a reply is held, a change to what it waits on answers it immediately
with the state as it is then: the token is revoked, the instance exits, or
the session is closed/deleted/switched off. A front end that disconnects
simply loses its held reply (nothing is sent to a closed connection). An
enable request that arrives while another one is held is held separately, so
each request gets exactly one answer.

### 20.6 Stopping one worker

`team.stop_worker {team, name, remove?}` `<- {}`: stops a worker's instance
(as on `team.close`); the participant becomes `exited` with reason `stopped`
and its open items are orphaned. With `remove: true` the participant is also
dropped from the team (its name becomes free again) after it exited; its
worktree is kept (use `team.remove_worktree` first if wanted). `leader` and
`human` are `-32060`; an unknown name `-32064`. The leader receives a
`notice` (`worker <name> stopped by the person`).

Leader tool `team_stop {name, remove?}` → `bus.stop_worker`, same rules,
no notice to itself.

### 20.7 Recovery

A stored (suspended) team is resumed only when **all** hold: a forwarded
`session/load` or `session/resume` of its stored leader `sessionId` was
**answered successfully** by the agent; that request got a session token
(20.2: the instance's cwd is configured and enabled, and the session's switch
is on); the instance's `key.cwd` equals the team's cwd; and the instance runs
the stored leader agent. Nothing else resumes a team: a `team.configure`
arriving later does not (the front end always configures before its session
requests, 20.2); the person can still use `:Ade team on` (20.5 reload) or
`team.set_leader` (20.4). There is no resume candidate state.

### 20.8 Summary of method changes

| Method | Change |
|---|---|
| `team.configure` | gains `enabled`, `session_default`; `derived` ignored |
| `team.leader_server`, `team.bind_leader` | removed |
| `team.spawn`, `team.start` | `team` or `{instance, sessionId}`; result gains `team` |
| `team.set_leader` | new (20.4) |
| `team.stop_worker` | new (20.6) |
| `session.teams` | new (20.5); notification `session.teams_changed` |
| `team.answer` | handles `handover` items (20.4) |
| MCP | session role, `listChanged`, `team_stop` |
