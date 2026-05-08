#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HERMES_HOME="${HERMES_HOME:-$HOME/.hermes}"
export HERMES_HOME

if [ -z "${HERMES_WORKSPACE_DRIVE_FOLDER_ID:-}" ]; then
  HERMES_WORKSPACE_DRIVE_FOLDER_ID="10Io92h6D936VcajyNYJJ9RYFkfKYQyXV"
  export HERMES_WORKSPACE_DRIVE_FOLDER_ID
fi

if [ ! -s "$HERMES_HOME/google_token.json" ]; then
  echo "Missing Google token: $HERMES_HOME/google_token.json" >&2
  exit 1
fi

if [ ! -s "$HERMES_HOME/google_client_secret.json" ]; then
  echo "Missing Google client secret: $HERMES_HOME/google_client_secret.json" >&2
  exit 1
fi

python "$ROOT_DIR/shared_state_sync.py" push
