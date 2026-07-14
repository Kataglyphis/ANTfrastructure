#!/usr/bin/env bash
set -euo pipefail
# configure-gcc-env.sh - Environment configuration for GCC installation.
# Called from build-gcc.sh after GCC is installed.

_append_env_var() {
  local var_name="$1" var_value="$2" env_file="$3"

  [ -f "${env_file}" ] || return 0

  local existing
  existing=$(grep -E "^${var_name}=" "${env_file}" 2>/dev/null | cut -d= -f2- | tr -d '"' || echo "")
  existing=$(echo "$existing" | sed -e "s|${var_value}:||g" -e "s|:${var_value}||g")
  if [ -n "$existing" ]; then
    existing="${var_value}:${existing}"
  else
    existing="${var_value}"
  fi
  ${SUDO:-} sed -i "/^${var_name}=/d" "${env_file}" 2>/dev/null || true
  echo "${var_name}=\"${existing}\"" | ${SUDO:-} tee -a "${env_file}" >/dev/null
}

# 6) Add library path to loader and run ldconfig
_gcc_env_ldconfig() {
  local PREFIX="$1" GCC_VERSION="$2" SUDO="${3:-}"
  local CONF_FILE="/etc/ld.so.conf.d/gcc-${GCC_VERSION}.conf"

  ${SUDO} sh -c ": > \"${CONF_FILE}\""

  if [ -d "${PREFIX}/lib64" ]; then
    echo "${PREFIX}/lib64" | ${SUDO} tee -a "${CONF_FILE}" >/dev/null
  fi
  if [ -d "${PREFIX}/lib" ]; then
    echo "${PREFIX}/lib" | ${SUDO} tee -a "${CONF_FILE}" >/dev/null
  fi

  if [ -s "${CONF_FILE}" ]; then
    echo "Adding GCC runtime libs from ${PREFIX} to loader path and running ldconfig..."
    ${SUDO} ldconfig
  else
    ${SUDO} rm -f "${CONF_FILE}"
    echo "No GCC lib directories found under ${PREFIX}; skipping ldconfig step." >&2
  fi
}

# 6b) Add pkg-config path configuration
_gcc_env_pkgconfig() {
  local PREFIX="$1" GCC_VERSION="$2" SUDO="${3:-}"
  echo "Configuring PKG_CONFIG_PATH..."
  local PKG_CONFIG_DIR="/etc/profile.d"
  local PKG_CONFIG_FILE="${PKG_CONFIG_DIR}/gcc-${GCC_VERSION}-pkgconfig.sh"

  if [ -d "${PREFIX}/lib64/pkgconfig" ] || [ -d "${PREFIX}/lib/pkgconfig" ]; then
    ${SUDO} sh -c "cat > \"${PKG_CONFIG_FILE}\"" <<EOF
# GCC ${GCC_VERSION} pkg-config path
if [ -d "${PREFIX}/lib64/pkgconfig" ]; then
  export PKG_CONFIG_PATH="${PREFIX}/lib64/pkgconfig:\${PKG_CONFIG_PATH}"
fi
if [ -d "${PREFIX}/lib/pkgconfig" ]; then
  export PKG_CONFIG_PATH="${PREFIX}/lib/pkgconfig:\${PKG_CONFIG_PATH}"
fi
EOF
    ${SUDO} chmod 644 "${PKG_CONFIG_FILE}"
    echo "Created ${PKG_CONFIG_FILE}"
  else
    echo "No pkg-config directories found; skipping PKG_CONFIG_PATH setup."
  fi
}

# 6c) Add to system PATH
_gcc_env_path() {
  local PREFIX="$1" GCC_VERSION="$2" SUDO="${3:-}"
  echo "Configuring PATH..."
  local PATH_FILE="/etc/profile.d/gcc-${GCC_VERSION}-path.sh"
  ${SUDO} sh -c "cat > \"${PATH_FILE}\"" <<EOF
# GCC ${GCC_VERSION} binaries
export PATH="${PREFIX}/bin:\${PATH}"
EOF
  ${SUDO} chmod 644 "${PATH_FILE}"
  echo "Created ${PATH_FILE}"
}

# 6d) For Docker: Also add to /etc/environment for non-interactive shells.
# SUDO is declared local so _append_env_var's ${SUDO:-} resolves to it (as it did
# when this block lived inline in _configure_gcc_environment).
_gcc_env_docker_environment() {
  local PREFIX="$1" SUDO="${2:-}"
  echo "Adding GCC paths to /etc/environment for Docker compatibility..."
  if [ -f /etc/environment ]; then
    _append_env_var PATH "${PREFIX}/bin" /etc/environment
    if [ -d "${PREFIX}/lib64/pkgconfig" ] || [ -d "${PREFIX}/lib/pkgconfig" ]; then
      local pkg_paths=""
      [ -d "${PREFIX}/lib64/pkgconfig" ] && pkg_paths="${PREFIX}/lib64/pkgconfig"
      if [ -d "${PREFIX}/lib/pkgconfig" ]; then
        [ -n "$pkg_paths" ] && pkg_paths="${pkg_paths}:${PREFIX}/lib/pkgconfig" || pkg_paths="${PREFIX}/lib/pkgconfig"
      fi
      [ -n "$pkg_paths" ] && _append_env_var PKG_CONFIG_PATH "$pkg_paths" /etc/environment
    fi
    local ld_paths=""
    [ -d "${PREFIX}/lib64" ] && ld_paths="${PREFIX}/lib64"
    if [ -d "${PREFIX}/lib" ]; then
      [ -n "$ld_paths" ] && ld_paths="${ld_paths}:${PREFIX}/lib" || ld_paths="${PREFIX}/lib"
    fi
    [ -n "$ld_paths" ] && _append_env_var LD_LIBRARY_PATH "$ld_paths" /etc/environment
    echo "Updated /etc/environment with GCC paths"
  else
    echo "WARNING: /etc/environment not found; skipping Docker-friendly environment setup"
  fi
}

# 6e) Configure man pages
_gcc_env_manpages() {
  local PREFIX="$1" SUDO="${2:-}"
  echo "Configuring man pages..."
  local MANPATH_FILE="/etc/manpath.config"
  if [ -d "${PREFIX}/share/man" ] && [ -f "${MANPATH_FILE}" ]; then
    if ! grep -q "${PREFIX}/share/man" "${MANPATH_FILE}" 2>/dev/null; then
      echo "MANPATH_MAP ${PREFIX}/bin ${PREFIX}/share/man" | ${SUDO} tee -a "${MANPATH_FILE}" >/dev/null
      echo "Added man page path to ${MANPATH_FILE}"
    else
      echo "Man page path already exists in ${MANPATH_FILE}"
    fi
  elif [ -d "${PREFIX}/share/man" ]; then
    echo "MANPATH_FILE not found at ${MANPATH_FILE}; skipping man page configuration."
  fi
}

_configure_gcc_environment() {
  local PREFIX="$1"
  local GCC_VERSION="$2"
  local SUDO="${3:-}"

  _gcc_env_ldconfig          "${PREFIX}" "${GCC_VERSION}" "${SUDO}"
  _gcc_env_pkgconfig         "${PREFIX}" "${GCC_VERSION}" "${SUDO}"
  _gcc_env_path              "${PREFIX}" "${GCC_VERSION}" "${SUDO}"
  _gcc_env_docker_environment "${PREFIX}" "${SUDO}"
  _gcc_env_manpages          "${PREFIX}" "${SUDO}"
}
