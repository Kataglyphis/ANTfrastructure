#!/usr/bin/env bash
# append_optional_available_packages: present names are added, absent ones stay silent; the strict variant still warns (CON155).
set -u
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${TESTS_DIR}/test-harness.sh"
LISTS="$(cd "${TESTS_DIR}/.." && pwd)/01-core/package-lists.sh"

# Stand-ins for the apt helpers: only the names in PRESENT exist.
apt_package_exists() { case " ${PRESENT} " in *" $1 "*) return 0 ;; *) return 1 ;; esac; }
append_unique_packages() { local -n _a="$1"; _a+=("$2"); }
warn() { echo "WARN $*"; }
source "${LISTS}"

# Output goes to a file: a command substitution would run the append in a subshell and lose the array.
_OUT="$(mktemp)"
trap 'rm -f "${_OUT}"' EXIT

t_case "absent LLVM majors add nothing and log nothing"
PRESENT="clang-22 lld-22"
out_arr=(); append_optional_available_packages out_arr clang-23 lld-23 clang-22 lld-22 >"${_OUT}" 2>&1
t_assert_eq "" "$(cat "${_OUT}")"
t_assert_eq "clang-22 lld-22" "${out_arr[*]}"

t_case "the strict variant still reports what it drops"
PRESENT="clang-22"
out_arr=(); append_available_packages out_arr clang-23 clang-22 >"${_OUT}" 2>&1
t_assert_contains "$(cat "${_OUT}")" "requested-but-absent packages dropped: clang-23"
t_assert_eq "clang-22" "${out_arr[*]}"

t_summary
