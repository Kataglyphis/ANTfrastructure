#!/usr/bin/env bash
set -euo pipefail

run_gstreamer_meson_setup() {
  local -a extra_meson_flags=()

  if [ -n "${EXTRA_MESON_ARGS:-}" ]; then
    read -r -a extra_meson_flags <<< "${EXTRA_MESON_ARGS}"
  fi

  uv run meson setup builddir "${MESON_FLAGS[@]}" "${extra_meson_flags[@]}" "$@"
}

prebuild_gstreamer_riscv_targets() {
  local -a glib_subprojects=()
  local -a graphene_subprojects=()
  local glib_lib_target="glib-2.0"
  local gobject_lib_target="gobject-2.0"
  local gmodule_lib_target="gmodule-2.0"
  local gio_lib_target="gio-2.0"
  local gmodule_visibility_target=""
  local graphene_gir_target=""

  if [ "${TARGET_MACHINE_ARCH}" != "riscv64" ]; then
    return 0
  fi

  shopt -s nullglob
  glib_subprojects=(subprojects/glib-[0-9]*)
  graphene_subprojects=(subprojects/graphene-[0-9]*)
  shopt -u nullglob

  if [ "${#glib_subprojects[@]}" -gt 0 ]; then
    gmodule_visibility_target="subprojects/$(basename "${glib_subprojects[0]}")/gmodule/gmodule-visibility.h"

    echo "Prebuilding ${gmodule_visibility_target} before Graphene GIR generation"
    uv run meson compile -C builddir --jobs 1 "${gmodule_visibility_target}"
    echo "Prebuilding ${glib_lib_target}, ${gobject_lib_target}, ${gmodule_lib_target} and ${gio_lib_target} before Graphene GIR generation"
    uv run meson compile -C builddir --jobs 1 "${glib_lib_target}" "${gobject_lib_target}" "${gmodule_lib_target}" "${gio_lib_target}"
  fi

  if [ "${#graphene_subprojects[@]}" -gt 0 ]; then
    graphene_gir_target="subprojects/$(basename "${graphene_subprojects[0]}")/src/Graphene-1.0.gir"
    echo "Prebuilding ${graphene_gir_target} before full compile to satisfy GTK cross-introspection ordering"
    uv run meson compile -C builddir --jobs 1 "${graphene_gir_target}"
  fi
}

compute_gstreamer_meson_jobs() {
  local per_job_mb=1500
  local cores=""
  local avail_mb=""
  local max_by_mem=1
  local jobs=1

  if command -v compute_jobs_with_mem_cap >/dev/null 2>&1; then
    if [ "${AGGRESSIVE_PARALLELISM:-false}" = "true" ]; then
      compute_jobs_with_mem_cap "" 1000
    else
      compute_jobs_with_mem_cap "" 1500
    fi
    return 0
  fi

  [ "${AGGRESSIVE_PARALLELISM:-false}" = "true" ] && per_job_mb=1000
  cores="$(nproc --all)"
  avail_mb="$(awk '/MemAvailable/ {printf("%d",$2/1024); exit}' /proc/meminfo)"
  [ -n "${avail_mb}" ] || avail_mb=2048
  max_by_mem=$(( avail_mb / per_job_mb ))
  [ "${max_by_mem}" -lt 1 ] && max_by_mem=1

  if [ "${cores}" -lt "${max_by_mem}" ]; then
    jobs="${cores}"
  else
    jobs="${max_by_mem}"
  fi

  [ "${jobs}" -lt 1 ] && jobs=1
  printf '%s' "${jobs}"
}

build_gstreamer_monorepo() {
  local host_arch=""
  local deb_host_multiarch_dir=""
  local sys_pkgconf_dir=""
  local opencv_prefix="${OPENCV_OUTPUT_DIR:-/opt/opencv4}"
  local opencv_libdir=""
  local target_python_libdir=""
  local target_python_pkgconfig_dir=""
  local tflite_pkg_config_name=""
  local tflite_includedir=""
  local tflite_libdir=""
  local python_feature="enabled"

  echo ""
  echo "Setting up Meson build..."

  host_arch="$(uname -m)"
  TARGET_MACHINE_ARCH="${TARGET_ARCH:-${TARGETARCH:-${host_arch}}}"
  if command -v cross_build_enabled >/dev/null 2>&1 && cross_build_enabled; then
    setup_linux_cross_env
    TARGET_MACHINE_ARCH="$(cross_target_arch)"
    if command -v prepare_host_cargo_toolchain_env >/dev/null 2>&1; then
      prepare_host_cargo_toolchain_env
    fi
    if [ "${GSTREAMER_ENABLE_PYTHON_BINDINGS:-true}" != "true" ]; then
      python_feature="disabled"
    fi
  fi
  prepare_cross_python_build_config

  if [ "${python_feature}" = "enabled" ] && \
     command -v cross_build_enabled >/dev/null 2>&1 && cross_build_enabled && \
     command -v cross_target_python_libdir >/dev/null 2>&1; then
    target_python_libdir="$(cross_target_python_libdir 2>/dev/null || true)"
    if [ -n "${target_python_libdir}" ]; then
      append_meson_arg "-Dgst-python:libpython-dir=${target_python_libdir}"
    fi
  fi

  if [ "${python_feature}" = "enabled" ] && \
     command -v cross_build_enabled >/dev/null 2>&1 && cross_build_enabled && \
     command -v cross_target_python_pkgconfig_dir >/dev/null 2>&1; then
    target_python_pkgconfig_dir="$(cross_target_python_pkgconfig_dir 2>/dev/null || true)"
    if [ -n "${target_python_pkgconfig_dir}" ]; then
      case ":${PKG_CONFIG_PATH:-}:" in
        *":${target_python_pkgconfig_dir}:"*) ;;
        *) export PKG_CONFIG_PATH="${target_python_pkgconfig_dir}${PKG_CONFIG_PATH:+:${PKG_CONFIG_PATH}}" ;;
      esac
    fi
  fi

  MESON_FLAGS=(
    "--prefix=${GSTREAMER_PREFIX}"
    "-Dbuildtype=${BUILD_TYPE_LOWER}"
    "-Dgpl=enabled"
    "-Ddoc=disabled"
    "-Dbase=enabled"
    "-Dgood=enabled"
    "-Dgtk_doc=disabled"
    "-Dgtk=enabled"
    "-Dugly=enabled"
    "-Dges=enabled"
    "-Dbad=enabled"
    "-Dgst-plugins-bad:tflite=enabled"
    "-Dgst-plugins-bad:opencv=enabled"
    "-Dgst-plugins-bad:onnx=enabled"
    "-Dtools=enabled"
    "-Dlibav=enabled"
    "-Ddevtools=enabled"
    "-Dexamples=disabled"
    "-Dtests=disabled"
    "-Drtsp_server=enabled"
    "-Dpython=${python_feature}"
    "-Dintrospection=enabled"
  )

  case "${TARGET_MACHINE_ARCH}" in
    riscv*|*riscv*)
      echo "Target arch '${TARGET_MACHINE_ARCH}' detected: keeping GTK, Python and introspection enabled while skipping -Drs (Rust bindings)"
      MESON_FLAGS+=("-Drs=disabled")
      MESON_FLAGS+=("-Ddevtools=disabled")
      append_meson_arg "--force-fallback-for=glib-2.0,gobject-2.0,gio-2.0,gio-unix-2.0,gmodule-2.0,gmodule-no-export-2.0,gmodule-export-2.0,gthread-2.0,cairo,cairo-gobject,pango,pangoft2,pangocairo,pangoxft,harfbuzz,gdk-pixbuf-2.0,gobject-introspection-1.0,pygobject-3.0,graphene-1.0,graphene-gobject-1.0,gtk4,gtk4-x11,gtk4-wayland"
      append_meson_arg "-Dgobject-introspection:gi_cross_use_prebuilt_gi=true"
      if [ -x /usr/local/bin/g-ir-scanner-riscv64-binary-wrapper ]; then
        append_meson_arg "-Dgobject-introspection:gi_cross_binary_wrapper=/usr/local/bin/g-ir-scanner-riscv64-binary-wrapper"
      fi
      if [ -x /usr/local/bin/g-ir-scanner-ldd-riscv64-cross ]; then
        append_meson_arg "-Dgobject-introspection:gi_cross_ldd_wrapper=/usr/local/bin/g-ir-scanner-ldd-riscv64-cross"
      fi
      append_meson_arg "-Dgraphene:introspection=enabled"
      append_meson_arg "-Dpango:introspection=disabled"
      append_meson_arg "-Dharfbuzz:introspection=disabled"
      append_meson_arg "-Dgdk-pixbuf:glycin=disabled"
      append_meson_arg "-Dgdk-pixbuf:man=false"
      append_meson_arg "-Dgst-plugins-rs:whisper=disabled"
      echo "Disabling gst-plugins-rs whisper plugin for RISC-V host arch"
      ;;
    aarch64*|arm*)
      echo "Target arch '${TARGET_MACHINE_ARCH}' detected: enabling -Drs (Rust bindings) but disabling csound"
      MESON_FLAGS+=("-Drs=enabled")
      append_meson_arg "-Dgst-plugins-rs:csound=disabled"
      append_meson_arg "-Dgst-plugins-rs:whisper=disabled"
      echo "Disabling gst-plugins-rs whisper plugin for ARM host arch"
      ;;
    *)
      MESON_FLAGS+=("-Drs=enabled")
      ;;
  esac

  if [ -n "${CROSS_PYTHON_BUILD_CONFIG:-}" ]; then
    append_meson_arg "-Dpython.build_config=${CROSS_PYTHON_BUILD_CONFIG}"
    if [ "${GSTREAMER_ENABLE_PYTHON_BINDINGS:-true}" = "true" ]; then
      append_meson_arg "-Dgst-python:python.build_config=${CROSS_PYTHON_BUILD_CONFIG}"
    fi
  fi

  if command -v append_meson_cross_flags >/dev/null 2>&1; then
    append_meson_cross_flags MESON_FLAGS
  fi
  if command -v append_meson_native_flags >/dev/null 2>&1; then
    append_meson_native_flags MESON_FLAGS
  fi

  MESON_WRAP_MODE="${MESON_WRAP_MODE:-nofallback}"
  case " ${EXTRA_MESON_ARGS} " in
    *" --wrap-mode="*) ;;
    *) EXTRA_MESON_ARGS="${EXTRA_MESON_ARGS} --wrap-mode=${MESON_WRAP_MODE}" ;;
  esac
  case " ${EXTRA_MESON_ARGS} " in
    *" --force-fallback-for="*) ;;
    *) EXTRA_MESON_ARGS="${EXTRA_MESON_ARGS} --force-fallback-for=pygobject-3.0" ;;
  esac
  append_meson_arg "-Dpygobject:tests=false"

  dump_debug_info | tee /tmp/gstreamer-debug-info.log || true

  if command -v cross_target_triplet >/dev/null 2>&1 && cross_build_enabled; then
    deb_host_multiarch_dir="$(cross_target_triplet)"
  fi
  if [ -z "${deb_host_multiarch_dir}" ]; then
    deb_host_multiarch_dir="$(dpkg-architecture -q DEB_HOST_MULTIARCH 2>/dev/null || true)"
  fi

  if [ -n "${deb_host_multiarch_dir}" ]; then
    sys_pkgconf_dir="/usr/lib/${deb_host_multiarch_dir}/pkgconfig"
    export CSOUND_LIB_DIR="/usr/lib/${deb_host_multiarch_dir}"
  else
    sys_pkgconf_dir="/usr/lib/pkgconfig"
    export CSOUND_LIB_DIR="/usr/lib"
  fi

  PKG_CONFIG_LIBDIR="${sys_pkgconf_dir}:/usr/lib/pkgconfig:/usr/local/lib/pkgconfig"
  if [ -n "${PKG_CONFIG_LIBDIR_ORIG:-}" ]; then
    PKG_CONFIG_LIBDIR="${PKG_CONFIG_LIBDIR}:${PKG_CONFIG_LIBDIR_ORIG}"
  fi
  export PKG_CONFIG_LIBDIR

  if [ -d /usr/share/pkgconfig ]; then
    PKG_CONFIG_LIBDIR="${PKG_CONFIG_LIBDIR}:/usr/share/pkgconfig"
    export PKG_CONFIG_LIBDIR
  fi

  if command -v cross_build_enabled >/dev/null 2>&1 && cross_build_enabled && [ -n "${deb_host_multiarch_dir}" ] && [ -d "/usr/include/${deb_host_multiarch_dir}" ]; then
    append_env_flag CPPFLAGS "-idirafter /usr/include/${deb_host_multiarch_dir}"
    append_env_flag CFLAGS "-idirafter /usr/include/${deb_host_multiarch_dir}"
    append_env_flag CXXFLAGS "-idirafter /usr/include/${deb_host_multiarch_dir}"
  fi

  if command -v cross_build_enabled >/dev/null 2>&1 && cross_build_enabled && [ -d /usr/include ]; then
    append_env_flag CPPFLAGS "-idirafter /usr/include"
    append_env_flag CFLAGS "-idirafter /usr/include"
    append_env_flag CXXFLAGS "-idirafter /usr/include"
  fi

  if command -v cross_build_enabled >/dev/null 2>&1 && cross_build_enabled && [ -n "${deb_host_multiarch_dir}" ]; then
    append_env_flag LDFLAGS "-L/usr/lib/${deb_host_multiarch_dir}"
    append_env_flag LDFLAGS "-Wl,-rpath-link,/usr/lib/${deb_host_multiarch_dir}"
  fi

  for opencv_libdir in "${opencv_prefix}/lib" "${opencv_prefix}/lib64"; do
    [ -d "${opencv_libdir}" ] || continue
    if [ -e "${opencv_libdir}/libopencv_tracking.so" ]; then
      # gst-plugins-bad/ext/opencv links opencv_tracking via a raw -l flag.
      append_env_flag LDFLAGS "-L${opencv_libdir}"
      append_env_flag LDFLAGS "-Wl,-rpath-link,${opencv_libdir}"
      break
    fi
  done

  if command -v cross_build_enabled >/dev/null 2>&1 && cross_build_enabled; then
    for dep in tensorflowlite_c tensorflow-lite; do
      if pkg-config --exists "${dep}" 2>/dev/null; then
        tflite_pkg_config_name="${dep}"
        break
      fi
    done

    if [ -n "${tflite_pkg_config_name}" ]; then
      tflite_includedir="$(pkg-config --variable=includedir "${tflite_pkg_config_name}" 2>/dev/null || true)"
      tflite_libdir="$(pkg-config --variable=libdir "${tflite_pkg_config_name}" 2>/dev/null || true)"

      if [ -n "${tflite_includedir}" ]; then
        append_env_flag CPPFLAGS "-idirafter ${tflite_includedir}"
        append_env_flag CFLAGS "-idirafter ${tflite_includedir}"
        append_env_flag CXXFLAGS "-idirafter ${tflite_includedir}"
      fi
      if [ -n "${tflite_libdir}" ]; then
        append_env_flag LDFLAGS "-L${tflite_libdir}"
        append_env_flag LDFLAGS "-Wl,-rpath-link,${tflite_libdir}"
      fi

      echo "Resolved ${tflite_pkg_config_name} for Meson probes: includedir='${tflite_includedir:-}' libdir='${tflite_libdir:-}'"
    fi
  fi

  echo "--- cairo / pkg-config debug ---" | tee /tmp/gstreamer-cairo-debug.txt
  echo "PKG_CONFIG PATH: PKG_CONFIG_PATH='${PKG_CONFIG_PATH:-}'" | tee -a /tmp/gstreamer-cairo-debug.txt
  echo "PKG_CONFIG LIBDIR: PKG_CONFIG_LIBDIR='${PKG_CONFIG_LIBDIR:-}'" | tee -a /tmp/gstreamer-cairo-debug.txt
  echo "DEB_HOST_MULTIARCH: $(dpkg-architecture -q DEB_HOST_MULTIARCH 2>/dev/null || true)" | tee -a /tmp/gstreamer-cairo-debug.txt
  which pkg-config || true | tee -a /tmp/gstreamer-cairo-debug.txt
  pkg-config --version 2>&1 | tee -a /tmp/gstreamer-cairo-debug.txt || true
  for p in "/usr/lib/${deb_host_multiarch_dir:-}/pkgconfig" /usr/lib/pkgconfig /usr/local/lib/pkgconfig; do
    echo "listing: $p" | tee -a /tmp/gstreamer-cairo-debug.txt
    find "$p" -mindepth 1 -maxdepth 1 2>/dev/null | sed -n '1,20p' | tee -a /tmp/gstreamer-cairo-debug.txt || true
    [ -f "$p/cairo.pc" ] && echo "FOUND: $p/cairo.pc" | tee -a /tmp/gstreamer-cairo-debug.txt || true
  done
  pkg-config --cflags --libs cairo 2>&1 | tee -a /tmp/gstreamer-cairo-debug.txt || true

  if ! pkg-config --exists cairo 2>/dev/null; then
    if command -v cross_build_enabled >/dev/null 2>&1 && cross_build_enabled && \
       command -v cross_target_arch >/dev/null 2>&1 && [ "$(cross_target_arch)" = "riscv64" ]; then
      echo "cairo not found in target pkg-config paths on riscv64 cross build; keeping PKG_CONFIG_LIBDIR intact and relying on Meson subproject fallback" | tee -a /tmp/gstreamer-cairo-debug.txt || true
    else
      echo "cairo not found with PKG_CONFIG_LIBDIR='${PKG_CONFIG_LIBDIR:-}' - trying fallback by unsetting PKG_CONFIG_LIBDIR" | tee -a /tmp/gstreamer-cairo-debug.txt || true
      if env -u PKG_CONFIG_LIBDIR pkg-config --exists cairo 2>/dev/null; then
        echo "Fallback: cairo found after unsetting PKG_CONFIG_LIBDIR; proceeding using fallback search paths" | tee -a /tmp/gstreamer-cairo-debug.txt || true
        unset PKG_CONFIG_LIBDIR
      else
        echo "Fallback also failed: cairo still not found" | tee -a /tmp/gstreamer-cairo-debug.txt || true
      fi
    fi
  fi
  echo "--- end cairo debug ---" | tee -a /tmp/gstreamer-cairo-debug.txt

  if ! run_gstreamer_meson_setup > /tmp/meson-setup.log 2>&1; then
    echo "Meson setup failed; printing verbose output..."
    run_gstreamer_meson_setup -Dwarning_level=2 | tee /tmp/meson-setup-fallback.log 2>&1 || true
  fi

  echo "Updating subprojects..."
  uv run meson subprojects update > /dev/null 2>&1 || true
  if command -v patch_gstreamer_sources >/dev/null 2>&1; then
    # Wrapped subprojects such as gst-plugins-rs may only exist after Meson has
    # populated the source tree, so reapply source patches here before compile.
    patch_gstreamer_sources "$(pwd)" "${EXTRA_MESON_ARGS}"
  fi
  prebuild_gstreamer_riscv_targets

  echo "Compiling GStreamer (this may take a while)..."
  JOBS="$(compute_gstreamer_meson_jobs)"
  export JOBS
  echo "Using JOBS=$JOBS (AGGRESSIVE_PARALLELISM=${AGGRESSIVE_PARALLELISM:-false})"

  echo "Compiling GStreamer..."
  if ! uv run meson compile -C builddir --jobs "${JOBS}" 2>&1 | tee /tmp/meson-compile.log; then
    echo "ERROR: Meson compile failed"
    echo "==> Letzte Zeilen der Compile-Logs:"
    tail -n 20000 /tmp/meson-compile.log || true
    echo "==> Meson log:"
    tail -n +1 builddir/meson-logs/meson-log.txt || true
    dmesg | tail -n 100 | grep -i -E "out of memory|killed process" || true
    exit 1
  fi

  echo "Installing GStreamer..."
  if command -v cross_build_enabled >/dev/null 2>&1 && cross_build_enabled; then
    # Cross-build: meson install may fail because post-install scripts
    # (e.g. GLib's gio-querymodules) try to run target binaries on the
    # build host.  Install via DESTDIR into a staging directory first,
    # then copy to the real prefix; ignore install-script failures.
    local gst_stage="$(mktemp -d "/tmp/gst-stage.XXXXXX")"
    set +euo pipefail
    uv run meson install -C builddir --destdir "${gst_stage}" --no-rebuild >/tmp/gst-install.log 2>&1
    local install_rc=$?
    set -euo pipefail
    if [ "${install_rc}" -eq 0 ]; then
      echo "GStreamer cross-install via DESTDIR succeeded"
    else
      echo "WARNING: GStreamer cross-install had errors (rc=${install_rc}); copying staged files anyway"
    fi
    if [ -d "${gst_stage}${GSTREAMER_PREFIX}" ]; then
      cp -a "${gst_stage}${GSTREAMER_PREFIX}/"* "${GSTREAMER_PREFIX}/" 2>/dev/null || true
    fi
    if [ -d "${gst_stage}/usr/local" ]; then
      cp -a "${gst_stage}/usr/local/"* /usr/local/ 2>/dev/null || true
    fi
    rm -rf "${gst_stage}"
    if ! find "${GSTREAMER_PREFIX}" -name "libgstreamer*.so*" 2>/dev/null | grep -q .; then
      echo "ERROR: GStreamer cross-install produced no libgstreamer libraries" >&2
      exit 1
    fi
  else
    if ! uv run meson install -C builddir; then
      echo "ERROR: Meson install failed"
      echo "==> Meson log:"
      tail -n +1 builddir/meson-logs/meson-log.txt || true
      echo "==> Meson install log (if present):"
      tail -n +1 builddir/meson-logs/install-log.txt || true
      exit 1
    fi
  fi
}
