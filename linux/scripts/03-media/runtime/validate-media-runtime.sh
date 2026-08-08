#!/usr/bin/env bash
set -euo pipefail

if [ -f /opt/scripts/core/cross-env.sh ]; then
  # shellcheck disable=SC1091
  source /opt/scripts/core/cross-env.sh   # defines cross_build_is_active
fi

ARTIFACTS=(
  "${GSTREAMER_PREFIX:-/opt/gstreamer}/bin/gst-launch-1.0"
  "${LIBCAMERA_PREFIX:-/opt/libcamera}/bin/cam"
  "${FFMPEG_PREFIX:-/opt/ffmpeg}/bin/ffmpeg"
)

# _VMR_MA: Debian multiarch triplet — meson installs libcamera (and friends)
# under lib/<triplet>/, which this list previously did NOT cover. The resolver
# then declared the build's OWN libcamera libs "missing" and apt-installed
# Ubuntu's older libcamera0.7 as a shadow copy next to the source-built one —
# a false-positive "repair" that undercut the LIBCAMERA_VERSION pin.
_VMR_MA="$(dpkg-architecture -qDEB_HOST_MULTIARCH 2>/dev/null || true)"
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
if [ -n "${_VMR_MA}" ]; then
  LIB_DIRS+=(
    "${GSTREAMER_PREFIX:-/opt/gstreamer}/lib/${_VMR_MA}"
    "${LIBCAMERA_PREFIX:-/opt/libcamera}/lib/${_VMR_MA}"
    "${FFMPEG_PREFIX:-/opt/ffmpeg}/lib/${_VMR_MA}"
    "/opt/opencv5/lib/${_VMR_MA}"
    "/usr/local/lib/${_VMR_MA}"
  )
fi

# Return 0 if <so_name> resolves under LIB_DIRS, the standard lib dirs, or the
# ldconfig cache; 1 otherwise. DRYs the identical scan used by
# find_missing_needed and scan_plugin_directory.
so_name_resolvable() {
  local so_name="$1" dir
  for dir in "${LIB_DIRS[@]}" /usr/lib /lib /usr/lib/*-linux-gnu* /usr/local/lib/*-linux-gnu*; do
    [ -d "${dir}" ] || continue
    [ -f "${dir}/${so_name}" ] && return 0
  done
  ldconfig -p 2>/dev/null | grep -qF " ${so_name} " && return 0
  return 1
}

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
  echo "WARNING: so-package-map.txt not found; continuing with an empty known-so map (dpkg-query/apt-cache lookups only)" >&2
}

find_missing_needed() {
  local binary="$1"
  local missing=()

  [ -f "${binary}" ] || [ -L "${binary}" ] || { echo "WARNING: ${binary} not found, skipping" >&2; return 0; }

  echo "Checking: ${binary}" >&2

  local so_name
  while IFS= read -r so_name; do
    [ -n "${so_name}" ] || continue
    if ! so_name_resolvable "${so_name}"; then
      echo "  MISSING: ${so_name}" >&2
      missing+=("${so_name}")
    fi
  done < <(objdump -p "${binary}" 2>/dev/null | awk '/NEEDED/ {print $2}')

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
    while IFS= read -r so_name; do
      [ -n "${so_name}" ] || continue
      if ! so_name_resolvable "${so_name}"; then
        missing_all+=("${so_name}")
      fi
    done < <(objdump -p "${p}" 2>/dev/null | awk '/NEEDED/ {print $2}')
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
  # Deliberately NO exit here. The ELF architecture gate below must run on
  # clean scans too: NEEDED sonames resolve by NAME, so a wrong-arch ffmpeg
  # scans perfectly clean — the early `exit 0` this replaced made the
  # wrong-arch check dead code on every healthy build.
else

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
    echo "to so-package-map.txt (next to validate-media-runtime.sh)."
  else
    echo "All dependencies resolved after package install."
  fi
fi

if [ ${#STILL_MISSING[@]} -gt 0 ]; then
  echo ""
  echo "=== WARNING: ${#STILL_MISSING[@]} dependencies have no known apt package ==="
  printf '  %s\n' "${STILL_MISSING[@]}"
  echo "Add entries to so-package-map.txt (next to validate-media-runtime.sh)."
fi

fi  # end of the dirty-scan resolution branch — ELF validation runs either way

# ---------------------------------------------------------------------------
# ELF architecture validation — verify key binaries match the target arch
# ---------------------------------------------------------------------------
echo ""
echo "=== ELF Architecture Validation ==="

target_arch="${TARGET_ARCH:-${TARGETARCH:-amd64}}"
case "${target_arch}" in
  amd64)   elf_machine_grep="X86-64" ;;
  arm64)   elf_machine_grep="AArch64" ;;
  riscv64) elf_machine_grep="RISC-V" ;;
  *)       elf_machine_grep="" ;;
esac

# Directories that contain intentionally foreign-arch vendor binaries
# (Qualcomm QNN, SNPE, MediaTek NeuroPilot, etc.). These are shipped as-is
# and should NOT be flagged as ELF architecture mismatches.
VENDOR_ARCH_SKIP_PATTERNS=(
  "libQnn"
  "libSnpe"
  "libSNPE"
  "libhta_hexagon"
  "libneuronusdk"
  "libcalculator"
  "libCalculator"
  "libPyBackend"
  "libPyIr"
  "libPyNet"
  "libPlatformValidator"
  "libGenie"
  "libDlModelTools"
  "libatomic.so"
)

is_vendor_binary() {
  local basename="$1"
  local pattern
  for pattern in "${VENDOR_ARCH_SKIP_PATTERNS[@]}"; do
    case "${basename}" in
      *"${pattern}"*) return 0 ;;
    esac
  done
  return 1
}

core_mismatches=0
so_mismatches=0
if [ -n "${elf_machine_grep}" ] && command -v readelf >/dev/null 2>&1; then
  # CORE media binaries — never vendor, so a wrong arch here is always a genuine
  # defect. These drive the FATAL gate below.
  elf_binaries=(
    "${GSTREAMER_PREFIX:-/opt/gstreamer}/bin/gst-launch-1.0"
    "${GSTREAMER_PREFIX:-/opt/gstreamer}/bin/gst-inspect-1.0"
    "${FFMPEG_PREFIX:-/opt/ffmpeg}/bin/ffmpeg"
    "${FFMPEG_PREFIX:-/opt/ffmpeg}/bin/ffprobe"
  )
  for bin in "${elf_binaries[@]}"; do
    [ -f "${bin}" ] || continue
    elf_machine="$(LC_ALL=C readelf -h "${bin}" 2>/dev/null | sed -n 's/^[[:space:]]*Machine:[[:space:]]*//p' | head -n1)"
    case "${elf_machine}" in
      *"${elf_machine_grep}"*)
        echo "  OK: $(basename "${bin}") ELF machine=${elf_machine}" >&2
        ;;
      *)
        echo "  MISMATCH: $(basename "${bin}") ELF machine=${elf_machine} != expected ${elf_machine_grep} (arch=${target_arch})" >&2
        core_mismatches=$((core_mismatches + 1))
        ;;
    esac
  done
  # Shared-object sweep over LIB_DIRS is ADVISORY only. These dirs also hold
  # intentionally foreign-arch vendor SDKs (Qualcomm QNN/QAIRT libQairt*/libPyQnn*/
  # libDlContainerPy/libqnn-*, Hexagon DSP6 skels, MediaTek NeuroPilot, …) whose
  # names the VENDOR_ARCH_SKIP_PATTERNS list cannot exhaustively enumerate — so
  # treating a .so mismatch as fatal would abort on legitimately-bundled vendor
  # libs (it did: 33 QAIRT/QNN libs on the amd64 image). Report, do not fail.
  for so_dir in "${LIB_DIRS[@]}"; do
    [ -d "${so_dir}" ] || continue
    for so in "${so_dir}"/*.so "${so_dir}"/*.so.*; do
      [ -f "${so}" ] || continue
      _so_base="$(basename "${so}")"
      is_vendor_binary "${_so_base}" && continue
      # `|| true`: readelf exits 1 on non-ELF *.so files (GNU-ld linker scripts
      # live in these dirs) and pipefail would abort the whole validator; the
      # `""` case arm below is the intended handler for exactly that.
      elf_machine="$(LC_ALL=C readelf -h "${so}" 2>/dev/null | sed -n 's/^[[:space:]]*Machine:[[:space:]]*//p' | head -n1 || true)"
      case "${elf_machine}" in
        *"${elf_machine_grep}"*) ;;
        "") continue ;;
        *)
          echo "  MISMATCH (advisory, may be vendor): ${_so_base} ELF machine=${elf_machine} != expected ${elf_machine_grep}" >&2
          so_mismatches=$((so_mismatches + 1))
          ;;
      esac
    done
  done
else
  echo "  SKIP: readelf not available or unknown arch ${target_arch}" >&2
fi

# A wrong-arch CORE binary (ffmpeg/ffprobe/gst-launch/gst-inspect) is a genuine
# host-vs-target-triple defect — the exact class this build fights — and is never
# a vendor binary, so fail loud on it. The .so sweep stays advisory (see above);
# escape hatch MEDIA_ELF_MISMATCH_FATAL=0 downgrades the core gate to a warning.
[ "${so_mismatches}" -gt 0 ] && echo "  NOTE: ${so_mismatches} advisory .so ELF mismatch(es) (likely bundled vendor SDKs; not failing)" >&2
if [ "${core_mismatches}" -gt 0 ]; then
  if [ "${MEDIA_ELF_MISMATCH_FATAL:-1}" = "1" ]; then
    echo "  FAIL: ${core_mismatches} CORE media binary ELF mismatch(es) for target ${target_arch} — wrong-arch artifact(s) present" >&2
    exit 1
  fi
  echo "  WARN: ${core_mismatches} core ELF mismatch(es) (MEDIA_ELF_MISMATCH_FATAL=0; not failing)" >&2
fi

# ---------------------------------------------------------------------------
# QEMU-based cross-arch binary smoke (only when cross-compiling)
# ---------------------------------------------------------------------------
if cross_build_is_active 2>/dev/null && command -v cross_target_qemu_runner >/dev/null 2>&1; then
  echo ""
  echo "=== QEMU Cross-Arch Binary Smoke ==="
  qemu_runner="$(cross_target_qemu_runner 2>/dev/null || true)"
  if [ -n "${qemu_runner}" ] && [ -x "${qemu_runner}" ]; then
    for bin in "${ARTIFACTS[@]}"; do
      [ -f "${bin}" ] || continue
      if "${qemu_runner}" "${bin}" --help >/dev/null 2>&1; then
        echo "  OK: ${qemu_runner} $(basename "${bin}") --help" >&2
      else
        echo "  WARN: ${qemu_runner} $(basename "${bin}") --help failed (may be expected for cross builds without full sysroot)" >&2
      fi
    done
  else
    echo "  SKIP: qemu user-mode emulator not found (install qemu-user-static)" >&2
  fi
fi

echo ""
echo "=== Validation complete ==="
