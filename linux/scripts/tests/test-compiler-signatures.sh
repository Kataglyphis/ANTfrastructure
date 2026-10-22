#!/usr/bin/env bash
# Signature matching and sample bounds use recorded readelf text; real compiler binaries are outside this suite.
set -u
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${TESTS_DIR}/test-harness.sh"
eval "$(t_fn_src "${TESTS_DIR}/../06-packaging/validate-compilers.sh" _smoke_compiler_signatures)"
WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT
mkdir -p "${WORK}/GCC libs/nested" "${WORK}/Clang libs/nested" "${WORK}/bounded"
readelf() { cat "$3"; }
printf 'GCC: (GNU) 16.2.0\n' > "${WORK}/GCC libs/lib with spaces.so.1"
printf 'clang version 23.1.0\n' > "${WORK}/Clang libs/nested/libclang.a"
t_case "GCC signature matching preserves paths with spaces"
t_assert_eq "SMOKE OK: ${WORK}/GCC libs/lib with spaces.so.1 compiled with GCC 16.2.0" "$(_smoke_compiler_signatures GCC 16.2.0 "${WORK}/GCC libs")"
t_case "a different GCC version produces only an advisory note"
t_assert_eq 'SMOKE NOTE: no GCC 15.0 .comment signature found in sampled libs (may be clang-built or stripped)' "$(_smoke_compiler_signatures GCC 15.0 "${WORK}/GCC libs")"
t_case "Clang's sample includes nested static archives"
t_assert_eq "SMOKE OK: ${WORK}/Clang libs/nested/libclang.a compiled with Clang 23.1.0" "$(_smoke_compiler_signatures Clang 23.1.0 "${WORK}/Clang libs")"
t_case "GCC's sample excludes nested archives"
t_assert_contains "$(_smoke_compiler_signatures GCC 16.2.0 "${WORK}/Clang libs")" 'SMOKE NOTE:'
t_case "missing directories remain advisory"
t_assert_contains "$(_smoke_compiler_signatures Clang 23.1.0 "${WORK}/missing")" 'SMOKE NOTE:'
for number in 01 02 03 04 05 06 07 08 09 10 11; do
  printf 'no signature\n' > "${WORK}/bounded/lib${number}.so"
done
printf 'GCC: (GNU) 16.2.0\nclang version 23.1.0\n' > "${WORK}/bounded/lib11.so"
find() { command find "$@" | LC_ALL=C sort; }
t_case "GCC stops at five libraries per directory"
t_assert_contains "$(_smoke_compiler_signatures GCC 16.2.0 "${WORK}/bounded")" 'SMOKE NOTE:'
t_case "Clang stops at ten libraries per directory"
t_assert_contains "$(_smoke_compiler_signatures Clang 23.1.0 "${WORK}/bounded")" 'SMOKE NOTE:'
printf 'GCC: (GNU) 16.2.0\nclang version 23.1.0\n' > "${WORK}/bounded/lib05.so"
t_case "a signature inside each sample bound is observed"
t_assert_contains "$(_smoke_compiler_signatures GCC 16.2.0 "${WORK}/bounded")" 'SMOKE OK:'
t_assert_contains "$(_smoke_compiler_signatures Clang 23.1.0 "${WORK}/bounded")" 'SMOKE OK:'
t_summary
