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
  # The prebuild only orders GIR generation: with introspection disabled the
  # Graphene-1.0.gir target does not exist and `meson compile` dies "not found".
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

    # One call suffices: ninja orders the header before the libs needing it.
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
  # Peak RSS here is ~2-3 GB per job, far above the global AGGRESSIVE estimate,
  # so size by AVAILABLE memory; see docs/build-parallelism-memory-tuning.md.
  local jobs mb_per_job
  mb_per_job="${GSTREAMER_MB_PER_JOB:-2500}"

  if command -v compute_jobs_with_mem_cap >/dev/null 2>&1; then
    jobs="$(compute_jobs_with_mem_cap "" "${mb_per_job}")"
  else
    jobs="$(nproc --all 2>/dev/null || echo 1)"
  fi

  # Cross subprojects build under QEMU, which uses ~3x the memory per job.
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
  # cross_build_is_active comes from cross-env.sh; this guarded fallback must
  # normalize BOTH arches (raw OCI-vs-uname reported "cross" on native arm64).
  if ! command -v cross_build_is_active >/dev/null 2>&1; then
    cross_build_is_active() {
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

  # The cross-built RUNTIME Vulkan lacks vkCreateWaylandSurfaceKHR, so gtk's
  # Vulkan renderer makes libgtk-4.so.1 and the gtk sinks unloadable — and they
  # are display-only, useless in a headless container.
  gtk_feature="${gtk_feature:-enabled}"
  if cross_build_is_active; then
    case "${TARGET_MACHINE_ARCH}" in
      riscv*|*riscv*|aarch64*|arm*) gtk_feature="disabled" ;;
    esac
  fi

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
      # Keep introspection ENABLED here (g-i cross wrappers below): the g-i
      # break was a poisoned ports glib-2.0.pc, and disabling it also drops
      # /opt/gstreamer's glib .pc export that libcamera/opencv consume.
      # Force graphene introspection on to avoid dangling .gir deps in ninja.
      append_meson_arg "-Dgraphene:introspection=enabled"
      # The glib subproject's test suite needs dbus/dbus.h, absent from the
      # riscv64 sysroot; cross builds never run subproject tests anyway.
      append_meson_arg "-Dglib:tests=false"
      # Under force_fallback_for GTK looks for pango in its OWN subprojects/,
      # but the pango wrap lives at the GStreamer top level.
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
        # LOG9: introspection was disabled unconditionally for arm64 cross
        # ("g-ir-compiler needs qemu exe_wrapper"), but pre-setup.sh creates
        # the arm64 qemu wrappers (same as riscv64). Keep introspection ENABLED
        # when the wrappers exist; fall back to disabled only if they don't.
        if [ -x /usr/local/bin/g-ir-scanner-arm64-binary-wrapper ] \
           && [ -x /usr/local/bin/g-ir-scanner-ldd-arm64-cross ]; then
          echo "ARM cross build: keeping introspection ENABLED (qemu wrappers present)"
          append_meson_arg "-Dgobject-introspection:gi_cross_use_prebuilt_gi=true"
          append_meson_arg "-Dgobject-introspection:gi_cross_binary_wrapper=/usr/local/bin/g-ir-scanner-arm64-binary-wrapper"
          append_meson_arg "-Dgobject-introspection:gi_cross_ldd_wrapper=/usr/local/bin/g-ir-scanner-ldd-arm64-cross"
          append_meson_arg "-Dpango:introspection=disabled"
          append_meson_arg "-Dharfbuzz:introspection=disabled"
        else
          echo "ARM cross build: disabling introspection (qemu wrappers not found)"
          MESON_FLAGS+=("-Dintrospection=disabled")
        fi
      fi
      ;;
    *)
      MESON_FLAGS+=("-Drs=enabled")
      ;;
  esac

  if cross_build_is_active; then
    # -Drs stays as the per-arch block chose: prepare_host_cargo_toolchain_env
    # exports CARGO_TARGET_<triple>_LINKER, so target crates link with cross gcc.
    echo "Cross build: gst-plugins-rs built in-monorepo (target Rust linker wired via cargo env)"

    # Cargo has no dependency() gate, so ONE plugin whose native dep is missing
    # hard-fails the whole set. validate needs gstreamer-validate (devtools, off
    # for all cross builds).
    local -a _rs_disable=(validate)
    # riscv64 only. skia: skia-bindings' gn build injects the clang-only
    # `--target=riscv64-linux-gnu`, which the GCC cross g++ rejects.
    # csound: the old reason ("Ports has no libcsound64") is FALSE --
    # libcsound64-dev exists on resolute riscv64 and the image already ships
    # libcsound64.so.6.0. Kept disabled only because one failing plugin
    # hard-fails the whole rs set. docs/refactoring-backlog.md
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

  # setup_linux_cross_env can leave CXX unexported when require_cross_gcc_tool
  # g++ cannot find the binary; the meson cross file needs both.
  if [ "${BUILD_MODE:-native}" = "cross" ] && { [ -z "${CC:-}" ] || [ -z "${CXX:-}" ]; }; then
    if command -v resolve_cross_cc_cxx_for_arch >/dev/null 2>&1; then
      resolve_cross_cc_cxx_for_arch || true
    fi
  fi

  if command -v append_meson_cross_flags >/dev/null 2>&1; then
    append_meson_cross_flags MESON_FLAGS
    # The SDK image's cross file pins host pkgconfig paths; drop the key so
    # meson falls back to the PKG_CONFIG_LIBDIR set below.
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

  # Cross: exclude host /usr/lib/pkgconfig — its .pc files (e.g. x11-xcb) point
  # at x86_64 library paths. Meson honours this once the cross-file key is gone.
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

  # Idempotent sanitizer for the stray `}` a since-fixed generate_pkgconfig_file()
  # bug left after -ltensorflow-lite in older toolchain images.
  if [ -f /usr/local/lib/pkgconfig/tensorflow-lite.pc ]; then
    if grep -q 'ltensorflow-lite}' /usr/local/lib/pkgconfig/tensorflow-lite.pc 2>/dev/null; then
      sed -i 's/-ltensorflow-lite}/-ltensorflow-lite/g' /usr/local/lib/pkgconfig/tensorflow-lite.pc
    fi
  fi
  # Meson probes libraries via the cross compiler's -print-file-name, which
  # ignores pkg-config's -L flags; symlink into its default search dirs.
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
    # No blanket `meson subprojects update` (supply-chain audit #21): it moves
    # git-backed wraps to a `revision` that is a BRANCH, past the pinned tag.
    touch builddir/.subprojects_updated
  fi
  if command -v patch_gstreamer_sources >/dev/null 2>&1; then
    # Wrapped subprojects such as gst-plugins-rs may only exist after Meson has
    # populated the source tree, so reapply source patches here before compile.
    patch_gstreamer_sources "$(pwd)"
  fi
  prebuild_gstreamer_riscv_targets
}

# csound-sys 0.1.2's `[0i8; 64usize]` literals fail on unsigned-char targets
# (aarch64/riscv64, where bindgen maps `char[64]` to `[u8; 64]`); an untyped
# literal infers per arch. crates.io dep, so patch the unpacked registry copy.
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
  JOBS="$(compute_gstreamer_meson_jobs)"
  export JOBS
  echo "Using JOBS=$JOBS (mem-capped; GSTREAMER_MB_PER_JOB=${GSTREAMER_MB_PER_JOB:-2500}, AGGRESSIVE_PARALLELISM=${AGGRESSIVE_PARALLELISM:-false})"

  # Patch FIRST: on a warm cargo-registry mount the crate is already extracted,
  # so this saves a failed compile. rc 1 just means "nothing extracted yet".
  patch_csound_sys_char_signedness || true

  echo "Compiling GStreamer..."
  if uv run meson compile -C builddir --jobs "${JOBS}" 2>&1 | tee /tmp/meson-compile.log; then
    return 0
  fi

  # Cold cache: the crate is only extracted DURING the compile, so patch and
  # retry once — guarded to that one known failure, and incremental.
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

# Fallback when the cross DESTDIR install produced no libraries: copy them
# straight out of the meson builddir. Fatal if libgstreamer is still missing.
_gst_install_fallback_copy() {
  if [ -d "builddir/subprojects/gstreamer/libs/gst" ]; then
    cp -a builddir/subprojects/gstreamer/libs/gst/*/libgstreamer*.so* "${GSTREAMER_PREFIX}/lib/" 2>/dev/null || true
    cp -a builddir/subprojects/gstreamer/gst/libgstreamer*.so* "${GSTREAMER_PREFIX}/lib/" 2>/dev/null || true
    cp -a builddir/subprojects/*/gst-libs/gst/*/libgst*.so* "${GSTREAMER_PREFIX}/lib/" 2>/dev/null || true
  fi
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
    # Post-install scripts (e.g. GLib's gio-querymodules) try to run TARGET
    # binaries on the build host, so stage via DESTDIR and tolerate their errors.
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
  # Declared local so a prior cross call's gtk_feature=disabled cannot leak into
  # a later native call in the same shell process.
  local gtk_feature="enabled"

  # Rust caching goes through the GUARDED launcher, so a sccache hiccup costs
  # hits, not the build; RUSTC_WRAPPER="" opts out. docs/build-cache-tiers.md.
  if [ -z "${RUSTC_WRAPPER+x}" ]; then
    for _rw in /opt/scripts/core/sccache-launcher.sh; do
      if [ -x "${_rw}" ]; then
        export RUSTC_WRAPPER="${_rw}"
        break
      fi
    done
    # Owner decision "immer sccache": stages without 01-core get BARE sccache
    # (as common.sh does) even though it aborts a compile on its own errors.
    export RUSTC_WRAPPER="${RUSTC_WRAPPER:-sccache}"
  fi

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
