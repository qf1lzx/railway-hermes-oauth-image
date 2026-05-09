#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT_NAME="${PROJECT_NAME:-hermes-agent}"
SERVICE_NAME="${SERVICE_NAME:-hermes}"
REPO="${REPO:-qf1lzx/railway-hermes-oauth-image}"
VOLUME_MOUNT_PATH="${VOLUME_MOUNT_PATH:-/data}"
GOOGLE_TOKEN_JSON_PATH="${GOOGLE_TOKEN_JSON_PATH:-$HOME/.hermes/google_token.json}"
GOOGLE_CLIENT_SECRET_JSON_PATH="${GOOGLE_CLIENT_SECRET_JSON_PATH:-$HOME/.hermes/google_client_secret.json}"
DEFAULT_HERMES_WORKSPACE_DRIVE_FOLDER_ID="10Io92h6D936VcajyNYJJ9RYFkfKYQyXV"
HERMES_WORKSPACE_DRIVE_FOLDER_ID_WAS_SET="${HERMES_WORKSPACE_DRIVE_FOLDER_ID+x}"
HERMES_WORKSPACE_DRIVE_FOLDER_ID="${HERMES_WORKSPACE_DRIVE_FOLDER_ID:-$DEFAULT_HERMES_WORKSPACE_DRIVE_FOLDER_ID}"
HERMES_SHARED_STATE_SYNC="${HERMES_SHARED_STATE_SYNC:-drive}"
HERMES_SHARED_STATE_PULL_OVERWRITE="${HERMES_SHARED_STATE_PULL_OVERWRITE:-true}"
GSTACK_AUTO_SETUP="${GSTACK_AUTO_SETUP:-true}"
GSTACK_HOSTS="${GSTACK_HOSTS:-codex,claude}"
GSTACK_TEAM_MODE="${GSTACK_TEAM_MODE:-false}"
GSTACK_SKILL_PREFIX="${GSTACK_SKILL_PREFIX:-false}"
GSTACK_PLAYWRIGHT_BROWSERS_PATH="${GSTACK_PLAYWRIGHT_BROWSERS_PATH:-/tmp/ms-playwright}"
GSTACK_CLEAN_PLAYWRIGHT_CACHE="${GSTACK_CLEAN_PLAYWRIGHT_CACHE:-true}"
CLIENT_NAME="${CLIENT_NAME:-}"
CLIENT_SLUG="${CLIENT_SLUG:-}"
LOCAL_HERMES_HOME="${LOCAL_HERMES_HOME:-$HOME/.hermes}"
RUN_CLOUD_AUTH="${RUN_CLOUD_AUTH:-true}"
RUN_SMOKE_TESTS="${RUN_SMOKE_TESTS:-true}"

if [ -n "$CLIENT_NAME$CLIENT_SLUG" ] && [ -z "$HERMES_WORKSPACE_DRIVE_FOLDER_ID_WAS_SET" ]; then
  echo "Client mode detected (CLIENT_NAME/CLIENT_SLUG set) and no HERMES_WORKSPACE_DRIVE_FOLDER_ID was provided."
  echo "Disabling Drive shared-state sync to avoid wiring a client deployment to Nick's personal Hermes Drive folder."
  HERMES_WORKSPACE_DRIVE_FOLDER_ID=""
  HERMES_SHARED_STATE_SYNC="none"
fi

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "Missing required command: $1" >&2
    exit 1
  }
}

need_cmd railway
need_cmd python
need_cmd base64
need_cmd curl

railway_ssh() {
  local args=(ssh --service "$SERVICE_NAME")
  if [ -n "${RAILWAY_SSH_IDENTITY_FILE:-}" ]; then
    args+=(--identity-file "$RAILWAY_SSH_IDENTITY_FILE")
  fi
  railway "${args[@]}" "$@"
}

wait_for_railway_ssh() {
  local attempt
  for attempt in $(seq 1 30); do
    if railway_ssh 'echo ssh_ready' >/dev/null 2>&1; then
      return 0
    fi
    echo "Waiting for Railway SSH/deployment to become ready ($attempt/30)..."
    sleep 10
  done
  echo "Timed out waiting for Railway SSH/deployment readiness. Check: railway deployment list --service $SERVICE_NAME; if SSH reports no active deployment, pin the RUNNING deployment instance." >&2
  return 1
}

hydrate_shared_state_to_cloud() {
  local bundle
  bundle="$(mktemp /tmp/hermes-shared-state.XXXXXX.tar.gz)"
  python "$ROOT_DIR/shared_state_sync.py" pack --home "$LOCAL_HERMES_HOME" --output "$bundle"
  echo "Hydrating non-secret local Hermes shared state into Railway /data volume"
  base64 < "$bundle" | railway_ssh 'export HOME=/data HERMES_HOME=/data/.hermes; tmp=$(mktemp /tmp/hermes-shared-state.XXXXXX.tar.gz); base64 -d > "$tmp"; tar -xzf "$tmp" -C "$HERMES_HOME"; rm -f "$tmp"; echo "hydrated $HERMES_HOME from local shared-state bundle"'
  rm -f "$bundle"
}

if ! railway whoami >/dev/null 2>&1; then
  echo "Railway CLI is not logged in. Run: railway login --browserless" >&2
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

echo "Validating Telegram bot token with Telegram getMe (token is not printed)"
if ! curl -fsS "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/getMe" | python -c 'import json,sys; data=json.load(sys.stdin); assert data.get("ok") is True, data' >/dev/null; then
  echo "Telegram rejected TELEGRAM_BOT_TOKEN. Create/check the token in @BotFather before deploying." >&2
  exit 1
fi

echo "Creating/linking Railway project: $PROJECT_NAME"
if ! railway status >/dev/null 2>&1; then
  railway init --name "$PROJECT_NAME"
else
  echo "Already linked to a Railway project; using current link."
fi

echo "Ensuring Railway service exists: $SERVICE_NAME"
if ! railway service list --json 2>/dev/null | grep -q '"name":"'"$SERVICE_NAME"'"'; then
  echo "Trying GitHub-backed service from $REPO"
  if ! railway add --repo "$REPO" --service "$SERVICE_NAME"; then
    cat >&2 <<'EOF'

Railway could not add the GitHub-backed service. Falling back to an empty
service + `railway up`, which avoids Railway's GitHub integration path.
EOF
    railway add --service "$SERVICE_NAME"
  fi
else
  echo "Service $SERVICE_NAME already exists; skipping add."
fi

railway service link "$SERVICE_NAME" >/dev/null 2>&1 || true

echo "Ensuring persistent volume mounted at $VOLUME_MOUNT_PATH"
if ! railway volume list --json 2>/dev/null | grep -q '"mountPath":"'"$VOLUME_MOUNT_PATH"'"'; then
  # The Railway CLI currently expects the service to be linked for volume add;
  # passing --service directly can panic on some versions.
  railway volume add --mount-path "$VOLUME_MOUNT_PATH"
else
  echo "Volume at $VOLUME_MOUNT_PATH already exists; skipping add."
fi

echo "Setting Railway variables without printing secret values"
printf '%s' "$TELEGRAM_BOT_TOKEN" | railway variable set --service "$SERVICE_NAME" --skip-deploys --stdin TELEGRAM_BOT_TOKEN >/dev/null
railway variable set --service "$SERVICE_NAME" "TELEGRAM_ALLOWED_USERS=$TELEGRAM_ALLOWED_USERS" --skip-deploys >/dev/null
railway variable set --service "$SERVICE_NAME" "GATEWAY_ALLOW_ALL_USERS=false" --skip-deploys >/dev/null

if [ -s "$GOOGLE_TOKEN_JSON_PATH" ]; then
  printf '%s' "$(cat "$GOOGLE_TOKEN_JSON_PATH")" | railway variable set --service "$SERVICE_NAME" --skip-deploys --stdin GOOGLE_TOKEN_JSON >/dev/null
else
  echo "Warning: Google token not found at $GOOGLE_TOKEN_JSON_PATH; Drive workspace sync will not work until GOOGLE_TOKEN_JSON is set." >&2
fi

if [ -s "$GOOGLE_CLIENT_SECRET_JSON_PATH" ]; then
  printf '%s' "$(cat "$GOOGLE_CLIENT_SECRET_JSON_PATH")" | railway variable set --service "$SERVICE_NAME" --skip-deploys --stdin GOOGLE_CLIENT_SECRET_JSON >/dev/null
else
  echo "Warning: Google client secret not found at $GOOGLE_CLIENT_SECRET_JSON_PATH; Drive workspace sync will not work until GOOGLE_CLIENT_SECRET_JSON is set." >&2
fi

if [ -n "$HERMES_WORKSPACE_DRIVE_FOLDER_ID" ]; then
  railway variable set --service "$SERVICE_NAME" "HERMES_WORKSPACE_DRIVE_FOLDER_ID=$HERMES_WORKSPACE_DRIVE_FOLDER_ID" --skip-deploys >/dev/null
fi
railway variable set --service "$SERVICE_NAME" "HERMES_SHARED_STATE_SYNC=$HERMES_SHARED_STATE_SYNC" --skip-deploys >/dev/null
railway variable set --service "$SERVICE_NAME" "HERMES_SHARED_STATE_PULL_OVERWRITE=$HERMES_SHARED_STATE_PULL_OVERWRITE" --skip-deploys >/dev/null
railway variable set --service "$SERVICE_NAME" "GSTACK_AUTO_SETUP=$GSTACK_AUTO_SETUP" --skip-deploys >/dev/null
railway variable set --service "$SERVICE_NAME" "GSTACK_HOSTS=$GSTACK_HOSTS" --skip-deploys >/dev/null
railway variable set --service "$SERVICE_NAME" "GSTACK_TEAM_MODE=$GSTACK_TEAM_MODE" --skip-deploys >/dev/null
railway variable set --service "$SERVICE_NAME" "GSTACK_SKILL_PREFIX=$GSTACK_SKILL_PREFIX" --skip-deploys >/dev/null
railway variable set --service "$SERVICE_NAME" "GSTACK_PLAYWRIGHT_BROWSERS_PATH=$GSTACK_PLAYWRIGHT_BROWSERS_PATH" --skip-deploys >/dev/null
railway variable set --service "$SERVICE_NAME" "GSTACK_CLEAN_PLAYWRIGHT_CACHE=$GSTACK_CLEAN_PLAYWRIGHT_CACHE" --skip-deploys >/dev/null
if [ -n "$CLIENT_NAME" ]; then
  railway variable set --service "$SERVICE_NAME" "CLIENT_NAME=$CLIENT_NAME" --skip-deploys >/dev/null
fi
if [ -n "$CLIENT_SLUG" ]; then
  railway variable set --service "$SERVICE_NAME" "CLIENT_SLUG=$CLIENT_SLUG" --skip-deploys >/dev/null
fi

if [ "$HERMES_SHARED_STATE_SYNC" = "drive" ] && [ -s "$GOOGLE_TOKEN_JSON_PATH" ]; then
  echo "Publishing local non-secret Hermes shared state bundle to Drive"
  if ! HERMES_HOME="$LOCAL_HERMES_HOME" HERMES_WORKSPACE_DRIVE_FOLDER_ID="$HERMES_WORKSPACE_DRIVE_FOLDER_ID" "$ROOT_DIR/scripts/publish-shared-state-to-drive.sh"; then
    echo "Warning: Drive shared-state publish failed; continuing with direct Railway hydration." >&2
  fi
fi

echo "Triggering deployment from the current repo contents"
railway up --service "$SERVICE_NAME" --detach

wait_for_railway_ssh
hydrate_shared_state_to_cloud

if [ "$RUN_CLOUD_AUTH" = "true" ]; then
  cat <<EOF

Starting cloud OAuth bootstrap inside Railway.
Approve the printed Codex/Nous device-code URLs in your browser when prompted.
Set RUN_CLOUD_AUTH=false to skip this step on future runs when /data/.hermes/auth.json is already valid.
EOF
  railway_ssh 'export HOME=/data HERMES_HOME=/data/.hermes; hermes-cloud-auth'
  railway restart --service "$SERVICE_NAME" --yes || railway restart --service "$SERVICE_NAME"
fi

if [ "$RUN_SMOKE_TESTS" = "true" ]; then
  echo "Running Railway Hermes smoke test"
  wait_for_railway_ssh
  railway_ssh 'export HOME=/data HERMES_HOME=/data/.hermes; timeout 180 hermes chat -q "Reply with exactly RAILWAY_OK" --quiet --toolsets ""'
fi

cat <<EOF

Done.
Project/service is deployed, local shared state has been hydrated into Railway, and cloud OAuth/smoke tests ran unless disabled.

Useful checks:
  railway status
  railway logs --service $SERVICE_NAME --lines 100

If you want a public Railway URL for /health:
  railway domain --service $SERVICE_NAME --port 8080
EOF
