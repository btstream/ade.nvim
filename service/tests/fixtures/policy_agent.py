#!/usr/bin/env python3
"""A minimal ACP agent for the server-side permission-policy tests.

It only speaks what the tests need: initialize, session/new, session/load,
session/prompt, session/cancel and session/request_permission. Prompt text picks
the permission shape; `POLICY_AGENT_GATE` can hold a request until a file
appears, so a test can detach or cancel at a deterministic point.

Every answer is appended to `POLICY_AGENT_LOG` as one JSON line.
"""

import json
import os
import sys
import threading
import time

LOCK = threading.Lock()
NEXT_ID = [9100]
PENDING = {}
LOG = os.environ.get("POLICY_AGENT_LOG")
GATE = os.environ.get("POLICY_AGENT_GATE")
SESSION = [0]


def log(event):
    if not LOG:
        return
    with open(LOG, "a", encoding="utf-8") as handle:
        handle.write(json.dumps(event) + "\n")


def send(message):
    with LOCK:
        print(json.dumps(message), flush=True)


def result(ident, value):
    send({"jsonrpc": "2.0", "id": ident, "result": value})


def request_client(method, params, timeout=15):
    with LOCK:
        NEXT_ID[0] += 1
        ident = NEXT_ID[0]
        slot = {"event": threading.Event(), "response": None}
        PENDING[ident] = slot
    send({"jsonrpc": "2.0", "id": ident, "method": method, "params": params})
    if not slot["event"].wait(timeout):
        return ident, None
    return ident, slot["response"]


def wait_gate():
    if not GATE:
        return
    deadline = time.monotonic() + 15
    while time.monotonic() < deadline:
        if os.path.exists(GATE):
            return
        time.sleep(0.02)


def ask_permission(session, tool, options, index, wait=False):
    if wait:
        wait_gate()
    _, response = request_client(
        "session/request_permission",
        {"sessionId": session, "toolCall": tool, "options": options},
    )
    body = (response or {}).get("result") or {}
    outcome = body.get("outcome") or {}
    log(
        {
            "event": "permission",
            "index": index,
            "outcome": outcome.get("outcome"),
            "optionId": outcome.get("optionId"),
        }
    )
    return outcome


ALLOW_REJECT = [
    {"optionId": "allow", "name": "Allow", "kind": "allow_once"},
    {"optionId": "reject", "name": "Reject", "kind": "reject_once"},
]


def run_prompt(ident, text, session):
    try:
        if text.startswith("paths:"):
            tool = json.loads(text[len("paths:") :])
            ask_permission(session, tool, ALLOW_REJECT, 1)
        elif text.startswith("large:"):
            ask_permission(
                session,
                {"toolCallId": "large", "kind": "edit", "rawInput": "x" * (70 * 1024)},
                ALLOW_REJECT,
                1,
            )
        elif text == "permission-gate":
            ask_permission(session, {"toolCallId": "gate", "kind": "edit"}, ALLOW_REJECT, 1, wait=True)
        elif text == "question":
            ask_permission(
                session,
                {
                    "toolCallId": "question",
                    "kind": "other",
                    "rawInput": {"method": "select", "title": "Pick one"},
                },
                [
                    {"optionId": "a", "kind": "allow_once"},
                    {"optionId": "b", "kind": "allow_once"},
                ],
                1,
            )
        elif text == "turn-two":
            ask_permission(session, {"toolCallId": "one", "kind": "edit"}, ALLOW_REJECT, 1)
            ask_permission(session, {"toolCallId": "two", "kind": "edit"}, ALLOW_REJECT, 2, wait=True)
        elif text == "permission":
            ask_permission(session, {"toolCallId": "perm", "kind": "edit"}, ALLOW_REJECT, 1)
        result(ident, {"stopReason": "end_turn"})
    except Exception as error:  # noqa: BLE001 - the test reads the log instead
        log({"event": "error", "message": repr(error)})
        send(
            {
                "jsonrpc": "2.0",
                "id": ident,
                "error": {"code": -32603, "message": repr(error)},
            }
        )


def main():
    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue
        message = json.loads(line)
        method = message.get("method")
        ident = message.get("id")
        params = message.get("params") or {}
        if method is None:
            slot = PENDING.get(ident)
            if slot is not None:
                with LOCK:
                    slot["response"] = message
                slot["event"].set()
            continue
        if method == "initialize":
            result(
                ident,
                {
                    "protocolVersion": 1,
                    "agentCapabilities": {"loadSession": True},
                    "authMethods": [],
                },
            )
        elif method == "session/new":
            SESSION[0] += 1
            result(ident, {"sessionId": f"sess_policy_{SESSION[0]}", "configOptions": []})
        elif method == "session/load":
            result(ident, {"configOptions": []})
        elif method == "session/resume":
            result(ident, {"sessionId": params.get("sessionId", "sess_policy")})
        elif method == "session/prompt":
            threading.Thread(
                target=run_prompt,
                args=(
                    ident,
                    params.get("prompt", [{}])[0].get("text", ""),
                    params.get("sessionId", "sess_policy"),
                ),
                daemon=True,
            ).start()
        elif method == "session/cancel":
            log({"event": "cancel", "sessionId": params.get("sessionId")})
        else:
            if ident is not None:
                result(ident, {})


if __name__ == "__main__":
    main()
