#!/usr/bin/env bash
set -euo pipefail

# Install/update gstack inside the current runtime HOME for Claude/Codex-style
# agents. This is intentionally safe to rerun on every Railway boot: the gstack
# repo is persisted on /data when HOME=/data, and setup relinks skills idempotently.

export HOME="${HOME:-/data}"
GSTACK_REPO="${GSTACK_REPO:-https://github.com/garrytan/gstack.git}"
GSTACK_REF="${GSTACK_REF:-main}"
GSTACK_DIR="${GSTACK_DIR:-$HOME/.gstack/repos/gstack}"
GSTACK_HOSTS="${GSTACK_HOSTS:-codex,claude}"
GSTACK_TEAM_MODE="${GSTACK_TEAM_MODE:-false}"
GSTACK_SKILL_PREFIX="${GSTACK_SKILL_PREFIX:-false}"
GSTACK_UPDATE_ON_BOOT="${GSTACK_UPDATE_ON_BOOT:-true}"
GSTACK_SETUP_TIMEOUT="${GSTACK_SETUP_TIMEOUT:-300}"
GSTACK_PLAYWRIGHT_BROWSERS_PATH="${GSTACK_PLAYWRIGHT_BROWSERS_PATH:-/tmp/ms-playwright}"
export PLAYWRIGHT_BROWSERS_PATH="$GSTACK_PLAYWRIGHT_BROWSERS_PATH"

log() { printf '[gstack] %s\n' "$*"; }

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    log "missing required command: $1"
    return 1
  }
}

if ! need_cmd git || ! need_cmd bash; then
  exit 1
fi

if ! command -v bun >/dev/null 2>&1; then
  log "bun is not installed; skipping gstack setup. Rebuild the image with bun or install bun first."
  exit 0
fi

mkdir -p "$(dirname "$GSTACK_DIR")"

if [ ! -d "$GSTACK_DIR/.git" ]; then
  log "cloning $GSTACK_REPO into $GSTACK_DIR"
  git clone --single-branch --depth 1 --branch "$GSTACK_REF" "$GSTACK_REPO" "$GSTACK_DIR"
elif [ "$GSTACK_UPDATE_ON_BOOT" = "true" ]; then
  log "updating existing gstack checkout at $GSTACK_DIR"
  git -C "$GSTACK_DIR" fetch --depth 1 origin "$GSTACK_REF" >/dev/null 2>&1 || true
  git -C "$GSTACK_DIR" checkout -q FETCH_HEAD >/dev/null 2>&1 || git -C "$GSTACK_DIR" checkout -q "$GSTACK_REF" >/dev/null 2>&1 || true
fi

if [ "$GSTACK_SKILL_PREFIX" = "true" ]; then
  prefix_arg="--prefix"
else
  prefix_arg="--no-prefix"
fi

IFS=',' read -r -a hosts <<< "$GSTACK_HOSTS"
for raw_host in "${hosts[@]}"; do
  host="$(printf '%s' "$raw_host" | tr -d '[:space:]')"
  [ -n "$host" ] || continue
  case "$host" in
    claude|codex|kiro|factory|opencode|auto) ;;
    hermes)
      log "host=hermes only generates methodology artifacts upstream; skipping direct setup"
      continue
      ;;
    *)
      log "unknown host '$host'; expected claude,codex,kiro,factory,opencode,auto; skipping"
      continue
      ;;
  esac

  args=(--host "$host" "$prefix_arg" --quiet)
  if [ "$GSTACK_TEAM_MODE" = "true" ]; then
    args+=(--team)
  else
    args+=(--no-team)
  fi

  log "running ./setup ${args[*]}"
  if command -v timeout >/dev/null 2>&1; then
    timeout "$GSTACK_SETUP_TIMEOUT" bash -lc "cd \"$GSTACK_DIR\" && ./setup ${args[*]}"
  else
    (cd "$GSTACK_DIR" && ./setup "${args[@]}")
  fi
done

# Make gstack helper binaries easy to call from Hermes terminal sessions.
profile="$HOME/.profile"
path_line="export PATH=\"$GSTACK_DIR/bin:\$PATH\""
if [ ! -f "$profile" ] || ! grep -qF "$GSTACK_DIR/bin" "$profile"; then
  printf '\n# gstack helpers\n%s\n' "$path_line" >> "$profile"
fi

log "setup complete"
