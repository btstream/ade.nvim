"""Helpers for the persistence end-to-end scenarios (S1b).

The only one so far is the **version proxy** used by scenario 16.

The real service reports `server_version` from a compile-time constant
(`crate::SERVER_VERSION`), so a test cannot ask it to claim an older build. A
`service.path` wrapper can: it starts the real binary on a private socket,
forwards every byte, and rewrites the `server_version` of the `hello` response
on its **first** run only. The plugin then sees "an old service is running",
decides it is idle, restarts it, and the second run reports the real version, so
the handshake matches. That is exactly the restart path of
`lua/ade/service/version_check.lua`, end to end.

The wrapper also makes `version` report the old number until the first serve and
the real one afterwards, which is what a real upgrade looks like: the binary on
disk changed, the running process is stale.

Usage (the test does this; it is not a script to run by hand):

    proxy = write_version_proxy(directory, real_binary)
    # `<proxy> version`             -> the old version, then the real one
    # `<proxy> serve --idle-timeout N` -> the real service behind a rewriting relay
"""

import json
import os
import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent


def _lua_constants():
    """Read the plugin's service version and api_version (single source)."""
    text = (ROOT / "lua" / "ade" / "service" / "version.lua").read_text(encoding="utf-8")
    version = re.search(r'M\.VERSION\s*=\s*"([^"]+)"', text)
    api = re.search(r"M\.API_VERSION\s*=\s*(\d+)", text)
    if not version or not api:
        raise RuntimeError("lua/ade/service/version.lua has no VERSION/API_VERSION")
    return version.group(1), int(api.group(1))


VERSION, API_VERSION = _lua_constants()
# A genuinely older release, but on the current protocol version: the proxy
# must exercise the version restart, never an api_version handshake failure.
OLD_VERSION = "0.2.0"


def _version_tuple(value):
    parts = []
    for part in re.split(r"[.+-]", value):
        if part.isdigit():
            parts.append(int(part))
        elif parts:
            break
    return tuple(parts)


assert _version_tuple(OLD_VERSION) < _version_tuple(VERSION), (OLD_VERSION, VERSION)

SCRIPT = r'''#!{python}
"""A service.path wrapper that runs the real nvim_ade_server behind a relay.

The first `serve` pretends to be an older build: `hello`'s `server_version` is
rewritten to the old number so the plugin's version check has something to
restart. Later runs pass the real version through.
"""
import json
import os
import socket
import subprocess
import sys
import threading

REAL = {real!r}
STATE = {state!r}
OLD = {old!r}
NEW = {new!r}

DIR = os.environ.get("NVIM_ADE_SERVER_DIR", "")
SOCKET = os.path.join(DIR, "nvim_ade_server.sock")
REAL_SOCKET = os.path.join(DIR, "nvim_ade_server.real.sock")


def serves_so_far():
    try:
        with open(STATE, encoding="utf-8") as handle:
            return int(handle.read().strip() or "0")
    except (OSError, ValueError):
        return 0


def mark_serve():
    count = serves_so_far() + 1
    with open(STATE, "w", encoding="utf-8") as handle:
        handle.write(str(count) + "\n")
    return count


def relay(src, dst, rewrite):
    """Copy one direction; with `rewrite`, replace hello's server_version."""
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
                out = line
                try:
                    msg = json.loads(line)
                    result = msg.get("result") if isinstance(msg, dict) else None
                    if isinstance(result, dict) and "server_version" in result:
                        result["server_version"] = OLD
                        out = json.dumps(msg).encode()
                except Exception:
                    pass
                dst.sendall(out + b"\n")
        if buf:
            dst.sendall(buf)
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
        # Before the first serve the "installed" binary is still the old build.
        version = OLD if serves_so_far() == 0 else NEW
        print(json.dumps({{"version": version, "api_version": {api}}}))
        return 0

    if not DIR:
        print(json.dumps({{"status": "error", "message": "NVIM_ADE_SERVER_DIR is not set"}}), flush=True)
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
    real = subprocess.Popen([REAL] + forwarded, stdout=subprocess.PIPE, stderr=None, text=True)
    line = real.stdout.readline()
    if not line:
        print(json.dumps({{"status": "error", "message": "the real service did not start"}}), flush=True)
        return 1
    first = mark_serve() == 1

    def stop(_code=None):
        # The plugin owns the public socket; when the real service exits (shutdown
        # or idle timeout) the wrapper must exit too, or the next probe would find
        # a socket nobody serves.
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
    os.chmod(SOCKET, 0o600)
    listener.listen(16)
    print(json.dumps({{"status": "ready", "socket": SOCKET, "pid": os.getpid()}}), flush=True)

    while True:
        try:
            client, _ = listener.accept()
        except OSError:
            break

        def serve(client=client):
            upstream = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            try:
                upstream.connect(REAL_SOCKET)
            except OSError:
                client.close()
                return
            up = threading.Thread(target=relay, args=(client, upstream, False), daemon=True)
            down = threading.Thread(target=relay, args=(upstream, client, first), daemon=True)
            up.start()
            down.start()
            up.join()
            down.join()
            for sock in (client, upstream):
                try:
                    sock.close()
                except OSError:
                    pass

        threading.Thread(target=serve, daemon=True).start()

    stop()


if __name__ == "__main__":
    main()
'''


def real_server_version(binary):
    """The real service's version, from its `version` subcommand."""
    output = subprocess.run(
        [binary, "version"], capture_output=True, text=True, timeout=60, check=True
    ).stdout
    return json.loads(output.strip().splitlines()[0])["version"]


def write_version_proxy(directory, binary, old_version=OLD_VERSION):
    """Write the version-rewriting wrapper and return its path.

    `binary` is the real service; the wrapper's state file lives in
    `directory`, so one scenario cannot affect another.
    """
    path = Path(directory) / "version_proxy.py"
    state = Path(directory) / "version_proxy.serves"
    path.write_text(
        SCRIPT.format(
            python=sys.executable,
            real=str(binary),
            state=str(state),
            old=old_version,
            new=real_server_version(binary),
            api=API_VERSION,
        ),
        encoding="utf-8",
    )
    path.chmod(0o755)
    return str(path)
