#!/usr/bin/env bash
set -euo pipefail
# verify-android-stage-parity.sh — the five parallel library stages in
# linux/Dockerfile.android (android-gstreamer/-onnx/-litert/-opencv/-iree) are
# INTENTIONALLY identical except for their `ARG ANDROID_LIB=<name>` value: they
# must stay separate stages so BuildKit builds them concurrently in one graph
# (collapsing them into a parameterized single stage would serialize five
# orchestrator invocations), and this check makes the resulting copy-paste
# mechanical instead of drift-prone. Any real divergence must be introduced
# deliberately — by teaching THIS check about it, not by silent editing.
#
# Method: extract each stage block, drop comments/blank lines, normalize the
# ANDROID_LIB value to a placeholder, and require all five normalized blocks to
# be byte-identical.

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
DOCKERFILE="${REPO_ROOT}/linux/Dockerfile.android"

STAGES=(android-gstreamer android-onnx android-litert android-opencv android-iree)

echo "=== Android library stage parity check ==="

extract_normalized() {  # extract_normalized <stage-name>
  awk -v stage="$1" '
    $0 ~ "^FROM android-sdk AS " stage "$" { grab = 1; next }
    grab && /^FROM / { grab = 0 }
    grab && /^# =/   { grab = 0 }
    grab {
      if ($0 ~ /^[[:space:]]*#/ || $0 ~ /^[[:space:]]*$/) next   # comments/blanks
      sub(/^ARG ANDROID_LIB=.*/, "ARG ANDROID_LIB=<LIB>")
      print
    }
  ' "${DOCKERFILE}"
}

reference=""
reference_stage=""
FAIL=0
for stage in "${STAGES[@]}"; do
  block="$(extract_normalized "${stage}")"
  if [ -z "${block}" ]; then
    echo "  ERROR: stage '${stage}' not found in linux/Dockerfile.android (renamed? update STAGES here)"
    FAIL=1
    continue
  fi
  if [ -z "${reference}" ]; then
    reference="${block}"
    reference_stage="${stage}"
    continue
  fi
  if [ "${block}" != "${reference}" ]; then
    echo "  ERROR: stage '${stage}' diverges from '${reference_stage}' (modulo ANDROID_LIB):"
    diff <(printf '%s\n' "${reference}") <(printf '%s\n' "${block}") | sed 's/^/    /' || true
    FAIL=1
  fi
done

if [ "${FAIL}" -ne 0 ]; then
  echo "ERROR: android library stages have drifted apart."
  echo "Either restore parity, or update this check if the divergence is deliberate."
  exit 1
fi
echo "All ${#STAGES[@]} android library stages are identical modulo ANDROID_LIB"
