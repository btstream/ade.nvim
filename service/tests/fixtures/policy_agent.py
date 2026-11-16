#!/usr/bin/env python3
"""A minimal ACP agent for the permission-policy tests.

It only speaks what the tests need: initialize, session/new, session/load,
session/resume, session/prompt, session/cancel and
session/request_permission. Prompt text picks the permission shape;
`POLICY_AGENT_GATE` can hold a request until a file appears, so a test can
detach or cancel at a deterministic point.

Normal prompts:

  permission         one edit permission, immediately
  permission-gate    one edit permission after `POLICY_AGENT_GATE` exists
  question           a pi-style select question (never policy-decided)
  turn-two           one permission, then a second one after the gate
  paths:<json>       the tool call in the JSON, one permission
  large:             a tool call with 70 KiB of rawInput
  delayed-permission waits `POLICY_AGENT_DELAY` seconds (default 3), then asks
  delayed-question   waits the same, then asks a question

Inline prompts (`INLINE_BUFFER_EDIT:`) parse the private copy and source paths
from the generated prompt and run the sequence named by the user's request:

  policy-full        edit copy, edit source, edit another file, read source,
                     ask a question, then change the copy
  policy-cancel      edit copy, wait for the gate (the test cancelled first),
                     then another edit
  policy-hold        edit copy, then wait for the gate
  policy-symlink     replace the copy with a symlink to the source, then edit
  policy-hardlink    replace the copy with a hard link to the source, then edit
  anything else      edit the copy

Every answer is appended to `POLICY_AGENT_LOG` as one JSON line.
"""

import json
import os
import re
import sys
import threading
import time

LOCK = threading.Lock()
LOG_LOCK = threading.Lock()
NEXT_ID = [9100]
PENDING = {}
LOG = os.environ.get("POLICY_AGENT_LOG")
GATE = os.environ.get("POLICY_AGENT_GATE")
DELAY = float(os.environ.get("POLICY_AGENT_DELAY", "3"))
SESSION = [0]


def log(event):
    if not LOG:
        return
    with LOG_LOCK:
        with open(LOG, "a", encoding="utf-8") as handle:
            handle.write(json.dumps(event) + "\n")


def send(message):
    with LOCK:
        print(json.dumps(message), flush=True)


def result(ident, value):
    send({"jsonrpc": "2.0", "id": ident, "result": value})


def update(session, update_obj):
    send(
        {
            "jsonrpc": "2.0",
            "method": "session/update",
            "params": {"sessionId": session, "update": update_obj},
        }
    )


def say(session, text):
    update(
        session,
        {
            "sessionUpdate": "agent_message_chunk",
            "content": {"type": "text", "text": text},
        },
    )


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


def wait_gate(timeout=15):
    if not GATE:
        return
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if os.path.exists(GATE):
            return
        time.sleep(0.02)


def ask_permission(session, tool, options, index, wait=False):
    if wait:
        wait_gate()
    log(
        {
            "event": "ask",
            "session": session,
            "index": index,
            "toolCallId": tool.get("toolCallId"),
            "kind": tool.get("kind"),
        }
    )
    _, response = request_client(
        "session/request_permission",
        {"sessionId": session, "toolCall": tool, "options": options},
    )
    body = (response or {}).get("result") or {}
    outcome = body.get("outcome") or {}
    log(
        {
            "event": "permission",
            "session": session,
            "index": index,
            "toolCallId": tool.get("toolCallId"),
            "kind": tool.get("kind"),
            "outcome": outcome.get("outcome"),
            "optionId": outcome.get("optionId"),
        }
    )
    return outcome


ALLOW_REJECT = [
    {"optionId": "allow", "name": "Allow", "kind": "allow_once"},
    {"optionId": "reject", "name": "Reject", "kind": "reject_once"},
]


def inline_paths(text):
    copy = re.search(r"private buffer copy at `([^`\n]+)`", text)
    source = re.search(r"The original file at `([^`\n]+)`", text)
    return (
        copy.group(1) if copy else None,
        source.group(1) if source else None,
    )


def edit_at(path, ident):
    return {
        "toolCallId": ident,
        "kind": "edit",
        "title": "Edit " + os.path.basename(path),
        "locations": [{"path": path}],
    }


def ask_question(session, index):
    return ask_permission(
        session,
        {
            "toolCallId": "question",
            "kind": "other",
            "title": "Pick one",
            "rawInput": {"method": "select", "title": "Pick one"},
        },
        [
            {"optionId": "a", "name": "A", "kind": "allow_once"},
            {"optionId": "b", "name": "B", "kind": "allow_once"},
        ],
        index,
    )


def run_inline(text, session):
    copy, source = inline_paths(text)
    other = (source or copy or "/tmp/ade-policy-other") + ".other"
    mode = "default"
    for candidate in ("full", "cancel", "hold", "symlink", "hardlink"):
        if "policy-" + candidate in text:
            mode = candidate
            break
    log(
        {
            "event": "inline",
            "mode": mode,
            "copy": copy,
            "source": source,
            "session": session,
        }
    )
    if mode == "symlink" and copy and source:
        os.unlink(copy)
        os.symlink(source, copy)
        ask_permission(session, edit_at(copy, "copy"), ALLOW_REJECT, 1)
        return
    if mode == "hardlink" and copy and source:
        os.unlink(copy)
        os.link(source, copy)
        ask_permission(session, edit_at(copy, "copy"), ALLOW_REJECT, 1)
        return
    if mode == "hold" and copy:
        ask_permission(session, edit_at(copy, "copy"), ALLOW_REJECT, 1)
        wait_gate()
        return
    if mode == "cancel" and copy:
        ask_permission(session, edit_at(copy, "copy"), ALLOW_REJECT, 1)
        wait_gate()
        ask_permission(session, edit_at(other, "other"), ALLOW_REJECT, 2)
        return
    if mode == "full" and copy and source:
        ask_permission(session, edit_at(copy, "copy"), ALLOW_REJECT, 1)
        ask_permission(session, edit_at(source, "source"), ALLOW_REJECT, 2)
        ask_permission(session, edit_at(other, "other"), ALLOW_REJECT, 3)
        ask_permission(
            session,
            {
                "toolCallId": "read",
                "kind": "read",
                "title": "Read " + os.path.basename(source),
                "locations": [{"path": source}],
            },
            ALLOW_REJECT,
            4,
        )
        ask_question(session, 5)
        with open(copy, encoding="utf-8") as handle:
            data = handle.read()
        with open(copy, "w", encoding="utf-8") as handle:
            handle.write(data.replace("alpha", "omega", 1))
        return
    if copy:
        ask_permission(session, edit_at(copy, "copy"), ALLOW_REJECT, 1)


def run_prompt(ident, text, session):
    try:
        if text.startswith("INLINE_BUFFER_EDIT:"):
            run_inline(text, session)
        elif text.startswith("paths:"):
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
            ask_question(session, 1)
        elif text == "turn-two":
            ask_permission(session, {"toolCallId": "one", "kind": "edit"}, ALLOW_REJECT, 1)
            ask_permission(session, {"toolCallId": "two", "kind": "edit"}, ALLOW_REJECT, 2, wait=True)
        elif text == "permission":
            ask_permission(session, {"toolCallId": "perm", "kind": "edit"}, ALLOW_REJECT, 1)
        elif text == "delayed-permission":
            say(session, "working")
            time.sleep(DELAY)
            ask_permission(
                session,
                {
                    "toolCallId": "delayed",
                    "kind": "edit",
                    "title": "Write notes.txt",
                    "locations": [{"path": "notes.txt"}],
                },
                ALLOW_REJECT,
                1,
            )
            say(session, "done")
        elif text == "delayed-question":
            say(session, "working")
            time.sleep(DELAY)
            ask_question(session, 1)
            say(session, "done")
        else:
            say(session, "done")
        result(ident, {"stopReason": "end_turn"})
        log({"event": "done", "text": text[:80], "session": session})
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
