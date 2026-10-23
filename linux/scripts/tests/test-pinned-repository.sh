#!/usr/bin/env bash
# Pinned clone fixtures exercise no remote repository, SDK build or package installation.
set -uo pipefail
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${TESTS_DIR}/test-harness.sh"
source "${TESTS_DIR}/../01-core/downloads.sh"
w="$(mktemp -d)"
trap 'rm -rf "${w}"' EXIT
pin=1111111111111111111111111111111111111111
calls="${w}/calls"
git() {
  printf '<%s>' "$@" >> "${calls}"
  printf '\n' >> "${calls}"
  case "$1" in
    clone)
      [ "${CLONE_FAIL:-0}" != 1 ] || return 5
      if [ "${3:-}" = --filter=blob:none ] && [ "${FILTER_FAIL:-0}" = 1 ]; then return 4; fi
      mkdir -p "${!#}/include"
      printf fixture > "${!#}/include/header.h"
      ;;
    -C)
      case "$3" in
        checkout) return "${CHECKOUT_RC:-0}" ;;
        rev-parse) printf '%s\n' "${ACTUAL_PIN:-${pin}}"; return "${HEAD_RC:-0}" ;;
        submodule) return 0 ;;
      esac
      ;;
  esac
}

PINNED_GIT_STUB="$(declare -f git)"
export PINNED_GIT_STUB
export calls pin
export ACTUAL_PIN="${pin}" CLONE_FAIL=0 CHECKOUT_RC=0 HEAD_RC=0 FILTER_FAIL=0

clone_fixture() { clone_pinned_repository https://example.invalid/repo "${w}/repo with spaces" "${pin}"; }
t_case "a filtered clone checks out and verifies the exact commit, preserving path arguments"
: > "${calls}"
t_assert_ok clone_fixture
t_assert_contains "$(cat "${calls}")" "<--no-checkout><https://example.invalid/repo><${w}/repo with spaces>"
t_assert_eq 1 "$(grep -c '<clone>' "${calls}")"
t_assert_contains "$(cat "${calls}")" "<checkout><--quiet><${pin}>"
t_assert_contains "$(cat "${calls}")" '<rev-parse><HEAD>'

t_case "servers rejecting filters retain the unfiltered no-checkout fallback"
: > "${calls}"
FILTER_FAIL=1 t_assert_ok clone_fixture
t_assert_eq 2 "$(grep -c '<clone>' "${calls}")"
t_assert_contains "$(cat "${calls}")" '<clone><--quiet><--no-checkout>'

t_case "clone, checkout and HEAD failures propagate even in conditional calls"
for mode in CLONE_FAIL=1 CHECKOUT_RC=7 HEAD_RC=8 ACTUAL_PIN=wrong; do
  : > "${calls}"
  t_assert_fails env "${mode}" PINNED_TEST_ROOT="${TESTS_DIR}/.." PINNED_TEST_WORK="${w}" PINNED_TEST_COMMIT="${pin}" \
    bash -c 'source "$PINNED_TEST_ROOT/01-core/downloads.sh"; eval "$PINNED_GIT_STUB"; if clone_pinned_repository https://example.invalid/repo "$PINNED_TEST_WORK/repo" "$PINNED_TEST_COMMIT"; then exit 0; else exit 1; fi'
done

BUILD="${TESTS_DIR}/../03-media/build/hailo/build-hailort.sh"
PINNED_SOURCE_FUNCTIONS="$(t_fn_src "${BUILD}" stage_remaining_externals)"$'\n'"$(t_fn_src "${BUILD}" fetch_tappas)"
export PINNED_SOURCE_FUNCTIONS
run_staging_fixture() {
  env PINNED_TEST_ROOT="${TESTS_DIR}/.." PINNED_TEST_WORK="${w}" PINNED_STAGE_MODE="$1" \
    bash -c 'source "$PINNED_TEST_ROOT/01-core/downloads.sh"
      eval "$PINNED_GIT_STUB"
      eval "$PINNED_SOURCE_FUNCTIONS"
      info() { :; }
      case "$PINNED_STAGE_MODE" in
        hailort)
          HAILORT_SRC="$PINNED_TEST_WORK/hailort"
          HAILO_EXTERNALS=("dep|https://example.invalid/repo|$pin")
          stage_remaining_externals ;;
        tappas)
          WORK="$PINNED_TEST_WORK/work"
          TAPPAS_VERSION=fixture
          TAPPAS_EXTERNALS=("dep|https://example.invalid/repo|$pin|headers|include|header.h")
          fetch_tappas ;;
      esac'
}
t_case "Hailo external staging retains recursive submodules and its existing-tree skip"
: > "${calls}"
t_assert_ok run_staging_fixture hailort
t_assert_contains "$(cat "${calls}")" "<-C><${w}/hailort/hailort/external/dep-src><submodule><update><--init><--recursive><--quiet>"
: > "${calls}"
t_assert_ok run_staging_fixture hailort
t_assert_eq '' "$(cat "${calls}")"

t_case "TAPPAS stages only the selected subdirectory and does not initialize submodules"
mkdir -p "${w}/work/tappas-fixture/core/hailo"
: > "${w}/work/tappas-fixture/core/hailo/meson.build"
: > "${calls}"
t_assert_ok run_staging_fixture tappas
t_assert_eq fixture "$(cat "${w}/work/tappas-fixture/core/open_source/headers/header.h")"
t_assert_eq 0 "$(grep -c '<submodule>' "${calls}")"
: > "${calls}"
t_assert_ok run_staging_fixture tappas
t_assert_eq '' "$(cat "${calls}")"

t_case "a real local repository lands the requested commit without remote access"
clone_local_commit() (
  unset -f git
  local origin="${w}/local source" destination="${w}/local clone" commit
  mkdir -p "${origin}"
  git -C "${origin}" init -q
  printf 'local fixture\n' > "${origin}/input"
  git -C "${origin}" add input
  git -C "${origin}" -c user.name=Fixture -c user.email=fixture@example.invalid commit -qm fixture
  commit="$(git -C "${origin}" rev-parse HEAD)"
  clone_pinned_repository "${origin}" "${destination}" "${commit}" || return 1
  if [ "$(git -C "${destination}" rev-parse HEAD)" = "${commit}" ]; then return 0; fi
  return 1
)
t_assert_ok clone_local_commit

t_summary
