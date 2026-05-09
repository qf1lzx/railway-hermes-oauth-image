#!/usr/bin/env bash
set -euo pipefail

# Initialize a future-client repo with gstack team-mode plus a tiny Hermes-facing
# AGENTS.md bridge. Run this from the client repo root, or pass the repo path as
# the first argument.

TARGET_REPO="${1:-${CLIENT_REPO:-$(pwd)}}"
GSTACK_MODE="${GSTACK_MODE:-required}" # required|optional
GSTACK_HOME="${GSTACK_HOME:-$HOME/.claude/skills/gstack}"
GSTACK_REPO="${GSTACK_REPO:-https://github.com/garrytan/gstack.git}"
GSTACK_REF="${GSTACK_REF:-main}"
CLIENT_NAME="${CLIENT_NAME:-}"

log() { printf '[client-gstack] %s\n' "$*"; }

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "Missing required command: $1" >&2
    exit 1
  }
}

need_cmd git
need_cmd bash

if [ "$GSTACK_MODE" != "required" ] && [ "$GSTACK_MODE" != "optional" ]; then
  echo "GSTACK_MODE must be required or optional" >&2
  exit 1
fi

mkdir -p "$(dirname "$GSTACK_HOME")"
if [ ! -d "$GSTACK_HOME/.git" ]; then
  log "cloning gstack into $GSTACK_HOME"
  git clone --single-branch --depth 1 --branch "$GSTACK_REF" "$GSTACK_REPO" "$GSTACK_HOME"
else
  log "updating gstack at $GSTACK_HOME"
  git -C "$GSTACK_HOME" fetch --depth 1 origin "$GSTACK_REF" >/dev/null 2>&1 || true
  git -C "$GSTACK_HOME" checkout -q FETCH_HEAD >/dev/null 2>&1 || git -C "$GSTACK_HOME" checkout -q "$GSTACK_REF" >/dev/null 2>&1 || true
fi

# Install for both Claude and Codex when possible. Do not fail the whole client
# bootstrap if one host's optional integration has a transient issue.
(cd "$GSTACK_HOME" && ./setup --host claude --team --no-prefix --quiet) || log "warning: gstack Claude setup failed"
(cd "$GSTACK_HOME" && ./setup --host codex --team --no-prefix --quiet) || log "warning: gstack Codex setup failed"

if [ ! -d "$TARGET_REPO/.git" ]; then
  echo "Target is not a git repo: $TARGET_REPO" >&2
  exit 1
fi

log "initializing gstack team mode ($GSTACK_MODE) in $TARGET_REPO"
(cd "$TARGET_REPO" && "$GSTACK_HOME/bin/gstack-team-init" "$GSTACK_MODE")

AGENTS_MD="$TARGET_REPO/AGENTS.md"
if [ ! -f "$AGENTS_MD" ] || ! grep -q "gstack" "$AGENTS_MD" 2>/dev/null; then
  {
    printf '\n## AI workflow\n\n'
    if [ -n "$CLIENT_NAME" ]; then
      printf 'Client/project: %s.\n\n' "$CLIENT_NAME"
    fi
    cat <<'EOF'
This repo uses gstack for AI-assisted product/engineering workflow. If CLAUDE.md contains a gstack section, follow it before doing implementation work. For Hermes sessions, treat the gstack flow as the default operating cadence: clarify goal, plan, review scope/architecture, build, QA, ship, and record reusable learnings.

Do not commit secrets, OAuth tokens, Railway variables, `.env` files, or client data exports. Prefer client-specific environment variables and deployment secrets over repository files.
EOF
  } >> "$AGENTS_MD"
  log "updated AGENTS.md with Hermes/gstack bridge"
fi

cat <<EOF

Done. Review and commit generated client bootstrap files:
  cd "$TARGET_REPO"
  git status --short
  git add CLAUDE.md AGENTS.md .claude/ .gitignore
  git commit -m "chore: add gstack AI workflow"
EOF
