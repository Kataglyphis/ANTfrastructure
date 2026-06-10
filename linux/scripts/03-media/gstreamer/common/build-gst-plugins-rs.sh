#!/usr/bin/env bash
set -euo pipefail

configure_gstreamer_prefix_for_cargo() {
  if [ -d "${GSTREAMER_PREFIX}/lib/x86_64-linux-gnu/pkgconfig" ]; then
    export PKG_CONFIG_PATH="${GSTREAMER_PREFIX}/lib/x86_64-linux-gnu/pkgconfig:${PKG_CONFIG_PATH:-}"
    export LD_LIBRARY_PATH="${GSTREAMER_PREFIX}/lib/x86_64-linux-gnu:${LD_LIBRARY_PATH:-}"
  elif [ -d "${GSTREAMER_PREFIX}/lib/aarch64-linux-gnu/pkgconfig" ]; then
    export PKG_CONFIG_PATH="${GSTREAMER_PREFIX}/lib/aarch64-linux-gnu/pkgconfig:${PKG_CONFIG_PATH:-}"
    export LD_LIBRARY_PATH="${GSTREAMER_PREFIX}/lib/aarch64-linux-gnu:${LD_LIBRARY_PATH:-}"
  elif [ -d "${GSTREAMER_PREFIX}/lib/riscv64-linux-gnu/pkgconfig" ]; then
    export PKG_CONFIG_PATH="${GSTREAMER_PREFIX}/lib/riscv64-linux-gnu/pkgconfig:${PKG_CONFIG_PATH:-}"
    export LD_LIBRARY_PATH="${GSTREAMER_PREFIX}/lib/riscv64-linux-gnu:${LD_LIBRARY_PATH:-}"
  else
    export PKG_CONFIG_PATH="${GSTREAMER_PREFIX}/lib/pkgconfig:${PKG_CONFIG_PATH:-}"
    export LD_LIBRARY_PATH="${GSTREAMER_PREFIX}/lib:${LD_LIBRARY_PATH:-}"
  fi
}

compute_gst_plugins_rs_rust_jobs() {
  if command -v compute_rust_jobs >/dev/null 2>&1; then
    compute_rust_jobs
    return 0
  fi
  nproc --all 2>/dev/null || echo 1
}

cargo_metadata_package_names() {
  local pattern="$1"

  cargo metadata --no-deps --format-version=1 2>/dev/null | "${HOST_PYTHON}" -c '
import json
import re
import sys

pattern = re.compile(sys.argv[1])
try:
    data = json.load(sys.stdin)
except Exception:
    raise SystemExit(1)

names = [pkg.get("name", "") for pkg in data.get("packages", [])]
matches = [name for name in names if pattern.search(name)]
if matches:
    print(" ".join(matches))
' "$pattern"
}

prepare_cargo_target_compiler_wrapper() {
  local compiler="$1"
  local wrapper_name="$2"
  local cross_bindir="${3:-/opt/cross-bin}"
  local wrapper_dir="${GSTREAMER_CARGO_TARGET_TOOLCHAIN_DIR:-/tmp/gstreamer-cargo-target-toolchain}"

  [ -n "${compiler}" ] || return 1
  [ -n "${wrapper_name}" ] || return 1

  mkdir -p "${wrapper_dir}"
  cat > "${wrapper_dir}/${wrapper_name}" <<EOF
#!/usr/bin/env bash
exec "${compiler}" -B"${cross_bindir%/}/" "\$@"
EOF
  chmod +x "${wrapper_dir}/${wrapper_name}"
  printf '%s' "${wrapper_dir}/${wrapper_name}"
}

build_standalone_gst_plugins_rs() {
  local plugin_rs_dir="/opt/gst-plugins-rs"
  local standalone_cargo_toml=""
  local rust_jobs=""
  local cargo_host_cc=""
  local cargo_host_linker=""
  local cargo_host_cxx=""
  local cargo_host_cxx_wrapper=""
  local cargo_target_rust_env=""
  local cargo_target_rust_lower=""
  local cargo_target_cross_bindir=""
  local cargo_target_cc_wrapper=""
  local cargo_target_cxx_wrapper=""
  local arch_for_excludes=""
  local arch_probes=""
  local cs_pkg_names=""
  local skia_pkg_names=""
  local whisper_pkg_names=""
  local validate_pkg_names=""
  local dav1d_pkg_names=""
  local -a cargo_flags=()
  local -a default_excludes=(--exclude gst-plugin-burn)
  local -a build_cmd=()

  configure_gstreamer_prefix_for_cargo

  if [ -d "${plugin_rs_dir}" ]; then
    cd "${plugin_rs_dir}"
    git fetch origin --tags
    git checkout "gstreamer-${GSTREAMER_VERSION}"
  else
    sudo mkdir -p "${plugin_rs_dir}"
    sudo chown "$(id -u):$(id -g)" "${plugin_rs_dir}" 2>/dev/null || true
    git clone --depth 1 --branch "gstreamer-${GSTREAMER_VERSION}" https://github.com/GStreamer/gst-plugins-rs.git "${plugin_rs_dir}"
    cd "${plugin_rs_dir}"
    sudo chown "$(id -u):$(id -g)" "${plugin_rs_dir}" 2>/dev/null || true
  fi

  [ "${BUILD_TYPE_LOWER}" = "release" ] && cargo_flags+=(--release)

  rust_jobs="$(compute_gst_plugins_rs_rust_jobs)"
  export CARGO_BUILD_JOBS="${CARGO_BUILD_JOBS:-${rust_jobs}}"
  echo "Building gst-plugins-rs workspace with CARGO_BUILD_JOBS=${CARGO_BUILD_JOBS} (AGGRESSIVE_PARALLELISM=${AGGRESSIVE_PARALLELISM:-false})"

  cd "${plugin_rs_dir}"
  standalone_cargo_toml="${plugin_rs_dir}/Cargo.toml"

  if command -v prepare_host_cargo_toolchain_env >/dev/null 2>&1; then
    prepare_host_cargo_toolchain_env
  elif cross_build_is_active; then
    cargo_host_cc="$(resolve_host_gcc_for_cargo)"
    if [ -n "${cargo_host_cc}" ]; then
      cargo_host_linker="$(prepare_cargo_host_linker_wrapper "${cargo_host_cc}")"
      export CARGO_TARGET_X86_64_UNKNOWN_LINUX_GNU_LINKER="${cargo_host_linker}"
      export CC_x86_64_unknown_linux_gnu="${cargo_host_linker}"
    fi

    cargo_host_cxx="$(resolve_host_gxx_for_cargo)"
    if [ -n "${cargo_host_cxx}" ]; then
      cargo_host_cxx_wrapper="$(prepare_cargo_host_cxx_wrapper "${cargo_host_cxx}")"
      export CXX_x86_64_unknown_linux_gnu="${cargo_host_cxx_wrapper}"
    fi
  fi

  if cross_build_is_active &&
     command -v cross_target_arch >/dev/null 2>&1 &&
     [ "$(cross_target_arch)" = "riscv64" ]; then
    # prepare_host_cargo_toolchain_env removes /opt/cross-bin from PATH so host
    # build scripts keep using the native cc/c++. Wrap the target compiler driver
    # with -B/opt/cross-bin so target-side cc-rs builds still resolve riscv64 as/ld.
    cargo_target_cross_bindir="$(cross_bin_dir 2>/dev/null || printf '%s' '/opt/cross-bin')"
    if command -v cross_target_upper_rust >/dev/null 2>&1; then
      cargo_target_rust_env="$(cross_target_upper_rust 2>/dev/null || true)"
    fi
    if command -v cross_target_lower_rust >/dev/null 2>&1; then
      cargo_target_rust_lower="$(cross_target_lower_rust 2>/dev/null || true)"
    fi
    [ -n "${cargo_target_rust_env}" ] || cargo_target_rust_env="$(printf '%s' "${CARGO_BUILD_TARGET}" | tr '[:lower:]-' '[:upper:]_')"
    [ -n "${cargo_target_rust_lower}" ] || cargo_target_rust_lower="$(printf '%s' "${CARGO_BUILD_TARGET}" | tr '[:upper:]-' '[:lower:]_')"

    if [ -d "${cargo_target_cross_bindir}" ] && [ -n "${CC:-}" ]; then
      cargo_target_cc_wrapper="$(prepare_cargo_target_compiler_wrapper "${CC}" "target-gcc-riscv64" "${cargo_target_cross_bindir}")"
      export "CARGO_TARGET_${cargo_target_rust_env}_LINKER=${cargo_target_cc_wrapper}"
      export "CC_${cargo_target_rust_lower}=${cargo_target_cc_wrapper}"
    fi

    if [ -d "${cargo_target_cross_bindir}" ] && [ -n "${CXX:-}" ]; then
      cargo_target_cxx_wrapper="$(prepare_cargo_target_compiler_wrapper "${CXX}" "target-g++-riscv64" "${cargo_target_cross_bindir}")"
      export "CXX_${cargo_target_rust_lower}=${cargo_target_cxx_wrapper}"
    fi

    # Standalone Cargo crates here use pkg-config / system-deps, which can drop
    # target system libdirs (for example /usr/lib/riscv64-linux-gnu and
    # /usr/local/lib) from emitted link-search flags. Keep those -L entries so
    # Rust links can resolve target shared libs like Vulkan and vvdec.
    export PKG_CONFIG_ALLOW_SYSTEM_LIBS=1

    # vvdec-sys resolves libvvdec via system-deps/pkg-config, which still needs
    # an explicit native search override because libvvdec is installed into
    # /usr/local/lib by install-vvdec.sh rather than coming from the distro.
    if [ -d /usr/local/lib ]; then
      export SYSTEM_DEPS_LIBVVDEC_SEARCH_NATIVE="${SYSTEM_DEPS_LIBVVDEC_SEARCH_NATIVE:-/usr/local/lib}"
    fi

    if [ -n "${cargo_target_cc_wrapper}" ]; then
      echo "RISC-V standalone gst-plugins-rs build detected: using target compiler wrappers with -B${cargo_target_cross_bindir%/}/"
    fi
  fi

  prune_gst_plugins_rs_workspace_member "${standalone_cargo_toml}" "analytics/burn"

  arch_for_excludes="${TARGET_MACHINE_ARCH} ${TARGETARCH:-} ${TARGET_ARCH:-} $(dpkg-architecture -q DEB_HOST_ARCH 2>/dev/null || true) $(dpkg-architecture -q DEB_HOST_MULTIARCH 2>/dev/null || true) $(uname -m 2>/dev/null || true)"
  if echo "${arch_for_excludes}" | grep -qi -E 'riscv|riscv64|aarch64|arm64|arm'; then
    default_excludes+=(--exclude gst-plugin-csound --exclude csound --exclude csound-sys)
    prune_gst_plugins_rs_workspace_member "${standalone_cargo_toml}" "audio/csound"
    echo "Host arch detected in (${arch_for_excludes}): added csound-related excludes to DEFAULT_EXCLUDES"
  fi

  build_cmd=(cargo build --workspace "${cargo_flags[@]}" --jobs "${CARGO_BUILD_JOBS}")
  build_cmd+=("${default_excludes[@]}")
  if cross_build_is_active; then
    build_cmd+=(--target "${CARGO_BUILD_TARGET}")
  fi

  arch_probes="${TARGET_MACHINE_ARCH} ${TARGETARCH:-} ${TARGET_ARCH:-} $(dpkg-architecture -q DEB_HOST_ARCH 2>/dev/null || true) $(dpkg-architecture -q DEB_HOST_MULTIARCH 2>/dev/null || true)"
  if echo "${arch_probes}" | grep -qi -E 'riscv|riscv64|aarch64|arm64|arm'; then
    echo "Host arch detected in (${arch_probes}): excluding csound-related workspace crates from cargo build"
    if cs_pkg_names="$(cargo_metadata_package_names 'csound')"; then
      if [ -n "${cs_pkg_names}" ]; then
        for name in ${cs_pkg_names}; do
          build_cmd+=(--exclude "${name}")
        done
        echo "Excluding csound packages: ${cs_pkg_names}"
      else
        build_cmd+=(--exclude gst-plugin-csound)
        build_cmd+=(--exclude csound)
        build_cmd+=(--exclude csound-sys)
        echo "No csound package names found via cargo metadata; excluding gst-plugin-csound, csound and csound-sys"
      fi
    else
      build_cmd+=(--exclude gst-plugin-csound)
      build_cmd+=(--exclude csound)
      build_cmd+=(--exclude csound-sys)
      echo "cargo metadata unavailable; excluding gst-plugin-csound, csound and csound-sys by default"
    fi
  fi

  if echo " ${EXTRA_MESON_ARGS} ${MESON_ARGS:-} " | grep -q -E 'skia=disabled'; then
    echo "skia disabled via Meson args: excluding skia-related workspace crates from cargo build"
    prune_gst_plugins_rs_workspace_member "${standalone_cargo_toml}" "video/skia"
    if skia_pkg_names="$(cargo_metadata_package_names 'skia')"; then
      if [ -n "${skia_pkg_names}" ]; then
        for name in ${skia_pkg_names}; do
          build_cmd+=(--exclude "${name}")
        done
        echo "Excluding skia packages: ${skia_pkg_names}"
      else
        build_cmd+=(--exclude gst-plugin-skia)
        build_cmd+=(--exclude gst-plugin-skia-sys)
        echo "No skia package names found via cargo metadata; excluding gst-plugin-skia and gst-plugin-skia-sys"
      fi
    else
      build_cmd+=(--exclude gst-plugin-skia)
      build_cmd+=(--exclude gst-plugin-skia-sys)
      echo "cargo metadata unavailable; excluding gst-plugin-skia and gst-plugin-skia-sys by default"
    fi
  fi

  if [ "${BUILD_TYPE_LOWER}" = "release" ] && echo "${arch_probes}" | grep -qi -E 'riscv|riscv64|aarch64|arm64|arm|armv7l'; then
    echo "Release build on ARM/RISC-V detected in (${arch_probes}): excluding whisper-related workspace crates from cargo build"
    prune_gst_plugins_rs_workspace_member "${standalone_cargo_toml}" "audio/whisper"
    if whisper_pkg_names="$(cargo_metadata_package_names 'whisper')"; then
      if [ -n "${whisper_pkg_names}" ]; then
        for name in ${whisper_pkg_names}; do
          build_cmd+=(--exclude "${name}")
        done
        echo "Excluding whisper packages: ${whisper_pkg_names}"
      else
        build_cmd+=(--exclude gst-plugin-whisper)
        echo "No whisper package names found via cargo metadata; excluding gst-plugin-whisper"
      fi
    else
      build_cmd+=(--exclude gst-plugin-whisper)
      echo "cargo metadata unavailable; excluding gst-plugin-whisper by default"
    fi
  fi

  if echo "${arch_probes}" | grep -qi -E 'riscv|riscv64'; then
    echo "RISC-V detected in (${arch_probes}): excluding cargo plugins that require unavailable gstreamer-validate/dav1d pkg-config deps"
    prune_gst_plugins_rs_workspace_member "${standalone_cargo_toml}" "utils/validate"
    prune_gst_plugins_rs_workspace_member "${standalone_cargo_toml}" "video/dav1d"

    if validate_pkg_names="$(cargo_metadata_package_names 'validate')"; then
      if [ -n "${validate_pkg_names}" ]; then
        for name in ${validate_pkg_names}; do
          build_cmd+=(--exclude "${name}")
        done
        echo "Excluding validate packages: ${validate_pkg_names}"
      else
        build_cmd+=(--exclude gst-plugin-validate)
        echo "No validate package names found via cargo metadata; excluding gst-plugin-validate"
      fi
    else
      build_cmd+=(--exclude gst-plugin-validate)
      echo "cargo metadata unavailable; excluding gst-plugin-validate by default"
    fi

    if dav1d_pkg_names="$(cargo_metadata_package_names 'dav1d')"; then
      if [ -n "${dav1d_pkg_names}" ]; then
        for name in ${dav1d_pkg_names}; do
          build_cmd+=(--exclude "${name}")
        done
        echo "Excluding dav1d packages: ${dav1d_pkg_names}"
      else
        build_cmd+=(--exclude gst-plugin-dav1d)
        echo "No dav1d package names found via cargo metadata; excluding gst-plugin-dav1d"
      fi
    else
      build_cmd+=(--exclude gst-plugin-dav1d)
      echo "cargo metadata unavailable; excluding gst-plugin-dav1d by default"
    fi
  fi

  if ! "${build_cmd[@]}"; then
    echo "ERROR: cargo build for gst-plugins-rs failed"
    exit 1
  fi
}
