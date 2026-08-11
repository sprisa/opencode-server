#!/usr/bin/env bash
set -euo pipefail

mkdir -p "${HOME}/.config/opencode" "${HOME}/workspace"
cd "${HOME}/workspace"

# This is opt-in because customer-configured tools can be large and compete with
# the server for resources after startup. Keep system and project tools lazy: the
# home ceiling plus a null system config scopes this install to the global user
# config at ~/.config/mise/config.toml.
if [ "${OPENCODE_INSTALL_HOME_TOOLS:-false}" = "true" ] && [ -f "${HOME}/.config/mise/config.toml" ]; then
  (
    sleep 3
    if ! MISE_SYSTEM_CONFIG_FILE=/dev/null MISE_CEILING_PATHS="${HOME}" \
      mise -C "${HOME}" install --yes; then
      printf '%s\n' 'opencode: home tool installation failed' >&2
    fi
  ) &
fi

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
