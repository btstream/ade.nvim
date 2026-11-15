#!/usr/bin/env python3
"""Minimal nvim_ade_server stand-in for the plugin tests.

It implements the api_version 2 tunnel protocol from `service/PROTOCOL.md`:
`hello`/`ping`/`shutdown`, `agent.attach/detach/stop/list`, `tunnel.send/recv`,
`agent.exited` and `tunnel.error`. A `tunnel.send` is answered by a canned agent
in this script, which is enough for the launcher/lifecycle tests; the in-process
Lua stand-in (`tests/fake_service.lua`) is what drives a real `mock_agent.py`.

Version numbers are **not** hardcoded here: `--server-version` and
`--api-version` are passed by the caller (which reads them from
`lua/ade/service/version.lua`), so bumping the constants needs no change here.

    python3 tests/fake_service.py serve --dir DIR [--token TOKEN]
        [--server-version V] [--api-version N] [--wrong-token]
        [--status error|ready|already_running] [--no-ready-line] [--require-hello]
    python3 tests/fake_service.py version --server-version V --api-version N
"""

import argparse
import json
import os
import socket
import subprocess
import sys
import threading
import time


def log(message):
    print(message, file=sys.stderr, flush=True)


class Instance:
    def __init__(self, ident, key, capabilities, initialized=False, env=None):
        self.id = ident
        self.key = key
        self.capabilities = capabilities
        self.initialized = initialized
        self.attached = set()
        self.seq = 0
        self.started_at = int(time.time() * 1000)
        self.env = env
        self.process = None
        # PROTOCOL.md 3.4: a stopped instance leaves the identity lookup at
        # once but stays listed (with stopping=true) until its exit is sent.
        self.stopping = False
        # Ids of `initialize` requests forwarded to the agent; the answer is a
        # response object, so the method name is not available to check there.
        self.initialize_ids = set()
        # Sessions the relay tracks for this instance (PROTOCOL.md 11), in the
        # exact shape `agent.attach` reports them (PROTOCOL.md 3.2):
        # `{sessionId, cwd, running, updated_at}`.
        self.sessions = []

    def start(self):
        """Spawn the real agent command, like the service does."""
        command = self.key.get("command")
        if not command:
            return False
        argv = [command] + list(self.key.get("args") or [])
        env = self.env if self.env else None
        try:
            self.process = subprocess.Popen(
                argv,
                cwd=self.key.get("cwd") or None,
                env=env,
                stdin=subprocess.PIPE,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                start_new_session=True,
            )
        except OSError as error:
            log("spawn failed: %s" % error)
            return False
        return True

    def send(self, message):
        if not self.process or not self.process.stdin:
            return
        try:
            self.process.stdin.write(json.dumps(message).encode() + b"\n")
            self.process.stdin.flush()
        except OSError as error:
            log("write to agent failed: %s" % error)

    def stop(self, force=False):
        if not self.process:
            return
        try:
            if force:
                self.process.kill()
            else:
                self.process.stdin.close()
                try:
                    self.process.wait(timeout=3)
                except subprocess.TimeoutExpired:
                    self.process.terminate()
                    try:
                        self.process.wait(timeout=3)
                    except subprocess.TimeoutExpired:
                        self.process.kill()
        except OSError:
            pass


class Server:
    def __init__(self, args):
        self.args = args
        self.socket_path = os.path.join(args.dir, "nvim_ade_server.sock")
        self.token_path = os.path.join(args.dir, "nvim_ade_server.token")
        self.token = args.token
        self.stop = threading.Event()
        self.instances = {}
        # Stop requested, exit not announced yet (listed with stopping=true).
        self.stopping = {}
        self.counter = 0
        self.lock = threading.Lock()

    def prepare(self):
        os.makedirs(self.args.dir, mode=0o700, exist_ok=True)
        if os.path.exists(self.socket_path):
            os.unlink(self.socket_path)
        if not os.path.exists(self.token_path):
            with open(self.token_path, "w", encoding="utf-8") as handle:
                handle.write(self.token)
        os.chmod(self.token_path, 0o600)

    # --- connection handling ---------------------------------------------

    def handle(self, conn):
        buffer = b""
        greeted = False
        attached = set()
        while True:
            try:
                chunk = conn.recv(65536)
            except OSError:
                return
            if not chunk:
                with self.lock:
                    for ident in attached:
                        instance = self.instances.get(ident)
                        if instance:
                            instance.attached.discard(conn)
                return
            buffer += chunk
            while b"\n" in buffer:
                line, buffer = buffer.split(b"\n", 1)
                if not line.strip():
                    continue
                try:
                    message = json.loads(line)
                except json.JSONDecodeError:
                    continue
                reply = self.dispatch(message, conn, attached)
                if reply is None:
                    continue
                try:
                    conn.sendall(json.dumps(reply).encode() + b"\n")
                except OSError:
                    return
                greeted = greeted or message.get("method") == "hello"
                if reply.get("_shutdown"):
                    reply.pop("_shutdown", None)
                    self.stop.set()
                    conn.close()
                    return

    def send(self, conn, payload):
        try:
            conn.sendall(json.dumps(payload).encode() + b"\n")
        except OSError:
            pass

    def emit(self, conn, method, params):
        self.send(conn, {"jsonrpc": "2.0", "method": method, "params": params})

    # --- protocol --------------------------------------------------------

    def error(self, ident, code, message, data=None):
        payload = {"code": code, "message": message}
        if data is not None:
            payload["data"] = data
        return {"jsonrpc": "2.0", "id": ident, "error": payload}

    def result(self, ident, value):
        return {"jsonrpc": "2.0", "id": ident, "result": value}

    def canonical(self, key, capabilities):
        return json.dumps(
            {
                "agent": key.get("agent"),
                "command": key.get("command"),
                "args": key.get("args") or [],
                "cwd": key.get("cwd"),
                "client_capabilities": capabilities or {},
            },
            sort_keys=True,
        )

    def dispatch(self, message, conn, attached):
        method = message.get("method")
        ident = message.get("id")
        params = message.get("params") or {}
        if method == "hello":
            if self.args.wrong_token:
                return self.error(ident, -32001, "invalid token")
            if params.get("token") != self.token:
                return self.error(ident, -32001, "invalid token")
            if params.get("api_version") != self.args.api_version:
                return self.error(
                    ident,
                    -32002,
                    "incompatible api_version",
                    {"server_api_version": self.args.api_version},
                )
            return self.result(
                ident,
                {
                    "server_version": self.args.server_version,
                    "api_version": self.args.api_version,
                    "features": ["tunnel"],
                },
            )
        if self.args.require_hello and not attached and not self._greeted(conn):
            return self.error(ident, -32003, "hello required")
        if method == "ping":
            return self.result(ident, {})
        if method == "shutdown":
            reply = self.result(ident, {})
            reply["_shutdown"] = True
            return reply
        if method == "agent.attach":
            return self.attach(params, conn, ident)
        if method == "agent.detach":
            with self.lock:
                instance = self.instances.get(params.get("instance"))
                if not instance:
                    return self.error(ident, -32020, "unknown instance")
                instance.attached.discard(conn)
                attached.discard(instance.id)
            return self.result(ident, {})
        if method == "agent.stop":
            with self.lock:
                instance = self.instances.get(params.get("instance"))
                if not instance:
                    return self.error(ident, -32020, "unknown instance")
                self.stop_instance(instance, force=bool(params.get("force")))
            return self.result(ident, {"exited": True, "code": 0})
        if method == "agent.list":
            with self.lock:
                instances = [
                    {
                        "instance": instance.id,
                        "agent": instance.key.get("agent"),
                        "command": instance.key.get("command"),
                        "args": instance.key.get("args") or [],
                        "cwd": instance.key.get("cwd"),
                        "pid": 0,
                        "started_at": instance.started_at,
                        "initialized": instance.initialized,
                        "attached": len(instance.attached),
                        "turns_running": 0,
                        "pending_requests": 0,
                        "stopping": instance.stopping,
                        "sessions": len(instance.sessions),
                        "log_bytes": 0,
                    }
                    for instance in list(self.instances.values()) + list(self.stopping.values())
                ]
            instances.sort(key=lambda item: item["instance"])
            return self.result(ident, {"instances": instances})
        if method == "tunnel.send":
            self.tunnel_send(params, conn, attached)
            return None
        return self.error(ident, -32601, "Method not found: " + str(method))

    def _greeted(self, conn):
        return True

    def attach(self, params, conn, ident):
        key = params.get("key") or {}
        capabilities = params.get("client_capabilities") or {}
        canonical = self.canonical(key, capabilities)
        with self.lock:
            found = None
            for instance in self.instances.values():
                if instance.stopping:
                    continue
                if self.canonical(instance.key, instance.capabilities) == canonical:
                    found = instance
                    break
            created = False
            if not found:
                self.counter += 1
                found = Instance("inst-%d" % self.counter, key, capabilities, env=params.get("env"))
                self.instances[found.id] = found
                created = True
                if self.args.spawn_agent:
                    if not found.start():
                        self.instances.pop(found.id, None)
                        return self.error(ident, -32022, "spawn failed")
                    threading.Thread(target=self.pump, args=(found,), daemon=True).start()
            found.attached.add(conn)
        return self.result(
            ident,
            {
                "instance": found.id,
                "created": created,
                "pid": 0,
                "initialized": found.initialized,
                "attached": len(found.attached),
                # PROTOCOL.md 3.2. Newest activity first; an entry uses
                # `sessionId`, never `id`.
                "sessions": sorted(
                    found.sessions, key=lambda item: (-item.get("updated_at", 0), item.get("sessionId", ""))
                ),
            },
        )

    def tunnel_send(self, params, conn, attached):
        if self.args.trace:
            with open(self.args.trace, "a", encoding="utf-8") as handle:
                handle.write(json.dumps({"dir": "client->agent", "message": params.get("message")}) + "\n")
        ident = params.get("instance")
        message = params.get("message")
        with self.lock:
            instance = self.instances.get(ident)
            if not instance or conn not in instance.attached:
                self.emit(
                    conn,
                    "tunnel.error",
                    {"instance": ident, "code": -32024, "message": "not attached"},
                )
                return
        if not isinstance(message, dict):
            self.emit(
                conn,
                "tunnel.error",
                {"instance": ident, "code": -32025, "message": "frame is not an object"},
            )
            return
        if isinstance(message, dict) and message.get("method") == "initialize" and message.get("id") is not None:
            instance.initialize_ids.add(message["id"])
        if instance.process:
            instance.send(message)
            return
        reply = self.answer(instance, message)
        if reply is not None:
            with self.lock:
                self.track(instance, message, reply)
                instance.seq += 1
                seq = instance.seq
                if message.get("method") == "initialize":
                    instance.initialized = True
                targets = list(instance.attached)
            for target in targets:
                self.emit(target, "tunnel.recv", {"instance": ident, "seq": seq, "message": reply})

    def pump(self, instance):
        """Forward the agent's stdout lines to every attached connection.

        `readline()` rather than `for line in stream`: iterating a pipe uses
        read-ahead buffering, which holds a message back until the buffer fills.
        ACP is request/response, so a held-back line deadlocks the pair (the
        agent waits for an answer to a message that never arrived).
        """
        stdout = instance.process.stdout
        while True:
            line = stdout.readline()
            if not line:
                break
            line = line.strip()
            if not line:
                continue
            try:
                message = json.loads(line)
            except json.JSONDecodeError:
                log("agent wrote a non-JSON line")
                continue
            if not isinstance(message, dict):
                continue
            if os.environ.get("ADE_FAKE_TRACE"):
                with open(os.environ["ADE_FAKE_TRACE"], "a", encoding="utf-8") as handle:
                    handle.write(json.dumps(message) + "\n")
            if self.args.trace:
                with open(self.args.trace, "a", encoding="utf-8") as handle:
                    handle.write(json.dumps({"dir": "agent->client", "message": message}) + "\n")
            if (
                message.get("id") in instance.initialize_ids
                and "result" in message
                and "method" not in message
            ):
                instance.initialized = True
            with self.lock:
                instance.seq += 1
                seq = instance.seq
                targets = list(instance.attached)
            for target in targets:
                self.emit(target, "tunnel.recv", {"instance": instance.id, "seq": seq, "message": message})
        code = instance.process.poll()
        with self.lock:
            self.instances.pop(instance.id, None)
            targets = list(instance.attached)
        for target in targets:
            self.emit(
                target,
                "agent.exited",
                {"instance": instance.id, "code": code if code is not None else 0, "signal": None, "stderr_tail": ""},
            )

    def track(self, instance, message, reply):
        """Mirror the relay's session tracking (PROTOCOL.md 11).

        Only what the canned agent exercises: `session/new` and `session/load`
        on success. `session/close` and `session/delete` forget the session, so
        a test can assert that the exit path did *not* send one.
        """
        if not isinstance(message, dict) or not isinstance(reply, dict):
            return
        method = message.get("method")
        params = message.get("params") or {}
        result = reply.get("result")
        if method == "session/new" and isinstance(result, dict) and isinstance(result.get("sessionId"), str):
            instance.sessions = [
                entry for entry in instance.sessions if entry.get("sessionId") != result["sessionId"]
            ]
            instance.sessions.append(
                {
                    "sessionId": result["sessionId"],
                    "cwd": params.get("cwd") or instance.key.get("cwd") or "",
                    "running": False,
                    "updated_at": int(time.time() * 1000),
                }
            )
        elif method == "session/load" and isinstance(result, dict) and isinstance(params.get("sessionId"), str):
            if all(entry.get("sessionId") != params["sessionId"] for entry in instance.sessions):
                instance.sessions.append(
                    {
                        "sessionId": params["sessionId"],
                        "cwd": params.get("cwd") or instance.key.get("cwd") or "",
                        "running": False,
                        "updated_at": int(time.time() * 1000),
                    }
                )
        elif method in ("session/close", "session/delete") and isinstance(result, dict):
            if params.get("sessionId") is not None:
                instance.sessions = [
                    entry for entry in instance.sessions if entry.get("sessionId") != params["sessionId"]
                ]

    def answer(self, instance, message):
        """A tiny canned agent: enough to prove the tunnel, not an ACP agent."""
        method = message.get("method")
        ident = message.get("id")
        if method == "initialize":
            return {
                "jsonrpc": "2.0",
                "id": ident,
                "result": {"protocolVersion": 1, "agentCapabilities": {}},
            }
        if method == "session/new":
            return {"jsonrpc": "2.0", "id": ident, "result": {"sessionId": "fake-session"}}
        if method == "session/prompt":
            return {"jsonrpc": "2.0", "id": ident, "result": {"stopReason": "end_turn"}}
        if method in ("session/close", "session/delete"):
            return {"jsonrpc": "2.0", "id": ident, "result": {}}
        return None

    def stop_instance(self, instance, force=False):
        instance.stopping = True
        targets = list(instance.attached)
        # Leave the identity lookup before the process is touched, so an attach
        # sent right after this request gets a fresh instance.
        self.instances.pop(instance.id, None)
        self.stopping[instance.id] = instance
        if instance.process:
            instance.stop(force=force)
        for target in targets:
            self.emit(
                target,
                "agent.exited",
                {"instance": instance.id, "code": 0, "signal": None, "stderr_tail": ""},
            )
        self.stopping.pop(instance.id, None)

    # --- process ---------------------------------------------------------

    def run(self):
        if self.args.status == "error":
            print(json.dumps({"status": "error", "message": self.args.message}), flush=True)
            return 1
        self.prepare()
        listener = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        listener.bind(self.socket_path)
        os.chmod(self.socket_path, 0o600)
        listener.listen(8)
        if not self.args.no_ready_line:
            print(
                json.dumps({"status": self.args.status, "socket": self.socket_path, "pid": os.getpid()}),
                flush=True,
            )
        if self.args.no_ready_line:
            self.stop.wait(self.args.lifetime)
            return 0
        listener.settimeout(0.2)
        while not self.stop.is_set() and self.args.lifetime > 0:
            self.args.lifetime -= 0.2
            try:
                conn, _ = listener.accept()
            except socket.timeout:
                continue
            thread = threading.Thread(target=self.handle, args=(conn,), daemon=True)
            thread.start()
        listener.close()
        try:
            os.unlink(self.socket_path)
        except OSError:
            log("socket already gone")
        return 0


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("command", nargs="?", default="serve", choices=["serve", "version"])
    parser.add_argument("--dir", default=os.environ.get("NVIM_ADE_SERVER_DIR", ""))
    parser.add_argument("--token", default="test-token")
    parser.add_argument("--server-version", default=os.environ.get("ADE_FAKE_SERVER_VERSION", ""))
    parser.add_argument("--api-version", type=int, default=int(os.environ.get("ADE_FAKE_API_VERSION", "0")))
    parser.add_argument("--wrong-token", action="store_true")
    parser.add_argument("--status", default="ready", choices=["ready", "already_running", "error"])
    parser.add_argument("--message", default="boom")
    parser.add_argument("--no-ready-line", action="store_true")
    parser.add_argument("--require-hello", action="store_true")
    parser.add_argument("--lifetime", type=float, default=30.0)
    # Spawn the command from `agent.attach` like the real service; the canned
    # agent is only used when this is off (launcher-only tests).
    parser.add_argument("--spawn-agent", action="store_true")
    parser.add_argument("--trace", default=os.environ.get("ADE_FAKE_TRACE"))
    # The real binary's `serve` accepts these; the stand-in only needs to accept
    # them so the launcher's argv (which now carries --idle-timeout) keeps
    # working.
    parser.add_argument("--idle-timeout", type=float, default=None)
    parser.add_argument("--socket", default=None)
    # PROTOCOL.md 15: the real service accepts these; the stand-in records them
    # so a test can assert the launcher passed the right flags.
    parser.add_argument("--event-log", default="on", choices=["on", "off"])
    parser.add_argument("--event-log-max-mb", type=int, default=256)
    args = parser.parse_args()
    if not args.server_version or args.api_version <= 0:
        parser.error("--server-version and --api-version are required (pass them from version.lua)")
    if args.command == "version":
        print(json.dumps({"version": args.server_version, "api_version": args.api_version}), flush=True)
        return 0
    if not args.dir:
        parser.error("--dir is required for serve")
    return Server(args).run()


if __name__ == "__main__":
    sys.exit(main())
