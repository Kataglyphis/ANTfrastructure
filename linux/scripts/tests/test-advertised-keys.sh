#!/usr/bin/env bash
# Tests for verify-advertised-keys.sh's gate and the smoke's advertised-vs-actual
# verdicts. Both were built to stop a version key shipping unchecked; the point of
# freezing them here is that each mutation below was PROVEN to go red once.
# See docs/cross-build-verification.md.
set -u
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${TESTS_DIR}/test-harness.sh"
SCRIPTS_DIR="$(cd "${TESTS_DIR}/.." && pwd)"
REPO="$(cd "${SCRIPTS_DIR}/../.." && pwd)"
PY="${PREFLIGHT_PYTHON:-python3}"

# A throwaway tree: the gate derives its root from its own path, so a copy is
# enough to mutate Dockerfiles without touching the real ones.
_fixture() {
  local d; d="$(mktemp -d)"
  mkdir -p "${d}/linux/scripts/06-packaging"
  cp "${SCRIPTS_DIR}/verify-advertised-keys.py" "${d}/linux/scripts/"
  cp "${SCRIPTS_DIR}/06-packaging/smoke-runtime-image.sh" "${d}/linux/scripts/06-packaging/"
  cp "${REPO}"/linux/Dockerfile.* "${d}/linux/"
  printf '%s' "${d}"
}

t_case "the gate passes on the real tree"
t_assert_ok "${PY}" "${SCRIPTS_DIR}/verify-advertised-keys.py"

t_case "a new unexcused version ENV fails the gate"
FIX="$(_fixture)"
printf '\nENV FOOBAR_VERSION=1.2.3\n' >> "${FIX}/linux/Dockerfile.package"
t_assert_fails "${PY}" "${FIX}/linux/scripts/verify-advertised-keys.py"
t_assert_contains "$("${PY}" "${FIX}/linux/scripts/verify-advertised-keys.py" 2>&1)" \
  "FOOBAR_VERSION is advertised" "an unchecked key must name itself"
rm -rf "${FIX}"

t_case "dropping a key from the smoke table fails the gate"
FIX="$(_fixture)"
sed -i 's/^GSTREAMER_VERSION VULKAN_VERSION /VULKAN_VERSION /' \
  "${FIX}/linux/scripts/06-packaging/smoke-runtime-image.sh"
t_assert_fails "${PY}" "${FIX}/linux/scripts/verify-advertised-keys.py"
rm -rf "${FIX}"

t_case "a stale excuse fails the gate"
FIX="$(_fixture)"
sed -i 's/^EXCUSED = {/EXCUSED = {\n    "GONE_VERSION": "nothing advertises this",/' \
  "${FIX}/linux/scripts/verify-advertised-keys.py"
t_assert_fails "${PY}" "${FIX}/linux/scripts/verify-advertised-keys.py"
rm -rf "${FIX}"

# --- the smoke's pure verdict function, driven with values measured in the
# --- shipped arm64 image (2026-09-01).
SMOKE="${SCRIPTS_DIR}/06-packaging/smoke-runtime-image.sh"
eval "$(sed -n '/^_advert_verdicts()/,/^}/p' "${SMOKE}")"
eval "$(sed -n '/^_ADVERTISED_VERSION_KEYS=/,/"$/p' "${SMOKE}")"
_v() { _advert_verdicts "ADV $1 $2
HAVE $1 $3" | grep -e "^[A-Z]* $1 "; }

t_case "an advertised git tag compares equal to the bare version"
t_assert_contains "$(_v ONNXRUNTIME_VERSION v1.29.0 1.29.0)" "OK ONNXRUNTIME_VERSION"
t_case "a .devN+sha trailer still compares equal"
t_assert_contains "$(_v IREE_VERSION v3.11.0 3.11.0.dev0+e4a3b04)" "OK IREE_VERSION"
t_case "the Vulkan SDK's 4th component is tolerated against the loader's 3"
t_assert_contains "$(_v VULKAN_VERSION 1.4.357.0 1.4.357)" "OK VULKAN_VERSION"

t_case "a stale runtime version is reported BAD, not tolerated"
t_assert_contains "$(_v ONNXRUNTIME_VERSION v1.29.0 1.28.0)" "BAD ONNXRUNTIME_VERSION"
t_assert_contains "$(_v OPENCV_VERSION 5.0.0 4.13.0)" "BAD OPENCV_VERSION"
t_assert_contains "$(_v IREE_VERSION v3.11.0 3.10.0.dev0+abc)" "BAD IREE_VERSION"
t_assert_contains "$(_v VULKAN_VERSION 1.4.357.0 1.3.290)" "BAD VULKAN_VERSION"

t_case "an unreadable actual value is a SKIP, never a pass"
t_assert_contains "$(_v LITERT_VERSION v2.2.0 '')" "SKIP LITERT_VERSION"

t_summary
