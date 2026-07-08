#!/usr/bin/env bash
set -euo pipefail

# smoke-torch-venv.sh
# Standalone integrity smoke for the shipped PyTorch venv (/opt/venv). Imports
# the critical packages and prints versions, so a broken/incomplete venv is
# caught explicitly rather than surfacing later at app runtime.
#
# Why this exists in addition to assemble-torch-app.sh's build-time verify:
#   - It runs against ANY built or pulled image (post-build / pre-flight),
#     whereas the build-time verify only runs when assembly SUCCEEDS — the numpy
#     wheel-install collision (fix 9f07334) failed *before* that verify ran.
#   - It also catches the subtler "silent drop": when the frozen uv.lock fails
#     for a Python/platform (`Extra 'none' is not defined ...`) and assembly
#     falls back to force-reinstalling wheels, a dependency can go missing while
#     the build still succeeds. An explicit import check surfaces that.
# See docs/cross-build-verification.md (failure class #5).
#
# Usage:  smoke-torch-venv.sh            # uses /opt/venv
#         VENV=/path smoke-torch-venv.sh # override venv location
# Exit:   non-zero if any REQUIRED import fails (skips cleanly if no venv).

_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=linux/scripts/06-packaging/smoke-common.sh
source "${_SCRIPT_DIR}/smoke-common.sh"

VENV="${VENV:-/opt/venv}"
PY="${VENV}/bin/python"

# Required modules: (import_name, pretty_name, version_expr_or_empty)
REQUIRED_MODULES=(
  "numpy|numpy|numpy.__version__"
  "torch|torch|torch.__version__"
  "torchvision|torchvision|torchvision.__version__"
  "PIL|pillow|PIL.__version__"
  "cv2|opencv|cv2.__version__"
  "contourpy|contourpy|contourpy.__version__"
)

# Optional modules (warn, do not fail): the app package name can vary and GPU
# EPs are build-dependent.
OPTIONAL_MODULES=(
  "onnxruntime|onnxruntime|onnxruntime.__version__"
)

try_import() {
  # $1 import name, $2 pretty, $3 version expr, $4 required(1)/optional(0)
  local mod="$1" pretty="$2" ver_expr="$3" required="$4" out
  if out="$("${PY}" -c "import ${mod}; print(${ver_expr:-\"ok\"})" 2>&1)"; then
    pass "${pretty} import OK (${out})"
    return 0
  fi
  if [ "${required}" = "1" ]; then
    fail "${pretty} import FAILED: $(printf '%s' "${out}" | tail -1)"
  else
    printf '  SKIP %s not importable (optional): %s\n' "${pretty}" "$(printf '%s' "${out}" | tail -1)"
  fi
  return 1
}

main() {
  echo "=== smoke: torch venv integrity (${VENV}) ==="
  if [ ! -x "${PY}" ]; then
    echo "  SKIP no venv interpreter at ${PY} (nothing to check in this image)"
    exit 0
  fi
  pass "venv python present: $("${PY}" --version 2>&1)"

  local spec
  for spec in "${REQUIRED_MODULES[@]}"; do
    IFS='|' read -r mod pretty ver <<<"${spec}"
    try_import "${mod}" "${pretty}" "${ver}" 1 || true
  done
  for spec in "${OPTIONAL_MODULES[@]}"; do
    IFS='|' read -r mod pretty ver <<<"${spec}"
    try_import "${mod}" "${pretty}" "${ver}" 0 || true
  done

  # numpy<->torch ABI sanity: torch must be able to bridge a numpy array.
  if "${PY}" -c "import torch,numpy; torch.from_numpy(numpy.zeros(1))" 2>/dev/null; then
    pass "torch<->numpy ABI bridge OK"
  else
    fail "torch.from_numpy failed (numpy/torch ABI mismatch)"
  fi

  smoke_summary
}

main "$@"
