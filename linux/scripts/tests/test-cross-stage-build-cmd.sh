#!/usr/bin/env bash
# CHARACTERISATION tests for _cross_stage_build_impl. They pin what it DOES today
# -- the argv it assembles, how often it retries, and what it salvages -- so the
# function can be decomposed (backlog F1) and proven unchanged. A difference here
# after a refactor is a regression, not a judgement call.
set -u
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${TESTS_DIR}/test-harness.sh"
CORE="${TESTS_DIR}/../01-core"

_work="$(mktemp -d)"; trap 'rm -rf "${_work}"' EXIT

# Collaborators, written once. Three of them are defined by cross-stage-build.sh
# itself, so those live in a SECOND file sourced AFTER it: stubbing them before
# the source is silently undone and their knobs then do nothing.
cat > "${_work}/stubs.sh" <<'STUBS'
append_common_build_args() { local -n _o="$1"; _o+=(--common); }
append_buildkit_host_arg() { local -n _o="$1"; _o+=(--host); }
_has_digest_pinned_base() { [ "${HAS_PINNED_BASE:-0}" = "1" ]; }
ancestry_output_annotations() { printf ""; }
log() { :; }
warn() { :; }
sleep() { :; }
STUBS
cat > "${_work}/restubs.sh" <<'RESTUBS'
_cross_stage_push_error_is_transient() { [ "${TRANSIENT:-0}" = "1" ]; }
_cross_salvage_disk_ok() { [ "${DISK_OK:-1}" = "1" ]; }
cross_stage_log_redirect() { printf ""; }
RESTUBS

# One run of the function under stubs. $1 is shell to run instead of the default
# body; the rest are env assignments.
_impl() {
  local body="$1"; shift
  env "$@" bash -c '
    set -u
    source "'"${_work}"'/stubs.sh"
    BUILDKIT_CACHE_DIR="'"${_work}"'/bc"
    NERDCTL_BIN="'"${_work}"'/fake-nerdctl"
    '"${body}"'
    source "'"${CORE}"'/cross-stage-build.sh" 2>/dev/null || true
    source "'"${_work}"'/restubs.sh"
    '"${RUNLINE}"'
  ' 2>/dev/null
}

# ── the assembled command (dry run) ──────────────────────────────────────────
RUNLINE='_cross_stage_build_impl "${PUSH:-0}" label repo/img:tag Dockerfile.x --extra'
_cmd() {
  local push="$1"; shift
  PUSH="${push}" _impl 'is_dry_run() { return 0; }; run() { :; }' "$@" \
    | tr -s " " | tr -d '\\'   # %q escapes the commas; drop them for readability
}

t_case "a local build does not pull and does not push"
_out="$(_cmd 0)"
t_assert_contains "${_out}" "--pull=false" "local builds use local images"
t_assert_eq "0" "$(printf '%s' "${_out}" | grep -c -e 'push=true' || true)" \
  "a local build must not push"

t_case "a pushing build pulls, and stamps the output"
_out="$(_cmd 1)"
t_assert_contains "${_out}" "--pull=true" "a pushing build refreshes its base"
t_assert_contains "${_out}" "type=image,name=repo/img:tag,push=true" "it pushes the tag"
t_assert_contains "${_out}" "compression=zstd" "PUSH1: zstd for new layers"

t_case "a digest-pinned base is immutable, so no pull"
t_assert_contains "$(_cmd 1 HAS_PINNED_BASE=1)" "--pull=false" "a pinned base needs no refresh"

t_case "the local cache is read only when a manifest exists, and written by default"
_out="$(_cmd 0)"
t_assert_eq "0" "$(printf '%s' "${_out}" | grep -c -e '--cache-from type=local' || true)" \
  "an index.json-less slug must not be read"
t_assert_contains "${_out}" "--cache-to type=local" "the local export is the primary tier"

t_case "CROSS_NO_LOCAL_CACHE_EXPORT stops writing but keeps reading"
t_assert_eq "0" "$(printf '%s' "$(_cmd 0 CROSS_NO_LOCAL_CACHE_EXPORT=1)" | grep -c -e '--cache-to type=local' || true)" \
  "the disk guard's knob must stop the local export"

t_case "inline registry cache rides along only on a push"
t_assert_contains "$(_cmd 1)" "--cache-to type=inline" "a push warms other hosts"
t_assert_eq "0" "$(printf '%s' "$(_cmd 0)" | grep -c -e 'type=inline' || true)" \
  "a local build has nothing to publish"

t_case "NO_CACHE disables every tier"
_out="$(_cmd 1 NO_CACHE=1)"
t_assert_contains "${_out}" "--no-cache" "the flag reaches nerdctl"
t_assert_eq "0" "$(printf '%s' "${_out}" | grep -c -e 'cache-from\|cache-to' || true)" \
  "no tier may survive NO_CACHE"

t_case "BUILD_ATTEST is opt-in"
t_assert_eq "0" "$(printf '%s' "$(_cmd 1)" | grep -c -e 'provenance' || true)" "off by default"
t_assert_contains "$(_cmd 1 BUILD_ATTEST=1)" "--provenance=mode=max" "on when asked"

t_case "the caller's extra args and the common args both survive, context last"
t_assert_contains "$(_cmd 1)" "--extra --common ." "extra, then common, then the context"

# ── the retry loop (past the dry-run return) ─────────────────────────────────
RUNLINE='_cross_stage_build_impl "${PUSH:-0}" label repo/img:tag Dockerfile.x --extra >/dev/null 2>&1
    printf "attempts=%s\n" "${_N}"'
_attempts() {
  _impl 'is_dry_run() { return 1; }; _N=0; run() { _N=$((_N + 1)); return "${BUILD_RC:-1}"; }' "$@"
}

t_case "a local build does not retry"
t_assert_contains "$(_attempts PUSH=0 TRANSIENT=1)" "attempts=1" \
  "PUSH_MAX_ATTEMPTS is a push concept; a local failure is final"

t_case "a pushing build retries a transient error up to the cap"
t_assert_contains "$(_attempts PUSH=1 TRANSIENT=1 PUSH_MAX_ATTEMPTS=3)" "attempts=3" \
  "a registry hiccup must not discard a completed multi-GB build"

t_case "a non-transient failure is not retried"
t_assert_contains "$(_attempts PUSH=1 TRANSIENT=0 PUSH_MAX_ATTEMPTS=4)" "attempts=1" \
  "a real build error must fail fast"

t_case "a successful build runs once"
t_assert_contains "$(_attempts PUSH=1 TRANSIENT=1 BUILD_RC=0)" "attempts=1" \
  "success returns immediately"

# ── the salvage pass ─────────────────────────────────────────────────────────
printf 'FROM base AS alpha\nFROM alpha AS beta\nRUN :\n' > "${_work}/Dockerfile.salv"
cat > "${_work}/fake-nerdctl" <<'FAKE'
#!/usr/bin/env bash
for a in "$@"; do [ "${prev:-}" = --target ] && printf '%s\n' "$a" >> "${SALVAGE_LOG}"; prev="$a"; done
exit 0
FAKE
chmod +x "${_work}/fake-nerdctl"

RUNLINE='_cross_stage_build_impl 0 label repo/img:tag "'"${_work}"'/Dockerfile.salv" --extra'
_salvaged() {
  : > "${_work}/salvage.log"
  SALVAGE_LOG="${_work}/salvage.log" \
    _impl 'is_dry_run() { return 1; }; run() { return 1; }; timeout() { shift; "$@"; }' "$@" >/dev/null
  tr '\n' ' ' < "${_work}/salvage.log"
}

t_case "a failed build salvages every named stage of its Dockerfile"
t_assert_eq "alpha beta " "$(_salvaged)" \
  "each FROM ... AS <name> must be re-driven to export its subtree"

t_case "the salvage pass has three off switches, and each works"
t_assert_eq "" "$(_salvaged SALVAGE_CACHE_EXPORT=0)"        "its own knob"
t_assert_eq "" "$(_salvaged CROSS_NO_LOCAL_CACHE_EXPORT=1)" "no local export, nothing to salvage"
t_assert_eq "" "$(_salvaged DISK_OK=0)"                     "a short disk must not be filled further"

t_summary
