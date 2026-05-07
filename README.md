# Hermes Agent for Railway — Codex + Nous subscriptions

[![Deploy on Railway](https://railway.app/button.svg)](https://railway.app/new/template?template=https://github.com/qf1lzx/railway-hermes-oauth-image)

A Railway-ready, gateway-only Hermes Agent container for using:

- **OpenAI Codex subscription** as the main model provider
- **Nous subscription** for delegation + auxiliary models
- **Telegram/Discord/Slack/etc.** as the interface
- **Railway volume at `/data`** for persistent state

No admin dashboard is included. Railway only exposes a tiny `/health` endpoint; you talk to Hermes through the messaging gateway.

## The simple deploy path

### 1. Click deploy

Use the button above, or this URL:

```txt
https://railway.app/new/template?template=https://github.com/qf1lzx/railway-hermes-oauth-image
```

Railway will build the Dockerfile directly. `railway.toml` already sets the builder, health check, and restart policy.

### 2. Add a Railway volume

Mount a persistent volume at:

```txt
/data
```

This stores Hermes config, auth, sessions, pairing approvals, logs, skills, generated files, and cron state.

### 3. Set only the variables you actually need

For Telegram, the minimum is:

```env
TELEGRAM_BOT_TOKEN=...
TELEGRAM_ALLOWED_USERS=123456789
GATEWAY_ALLOW_ALL_USERS=false
```

For Codex/Nous subscription OAuth, set one of these once:

```env
HERMES_AUTH_JSON={...contents of ~/.hermes/auth.json...}
```

Optional Codex CLI credential import:

```env
CODEX_AUTH_JSON={...contents of ~/.codex/auth.json...}
```

That is it. You do **not** need to base64 encode config/env files anymore.

## Why any auth JSON is still needed

Codex subscription auth and Nous subscription auth are OAuth refresh-token flows. Railway cannot magically log into your browser account for you. The only unavoidable step is exporting the OAuth credential file from a machine where you already logged in.

On your Mac:

```bash
hermes auth add openai-codex --type oauth
hermes auth add nous --type oauth
hermes auth list
```

Then copy the raw file contents into the Railway variable `HERMES_AUTH_JSON`:

```bash
pbcopy < ~/.hermes/auth.json
```

No base64. No config YAML. No `.env` file assembly.

## Optional: push local secrets to an already-linked Railway service

If you use the Railway CLI and this repo is linked to a Railway service:

```bash
cd /Users/nickthegoat/Documents/Hermes/railway-hermes-oauth-image
export TELEGRAM_BOT_TOKEN='...'
export TELEGRAM_ALLOWED_USERS='123456789'
export GATEWAY_ALLOW_ALL_USERS=false
./scripts/push-railway-vars.sh
```

The script uploads:

- `~/.hermes/auth.json` as `HERMES_AUTH_JSON`
- `~/.codex/auth.json` as `CODEX_AUTH_JSON`, if present
- common gateway variables from your shell environment

## Runtime defaults

If you do not provide `HERMES_CONFIG_YAML`, the container generates this config automatically:

```yaml
model:
  provider: openai-codex
  default: openai/gpt-5.4

delegation:
  provider: nous
  model: moonshotai/kimi-k2.6
  base_url: https://inference-api.nousresearch.com/v1
```

Auxiliary routing also defaults to Nous.

You can override with simple Railway variables instead of a config file:

```env
HERMES_MAIN_PROVIDER=openai-codex
HERMES_MAIN_MODEL=openai/gpt-5.4
HERMES_DELEGATION_PROVIDER=nous
HERMES_DELEGATION_MODEL=moonshotai/kimi-k2.6
HERMES_AUX_PROVIDER=nous
HERMES_AUX_MODEL=google/gemini-3.1-flash-lite-preview
```

Advanced users can still provide raw or base64 config/env files:

```env
HERMES_CONFIG_YAML=...
HERMES_ENV=...
HERMES_AUTH_JSON_B64=...
HERMES_CONFIG_YAML_B64=...
HERMES_ENV_B64=...
```

## Health check

Railway checks:

```txt
/health
```

Expected response:

```txt
hermes gateway container ok
```

## Caveats

- Treat `HERMES_AUTH_JSON` like a password. It contains refresh tokens.
- Railway is Linux; Mac-only local integrations like Cua Driver, BlueBubbles/iMessage, and Spotify AppleScript will not work inside this container.
- If the GitHub repo is private, the generic Deploy button may require GitHub/Railway access. Making the repo public gives the cleanest one-click template flow.
