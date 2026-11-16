# nvim_ade_server protocol (api_version 3, service 0.4.0)

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

`api_version` is `3`. `features` contains `"tunnel"`, `"install"` on unix
(section 16), and `"log"` when the event log is enabled (section 10). Errors are unchanged:
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

Each connection has an outbound queue capped at **64 MiB**. When it would be
exceeded the service closes that connection (the agent is unaffected and keeps
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
  deleted when the instance stops or exits, and the whole log file is deleted
  when the service starts (no instance survives a service restart, so a stale
  log would describe nothing). It is never read after that.
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
