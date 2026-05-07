#!/usr/bin/env bash
set -euo pipefail

PROJECT_NAME="${PROJECT_NAME:-hermes-agent}"
SERVICE_NAME="${SERVICE_NAME:-hermes}"
REPO="${REPO:-qf1lzx/railway-hermes-oauth-image}"
VOLUME_MOUNT_PATH="${VOLUME_MOUNT_PATH:-/data}"
HERMES_AUTH_JSON_PATH="${HERMES_AUTH_JSON_PATH:-$HOME/.hermes/auth.json}"
CODEX_AUTH_JSON_PATH="${CODEX_AUTH_JSON_PATH:-$HOME/.codex/auth.json}"

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "Missing required command: $1" >&2
    exit 1
  }
}

need_cmd railway

if ! railway whoami >/dev/null 2>&1; then
  echo "Railway CLI is not logged in. Run: railway login" >&2
  exit 1
fi

if [ ! -s "$HERMES_AUTH_JSON_PATH" ]; then
  cat >&2 <<EOF
Missing Hermes OAuth auth file: $HERMES_AUTH_JSON_PATH

Run locally first:
  hermes auth add openai-codex --type oauth
  hermes auth add nous --type oauth
EOF
  exit 1
fi

if [ -z "${TELEGRAM_BOT_TOKEN:-}" ]; then
  read -rsp "Telegram bot token from @BotFather: " TELEGRAM_BOT_TOKEN
  echo
fi

if [ -z "${TELEGRAM_ALLOWED_USERS:-}" ]; then
  read -rp "Your numeric Telegram user ID from @userinfobot: " TELEGRAM_ALLOWED_USERS
fi

if [ -z "$TELEGRAM_BOT_TOKEN" ] || [ -z "$TELEGRAM_ALLOWED_USERS" ]; then
  echo "TELEGRAM_BOT_TOKEN and TELEGRAM_ALLOWED_USERS are required." >&2
  exit 1
fi

echo "Creating/linking Railway project: $PROJECT_NAME"
if ! railway status >/dev/null 2>&1; then
  railway init --name "$PROJECT_NAME"
else
  echo "Already linked to a Railway project; using current link."
fi

echo "Adding GitHub-backed service: $SERVICE_NAME from $REPO"
if ! railway service list --json 2>/dev/null | grep -q '"name":"'"$SERVICE_NAME"'"'; then
  railway add --repo "$REPO" --service "$SERVICE_NAME"
else
  echo "Service $SERVICE_NAME already exists; skipping add."
fi

railway service link "$SERVICE_NAME" >/dev/null 2>&1 || true

echo "Ensuring persistent volume mounted at $VOLUME_MOUNT_PATH"
if ! railway volume list --json 2>/dev/null | grep -q '"mountPath":"'"$VOLUME_MOUNT_PATH"'"'; then
  railway volume add --service "$SERVICE_NAME" --mount-path "$VOLUME_MOUNT_PATH"
else
  echo "Volume at $VOLUME_MOUNT_PATH already exists; skipping add."
fi

echo "Setting Railway variables without printing secret values"
printf '%s' "$TELEGRAM_BOT_TOKEN" | railway variable set --service "$SERVICE_NAME" TELEGRAM_BOT_TOKEN --stdin --skip-deploys >/dev/null
railway variable set --service "$SERVICE_NAME" "TELEGRAM_ALLOWED_USERS=$TELEGRAM_ALLOWED_USERS" --skip-deploys >/dev/null
railway variable set --service "$SERVICE_NAME" "GATEWAY_ALLOW_ALL_USERS=false" --skip-deploys >/dev/null
printf '%s' "$(cat "$HERMES_AUTH_JSON_PATH")" | railway variable set --service "$SERVICE_NAME" HERMES_AUTH_JSON --stdin --skip-deploys >/dev/null

if [ -s "$CODEX_AUTH_JSON_PATH" ]; then
  printf '%s' "$(cat "$CODEX_AUTH_JSON_PATH")" | railway variable set --service "$SERVICE_NAME" CODEX_AUTH_JSON --stdin --skip-deploys >/dev/null
fi

echo "Triggering deployment from the current repo contents"
railway up --service "$SERVICE_NAME" --detach

cat <<EOF

Done.
Project/service should now deploy on Railway.

Next checks:
  railway status
  railway logs --service $SERVICE_NAME --lines 100
  railway open

If you want a public Railway URL for /health:
  railway domain --service $SERVICE_NAME --port 8080
EOF
