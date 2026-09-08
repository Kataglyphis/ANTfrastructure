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
# Empty by default -- most cases want no log file at all. FAKE_LOG_FILE gives the
# retry loop a real one to tail, which is the only way to reach the registry-cache
# drop below. It is re-stubbed AFTER the source because the subject defines it.
cross_stage_log_redirect() { printf '%s' "${FAKE_LOG_FILE:-}"; }
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

# ── the registry-cache drop (F1) ─────────────────────────────────────────────
# 2026-08-18: the ghcr cache IMPORT is itself the failing read, so a retry that
# keeps `--cache-from type=registry` re-reads the same broken blob. After TWO
# DeadlineExceeded/httpReadSeeker hits the loop drops the registry pair and keeps
# the LOCAL cache. Nothing covered this path before: it needs a non-empty
# log_file whose tail matches, and it mutates build_cmd and _regcache_fails
# ACROSS retry iterations, which no single-shot argv assertion can see.
RUNLINE='_cross_stage_build_impl 1 label repo/img:tag Dockerfile.x --extra >/dev/null 2>&1'
# Every attempt appends its own argv to ARGV_LOG; the log_file the impl tails is
# seeded with the flake text so `tail | grep` matches from the first failure.
# $1 is the last line the build log ends on -- the retry loop tails it and only
# the cache-import flake text arms the drop.
_regcache() {
  local tail_line="$1"; shift
  : > "${_work}/argv.log"
  printf '%s\n' "${tail_line}" > "${_work}/flake.log"
  ARGV_LOG="${_work}/argv.log" FAKE_LOG_FILE="${_work}/flake.log" _impl '
    is_dry_run() { return 1; }
    tee() { cat >/dev/null; }
    run() { printf "%s\n" "$*" >> "${ARGV_LOG}"; return 1; }' "$@"
}
_FLAKE='ERROR: failed to copy: httpReadSeeker: failed open: DeadlineExceeded'
_NOT_FLAKE='ERROR: unexpected status: 502 Bad Gateway' 
# $1 = 1-based attempt number -> that attempt's argv
_argv_of() { sed -n "$1p" "${_work}/argv.log"; }

# The count comes from the argv log, not from _N: with a log_file set, the impl
# pipes `run` into tee, and the left side of a pipe is a SUBSHELL -- an in-process
# counter never leaves it. That is also why the log file is the only honest record
# of what each attempt was handed.
_attempt_count() { grep -c . "${_work}/argv.log" 2>/dev/null || true; }

t_case "the registry cache survives the FIRST flake -- one hiccup is not a verdict"
_regcache "${_FLAKE}" PUSH=1 TRANSIENT=1 PUSH_MAX_ATTEMPTS=4 >/dev/null
t_assert_eq "4" "$(_attempt_count)" "the retry ladder itself must be unaffected"
t_assert_contains "$(_argv_of 1)" "cache-from type=registry" "attempt 1 reads the registry cache"
t_assert_contains "$(_argv_of 2)" "cache-from type=registry" \
  "one DeadlineExceeded can be a network blip; dropping the tier on it loses reuse for nothing"

t_case "after the SECOND flake the registry pair is gone from every later attempt"
t_assert_eq "0" "$(_argv_of 3 | grep -c 'cache-from type=registry' || true)" \
  "the import is the failing read; retrying it re-reads the same broken blob"
t_assert_eq "0" "$(_argv_of 3 | grep -c 'cache-to type=inline' || true)" \
  "the inline export rides on the same registry ref"
t_assert_eq "0" "$(_argv_of 4 | grep -c 'type=registry\|type=inline' || true)" \
  "and it stays gone -- the counter does not reset per attempt"

t_case "the LOCAL cache tier survives the drop"
t_assert_contains "$(_argv_of 3)" "--cache-to type=local" \
  "the local export is what still fast-forwards the retry; dropping it too would rebuild from scratch"
t_assert_contains "$(_argv_of 3)" "--extra" "the caller's own args are not collateral"

t_case "a flake-free failure keeps the registry cache for every attempt"
_regcache "${_NOT_FLAKE}" PUSH=1 TRANSIENT=1 PUSH_MAX_ATTEMPTS=4 >/dev/null
t_assert_contains "$(_argv_of 4)" "cache-from type=registry" \
  "a transient push error that is NOT a cache-import read must not cost the tier"

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

# ── the REAL classifier ────────────────────────────────────────────────────
# Everything above stubs _cross_stage_push_error_is_transient to a boolean, so
# its regex had no coverage at all -- which is how a bare 429 arm shipped that
# matched BuildKit's `#15 429.0` elapsed-time prefix and bought three full
# rebuilds of a stage whose smoke had failed deterministically. Drive the
# shipped function against log tails instead.
_classify() {
  local out
  out="$(mktemp)"; printf '%s\n' "$1" > "${out}"
  ( eval "$(sed -n '/^_cross_stage_push_error_is_transient()/,/^}/p' "${CORE}/cross-stage-build.sh")"
    if _cross_stage_push_error_is_transient "${out}"; then printf 'retry'; else printf 'hard'; fi )
  rm -f "${out}"
}

t_case "BuildKit's elapsed-time prefix is not an HTTP status"
t_assert_eq "hard" "$(_classify '#15 429.0 /opt/gcc/bin/gcc -shared foo.o')" \
  "a step running 429.x seconds must not make the next hard failure look rate-limited"
t_assert_eq "hard" "$(_classify '#15 4291.7 /opt/gcc/bin/gcc -c bar.c')" \
  "and the same at 4290-4299s, which is where a long LLVM step actually sits"
t_assert_eq "hard" "$(_classify '#15 503.2 cc -c x.c')" \
  "the 5xx arm was always anchored to its status text; keep it that way"

t_case "a real rate limit still retries, in every spelling a registry uses"
t_assert_eq "retry" "$(_classify 'failed to push: 429 Too Many Requests')" "the HTTP status line"
t_assert_eq "retry" "$(_classify 'unexpected status: toomanyrequests')"    "the registry error code"
t_assert_eq "retry" "$(_classify 'unexpected status: 429')"                "a bare status: label"

t_case "a DNS blip is transient -- it killed a whole 3-arch chain once"
for _d in 'fatal: unable to access: Could not resolve host: github.com' \
          'curl: (6) Temporary failure in name resolution' \
          'ssh: Name or service not known' \
          'connect: Network is unreachable'; do
  t_assert_eq "retry" "$(_classify "${_d}")" \
    "a source stage clones from github; the STAGE BARRIER turns one failed lookup into a dead run"
done

t_case "a deterministic build failure is never retried"
t_assert_eq "hard" "$(_classify 'error: failed to solve: process \"bash -lc smoke.sh\" did not complete successfully: exit code: 1')" \
  "retrying a failed smoke costs a full stage rebuild per attempt and can never pass"

t_case "an unreadable log stays retryable -- we cannot classify what we cannot read"
t_assert_eq "retry" "$( ( eval "$(sed -n '/^_cross_stage_push_error_is_transient()/,/^}/p' "${CORE}/cross-stage-build.sh")"
  if _cross_stage_push_error_is_transient ""; then printf 'retry'; else printf 'hard'; fi ) )" \
  "the no-log fallback is deliberate; only the regex was wrong"

t_summary
