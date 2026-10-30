#!/usr/bin/env bash
# Shared initialization sourced by both server entrypoints.
mkdir -p "${HOME}/.config/opencode" "${HOME}/workspace"
cd "${HOME}/workspace"

# This is opt-in because customer-configured tools can be large and compete with
# the server for resources after startup. Keep system and project tools lazy: the
# home ceiling plus an empty system config scopes this install to the global user
# config at ~/.config/mise/config.toml.
if [ "${OPENCODE_INSTALL_HOME_TOOLS:-false}" = "true" ] && [ -f "${HOME}/.config/mise/config.toml" ]; then
  (
    sleep 3
    if ! MISE_SYSTEM_CONFIG_FILE=/etc/mise/empty.toml MISE_CEILING_PATHS="${HOME}" \
      mise -C "${HOME}" install --yes; then
      printf '%s\n' 'opencode: home tool installation failed' >&2
    fi
  ) &
fi
