#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

if [ -f /opt/scripts/core/cross-env.sh ]; then
  # shellcheck disable=SC1091
  source /opt/scripts/core/cross-env.sh
fi

WHEELS_DIR="${WHEELS_DIR:-/opt/wheels}"

if cross_build_is_active; then
  target_arch="$(cross_target_arch 2>/dev/null || true)"
  [ -n "${target_arch}" ] || target_arch="${TARGET_ARCH:-}"
  if [ -n "${target_arch}" ] && command -v arch_linux_platform_tag_for >/dev/null 2>&1; then
    platform_tag="$(arch_linux_platform_tag_for "${target_arch}")"
    if [ -n "${platform_tag}" ]; then
      echo "Retagging cross-built wheels for platform: ${platform_tag}"
      shopt -s nullglob
      for wheel in "${WHEELS_DIR}"/*.whl; do
        wheel_name="$(basename "${wheel}")"
        case "${wheel_name}" in
          *-none-any.whl|*"${platform_tag}"*.whl)
            continue
            ;;
        esac
        uv run python -m wheel tags --remove --platform-tag "${platform_tag}" "${wheel}" && \
          echo "Retagged: ${wheel_name}" || \
          echo "Failed to retag: ${wheel_name}"
      done
      shopt -u nullglob
    fi
  fi
  echo "Cross-build wheel retagging complete"
  exit 0
fi

if ! command -v cross_build_enabled >/dev/null 2>&1 && [ "${BUILD_MODE:-native}" = "cross" ]; then
  echo "Skipping auditwheel repair in cross mode"
  exit 0
fi

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
