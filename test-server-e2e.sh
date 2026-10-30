#!/usr/bin/env bash
# Exercise the real, major-specific entrypoint. Usage: bash test-server-e2e.sh <image>
set -euo pipefail

IMAGE="${1:?usage: test-server-e2e.sh <image>}"
NAME="opencode-server-e2e-$$"
PORT=4186
VERSION="$(docker image inspect -f '{{index .Config.Labels "org.opencontainers.image.version"}}' "$IMAGE")"
case "$VERSION" in
  1.*) ENDPOINT=/global/health; USERNAME=custom-user; PASSWORD=legacy-password; ENTRYPOINT=entrypoint-v1.sh ;;
  2.*) ENDPOINT=/api/info; USERNAME=opencode; PASSWORD=native-password; ENTRYPOINT=entrypoint.sh ;;
  *) echo "unsupported image version: $VERSION" >&2; exit 1 ;;
esac

cleanup() { docker rm -f "$NAME" >/dev/null 2>&1 || true; }
trap cleanup EXIT
fail() { echo "FAIL: $*" >&2; docker logs "$NAME" >&2 || true; exit 1; }

start() {
  docker run -d --name "$NAME" "$@" "$IMAGE" >/dev/null
  # Use the container's network address to verify --hostname 0.0.0.0, with no
  # host port allocation that could collide with another test or development server.
  ADDRESS="$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "$NAME")"
  URL="http://${ADDRESS}:${PORT}${ENDPOINT}"
}

status() { docker exec "$NAME" curl --noproxy '*' -s -m 2 -o /dev/null -w '%{http_code}' "$@" "$URL"; }
wait_ready() {
  local code
  for _ in $(seq 1 30); do
    code="$(status -u "${USERNAME}:${PASSWORD}" || true)"
    [ "$code" = 200 ] && return
    [ "$(docker inspect -f '{{.State.Running}}' "$NAME")" = true ] || fail "server exited during startup"
    sleep 1
  done
  fail "server did not become ready (HTTP $code)"
}

# Supplying both password names proves v2's native-name precedence and v1's
# legacy-name handling. Uppercase DEBUG is accepted by both image entrypoints.
start -e OPENCODE_PORT="$PORT" -e OPENCODE_PASSWORD=native-password \
  -e OPENCODE_SERVER_PASSWORD=legacy-password -e OPENCODE_PRINT_LOGS=true \
  -e OPENCODE_SERVER_USERNAME=custom-user \
  -e OPENCODE_LOG_LEVEL=DEBUG -e OPENCODE_CORS_ORIGIN=https://entrypoint.example
wait_ready
docker exec "$NAME" cmp /usr/local/bin/entrypoint.sh "/usr/local/lib/opencode/${ENTRYPOINT}"
[ "$(status)" = 401 ] || fail "unauthenticated API request was accepted"
[ "$(status -u "${USERNAME}:wrong-password")" = 401 ] || fail "incorrect password was accepted"
[ "$(status -u "wrong-user:${PASSWORD}")" = 401 ] || fail "incorrect username was accepted"
body="$(docker exec "$NAME" curl --noproxy '*' -fsS -u "${USERNAME}:${PASSWORD}" "$URL")"
[ "$(printf '%s' "$body" | jq -r .version)" = "$VERSION" ] || fail "API did not report the expected version"
headers="$(docker exec "$NAME" curl --noproxy '*' -sSI -X OPTIONS \
  -H 'Origin: https://entrypoint.example' -H 'Access-Control-Request-Method: GET' "$URL")"
[[ "$headers" == *"https://entrypoint.example"* ]] || fail "configured CORS origin was not allowed"
logs="$(docker logs "$NAME" 2>&1)"
[[ "$logs" == *"level="* ]] || fail "structured logs were not printed"
echo "PASS: v${VERSION%%.*} entrypoint selection, custom port/CORS, logging, password precedence, API auth"

if [[ "$VERSION" == 2.* ]]; then
  [ "$(status -u opencode:legacy-password)" = 401 ] || fail "legacy password overrode OPENCODE_PASSWORD"
  config="$(docker exec "$NAME" curl --noproxy '*' -fsS -u "opencode:${PASSWORD}" \
    "http://${ADDRESS}:${PORT}/api/config?directory=/home/opencode/workspace")"
  [[ "$config" == *"/etc/opencode/mise-instructions.md"* ]] || fail "managed instructions were not loaded"
  cleanup

  PASSWORD=legacy-password
  start -e OPENCODE_PORT="$PORT" -e OPENCODE_SERVER_PASSWORD="$PASSWORD"
  wait_ready
  [ "$(status)" = 401 ] || fail "legacy password did not protect the v2 API"
  echo "PASS: v2 OPENCODE_SERVER_PASSWORD fallback"
  cleanup

  start -e OPENCODE_PORT="$PORT"
  PASSWORD=""
  for _ in $(seq 1 30); do
    logs="$(docker logs "$NAME" 2>&1)"
    if [[ "$logs" == *"server password "* ]]; then
      PASSWORD="${logs##*server password }"
      PASSWORD="${PASSWORD%%$'\n'*}"
      break
    fi
    sleep 1
  done
  [ -n "$PASSWORD" ] || fail "v2 did not generate a server password"
  wait_ready
  [ "$(status)" = 401 ] || fail "generated password did not protect the v2 API"
  echo "PASS: v2 generated-password authentication"
fi

docker stop -t 10 "$NAME" >/dev/null
[ "$(docker inspect -f '{{.State.ExitCode}}' "$NAME")" != 137 ] || fail "server required SIGKILL to stop"
echo "PASS: graceful server shutdown ($IMAGE)"
