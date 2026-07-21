#!/usr/bin/env bash
set -euo pipefail

mkdir -p "${HOME}/.config/opencode" "${HOME}/workspace"
cd "${HOME}/workspace"

args=(serve --hostname 0.0.0.0 --port "${OPENCODE_PORT:-4096}")
if [ "${OPENCODE_PRINT_LOGS:-false}" = "true" ]; then
  args+=(--print-logs)
fi
if [ -n "${OPENCODE_LOG_LEVEL:-}" ]; then
  args+=(--log-level "${OPENCODE_LOG_LEVEL}")
fi
if [ -n "${OPENCODE_CORS_ORIGIN:-}" ]; then
  args+=(--cors "${OPENCODE_CORS_ORIGIN}")
fi
exec opencode "${args[@]}"
