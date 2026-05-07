# Hermes Agent for Railway — Codex + Nous subscriptions

A Railway-ready, gateway-only Hermes Agent container for using:

- **OpenAI Codex subscription** as the main model provider
- **Nous subscription** for delegation + auxiliary models
- **Telegram/Discord/Slack/etc.** as the interface
- **Railway volume at `/data`** for persistent state

No admin dashboard is included. Railway only exposes a tiny `/health` endpoint; you talk to Hermes through the messaging gateway.

## Important: this is a GitHub repo, not a published Railway Marketplace template

Railway's old generic URL form:

```txt
https://railway.app/new/template?template=https://github.com/OWNER/REPO
```

is **not** enough for Railway to recognize a repo as a real template anymore. Real templates need a Railway-generated template code like:

```txt
https://railway.com/new/template/ZweBXA
```

So until this is published from the Railway Templates UI, use one of the two setup paths below.

## Fastest setup: one local script

This creates/uses a Railway project, adds the GitHub-backed service, attaches the `/data` volume, uploads your local OAuth files as Railway variables, and triggers a deployment.

```bash
cd /Users/nickthegoat/Documents/Hermes/railway-hermes-oauth-image
./scripts/create-railway-project.sh
```

It will ask for:

```txt
Telegram bot token from @BotFather
Your numeric Telegram user ID from @userinfobot
```

You can also run it non-interactively:

```bash
cd /Users/nickthegoat/Documents/Hermes/railway-hermes-oauth-image

export PROJECT_NAME='hermes-agent'
export SERVICE_NAME='hermes'
export TELEGRAM_BOT_TOKEN='...'
export TELEGRAM_ALLOWED_USERS='123456789'

./scripts/create-railway-project.sh
```

The script uploads these without printing secret values:

- `~/.hermes/auth.json` → `HERMES_AUTH_JSON`
- `~/.codex/auth.json` → `CODEX_AUTH_JSON`, if present
- `TELEGRAM_BOT_TOKEN`
- `TELEGRAM_ALLOWED_USERS`
- `GATEWAY_ALLOW_ALL_USERS=false`

## Manual Railway UI setup

If you prefer the Railway web UI:

1. Railway → **New Project** → **Deploy from GitHub repo**
2. Select:

```txt
qf1lzx/railway-hermes-oauth-image
```

3. Add a volume mounted at:

```txt
/data
```

4. Add variables:

```env
TELEGRAM_BOT_TOKEN=...
TELEGRAM_ALLOWED_USERS=123456789
GATEWAY_ALLOW_ALL_USERS=false
HERMES_AUTH_JSON={...contents of ~/.hermes/auth.json...}
```

To copy the local auth file:

```bash
pbcopy < ~/.hermes/auth.json
```

That is it. You do **not** need to base64 encode config/env files.

## Why any auth JSON is still needed

Codex subscription auth and Nous subscription auth are OAuth refresh-token flows. Railway cannot magically log into your browser account for you. The only unavoidable step is exporting the OAuth credential file from a machine where you already logged in.

On your Mac:

```bash
hermes auth add openai-codex --type oauth
hermes auth add nous --type oauth
hermes auth list
```

Then use either the setup script or paste the raw file contents into Railway as `HERMES_AUTH_JSON`:

```bash
pbcopy < ~/.hermes/auth.json
```

## Optional: push local secrets to an already-linked Railway service

If you already have a Railway service linked to this directory:

```bash
cd /Users/nickthegoat/Documents/Hermes/railway-hermes-oauth-image
export TELEGRAM_BOT_TOKEN='...'
export TELEGRAM_ALLOWED_USERS='123456789'
export GATEWAY_ALLOW_ALL_USERS=false
./scripts/push-railway-vars.sh
```

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
- A real one-click Railway template link requires creating/publishing a template from Railway's Templates UI. This repo is ready for that, but the generic GitHub URL is not a marketplace template code.
