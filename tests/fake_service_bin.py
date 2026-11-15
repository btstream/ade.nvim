#!/usr/bin/env python3
"""Executable stand-in for `nvim_ade_server`, for the parameterised integration
runs.

It forwards to `tests/fake_service.py`, passing the protocol versions from
`lua/ade/service/version.lua` so the script keeps handshaking after the
constants are bumped. Point `ADE_TEST_SERVICE_BIN` at this file:

    ADE_TEST_BACKEND=service ADE_TEST_SERVICE_BIN=tests/fake_service_bin.py \
      nvim --headless -u tests/minimal_init.lua -l tests/integration.lua

The real Rust binary is what the verifier runs after merging; this exists so
the plugin side can be exercised on its own.
"""

import os
import re
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
VERSION_FILE = os.path.join(ROOT, "lua", "ade", "service", "version.lua")


def read_version():
    text = open(VERSION_FILE, encoding="utf-8").read()
    version = re.search(r'M\.VERSION\s*=\s*"([^"]+)"', text)
    api = re.search(r"M\.API_VERSION\s*=\s*(\d+)", text)
    if not version or not api:
        sys.stderr.write("cannot read the service version from %s\n" % VERSION_FILE)
        sys.exit(2)
    return version.group(1), api.group(1)


def main():
    version, api = read_version()
    script = os.path.join(ROOT, "tests", "fake_service.py")
    argv = [
        sys.executable,
        script,
        *sys.argv[1:],
        # The stand-in runs the real agent command, so a script that opens a
        # panel really talks ACP through the tunnel.
        "--spawn-agent",
        *(["--trace", os.environ["ADE_FAKE_TRACE"]] if os.environ.get("ADE_FAKE_TRACE") else []),
        "--server-version",
        version,
        "--api-version",
        api,
    ]
    os.execv(sys.executable, argv)


if __name__ == "__main__":
    main()
