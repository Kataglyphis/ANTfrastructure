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
  # GStreamer's monorepo links heavy C++ TUs (gtk4, webrtc, opencv/onnx plugins)
  # and Rust crates (gst-plugins-rs) whose peak RSS is ~2-3 GB per job — far more
  # than the global AGGRESSIVE 800-1000 MB/job estimate. Size the job count by
  # AVAILABLE memory at a realistic per-job budget: big-RAM hosts (>=32 GB) get
  # more jobs (RAM used fully) while smaller hosts throttle automatically, and
  # neither oversubscribes into OOM. Deliberately ignores AGGRESSIVE_PARALLELISM
  # here — its estimate is too optimistic for this stage. Override the budget
  # with GSTREAMER_MB_PER_JOB, or pin the count with PARALLEL_JOBS.
  local jobs mb_per_job
  mb_per_job="${GSTREAMER_MB_PER_JOB:-2500}"

  if command -v compute_jobs_with_mem_cap >/dev/null 2>&1; then
    jobs="$(compute_jobs_with_mem_cap "" "${mb_per_job}")"
  else
    jobs="$(nproc --all 2>/dev/null || echo 1)"
  fi

  # arm64/riscv64 cross subprojects build under QEMU, which uses ~3x the memory
  # per job; apply an extra memory-derived headroom cap (scales with RAM instead
  # of a hardcoded ceiling, so a big host still gets more than 2 jobs).
  if cross_build_is_active; then
    case "${TARGET_MACHINE_ARCH:-}" in
      arm64|aarch64|riscv64|riscv*)
        local qemu_jobs
        qemu_jobs="$(compute_jobs_with_mem_cap "" "$(( mb_per_job * 3 ))" 2>/dev/null || echo 2)"
        [ "${jobs}" -gt "${qemu_jobs}" ] 2>/dev/null && jobs="${qemu_jobs}"
        ;;
    esac
  fi

  [ "${jobs}" -ge 1 ] 2>/dev/null || jobs=1
  printf '%s' "${jobs}"
}

build_gstreamer_monorepo() {
  # cross_build_is_active is provided by cross-env.sh via media_common_init.
  # Minimal fallback if the module chain didn't load it.
  if ! command -v cross_build_is_active >/dev/null 2>&1; then
    cross_build_is_active() {
      [ "${BUILD_MODE:-native}" = "cross" ] && \
      [ "${TARGET_ARCH:-${TARGETARCH:-}}" != "${BUILDARCH:-$(uname -m)}" ]
    }
  fi

  local host_arch=""
  local deb_host_multiarch_dir=""
  local sys_pkgconf_dir=""
  local opencv_prefix="${OPENCV_OUTPUT_DIR:-/opt/opencv5}"
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
  if cross_build_is_active; then
    setup_linux_cross_env
    TARGET_MACHINE_ARCH="$(cross_target_arch)"
    if command -v prepare_host_cargo_toolchain_env >/dev/null 2>&1; then
      prepare_host_cargo_toolchain_env
    fi
    if [ "${GSTREAMER_ENABLE_PYTHON_BINDINGS:-true}" != "true" ]; then
      python_feature="disabled"
    fi
    case "${TARGET_MACHINE_ARCH}" in
      riscv*|*riscv*|aarch64*|arm*) python_feature="disabled" ;;
    esac
  fi

  # GSTREAMER_ENABLE_PYTHON_BINDINGS env var (set externally) can force-disable
  # Python bindings even outside the cross-build check, preventing pycairo builds.
  if [ "${GSTREAMER_ENABLE_PYTHON_BINDINGS:-true}" != "true" ]; then
    python_feature="disabled"
  fi

  prepare_cross_python_build_config

  if [ "${python_feature}" = "enabled" ] && \
     cross_build_is_active && \
     command -v cross_target_python_libdir >/dev/null 2>&1; then
    target_python_libdir="$(cross_target_python_libdir 2>/dev/null || true)"
    # If cross_target_python_libdir resolved to the host /usr/local/lib
    # instead of the staged cross Python, force the correct per-arch path.
    if [ "${target_python_libdir}" = "/usr/local/lib" ] && \
       [ "${GSTREAMER_ENABLE_PYTHON_BINDINGS:-true}" = "true" ]; then
      local _cross_arch="${TARGET_MACHINE_ARCH:-riscv64}"
      local _cross_python_lib="/opt/python-cross/${_cross_arch}/usr/local/lib"
      if [ -d "${_cross_python_lib}" ] && [ -f "${_cross_python_lib}/libpython3.14.so" ]; then
        target_python_libdir="${_cross_python_lib}"
      fi
    fi
    if [ -n "${target_python_libdir}" ]; then
      append_meson_arg "-Dgst-python:libpython-dir=${target_python_libdir}"
    fi
  fi

  if [ "${python_feature}" = "enabled" ] && \
     cross_build_is_active && \
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
    "-Dgst-plugins-bad:introspection=disabled"
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

  # webrtcbin2 is built when GST_RS_BUILD_ALL=true (default); force off otherwise.
  [ "${GST_RS_BUILD_ALL:-true}" = "true" ] || MESON_FLAGS+=("-Dgst-plugins-rs:webrtcbin2=disabled")

  if cross_build_is_active; then
    echo "Cross build detected: disabling devtools (avoid cargo host-toolchain collisions)"
    MESON_FLAGS+=("-Ddevtools=disabled")
  fi

  case "${TARGET_MACHINE_ARCH}" in
    riscv*|*riscv*)
      echo "Target arch '${TARGET_MACHINE_ARCH}' detected: python disabled (no target Python dev for riscv64)"
      if [ "${GST_RS_BUILD_ALL:-true}" = "true" ]; then
        echo "GST_RS_BUILD_ALL=true: attempting Rust plugins on riscv64 (-Drs=enabled) — cross-compiling Rust to riscv64 is experimental and may fail"
        MESON_FLAGS+=("-Drs=enabled")
      else
        MESON_FLAGS+=("-Drs=disabled")
      fi
      # PTP helper fails to link on riscv64 (collect2 error with gcc cross linker).
      append_meson_arg "-Dgstreamer:ptp-helper=disabled"
      # Introspection kept enabled — exe_wrapper is provided via pre-setup.sh QEMU wrapper.
      # Force graphene introspection on to avoid dangling .gir dependency in ninja.
      append_meson_arg "-Dgraphene:introspection=enabled"
      # Pango: ensure GTK's subprojects dir can find the top-level pango subproject
      # (GTK looks for pango in its own subprojects/ directory when force_fallback_for
      # is active, but the pango wrap is at the GStreamer top level).
      local gtk_subproj="${BUILD_DIR}/gstreamer/subprojects/gtk-4.14.5/subprojects"
      if [ -d "${gtk_subproj}" ] && [ ! -e "${gtk_subproj}/pango" ]; then
        ln -snf "$(realpath "${BUILD_DIR}/gstreamer/subprojects/pango" 2>/dev/null || echo "${BUILD_DIR}/gstreamer/subprojects/pango")" "${gtk_subproj}/pango" 2>/dev/null || true
      fi
      append_meson_arg "--force-fallback-for=glib-2.0,gobject-2.0,gio-2.0,gio-unix-2.0,gmodule-2.0,gmodule-no-export-2.0,gmodule-export-2.0,gthread-2.0,cairo,cairo-gobject,pango,pangoft2,pangocairo,pangoxft,harfbuzz,gdk-pixbuf-2.0,gobject-introspection-1.0,pygobject-3.0,graphene-1.0,graphene-gobject-1.0,gtk4,gtk4-x11,gtk4-wayland"
      append_meson_arg "-Dgobject-introspection:gi_cross_use_prebuilt_gi=true"
      if [ -x /usr/local/bin/g-ir-scanner-riscv64-binary-wrapper ]; then
        append_meson_arg "-Dgobject-introspection:gi_cross_binary_wrapper=/usr/local/bin/g-ir-scanner-riscv64-binary-wrapper"
      fi
      if [ -x /usr/local/bin/g-ir-scanner-ldd-riscv64-cross ]; then
        append_meson_arg "-Dgobject-introspection:gi_cross_ldd_wrapper=/usr/local/bin/g-ir-scanner-ldd-riscv64-cross"
      fi
      append_meson_arg "-Dpango:introspection=disabled"
      append_meson_arg "-Dharfbuzz:introspection=disabled"
      append_meson_arg "-Dgdk-pixbuf:glycin=disabled"
      append_meson_arg "-Dgdk-pixbuf:man=false"
      [ "${GST_RS_BUILD_ALL:-true}" = "true" ] || { append_meson_arg "-Dgst-plugins-rs:whisper=disabled"; echo "Disabling gst-plugins-rs whisper plugin for RISC-V host arch"; }
      ;;
    aarch64*|arm*)
      echo "Target arch '${TARGET_MACHINE_ARCH}' detected: enabling -Drs (Rust bindings)"
      MESON_FLAGS+=("-Drs=enabled")
      if [ "${GST_RS_BUILD_ALL:-true}" != "true" ]; then
        append_meson_arg "-Dgst-plugins-rs:csound=disabled"
        append_meson_arg "-Dgst-plugins-rs:whisper=disabled"
        echo "Disabling gst-plugins-rs csound/whisper plugins for ARM host arch"
      fi
      if [ "${BUILD_MODE:-native}" = "cross" ]; then
        echo "ARM cross build: disabling introspection (g-ir-compiler needs qemu exe_wrapper)"
        MESON_FLAGS+=("-Dintrospection=disabled")
      fi
      ;;
    *)
      MESON_FLAGS+=("-Drs=enabled")
      ;;
  esac

  if cross_build_is_active; then
    echo "Cross build detected: disabling gst-plugins-rs subproject in monorepo"
    echo "(standalone cargo build handles Rust plugins independently)"
    MESON_FLAGS+=("-Drs=disabled")
  fi

  if [ -n "${CROSS_PYTHON_BUILD_CONFIG:-}" ]; then
    append_meson_arg "-Dpython.build_config=${CROSS_PYTHON_BUILD_CONFIG}"
    if [ "${GSTREAMER_ENABLE_PYTHON_BINDINGS:-true}" = "true" ]; then
      append_meson_arg "-Dgst-python:python.build_config=${CROSS_PYTHON_BUILD_CONFIG}"
    fi
  fi

  # Ensure CC/CXX are exported for the meson cross file. setup_linux_cross_env
  # may fail to export CXX if require_cross_gcc_tool g++ cannot find the binary.
  # Use canonical helpers from compiler-resolution.sh as fallback.
  if [ "${BUILD_MODE:-native}" = "cross" ] && { [ -z "${CC:-}" ] || [ -z "${CXX:-}" ]; }; then
    if command -v resolve_cross_cc_cxx_for_arch >/dev/null 2>&1; then
      resolve_cross_cc_cxx_for_arch || true
    fi
  fi

  if command -v append_meson_cross_flags >/dev/null 2>&1; then
    append_meson_cross_flags MESON_FLAGS
    # Remove pkg_config_libdir from the cross file so meson falls back to
    # the PKG_CONFIG_LIBDIR env var (which we set without the host x86_64
    # pkgconfig path).  The SDK image's cross file includes host paths.
    if [ -n "${MESON_CROSS_FILE:-}" ] && [ -f "${MESON_CROSS_FILE}" ]; then
      sed -i '/^pkg_config_libdir = /d' "${MESON_CROSS_FILE}"
    fi
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

  dump_debug_info > /tmp/gstreamer-debug-info.log 2>&1 || true

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

  # When cross-compiling, exclude /usr/lib/pkgconfig (host pkgconfig) to
  # prevent pkg-config from returning host .pc files (e.g. x11-xcb.pc) that
  # point to x86_64 library paths.  Meson also respects this env var when
  # the cross file's pkg_config_libdir is absent (which we handle below).
  if cross_build_is_active && [ "${BUILD_MODE:-native}" = "cross" ]; then
    PKG_CONFIG_LIBDIR="${sys_pkgconf_dir}:/usr/local/lib/pkgconfig"
  else
    PKG_CONFIG_LIBDIR="${sys_pkgconf_dir}:/usr/lib/pkgconfig:/usr/local/lib/pkgconfig"
  fi
  if [ -n "${PKG_CONFIG_LIBDIR_ORIG:-}" ]; then
    PKG_CONFIG_LIBDIR="${PKG_CONFIG_LIBDIR}:${PKG_CONFIG_LIBDIR_ORIG}"
  fi
  export PKG_CONFIG_LIBDIR

  if [ -d /usr/share/pkgconfig ]; then
    PKG_CONFIG_LIBDIR="${PKG_CONFIG_LIBDIR}:/usr/share/pkgconfig"
    export PKG_CONFIG_LIBDIR
  fi

  if cross_build_is_active && [ -n "${deb_host_multiarch_dir}" ] && [ -d "/usr/include/${deb_host_multiarch_dir}" ]; then
    append_env_flag CPPFLAGS "-idirafter /usr/include/${deb_host_multiarch_dir}"
    append_env_flag CFLAGS "-idirafter /usr/include/${deb_host_multiarch_dir}"
    append_env_flag CXXFLAGS "-idirafter /usr/include/${deb_host_multiarch_dir}"
  fi

  if cross_build_is_active && [ -d /usr/include ]; then
    append_env_flag CPPFLAGS "-idirafter /usr/include"
    append_env_flag CFLAGS "-idirafter /usr/include"
    append_env_flag CXXFLAGS "-idirafter /usr/include"
  fi

  if cross_build_is_active && [ -n "${deb_host_multiarch_dir}" ]; then
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

  if cross_build_is_active; then
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

  # Defensive cleanup: the root-cause was a bash `${6:--L\${libdir}}` parsing
  # bug in generate_pkgconfig_file() that left a stray `}` after `-ltensorflow-lite`.
  # That's been fixed in 01-core/common.sh, but keep this idempotent sanitizer so
  # images rebuilt from older toolchain still produce a valid pc file at runtime.
  if [ -f /usr/local/lib/pkgconfig/tensorflow-lite.pc ]; then
    if grep -q 'ltensorflow-lite}' /usr/local/lib/pkgconfig/tensorflow-lite.pc 2>/dev/null; then
      sed -i 's/-ltensorflow-lite}/-ltensorflow-lite/g' /usr/local/lib/pkgconfig/tensorflow-lite.pc
    fi
  fi
  # Ensure meson's cross-compiler can find libtensorflow-lite. Meson checks
  # library existence via the cross compiler's -print-file-name, which does
  # NOT use -L flags from pkg-config. Symlink the library into one of the
  # cross-compiler's default search directories.
  if [ "${BUILD_MODE:-native}" = "cross" ] && [ -f /usr/local/lib/libtensorflow-lite.so ]; then
    for _gcc_arch in aarch64-linux-gnu riscv64-linux-gnu; do
      for _gcc_dir in /opt/gcc-*/${_gcc_arch}/lib* /opt/gcc-*/lib/gcc/${_gcc_arch}/*/; do
        [ -d "${_gcc_dir}" ] || continue
        ln -sf /usr/local/lib/libtensorflow-lite.so "${_gcc_dir}/libtensorflow-lite.so" 2>/dev/null || true
        ln -sf /usr/local/lib/libtensorflow-lite.a "${_gcc_dir}/libtensorflow-lite.a" 2>/dev/null || true
      done
    done
    export LIBRARY_PATH="/usr/local/lib:${LIBRARY_PATH:-}"
  fi

  if ! run_gstreamer_meson_setup > /tmp/meson-setup.log 2>&1; then
    echo "Meson setup failed; retrying with verbose output..." >&2
    if ! run_gstreamer_meson_setup -Dwarning_level=2 | tee /tmp/meson-setup-fallback.log 2>&1; then
      echo "ERROR: Meson setup failed both attempts. See /tmp/meson-setup.log" >&2
      exit 1
    fi
  fi

  if [ ! -f builddir/.subprojects_updated ]; then
    echo "Updating subprojects..."
    uv run meson subprojects update > /dev/null 2>&1 || true
    touch builddir/.subprojects_updated
  fi
  if command -v patch_gstreamer_sources >/dev/null 2>&1; then
    # Wrapped subprojects such as gst-plugins-rs may only exist after Meson has
    # populated the source tree, so reapply source patches here before compile.
    patch_gstreamer_sources "$(pwd)" "${EXTRA_MESON_ARGS}"
  fi
  prebuild_gstreamer_riscv_targets

  echo "Compiling GStreamer (this may take a while)..."
  # Use the memory-aware job count (was previously raw `nproc`, uncapped, which
  # oversubscribed heavy C++/Rust link jobs and OOM-killed the compile).
  JOBS="$(compute_gstreamer_meson_jobs)"
  export JOBS
  echo "Using JOBS=$JOBS (mem-capped; GSTREAMER_MB_PER_JOB=${GSTREAMER_MB_PER_JOB:-2500}, AGGRESSIVE_PARALLELISM=${AGGRESSIVE_PARALLELISM:-false})"

  echo "Compiling GStreamer..."
  if ! uv run meson compile -C builddir --jobs "${JOBS}" 2>&1 | tee /tmp/meson-compile.log; then
    echo "ERROR: Meson compile failed"
    echo "==> Last lines of compile logs:"
    tail -n 20000 /tmp/meson-compile.log || true
    echo "==> Meson log:"
    tail -n +1 builddir/meson-logs/meson-log.txt || true
    dmesg | tail -n 100 | grep -i -E "out of memory|killed process" || true
    exit 1
  fi

  echo "Installing GStreamer..."
  if cross_build_is_active; then
    # Cross-build: meson install may fail because post-install scripts
    # (e.g. GLib's gio-querymodules) try to run target binaries on the
    # build host.  Install via DESTDIR into a staging directory first,
    # then copy to the real prefix; ignore install-script failures.
    local gst_stage="$(mktemp -d "/tmp/gst-stage.XXXXXX")"
    set +e
    uv run meson install -C builddir --destdir "${gst_stage}" --no-rebuild >/tmp/gst-install.log 2>&1
    local install_rc=$?
    set -e
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
    # If DESTDIR install failed (e.g. post-install scripts can't run cross
    # binaries), fall back to copying directly from the meson builddir.
    if ! find "${GSTREAMER_PREFIX}" -name "libgstreamer*.so*" 2>/dev/null | grep -q .; then
      echo "WARNING: DESTDIR install produced no libraries; falling back to builddir copy"
      local _build_libdirs=()
      if [ -d "builddir/subprojects/gstreamer/libs/gst" ]; then
        cp -a builddir/subprojects/gstreamer/libs/gst/*/libgstreamer*.so* "${GSTREAMER_PREFIX}/lib/" 2>/dev/null || true
        cp -a builddir/subprojects/gstreamer/gst/libgstreamer*.so* "${GSTREAMER_PREFIX}/lib/" 2>/dev/null || true
        cp -a builddir/subprojects/*/gst-libs/gst/*/libgst*.so* "${GSTREAMER_PREFIX}/lib/" 2>/dev/null || true
      fi
      # Also copy any .so from the builddir into prefix
      find builddir -name "*.so" -path "*/libgst*" -exec cp -aL {} "${GSTREAMER_PREFIX}/lib/" \; 2>/dev/null || true
      find builddir -name "*.so" -path "*/gstreamer-1.0/*" -exec cp -aL {} "${GSTREAMER_PREFIX}/lib/multiarch/gstreamer-1.0/" \; 2>/dev/null || true
      # Also copy binaries
      find builddir -name "gst-launch-1.0" -o -name "gst-inspect-1.0" -exec cp -aL {} "${GSTREAMER_PREFIX}/bin/" \; 2>/dev/null || true
      ldconfig 2>/dev/null || true
      if ! find "${GSTREAMER_PREFIX}" -name "libgstreamer*.so*" 2>/dev/null | grep -q .; then
        echo "ERROR: GStreamer cross-install produced no libgstreamer libraries" >&2
        exit 1
      fi
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
