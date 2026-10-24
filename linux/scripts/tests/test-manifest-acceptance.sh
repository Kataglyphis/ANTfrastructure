#!/usr/bin/env bash
# The real manifest decision must keep the public tag behind acceptance.
set -euo pipefail
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${TESTS_DIR}/test-harness.sh"
SUBJECT="${TESTS_DIR}/../build-runtime-manifest.sh"
subject="$(t_fn_src "${SUBJECT}" create_manifest)"

# shellcheck disable=SC2034 # The extracted production function reads these test inputs through eval.
scenario() (
  eval "${subject}"
  TARGET_ARCHES=amd64,arm64,riscv64
  IMAGE_NAME=ghcr.io/kataglyphis/example:latest
  CROSS_RUN_ID=test-run
  PUSH_MANIFEST=1
  RUNTIME_MANIFEST_COHERENCE=1
  RUNTIME_MANIFEST_COMPLETENESS=1
  NERDCTL_BIN=engine
  arch_list_to_words() { printf '%s' "${1//,/ }"; }
  runtime_wrapper_tag() { printf 'wrapper:%s' "$1"; }
  is_dry_run() { return 1; }
  _manifest_image_env_gate() { return 0; }
  _manifest_wrapper_gate() { return 0; }
  _manifest_completeness_gate() { return 0; }
  engine() { [ "$1 $2" = 'manifest inspect' ] && return 1; printf 'ENGINE %s\n' "$*"; }
  run() { "$@"; }
  retry() { shift 3; "$@"; }
  _manifest_accept_and_promote() {
    printf 'ACCEPT %s\n' "$1"
    [ "${FAIL_ACCEPTANCE:-0}" = 0 ] || return 1
    printf 'PROMOTE %s\n' "${IMAGE_NAME}"
  }
  create_manifest
)

t_case "candidate is published before acceptance, then the public tag is promoted"
out="$(scenario)"
t_assert_contains "${out}" 'manifest create ghcr.io/kataglyphis/example:candidate-test-run wrapper:amd64 wrapper:arm64 wrapper:riscv64'
t_assert_contains "${out}" 'manifest push --purge ghcr.io/kataglyphis/example:candidate-test-run'
t_assert_contains "${out}" 'ACCEPT ghcr.io/kataglyphis/example:candidate-test-run'
t_assert_contains "${out}" 'PROMOTE ghcr.io/kataglyphis/example:latest'
t_assert_eq 0 "$(printf '%s\n' "${out}" | grep -c 'manifest .*example:latest' || true)"

t_case "failed acceptance fails publication and never promotes"
status=0
out="$(FAIL_ACCEPTANCE=1 scenario)" || status=$?
t_assert_eq 1 "${status}"
t_assert_eq 0 "$(printf '%s\n' "${out}" | grep -c PROMOTE || true)"

acceptance_route() (
  eval "$(t_fn_src "${SUBJECT}" _manifest_accept_and_promote)"
  REPO_ROOT=/fixture
  CROSS_RUN_ID=test-run
  IMAGE_NAME=ghcr.io/kataglyphis/example:latest
  python3() {
    case "$2" in
      resolve) printf 'ghcr.io/kataglyphis/example@sha256:abc' ;;
      check|promote) printf '%s\n' "$*" ;;
    esac
  }
  _manifest_accept_and_promote candidate
)

t_case "consumer logs and receipt live under logs while promotion uses that receipt"
out="$(acceptance_route)"
t_assert_contains "${out}" '--workspace /fixture/logs/image-acceptance/test-run/consumers'
t_assert_contains "${out}" '--receipt /fixture/logs/image-acceptance/test-run/receipt.json'
t_assert_contains "${out}" 'promote --receipt /fixture/logs/image-acceptance/test-run/receipt.json --target ghcr.io/kataglyphis/example:latest'
t_summary
