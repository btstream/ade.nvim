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
import copy
import json
import os
import re
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
        # Live connections, for install progress broadcast (PROTOCOL.md 16.3).
        self.connections = []
        self.install_jobs = {}
        self.install_locks = {}
        self.pending_installs = {}
        # PROTOCOL.md 17: rule sets installed by front ends, keyed by name.
        self.policy_sets = {}
        self.install_version = args.install_version
        self.latest_version = args.latest_version or args.install_version

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
        with self.lock:
            self.connections.append(conn)
        try:
            self._handle(conn, buffer, greeted, attached)
        finally:
            with self.lock:
                if conn in self.connections:
                    self.connections.remove(conn)

    def _handle(self, conn, buffer, greeted, attached):
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
                    "features": ["tunnel"] + (["install"] if self.args.api_version >= 3 else []),
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
        if method == "policy.set":
            return self.policy_set(params, conn, ident)
        if method == "policy.clear":
            return self.policy_clear(params, conn, ident)
        if method == "policy.list":
            return self.result(ident, {"sets": list(self.policy_sets.values())})
        if method == "$/cancel_request":
            job = self.pending_installs.get(params.get("id"))
            if job:
                self.cancel_install(job)
            return None
        if method == "install.resolve":
            threading.Thread(target=self.resolve_version, args=(params, conn, ident), daemon=True).start()
            return None
        if method == "install.run":
            return self.install_run(params, conn, ident)
        if method == "install.uninstall":
            return self.install_uninstall(params, conn, ident)
        if method == "tunnel.send":
            self.tunnel_send(params, conn, attached)
            return None
        return self.error(ident, -32601, "Method not found: " + str(method))

    # --- permission policy (PROTOCOL.md 17) --------------------------------

    def policy_set(self, params, conn, ident):
        rule_set = params.get("set")
        if not isinstance(rule_set, dict) or not isinstance(rule_set.get("name"), str):
            return self.error(ident, -32050, "set.name is required")
        stored = copy.deepcopy(rule_set)
        stored["owner"] = "conn-%d" % id(conn)
        stored["installed_at"] = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
        self.policy_sets[stored["name"]] = stored
        threading.Thread(target=self.later_result, args=(conn, ident, {}), daemon=True).start()
        return None

    def policy_clear(self, params, conn, ident):
        removed = self.policy_sets.pop(params.get("name"), None) is not None
        threading.Thread(
            target=self.later_result, args=(conn, ident, {"removed": removed}), daemon=True
        ).start()
        return None

    def later_result(self, conn, ident, value):
        time.sleep(0.02)
        self.send(conn, self.result(ident, value))

    def policy_applied(self, payload):
        self.broadcast("policy.applied", payload)

    # --- managed installs (PROTOCOL.md 16) -------------------------------

    def broadcast(self, method, params):
        with self.lock:
            connections = list(self.connections)
        for conn in connections:
            self.emit(conn, method, params)

    def emit_install(self, job, event):
        event["job"] = job.get("job")
        event["agent"] = job.get("agent")
        event["action"] = job.get("action") or job["params"].get("action") or "uninstall"
        self.broadcast("install.progress", event)

    def refuse_install(self, params, ident, code, message, data=None):
        """Early refusal: section 16.3 requires one terminal event first."""
        self.emit_install(
            {"job": params.get("job"), "agent": params.get("agent"), "params": params},
            {"phase": "failed", "message": message},
        )
        return self.error(ident, code, message, data)

    def resolve_version(self, params, conn, ident):
        time.sleep(0.01)
        spec = params.get("spec") or "latest"
        version = spec if spec != "latest" else (self.latest_version or self.install_version)
        self.send(conn, self.result(ident, {"version": version}))

    @staticmethod
    def read_json(path):
        try:
            with open(path, encoding="utf-8") as handle:
                value = json.load(handle)
            return value if isinstance(value, dict) else None
        except (OSError, ValueError):
            return None

    @staticmethod
    def write_json(path, value):
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, "w", encoding="utf-8") as handle:
            json.dump(value, handle)

    @staticmethod
    def install_id_for(version):
        base = re.sub(r"[^0-9a-z.-]", "_", version.lower())[:64]
        return "v%s-%d" % (base, int(time.time() * 1000) % 1000000000)

    def finish_install(self, job, reply):
        self.install_locks.pop(job["agent"], None)
        self.install_jobs.pop(job["job"], None)
        self.pending_installs.pop(job["id"], None)
        self.send(job["conn"], reply)

    def install_run(self, params, conn, ident):
        if params.get("job") in self.install_jobs:
            # A validation failure emits no terminal event (16.3); the id
            # already belongs to the running job.
            return self.error(ident, -32040, "job is already running")
        agent = params.get("agent")
        if agent in self.install_locks:
            return self.refuse_install(params, ident, -32042, "another instance is using this agent", {"reason": "pid 4242 is running"})
        root = params.get("root") or ""
        version = params.get("version")
        agent_dir = os.path.join(root, agent or "")
        current = self.read_json(os.path.join(agent_dir, "current.json"))
        if params.get("action") == "update" and current and current.get("version") == version:
            self.emit_install(
                {"job": params.get("job"), "agent": agent, "params": params},
                {"phase": "unchanged", "version": version},
            )
            return self.result(ident, {
                "status": "unchanged",
                "installId": current.get("installId"),
                "version": version,
            })
        self.install_locks[agent] = True
        job = {
            "id": ident,
            "job": params.get("job"),
            "agent": agent,
            "params": params,
            "conn": conn,
            "cancelled": False,
        }
        self.install_jobs[job["job"]] = job
        self.pending_installs[ident] = job
        threading.Thread(target=self.run_install_steps, args=(job,), daemon=True).start()
        return None

    def run_install_steps(self, job):
        params = job["params"]
        agent = job["agent"]
        version = params.get("version")
        delay = 0.01
        time.sleep(delay)
        if job["cancelled"]:
            return
        self.emit_install(job, {"phase": "checking"})
        time.sleep(delay)
        if job["cancelled"]:
            return
        install_id = self.install_id_for(version)
        agent_dir = os.path.join(params.get("root") or "", agent)
        release = os.path.join(agent_dir, "releases", install_id)
        job["dir"] = release
        os.makedirs(release, exist_ok=True)
        self.emit_install(job, {"phase": "installing", "version": version, "dir": release})
        time.sleep(delay)
        if job["cancelled"]:
            return
        self.write_json(os.path.join(release, "package.json"), {
            "name": "ade-nvim-managed",
            "private": True,
            "version": "0.0.0",
            "description": "Installed by ade.nvim; do not edit.",
            "dependencies": {params.get("package"): version},
        })
        self.emit_install(job, {
            "phase": "output",
            "line": "$ npm install --no-audit --no-fund --omit=dev --loglevel=notice --progress=false",
        })
        package = params.get("package") or "package"
        entry = params.get("entry") or "dist/index.js"
        package_dir = os.path.join(release, "node_modules", package)
        os.makedirs(os.path.join(package_dir, os.path.dirname(entry)), exist_ok=True)
        self.write_json(os.path.join(package_dir, "package.json"), {"name": package, "version": version})
        try:
            with open(os.path.join(package_dir, entry), "w", encoding="utf-8") as handle:
                handle.write("#!/usr/bin/env node\n")
        except OSError:
            pass
        self.emit_install(job, {"phase": "verifying", "version": version})
        time.sleep(delay)
        if job["cancelled"]:
            return
        import platform as _platform

        system = _platform.system()
        arch = _platform.machine()
        platform_name = {"Darwin": "OSX", "Windows": "Windows"}.get(system, system)
        arch_name = {"x86_64": "x64", "AMD64": "x64", "aarch64": "arm64", "arm64": "arm64"}.get(arch, arch)
        self.write_json(os.path.join(release, "receipt.json"), {
            "schemaVersion": 1,
            "agentId": agent,
            "installId": install_id,
            "package": package,
            "version": version,
            "entry": "node_modules/%s/%s" % (package, entry),
            "runtime": "node",
            "installedAt": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
            "platform": platform_name,
            "arch": arch_name,
        })
        self.write_json(os.path.join(agent_dir, "current.json"), {
            "schemaVersion": 1,
            "installId": install_id,
            "updatedAt": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
            "package": package,
            "version": version,
        })
        self.emit_install(job, {"phase": "committed", "version": version})
        self.finish_install(job, self.result(job["id"], {
            "status": "committed",
            "installId": install_id,
            "version": version,
            "dir": release,
        }))

    def install_uninstall(self, params, conn, ident):
        if params.get("job") in self.install_jobs:
            return self.error(ident, -32040, "job is already running")
        agent = params.get("agent")
        if agent in self.install_locks:
            return self.refuse_install(params, ident, -32042, "another instance is using this agent", {"reason": "pid 4242 is running"})
        root = params.get("root") or ""
        agent_dir = os.path.join(root, agent or "")
        current = self.read_json(os.path.join(agent_dir, "current.json"))
        if not current or not isinstance(current.get("installId"), str):
            return self.refuse_install(params, ident, -32045, "this agent has no manager-owned install")
        if params.get("installId") and params["installId"] != current.get("installId"):
            return self.refuse_install(params, ident, -32042, "the installed release changed", {"reason": "changed"})
        self.install_locks[agent] = True
        job = {
            "id": ident,
            "job": params.get("job"),
            "agent": agent,
            "params": params,
            "conn": conn,
            "cancelled": False,
        }
        self.install_jobs[job["job"]] = job
        self.pending_installs[ident] = job
        threading.Thread(target=self.run_uninstall_steps, args=(job, current), daemon=True).start()
        return None

    def run_uninstall_steps(self, job, current):
        time.sleep(0.01)
        if job["cancelled"]:
            return
        agent_dir = os.path.join(job["params"].get("root") or "", job["agent"])
        try:
            os.remove(os.path.join(agent_dir, "current.json"))
        except OSError:
            pass
        import shutil
        shutil.rmtree(os.path.join(agent_dir, "releases", current.get("installId")), ignore_errors=True)
        self.emit_install(job, {"phase": "removed"})
        self.finish_install(job, self.result(job["id"], {"installId": current.get("installId")}))

    def cancel_install(self, job):
        job["cancelled"] = True
        if job.get("dir"):
            import shutil
            shutil.rmtree(job["dir"], ignore_errors=True)
        self.emit_install(job, {"phase": "cancelled"})
        self.finish_install(job, self.error(job["id"], -32800, "request cancelled"))

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
    parser.add_argument("--install-version", default="1.0.0")
    parser.add_argument("--latest-version", default=None)
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
