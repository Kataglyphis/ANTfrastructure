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
  # RV1-FOLGE (2026-08-20): the whole prebuild exists to satisfy GIR
  # generation ordering — with introspection now DISABLED for the riscv64
  # cross build (see the meson-args branch), the Graphene-1.0.gir target no
  # longer exists and `meson compile <gir>` dies "target not found". Skip.
  if printf '%s\n' "${MESON_FLAGS[@]}" | grep -q '^-Dintrospection=disabled$'; then
    echo "Skipping glib/graphene GIR prebuild: introspection is disabled for this cross build"
    return 0
  fi

  shopt -s nullglob
  glib_subprojects=(subprojects/glib-[0-9]*)
  graphene_subprojects=(subprojects/graphene-[0-9]*)
  shopt -u nullglob

  if [ "${#glib_subprojects[@]}" -gt 0 ]; then
    gmodule_visibility_target="subprojects/$(basename "${glib_subprojects[0]}")/gmodule/gmodule-visibility.h"

    # Ninja/Makefile dependency ordering means a single meson compile call
    # suffices to build the header before the libs it depends on; collapsing
    # what was two sequential --jobs 1 invocations into one removes a full
    # ninja startup/scheduling round-trip.
    echo "Prebuilding ${gmodule_visibility_target}, ${glib_lib_target}, ${gobject_lib_target}, ${gmodule_lib_target} and ${gio_lib_target} before Graphene GIR generation"
    uv run meson compile -C builddir --jobs 1 \
        "${gmodule_visibility_target}" \
        "${glib_lib_target}" \
        "${gobject_lib_target}" \
        "${gmodule_lib_target}" \
        "${gio_lib_target}"
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

_gst_monorepo_env_setup() {
  # cross_build_is_active is provided by cross-env.sh via media_common_init.
  # Minimal fallback if the module chain didn't load it — normalizing both
  # sides (the raw OCI-vs-uname comparison reported "cross active" on native
  # arm64 hosts; this copy had drifted from the documented fix). NOTE: bash
  # function definitions are global, so defining this inside the setup
  # function still leaks — acceptable for a guarded fallback.
  if ! command -v cross_build_is_active >/dev/null 2>&1; then
    cross_build_is_active() {
      # Delegate to the authoritative predicate when available — this branch
      # was MISSING from this copy only (the 01-core and 03-media/core
      # siblings both have it; complexity audit F-C found the structural
      # drift survived the earlier arch-normalization re-sync).
      if command -v cross_build_enabled >/dev/null 2>&1; then
        cross_build_enabled
        return $?
      fi
      [ "${BUILD_MODE:-native}" = "cross" ] || return 1
      local _t _b
      _t="$(arch_normalize "${TARGET_ARCH:-${TARGETARCH:-}}" 2>/dev/null || printf '%s' "${TARGET_ARCH:-${TARGETARCH:-}}")"
      _b="$(arch_normalize "${BUILDARCH:-$(uname -m)}" 2>/dev/null || printf '%s' "${BUILDARCH:-$(uname -m)}")"
      [ -n "${_t}" ] && [ "${_t}" != "${_b}" ]
    }
  fi

  local host_arch=""

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

  # gtk (gtk4/gtk3 display sinks) is built from source with the Vulkan renderer,
  # which references vkCreateWaylandSurfaceKHR. The full Vulkan SDK on amd64 exports
  # it, but the cross-built RUNTIME Vulkan on arm64/riscv64 does NOT — so
  # libgtk-4.so.1 fails to load ("undefined symbol: vkCreateWaylandSurfaceKHR") and
  # libgstgtk4.so / libgstgtk.so become unloadable. They are display-only sinks,
  # useless in a headless container, so disable the gtk plugin (and its heavy gtk4
  # subproject build) on the affected cross arches; amd64 keeps it.
  gtk_feature="${gtk_feature:-enabled}"
  if cross_build_is_active; then
    case "${TARGET_MACHINE_ARCH}" in
      riscv*|*riscv*|aarch64*|arm*) gtk_feature="disabled" ;;
    esac
  fi

  # GSTREAMER_ENABLE_PYTHON_BINDINGS env var (set externally) can force-disable
  # Python bindings even outside the cross-build check, preventing pycairo builds.
  if [ "${GSTREAMER_ENABLE_PYTHON_BINDINGS:-true}" != "true" ]; then
    python_feature="disabled"
  fi
}

_gst_monorepo_python_config() {
  local target_python_libdir=""
  local target_python_pkgconfig_dir=""

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
}

_gst_monorepo_meson_base_flags() {
  MESON_FLAGS=(
    "--prefix=${GSTREAMER_PREFIX}"
    "-Dbuildtype=${BUILD_TYPE_LOWER}"
    "-Dgpl=enabled"
    "-Ddoc=disabled"
    "-Dbase=enabled"
    "-Dgood=enabled"
    "-Dgtk_doc=disabled"
    "-Dgtk=${gtk_feature:-enabled}"
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
}

_gst_monorepo_arch_flags() {
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
      # RV1-FOLGE (2026-08-20): with ports glib-dev now installed in the
      # riscv64 sysroot, gobject-introspection-1.84's gir build dies with
      # `Subproject "subprojects/glib" required but not found` (meson
      # system-vs-subproject resolution shifted; deterministic). Take the
      # SAME route the arm64 cross branch has always taken: introspection
      # OFF for the cross build. GIRs/typelibs served no consumer on
      # riscv64 anyway (gst-python is disabled above). RESIDUAL: re-enable
      # once the g-i subproject resolution is understood (backlog RV1-GI).
      MESON_FLAGS+=("-Dintrospection=disabled")
      append_meson_arg "-Dgraphene:introspection=disabled"
      # RV1-FOLGE 3 (2026-08-20): the glib SUBPROJECT builds its test suite by
      # default and gdbus-server-auth.c needs dbus/dbus.h — libdbus dev is not
      # in the riscv64 sysroot. Cross builds never run subproject tests;
      # don't compile them.
      append_meson_arg "-Dglib:tests=false"
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
    # Keep -Drs at whatever the per-arch block chose (enabled for arm64/riscv64).
    # Previously forced to disabled for cross because target Rust crates linked
    # with the host cc and failed; prepare_host_cargo_toolchain_env now exports
    # CARGO_TARGET_<triple>_LINKER pointing at the cross gcc, so the monorepo can
    # cross-build and install the gst-plugins-rs cdylibs directly.
    echo "Cross build: gst-plugins-rs built in-monorepo (target Rust linker wired via cargo env)"

    # Disable the Rust plugins whose native -sys deps / host tools are absent when
    # cross-compiling — these hard-fail the cargo build (no meson dependency() gate
    # to auto-skip them, unlike webrtcbin2 which auto-skips via dependency('rice-proto')).
    # Per-arch set mirrors build-gst-plugins-rs.sh's standalone cross excludes:
    #   validate -> gstreamer-validate-1.0.pc (devtools disabled on ALL cross)
    #   csound   -> libcsound (excluded arm+riscv)   whisper -> whisper.cpp (arm+riscv)
    #   skia     -> Skia built from source (skia-sys, cross-hostile both)
    #   burn     -> heavy ML crate (pruned both)
    #   dav1d    -> libdav1d: RISC-V ONLY (arm64 has libdav1d and builds fine)
    # "all Rust plugins that can cross-compile for this arch"; re-enable a plugin
    # once its native dep is provided for the target.
    # validate genuinely needs gstreamer-validate-1.0 (devtools, off for all cross).
    local -a _rs_disable=(validate)
    # arm64 cross-builds the full Rust plugin set — csound/whisper/skia/burn/dav1d
    # all validated once the target Rust linker + libcsound64 (+ csound-sys
    # char-signedness patch) were wired, so arm64 only disables `validate` (needs
    # gstreamer-validate devtools, off for cross).
    # riscv64 PROBE: testing whether whisper/skia/burn/dav1d cross-build here the
    # way they did on arm64. csound stays disabled — riscv64 Ports has no
    # libcsound64 to link against. Re-add any crate that hard-fails below.
    #   skia -> HARD-FAILS: skia-bindings' bundled gn/ninja build injects the
    #     clang-only flag `--target=riscv64-linux-gnu`, which the GCC cross
    #     compiler (riscv64-linux-gnu-g++) rejects with "unrecognized
    #     command-line option". One cargo custom-target => this kills the whole
    #     gst-plugins-rs set, so skia must be disabled for the riscv64 cross.
    if [ "$(cross_target_arch 2>/dev/null || true)" = "riscv64" ]; then
      _rs_disable+=(csound skia)
    fi
    local _rs_plugin
    for _rs_plugin in "${_rs_disable[@]}"; do
      append_meson_arg "-Dgst-plugins-rs:${_rs_plugin}=disabled"
    done
  fi
}

_gst_monorepo_cross_flags() {
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
}

_gst_monorepo_pkgconfig_env() {
  local deb_host_multiarch_dir=""
  local sys_pkgconf_dir=""

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

  if cross_build_is_active && [ -n "${deb_host_multiarch_dir}" ]; then
    append_cross_idirafter "${deb_host_multiarch_dir}"
  fi

  if cross_build_is_active && [ -n "${deb_host_multiarch_dir}" ]; then
    append_flag_if_missing LDFLAGS "-L/usr/lib/${deb_host_multiarch_dir}"
    append_flag_if_missing LDFLAGS "-Wl,-rpath-link,/usr/lib/${deb_host_multiarch_dir}"
  fi
}

_gst_monorepo_opencv_flags() {
  local opencv_prefix="${OPENCV_OUTPUT_DIR:-/opt/opencv5}"
  local opencv_libdir=""

  for opencv_libdir in "${opencv_prefix}/lib" "${opencv_prefix}/lib64"; do
    [ -d "${opencv_libdir}" ] || continue
    if [ -e "${opencv_libdir}/libopencv_tracking.so" ]; then
      # gst-plugins-bad/ext/opencv links opencv_tracking via a raw -l flag.
      append_flag_if_missing LDFLAGS "-L${opencv_libdir}"
      append_flag_if_missing LDFLAGS "-Wl,-rpath-link,${opencv_libdir}"
      break
    fi
  done
}

_gst_monorepo_tflite_flags() {
  local tflite_pkg_config_name=""
  local tflite_includedir=""
  local tflite_libdir=""

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
        append_flag_if_missing CPPFLAGS "-idirafter ${tflite_includedir}"
        append_flag_if_missing CFLAGS "-idirafter ${tflite_includedir}"
        append_flag_if_missing CXXFLAGS "-idirafter ${tflite_includedir}"
      fi
      if [ -n "${tflite_libdir}" ]; then
        append_flag_if_missing LDFLAGS "-L${tflite_libdir}"
        append_flag_if_missing LDFLAGS "-Wl,-rpath-link,${tflite_libdir}"
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
}

_gst_monorepo_meson_setup_run() {
  if ! run_gstreamer_meson_setup > /tmp/meson-setup.log 2>&1; then
    echo "Meson setup failed; retrying with verbose output..." >&2
    if ! run_gstreamer_meson_setup -Dwarning_level=2 | tee /tmp/meson-setup-fallback.log 2>&1; then
      echo "ERROR: Meson setup failed both attempts. See /tmp/meson-setup.log" >&2
      exit 1
    fi
  fi

  if [ ! -f builddir/.subprojects_updated ]; then
    echo "Updating subprojects..."
    # NO blanket `meson subprojects update` here any more (supply-chain audit
    # #21): it moved git-backed wraps to their wrap `revision`, which for
    # several GStreamer wraps is a BRANCH — quietly advancing pinned sources,
    # with all output suppressed. The wraps checked out by the pinned
    # ${GSTREAMER_VERSION} tag are already the intended set; tarball wraps
    # stay protected by upstream's source_hash either way.
    touch builddir/.subprojects_updated
  fi
  if command -v patch_gstreamer_sources >/dev/null 2>&1; then
    # Wrapped subprojects such as gst-plugins-rs may only exist after Meson has
    # populated the source tree, so reapply source patches here before compile.
    patch_gstreamer_sources "$(pwd)"
  fi
  prebuild_gstreamer_riscv_targets
}

# csound-sys 0.1.2 (pulled by gst-plugin-csound) hardcodes signed-char array
# initialisers `[0i8; 64usize]` for its CsoundParams-style structs. bindgen maps
# the underlying C `char[64]` fields to `[u8; 64]` on unsigned-char targets
# (aarch64, riscv64), so those literals fail to type-check when cross-compiling
# ("expected u8, found i8"). It is a crates.io dependency, so we cannot patch it
# in-tree; rewrite the extracted registry source to an *untyped* `[0; 64usize]`
# instead — the literal then infers the field's element type on every arch,
# including signed-char x86 where it stays i8. cargo has already unpacked the
# crate into the registry (that is what produced the compile error), so the sed
# lands on the real source before the incremental rebuild picks it up. Returns
# success only if at least one file was rewritten; idempotent.
patch_csound_sys_char_signedness() {
  local cargo_home="${CARGO_HOME:-/usr/local/cargo}" f patched=0
  while IFS= read -r f; do
    if grep -q '\[0i8; 64usize\]' "$f" 2>/dev/null; then
      sed -i 's/\[0i8; 64usize\]/[0; 64usize]/g' "$f" && {
        patched=1
        echo "  patched csound-sys char signedness: $f"
      }
    fi
  done < <(find "${cargo_home}/registry/src" -path '*csound-sys-*/src/*.rs' 2>/dev/null || true)
  [ "${patched}" = "1" ]
}

_gst_monorepo_compile() {
  echo "Compiling GStreamer (this may take a while)..."
  # Use the memory-aware job count (was previously raw `nproc`, uncapped, which
  # oversubscribed heavy C++/Rust link jobs and OOM-killed the compile).
  JOBS="$(compute_gstreamer_meson_jobs)"
  export JOBS
  echo "Using JOBS=$JOBS (mem-capped; GSTREAMER_MB_PER_JOB=${GSTREAMER_MB_PER_JOB:-2500}, AGGRESSIVE_PARALLELISM=${AGGRESSIVE_PARALLELISM:-false})"

  # Patch FIRST: on warm caches the csound-sys crate is already extracted in
  # the persistent cargo-registry mount, so rewriting it before the compile
  # skips paying a full failed compile + incremental retry. A cold cache only
  # extracts the crate DURING the compile — the guarded retry below still
  # covers that first-ever build. Idempotent; rc intentionally ignored (rc 1
  # just means "nothing extracted yet / already patched").
  patch_csound_sys_char_signedness || true

  echo "Compiling GStreamer..."
  if uv run meson compile -C builddir --jobs "${JOBS}" 2>&1 | tee /tmp/meson-compile.log; then
    return 0
  fi

  # Cross csound-sys char-signedness failure: patch the extracted crate and retry
  # once (the retry is incremental — only csound-sys and its dependent plugins
  # rebuild). Guarded so it only triggers for that specific, known failure.
  if grep -q 'csound-sys' /tmp/meson-compile.log 2>/dev/null \
     && grep -qE "expected .u8., found .i8." /tmp/meson-compile.log 2>/dev/null \
     && patch_csound_sys_char_signedness; then
    echo "Retrying meson compile after csound-sys char-signedness patch..."
    if uv run meson compile -C builddir --jobs "${JOBS}" 2>&1 | tee /tmp/meson-compile.log; then
      return 0
    fi
  fi

  echo "ERROR: Meson compile failed"
  echo "==> Last lines of compile logs:"
  tail -n 20000 /tmp/meson-compile.log || true
  echo "==> Meson log:"
  tail -n +1 builddir/meson-logs/meson-log.txt || true
  dmesg | tail -n 100 | grep -i -E "out of memory|killed process" || true
  exit 1
}

# Fallback when the cross DESTDIR install produced no libraries (post-install
# scripts can't run target binaries): copy libs/plugins/binaries straight out of
# the meson builddir into the prefix. Fatal if still no libgstreamer afterward.
_gst_install_fallback_copy() {
  if [ -d "builddir/subprojects/gstreamer/libs/gst" ]; then
    cp -a builddir/subprojects/gstreamer/libs/gst/*/libgstreamer*.so* "${GSTREAMER_PREFIX}/lib/" 2>/dev/null || true
    cp -a builddir/subprojects/gstreamer/gst/libgstreamer*.so* "${GSTREAMER_PREFIX}/lib/" 2>/dev/null || true
    cp -a builddir/subprojects/*/gst-libs/gst/*/libgst*.so* "${GSTREAMER_PREFIX}/lib/" 2>/dev/null || true
  fi
  # Also copy any .so from the builddir into prefix, plus the CLI binaries.
  find builddir -name "*.so" -path "*/libgst*" -exec cp -aL {} "${GSTREAMER_PREFIX}/lib/" \; 2>/dev/null || true
  find builddir -name "*.so" -path "*/gstreamer-1.0/*" -exec cp -aL {} "${GSTREAMER_PREFIX}/lib/multiarch/gstreamer-1.0/" \; 2>/dev/null || true
  find builddir \( -name "gst-launch-1.0" -o -name "gst-inspect-1.0" \) -exec cp -aL {} "${GSTREAMER_PREFIX}/bin/" \; 2>/dev/null || true
  ldconfig 2>/dev/null || true
  if ! find "${GSTREAMER_PREFIX}" -name "libgstreamer*.so*" 2>/dev/null | grep -q .; then
    echo "ERROR: GStreamer cross-install produced no libgstreamer libraries" >&2
    exit 1
  fi
}

_gst_monorepo_install() {
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
      _gst_install_fallback_copy
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

build_gstreamer_monorepo() {
  local python_feature="enabled"
  # Declared local (not just assigned in _gst_monorepo_env_setup) so a prior
  # cross arm64/riscv64 invocation that set gtk_feature=disabled can't leak a
  # stale value into a later native/amd64 call in the same shell process.
  local gtk_feature="enabled"

  # SCCACHE-RUST OFF (2026-08-20): the toolchain cargo config wires sccache as
  # rustc-wrapper; its in-container server died mid-compile in THREE separate
  # media rounds this session ("Failed to send/receive data from server" /
  # "No such file or directory" fatals on trivial crates) and killed otherwise
  # green gstreamer builds at 99%. Empty RUSTC_WRAPPER beats the cargo config
  # (env > config precedence; empty = no wrapper). ccache keeps covering
  # C/C++; sccache-for-rust returns via the controlled ENABLE_SCCACHE_RUST /
  # SCC1 validation, not as a silent default.
  export RUSTC_WRAPPER=""

  _gst_monorepo_env_setup
  _gst_monorepo_python_config
  _gst_monorepo_meson_base_flags
  _gst_monorepo_arch_flags
  _gst_monorepo_cross_flags
  _gst_monorepo_pkgconfig_env
  _gst_monorepo_opencv_flags
  _gst_monorepo_tflite_flags
  _gst_monorepo_meson_setup_run
  _gst_monorepo_compile
  _gst_monorepo_install
}
