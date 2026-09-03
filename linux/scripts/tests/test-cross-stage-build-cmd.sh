#!/usr/bin/env bash
# CHARACTERISATION tests for _cross_stage_build_impl: they pin the exact
# `nerdctl build` command it assembles, so the 170-line function can be
# decomposed (backlog F1) and proven byte-identical afterwards. They describe
# what it DOES today, not what it should do -- a difference here after a refactor
# is a regression, not a judgement call.
#
# The dry-run path prints the assembled argv, which is the whole hook.
set -u
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${TESTS_DIR}/test-harness.sh"
CORE="${TESTS_DIR}/../01-core"

_work="$(mktemp -d)"; trap 'rm -rf "${_work}"' EXIT

# Assemble the command for one flag combination and print it on one line.
# Every collaborator is stubbed so only this function's own logic shows.
_cmd() {
  local push="$1"; shift
  env "$@" bash -c '
    set -u
    append_common_build_args() { local -n _o="$1"; _o+=(--common); }
    append_buildkit_host_arg() { local -n _o="$1"; _o+=(--host); }
    cross_stage_log_redirect() { printf ""; }
    _has_digest_pinned_base() { [ "${HAS_PINNED_BASE:-0}" = "1" ]; }
    ancestry_output_annotations() { printf "%s" "${ANCESTRY_ANN:-}"; }
    is_dry_run() { return 0; }
    log() { :; }; warn() { :; }; run() { :; }
    BUILDKIT_CACHE_DIR="'"${_work}"'/bc"
    source "'"${CORE}"'/cross-stage-build.sh" 2>/dev/null || true
    _cross_stage_build_impl '"${push}"' label repo/img:tag Dockerfile.x --extra
  ' 2>/dev/null | tr -s " " | tr -d '\\'   # %q escapes the commas; drop them for readability
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
_out="$(_cmd 1 HAS_PINNED_BASE=1)"
t_assert_contains "${_out}" "--pull=false" "a pinned base needs no refresh"

t_case "the local cache is read only when a manifest exists, and written by default"
_out="$(_cmd 0)"
t_assert_eq "0" "$(printf '%s' "${_out}" | grep -c -e '--cache-from type=local' || true)" \
  "an index.json-less slug must not be read"
t_assert_contains "${_out}" "--cache-to type=local" "the local export is the primary tier"

t_case "CROSS_NO_LOCAL_CACHE_EXPORT stops writing but keeps reading"
_out="$(_cmd 0 CROSS_NO_LOCAL_CACHE_EXPORT=1)"
t_assert_eq "0" "$(printf '%s' "${_out}" | grep -c -e '--cache-to type=local' || true)" \
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
_out="$(_cmd 1)"
t_assert_contains "${_out}" "--extra --common ." "extra, then common, then the context"

t_summary
