#!/usr/bin/env bash
# compiler_cache_launcher's stdout becomes CC/CXX, so it must be a bare name; info() writes to fd 1.
set -u
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${TESTS_DIR}/test-harness.sh"

# Only the function, helpers stubbed; [dir] stands in for _COMMON_SH_DIR, which extraction leaves unset under set -u.
_load_launcher() {
  _COMMON_SH_DIR="${1:-${TMPDIR:-/tmp}/ccl-empty.$$}"
  mkdir -p "${_COMMON_SH_DIR}"
  # shellcheck disable=SC1090
  source "${TESTS_DIR}/../01-core/logging.sh"
  # The image path follows [dir]: inside the image /opt/scripts/core holds a real launcher.
  eval "$(sed -n '/^compiler_cache_launcher() {/,/^}/p' "${TESTS_DIR}/../01-core/common.sh" \
    | sed "s#/opt/scripts/core#${_COMMON_SH_DIR}#g")"
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

# ── mutation check: the detector must fire on an unredirected helper ─────────
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


# ── the address must reach the compiling shell (YB): a $( ) subshell cannot export to its parent ──
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
  # Called guarded: without 01-core a bare call is rc 127 under set -e.
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
# Each call sits above a ccache fallback that exists because 01-core may be absent.
_unguarded="$(grep -rn 'compiler_cache_launcher_env' "${TESTS_DIR}/.." --include='*.sh' \
  | grep -v '/tests/' | grep -v '01-core/common.sh' | grep -v '2>/dev/null || true' || true)"
t_assert_eq "" "${_unguarded}" "unguarded call site(s) would abort the stage instead of degrading to ccache"

# ── media half (F3): an out-variable, not $( ). See docs/cross-build-verification.md#the-media-compile-cache-launcher
_MEDIA_COMMON="${TESTS_DIR}/../03-media/core/common.sh"
_MW="$(mktemp -d)"
trap 'rm -rf "${_MW}"' EXIT

# One call with the collaborators faked. $1 is shell run before the call.
_media_launcher() {
  # platform.sh, not a stub: a second copy of is_truthy's table is what the dupes gate flags.
  bash -c "set -u
    source '${TESTS_DIR}/../01-core/platform.sh'
    source '${_MEDIA_COMMON}'
    ${1}
    _got=
    media_compiler_launcher _got
    printf '[%s]' \"\${_got}\"" 2>&1
}

t_case "a resolvable launcher is returned, and the address is established first"
_out="$(_media_launcher "
  compiler_cache_launcher_env() { echo env-called >> '${_MW}/order'; }
  compiler_cache_launcher()     { echo resolve-called >> '${_MW}/order'; printf sccache; }")"
t_assert_eq "[sccache]" "${_out}" "the out-variable carries the bare launcher token and nothing else"
t_assert_eq "env-called
resolve-called" "$(cat "${_MW}/order")" "resolving before the address is set is the TCP 4226 bug"

t_case "the address reaches the CALLER's shell — the reason this is not a \$( ) helper"
_out="$(_media_launcher '
  compiler_cache_launcher_env() { export SCCACHE_SERVER_UDS=/tmp/probe.sock; }
  compiler_cache_launcher()     { printf sccache; }
  _addr_after() { printf "|addr=%s" "${SCCACHE_SERVER_UDS:-UNSET}"; }
  trap _addr_after EXIT')"
t_assert_contains "${_out}" "addr=/tmp/probe.sock" \
  "a \$( ) resolver exports into a subshell and the compiles then run without the server address"

t_case "a launcher that fails yields empty, never a partial command line"
t_assert_eq "[]" "$(_media_launcher 'compiler_cache_launcher_env() { :; }
  compiler_cache_launcher() { return 1; }')"

t_case "without 01-core the ccache fallback still answers"
printf '#!/bin/sh\nexit 0\n' > "${_MW}/ccache"; chmod +x "${_MW}/ccache"
t_assert_eq "[ccache]" "$(_media_launcher "PATH='${_MW}':\${PATH}")"

t_case "USE_CCACHE=0 turns the fallback off"
t_assert_eq "[]" "$(_media_launcher "PATH='${_MW}':\${PATH}; USE_CCACHE=0")"

t_case "no launcher and no ccache is empty and rc 0 — never an aborted stage"
t_assert_eq "[]" "$(_media_launcher "PATH='${_MW}/none'")"
t_assert_ok bash -c "set -euo pipefail; source '${_MEDIA_COMMON}'
  PATH='${_MW}/none'; x=seed; media_compiler_launcher x; [ -z \"\${x}\" ]"

t_case "the two media scripts call the owner and keep no copy of the guard"
for _f in "${TESTS_DIR}/../03-media/build/ffmpeg/build-ffmpeg.sh" \
          "${TESTS_DIR}/../03-media/build/pyav/build-pyav.sh"; do
  t_assert_ok grep -q 'media_compiler_launcher' "${_f}"
  t_assert_fails grep -q 'command -v compiler_cache_launcher' "${_f}"
  t_assert_fails grep -q '$(media_compiler_launcher' "${_f}"
done

t_summary
