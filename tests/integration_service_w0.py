#!/usr/bin/env python3
"""W0 end-to-end scenarios (real service + real Neovim + fake agents).

Run: python3 tests/integration_service_w0.py
     ADE_E2E_ONLY="1" python3 ...   # one scenario (substring match)
     ADE_E2E_KEEP=1 python3 ...     # keep temporary directories
"""
import json
import os
import sys
import traceback
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import integration_service_team as base  # noqa: E402


ROOT = base.ROOT
SERVICE = base.SERVICE
TEAM_AGENT = base.TEAM_AGENT
WAIT = base.WAIT
Failure = base.Failure
wait_until = base.wait_until


class W0Editor(base.Editor):
    def __init__(
        self,
        case,
        label,
        workflows=None,
        default_workflow=None,
        dashboard=None,
        service_env=None,
        **kwargs,
    ):
        super().__init__(case, label, **kwargs)
        self.workflows = workflows
        self.default_workflow = default_workflow
        self.dashboard = dashboard
        self.service_env = service_env or {}

    def configure(self):
        agent_env = {
            "TEAM_AGENT_LOG": str(self.case.agent_log),
            "TEAM_AGENT_GATE": str(self.case.gate),
            "TEAM_AGENT_TEMPLATE": "coder",
        }
        agent_env.update(self.agent_env)
        teams = {
            "max_workers": self.max_workers,
            "spawn_confirm": {"auto": list(self.spawn_confirm_auto)},
            "limits": {
                "max_turns_per_task": int(self.limits.get("max_turns_per_task", 30)),
                "max_turns_total": int(self.limits.get("max_turns_total", 200)),
            },
        }
        if self.templates:
            teams["templates"] = self.templates
        if self.teams_enabled is not None:
            teams["enabled"] = self.teams_enabled
            teams["session_default"] = self.teams_enabled
        if self.workflows:
            teams["workflows"] = self.workflows
        if self.default_workflow:
            teams["default"] = self.default_workflow
        if self.dashboard:
            teams["dashboard"] = self.dashboard
        opts = {
            "agent": "coder",
            "agents": {
                "coder": {
                    "command": "python3",
                    "args": [str(TEAM_AGENT)],
                    "env": agent_env,
                }
            },
            "teams": teams,
            "service": {
                "path": str(self.service_path),
                "keep_alive": self.keep_alive,
                "idle_timeout": self.idle_timeout,
                "event_log": True,
                "restore": self.restore,
            },
            "permissions": {"prompt": "native", "show_details": False},
            "ui": {},
            "log": {"level": "info"},
        }
        if self.backend is not None:
            opts["backend"] = self.backend
        self.lua(
            """
            local opts, env = ...
            _G.ade_e2e_notifications = {}
            vim.notify = function(message, level)
              _G.ade_e2e_notifications[#_G.ade_e2e_notifications + 1] = {
                message = tostring(message),
                level = level or vim.log.levels.INFO,
              }
            end
            for key, value in pairs(env) do vim.env[key] = value end
            require("ade").setup(opts)
            return true
            """,
            opts,
            self.service_env,
        )


class ErrorEditor(base.Editor):
    """An editor whose setup is expected to fail (old configuration keys)."""

    def __init__(self, case, label, old_config):
        super().__init__(case, label, templates=None)
        self.old_config = old_config
        self.setup_result = None

    def configure(self):
        self.setup_result = self.lua(
            """
            local opts = ...
            local ok, err = pcall(function() require("ade").setup(opts) end)
            return { ok = ok, err = tostring(err) }
            """,
            self.old_config,
        )


def spawn_group(editor):
    return editor.lua(
        """
        local st = require("ade.controller").state()
        local n, group = 0, nil
        for _, item in pairs(st.view.team.inbox) do
          if item.kind == "spawn" and item.state == "open" then
            n = n + 1
            group = group or item.group
          end
        end
        return { n = n, group = group }
        """
    )


def make_editor(case, label, **kwargs):
    editor = W0Editor(case, label, **kwargs)
    case.editors.append(editor)
    editor.start()
    return editor


def wide_editor(editor):
    editor.lua("vim.opt.columns = 170; return vim.o.columns")


def panel_state(editor):
    """The team panes as the current layout renders them.

    v3 keeps the tree, members and board as independent panes inside the current
    tabpage (no separate tabpage and no cooked tabline): each pane's buffer and
    winbar are read directly.
    """
    return editor.lua(
        """
        local st = require("ade.controller").state()
        local ui = st.view.team_ui
        if not ui then return { open = false } end
        local layout = ui.layout
        local function lines(name)
          local buf = layout and layout:buf(name)
          if buf then return vim.api.nvim_buf_get_lines(buf, 0, -1, false) end
          return nil
        end
        local function header(name)
          local win = layout and layout:win(name)
          if win then return vim.api.nvim_get_option_value("winbar", { win = win }) end
          return nil
        end
        local out = { open = ui:is_open() }
        out.members_open = layout and layout:is_open_pane("members") or false
        out.board_open = layout and layout:is_open_pane("board") or false
        out.tree_open = layout and layout:is_open_pane("tree") or false
        out.members = lines("members")
        out.board = lines("board")
        out.title = header("members") or header("board") or ""
        return out
        """
    )


def send_participant(editor, name, body, kind="task"):
    editor.lua(
        """
        local name, body, kind = ...
        local st = require("ade.controller").state()
        local team = st.view.team
        local entry = team:list_rows()[1]
        team:send(entry.id, name, kind, body, nil, function() end)
        return true
        """,
        name,
        body,
        kind,
    )


def cursor_id(editor, ident):
    ok = editor.lua(
        """
        local ident = ...
        local st = require("ade.controller").state()
        local ui = st.view.team_ui
        local layout = ui.layout
        local panel = "members"
        if ident:sub(1, 5) == "item:" then panel = "members"
        elseif ident:sub(1, 5) == "card:" or ident:sub(1, 6) == "stage:" then panel = "board" end
        local ids, win = layout.ids[panel], layout:win(panel)
        for line, id in pairs(ids or {}) do
          if id == ident then
            vim.api.nvim_set_current_win(win)
            vim.api.nvim_win_set_cursor(win, { line, 0 })
            return true
          end
        end
        -- A board row with several cards has no single id; locate the card id
        -- in the rendered line and put the cursor on its cell.
        if ident:sub(1, 5) == "card:" and win then
          local card = ident:sub(6)
          local buf = layout:buf("board")
          local lines = buf and vim.api.nvim_buf_get_lines(buf, 0, -1, false) or {}
          for index, line in ipairs(lines) do
            local col = line:find(card, 1, true)
            if col then
              vim.api.nvim_set_current_win(win)
              vim.api.nvim_win_set_cursor(win, { index, col - 1 })
              return true
            end
          end
        end
        return false
        """,
        ident,
    )
    if not ok:
        raise Failure(f"no panel row for {ident}: {panel_state(editor)}")


def board(editor):
    return editor.lua(
        """
        local st = require("ade.controller").state()
        local team = st.view.team
        local entry = team:list_rows()[1]
        return entry and team:board(entry.id) or nil
        """
    )


def leader_events(case, needle):
    leader = base.leader_pid(case)
    return [
        event
        for event in case.agent_events()
        if event.get("pid") == leader and needle in (event.get("text") or "")
    ]


def wait_leader_prompt(case, needle, label=None, timeout=WAIT):
    return wait_until(
        lambda: leader_events(case, needle) or None,
        label or f"the leader prompt containing {needle!r}",
        timeout,
    )


def scenario_workflow_start(case):
    """1. A named workflow starts two workers, shows the board and wide panel."""
    editor = make_editor(case, 
        "a",
        workflows={
            "dev": {
                "summary": "两个 worker 写代码",
                "text": "1. plan\\n2. implement",
                "team": [
                    {"name": "w1", "template": "coder", "task": "T1"},
                    {"name": "w2", "template": "coder", "task": "T2"},
                ],
                "columns": ["todo", "doing"],
            }
        },
        default_workflow="dev",
        templates=base.template(),
        max_workers=3,
    )
    wide_editor(editor)
    editor.queue_answer("the task from the person")
    editor.connect()
    editor.lua("vim.cmd('Ade team start dev')")
    editor.wait_participant("w1", lambda entry: entry["sessionId"] is not None, "w1 started")
    editor.wait_participant("w2", lambda entry: entry["sessionId"] is not None, "w2 started")
    wait_leader_prompt(case, "the task from the person", "the start notice with the task")
    wait_until(
        lambda: (board(editor) or {}).get("workflow_name") == "dev",
        "the board workflow",
    )
    got = board(editor)
    assert got["columns"] == ["todo", "doing"], got
    editor.open_panel("members")
    panel = wait_until(
        lambda: (lambda value: value if value.get("members_open") and any("w1" in line for line in value.get("members") or []) else None)(
            panel_state(editor)
        ),
        "the members pane with workers",
    )
    assert any("w2" in line for line in panel["members"]), panel["members"]
    editor.open_panel("board")
    board_panel = wait_until(
        lambda: (lambda value: value if value.get("board_open") and value.get("board") else None)(panel_state(editor)),
        "the board pane",
    )
    assert any("todo" in line or "doing" in line for line in board_panel["board"]), board_panel["board"]
    return "a named workflow started two workers, notified the leader with the task, and showed members and the board"


def scenario_board_cards(case):
    """2. Board cards, card_update merging, card messages and history."""
    editor = make_editor(case, 
        "a",
        templates=base.template(),
        spawn_confirm_auto=["coder"],
        service_env={"NVIM_ADE_SERVER_BOARD_FLUSH_MS": "200"},
        dashboard={"wide": 160},
    )
    wide_editor(editor)
    editor.connect()
    editor.submit("spawn-task:do work")
    editor.wait_participant("w1", lambda entry: entry["state"] == "idle", "w1 idle")
    editor.submit("[board-create]")
    wait_until(lambda: (board(editor) or {}).get("rev") == 1, "the leader board")
    editor.open_panel("board")
    send_participant(editor, "w1", 'do [card-update {"card":"T1","body":"progress","fields":{"tests":"ok"}}]')
    wait_until(
        lambda: any(
            card.get("id") == "T1" and card.get("body") == "progress"
            for card in (board(editor) or {}).get("cards", [])
        ),
        "the worker card update",
    )
    cursor_id(editor, "card:T1")
    editor.queue_answer("please look at T1")
    editor.panel_press("m")
    wait_leader_prompt(case, "[card T1", "the card summary in the leader prompt")
    editor.panel_press("H")
    wait_until(
        lambda: editor.lua(
            """
            for _, buf in ipairs(vim.api.nvim_list_bufs()) do
              if vim.bo[buf].filetype == "ade_team_history" then return true end
            end
            return false
            """
        ),
        "the card history window",
    )
    return "a leader board, a worker card_update and the card message/history worked"


def scenario_group_approve(case):
    """3. Two spawns in one turn form a group; `!` approves both through the UI."""
    editor = make_editor(case, "a", templates=base.template(), spawn_confirm_auto=[])
    editor.connect()
    editor.submit("[spawn-two]")
    wait_until(
        lambda: (lambda value: value if value and value.get("n", 0) >= 2 and value.get("group") else None)(spawn_group(editor)),
        "the spawn group",
    )
    editor.open_panel()
    editor.panel_press("!")
    wait_until(editor.choice_open, "the choice component")
    # Two spawn requests approved together: the card offers the group action.
    editor.choice_pick("allow")
    editor.wait_participant("w1", lambda entry: entry["sessionId"] is not None, "w1 after allow")
    editor.wait_participant("w2", lambda entry: entry["sessionId"] is not None, "w2 after allow")
    approvals = sum((event.get("text") or "").count("approved:") for event in case.agent_events())
    assert approvals >= 2, approvals
    return "the spawn group was approved together through the choice queue"


def scenario_activity(case):
    """4. A worker tool_call becomes the member activity."""
    editor = make_editor(case, "a", templates=base.template(), spawn_confirm_auto=["coder"])
    editor.connect()
    editor.submit("spawn-task:do [activity-tool]")
    editor.wait_participant("w1", lambda entry: entry["state"] == "idle", "w1 idle")
    editor.open_panel()
    editor.wait_panel(
        lambda value: any("↳" in line and "Run cargo test" in line for line in value.get("lines", [])),
        "the member activity line",
    )
    return "the worker tool_call appeared as the member activity"


def scenario_watch_leader(case):
    """5. Worker watch, switch, then the leader chat/input in the right column."""
    editor = make_editor(case, 
        "a",
        templates=base.template(),
        spawn_confirm_auto=["coder"],
        dashboard={"wide": 160},
    )
    wide_editor(editor)
    editor.connect()
    editor.submit("spawn-task:do [activity-tool]")
    editor.submit("spawn-task:do idle")
    editor.wait_participant("w1", lambda entry: entry["state"] == "idle", "w1 idle")
    editor.wait_participant("w2", lambda entry: entry["state"] == "idle", "w2 idle")
    editor.lua("require('ade.controller').open(); return true")
    wait_until(
        lambda: editor.lua("local w=require('ade.controller').state().view.chat.win; return w ~= nil and vim.api.nvim_win_is_valid(w)"),
        "the original chat window",
    )
    editor.open_panel("members")
    cursor_id(editor, "t1|w1")
    editor.panel_press("<CR>")
    # v3 shows a worker's transcript in the ordinary chat/composer pair; the
    # watch state carries the replayed tool card.
    wait_until(
        lambda: base.normalize(editor.lua(
            "return require('ade.controller').state().view.team.watching and require('ade.controller').state().view.team.watching.participant"
        )) == "w1",
        "the w1 watch",
    )
    # The watched worker's transcript (replay included) lives on
    # `team.watching.session`; the ordinary chat shows it.
    wait_until(
        lambda: editor.lua(
            """
            local st = require("ade.controller").state()
            local watch = st.view.team.watching
            local session = watch and watch.session
            if not session then return false end
            for _, block in ipairs(session.blocks or {}) do
              if block.kind == "tool" and tostring(block.title or ""):find("Run cargo test", 1, true) then
                return true
              end
            end
            return false
            """
        ),
        "the replay to include the tool card",
    )
    cursor_id(editor, "t1|w2")
    editor.panel_press("<CR>")
    wait_until(
        lambda: base.normalize(editor.lua("return require('ade.controller').state().view.team.watching and require('ade.controller').state().view.team.watching.participant")) == "w2",
        "the switched watch",
    )
    cursor_id(editor, "t1|leader")
    editor.panel_press("<CR>")
    got = wait_until(
        lambda: editor.lua(
            """
            local st = require("ade.controller").state()
            local chat, input = st.view.chat, st.view.input
            if not chat.win or not input.win then return nil end
            if vim.api.nvim_win_get_buf(chat.win) ~= chat.buf then return nil end
            if vim.api.nvim_win_get_buf(input.win) ~= input.buf then return nil end
            local watching = st.view.team.watching
            if watching then return nil end
            return { chat = chat.win, input = input.win, tab = vim.api.nvim_get_current_tabpage() }
            """
        ),
        "the leader chat back in the ordinary panel",
    )
    editor.lua(
        """
        local st = require("ade.controller").state()
        local input = st.view.input
        vim.api.nvim_set_current_win(input.win)
        vim.api.nvim_buf_set_lines(input.buf, 0, -1, false, { "hello leader" })
        vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<C-s>", true, false, true), "x", false)
        return true
        """
    )
    wait_leader_prompt(case, "hello leader", "the prompt typed into the leader input")
    editor.panel_press("q")
    wait_until(
        lambda: editor.lua(
            """
            local st = require("ade.controller").state()
            local chat, input = st.view.chat, st.view.input
            if not chat.win or not vim.api.nvim_win_is_valid(chat.win) then return false end
            if not input.win or not vim.api.nvim_win_is_valid(input.win) then return false end
            if vim.api.nvim_win_get_buf(chat.win) ~= chat.buf then return false end
            if vim.api.nvim_win_get_buf(input.win) ~= input.buf then return false end
            return true
            """
        ),
        "the chat restored",
    )
    return "the right watch column switched workers and the leader chat/input moved there and back"


def scenario_workflow_save(case):
    """6. workflow_save is listed and d deletes it after confirmation."""
    editor = make_editor(case, "a", templates=base.template(), spawn_confirm_auto=["coder"])
    editor.connect()
    editor.submit("spawn-task:idle")
    editor.submit("[workflow-save]")
    wait_until(
        lambda: any(
            event.get("event") == "workflow-save-response"
            and not (event.get("response") or {}).get("isError")
            for event in case.agent_events()
        ),
        "the saved workflow",
    )
    editor.lua("vim.cmd('Ade workflows')")
    wait_until(
        lambda: (lambda text: text if text and "review_by_pi" in text else None)(
            editor.lua(
                """
                local ui = require("ade.controller").state().view.team_commands.workflows_ui
                if not ui or not ui.buf or not vim.api.nvim_buf_is_valid(ui.buf) then return nil end
                return table.concat(vim.api.nvim_buf_get_lines(ui.buf, 0, -1, false), "\\n")
                """
            )
        ),
        "the workflows window",
    )
    editor.queue_answer("Yes")
    editor.lua(
        """
        local ui = require("ade.controller").state().view.team_commands.workflows_ui
        vim.api.nvim_set_current_win(ui.win)
        for line, text in ipairs(vim.api.nvim_buf_get_lines(ui.buf, 0, -1, false)) do
          if text:find("review_by_pi", 1, true) then
            vim.api.nvim_win_set_cursor(ui.win, { line, 0 })
            break
          end
        end
        vim.api.nvim_feedkeys("d", "x", false)
        return true
        """
    )
    wait_until(
        lambda: editor.lua(
            """
            local ui = require("ade.controller").state().view.team_commands.workflows_ui
            if not ui or not ui.buf or not vim.api.nvim_buf_is_valid(ui.buf) then return true end
            local text = table.concat(vim.api.nvim_buf_get_lines(ui.buf, 0, -1, false), "\\n")
            return not text:find("review_by_pi", 1, true)
            """
        ),
        "the deleted workflow",
    )
    return "workflow_save listed the workflow and d deleted it"


def scenario_old_config(case):
    """7. The old teams.definitions key fails setup with the new form suggested."""
    editor = make_editor(case, "a")
    result = editor.lua(
        """
        local opts = ...
        local ok, err = pcall(function() require("ade").setup(opts) end)
        return { ok = ok, err = tostring(err) }
        """,
        {
            "backend": "service",
            "agent": "coder",
            "agents": {"coder": {"command": "python3", "args": [str(TEAM_AGENT)]}},
            "teams": {"definitions": {"dev": {"team": {}}}},
        },
    )
    assert result and result.get("ok") is False, result
    assert "teams.workflows" in result.get("err", ""), result
    return "the old teams.definitions configuration was rejected with the new form in the message"


SCENARIOS = [
    ("1-workflow-start", scenario_workflow_start),
    ("2-board-cards", scenario_board_cards),
    ("3-group-approve", scenario_group_approve),
    ("4-activity", scenario_activity),
    ("5-watch-leader", scenario_watch_leader),
    ("6-workflow-save", scenario_workflow_save),
    ("7-old-config", scenario_old_config),
]


def main():
    only = os.environ.get("ADE_E2E_ONLY", "")
    failures = []
    for label, fn in SCENARIOS:
        if only and only not in label:
            continue
        case = base.Case(label)
        try:
            result = fn(case)
            print(f"ok: {label}: {result}")
        except Exception:
            failures.append(label)
            traceback.print_exc()
            print(case.report())
        finally:
            case.cleanup()
    if failures:
        print(f"\n{len(failures)} failure(s): {', '.join(failures)}")
        return 1
    print(f"\nall {len([name for name, _ in SCENARIOS if not only or only in name])} scenarios passed")
    return 0


if __name__ == "__main__":
    sys.exit(main())
