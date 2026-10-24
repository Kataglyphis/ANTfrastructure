#!/usr/bin/env bash
# Optional-tool consumer suites share isolated workspaces and positional source snapshots.
source "${BASH_SOURCE[0]%/*}/test-workspace-fixture.sh"

t_compiler_tool_fixture_init() {
  local ffmpeg_leaf="$1" scripts="${BASH_SOURCE[0]%/*}/.."
  local -n _ctf_ffmpeg=FFMPEG _ctf_ort=ORT _ctf_utils=UTILS _ctf_receipt=RECEIPT
  shift
  t_fixture_workspace_init WORK
  _ctf_ffmpeg="${1:-${scripts}/03-media/build/ffmpeg/${ffmpeg_leaf}}"
  _ctf_ort="${2:-${scripts}/03-media/build/onnxruntime/build/lib/common.sh}"
  _ctf_utils="${3:-${scripts}/01-core/compiler-cache-utils.sh}"
  _ctf_receipt="${4:-}"
  [ -z "${_ctf_receipt}" ] || : > "${_ctf_receipt}"
}
