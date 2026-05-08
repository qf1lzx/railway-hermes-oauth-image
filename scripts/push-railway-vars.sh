#!/usr/bin/env bash
set -euo pipefail

if ! command -v railway >/dev/null 2>&1; then
  echo "Railway CLI is not installed. Install it from https://docs.railway.com/guides/cli first." >&2
  exit 1
fi

if ! railway whoami >/dev/null 2>&1; then
  echo "Run: railway login" >&2
  exit 1
fi

set_var_file() {
  local name="$1"
  local file="$2"
  if [ -f "$file" ]; then
    railway variables --set "$name=$(cat "$file")"
    echo "set $name from $file"
  else
    echo "skip $name: $file not found"
  fi
}

set_var_if_present() {
  local name="$1"
  local value="${!name:-}"
  if [ -n "$value" ]; then
    railway variables --set "$name=$value"
    echo "set $name from shell env"
  fi
}

# Plain, non-base64 variables. Railway supports multiline values, so this avoids
# the old copy/base64/paste dance.
set_var_file HERMES_AUTH_JSON "${HERMES_AUTH_JSON_PATH:-$HOME/.hermes/auth.json}"
set_var_file CODEX_AUTH_JSON "${CODEX_AUTH_JSON_PATH:-$HOME/.codex/auth.json}"
set_var_file GOOGLE_TOKEN_JSON "${GOOGLE_TOKEN_JSON_PATH:-$HOME/.hermes/google_token.json}"
set_var_file GOOGLE_CLIENT_SECRET_JSON "${GOOGLE_CLIENT_SECRET_JSON_PATH:-$HOME/.hermes/google_client_secret.json}"

: "${HERMES_WORKSPACE_DRIVE_FOLDER_ID:=10Io92h6D936VcajyNYJJ9RYFkfKYQyXV}"
: "${HERMES_SHARED_STATE_SYNC:=drive}"
set_var_if_present HERMES_WORKSPACE_DRIVE_FOLDER_ID
set_var_if_present HERMES_SHARED_STATE_SYNC
set_var_if_present HERMES_SHARED_STATE_PULL_OVERWRITE

if [ "${HERMES_SHARED_STATE_SYNC:-}" = "drive" ] && [ -s "${GOOGLE_TOKEN_JSON_PATH:-$HOME/.hermes/google_token.json}" ]; then
  echo "publishing non-secret Hermes shared state bundle to Drive"
  HERMES_WORKSPACE_DRIVE_FOLDER_ID="$HERMES_WORKSPACE_DRIVE_FOLDER_ID" "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/scripts/publish-shared-state-to-drive.sh"
fi

# Messaging/gateway variables can be exported before running this script.
for key in \
  TELEGRAM_BOT_TOKEN TELEGRAM_ALLOWED_USERS TELEGRAM_ALLOWED_CHATS \
  DISCORD_BOT_TOKEN DISCORD_ALLOWED_USERS DISCORD_ALLOWED_CHANNELS \
  SLACK_BOT_TOKEN SLACK_APP_TOKEN GATEWAY_ALLOW_ALL_USERS WEBHOOK_SECRET; do
  set_var_if_present "$key"
done

echo
cat <<'EOF'
Done. Make sure the Railway service has a volume mounted at /data.
If you have not linked this repo to a Railway project yet, run:
  railway link
or create one with:
  railway init
EOF
