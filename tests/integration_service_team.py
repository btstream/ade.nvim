#!/usr/bin/env python3
"""Team end-to-end scenarios: real service binary + real Lua plugin + Neovim.

Every scenario runs in its own temporary tree with its own service directory and
headless Neovims driven over pynvim. The agents are
`service/tests/fixtures/team_agent.py`: the leader really starts
`nvim_ade_server mcp` from the `ade-team` server entry in `session/new` and
calls the team tools; workers are started by the service from a template.

Run: python3 tests/integration_service_team.py
     ADE_E2E_ONLY="3" python3 ...   # one scenario (substring match)
     ADE_E2E_KEEP=1 python3 ...    # keep temporary directories
"""

import json
import logging
import os
import shutil
import signal
import subprocess
import sys
import tempfile
import time
import traceback
from pathlib import Path

import pynvim

# pynvim logs a warning when a deliberately closed editor connection ends; the
# scenario result must be byte-identical across runs.
logging.getLogger("pynvim").setLevel(logging.ERROR)

ROOT = Path(__file__).resolve().parent.parent
SERVICE = ROOT / "service" / "target" / "release" / "nvim_ade_server"
TEAM_AGENT = ROOT / "service" / "tests" / "fixtures" / "team_agent.py"
WAIT = 30.0

failures = []
active_cases = []
_our_handlers = {}


class Failure(AssertionError):
    pass


def wait_until(check, label, timeout=WAIT, interval=0.05):
    deadline = time.monotonic() + timeout
    last = None
    while time.monotonic() < deadline:
        try:
            value = check()
        except Exception as exc:  # a transient pynvim error is retried
            last = exc
            value = None
        if value:
            return value
        last = None
        time.sleep(interval)
    raise Failure(f"timed out after {timeout:g}s waiting for {label}" + (f" ({last})" if last else ""))


def normalize(value):
    return json.loads(json.dumps(value, default=str))


def _proc_env(pid):
    try:
        return Path(f"/proc/{pid}/environ").read_bytes()
    except OSError:
        return b""


def _proc_cmdline(pid):
    try:
        return Path(f"/proc/{pid}/cmdline").read_bytes().replace(b"\0", b" ").decode("utf-8", "replace")
    except OSError:
        return ""


def _all_pids():
    for entry in Path("/proc").iterdir():
        if entry.name.isdigit():
            yield int(entry.name)


def _cleanup_active_cases():
    ignored = (signal.SIGINT, signal.SIGTERM, signal.SIGHUP)
    previous = {signum: signal.getsignal(signum) for signum in ignored}
    for signum in ignored:
        try:
            signal.signal(signum, signal.SIG_IGN)
        except (ValueError, OSError):
            pass
    try:
        while active_cases:
            case = active_cases.pop()
            try:
                case.cleanup()
                shutil.rmtree(case.dir, ignore_errors=True)
            except Exception:  # noqa: BLE001 - cleanup must not mask the real error
                pass
    finally:
        for signum, handler in previous.items():
            try:
                signal.signal(signum, handler)
            except (ValueError, OSError):
                pass


def _install_signal_handlers():
    def handler(signum, _frame):
        print(f"\ninterrupted by signal {signum}: cleaning up", flush=True)
        _cleanup_active_cases()
        signal.signal(signum, signal.SIG_DFL)
        os.kill(os.getpid(), signum)

    for signum in (signal.SIGINT, signal.SIGTERM, signal.SIGHUP):
        try:
            signal.signal(signum, handler)
            _our_handlers[signum] = handler
        except (ValueError, OSError):
            pass


def ensure_signal_handlers():
    for signum, handler in _our_handlers.items():
        try:
            if signal.getsignal(signum) is not handler:
                signal.signal(signum, handler)
        except (ValueError, OSError):
            pass


def isolated_env(case, label):
    base = case.dir / "env" / label
    env = dict(os.environ)
    env.update(
        {
            "HOME": str(base / "home"),
            "XDG_DATA_HOME": str(base / "xdg_data"),
            "XDG_STATE_HOME": str(base / "xdg_state"),
            "XDG_CACHE_HOME": str(base / "xdg_cache"),
            "NVIM_ADE_SERVER_DIR": str(case.service_dir),
        }
    )
    for key in ("XDG_DATA_HOME", "XDG_STATE_HOME", "XDG_CACHE_HOME", "HOME"):
        os.makedirs(env[key], exist_ok=True)
    return env


class Case:
    def __init__(self, label):
        self.label = label
        self.dir = Path(tempfile.mkdtemp(prefix=f"ade-team-e2e-{label}-"))
        self.service_dir = self.dir / "service"
        os.makedirs(self.service_dir, exist_ok=True)
        self.work = self.dir / "work"
        os.makedirs(self.work, exist_ok=True)
        self.agent_log = self.dir / "team-agent.log"
        self.gate = self.dir / "team-agent.gate"
        self.editors = []
        self.init = self.dir / "init.lua"
        self.init.write_text(
            "vim.opt.runtimepath:append(%r)\n"
            "vim.opt.swapfile = false\n"
            "vim.opt.shadafile = 'NONE'\n"
            "vim.opt.laststatus = 3\n"
            "vim.opt.columns = 140\n"
            "vim.opt.lines = 50\n"
            # The panel asks through vim.ui.select/input; queue answers here.
            "_G.ade_e2e_answers = {}\n"
            "vim.ui.select = function(items, opts, on_choice)\n"
            "  local wanted = table.remove(_G.ade_e2e_answers, 1)\n"
            "  local picked = nil\n"
            "  for _, item in ipairs(items) do\n"
            "    local label = type(item) == 'table' and (item.label or item.name) or tostring(item)\n"
            "    if wanted == nil then picked = item break end\n"
            "    if label == wanted or tostring(label):lower():find(tostring(wanted):lower(), 1, true) then\n"
            "      picked = item\n"
            "      break\n"
            "    end\n"
            "  end\n"
            "  vim.schedule(function() on_choice(picked) end)\n"
            "end\n"
            "vim.ui.input = function(opts, on_confirm)\n"
            "  local text = table.remove(_G.ade_e2e_answers, 1)\n"
            "  vim.schedule(function() on_confirm(text) end)\n"
            "end\n" % str(ROOT)
        )

    # -- agent log ----------------------------------------------------------
    def agent_events(self):
        events = []
        try:
            text = self.agent_log.read_text(encoding="utf-8", errors="replace")
        except OSError:
            return events
        for line in text.splitlines():
            try:
                events.append(json.loads(line))
            except ValueError:
                continue  # a line being appended right now
        return events

    def wait_agent_event(self, predicate, label, timeout=WAIT):
        return wait_until(
            lambda: self.agent_events() if predicate(self.agent_events()) else None,
            label,
            timeout,
        )

    def wait_agent_prompt(self, needle, label=None, timeout=WAIT):
        def match(event):
            return event.get("event") == "prompt" and needle in (event.get("text") or "")

        return next(
            event
            for event in self.wait_agent_event(
                lambda events: any(match(event) for event in events),
                label or f"agent prompt containing {needle!r}",
                timeout,
            )
            if match(event)
        )

    def wait_worker_prompt(self, needle, label=None, timeout=WAIT):
        """The worker's prompt; the leader's spawn prompt carries the task too."""
        owner = leader_pid(self)

        def match(event):
            return (
                event.get("event") == "prompt"
                and needle in (event.get("text") or "")
                and event.get("pid") != owner
            )

        return next(
            event
            for event in self.wait_agent_event(
                lambda events: any(match(event) for event in events),
                label or f"a worker prompt containing {needle!r}",
                timeout,
            )
            if match(event)
        )

    def agent_log_tail(self, lines=40):
        try:
            text = self.agent_log.read_text(encoding="utf-8", errors="replace")
        except OSError:
            return "<no agent log>"
        return "\n".join(text.splitlines()[-lines:])

    # -- editors and cleanup ------------------------------------------------
    def editor(self, label, **kwargs):
        editor = Editor(self, label, **kwargs)
        self.editors.append(editor)
        editor.start()
        return editor

    def service_pids(self):
        pids = []
        wanted = f"NVIM_ADE_SERVER_DIR={self.service_dir}".encode()
        for pid in _all_pids():
            cmdline = _proc_cmdline(pid)
            if _proc_env(pid).split(b"\0").count(wanted) and "nvim_ade_server" in cmdline:
                pids.append(pid)
        return pids

    def stop(self):
        """Kill the editors, the service and the agents; keep the logs."""
        for editor in self.editors:
            editor.kill()
        for pid in self.service_pids():
            try:
                os.kill(pid, signal.SIGKILL)
            except OSError:
                pass
        for pid in _all_pids():
            env = _proc_env(pid)
            if str(self.dir).encode() not in env:
                continue
            cmdline = _proc_cmdline(pid)
            if "team_agent.py" in cmdline or "nvim_ade_server" in cmdline:
                try:
                    os.kill(pid, signal.SIGKILL)
                except OSError:
                    pass

    def cleanup(self):
        self.stop()
        if os.environ.get("ADE_E2E_KEEP") != "1":
            shutil.rmtree(self.dir, ignore_errors=True)

    def leftover_processes(self):
        out = []
        for pid in _all_pids():
            env = _proc_env(pid)
            if str(self.dir).encode() not in env:
                continue
            cmdline = _proc_cmdline(pid)
            if "team_agent.py" in cmdline or "nvim_ade_server" in cmdline:
                out.append((pid, cmdline))
        return out

    def report(self):
        parts = [f"=== {self.label} ===", f"case dir: {self.dir}"]
        for editor in self.editors:
            parts.append(editor.diagnostic())
        parts.append("--- agent log ---")
        parts.append(self.agent_log_tail())
        parts.append("--- service pids ---")
        parts.append(repr(self.service_pids()))
        return "\n".join(parts)


class Editor:
    def __init__(
        self,
        case,
        label,
        templates=None,
        spawn_confirm_auto=None,
        limits=None,
        max_workers=3,
        restore=True,
        spawn_from_chat=None,
        idle_timeout=120,
        keep_alive=True,
        backend="service",
        service_path=None,
        agent_env=None,
    ):
        self.case = case
        self.label = label
        self.templates = templates
        self.spawn_confirm_auto = spawn_confirm_auto or []
        self.limits = limits or {}
        self.max_workers = max_workers
        self.restore = restore
        self.spawn_from_chat = spawn_from_chat
        self.idle_timeout = idle_timeout
        self.keep_alive = keep_alive
        self.backend = backend
        self.service_path = service_path or SERVICE
        self.agent_env = agent_env or {}
        self.socket = case.dir / f"{label}.sock"
        self.log = case.dir / f"{label}.nvim.log"
        self.proc = None
        self.nvim = None

    def start(self):
        env = isolated_env(self.case, self.label)
        self._log = open(self.log, "wb")
        self.proc = subprocess.Popen(
            ["nvim", "--headless", "--listen", str(self.socket), "-u", str(self.case.init)],
            cwd=str(self.case.work),
            env=env,
            stdin=subprocess.DEVNULL,
            stdout=self._log,
            stderr=subprocess.STDOUT,
        )
        wait_until(lambda: self.socket.exists(), f"{self.label} socket")
        self.nvim = wait_until(self._attach, f"{self.label} to accept a connection")
        self.configure()

    def _attach(self):
        try:
            return pynvim.attach("socket", path=str(self.socket))
        except (OSError, ConnectionError):
            return None

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
        if self.spawn_from_chat is not None:
            teams["spawn_from_chat"] = self.spawn_from_chat
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
            local opts = ...
            _G.ade_e2e_notifications = {}
            vim.notify = function(message, level)
              _G.ade_e2e_notifications[#_G.ade_e2e_notifications + 1] = {
                message = tostring(message),
                level = level or vim.log.levels.INFO,
              }
            end
            require("ade").setup(opts)
            return true
            """,
            opts,
        )

    # -- Lua plumbing -------------------------------------------------------
    def lua(self, code, *args):
        try:
            return self.nvim.exec_lua(code, *args)
        finally:
            ensure_signal_handlers()

    def notifications(self):
        raw = self.lua(
            """
            local out = {}
            for _, entry in ipairs(_G.ade_e2e_notifications or {}) do
              out[#out + 1] = { message = entry.message, level = entry.level }
            end
            return out
            """
        )
        return normalize(raw or [])

    def notification_lines(self):
        return [entry["message"] for entry in self.notifications()]

    def clear_notifications(self):
        self.lua("_G.ade_e2e_notifications = {}; return true")

    def wait_notification(self, needle, label=None, timeout=WAIT):
        def check():
            for line in self.notification_lines():
                if needle in line:
                    return line
            return None

        return wait_until(check, label or f"{self.label} notification {needle!r}", timeout)

    def queue_answer(self, *answers):
        self.lua(
            """
            local answers = { ... }
            for i = #answers, 1, -1 do
              table.insert(_G.ade_e2e_answers, 1, answers[i])
            end
            return true
            """,
            *answers,
        )

    # -- session ------------------------------------------------------------
    def connect(self):
        self.lua("require('ade.controller').connect(); return true")
        self.wait_state(
            lambda st: st.get("phase") == "ready" and (st.get("session") or {}).get("id"),
            "agent ready",
        )

    def state(self):
        raw = self.lua(
            """
            local st = require("ade.controller").state()
            return {
              phase = st.conn.phase,
              session = st.session and { id = st.session.id, status = st.session.status } or nil,
              backend_service = st.conn.service and st.conn.service.backend_service == true or false,
            }
            """
        )
        return normalize(raw)

    def wait_state(self, predicate, label="state", timeout=WAIT):
        return wait_until(
            lambda: (lambda st: st if predicate(st) else None)(self.state()),
            f"{self.label} {label}",
            timeout,
        )

    def session_id(self):
        return (self.state().get("session") or {}).get("id")

    def submit(self, text):
        self.lua("require('ade.controller').submit(...); return true", text)

    def transcript(self):
        raw = self.lua(
            """
            local out = {}
            local st = require("ade.controller").state()
            if st.session then
              for _, block in ipairs(st.session.blocks or {}) do
                out[#out + 1] = {
                  kind = block.kind,
                  text = block.text or "",
                  origin = block.bus and block.bus.origin or nil,
                }
              end
            end
            return out
            """
        )
        return normalize(raw or [])

    def wait_transcript(self, predicate, label, timeout=WAIT):
        return wait_until(
            lambda: self.transcript() if predicate(self.transcript()) else None,
            f"{self.label} {label}",
            timeout,
        )

    def wait_bus_text(self, needle, label=None, timeout=WAIT):
        def check():
            for block in self.transcript():
                if block.get("kind") == "user" and needle in (block.get("text") or ""):
                    return block
            return None

        return wait_until(check, label or f"{self.label} bus turn containing {needle!r}", timeout)

    def wait_turn_idle(self, timeout=WAIT):
        return self.wait_state(
            lambda st: (st.get("session") or {}).get("status") == "idle",
            "turn to finish",
            timeout,
        )

    # -- teams (real plugin state) -----------------------------------------
    def teams(self):
        raw = self.lua(
            """
            local st = require("ade.controller").state()
            local team = st.view.team
            local out = { teams = {}, inbox = {}, bound = {} }
            for id, value in pairs(team and team.teams or {}) do
              out.teams[id] = vim.deepcopy(value)
            end
            for id, value in pairs(team and team.inbox or {}) do
              out.inbox[id] = vim.deepcopy(value)
            end
            for cwd, value in pairs(team and team.bound or {}) do
              out.bound[cwd] = vim.deepcopy(value)
            end
            return out
            """
        )
        return normalize(raw or {"teams": {}, "inbox": {}, "bound": {}})

    def wait_team(self, predicate, label, timeout=WAIT):
        return wait_until(
            lambda: (lambda teams: teams if predicate(teams) else None)(self.teams()),
            f"{self.label} {label}",
            timeout,
        )

    def first_team(self, timeout=WAIT):
        teams = self.wait_team(lambda value: value["teams"], "a team")
        team_id = sorted(teams["teams"])[0]
        return team_id, teams["teams"][team_id]

    def participant(self, name, team_id=None, timeout=WAIT):
        def check():
            teams = self.teams()["teams"]
            ids = [team_id] if team_id else sorted(teams)
            for ident in ids:
                for entry in teams.get(ident, {}).get("participants") or []:
                    if entry.get("name") == name:
                        return entry
            return None

        return wait_until(check, f"{self.label} participant {name}", timeout)

    def wait_participant(self, name, predicate, label=None, timeout=WAIT, team_id=None):
        def check():
            teams = self.teams()["teams"]
            ids = [team_id] if team_id else sorted(teams)
            for ident in ids:
                for entry in teams.get(ident, {}).get("participants") or []:
                    if entry.get("name") == name and predicate(entry):
                        return entry
            return None

        return wait_until(check, f"{self.label} participant {name} {label or ''}".strip(), timeout)

    def wait_item(self, kind, predicate=lambda item: True, timeout=WAIT):
        def check():
            for item in self.teams()["inbox"].values():
                if item.get("kind") == kind and item.get("state") == "open" and predicate(item):
                    return item
            return None

        return wait_until(check, f"{self.label} {kind} inbox item", timeout)

    # -- panel --------------------------------------------------------------
    def open_panel(self, timeout=WAIT):
        def check():
            return self.lua("return require('ade').open_team() == true")

        try:
            return wait_until(check, f"{self.label} team panel")
        except Failure:
            raise Failure(f"{self.label}: :Ade team did not open with a team present")

    def panel(self):
        raw = self.lua(
            """
            local st = require("ade.controller").state()
            local ui = st.view.team_ui
            if not ui then return { open = false, lines = {}, watch = {}, watch_open = false } end
            local open = ui:is_open()
            local lines = {}
            if open and ui.buf and vim.api.nvim_buf_is_valid(ui.buf) then
              lines = vim.api.nvim_buf_get_lines(ui.buf, 0, -1, false)
            end
            local watch = {}
            local watch_open = ui.watch_buf ~= nil and vim.api.nvim_buf_is_valid(ui.watch_buf)
            if watch_open then
              watch = vim.api.nvim_buf_get_lines(ui.watch_buf, 0, -1, false)
            end
            return { open = open, lines = lines, watch = watch, watch_open = watch_open }
            """
        )
        return normalize(raw or {"open": False, "lines": [], "watch": [], "watch_open": False})

    def wait_panel(self, predicate, label, timeout=WAIT):
        return wait_until(
            lambda: (lambda panel: panel if predicate(panel) else None)(self.panel()),
            f"{self.label} panel {label}",
            timeout,
        )

    def panel_press(self, lhs):
        pressed = self.lua(
            """
            local lhs = ...
            local st = require("ade.controller").state()
            local ui = st.view.team_ui
            if not ui or not ui:is_open() then return false end
            for _, map in ipairs(vim.api.nvim_buf_get_keymap(ui.buf, "n")) do
              if map.lhs == lhs and type(map.callback) == "function" then
                map.callback()
                return true
              end
            end
            return false
            """,
            lhs,
        )
        if not pressed:
            raise Failure(f"{self.label}: the team panel has no `{lhs}` keymap")
        return True

    def panel_cursor(self, ident):
        moved = self.lua(
            """
            local ident = ...
            local st = require("ade.controller").state()
            local ui = st.view.team_ui
            if not ui or not ui:is_open() then return false end
            for lnum, value in pairs(ui.ids or {}) do
              if value == ident then
                vim.api.nvim_win_set_cursor(ui.win, { lnum, 0 })
                return true
              end
            end
            return false
            """,
            ident,
        )
        if not moved:
            raise Failure(f"{self.label}: the panel has no line for {ident}")
        return True

    def panel_cursor_participant(self, name, team_id=None):
        teams = self.teams()["teams"]
        team_id = team_id or sorted(teams)[0]
        return self.panel_cursor(f"{team_id}|{name}")

    def panel_answer(self, item_id, choice):
        self.panel_cursor(f"item:{item_id}")
        self.queue_answer(choice)
        self.panel_press("a")

    def panel_send(self, name, body, kind="task"):
        self.panel_cursor_participant(name)
        self.queue_answer(kind, body)
        self.panel_press("m")

    def panel_resume(self, name):
        self.panel_cursor_participant(name)
        self.panel_press("r")

    def unwatch(self):
        self.lua("require('ade.controller').state().view.team:unwatch(); return true")

    # -- probes -------------------------------------------------------------
    def probe_team_calls(self):
        """Record every method sent to the service, whatever the Lua path."""
        self.lua(
            """
            local connection = require("ade.controller").state().conn.service
            _G.ade_e2e_methods = {}
            local original = connection.request_tracked
            connection.request_tracked = function(self, method, params, cb)
              _G.ade_e2e_methods[#_G.ade_e2e_methods + 1] = method
              return original(self, method, params, cb)
            end
            return true
            """
        )

    def team_calls(self):
        return normalize(self.lua("return _G.ade_e2e_methods or {}") or [])

    # -- lifecycle ----------------------------------------------------------
    def quit(self):
        if not self.nvim:
            return
        try:
            self.nvim.command("qa!")
        except Exception:
            pass
        ensure_signal_handlers()
        try:
            self.nvim.close()
        except Exception:
            pass
        self.nvim = None
        if self.proc and self.proc.poll() is None:
            try:
                self.proc.wait(timeout=15)
            except subprocess.TimeoutExpired:
                self.proc.kill()
                self.proc.wait(timeout=10)
        if getattr(self, "_log", None):
            try:
                self._log.close()
            except OSError:
                pass
            self._log = None

    def kill(self):
        if self.nvim:
            try:
                self.nvim.close()
            except Exception:
                pass
            self.nvim = None
        if self.proc and self.proc.poll() is None:
            self.proc.kill()
            try:
                self.proc.wait(timeout=10)
            except subprocess.TimeoutExpired:
                pass
        if getattr(self, "_log", None):
            try:
                self._log.close()
            except OSError:
                pass
            self._log = None

    def diagnostic(self):
        try:
            text = self.log.read_text(encoding="utf-8", errors="replace")
        except OSError:
            text = "<no log>"
        notes = []
        if self.nvim:
            try:
                notes = self.notification_lines()
            except Exception:
                pass
        return (
            f"--- {self.label} notifications ---\n"
            + "\n".join(notes[-30:])
            + f"\n--- {self.label} log tail ---\n"
            + "\n".join(text.splitlines()[-40:])
        )


# ---------------------------------------------------------------------------
# helpers shared by the scenarios
# ---------------------------------------------------------------------------


def template(role="Do the task carefully and report."):
    return {"coder": {"agent": "coder", "role": role}}


def approve(editor, case, task, timeout=WAIT):
    """Spawn through the leader's real MCP tool call, then approve in the panel."""
    case.wait_agent_prompt("spawn", label=f"the leader to call team_spawn for {task!r}")
    editor.wait_team(lambda value: value["teams"], "the team")
    item = editor.wait_item("spawn", timeout=timeout)
    editor.open_panel()
    editor.wait_panel(lambda panel: any("inbox" in line and "spawn" in line for line in panel["lines"]), "spawn row")
    editor.panel_answer(item["id"], "allow")
    return item


def leader_pid(case):
    sessions = [event for event in case.agent_events() if event.get("event") == "session"]
    return sessions[0]["pid"] if sessions else -1


def pid_alive(pid):
    try:
        os.kill(pid, 0)
        return True
    except OSError:
        return False


# ---------------------------------------------------------------------------
# scenarios
# ---------------------------------------------------------------------------


def scenario_chat_spawn(case):
    """1. Build a team from chat: approval, worker run, report as a bus turn."""
    editor = case.editor("a", templates=template())
    editor.connect()
    editor.submit("spawn-task:do [report]")
    item = approve(editor, case, "do [report]")

    worker = editor.wait_participant("w1", lambda entry: entry["state"] in ("working", "idle"))
    assert worker["role"] == "worker", worker
    # The worker really ran: a second agent process with its own session.
    worker_prompt = case.wait_worker_prompt("do [report]", "the worker's first prompt")
    assert worker_prompt["pid"] != leader_pid(case), worker_prompt

    block = editor.wait_bus_text("worker report", "the report bus turn")
    assert block["origin"] == "bus", block
    editor.wait_panel(lambda panel: any("w1" in line for line in panel["lines"]), "the worker row")
    state = editor.teams()["inbox"][item["id"]]
    assert state["state"] == "answered", state
    # The leader's real MCP client called the tool.
    tools = next(event for event in case.agent_events() if event.get("event") == "tools")
    assert "team_spawn" in tools["names"], tools
    return "leader called team_spawn through MCP; the panel approved; the worker reported as a bus turn"


def scenario_refuse_spawn(case):
    """2. Refusing in the panel sends a notice and starts no worker."""
    editor = case.editor("a", templates=template())
    editor.connect()
    editor.submit("spawn-task:do [report]")
    case.wait_agent_prompt("spawn", "the leader spawn call")
    item = editor.wait_item("spawn")
    editor.open_panel()
    editor.panel_answer(item["id"], "refuse")

    block = editor.wait_bus_text("refused", "the refused notice")
    assert f"spawn request {item['id']}" in block["text"], block
    _, team = editor.first_team()
    names = [entry["name"] for entry in team["participants"]]
    assert names == ["leader"], names
    # No worker agent process was ever started.
    prompt_pids = {event["pid"] for event in case.agent_events() if event.get("event") == "prompt"}
    assert len(prompt_pids) == 1, prompt_pids
    return "the refused spawn produced the documented notice and no worker process"


def scenario_survives_exit(case):
    """3. A worker finishes after Neovim exits; the next editor replays the turn."""
    first = case.editor("a", templates=template(), keep_alive=True, restore=True)
    first.connect()
    first.submit("spawn-task:do [report-slow]")
    approve(first, case, "do [report-slow]")
    first.wait_participant("w1", lambda entry: entry["state"] == "working")
    case.wait_worker_prompt("do [report-slow]", "the slow worker prompt")
    session_id = first.session_id()
    first.quit()

    # The worker is still alive without a front end; let it finish and report.
    case.gate.write_text("go", encoding="utf-8")
    delivered = case.wait_agent_event(
        lambda events: any(
            event.get("event") == "prompt" and "worker report" in (event.get("text") or "")
            for event in events
        ),
        "the report delivered to the leader while Neovim is gone",
    )
    assert delivered

    second = case.editor("b", templates=template(), keep_alive=True, restore=True)
    second.connect()
    second.wait_state(
        lambda st: (st.get("session") or {}).get("id") == session_id,
        f"the previous session {session_id} to be restored",
    )
    block = second.wait_bus_text("worker report", "the replayed report bus turn")
    # Replay carries the prompt text; the live `[bus]` marker is not logged.
    assert "worker report" in block["text"], block
    team_id, team = second.first_team()
    assert any(entry["name"] == "w1" for entry in team["participants"]), team
    second.wait_participant("w1", lambda entry: entry["state"] == "idle")
    second.open_panel()
    second.wait_panel(lambda panel: any("w1" in line for line in panel["lines"]), "the restored worker row")
    return "worker finished while Neovim was closed; the next editor restored the session and replayed the bus turn"


def scenario_bus_ask_human(case):
    """4. A worker question waits in the panel; the answer resumes it."""
    editor = case.editor("a", templates=template())
    editor.connect()
    editor.submit("spawn-task:do [ask]")
    approve(editor, case, "do [ask]")
    item = editor.wait_item("question")
    assert item["from"] == "w1", item
    assert "worker needs input" in item["body"], item
    editor.wait_participant("w1", lambda entry: entry["state"] == "waiting_human")

    editor.open_panel()
    editor.panel_answer(item["id"], "yes")
    answered = case.wait_agent_event(
        lambda events: any(
            event.get("event") == "prompt"
            and event.get("pid") != leader_pid(case)
            and 'kind="answer"' in (event.get("text") or "")
            and "yes" in (event.get("text") or "")
            for event in events
        ),
        "the worker's answer prompt",
    )
    assert answered
    editor.wait_bus_text("answer report", "the report after the answer")
    return "the question showed in the panel and the worker continued after the answer"


def scenario_permission(case):
    """5. A permission with nobody watching waits in the inbox; the panel answers."""
    editor = case.editor("a", templates=template())
    editor.connect()
    editor.submit("spawn-task:do [permission]")
    approve(editor, case, "do [permission]")
    item = editor.wait_item("permission")
    assert item["from"] == "w1", item
    editor.open_panel()
    editor.wait_panel(
        lambda panel: any("inbox" in line and "permission" in line for line in panel["lines"]),
        "the permission row",
    )
    editor.panel_answer(item["id"], "Allow")
    response = case.wait_agent_event(
        lambda events: any(event.get("event") == "permission-response" for event in events),
        "the worker's permission response",
    )
    decision = next(event for event in response if event.get("event") == "permission-response")
    assert decision["response"]["result"]["outcome"]["optionId"] == "allow", decision
    editor.wait_participant("w1", lambda entry: entry["state"] == "idle")
    editor.wait_panel(lambda panel: not any("inbox" in line for line in panel["lines"]), "the empty inbox")

    # With a watch open the request is still visible in the same panel and
    # answerable there; the first answer closes the item for every watcher.
    editor.submit("spawn-task:do [permission]")
    item = editor.wait_item("spawn")
    editor.open_panel()
    editor.panel_answer(item["id"], "allow")
    editor.wait_participant("w2", lambda entry: entry["state"] in ("working", "idle"))
    editor.open_panel()
    editor.panel_cursor_participant("w2")
    editor.panel_press("w")
    editor.wait_panel(lambda panel: panel["watch_open"], "the watch window")
    permission = editor.wait_item("permission", predicate=lambda value: value.get("from") == "w2")
    editor.wait_panel(
        lambda panel: any("permission" in line and "w2" in line for line in panel["lines"]),
        "the watched permission row",
    )
    editor.panel_answer(permission["id"], "Allow")
    response = case.wait_agent_event(
        lambda events: any(
            event.get("event") == "permission-response" and event.get("pid") != leader_pid(case)
            for event in events
        ),
        "the watched worker's permission response",
    )
    decision = next(
        event
        for event in response
        if event.get("event") == "permission-response" and event.get("pid") != leader_pid(case)
    )
    assert decision["response"]["result"]["outcome"]["optionId"] == "allow", decision
    editor.wait_participant("w2", lambda entry: entry["state"] == "idle")
    editor.unwatch()
    return (
        "the un-watched permission waited in the inbox and the panel answered it; "
        "with a watch open the same item stayed visible and was answered once"
    )


def scenario_human_first(case):
    """6. A chat prompt cancels a running bus turn on the leader, then completes."""
    editor = case.editor("a", templates=template())
    editor.connect()
    editor.first_team()
    editor.open_panel()
    editor.panel_send("leader", "do [slow]")
    case.wait_agent_prompt("do [slow]", "the leader bus prompt")
    editor.wait_participant("leader", lambda entry: entry["state"] == "working")

    editor.submit("human now")
    try:
        case.wait_agent_prompt("human now", "the human prompt forwarded after the cancel", timeout=5)
    except Failure:
        detail = normalize(
            editor.lua(
                """
                local st = require("ade.controller").state()
                local session = st.session
                return {
                  status = session and session.status or nil,
                  bus_turn = session and session.bus_turn == true or false,
                  queued = session and #(session.queue or {}) or 0,
                  agent_events = "see the agent log",
                  notifications = _G.ade_e2e_notifications or {},
                }
                """
            )
        )
        raise Failure(
            "the person's prompt was not sent while a bus turn was running: "
            f"status={detail.get('status')!r}, bus_turn={detail.get('bus_turn')}, "
            f"queued={detail.get('queued')}, notifications={editor.notification_lines()!r}; "
            "the service never saw session/prompt and therefore never cancelled the bus turn"
        )
    events = case.agent_events()
    cancels = [index for index, event in enumerate(events) if event.get("event") == "cancel"]
    human = [
        index
        for index, event in enumerate(events)
        if event.get("event") == "prompt" and "human now" in (event.get("text") or "")
    ]
    assert cancels and human and cancels[0] < human[-1], (cancels, human)
    editor.wait_turn_idle()
    assert any(
        block["kind"] == "user" and "human now" in block["text"] for block in editor.transcript()
    ), editor.transcript()
    return "the person's prompt cancelled the bus turn first and then finished normally"


def scenario_watch(case):
    """7. The read-only view replays a worker and then follows it live."""
    editor = case.editor("a", templates=template())
    editor.connect()
    editor.submit("spawn-task:do [chunk-slow]")
    approve(editor, case, "do [chunk-slow]")
    editor.wait_participant("w1", lambda entry: entry["state"] == "working")
    case.wait_worker_prompt("do [chunk-slow]", "the worker prompt")
    case.wait_agent_event(
        lambda events: any(event.get("event") == "chunk" and event.get("text") == "before waiting" for event in events),
        "the worker's first chunk",
    )

    editor.open_panel()
    editor.panel_cursor_participant("w1")
    editor.panel_press("w")
    panel = editor.wait_panel(
        lambda value: value["watch_open"] and any("before waiting" in line for line in value["watch"]),
        "the replayed worker transcript",
    )
    assert any("watching" in line for line in panel["watch"]), panel["watch"]

    case.gate.write_text("go", encoding="utf-8")
    editor.wait_panel(
        lambda value: any("after waiting" in line for line in value["watch"]),
        "the live worker chunk",
    )
    editor.wait_bus_text("worker report", "the worker report")
    notifications = editor.notification_lines()
    assert not any("watcher" in line or "-32062" in line for line in notifications), notifications
    editor.unwatch()
    return "the watch view replayed the worker and followed live updates without sending requests"


def scenario_limits(case):
    """8. max_turns_per_task pauses the worker, the panel resumes it."""
    editor = case.editor(
        "a",
        templates=template(),
        limits={"max_turns_per_task": 2},
    )
    editor.connect()
    editor.submit("spawn-task:first")
    approve(editor, case, "first")
    editor.wait_participant(
        "w1",
        lambda entry: entry["state"] == "idle" and (entry["turns"]["total"] or 0) >= 1,
        "the first worker turn",
    )
    editor.open_panel()
    editor.panel_send("w1", "second")
    paused = editor.wait_participant("w1", lambda entry: entry["paused"] is True, "the paused worker")
    assert paused["state"] == "idle", paused
    item = editor.wait_item("limit")
    assert item["participant"] == "w1", item
    editor.wait_panel(lambda panel: any("paused" in line for line in panel["lines"]), "the paused row")

    editor.panel_resume("w1")
    editor.wait_participant("w1", lambda entry: entry["paused"] is False, "the resumed worker")
    editor.panel_send("w1", "third")
    resumed = editor.wait_participant(
        "w1",
        lambda entry: entry["state"] == "idle" and (entry["turns"]["total"] or 0) >= 3,
        "the third worker turn",
    )
    # Resume clears `paused`; the counter is still at the limit, so finishing
    # one more turn pauses again (18.8 resets counters only with reset_limits).
    assert resumed["turns"]["total"] >= 3, resumed
    return "the per-task limit paused the worker, showed a limit item, and resume continued the task"


def scenario_close(case):
    """9. team.close stops the worker and removes the panel."""
    editor = case.editor("a", templates=template())
    editor.connect()
    editor.submit("spawn-task:do [report]")
    approve(editor, case, "do [report]")
    worker = case.wait_worker_prompt("do [report]", "the worker prompt")
    editor.wait_participant("w1", lambda entry: entry["state"] in ("working", "idle"))
    editor.wait_bus_text("worker report", "the worker report")
    editor.open_panel()
    editor.panel_cursor_participant("leader")
    editor.queue_answer("Close the team")
    editor.panel_press("x")
    editor.wait_team(lambda value: not value["teams"], "the closed team")

    editor.wait_panel(lambda panel: panel["open"] is False, "the panel to disappear")
    wait_until(lambda: not pid_alive(worker["pid"]), "the worker process to exit")
    return "team.close stopped the worker process and the panel disappeared"


def scenario_single_agent(case):
    """10. No template (and spawn_from_chat=false) keeps the single-agent path."""
    calls = []
    for label, templates, spawn_from_chat in (
        ("no-templates", None, True),
        ("spawn-off", template(), False),
    ):
        editor = case.editor(
            label,
            templates=templates,
            spawn_from_chat=None if spawn_from_chat else False,
        )
        editor.probe_team_calls()
        editor.connect()
        editor.submit("hello")
        editor.wait_transcript(
            lambda blocks: any(block["kind"] == "agent" and "working on it" in block["text"] for block in blocks),
            "the normal reply",
        )
        calls.extend((label, name) for name in editor.team_calls())
        sessions = [event for event in case.agent_events() if event.get("event") == "session"]
        assert sessions, "the agent never started"
        assert not any(event.get("mcp") for event in sessions), (
            f"{label}: teams injected an ade-team MCP server without a reason: {sessions}"
        )
        assert not editor.teams()["teams"], f"{label}: a team exists"
    assert not [entry for label, entry in calls if entry.startswith("team.")], calls
    return "without templates (and with spawn_from_chat=false) no ade-team server or team.* call happens"


SCENARIOS = [
    ("1-chat-spawn", scenario_chat_spawn),
    ("2-refuse-spawn", scenario_refuse_spawn),
    ("3-survives-exit", scenario_survives_exit),
    ("4-bus-ask-human", scenario_bus_ask_human),
    ("5-permission", scenario_permission),
    ("6-human-first", scenario_human_first),
    ("7-watch", scenario_watch),
    ("8-limits", scenario_limits),
    ("9-close", scenario_close),
    ("10-single-agent", scenario_single_agent),
]


def run_case(label, fn):
    case = Case(label)
    active_cases.append(case)
    try:
        result = fn(case)
        case.stop()
        leftover = case.leftover_processes()
        assert not leftover, f"leftover processes: {leftover}"
        print(f"ok: {label}: {result}", flush=True)
        return True
    except Exception as exc:  # noqa: BLE001 - the report includes the traceback
        failures.append((label, exc))
        print(f"FAIL: {label}: {exc}", flush=True)
        traceback.print_exc()
        try:
            print(case.report(), flush=True)
        except Exception:  # noqa: BLE001
            pass
        return False
    finally:
        try:
            case.cleanup()
        finally:
            if case in active_cases:
                active_cases.remove(case)


def main():
    if not SERVICE.exists():
        print("SKIP: no service binary at service/target/release/nvim_ade_server")
        return 2
    _install_signal_handlers()
    only = os.environ.get("ADE_E2E_ONLY", "")
    selected = [(label, fn) for label, fn in SCENARIOS if not only or only in label]
    if not selected:
        print(f"no scenario matches ADE_E2E_ONLY={only!r}")
        return 2
    started = time.monotonic()
    for label, fn in selected:
        run_case(label, fn)
    elapsed = time.monotonic() - started
    if failures:
        print(f"\n{len(failures)} failure(s) in {elapsed:.1f}s:", flush=True)
        for label, exc in failures:
            print(f"  {label}: {exc}", flush=True)
        return 1
    print(f"\nall {len(selected)} scenarios passed in {elapsed:.1f}s", flush=True)
    return 0


if __name__ == "__main__":
    sys.exit(main())
