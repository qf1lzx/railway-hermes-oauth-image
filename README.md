# Hermes OAuth Railway Image

A minimal Railway-ready Docker image for running Hermes with OAuth-backed providers such as:

- `openai-codex` for your Codex subscription
- `nous` for your Nous subscription

The point is to avoid manually SSHing into a disposable Railway container.

## How it works

On every boot, `entrypoint.sh` hydrates Hermes state from Railway secrets:

| Railway variable | Written to |
|---|---|
| `HERMES_AUTH_JSON_B64` | `/data/.hermes/auth.json` |
| `HERMES_CONFIG_YAML_B64` | `/data/.hermes/config.yaml` |
| `HERMES_ENV_B64` | `/data/.hermes/.env` |

Then it starts:

- `hermes gateway` for Telegram/Discord/Slack/etc.
- a tiny HTTP health server on `$PORT` so Railway has something to check

There is no Hermes web dashboard in this minimal image. You talk to the agent through the messaging gateway.

## Railway setup

1. Create a Railway service from this repo.
2. Add a Railway volume mounted at `/data`. This is the persistent storage for sessions, logs, pairing approvals, skills, and any generated files.
3. Set variables:

```env
HERMES_AUTH_JSON_B64=...
HERMES_CONFIG_YAML_B64=...
HERMES_ENV_B64=...
```

## Local OAuth setup

Run locally on your Mac:

```bash
hermes auth add nous --type oauth
hermes auth add openai-codex --type oauth
hermes auth list
```

Encode the auth store:

```bash
base64 < ~/.hermes/auth.json | tr -d '\n' | pbcopy
```

Paste clipboard into Railway as `HERMES_AUTH_JSON_B64`.

## Config setup

Copy and edit:

```bash
cp railway-config.example.yaml railway-config.yaml
```

Encode:

```bash
base64 < railway-config.yaml | tr -d '\n' | pbcopy
```

Paste into Railway as `HERMES_CONFIG_YAML_B64`.

## Hermes .env setup

Copy and edit:

```bash
cp railway-hermes.env.example railway-hermes.env
```

Encode:

```bash
base64 < railway-hermes.env | tr -d '\n' | pbcopy
```

Paste into Railway as `HERMES_ENV_B64`.

## Caveats

- Treat `HERMES_AUTH_JSON_B64` like a password. It contains OAuth refresh tokens.
- Railway is Linux; Mac-only tools like Cua Driver, BlueBubbles/iMessage, and Spotify AppleScript will not work in this container.
- This is intentionally simpler than the template admin wizard. The source of truth is Railway env/secrets, not hand-edited container files.
- The included HTTP server is only for Railway health checks; it is not an admin UI.
