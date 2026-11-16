#!/usr/bin/env python3
"""Permission-policy end-to-end scenarios: real service binary + real Lua plugin.

Every scenario runs in its own temporary tree with its own service directory and
headless Neovims driven over pynvim. The agent is
`service/tests/fixtures/policy_agent.py`, which asks for exactly the permission
shape a scenario needs. The service is the release build
`service/target/release/nvim_ade_server`.

Run: python3 tests/integration_service_policy.py
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
POLICY_AGENT = ROOT / "service" / "tests" / "fixtures" / "policy_agent.py"
WAIT = 25.0

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
        self.dir = Path(tempfile.mkdtemp(prefix=f"ade-policy-e2e-{label}-"))
        self.service_dir = self.dir / "service"
        os.makedirs(self.service_dir, exist_ok=True)
        self.agent_log = self.dir / "policy-agent.log"
        self.gate = self.dir / "policy-agent.gate"
        self.editors = []
        self.init = self.dir / "init.lua"
        self.init.write_text(
            "vim.opt.runtimepath:append(%r)\n"
            "vim.opt.swapfile = false\n"
            "vim.opt.shadafile = 'NONE'\n"
            "vim.opt.laststatus = 3\n"
            "vim.opt.columns = 140\n"
            "vim.opt.lines = 50\n" % str(ROOT)
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

    def wait_agent(self, kind, index=None, timeout=WAIT):
        def match(event):
            return event.get("event") == kind and (index is None or event.get("index") == index)

        return next(
            event
            for event in self.wait_agent_event(
                lambda events: any(match(event) for event in events),
                f"agent {kind}" + (f" #{index}" if index is not None else ""),
                timeout,
            )
            if match(event)
        )

    def agent_log_tail(self, lines=30):
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
            if _proc_env(pid).split(b"\0").count(wanted) and (
                "nvim_ade_server" in cmdline or "policy_proxy" in cmdline
            ):
                pids.append(pid)
        return pids

    def cleanup(self):
        for editor in self.editors:
            editor.kill()
        for pid in self.service_pids():
            try:
                os.kill(pid, signal.SIGKILL)
            except OSError:
                pass
        # Agents, proxies and the service all carry this case's directory in
        # their environment; match the command line so nothing else is touched.
        for pid in _all_pids():
            env = _proc_env(pid)
            if str(self.dir).encode() not in env:
                continue
            cmdline = _proc_cmdline(pid)
            if (
                "policy_agent.py" in cmdline
                or "policy_proxy" in cmdline
                or "nvim_ade_server" in cmdline
            ):
                try:
                    os.kill(pid, signal.SIGKILL)
                except OSError:
                    pass
        if os.environ.get("ADE_E2E_KEEP") != "1":
            shutil.rmtree(self.dir, ignore_errors=True)

    def leftover_processes(self):
        out = []
        for pid in _all_pids():
            env = _proc_env(pid)
            if str(self.dir).encode() not in env:
                continue
            cmdline = _proc_cmdline(pid)
            if (
                "policy_agent.py" in cmdline
                or "policy_proxy" in cmdline
                or "nvim_ade_server" in cmdline
            ):
                out.append((pid, cmdline))
        return out

    def report(self):
        parts = [f"=== {self.label} ===", f"case dir: {self.dir}"]
        for editor in self.editors:
            parts.append(editor.diagnostic())
        parts.append("--- agent log ---")
        parts.append(self.agent_log_tail())
        for editor in self.editors:
            if editor.nvim:
                try:
                    parts.append(f"--- {editor.label} policy.list ---")
                    parts.append(json.dumps(editor.policy_list(), ensure_ascii=False, indent=2))
                except Exception as exc:  # noqa: BLE001
                    parts.append(f"<policy.list failed: {exc}>")
        parts.append("--- service pids ---")
        parts.append(repr(self.service_pids()))
        return "\n".join(parts)


class Editor:
    def __init__(
        self,
        case,
        label,
        backend="service",
        auto_allow=None,
        service_path=None,
        idle_timeout=60,
        agent_env=None,
        restore=True,
    ):
        self.case = case
        self.label = label
        self.backend = backend
        self.auto_allow = auto_allow or []
        self.service_path = service_path or SERVICE
        self.idle_timeout = idle_timeout
        self.agent_env = agent_env or {}
        self.restore = restore
        self.socket = case.dir / f"{label}.sock"
        self.log = case.dir / f"{label}.nvim.log"
        self.proc = None
        self.nvim = None

    def start(self):
        env = isolated_env(self.case, self.label)
        self._log = open(self.log, "wb")
        self.proc = subprocess.Popen(
            ["nvim", "--headless", "--listen", str(self.socket), "-u", str(self.case.init)],
            cwd=str(ROOT),
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
            "POLICY_AGENT_LOG": str(self.case.agent_log),
            "POLICY_AGENT_GATE": str(self.case.gate),
            "POLICY_AGENT_DELAY": "3",
        }
        agent_env.update(self.agent_env)
        opts = {
            "agent": "opencode",
            "agents": {
                "opencode": {
                    "command": "python3",
                    "args": [str(POLICY_AGENT)],
                    "env": agent_env,
                }
            },
            "service": {
                "path": str(self.service_path),
                "keep_alive": True,
                "idle_timeout": self.idle_timeout,
                "event_log": True,
                "restore": self.restore,
            },
            "permissions": {
                "prompt": "native",
                "show_details": False,
                "auto_allow": list(self.auto_allow),
            },
            "ui": {},
            "log": {"level": "info"},
        }
        # `backend=None` leaves the key out, so the configured default applies.
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

    def wait_state(self, predicate, label="state"):
        return wait_until(lambda: (lambda st: st if predicate(st) else None)(self.state()), f"{self.label} {label}")

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
                  policy = block.policy,
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

    def wait_reply(self, needle, timeout=WAIT):
        def check():
            for block in self.transcript():
                if block.get("kind") == "agent" and needle in (block.get("text") or ""):
                    return block
            return None

        return wait_until(check, f"{self.label} reply containing {needle!r}", timeout)

    def wait_turn_idle(self, timeout=WAIT):
        return self.wait_state(
            lambda st: (st.get("session") or {}).get("status") == "idle",
            "turn to finish",
        )

    def wait_session(self, session_id, timeout=WAIT):
        return self.wait_state(
            lambda st: (st.get("session") or {}).get("id") == session_id,
            f"session {session_id}",
        )

    # -- service ------------------------------------------------------------
    def instances(self):
        raw = self.lua(
            """
            local connection = require("ade.service.connection").shared()
            local done, result = false, nil
            connection:request("agent.list", {}, function(ok, value)
              done = true
              result = ok and value.instances or { error = vim.inspect(value) }
            end)
            vim.wait(5000, function() return done end, 10)
            return result
            """
        )
        return normalize(raw or [])

    def has_feature(self, name):
        raw = self.lua(
            """
            local name = ...
            local connection = require("ade.service.connection").shared()
            return connection:has_feature(name) == true
            """,
            name,
        )
        return raw is True

    def policy_list(self):
        raw = self.lua(
            """
            local connection = require("ade.service.connection").shared()
            if not connection:is_connected() then return { sets = {}, error = "not connected" } end
            local done, result = false, nil
            connection:request("policy.list", {}, function(ok, value)
              done = true
              result = ok and value or { error = vim.inspect(value) }
            end)
            vim.wait(5000, function() return done end, 10)
            return result
            """
        )
        return normalize(raw or {})

    def policy_names(self):
        sets = self.policy_list().get("sets") or []
        return [entry.get("name") for entry in sets]

    def wait_policy(self, predicate, label, timeout=WAIT):
        def check():
            sets = self.policy_list().get("sets") or []
            # Wrap it: an empty list is a legitimate match, but `wait_until`
            # treats a falsy result as "not yet".
            return {"sets": sets} if predicate(sets) else None

        return wait_until(check, f"{self.label} {label}", timeout)["sets"]

    # -- permissions --------------------------------------------------------
    def pending_permissions(self):
        raw = self.lua(
            """
            local st = require("ade.controller").state()
            local items = st.view.interactions:pending()
            local out = {}
            for _, item in ipairs(items) do
              out[#out + 1] = { id = item.id, type = item.type }
            end
            return out
            """
        )
        return normalize(raw or [])

    def wait_permission(self, label="a pending permission", timeout=WAIT):
        return wait_until(
            lambda: self.pending_permissions() if self.pending_permissions() else None,
            f"{self.label} {label}",
            timeout,
        )

    def answer_permission(self, option_id):
        self.lua(
            """
            local option = ...
            local st = require("ade.controller").state()
            local items = st.view.interactions:pending()
            assert(#items > 0, "no pending permission to answer")
            st.view.interactions:answer(items[1].id, {
              outcome = { outcome = "selected", optionId = option },
            })
            return true
            """,
            option_id,
        )

    # -- inline -------------------------------------------------------------
    def open_inline(self, path, prompt):
        raw = self.lua(
            """
            local path, prompt = ...
            vim.cmd("edit " .. vim.fn.fnameescape(path))
            vim.api.nvim_win_set_cursor(0, { 1, 0 })
            local inline = require("ade.inline")
            local opened = inline.open({ review = "write" })
            if not opened then return { opened = false } end
            local inv = inline._current()
            if not inv then return { opened = false, error = "no inline invocation" } end
            local submitted = inline.submit(inv, prompt)
            return { opened = true, submitted = submitted == true, copy = inv.copy, turn = inv.turn }
            """,
            path,
            prompt,
        )
        return normalize(raw or {})

    def stop_inline(self):
        return self.lua("return require('ade.inline').stop() == true")

    def buffer_lines(self, path):
        raw = self.lua(
            """
            local path = ...
            local buf = vim.fn.bufnr(path)
            if buf < 0 then return nil end
            return vim.api.nvim_buf_get_lines(buf, 0, -1, false)
            """,
            path,
        )
        return normalize(raw) if raw is not None else None

    def wait_buffer(self, path, predicate, label, timeout=WAIT):
        return wait_until(
            lambda: (lambda lines: lines if lines is not None and predicate(lines) else None)(
                self.buffer_lines(path)
            ),
            f"{self.label} {label}",
            timeout,
        )

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
            f"--- {self.label} ({self.backend}) notifications ---\n"
            + "\n".join(notes[-30:])
            + f"\n--- {self.label} log tail ---\n"
            + "\n".join(text.splitlines()[-40:])
        )


# ---------------------------------------------------------------------------
# scenarios
# ---------------------------------------------------------------------------


def scenario_unattended_auto(case):
    """1. The service config set answers a permission after its editor exited."""
    first = case.editor("a", auto_allow=["allow_once"])
    first.connect()
    session = first.session_id()
    first.submit("delayed-permission")
    first.wait_reply("working")
    first.quit()

    allowed = case.wait_agent("permission", 1, timeout=WAIT)
    assert allowed["outcome"] == "selected", allowed
    assert allowed["optionId"] == "allow", allowed
    case.wait_agent("done", timeout=WAIT)

    second = case.editor("b", auto_allow=["allow_once"])
    second.connect()
    second.wait_session(session)
    transcript = second.wait_transcript(
        lambda blocks: any(block["kind"] == "agent" and block["text"] == "done" for block in blocks)
        and any(block["kind"] == "notice" and "auto-allowed" in block["text"] for block in blocks),
        "the replayed turn and its policy notice",
    )
    notices = [block for block in transcript if block["kind"] == "notice"]
    assert any(
        "auto-allowed" in block["text"] and (block.get("policy") or {}).get("set") == "config"
        for block in notices
    ), notices
    assert "config" in second.policy_names(), second.policy_names()
    return "auto-allowed after the editor exited; replayed as a notice"


def scenario_unattended_question(case):
    """2. A question is relayed, stays pending with no front end, and shows up."""
    first = case.editor("a", auto_allow=["allow_once"])
    first.connect()
    session = first.session_id()
    first.submit("delayed-question")
    first.wait_reply("working")
    first.quit()

    asked = case.wait_agent("ask", 1, timeout=WAIT)
    assert asked["toolCallId"] == "question", asked
    # Give a wrong auto-answer a full second to appear; the question must not
    # be decided while nobody is attached.
    deadline = time.monotonic() + 1.0
    while time.monotonic() < deadline:
        assert not any(event.get("event") == "permission" for event in case.agent_events()), case.agent_events()
        time.sleep(0.1)

    second = case.editor("b", auto_allow=["allow_once"])
    second.connect()
    second.wait_session(session)
    pending = second.wait_permission("the replayed question")
    assert pending, pending
    second.wait_notification("Permission required")
    second.answer_permission("a")
    answered = case.wait_agent("permission", 1, timeout=WAIT)
    assert answered["outcome"] == "selected" and answered["optionId"] == "a", answered
    second.wait_turn_idle()
    return "question stayed pending until the new editor answered it"


def scenario_inline_turn(case):
    """3. One real inline turn: copy allowed, everything else refused."""
    editor = case.editor("a")
    editor.connect()
    source = case.dir / "notes.txt"
    source.write_text("alpha\nbeta\n", encoding="utf-8")

    opened = editor.open_inline(str(source), "policy-full")
    assert opened.get("opened") and opened.get("submitted"), opened
    assert opened.get("copy") and Path(opened["copy"]).exists(), opened

    pending = editor.wait_permission("the inline question")
    assert pending, pending
    events = case.wait_agent_event(
        lambda events: all(
            any(
                event.get("event") == "permission" and event.get("index") == index
                for event in events
            )
            for index in (1, 2, 3, 4)
        ),
        "the four inline tool decisions",
    )
    decisions = {
        event["index"]: event
        for event in events
        if event.get("event") == "permission" and event.get("session") == editor.session_id()
    }
    assert decisions[1]["outcome"] == "selected" and decisions[1]["optionId"] == "allow", decisions[1]
    assert decisions[2]["outcome"] == "selected" and decisions[2]["optionId"] == "reject", decisions[2]
    assert decisions[3]["outcome"] == "selected" and decisions[3]["optionId"] == "reject", decisions[3]
    assert decisions[4]["outcome"] == "selected" and decisions[4]["optionId"] == "allow", decisions[4]

    editor.answer_permission("a")
    answered = case.wait_agent("permission", 5, timeout=WAIT)
    assert answered["outcome"] == "selected" and answered["optionId"] == "a", answered
    editor.wait_turn_idle()
    lines = editor.wait_buffer(str(source), lambda lines: lines and lines[0] == "omega", "the inline write")
    assert lines == ["omega", "beta"], lines
    editor.wait_policy(lambda sets: not any(s["name"].startswith("inline:") for s in sets), "inline set removal")
    notices = editor.notification_lines()
    assert any("inline applied" in line for line in notices), notices
    return "private copy allowed, source/other refused, read allowed, question asked"


def scenario_inline_cancel(case):
    """4. A cancelled inline turn answers later requests `cancelled`, not a dialog."""
    editor = case.editor("a")
    editor.connect()
    source = case.dir / "cancel.txt"
    source.write_text("alpha\nbeta\n", encoding="utf-8")

    opened = editor.open_inline(str(source), "policy-cancel")
    assert opened.get("opened") and opened.get("submitted"), opened
    first = case.wait_agent("permission", 1)
    assert first["outcome"] == "selected" and first["optionId"] == "allow", first
    editor.wait_policy(
        lambda sets: any(s["name"].startswith("inline:") and s.get("bound") for s in sets),
        "the bound inline set",
    )

    assert editor.stop_inline() is True
    case.wait_agent("cancel")
    case.gate.write_text("", encoding="utf-8")

    second = case.wait_agent("permission", 2)
    assert second["outcome"] == "cancelled", second
    assert second["optionId"] is None, second
    assert editor.pending_permissions() == [], editor.pending_permissions()
    editor.wait_turn_idle()
    editor.wait_policy(lambda sets: not any(s["name"].startswith("inline:") for s in sets), "inline set removal")
    return "the post-cancel request was answered cancelled without a prompt"


def scenario_other_session_unaffected(case):
    """5. An inline set is bound to its session; another Neovim is untouched."""
    first = case.editor("a")
    second = case.editor("b", restore=False)
    first.connect()
    second.connect()
    first_session = first.session_id()
    second_session = second.session_id()
    assert first_session and second_session and first_session != second_session

    source = case.dir / "hold.txt"
    source.write_text("alpha\nbeta\n", encoding="utf-8")
    opened = first.open_inline(str(source), "policy-hold")
    assert opened.get("opened") and opened.get("submitted"), opened
    allowed = case.wait_agent("permission", 1)
    assert allowed["session"] == first_session, allowed
    assert allowed["outcome"] == "selected" and allowed["optionId"] == "allow", allowed
    first.wait_policy(
        lambda sets: any(
            s["name"] == "inline:" + first_session and s.get("bound") and s.get("session") == first_session
            for s in sets
        ),
        "the bound inline set",
    )

    second.submit("permission")
    pending = second.wait_permission("the other session's request")
    assert pending, pending
    assert not any(
        event.get("event") == "permission" and event.get("session") == second_session
        for event in case.agent_events()
    ), case.agent_events()
    second.answer_permission("allow")
    answered = case.wait_agent_event(
        lambda events: any(
            event.get("event") == "permission"
            and event.get("session") == second_session
            and event.get("outcome") == "selected"
            for event in events
        ),
        "the other session's answer",
    )
    assert answered
    second.wait_turn_idle()

    case.gate.write_text("", encoding="utf-8")
    first.wait_turn_idle()
    first.wait_policy(lambda sets: not any(s["name"].startswith("inline:") for s in sets), "inline set removal")
    return "the other session stayed on the normal permission path"


def scenario_links(case):
    """6. A symlink or hard link planted at the copy path is not auto-allowed."""
    editor = case.editor("a")
    editor.connect()
    for kind in ("symlink", "hardlink"):
        source = case.dir / f"{kind}.txt"
        source.write_text("alpha\nbeta\n", encoding="utf-8")
        opened = editor.open_inline(str(source), "policy-" + kind)
        assert opened.get("opened") and opened.get("submitted"), opened
        event = case.wait_agent_event(
            lambda events: any(
                item.get("event") == "permission" and item.get("toolCallId") == "copy"
                for item in events
            ),
            f"the {kind} permission",
        )
        decision = next(
            item
            for item in event
            if item.get("event") == "permission" and item.get("toolCallId") == "copy"
        )
        assert decision["outcome"] == "selected", decision
        assert decision["optionId"] == "reject", decision
        editor.wait_turn_idle()
        editor.wait_policy(lambda sets: not any(s["name"].startswith("inline:") for s in sets), "inline set removal")
        assert editor.buffer_lines(str(source)) == ["alpha", "beta"], editor.buffer_lines(str(source))
        assert source.read_text(encoding="utf-8") == "alpha\nbeta\n"
    return "both links refused and neither file changed"


PROXY = r'''#!/usr/bin/env python3
"""A service wrapper whose hello does not advertise "policy"."""
import json, os, socket, subprocess, sys, threading

REAL = {real!r}
DIR = os.environ["NVIM_ADE_SERVER_DIR"]
SOCKET = os.path.join(DIR, "nvim_ade_server.sock")
REAL_SOCKET = os.path.join(DIR, "nvim_ade_server.real.sock")

def relay(src, dst, rewrite):
    buf = b""
    try:
        while True:
            chunk = src.recv(1 << 16)
            if not chunk:
                break
            if not rewrite:
                dst.sendall(chunk)
                continue
            buf += chunk
            while b"\n" in buf:
                line, buf = buf.split(b"\n", 1)
                try:
                    message = json.loads(line)
                    result = message.get("result") if isinstance(message, dict) else None
                    if isinstance(result, dict) and isinstance(result.get("features"), list):
                        result["features"] = [f for f in result["features"] if f != "policy"]
                        line = json.dumps(message).encode()
                except Exception:
                    pass
                dst.sendall(line + b"\n")
    except OSError:
        pass
    finally:
        try:
            dst.shutdown(socket.SHUT_WR)
        except OSError:
            pass

def main():
    argv = sys.argv[1:]
    if argv and argv[0] == "version":
        out = subprocess.run([REAL, "version"], capture_output=True, text=True)
        sys.stdout.write(out.stdout)
        return out.returncode
    rest = argv[1:] if argv and argv[0] == "serve" else argv
    forwarded = ["serve", "--socket", REAL_SOCKET]
    index = 0
    while index < len(rest):
        if rest[index] == "--socket":
            index += 2
            continue
        forwarded.append(rest[index])
        index += 1
    try:
        os.unlink(REAL_SOCKET)
    except OSError:
        pass
    real = subprocess.Popen([REAL] + forwarded, stdout=subprocess.PIPE, stderr=None, text=True)
    line = real.stdout.readline()
    if not line:
        print(json.dumps({{"status": "error", "message": "real service did not start"}}), flush=True)
        return 1
    def stop(_code=None):
        try:
            os.unlink(SOCKET)
        except OSError:
            pass
        os._exit(0)
    threading.Thread(target=lambda: (real.wait(), stop()), daemon=True).start()
    try:
        os.unlink(SOCKET)
    except OSError:
        pass
    listener = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    listener.bind(SOCKET)
    listener.listen(16)
    print(json.dumps({{"status": "ready", "socket": SOCKET, "pid": os.getpid()}}), flush=True)
    while True:
        client, _ = listener.accept()
        def serve(client=client):
            upstream = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            try:
                upstream.connect(REAL_SOCKET)
            except OSError:
                client.close()
                return
            threading.Thread(target=relay, args=(client, upstream, False), daemon=True).start()
            threading.Thread(target=relay, args=(upstream, client, True), daemon=True).start()
        threading.Thread(target=serve, daemon=True).start()

if __name__ == "__main__":
    sys.exit(main())
'''


def scenario_old_service(case):
    """7. Without the `policy` feature the Lua policies still decide."""
    proxy = case.dir / "policy_proxy.py"
    proxy.write_text(PROXY.format(real=str(SERVICE)), encoding="utf-8")
    proxy.chmod(0o755)
    editor = case.editor("a", auto_allow=["allow_once"], service_path=proxy)
    editor.connect()
    assert editor.has_feature("policy") is False, "the proxy must hide the feature"

    editor.submit("permission")
    allowed = case.wait_agent("permission", 1)
    assert allowed["outcome"] == "selected" and allowed["optionId"] == "allow", allowed
    assert editor.pending_permissions() == []
    assert not any("Permission required" in line for line in editor.notification_lines())
    editor.wait_turn_idle()

    source = case.dir / "legacy.txt"
    source.write_text("alpha\nbeta\n", encoding="utf-8")
    opened = editor.open_inline(str(source), "policy-full")
    assert opened.get("opened") and opened.get("submitted"), opened
    pending = editor.wait_permission("the Lua inline question")
    assert pending, pending
    events = case.wait_agent_event(
        lambda events: all(
            any(event.get("event") == "permission" and event.get("index") == index for event in events)
            for index in (1, 2, 3, 4)
        ),
        "the Lua inline decisions",
    )
    decisions = {event["index"]: event for event in events if event.get("event") == "permission"}
    assert decisions[1]["optionId"] == "allow", decisions[1]
    assert decisions[2]["optionId"] == "reject", decisions[2]
    assert decisions[3]["optionId"] == "reject", decisions[3]
    assert decisions[4]["optionId"] == "allow", decisions[4]
    editor.answer_permission("a")
    answered = case.wait_agent("permission", 5)
    assert answered["optionId"] == "a", answered
    editor.wait_turn_idle()
    editor.wait_buffer(str(source), lambda lines: lines and lines[0] == "omega", "the inline write")
    assert editor.policy_names() == [], editor.policy_names()
    return "Lua auto_allow and inline policy answered without the feature"


def scenario_default_backend(case):
    """8. backend defaults to auto: service when usable, direct when not."""
    service = case.editor("a", backend=None, service_path=SERVICE)
    service.connect()
    state = service.state()
    assert state["backend_service"] is True, state
    assert service.instances(), service.instances()
    service.submit("hello")
    service.wait_reply("done")
    service.wait_turn_idle()

    direct = case.editor("b", backend=None, service_path=case.dir / "missing-server")
    direct.connect()
    state = direct.state()
    assert state["backend_service"] is False, state
    warnings = [line for line in direct.notification_lines() if "using the direct backend" in line]
    assert len(warnings) == 1, direct.notification_lines()
    direct.submit("hello")
    direct.wait_reply("done")
    direct.wait_turn_idle()

    direct.clear_notifications()
    direct.lua("require('ade.controller').disconnect(); return true")
    wait_until(lambda: direct.state()["phase"] != "ready", "the direct session to stop")
    direct.connect()
    again = [line for line in direct.notification_lines() if "using the direct backend" in line]
    assert again == [], again
    return "auto used the service, then fell back once to direct"


SCENARIOS = [
    ("1 unattended auto allow", scenario_unattended_auto),
    ("2 unattended question stays pending", scenario_unattended_question),
    ("3 inline turn permissions", scenario_inline_turn),
    ("4 inline cancel", scenario_inline_cancel),
    ("5 other session unaffected", scenario_other_session_unaffected),
    ("6 symlink and hardlink guard", scenario_links),
    ("7 service without policy feature", scenario_old_service),
    ("8 default backend auto", scenario_default_backend),
]


def run(label, fn):
    case = Case(label.split()[0])
    active_cases.append(case)
    try:
        detail = fn(case)
        print(f"ok: {label}: {detail}", flush=True)
    except Exception as exc:  # noqa: BLE001 - a failure is a test result
        failures.append(label)
        print(f"FAIL: {label}: {exc}", flush=True)
        traceback.print_exc()
        print(case.report(), flush=True)
    finally:
        active_cases.remove(case)
        case.cleanup()
        leftover = case.leftover_processes()
        if leftover:
            print(f"FAIL: {label}: leftover processes: {leftover}", flush=True)
            failures.append(label + " cleanup")
        if case.dir.exists():
            print(f"FAIL: {label}: temporary directory was not removed: {case.dir}", flush=True)
            failures.append(label + " cleanup")
        ensure_signal_handlers()


def main():
    if not SERVICE.exists():
        sys.exit(f"missing service binary: {SERVICE}")
    if not POLICY_AGENT.exists():
        sys.exit(f"missing policy agent: {POLICY_AGENT}")
    _install_signal_handlers()
    print(f"service binary: {SERVICE}", flush=True)
    only = os.environ.get("ADE_E2E_ONLY", "")
    try:
        for label, fn in SCENARIOS:
            if only and only not in label:
                continue
            run(label, fn)
    finally:
        _cleanup_active_cases()
    if failures:
        print(f"{len(failures)} scenario(s) failed: {', '.join(failures)}")
        return 1
    print("all permission-policy scenarios passed")
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    finally:
        _cleanup_active_cases()
