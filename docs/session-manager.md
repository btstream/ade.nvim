# Session manager (all agents)

Status: approved design, 2026-11-26. Service contract: `service/PROTOCOL.md`
section 21 (api_version 8, service 0.9.0).

## Goal

One window that lists the stored sessions of **every configured agent**
(claude, opencode, pi, user-defined ones), across all project directories.
Loading a session from it also moves Neovim to that session's folder.

The existing `:Ade sessions` (current agent, current cwd, `<C-d>` delete) is
unchanged.

## Decisions (made by the user)

1. **Data source: the service lists and caches** (PROTOCOL 21). Opening the
   manager shows the cached catalog at once (`sessions.cached`) and refreshes
   in the background (`sessions.refresh`); rows of an agent are replaced as its
   `sessions.updated` notification arrives.
2. **Folder sync is a global `:cd`** to the session's `cwd` (not `:tcd`, not a
   new tabpage): the chat panel is a global singleton, so editor and panel must
   agree on one directory.
3. **Switching agent while work is pending asks first.** If the panel's
   current agent has a running turn or queued messages and loading the target
   needs a new connection, show a confirmation that says how many queued
   messages will be dropped and running turns interrupted. Without pending work
   switch directly.

## Front end

### Entry points

- `:Ade sessions all` (completion offers `all` after `sessions`).
- Lua: `require("ade").session_manager()`.
- Requires the service backend and `hello.features` containing `"sessions"`.
  Otherwise (direct backend, old service) notify once
  ("The session manager needs the ade service; showing this agent's sessions")
  and fall back to the existing `pick_session()`.

### Which agents are listed

Every key of `config.agents`, sorted. For each, resolve the launch exactly the
way the panel does before `agent.attach` (command, args, env, `launch` for
managed installs; see `lua/ade/manager/resolve.lua` and the service connection
code that builds `agent.attach` params). An agent whose launch is not available
(not installed, not executable) is not sent to the service; it is shown in the
status header as unavailable with the reason. `cwd` sent for each agent is the
resolved editor cwd (`runtime_ops:resolve_cwd()`).

The service connection used for these calls is the shared front-end service
connection (the same one `:Ade agents` / installs use, started on demand); the
manager must work even when the panel has never connected.

### Window

A floating window in the style of `lua/ade/ui/session_picker.lua`
(same highlight groups from `ade.ui.highlights.picker`, same filter keys).

```
╭──────────────────────────── Sessions (all agents) ────────────────────────────╮
│ claude ✓ 23   opencode ⟳   pi ✗ auth required   mycli – not installed         │
│───────────────────────────────────────────────────────────────────────────────│
│ ▸ claude    ~/src/ade.nvim       Fix the toolbar badge        2026-11-25 18:02 │
│   opencode  ~/src/ade.nvim       Session manager design       2026-11-25 17:40 │
│   pi        ~/work/api  (missing) Migrate auth                2026-11-20 09:13 │
│───────────────────────────────────────────────────────────────────────────────│
│ Type to filter   <CR> open  <C-r> refresh  <Tab> agent filter  q close        │
╰───────────────────────────────────────────────────────────────────────────────╯
```

- Header: one item per agent: `✓ <count>` listed, `⟳` refreshing,
  `✗ <error message, shortened>` failed (cached rows of that agent stay
  visible), `– not installed/unavailable`. Use icons from `ade.ui.icons`
  respecting `ui.icons`.
- Rows sorted by `updatedAt` descending (missing `updatedAt` last, then by
  agent, then title). Columns: agent, cwd shortened with `~` and truncated from
  the left to fit, title (fallback: sessionId), time (`YYYY-MM-DD HH:MM`, same
  formatter as the existing picker).
- The session the panel currently shows (same agent and same id) gets the
  current marker.
- A row whose `cwd` is not an existing directory is shown dimmed with
  `(missing)`; `<CR>` on it notifies and does nothing.
- Typing filters (fuzzy over agent, cwd and title); `<BS>`, `<C-u>` as in the
  existing picker. `<Tab>` cycles an agent filter (all → each agent → all),
  shown in the footer. `<C-r>` refreshes again. `q`/`<Esc>`/`<C-c>` close.
- Refresh results arriving after the window closed are ignored (no errors).
- No delete in this window (deleting another agent's session would need that
  agent connected); the footer does not advertise `<C-d>`.

### Loading a row

Given `{agent, sessionId, cwd}`:

1. `cwd` must be an existing directory, else notify and stop.
2. If `config.cwd` is pinned and differs from the session `cwd`: notify that the
   pinned `cwd` option prevents switching folders, and stop.
3. **Same agent and the panel's live connection already runs in `cwd`**: just
   `Sessions:load(sessionId)` (normal path; the catalog cwd must be used for the
   load, i.e. seed `catalog:cwds()[sessionId] = cwd` or pass `opts.cwd`).
4. **Otherwise a new connection is needed** (other agent, or same agent but the
   connection belongs to another cwd, or no connection):
   - Count pending work the same way `connection_flow:pending_work()` does. If
     anything is queued or running, ask (via the existing confirm/select
     presenter) "Switch to <agent> in <cwd>? This drops N queued message(s) and
     interrupts M running turn(s)." with Switch / Cancel. Cancel stops here.
   - `:cd` to `cwd` (escaped with `vim.fn.fnameescape`).
   - Reconfigure to the target agent the same way `pick_agent` does
     (`setup(opts, {discard_queued = true})`, `inline.stop()`), but with a
     **one-shot pending load** so that when the new connection is ready
     (`on_ready` in `lua/ade/app/bootstrap.lua`) it loads `sessionId` with
     `cwd` **instead of** auto-restoring another session or creating an empty
     one. No empty session may be created on the way.
   - Open the panel. On load failure the normal load error reporting applies
     and the user ends up with a fresh session in the new folder (existing
     behaviour of a failed load).
5. Close the manager window when the load starts.

### Notes

- Team state is not touched: teams belong to the service and keep running.
- `lua/ade/service/version.lua` `API_VERSION` becomes 8 (together with the
  service).
- Document `:Ade sessions all` in `README.md` and `doc/ade.txt`.

## Tests

- Service (Rust, `service/tests/`): cached/refresh happy path with a fake agent
  (temporary instance started, initialized, paged list, stopped afterwards),
  reuse of an initialized instance (no second `initialize`), capability
  missing (-32070), timeout (-32071), agent exit (-32072), error passthrough,
  joining concurrent refreshes, delete removes a row, schema 4 → 5 upgrade,
  temporary instance requests answered with -32601 and not counted as pending.
- Front end (Lua specs in `tests/`, fake service): cached rows shown before the
  refresh finishes; `sessions.updated` replaces one agent's rows; header states;
  filter and agent filter; fallback without the `"sessions"` feature; load
  paths 3 and 4 including the confirmation (cancel and accept), `:cd`, no empty
  session created, pinned `cwd` refusal, missing directory.
