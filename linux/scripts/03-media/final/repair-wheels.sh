#!/usr/bin/env bash
set -euo pipefail

if [ -f /opt/scripts/core/cross-env.sh ]; then
  # shellcheck disable=SC1091
  source /opt/scripts/core/cross-env.sh
fi

if command -v cross_build_enabled >/dev/null 2>&1 && cross_build_enabled; then
  echo "Skipping auditwheel repair for foreign-arch cross builds"
  exit 0
fi

if ! command -v cross_build_enabled >/dev/null 2>&1 && [ "${BUILD_MODE:-native}" = "cross" ]; then
  echo "Skipping auditwheel repair in cross mode"
  exit 0
fi

WHEELS_DIR="${WHEELS_DIR:-/opt/wheels}"
REPAIRED_WHEELS_DIR="${WHEELS_DIR}/repaired"

uv pip install auditwheel patchelf
runtime_ld_path="$(find /opt /usr/local -type d \( -name 'lib*' -o -name '*linux-gnu*' \) | sort -u | paste -sd ':' -)"
export LD_LIBRARY_PATH="${runtime_ld_path}:${LD_LIBRARY_PATH:-}"

mkdir -p "${REPAIRED_WHEELS_DIR}"
shopt -s nullglob
for wheel in "${WHEELS_DIR}"/*.whl; do
  case "$(basename "${wheel}")" in
    *none-any.whl)
      cp "${wheel}" "${REPAIRED_WHEELS_DIR}/"
      ;;
    *)
      auditwheel repair "${wheel}" -w "${REPAIRED_WHEELS_DIR}/" || cp "${wheel}" "${REPAIRED_WHEELS_DIR}/"
      ;;
  esac
done
shopt -u nullglob

rm -f "${WHEELS_DIR}"/*.whl
shopt -s nullglob
mv "${REPAIRED_WHEELS_DIR}"/*.whl "${WHEELS_DIR}/"
shopt -u nullglob
rmdir "${REPAIRED_WHEELS_DIR}" 2>/dev/null || true
