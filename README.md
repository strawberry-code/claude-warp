# ClaudeWarp

A native macOS app that proxies the Anthropic Messages API, letting you use Claude Code's MAX subscription as an API backend. No separate API key needed. Just point your client at `http://localhost:8082/v1/messages` and you're done.

## What it does

ClaudeWarp runs as a menu bar app on macOS. It exposes a local Anthropic API-compatible endpoint that converts requests into headless `claude` calls. Any tool that speaks the Anthropic Messages API (LiteLLM, Open Interpreter, curl, whatever) can hit it and use your Claude Code subscription.

## Install

```bash
make install
```

This builds the app, copies it to `/Applications`, and fixes the macOS gatekeeper signature issue automatically.

## Use

1. Start ClaudeWarp from Applications or Spotlight
2. Set these environment variables in your client:
   ```
   ANTHROPIC_API_BASE=http://localhost:8082
   ANTHROPIC_API_KEY=dummy
   ```
3. Point your client at the proxy and go

If the app won't run, you might need to manually clear the quarantine flag:
```bash
xattr -cr "/Applications/ClaudeWarp.app"
```

## Build

```bash
make
```

Output: `build/ClaudeWarp.app`

## Clean

```bash
make clean
```

## Run (dev)

```bash
make run
```

---

Built because waiting for an official Claude API with the MAX subscription is stupid.
