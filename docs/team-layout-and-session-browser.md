# Team pane layout and unified session browser

Status: approved direction, 2026-11-27. Three independent work items:

- **A** team pane layout configuration (Lua only)
- **B** `sessions.delete` service method (Rust + PROTOCOL, api_version 9)
- **C** one session browser for `:Ade sessions` and `:Ade sessions all`
  (Lua; uses B for deleting sessions of agents the panel is not connected to)

A and B can start in parallel. C can start in parallel and stub the B call
behind `ServiceSessions.delete` until B lands.

---

## A. Team pane layout

### Today

`lua/ade/ui/team/layout_pane.lua` hard-codes placement: when
`vim.o.columns >= teams.dashboard.wide` every pane is a `botright vsplit` from
the widest window (tree/members pinned at `members_width`, board fills the
rest); otherwise all requested panes become stacked centred floats. The panes
already have their own filetypes: `ade_team_tree`, `ade_team_members`,
`ade_team_board`. The detail float (`ade_team_detail`) and the interrupt hint
stay floats and are out of scope.

### Configuration

```lua
teams = {
  layout = {
    -- inherit: follow `layout.backend` (native | external)
    backend = "inherit",          -- inherit | native | external
    -- native only: below this editor width every pane is a float
    float_below = 160,
    -- native only: same-side panes share one column/row (A2); off = old layout
    stack = false,
    panes = {
      tree    = { position = "right", size = 32 },
      members = { position = "right", size = 32 },
      board   = { position = "right" },  -- no size: take the free space
    },
  },
}
```

- `position`: `left | right | top | bottom | float`. `size`: columns for
  left/right, lines for top/bottom; `0 < size <= 1` is a fraction of the editor
  (same rule as `layout.width`). Clamped to the current limits (16..120 cols).
- Defaults reproduce today's behaviour exactly.
- Aliases: `teams.dashboard.wide` -> `teams.layout.float_below`,
  `teams.dashboard.members_width` -> `panes.members.size` and `panes.tree.size`,
  applied in config normalisation only when the new key is not set. Keep the
  old keys documented as deprecated; no warning in this release.
- Validation in `config.lua` like the existing `layout.*` checks.

### A1. External backend (first)

When the effective backend is `external`:

- `create_split` creates a plain split by position (`botright vsplit`,
  `topleft vsplit`, `botright split`, `topleft split`) and does **nothing
  else**: no width/height, no `winfixwidth`, no `pinned_widths` /
  `restore_pinned`, no `adopted_width`, no `WinResized` width adoption.
- No float fallback for narrow editors (the layout manager decides); only an
  explicit `position = "float"` makes a float.
- `ade.integrations.edgy`:
  - `views(opts)` additionally returns `tree`, `members`, `board` view specs
    (`ft`, `title`, `size` from the defaults) when `opts.team ~= false`.
  - `extend(edgy_opts, { team = { tree = "left", members = "left", board = "bottom" } })`
    inserts the team views into those edgy positions (array entries, skipping
    fts already present). `team = false` skips them. Default: team views go to
    the same position as the chat panel.
  - `check_registered()` gains a team variant called the first time a team
    pane opens in external mode, warning once about missing team fts.
- Window ids: edgy moves windows without recreating them, so `self.windows`
  stays valid; the existing `WinClosed` handler covers edgy closing a pane.
- Lock guard: register team pane windows with `ade.layout` (generalise
  `state.views` / `is_panel_buffer` to include the team fts) so `:split` from a
  team pane gets a scratch buffer and `winfixbuf` applies, as for chat/input.

### A2. Native per-pane position (second)

- `split_base` / `create_split` take the pane's position. Left/right keep the
  current column logic (release pins of team panes, split, restore). Top/bottom
  do the same with heights (`winfixheight`, a `pinned_heights` twin).
- Stacking is **opt-in**: `teams.layout.stack = false` (default) keeps the old
  behaviour, every pane opens its own column (left/right) or row (top/bottom)
  and a pane without `size` fills the free space. With `stack = true`, panes
  on the same side share one column/row in `PANES` order (tree, members,
  board) whatever order they are opened in: a new pane is inserted before its
  next open successor or after its previous open predecessor
  (`aboveleft`/`belowright split` for left/right, `aboveleft`/`belowright
  vsplit` for top/bottom).
- `float_below` keeps its meaning; `position = "float"` always floats.
- Board rendering already adapts to width; check `board.lua` column layout at
  bottom positions with small heights.

### Tests

Extend `tests/spec_w0e_team.lua` / `spec_s4_team.lua` (positions, sizes,
aliases, float fallback, external = no resizing), `tests/spec_edgy_views.lua`
(team views, extend with `team`), `tests/integration_edgy.lua` (team panes under
edgy), config validation specs.

---

## B. `sessions.delete` (PROTOCOL 21.8, api_version 9)

The wire contract is `service/PROTOCOL.md` 21.8; this section is a summary.

### Contract

```
-> {agent: {agent, command, args, cwd, env?, launch?},   // same item as sessions.refresh
    sessionId: string,
    timeout_ms: integer?}                                // default 30000, clamped [1000, 120000]
<- {}                                                    // success
```

1. **In use.** If any running instance tracks `sessionId` for that agent
   (section 11), fail with `-32074` "session is in use". The panel's own
   session is deleted through the tunnel (front end path), never here.
2. **Reuse / temporary instance / initialize**: exactly as 21.3 steps 1-2.
3. **Capability.** No `agentCapabilities.sessionCapabilities.delete` ->
   `-32073`.
4. Send a service-originated `session/delete {sessionId}`; an error response
   fails with that error's code and message. Timeout `-32071`, exit `-32072`,
   spawn failure `-32022` (same as 21.3).
5. **Result.** Remove the catalog row `(agent, sessionId)` explicitly (do not
   rely on relay tracking of service-originated traffic) and stop a temporary
   instance.
6. **Joining.** A second delete of the same `(agent, sessionId)` while one is
   running waits for it and gets the same answer.
7. **Racing a refresh.** A row deleted while a refresh of the same agent is
   running must not come back: keep a per-agent tombstone set for the duration
   of that refresh and drop those ids from its result.

`sessions.refresh` additionally records `agent_state.can_delete: boolean`
(from the initialize result) on success; `sessions.cached` returns it.

Busy for idle exit while running. Version: `api_version` 9 in
`service/src/lib.rs` and `lua/ade/service/version.lua`, service `0.10.0`,
`hello.features` gains `"sessions.delete"`.

### Tests

`service/tests/sessions.rs` with the fixture agent: reuse path, temporary
path, missing capability, in use, agent error, timeout, join, refresh race,
`can_delete` in cached state.

---

## C. One session browser

### Behaviour

One window, three scopes, cycled with `<Tab>`:

| scope | rows | source |
|---|---|---|
| `here` | current agent, current cwd | live `session/list` on the panel client (works on the direct backend) |
| `agent` | current agent, all directories | service catalog filtered by agent |
| `all` | every configured agent | service catalog (cached, then refreshed) |

- `:Ade sessions` opens at `here`, `:Ade sessions all` at `all`.
- Without the service (direct backend, old service) only `here` exists;
  `<Tab>` says why once. Without a connected panel `here` is skipped.
- In `all`, `<S-Tab>` cycles the agent filter (today's manager `<Tab>`).
- Keys: `<CR>` open, `<C-d>` delete (confirm), `<C-r>` refresh, typing filters.

### Actions

- **Open**: live rows -> `Sessions:load`; catalog rows -> `Manager:load`
  (global `:cd`, agent switch with confirmation; unchanged).
- **Delete**: row agent == panel agent and panel connected -> `Sessions:delete`
  (local cleanup, new session if it was the current one; the relay already
  drops the catalog row). Otherwise -> `sessions.delete` with the resolved
  launch, then `last_sessions.forget_session(agent, id)`. `-32074` is shown as
  "open in another window/agent instance".
- **can_delete**: panel agent -> client capability; others ->
  `agent_state.can_delete` (unknown: allow, the service answers `-32073`).

### Structure

```
lua/ade/ui/session_browser/
  model.lua     rows, sorting, fuzzy filter, labels, truncation, scopes
  internal.lua  the float (from ui/session_manager.lua, which is the superset)
  snacks.lua    snacks backend (from ui/session_snacks.lua): live row updates
                via picker refresh, agent/cwd columns, scope/agent/refresh/delete actions
lua/ade/app/session_browser.lua   controller: sources, scope switching, actions
```

- The app side merges `Sessions:pick` and `app/session_manager.lua` behind a
  source interface `{ list, refresh?, open, delete, can_delete }`; the manager
  keeps its service/round/listener logic as the catalog source.
- `ui.session_picker = "snacks" | "internal"` now applies to both commands.
- Remove `ui/session_picker.lua`, `ui/session_snacks.lua`,
  `ui/session_manager.lua` once callers moved; `presenter.open_session_browser`
  stays as the facade.

### Tests

Port `spec_sessions.lua`, `spec_sessions_snacks.lua`, `spec_session_manager.lua`,
`spec_pickers.lua` to the new modules; add scope switching, direct-backend
fallback, delete routing (panel vs service), `-32073`/`-32074` messages.

---

## Docs

README / `doc/ade.txt`: `teams.layout`, edgy team views, session browser scopes
and keys, deprecated `teams.dashboard.wide/members_width`.
