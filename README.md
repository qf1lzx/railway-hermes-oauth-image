# Hermes Agent for Railway — Codex + Nous subscriptions

A Railway-ready, gateway-only Hermes Agent container for using:

- **OpenAI Codex subscription** as the main model provider
- **Nous subscription** for delegation + auxiliary models
- **Telegram/Discord/Slack/etc.** as the interface
- **Railway volume at `/data`** for persistent state
- **gstack auto-setup** for Codex/Claude-style client workflows

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

## One-click interactive deploy CLI

Run the guided deployer when you want the simple, all-in-one path:

```bash
cd /Users/nickthegoat/Documents/Hermes/railway-hermes-oauth-image
./scripts/deploy.sh
```

The CLI walks you through:

1. Railway project/service creation
2. Telegram, Discord, or Slack gateway auth
3. OAuth/subscription providers: **Nous**, **OpenAI Codex**, optional Qwen OAuth
4. API-key providers: **OpenRouter**, Anthropic, OpenAI, Gemini, DeepSeek, xAI/Grok, Groq, Mistral, Copilot
5. Model-routing presets:
   - recommended **Codex main + Nous delegation/auxiliary**
   - Nous-first
   - OpenRouter fallback
6. Optional tooling:
   - **gstack** auto-bootstrap
   - **Honcho** memory via `HONCHO_API_KEY`
   - GBrain-style/custom env credentials via `GBRAIN_API_KEY` or `NAME=value`
   - Google Drive shared-state sync
7. Railway deploy, cloud OAuth, restart, and smoke test

Secrets are never written into this repository. API keys/tokens are sent to Railway through `railway variable set --stdin`; Nous/Codex OAuth is performed inside Railway with `hermes-cloud-auth`, which writes cloud-owned tokens to `/data/.hermes/auth.json` on the persistent volume.

Useful modes:

```bash
# See exactly what would happen without touching Railway
./scripts/deploy.sh --dry-run

# Non-interactive deploy from environment variables/defaults
TELEGRAM_BOT_TOKEN='...' TELEGRAM_ALLOWED_USERS='123456789' ./scripts/deploy.sh --yes

# Deploy only; do OAuth manually later
./scripts/deploy.sh --no-cloud-auth
```

## Legacy/advanced setup: one local script

This creates/uses a Railway project, validates the Telegram bot token with Telegram `getMe` without printing it, adds the GitHub-backed service, attaches the `/data` volume, sets gateway variables via stdin-safe Railway CLI calls, and triggers a deployment.

OAuth is **not** copied from your Mac. After the first deploy, SSH into the Railway container and run `hermes-cloud-auth`; it prints the OAuth links/device-code prompts in the Railway shell, you copy/paste them into your browser, and Hermes writes the cloud-owned token store to `/data/.hermes/auth.json`.

```bash
cd /Users/nickthegoat/Documents/Hermes/railway-hermes-oauth-image
./scripts/create-railway-project.sh
```

After Railway deploys, the script can run `hermes-cloud-auth` for you. If you skipped it with `RUN_CLOUD_AUTH=false`, run it manually:

```bash
railway ssh --service hermes
hermes-cloud-auth
exit
railway restart --service hermes
```

`hermes-cloud-auth` authenticates providers independently and runs Nous first. If Codex device-code creation fails from Railway, Nous can still be saved to `/data/.hermes/auth.json`; rerun only the failed provider later.

The setup script will ask for:

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

The script sets these Railway variables without printing secret values. Secret and JSON values use `railway variable set --stdin`; do not verify them with `railway variables --service ...` because that command can print raw values in a table.

- `TELEGRAM_BOT_TOKEN`
- `TELEGRAM_ALLOWED_USERS`
- `GATEWAY_ALLOW_ALL_USERS=false`
- `GOOGLE_TOKEN_JSON`, if present
- `GOOGLE_CLIENT_SECRET_JSON`, if present
- `HERMES_WORKSPACE_DRIVE_FOLDER_ID`
- `HERMES_SHARED_STATE_SYNC=drive`
- `GSTACK_AUTO_SETUP=true`
- `GSTACK_HOSTS=codex,claude`

If Google Workspace credentials are present, it also publishes a non-secret shared-state bundle named `hermes-shared-state.tar.gz` into the configured Drive folder. On Railway boot the container pulls that bundle into `/data/.hermes` before starting the gateway, so cloud Hermes starts with the same shared config/skills/memory notes as local Hermes.

These files/values are **not committed to Git**. `.gitignore` and `.dockerignore` exclude local `.env`, `*.env`, `auth.json`, `*auth*.json`, and secret files so accidental local copies do not get pushed or included in the Docker build context.

## Client/project bootstrap with gstack

The image now auto-installs [gstack](https://github.com/garrytan/gstack) on Railway boot by default. It installs into the persistent `/data` home and links skills for Codex/Claude-style agents. The setup runs in the background after the `/health` server starts, so Railway health checks are not blocked; logs go to `/data/.hermes/logs/gstack-setup.log`.

```env
GSTACK_AUTO_SETUP=true
GSTACK_HOSTS=codex,claude
GSTACK_TEAM_MODE=false
GSTACK_SKILL_PREFIX=false
GSTACK_PLAYWRIGHT_BROWSERS_PATH=/tmp/ms-playwright
GSTACK_CLEAN_PLAYWRIGHT_CACHE=true
```

You can override those per Railway service with `./scripts/push-railway-vars.sh` or during first setup:

```bash
export PROJECT_NAME='acme-hermes'
export SERVICE_NAME='hermes'
export CLIENT_NAME='Acme Corp'
export CLIENT_SLUG='acme'
export GSTACK_AUTO_SETUP=true
export GSTACK_HOSTS='codex,claude'
./scripts/create-railway-project.sh
```

For a future client's actual app/code repo, initialize repo-level gstack team mode locally:

```bash
cd /path/to/client-app-repo
CLIENT_NAME='Acme Corp' /Users/nickthegoat/Documents/Hermes/railway-hermes-oauth-image/scripts/setup-client-gstack.sh .
```

That script:

- installs/updates global gstack under `~/.claude/skills/gstack`
- runs gstack setup for Claude + Codex
- runs `gstack-team-init required` by default
- adds a small `AGENTS.md` bridge so Hermes follows the same workflow
- tells you exactly what generated files to review/commit

Use `GSTACK_MODE=optional` if you do not want to block non-gstack work in a client's repo.

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
HERMES_WORKSPACE_DRIVE_FOLDER_ID=10Io92h6D936VcajyNYJJ9RYFkfKYQyXV
HERMES_SHARED_STATE_SYNC=drive
```

5. Deploy, then run cloud OAuth inside the Railway container:

```bash
railway ssh --service hermes
hermes-cloud-auth
exit
railway restart --service hermes
```

Do **not** paste your Mac's `~/.hermes/auth.json` into Railway for normal setup. The cloud deployment gets its own OAuth token store at `/data/.hermes/auth.json`.

## Why cloud OAuth is still needed

Codex subscription auth and Nous subscription auth are OAuth refresh-token flows. Railway cannot magically log into your browser account for you, but the login should happen **from the Railway/VPS environment**, not by copying your Mac's token file. `hermes-cloud-auth` runs the provider login commands on Railway and prints the URLs/codes for you to open in your browser.

Run once after the service is deployed:

```bash
railway ssh --service hermes
hermes-cloud-auth
exit
railway restart --service hermes
```

That writes cloud-owned credentials to:

```txt
/data/.hermes/auth.json
```

The file lives on the Railway `/data` volume, so it survives rebuilds/redeploys and stays separate from your local Mac OAuth store.

## Optional: push local secrets to an already-linked Railway service

If you already have a Railway service linked to this directory, this helper uses stdin-safe `railway variable set` calls. Set `SERVICE_NAME` if the service is not named `hermes`:

```bash
cd /Users/nickthegoat/Documents/Hermes/railway-hermes-oauth-image
export SERVICE_NAME='hermes'
export TELEGRAM_BOT_TOKEN='...'
export TELEGRAM_ALLOWED_USERS='123456789'
export GATEWAY_ALLOW_ALL_USERS=false
./scripts/push-railway-vars.sh
```

## Shared Google Drive workspace and shared Hermes state

This image supports the intended two-agent workflow:

```txt
Local Mac Hermes
  - works directly in the Google Drive Desktop-backed Hermes workspace
  - can publish a shared Hermes state snapshot to Drive

Railway Hermes
  - uses Google Drive API/OAuth, not a mounted Drive filesystem
  - hydrates Google OAuth into /data/.hermes
  - pulls hermes-shared-state.tar.gz from the shared Drive folder on boot
```

The shared-state bundle intentionally contains only non-secret operational context:

- `config.yaml` with obvious secret-like keys redacted
- `skills/`
- `memories/`
- `hooks/`
- `MEMORY.md`, `USER.md`, `personality.md` if present

It intentionally excludes `.env`, `auth.json`, Google tokens/client secrets, sessions, logs, cron state, pairings, and caches.

Publish the current local state bundle manually whenever you want cloud Hermes to learn the latest local skills/config/context:

```bash
cd /Users/nickthegoat/Documents/Hermes/railway-hermes-oauth-image
./scripts/publish-shared-state-to-drive.sh
railway restart --service hermes
```

From cloud Hermes, a Telegram command can also run:

```bash
python /app/shared_state_sync.py push
```

That updates the Drive bundle from Railway's `/data/.hermes` state. Use this deliberately when the cloud agent has learned useful reusable skills/context. Avoid automatic bidirectional overwrites; the bundle is a collaboration handoff, not a live filesystem.

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
HERMES_CONFIG_YAML_B64=...
HERMES_ENV_B64=...
```

## Updates

This repo is designed to use Railway's native template-update path: Railway tracks commits to the template repo's root branch. The included GitHub Action bridges Hermes upstream into that native path:

```txt
NousResearch/hermes-agent main changes
→ .github/workflows/update-hermes.yml updates Dockerfile ARG HERMES_REF=<upstream-sha>
→ workflow commits to this template repo
→ Railway sees the template repo changed
→ deployed projects can rebuild/redeploy from the new image
→ /data keeps cloud OAuth/config/sessions
```

`HERMES_REF` is pinned to an upstream SHA for reproducibility. Do not rely on `hermes update` inside Railway for the default flow.

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

- If Railway CLI auth looks stale even though `railway whoami` works, rerun `railway login --browserless`. Some operations can fail with stale Railway auth while basic identity checks still pass.
- If `railway ssh` reports no active deployment or times out after a deploy, check `railway deployment list --service hermes`; for stubborn cases, pin the current running deployment instance.
- Do not paste local `~/.hermes/auth.json` into Railway for normal setup. Run `hermes-cloud-auth` in `railway ssh` and copy/paste the printed OAuth links into your browser so Railway creates its own `/data/.hermes/auth.json`.
- Railway is Linux; Mac-only local integrations like Cua Driver, BlueBubbles/iMessage, and Spotify AppleScript will not work inside this container.
- A real one-click Railway template link requires creating/publishing a template from Railway's Templates UI. This repo is ready for that, but the generic GitHub URL is not a marketplace template code.
