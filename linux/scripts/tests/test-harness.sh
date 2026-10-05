#!/usr/bin/env bash
# Assert helpers for linux/scripts tests: source it, use t_case and t_assert_*, end with t_summary.
[ -n "${_TEST_HARNESS_SH_LOADED:-}" ] && return 0
_TEST_HARNESS_SH_LOADED=1

_T_RUN=0
_T_FAILED=0
_T_CASE=""

_T_WAIVED=0
_T_WAIVED_CASE=""
t_case() { _T_CASE="$1"; _T_WAIVED_CASE=""; }

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
  if [ -n "${_T_WAIVED_CASE}" ]; then
    _T_RUN=$((_T_RUN - 1))
    _T_WAIVED=$((_T_WAIVED + 1))
    return 0
  fi
  _T_FAILED=$((_T_FAILED + 1))
  printf '  \033[0;31mFAIL\033[0m [%s] %s\n' "${_T_CASE:-?}" "$1" >&2
}

_t_pass() { :; }

# Only a Git Bash host may skip; on Linux, where CI runs, a missing prerequisite is a failure.
_t_may_skip() {
  case "$(uname -s)" in MINGW* | MSYS* | CYGWIN*) return 0 ;; esac
  return 1
}

# _t_host_verdict <label> <what> <command...>: 0 present; 1 Git Bash lacks it (SKIP printed); 2 a host that must have it lacks it.
_t_host_verdict() {
  local label="$1" what="$2"
  shift 2
  "$@" >/dev/null 2>&1 && return 0
  _t_may_skip || return 2
  printf '  SKIP [%s] this host lacks %s\n' "${label}" "${what}"
  return 1
}

# t_skip_unless <what> <command...>: Git Bash may skip a suite it cannot host (exit 77, listed by run-tests.sh); elsewhere it fails.
t_skip_unless() {
  local rc=0
  _t_host_verdict "$(basename "$0")" "$@" || rc=$?
  [ "${rc}" -ne 1 ] || exit 77
  [ "${rc}" -eq 2 ] || return 0
  printf '  \033[0;31mFAIL\033[0m [%s] prerequisite missing: %s\n' "$(basename "$0")" "$1" >&2
  exit 1
}

# t_needs <what> <command...>, right after t_case: Git Bash waives that case's failures (SKIP, counted in t_summary); elsewhere it fails.
t_needs() {
  local rc=0
  _t_host_verdict "${_T_CASE:-?}" "$@" || rc=$?
  [ "${rc}" -ne 1 ] || _T_WAIVED_CASE="${_T_CASE}"
  [ "${rc}" -eq 2 ] || return 0
  _T_RUN=$((_T_RUN + 1))
  _t_fail "prerequisite missing: $1"
}

# _t_probe_file <test...>: one throwaway file a/ in a fresh dir, the test run with it as $1 and $2 = its dir.
_t_probe_file() {
  local d rc=1
  d="$(mktemp -d)" || return 1
  if : > "${d}/a" && "$@" "${d}/a" "${d}"; then rc=0; fi
  rm -r -f -- "${d}"
  return "${rc}"
}

# t_posix_symlinks: true when ln -s makes a link; Git Bash copies the file instead.
t_posix_symlinks() { _t_probe_file _t_links; }
_t_links() { ln -s a "$2/b" 2>/dev/null && [ -L "$2/b" ]; }

# t_posix_modes: true when chmod sets the bits it is given; Git Bash derives them from the file's name and content.
t_posix_modes() { _t_probe_file _t_modes; }
_t_modes() { chmod 711 "$1" && [ "$(stat -c %a "$1" 2>/dev/null)" = 711 ]; }

# t_posix_python: true when python3 is a POSIX one; Windows' python sees drive-letter paths, not the shell's /tmp or /dev/fd.
t_posix_python() { python3 -c 'import os, sys; sys.exit(os.sep != "/")'; }

# t_is_elf <file>: true when the file starts with the ELF magic; Git Bash's own binaries are PE.
t_is_elf() { [ "$(head -c 4 "$1" 2>/dev/null | tail -c 3)" = ELF ]; }

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

# t_rt_sandbox: a dir holding the runtime smoke minus its main() call (rt.sh), beside every sibling it sources.
t_rt_sandbox() {
  local _d; _d="$(mktemp -d)"
  cp "${_T_SCRIPTS}/06-packaging"/*.sh "${_T_SCRIPTS}/06-packaging"/*.py "${_d}/"
  sed '$d' "${_T_SCRIPTS}/06-packaging/smoke-runtime-image.sh" > "${_d}/rt.sh"
  printf '%s' "${_d}"
}

# t_rt_recorded <sandbox> <probe text> <call...>: the call's output with _rt_run printing the recorded probe, then FAILURES=<n>.
t_rt_recorded() {
  local _sb="$1" _probe="$2"; shift 2
  PROBE="${_probe}" bash -c "source '${_sb}/rt.sh' >/dev/null 2>&1
_rt_run() { printf '%s\n' \"\${PROBE}\"; }
$*; echo \"FAILURES=\${FAILURES}\"" 2>&1
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
  [ "${_T_WAIVED}" -eq 0 ] || printf '  %d failed assertion(s) waived: their cases name what this host lacks\n' "${_T_WAIVED}"
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
