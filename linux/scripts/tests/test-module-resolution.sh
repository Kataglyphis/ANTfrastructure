#!/usr/bin/env bash
# Tests for 01-core/modules.sh source_module resolution order (2026-08-30).
#
# WHY THIS SUITE EXISTS
# ---------------------
# The old candidate list started with ${caller_dir}/${name}. Sourcing
# 03-media/build/onnxruntime/build/lib/common.sh bare (SCRIPT_DIR unset) made
# source_module "common.sh" resolve to THAT SAME FILE — an infinite re-source
# loop (media_common_init → common.sh → media_common_init …) that ended in a
# stack-overflow SIGSEGV. Framework dirs now come first; the caller-local slot
# is a last resort. These tests pin the resolution order so a future
# "convenience" reordering cannot resurrect the recursion.
set -u
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${TESTS_DIR}/test-harness.sh"
MODULES="${TESTS_DIR}/../01-core/modules.sh"

_TM_ROOT="${TMPDIR:-/tmp}/modres-test.$$"
rm -rf "${_TM_ROOT}"
mkdir -p "${_TM_ROOT}/scripts/01-core" "${_TM_ROOT}/caller/lib"
trap 'rm -rf "${_TM_ROOT}"' EXIT

# The 01-core module under test (marker set on load).
printf 'MODRES_LOADED=from-core\n' > "${_TM_ROOT}/scripts/01-core/armnn-support.sh"
# Poison: same name inside caller_dir — the pre-fix resolution hit THIS first.
printf 'MODRES_LOADED=from-caller-poison\n' > "${_TM_ROOT}/caller/armnn-support.sh"
# The recursion shape: a caller-local common.sh (ORT lib/common.sh analogue).
printf 'MODRES_POISON_SOURCED=yes\n' > "${_TM_ROOT}/caller/lib/common.sh"
printf 'MODRES_LOADED=from-core\n' > "${_TM_ROOT}/scripts/01-core/common.sh"

case_01core_preferred() {
  MODRES_LOADED=""
  export SCRIPT_DIR="${_TM_ROOT}/caller"
  export SCRIPTS_ROOT="${_TM_ROOT}/scripts"
  # shellcheck disable=SC1090
  source "${MODULES}"
  source_module armnn-support.sh
  t_assert_eq "from-core" "${MODRES_LOADED:-EMPTY}"
}

case_recursion_shape() {
  # Nested shell: caller_dir holds a common.sh (poison); 01-core exists. The
  # module must resolve to 01-core and never reach the caller-local file.
  _out="$(timeout 5 bash -c '
    source "$1" 2>/dev/null || exit 99
    export SCRIPT_DIR="$2"
    export SCRIPTS_ROOT="$3"
    if source_module common.sh 2>/dev/null; then
      printf "core=%s poison=%s" "${MODRES_LOADED:-none}" "${MODRES_POISON_SOURCED:-no}"
    else
      printf "src-fail"
    fi
  ' _ "${MODULES}" "${_TM_ROOT}/caller/lib" "${_TM_ROOT}/scripts" 2>/dev/null || printf 'TIMEOUT')"
  t_assert_eq "core=from-core poison=no" "${_OUT:-${_out}}"
}

case_script_root_exists_shadows_caller() {
  MODRES_LOADED=""
  export SCRIPT_DIR="${_TM_ROOT}/caller"
  export SCRIPTS_ROOT="${_TM_ROOT}/scripts"
  # shellcheck disable=SC1090
  source "${MODULES}"
  source_module armnn-support.sh
  t_assert_eq "from-core" "${MODRES_LOADED}"
}

case_caller_local_last_resort() {
  MODRES_LOADED=""
  export SCRIPT_DIR="${_TM_ROOT}/caller"
  # shellcheck disable=SC1090
  source "${MODULES}"
  unset SCRIPTS_ROOT 2>/dev/null || true
  printf 'MODRES_LOADED=from-caller-only\n' > "${_TM_ROOT}/caller/caller-only.sh"
  source_module caller-only.sh
  t_assert_eq "from-caller-only" "${MODRES_LOADED}"
}

case_modres_double_source() {
  t_assert_ok bash -c "source '${MODULES}'; source '${MODULES}'"
}

t_case "source_module prefers the 01-core module over a caller-local shadow"; case_01core_preferred
t_case "the ORT recursion shape: caller-local common.sh must NOT be re-sourced"; case_recursion_shape
t_case "SCRIPTS_ROOT/01-core exists → caller_dir slot NEVER reached for a shadowed name"; case_script_root_exists_shadows_caller
t_case "no framework dirs → caller-local last resort still resolves"; case_caller_local_last_resort
t_case "modules.sh double-source is safe"; case_modres_double_source

t_summary
