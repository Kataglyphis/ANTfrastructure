#!/usr/bin/env bash
# Tests for _manifest_wrapper_gate (build-runtime-manifest.sh) — the refusal
# matrix that keeps a multi-arch index from mixing two generations of wrapper
# images. Extracted with its ancestry collaborators stubbed, so the DECISION is
# under test, not the registry.
# docs/cross-build-verification.md#the-wrapper-generation-gate-_manifest_wrapper_gate
set -u
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${TESTS_DIR}/test-harness.sh"
SUBJECT="${TESTS_DIR}/../build-runtime-manifest.sh"

_fn="$(t_fn_src "${SUBJECT}" _manifest_wrapper_gate)" || exit 1

# _gate — run the gate with every collaborator stubbed. Inputs come from the
# environment: RIDS (comma-separated recorded run-ids, one per arch, empty = no
# stamp), COHERENT/ANDROID_STALE/TAG_FAILS as 0|1, plus the real knobs.
_gate() {
  (
    set +e
    RIDS="${RIDS:-r1,r1,r1}"
    TARGET_ARCHES="${TARGET_ARCHES:-amd64,arm64,riscv64}"
    BUILD_IMAGES="${BUILD_IMAGES:-1}"
    FORCE_MANIFEST="${FORCE_MANIFEST:-0}"
    IMAGE_NAME="${IMAGE_NAME:-img:latest-cross}"
    eval "${_fn}"
    arch_list_to_words() { printf '%s' "${1//,/ }"; }
    runtime_wrapper_tag() { [ "${TAG_FAILS:-0}" = "1" ] && return 1; printf 'img:runtime-%s' "$1"; }
    # Stateless on purpose: the caller reads it in a command substitution, so a
    # counter kept here would be discarded with that subshell every time.
    ancestry_recorded_run_id() {
      local a="${1##*-}" i=1 x
      for x in ${TARGET_ARCHES//,/ }; do
        [ "${x}" = "${a}" ] && printf '%s' "$(printf '%s' "${RIDS}" | cut -d, -f"${i}")"
        i=$((i + 1))
      done
    }
    ancestry_run_ids_coherent() { return "${COHERENT:-0}"; }
    runtime_ancestry_assert_wrappers() { return "${ANDROID_STALE:-0}"; }
    warn() { printf 'WARN %s\n' "$*"; }
    log()  { printf 'LOG %s\n' "$*"; }
    _manifest_wrapper_gate
    printf 'RC=%s\n' "$?"
  )
}
# Every call sits in a command substitution, so an assignment prefix cannot leak
# into the next case.

t_case "one generation across all three arches passes"
out="$(_gate)"
t_assert_contains "${out}" "RC=0"
t_assert_contains "${out}" "generation check: OK"

t_case "tags that span generations REFUSE, on the build path too"
out="$(COHERENT=1 _gate)"
t_assert_contains "${out}" "RC=1"
t_assert_contains "${out}" "would MIX releases"
t_assert_contains "$(COHERENT=1 BUILD_IMAGES=0 _gate)" "RC=1"

t_case "a missing run-id WARNS on the build path and REFUSES on the repair path"
out="$(RIDS="r1,,r1" _gate)"
t_assert_contains "${out}" "RC=0"
t_assert_contains "${out}" "1/3 wrapper tag(s) carry no run-id provenance"
out="$(RIDS="r1,,r1" BUILD_IMAGES=0 _gate)"
t_assert_contains "${out}" "RC=1"
t_assert_contains "${out}" "CANNOT be ruled out"

t_case "a wrapper older than the android artifact is advisory on a build, fatal on a repair"
t_assert_contains "$(ANDROID_STALE=1 _gate)" "RC=0"
out="$(ANDROID_STALE=1 BUILD_IMAGES=0 _gate)"
t_assert_contains "${out}" "RC=1"
t_assert_contains "${out}" "predates the current android artifact"

t_case "--force assembles anyway, and says so"
out="$(COHERENT=1 FORCE_MANIFEST=1 _gate)"
t_assert_contains "${out}" "RC=0"
t_assert_contains "${out}" "--force set"

t_case "a repo with no wrapper tag scheme opts out instead of refusing"
t_assert_contains "$(TAG_FAILS=1 _gate)" "RC=0"

t_summary
