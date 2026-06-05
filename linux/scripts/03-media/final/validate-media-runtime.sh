#!/usr/bin/env bash
set -euo pipefail

if [ -f /opt/scripts/core/cross-env.sh ]; then
  # shellcheck disable=SC1091
  source /opt/scripts/core/cross-env.sh
fi

ARTIFACTS=(
  "${GSTREAMER_PREFIX:-/opt/gstreamer}/bin/gst-launch-1.0"
  "${LIBCAMERA_PREFIX:-/opt/libcamera}/bin/cam"
  "${FFMPEG_PREFIX:-/opt/ffmpeg}/bin/ffmpeg"
)

LIB_DIRS=(
  "${GSTREAMER_PREFIX:-/opt/gstreamer}/lib"
  "${GSTREAMER_PREFIX:-/opt/gstreamer}/lib/multiarch"
  "${LIBCAMERA_PREFIX:-/opt/libcamera}/lib"
  "${LIBCAMERA_PREFIX:-/opt/libcamera}/lib64"
  "${FFMPEG_PREFIX:-/opt/ffmpeg}/lib"
  "/opt/opencv5/lib"
  "/usr/local/lib"
  "/usr/local/lib/onnxruntime-cpu/lib"
)

known_so_packages_load() {
  local map_file="${1:-${SCRIPT_DIR:-.}/so-package-map.txt}"
  if [ -f "${map_file}" ]; then
    while IFS=$'\t' read -r so_name pkg || [ -n "${so_name}" ]; do
      case "${so_name}" in
        ""|\#*) continue ;;
      esac
      KNOWN_SO_PACKAGES["${so_name}"]="${pkg}"
    done < "${map_file}"
    return 0
  fi
  return 1
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
declare -A KNOWN_SO_PACKAGES=()
known_so_packages_load || {
  echo "WARNING: so-package-map.txt not found, using embedded fallback map" >&2
}

find_missing_needed() {
  local binary="$1"
  local missing=()

  [ -f "${binary}" ] || [ -L "${binary}" ] || { echo "WARNING: ${binary} not found, skipping" >&2; return 0; }

  echo "Checking: ${binary}" >&2

  local so_name
  for so_name in $(objdump -p "${binary}" 2>/dev/null | awk '/NEEDED/ {print $2}'); do
    local found=false

    for dir in "${LIB_DIRS[@]}" /usr/lib /lib /usr/lib/*-linux-gnu* /usr/local/lib/*-linux-gnu*; do
      [ -d "${dir}" ] || continue
      if [ -f "${dir}/${so_name}" ]; then
        found=true
        break
      fi
    done

    if [ "${found}" = "false" ]; then
      if ldconfig -p 2>/dev/null | grep -qF " ${so_name} "; then
        found=true
      fi
    fi

    if [ "${found}" = "false" ]; then
      echo "  MISSING: ${so_name}" >&2
      missing+=("${so_name}")
    fi
  done

  if [ ${#missing[@]} -gt 0 ]; then
    printf '%s\n' "${missing[@]}"
  fi
}

resolve_package_for_so() {
  local so_name="$1"
  local pkg=""

  pkg="${KNOWN_SO_PACKAGES[${so_name}]:-}"

  if [ -n "${pkg}" ]; then
    echo "${pkg}"
    return 0
  fi

  pkg="$(dpkg-query -S "${so_name}" 2>/dev/null | head -1 | cut -d: -f1 || true)"

  if [ -n "${pkg}" ]; then
    echo "${pkg}"
    return 0
  fi

  local base_lib="${so_name%%.so*}"
  if apt-cache search "^${base_lib}[0-9]" 2>/dev/null | head -1 | grep -q .; then
    pkg="$(apt-cache search "^${base_lib}[0-9]" 2>/dev/null | head -1 | awk '{print $1}')"
    if [ -n "${pkg}" ]; then
      echo "${pkg}"
      return 0
    fi
  fi

  return 1
}

scan_plugin_directory() {
  local plugin_dir="$1"

  [ -d "${plugin_dir}" ] || return 0

  echo "Scanning plugins in: ${plugin_dir}" >&2

  local missing_all=()

  local p
  for p in "${plugin_dir}"/*.so; do
    [ -f "${p}" ] || continue

    local so_name
    for so_name in $(objdump -p "${p}" 2>/dev/null | awk '/NEEDED/ {print $2}'); do
      local found=false

      for dir in "${LIB_DIRS[@]}" /usr/lib /lib /usr/lib/*-linux-gnu* /usr/local/lib/*-linux-gnu*; do
        [ -d "${dir}" ] || continue
        if [ -f "${dir}/${so_name}" ]; then
          found=true
          break
        fi
      done

      if [ "${found}" = "false" ]; then
        if ldconfig -p 2>/dev/null | grep -qF " ${so_name} "; then
          found=true
        fi
      fi

      if [ "${found}" = "false" ]; then
        missing_all+=("${so_name}")
        break
      fi
    done
  done

  if [ ${#missing_all[@]} -gt 0 ]; then
    printf '%s\n' "Some plugins have missing deps:" "${missing_all[@]}" >&2
  fi

  if [ ${#missing_all[@]} -gt 0 ]; then
    printf '%s\n' "${missing_all[@]}"
  fi
}

uniq_nonempty_lines() {
  grep -v '^$' | sort -u || true
}

echo "=== Media Runtime Validation ==="

ALL_MISSING=()

for artifact in "${ARTIFACTS[@]}"; do
  mapfile -t missing_list < <(find_missing_needed "${artifact}")
  ALL_MISSING+=("${missing_list[@]}")
done

gst_plugin_dir="${GSTREAMER_PREFIX:-/opt/gstreamer}/lib/multiarch/gstreamer-1.0"
if [ -d "${gst_plugin_dir}" ]; then
  mapfile -t plugin_missing < <(scan_plugin_directory "${gst_plugin_dir}")
  ALL_MISSING+=("${plugin_missing[@]}")
fi

mapfile -t UNIQ_MISSING < <(printf '%s\n' "${ALL_MISSING[@]}" | uniq_nonempty_lines)

if [ ${#UNIQ_MISSING[@]} -eq 0 ]; then
  echo "All artifacts have their runtime dependencies satisfied."
  exit 0
fi

echo ""
echo "=== Resolving ${#UNIQ_MISSING[@]} missing dependencies ==="

PACKAGES_TO_INSTALL=()
STILL_MISSING=()

for so_name in "${UNIQ_MISSING[@]}"; do
  pkg="$(resolve_package_for_so "${so_name}" || true)"
  if [ -n "${pkg}" ]; then
    echo "  ${so_name} -> ${pkg}"
    PACKAGES_TO_INSTALL+=("${pkg}")
  else
    echo "  ${so_name} -> UNKNOWN (no apt package mapping found)"
    STILL_MISSING+=("${so_name}")
  fi
done

mapfile -t UNIQ_PKGS < <(printf '%s\n' "${PACKAGES_TO_INSTALL[@]}" | uniq_nonempty_lines)

if [ ${#UNIQ_PKGS[@]} -gt 0 ]; then
  echo ""
  echo "Installing ${#UNIQ_PKGS[@]} runtime packages..."

  if command -v cross_apt_update >/dev/null 2>&1; then
    cross_apt_update
  else
    apt-get update
  fi

  if command -v install_target_packages >/dev/null 2>&1; then
    DEBIAN_FRONTEND=noninteractive install_target_packages "${UNIQ_PKGS[@]}" || true
  else
    DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends "${UNIQ_PKGS[@]}" || true
  fi

  ldconfig

  echo ""
  echo "=== Re-checking after package install ==="
  REMAINING=()
  for artifact in "${ARTIFACTS[@]}"; do
    mapfile -t still_missing < <(find_missing_needed "${artifact}")
    REMAINING+=("${still_missing[@]}")
  done

  mapfile -t UNIQ_REMAINING < <(printf '%s\n' "${REMAINING[@]}" | uniq_nonempty_lines)

  if [ ${#UNIQ_REMAINING[@]} -gt 0 ]; then
    echo ""
    echo "=== WARNING: ${#UNIQ_REMAINING[@]} dependencies still unresolved ==="
    printf '  %s\n' "${UNIQ_REMAINING[@]}"
    echo ""
    echo "These libraries could not be found in any apt package. The artifacts"
    echo "that depend on them (and the plugins that load them) will fail at"
    echo "runtime. Review the build configuration or add package mappings"
    echo "to KNOWN_SO_PACKAGES in validate-media-runtime.sh."
  else
    echo "All dependencies resolved after package install."
  fi
fi

if [ ${#STILL_MISSING[@]} -gt 0 ]; then
  echo ""
  echo "=== WARNING: ${#STILL_MISSING[@]} dependencies have no known apt package ==="
  printf '  %s\n' "${STILL_MISSING[@]}"
  echo "Add entries to KNOWN_SO_PACKAGES in validate-media-runtime.sh."
fi

echo ""
echo "=== Validation complete ==="
