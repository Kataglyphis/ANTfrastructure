#!/usr/bin/env bash
# The entrypoint's CPU baseline check on loader texts and fake loaders; no CPU below x86-64-v3 is exercised. docs/amd64-x86-64-v3-baseline.md#the-gates
set -u
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${TESTS_DIR}/test-harness.sh"
ENTRY="${TESTS_DIR}/../04-runtime/entrypoint.sh"

_verdict_fn="$(t_fn_src "${ENTRY}" _ep_cpu_baseline_verdict)" || exit 1
_check_fn="$(t_fn_src "${ENTRY}" _ep_cpu_baseline_check)" || exit 1
eval "${_verdict_fn}"

# glibc's own wording, read off :latest amd64 on 2026-11-12.
_HEAD='Subdirectories of glibc-hwcaps directories, in priority order:'
_SUPPORTED="${_HEAD}
  x86-64-v4
  x86-64-v3 (supported, searched)
  x86-64-v2 (supported, searched)"
_BELOW="${_HEAD}
  x86-64-v4
  x86-64-v3
  x86-64-v2 (supported, searched)"

t_case "the loader's wording decides: supported, listed but not supported, or not listed"
t_assert_eq "ok" "$(_ep_cpu_baseline_verdict "${_SUPPORTED}")"
t_assert_eq "below" "$(_ep_cpu_baseline_verdict "${_BELOW}")" "a v2 CPU: the level is listed without the marker"
t_assert_eq "unknown" "$(_ep_cpu_baseline_verdict "")" "a loader that printed nothing"
t_assert_eq "unknown" "$(_ep_cpu_baseline_verdict "${_HEAD}
  (no subdirectories)")" "another architecture's loader names no x86 level"

_work="$(t_mktemp -d)"
_loader() {  # <name> <text>: a loader that answers --help with that text
  printf '#!/bin/sh\ncat <<"T"\n%s\nT\n' "$2" > "${_work}/$1"
  chmod +x "${_work}/$1"
}
_check() { bash -c 'set -euo pipefail; eval "$1"; eval "$2"; _ep_cpu_baseline_check "$3"' _ "${_verdict_fn}" "${_check_fn}" "$1"; }
_loader supported "${_SUPPORTED}"
_loader below "${_BELOW}"
_loader silent ""
printf '#!/bin/sh\nexit 127\n' > "${_work}/broken"; chmod +x "${_work}/broken"
printf 'not executable\n' > "${_work}/plain"

t_case "a CPU at the baseline starts without a word"
t_assert_ok _check "${_work}/supported"
t_assert_eq "" "$(t_out _check "${_work}/supported")"

t_case "a CPU below it is refused, with the cause"
t_assert_fails _check "${_work}/below"
t_assert_contains "$(t_out _check "${_work}/below")" "built for x86-64-v3 (AVX2, FMA, BMI2) and this CPU does not provide it"

t_case "no verdict never blocks the image: no loader, a silent one, a failing one"
t_assert_ok _check "${_work}/absent"
t_assert_ok _check "${_work}/plain"
t_assert_ok _check "${_work}/silent"
t_assert_ok _check "${_work}/broken"

t_case "the entrypoint asks before it sources anything"
_src="$(cat "${ENTRY}")"
t_assert_contains "${_src}" '_ep_cpu_baseline_check /lib64/ld-linux-x86-64.so.2 || exit 1' "a check nothing calls is not a check"
_call="$(grep -n -e '^_ep_cpu_baseline_check /lib64' "${ENTRY}" | head -1 | cut -d: -f1)"
_first="$(grep -n -e '^_safe_source ' "${ENTRY}" | head -1 | cut -d: -f1)"
t_assert_eq "1" "$([ "${_call:-999999}" -lt "${_first:-0}" ] && echo 1 || echo 0)" "line ${_call:-none} must precede the first source at ${_first:-none}"

t_summary
