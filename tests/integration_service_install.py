#!/usr/bin/env python3
"""End-to-end managed-install scenarios: real service binary + real Lua plugin.

Every scenario runs in its own temporary tree with its own service directory,
manager root and fake npm. Editors are headless Neovims driven over pynvim.

Run: python3 tests/integration_service_install.py
     ADE_E2E_ONLY="3" python3 ...   # one scenario (substring match)
     ADE_E2E_KEEP=1 python3 ...    # keep temporary directories
"""

import json
import logging
import os
import shutil
import signal
import socket
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
FAKE_NPM = ROOT / "service" / "tests" / "fixtures" / "fake-npm"
MOCK_AGENT = ROOT / "tests" / "mock_agent.py"
WAIT = 20.0


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


def isolated_env(case, label):
    base = case.dir / "env" / label
    env = dict(os.environ)
    for key in ("HOME", "XDG_DATA_HOME", "XDG_STATE_HOME", "XDG_CACHE_HOME"):
        os.makedirs(base / key.lower(), exist_ok=True)
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
        self.dir = Path(tempfile.mkdtemp(prefix=f"ade-install-e2e-{label}-"))
        self.service_dir = self.dir / "service"
        os.makedirs(self.service_dir, exist_ok=True)
        self.manager_root = self.dir / "manager"
        os.makedirs(self.manager_root, exist_ok=True)
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

    def editor(self, label, backend, manager_root=None, agent="opencode", env_extra=None, service_path=None):
        editor = Editor(self, label, backend, manager_root or self.manager_root, agent, env_extra, service_path)
        self.editors.append(editor)
        editor.start()
        return editor

    def service_pids(self):
        pids = []
        for entry in Path("/proc").iterdir():
            if not entry.name.isdigit():
                continue
            try:
                env = (entry / "environ").read_bytes().split(b"\0")
                cmdline = (entry / "cmdline").read_bytes().replace(b"\0", b" ").decode("utf-8", "replace")
            except OSError:
                continue
            if f"NVIM_ADE_SERVER_DIR={self.service_dir}".encode() in env and (
                "nvim_ade_server" in cmdline or "install_proxy" in cmdline
            ):
                pids.append(int(entry.name))
        return pids

    def cleanup(self):
        for editor in self.editors:
            editor.kill()
        for pid in self.service_pids():
            try:
                os.kill(pid, signal.SIGKILL)
            except OSError:
                pass
        # fake npm and mock agents inherit the case environment.
        for entry in Path("/proc").iterdir():
            if not entry.name.isdigit():
                continue
            try:
                env = (entry / "environ").read_bytes()
                cmdline = (entry / "cmdline").read_bytes().replace(b"\0", b" ").decode("utf-8", "replace")
            except OSError:
                continue
            if str(self.dir).encode() in env and (
                "fake-npm" in cmdline or "mock_agent.py" in cmdline
            ):
                try:
                    os.kill(int(entry.name), signal.SIGKILL)
                except OSError:
                    pass
        if os.environ.get("ADE_E2E_KEEP") != "1":
            shutil.rmtree(self.dir, ignore_errors=True)

    def leftover_processes(self):
        out = []
        for entry in Path("/proc").iterdir():
            if not entry.name.isdigit():
                continue
            try:
                env = (entry / "environ").read_bytes()
                cmdline = (entry / "cmdline").read_bytes().replace(b"\0", b" ").decode("utf-8", "replace")
            except OSError:
                continue
            if str(self.dir).encode() in env and (
                "fake-npm" in cmdline
                or "mock_agent.py" in cmdline
                or "nvim_ade_server" in cmdline
                or "install_proxy" in cmdline
            ):
                out.append((int(entry.name), cmdline))
        return out

    def report(self):
        parts = [f"=== {self.label} ===", f"manager root: {self.manager_root}"]
        for editor in self.editors:
            parts.append(editor.diagnostic())
        parts.append("--- manager tree ---")
        for path in sorted(self.manager_root.rglob("*")):
            if path.is_file():
                relative = path.relative_to(self.manager_root)
                try:
                    content = path.read_text(encoding="utf-8", errors="replace")
                except OSError:
                    content = "<unreadable>"
                parts.append(f"{relative}: {content[:400]!r}")
            else:
                parts.append(f"{path.relative_to(self.manager_root)}/")
        parts.append("--- service stderr (inherited by the editor logs) ---")
        for editor in self.editors:
            try:
                text = editor.log.read_text(encoding="utf-8", errors="replace")
            except OSError:
                text = ""
            parts.append(f"[{editor.label}] " + " | ".join(text.splitlines()[-8:]))
        parts.append("--- service pids ---")
        parts.append(repr(self.service_pids()))
        return "\n".join(parts)


class Editor:
    def __init__(self, case, label, backend, manager_root, agent, env_extra, service_path):
        self.case = case
        self.label = label
        self.backend = backend
        self.manager_root = manager_root
        self.agent = agent
        self.env_extra = env_extra or {}
        self.service_path = service_path
        self.socket = case.dir / f"{label}.sock"
        self.log = case.dir / f"{label}.nvim.log"
        self.proc = None
        self.nvim = None

    def start(self):
        env = isolated_env(self.case, self.label)
        # The fake package's entry file is the real mock ACP agent, so a managed
        # launch works with `manager.node = "python3"` (no Node.js needed).
        env["FAKE_NPM_ENTRY_SOURCE"] = str(MOCK_AGENT)
        env.update(self.env_extra)
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
        self.nvim = wait_until(
            lambda: self._attach(),
            f"{self.label} to accept a connection",
        )
        self.configure()

    def _attach(self):
        try:
            return pynvim.attach("socket", path=str(self.socket))
        except (OSError, ConnectionError):
            return None

    def configure(self):
        service = {
            "path": str(self.service_path or SERVICE),
            "keep_alive": True,
            "idle_timeout": 60,
            "event_log": True,
        }
        opts = {
            "backend": self.backend,
            "service": service,
            "agent": self.agent,
            "agents": {
                "opencode": {"command": "python3", "args": [str(MOCK_AGENT)]},
                "pi": {"source": "managed", "profile": "pi"},
            },
            "manager": {
                "root": str(self.manager_root),
                "node": "python3",
                "npm": str(FAKE_NPM),
                "confirm": False,
                "install_timeout": 20000,
                "max_log_bytes": 1024 * 1024,
            },
            "permissions": {"prompt": "native", "show_details": False},
            "ui": {},
            "log": {"level": "info"},
        }
        self.lua(
            """
            local opts = ...
            require("ade").setup(opts)
            _G.ade_e2e_notifications = {}
            vim.notify = function(message, level)
              _G.ade_e2e_notifications[#_G.ade_e2e_notifications + 1] = tostring(message)
            end
            return true
            """,
            opts,
        )

    def lua(self, code, *args):
        return self.nvim.exec_lua(code, *args)

    def notifications(self):
        raw = self.lua("return _G.ade_e2e_notifications or {}")
        return normalize(raw)

    def wait_notification(self, needle, label=None, timeout=WAIT):
        def check():
            for line in self.notifications():
                if needle in line:
                    return line
            return None

        return wait_until(check, label or f"{self.label} notification {needle!r}", timeout)

    def clear_notifications(self):
        self.lua("_G.ade_e2e_notifications = {}; return true")

    def manager_row(self, agent="pi"):
        raw = self.lua(
            """
            local id = ...
            local manager = require("ade.controller").state().view.agent_manager_service
            if not manager then return nil end
            for _, row in ipairs(manager:list()) do
              if row.id == id then
                local task = row.task
                local outcome = row.outcome
                return {
                  status = row.status,
                  source = row.source,
                  command = row.command,
                  args = row.args,
                  install = row.install,
                  error = row.error,
                  latest = row.latest,
                  outdated = row.outdated,
                  task = task and {
                    phase = task.phase,
                    action = task.action,
                    foreign = task.foreign == true,
                  } or nil,
                  outcome = outcome and {
                    phase = outcome.phase,
                    message = outcome.message,
                    version = outcome.version,
                  } or nil,
                }
              end
            end
            return nil
            """,
            agent,
        )
        return normalize(raw)

    def clear_outcome(self, agent="pi"):
        self.lua(
            """
            local id = ...
            local manager = require("ade.controller").state().view.agent_manager_service
            if manager and manager.outcome then manager.outcome[id] = nil end
            return true
            """,
            agent,
        )

    def wait_outcome(self, agent="pi", timeout=WAIT):
        def check():
            row = self.manager_row(agent)
            if not row or not row.get("outcome"):
                return None
            return row

        return wait_until(check, f"{self.label} {agent} outcome", timeout)

    def store_state(self, agent="pi"):
        raw = self.lua(
            """
            local agent, root = ...
            local store = require("ade.manager.store").new({ root = function() return root end })
            local state = store:state(agent)
            return {
              status = state.status,
              install_id = state.install_id,
              version = state.install and state.install.version,
              package = state.install and state.install.package,
              entry = state.entry,
              dir = state.dir,
              error = state.error,
              releases = store:list_install_ids(agent),
            }
            """,
            agent,
            str(self.manager_root),
        )
        return normalize(raw)

    def resolve_managed(self, agent="pi"):
        raw = self.lua(
            """
            local agent, root = ...
            local cfg = require("ade.config").effective()
            local store = require("ade.manager.store").new({ root = function() return root end })
            local spec, err = require("ade.manager.resolve").resolve(cfg, agent, cfg.launch_origin, store)
            if not spec then return { error = err } end
            return { command = spec.command, args = spec.args, source = spec.source,
                     install_id = spec.install_id, version = spec.version }
            """,
            agent,
            str(self.manager_root),
        )
        return normalize(raw)

    def command(self, text):
        self.nvim.command(text)

    def agents_lines(self):
        raw = self.lua(
            """
            local manager = require("ade.controller").state().view.agent_manager
            if not manager then return {} end
            manager:open()
            manager:refresh()
            return vim.api.nvim_buf_get_lines(manager.buf, 0, -1, false)
            """
        )
        return normalize(raw or [])

    def connect(self):
        self.lua("require('ade.controller').connect(); return true")
        wait_until(
            lambda: (self.state().get("phase") == "ready" and (self.state().get("session") or {}).get("id")),
            f"{self.label} agent ready",
        )

    def state(self):
        raw = self.lua(
            """
            local st = require("ade.controller").state()
            return {
              phase = st.conn.phase,
              session = st.session and { id = st.session.id, status = st.session.status } or nil,
              connection = st.connection,
            }
            """
        )
        return normalize(raw)

    def disconnect(self):
        self.lua("require('ade.controller').disconnect(); return true")

    def quit(self):
        if not self.nvim:
            return
        try:
            self.nvim.command("qa!")
        except Exception:
            pass
        try:
            self.nvim.close()
        except Exception:
            pass
        self.nvim = None
        if self.proc and self.proc.poll() is None:
            try:
                self.proc.wait(timeout=10)
            except subprocess.TimeoutExpired:
                self.proc.kill()
                self.proc.wait(timeout=10)

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
                notes = self.notifications()
            except Exception:
                pass
        return (
            f"--- {self.label} ({self.backend}) notifications ---\n"
            + "\n".join(notes[-30:])
            + f"\n--- {self.label} log tail ---\n"
            + "\n".join(text.splitlines()[-40:])
        )


def lock_owner(case, agent="pi"):
    path = case.manager_root / ".locks" / agent / "owner.json"
    if not path.exists():
        return None
    try:
        return json.loads(path.read_text())
    except (OSError, ValueError):
        return {"unreadable": True}


def leases(case, agent="pi"):
    directory = case.manager_root / ".leases" / agent
    if not directory.is_dir():
        return []
    out = []
    for path in sorted(directory.glob("lease-*.json")):
        try:
            out.append((path.name, json.loads(path.read_text())))
        except (OSError, ValueError):
            out.append((path.name, {"unreadable": True}))
    return out


def service_alive(case):
    return bool(case.service_pids())


def write_mode(editor_env_file, mode):
    Path(editor_env_file).write_text(mode)


def scenario_install_from_service(case):
    """1. Service install is visible to a direct-mode editor and resolves there."""
    service = case.editor("a", "service")
    service.command("Ade install pi")
    row = service.wait_outcome()
    assert row["outcome"]["phase"] == "done", row
    assert any("pi 1.2.3 installed" in line for line in service.notifications()), service.notifications()
    installed = wait_until(lambda: service.store_state()["status"] == "installed" and service.store_state(), "installed")
    install_id = installed["install_id"]

    direct = case.editor("b", "direct")
    state = wait_until(lambda: direct.store_state()["status"] == "installed" and direct.store_state(), "direct view")
    assert state["install_id"] == install_id, (installed, state)
    assert state["version"] == "1.2.3", state
    spec = direct.resolve_managed()
    assert spec["source"] == "managed", spec
    assert spec["command"] == "python3", spec
    assert spec["args"] == [state["entry"]], spec
    assert spec["install_id"] == install_id, spec
    assert lock_owner(case) is None, lock_owner(case)
    assert leases(case) == [], leases(case)
    return "installed, visible and resolvable in direct mode"


def scenario_two_writers(case):
    """2. Cross-process lock: direct holds it, then service; and the reverse."""
    forward = case.dir / "forward"
    reverse = case.dir / "reverse"
    os.makedirs(forward)
    os.makedirs(reverse)

    direct = case.editor("d1", "direct", manager_root=forward,
                         env_extra={"FAKE_NPM_MODE": "slow", "FAKE_NPM_SLEEP": "3"})
    direct.command("Ade install pi 1.2.3")
    wait_until(lambda: (forward / ".locks/pi/owner.json").exists(), "direct lock")
    service = case.editor("s1", "service", manager_root=forward)
    service.command("Ade install pi")
    row = service.wait_outcome()
    assert row["outcome"]["phase"] == "failed", row
    message = row["outcome"].get("message") or ""
    assert "another instance is using this agent" in message, message
    direct.wait_outcome()

    service2 = case.editor("s2", "service", manager_root=reverse,
                           env_extra={"FAKE_NPM_MODE": "slow", "FAKE_NPM_SLEEP": "3"})
    service2.command("Ade install pi 1.2.3")
    wait_until(lambda: (reverse / ".locks/pi/owner.json").exists(), "service lock")
    direct2 = case.editor("d2", "direct", manager_root=reverse)
    direct2.command("Ade install pi")
    row = direct2.wait_outcome()
    assert row["outcome"]["phase"] == "failed", row
    text = " ".join(direct2.notifications())
    assert "another instance is using this agent" in text, text
    service2.wait_outcome()
    return "both directions refused"


def scenario_service_lease_blocks_direct_uninstall(case):
    """3. A service-run release is leased by the service; uninstall waits for stop."""
    service = case.editor("s", "service", agent="pi")
    service.command("Ade install pi")
    service.wait_outcome()
    service.connect()
    lease = wait_until(lambda: leases(case) or None, "service lease")
    assert any(name.startswith("lease-") for name, _ in lease), lease
    assert lease[0][1]["host"] and lease[0][1]["installId"], lease

    direct = case.editor("d", "direct")
    direct.command("Ade uninstall pi")
    row = direct.wait_outcome()
    assert row["outcome"]["phase"] == "failed", row
    assert "cannot remove pi" in (row["outcome"].get("message") or ""), row

    service.quit()
    assert service_alive(case), "the service must outlive the Neovim that started the agent"
    assert leases(case), "the service lease must survive the front end exiting"
    direct.clear_outcome()
    direct.command("Ade uninstall pi")
    row = direct.wait_outcome()
    assert row["outcome"]["phase"] == "failed", row
    assert "cannot remove pi" in (row["outcome"].get("message") or ""), row

    direct.command("Ade service stop")
    wait_until(lambda: not service_alive(case), "service stopped", timeout=15)
    wait_until(lambda: not leases(case), "lease removed")
    direct.clear_outcome()
    direct.command("Ade uninstall pi")
    row = direct.wait_outcome()
    assert row["outcome"]["phase"] == "removed", row
    assert direct.store_state()["status"] == "not_installed"
    return "lease blocked direct uninstall until stop"


def scenario_install_survives_editor_exit(case):
    """4. An install started by a Neovim continues in the service after it exits."""
    editor = case.editor("a", "service", env_extra={"FAKE_NPM_MODE": "slow", "FAKE_NPM_SLEEP": "3"})
    editor.command("Ade install pi 1.2.3")
    wait_until(lambda: (case.manager_root / ".locks/pi/owner.json").exists(), "install lock")
    wait_until(
        lambda: any(p.name.startswith("v1.2.3-") for p in (case.manager_root / "pi" / "releases").glob("*")),
        "release directory",
    )
    editor.quit()
    newcomer = case.editor("b", "service")
    state = wait_until(
        lambda: newcomer.store_state()["status"] == "installed" and newcomer.store_state(),
        "the install to finish without its editor",
        timeout=25,
    )
    assert state["version"] == "1.2.3", state
    assert lock_owner(case) is None, lock_owner(case)
    return "finished in the service after its editor exited"


def scenario_cancel_from_window(case):
    """5. `x` in :Ade agents cancels a slow service install."""
    mode_file = case.dir / "npm-mode"
    write_mode(mode_file, "daemon")
    child_pid = case.dir / "npm-child.pid"
    child_ready = case.dir / "npm-child.ready"
    editor = case.editor(
        "a",
        "service",
        env_extra={
            "FAKE_NPM_MODE_FILE": str(mode_file),
            "FAKE_NPM_SLEEP": "30",
            "FAKE_NPM_CHILD_PID": str(child_pid),
            "FAKE_NPM_CHILD_READY": str(child_ready),
        },
    )
    editor.command("Ade install pi 1.2.3")
    wait_until(lambda: child_pid.exists() and child_ready.exists(), "npm child")
    pid = int(child_pid.read_text().strip())
    wait_until(lambda: (editor.manager_row() or {}).get("task"), "manager task")
    editor.lua(
        """
        local manager = require("ade.controller").state().view.agent_manager
        manager:open()
        manager:refresh()
        local line
        local lines = vim.api.nvim_buf_get_lines(manager.buf, 0, -1, false)
        for index = 1, #lines do
          if manager.ids and manager.ids[index] == "pi" then line = index break end
        end
        assert(line, "pi row not found")
        vim.api.nvim_win_set_cursor(manager.win, { line, 0 })
        return true
        """
    )
    editor.nvim.input("x")
    row = editor.wait_outcome()
    assert row["outcome"]["phase"] == "cancelled", row
    releases = editor.store_state()["releases"]
    assert releases == [], releases
    assert lock_owner(case) is None, lock_owner(case)
    wait_until(lambda: not pid_alive(pid), "npm child to exit")
    wait_until(lambda: (editor.manager_row() or {}).get("task") is None, "task cleared")

    write_mode(mode_file, "ok")
    editor.clear_outcome()
    editor.command("Ade install pi 1.2.3")
    row = editor.wait_outcome()
    assert row["outcome"]["phase"] == "done", row
    assert editor.store_state()["status"] == "installed"
    return "cancelled, cleaned, reinstalled"


def pid_alive(pid):
    try:
        os.kill(pid, 0)
        return True
    except OSError:
        return False


def scenario_leased_release_survives_update(case):
    """6. Prune keeps a release leased by the direct backend; a later Lua update cleans it."""
    direct = case.editor("d", "direct", agent="pi", env_extra={"FAKE_NPM_VIEW_VERSION": "2.0.1"})
    direct.command("Ade install pi 1.2.3")
    direct.wait_outcome()
    direct.connect()
    lease = wait_until(lambda: leases(case) or None, "direct lease")
    old_id = direct.store_state()["install_id"]
    assert any(item["installId"] == old_id for _, item in lease), lease

    service = case.editor("s", "service", env_extra={"FAKE_NPM_VIEW_VERSION": "2.0.1"})
    service.command("Ade install pi 2.0.0")
    row = service.wait_outcome()
    assert row["outcome"]["phase"] == "done", row
    state = service.store_state()
    assert state["version"] == "2.0.0", state
    assert old_id in state["releases"], state
    assert leases(case), "the direct lease still protects the old release"

    direct.disconnect()
    wait_until(lambda: not leases(case), "direct lease to disappear")
    direct.clear_outcome()
    direct.command("Ade update pi")
    row = direct.wait_outcome()
    assert row["outcome"]["phase"] == "done", row
    state = wait_until(
        lambda: direct.store_state()["version"] == "2.0.1" and direct.store_state(), "direct update"
    )
    assert old_id not in state["releases"], state
    assert len(state["releases"]) == 1, state
    return "kept the leased release, pruned it after the lease ended"


def scenario_foreign_job(case):
    """7. A second service-mode Neovim sees another front end's job as busy."""
    watcher = case.editor("b", "service")
    watcher.lua(
        """
        local manager = require("ade.controller").state().view.agent_manager_service
        manager:installer()
        return true
        """
    )
    watcher.command("Ade agents")
    writer = case.editor("a", "service", env_extra={"FAKE_NPM_MODE": "slow", "FAKE_NPM_SLEEP": "3"})
    writer.command("Ade install pi 1.2.3")
    foreign = wait_until(
        lambda: (watcher.manager_row() or {}).get("task", {}).get("foreign") and watcher.manager_row(),
        "foreign task",
    )
    assert foreign["task"]["foreign"] is True, foreign
    lines = watcher.agents_lines()
    assert any("pi" in line and ("install" in line or "update" in line) for line in lines), lines
    writer.wait_outcome()
    wait_until(lambda: (watcher.manager_row() or {}).get("task") is None, "foreign task cleared")
    assert watcher.manager_row()["status"] == "installed"
    return "foreign job shown and cleared"


PROXY = r'''#!/usr/bin/env python3
"""A service wrapper whose hello does not advertise "install"."""
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
                        result["features"] = [f for f in result["features"] if f != "install"]
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


def scenario_missing_install_feature(case):
    """8. A service without the feature falls back to the Lua installer."""
    proxy = case.dir / "install_proxy.py"
    proxy.write_text(PROXY.format(real=str(SERVICE)))
    proxy.chmod(0o755)
    editor = case.editor("a", "service", service_path=proxy)
    editor.lua(
        """
        local connection = require("ade.service.connection").shared()
        local ready = false
        connection:ensure(function(ok) ready = ok == true end)
        vim.wait(10000, function() return ready end, 10)
        return { ready = ready, install = connection:has_feature("install") }
        """
    )
    info = normalize(
        editor.lua(
            """
            local connection = require("ade.service.connection").shared()
            return { install = connection:has_feature("install") }
            """
        )
    )
    assert info["install"] is False, info
    editor.command("Ade install pi 1.2.3")
    row = editor.wait_outcome()
    assert row["outcome"]["phase"] == "done", row
    state = editor.store_state()
    assert state["status"] == "installed", state
    assert state["version"] == "1.2.3", state
    assert lock_owner(case) is None, lock_owner(case)
    return "Lua fallback installed without the feature"


SCENARIOS = [
    ("1 service install visible to direct", scenario_install_from_service),
    ("2 cross-process lock both directions", scenario_two_writers),
    ("3 service lease blocks direct uninstall", scenario_service_lease_blocks_direct_uninstall),
    ("4 install survives editor exit", scenario_install_survives_editor_exit),
    ("5 cancel from :Ade agents", scenario_cancel_from_window),
    ("6 leased release survives update", scenario_leased_release_survives_update),
    ("7 foreign job in second Neovim", scenario_foreign_job),
    ("8 service without install feature", scenario_missing_install_feature),
]


def main():
    if not SERVICE.exists():
        sys.exit(f"missing service binary: {SERVICE}")
    only = os.environ.get("ADE_E2E_ONLY", "")
    failures = []
    for label, fn in SCENARIOS:
        if only and only not in label:
            continue
        case = Case(label.split()[0])
        try:
            detail = fn(case)
            print(f"ok: {label}: {detail}", flush=True)
        except Exception as exc:  # noqa: BLE001 - a failure is a test result
            failures.append(label)
            print(f"FAIL: {label}: {exc}", flush=True)
            traceback.print_exc()
            print(case.report(), flush=True)
        finally:
            case.cleanup()
            leftover = case.leftover_processes()
            if leftover:
                print(f"FAIL: {label}: leftover processes: {leftover}", flush=True)
                failures.append(label + " cleanup")
            if case.dir.exists():
                print(f"FAIL: {label}: temporary directory was not removed: {case.dir}", flush=True)
                failures.append(label + " cleanup")
    if failures:
        print(f"{len(failures)} scenario(s) failed: {', '.join(failures)}")
        return 1
    print("all managed-install scenarios passed")
    return 0


if __name__ == "__main__":
    sys.exit(main())
