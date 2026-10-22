#!/usr/bin/env bash
# runtime_push_tag: a tag whose registry digest equals the local manifest digest is not uploaded again (CON158).
set -u
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${TESTS_DIR}/test-harness.sh"
FN="$(t_fn_src "${TESTS_DIR}/../01-core/runtime-build-fns.sh" runtime_push_tag)" || exit 1
eval "${FN}"

# Stand-ins: the digests come from STUB_LOCAL / STUB_REMOTE, and every upload attempt is counted.
_runtime_local_digest() { echo "${STUB_LOCAL}"; }
_runtime_registry_digest() { echo "${STUB_REMOTE}"; }
_runtime_push_attempt() { PUSHES=$(( PUSHES + 1 )); return 0; }
log() { LAST_LOG="$*"; }
warn() { LAST_LOG="$*"; }
sleep() { :; }
PUSHES=0

t_case "a registry digest equal to the local one skips the upload"
PUSHES=0; STUB_LOCAL=sha256:aa; STUB_REMOTE=sha256:aa
runtime_push_tag ghcr.io/x/y:latest-amd64
t_assert_eq "0" "${PUSHES}"
t_assert_contains "${LAST_LOG}" "already in the registry (sha256:aa), no upload"

t_case "a different or unknown registry digest uploads"
PUSHES=0; STUB_LOCAL=sha256:aa; STUB_REMOTE=sha256:bb
runtime_push_tag ghcr.io/x/y:latest-amd64
t_assert_eq "1" "${PUSHES}"

PUSHES=0; STUB_LOCAL=sha256:aa; STUB_REMOTE=""
runtime_push_tag ghcr.io/x/y:latest-amd64
t_assert_eq "1" "${PUSHES}"

t_summary
