#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

if [ -f /opt/scripts/core/common.sh ]; then
  # shellcheck disable=SC1091
  source /opt/scripts/core/common.sh
fi

WHEELS_DIR="${WHEELS_DIR:-/opt/wheels}"

PY_TAG="cp$(python -c 'import sys; print(f"{sys.version_info.major}{sys.version_info.minor}")')"

if declare -F info >/dev/null 2>&1; then
  info "Verifying wheels in ${WHEELS_DIR} have the correct tag (${PY_TAG} or generic)..."
else
  echo "Verifying wheels in ${WHEELS_DIR} have the correct tag (${PY_TAG} or generic)..."
fi

FAILURES=0
shopt -s nullglob
for wheel in "${WHEELS_DIR}"/*.whl; do
  case "$(basename "${wheel}")" in
    *"${PY_TAG}-"*|*py2.py3-none-*|*py3-none-*) ;;
    *)
      if declare -F err >/dev/null 2>&1; then
        err "Wheel $(basename "${wheel}") has incorrect tag (expected ${PY_TAG}- or generic py3)"
      else
        echo "ERROR: Wheel $(basename "${wheel}") has incorrect tag (expected ${PY_TAG}- or generic py3)" >&2
        exit 1
      fi
      ;;
  esac
done
shopt -u nullglob

if declare -F info >/dev/null 2>&1; then
  info "All wheel tags verified"
else
  echo "All wheel tags verified"
fi
