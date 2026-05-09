#!/usr/bin/env bash
set -euo pipefail

if ! command -v railway >/dev/null 2>&1; then
  echo "Railway CLI is not installed. Install it from https://docs.railway.com/guides/cli first." >&2
  exit 1
fi

if ! railway whoami >/dev/null 2>&1; then
  echo "Run: railway login --browserless" >&2
  exit 1
fi

SERVICE_NAME="${SERVICE_NAME:-hermes}"

set_var_stdin() {
  local name="$1"
  local value="$2"
  if [ -n "$value" ]; then
    # Avoid `railway variables --set`, which can echo a raw variables table with secrets.
    printf '%s' "$value" | railway variable set --service "$SERVICE_NAME" --skip-deploys --stdin "$name" >/dev/null
    echo "set $name"
  fi
}

set_var_file() {
  local name="$1"
  local file="$2"
  if [ -f "$file" ]; then
    set_var_stdin "$name" "$(cat "$file")"
    echo "  source: $file"
  else
    echo "skip $name: $file not found"
  fi
}

set_var_if_present() {
  local name="$1"
  local value="${!name:-}"
  if [ -n "$value" ]; then
    set_var_stdin "$name" "$value"
    echo "  source: shell env"
  fi
}

# Plain, non-base64 variables. Do not push local Hermes/Codex OAuth token
# files to Railway; run `hermes-cloud-auth` inside the Railway container so the
# cloud deployment owns its own persistent /data OAuth store.
set_var_file GOOGLE_TOKEN_JSON "${GOOGLE_TOKEN_JSON_PATH:-$HOME/.hermes/google_token.json}"
set_var_file GOOGLE_CLIENT_SECRET_JSON "${GOOGLE_CLIENT_SECRET_JSON_PATH:-$HOME/.hermes/google_client_secret.json}"

DEFAULT_HERMES_WORKSPACE_DRIVE_FOLDER_ID="10Io92h6D936VcajyNYJJ9RYFkfKYQyXV"
HERMES_WORKSPACE_DRIVE_FOLDER_ID_WAS_SET="${HERMES_WORKSPACE_DRIVE_FOLDER_ID+x}"
: "${HERMES_WORKSPACE_DRIVE_FOLDER_ID:=$DEFAULT_HERMES_WORKSPACE_DRIVE_FOLDER_ID}"
: "${HERMES_SHARED_STATE_SYNC:=drive}"
if [ -n "${CLIENT_NAME:-}${CLIENT_SLUG:-}" ] && [ -z "$HERMES_WORKSPACE_DRIVE_FOLDER_ID_WAS_SET" ]; then
  echo "client mode without HERMES_WORKSPACE_DRIVE_FOLDER_ID; disabling Drive sync to avoid using Nick's personal Drive folder"
  HERMES_WORKSPACE_DRIVE_FOLDER_ID=""
  HERMES_SHARED_STATE_SYNC="none"
fi
set_var_if_present HERMES_WORKSPACE_DRIVE_FOLDER_ID
set_var_if_present HERMES_SHARED_STATE_SYNC
set_var_if_present HERMES_SHARED_STATE_PULL_OVERWRITE

: "${GSTACK_AUTO_SETUP:=true}"
: "${GSTACK_HOSTS:=codex,claude}"
: "${GSTACK_TEAM_MODE:=false}"
: "${GSTACK_SKILL_PREFIX:=false}"
set_var_if_present GSTACK_AUTO_SETUP
set_var_if_present GSTACK_HOSTS
set_var_if_present GSTACK_TEAM_MODE
set_var_if_present GSTACK_SKILL_PREFIX
set_var_if_present GSTACK_REPO
set_var_if_present GSTACK_REF
set_var_if_present GSTACK_UPDATE_ON_BOOT
set_var_if_present GSTACK_PLAYWRIGHT_BROWSERS_PATH
set_var_if_present GSTACK_CLEAN_PLAYWRIGHT_CACHE
set_var_if_present CLIENT_NAME
set_var_if_present CLIENT_SLUG

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
Done. Variables were set on the Railway service named by SERVICE_NAME, default: hermes. Make sure it has a volume mounted at /data.
If you have not linked this repo to a Railway project yet, run:
  railway link
or create one with:
  railway init
EOF
