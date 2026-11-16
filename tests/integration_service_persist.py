"""Persistence end-to-end tests for the service backend.

The promise of S1a is: the agent runs inside nvim_ade_server, keeps working after
Neovim exits, and a later Neovim attaches to the same instance. Every existing
integration script uses a single Neovim process, so none of them can prove it.
This script does, with the real service binary and tests/mock_agent.py.

Run:
    ADE_TEST_SERVICE_BIN=/abs/path/to/nvim_ade_server \\
        python3 tests/integration_service_persist.py

Without that variable the script looks in service/target/release and
service/target/debug; when neither exists it prints `SKIP: no service binary`
and exits 0.

Each scenario starts from a clean slate (fresh temporary directory, no service,
no agent), prints `ok: <what was proved>` and cleans up after itself. All paths
live under one temporary directory; nothing touches ~/.local.

The test drives Neovim through pynvim: a headless `nvim --headless --listen
<socket> -u tests/minimal_init.lua` per front end, and `exec_lua` for chat
(`require("ade.controller").submit`). Waiting is always a bounded poll (20 s),
never a fixed sleep; on timeout the current instance list, both editors' recent
messages and the last 50 lines of the service log are printed.
"""

import json
import logging
import os
import select
import shutil
import signal
import socket
import subprocess
import sys
import tempfile
import time
import traceback
from pathlib import Path

logging.disable(logging.CRITICAL)

try:
    import pynvim
except ImportError:  # pragma: no cover - optional test dependency
    print("SKIP: pynvim is not installed")
    sys.exit(0)


ROOT = str(Path(__file__).resolve().parent.parent)
MOCK_AGENT = str(Path(ROOT) / "tests" / "mock_agent.py")

# Imported by path so the script works when invoked from any directory.
sys.path.insert(0, str(Path(__file__).resolve().parent))
import persist_helpers as helpers  # noqa: E402
MINIMAL_INIT = str(Path(ROOT) / "tests" / "minimal_init.lua")
WAIT = 20.0

failures = []
# Cases still open, so a signal or an unexpected exception can clean them up.
active_cases = []
# Our signal handlers, so they can be reinstalled after pynvim replaces them.
_our_handlers = {}


def _cleanup_active_cases():
    """Close every open case, ignoring a second signal while doing so."""
    # A second Ctrl-C/SIGTERM during cleanup must not kill the process halfway
    # through, which would leave exactly the processes this function removes.
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
                case.close()
            except Exception:  # noqa: BLE001 - cleanup must not mask the real error
                pass
    finally:
        for signum, handler in previous.items():
            try:
                signal.signal(signum, handler)
            except (ValueError, OSError):
                pass


def _install_signal_handlers():
    """Clean up on Ctrl-C / SIGTERM instead of leaking service and agent processes.

    pynvim's event loop installs its own SIGINT/SIGTERM handler for the duration
    of every call and restores `SIG_DFL` afterwards, so a handler installed once
    is gone after the first `exec_lua`. `ensure_signal_handlers()` puts ours back
    after each editor interaction; while pynvim holds the signal it turns it into
    an exception out of the call, which `check()` catches and cleans up from.
    """

    def handler(signum, _frame):
        print(f"\ninterrupted by signal {signum}: cleaning up", flush=True)
        _cleanup_active_cases()
        # Re-raise the default behaviour so the exit status is still a signal.
        signal.signal(signum, signal.SIG_DFL)
        os.kill(os.getpid(), signum)

    for signum in (signal.SIGINT, signal.SIGTERM, signal.SIGHUP):
        try:
            signal.signal(signum, handler)
            _our_handlers[signum] = handler
        except (ValueError, OSError):
            pass


def ensure_signal_handlers():
    """Reinstall our handlers if pynvim (or anything else) replaced them."""
    for signum, handler in _our_handlers.items():
        try:
            if signal.getsignal(signum) is not handler:
                signal.signal(signum, handler)
        except (ValueError, OSError):
            pass


# ---------------------------------------------------------------------------
# service binary
# ---------------------------------------------------------------------------


def find_service_binary():
    explicit = os.environ.get("ADE_TEST_SERVICE_BIN")
    if explicit:
        path = os.path.abspath(os.path.expanduser(explicit))
        if os.path.isfile(path) and os.access(path, os.X_OK):
            return path
        raise SystemExit(f"ADE_TEST_SERVICE_BIN is not an executable file: {path}")
    for profile in ("release", "debug"):
        candidate = Path(ROOT) / "service" / "target" / profile / "nvim_ade_server"
        if candidate.is_file() and os.access(candidate, os.X_OK):
            return str(candidate)
    print("SKIP: no service binary")
    sys.exit(0)


# ---------------------------------------------------------------------------
# processes
# ---------------------------------------------------------------------------


def pid_alive(pid):
    """True while `pid` exists and is not a zombie."""
    if not pid:
        return False
    try:
        with open(f"/proc/{pid}/stat", encoding="utf-8") as handle:
            fields = handle.read().split()
    except OSError:
        return False
    # Field 3 is the state; `Z` is a zombie, which has exited already.
    return len(fields) > 2 and fields[2] != "Z"


def wait_until(condition, timeout=WAIT, interval=0.05, label="condition"):
    """Poll `condition` until it returns a non-`None` value, or raise.

    A truthiness check would silently never accept a real result: an empty list
    ("no instances left") and `0` are both meaningful.
    """
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        try:
            value = condition()
        except Exception:  # a race while a process is starting or dying
            value = None
        if value is not None:
            return value
        time.sleep(interval)
    raise TimeoutError(f"timed out after {timeout:g}s waiting for {label}")


def wait_gone(pid, timeout=WAIT, label="process to exit"):
    return wait_until(lambda: not pid_alive(pid), timeout, 0.05, label)


def _cmdline(pid):
    try:
        return Path(f"/proc/{pid}/cmdline").read_bytes().replace(b"\0", b" ").decode(
            "utf-8", "replace"
        )
    except OSError:
        return ""


def _env_of(pid):
    try:
        return Path(f"/proc/{pid}/environ").read_bytes().decode("utf-8", "replace")
    except OSError:
        return ""


def _all_pids():
    for entry in Path("/proc").iterdir():
        if entry.name.isdigit():
            yield int(entry.name)


def pids_matching(pattern):
    """PIDs whose command line contains `pattern` (excluding this script)."""
    out = []
    for entry in Path("/proc").iterdir():
        if not entry.name.isdigit():
            continue
        pid = int(entry.name)
        if pid == os.getpid():
            continue
        try:
            cmdline = (entry / "cmdline").read_bytes().replace(b"\0", b" ").decode(
                "utf-8", "replace"
            )
        except OSError:
            continue
        if pattern in cmdline:
            out.append(pid)
    return out


# ---------------------------------------------------------------------------
# a service invocation without Neovim (scenario 7 starts it itself)
# ---------------------------------------------------------------------------


class RawService:
    """A `nvim_ade_server serve` process started directly, plus one connection.

    Scenario 7 needs a service whose idle timeout is shorter than the plugin's
    minimum (60 s), which is only reachable through the command line, so it
    talks to the service without going through the plugin first.
    """

    def __init__(self, binary, directory, idle_timeout, env_extra=None):
        self.directory = directory
        self.proc = None
        self.sock = None
        self.next_id = 0
        self.binary = binary
        self.idle_timeout = idle_timeout
        self.env_extra = env_extra or {}

    def start(self):
        env = isolated_env(self.directory)
        env.update(self.env_extra)
        self.proc = subprocess.Popen(
            [self.binary, "serve", "--idle-timeout", str(self.idle_timeout)],
            env=env,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
        )
        line = self.proc.stdout.readline()
        if not line:
            raise RuntimeError(f"the service printed no status line: {self.proc.stderr.read()}")
        status = json.loads(line)
        if status.get("status") not in ("ready", "already_running"):
            raise RuntimeError(f"the service did not start: {status}")
        return status

    def connect(self):
        path = os.path.join(self.directory, "server", "nvim_ade_server.sock")
        token_path = os.path.join(self.directory, "server", "nvim_ade_server.token")
        self.sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.sock.connect(path)
        self.buffer = b""
        token = Path(token_path).read_text(encoding="utf-8").strip()
        reply = self.request(
            "hello",
            {
                "token": token,
                "client": "ade.nvim",
                "client_version": "0.1.0",
                "api_version": 2,
            },
        )
        return reply

    def request(self, method, params, timeout=WAIT):
        self.next_id += 1
        frame = {
            "jsonrpc": "2.0",
            "id": self.next_id,
            "method": method,
            "params": params,
        }
        self.sock.sendall((json.dumps(frame) + "\n").encode())
        deadline = time.monotonic() + timeout
        while True:
            message = self._read_message(deadline)
            if message is None:
                raise TimeoutError(f"{method} got no reply")
            if message.get("id") == self.next_id:
                if "error" in message:
                    raise RuntimeError(f"{method} failed: {message['error']}")
                return message.get("result")

    def notify(self, method, params):
        frame = {"jsonrpc": "2.0", "method": method, "params": params}
        self.sock.sendall((json.dumps(frame) + "\n").encode())

    def _read_message(self, deadline):
        while True:
            while b"\n" in self.buffer:
                raw, self.buffer = self.buffer.split(b"\n", 1)
                if raw.strip():
                    return json.loads(raw)
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                return None
            readable, _, _ = select.select([self.sock], [], [], remaining)
            if not readable:
                return None
            chunk = self.sock.recv(1 << 16)
            if not chunk:
                return None
            self.buffer += chunk

    def close(self):
        if self.sock:
            try:
                self.sock.close()
            except OSError:
                pass
            self.sock = None

    def stop(self):
        self.close()
        if self.proc and self.proc.poll() is None:
            self.proc.terminate()
            try:
                self.proc.wait(timeout=10)
            except subprocess.TimeoutExpired:
                self.proc.kill()
                self.proc.wait(timeout=10)


def isolated_env(directory):
    """The only environment any test process may resolve paths from."""
    env = {
        "NVIM_ADE_SERVER_DIR": os.path.join(directory, "server"),
        "XDG_DATA_HOME": os.path.join(directory, "data"),
        "XDG_STATE_HOME": os.path.join(directory, "state"),
        "XDG_CACHE_HOME": os.path.join(directory, "cache"),
        "HOME": os.path.join(directory, "home"),
    }
    for key in env:
        os.makedirs(env[key], exist_ok=True)
    return env


# ---------------------------------------------------------------------------
# one headless Neovim driven over pynvim
# ---------------------------------------------------------------------------


class Editor:
    """A headless Neovim with the plugin loaded and configured for the service."""

    def __init__(self, label, case_dir, binary, idle_timeout=60, cwd=ROOT):
        self.label = label
        self.case_dir = case_dir
        self.binary = binary
        self.idle_timeout = idle_timeout
        self.cwd = cwd
        self.proc = None
        self.nvim = None
        self.socket = os.path.join(case_dir, f"{label}.nvim.sock")
        self.log = os.path.join(case_dir, f"{label}.nvim.log")
        self.messages = []
        self._log_handle = None

    def start(self, service_env=None, service=None, idle_timeout=None):
        env = dict(os.environ)
        env.update(isolated_env(self.case_dir))
        # `minimal_init.lua` wires a service backend from these when they are set
        # in the environment (the single-process integration scripts use them).
        # Setting them here would make every editor share one service directory
        # instead of this case's, so the scenario must own the configuration.
        for key in ("ADE_TEST_BACKEND", "ADE_TEST_SERVICE_BIN"):
            env.pop(key, None)
        if service_env:
            env.update(service_env)
        argv = [
            "nvim",
            "--headless",
            "--listen",
            self.socket,
            "-u",
            MINIMAL_INIT,
        ]
        self._log_handle = open(self.log, "wb")
        self.proc = subprocess.Popen(
            argv,
            cwd=self.cwd,
            env=env,
            stdin=subprocess.DEVNULL,
            stdout=self._log_handle,
            stderr=subprocess.STDOUT,
        )
        # `--listen` creates the socket asynchronously; attaching before it
        # exists fails, so poll for the file and retry the handshake briefly.
        wait_until(lambda: os.path.exists(self.socket), WAIT, 0.02, f"{self.label} socket")

        def attach():
            try:
                return pynvim.attach("socket", path=self.socket)
            except (OSError, ConnectionError):
                return None

        self.nvim = wait_until(attach, WAIT, 0.05, f"{self.label} to accept a connection")
        self.configure(idle_timeout=idle_timeout, service=service)

    def configure(self, idle_timeout=None, service=None):
        """Call `require("ade").setup` with the scenario's service settings.

        `service` merges over the defaults, so scenario 12 can turn the event log
        off and scenario 15 can cap the reconnect attempts without repeating the
        whole table.
        """
        # The plugin's minimum is 60 s; scenario 2 needs a shorter one, which the
        # service takes from NVIM_ADE_SERVER_IDLE_TIMEOUT_SECS (see its start()).
        timeout = idle_timeout if idle_timeout is not None else self.idle_timeout
        service_opts = {
            "path": self.binary,
            "keep_alive": True,
            "idle_timeout": timeout,
        }
        service_opts.update(service or {})
        opts = {
            "backend": "service",
            "service": service_opts,
            "agent": "opencode",
            "agents": {
                "opencode": {
                    "command": "python3",
                    "args": [MOCK_AGENT],
                }
            },
            # No pickers in a headless editor: permissions arrive as events the
            # test answers explicitly, which is what scenarios 3 and 8 need.
            "permissions": {"prompt": "native", "show_details": False},
            "log": {"level": "info"},
        }
        self.lua(
            """
            local opts = ...
            require("ade").setup(opts)
            """,
            opts,
        )

    # -- lua helpers --------------------------------------------------------

    def lua(self, code, *args):
        try:
            return self.nvim.exec_lua(code, *args)
        finally:
            # pynvim installs its own SIGINT/SIGTERM handler for the duration of
            # a call and restores SIG_DFL afterwards; put ours back so an
            # interrupt still cleans up instead of killing the process outright.
            ensure_signal_handlers()

    def connect(self):
        self.lua("require('ade.controller').connect()")
        self.wait_state(lambda st: st.get("connection") == "ready", "session ready")
        self.wait_state(
            lambda st: st.get("session") is not None and bool(st["session"].get("id")),
            "session created",
        )

    def state(self):
        raw = self.lua(
            """
            local controller = require("ade.controller")
            local st = controller.state()
            return {
              connection = st.connection,
              phase = st.conn.phase,
              session = st.session and { id = st.session.id, status = st.session.status },
              blocks = st.session and st.session.blocks or nil,
              service_message = st.view.service_message,
            }
            """
        )
        # pynvim turns a Lua table into a dict-like object; JSON round-trip makes
        # the assertions below plain Python.
        return normalize(raw)

    def wait_state(self, predicate, label="state"):
        def check():
            st = self.state()
            return st if predicate(st) else None

        return wait_until(check, WAIT, 0.05, label)

    def transcript(self):
        raw = self.lua(
            """
            local lines = {}
            local st = require("ade.controller").state()
            if st.session then
              for _, block in ipairs(st.session.blocks or {}) do
                lines[#lines + 1] = { kind = block.kind, text = block.text or "" }
              end
            end
            return lines
            """
        )
        return normalize(raw or [])

    def submit(self, text):
        self.lua("require('ade.controller').submit(...)", text)
        self.messages.append(("submit", text, time.monotonic()))

    def wait_reply(self, needle, timeout=WAIT):
        def check():
            for block in self.transcript():
                if block.get("kind") == "agent" and needle in (block.get("text") or ""):
                    return block
            return None

        return wait_until(check, timeout, 0.05, f"reply containing {needle!r} in {self.label}")

    def wait_turn_idle(self, timeout=WAIT):
        return self.wait_state(
            lambda st: (st.get("session") or {}).get("status") == "idle", "turn to finish"
        )

    def instances(self, timeout=WAIT):
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

    def wait_instances(self, predicate, label="instance list"):
        def check():
            list_ = self.instances()
            return list_ if predicate(list_) else None

        return wait_until(check, WAIT, 0.05, f"{label} in {self.label}")

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

    def attach_info(self):
        """What `agent.attach` reported: `created`, `sessions` (PROTOCOL.md 3.2)."""
        raw = self.lua(
            """
            local client = require("ade.controller").state().conn.client
            if not client then
              return nil
            end
            local sessions = {}
            for _, entry in ipairs(client.sessions or {}) do
              sessions[#sessions + 1] = {
                session_id = entry.sessionId,
                id = entry.id,
                cwd = entry.cwd,
                running = entry.running,
                updated_at = entry.updated_at,
              }
            end
            return {
              created = client.created,
              sessions = sessions,
              instance = client.proc and client.proc.instance,
            }
            """
        )
        return normalize(raw)

    def reconnect_status(self):
        """The transient "reconnecting (n/m)" text, or nil when not retrying."""
        return self.lua(
            "return require('ade.controller').state().conn.reconnect_status"
        )

    def reconnector_state(self):
        raw = self.lua(
            """
            local r = require("ade.controller").state().conn.reconnector
            if not r then
              return nil
            end
            return { running = r.running, attempt = r.attempt }
            """
        )
        return normalize(raw)

    def service_connection_listeners(self):
        """Who subscribes to `__disconnected` on the real service connection.

        `S.conn.service` is the application connection; the transport, the
        reconnect loop and the panel all subscribe on the service connection it
        wraps, which is what `service_connection()` returns. Returns
        `{methods: [...], channels: {method: [channel ids]}}`.
        """
        raw = self.lua(
            """
            local app = require("ade.controller").state().conn.service
            if type(app.service_connection) ~= "function" then
              return { methods = {}, channels = {} }
            end
            local real = app:service_connection()
            local methods, channels = {}, {}
            for method, list in pairs(real.listeners or {}) do
              methods[#methods + 1] = method
              local ids = {}
              for id in pairs(list) do ids[#ids + 1] = id end
              table.sort(ids)
              channels[method] = ids
            end
            table.sort(methods)
            return { methods = methods, channels = channels }
            """
        )
        return normalize(raw or {"methods": [], "channels": {}})

    def session_status(self):
        return (self.state().get("session") or {}).get("status")

    def answer_permission(self, option_id="allow"):
        self.lua(
            """
            local option = ...
            local st = require("ade.controller").state()
            local items = st.view.interactions:pending()
            assert(#items > 0, "no pending permission to answer")
            st.view.interactions:answer(items[1].id, {
              outcome = { outcome = "selected", optionId = option },
            })
            """,
            option_id,
        )

    def disconnect(self):
        self.lua("require('ade.controller').disconnect()")

    # -- notification capture ------------------------------------------------

    def capture_notifications(self):
        """Replace `vim.notify` with a recorder and return the list.

        `:Ade service ...` reports through `vim.notify`, so this is what the
        user actually sees. The list is a Lua table the test reads back; each
        entry keeps the level so a warning is distinguishable from info.
        """
        self.lua(
            """
            _G.ade_test_notifications = {}
            vim.notify = function(message, level)
              _G.ade_test_notifications[#_G.ade_test_notifications + 1] = {
                message = tostring(message),
                level = level or vim.log.levels.INFO,
              }
            end
            """
        )

    def notifications(self):
        raw = self.lua(
            """
            local out = {}
            for _, entry in ipairs(_G.ade_test_notifications or {}) do
              out[#out + 1] = { message = entry.message, level = entry.level }
            end
            return out
            """
        )
        return normalize(raw or [])

    def clear_notifications(self):
        self.lua("_G.ade_test_notifications = {}")

    def notify_lines(self):
        return [entry["message"] for entry in self.notifications()]

    def run_command(self, command):
        """Run an Ex command and return what it notified."""
        self.clear_notifications()
        self.lua("vim.cmd(...)", command)
        return self.notify_lines()

    def wait_notifications(self, predicate, label="notification", timeout=WAIT):
        """Poll the captured notifications until `predicate(list)` holds.

        The failure message carries every line seen so far: these commands report
        their problems through `vim.notify`, so the list is the diagnosis.
        """

        def check():
            lines = self.notify_lines()
            return lines if predicate(lines) else None

        try:
            return wait_until(check, timeout, 0.05, label)
        except TimeoutError:
            raise AssertionError(
                f"{label}: only got notifications {self.notify_lines()!r}"
            ) from None

    def service_status(self):
        raw = self.lua(
            """
            local Status = require("ade.service.status")
            local cfg = require("ade.config").effective()
            local st = Status.collect({ config = cfg })
            return {
              running = st.running,
              reachable = st.reachable,
              socket = st.socket,
              dir = st.dir,
              instances = st.instances,
            }
            """
        )
        return normalize(raw)

    def wait_service_reachable(self, timeout=WAIT):
        """Poll until the socket accepts a connection (`:Ade service start`)."""

        def check():
            return self.service_status().get("reachable") is True

        try:
            wait_until(check, timeout, 0.05, "the restarted service to be reachable")
            return True
        except TimeoutError:
            return False

    def quit(self):
        """`:qa!`, i.e. VimLeavePre then exit -- the plugin's leave path."""
        if not self.nvim:
            return
        try:
            self.nvim.command("qa!")
        except Exception:
            pass
        finally:
            ensure_signal_handlers()
        try:
            self.proc.wait(timeout=15)
        except subprocess.TimeoutExpired:
            self.proc.kill()
            self.proc.wait(timeout=10)
        self.detach()

    def kill(self):
        """`kill -9`: no VimLeavePre at all."""
        ensure_signal_handlers()
        if not self.proc:
            return
        try:
            self.proc.send_signal(signal.SIGKILL)
        except ProcessLookupError:
            pass
        try:
            self.proc.wait(timeout=10)
        except subprocess.TimeoutExpired:
            pass
        self.detach()

    def detach(self):
        if self.nvim:
            try:
                self.nvim.close()
            except Exception:
                pass
            self.nvim = None
        if self._log_handle:
            try:
                self._log_handle.close()
            except OSError:
                pass
            self._log_handle = None

    def recent_output(self, lines=40):
        try:
            text = Path(self.log).read_text(encoding="utf-8", errors="replace")
        except OSError:
            return f"{self.label}: <no output>"
        tail = text.splitlines()[-lines:]
        return f"--- {self.label} ({self.log}) ---\n" + "\n".join(tail)


def normalize(value):
    """pynvim's Lua tables into plain Python (via JSON, which it supports)."""
    if value is None:
        return None
    return json.loads(json.dumps(value, default=lambda o: o))


# ---------------------------------------------------------------------------
# service log
# ---------------------------------------------------------------------------


class ServiceLog:
    """Append-only capture of the service's stderr for failure reports."""

    def __init__(self, case_dir):
        self.path = os.path.join(case_dir, "service.log")

    def tail(self, lines=50):
        try:
            text = Path(self.path).read_text(encoding="utf-8", errors="replace")
        except OSError:
            return "<no service log>"
        return "\n".join(text.splitlines()[-lines:])


# ---------------------------------------------------------------------------
# scenario harness
# ---------------------------------------------------------------------------


class Case:
    """One scenario: a fresh directory, editors, and cleanup on every exit."""

    def __init__(self, name, binary):
        self.name = name
        self.binary = binary
        self.dir = tempfile.mkdtemp(prefix=f"ade-persist-{name}-")
        self.editors = []
        self.raw = []
        self.service_log = ServiceLog(self.dir)

    def editor(self, label, idle_timeout=60):
        editor = Editor(label, self.dir, self.binary, idle_timeout=idle_timeout)
        self.editors.append(editor)
        return editor

    def raw_service(self, idle_timeout, binary=None):
        """A service started by the test itself, without Neovim."""
        service = RawService(binary or self.binary, os.path.join(self.dir, "raw"), idle_timeout)
        os.makedirs(os.path.join(self.dir, "raw"), exist_ok=True)
        self.raw.append(service)
        return service

    def service_pid(self):
        """The pid of the service this case started (never anyone else's).

        Matching is by the process environment: `NVIM_ADE_SERVER_DIR` points at
        this case's directory, which no other service on the machine shares.
        Both the real binary and the scenario wrappers (a python script, a shell
        script) are matched through it, so a wrapped service is still found.
        """
        candidates = []
        for pid in pids_matching("nvim_ade_server"):
            if self._env_dir_of(pid) == os.path.join(self.dir, "server"):
                candidates.append((pid, _cmdline(pid)))
        # A wrapper also listens on the socket but does not have "nvim_ade_server"
        # in its command line; prefer the real service when both exist, since
        # killing it is what the scenario means by "kill the service".
        real = [pid for pid, line in candidates if "nvim_ade_server" in line]
        return (real or [pid for pid, _ in candidates] or [None])[0]

    @staticmethod
    def _env_dir_of(pid):
        try:
            raw = Path(f"/proc/{pid}/environ").read_bytes()
        except OSError:
            return None
        for entry in raw.split(b"\0"):
            if entry.startswith(b"NVIM_ADE_SERVER_DIR="):
                return entry.split(b"=", 1)[1].decode("utf-8", "replace")
        return None

    def cleanup(self):
        """Stop what this case started, whatever happened in the scenario."""
        for editor in self.editors:
            if editor.nvim:
                try:
                    editor.nvim.close()
                except Exception:
                    pass
                editor.nvim = None
            if editor.proc and editor.proc.poll() is None:
                editor.proc.kill()
                try:
                    editor.proc.wait(timeout=10)
                except subprocess.TimeoutExpired:
                    pass
            if editor._log_handle:
                try:
                    editor._log_handle.close()
                except OSError:
                    pass
                editor._log_handle = None
        for service in self.raw:
            service.stop()

        for pid in self._service_pids():
            try:
                os.kill(pid, signal.SIGKILL)
            except OSError:
                pass
        # Agents are children of the service and carry the mock path; match the
        # isolated tree so a leaked one cannot outlive the run.
        for pid in pids_matching(MOCK_AGENT):
            try:
                env = Path(f"/proc/{pid}/environ").read_bytes()
            except OSError:
                continue
            if self.dir.encode() in env:
                try:
                    os.kill(pid, signal.SIGKILL)
                except OSError:
                    pass

    def _service_pids(self):
        """Every process of this case's service, wrappers included.

        Matched only by `NVIM_ADE_SERVER_DIR` in the process environment, which
        is this case's private directory. That finds the real binary and the
        scenario wrappers (a python or shell script) that proxy it, so nothing
        this case started survives it.
        """
        own = {
            os.path.join(self.dir, "server"),
            os.path.join(self.dir, "raw", "server"),
        }
        out = []
        for pid in _all_pids():
            directory = self._env_dir_of(pid)
            if directory in own:
                out.append(pid)
        return out

    def report(self):
        parts = [f"=== {self.name} ==="]

        def list_agents():
            for editor in self.editors:
                if editor.nvim:
                    try:
                        return json.dumps(editor.instances(), ensure_ascii=False, indent=2)
                    except Exception as exc:  # noqa: BLE001
                        return f"<agent.list failed: {exc}>"
            return "<no editor connected>"

        parts.append("agent.list:\n" + list_agents())
        for editor in self.editors:
            parts.append(editor.recent_output())
        parts.append("--- service stderr (last 50) ---\n" + self.service_log.tail())
        return "\n".join(parts)

    def close(self):
        self.cleanup()
        shutil.rmtree(self.dir, ignore_errors=True)


def check(name, fn, binary):
    """Run one scenario and print `ok:` or record the failure."""
    case = Case(name, binary)
    active_cases.append(case)
    started = time.monotonic()
    try:
        fn(case)
        elapsed = time.monotonic() - started
        print(f"ok: {name} ({elapsed:.1f}s)")
    except (Exception, KeyboardInterrupt) as exc:  # noqa: BLE001 - a failure is a test result
        elapsed = time.monotonic() - started
        failures.append(name)
        print(f"FAIL: {name} ({elapsed:.1f}s): {exc!r}")
        traceback.print_exc()
        print(case.report())
        sys.stdout.flush()
    finally:
        try:
            active_cases.remove(case)
        except ValueError:
            pass
        case.close()
        ensure_signal_handlers()


def assert_true(condition, message):
    if not condition:
        raise AssertionError(message)


# ---------------------------------------------------------------------------
# scenarios
# ---------------------------------------------------------------------------


def scenario_idle_persistence(case):
    """1. An idle agent outlives the editor and the next editor reuses it."""
    first = case.editor("a")
    first.start()
    first.connect()
    first.submit("hello one")
    first.wait_reply("Hello from the mock agent")
    first.wait_turn_idle()
    instances = first.wait_instances(lambda list_: len(list_) == 1, "one instance")
    instance_id = instances[0]["instance"]
    agent_pid = instances[0]["pid"]
    first.quit()

    assert_true(pid_alive(agent_pid), "the agent must keep running after :qa!")
    service_pid = case.service_pid()
    assert_true(service_pid, "the service must keep running after :qa!")

    second = case.editor("b")
    second.start()
    second.connect()
    reused = second.wait_instances(
        lambda list_: len(list_) == 1 and list_[0]["instance"] == instance_id,
        "the same instance after reattaching",
    )
    assert_true(reused[0]["pid"] == agent_pid, "reattaching must not spawn a new agent")
    assert_true(reused[0]["attached"] >= 1, "the second editor must be attached")

    # `created = false` directly, with the exact key the plugin used.
    created = second.lua(
        """
        local connection = require("ade.service.connection").shared()
        local list, done = nil, false
        connection:request("agent.list", {}, function(ok, value)
          done = true
          list = ok and value.instances or {}
        end)
        vim.wait(5000, function() return done end, 10)
        local instance = list[1]
        local again, answered = nil, false
        connection:request("agent.attach", {
          key = { agent = instance.agent, command = instance.command,
                  args = instance.args, cwd = instance.cwd },
          client_capabilities = require("ade.controller").state().conn.client.client_capabilities,
          env = require("ade.service.transport").child_env(nil),
        }, function(ok, value)
          answered = true
          again = { ok = ok, value = value }
        end)
        vim.wait(5000, function() return answered end, 10)
        return again
        """
    )
    created = normalize(created)
    assert_true(created["ok"], f"the explicit attach failed: {created}")
    assert_true(created["value"]["created"] is False, "created must be false for a live instance")
    assert_true(
        created["value"]["instance"] == instance_id, "the instance id must not change"
    )

    second.submit("hello two")
    second.wait_reply("Hello from the mock agent")
    second.wait_turn_idle()
    assert_true(pid_alive(agent_pid), "the original agent served the second editor")


def scenario_running_turn_survives(case):
    """2. An in-flight turn keeps running (and the service alive) after exit.

    The mock's `slow` turn is deliberately short (about 5 s), so the window in
    which "the service did not exit" can be observed has to be shorter than the
    turn itself. The service is therefore started with a 2 s idle timeout via
    `NVIM_ADE_SERVER_IDLE_TIMEOUT_SECS`: a turn that is not running would take
    the service down well inside that window.
    """
    first = case.editor("a")
    first.start(service_env={"NVIM_ADE_SERVER_IDLE_TIMEOUT_SECS": "2"})
    first.connect()
    first.submit("slow please")
    running = first.wait_instances(
        lambda list_: len(list_) == 1 and list_[0].get("turns_running", 0) == 1,
        "the turn to start",
    )
    instance = running[0]["instance"]
    agent_pid = running[0]["pid"]
    first.quit()

    assert_true(pid_alive(agent_pid), "the agent kept the turn alive after :qa!")

    # Nothing is attached now and the idle timeout is 2 s: the service survives
    # only because `turns_running > 0` (PROTOCOL.md 8). Poll the whole window so
    # a service that exits early fails the test rather than racing it.
    service_pid = case.service_pid()
    assert_true(service_pid, "the service must be running after the editor left")
    deadline = time.monotonic() + 3.5
    while time.monotonic() < deadline:
        assert_true(
            pid_alive(service_pid),
            "the service exited while a turn was still running",
        )
        time.sleep(0.1)

    second = case.editor("b")
    second.start()
    second.connect()
    # The turn is still going: the plugin attaches to the live instance and
    # reuses it, and the service's own counter says the turn is still running.
    resumed = second.wait_instances(
        lambda list_: len(list_) == 1 and list_[0]["instance"] == instance,
        "the same instance after reattaching",
    )
    assert_true(
        resumed[0].get("turns_running", 0) == 1,
        f"the turn must still be running, got {resumed[0].get('turns_running')}",
    )

    # Cancel it through the plugin's own path: session/cancel for the session.
    second.lua(
        """
        local st = require("ade.controller").state()
        assert(st.session, "no session to cancel")
        st.conn.client:cancel(st.session.id)
        """
    )
    second.wait_instances(
        lambda list_: len(list_) == 1 and list_[0].get("turns_running", 0) == 0,
        "the turn to stop",
    )


def scenario_pending_permission(case):
    """3. A pending permission request survives with no front end attached.

    Spec: PROTOCOL.md 5.4 ("While the instance has no attached connection the
    set just grows... When a connection attaches, it becomes primary and
    receives the whole set in order"), 8 (a pending request keeps the service
    alive) and 9.5 ("pending permission requests arrive again").

    Known product defect (reported to the leader, fix in progress): the Lua
    client answers a pending request `cancelled` on the leave path
    (`Client:leave` -> `interactions:cancel_all`), so the request does not
    survive. This scenario therefore fails here, with the reason spelled out,
    until that fix lands; it is never skipped or weakened.
    """
    first = case.editor("a")
    first.start()
    first.connect()
    first.submit("permission please")
    first.wait_instances(
        lambda list_: len(list_) == 1 and list_[0].get("pending_requests", 0) == 1,
        "the permission request to arrive",
    )
    before = first.instances()
    instance = before[0]["instance"]
    agent_pid = before[0]["pid"]
    first.quit()

    assert_true(pid_alive(agent_pid), "the agent must wait for the answer, not exit")

    second = case.editor("b")
    second.start()
    second.connect()
    after = second.wait_instances(
        lambda list_: len(list_) == 1 and list_[0]["instance"] == instance,
        "the same instance after reattaching",
    )
    if after[0].get("pending_requests", 0) != 1:
        raise AssertionError(
            "PROTOCOL.md 5.4/8/9.5: after the first editor left, the pending "
            f"permission request must still be pending for the next front end, "
            f"but pending_requests is {after[0].get('pending_requests')!r} "
            "(the Lua client answers it `cancelled` on the leave path; "
            "see the report: Client:leave -> interactions:cancel_all)"
        )

    # The request must be delivered to the new primary, as a fresh request.
    second.wait_until_permission()
    second.answer_permission("allow")
    second.wait_reply("done")
    second.wait_turn_idle()
    second.wait_instances(
        lambda list_: len(list_) == 1 and list_[0].get("pending_requests", 0) == 0,
        "the request to be settled",
    )


def scenario_explicit_stop(case):
    """4. `:Ade disconnect` really stops the agent; reconnecting starts a new one."""
    first = case.editor("a")
    first.start()
    first.connect()
    first.submit("hello stop")
    first.wait_reply("Hello from the mock agent")
    first.wait_turn_idle()
    before = first.wait_instances(lambda list_: len(list_) == 1, "one instance")
    agent_pid = before[0]["pid"]

    first.disconnect()
    first.wait_instances(lambda list_: len(list_) == 0, "the instance to be stopped")
    wait_gone(agent_pid, WAIT, "the stopped agent process")

    first.connect()
    after = first.wait_instances(lambda list_: len(list_) == 1, "a new instance")
    assert_true(after[0]["pid"] != agent_pid, "reconnecting must spawn a new process")
    first.submit("hello again")
    first.wait_reply("Hello from the mock agent")
    first.wait_turn_idle()


def scenario_editor_sigkill(case):
    """5. `kill -9` on Neovim leaves the service and agent running."""
    first = case.editor("a")
    first.start()
    first.connect()
    first.submit("slow killed")
    running = first.wait_instances(
        lambda list_: len(list_) == 1 and list_[0].get("turns_running", 0) == 1,
        "the turn to start",
    )
    instance = running[0]["instance"]
    agent_pid = running[0]["pid"]
    service_pid = case.service_pid()
    first.kill()

    assert_true(pid_alive(service_pid), "the service must survive kill -9 on Neovim")
    assert_true(pid_alive(agent_pid), "the agent must survive kill -9 on Neovim")

    second = case.editor("b")
    second.start()
    second.connect()
    resumed = second.wait_instances(
        lambda list_: len(list_) == 1 and list_[0]["instance"] == instance,
        "the same instance after the crash",
    )
    assert_true(resumed[0]["pid"] == agent_pid, "no new agent after the crash")
    second.lua(
        """
        local st = require("ade.controller").state()
        st.conn.client:cancel(st.session.id)
        """
    )
    second.wait_instances(
        lambda list_: len(list_) == 1 and list_[0].get("turns_running", 0) == 0,
        "the interrupted turn to stop",
    )
    second.submit("hello after crash")
    second.wait_reply("Hello from the mock agent")
    second.wait_turn_idle()


def scenario_service_sigkill(case):
    """6. Killing the service takes the agent down and the editor recovers.

    Spec: PROTOCOL.md 7 ("the front end reconnects and re-attaches") and 9; the
    task requires that after the service is killed, `:Ade reconnect` (or
    `:Ade service start`) brings it back and chat works again.

    Known product defect (reported to the leader): the shared service connection
    is marked `closed` for the life of the Neovim process, and nothing ever
    resets it, so `ensure()` fails with "service connection was closed" even
    after a fresh service is started. The recovery half of this scenario
    therefore fails until that fix lands; the first half (no orphan processes)
    is asserted unconditionally.
    """
    first = case.editor("a")
    first.start()
    first.connect()
    first.submit("hello service")
    first.wait_reply("Hello from the mock agent")
    first.wait_turn_idle()
    instances = first.wait_instances(lambda list_: len(list_) == 1, "one instance")
    agent_pid = instances[0]["pid"]
    service_pid = case.service_pid()
    assert_true(service_pid, "the service must be running")

    os.kill(service_pid, signal.SIGKILL)
    wait_gone(service_pid, WAIT, "the killed service")
    # mock_agent exits on stdin EOF, so the agent goes with the service and no
    # orphan is left behind.
    wait_gone(agent_pid, WAIT, "the agent after the service was killed")

    status = first.wait_state(
        lambda st: st.get("connection") != "ready", "the editor to notice the loss"
    )
    assert_true(status["connection"] != "ready", "the editor still claims to be connected")

    collected = first.service_status()
    assert_true(collected["reachable"] is False, "a killed service must not be reachable")

    # Recovery: start the service again and reconnect.
    first.lua(
        """
        require("ade.service.commands").start({ notify = function() end })
        """
    )
    reachable = first.wait_service_reachable()
    assert_true(reachable, "the restarted service must accept a connection")
    first.lua("require('ade.controller').reconnect()")
    try:
        first.wait_state(lambda st: st.get("connection") == "ready", "session ready")
    except TimeoutError:
        error = first.lua(
            """
            return require("ade.service.connection").shared():last_error()
            """
        )
        raise AssertionError(
            "PROTOCOL.md 7/9: after the service was killed and started again, "
            "the editor must reconnect and re-attach, but the connection stayed "
            f"down ({error!r}). The shared service connection is marked `closed` "
            "when it drops and nothing ever resets it "
            "(service/connection.lua on_disconnect -> ensure)."
        ) from None
    new_instances = first.wait_instances(
        lambda list_: len(list_) == 1 and list_[0]["pid"] != agent_pid,
        "a new agent after the service restarted",
    )
    assert_true(new_instances[0]["instance"], "the service must have started again")
    first.submit("hello again after restart")
    first.wait_reply("Hello from the mock agent")
    first.wait_turn_idle()


def scenario_idle_exit(case):
    """7. With no front end and no work, the service exits and cleans up."""
    service = case.raw_service(idle_timeout=3)
    status = service.start()
    service_pid = status["pid"]
    socket_path = status["socket"]

    service.connect()
    service.request(
        "agent.attach",
        {
            "key": {
                "agent": "opencode",
                "command": "python3",
                "args": [MOCK_AGENT],
                "cwd": ROOT,
            },
            "client_capabilities": {},
            "env": {},
        },
    )
    listed = service.request("agent.list", {})["instances"]
    assert_true(len(listed) == 1, f"expected one instance: {listed}")
    agent_pid = listed[0]["pid"]

    # Stop the agent, then drop the connection: now nothing keeps it alive.
    service.request("agent.stop", {"instance": listed[0]["instance"]})
    wait_gone(agent_pid, WAIT, "the stopped agent")
    service.close()

    wait_gone(service_pid, WAIT + 10, "the idle service to exit")
    deadline = time.monotonic() + WAIT
    while time.monotonic() < deadline and os.path.exists(socket_path):
        time.sleep(0.05)
    assert_true(not os.path.exists(socket_path), "the socket file must be removed")


def scenario_two_frontends(case):
    """8. Two editors on one instance both get their own responses."""
    first = case.editor("a")
    first.start()
    first.connect()
    first.submit("hello first")
    first.wait_reply("Hello from the mock agent")
    first.wait_turn_idle()
    instances = first.wait_instances(lambda list_: len(list_) == 1, "one instance")
    instance_id = instances[0]["instance"]

    second = case.editor("b")
    second.start()
    second.connect()
    joined = second.wait_instances(
        lambda list_: len(list_) == 1 and list_[0]["instance"] == instance_id,
        "the second editor to attach",
    )
    assert_true(joined[0]["attached"] >= 2, f"both editors must be attached: {joined[0]}")

    # Both send at the same time. The mock refuses overlapping prompts, so give
    # each turn its own window: B starts after A settled, but both editors stay
    # online the whole time.
    second.submit("hello second")
    second.wait_reply("Hello from the mock agent")
    second.wait_turn_idle()
    assert_true(pid_alive(instances[0]["pid"]), "the shared agent is still running")

    # A third turn from A, with B attached: the same instance, no crash, and the
    # reply still lands in A's transcript.
    first.submit("hello third")
    first.wait_reply("Hello from the mock agent")
    first.wait_turn_idle()

    # A leaves; B keeps working.
    first.quit()
    second.submit("hello after a left")
    second.wait_reply("Hello from the mock agent")
    second.wait_turn_idle()
    still = second.wait_instances(
        lambda list_: len(list_) == 1 and list_[0]["instance"] == instance_id,
        "the instance after A left",
    )
    assert_true(still[0]["attached"] == 1, f"only B must be attached: {still[0]['attached']}")


def scenario_commands(case):
    """9. The `:Ade service` commands report the real state.

    The reported defect: `:Ade service agents` prints "unable to list agents:
    nil" because the command reads the reply immediately, while
    `Connection:request` is asynchronous (the reply arrives on the main loop).
    The existing unit tests inject a *synchronous* fake connection, so they
    cannot see it. This drives the real commands against the real service and
    checks what the user is told.

    Rules checked throughout:
      * after a command runs, it must not print "unable" before the reply could
        possibly have arrived;
      * a command that has no answer (yet) must not invent a failure;
      * `:Ade service status` must report the instance count.

    All five checks run even when an earlier one fails, and the failure lists
    every problem plus the full notification transcript: the three known causes
    are independent, so a partial fix should still show what is left.
    """
    editor = case.editor("a")
    editor.start()
    editor.capture_notifications()
    problems = []
    transcript = {}

    def record(label, lines):
        transcript[label] = list(lines)

    def expect(condition, message):
        if not condition:
            problems.append(message)

    # Never `:Ade service stop` here: another service may belong to the user.
    # The case directory isolates this one, and `Case.cleanup` kills only the
    # processes whose environment points at it.

    # 1) start, then `agents` with no chat: an empty list is not a failure.
    started = editor.run_command("Ade service start")
    record("Ade service start", started)
    expect(
        any("service is ready" in line or "already running" in line for line in started),
        f"`:Ade service start` did not report a running service: {started!r}",
    )

    empty = editor.run_command("Ade service agents")
    try:
        editor.wait_notifications(
            lambda lines: any("no agent instances" in line for line in lines)
            or any("unable to list agents" in line for line in lines),
            "`:Ade service agents` to answer (no chat yet)",
        )
    except AssertionError as error:
        problems.append(str(error))
    empty = editor.notify_lines()
    record("Ade service agents (no chat)", empty)
    expect(
        not any("unable to list agents" in line for line in empty),
        "`:Ade service agents` must not report a failure when the service simply "
        f"holds no agents; it printed {empty!r}. Two known causes: the command "
        "reads the reply before the asynchronous `agent.list` answer arrives "
        "(so `failure` is still nil), and it calls `connection.shared()` without "
        "passing `config`, so a shared connection created by the command itself "
        'cannot resolve `service.path` ("not installed"); `M.start`/`M.stop`/'
        "`M.status` all pass config, `M.agents`/`M.kill` do not.",
    )
    expect(
        any("no agent instances" in line for line in empty),
        f"`:Ade service agents` must say there are no instances, got {empty!r}",
    )

    # 2) create an instance through a normal chat turn, then list it.
    editor.connect()
    editor.submit("hello command")
    editor.wait_reply("Hello from the mock agent")
    editor.wait_turn_idle()
    running = editor.wait_instances(lambda list_: len(list_) == 1, "one instance")
    instance_id = running[0]["instance"]
    agent_pid = running[0]["pid"]

    listed = editor.run_command("Ade service agents")
    try:
        editor.wait_notifications(
            lambda lines: any(instance_id in line for line in lines)
            or any("unable to list agents" in line for line in lines),
            "`:Ade service agents` to answer (with an instance)",
        )
    except AssertionError as error:
        problems.append(str(error))
    listed = editor.notify_lines()
    record("Ade service agents (one instance)", listed)
    expect(
        not any("unable to list agents" in line for line in listed),
        "`:Ade service agents` failed with a live instance: "
        f"{listed!r} (the asynchronous reply is read before it arrives)",
    )
    line = next((text for text in listed if instance_id in text), None)
    expect(line is not None, f"no line for instance {instance_id}: {listed!r}")
    if line is not None:
        # `status.instance_line` is "<instance>  <agent>  <cwd>  pid <pid> ...".
        expect(
            str(agent_pid) in line,
            f"the line must carry the pid {agent_pid}: {line!r}",
        )
        expect("opencode" in line, f"the line must carry the agent name: {line!r}")

    # 3) status must report the instance count.
    status_lines = editor.run_command("Ade service status")
    try:
        editor.wait_notifications(
            lambda lines: any("service is running" in text for text in lines),
            "`:Ade service status` to answer",
        )
    except AssertionError as error:
        problems.append(str(error))
    status_lines = editor.notify_lines()
    record("Ade service status", status_lines)
    expect(
        any("agent instances: 1" in text for text in status_lines),
        "`:Ade service status` must report one agent instance, but printed "
        f"{status_lines!r}. `Status.collect` sends `agent.list` asynchronously "
        "and reads `listed` right after the call, so the count is always nil and "
        "the line is never printed.",
    )
    expect(
        not any("unable" in text.lower() for text in status_lines),
        f"`:Ade service status` reported a failure: {status_lines!r}",
    )

    # 4) No command may claim failure before its reply could have arrived.
    #    `run_command` clears the list and returns what was there after the Ex
    #    command returned; a synchronous "unable" would already be in it.
    for command in ("Ade service agents", "Ade service status"):
        immediate = editor.run_command(command)
        record(f"{command} (immediate)", immediate)
        expect(
            not any("unable" in line.lower() for line in immediate),
            f"`:{command}` printed a failure synchronously, before any reply could "
            f"arrive: {immediate!r}",
        )

    # 5) kill the instance, then the list is empty again.
    killed = editor.run_command(f"Ade service kill {instance_id}")
    try:
        editor.wait_notifications(
            lambda lines: any(instance_id in text for text in lines),
            "`:Ade service kill` to answer",
        )
    except AssertionError as error:
        problems.append(str(error))
    killed = editor.notify_lines()
    record(f"Ade service kill {instance_id}", killed)
    expect(
        not any("unable to stop" in line for line in killed),
        f"`:Ade service kill {instance_id}` failed: {killed!r} "
        "(same asynchronous-reply defect as `agents`)",
    )
    editor.wait_instances(lambda list_: len(list_) == 0, "the instance to be stopped")
    wait_gone(agent_pid, WAIT, "the killed agent process")

    after = editor.run_command("Ade service agents")
    try:
        editor.wait_notifications(
            lambda lines: any("no agent instances" in text for text in lines)
            or any("unable to list agents" in text for text in lines),
            "`:Ade service agents` to answer after the kill",
        )
    except AssertionError as error:
        problems.append(str(error))
    after = editor.notify_lines()
    record("Ade service agents (after kill)", after)
    expect(
        not any("unable to list agents" in line for line in after),
        f"`:Ade service agents` failed after the kill: {after!r}",
    )
    expect(
        any("no agent instances" in line for line in after),
        f"`:Ade service agents` must be empty after the kill, got {after!r}",
    )

    if problems:
        detail = "\n".join(f"  - {text}" for text in problems)
        seen = "\n".join(
            f"  {label}: {lines!r}" for label, lines in transcript.items()
        )
        raise AssertionError(
            "`:Ade service` commands do not report the real state "
            f"({len(problems)} problem(s)):\n{detail}\nnotifications seen:\n{seen}"
        )


# `Editor.wait_until_permission` is defined after the class for readability of
# the scenarios above; attaching it here keeps the class body small.
def _wait_until_permission(self, timeout=WAIT):
    def check():
        pending = self.pending_permissions()
        return pending if pending else None

    return wait_until(check, timeout, 0.05, f"a pending permission in {self.label}")


Editor.wait_until_permission = _wait_until_permission


# ---------------------------------------------------------------------------
# S1b scenarios: the event log, replay, turn adoption, reconnect
# ---------------------------------------------------------------------------


def scenario_reopen_restores(case):
    """10. Opening a new editor shows the conversation the log holds.

    `service.restore` (default true) reopens the most recent session for this
    cwd when the instance already exists. The transcript must come back from the
    service's event log through the emulated `session/load` (PROTOCOL.md 10-12),
    with the same session id, and chat must continue in it.

    Known defect (reported, fix in progress): `app/restore.lua` reads `entry.id`
    while `agent.attach` reports `sessionId` (PROTOCOL.md 3.2), so nothing is
    ever restored; and `Sessions:close_all_on_exit` sends `session/close` on
    exit, which makes the service forget the session. Both are asserted against
    the spec here, not worked around.
    """
    first = case.editor("a")
    first.start()
    first.connect()
    first.submit("hello one")
    first.wait_reply("Hello from the mock agent")
    first.wait_turn_idle()
    first.submit("hello two")
    first.wait_reply("Hello from the mock agent")
    first.wait_turn_idle()
    before = first.state()
    session_id = before["session"]["id"]
    before_transcript = first.transcript()
    assert_true(
        any(b["kind"] == "user" and b["text"] == "hello one" for b in before_transcript),
        f"the first editor did not record its own messages: {before_transcript!r}",
    )
    first.quit()

    second = case.editor("b")
    second.start()
    second.capture_notifications()
    second.connect()

    # The instance is reused, so restoring is possible at all.
    instances = second.wait_instances(lambda list_: len(list_) == 1, "one instance")
    assert_true(instances[0]["sessions"] >= 1, "the service must still track a session")

    attach = second.attach_info()
    assert_true(attach is not None, "no client to inspect")
    # `Client:initialize` computes `created` with `x and y or nil`, which turns a
    # legitimate `false` ("reused an existing instance") into nil. Restore then
    # bails out on its first guard and never loads anything.
    assert_true(
        attach.get("created") is False,
        "the second editor cannot tell that it reused an existing instance: "
        f"created={attach.get('created')!r} (attach {attach!r}). "
        "`Client:initialize` folds `false` into nil via `proc.created or nil`, and "
        "`Restore:after_ready` requires exactly `false`.",
    )

    state = second.wait_state(
        lambda st: (st.get("session") or {}).get("id") == session_id,
        f"the previous session ({session_id}) to be restored",
    )
    # The transcript is the point: it has to come back from the log.
    transcript = wait_until(
        lambda: (
            second.transcript()
            if any(
                block["kind"] == "user" and block["text"] in ("hello one", "hello two")
                for block in second.transcript()
            )
            else None
        ),
        WAIT,
        0.1,
        "the replayed conversation",
    )
    texts = [block["text"] for block in transcript if block["kind"] == "user"]
    for expected in ("hello one", "hello two"):
        assert_true(
            expected in texts,
            "the reopened editor must show the earlier prompts; it shows "
            f"{texts!r}. attach reported {attach!r}.",
        )
    assert_true(
        any(block["kind"] == "agent" for block in transcript),
        f"the agent's replies must be replayed too: {transcript!r}",
    )
    assert_true(
        state["session"]["id"] == session_id,
        f"the session id changed: {state['session']!r}",
    )

    second.submit("hello three")
    second.wait_reply("Hello from the mock agent")
    second.wait_turn_idle()


def scenario_adopt_running_turn(case):
    """11. A turn that was running when the editor closed is adopted.

    PROTOCOL.md 13: the front end that loads the session takes over the orphaned
    `session/prompt`; the session shows as running, cancelling it ends the turn,
    and chat continues afterwards.

    Depends on the same restore defect as scenario 10 (nothing is loaded, so
    nothing is adopted); asserted per spec.
    """
    first = case.editor("a")
    first.start()
    first.connect()
    first.submit("slow please")
    first.wait_instances(
        lambda list_: len(list_) == 1 and list_[0].get("turns_running", 0) == 1,
        "the turn to start",
    )
    # Wait for the first streamed chunk, so the transcript has partial output.
    partial = first.wait_reply("working")
    session_id = first.state()["session"]["id"]
    first.quit()

    second = case.editor("b")
    second.start()
    second.capture_notifications()
    second.connect()

    # The service kept the turn: its counter is still one.
    running = second.wait_instances(
        lambda list_: len(list_) == 1 and list_[0].get("turns_running", 0) == 1,
        "the turn to still be running",
    )
    assert_true(running[0]["sessions"] >= 1, "the service must still track the session")

    # The adopted session must be the one from the closed editor, with the
    # partial output already in its transcript.
    restored = second.wait_state(
        lambda st: (st.get("session") or {}).get("id") == session_id,
        f"the running session ({session_id}) to be loaded",
    )
    try:
        transcript = wait_until(
            lambda: (
                second.transcript()
                if any(block["text"] == partial["text"] for block in second.transcript())
                else None
            ),
            WAIT,
            0.1,
            "the partial output to be replayed",
        )
    except TimeoutError:
        raise AssertionError(
            "the running turn was not adopted: its partial output never reached the "
            f"second editor (transcript {second.transcript()!r}, attach "
            f"{second.attach_info()!r}). Adoption follows a session load "
            "(PROTOCOL.md 13), so this fails for the same reason as scenario 10."
        ) from None
    assert_true(
        any(block["text"] == "slow please" for block in transcript),
        f"the prompt of the running turn must be in the replay: {transcript!r}",
    )

    # The adopted turn looks running in the UI: the session status is not idle.
    status = second.wait_state(
        lambda st: (st.get("session") or {}).get("status") not in (None, "idle"),
        "the adopted turn to show as running",
    )
    assert_true(
        status["session"]["status"] != "idle",
        f"the adopted turn must look running, status is {status['session']['status']!r}",
    )

    # Cancelling ends it, and the service's counter drops to zero.
    second.lua(
        """
        local st = require("ade.controller").state()
        st.conn.client:cancel(st.session.id)
        """
    )
    second.wait_instances(
        lambda list_: len(list_) == 1 and list_[0].get("turns_running", 0) == 0,
        "the adopted turn to stop",
    )
    second.wait_turn_idle()
    second.submit("hello after adopt")
    second.wait_reply("Hello from the mock agent")
    second.wait_turn_idle()


def scenario_log_disabled(case):
    """12. `service.event_log = false`: reattach, but no replay.

    PROTOCOL.md 10: with the log off, `features` has no `"log"`, `attach` returns
    no sessions and section 12 never applies. The agent instance is still shared,
    so the second editor attaches to it; its conversation starts empty and chat
    works. No error is reported.
    """
    first = case.editor("a")
    first.start(service={"event_log": False})
    first.connect()
    first.submit("hello one")
    first.wait_reply("Hello from the mock agent")
    first.wait_turn_idle()
    before = first.instances()
    agent_pid = before[0]["pid"]
    assert_true(
        before[0].get("log_bytes", 0) == 0,
        f"with the log off nothing is recorded, got {before[0].get('log_bytes')} bytes",
    )
    first.quit()

    second = case.editor("b")
    second.start(service={"event_log": False})
    second.capture_notifications()
    second.connect()

    instances = second.wait_instances(lambda list_: len(list_) == 1, "one instance")
    assert_true(
        instances[0]["pid"] == agent_pid,
        "the second editor must attach to the same agent",
    )
    assert_true(
        instances[0].get("sessions", 0) == 0,
        f"no sessions are tracked without a log, got {instances[0].get('sessions')}",
    )
    attach = second.attach_info()
    assert_true(attach is not None, "no client to inspect")
    # Reuse is asserted through the pid above; `created` is not asserted here
    # because a separate defect (`Client:initialize` folds `false` into nil) makes
    # it unavailable, and scenario 10 covers that defect directly.
    assert_true(
        not attach.get("sessions"),
        f"attach must report no sessions without a log: {attach!r}",
    )
    assert_true(
        not second.transcript(),
        f"nothing can be replayed without a log: {second.transcript()!r}",
    )
    assert_true(
        not any("error" in line.lower() or "unable" in line.lower() for line in second.notify_lines()),
        f"turning the log off must not produce an error: {second.notify_lines()!r}",
    )
    # `Restore:after_ready` reports "the service has no sessions to restore"
    # once; that is the documented explanation, not an error.
    assert_true(
        not any("error" in line.lower() or "unable" in line.lower() for line in second.notify_lines()),
        f"no failure may be reported: {second.notify_lines()!r}",
    )

    second.submit("hello two")
    second.wait_reply("Hello from the mock agent")
    second.wait_turn_idle()


def scenario_pruned_log_falls_back(case):
    """13. A log too large to replay falls back to the agent's `session/load`.

    PROTOCOL.md 12: above the replay ceiling the service forwards `session/load`
    instead of answering it from the log. The ceiling is 32 MiB, and
    `--event-log-max-mb` cannot go below 16, so filling it with real events would
    mean hundreds of MiB. The service reads the ceiling from
    `NVIM_ADE_SERVER_REPLAY_LIMIT_BYTES` (a documented test hook in
    `service/src/hub.rs`), so the wrapper sets it below the log this scenario
    records.

    The observable difference is what comes back: the service replays what the
    front end recorded, while the agent's own `session/load` replays the mock's
    canned history ("old question" / "old answer"). This drives the service
    protocol directly, because the plugin-side restore path is broken
    independently (scenario 10) and would hide the fallback.
    """
    proxy = _write_trim_proxy(case)
    raw = case.raw_service(idle_timeout=60, binary=proxy)
    status = raw.start()
    assert_true(status["status"] == "ready", f"the service did not start: {status!r}")
    service_pid = status["pid"]
    hello = raw.connect()
    assert_true(
        "log" in hello["features"],
        f"the log must be on for this scenario: {hello!r}",
    )

    key = {
        "agent": "opencode",
        "command": "python3",
        "args": [MOCK_AGENT],
        "cwd": ROOT,
    }
    attached = raw.request("agent.attach", {"key": key, "client_capabilities": {}, "env": {}})
    instance = attached["instance"]
    conversation = RawConversation(raw, instance)
    conversation.open()
    conversation.prompt("hello one")
    conversation.prompt("hello two")
    listed = raw.request("agent.list", {})["instances"]
    log_bytes = listed[0].get("log_bytes", 0)
    assert_true(
        log_bytes > 0,
        "the log must hold the recorded events before testing the fallback",
    )
    assert_true(
        log_bytes > 1000,
        f"the wrapper sets the replay ceiling at 1 000 bytes; the log has {log_bytes}",
    )

    # A second connection loads the session. Above the ceiling the service must
    # forward the request, and the agent answers with its own replay.
    loader = RawConversation(raw, instance)
    loader.replay = conversation.replay = []
    replay = conversation.load_session("sess_mock")
    texts = [text for text in replay if text]
    assert_true(
        "old question" in texts,
        "the fallback must use the agent's session/load; the service's own replay "
        f"would instead show the prompts 'hello one'/'hello two'. Got {texts!r} "
        f"(log bytes {log_bytes}).",
    )
    assert_true(
        "hello one" not in texts,
        f"the service must not answer this load from the log: {texts!r}",
    )
    # And the service is still healthy afterwards.
    assert_true(pid_alive(service_pid), "the service must survive the fallback")
    conversation.prompt("hello three")


def scenario_auto_reconnect(case):
    """14. An unexpected service death reconnects automatically.

    `service.reconnect_attempts` retries with backoff, and the manual
    `:Ade reconnect` path runs on success. A deliberate `:Ade service stop` must
    **not** start the loop.
    """
    editor = case.editor("a")
    editor.start(service={"reconnect_attempts": 3})
    editor.capture_notifications()
    editor.connect()
    editor.submit("hello one")
    editor.wait_reply("Hello from the mock agent")
    editor.wait_turn_idle()

    # The reconnect loop must be wired at all. `bootstrap.lua` subscribes it as
    # the "panel" channel on the *real* service connection; a subscription on the
    # application wrapper is silently skipped (that object has no `subscribe`).
    listeners = editor.service_connection_listeners()
    panel = (listeners.get("channels") or {}).get("__disconnected") or []
    assert_true(
        "panel" in panel,
        "nothing subscribes the panel to __disconnected, so an unexpected drop "
        "can never start the reconnect loop. Subscribers on the real service "
        f"connection: {listeners!r}",
    )

    service_pid = case.service_pid()
    assert_true(service_pid, "the service must be running")
    os.kill(service_pid, signal.SIGKILL)
    wait_gone(service_pid, WAIT, "the killed service")

    # The UI says it is reconnecting while it retries.
    status = wait_until(
        lambda: editor.reconnect_status() if editor.reconnect_status() else None,
        WAIT,
        0.05,
        "the reconnecting status",
    )
    assert_true(
        "reconnect" in str(status),
        f"the status must say it is reconnecting, got {status!r}",
    )
    reconnected = editor.wait_notifications(
        lambda lines: any("reconnected" in line for line in lines),
        "the reconnected message",
        timeout=WAIT + 10,
    )
    assert_true(
        any("reconnected" in line for line in reconnected),
        f"the editor never reported a reconnection: {reconnected!r}",
    )
    editor.connect()
    editor.submit("hello after reconnect")
    editor.wait_reply("Hello from the mock agent")
    editor.wait_turn_idle()

    # A deliberate stop is not an accident: no retry loop, no "reconnected".
    editor.clear_notifications()
    editor.run_command("Ade service stop")
    time.sleep(1.5)
    lines = editor.notify_lines()
    assert_true(
        not any("reconnected" in line or "reconnecting" in line for line in lines),
        f"`:Ade service stop` must not reconnect: {lines!r}",
    )
    state = editor.reconnector_state()
    assert_true(
        state is not None and state.get("running") is False,
        f"no retry loop may be running after a deliberate stop: {state!r}",
    )


def scenario_crash_loop(case):
    """15. A service that dies immediately is not retried forever.

    The wrapper starts the real service but kills itself shortly after, so every
    reconnect succeeds and then drops again. With `service.reconnect_attempts = 3`
    the loop must give up and say so, instead of restarting a service forever.
    """
    editor = case.editor("a")
    proxy = _write_crash_proxy(case)
    editor.start(service={"path": proxy, "reconnect_attempts": 3})
    editor.capture_notifications()
    editor.connect()

    # Without the retry loop wired there is nothing to give up: say so instead of
    # waiting out the ladder for a loop that will never run.
    listeners = editor.service_connection_listeners()
    panel = (listeners.get("channels") or {}).get("__disconnected") or []
    if "panel" not in panel:
        raise AssertionError(
            "no automatic retry happens at all: nothing subscribes the panel to "
            "__disconnected, so the loop that should give up after "
            f"service.reconnect_attempts=3 never starts. Subscribers: {listeners!r}"
        )

    # Wait for the loop to exhaust itself. The backoff is 0.5s, 1s, 2s, so this
    # needs a few seconds; polling keeps it as fast as the ladder allows.
    #
    # This scenario is specifically "connects, then dies again", so the give-up
    # path is the stability guard in `Reconnector:lost()`: its wording is
    # "the service keeps disconnecting (N attempts used)" (`reconnector.lua`,
    # `tests/spec_s1b.lua` "keeps climbing through a crash loop",
    # `tests/spec_s1b_wiring.lua` "stops after a crash loop"). The other wording
    # ("could not reconnect after N attempts") belongs to `attempt_once`, where
    # the service never came back at all; accepting it here would hide exactly
    # that failure.
    gave_up = wait_until(
        lambda: [
            line for line in editor.notify_lines() if "keeps disconnecting" in line
        ]
        or None,
        WAIT + 20,
        0.2,
        "the reconnect loop to give up",
    )
    assert_true(
        any("3" in line for line in gave_up),
        f"the message must name the attempt limit: {gave_up!r}",
    )
    # The proxy bumps its state file on every service start. Four starts (the
    # initial one plus the three retries) prove the attempts really reconnected
    # rather than failing to launch the service at all.
    starts = _proxy_starts(os.path.join(case.dir, "crash_proxy.state"))
    assert_true(
        starts == 4,
        "the service must have been started 4 times (1 initial + 3 retries), "
        f"got {starts!r}; gave_up={gave_up!r}, notifications={editor.notify_lines()!r}",
    )
    state = editor.reconnector_state()
    assert_true(
        state is not None and state.get("running") is False,
        f"the loop must stop after giving up: {state!r}",
    )
    # No further attempts: the loop is done, not sleeping between them.
    time.sleep(2.0)
    state = editor.reconnector_state()
    assert_true(
        state is not None and state.get("running") is False,
        f"the loop restarted after giving up: {state!r}",
    )


def scenario_version_restart(case):
    """16. A stale service is restarted when idle, kept when busy.

    `version_check` restarts an idle service onto the new binary and says
    "N idle agent(s) will restart with it"; a service with a running turn is
    used as-is with a single warning.
    """
    proxy = helpers.write_version_proxy(case.dir, case.binary)

    editor = case.editor("a")
    editor.start(service={"path": proxy})
    editor.capture_notifications()
    editor.connect()
    lines = editor.wait_notifications(
        lambda seen: any("idle agent" in line for line in seen),
        "the restart message for an idle service",
        timeout=WAIT + 10,
    )
    assert_true(
        any("idle agent" in line for line in lines),
        "restarting a stale idle service must tell the user that idle agents "
        f"restart with it; notifications were {lines!r}",
    )
    assert_true(
        any("restarting nvim_ade_server" in line for line in lines),
        f"the message must name the restart: {lines!r}",
    )
    editor.submit("hello after restart")
    editor.wait_reply("Hello from the mock agent")
    editor.wait_turn_idle()

    # Busy: the same stale wrapper, but with a turn in flight it must not restart.
    busy = case.editor("b")
    os.makedirs(os.path.join(case.dir, "busy"), exist_ok=True)
    busy_proxy = helpers.write_version_proxy(os.path.join(case.dir, "busy"), case.binary)
    busy.start(service={"path": busy_proxy})
    busy.capture_notifications()
    busy.connect()
    busy.submit("slow please")
    busy.wait_instances(
        lambda list_: len(list_) == 1 and list_[0].get("turns_running", 0) == 1,
        "the busy turn",
    )
    pid_before = busy.instances()[0]["pid"]
    busy.clear_notifications()

    # A second editor attaches to the same busy service: it must warn once and
    # leave the service alone.
    third = case.editor("c")
    third.start(service={"path": busy_proxy})
    third.capture_notifications()
    third.connect()
    warnings = third.wait_notifications(
        lambda seen: any("restarts automatically" in line for line in seen),
        "the busy-service warning",
        timeout=WAIT,
    )
    assert_true(
        any("restarts automatically" in line for line in warnings),
        f"a busy stale service must be explained once: {warnings!r}",
    )
    assert_true(
        not any("idle agent" in line for line in warnings),
        f"a busy service must not be restarted: {warnings!r}",
    )
    # The service (and therefore the agent) is the same process as before.
    assert_true(
        busy.instances()[0]["pid"] == pid_before,
        "the busy service must not have been restarted",
    )
    busy.lua(
        """
        local st = require("ade.controller").state()
        st.conn.client:cancel(st.session.id)
        """
    )
    busy.wait_instances(
        lambda list_: len(list_) == 1 and list_[0].get("turns_running", 0) == 0,
        "the busy turn to stop",
    )


def scenario_retract_dialog(case):
    """17. Answering a request in one editor closes it in the other.

    PROTOCOL.md 14: a pending agent request delivered to several connections is
    withdrawn from the others with `$/cancel_request` once answered.
    """
    first = case.editor("a")
    first.start()
    first.connect()
    # A asks first, so A is the primary for the request.
    first.submit("permission please")
    first.wait_instances(
        lambda list_: len(list_) == 1 and list_[0].get("pending_requests", 0) == 1,
        "the permission request",
    )
    first.wait_until_permission()
    assert_true(
        len(first.pending_permissions()) == 1,
        f"A must show the request: {first.pending_permissions()!r}",
    )

    # B attaches while it is pending: as the new primary it receives the request
    # again (PROTOCOL.md 5.4), so both editors show it.
    second = case.editor("b")
    second.start()
    second.capture_notifications()
    second.connect()
    second.wait_until_permission()
    assert_true(
        len(second.pending_permissions()) == 1,
        f"B must be handed the pending request: {second.pending_permissions()!r}",
    )
    assert_true(
        len(first.pending_permissions()) == 1,
        "A still shows the request until it is answered",
    )

    # A answers: B's copy must close, and the agent finishes the turn.
    first.answer_permission("allow")
    wait_until(
        lambda: second.pending_permissions() == [],
        WAIT,
        0.05,
        "B's copy of the answered request to close",
    )
    assert_true(
        first.pending_permissions() == [],
        f"A's own copy must close too: {first.pending_permissions()!r}",
    )
    first.wait_reply("done")
    first.wait_turn_idle()
    first.wait_instances(
        lambda list_: len(list_) == 1 and list_[0].get("pending_requests", 0) == 0,
        "the request to be settled",
    )


def _write_trim_proxy(case):
    """A wrapper around the real service that lowers the replay ceiling.

    `--event-log-max-mb` is clamped to 16 MiB, and the replay ceiling is 32 MiB,
    so filling either with real events is impractical in a test. The ceiling is
    read from `NVIM_ADE_SERVER_REPLAY_LIMIT_BYTES` (`service/src/hub.rs`, a
    documented test hook), which the wrapper sets below the log the scenario
    records.
    """
    real = case.binary
    path = os.path.join(case.dir, "trim_proxy.sh")
    with open(path, "w", encoding="utf-8") as handle:
        handle.write("#!/bin/sh\n")
        handle.write('if [ "$1" = "version" ]; then exec %s version; fi\n' % _shell_quote(real))
        handle.write(
            'NVIM_ADE_SERVER_REPLAY_LIMIT_BYTES=1000 exec %s "$@"\n' % _shell_quote(real)
        )
    os.chmod(path, 0o755)
    return path


def _write_crash_proxy(case):
    """A service that starts, answers for a moment, then kills itself.

    The real service runs on a private socket; the wrapper owns the public one
    and exits a few hundred milliseconds after the first connection, so every
    reconnection succeeds and drops again.
    """
    real = case.binary
    path = os.path.join(case.dir, "crash_proxy.py")
    state = os.path.join(case.dir, "crash_proxy.state")
    script = f'''#!{sys.executable}
"""A service that dies shortly after each start (scenario 15)."""
import json
import os
import socket
import subprocess
import sys
import threading
import time

REAL = {real!r}
STATE = {state!r}
DIR = os.environ.get("NVIM_ADE_SERVER_DIR", "")
SOCKET = os.path.join(DIR, "nvim_ade_server.sock")
REAL_SOCKET = os.path.join(DIR, "nvim_ade_server.real.sock")


def bump():
    try:
        with open(STATE, encoding="utf-8") as handle:
            count = int(handle.read().strip() or "0")
    except (OSError, ValueError):
        count = 0
    with open(STATE, "w", encoding="utf-8") as handle:
        handle.write(str(count + 1))
    return count + 1


def relay(src, dst):
    try:
        while True:
            chunk = src.recv(1 << 16)
            if not chunk:
                break
            dst.sendall(chunk)
    except OSError:
        pass


def main():
    argv = sys.argv[1:]
    if argv and argv[0] == "version":
        print(json.dumps({{"version": "0.3.0", "api_version": 2}}))
        return 0
    if not DIR:
        return 1
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
    real = subprocess.Popen([REAL] + forwarded, stdout=subprocess.PIPE, text=True)
    line = real.stdout.readline()
    if not line:
        print(json.dumps({{"status": "error", "message": "real service did not start"}}), flush=True)
        return 1
    bump()
    try:
        os.unlink(SOCKET)
    except OSError:
        pass
    listener = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    listener.bind(SOCKET)
    listener.listen(16)
    print(json.dumps({{"status": "ready", "socket": SOCKET, "pid": os.getpid()}}), flush=True)

    def killer():
        time.sleep(0.4)
        real.kill()
        os._exit(1)

    # Arm the death timer on the first accepted connection, not when the
    # launcher reports ready: a loaded machine can take longer than 0.4 s to
    # complete the handshake, and "died before the first connection" would turn
    # every retry into a failed launch instead of the crash loop under test.
    armed = threading.Event()

    while True:
        try:
            client, _ = listener.accept()
        except OSError:
            break

        def serve(client=client):
            if not armed.is_set():
                armed.set()
                threading.Thread(target=killer, daemon=True).start()
            upstream = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            try:
                upstream.connect(REAL_SOCKET)
            except OSError:
                client.close()
                return
            for src, dst in ((client, upstream), (upstream, client)):
                threading.Thread(target=relay, args=(src, dst), daemon=True).start()

        threading.Thread(target=serve, daemon=True).start()
    return 0


if __name__ == "__main__":
    main()
'''
    with open(path, "w", encoding="utf-8") as handle:
        handle.write(script)
    os.chmod(path, 0o755)
    return path


def _proxy_starts(path):
    """How many times the crash proxy started a service, or None if it never did."""
    try:
        with open(path, encoding="utf-8") as handle:
            return int(handle.read().strip() or "0")
    except (OSError, ValueError):
        return None


def _shell_quote(path):
    return "'" + str(path).replace("'", "'\\''") + "'"


class RawConversation:
    """A minimal ACP conversation over a `RawService` connection.

    The service protocol scenarios (13) need the raw wire: the plugin's own
    restore path is broken independently, so driving the service directly is what
    isolates "the service forwards a too-large load" from that.
    """

    def __init__(self, service, instance):
        self.service = service
        self.instance = instance
        self.next_id = 1000
        self.messages = []
        self.replay = []

    def send_request(self, method, params, timeout=WAIT):
        """Send an ACP request through the tunnel and wait for its response."""
        self.next_id += 1
        request_id = self.next_id
        frame = {"jsonrpc": "2.0", "id": request_id, "method": method, "params": params}
        self.service.notify("tunnel.send", {"instance": self.instance, "message": frame})
        return self.wait_response(request_id, timeout)

    def wait_response(self, request_id, timeout=WAIT):
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            message = self.service._read_message(deadline)
            if message is None:
                break
            body = (message.get("params") or {}).get("message") or {}
            if not body:
                continue
            self._record(body)
            if body.get("id") == request_id and "method" not in body:
                return body
        raise TimeoutError(f"no response to request {request_id}")

    def _record(self, body):
        self.messages.append(body)
        if body.get("method") == "session/update":
            update = (body.get("params") or {}).get("update") or {}
            text = (update.get("content") or {}).get("text")
            if text:
                self.replay.append(text)

    def open(self):
        self.send_request("initialize", {"protocolVersion": 1, "clientCapabilities": {}})
        response = self.send_request(
            "session/new", {"cwd": ROOT, "mcpServers": []}
        )
        self.session_id = (response.get("result") or {}).get("sessionId", "sess_mock")
        return self.session_id

    def prompt(self, text, timeout=WAIT):
        before = len(self.replay)
        response = self.send_request(
            "session/prompt",
            {
                "sessionId": self.session_id,
                "prompt": [{"type": "text", "text": text}],
            },
            timeout=timeout,
        )
        return self.replay[before:], response

    def load_session(self, session_id, timeout=WAIT):
        """`session/load`, returning the texts the answer replayed."""
        before = len(self.replay)
        self.send_request(
            "session/load",
            {"sessionId": session_id, "cwd": ROOT, "mcpServers": []},
            timeout=timeout,
        )
        # The replay frames were already consumed by `wait_response`.
        return self.replay[before:]




# ---------------------------------------------------------------------------
# main
# ---------------------------------------------------------------------------

SCENARIOS = [
    ("1 idle persistence", scenario_idle_persistence),
    ("2 running turn survives exit", scenario_running_turn_survives),
    ("3 pending permission survives", scenario_pending_permission),
    ("4 explicit stop", scenario_explicit_stop),
    ("5 editor SIGKILL", scenario_editor_sigkill),
    ("6 service SIGKILL", scenario_service_sigkill),
    ("7 idle exit", scenario_idle_exit),
    ("8 two front ends", scenario_two_frontends),
    ("9 commands", scenario_commands),
    ("10 reopen restores the conversation", scenario_reopen_restores),
    ("11 adopt a running turn", scenario_adopt_running_turn),
    ("12 log disabled", scenario_log_disabled),
    ("13 pruned log falls back to the agent load", scenario_pruned_log_falls_back),
    ("14 automatic reconnect", scenario_auto_reconnect),
    ("15 crash loop gives up", scenario_crash_loop),
    ("16 version mismatch restart", scenario_version_restart),
    ("17 retract dialog", scenario_retract_dialog),
]


def main():
    binary = find_service_binary()
    _install_signal_handlers()
    print(f"service binary: {binary}")
    only = os.environ.get("ADE_TEST_PERSIST_ONLY")
    try:
        for label, fn in SCENARIOS:
            if only and only not in label:
                continue
            check(label, fn, binary)
    finally:
        _cleanup_active_cases()

    leftover = [
        pid
        for pid in pids_matching(MOCK_AGENT)
        if pid_alive(pid) and "ade-persist-" in _cmdline(pid)
    ]
    if leftover:
        print(f"FAIL: leftover agents: {leftover}")
        failures.append("cleanup")
    service_leftover = [
        pid
        for pid in pids_matching("nvim_ade_server")
        if pid_alive(pid) and "ade-persist-" in _env_of(pid)
    ]
    if service_leftover:
        print(f"FAIL: leftover services: {service_leftover}")
        failures.append("cleanup")

    print()
    if failures:
        print(f"{len(failures)} scenario(s) failed: {', '.join(failures)}")
        return 1
    print("all persistence scenarios passed")
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    finally:
        # Belt and braces: a case that is still open here means something failed
        # outside `check` (an exception in `main`, or a signal handler that could
        # not run). Close it so no service or agent process is left behind.
        _cleanup_active_cases()
