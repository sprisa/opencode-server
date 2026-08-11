#!/usr/bin/env bash
# End-to-end test for the delayed home-tool installer.
# Usage: test-home-tools-e2e.sh [image]
set -euo pipefail

IMAGE="${1:-opencode-test:latest}"
NAME="opencode-home-tools-e2e-$$"
FIXTURE="$(mktemp -d)"

cleanup() {
  docker rm -f "${NAME}" >/dev/null 2>&1 || true
  rm -rf "${FIXTURE}"
}
trap cleanup EXIT

mkdir -p "${FIXTURE}/mise" "${FIXTURE}/project"
printf '%s\n' '[tools]' 'claude = "latest"' > "${FIXTURE}/mise/config.toml"
printf '%s\n' '[tools]' 'node = "latest"' > "${FIXTURE}/project/mise.toml"

# The default must preserve lazy behavior even when a home config exists.
docker run -d --name "${NAME}" \
  --mount "type=bind,src=${FIXTURE}/mise,dst=/home/opencode/.config/mise" \
  --mount "type=bind,src=${FIXTURE}/project/mise.toml,dst=/home/opencode/workspace/mise.toml,readonly" \
  "${IMAGE}" >/dev/null

if [ "$(docker inspect -f '{{.State.Running}}' "${NAME}")" != "true" ]; then
  docker logs "${NAME}" >&2 || true
  exit 1
fi

config="$(docker exec "${NAME}" opencode debug config --pure)"
case "${config}" in
  *"/etc/opencode/mise-instructions.md"*) ;;
  *)
    echo "mise instruction was not loaded into OpenCode config" >&2
    exit 1
    ;;
esac

sleep 4
if docker exec "${NAME}" bash -c 'for path in /opt/mise/installs/claude/*/claude; do [ -x "$path" ] && exit 0; done; exit 1'; then
  echo "home tool installed while the feature was disabled" >&2
  exit 1
fi
docker rm -f "${NAME}" >/dev/null

# The opt-in path uses the same real image and home/project config.
docker run -d --name "${NAME}" \
  -e OPENCODE_INSTALL_HOME_TOOLS=true \
  -e OPENCODE_PRINT_LOGS=true \
  --mount "type=bind,src=${FIXTURE}/mise,dst=/home/opencode/.config/mise" \
  --mount "type=bind,src=${FIXTURE}/project/mise.toml,dst=/home/opencode/workspace/mise.toml,readonly" \
  "${IMAGE}" >/dev/null

if [ "$(docker inspect -f '{{.State.Running}}' "${NAME}")" != "true" ]; then
  docker logs "${NAME}" >&2 || true
  exit 1
fi

# The server process must be up before the three-second installer delay expires.
sleep 1
if ! docker exec "${NAME}" bash -c 'for path in /opt/mise/installs/claude/*/claude; do [ -x "$path" ] && exit 0; done; exit 1'; then
  : # Not installed yet is the expected state.
else
  echo "home tool installed before the startup delay" >&2
  exit 1
fi

health="000"
for _ in $(seq 1 30); do
  health="$(docker exec "${NAME}" curl -s -o /dev/null -m 1 -w '%{http_code}' http://127.0.0.1:4096/global/health || true)"
  if [ "${health}" != "000" ]; then
    break
  fi
  sleep 1
done
case "${health}" in
  200|401) ;;
  *)
    echo "opencode health check returned ${health}" >&2
    docker logs "${NAME}" >&2 || true
    exit 1
    ;;
esac

installed=0
for _ in $(seq 1 90); do
  if docker exec "${NAME}" bash -c 'for path in /opt/mise/installs/claude/*/claude; do [ -x "$path" ] && exit 0; done; exit 1'; then
    installed=1
    break
  fi
  sleep 1
done
if [ "${installed}" -ne 1 ]; then
  echo "Claude was not installed by the background home-tool job" >&2
  docker logs "${NAME}" >&2 || true
  exit 1
fi

# The system config and project config must remain lazy.
if docker exec "${NAME}" bash -c 'for path in /opt/mise/installs/github-jqlang-jq/*/jq /opt/mise/installs/node/*/bin/node; do [ -x "$path" ] && exit 0; done; exit 1'; then
  echo "system/project tool was eagerly installed" >&2
  exit 1
fi

echo "PASS: Docker home-tool installation e2e (${IMAGE})"
