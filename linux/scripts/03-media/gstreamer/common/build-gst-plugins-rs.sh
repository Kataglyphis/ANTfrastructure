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
  local rust_per_job_mb=""
  local rust_cores=""
  local rust_avail_mb=""
  local rust_max_by_mem=1
  local rust_jobs=1

  if command -v compute_rust_jobs >/dev/null 2>&1; then
    compute_rust_jobs
    return 0
  fi

  if [ "${AGGRESSIVE_PARALLELISM:-false}" = "true" ]; then
    rust_per_job_mb="${RUST_PER_JOB_MB:-1800}"
  else
    rust_per_job_mb="${RUST_PER_JOB_MB:-2500}"
  fi

  rust_cores="$(nproc --all 2>/dev/null || echo 1)"
  rust_avail_mb="$(awk '/MemAvailable/ {printf("%d",$2/1024); exit}' /proc/meminfo 2>/dev/null || true)"
  [ -n "${rust_avail_mb}" ] || rust_avail_mb=2048
  rust_max_by_mem=$(( rust_avail_mb / rust_per_job_mb ))
  [ "${rust_max_by_mem}" -lt 1 ] && rust_max_by_mem=1

  if [ "${rust_cores}" -lt "${rust_max_by_mem}" ]; then
    rust_jobs="${rust_cores}"
  else
    rust_jobs="${rust_max_by_mem}"
  fi

  [ "${rust_jobs}" -lt 1 ] && rust_jobs=1
  printf '%s' "${rust_jobs}"
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

build_standalone_gst_plugins_rs() {
  local plugin_rs_dir="/opt/gst-plugins-rs"
  local standalone_cargo_toml=""
  local rust_jobs=""
  local cargo_host_cc=""
  local cargo_host_linker=""
  local cargo_host_cxx=""
  local cargo_host_cxx_wrapper=""
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

  # Cargo still builds host-side proc-macros and build scripts while compiling
  # the plugin crates for the cross target.
  if command -v cross_build_enabled >/dev/null 2>&1 && cross_build_enabled && [ -d /opt/cross-bin ]; then
    export PATH="${PATH#/opt/cross-bin:}"
  fi

  if command -v cross_build_enabled >/dev/null 2>&1 && cross_build_enabled; then
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

  prune_gst_plugins_rs_workspace_member "${standalone_cargo_toml}" "analytics/burn"

  arch_for_excludes="${TARGET_MACHINE_ARCH} ${TARGETARCH:-} ${TARGET_ARCH:-} $(dpkg-architecture -q DEB_HOST_ARCH 2>/dev/null || true) $(dpkg-architecture -q DEB_HOST_MULTIARCH 2>/dev/null || true) $(uname -m 2>/dev/null || true)"
  if echo "${arch_for_excludes}" | grep -qi -E 'riscv|riscv64|aarch64|arm64|arm'; then
    default_excludes+=(--exclude gst-plugin-csound --exclude csound --exclude csound-sys)
    prune_gst_plugins_rs_workspace_member "${standalone_cargo_toml}" "audio/csound"
    echo "Host arch detected in (${arch_for_excludes}): added csound-related excludes to DEFAULT_EXCLUDES"
  fi

  build_cmd=(cargo build --workspace "${cargo_flags[@]}" --jobs "${CARGO_BUILD_JOBS}")
  build_cmd+=("${default_excludes[@]}")
  if command -v cross_build_enabled >/dev/null 2>&1 && cross_build_enabled; then
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
