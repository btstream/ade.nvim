#!/usr/bin/env python3
"""A scriptable ACP agent for the session-catalog tests (PROTOCOL.md 21).

It speaks `initialize`, `session/list`, `session/new`, `session/close`,
`session/delete` and answers client requests it made itself.

Environment knobs:

  CATALOG_AGENT_LOG            append one JSON event per line (initialize,
                               list, client_response, exit)
  CATALOG_AGENT_NO_LIST        omit `sessionCapabilities.list` (null)
  CATALOG_AGENT_INIT_FAIL      fail `initialize` with code 500
  CATALOG_AGENT_PAGES          JSON array of pages served in order:
                               [{"sessions": [...], "nextCursor": "c1"}, ...]
                               Default: one page with session `s1`
  CATALOG_AGENT_LIST_DELAY     seconds to sleep before answering `session/list`
  CATALOG_AGENT_LIST_ERROR     "code:message" error for every `session/list`
  CATALOG_AGENT_EXIT_ON_LIST   exit the process when `session/list` arrives
  CATALOG_AGENT_CLIENT_REQUEST send an `fs/read_text_file` request before the
                               first `session/list` answer
"""

import json
import os
import sys
import time

LOG = os.environ.get("CATALOG_AGENT_LOG")
PAGES = json.loads(
    os.environ.get(
        "CATALOG_AGENT_PAGES",
        '[{"sessions": [{"sessionId": "s1", "cwd": "/tmp/work", "title": "One"}]}]',
    )
)
LIST_DELAY = float(os.environ.get("CATALOG_AGENT_LIST_DELAY", "0"))
LIST_ERROR = os.environ.get("CATALOG_AGENT_LIST_ERROR")
NO_LIST = os.environ.get("CATALOG_AGENT_NO_LIST")
INIT_FAIL = os.environ.get("CATALOG_AGENT_INIT_FAIL")
EXIT_ON_LIST = os.environ.get("CATALOG_AGENT_EXIT_ON_LIST")
CLIENT_REQUEST = os.environ.get("CATALOG_AGENT_CLIENT_REQUEST")
PAGE = [0]
REQUESTED = [False]


def log(event):
    if not LOG:
        return
    with open(LOG, "a", encoding="utf-8") as handle:
        handle.write(json.dumps(event) + "\n")


def send(message):
    print(json.dumps(message), flush=True)


def result(ident, value):
    send({"jsonrpc": "2.0", "id": ident, "result": value})


def error(ident, code, message):
    send({"jsonrpc": "2.0", "id": ident, "error": {"code": code, "message": message}})


def handle(message):
    method = message.get("method")
    ident = message.get("id")
    if method is None:
        # A response to a client request we made.
        body = message.get("error") or message.get("result")
        log({"event": "client_response", "id": ident, "body": body})
        return

    if method == "initialize":
        log({"event": "initialize", "params": message.get("params")})
        if INIT_FAIL:
            error(ident, 500, "initialize refused")
            return
        capabilities = {"loadSession": True}
        capabilities["sessionCapabilities"] = (
            {"list": None} if NO_LIST else {"list": {}}
        )
        result(ident, {"protocolVersion": 1, "agentCapabilities": capabilities})
        return

    if method == "session/list":
        log({"event": "list", "params": message.get("params")})
        if EXIT_ON_LIST:
            sys.exit(0)
        if CLIENT_REQUEST and not REQUESTED[0]:
            REQUESTED[0] = True
            send(
                {
                    "jsonrpc": "2.0",
                    "id": 7001,
                    "method": "fs/read_text_file",
                    "params": {"sessionId": "s1", "path": "/tmp/x"},
                }
            )
        if LIST_DELAY:
            time.sleep(LIST_DELAY)
        if LIST_ERROR:
            code, text = LIST_ERROR.split(":", 1)
            error(ident, int(code), text)
            return
        index = min(PAGE[0], len(PAGES) - 1)
        PAGE[0] += 1
        page = PAGES[index] if PAGES else {"sessions": []}
        body = {"sessions": page.get("sessions", [])}
        cursor = page.get("nextCursor")
        if cursor is not None:
            body["nextCursor"] = cursor
        result(ident, body)
        return

    if method in ("session/new", "session/close", "session/delete"):
        log({"event": method})
        if method == "session/new":
            result(ident, {"sessionId": "agent-session"})
        else:
            result(ident, {})
        return

    if ident is not None:
        error(ident, -32601, "method not found")


def main():
    try:
        for line in sys.stdin:
            line = line.strip()
            if not line:
                continue
            try:
                message = json.loads(line)
            except json.JSONDecodeError:
                continue
            handle(message)
    finally:
        log({"event": "exit"})


if __name__ == "__main__":
    main()
