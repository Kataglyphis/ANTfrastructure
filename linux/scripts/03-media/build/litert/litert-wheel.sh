#!/usr/bin/env bash
# Wheel helpers use the build driver scope; see docs/cross-build-verification.md#litert-wheel-build-helpers.

_litert_wheel_prepare_env() {
    if cross_build_is_active; then
        cross_wheel_build=true
        if command -v cross_target_python_dev_ready >/dev/null 2>&1 && ! cross_target_python_dev_ready; then
            warn Target Python development files are unavailable; skipping LiteRT Python wheel build in cross mode
            return 1
        fi
        info "Attempting LiteRT Python wheel build in cross mode for $(cross_target_arch)"
    fi

    pip_pkg_dir="${LITERT_SRC}/tflite/tools/pip_package"
    if [ ! -d "${pip_pkg_dir}" ]; then
        info "No Python packaging detected for LiteRT at ${pip_pkg_dir}; skipping wheel build"
        return 1
    fi

    info Detected Python packaging in LiteRT source - attempting to build wheel
    pushd "${pip_pkg_dir}" > /dev/null || return 1

    export PYTHON="${HOST_PYTHON_BIN}"
    if [ -z "${PYTHON}" ]; then
        warn No python found in PATH to build LiteRT wheel
        popd > /dev/null || return 1
        return 1
    fi

    info Building wheel via build_pip_package_with_cmake.sh...
    export TENSORFLOW_DIR="${LITERT_SRC}"
    export TENSORFLOW_LITE_DIR="${LITERT_SRC}/tflite"
    export TENSORFLOW_TARGET="native"
    export TENSORFLOW_VERSION="${LITERT_VERSION#v}"

    _litert_link_tensorflow_lite

    # The patched pip script passes EXTRA_CMAKE_FLAGS, word-split, to every cmake call.
    extra_cmake_flags="-DCMAKE_POLICY_VERSION_MINIMUM=${CMAKE_POLICY_VERSION_MINIMUM:-3.5} -DRUY_PROFILER=0 -DRUY_ENABLE_INSTRUMENTATION=OFF -DRUY_PROFILER_INSTRUMENTATION=OFF -DRUY_BUILD_TOOLS=OFF -DRUY_BUILD_TESTING=OFF -DLITERT_AUTO_BUILD_TFLITE=ON -DLITERT_ENABLE_GPU=OFF -DLITERT_ENABLE_NPU=OFF -DTFLITE_ENABLE_RUY=ON -DPython3_EXECUTABLE=${PYTHON}"
    if [ -n "${LITERT_QNN_HOME:-}" ]; then
        # The later duplicate -D wins over the NPU=OFF default above.
        extra_cmake_flags+=" -DQAIRT_HEADERS_DIR=$(_litert_qairt_include_dir) -DLITERT_ENABLE_NPU=ON"
    fi
    extra_cmake_flags+=" $(litert_eigen_fetch_flags_str)"
    export EXTRA_CMAKE_FLAGS="${extra_cmake_flags}"

    # Upstream's pip script hardcodes what a cross build must override; see docs/upstreamable-patches.md § 13.
    bash /opt/scripts/core/apply-patch.sh \
        /opt/scripts/patches/litert/001-env-var-overrides.patch \
        "${pip_pkg_dir}" \
        "LiteRT build_pip_package_with_cmake.sh env var overrides"
    _fixed="${pip_pkg_dir}/build_pip_package_with_cmake.sh"
  # Explicit: the trailing assignment would otherwise BE the exit status.
  return 0
}

_litert_wheel_native_args() {
    export WHEEL_PROJECT_NAME="ai_edge_litert"

    append_litert_preferred_cmake_compiler_args native_compiler_args
    if [ "${#native_compiler_args[@]}" -gt 0 ]; then
        extra_cmake_flags+=" ${native_compiler_args[*]}"
    fi
}

_litert_wheel_cross_paths() {
    tflite_host_tools_dir="$(resolve_litert_tflite_host_tools_dir || true)"
    if [ -z "${tflite_host_tools_dir}" ]; then
        err Could not resolve TFLite host tools directory containing flatc for cross wheel build
    fi
    wheel_platform_name="$(litert_cross_wheel_platform_tag || true)"
    if [ -z "${wheel_platform_name}" ]; then
        err "Could not resolve wheel platform tag for target architecture $(cross_target_arch)"
    fi
    if [ -n "${python_major_minor}" ] && command -v cross_target_python_include_dir >/dev/null 2>&1; then
        target_python_include="$(cross_target_python_include_dir 2>/dev/null || true)"
        target_python_arch_include="$(cross_target_python_arch_include_dir 2>/dev/null || true)"
        if [ ! -d "${target_python_include}" ] || [ ! -d "${target_python_arch_include}" ]; then
            target_python_include=""
            target_python_arch_include=""
        fi
    fi
}

_litert_wheel_cross_args() {
    local wheel_cross_args=()

    python_major_minor="${python_major_minor:-$(host_python_major_minor 2>/dev/null || true)}"

    if command -v append_cmake_cross_args >/dev/null 2>&1; then
        append_cmake_cross_args wheel_cross_args
    fi
    if command -v append_cmake_cross_archiver_args >/dev/null 2>&1; then
        append_cmake_cross_archiver_args wheel_cross_args resolve_cross_archive_tool
    fi
    _litert_wheel_cross_paths

    extra_cmake_flags+=" ${wheel_cross_args[*]}"
    extra_cmake_flags+=" -DTFLITE_HOST_TOOLS_DIR=${tflite_host_tools_dir}"
    if [ -n "${target_python_include}" ]; then
        extra_cmake_flags+=" -DPYTHON_INCLUDE_DIR=${target_python_include}"
        extra_cmake_flags+=" -DPYTHON_INCLUDE_PATH=${target_python_include}"
        info Cross wheel target Python include dir: ${target_python_include}
        info Cross wheel target Python arch include dir: ${target_python_arch_include}
    fi

    export EXTRA_CMAKE_FLAGS="${extra_cmake_flags}"
    export TENSORFLOW_TARGET="native"
    export WHEEL_PLATFORM_NAME="${wheel_platform_name}"
    # Emit -I only for resolved dirs: a bare -I corrupts the command line and breaks Abseil's C++17 probe.
    local litert_build_flags="-idirafter /usr/include"
    [ -n "${TF_CXX_FLAGS:-}" ] && litert_build_flags+=" ${TF_CXX_FLAGS}"
    [ -n "${target_python_include:-}" ] && litert_build_flags+=" -I${target_python_include}"
    [ -n "${target_python_arch_include:-}" ] && litert_build_flags+=" -I${target_python_arch_include}"
    # pybind11 and numpy headers are arch-independent, so the host venv's include dirs serve a cross target.
    local _pybind11_inc="" _numpy_inc=""
    if [ -n "${PYTHON:-}" ]; then
        _pybind11_inc="$(python_module_include "${PYTHON}" pybind11)"
        _numpy_inc="$(python_module_include "${PYTHON}" numpy)"
    fi
    [ -n "${_pybind11_inc}" ] && litert_build_flags+=" -I${_pybind11_inc}"
    [ -n "${_numpy_inc}" ] && litert_build_flags+=" -I${_numpy_inc}"
    export BUILD_FLAGS="${litert_build_flags}"
    info "Building LiteRT wheel in cross mode for $(cross_target_arch)"
    info Cross wheel platform tag: ${WHEEL_PLATFORM_NAME}
    info Cross wheel host tools dir: ${tflite_host_tools_dir}
}

_litert_wheel_native_finalize() {
    export TENSORFLOW_TARGET="native"
    unset WHEEL_PLATFORM_NAME || true
    export EXTRA_CMAKE_FLAGS="${extra_cmake_flags}"
}

_litert_wheel_run() {
    export CMAKE_POLICY_VERSION_MINIMUM="${CMAKE_POLICY_VERSION_MINIMUM:-3.5}"

    bash "${_fixed}" "${TENSORFLOW_TARGET}" > pip_build.log 2>&1 || {
        warn pip wheel failed for LiteRT source. Last 1000 lines of log:
        tail -n 1000 pip_build.log
        if [ "${cross_wheel_build}" = "true" ]; then
            warn Continuing without a local LiteRT wheel for the cross build
            popd > /dev/null || return 1
            return 0
        fi
        exit 1
    }

    info pip wheel success! Last 50 lines of log:
    tail -n 50 pip_build.log

    find "gen/tflite_pip" -name "*.whl" -type f -exec cp -v {} "${LITERT_PREFIX}/wheels/" \; 2>/dev/null || warn No wheels found after build script
    _litert_fix_pywrap_ext_name
    popd > /dev/null || return 1
}

# The wheel names the ext file _pywrap_tensorflow_* while its PyInit_ symbol and importers use _pywrap_litert_*.
_litert_fix_pywrap_ext_name() {
    local py="${PYTHON:-python3}" wheel tmp unpacked tf_so _renamed
    command -v "${py}" >/dev/null 2>&1 || return 0
    for wheel in "${LITERT_PREFIX}/wheels/"ai_edge_litert-*.whl; do
        [ -f "${wheel}" ] || continue
        tmp="$(mktemp -d)"
        if ! "${py}" -m wheel unpack "${wheel}" -d "${tmp}" >/dev/null 2>&1; then
            rm -rf "${tmp}"; continue
        fi
        _renamed=""
        while IFS= read -r tf_so; do
            [ -n "${tf_so}" ] || continue
            mv "${tf_so}" "${tf_so/_pywrap_tensorflow_/_pywrap_litert_}" && _renamed=1
        done < <(find "${tmp}" -name '_pywrap_tensorflow_interpreter_wrapper*.so')
        if [ -n "${_renamed}" ]; then
            unpacked="$(first_match "${tmp}" -mindepth 1 -maxdepth 1 -type d)"
            if "${py}" -m wheel pack "${unpacked}" -d "${LITERT_PREFIX}/wheels/" >/dev/null 2>&1; then
                info "Renamed misnamed LiteRT pywrap ext to _pywrap_litert_interpreter_wrapper in $(basename "${wheel}")"
            else
                warn "Failed to repack LiteRT wheel after pywrap rename: $(basename "${wheel}")"
            fi
        fi
        rm -rf "${tmp}"
    done
}

_litert_build_wheel() {
    local cross_wheel_build=false
    local pip_pkg_dir=""
    local extra_cmake_flags=""
    local _fixed=""
    local native_compiler_args=()
    local wheel_platform_name=""
    local tflite_host_tools_dir=""
    local python_major_minor="${PYTHON_MAJOR_MINOR:-}"
    local target_python_include=""
    local target_python_arch_include=""

    _litert_wheel_prepare_env || return 0
    _litert_wheel_native_args
    if cross_build_is_active; then
        _litert_wheel_cross_args
    else
        _litert_wheel_native_finalize
    fi
    _litert_wheel_run
}
