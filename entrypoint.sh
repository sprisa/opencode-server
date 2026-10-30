#!/usr/bin/env bash
set -euo pipefail

source /usr/local/lib/opencode/init-home.sh

# v2 reads OPENCODE_PASSWORD (or the legacy OPENCODE_SERVER_PASSWORD) directly.
# Leave both unset to let v2 generate a password and print it on startup.
# Foreground serve honors these credentials; --service uses its own saved config.
args=(serve --hostname 0.0.0.0 --port "${OPENCODE_PORT:-4096}")
case "${OPENCODE_PRINT_LOGS:-false}" in
  true|1)
    export OPENCODE_PRINT_LOGS=1
    args+=(--print-logs)
    ;;
esac
if [ -n "${OPENCODE_LOG_LEVEL:-}" ]; then
  # v2's CLI requires lowercase levels; accept the existing uppercase image ENV.
  export OPENCODE_LOG_LEVEL="$(printf '%s' "${OPENCODE_LOG_LEVEL}" | tr '[:upper:]' '[:lower:]')"
  args+=(--log-level "${OPENCODE_LOG_LEVEL}")
fi
if [ -n "${OPENCODE_CORS_ORIGIN:-}" ]; then
  args+=(--cors "${OPENCODE_CORS_ORIGIN}")
fi
exec opencode "${args[@]}"
