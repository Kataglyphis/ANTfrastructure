#!/usr/bin/env bash
# Tests for 01-core/common.sh compiler_cache_launcher — the function whose
# STDOUT becomes CC/CXX.
#
# WHY THIS SUITE EXISTS (2026-08-26)
# ----------------------------------
# compiler_cache_launcher returns the launcher NAME on stdout and callers do
# CC="$(compiler_cache_launcher) gcc". The helpers it calls log with info(),
# which writes to fd 1 (logging.sh:77) — so an unredirected helper leaks its
# log line into the command substitution. That shipped for exactly one build:
# GCC was configured with
#   CC="[INFO] Using sccache with SCCACHE_DIR=... (cap 30G)sccache gcc"
# and died as "configure: error: C compiler cannot create executables", a
# message that points nowhere near the actual cause.
#
# These tests assert the CONTRACT rather than the implementation: whatever the
# function prints on stdout must be a bare launcher name, and nothing else.
set -u
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${TESTS_DIR}/test-harness.sh"

# Load only the function under test, with stub helpers around it, so the suite
# stays a pure unit test (no apt, no sccache server, no network).
# $1 (optional): a directory to present as _COMMON_SH_DIR. The function under
# test looks for its guarded launcher there, and common.sh:6 sets that variable
# when the module is really sourced. Extracting the function with sed leaves it
# UNSET, and the suite runs under `set -u` -- so from c42091e (2026-08-26, the
# commit that added the launcher lookup) every case died on
#   _COMMON_SH_DIR: unbound variable
# and reported an empty stdout instead of testing anything. The suite written to
# catch a stdout leak was itself dead the day after it landed; caught 2026-08-27
# by preflight, which the `2 check(s) failed` / exit-0 bug had also been hiding.
_load_launcher() {
  _COMMON_SH_DIR="${1:-${TMPDIR:-/tmp}/ccl-empty.$$}"
  mkdir -p "${_COMMON_SH_DIR}"
  # shellcheck disable=SC1090
  source "${TESTS_DIR}/../01-core/logging.sh"
  eval "$(sed -n '/^compiler_cache_launcher() {/,/^}/p' "${TESTS_DIR}/../01-core/common.sh")"
}

# ── the leak that actually happened ──────────────────────────────────────────
t_case "sccache branch: stdout carries ONLY the launcher name"
(
  _load_launcher
  ensure_sccache_env() { info "Using sccache with SCCACHE_DIR=/var/cache/sccache (cap 30G)"; return 0; }
  ensure_ccache_env()  { info "Using ccache"; return 0; }
  compiler_cache_launcher 2>/dev/null
) > "${TMPDIR:-/tmp}/ccl_out.$$" 2>/dev/null
_out="$(cat "${TMPDIR:-/tmp}/ccl_out.$$")"; rm -f "${TMPDIR:-/tmp}/ccl_out.$$"
t_assert_eq "${_out}" "sccache"

t_case "ccache fallback: stdout carries ONLY the launcher name"
(
  _load_launcher
  ensure_sccache_env() { info "sccache unavailable"; return 1; }
  ensure_ccache_env()  { info "Using ccache with CCACHE_DIR=/var/cache/ccache"; return 0; }
  command() { if [ "${2:-}" = "ccache" ]; then return 0; fi; builtin command "$@"; }
  compiler_cache_launcher 2>/dev/null
) > "${TMPDIR:-/tmp}/ccl_out2.$$" 2>/dev/null
_out2="$(cat "${TMPDIR:-/tmp}/ccl_out2.$$")"; rm -f "${TMPDIR:-/tmp}/ccl_out2.$$"
t_assert_eq "${_out2}" "ccache"

# ── the preference the whole migration rests on ──────────────────────────────
t_case "guarded launcher WINS over bare sccache when it is reachable"
_gl_dir="${TMPDIR:-/tmp}/ccl-guarded.$$"
mkdir -p "${_gl_dir}"
printf '#!/bin/sh\nexec sccache "$@"\n' > "${_gl_dir}/sccache-launcher.sh"
chmod +x "${_gl_dir}/sccache-launcher.sh"
(
  _load_launcher "${_gl_dir}"
  ensure_sccache_env() { info "Using sccache"; return 0; }
  compiler_cache_launcher 2>/dev/null
) > "${TMPDIR:-/tmp}/ccl_out3.$$" 2>/dev/null
_out3="$(cat "${TMPDIR:-/tmp}/ccl_out3.$$")"; rm -f "${TMPDIR:-/tmp}/ccl_out3.$$"
t_assert_eq "${_out3}" "${_gl_dir}/sccache-launcher.sh"
rm -rf "${_gl_dir}"

# ── the property that matters, stated directly ───────────────────────────────
t_case "output is a single bare token — never a log line, never multi-word"
case "${_out}" in
  *' '*|*'['*|*$'\n'*) t_assert_eq "polluted: ${_out}" "single bare token" ;;
  *)                   t_assert_eq "ok" "ok" ;;
esac

t_case "output never contains a log prefix"
case "${_out}${_out2}" in
  *INFO*|*WARN*|*ERROR*) t_assert_eq "log prefix leaked" "no log prefix" ;;
  *)                     t_assert_eq "ok" "ok" ;;
esac

# ── mutation check: prove the test can actually FAIL ─────────────────────────
# A guard that cannot fail is worse than none, so demonstrate the detector
# fires on the exact pre-fix behaviour (helper stdout NOT redirected).
t_case "MUTATION: an unredirected helper is detected as pollution"
_leaky="$(
  source "${TESTS_DIR}/../01-core/logging.sh"
  ensure_sccache_env() { info "Using sccache with SCCACHE_DIR=/x (cap 30G)"; return 0; }
  # deliberately WITHOUT the >&2 redirect — the shape of the shipped bug
  leaky() { if ensure_sccache_env; then printf '%s' sccache; fi; }
  leaky 2>/dev/null
)"
case "${_leaky}" in
  *INFO*) t_assert_eq "detected" "detected" ;;
  *)      t_assert_eq "mutation NOT detected (${_leaky})" "detected" ;;
esac


# ── the address must reach the shell that runs the COMPILES (YB) ─────────────
# compiler_cache_launcher is always resolved with $( ), and a subshell cannot
# export to its parent, so the sccache server address set inside it never
# reached ninja: every client fell back to TCP 4226 and rootless BuildKit steps
# were served by each other's server. compiler_cache_launcher_env is the one
# owner of the parent-shell half.
_load_env_fn() {
  # shellcheck disable=SC1090
  source "${TESTS_DIR}/../01-core/logging.sh"
  eval "$(sed -n '/^compiler_cache_launcher_env() {/,/^}/p' "${TESTS_DIR}/../01-core/common.sh")"
}

t_case "the env owner exports the address into the CALLER's shell"
_env_out="$(
  _load_env_fn
  ensure_sccache_env() { export SCCACHE_SERVER_UDS=/tmp/probe.sock; info "Using sccache"; return 0; }
  compiler_cache_launcher_env
  printf '%s' "${SCCACHE_SERVER_UDS:-UNSET}"
)"
t_assert_eq "${_env_out}" "/tmp/probe.sock" "a \$( ) resolver cannot do this; that is the whole defect"

t_case "MUTATION: the same call inside \$( ) leaves the caller UNSET"
_env_lost="$(
  _load_env_fn
  ensure_sccache_env() { export SCCACHE_SERVER_UDS=/tmp/probe.sock; return 0; }
  _inner="$(compiler_cache_launcher_env; printf '%s' "${SCCACHE_SERVER_UDS:-UNSET}")"
  printf '%s|%s' "${_inner}" "${SCCACHE_SERVER_UDS:-UNSET}"
)"
t_assert_eq "${_env_lost}" "/tmp/probe.sock|UNSET" "the address is set and then discarded with the subshell"

t_case "the env owner is TOTAL: no usable sccache must not kill the caller"
_env_rc="$(
  set -e
  _load_env_fn
  ensure_sccache_env() { warn "sccache not found"; return 1; }
  compiler_cache_launcher_env
  printf 'survived'
)"
t_assert_eq "${_env_rc}" "survived" "it runs under the caller's set -e, before the launcher is resolved"

t_case "USE_SCCACHE=0 never probes for a server"
_probe_mark="${TMPDIR:-/tmp}/ccl-probed.$$"
rm -f "${_probe_mark}"
(
  _load_env_fn
  ensure_sccache_env() { : > "${_probe_mark}"; return 0; }
  USE_SCCACHE=0 compiler_cache_launcher_env
) >/dev/null 2>&1
t_assert_eq "$([ -e "${_probe_mark}" ] && echo probed || echo quiet)" "quiet" \
  "the switch is honoured before anything starts a server"
rm -f "${_probe_mark}"

t_case "the env owner writes nothing to stdout"
_env_quiet="$(
  _load_env_fn
  ensure_sccache_env() { info "Using sccache with SCCACHE_DIR=/x (cap 30G)"; return 0; }
  compiler_cache_launcher_env 2>/dev/null
)"
t_assert_eq "${_env_quiet}" "" "callers capture the launcher next; a leak here is the 2026-08-26 CC= disaster again"

# ── drift pins: the owner has to be AT the sites, and the guard has to be mounted
t_case "every launcher resolution in the closure is preceded by the env owner"
_SCRIPTS="$(cd "${TESTS_DIR}/.." && pwd)"
_unpaired=""
while IFS=: read -r _f _n _; do
  case "${_f}" in
    */tests/*|*/01-core/common.sh|*/01-core/compiler-cache.sh) continue ;;
  esac
  [ -n "${_n}" ] || continue
  # The owner is called guarded (2>/dev/null || true): 01-core may be absent, and a
  # bare call there is rc 127 under set -e where the line below degrades to ccache.
  if [ "$(sed -n "$((_n - 1))p" "${_f}" | tr -d ' \t')" != "compiler_cache_launcher_env2>/dev/null||true" ]; then
    _unpaired="${_unpaired} ${_f}:${_n}"
  fi
done < <(grep -rn --include='*.sh' -F '$(compiler_cache_launcher' "${_SCRIPTS}" 2>/dev/null)
t_assert_eq "${_unpaired}" "" "a site that resolves the launcher without establishing the address addresses TCP 4226"

t_case "the toolchain stages mount the guarded launcher beside common.sh"
_DF="${TESTS_DIR}/../../Dockerfile.toolchain"
t_assert_eq \
  "$(grep -c 'source=linux/scripts/01-core/common.sh' "${_DF}")" \
  "$(grep -c 'source=linux/scripts/01-core/sccache-launcher.sh' "${_DF}")" \
  "without it these stages run BARE sccache, where an sccache fault ABORTS the build"

t_case "every production call to compiler_cache_launcher_env tolerates 01-core being absent"
# Four of these files document running without 01-core, and each call sits directly
# above `compiler_cache_launcher 2>/dev/null || echo ccache` -- a fallback that exists
# BECAUSE the function may be missing. A bare call there is rc 127 under set -e.
_unguarded="$(grep -rn 'compiler_cache_launcher_env' "${TESTS_DIR}/.." --include='*.sh' \
  | grep -v '/tests/' | grep -v '01-core/common.sh' | grep -v '2>/dev/null || true' || true)"
t_assert_eq "" "${_unguarded}" "unguarded call site(s) would abort the stage instead of degrading to ccache"

t_summary
