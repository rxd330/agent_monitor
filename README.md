# AgentMonitor

A modular macOS menu-bar + floating desktop widget for local AI agent status.

Status meanings:

- green: finished with work
- yellow: processing
- red: waiting on a human, approval, or other attention

The app has two surfaces:

1. A menu-bar status item that is always available.
2. A floating desktop widget that can be dragged around and hidden by right-clicking it or using the eye-slash button. Bring it back from the menu bar.

The local API listens on `127.0.0.1:${AGENT_MONITOR_PORT:-8765}`.

## Run

For development:

```bash
swift run AgentMonitor
```

Optionally choose a port:

```bash
AGENT_MONITOR_PORT=8989 swift run AgentMonitor
```

Build a normal macOS app bundle:

```bash
scripts/build-app-bundle
open dist/AgentMonitor.app
```

## Agent update API

Update or create an agent:

```bash
curl -X POST http://127.0.0.1:8765/agents/hermes-main \
  -H 'Content-Type: application/json' \
  -d '{"state":"yellow","name":"Hermes main","message":"running tests"}'
```

List agents:

```bash
curl http://127.0.0.1:8765/agents
```

Delete one agent:

```bash
curl -X DELETE http://127.0.0.1:8765/agents/hermes-main
```

Clear all agents:

```bash
curl -X DELETE http://127.0.0.1:8765/agents
```

## Static local helper

```bash
scripts/agent-monitor hermes-main yellow "running tests" "Hermes main"
scripts/agent-monitor hermes-main red "waiting for approval"
scripts/agent-monitor hermes-main green "finished"
scripts/agent-monitor list
scripts/agent-monitor clear
```

## Hermes hook / skill integration idea

For now, agents can make a static local call whenever behavior changes:

- before long work: `scripts/agent-monitor "$AGENT_ID" yellow "processing: <task>"`
- before asking the human: `scripts/agent-monitor "$AGENT_ID" red "waiting for approval: <reason>"`
- after completion: `scripts/agent-monitor "$AGENT_ID" green "finished: <summary>"`

Keep this monitor decoupled from any one agent runtime. The only contract is the local HTTP API.
