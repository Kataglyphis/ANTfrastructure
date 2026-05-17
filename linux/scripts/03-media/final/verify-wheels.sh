#!/usr/bin/env bash
set -euo pipefail

WHEELS_DIR="${WHEELS_DIR:-/opt/wheels}"

PY_TAG="cp$(python -c 'import sys; print(f"{sys.version_info.major}{sys.version_info.minor}")')"
echo "Verifying wheels in ${WHEELS_DIR} have the correct tag (${PY_TAG} or generic)..."

shopt -s nullglob
for wheel in "${WHEELS_DIR}"/*.whl; do
  case "$(basename "${wheel}")" in
    *"${PY_TAG}-"*|*py2.py3-none-*|*py3-none-*) ;;
    *)
      echo "Error: Wheel ${wheel} does not have the correct tag (expected ${PY_TAG}- or generic py3)"
      exit 1
      ;;
  esac
done
shopt -u nullglob
