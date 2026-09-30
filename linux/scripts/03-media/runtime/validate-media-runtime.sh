#!/usr/bin/env bash
set -euo pipefail

if [ -f /opt/scripts/core/cross-env.sh ]; then
  # shellcheck disable=SC1091
  source /opt/scripts/core/cross-env.sh   # defines cross_build_is_active
fi

# Hard-require platform.sh's NEEDED walk: a silent fallback would gut the missing-deps scan.
_VMR_SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
for _vmr_platform in /opt/scripts/core/platform.sh "${_VMR_SELF_DIR}/../../01-core/platform.sh"; do
  if [ -f "${_vmr_platform}" ]; then
    # shellcheck disable=SC1090
    source "${_vmr_platform}"
    break
  fi
done
command -v elf_unresolved_needed >/dev/null 2>&1 \
  || { echo "FATAL: platform.sh (elf_needed_sonames/elf_unresolved_needed) not found" >&2; exit 1; }

ARTIFACTS=(
  "${GSTREAMER_PREFIX:-/opt/gstreamer}/bin/gst-launch-1.0"
  "${LIBCAMERA_PREFIX:-/opt/libcamera}/bin/cam"
  "${FFMPEG_PREFIX:-/opt/ffmpeg}/bin/ffmpeg"
)

# meson installs under lib/<triplet>; unlisted, the build's own libcamera looks missing and apt shadows it.
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
  # GEN1: genai prefix, a resolution root + arch sweep. docs/gen1-riscv64-genai.md
  "${ONNXRUNTIME_GENAI_OUTPUT_DIR:-/usr/local/lib/onnxruntime-genai}/lib"
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

known_so_packages_load() {
  local map_file="${1:-${SCRIPT_DIR:-.}/so-package-map.txt}"
  if [ -f "${map_file}" ]; then
    while IFS=$'\t' read -r so_name pkg || [ -n "${so_name}" ]; do
      case "${so_name}" in
        ""|\#*) continue ;;
      esac
      KNOWN_SO_PACKAGES["${so_name}"]="${pkg}"
      # Wildcard keys kept in file order: the assoc array is unordered.
      case "${so_name}" in
        *[*?[]*) KNOWN_SO_GLOBS+=("${so_name}") ;;
      esac
    done < "${map_file}"
    return 0
  fi
  return 1
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# ORT is chain-only (owner rule 2026-09-23): the resolver may never reach apt for it.
# shellcheck source=ort-runtime-gate.sh
source "${SCRIPT_DIR}/ort-runtime-gate.sh"
declare -A KNOWN_SO_PACKAGES=()
declare -a KNOWN_SO_GLOBS=()
# Map target for source-built libs: a miss is never "repaired" from apt, which would shadow them.
SO_PACKAGE_DENY=source-built
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
    echo "  MISSING: ${so_name}" >&2
    missing+=("${so_name}")
  done < <(elf_unresolved_needed "${binary}" "${LIB_DIRS[@]}")

  if [ ${#missing[@]} -gt 0 ]; then
    printf '%s\n' "${missing[@]}"
  fi
}

# rc 0 + package name on stdout; rc 1 unmappable; rc 2 DENIED (source-built).
resolve_package_for_so() {
  local so_name="$1"
  local pkg="" glob

  # Denied in code, not only in the map: a missing map must not reopen the 2026-08-27 path.
  ort_is_denied_soname "${so_name}" && return 2
  pkg="${KNOWN_SO_PACKAGES[${so_name}]:-}"

  if [ -z "${pkg}" ] && [ ${#KNOWN_SO_GLOBS[@]} -gt 0 ]; then
    for glob in "${KNOWN_SO_GLOBS[@]}"; do
      # shellcheck disable=SC2254  # the pattern is meant to glob, that is the point
      case "${so_name}" in
        ${glob}) pkg="${KNOWN_SO_PACKAGES[${glob}]}"; break ;;
      esac
    done
  fi

  [ "${pkg}" = "${SO_PACKAGE_DENY}" ] && return 2

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
      missing_all+=("${so_name}")
    done < <(elf_unresolved_needed "${p}" "${LIB_DIRS[@]}")
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

# A no-op when the genai lane is off. See docs/gen1-riscv64-genai.md
genai_lib_dir="${ONNXRUNTIME_GENAI_OUTPUT_DIR:-/usr/local/lib/onnxruntime-genai}/lib"
if [ -d "${genai_lib_dir}" ]; then
  mapfile -t genai_missing < <(scan_plugin_directory "${genai_lib_dir}")
  ALL_MISSING+=("${genai_missing[@]}")
fi

mapfile -t UNIQ_MISSING < <(printf '%s\n' "${ALL_MISSING[@]}" | uniq_nonempty_lines)

if [ ${#UNIQ_MISSING[@]} -eq 0 ]; then
  echo "All artifacts have their runtime dependencies satisfied."
  # No exit: sonames resolve by name, so a wrong-arch ffmpeg scans clean and the ELF gate must still run.
else

echo ""
echo "=== Resolving ${#UNIQ_MISSING[@]} missing dependencies ==="

PACKAGES_TO_INSTALL=()
STILL_MISSING=()
DENIED_MISSING=()

for so_name in "${UNIQ_MISSING[@]}"; do
  rc=0
  pkg="$(resolve_package_for_so "${so_name}")" || rc=$?
  if [ "${rc}" = "2" ]; then
    echo "  ${so_name} -> DENIED (source-built; an apt copy would shadow our build)"
    DENIED_MISSING+=("${so_name}")
  elif [ -n "${pkg}" ]; then
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

  ort_apt_plan_gate "${UNIQ_PKGS[@]}" || exit 1

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

if [ ${#DENIED_MISSING[@]} -gt 0 ]; then
  echo ""
  echo "=== FAIL: ${#DENIED_MISSING[@]} source-built dependencies unresolved (apt repair denied) ==="
  printf '  %s\n' "${DENIED_MISSING[@]}"
  echo "These ship from this repo's own build; a miss means the builder did not"
  echo "install the SONAME link. Fix the builder — do NOT map them to a distro"
  echo "package, which is what silently downgraded ONNX Runtime before 2026-08-28."
  _VMR_DENIED_FAILURES=${#DENIED_MISSING[@]}
fi

fi  # end of the dirty-scan resolution branch — ELF validation runs either way

# ELF architecture validation
echo ""
echo "=== ELF Architecture Validation ==="

target_arch="${TARGET_ARCH:-${TARGETARCH:-amd64}}"
case "${target_arch}" in
  amd64)   elf_machine_grep="X86-64" ;;
  arm64)   elf_machine_grep="AArch64" ;;
  riscv64) elf_machine_grep="RISC-V" ;;
  *)       elf_machine_grep="" ;;
esac

# Vendor libraries that ship foreign-arch on purpose (QNN, SNPE, NeuroPilot).
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
  # Core binaries are never vendor, so a wrong arch here is always a defect.
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
  # Advisory only: these dirs also hold vendor SDKs that no name list can fully enumerate.
  for so_dir in "${LIB_DIRS[@]}"; do
    [ -d "${so_dir}" ] || continue
    for so in "${so_dir}"/*.so "${so_dir}"/*.so.*; do
      [ -f "${so}" ] || continue
      _so_base="$(basename "${so}")"
      is_vendor_binary "${_so_base}" && continue
      # `|| true`: readelf exits 1 on linker-script *.so files, which the "" arm handles.
      elf_machine="$(LC_ALL=C readelf -h "${so}" 2>/dev/null | sed -n 's/^[[:space:]]*Machine:[[:space:]]*//p' | head -n1 || true)"
      case "${elf_machine}" in
        *"${elf_machine_grep}"*) ;;
        "") continue ;;
        *)
          # Full path: vendor versus leak cannot be judged from a name.
          echo "  MISMATCH (advisory): ${so} ELF machine=${elf_machine} != expected ${elf_machine_grep}" >&2
          so_mismatches=$((so_mismatches + 1))
          ;;
      esac
    done
  done
else
  echo "  SKIP: readelf not available or unknown arch ${target_arch}" >&2
fi

# A wrong-arch core binary is a host-vs-target defect: fatal unless MEDIA_ELF_MISMATCH_FATAL=0.
[ "${so_mismatches}" -gt 0 ] && echo "  NOTE: ${so_mismatches} advisory .so ELF mismatch(es); not failing — check the paths above, a vendor SDK and a real wrong-arch leak look identical here" >&2
if [ "${core_mismatches}" -gt 0 ]; then
  if [ "${MEDIA_ELF_MISMATCH_FATAL:-1}" = "1" ]; then
    echo "  FAIL: ${core_mismatches} CORE media binary ELF mismatch(es) for target ${target_arch} — wrong-arch artifact(s) present" >&2
    exit 1
  fi
  echo "  WARN: ${core_mismatches} core ELF mismatch(es) (MEDIA_ELF_MISMATCH_FATAL=0; not failing)" >&2
fi

# No QEMU smoke here. See docs/failure-modes.md § A smoke that never passed and always excused itself

echo ""
echo "=== Validation complete ==="

# Whatever the repair or an earlier install pulled in: no distro ONNX Runtime ships.
ort_dpkg_gate || exit 1

# The DENIED class is empty by construction; any count is a builder bug.
if [ "${_VMR_DENIED_FAILURES:-0}" -gt 0 ]; then
  echo "FAIL: ${_VMR_DENIED_FAILURES} DENIED source-built dependency failure(s) — see above" >&2
  exit 1
fi
