#!/usr/bin/env bash
set -eux
if [ -f /opt/scripts/core/cross-env.sh ]; then
  # shellcheck disable=SC1091
  source /opt/scripts/core/cross-env.sh
fi
if [ -f /opt/scripts/toolchain/vulkan.sh ]; then
  # shellcheck disable=SC1091
  source /opt/scripts/toolchain/vulkan.sh
fi

vulkan_prefix="${VULKAN_PREFIX:-${VULKAN_INSTALL_ROOT:-/opt/vulkan}}"

if command -v cross_apt_update >/dev/null 2>&1; then
  cross_apt_update
else
  apt-get update
fi

is_riscv64_cross=false
if command -v cross_build_enabled >/dev/null 2>&1 && cross_build_enabled && \
   command -v cross_target_arch >/dev/null 2>&1 && [ "$(cross_target_arch)" = "riscv64" ]; then
  is_riscv64_cross=true
fi

gi_cross_wrapper_arch=""
if command -v cross_build_enabled >/dev/null 2>&1 && cross_build_enabled && \
   command -v cross_target_arch >/dev/null 2>&1; then
  case "$(cross_target_arch)" in
    arm64|riscv64)
      gi_cross_wrapper_arch="$(cross_target_arch)"
      ;;
  esac
fi

skip_csound_cross=false
if command -v cross_build_enabled >/dev/null 2>&1 && cross_build_enabled && \
   command -v cross_target_arch >/dev/null 2>&1; then
  case "$(cross_target_arch)" in
    arm64|riscv64)
      skip_csound_cross=true
      ;;
  esac
fi

prefer_toolchain_vulkan=false
if command -v cross_build_enabled >/dev/null 2>&1 && cross_build_enabled && \
   [ -d "${vulkan_prefix}" ]; then
  prefer_toolchain_vulkan=true
fi

find_toolchain_vulkan_sdk_dir() {
  local prefix host_arch candidate version_dir

  prefix="${vulkan_prefix}"
  host_arch="$(uname -m)"

  if declare -F source_vulkan_sdk_env >/dev/null 2>&1 && \
     source_vulkan_sdk_env "${prefix}" sanitize-libs >/dev/null 2>&1; then
    if [ -n "${VULKAN_SDK:-}" ] && [ -d "${VULKAN_SDK}" ]; then
      printf '%s' "${VULKAN_SDK}"
      return 0
    fi
  fi

  if [ -n "${VULKAN_SDK:-}" ] && [ -d "${VULKAN_SDK}" ]; then
    printf '%s' "${VULKAN_SDK}"
    return 0
  fi

  if [ -n "${VULKAN_VERSION:-}" ] && [ -d "${prefix}/${VULKAN_VERSION}/${host_arch}" ]; then
    printf '%s' "${prefix}/${VULKAN_VERSION}/${host_arch}"
    return 0
  fi

  for version_dir in "${prefix}"/*; do
    [ -d "${version_dir}" ] || continue
    if [ -d "${version_dir}/${host_arch}" ]; then
      candidate="${version_dir}/${host_arch}"
    fi
  done

  [ -n "${candidate:-}" ] || return 1
  printf '%s' "${candidate}"
}

setup_toolchain_vulkan_cross_metadata() {
  local sdk_dir sdk_version triplet target_libdir target_runtime pcdir candidate

  sdk_dir="$(find_toolchain_vulkan_sdk_dir)" || {
    echo "ERROR: Could not find toolchain Vulkan SDK under ${vulkan_prefix}" >&2
    return 1
  }

  if command -v cross_target_triplet >/dev/null 2>&1 && cross_build_enabled; then
    triplet="$(cross_target_triplet)"
  else
    triplet="$(dpkg-architecture -q DEB_HOST_MULTIARCH 2>/dev/null || true)"
  fi

  if [ -z "${triplet}" ]; then
    echo "ERROR: Could not determine target triplet for Vulkan cross metadata" >&2
    return 1
  fi

  target_libdir="/usr/lib/${triplet}"
  for candidate in "${target_libdir}/libvulkan.so.1" "${target_libdir}"/libvulkan.so.*; do
    [ -e "${candidate}" ] || continue
    target_runtime="${candidate}"
    break
  done

  if [ -z "${target_runtime:-}" ]; then
    echo "ERROR: Expected target Vulkan runtime library under ${target_libdir}; install libvulkan1 first" >&2
    return 1
  fi

  ln -snf "${target_runtime}" "${target_libdir}/libvulkan.so"

  sdk_version="$(basename "$(dirname "${sdk_dir}")")"
  pcdir="${target_libdir}/pkgconfig"
  mkdir -p "${pcdir}"
  printf '%s\n' \
    "prefix=/usr" \
    "exec_prefix=\${prefix}" \
    "libdir=${target_libdir}" \
    "includedir=${sdk_dir}/include" \
    "" \
    "Name: Vulkan" \
    "Description: Vulkan loader using toolchain SDK headers" \
    "Version: ${sdk_version}" \
    "Libs: -L\${libdir} -lvulkan" \
    "Cflags: -I\${includedir}" \
    > "${pcdir}/vulkan.pc"

  echo "Configured Vulkan cross metadata with SDK headers from ${sdk_dir} and loader from ${target_libdir}"
}

# Ensure basic build tooling present for building vvdec and host-side
# introspection / GTK / Cairo checks. Install core packages first, then attempt
# to install X protocol headers.
host_packages=(build-essential cmake git pkg-config python3-gi gobject-introspection libgirepository1.0-dev libcairo2-dev libpcre2-dev)
core_packages=(libx11-dev libxext-dev libxrender-dev libxau-dev libxdmcp-dev libxfixes-dev x11proto-dev libsodium-dev)

if [ -n "${gi_cross_wrapper_arch}" ]; then
  host_packages+=(qemu-user)
fi

if [ "${is_riscv64_cross}" = "true" ]; then
  echo "Skipping libpango1.0-dev and libgdk-pixbuf-2.0-dev target helper packages for riscv64 cross pre-setup because Ubuntu Ports cannot satisfy their GLib helper dependency chain."
else
  core_packages=(libcairo2-dev libpango1.0-dev libgdk-pixbuf-2.0-dev "${core_packages[@]}")
fi

apt-get install -y --no-install-recommends "${host_packages[@]}" "${core_packages[@]}"

# Keep the cross pkg-config path target-only, but expose the wrapped scanner
# path through a focused shim without dropping the target package's real
# include/library flags.
if [ -n "${gi_cross_wrapper_arch}" ]; then
  build_triplet="$(dpkg-architecture -q DEB_BUILD_MULTIARCH 2>/dev/null || dpkg-architecture -q DEB_HOST_MULTIARCH 2>/dev/null || true)"
  target_triplet=""
  target_gi_bindir="/usr/bin"
  target_gi_datadir="/usr/share"
  target_gi_includedir="/usr/include"
  target_gi_libdir="/usr/lib"
  target_gi_requires="glib-2.0 >= 2.82.0, gobject-2.0 >= 2.82.0"
  target_gi_libs='-L${libdir} -lgirepository-1.0'
  target_gi_cflags='-I${includedir}/gobject-introspection-1.0'
  target_gi_compiler="${target_gi_bindir}/g-ir-compiler"
  target_gi_generate="${target_gi_bindir}/g-ir-generate"
  target_gi_pc=""
  if command -v cross_target_triplet >/dev/null 2>&1; then
    target_triplet="$(cross_target_triplet 2>/dev/null || true)"
  fi
  if [ -z "${target_triplet}" ]; then
    target_triplet="$(dpkg-architecture -a "${gi_cross_wrapper_arch}" -q DEB_HOST_MULTIARCH 2>/dev/null || true)"
  fi
  if [ -n "${target_triplet}" ]; then
    target_gi_pc="/usr/lib/${target_triplet}/pkgconfig/gobject-introspection-1.0.pc"
    if [ -d "/usr/lib/${target_triplet}" ]; then
      target_gi_libdir="/usr/lib/${target_triplet}"
    fi
    if [ -x "/usr/bin/${target_triplet}-g-ir-compiler" ]; then
      target_gi_compiler="/usr/bin/${target_triplet}-g-ir-compiler"
    fi
    if [ -x "/usr/bin/${target_triplet}-g-ir-generate" ]; then
      target_gi_generate="/usr/bin/${target_triplet}-g-ir-generate"
    fi
  fi
  if [ -n "${target_gi_pc}" ] && [ -f "${target_gi_pc}" ]; then
    target_gi_requires="$(awk -F': *' '$1=="Requires" { print $2; exit }' "${target_gi_pc}")"
    target_gi_libs="$(awk -F': *' '$1=="Libs" { print $2; exit }' "${target_gi_pc}")"
    target_gi_cflags="$(awk -F': *' '$1=="Cflags" { print $2; exit }' "${target_gi_pc}")"
  fi
  gi_version="$(dpkg-query -W -f='${Version}' gobject-introspection 2>/dev/null || true)"
  gi_version="${gi_version%%-*}"
  gi_bindir="/usr/bin"
  # Prefer the distro-provided scanner path even on reruns so we don't recurse
  # back into the wrapper we install under /usr/local/bin for Meson's lookup.
  gi_scanner="$(PATH=/usr/bin:/bin command -v g-ir-scanner 2>/dev/null || command -v g-ir-scanner 2>/dev/null || true)"
  gi_host_ldd="$(PATH=/usr/bin:/bin command -v ldd 2>/dev/null || true)"
  gi_scanner_wrapper="/usr/local/bin/g-ir-scanner-${gi_cross_wrapper_arch}-cross"
  gi_scanner_triplet_wrapper="/usr/bin/${target_triplet}-g-ir-scanner"
  gi_scanner_default="/usr/local/bin/g-ir-scanner"
  gi_ldd_default="/usr/local/bin/ldd"
  gi_ldd_wrapper="/usr/local/bin/g-ir-scanner-ldd-${gi_cross_wrapper_arch}-cross"
  gi_binary_wrapper="/usr/local/bin/g-ir-scanner-${gi_cross_wrapper_arch}-binary-wrapper"
  meson_binary_wrapper="/usr/local/bin/meson-${gi_cross_wrapper_arch}-exe-wrapper"
  if [ -n "${gi_scanner}" ]; then
    gi_bindir="$(dirname "${gi_scanner}")"
  fi
  gi_libdir="/usr/lib"
  if [ -n "${build_triplet}" ] && [ -d "/usr/lib/${build_triplet}" ]; then
    gi_libdir="/usr/lib/${build_triplet}"
  fi
  if [ -z "${gi_version}" ]; then
    gi_version="1.80.1"
  fi
  if [ -z "${gi_host_ldd}" ]; then
    gi_host_ldd="/usr/bin/ldd"
  fi

  qemu_runner=""
  case "${gi_cross_wrapper_arch}" in
    riscv64)
      qemu_runner="$(command -v qemu-riscv64 2>/dev/null || command -v qemu-riscv64-static 2>/dev/null || true)"
      if [ -z "${qemu_runner}" ]; then
        echo "ERROR: riscv64 cross-introspection requires qemu-riscv64 or qemu-riscv64-static" >&2
        exit 1
      fi
      ;;
    arm64)
      qemu_runner="$(command -v qemu-aarch64 2>/dev/null || command -v qemu-aarch64-static 2>/dev/null || true)"
      if [ -z "${qemu_runner}" ]; then
        echo "ERROR: arm64 cross-introspection requires qemu-aarch64 or qemu-aarch64-static" >&2
        exit 1
      fi
      ;;
  esac

  qemu_sysroot=""
  for candidate in "/usr/${target_triplet}" "/"; do
    case "${gi_cross_wrapper_arch}" in
      riscv64)
        for loader in \
          "${candidate}/lib/ld-linux-riscv64-lp64d.so.1" \
          "${candidate}/lib/ld-linux-riscv64-lp64.so.1" \
          "${candidate}/lib/ld-linux-riscv64-ilp32d.so.1" \
          "${candidate}/lib/ld-linux-riscv64-ilp32.so.1"; do
          if [ -e "${loader}" ]; then
            qemu_sysroot="${candidate}"
            break 2
          fi
        done
        ;;
      arm64)
        for loader in \
          "${candidate}/lib/ld-linux-aarch64.so.1"; do
          if [ -e "${loader}" ]; then
            qemu_sysroot="${candidate}"
            break 2
          fi
        done
        ;;
    esac
  done

  if [ -z "${qemu_sysroot}" ]; then
    echo "ERROR: Could not locate a ${gi_cross_wrapper_arch} dynamic loader for qemu under /usr/${target_triplet} or /" >&2
    exit 1
  fi

  cat > "${gi_ldd_wrapper}" <<EOF
#!/usr/bin/env bash
set -eu

binary="\$1"
[ -n "\${binary:-}" ] || exit 2

  if [ -n "${target_triplet}" ] && command -v "${target_triplet}-objdump" >/dev/null 2>&1; then
    objdump_cmd="${target_triplet}-objdump"
  else
    objdump_cmd="objdump"
  fi

"\${objdump_cmd}" -p "\${binary}" | awk '
  /^[[:space:]]*NEEDED/ { print \$2 }
  /^[[:space:]]*SONAME/ { print \$2 }
'
EOF
  chmod +x "${gi_ldd_wrapper}"

  cat > "${gi_ldd_default}" <<EOF
#!/usr/bin/env bash
set -eu

host_ldd="${gi_host_ldd}"
binary=""

for arg in "\$@"; do
  case "\${arg}" in
    -*)
      ;;
    *)
      binary="\${arg}"
      ;;
  esac
done

  if [ -n "\${binary}" ] && [ -f "\${binary}" ]; then
    arch="\$(PATH=/usr/bin:/bin objdump -f "\${binary}" 2>/dev/null | awk -F'architecture: ' '/architecture:/ { print \$2; exit }')"
    case "\${arch}" in
      aarch64:*|aarch64*|arm64*|*aarch64*)
        exec "${gi_ldd_wrapper}" "\$@"
        ;;
      riscv:*|riscv64*|*riscv*)
        exec "${gi_ldd_wrapper}" "\$@"
        ;;
    esac
  fi

exec "\${host_ldd}" "\$@"
EOF
  chmod +x "${gi_ldd_default}"

  write_qemu_binary_wrapper() {
    local wrapper_path="$1"
    local mode="$2"

    cat > "${wrapper_path}" <<EOF
#!/usr/bin/env bash
set -eu

wrapper_mode='${mode}'

[ "\$#" -ge 1 ] || exit 2

binary="\$1"
shift

target_ld_library_path=""

append_target_libdir() {
  local dir="\$1"
  [ -n "\${dir}" ] || return 0
  [ -d "\${dir}" ] || return 0

  case ":\${target_ld_library_path}:" in
    *":\${dir}:"*)
      ;;
    *)
      if [ -n "\${target_ld_library_path}" ]; then
        target_ld_library_path="\${target_ld_library_path}:\${dir}"
      else
        target_ld_library_path="\${dir}"
      fi
      ;;
  esac
}

append_binary_runpaths() {
  local binary_path="\$1"
  local binary_dir objdump_cmd runpath old_ifs entry

  [ -n "\${binary_path}" ] || return 0
  [ -f "\${binary_path}" ] || return 0

  binary_dir="\$(cd "\$(dirname "\${binary_path}")" 2>/dev/null && pwd)"

  if [ -n "${target_triplet}" ] && command -v "${target_triplet}-objdump" >/dev/null 2>&1; then
    objdump_cmd="${target_triplet}-objdump"
  else
    objdump_cmd="objdump"
  fi

  while IFS= read -r runpath; do
    [ -n "\${runpath}" ] || continue

    old_ifs="\${IFS}"
    IFS=':'
    for entry in \${runpath}; do
      case "\${entry}" in
        '\$ORIGIN'|'\${ORIGIN}')
          entry="\${binary_dir}"
          ;;
        '\$ORIGIN'/*|'\${ORIGIN}'/*)
          entry="\${binary_dir}/\${entry#*/}"
          ;;
      esac
      append_target_libdir "\${entry}"
    done
    IFS="\${old_ifs}"
  done < <("\${objdump_cmd}" -p "\${binary_path}" | awk '
    /^[[:space:]]*RUNPATH/ || /^[[:space:]]*RPATH/ {
      \$1 = ""
      sub(/^[[:space:]]+/, "")
      print
    }
  ')
}

merge_target_libdirs() {
  local value="\$1" dir old_ifs
  [ -n "\${value}" ] || return 0

  old_ifs="\${IFS}"
  IFS=':'
  for dir in \${value}; do
    append_target_libdir "\${dir}"
  done
  IFS="\${old_ifs}"
}

append_meson_uninstalled_libdirs() {
  local meson_uninstalled="" entry pc_file pkg_name lib_flag
  local old_ifs
  local -a pkg_config_entries

  IFS=':' read -r -a pkg_config_entries <<< "\${PKG_CONFIG_PATH:-}"
  for entry in "\${pkg_config_entries[@]}"; do
    case "\${entry}" in
      */meson-uninstalled)
        meson_uninstalled="\${entry}"
        break
        ;;
    esac
  done

  if [ -n "\${meson_uninstalled}" ] && [ -d "\${meson_uninstalled}" ]; then
    while IFS= read -r pc_file; do
      pkg_name="\$(basename "\${pc_file}" .pc)"
      for lib_flag in \$(pkg-config --libs-only-L "\${pkg_name}" 2>/dev/null || true); do
        case "\${lib_flag}" in
          -L*)
            append_target_libdir "\${lib_flag#-L}"
            ;;
        esac
      done
    done < <(find "\${meson_uninstalled}" -maxdepth 1 -type f -name '*.pc' -print)
  fi
}

if [ "\${wrapper_mode}" = "gi" ]; then
  # For temporary GIR dump binaries, prefer the current build-tree libraries
  # from meson-uninstalled metadata before broader inherited target paths.
  append_meson_uninstalled_libdirs
  merge_target_libdirs "\${LD_LIBRARY_PATH:-}"
  merge_target_libdirs "\${GI_TARGET_LD_LIBRARY_PATH:-}"
  merge_target_libdirs "\${LIBRARY_PATH:-}"
  append_target_libdir "\$(dirname "\${binary}")"
else
  # Generic Meson target helpers like orcc need their executable-local
  # RUNPATH/RPATH ahead of broader target library fallbacks.
  append_target_libdir "\$(dirname "\${binary}")"
  append_binary_runpaths "\${binary}"
  append_meson_uninstalled_libdirs
  merge_target_libdirs "\${LD_LIBRARY_PATH:-}"
  merge_target_libdirs "\${GI_TARGET_LD_LIBRARY_PATH:-}"
  merge_target_libdirs "\${LIBRARY_PATH:-}"
fi

if [ -n "${target_triplet}" ]; then
  append_target_libdir "/lib/${target_triplet}"
  append_target_libdir "/usr/lib/${target_triplet}"
fi

qemu_args=( "${qemu_runner}" -L "${qemu_sysroot}" )
if [ -n "\${target_ld_library_path}" ]; then
  qemu_args+=( -E "LD_LIBRARY_PATH=\${target_ld_library_path}" )
fi

exec env -u LD_LIBRARY_PATH "\${qemu_args[@]}" "\${binary}" "\$@"
EOF
    chmod +x "${wrapper_path}"
  }

  write_qemu_binary_wrapper "${gi_binary_wrapper}" gi
  write_qemu_binary_wrapper "${meson_binary_wrapper}" meson

  cat > "${gi_scanner_wrapper}" <<EOF
#!/usr/bin/env bash
set -eu
exec "${gi_scanner:-/bin/g-ir-scanner}" \
  --use-binary-wrapper="${gi_binary_wrapper}" \
  --use-ldd-wrapper="${gi_ldd_wrapper}" \
  "\$@"
EOF
  chmod +x "${gi_scanner_wrapper}"

  cat > "${gi_scanner_triplet_wrapper}" <<EOF
#!/usr/bin/env bash
set -eu
exec "${gi_scanner_wrapper}" "\$@"
EOF
  chmod +x "${gi_scanner_triplet_wrapper}"

  cat > "${gi_scanner_default}" <<EOF
#!/usr/bin/env bash
set -eu
exec "${gi_scanner_wrapper}" "\$@"
EOF
  chmod +x "${gi_scanner_default}"

  mkdir -p /usr/local/lib/pkgconfig
  printf '%s\n' \
    "prefix=/usr" \
    "exec_prefix=\${prefix}" \
    "bindir=${target_gi_bindir}" \
    "datadir=${target_gi_datadir}" \
    "includedir=${target_gi_includedir}" \
    "libdir=${target_gi_libdir}" \
    "g_ir_scanner=${gi_scanner_triplet_wrapper}" \
    "g_ir_compiler=${target_gi_compiler}" \
    "g_ir_generate=${target_gi_generate}" \
    "gidatadir=\${datadir}/gobject-introspection-1.0" \
    "girdir=\${datadir}/gir-1.0" \
    "typelibdir=\${libdir}/girepository-1.0" \
    "" \
    "Name: gobject-introspection" \
    "Description: GObject Introspection cross-build helper metadata" \
    "Version: ${gi_version}" \
    "Requires: ${target_gi_requires}" \
    "Libs: ${target_gi_libs}" \
    "Cflags: ${target_gi_cflags}" \
    > /usr/local/lib/pkgconfig/gobject-introspection-1.0.pc
  cp /usr/local/lib/pkgconfig/gobject-introspection-1.0.pc /usr/local/lib/pkgconfig/gobject-introspection-no-export-1.0.pc
fi

if [ "${prefer_toolchain_vulkan}" = "true" ]; then
  setup_toolchain_vulkan_cross_metadata
fi

# Some base images may not provide the \`xorgproto\` package name. Try a few
# alternatives and fail early if none are available so the error is clear.
if command -v cross_apt_update >/dev/null 2>&1; then
  cross_apt_update || true
else
  apt-get update || true
fi
apt-get install -y --no-install-recommends xorg-dev || true
if [ "${is_riscv64_cross}" = "true" ]; then
  apt-get install -y --no-install-recommends x11proto-dev || true
else
  apt-get install -y --no-install-recommends x11proto-core-dev x11proto-dev || true
fi
# Ensure pkg-config metadata directories updated
update-alternatives --set xauth /usr/bin/xauth 2>/dev/null || true
# Install Csound packages required for building csound-related plugins.
if command -v cross_apt_update >/dev/null 2>&1; then
  cross_apt_update
else
  apt-get update
fi
# The later GStreamer build already disables/excludes csound on ARM and RISC-V
# cross targets, so avoid redundant host-side package churn here.
if [ "${skip_csound_cross}" = "true" ]; then
  echo "Skipping Csound pre-setup for $(cross_target_arch 2>/dev/null || echo target) cross builds because the Csound plugin is disabled on this target."
else
  apt-get install -y --no-install-recommends \
    csound csound-utils csoundqt csoundqt-examples csound-doc libcsound64-dev pd-csound || \
  { echo "ERROR: required Csound packages not found in APT; please add an appropriate repo or package name." >&2; exit 1; }
fi
# Some Debian packages do not provide a pkg-config .pc file for Csound.
# Create a minimal csound.pc in the appropriate multiarch pkgconfig
# directory so downstream pkg-config checks succeed. Only create the
# stub when not building for riscv targets (we skipped installing Csound
# packages above for skipped cross targets), otherwise creating a stub may mask
# missing package problems on supported arches.
if [ "${skip_csound_cross}" != "true" ]; then
  triplet=""
  if command -v cross_target_triplet >/dev/null 2>&1 && cross_build_enabled; then
    triplet="$(cross_target_triplet)"
  fi
  if [ -z "$triplet" ]; then
    triplet="$(dpkg-architecture -q DEB_HOST_MULTIARCH 2>/dev/null || true)"
  fi
  if [ -n "$triplet" ] && [ -d "/usr/lib/$triplet" ]; then
    pcdir="/usr/lib/$triplet/pkgconfig"
    libdir="/usr/lib/$triplet"
  else
    pcdir="/usr/lib/pkgconfig"
    libdir="/usr/lib"
  fi
  mkdir -p "$pcdir"
  # Write a minimal csound.pc with the computed libdir. Keep ${prefix}
  # and ${libdir}/${includedir} in the file as pkg-config variables.
  printf '%s\n' \
    "prefix=/usr" \
    "exec_prefix=\${prefix}" \
    "libdir=${libdir}" \
    "includedir=/usr/include/csound" \
    "" \
    "Name: Csound" \
    "Description: Csound audio and music processing system" \
    "Version: 6.18.1" \
    "Libs: -L\${libdir} -lcsound64" \
    "Cflags: -I\${includedir}" \
    > "$pcdir/csound.pc" || true
  # Verify that pkg-config can discover csound; fail with diagnostics if not.
  if ! pkg-config --exists csound 2>/dev/null; then
    echo "" >&2
    echo "ERROR: csound pkg-config (.pc) not found after installing Csound packages." >&2
    echo "dpkg multiarch triplet: ${triplet:-unset}" >&2
    echo "PKG_CONFIG_LIBDIR=${PKG_CONFIG_LIBDIR:-unset}" >&2
    echo "PKG_CONFIG_PATH=${PKG_CONFIG_PATH:-unset}" >&2
    echo "Listing likely pkgconfig directories:" >&2
    for d in "/usr/lib/${triplet:-}/pkgconfig" /usr/lib/pkgconfig /usr/local/lib/pkgconfig; do
      echo "-- $d --" >&2; ls -la "$d" 2>/dev/null | sed -n '1,200p' >&2 || true
    done
    echo "pkg-config output (if any):" >&2
    pkg-config --cflags --libs csound 2>/dev/null || true
    echo "APT policy for csound packages:" >&2; apt-cache policy libcsound64-dev libcsound-dev csound || true
    echo "If these packages are provided by a non-default repository, enable it (for example: add-apt-repository universe) and re-run the build." >&2
    exit 1
  fi
  if [ -n "$triplet" ] && [ -d "/usr/lib/$triplet" ]; then
    CSOUND_LIB_DIR="/usr/lib/$triplet"
  else
    CSOUND_LIB_DIR="/usr/lib"
  fi
  echo "Setting CSOUND_LIB_DIR=$CSOUND_LIB_DIR"
  export CSOUND_LIB_DIR
  # Persist for later stages / shells
  echo "CSOUND_LIB_DIR=$CSOUND_LIB_DIR" >> /etc/environment
else
  echo "Skipping creation of csound.pc stub for cross targets where Csound is disabled"
fi
rm -rf /var/lib/apt/lists/*
