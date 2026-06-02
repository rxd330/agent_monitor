#!/usr/bin/env python3
"""Hermes shell hook: report lifecycle status to local AgentMonitor.

Install this file somewhere stable, for example:

    mkdir -p ~/.hermes/agent-hooks
    cp templates/hermes-agent-monitor-status.py ~/.hermes/agent-hooks/agent-monitor-status.py
    chmod +x ~/.hermes/agent-hooks/agent-monitor-status.py

Then configure Hermes shell hooks to run it for lifecycle events.

The script is observer-only: it reads Hermes hook JSON from stdin, posts a
best-effort status update to AgentMonitor, writes optional diagnostics to a log,
and exits 0 with empty stdout so monitor downtime never breaks Hermes.
"""
from __future__ import annotations

import json
import os
import socket
import subprocess
import sys
import urllib.parse
import urllib.request
from datetime import datetime, timezone
from pathlib import Path

DEFAULT_ENDPOINT = "http://127.0.0.1:8765"
BASE_AGENT_ID = os.environ.get("HERMES_AGENT_MONITOR_ID", "hermes-default-cli")
BASE_AGENT_NAME = os.environ.get("HERMES_AGENT_MONITOR_NAME", "Hermes CLI")
ENDPOINT = os.environ.get("AGENT_MONITOR_URL") or os.environ.get("HERMES_AGENT_MONITOR_URL") or DEFAULT_ENDPOINT
LOG_PATH = Path(os.environ.get("HERMES_AGENT_MONITOR_HOOK_LOG", "~/.hermes/logs/agent-monitor-hook.log")).expanduser()
TIMEOUT_SECONDS = float(os.environ.get("HERMES_AGENT_MONITOR_TIMEOUT", "0.7"))


def _read_payload() -> dict:
    try:
        raw = sys.stdin.read()
        return json.loads(raw) if raw.strip() else {}
    except Exception:
        return {}


def _short(value: object, limit: int = 120) -> str:
    text = str(value or "").replace("\n", " ").strip()
    return text if len(text) <= limit else text[: limit - 1] + "…"


def _message_for(payload: dict) -> tuple[str, str]:
    event = payload.get("hook_event_name") or "unknown"
    tool = payload.get("tool_name") or ""
    tool_input_raw = payload.get("tool_input")
    tool_input = tool_input_raw if isinstance(tool_input_raw, dict) else {}
    extra_raw = payload.get("extra")
    extra = extra_raw if isinstance(extra_raw, dict) else {}

    if event == "on_session_start":
        return "yellow", "initializing session"
    if event == "pre_gateway_dispatch":
        text = extra.get("text") or payload.get("text") or ""
        return "yellow", f"waking up: {_short(text, 90)}" if text else "waking up"
    if event == "pre_llm_call":
        user_msg = payload.get("user_message") or extra.get("user_message") or extra.get("message") or ""
        return "yellow", f"waking up / thinking: {_short(user_msg, 90)}" if user_msg else "waking up / thinking"
    if event == "pre_api_request":
        model = payload.get("model") or extra.get("model") or ""
        provider = payload.get("provider") or extra.get("provider") or ""
        label = "/".join(part for part in (provider, model) if part)
        return "yellow", f"calling model: {_short(label, 100)}" if label else "calling model"
    if event in {"post_api_request", "post_llm_call"}:
        return "yellow", "model response received; continuing"
    if event == "pre_tool_call":
        detail = ""
        if tool == "terminal":
            detail = _short(tool_input.get("command"), 90)
        elif tool in {"read_file", "write_file", "patch"}:
            detail = _short(tool_input.get("path"), 90)
        elif tool == "browser_navigate":
            detail = _short(tool_input.get("url"), 90)
        return "yellow", f"using {tool}: {detail}" if detail else f"using {tool or 'tool'}"
    if event == "post_tool_call":
        return "yellow", f"finished {tool}; continuing" if tool else "tool finished; continuing"
    if event == "pre_approval_request":
        command = extra.get("command") or payload.get("command") or ""
        desc = extra.get("description") or "approval required"
        return "red", f"waiting for approval: {_short(desc, 55)} {_short(command, 70)}".strip()
    if event == "post_approval_response":
        choice = extra.get("choice") or "responded"
        if choice in {"deny", "timeout"}:
            return "red", f"approval {choice}; waiting for human direction"
        return "yellow", f"approval {choice}; continuing"
    if event == "subagent_stop":
        return "yellow", "subagent finished; continuing"
    if event == "transform_llm_output":
        return "green", "finished response"
    if event in {"on_session_end", "on_session_finalize"}:
        return "green", "session ended"
    if event == "on_session_reset":
        return "green", "session reset"
    return "yellow", f"event: {event}"


def _detect_tty() -> str:
    """Best-effort terminal id for focusing an existing Terminal/iTerm tab."""
    env_tty = os.environ.get("AGENT_MONITOR_TERMINAL_TAG") or os.environ.get("HERMES_AGENT_MONITOR_TERMINAL_TAG")
    if env_tty:
        return env_tty.removeprefix("/dev/")

    for stream in (sys.stdin, sys.stdout, sys.stderr):
        try:
            if stream.isatty():
                return os.ttyname(stream.fileno()).removeprefix("/dev/")
        except Exception:
            pass

    # Hooks usually receive JSON on stdin, so stdin is not a TTY. Walk ancestors
    # and ask ps for the controlling terminal. On macOS this usually discovers
    # the Terminal.app/iTerm2 tab's ttysNNN.
    seen: set[int] = set()
    pid = os.getpid()
    for _ in range(8):
        if pid <= 1 or pid in seen:
            break
        seen.add(pid)
        try:
            tty = subprocess.check_output(
                ["/bin/ps", "-o", "tty=", "-p", str(pid)],
                text=True,
                stderr=subprocess.DEVNULL,
                timeout=0.2,
            ).strip()
            if tty and tty != "??":
                return tty.removeprefix("/dev/")
        except Exception:
            pass
        try:
            ppid = subprocess.check_output(
                ["/bin/ps", "-o", "ppid=", "-p", str(pid)],
                text=True,
                stderr=subprocess.DEVNULL,
                timeout=0.2,
            ).strip()
            pid = int(ppid)
        except Exception:
            break
    return ""


def _record_id(session_id: object, tty: str) -> str:
    """Stable AgentMonitor row id for this process/session.

    Do not post all Hermes sessions to one static id like hermes-default-cli.
    Concurrent Hermes terminals in the same folder would overwrite each other.
    Prefer TTY because it is stable across hook events from the same tab even
    when some payloads omit session_id; fall back to session_id for non-TTY runs.
    """
    explicit = os.environ.get("HERMES_AGENT_MONITOR_SESSION_ID") or ""
    suffix = explicit or str(tty or "").strip() or str(session_id or "").strip()
    if not suffix:
        return BASE_AGENT_ID
    return f"{BASE_AGENT_ID}:{suffix}"


def _display_name(session_id: object, tty: str) -> str:
    suffix = str(tty or "").strip() or str(session_id or "").strip()
    if not suffix:
        return BASE_AGENT_NAME
    return f"{BASE_AGENT_NAME} · {suffix[-8:]}"


def _post(state: str, message: str, payload: dict) -> None:
    session_id = payload.get("session_id") or ""
    cwd = payload.get("cwd") or os.environ.get("PWD") or os.getcwd()
    tty = _detect_tty()
    terminal_tag = tty or str(session_id) or BASE_AGENT_ID
    record_id = _record_id(session_id, tty)
    body = {
        "state": state,
        "name": _display_name(session_id, tty),
        "message": message,
        "metadata": {
            "runtime": "hermes",
            "profile": os.environ.get("HERMES_PROFILE", "default"),
            "base_agent_id": BASE_AGENT_ID,
            "session_id": str(session_id),
            "cwd": str(cwd),
            "tty": str(tty),
            "terminal_tag": str(terminal_tag),
            "host": socket.gethostname(),
            "pid": str(os.getpid()),
            "ppid": str(os.getppid()),
            "updated_by": "hermes-shell-hook",
        },
    }
    url = ENDPOINT.rstrip("/") + "/agents/" + urllib.parse.quote(record_id, safe="")
    req = urllib.request.Request(
        url,
        data=json.dumps(body).encode("utf-8"),
        headers={"Content-Type": "application/json"},
        method="POST",
    )
    with urllib.request.urlopen(req, timeout=TIMEOUT_SECONDS) as response:
        response.read(256)


def _log(record: dict) -> None:
    try:
        LOG_PATH.parent.mkdir(parents=True, exist_ok=True)
        with LOG_PATH.open("a", encoding="utf-8") as f:
            f.write(json.dumps(record, ensure_ascii=False) + "\n")
    except Exception:
        pass


def main() -> int:
    payload = _read_payload()
    state, message = _message_for(payload)
    try:
        _post(state, message, payload)
        _log({"ts": datetime.now(timezone.utc).isoformat(), "ok": True, "state": state, "message": message})
    except Exception as exc:
        _log({"ts": datetime.now(timezone.utc).isoformat(), "ok": False, "error": str(exc), "state": state, "message": message})
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
