#!/usr/bin/env bash
set -euo pipefail

export HOME="${HOME:-/data}"
export HERMES_HOME="${HERMES_HOME:-/data/.hermes}"
export PORT="${PORT:-8080}"

mkdir -p "$HERMES_HOME" \
  "$HERMES_HOME/cron" "$HERMES_HOME/sessions" "$HERMES_HOME/logs" \
  "$HERMES_HOME/memories" "$HERMES_HOME/skills" "$HERMES_HOME/pairing" \
  "$HERMES_HOME/hooks" "$HERMES_HOME/image_cache" "$HERMES_HOME/audio_cache" \
  "$HERMES_HOME/workspace"

chmod 700 "$HERMES_HOME" || true
rm -f "$HERMES_HOME/gateway.pid"

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

write_b64_file HERMES_AUTH_JSON_B64 "$HERMES_HOME/auth.json"
write_b64_file HERMES_CONFIG_YAML_B64 "$HERMES_HOME/config.yaml"
write_b64_file HERMES_ENV_B64 "$HERMES_HOME/.env"

if [ ! -f "$HERMES_HOME/.env" ]; then
  touch "$HERMES_HOME/.env"
  chmod 600 "$HERMES_HOME/.env"
fi

if [ ! -f "$HERMES_HOME/config.yaml" ]; then
  cat > "$HERMES_HOME/config.yaml" <<EOF
model:
  provider: "${HERMES_MODEL_PROVIDER:-openai-codex}"
  default: "${LLM_MODEL:-openai/gpt-5.4}"

terminal:
  backend: "local"
  cwd: "/data"
  timeout: 180

agent:
  max_iterations: 90

data_dir: "$HERMES_HOME"
EOF
  chmod 600 "$HERMES_HOME/config.yaml"
  echo "[boot] wrote fallback config.yaml"
fi

# Mirror selected Railway env vars into Hermes .env without overwriting an encoded .env.
# Keep this small and explicit; secrets should usually be provided through HERMES_ENV_B64.
if [ -z "${HERMES_ENV_B64:-}" ]; then
  for key in \
    LLM_MODEL HERMES_MODEL_PROVIDER \
    TELEGRAM_BOT_TOKEN TELEGRAM_ALLOWED_USERS \
    DISCORD_BOT_TOKEN DISCORD_ALLOWED_USERS \
    SLACK_BOT_TOKEN SLACK_APP_TOKEN \
    GATEWAY_ALLOW_ALL_USERS; do
    value="${!key:-}"
    if [ -n "$value" ] && ! grep -q "^${key}=" "$HERMES_HOME/.env" 2>/dev/null; then
      printf '%s=%s\n' "$key" "$value" >> "$HERMES_HOME/.env"
    fi
  done
fi

if [ ! -s "$HERMES_HOME/auth.json" ]; then
  echo "[boot] WARNING: $HERMES_HOME/auth.json missing/empty. OAuth providers like nous/openai-codex will not work until HERMES_AUTH_JSON_B64 is set."
fi

# Gateway-only runtime. Railway still expects an HTTP listener for health checks,
# so we run a tiny /health server on $PORT next to the Hermes messaging gateway.
python /app/health.py &
health_pid=$!
echo "[boot] health server pid=$health_pid"

hermes gateway > "$HERMES_HOME/logs/gateway.log" 2>&1 &
gateway_pid=$!
echo "[boot] gateway pid=$gateway_pid"

cleanup() {
  echo "[boot] shutting down"
  kill "$gateway_pid" "$health_pid" 2>/dev/null || true
  wait "$gateway_pid" "$health_pid" 2>/dev/null || true
}
trap cleanup TERM INT

wait -n "$gateway_pid" "$health_pid"
exit_code=$?
echo "[boot] a child exited with code $exit_code"
cleanup
exit "$exit_code"
