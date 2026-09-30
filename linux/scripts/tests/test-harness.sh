#!/usr/bin/env bash
# Assert helpers for linux/scripts tests: source it, use t_case and t_assert_*, end with t_summary.
[ -n "${_TEST_HARNESS_SH_LOADED:-}" ] && return 0
_TEST_HARNESS_SH_LOADED=1

_T_RUN=0
_T_FAILED=0
_T_CASE=""

t_case() { _T_CASE="$1"; }

# A mistyped t_* counts as a failure; the handler runs in a separate environment, so it records on disk.
_T_UNKNOWN_MARK="${TMPDIR:-/tmp}/.t-harness-unknown.$$"
rm -f "${_T_UNKNOWN_MARK}" 2>/dev/null || true

command_not_found_handle() {
  # Only t_* names: suites legitimately probe for absent binaries.
  case "$1" in
    t_*)
      printf '%s\n' "$1" >> "${_T_UNKNOWN_MARK}"
      printf '  \033[0;31mFAIL\033[0m [%s] unknown assertion: %s\n' "${_T_CASE:-?}" "$1" >&2
      ;;
  esac
  return 127
}

_t_fail() {
  _T_FAILED=$((_T_FAILED + 1))
  printf '  \033[0;31mFAIL\033[0m [%s] %s\n' "${_T_CASE:-?}" "$1" >&2
}

_t_pass() { :; }

# t_fake_elf <path> <e_machine>: a 64-byte ELF header, all any gate here reads of a binary.
t_fake_elf() {
  python3 -c 'import sys
m = int(sys.argv[2])
h = bytearray(64)
h[0:4] = b"\x7fELF"; h[4] = 2; h[5] = 1
h[16:18] = (2).to_bytes(2, "little")
h[18:20] = m.to_bytes(2, "little")
open(sys.argv[1], "wb").write(bytes(h))' "$1" "$2"
}

# t_fn_src <file> <function>: one top-level function's source; 1 when gone, so callers add `|| exit 1`.
t_fn_src() {
  local _src
  _src="$(awk -v fn="$2" '$0 == fn "() {" {p=1} p {print} p && /^}$/ {exit}' "$1")"
  [ -n "${_src}" ] || { echo "FAIL: $2 not found in $1" >&2; return 1; }
  printf '%s\n' "${_src}"
}

# t_stubbed_script <library> <fn> [args...]: a `bash -c` body calling one library function; env prefixes stay on the caller's line.
t_stubbed_script() {
  local _lib="${1:?t_stubbed_script: library path required}"
  shift
  local _args="" _a
  for _a in "$@"; do _args+=" $(printf '%q' "${_a}")"; done
  printf 'set -uo pipefail\nsource %q\n%s\n' "${_lib}" "${_args}"
}

# t_stage_build_args <repo root> <arch>: "ARGS=<n>", then each build arg an orchestrator hands a stage, one per line.
t_stage_build_args() {
  bash -c 'REPO_ROOT="$1"; source "$1/linux/scripts/lib-orchestrator.sh" >/dev/null 2>&1
    declare -a a=(); append_common_build_args a "$2"; echo "ARGS=${#a[@]}"
    printf "%s\n" "${a[@]}"' _ "$1" "$2"
}

# t_gate_tree <module>...: a throwaway root for gates rooted at __file__; see docs/code-quality-tooling.md#the-mutation-gate-mutations
_T_SCRIPTS="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
t_gate_tree() {
  local root m; root="$(mktemp -d)"
  for m in "$@"; do
    install -D -m 0644 "${_T_SCRIPTS}/${m}" "${root}/linux/scripts/${m}"
  done
  printf '%s' "${root}"
}

# t_git_commit <dir>: commit everything quietly, with a per-command identity independent of the runner's config.
t_git_commit() {
  git -C "$1" add -A >/dev/null 2>&1
  git -C "$1" -c user.email=t@t -c user.name=t commit -qm fixture >/dev/null 2>&1
}

# t_consumer_fixture <parent-dir> <plant-fn> <shape> [vendored]: prints a consumer git checkout; vendored adds a gitlink.

# <plant-fn> gets `<dir> <shape>`, then shape `vendored` for the nested one; see docs/code-quality-tooling.md#the-mutation-gate-mutations
T_VENDORED=third_party/ANTfrastructure
t_consumer_fixture() {
  local parent="$1" plant="$2" shape="$3" vendored="${4:-}" d
  d="$(mktemp -d "${parent}/consumer.XXXXXX")"
  git -C "${d}" init -q
  "${plant}" "${d}" "${shape}"
  if [ "${vendored}" = vendored ]; then
    mkdir -p "${d}/${T_VENDORED}"
    git -C "${d}/${T_VENDORED}" init -q
    "${plant}" "${d}/${T_VENDORED}" vendored
    t_git_commit "${d}/${T_VENDORED}"
  fi
  t_git_commit "${d}"
  printf '%s' "${d}"
}

# t_out <command...> — combined stdout+stderr, to assert on messages
t_out() { "$@" 2>&1; }
# t_rc <command...> — the exit code as text, for t_assert_eq
t_rc()  { "$@" >/dev/null 2>&1; echo $?; }

# t_assert_eq <expected> <actual> [message]
t_assert_eq() {
  _T_RUN=$((_T_RUN + 1))
  if [ "$1" = "$2" ]; then _t_pass; else
    _t_fail "${3:-values differ}: expected '$1', got '$2'"
  fi
}

# t_assert_contains <haystack> <needle> [message]
t_assert_contains() {
  _T_RUN=$((_T_RUN + 1))
  case "$1" in *"$2"*) _t_pass ;; *) _t_fail "${3:-missing substring}: '$2' not in '$1'" ;; esac
}

# t_assert_contains_any <haystack> <message> <needle>...: any one needle, for evidence whose wording depends on a race.
t_assert_contains_any() {
  local haystack="$1" message="$2"; shift 2
  _T_RUN=$((_T_RUN + 1))
  local needle
  for needle in "$@"; do
    case "${haystack}" in *"${needle}"*) _t_pass; return ;; esac
  done
  _t_fail "${message}: none of '$*' in '${haystack}'"
}

# A message passed to t_assert_ok/t_assert_fails makes `test` exit 2, which would otherwise pass vacuously.
_t_usage_error() {
  [ "$2" = "2" ] || return 1
  case "$1" in test|'[') return 0 ;; *) return 1 ;; esac
}

# _t_assert_run <name> <want: 0 or 1> <verdict> <command...>: the runner behind t_assert_ok and t_assert_fails.
_t_assert_run() {
  local name="$1" want="$2" verdict="$3"; shift 3
  local _rc=0
  _T_RUN=$((_T_RUN + 1))
  "$@" >/dev/null 2>&1 || _rc=$?
  if _t_usage_error "$1" "${_rc}"; then
    _t_fail "malformed test expression: $* -- ${name} takes a COMMAND and no message, so the message became an ARGUMENT and this verdict is about the wrong thing"
  elif { [ "${want}" = "0" ] && [ "${_rc}" -eq 0 ]; } \
    || { [ "${want}" != "0" ] && [ "${_rc}" -ne 0 ]; }; then
    _t_pass
  else
    _t_fail "expected ${verdict}: $*"
  fi
}

# t_assert_ok <command...>  — command must succeed
t_assert_ok()    { _t_assert_run t_assert_ok 0 success "$@"; }

# t_assert_fails <command...>  — command must fail
t_assert_fails() { _t_assert_run t_assert_fails 1 failure "$@"; }

t_summary() {
  local _unknown=0
  if [ -s "${_T_UNKNOWN_MARK:-/nonexistent}" ]; then
    _unknown="$(wc -l < "${_T_UNKNOWN_MARK}" | tr -d ' ')"
    _T_FAILED=$((_T_FAILED + _unknown))
    printf '  %s unknown command(s)/assertion(s) — a typo is NOT coverage\n' "${_unknown}" >&2
    rm -f "${_T_UNKNOWN_MARK}" 2>/dev/null || true
  fi
  if [ "${_T_FAILED}" -gt 0 ]; then
    printf '  %d/%d assertion(s) FAILED\n' "${_T_FAILED}" "${_T_RUN}" >&2
    exit 1
  fi
  # Zero assertions is a failure: a gutted suite must not read as green.
  if [ "${_T_RUN}" -eq 0 ]; then
    printf '  SUITE RAN ZERO ASSERTIONS — treating as failure\n' >&2
    exit 1
  fi
  printf '  %d assertion(s) passed\n' "${_T_RUN}"
  exit 0
}

# t_gate_probe <module.py> <<'PY' … PY: stdout with the shipped gate bound to `g`; see docs/code-quality-tooling.md#code-to-docs-pointers-doc-links
t_gate_probe() {
  local _mod="$1"
  {
    printf 'import importlib.util, pathlib, tempfile\n'
    printf 'spec = importlib.util.spec_from_file_location("g", "%s")\n' "${_mod}"
    printf 'g = importlib.util.module_from_spec(spec); spec.loader.exec_module(g)\n'
    cat
  } | "${PREFLIGHT_PYTHON:-python3}" -
}
