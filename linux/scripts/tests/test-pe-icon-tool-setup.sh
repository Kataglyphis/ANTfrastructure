#!/usr/bin/env bash
# Simulates tool setup without running apt or sudo; real package availability is not covered.
set -u
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=linux/scripts/tests/test-harness.sh
source "${TESTS_DIR}/test-harness.sh"
SUBJECT="${TESTS_DIR}/../ensure-pe-icon-test-tools.sh"
_ensure_source="$(t_fn_src "${SUBJECT}" pe_icon_ensure_test_tools)" || exit 1
_root_source="$(t_fn_src "${SUBJECT}" pe_icon_as_root)" || exit 1
_missing_source="$(t_fn_src "${SUBJECT}" pe_icon_missing_packages)" || exit 1
eval "${_ensure_source}"
eval "${_root_source}"
eval "${_missing_source}"
_work="$(mktemp -d)"
trap 'rm -rf "${_work}"' EXIT

_ready() ( pe_icon_missing_packages() { :; }; pe_icon_as_root() { echo unexpected > "${_work}/called"; return 1; }; pe_icon_ensure_test_tools --install-missing )
_missing() ( pe_icon_missing_packages() { echo llvm-22; }; pe_icon_ensure_test_tools )
_bad_option() ( pe_icon_ensure_test_tools --bad )
_cargo_missing() (
  command() { if [ "${1:-}" = -v ] && [ "${2:-}" = cargo ]; then return 1; fi; return 0; }
  pe_icon_find_tool() { return 0; }
  pe_icon_find_clang() { return 0; }
  rustc() { return 0; }
  pe_icon_missing_packages
)
_missing_linker() (
  missing="$1"
  command() { return 0; }
  pe_icon_find_tool() { [ "$1" != "$missing" ]; }
  pe_icon_find_clang() { return 0; }
  rustc() { return 0; }
  pe_icon_missing_packages
)
_install() (
  id() { echo 0; }
  pe_icon_missing_packages() { [ -f "${_work}/installed" ] || printf '%s\n' llvm-22 lld-22 cargo; }
  pe_icon_as_root() {
    printf '%s\n' "$*" >> "${_work}/commands"
    if [ "${2:-}" = install ]; then touch "${_work}/installed"; fi
  }
  pe_icon_ensure_test_tools --install-missing
)
_update_failure() (
  id() { echo 0; }
  pe_icon_missing_packages() { echo llvm-22; }
  pe_icon_as_root() { printf '%s\n' "$*" >> "${_work}/failed"; return 7; }
  pe_icon_ensure_test_tools --install-missing
)
_install_failure() (
  id() { echo 0; }
  pe_icon_missing_packages() { echo llvm-22; }
  pe_icon_as_root() { if [ "${2:-}" = install ]; then return 8; fi; return 0; }
  pe_icon_ensure_test_tools --install-missing
)
_recheck_failure() (
  id() { echo 0; }
  pe_icon_missing_packages() { echo llvm-22; }
  pe_icon_as_root() { return 0; }
  pe_icon_ensure_test_tools --install-missing
)
_no_apt() (
  pe_icon_missing_packages() { echo llvm-22; }
  command() { if [ "${1:-}" = -v ] && [ "${2:-}" = apt-get ]; then return 1; fi; builtin command "$@"; }
  pe_icon_ensure_test_tools --install-missing
)
_no_sudo() (
  pe_icon_missing_packages() { echo llvm-22; }
  id() { echo 1000; }
  command() { if [ "${1:-}" = -v ] && [ "${2:-}" = sudo ]; then return 1; fi; builtin command "$@"; }
  pe_icon_ensure_test_tools --install-missing
)
_no_pwsh() (
  command() { if [ "${1:-}" = -v ] && [ "${2:-}" = pwsh ]; then return 1; fi; builtin command "$@"; }
  pe_icon_ensure_test_tools --install-missing
)
_sudo_failure() ( id() { echo 1000; }; sudo() { return 9; }; pe_icon_as_root apt-get update )

t_case "a ready host is reused without installing anything"
t_assert_ok _ready
t_assert_fails test -e "${_work}/called"
t_case "missing tools fail without an explicit installation request"
t_assert_rc 1 _missing
t_assert_rc 2 _bad_option
t_assert_eq cargo "$(_cargo_missing)"
t_assert_eq lld-22 "$(_missing_linker ld.lld)"
t_assert_eq lld-22 "$(_missing_linker lld-link)"
t_case "the explicit installer requests only missing packages and rechecks"
t_assert_ok _install
t_assert_eq $'apt-get update\napt-get install -y --no-install-recommends llvm-22 lld-22 cargo' "$(cat "${_work}/commands")"
t_case "apt and privilege failures remain fatal even under conditional invocation"
t_assert_rc 7 _update_failure
t_assert_no_grep "${_work}/failed" 'install'
t_assert_rc 8 _install_failure
t_assert_rc 1 _recheck_failure
t_assert_rc 1 _no_apt
t_assert_rc 1 _no_sudo
t_assert_rc 1 _no_pwsh
t_assert_rc 9 _sudo_failure

t_summary
