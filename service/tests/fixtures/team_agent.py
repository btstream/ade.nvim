#!/usr/bin/env python3
"""A scriptable ACP agent for the team integration tests.

It is deliberately small: it speaks initialize/session/new/load/prompt, keeps
the `mcpServers` entry from `session/new`, and can call the real
`nvim_ade_server mcp` subprocess from a prompt. Prompt text and environment
choose the behavior; every prompt, request and MCP result is appended to
TEAM_AGENT_LOG as one JSON line.

Leader prompts (sent by the front end in the tests) may start with:

  spawn            call team_spawn (TEAM_AGENT_TEMPLATE, TEAM_AGENT_NAME)
  idle             just end the turn

Worker task bodies may contain:

  [report]         send a report to the leader
  [ask]            call bus_ask_human and end the turn
  [permission]     ask the client for permission and log the outcome
  [request]        send a custom client request and log the response
  [slow]           wait for TEAM_AGENT_GATE (or a cancel)
  [cancel]         wait for session/cancel, then end cancelled
"""

import json
import os
import subprocess
import sys
import threading
import time

LOG = os.environ.get("TEAM_AGENT_LOG")
PID = os.getpid()
GATE = os.environ.get("TEAM_AGENT_GATE")
TEMPLATE = os.environ.get("TEAM_AGENT_TEMPLATE", "dev")
NAME = os.environ.get("TEAM_AGENT_NAME")
# session id -> Event, set by `session/cancel` for that session only. A front
# end prompt after a cancelled bus prompt starts with a fresh event.
CANCEL = {}
NEXT_ID = [7000]
PENDING = {}
LOCK = threading.Lock()
SESSIONS = {}
MCP = {}
COUNT = [0]


def log(event):
    if not LOG:
        return
    with LOCK:
        event = {"pid": PID, **event}
        with open(LOG, "a", encoding="utf-8") as handle:
            handle.write(json.dumps(event) + "\n")


def send(message):
    with LOCK:
        print(json.dumps(message), flush=True)


def result(ident, value):
    send({"jsonrpc": "2.0", "id": ident, "result": value})


def error(ident, message):
    send({"jsonrpc": "2.0", "id": ident, "error": {"code": -32603, "message": message}})


def request_client(method, params, timeout=20, ident=None):
    with LOCK:
        if ident is None:
            NEXT_ID[0] += 1
            ident = NEXT_ID[0]
        slot = {"event": threading.Event(), "response": None}
        PENDING[ident] = slot
    send({"jsonrpc": "2.0", "id": ident, "method": method, "params": params})
    slot["event"].wait(timeout)
    return slot["response"]


def wait_gate(session, timeout=20):
    if not GATE:
        return
    event = CANCEL.get(session)
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline and not (event and event.is_set()):
        if os.path.exists(GATE):
            return
        time.sleep(0.02)


def wait_gate_ignore_cancel(timeout=20):
    if not GATE:
        return
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if os.path.exists(GATE):
            return
        time.sleep(0.02)


def mcp_call(session, tool, arguments):
    entry = MCP.get(session)
    if not entry:
        log({"event": "mcp-missing", "session": session})
        return {"isError": True, "content": [{"type": "text", "text": "no mcp server"}]}
    env = dict(os.environ)
    for item in entry.get("env") or []:
        if isinstance(item, dict) and "name" in item:
            env[item["name"]] = item.get("value", "")
    command = [entry["command"], *(entry.get("args") or [])]
    process = subprocess.Popen(
        command,
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        stderr=subprocess.DEVNULL,
        text=True,
        env=env,
    )
    frames = [
        {
            "jsonrpc": "2.0",
            "id": 1,
            "method": "initialize",
            "params": {"protocolVersion": "2025-06-18", "capabilities": {}, "clientInfo": {"name": "team-test"}},
        },
        {"jsonrpc": "2.0", "method": "notifications/initialized"},
        {"jsonrpc": "2.0", "id": 2, "method": "tools/call", "params": {"name": tool, "arguments": arguments}},
    ]
    try:
        for frame in frames:
            process.stdin.write(json.dumps(frame) + "\n")
        process.stdin.flush()
        process.stdin.close()
        response = None
        for line in process.stdout:
            try:
                value = json.loads(line)
            except ValueError:
                continue
            if value.get("id") == 2:
                response = value
                break
        process.wait(timeout=10)
    except Exception as problem:  # noqa: BLE001
        log({"event": "mcp-error", "tool": tool, "message": repr(problem)})
        return {"isError": True, "content": [{"type": "text", "text": repr(problem)}]}
    log({"event": "mcp", "tool": tool, "arguments": arguments, "response": response})
    if response is None:
        return {"isError": True, "content": [{"type": "text", "text": "no mcp response"}]}
    return response.get("result") or {"isError": True, "content": response.get("error")}


def mcp_list(session):
    entry = MCP.get(session)
    if not entry:
        return []
    env = dict(os.environ)
    for item in entry.get("env") or []:
        if isinstance(item, dict) and "name" in item:
            env[item["name"]] = item.get("value", "")
    process = subprocess.Popen(
        [entry["command"], *(entry.get("args") or [])],
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        stderr=subprocess.DEVNULL,
        text=True,
        env=env,
    )
    frames = [
        {"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {"protocolVersion": "2025-06-18", "capabilities": {}, "clientInfo": {"name": "team-test"}}},
        {"jsonrpc": "2.0", "method": "notifications/initialized"},
        {"jsonrpc": "2.0", "id": 2, "method": "tools/list", "params": {}},
    ]
    try:
        for frame in frames:
            process.stdin.write(json.dumps(frame) + "\n")
        process.stdin.flush()
        process.stdin.close()
        init_result = None
        for line in process.stdout:
            value = json.loads(line)
            if value.get("id") == 1:
                init_result = value.get("result")
            if value.get("id") == 2:
                names = [tool.get("name") for tool in (value.get("result") or {}).get("tools") or []]
                log({
                    "event": "tools",
                    "session": session,
                    "names": names,
                    "instructions": (init_result or {}).get("instructions"),
                })
                return names
        process.wait(timeout=10)
    except Exception as problem:  # noqa: BLE001
        log({"event": "tools-error", "message": repr(problem)})
    return []


def run_prompt(ident, text, session):
    log({"event": "prompt", "session": session, "text": text})
    send({
        "jsonrpc": "2.0",
        "method": "session/update",
        "params": {
            "sessionId": session,
            "update": {
                "sessionUpdate": "agent_message_chunk",
                "content": {"type": "text", "text": "working on it"},
            },
        },
    })
    try:
        if 'kind="answer"' in text:
            response = mcp_call(session, "bus_send", {"to": "leader", "kind": "report", "body": "answer report"})
            log({"event": "answer-report-response", "response": response})
            result(ident, {"stopReason": "end_turn"})
            return
        if text.startswith("spawn-task:"):
            task = text[len("spawn-task:"):].strip()
            response = mcp_call(session, "team_spawn", {"template": TEMPLATE, **({"name": NAME} if NAME else {}), "task": task})
            log({"event": "spawn-response", "response": response})
        elif "spawn-pair" in text:
            # Two spawn requests in one prompt: they must share a group (19.6).
            for name in ("w1", "w2"):
                response = mcp_call(session, "team_spawn", {"template": TEMPLATE, "name": name})
                log({"event": "spawn-response", "name": name, "response": response})
        elif text.startswith("spawn"):
            task = text[len("spawn"):].strip() or "do [report]"
            response = mcp_call(session, "team_spawn", {"template": TEMPLATE, **({"name": NAME} if NAME else {}), "task": task})
            log({"event": "spawn-response", "response": response})
        elif "[control-tool]" in text:
            response = mcp_call(session, "bus_send", {"to": "leader", "kind": "control", "body": "pause"})
            log({"event": "control-tool-response", "response": response})
        elif "[spawn-tool]" in text:
            response = mcp_call(session, "team_spawn", {"template": TEMPLATE})
            log({"event": "spawn-tool-response", "response": response})
        elif "[read-tool]" in text:
            response = mcp_call(session, "bus_read", {"participant": "leader"})
            log({"event": "read-tool-response", "response": response})
        elif "[cancelled]" in text:
            result(ident, {"stopReason": "cancelled"})
        elif "[error]" in text:
            error(ident, "boom")
        elif "[max-tokens]" in text:
            result(ident, {"stopReason": "max_tokens"})
        elif "[permission-string]" in text:
            response = request_client(
                "session/request_permission",
                {
                    "sessionId": session,
                    "toolCall": {"toolCallId": "perm", "kind": "edit", "title": "Edit file"},
                    "options": [
                        {"optionId": "allow", "name": "Allow", "kind": "allow_once"},
                        {"optionId": "reject", "name": "Reject", "kind": "reject_once"},
                    ],
                },
                ident="perm-1",
            )
            log({"event": "permission-string-response", "response": response})
        elif "[fs-string]" in text:
            response = request_client(
                "fs/read_text_file",
                {"sessionId": session, "path": "/etc/hostname"},
                ident="fs-1",
            )
            log({"event": "fs-string-response", "response": response})
        elif "[ask-report-slow]" in text:
            response = mcp_call(session, "bus_ask_human", {"question": "worker needs input", "options": ["yes", "no"]})
            log({"event": "ask-response", "response": response})
            report = mcp_call(session, "bus_send", {"to": "leader", "kind": "report", "body": "report while waiting"})
            log({"event": "report-response", "response": report})
            wait_gate(session)
        elif "[ask-chunk-slow]" in text:
            response = mcp_call(session, "bus_ask_human", {"question": "worker needs input", "options": ["yes", "no"]})
            log({"event": "ask-response", "response": response})
            send({
                "jsonrpc": "2.0",
                "method": "session/update",
                "params": {
                    "sessionId": session,
                    "update": {
                        "sessionUpdate": "agent_message_chunk",
                        "content": {"type": "text", "text": "late chunk"},
                    },
                },
            })
            wait_gate(session)
        elif "[ask-slow]" in text:
            response = mcp_call(session, "bus_ask_human", {"question": "worker needs input", "options": ["yes", "no"]})
            log({"event": "ask-response", "response": response})
            wait_gate(session)
        elif "[ask]" in text:
            response = mcp_call(session, "bus_ask_human", {"question": "worker needs input", "options": ["yes", "no"]})
            log({"event": "ask-response", "response": response})
        elif "[permission]" in text:
            response = request_client(
                "session/request_permission",
                {
                    "sessionId": session,
                    "toolCall": {"toolCallId": "perm", "kind": "edit", "title": "Edit file"},
                    "options": [
                        {"optionId": "allow", "name": "Allow", "kind": "allow_once"},
                        {"optionId": "reject", "name": "Reject", "kind": "reject_once"},
                    ],
                },
            )
            log({"event": "permission-response", "response": response})
        elif "[request]" in text:
            response = request_client("custom/thing", {"sessionId": session, "value": 1})
            log({"event": "custom-response", "response": response})
        elif "[fs]" in text:
            response = request_client("fs/read_text_file", {"sessionId": session, "path": "/etc/hostname"})
            log({"event": "fs-response", "response": response})
        elif "[chunk-slow]" in text:
            log({"event": "chunk", "text": "before waiting"})
            send({
                "jsonrpc": "2.0",
                "method": "session/update",
                "params": {
                    "sessionId": session,
                    "update": {
                        "sessionUpdate": "agent_message_chunk",
                        "content": {"type": "text", "text": "before waiting"},
                    },
                },
            })
            wait_gate(session)
            log({"event": "chunk", "text": "after waiting"})
            send({
                "jsonrpc": "2.0",
                "method": "session/update",
                "params": {
                    "sessionId": session,
                    "update": {
                        "sessionUpdate": "agent_message_chunk",
                        "content": {"type": "text", "text": "after waiting"},
                    },
                },
            })
            response = mcp_call(session, "bus_send", {"to": "leader", "kind": "report", "body": "worker report"})
            log({"event": "report-response", "response": response})
        elif "[report-slow]" in text:
            wait_gate(session)
            response = mcp_call(session, "bus_send", {"to": "leader", "kind": "report", "body": "worker report"})
            log({"event": "report-response", "response": response})
        elif "[slow-ignore-cancel]" in text:
            wait_gate_ignore_cancel()
        elif "[slow]" in text:
            wait_gate(session)
        elif "[cancel]" in text:
            event = CANCEL.get(session)
            deadline = time.monotonic() + 20
            while time.monotonic() < deadline and not (event and event.is_set()):
                time.sleep(0.02)
        elif "[card-update" in text:
            rest = text.split("[card-update", 1)[1].lstrip()
            arguments, _ = json.JSONDecoder().raw_decode(rest)
            calls = arguments if isinstance(arguments, list) else [arguments]
            for call in calls:
                response = mcp_call(session, "card_update", call)
                log({"event": "card-update-response", "arguments": call, "response": response})
        elif "[board-create]" in text:
            response = mcp_call(
                session,
                "board_update",
                {
                    "workflow_name": "dev",
                    "workflow": "flow text",
                    "columns": ["todo", "doing"],
                    "upsert": [
                        {"id": "T1", "title": "fix reconnect", "column": "doing", "owner": "w1"},
                        {"id": "T2", "title": "write docs", "column": "todo", "owner": "w1"},
                    ],
                },
            )
            log({"event": "board-create-response", "response": response})
        elif "[workflow-save]" in text:
            response = mcp_call(
                session,
                "workflow_save",
                {
                    "workflow": {
                        "name": "review_by_pi",
                        "summary": "w1 写代码，reviewer 审查",
                        "text": "1. w1 实现\n2. reviewer 审查",
                        "team": [{"name": "w1", "template": TEMPLATE}],
                        "columns": ["todo", "doing"],
                    },
                    "replace": True,
                },
            )
            log({"event": "workflow-save-response", "response": response})
        elif "[spawn-two]" in text:
            for _ in range(2):
                response = mcp_call(session, "team_spawn", {"template": TEMPLATE, "task": "do [report]"})
                log({"event": "spawn-response", "response": response})
        elif "[board-update]" in text:
            response = mcp_call(session, "board_update", {})
            log({"event": "board-update-response", "response": response})
        elif "[activity-tool]" in text:
            send({
                "jsonrpc": "2.0",
                "method": "session/update",
                "params": {
                    "sessionId": session,
                    "update": {
                        "sessionUpdate": "tool_call",
                        "toolCallId": "call-1",
                        "title": "Run cargo test",
                        "kind": "execute",
                        "status": "in_progress",
                    },
                },
            })
        elif "[activity-failed]" in text:
            send({
                "jsonrpc": "2.0",
                "method": "session/update",
                "params": {
                    "sessionId": session,
                    "update": {
                        "sessionUpdate": "tool_call_update",
                        "toolCallId": "call-2",
                        "title": "Edit hub.rs",
                        "status": "failed",
                    },
                },
            })
        elif "[activity-plan]" in text:
            send({
                "jsonrpc": "2.0",
                "method": "session/update",
                "params": {
                    "sessionId": session,
                    "update": {
                        "sessionUpdate": "plan",
                        "entries": [
                            {"content": "done", "priority": "medium", "status": "completed"},
                            {"content": "补 reconnect 的回归测试", "priority": "high", "status": "in_progress"},
                        ],
                    },
                },
            })
        elif "[activity-gated]" in text:
            wait_gate_ignore_cancel()
            for step in (1, 2):
                send({
                    "jsonrpc": "2.0",
                    "method": "session/update",
                    "params": {
                        "sessionId": session,
                        "update": {
                            "sessionUpdate": "tool_call",
                            "toolCallId": f"gated-{step}",
                            "title": f"gated step {step}",
                            "status": "in_progress",
                        },
                    },
                })
                time.sleep(0.05)
            # Stay working while the test watches the notification window.
            time.sleep(4)
        elif "[activity-slow]" in text:
            for step in (1, 2):
                send({
                    "jsonrpc": "2.0",
                    "method": "session/update",
                    "params": {
                        "sessionId": session,
                        "update": {
                            "sessionUpdate": "tool_call",
                            "toolCallId": f"step-{step}",
                            "title": f"step {step}",
                            "status": "in_progress",
                        },
                    },
                })
                time.sleep(0.05)
            wait_gate(session)
        elif "[report-task]" in text:
            response = mcp_call(
                session,
                "bus_send",
                {"to": "leader", "kind": "report", "task": "T4", "body": "first line\nsecond"},
            )
            log({"event": "report-response", "response": response})
        elif "[report]" in text:
            response = mcp_call(session, "bus_send", {"to": "leader", "kind": "report", "body": "worker report"})
            log({"event": "report-response", "response": response})
        event = CANCEL.get(session)
        if event and event.is_set():
            result(ident, {"stopReason": "cancelled"})
        else:
            result(ident, {"stopReason": "end_turn"})
        log({"event": "done", "session": session})
    except Exception as problem:  # noqa: BLE001
        log({"event": "error", "message": repr(problem)})
        error(ident, repr(problem))


def main():
    log({"event": "start", "gate": bool(GATE), "log": bool(LOG), "template": TEMPLATE})
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
                slot["response"] = message
                slot["event"].set()
            continue
        if method == "initialize":
            log({"event": "initialize", "params": params})
            load_session = os.environ.get("TEAM_AGENT_LOAD_SESSION", "1") != "0"
            result(
                ident,
                {
                    "protocolVersion": 1,
                    "agentCapabilities": {"loadSession": load_session},
                    "authMethods": [],
                },
            )
        elif method in ("session/new", "session/load", "session/resume"):
            fails = method == "session/load" and os.environ.get("TEAM_AGENT_LOAD_FAIL") == "1"
            if method == "session/new":
                COUNT[0] += 1
                session = f"team_sess_{os.getpid()}_{COUNT[0]}"
            else:
                session = params.get("sessionId", "team_sess")
            SESSIONS[session] = True
            for entry in params.get("mcpServers") or []:
                if entry.get("name") == "ade-team":
                    MCP[session] = entry
            entry = MCP.get(session)
            safe_entry = None
            if entry:
                safe_entry = {
                    "name": entry.get("name"),
                    "command": entry.get("command"),
                    "args": entry.get("args"),
                    "env_names": [item.get("name") for item in entry.get("env") or []],
                }
                # The token must never reach the agent log: write it to a
                # side file the tests read back.
                token_path = os.environ.get("TEAM_AGENT_TOKEN_FILE")
                if token_path:
                    for item in entry.get("env") or []:
                        if item.get("name") == "ADE_TEAM_TOKEN":
                            with open(token_path, "a") as handle:
                                handle.write(f"{session} {item.get('value')}\n")
            log({
                "event": "session",
                "method": method,
                "session": session,
                "mcp": bool(entry),
                "cwd": params.get("cwd"),
                "mcp_entry": safe_entry,
                "mcp_servers": [
                    item.get("name") for item in params.get("mcpServers") or []
                ],
            })
            load_delay = os.environ.get("TEAM_AGENT_LOAD_DELAY")
            if load_delay and method in ("session/load", "session/resume"):
                # A slow load lets the tests change the session state or
                # handshake the token while the request is in flight.
                time.sleep(float(load_delay))
            if fails:
                # The token was written above, so the service can have issued
                # and even handshaked it before this refusal.
                log({"event": "load-failed", "session": params.get("sessionId")})
                error(ident, "load failed")
                continue
            new_delay = os.environ.get("TEAM_AGENT_NEW_DELAY")
            if new_delay and method == "session/new":
                # The token was written above: answer late so the MCP process can
                # handshake before the session is bound.
                time.sleep(float(new_delay))
            if MCP.get(session) and os.environ.get("TEAM_AGENT_SKIP_MCP_LIST") != "1":
                mcp_list(session)
            if method == "session/load":
                # A distinguishable replay the tests can look for.
                send({
                    "jsonrpc": "2.0",
                    "method": "session/update",
                    "params": {
                        "sessionId": session,
                        "update": {
                            "sessionUpdate": "agent_message_chunk",
                            "content": {"type": "text", "text": "replayed-history"},
                        },
                    },
                })
            result(
                ident,
                {
                    "sessionId": session,
                    "configOptions": [
                        {"id": "model", "options": [{"value": "m1", "name": "M1"}, {"value": "m2", "name": "M2"}]}
                    ],
                },
            )
        elif method == "session/prompt":
            session = params.get("sessionId", "")
            CANCEL[session] = threading.Event()
            text = "".join(
                block.get("text", "")
                for block in (params.get("prompt") or [])
                if isinstance(block, dict)
            )
            threading.Thread(target=run_prompt, args=(ident, text, session), daemon=True).start()
        elif method == "session/cancel":
            session = params.get("sessionId", "")
            CANCEL.setdefault(session, threading.Event()).set()
            log({"event": "cancel", "session": session})
        elif method == "session/set_config_option":
            log({"event": "set_config", "params": params})
            delay = float(os.environ.get("TEAM_AGENT_SET_CONFIG_DELAY", "0") or "0")
            if delay > 0:
                time.sleep(delay)
            result(ident, {"configOptions": [{"id": "model", "currentValue": params.get("value")}]})
        else:
            if ident is not None:
                result(ident, {})


if __name__ == "__main__":
    main()
