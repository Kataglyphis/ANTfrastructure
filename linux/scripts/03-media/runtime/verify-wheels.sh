#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

if [ -f /opt/scripts/core/common.sh ]; then
  # shellcheck disable=SC1091
  source /opt/scripts/core/common.sh
fi

# WHEELS_DIR comes from the canonical media-env.sh (sibling of this script).
_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${_SCRIPT_DIR}/media-env.sh"

PY_MAJOR="$(python -c 'import sys; print(sys.version_info.major)')"
PY_MINOR="$(python -c 'import sys; print(sys.version_info.minor)')"
PY_TAG="cp${PY_MAJOR}${PY_MINOR}"

if declare -F info >/dev/null 2>&1; then
  info "Verifying wheels in ${WHEELS_DIR} have the correct tag (${PY_TAG} or generic)..."
else
  echo "Verifying wheels in ${WHEELS_DIR} have the correct tag (${PY_TAG} or generic)..."
fi

shopt -s nullglob
for wheel in "${WHEELS_DIR}"/*.whl; do
  base="$(basename "${wheel}")"
  # Accept: exact container interpreter tag (cpXY-), or pure-python (py3-none / py2.py3-none).
  case "${base}" in
    *"${PY_TAG}-"*|*py2.py3-none-*|*py3-none-*) continue ;;
  esac
  # Accept stable-ABI (abi3) wheels whose interpreter floor is <= the container's.
  # abi3 is the CPython stable ABI: a cp3Y-abi3 wheel is forward-compatible and
  # installs/runs on cp3Z for any Z >= Y. This is exactly how IREE ships its
  # iree_base_compiler / iree_base_runtime wheels (cp312-abi3), including the
  # riscv64 cross-build on container Python 3.14. Same tag as the amd64/arm64 PyPI
  # IREE wheels — abi3 is not a defect, it's the intended, correct packaging.
  if [[ "${base}" =~ -cp([0-9])([0-9]+)-abi3- ]]; then
    _w_major="${BASH_REMATCH[1]}"
    _w_minor="${BASH_REMATCH[2]}"
    if [ "${_w_major}" = "${PY_MAJOR}" ] && [ "${_w_minor}" -le "${PY_MINOR}" ]; then
      continue
    fi
  fi
  # Otherwise the tag is genuinely incompatible with the container interpreter.
  if declare -F err >/dev/null 2>&1; then
    err "Wheel ${base} has incorrect tag (expected ${PY_TAG}-, a cp3<=${PY_MINOR}-abi3 stable-ABI, or generic py3)"
  else
    echo "ERROR: Wheel ${base} has incorrect tag (expected ${PY_TAG}-, a cp3<=${PY_MINOR}-abi3 stable-ABI, or generic py3)" >&2
    exit 1
  fi
done
shopt -u nullglob

if declare -F info >/dev/null 2>&1; then
  info "All wheel tags verified"
else
  echo "All wheel tags verified"
fi
