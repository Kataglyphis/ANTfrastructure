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
  cp "${SCRIPTS_DIR}/verify_advertised_keys.py" "${d}/linux/scripts/"
  cp "${SCRIPTS_DIR}/06-packaging/smoke-runtime-image.sh" "${d}/linux/scripts/06-packaging/"
  cp "${REPO}"/linux/Dockerfile.* "${d}/linux/"
  printf '%s' "${d}"
}

# Run the gate in a fixture and require it to fail naming a specific thing. The
# cases below differ only in their mutation; the running lives here.
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

# --- the smoke's pure verdict function, driven with values measured in the
# --- shipped arm64 image (2026-09-01).
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
# The rust defect's exact shape: `rustc --version` failed on arm64 for months and
# this arm said SKIP, so the gate reported 16/16 while the toolchain was unusable.
t_assert_contains "$(_v LITERT_VERSION v2.2.0 '')" "UNREAD LITERT_VERSION"

t_case "a key the image does not advertise is FATAL, never a SKIP"
# The other arm: PYTHON_VERSION is ARG-only, so its row could only ever SKIP -- the
# same shape verify_advertised_keys.py emptied FROZEN_UNPROBED to abolish.
t_assert_contains "$(_v LITERT_VERSION '' 2.2.0)" "UNSET LITERT_VERSION"

t_case "no verdict verb is a SKIP any more"
t_assert_eq "" "$(_v LITERT_VERSION '' '' | grep -o SKIP)" "both non-answers must be fatal"

t_case "PYTHON_VERSION no longer sits in a row that cannot fail"
t_assert_eq "" "$(printf '%s' "${_ADVERTISED_VERSION_KEYS}" | grep -owe PYTHON_VERSION)" \
  "ARG-only by design, so it is EXCUSED in the gate instead of SKIPping forever"

t_case "a table row with no ADV probe fails the gate"
# A row only says the smoke INTENDS to check the key; the value comes from an
# `ADV <KEY>` line the in-image probe prints. 10 of the 16 rows had no such line
# and could only ever SKIP, and neither guard could see it. Backlog WC/WD.
FIX="$(_fixture)"
sed -i 's/^_ADVERTISED_VERSION_KEYS="/_ADVERTISED_VERSION_KEYS="BRANDNEW_VERSION /' \
  "${FIX}/linux/scripts/06-packaging/smoke-runtime-image.sh"
_gate_must_fail "${FIX}" "prints no \`ADV BRANDNEW_VERSION\`" \
  "the gate must name the probe it wants"
rm -rf "${FIX}"

t_case "the frozen-unprobed baseline cannot rot"
# Adding the missing probe is the FIX, so the baseline must then shrink. If it
# does not, the next unprobed row hides behind a stale entry. The fixture seeds
# the entry itself: the live baseline is empty since all ten were probed, and a
# case that depends on it would quietly stop testing anything.
FIX="$(_fixture)"
sed -i 's/^FROZEN_UNPROBED = set()$/FROZEN_UNPROBED = {"UBUNTU_VERSION"}/' \
  "${FIX}/linux/scripts/verify_advertised_keys.py"
_gate_must_fail "${FIX}" "now HAS a probe" \
  "a key with a probe must be removed from the baseline"
rm -rf "${FIX}"

t_summary
