# ClaudeWarp

A native macOS menu bar app that proxies the Anthropic Messages API through Claude Code CLI. Use your Claude subscription (Pro, Max, or Bedrock) as if it were an API key. Point any Anthropic-compatible client at `http://localhost:8989/v1/messages` and go.

## What it does

ClaudeWarp exposes a local Anthropic API-compatible endpoint. Incoming requests get converted into headless `claude -p` calls using your existing subscription. Supports streaming (SSE), tool use, multi-turn conversations, and multiple Claude environments.

Works with: Crush, LiteLLM, Open Interpreter, Cursor, curl, anything that speaks the Anthropic Messages API.

## Features

- **Model selection** — pick opus/sonnet/haiku from the menu bar, overrides what the client sends
- **Multiple environments** — switch between different `~/.claude*` config directories
- **Full SSE streaming** — implements the complete Anthropic streaming spec (message_start, content_block_delta, ping, message_stop)
- **`/v1/models` endpoint** — clients that validate models before calling (like Crush) work out of the box
- **Tool use passthrough** — tool_use/tool_result blocks are forwarded correctly
- **Zero dependencies** — pure Swift, Network.framework, no Electron, no Node

## Install

```bash
make install
```

Builds the app, copies to `/Applications`, fixes macOS gatekeeper signature.

## Use

1. Start ClaudeWarp from Applications or Spotlight
2. Configure your client:
   ```
   ANTHROPIC_BASE_URL=http://localhost:8989
   ANTHROPIC_API_KEY=dummy
   ```
3. Select a model from the menu bar if needed
4. Done

If the app won't run:
```bash
xattr -cr "/Applications/ClaudeWarp.app"
```

## Endpoints

| Endpoint | Method | Description |
|----------|--------|-------------|
| `/health` | GET | Health check |
| `/v1/models` | GET | List available models |
| `/v1/messages` | POST | Messages API (streaming + non-streaming) |

## Build

```bash
make        # build
make run    # build + launch
make clean  # remove build artifacts
```

## How it works

```
Client (Crush, curl, etc.)
  → POST /v1/messages (Anthropic API format)
    → ClaudeWarp proxy (localhost:8989)
      → claude -p --model <model> --output-format json
        → Claude API (using your subscription)
      ← JSON response
    ← Anthropic API response (or SSE stream)
```

The proxy is stateless. Context management (conversation history, tool loops) is handled by the client.

---

Works with any valid Claude Code subscription or Bedrock setup.
