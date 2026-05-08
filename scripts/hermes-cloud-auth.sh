#!/usr/bin/env bash
set -euo pipefail

export HOME="${HOME:-/data}"
export HERMES_HOME="${HERMES_HOME:-/data/.hermes}"

mkdir -p "$HERMES_HOME"
chmod 700 "$HERMES_HOME" || true

echo "Using HOME=$HOME"
echo "Using HERMES_HOME=$HERMES_HOME"
echo
echo "This creates cloud-owned OAuth tokens on the persistent Railway volume."
echo "Copy/paste each printed OAuth link or device-code URL into your normal browser when prompted."
echo

hermes auth add openai-codex --type oauth
hermes auth add nous --type oauth

echo
echo "Verifying cloud auth store..."
hermes auth list

echo
if [ -s "$HERMES_HOME/auth.json" ]; then
  echo "OK: wrote $HERMES_HOME/auth.json"
  ls -lh "$HERMES_HOME/auth.json"
else
  echo "ERROR: $HERMES_HOME/auth.json was not created" >&2
  exit 1
fi

echo
echo "Restart/redeploy the Railway service so the gateway picks up the new cloud OAuth tokens."
