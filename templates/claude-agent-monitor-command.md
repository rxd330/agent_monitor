Update AgentMonitor with a manual status.

Arguments format:

```text
<green|yellow|red> <message>
```

Run this shell command, preserving the message:

```bash
/Users/ruizhe.deng/Developer/agent_monitor/scripts/agent-monitor claude-code "$FIRST_ARGUMENT" "$REMAINING_ARGUMENTS" "Claude Code"
```

If no arguments are supplied, show examples:

```text
/agent-monitor red waiting for approval
/agent-monitor yellow running tests
/agent-monitor green finished
```
