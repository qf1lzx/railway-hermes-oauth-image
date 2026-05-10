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

auth_provider() {
  local provider="$1"
  if hermes auth status "$provider" 2>/dev/null | grep -q 'logged in'; then
    echo "$provider already logged in; skipping"
    return 0
  fi

  echo "Authenticating $provider..."
  if hermes auth add "$provider" --type oauth --no-browser; then
    echo "$provider auth completed"
    return 0
  fi

  echo "WARNING: $provider auth failed; continuing so another provider is not blocked." >&2
  return 1
}

failed=0
providers_csv="${HERMES_OAUTH_PROVIDERS:-nous,openai-codex}"
IFS=',' read -r -a providers <<< "$providers_csv"

# Run providers independently. One provider failure should not prevent another
# subscription/OAuth provider from being bootstrapped on the persistent volume.
for provider in "${providers[@]}"; do
  provider="$(printf '%s' "$provider" | xargs)"
  [ -n "$provider" ] || continue
  auth_provider "$provider" || failed=1
done

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

if [ "${failed:-0}" != "0" ]; then
  echo
  echo "One or more providers failed. Re-run this helper later or authenticate that provider manually with:" >&2
  echo "  export HOME=/data HERMES_HOME=/data/.hermes" >&2
  echo "  hermes auth add <provider> --type oauth --no-browser" >&2
fi

echo
echo "Restart/redeploy the Railway service so the gateway picks up the new cloud OAuth tokens."
