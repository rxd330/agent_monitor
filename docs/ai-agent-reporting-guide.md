# AI agent reporting guide for AgentMonitor

AgentMonitor is intentionally simple: every agent reports its current state to a
local HTTP API, and the macOS menu-bar/floating widget renders one row per
reported agent/session.

This guide is for AI agents and agent authors who want to connect their runtime
to AgentMonitor, preferably through lifecycle hooks. The examples assume the app
is listening on the default local address:

```text
http://127.0.0.1:8765
```

If you run AgentMonitor with a different port, set `AGENT_MONITOR_PORT` or
`HERMES_AGENT_MONITOR_URL` as shown below.

## 1. The contract

### States

Use exactly one of these states:

| State | Meaning | Typical events |
| --- | --- | --- |
| `green` | Finished, idle, no blocker | response complete, task succeeded, session ended |
| `yellow` | Actively working | thinking, model call, tool call, tests/builds running |
| `red` | Human attention needed | approval prompt, credentials needed, blocked, failed action |

### API endpoints

```text
GET    /health
GET    /agents
POST   /agents/{agent-id}
DELETE /agents/{agent-id}
DELETE /agents
```

The important one is:

```text
POST http://127.0.0.1:8765/agents/{agent-id}
Content-Type: application/json

{
  "state": "green|yellow|red",
  "name": "Human readable row name",
  "message": "short current status",
  "metadata": {
    "runtime": "hermes|claude-code|codex|opencode|custom",
    "cwd": "/path/to/project",
    "terminal_tag": "ttys001",
    "tty": "ttys001",
    "session_id": "optional-runtime-session-id",
    "base_agent_id": "optional-grouping-id",
    "terminal_app": "auto|Terminal|iTerm2"
  }
}
```

AgentMonitor stores the latest update for each `{agent-id}`. Sending another
POST to the same id updates that row. Sending to a different id creates another
row.

### Identity: make row ids session-specific

Do not use only the project folder as identity. Do not post all instances of a
runtime to one static id like `hermes-default-cli` or `claude-code`. If two
agent sessions are opened in the same folder, a static id makes them overwrite
each other.

Recommended id shape:

```text
{runtime-or-profile}:{tty-or-session-id}
```

Examples:

```text
hermes-default-cli:ttys000
hermes-default-cli:20260601_213316_21edea
claude-code:ttys004
codex-auth-worker:ttys007
```

Prefer terminal TTY when available because it stays stable across lifecycle
events from the same terminal tab, even if some hook payloads omit a session id.
If there is no TTY, use the runtime's session id. Keep the grouping id in
`metadata.base_agent_id` if you want to show or debug the broader runtime/profile.

### Terminal focusing metadata

To make the row's terminal button useful, include:

- `metadata.cwd`: working directory to open if no existing tab is found.
- `metadata.terminal_tag` or `metadata.tty`: stable value the app can match
  against Terminal.app/iTerm2 tabs.
- `metadata.terminal_app`: optional preference, `auto`, `Terminal`, or `iTerm2`.

Acceptable TTY forms are both `ttys001` and `/dev/ttys001`; AgentMonitor
normalizes both. Avoid storing bogus values such as `not a tty` or `??`.

## 2. Quick manual reporting with curl

Create/update a row:

```bash
curl -fsS -X POST 'http://127.0.0.1:8765/agents/demo-agent:ttys001' \
  -H 'Content-Type: application/json' \
  -d '{
    "state": "yellow",
    "name": "Demo Agent",
    "message": "running tests",
    "metadata": {
      "runtime": "custom",
      "base_agent_id": "demo-agent",
      "cwd": "/Users/you/project",
      "tty": "ttys001",
      "terminal_tag": "ttys001",
      "terminal_app": "auto"
    }
  }'
```

List rows:

```bash
curl -fsS 'http://127.0.0.1:8765/agents'
```

Delete a row:

```bash
curl -fsS -X DELETE 'http://127.0.0.1:8765/agents/demo-agent:ttys001'
```

Clear all rows:

```bash
curl -fsS -X DELETE 'http://127.0.0.1:8765/agents'
```

## 3. Quick manual reporting with the helper

The repository includes a small helper that JSON-escapes the payload and posts to
AgentMonitor:

```bash
scripts/agent-monitor <agent-id> <green|yellow|red> [message] [display-name] [terminal-tag]
scripts/agent-monitor list
scripts/agent-monitor clear
```

Examples:

```bash
scripts/agent-monitor hermes-main:ttys001 yellow "running tests" "Hermes main" "ttys001"
scripts/agent-monitor hermes-main:ttys001 red "waiting for approval" "Hermes main" "ttys001"
scripts/agent-monitor hermes-main:ttys001 green "finished" "Hermes main" "ttys001"
```

Environment variables supported by the helper:

```bash
AGENT_MONITOR_HOST=127.0.0.1        # default
AGENT_MONITOR_PORT=8765             # default
AGENT_MONITOR_CWD=/path/to/project  # default: current directory
AGENT_MONITOR_TERMINAL_TAG=ttys001  # optional
AGENT_MONITOR_TERMINAL_APP=auto     # auto, Terminal, or iTerm2
```

When integrating through hooks, always make monitor calls best-effort:

```bash
/path/to/scripts/agent-monitor "$AGENT_ID" yellow "thinking" "$AGENT_NAME" "$TTY" >/dev/null 2>&1 || true
```

That pattern prevents AgentMonitor downtime from breaking the agent.

## 4. Hook integration pattern for any agent runtime

A good hook adapter follows this shape:

1. Read the runtime hook payload from stdin or environment.
2. Map the runtime event to `green`, `yellow`, or `red`.
3. Determine a stable row id:
   - base id: runtime/profile/project label
   - suffix: controlling TTY if available, otherwise runtime session id
4. Include metadata:
   - runtime
   - base_agent_id
   - session_id when available
   - cwd
   - tty / terminal_tag
   - pid / ppid if useful for debugging
5. POST to AgentMonitor with a short timeout.
6. Swallow all errors and exit 0.
7. Produce no stdout unless the host runtime expects hook output.

Recommended event mapping:

| Runtime event | AgentMonitor state | Message example |
| --- | --- | --- |
| session start | `yellow` | `initializing session` |
| user message received | `yellow` | `waking up` |
| model request starts | `yellow` | `calling model` |
| tool starts | `yellow` | `using terminal: swift test` |
| approval/input requested | `red` | `waiting for approval` |
| approval denied/timed out | `red` | `approval denied; waiting for direction` |
| tool/model response received | `yellow` | `continuing` |
| final answer emitted | `green` | `finished response` |
| task/process failed | `red` | `failed: exit 1` |
| session ended/reset | `green` | `session ended` |

### Portable shell TTY detection

Use this when a hook command runs from a real terminal:

```bash
detect_tty() {
  value="$(tty 2>/dev/null || true)"
  case "$value" in
    /dev/*) printf '%s' "${value#/dev/}" ;;
    ttys*|tty*) printf '%s' "$value" ;;
    *) printf '' ;;
  esac
}
```

Some hook systems pipe JSON on stdin, so `tty` may print `not a tty`. In that
case, use runtime-provided session ids, or walk the parent process tree like the
Hermes template does.

## 5. Hermes Agent via shell hooks

Hermes has first-class shell hooks in `~/.hermes/config.yaml`. The template in
this repository is:

```text
templates/hermes-agent-monitor-status.py
```

Install it:

```bash
mkdir -p ~/.hermes/agent-hooks
cp /Users/ruizhe.deng/Developer/agent_monitor/templates/hermes-agent-monitor-status.py \
  ~/.hermes/agent-hooks/agent-monitor-status.py
chmod +x ~/.hermes/agent-hooks/agent-monitor-status.py
```

Optional environment overrides:

```bash
export HERMES_AGENT_MONITOR_ID=hermes-default-cli
export HERMES_AGENT_MONITOR_NAME="Hermes CLI"
export HERMES_AGENT_MONITOR_URL=http://127.0.0.1:8765
export HERMES_AGENT_MONITOR_TIMEOUT=0.7
export HERMES_AGENT_MONITOR_HOOK_LOG=~/.hermes/logs/agent-monitor-hook.log
```

Add hooks to `~/.hermes/config.yaml` with `hermes config edit`:

```yaml
hooks:
  on_session_start:
  - command: /Users/you/.hermes/agent-hooks/agent-monitor-status.py
    timeout: 2
  pre_gateway_dispatch:
  - command: /Users/you/.hermes/agent-hooks/agent-monitor-status.py
    timeout: 2
  pre_llm_call:
  - command: /Users/you/.hermes/agent-hooks/agent-monitor-status.py
    timeout: 2
  pre_api_request:
  - command: /Users/you/.hermes/agent-hooks/agent-monitor-status.py
    timeout: 2
  post_api_request:
  - command: /Users/you/.hermes/agent-hooks/agent-monitor-status.py
    timeout: 2
  post_llm_call:
  - command: /Users/you/.hermes/agent-hooks/agent-monitor-status.py
    timeout: 2
  pre_tool_call:
  - matcher: .*
    command: /Users/you/.hermes/agent-hooks/agent-monitor-status.py
    timeout: 2
  post_tool_call:
  - matcher: .*
    command: /Users/you/.hermes/agent-hooks/agent-monitor-status.py
    timeout: 2
  pre_approval_request:
  - command: /Users/you/.hermes/agent-hooks/agent-monitor-status.py
    timeout: 2
  post_approval_response:
  - command: /Users/you/.hermes/agent-hooks/agent-monitor-status.py
    timeout: 2
  subagent_stop:
  - command: /Users/you/.hermes/agent-hooks/agent-monitor-status.py
    timeout: 2
  transform_llm_output:
  - command: /Users/you/.hermes/agent-hooks/agent-monitor-status.py
    timeout: 2
  on_session_end:
  - command: /Users/you/.hermes/agent-hooks/agent-monitor-status.py
    timeout: 2
  on_session_finalize:
  - command: /Users/you/.hermes/agent-hooks/agent-monitor-status.py
    timeout: 2
  on_session_reset:
  - command: /Users/you/.hermes/agent-hooks/agent-monitor-status.py
    timeout: 2
```

Validate:

```bash
hermes hooks list
hermes hooks doctor
hermes hooks test pre_llm_call
curl -fsS http://127.0.0.1:8765/agents
```

Important: Hermes registers shell hooks at process startup. Restart existing
Hermes sessions after changing hook config.

### Hermes same-folder session behavior

The template posts Hermes rows as:

```text
${HERMES_AGENT_MONITOR_ID:-hermes-default-cli}:${tty-or-session_id}
```

This is deliberate. Two Hermes sessions can be opened in the same folder, and
both must remain separate in AgentMonitor. TTY is preferred when available so
hook events with and without `session_id` still update the same row for the same
terminal tab.

## 6. Claude Code hooks

Claude Code supports project hooks in `.claude/settings.json` and global hooks in
`~/.claude/settings.json`. The repository includes a starter template:

```text
templates/claude-code-agent-monitor.settings.json
```

Project-local setup:

```bash
mkdir -p .claude
cp /Users/ruizhe.deng/Developer/agent_monitor/templates/claude-code-agent-monitor.settings.json \
  .claude/settings.json
```

Recommended improvements before launching Claude Code:

```bash
export AGENT_MONITOR_TERMINAL_TAG="$(tty 2>/dev/null | sed 's#^/dev/##')"
export AGENT_MONITOR_CWD="$PWD"
export AGENT_MONITOR_TERMINAL_APP=auto
```

Minimal hook mapping:

```json
{
  "hooks": {
    "SessionStart": [{
      "hooks": [{
        "type": "command",
        "command": "/Users/ruizhe.deng/Developer/agent_monitor/scripts/agent-monitor claude-code:${AGENT_MONITOR_TERMINAL_TAG:-session} yellow \"session started\" \"Claude Code\" \"${AGENT_MONITOR_TERMINAL_TAG:-}\" >/dev/null 2>&1 || true"
      }]
    }],
    "PreToolUse": [{
      "matcher": "Bash|Read|Edit|Write|MultiEdit",
      "hooks": [{
        "type": "command",
        "command": "/Users/ruizhe.deng/Developer/agent_monitor/scripts/agent-monitor claude-code:${AGENT_MONITOR_TERMINAL_TAG:-session} yellow \"using tool\" \"Claude Code\" \"${AGENT_MONITOR_TERMINAL_TAG:-}\" >/dev/null 2>&1 || true"
      }]
    }],
    "Notification": [{
      "hooks": [{
        "type": "command",
        "command": "/Users/ruizhe.deng/Developer/agent_monitor/scripts/agent-monitor claude-code:${AGENT_MONITOR_TERMINAL_TAG:-session} red \"waiting for human input or approval\" \"Claude Code\" \"${AGENT_MONITOR_TERMINAL_TAG:-}\" >/dev/null 2>&1 || true"
      }]
    }],
    "Stop": [{
      "hooks": [{
        "type": "command",
        "command": "/Users/ruizhe.deng/Developer/agent_monitor/scripts/agent-monitor claude-code:${AGENT_MONITOR_TERMINAL_TAG:-session} green \"finished response\" \"Claude Code\" \"${AGENT_MONITOR_TERMINAL_TAG:-}\" >/dev/null 2>&1 || true"
      }]
    }]
  }
}
```

Notes:

- Keep `>/dev/null 2>&1 || true` on every hook command.
- `Notification` is the best red signal for permission/input waits.
- `Stop` is the best green signal for response completion.
- Use a session-specific id such as `claude-code:$AGENT_MONITOR_TERMINAL_TAG`
  if multiple Claude Code sessions may run in the same folder.

## 7. Codex CLI wrapper

If your Codex CLI does not expose lifecycle hooks, wrap the invocation. This
repository includes:

```text
scripts/codex-monitor
```

Usage:

```bash
cd /path/to/project
/Users/ruizhe.deng/Developer/agent_monitor/scripts/codex-monitor \
  codex-worker:$(tty 2>/dev/null | sed 's#^/dev/##') \
  "Fix the auth bug and run tests" \
  --full-auto
```

Behavior:

- POST `yellow` before `codex exec` starts.
- Run `codex exec` with your prompt and flags.
- POST `green` on exit 0.
- POST `red` on non-zero exit.

If a future Codex version exposes native hooks, keep the adapter modular: make
those hooks call `scripts/agent-monitor` rather than changing AgentMonitor.

## 8. Building hooks for other agents

For any other runtime, implement a tiny adapter. Python example:

```python
#!/usr/bin/env python3
import json, os, sys, urllib.parse, urllib.request

endpoint = os.environ.get("AGENT_MONITOR_URL", "http://127.0.0.1:8765")
base_id = os.environ.get("AGENT_MONITOR_ID", "custom-agent")
session_id = os.environ.get("AGENT_SESSION_ID", "")
tty = os.environ.get("AGENT_MONITOR_TERMINAL_TAG", "")
suffix = tty or session_id or str(os.getpid())
agent_id = f"{base_id}:{suffix}"

body = {
    "state": sys.argv[1],
    "name": os.environ.get("AGENT_MONITOR_NAME", "Custom Agent"),
    "message": " ".join(sys.argv[2:]),
    "metadata": {
        "runtime": "custom",
        "base_agent_id": base_id,
        "session_id": session_id,
        "cwd": os.environ.get("PWD", os.getcwd()),
        "tty": tty,
        "terminal_tag": tty,
    },
}

try:
    req = urllib.request.Request(
        endpoint.rstrip("/") + "/agents/" + urllib.parse.quote(agent_id, safe=""),
        data=json.dumps(body).encode(),
        headers={"Content-Type": "application/json"},
        method="POST",
    )
    urllib.request.urlopen(req, timeout=0.7).read(256)
except Exception:
    pass
```

Then call it from hooks:

```bash
custom-agent-monitor yellow "thinking" >/dev/null 2>&1 || true
custom-agent-monitor red "waiting for approval" >/dev/null 2>&1 || true
custom-agent-monitor green "finished" >/dev/null 2>&1 || true
```

## 9. Verification checklist

Run this checklist after installing any integration:

```bash
# 1. AgentMonitor is alive
curl -fsS http://127.0.0.1:8765/health

# 2. A manual post works
/Users/ruizhe.deng/Developer/agent_monitor/scripts/agent-monitor \
  guide-test:manual yellow "manual test" "Guide Test" "manual-tag"

# 3. The row appears
curl -fsS http://127.0.0.1:8765/agents

# 4. Delete the test row
curl -fsS -X DELETE http://127.0.0.1:8765/agents/guide-test:manual
```

For Hermes specifically:

```bash
python3 -m py_compile ~/.hermes/agent-hooks/agent-monitor-status.py
hermes hooks doctor
hermes hooks test pre_llm_call
curl -fsS http://127.0.0.1:8765/agents
```

For same-folder collision testing, simulate two sessions with different terminal
tags but the same cwd. You should see two rows:

```bash
SCRIPT=~/.hermes/agent-hooks/agent-monitor-status.py

printf '%s' '{"hook_event_name":"pre_llm_call","session_id":"same-folder-A","cwd":"/tmp/project"}' |
  HERMES_AGENT_MONITOR_ID=hermes-collision-test \
  HERMES_AGENT_MONITOR_TERMINAL_TAG=ttys901 \
  "$SCRIPT"

printf '%s' '{"hook_event_name":"pre_llm_call","session_id":"same-folder-B","cwd":"/tmp/project"}' |
  HERMES_AGENT_MONITOR_ID=hermes-collision-test \
  HERMES_AGENT_MONITOR_TERMINAL_TAG=ttys902 \
  "$SCRIPT"

curl -fsS http://127.0.0.1:8765/agents
```

Clean up:

```bash
curl -fsS -X DELETE http://127.0.0.1:8765/agents/hermes-collision-test:ttys901
curl -fsS -X DELETE http://127.0.0.1:8765/agents/hermes-collision-test:ttys902
```

## 10. Troubleshooting

### Nothing appears in AgentMonitor

1. Confirm the app is running:
   ```bash
   curl -fsS http://127.0.0.1:8765/health
   ```
2. Confirm the port matches `AGENT_MONITOR_PORT` / `HERMES_AGENT_MONITOR_URL`.
3. Run the helper manually with an absolute path.
4. For Hermes, run `hermes hooks doctor` and restart the Hermes session.
5. Check hook logs if your adapter writes them.

### Rows overwrite each other

The row id is not unique enough. Include TTY or session id in `{agent-id}`:

```text
bad:  /agents/hermes-default-cli
good: /agents/hermes-default-cli:ttys000
good: /agents/hermes-default-cli:20260601_213316_21edea
```

### A finished/ready status disappears quickly

This can be normal. A hook may post `green: session ready` and then immediately
post `yellow: thinking` when a user message arrives. AgentMonitor shows current
state, not a full event history.

### Terminal button opens a new tab instead of focusing the old one

Make sure the row has one of:

```json
"terminal_tag": "ttys001"
"tty": "ttys001"
"session_id": "session-id"
```

For Terminal.app and iTerm2, TTY matching is the most reliable. Normalize
`/dev/ttys001` to `ttys001`, or provide both in compatible clients.

### Hooks slow down the agent

Use short timeouts and best-effort error handling. Recommended timeout is under
one second for direct HTTP calls and at most two seconds for host hook systems.
Every shell hook should end with:

```bash
>/dev/null 2>&1 || true
```

### Security notes

- Bind AgentMonitor to `127.0.0.1`, not a public interface.
- Do not put secrets in `message` or `metadata`.
- Keep messages short; they are UI labels, not logs.
- Treat hook payloads as potentially sensitive and redact before posting if your
  runtime includes prompts, files, or credentials in hook data.
