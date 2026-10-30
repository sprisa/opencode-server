#!/usr/bin/env bash
# End-to-end test for the delayed home-tool installer.
# Usage: test-home-tools-e2e.sh [image]
set -euo pipefail

IMAGE="${1:-opencode-test:latest}"
VERSION="$(docker image inspect -f '{{index .Config.Labels "org.opencontainers.image.version"}}' "$IMAGE")"
case "$VERSION" in
  1.*) HEALTH_PATH=/global/health; CONFIG_PATH=/config ;;
  2.*) HEALTH_PATH=/api/info; CONFIG_PATH='/api/config?directory=/home/opencode/workspace' ;;
  *) echo "unsupported image version: $VERSION" >&2; exit 1 ;;
esac
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
echo "Checking default lazy home-tool behavior (${IMAGE})..."
docker run -d --name "${NAME}" \
  -e OPENCODE_SERVER_PASSWORD=home-tools-test \
  --mount "type=bind,src=${FIXTURE}/mise,dst=/home/opencode/.config/mise" \
  --mount "type=bind,src=${FIXTURE}/project/mise.toml,dst=/home/opencode/workspace/mise.toml,readonly" \
  "${IMAGE}" >/dev/null

if [ "$(docker inspect -f '{{.State.Running}}' "${NAME}")" != "true" ]; then
  docker logs "${NAME}" >&2 || true
  exit 1
fi

# v2's debug config connects to a server and no longer accepts --pure. Read
# configuration from the running server using each major's actual API routes.
config=""
for _ in $(seq 1 30); do
  if config="$(docker exec "${NAME}" curl -fs --connect-timeout 2 --max-time 5 -u opencode:home-tools-test "http://127.0.0.1:4096${CONFIG_PATH}")"; then
    break
  fi
  sleep 1
done
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
echo "Checking opt-in home-tool installation (${IMAGE})..."
docker run -d --name "${NAME}" \
  -e OPENCODE_SERVER_PASSWORD=home-tools-test \
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
echo "Waiting for the authenticated server health endpoint..."
for _ in $(seq 1 30); do
  health="$(docker exec "${NAME}" curl -s -u opencode:home-tools-test -o /dev/null -m 1 -w '%{http_code}' "http://127.0.0.1:4096${HEALTH_PATH}" || true)"
  if [ "${health}" = "200" ]; then
    break
  fi
  sleep 1
done
case "${health}" in
  200) ;;
  *)
    echo "opencode health check returned ${health}" >&2
    docker logs "${NAME}" >&2 || true
    exit 1
    ;;
esac

installed=0
echo "Waiting for the background Claude install (up to 90 attempts)..."
for attempt in $(seq 1 90); do
  if docker exec "${NAME}" bash -c 'for path in /opt/mise/installs/claude/*/claude; do [ -x "$path" ] && exit 0; done; exit 1'; then
    installed=1
    break
  fi
  if [ "$((attempt % 15))" = 0 ]; then
    echo "Still waiting for the home-tool installer (${attempt}/90)..."
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
