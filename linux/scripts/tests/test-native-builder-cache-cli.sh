#!/usr/bin/env bash
# Extracted parser loops and help functions cover shared cache options and errors without reaching build or dependency commands.
set -u
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${TESTS_DIR}/test-harness.sh"
GCC_SCRIPT="${1:-${TESTS_DIR}/../02-toolchain/build-gcc.sh}"
CLANG_SCRIPT="${2:-${TESTS_DIR}/../02-toolchain/build-clang.sh}"
BOOTSTRAP="${3:-${TESTS_DIR}/../02-toolchain/bootstrap.sh}"
WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT
cat > "${WORK}/parse.sh" <<'BASH'
set -euo pipefail
bootstrap="$1" parser="$2"; shift 2
source "$bootstrap"
USE_CCACHE=0 DO_STRIP=1 KEEP_BUILD=0
warn() { printf 'WARN %s\n' "$*" >&2; }
die() { printf '%s\n' "$*" >&2; exit 1; }
usage() { printf '%s\n' usage; }
source "$parser"
printf '%s|%s|%s\n' "$USE_CCACHE" "$DO_STRIP" "$KEEP_BUILD"
BASH

for builder in gcc clang; do
  if [ "${builder}" = gcc ]; then
    file="${GCC_SCRIPT}"
    cache_line='  --compiler-cache                  Enable the compiler cache (sccache first, ccache fallback)'
    alias_line='  --ccache                          DEPRECATED alias for --compiler-cache'
  else
    file="${CLANG_SCRIPT}"
    cache_line='  --compiler-cache          Enable the compiler cache (sccache first, ccache fallback)'
    alias_line='  --ccache                  DEPRECATED alias for --compiler-cache'
  fi
  usage_source="$(t_fn_src "${file}" usage)" || exit 1
  help="$(bash -c 'source "$1"; eval "$2"; usage' _ "${BOOTSTRAP}" "${usage_source}")"
  t_case "${builder} retains both shared help descriptions with its original spacing"
  t_assert_contains "${help}" "${cache_line}"
  t_assert_contains "${help}" "${alias_line}"
  awk '/^while \[ "\$#" -gt 0 \]; do/ { printing=1 } printing { print } printing && /^done$/ { exit }' "${file}" > "${WORK}/parser.sh"
  for mode in default canonical alias combined repeated help unknown following-unknown; do
    args=(); expected='0|1|0'; expected_rc=0; expected_err=''
    case "${mode}" in
      canonical) args=(--compiler-cache); expected='1|1|0' ;;
      alias) args=(--ccache); expected='1|1|0' ;;
      combined) args=(--no-strip --keep-build --compiler-cache); expected='1|0|1' ;;
      repeated) args=(--compiler-cache --ccache); expected='1|1|0' ;;
      help) args=(--ccache --help); expected=usage ;;
      unknown) args=(--unknown); expected=''; expected_rc=1; expected_err=$'WARN Unknown option: --unknown\nusage' ;;
      following-unknown) args=(--compiler-cache value); expected=''; expected_rc=1; expected_err=$'WARN Unknown option: value\nusage' ;;
    esac
    t_case "${builder} parser ${mode}"
    rc=0
    out="$(timeout 5 bash "${WORK}/parse.sh" "${BOOTSTRAP}" "${WORK}/parser.sh" "${args[@]}" 2> "${WORK}/err")" || rc=$?
    t_assert_eq "${expected_rc}" "${rc}"
    t_assert_eq "${expected}" "${out}"
    t_assert_eq "${expected_err}" "$(cat "${WORK}/err")"
  done
done
t_summary
