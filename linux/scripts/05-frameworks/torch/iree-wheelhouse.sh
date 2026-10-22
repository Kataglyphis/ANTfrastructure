#!/usr/bin/env bash
# The wheelhouse driver owns shared paths and Python state; this library sets no shell options.

_iree_check_prereqs() {
    command -v cmake >/dev/null 2>&1 || { warn "cmake absent; skipping IREE riscv64 runtime wheel"; return 1; }
    command -v ninja >/dev/null 2>&1 || { warn "ninja absent; skipping IREE riscv64 runtime wheel"; return 1; }

    wheel_platform="$(wheel_platform_tag || true)"
    [ -n "${wheel_platform}" ] || { warn "no riscv64 wheel platform tag; skipping IREE"; return 1; }
}

# IREE's own LLVM fork takes ~1 h, so cache it; sets ccache_cmake_args/_iree_launcher, so nothing here is local.
_iree_system_compiler() {
    local language="$1" compiler
    local -a names=(gcc cc clang)
    [ "${language}" = cxx ] && names=(g++ c++ clang++)
    for compiler in "${names[@]}"; do
        if [ -x "/usr/bin/${compiler}" ]; then
            printf '/usr/bin/%s' "${compiler}"
            return 0
        fi
    done
    printf '/usr/bin/%s' "${names[-1]}"
}

_iree_bindings_cmake_args() {
    local -n _iree_binding_args="$1"
    _iree_binding_args+=(
        -DIREE_BUILD_PYTHON_BINDINGS=ON
        -DIREE_ENABLE_PYTHON_STABLE_ABI=OFF
        -DIREE_BUILD_SAMPLES=OFF
        -DIREE_BUILD_TESTS=OFF
        -DIREE_OUTPUT_FORMAT_C=OFF
        -DIREE_ENABLE_WERROR_FLAG=OFF
        -DIREE_HAL_DRIVER_LOCAL_SYNC=ON
        -DIREE_HAL_DRIVER_LOCAL_TASK=ON
    )
}

_iree_setup_compiler_cache() {
    if command -v ccache >/dev/null 2>&1; then
        export CCACHE_DIR="${CCACHE_DIR:-/var/cache/ccache}"
        export CCACHE_MAXSIZE="${IREE_CCACHE_MAXSIZE:-64G}"
        export CCACHE_COMPRESS=1
        export CCACHE_SLOPPINESS="pch_defines,time_macros,include_file_mtime,include_file_ctime"
        mkdir -p "${CCACHE_DIR}" 2>/dev/null || true
        # Report the limit the cache really carries, so the log proves it.
        ccache -M "${CCACHE_MAXSIZE}" 2>/dev/null || warn "could not set ccache max size to ${CCACHE_MAXSIZE}"
        echo "[INFO] IREE ccache limit now: $(ccache -p 2>/dev/null | awk '/max_size/{print $2, $3}' || echo unknown)"
        # sccache ignores `-M`: its cap comes from SCCACHE_CACHE_SIZE, which mirrors the override below.
        compiler_cache_launcher_env 2>/dev/null || true
        _iree_launcher="$(compiler_cache_launcher 2>/dev/null || echo ccache)"
        case "${_iree_launcher}" in *sccache*)
            # Quiet by default; IREE_SCCACHE_LOG=sccache=info brings the client log back.
            export SCCACHE_LOG="${IREE_SCCACHE_LOG:-}"
            export SCCACHE_ERROR_LOG="${SCCACHE_ERROR_LOG:-/tmp/sccache-iree.log}" ;;
        esac
        case "${_iree_launcher}" in *sccache*)
            export SCCACHE_CACHE_SIZE="${IREE_CCACHE_MAXSIZE:-64G}"
            echo "[INFO] IREE sccache cap: SCCACHE_CACHE_SIZE=${SCCACHE_CACHE_SIZE}" ;;
        esac
        ccache_cmake_args=("-DCMAKE_C_COMPILER_LAUNCHER=${_iree_launcher}" "-DCMAKE_CXX_COMPILER_LAUNCHER=${_iree_launcher}")
        echo "[INFO] IREE ccache ON: CCACHE_DIR=${CCACHE_DIR} MAXSIZE=${CCACHE_MAXSIZE} (LLVM rebuild is one-time; reruns cache-hit)"
    else
        warn "ccache not found — IREE bundled LLVM will rebuild from scratch every run (no cross-run cache)"
    fi
}

# Fetch the pinned IREE tree into src_dir. Returns 1 on clone/submodule failure.
_iree_fetch_source() {
    # All submodules: the compiler ships the stablehlo and torch input dialects, not just TOSA/linalg.
    rm -rf "${src_dir}"
    if ! git clone --branch "${IREE_REF}" --depth 1 https://github.com/iree-org/iree.git "${src_dir}"; then
        warn "IREE clone ${IREE_REF} failed"; return 1
    fi
    if ! ( cd "${src_dir}" && git submodule update --init --recursive --depth 1 ); then
        warn "IREE submodule init failed"; return 1
    fi
}

# Defeat IREE's abi3 wheel tagging in the freshly cloned tree (src_dir).
_iree_patch_setup_py_abi3() {
    # setup.py stamps abi3 with no escape hatch; the configure's STABLE_ABI=OFF is the other half.
    local _sp
    for _sp in "${src_dir}/runtime/setup.py" "${src_dir}/compiler/setup.py"; do
        if [ -f "${_sp}" ]; then
            sed -i 's/sys\.version_info >= (3, 12) and not /False and /' "${_sp}"
        fi
    done
}

# <log> <cmake args>...: configures twice, because IREE links iree::base before the libbacktrace subdirectory caches its target.
_iree_configure_settled() {
    local log="$1"
    shift
    cmake "$@" > "${log}" 2>&1 || return 1
    cmake "$@" >> "${log}" 2>&1
}

# See docs/iree-two-stage-build.md § Stage 1 — the native amd64 host tools
_iree_host_cmake_args() {
    local -n _iree_host_args="$1"
    _iree_host_args+=(
        "${ccache_cmake_args[@]}"
        -DCMAKE_BUILD_TYPE=Release
        "-DCMAKE_C_COMPILER=$2"
        "-DCMAKE_CXX_COMPILER=$3"
        "-DPython_EXECUTABLE=${BUILD_PYTHON}"
        "-DPython3_EXECUTABLE=${BUILD_PYTHON}"
    )
}

_iree_failure_log() {
    local warning="$1" label="$2" phase="$3" log_file="$4" lines="$5"
    warn "${warning}"
    echo "----- ${label} ${phase}: last ${lines} log lines -----"
    tail -n "${lines}" "${log_file}" 2>/dev/null
    echo "----- end ${label} ${phase} log -----"
}

_iree_build_host_stage() {
    local -a host_args=()
    _iree_host_cmake_args host_args "${host_cc}" "${host_cxx}"
    # See docs/iree-two-stage-build.md § The host tools stage 2 needs from IREE_HOST_BIN_DIR
    local -a host_required_tools=(iree-c-embed-data iree-flatcc-cli)
    local -a host_compiler_modes=(OFF ON)
    # A COMPILER=OFF target imports iree-tblgen from the host, and only an ON host build installs it.
    case "${IREE_CROSS_BUILD_COMPILER}" in
      ON|on|1|true|TRUE|yes|YES) : ;;
      *)
        host_required_tools+=(iree-tblgen)
        host_compiler_modes=(ON)
        ;;
    esac
    local host_stage_ok=0 host_compiler_mode="" host_tool="" host_tools_missing=""
    for host_compiler_mode in "${host_compiler_modes[@]}"; do
        rm -rf "${host_build}" "${host_install}"
        log "IREE host stage: configuring with IREE_BUILD_COMPILER=${host_compiler_mode}"
        if ! env -u CC -u CXX -u CPP -u CFLAGS -u CXXFLAGS -u CPPFLAGS -u LDFLAGS \
                 -u AR -u RANLIB -u CMAKE_TOOLCHAIN_FILE -u CMAKE_ARGS \
                cmake -G Ninja -S "${src_dir}" -B "${host_build}" \
                "${host_args[@]}" \
                -DIREE_BUILD_COMPILER="${host_compiler_mode}" \
                -DIREE_BUILD_PYTHON_BINDINGS=OFF \
                -DIREE_BUILD_SAMPLES=OFF \
                -DIREE_BUILD_TESTS=OFF \
                -DIREE_ENABLE_WERROR_FLAG=OFF \
                -DCMAKE_INSTALL_PREFIX="${host_install}"; then
            warn "IREE host configure (IREE_BUILD_COMPILER=${host_compiler_mode}) failed"
            continue
        fi
        # BuildKit collapses ninja's output, so the log tail is the only way to see the error.
        if ! env -u CC -u CXX -u CPP -u CFLAGS -u CXXFLAGS -u CPPFLAGS -u LDFLAGS \
                 -u AR -u RANLIB -u CMAKE_TOOLCHAIN_FILE -u CMAKE_ARGS \
                cmake --build "${host_build}" --target install -- -j"${MAX_JOBS}" \
                > "${host_build}.log" 2>&1; then
            _iree_failure_log "IREE host build (IREE_BUILD_COMPILER=${host_compiler_mode}) failed" "IREE host" build "${host_build}.log" 80
            # No escalation: ON's graph is a superset of OFF's and would fail the same way hours later.
            warn "not escalating to IREE_BUILD_COMPILER=ON: its build graph is a superset of this one, so it would fail the same way after a multi-hour LLVM compile"
            break
        fi
        host_tools_missing=""
        for host_tool in "${host_required_tools[@]}"; do
            [ -x "${host_install}/bin/${host_tool}" ] || host_tools_missing+=" ${host_tool}"
        done
        if [ -z "${host_tools_missing}" ]; then
            log "IREE host stage OK (IREE_BUILD_COMPILER=${host_compiler_mode}); IREE_HOST_BIN_DIR tools present: ${host_required_tools[*]}"
            host_stage_ok=1
            break
        fi
        warn "IREE host stage (IREE_BUILD_COMPILER=${host_compiler_mode}) left ${host_install}/bin missing:${host_tools_missing} — retrying with the full host compiler"
    done
    if [ "${host_stage_ok}" != "1" ]; then
        warn "IREE host stage failed in both COMPILER=OFF and COMPILER=ON modes; cannot build the target IREE wheels"
        return 1
    fi
}

# See docs/iree-two-stage-build.md § Stage 2 — cross the runtime and the Python bindings
_iree_target_configure() {
    local label="$1" warning="$2"
    shift 2
    if _iree_configure_settled "${target_build}.cfg.log" "$@"; then
        return 0
    fi
    _iree_failure_log "${warning}" "${label}" configure "${target_build}.cfg.log" 80
    return 1
}

_iree_target_build() {
    local label="$1" warning="$2"
    if cmake --build "${target_build}" -- -j"${MAX_JOBS}" > "${target_build}.log" 2>&1; then
        return 0
    fi
    _iree_failure_log "${warning}" "${label}" build "${target_build}.log" 80
    return 1
}

_iree_build_target_cross() {
    local -a bindings_args=()
    _iree_bindings_cmake_args bindings_args
    toolchain_file="$(write_cross_cmake_toolchain_file || true)"
    [ -n "${toolchain_file}" ] || { warn "no cross toolchain file for IREE; skipping"; return 1; }
    append_common_cross_cmake_args cmake_args

    # LLVM takes its default triple from the build host; unpinned, a target iree-compile emits x86_64 code.
    iree_target_triple="$(cross_target_triplet 2>/dev/null || true)"
    if [ -n "${iree_target_triple}" ]; then
        cmake_args+=(
            "-DLLVM_HOST_TRIPLE=${iree_target_triple}"
            "-DLLVM_DEFAULT_TARGET_TRIPLE=${iree_target_triple}"
        )
    fi

    # Target SOABI for the nanobind modules; set only now, so the stage-1 host tools kept the host config.
    local iree_sysconfig_export=""
    iree_sysconfig_export="$(resolve_target_python_sysconfig_export)"
    if [ -n "${iree_sysconfig_export}" ]; then eval "${iree_sysconfig_export}"; fi

    # LLVM's NATIVE tblgen sub-build defaults to the cross compilers; ';' is CMake's list separator.
    local native_flags="-DCMAKE_C_COMPILER=${host_cc};-DCMAKE_CXX_COMPILER=${host_cxx}"
    if [ "${#ccache_cmake_args[@]}" -gt 0 ]; then
        native_flags="${native_flags};-DCMAKE_C_COMPILER_LAUNCHER=${_iree_launcher:-ccache};-DCMAKE_CXX_COMPILER_LAUNCHER=${_iree_launcher:-ccache}"
    fi

    rm -rf "${target_build}"
    # Runtime-only unless IREE_CROSS_BUILD_COMPILER=ON, so expect only the wheels it builds.
    case "${IREE_CROSS_BUILD_COMPILER}" in
      [Oo][Nn]|1|[Tt][Rr][Uu][Ee]) iree_wheel_projects=(compiler runtime) ;;
      *)                           iree_wheel_projects=(runtime) ;;
    esac
    _iree_target_configure "IREE target" "IREE riscv64 runtime configure failed (best-effort); continuing without it" -G Ninja -S "${src_dir}" -B "${target_build}" \
            -DCMAKE_TOOLCHAIN_FILE="${toolchain_file}" \
            "${cmake_args[@]}" \
            "${ccache_cmake_args[@]}" \
            -DCROSS_TOOLCHAIN_FLAGS_NATIVE="${native_flags}" \
            -DIREE_HOST_BIN_DIR="${host_install}/bin" \
            -DIREE_BUILD_COMPILER="${IREE_CROSS_BUILD_COMPILER}" \
            "${bindings_args[@]}" \
            -DCMAKE_BUILD_TYPE=Release || return 1
    _iree_target_build "IREE target" "IREE riscv64 runtime build failed (best-effort); continuing without it"
}

# Native amd64: one stage, no host/target split; leaves iree_wheel_projects empty, so both wheels.
_iree_build_target_native() {
    local -a bindings_args=()
    _iree_bindings_cmake_args bindings_args
    local native_cc="" native_cxx=""
    native_cc="$(_iree_system_compiler c)"
    native_cxx="$(_iree_system_compiler cxx)"
    local -a native_args=()
    _iree_host_cmake_args native_args "${native_cc}" "${native_cxx}"
    rm -rf "${target_build}"
    _iree_target_configure "IREE native" "IREE native configure failed" -G Ninja -S "${src_dir}" -B "${target_build}" \
            "${native_args[@]}" \
            -DIREE_BUILD_COMPILER=ON \
            "${bindings_args[@]}" || return 1
    _iree_target_build "IREE native" "IREE native build failed"
}

# Empty iree_wheel_projects means both, and the free-threaded pass after it reads the list this sets.
_iree_package_wheels() {
    rm -rf "${dist_dir}"; mkdir -p "${dist_dir}"
    local _proj _pkg
    [ "${#iree_wheel_projects[@]}" -gt 0 ] || iree_wheel_projects=(compiler runtime)
    for _proj in "${iree_wheel_projects[@]}"; do
        _pkg="iree_base_${_proj}"
        if [ ! -d "${target_build}/${_proj}" ]; then
            warn "IREE target build produced no ${_proj}/ wheel project"; return 1
        fi
        if ! "${BUILD_PYTHON}" -m pip wheel "${target_build}/${_proj}" -w "${dist_dir}" --no-deps --no-build-isolation > "${target_build}.${_proj}-wheel.log" 2>&1; then
            _iree_failure_log "IREE riscv64 ${_proj} wheel packaging failed" "IREE ${_proj}" wheel "${target_build}.${_proj}-wheel.log" 60
            return 1
        fi
        retag_directory_wheels "${dist_dir}" "${_pkg}" "${wheel_platform}" "${BUILD_PYTHON}"
    done

    shopt -s nullglob
    local -a wheels=("${dist_dir}"/iree_base_compiler-*.whl "${dist_dir}"/iree_base_runtime-*.whl "${dist_dir}"/iree-*.whl)
    shopt -u nullglob
    if [ "${#wheels[@]}" -lt "${#iree_wheel_projects[@]}" ]; then
        warn "IREE build produced ${#wheels[@]} wheel(s), expected ${#iree_wheel_projects[@]} (${iree_wheel_projects[*]})"; return 1
    fi
    cp -a "${wheels[@]}" "${APP_WHEELHOUSE_DIR}/"
    log "Built IREE wheels: $(cd "${dist_dir}" && echo iree_base_*-*.whl)"
}

# The wheels again on a free-threaded venv in the warm target tree, so only the nanobind modules rebuild.
_iree_package_free_threaded_wheels() {
    local venv="${APP_WHEELHOUSE_BUILD_ROOT}/iree-ft-venv" ft_dist="${APP_WHEELHOUSE_BUILD_ROOT}/dist-iree-free-threaded"
    local _proj t0
    _wheelhouse_start_twin iree-base-runtime "${venv}" || { [ $? -eq 1 ] && return 0; return 1; }
    _iree_free_threaded_rebuild "${venv}/bin/python" || return 1
    log "IREE: the free-threaded rebuild took $(( $(date +%s) - t0 ))s in the warm ${target_build}"
    rm -rf "${ft_dist}"
    for _proj in "${iree_wheel_projects[@]}"; do
        ft_twin_wanted "iree-base-${_proj}" || return 1
        # setup.py installs into the build/ beside it, where the GIL pass's modules would ride into the free-threaded wheel.
        rm -rf "${target_build:?}/${_proj}/build"
        if ! "${venv}/bin/python" -m pip wheel "${target_build}/${_proj}" -w "${ft_dist}/${_proj}" --no-deps --no-build-isolation \
                > "${target_build}.${_proj}-ft-wheel.log" 2>&1; then
            warn "IREE ${_proj} free-threaded wheel packaging failed"
            tail -n 60 "${target_build}.${_proj}-ft-wheel.log" 2>/dev/null
            return 1
        fi
        retag_directory_wheels "${ft_dist}/${_proj}" "iree_base_${_proj}" "${wheel_platform}" "${venv}/bin/python"
        ft_twin_store_built "${ft_dist}/${_proj}" "${APP_WHEELHOUSE_FT_DIR}" || return 1
    done
}

# <free-threaded python>: reconfigure the target tree onto it and rebuild; what does not see Python stays built.
_iree_free_threaded_rebuild() {
    local -a py_args=("-DPython_EXECUTABLE=$1" "-DPython3_EXECUTABLE=$1")
    if [ -n "${FT_TARGET_INCLUDE:-}" ]; then
        # The GIL configure cached the target GIL headers for both FindPython spellings; the twin moves both and drops their results.
        py_args+=("-U" "_Python*" "-U" "Python_NumPy*" "-U" "Python3_NumPy*"
                  "-DPython_INCLUDE_DIR=${FT_TARGET_INCLUDE}" "-DPython3_INCLUDE_DIR=${FT_TARGET_INCLUDE}" "-DPYTHON_INCLUDE_DIR=${FT_TARGET_INCLUDE}" "-DPython3_INCLUDE_DIRS=${FT_TARGET_INCLUDE}"
                  "-DPython_LIBRARY=${FT_TARGET_LIBRARY}" "-DPython3_LIBRARY=${FT_TARGET_LIBRARY}" "-DPYTHON_LIBRARY=${FT_TARGET_LIBRARY}")
        eval "$(ft_target_env)"
    fi
    if ! cmake -S "${src_dir}" -B "${target_build}" "${py_args[@]}" \
            > "${target_build}.ft-cfg.log" 2>&1 \
       || ! cmake --build "${target_build}" -- -j"${MAX_JOBS}" > "${target_build}.ft.log" 2>&1; then
        warn "IREE free-threaded rebuild failed"
        tail -n 80 "${target_build}.ft-cfg.log" "${target_build}.ft.log" 2>/dev/null
        return 1
    fi
}

build_iree_wheels() {
    # Defaulted here, not at file scope: the stage suites extract this block alone.
    : "${IREE_CROSS_BUILD_COMPILER:=OFF}"
    # Set by the cross branch; declared here so set -u holds on the native path.
    local -a iree_wheel_projects=()
    local src_dir="${APP_WHEELHOUSE_BUILD_ROOT}/iree"
    local host_build="${APP_WHEELHOUSE_BUILD_ROOT}/iree-build-host"
    local host_install="${host_build}/install"
    local target_build="${APP_WHEELHOUSE_BUILD_ROOT}/iree-build-target"
    local dist_dir="${APP_WHEELHOUSE_BUILD_ROOT}/dist-iree"
    local wheel_platform="" toolchain_file="" iree_target_triple=""
    local -a cmake_args=()

    _iree_check_prereqs || return 1

    # Declared here, not in the helper, or the build steps below can't see it.
    local -a ccache_cmake_args=()
    _iree_setup_compiler_cache

    _iree_fetch_source || return 1
    _iree_patch_setup_py_abi3
    # No QNN flags: IREE has no such options and no Qualcomm NPU path.

    if cross_build_is_active; then
        # Stage 1 builds with the host compilers, stage 2 pins LLVM's NATIVE sub-build to them.
        local host_cc="" host_cxx=""
        host_cc="$(_iree_system_compiler c)"
        host_cxx="$(_iree_system_compiler cxx)"
        _iree_build_host_stage || return 1
        _iree_build_target_cross || return 1
    else
        # ===== amd64 NATIVE: single-stage build =====
        _iree_build_target_native || return 1
    fi

    _iree_package_wheels || return 1
    _iree_package_free_threaded_wheels
}
