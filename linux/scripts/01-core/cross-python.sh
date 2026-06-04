#!/usr/bin/env bash
# cross-env.sh - shared helpers for amd64-hosted target builds

# cross-python.sh - Python cross-compilation helpers
# Sourced by cross-env.sh after cross-env-core.sh

host_python_bin() {
  if [ -n "${MEDIA_HOST_PYTHON:-}" ] && [ -x "${MEDIA_HOST_PYTHON}" ]; then
    printf '%s' "${MEDIA_HOST_PYTHON}"
    return 0
  fi

  if [ -n "${UV_PYTHON:-}" ] && [ -x "${UV_PYTHON}" ]; then
    printf '%s' "${UV_PYTHON}"
    return 0
  fi

  if [ -n "${VIRTUAL_ENV:-}" ] && [ -x "${VIRTUAL_ENV}/bin/python" ]; then
    printf '%s' "${VIRTUAL_ENV}/bin/python"
    return 0
  fi

  if [ -n "${PYTHON_MAJOR_MINOR:-}" ] && [ -x "/usr/local/bin/python${PYTHON_MAJOR_MINOR}" ]; then
    printf '%s' "/usr/local/bin/python${PYTHON_MAJOR_MINOR}"
    return 0
  fi

  if [ -n "${PYTHON_VERSION:-}" ] && command -v version_major_minor >/dev/null 2>&1; then
    local python_mm=""
    python_mm="$(version_major_minor "${PYTHON_VERSION}" 2>/dev/null || true)"
    if [ -n "${python_mm}" ] && [ -x "/usr/local/bin/python${python_mm}" ]; then
      printf '%s' "/usr/local/bin/python${python_mm}"
      return 0
    fi
  fi

  command -v python3 2>/dev/null || command -v python 2>/dev/null || return 1
}

host_python_major_minor() {
  local python_bin

  if [ -n "${PYTHON_MAJOR_MINOR:-}" ]; then
    printf '%s' "${PYTHON_MAJOR_MINOR}"
    return 0
  fi

  python_bin="$(host_python_bin)" || return 1
  "${python_bin}" -c 'import sys; print(f"{sys.version_info.major}.{sys.version_info.minor}")'
}

cross_target_python_stage_root() {
  local target_arch=""

  target_arch="$(cross_require_single_target_arch "${1:-${TARGET_ARCH:-${TARGETARCH:-${ARCH:-}}}}" "target Python staging")" || return 1
  printf '%s' "${PYTHON_CROSS_STAGE_ROOT:-/opt/python-cross}/${target_arch}"
}

cross_target_python_active_stage_root() {
  local requested_arch="${1:-${TARGET_ARCH:-${TARGETARCH:-${ARCH:-}}}}"
  local active_root="${PYTHON_CROSS_ACTIVE_ROOT:-/opt/python-target}"
  local stage_root=""

  if [ -d "${active_root}/usr/local" ]; then
    printf '%s' "${active_root}"
    return 0
  fi

  stage_root="$(cross_target_python_stage_root "${requested_arch}" 2>/dev/null || true)"
  if [ -n "${stage_root}" ] && [ -d "${stage_root}/usr/local" ]; then
    printf '%s' "${stage_root}"
    return 0
  fi

  return 1
}

cross_target_python_root() {
  local active_root=""

  active_root="$(cross_target_python_active_stage_root "$@" 2>/dev/null || true)"
  if [ -n "${active_root}" ] && [ -d "${active_root}/usr/local" ]; then
    printf '%s' "${active_root}/usr/local"
    return 0
  fi

  return 1
}

cross_target_python_major_minor() {
  if [ -n "${TARGET_PYTHON_MAJOR_MINOR:-}" ]; then
    printf '%s' "${TARGET_PYTHON_MAJOR_MINOR}"
    return 0
  fi

  if [ -n "${PYTHON_MAJOR_MINOR:-}" ]; then
    printf '%s' "${PYTHON_MAJOR_MINOR}"
    return 0
  fi

  host_python_major_minor
}

cross_target_python_include_dir() {
  local python_mm
  local python_root=""
  local candidate

  python_mm="$(cross_target_python_major_minor)" || return 1
  python_root="$(cross_target_python_root "$@" 2>/dev/null || true)"

  for candidate in \
    "${python_root:+${python_root}/include/python${python_mm}}" \
    "/usr/local/include/python${python_mm}" \
    "/usr/include/python${python_mm}"; do
    [ -n "${candidate}" ] || continue
    [ -d "${candidate}" ] && {
      printf '%s' "${candidate}"
      return 0
    }
  done

  return 1
}

cross_target_python_arch_include_dir() {
  local python_mm
  local triplet
  local python_root=""
  local candidate

  python_mm="$(cross_target_python_major_minor)" || return 1
  triplet="$(cross_target_triplet 2>/dev/null || true)"
  python_root="$(cross_target_python_root "$@" 2>/dev/null || true)"

  for candidate in \
    "${python_root:+${python_root}/include/${triplet}/python${python_mm}}" \
    "${python_root:+${python_root}/include/python${python_mm}}" \
    "/usr/local/include/${triplet}/python${python_mm}" \
    "/usr/include/${triplet}/python${python_mm}" \
    "/usr/local/include/python${python_mm}" \
    "/usr/include/python${python_mm}"; do
    [ -n "${candidate}" ] || continue
    [ -d "${candidate}" ] && {
      printf '%s' "${candidate}"
      return 0
    }
  done

  return 1
}

cross_target_python_libdir() {
  local triplet
  local python_root=""
  local candidate

  python_root="$(cross_target_python_root "$@" 2>/dev/null || true)"
  triplet="$(cross_target_triplet 2>/dev/null || true)"

  for candidate in \
    "${python_root:+${python_root}/lib}" \
    "/usr/local/lib" \
    "/usr/lib/${triplet}" \
    "/usr/lib"; do
    [ -n "${candidate}" ] || continue
    [ -d "${candidate}" ] && {
      printf '%s' "${candidate}"
      return 0
    }
  done

  return 1
}

cross_target_python_library() {
  local python_mm
  local triplet
  local python_root=""
  local candidate

  python_mm="$(cross_target_python_major_minor)" || return 1
  triplet="$(cross_target_triplet 2>/dev/null || true)"
  python_root="$(cross_target_python_root "$@" 2>/dev/null || true)"

  for candidate in \
    "${python_root:+${python_root}/lib/libpython${python_mm}.so}" \
    "${python_root:+${python_root}/lib/libpython${python_mm}.so.1.0}" \
    "/usr/local/lib/libpython${python_mm}.so" \
    "/usr/local/lib/libpython${python_mm}.so.1.0" \
    "/usr/lib/${triplet}/libpython${python_mm}.so" \
    "/usr/lib/${triplet}/libpython${python_mm}.so.1.0" \
    "/usr/lib/libpython${python_mm}.so" \
    "/usr/lib/libpython${python_mm}.so.1.0"; do
    [ -f "${candidate}" ] && {
      printf '%s' "${candidate}"
      return 0
    }
  done

  return 1
}

cross_target_python_pkgconfig_dir() {
  local triplet
  local python_root=""
  local candidate

  python_root="$(cross_target_python_root "$@" 2>/dev/null || true)"
  triplet="$(cross_target_triplet 2>/dev/null || true)"

  for candidate in \
    "${python_root:+${python_root}/lib/pkgconfig}" \
    "/usr/local/lib/pkgconfig" \
    "/usr/lib/${triplet}/pkgconfig" \
    "/usr/lib/pkgconfig"; do
    [ -n "${candidate}" ] || continue
    [ -d "${candidate}" ] && {
      printf '%s' "${candidate}"
      return 0
    }
  done

  return 1
}

cross_target_python_pc() {
  local python_mm
  local pkgconfig_dir

  python_mm="$(cross_target_python_major_minor)" || return 1
  pkgconfig_dir="$(cross_target_python_pkgconfig_dir)" || return 1
  printf '%s' "${pkgconfig_dir}/python-${python_mm}.pc"
}

cross_target_python_embed_pc() {
  local python_mm
  local pkgconfig_dir

  python_mm="$(cross_target_python_major_minor)" || return 1
  pkgconfig_dir="$(cross_target_python_pkgconfig_dir)" || return 1
  printf '%s' "${pkgconfig_dir}/python-${python_mm}-embed.pc"
}

cross_target_python_dev_ready() {
  local include_dir
  local arch_include_dir
  local pc_file
  local embed_pc_file

  include_dir="$(cross_target_python_include_dir)" || return 1
  arch_include_dir="$(cross_target_python_arch_include_dir)" || return 1
  pc_file="$(cross_target_python_pc)" || return 1
  embed_pc_file="$(cross_target_python_embed_pc)" || return 1

  [ -d "${include_dir}" ] || return 1
  [ -d "${arch_include_dir}" ] || return 1
  [ -f "${pc_file}" ] || return 1
  [ -f "${embed_pc_file}" ] || return 1
  cross_target_python_library >/dev/null
}
