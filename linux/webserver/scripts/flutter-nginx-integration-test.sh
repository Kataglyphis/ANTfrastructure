#!/usr/bin/env bash
# flutter-nginx-integration-test.sh <build-dir> [--port N] [--image REF]: the smoke test against a Flutter web build behind the shared nginx config. See linux/webserver/README.md#reusable-flutter-web-helpers
set -euo pipefail

_HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../../scripts/01-core/http-readiness.sh
source "${_HERE}/../../scripts/01-core/http-readiness.sh"

usage() {
  printf 'usage: %s <build-dir> [--port N] [--image REF]\n' "$0"
  printf 'ENGINE picks docker or nerdctl (default: nerdctl if installed); the smoke test reads REQUIRED_CSP_HOSTS and CHECK_LOADING_SHELL.\n'
}

BUILD_DIR=""
PORT=8080
IMAGE="nginx:alpine"
while [ $# -gt 0 ]; do
  case "$1" in
    --port) PORT="${2:?--port needs a number}"; shift 2 ;;
    --image) IMAGE="${2:?--image needs an image reference}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    -*) printf 'flutter-nginx-integration-test.sh: unknown option %s\n' "$1" >&2; usage >&2; exit 2 ;;
    *) BUILD_DIR="$1"; shift ;;
  esac
done

if [ -z "${BUILD_DIR}" ] || [ ! -f "${BUILD_DIR}/index.html" ]; then
  printf 'flutter-nginx-integration-test.sh: no Flutter web build at "%s" (index.html missing); build it first.\n' "${BUILD_DIR}" >&2
  exit 2
fi
BUILD_DIR="$(cd "${BUILD_DIR}" && pwd)"
# Not the default.conf nginx ships: that one has none of the headers, CSP or rewrites under test, and would pass vacuously.
NGINX_CONF="${_HERE}/../templates/flutter-nginx-local.conf"
SMOKE_TEST="${FLUTTER_SMOKE_TEST:-${_HERE}/flutter_integration_smoke_test.sh}"

ENGINE="${ENGINE:-$(command -v nerdctl >/dev/null 2>&1 && echo nerdctl || echo docker)}"
command -v "${ENGINE}" >/dev/null 2>&1 || { printf 'flutter-nginx-integration-test.sh: %s is not on PATH (set ENGINE).\n' "${ENGINE}" >&2; exit 2; }

# Git Bash hands the engine MSYS paths it cannot mount; C:/... is the form both engines take there.
_host_path() { cygpath -m "$1" 2>/dev/null || printf '%s' "$1"; }

CONTAINER=""
stop_nginx() {
  if [ -n "${CONTAINER}" ]; then
    # Not silenced: this message explains a container you later find still running.
    "${ENGINE}" rm -f "${CONTAINER}" >/dev/null || printf 'Warning: could not remove container %s\n' "${CONTAINER}" >&2
    CONTAINER=""
  fi
}
trap stop_nginx EXIT

echo "=== Starting nginx (${ENGINE}, port ${PORT}) ==="
# No --rm: nerdctl refuses it beside -d; the trap's rm -f stops and removes the container instead.
if ! CONTAINER="$(MSYS_NO_PATHCONV=1 "${ENGINE}" run -d -p "${PORT}:8080" \
  --mount "type=bind,source=$(_host_path "${BUILD_DIR}"),target=/usr/share/nginx/html,readonly" \
  --mount "type=bind,source=$(_host_path "${NGINX_CONF}"),target=/etc/nginx/conf.d/default.conf,readonly" \
  "${IMAGE}")"; then
  printf 'Error: could not start the nginx container (engine error above).\n' >&2
  exit 1
fi

BASE_URL="http://localhost:${PORT}"
if ! wait_for_http "${BASE_URL}/" "nginx (container ${CONTAINER})" "${NGINX_READY_ATTEMPTS:-50}"; then
  # Unreadable logs are part of the diagnosis, so they are reported, not swallowed.
  "${ENGINE}" logs "${CONTAINER}" >&2 || printf '(could not read the container logs either)\n' >&2
  exit 1
fi

# `|| RESULT=$?`: under set -e a bare call would abort before the teardown; the status is re-raised below.
RESULT=0
bash "${SMOKE_TEST}" "${BASE_URL}" || RESULT=$?
stop_nginx
if [ "${RESULT}" -eq 0 ]; then
  echo "Integration tests passed"
else
  echo "Integration tests failed" >&2
fi
exit "${RESULT}"
