#!/usr/bin/env python3
"""Minimal nvim_ade_server stand-in for the plugin tests.

It implements only what `.acp-work/contract.md` promises for S0: the directory
and permission layout, the token file, the one-line status on stdout, and the
JSON-RPC methods `hello`, `ping` and `shutdown` with the three contract error
codes.

Options exist for the failure modes the client tests need, so the tests never
depend on the real Rust service:

    python3 tests/fake_service.py --dir DIR [--token TOKEN]
        [--wrong-token] [--api-version N] [--status error|ready|already_running]
        [--no-ready-line] [--require-hello]

Prints one status line on stdout, like the real binary, and logs to stderr.
"""

import argparse
import json
import os
import socket
import sys
import threading

API_VERSION = 1
SERVER_VERSION = "0.1.0"


def log(message):
    print(message, file=sys.stderr, flush=True)


class Server:
    def __init__(self, args):
        self.args = args
        self.socket_path = os.path.join(args.dir, "nvim_ade_server.sock")
        self.token_path = os.path.join(args.dir, "nvim_ade_server.token")
        self.token = args.token
        self.stop = threading.Event()

    def prepare(self):
        os.makedirs(self.args.dir, mode=0o700, exist_ok=True)
        if os.path.exists(self.socket_path):
            os.unlink(self.socket_path)
        if not os.path.exists(self.token_path):
            with open(self.token_path, "w", encoding="utf-8") as handle:
                handle.write(self.token)
        os.chmod(self.token_path, 0o600)

    def handle(self, conn):
        buffer = b""
        greeted = False
        while True:
            chunk = conn.recv(65536)
            if not chunk:
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
                reply = self.dispatch(message, greeted)
                if reply is None:
                    continue
                conn.sendall(json.dumps(reply).encode() + b"\n")
                greeted = True
                if reply.get("_shutdown"):
                    reply.pop("_shutdown", None)
                    self.stop.set()
                    conn.close()
                    return

    def error(self, ident, code, message, data=None):
        payload = {"code": code, "message": message}
        if data is not None:
            payload["data"] = data
        return {"jsonrpc": "2.0", "id": ident, "error": payload}

    def dispatch(self, message, greeted):
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
            return {
                "jsonrpc": "2.0",
                "id": ident,
                "result": {
                    "server_version": SERVER_VERSION,
                    "api_version": self.args.api_version,
                    "features": [],
                },
            }
        if not greeted and self.args.require_hello:
            return self.error(ident, -32003, "hello required")
        if method == "ping":
            return {"jsonrpc": "2.0", "id": ident, "result": {}}
        if method == "shutdown":
            return {"jsonrpc": "2.0", "id": ident, "result": {}, "_shutdown": True}
        return self.error(ident, -32601, "Method not found: " + str(method))

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
            # Stay alive without ever answering, so the launcher times out.
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
    parser.add_argument("--wrong-token", action="store_true")
    parser.add_argument("--api-version", type=int, default=API_VERSION)
    parser.add_argument("--status", default="ready", choices=["ready", "already_running", "error"])
    parser.add_argument("--message", default="boom")
    parser.add_argument("--no-ready-line", action="store_true")
    parser.add_argument("--require-hello", action="store_true")
    parser.add_argument("--lifetime", type=float, default=30.0)
    args = parser.parse_args()
    if args.command == "version":
        print(json.dumps({"version": SERVER_VERSION, "api_version": API_VERSION}), flush=True)
        return 0
    if not args.dir:
        parser.error("--dir is required for serve")
    return Server(args).run()


if __name__ == "__main__":
    sys.exit(main())
