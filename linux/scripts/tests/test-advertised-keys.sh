#!/usr/bin/env bash
# Tests for the advertised-keys gate and the smoke's verdicts. See docs/cross-build-verification.md#advertised-version-keys-advert-keys
set -u
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${TESTS_DIR}/test-harness.sh"
SCRIPTS_DIR="$(cd "${TESTS_DIR}/.." && pwd)"
REPO="$(cd "${SCRIPTS_DIR}/../.." && pwd)"
PY="${PREFLIGHT_PYTHON:-python3}"

# The gate finds its root from its own path, so a copied tree can mutate Dockerfiles safely.
_fixture() {
  local d; d="$(mktemp -d)"
  mkdir -p "${d}/linux/scripts/06-packaging"
  cp "${SCRIPTS_DIR}/verify_advertised_keys.py" "${d}/linux/scripts/"
  cp "${SCRIPTS_DIR}/06-packaging/smoke-runtime-image.sh" "${d}/linux/scripts/06-packaging/"
  cp "${REPO}"/linux/Dockerfile.* "${d}/linux/"
  printf '%s' "${d}"
}

# Run the gate in a fixture and require it to fail naming <want>.
_gate_must_fail() {
  local fix="$1" want="$2" why="$3"
  t_assert_fails "${PY}" "${fix}/linux/scripts/verify_advertised_keys.py"
  t_assert_contains "$("${PY}" "${fix}/linux/scripts/verify_advertised_keys.py" 2>&1)" \
    "${want}" "${why}"
}

t_case "the gate passes on the real tree"
t_assert_ok "${PY}" "${SCRIPTS_DIR}/verify_advertised_keys.py"

t_case "a new unexcused version ENV fails the gate"
FIX="$(_fixture)"
printf '\nENV FOOBAR_VERSION=1.2.3\n' >> "${FIX}/linux/Dockerfile.package"
t_assert_fails "${PY}" "${FIX}/linux/scripts/verify_advertised_keys.py"
t_assert_contains "$("${PY}" "${FIX}/linux/scripts/verify_advertised_keys.py" 2>&1)" \
  "FOOBAR_VERSION is advertised" "an unchecked key must name itself"
rm -rf "${FIX}"

t_case "dropping a key from the smoke table fails the gate"
FIX="$(_fixture)"
sed -i 's/^GSTREAMER_VERSION VULKAN_VERSION /VULKAN_VERSION /' \
  "${FIX}/linux/scripts/06-packaging/smoke-runtime-image.sh"
t_assert_fails "${PY}" "${FIX}/linux/scripts/verify_advertised_keys.py"
rm -rf "${FIX}"

t_case "a stale excuse fails the gate"
FIX="$(_fixture)"
sed -i 's/^EXCUSED = {/EXCUSED = {\n    "GONE_VERSION": "nothing advertises this",/' \
  "${FIX}/linux/scripts/verify_advertised_keys.py"
t_assert_fails "${PY}" "${FIX}/linux/scripts/verify_advertised_keys.py"
rm -rf "${FIX}"

# The smoke's pure verdict function, with values measured in the shipped arm64 image
SMOKE="${SCRIPTS_DIR}/06-packaging/smoke-runtime-image.sh"
eval "$(sed -n '/^_advert_verdicts()/,/^}/p' "${SMOKE}")"
eval "$(sed -n '/^_ADVERTISED_VERSION_KEYS=/,/"$/p' "${SMOKE}")"
_v() { _advert_verdicts "ADV $1 $2
HAVE $1 $3" | grep -e "^[A-Z]* $1"; }

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

t_case "an unreadable actual value is FATAL, never a SKIP"
# A failing `rustc --version` once read SKIP while the toolchain was unusable.
t_assert_contains "$(_v LITERT_VERSION v2.2.0 '')" "UNREAD LITERT_VERSION"

t_case "a key the image does not advertise is FATAL, never a SKIP"
# An ARG-only key such as PYTHON_VERSION could otherwise only ever SKIP.
t_assert_contains "$(_v LITERT_VERSION '' 2.2.0)" "UNSET LITERT_VERSION"

t_case "no verdict verb is a SKIP any more"
t_assert_eq "" "$(_v LITERT_VERSION '' '' | grep -o SKIP)" "both non-answers must be fatal"

t_case "PYTHON_VERSION no longer sits in a row that cannot fail"
t_assert_eq "" "$(printf '%s' "${_ADVERTISED_VERSION_KEYS}" | grep -owe PYTHON_VERSION)" \
  "ARG-only by design, so it is EXCUSED in the gate instead of SKIPping forever"

t_case "a table row with no ADV probe fails the gate"
# A row only states intent; the value comes from the in-image probe's `ADV <KEY>` line.
FIX="$(_fixture)"
sed -i 's/^_ADVERTISED_VERSION_KEYS="/_ADVERTISED_VERSION_KEYS="BRANDNEW_VERSION /' \
  "${FIX}/linux/scripts/06-packaging/smoke-runtime-image.sh"
_gate_must_fail "${FIX}" "prints no \`ADV BRANDNEW_VERSION\`" \
  "the gate must name the probe it wants"
rm -rf "${FIX}"

t_case "the frozen-unprobed baseline cannot rot"
# A stale entry would hide the next unprobed row; seeded here, since the live baseline is empty.
FIX="$(_fixture)"
sed -i 's/^FROZEN_UNPROBED = set()$/FROZEN_UNPROBED = {"UBUNTU_VERSION"}/' \
  "${FIX}/linux/scripts/verify_advertised_keys.py"
_gate_must_fail "${FIX}" "now HAS a probe" \
  "a key with a probe must be removed from the baseline"
rm -rf "${FIX}"

t_summary
