#!/usr/bin/env bash
set -euo pipefail

export HOME="${HOME:-/data}"
export HERMES_HOME="${HERMES_HOME:-/data/.hermes}"
export PORT="${PORT:-8080}"

mkdir -p "$HERMES_HOME" \
  "$HERMES_HOME/cron" "$HERMES_HOME/sessions" "$HERMES_HOME/logs" \
  "$HERMES_HOME/memories" "$HERMES_HOME/skills" "$HERMES_HOME/pairing" \
  "$HERMES_HOME/hooks" "$HERMES_HOME/image_cache" "$HERMES_HOME/audio_cache" \
  "$HERMES_HOME/workspace" \
  "$HOME/.codex" "$HOME/.claude" "$HOME/.gstack"

chmod 700 "$HERMES_HOME" "$HOME/.codex" "$HOME/.claude" "$HOME/.gstack" || true
rm -f "$HERMES_HOME/gateway.pid"

# gstack/Playwright can be large. If an earlier boot wrote browser caches to the
# persistent volume, clear them before hydrating secrets so a full volume can
# recover automatically. Runtime gstack setup uses /tmp for Playwright browsers.
if [ "${GSTACK_CLEAN_PLAYWRIGHT_CACHE:-true}" = "true" ]; then
  rm -rf "$HOME/Library/Caches/ms-playwright" "$HOME/.cache/ms-playwright" 2>/dev/null || true
fi

write_b64_file() {
  local var_name="$1"
  local target="$2"
  local value="${!var_name:-}"

  if [ -n "$value" ]; then
    printf '%s' "$value" | base64 -d > "$target"
    chmod 600 "$target"
    echo "[boot] wrote $target from $var_name"
  fi
}

write_raw_file() {
  local var_name="$1"
  local target="$2"
  local value="${!var_name:-}"

  if [ -n "$value" ]; then
    printf '%s' "$value" > "$target"
    chmod 600 "$target"
    echo "[boot] wrote $target from $var_name"
  fi
}

append_env_if_set() {
  local key="$1"
  local value="${!key:-}"
  local tmp

  if [ -n "$value" ]; then
    tmp="$(mktemp)"
    if [ -f "$HERMES_HOME/.env" ]; then
      grep -v "^${key}=" "$HERMES_HOME/.env" > "$tmp" 2>/dev/null || true
    fi
    printf '%s=%s\n' "$key" "$value" >> "$tmp"
    mv "$tmp" "$HERMES_HOME/.env"
    chmod 600 "$HERMES_HOME/.env"
  fi
}

# Preferred: run `hermes-cloud-auth` inside Railway so OAuth tokens are created
# by the cloud runtime and persisted on the /data volume. Config/env hydration
# remains supported for non-OAuth settings.
write_b64_file HERMES_CONFIG_YAML_B64 "$HERMES_HOME/config.yaml"
write_raw_file HERMES_CONFIG_YAML "$HERMES_HOME/config.yaml"
write_b64_file HERMES_ENV_B64 "$HERMES_HOME/.env"
write_raw_file HERMES_ENV "$HERMES_HOME/.env"

# Optional Google Workspace / Drive OAuth for collaboration with the shared Hermes Drive
# workspace. Railway cannot mount Google Drive Desktop, so it uses Drive API
# credentials persisted under the Hermes home on the /data volume.
write_b64_file GOOGLE_TOKEN_JSON_B64 "$HERMES_HOME/google_token.json"
write_raw_file GOOGLE_TOKEN_JSON "$HERMES_HOME/google_token.json"
write_b64_file GOOGLE_CLIENT_SECRET_JSON_B64 "$HERMES_HOME/google_client_secret.json"
write_raw_file GOOGLE_CLIENT_SECRET_JSON "$HERMES_HOME/google_client_secret.json"

if [ -n "${HERMES_SHARED_STATE_TAR_B64:-}" ]; then
  tmp_bundle="$(mktemp /tmp/hermes-shared-state.XXXXXX.tar.gz)"
  printf '%s' "$HERMES_SHARED_STATE_TAR_B64" | base64 -d > "$tmp_bundle"
  tar -xzf "$tmp_bundle" -C "$HERMES_HOME"
  rm -f "$tmp_bundle"
  echo "[boot] unpacked HERMES_SHARED_STATE_TAR_B64 into $HERMES_HOME"
fi

if [ "${HERMES_SHARED_STATE_SYNC:-}" = "drive" ] && [ -n "${HERMES_WORKSPACE_DRIVE_FOLDER_ID:-}" ] && [ -s "$HERMES_HOME/google_token.json" ]; then
  sync_args=(pull)
  if [ "${HERMES_SHARED_STATE_PULL_OVERWRITE:-false}" = "true" ]; then
    sync_args+=(--overwrite)
  fi
  python /app/shared_state_sync.py "${sync_args[@]}" || echo "[boot] WARNING: Drive shared-state pull failed; continuing without it"
fi

if [ ! -f "$HERMES_HOME/.env" ]; then
  touch "$HERMES_HOME/.env"
  chmod 600 "$HERMES_HOME/.env"
fi

if [ ! -f "$HERMES_HOME/config.yaml" ] || [ "${HERMES_REGENERATE_CONFIG_FROM_ENV:-false}" = "true" ]; then
  cat > "$HERMES_HOME/config.yaml" <<EOF
model:
  provider: "${HERMES_MAIN_PROVIDER:-${HERMES_MODEL_PROVIDER:-openai-codex}}"
  default: "${HERMES_MAIN_MODEL:-${LLM_MODEL:-openai/gpt-5.4}}"
  base_url: "${HERMES_MAIN_BASE_URL:-}"
  api_key: "${HERMES_MAIN_API_KEY:-}"

delegation:
  provider: "${HERMES_DELEGATION_PROVIDER:-nous}"
  model: "${HERMES_DELEGATION_MODEL:-moonshotai/kimi-k2.6}"
  base_url: "${HERMES_DELEGATION_BASE_URL:-https://inference-api.nousresearch.com/v1}"
  api_key: "${HERMES_DELEGATION_API_KEY:-}"

auxiliary:
  vision:
    provider: "${HERMES_AUX_PROVIDER:-nous}"
    model: "${HERMES_AUX_MODEL:-google/gemini-3.1-flash-lite-preview}"
    base_url: "${HERMES_AUX_BASE_URL:-https://inference-api.nousresearch.com/v1}"
    api_key: "${HERMES_AUX_API_KEY:-}"
    context_length: ${HERMES_AUX_CONTEXT_LENGTH:-1048576}
  web_extract:
    provider: "${HERMES_AUX_PROVIDER:-nous}"
    model: "${HERMES_AUX_MODEL:-google/gemini-3.1-flash-lite-preview}"
    base_url: "${HERMES_AUX_BASE_URL:-https://inference-api.nousresearch.com/v1}"
    api_key: "${HERMES_AUX_API_KEY:-}"
    context_length: ${HERMES_AUX_CONTEXT_LENGTH:-1048576}
  compression:
    provider: "${HERMES_AUX_PROVIDER:-nous}"
    model: "${HERMES_AUX_MODEL:-google/gemini-3.1-flash-lite-preview}"
    base_url: "${HERMES_AUX_BASE_URL:-https://inference-api.nousresearch.com/v1}"
    api_key: "${HERMES_AUX_API_KEY:-}"
    context_length: ${HERMES_AUX_CONTEXT_LENGTH:-1048576}
  title_generation:
    provider: "${HERMES_AUX_PROVIDER:-nous}"
    model: "${HERMES_AUX_MODEL:-google/gemini-3.1-flash-lite-preview}"
    base_url: "${HERMES_AUX_BASE_URL:-https://inference-api.nousresearch.com/v1}"
    api_key: "${HERMES_AUX_API_KEY:-}"
  approval:
    provider: "${HERMES_AUX_PROVIDER:-nous}"
    model: "${HERMES_AUX_MODEL:-google/gemini-3.1-flash-lite-preview}"
    base_url: "${HERMES_AUX_BASE_URL:-https://inference-api.nousresearch.com/v1}"
    api_key: "${HERMES_AUX_API_KEY:-}"
  skills_hub:
    provider: "${HERMES_AUX_PROVIDER:-nous}"
    model: "${HERMES_AUX_MODEL:-google/gemini-3.1-flash-lite-preview}"
    base_url: "${HERMES_AUX_BASE_URL:-https://inference-api.nousresearch.com/v1}"
    api_key: "${HERMES_AUX_API_KEY:-}"
  mcp:
    provider: "${HERMES_AUX_PROVIDER:-nous}"
    model: "${HERMES_AUX_MODEL:-google/gemini-3.1-flash-lite-preview}"
    base_url: "${HERMES_AUX_BASE_URL:-https://inference-api.nousresearch.com/v1}"
    api_key: "${HERMES_AUX_API_KEY:-}"

terminal:
  backend: "local"
  cwd: "/data"
  timeout: 180

agent:
  max_iterations: ${HERMES_MAX_ITERATIONS:-90}

memory:
  memory_enabled: ${HERMES_MEMORY_ENABLED:-true}
  user_profile_enabled: ${HERMES_USER_PROFILE_ENABLED:-true}
  provider: "${HERMES_MEMORY_PROVIDER:-built_in}"

data_dir: "$HERMES_HOME"
EOF
  chmod 600 "$HERMES_HOME/config.yaml"
  echo "[boot] wrote generated config.yaml from Railway variables/defaults"
fi

# Mirror common Railway variables into Hermes .env. This is what makes the image
# template-like: users can set normal env vars instead of shipping a prepared .env.
for key in \
  TELEGRAM_BOT_TOKEN TELEGRAM_ALLOWED_USERS TELEGRAM_ALLOWED_CHATS \
  DISCORD_BOT_TOKEN DISCORD_ALLOWED_USERS DISCORD_ALLOWED_CHANNELS \
  SLACK_BOT_TOKEN SLACK_APP_TOKEN SLACK_ALLOWED_USERS SLACK_ALLOWED_CHANNELS \
  MATRIX_HOMESERVER MATRIX_ACCESS_TOKEN MATRIX_ROOM_ID \
  GATEWAY_ALLOW_ALL_USERS WEBHOOK_SECRET \
  FIRECRAWL_API_KEY TAVILY_API_KEY EXA_API_KEY FAL_KEY FAL_API_KEY \
  OPENAI_API_KEY OPENAI_BASE_URL ANTHROPIC_API_KEY OPENROUTER_API_KEY \
  GOOGLE_API_KEY GEMINI_API_KEY DEEPSEEK_API_KEY XAI_API_KEY GROQ_API_KEY MISTRAL_API_KEY \
  KIMI_API_KEY DASHSCOPE_API_KEY GLM_API_KEY HF_TOKEN MINIMAX_API_KEY MINIMAX_CN_API_KEY XIAOMI_API_KEY \
  KILOCODE_API_KEY AI_GATEWAY_API_KEY OPENCODE_ZEN_API_KEY OPENCODE_GO_API_KEY \
  GITHUB_TOKEN COPILOT_GITHUB_TOKEN HONCHO_API_KEY GBRAIN_API_KEY \
  HERMES_REGENERATE_CONFIG_FROM_ENV HERMES_MAIN_PROVIDER HERMES_MAIN_MODEL HERMES_MAIN_BASE_URL HERMES_MAIN_API_KEY \
  HERMES_DELEGATION_PROVIDER HERMES_DELEGATION_MODEL HERMES_DELEGATION_BASE_URL HERMES_DELEGATION_API_KEY \
  HERMES_AUX_PROVIDER HERMES_AUX_MODEL HERMES_AUX_BASE_URL HERMES_AUX_API_KEY HERMES_AUX_CONTEXT_LENGTH \
  HERMES_MEMORY_PROVIDER HERMES_MEMORY_ENABLED HERMES_USER_PROFILE_ENABLED HERMES_OAUTH_PROVIDERS \
  HERMES_WORKSPACE_DRIVE_FOLDER_ID HERMES_SHARED_STATE_SYNC HERMES_SHARED_STATE_PULL_OVERWRITE \
  GSTACK_AUTO_SETUP GSTACK_HOSTS GSTACK_TEAM_MODE GSTACK_SKILL_PREFIX GSTACK_REPO GSTACK_REF GSTACK_UPDATE_ON_BOOT GSTACK_PLAYWRIGHT_BROWSERS_PATH GSTACK_CLEAN_PLAYWRIGHT_CACHE \
  HERMES_YOLO_MODE HERMES_API_TIMEOUT HERMES_STREAM_READ_TIMEOUT HERMES_REDACT_SECRETS; do
  append_env_if_set "$key"
done

if [ ! -s "$HERMES_HOME/auth.json" ]; then
  echo "[boot] WARNING: no cloud OAuth credentials found. After deploy, run: railway ssh --service <service> then hermes-cloud-auth. Copy/paste the printed OAuth links into your browser; tokens are written to $HERMES_HOME/auth.json on the /data volume."
fi

# Gateway-only runtime. Railway still expects an HTTP listener for health checks,
# so we run a tiny /health server on $PORT next to the Hermes messaging gateway.
python /app/health.py &
health_pid=$!
echo "[boot] health server pid=$health_pid"

if [ "${GSTACK_AUTO_SETUP:-true}" = "true" ]; then
  setup-gstack > "$HERMES_HOME/logs/gstack-setup.log" 2>&1 &
  gstack_pid=$!
  echo "[boot] gstack setup pid=$gstack_pid (log: $HERMES_HOME/logs/gstack-setup.log)"
else
  gstack_pid=""
fi

hermes gateway run > "$HERMES_HOME/logs/gateway.log" 2>&1 &
gateway_pid=$!
echo "[boot] gateway pid=$gateway_pid"

cleanup() {
  echo "[boot] shutting down"
  if [ -n "${gstack_pid:-}" ]; then
    kill "$gstack_pid" 2>/dev/null || true
  fi
  kill "$gateway_pid" "$health_pid" 2>/dev/null || true
  wait "$gateway_pid" "$health_pid" ${gstack_pid:-} 2>/dev/null || true
}
trap cleanup TERM INT

set +e
wait -n "$gateway_pid" "$health_pid"
exit_code=$?
set -e
echo "[boot] a child exited with code $exit_code"
if [ -f "$HERMES_HOME/logs/gateway.log" ]; then
  echo "[boot] last gateway log lines:"
  tail -n 80 "$HERMES_HOME/logs/gateway.log" || true
fi
cleanup
exit "$exit_code"
