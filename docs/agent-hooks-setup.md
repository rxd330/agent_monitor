# AgentMonitor hooks setup for Claude Code and Codex

This document wires local AI agents into the AgentMonitor macOS widget using the stable local API:

```text
POST http://127.0.0.1:8765/agents/{agent-id}
```

Status contract:

- `green`: finished with work
- `yellow`: processing
- `red`: waiting on a human, approval, or anything requiring attention

The helper script is:

```bash
scripts/agent-monitor <agent-id> <green|yellow|red> [message] [display-name] [terminal-tag]
```

From anywhere, call it with an absolute path:

```bash
/Users/ruizhe.deng/Developer/agent_monitor/scripts/agent-monitor hermes-main yellow "processing" "Hermes main" "tty-hermes-main"
```

The optional fifth argument is stored as `metadata.terminal_tag`. The helper also
stores `metadata.cwd` from the caller's current working directory, unless
`AGENT_MONITOR_CWD` is set. The widget's terminal button uses these fields to
focus a matching Terminal tab or open a new one in the right directory.

If you run AgentMonitor on a non-default port:

```bash
AGENT_MONITOR_PORT=8989 /Users/ruizhe.deng/Developer/agent_monitor/scripts/agent-monitor codex-1 yellow "processing" "Codex worker"
```

## Claude Code project hooks

Claude Code supports hooks in `.claude/settings.json` for a project or `~/.claude/settings.json` globally.

Recommended project-local setup:

```bash
mkdir -p .claude
cp /Users/ruizhe.deng/Developer/agent_monitor/templates/claude-code-agent-monitor.settings.json .claude/settings.json
```

Then edit the copied file and set the `agent-id` / display name for that project.

Minimal example:

```json
{
  "hooks": {
    "SessionStart": [{
      "hooks": [{
        "type": "command",
        "command": "/Users/ruizhe.deng/Developer/agent_monitor/scripts/agent-monitor claude-code yellow \"session started\" \"Claude Code\" >/dev/null 2>&1 || true"
      }]
    }],
    "PreToolUse": [{
      "matcher": "Bash|Read|Edit|Write",
      "hooks": [{
        "type": "command",
        "command": "/Users/ruizhe.deng/Developer/agent_monitor/scripts/agent-monitor claude-code yellow \"using tool: $CLAUDE_TOOL_NAME\" \"Claude Code\" >/dev/null 2>&1 || true"
      }]
    }],
    "Notification": [{
      "hooks": [{
        "type": "command",
        "command": "/Users/ruizhe.deng/Developer/agent_monitor/scripts/agent-monitor claude-code red \"waiting for human input or approval\" \"Claude Code\" >/dev/null 2>&1 || true"
      }]
    }],
    "Stop": [{
      "hooks": [{
        "type": "command",
        "command": "/Users/ruizhe.deng/Developer/agent_monitor/scripts/agent-monitor claude-code green \"finished response\" \"Claude Code\" >/dev/null 2>&1 || true"
      }]
    }],
    "SubagentStop": [{
      "hooks": [{
        "type": "command",
        "command": "/Users/ruizhe.deng/Developer/agent_monitor/scripts/agent-monitor claude-subagent green \"subagent finished\" \"Claude subagent\" >/dev/null 2>&1 || true"
      }]
    }]
  }
}
```

Notes:

- Hook commands intentionally end with `|| true` so monitor downtime never breaks Claude Code.
- Redirects keep Claude's hook output quiet.
- The helper records the hook process working directory as `metadata.cwd` automatically.
- To make the widget focus an exact existing terminal tab, set a stable tag before launching Claude Code, for example: `export AGENT_MONITOR_TERMINAL_TAG=$(tty | sed 's#^/dev/##')`. The helper will store it as `metadata.terminal_tag`.
- `Notification` is the best Claude Code signal for "red" because it fires on permission requests or input waits.
- `Stop` is the best signal for "green" because it fires after Claude finishes a response.
- `PreToolUse` is a reasonable signal for "yellow" because the agent is actively working.

## Claude Code custom slash command

You can also add a manual status command:

```bash
mkdir -p .claude/commands
cp /Users/ruizhe.deng/Developer/agent_monitor/templates/claude-agent-monitor-command.md .claude/commands/agent-monitor.md
```

Usage inside Claude Code:

```text
/agent-monitor red waiting for approval
/agent-monitor yellow running tests
/agent-monitor green finished
```

## Codex CLI integration

The Codex skill currently documents Codex execution patterns but does not document a native Codex hook system equivalent to Claude Code hooks. The safe modular integration is a wrapper script that updates AgentMonitor before and after `codex exec`.

Use:

```bash
/Users/ruizhe.deng/Developer/agent_monitor/scripts/codex-monitor codex-1 "Build the feature"
```

Behavior:

- sets the agent to `yellow` before starting Codex
- runs `codex exec ...`
- sets `green` if Codex exits successfully
- sets `red` if Codex exits non-zero or appears to need intervention

Example:

```bash
cd /path/to/git/repo
/Users/ruizhe.deng/Developer/agent_monitor/scripts/codex-monitor codex-auth "Fix the auth bug and run tests" --full-auto
```

If Codex later exposes first-class lifecycle hooks in your installed version, keep this monitor integration modular by making those hooks call the same `scripts/agent-monitor` helper rather than changing the widget app.

## Hermes Agent shell-hook integration

Hermes supports shell hooks in `~/.hermes/config.yaml`. The default Hermes profile on this machine has been configured to report to AgentMonitor through:

```text
/Users/ruizhe.deng/.hermes/agent-hooks/agent-monitor-status.py
```

Configured events:

- `on_session_start` -> green, session ready
- `pre_llm_call` -> yellow, thinking
- `pre_tool_call` -> yellow, using tool
- `post_tool_call` -> yellow, continuing
- `pre_approval_request` -> red, waiting for approval
- `post_approval_response` -> yellow if approved, red if denied/timed out
- `subagent_stop` -> yellow, subagent finished and parent continuing
- `transform_llm_output` -> green, finished response
- `on_session_end`, `on_session_finalize`, `on_session_reset` -> green

The Hermes hook reports lifecycle status plus terminal-opening metadata:

- `metadata.session_id`
- `metadata.cwd`
- `metadata.tty`
- `metadata.terminal_tag`
- `metadata.pid` / `metadata.ppid`
- `metadata.runtime`, `metadata.profile`, `metadata.host`, `metadata.updated_by`

`metadata.tty` is detected from the hook process or its parent process tree.
`metadata.terminal_tag` uses the detected tty when available, then falls back to
session id, then agent id. The widget uses that tag to focus an existing
Terminal.app tab; if no matching tab is found, it opens a new Terminal window in
`metadata.cwd`.

Validation commands:

```bash
hermes hooks list
hermes hooks doctor
hermes hooks test pre_llm_call
```

Important: Hermes registers shell hooks at process startup. Existing Hermes sessions need to be restarted before newly configured hooks fire automatically.

Optional environment overrides:

```bash
export HERMES_AGENT_MONITOR_ID=hermes-default-cli
export HERMES_AGENT_MONITOR_NAME="Hermes CLI"
export HERMES_AGENT_MONITOR_URL=http://127.0.0.1:8765
```

## Generic agent integration

Any local agent can report status with one shell line:

```bash
export AGENT_MONITOR=/Users/ruizhe.deng/Developer/agent_monitor/scripts/agent-monitor
$AGENT_MONITOR "$AGENT_ID" yellow "processing: $TASK" "$AGENT_NAME" "${AGENT_MONITOR_TERMINAL_TAG:-$(tty 2>/dev/null | sed 's#^/dev/##')}"
$AGENT_MONITOR "$AGENT_ID" red "waiting for approval" "$AGENT_NAME" "${AGENT_MONITOR_TERMINAL_TAG:-$(tty 2>/dev/null | sed 's#^/dev/##')}"
$AGENT_MONITOR "$AGENT_ID" green "finished" "$AGENT_NAME" "${AGENT_MONITOR_TERMINAL_TAG:-$(tty 2>/dev/null | sed 's#^/dev/##')}"
```

Keep the monitor decoupled: agents only need to know the local API/helper path.
