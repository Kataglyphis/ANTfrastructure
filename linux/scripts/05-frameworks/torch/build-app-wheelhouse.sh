#!/usr/bin/env bash
set -euo pipefail

if [ -f /opt/scripts/core/cross-env.sh ]; then
    # shellcheck disable=SC1091
    source /opt/scripts/core/cross-env.sh
fi

# shell_quote_args lives in common.sh, which cross-env.sh does not source.
for _common in \
    "/opt/scripts/core/common.sh" \
    "$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)/../../01-core/common.sh"; do
    if [ -f "${_common}" ]; then
        # shellcheck disable=SC1090,SC1091
        source "${_common}"
        break
    fi
done
unset _common

# QNN SDK helpers (backlog QNN-LINUX): same dual-layout source as common.sh.
for _qnnmod in \
    "/opt/scripts/core/qnn-sdk.sh" \
    "$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)/../../01-core/qnn-sdk.sh"; do
    if [ -f "${_qnnmod}" ]; then
        # shellcheck disable=SC1090,SC1091
        source "${_qnnmod}"
        break
    fi
done
unset _qnnmod

# The free-threaded twin helpers sit two levels up in the repo and in the RUN's per-file mount alike; a missing one fails the twin pass.
_ftw="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)/../../03-media/free-threaded-wheels.sh"
if [ -f "${_ftw}" ]; then
    # shellcheck source=../../03-media/free-threaded-wheels.sh
    source "${_ftw}"
fi
unset _ftw

# versions.env directly: the media app-wheelhouse stage runs this outside the orchestrator.
for _lvf in \
    "/opt/scripts/core/load-versions-env.sh" \
    "$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)/../../01-core/load-versions-env.sh"; do
    if [ -f "${_lvf}" ]; then
        # shellcheck source=../../01-core/load-versions-env.sh
        source "${_lvf}"
        break
    fi
done
unset _lvf
for _evf in \
    "/opt/scripts/core/versions.env" \
    "$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)/../../01-core/versions.env"; do
    if [ -f "${_evf}" ]; then
        # Not `set -a; source`: load_versions_env keeps orchestrator-forwarded values.
        load_versions_env "${_evf}"
        break
    fi
done
unset _evf

: "${APP_WHEELHOUSE_DIR:=/opt/app-wheels}"
: "${APP_WHEELHOUSE_FT_DIR:=/opt/app-wheels-free-threaded}"
: "${APP_WHEELHOUSE_BUILD_ROOT:=/tmp/app-wheelhouse}"
: "${PYTORCH_REF:=${PYTORCH_VERSION:-v2.13.0}}"
: "${PYTORCH_VERSION:=${PYTORCH_REF#v}}"
: "${TORCHVISION_REF:=${TORCHVISION_VERSION:-v0.28.0}}"
# The fallback only matters without versions.env.
: "${IREE_REF:=${IREE_VERSION:-v3.12.0}}"
: "${PYTORCH_HOST_INDEX_URL:=https://download.pytorch.org/whl/cpu}"
: "${DEFAULT_PYPI_INDEX_URL:=https://pypi.org/simple}"

if [ -f /opt/scripts/core/parallelism.sh ]; then
  # shellcheck disable=SC1091
  source /opt/scripts/core/parallelism.sh 2>/dev/null || true
  # torch's aten TUs peak ~4 GB per cc1plus, so budget 4 GB per job.
  if declare -F compute_cpp_heavy_jobs >/dev/null 2>&1; then
    MAX_JOBS="${MAX_JOBS:-$(compute_cpp_heavy_jobs "")}"
  elif declare -F compute_jobs_with_mem_cap >/dev/null 2>&1; then
    MAX_JOBS="${MAX_JOBS:-$(compute_jobs_with_mem_cap "" 4096)}"
  fi
fi
: "${MAX_JOBS:=$(nproc)}"

BUILD_PYTHON=""
TARGET_TORCH_WHEEL=""
TARGET_TORCH_VERSION=""
TORCH_STAGING_DIR=""

# shellcheck source=../../lib/log-bootstrap.sh
_LOG_BOOTSTRAP_REGISTRAR_ONLY=1 source "$(dirname "${BASH_SOURCE[0]}")/../../lib/log-bootstrap.sh"
log_bootstrap_fallbacks command plain log warn

require_host_python() {
    local python_bin=""

    if command -v host_python_bin >/dev/null 2>&1; then
        python_bin="$(host_python_bin 2>/dev/null || true)"
    fi

    if [ -z "${python_bin}" ] || [ ! -x "${python_bin}" ]; then
        python_bin="${MEDIA_HOST_PYTHON:-${UV_PYTHON:-}}"
    fi

    if [ -z "${python_bin}" ] || [ ! -x "${python_bin}" ]; then
        warn "Unable to resolve the host Python interpreter for the app wheelhouse build"
        return 1
    fi

    printf '%s' "${python_bin}"
}

wheel_platform_tag() {
    wheel_platform_tag_with_fallback best-effort
}

prepare_workspace() {
    rm -rf "${APP_WHEELHOUSE_BUILD_ROOT}" "${APP_WHEELHOUSE_DIR}" "${APP_WHEELHOUSE_FT_DIR}"
    mkdir -p "${APP_WHEELHOUSE_BUILD_ROOT}" "${APP_WHEELHOUSE_DIR}" "${APP_WHEELHOUSE_FT_DIR}"
}

install_build_dependencies() {
    if command -v cross_apt_update >/dev/null 2>&1; then
        cross_apt_update -y
    else
        apt-get update -y
    fi

    if command -v install_host_packages >/dev/null 2>&1; then
        # ccache is a host tool; without it the multi-hour cross builds never hit the cache.
        install_host_packages git ninja-build cmake pkg-config unzip rsync ccache sccache
        install_host_packages libopenblas-dev liblapack-dev zlib1g-dev libjpeg-dev libpng-dev libtiff-dev libwebp-dev
        if ! install_target_packages libopenblas-dev liblapack-dev zlib1g-dev libjpeg-dev libpng-dev libtiff-dev libwebp-dev; then
            warn "Some riscv64 target build dependencies are unavailable; continuing with the staged sysroot"
        fi
        # Its sysconfigdata gives the target extension suffixes; own call, as a group is all-or-nothing.
        install_target_packages libpython3-stdlib || \
            warn "Target libpython3-stdlib unavailable; wheel builds will use host sysconfig"
        # Bundled sleef builds its codegen tools for the target and runs them on the host.
        install_target_packages libsleef-dev || \
            warn "Target libsleef-dev unavailable; bundled sleef will fail under cross (Exec format error)"
        return 0
    fi

    apt-get install -y --no-install-recommends \
        git ninja-build cmake pkg-config unzip rsync ccache sccache \
        libopenblas-dev liblapack-dev zlib1g-dev libjpeg-dev libpng-dev libtiff-dev libwebp-dev
}

install_native_build_dependencies() {
    # ccache is the decisive lever: IREE's bundled LLVM is a ~1 h compile.
    apt-get update -y || true
    apt-get install -y --no-install-recommends \
        git ninja-build cmake pkg-config unzip rsync ccache sccache || return 1
}

prepare_build_environment() {
    # main() already ran prepare_workspace, so the wheelhouse exists even when this bails.
    if cross_build_is_active; then
        if ! command -v prepare_cross_target_env >/dev/null 2>&1; then
            warn "Cross environment helpers are unavailable; leaving the app wheelhouse empty"
            return 1
        fi

        prepare_cross_target_env "${TARGET_ARCH:-${TARGETARCH:-riscv64}}" "app wheelhouse"

        if ! command -v cross_target_python_dev_ready >/dev/null 2>&1 || ! cross_target_python_dev_ready; then
            warn "Target Python development files are not staged for $(cross_target_arch 2>/dev/null || echo target); leaving the app wheelhouse empty"
            return 1
        fi

        install_build_dependencies || {
            warn "Failed to install app wheelhouse build dependencies; leaving the app wheelhouse empty"
            return 1
        }
    else
        # Native amd64 source-builds only IREE; torch comes from PyPI.
        install_native_build_dependencies || {
            warn "Failed to install native IREE build dependencies; leaving the app wheelhouse empty"
            return 1
        }
    fi

    BUILD_PYTHON="$(require_host_python)" || return 1

    # Build executors are pinned (setuptools below torch's <82 ceiling); data-only deps float.
    uv pip install --python "${BUILD_PYTHON}" -U \
        "setuptools==${PY_SETUPTOOLS_LT82_VERSION:-81.0.0}" \
        "wheel==${PY_WHEEL_VERSION:-0.47.0}" \
        build cmake \
        "ninja==${PY_NINJA_VERSION:-1.13.0}" \
        numpy packaging pyyaml requests six typing-extensions \
        sympy filelock networkx jinja2
}

# torch's setup.py drops CMAKE_ARGS; CMake reads CMAKE_TOOLCHAIN_FILE from the environment instead.
write_cross_cmake_toolchain_file() {
    local path="${APP_WHEELHOUSE_BUILD_ROOT}/cross-toolchain.cmake"
    local processor="${CMAKE_SYSTEM_PROCESSOR:-}"
    if [ -z "${processor}" ]; then
        case "$(cross_target_arch 2>/dev/null || echo)" in
            riscv64) processor=riscv64 ;;
            arm64)   processor=aarch64 ;;
            *) return 1 ;;
        esac
    fi
    cat > "${path}" <<EOF || return 1
# Generated by build-app-wheelhouse.sh — minimal cross identity for
# setup.py-driven cmake builds (compilers come from CC/CXX env).
set(CMAKE_SYSTEM_NAME Linux)
set(CMAKE_SYSTEM_PROCESSOR ${processor})
set(CMAKE_FIND_ROOT_PATH_MODE_PROGRAM NEVER)
EOF
    # The toolchain file is the one channel setup.py cannot drop: hand it a host-runnable protoc.
    if [ -n "${CROSS_HOST_PROTOC:-}" ] && [ -x "${CROSS_HOST_PROTOC}" ]; then
        printf 'set(CAFFE2_CUSTOM_PROTOC_EXECUTABLE "%s" CACHE FILEPATH "host protoc for cross builds")\n' \
            "${CROSS_HOST_PROTOC}" >> "${path}"
    fi
    # Without these pytorch silently turns BUILD_PYTHON off and the link fails on -ltorch_python.
    local py_inc py_lib
    # CROSS_PYTHON_*: the free-threaded twin's target X.Yt; else the target GIL Python.
    py_inc="${CROSS_PYTHON_INCLUDE_DIR:-$(cross_target_python_include_dir 2>/dev/null || true)}"
    py_lib="${CROSS_PYTHON_LIBRARY:-$(cross_target_python_library 2>/dev/null || true)}"
    if [ -n "${py_inc}" ] && [ -d "${py_inc}" ] && [ -n "${py_lib}" ] && [ -f "${py_lib}" ]; then
        cat >> "${path}" <<EOF
set(Python_INCLUDE_DIR "${py_inc}" CACHE PATH "target Python include dir")
set(Python_LIBRARY "${py_lib}" CACHE FILEPATH "target Python library")
set(Python3_INCLUDE_DIR "${py_inc}" CACHE PATH "target Python include dir")
set(Python3_LIBRARY "${py_lib}" CACHE FILEPATH "target Python library")
EOF
    fi
    printf '%s' "${path}"
}

# Exports the BUILD TARGET's sysconfig module (without one, _PYTHON_SYSCONFIGDATA_NAME is an instant ModuleNotFoundError) and never the host's: `cross_target_triplet` answers for the host (arch_oci), which handed pip a 3.14 sysconfigdata (`cp315`, `cp314`, `linux_x86_64`, 2026-10-19).
resolve_target_python_sysconfig_export() {
    local target_arch="" target_triplet="" machine="" name="" stage_root="" dir="" sysdir=""
    target_arch="${TARGET_ARCH:-${TARGETARCH:-}}"
    [ -n "${target_arch}" ] || return 0
    target_triplet="$(cross_target_triplet_for_arch "${target_arch}" 2>/dev/null || true)"
    [ -n "${target_triplet}" ] || return 0
    machine="${target_triplet%%-*}"
    name="_sysconfigdata__linux_${target_triplet}"

    stage_root="$(cross_target_python_root "${target_arch}" 2>/dev/null || true)"
    dir="$(cross_target_sysconfigdata_dir "${target_triplet}" "${stage_root}" || true)"

    # A dir of its own: the target stdlib beside the module must not shadow the pinned interpreter's (FT_TARGET_SYSCONFIG_DIR's shape).
    sysdir="${APP_WHEELHOUSE_BUILD_ROOT}/sysconfigdata-${target_triplet}"
    mkdir -p "${sysdir}" || return 1
    if [ -n "${dir}" ]; then
        cp -f "${dir}/${name}.py" "${sysdir}/" || return 1
    else
        "${BUILD_PYTHON:-${MEDIA_HOST_PYTHON:-python3}}" - "${sysdir}/${name}.py" "${target_triplet}" <<'PY' || return 1
import pprint, sys, sysconfig
out, triplet = sys.argv[1], sys.argv[2]
mm = "".join(str(part) for part in sys.version_info[:2])
data = dict(sysconfig.get_config_vars())
data["SOABI"] = "cpython-%s-%s" % (mm, triplet)
data["EXT_SUFFIX"] = "." + data["SOABI"] + ".so"
data["MULTIARCH"] = triplet
with open(out, "w") as fh:
    fh.write("build_time_vars = ")
    fh.write(pprint.pformat(data, width=1000))
    fh.write("\n")
PY
    fi

    printf 'export _PYTHON_SYSCONFIGDATA_NAME=%q; export _PYTHON_HOST_PLATFORM=%q; export PYTHONPATH=%q${PYTHONPATH:+:${PYTHONPATH}}' \
        "${name}" "linux_${machine}" "${sysdir}"
}

# These outputs are locals in append_common_cross_cmake_args, so twin overrides stay scoped to its call.
_wheelhouse_resolve_target_python() {
    # CROSS_PYTHON_*: the free-threaded twin's target X.Yt, whose one include dir holds its pyconfig.h; else the target GIL Python.
    if [ -n "${CROSS_PYTHON_INCLUDE_DIR:-}" ]; then
        target_python_include="${CROSS_PYTHON_INCLUDE_DIR}"
        target_python_library="${CROSS_PYTHON_LIBRARY:-}"
    else
        target_python_include="$(cross_target_python_include_dir 2>/dev/null || true)"
        target_python_arch_include="$(cross_target_python_arch_include_dir 2>/dev/null || true)"
        target_python_library="$(cross_target_python_library 2>/dev/null || true)"
    fi
}

append_common_cross_cmake_args() {
    local -n out_args_ref=$1
    local resolved_ar=""
    local resolved_ranlib=""
    local target_python_include=""
    local target_python_arch_include=""
    local target_python_library=""
    local host_numpy_include=""
    local qemu_runner=""

    if command -v append_cmake_cross_args >/dev/null 2>&1; then
        append_cmake_cross_args out_args_ref
    fi

    resolved_ar="$(resolve_cross_gcc_tool ar 2>/dev/null || true)"
    resolved_ranlib="$(resolve_cross_gcc_tool ranlib 2>/dev/null || true)"
    _wheelhouse_resolve_target_python
    host_numpy_include="$("${BUILD_PYTHON}" -c 'import numpy; print(numpy.get_include())' 2>/dev/null || true)"
    qemu_runner="$(cross_target_qemu_runner 2>/dev/null || true)"

    [ -n "${resolved_ar}" ] && out_args_ref+=("-DCMAKE_AR=${resolved_ar}" "-DCMAKE_C_COMPILER_AR=${resolved_ar}" "-DCMAKE_CXX_COMPILER_AR=${resolved_ar}")
    [ -n "${resolved_ranlib}" ] && out_args_ref+=("-DCMAKE_RANLIB=${resolved_ranlib}" "-DCMAKE_C_COMPILER_RANLIB=${resolved_ranlib}" "-DCMAKE_CXX_COMPILER_RANLIB=${resolved_ranlib}")

    out_args_ref+=(
        "-DPython_EXECUTABLE=${BUILD_PYTHON}"
        "-DPYTHON_EXECUTABLE=${BUILD_PYTHON}"
        "-DPython3_EXECUTABLE=${BUILD_PYTHON}"
        "-DCMAKE_C_FLAGS=-idirafter /usr/include"
        "-DCMAKE_CXX_FLAGS=-idirafter /usr/include"
    )

    [ -n "${target_python_include}" ] && out_args_ref+=("-DPython3_INCLUDE_DIR=${target_python_include}" "-DPYTHON_INCLUDE_DIR=${target_python_include}")
    [ -n "${target_python_arch_include}" ] && out_args_ref+=("-DPython3_INCLUDE_DIRS=${target_python_include};${target_python_arch_include}")
    [ -n "${target_python_library}" ] && out_args_ref+=("-DPython3_LIBRARY=${target_python_library}" "-DPYTHON_LIBRARY=${target_python_library}")
    [ -n "${host_numpy_include}" ] && out_args_ref+=("-DNUMPY_INCLUDE_DIR=${host_numpy_include}")
    [ -n "${qemu_runner}" ] && out_args_ref+=("-DCMAKE_CROSSCOMPILING_EMULATOR=${qemu_runner}")
    # Explicit: an empty qemu_runner would make the && list above the exit status.
    return 0
}

git_clone_ref() {
    local url="$1"
    local ref="$2"
    local dest_dir="$3"
    shift 3

    rm -rf "${dest_dir}"
    git clone "$@" --branch "${ref}" --depth 1 "${url}" "${dest_dir}"
}

parse_wheel_version() {
    local wheel_path="$1"
    local package_name="$2"
    local wheel_basename=""

    wheel_basename="$(basename "${wheel_path}")"
    wheel_basename="${wheel_basename%.whl}"
    wheel_basename="${wheel_basename#${package_name}-}"
    wheel_basename="${wheel_basename%%-cp*}"
    printf '%s' "${wheel_basename}"
}

extract_torch_wheel() {
    TORCH_STAGING_DIR="${APP_WHEELHOUSE_BUILD_ROOT}/torch-staging"
    rm -rf "${TORCH_STAGING_DIR}"
    mkdir -p "${TORCH_STAGING_DIR}"
    unzip -q -o "${TARGET_TORCH_WHEEL}" -d "${TORCH_STAGING_DIR}"
}

# A cross bdist_wheel can drop torch._C; inject the cmake-built one and repack. No-op on a healthy wheel.
_torch_ensure_c_extension() {
    local dist_dir="$1"
    local wheel_path built_c_ext staging suffix triplet pyabi listing dest_name
    local build_torch_dir
    shopt -s nullglob
    local -a wheels=("${dist_dir}"/torch-*.whl)
    shopt -u nullglob
    [ "${#wheels[@]}" -gt 0 ] || return 0
    wheel_path="${wheels[0]}"

    # Read first: `unzip -l | grep -q` dies of SIGPIPE, which pipefail reports as absent.
    if ! listing="$(unzip -l "${wheel_path}" 2>/dev/null)"; then
        warn "cannot list ${wheel_path} (unzip failed); skipping the torch _C extension check"
        return 0
    fi
    # Already carries the top-level compiled extension? nothing to do.
    if grep -qE ' torch/_C[^/]*\.so$' <<<"${listing}"; then
        return 0
    fi

    # cmake links the ABI-mangled name; a literal torch/_C.so never appears. The wheel's own ABI, as the free-threaded twin's tree holds both.
    build_torch_dir="${APP_WHEELHOUSE_BUILD_ROOT}/pytorch/torch"
    pyabi="$(basename "${wheel_path}" | sed -nE 's/.*-cp[0-9]+-cp([0-9]+t?)-.*/\1/p')"
    [ -n "${pyabi}" ] || pyabi="314"
    shopt -s nullglob
    local -a built_c_exts=("${build_torch_dir}"/_C.cpython-"${pyabi}"-*.so)
    shopt -u nullglob
    # nullglob cannot drop a metacharacter-free word, so test the plain name.
    [ ! -f "${build_torch_dir}/_C.so" ] || built_c_exts+=("${build_torch_dir}/_C.so")
    if [ "${#built_c_exts[@]}" -eq 0 ]; then
        warn "torch wheel lacks torch/_C*.so and no cmake-built ${build_torch_dir}/_C*.so exists; import torch WILL fail (missing C extension)"
        return 0
    fi
    built_c_ext="${built_c_exts[0]}"

    # Keep an ABI-mangled name, else synthesise one from the wheel's -cpXYZ- tag.
    dest_name="$(basename "${built_c_ext}")"
    if [ "${dest_name}" = "_C.so" ]; then
        triplet="$(cross_target_triplet 2>/dev/null || echo riscv64-linux-gnu)"
        suffix="cpython-${pyabi}-${triplet}.so"
        dest_name="_C.${suffix}"
    fi

    staging="${APP_WHEELHOUSE_BUILD_ROOT}/torch-cext-repack"
    rm -rf "${staging}"
    mkdir -p "${staging}"
    unzip -q -o "${wheel_path}" -d "${staging}"
    cp "${built_c_ext}" "${staging}/torch/${dest_name}"
    log "Injected missing torch/${dest_name} into $(basename "${wheel_path}") (pytorch ${PYTORCH_REF} cross bdist_wheel dropped the compiled C extension)"

    rm -f "${wheel_path}"
    if ! ( cd "${staging}" && "${BUILD_PYTHON}" -m wheel pack . -d "${dist_dir}" ); then
        warn "wheel pack failed while repackaging the torch _C extension"
        return 1
    fi
}

# Torch phases read component-local state through Bash dynamic scope.
# shellcheck disable=SC2154

# Bundled protobuf builds protoc for the target, which onnx codegen then runs on the host.
_torch_build_host_protoc() {
    CROSS_HOST_PROTOC=""
    if [ ! -f "${src_dir}/scripts/build_host_protoc.sh" ]; then
        warn "pytorch has no scripts/build_host_protoc.sh at this ref; onnx codegen will hit Exec format error"
        return 0
    fi
    log "Building host protoc via scripts/build_host_protoc.sh..."
    # CMAKE_POLICY_VERSION_MINIMUM: cmake 4 refuses protobuf 3.13's cmake_minimum_required(<3.5).
    if (cd "${src_dir}" && \
        env -u AR -u RANLIB -u LD -u CFLAGS -u CXXFLAGS -u CPPFLAGS -u LDFLAGS \
            -u CMAKE_TOOLCHAIN_FILE -u CMAKE_SYSTEM_NAME -u CMAKE_SYSTEM_PROCESSOR \
            CC=gcc CXX=g++ \
            bash scripts/build_host_protoc.sh \
                --other-flags "-DCMAKE_POLICY_VERSION_MINIMUM=${CMAKE_POLICY_VERSION_MINIMUM:-3.5}" > /tmp/build_host_protoc.log 2>&1); then
        CROSS_HOST_PROTOC="${src_dir}/build_host_protoc/bin/protoc"
    fi
    # Run it, not just -x: a cross-built protoc is executable on disk only.
    if [ -n "${CROSS_HOST_PROTOC}" ] && "${CROSS_HOST_PROTOC}" --version >/dev/null 2>&1; then
        log "Host protoc ready: ${CROSS_HOST_PROTOC} ($("${CROSS_HOST_PROTOC}" --version 2>/dev/null))"
    else
        CROSS_HOST_PROTOC=""
        warn "build_host_protoc.sh failed or produced a non-host binary (tail of /tmp/build_host_protoc.log follows); onnx codegen will hit Exec format error"
        tail -20 /tmp/build_host_protoc.log >&2 || true
    fi
}

# Bundled sleef runs target-built codegen on the host; else keep it so the failure stays visible.
_torch_detect_system_sleef() {
    use_system_sleef=0
    if command -v cross_package_status_present >/dev/null 2>&1 && \
       cross_package_status_present "libsleef-dev:$(cross_target_arch 2>/dev/null || echo none)"; then
        use_system_sleef=1
        log "Using target system sleef (libsleef-dev) instead of pytorch's bundled sleef"
    else
        warn "Target libsleef-dev not present; bundled sleef will likely fail (Exec format error on mkrename)"
    fi
}

# pip wheel, not setup.py bdist_wheel: PyTorch 2.14 moved to scikit-build-core and removed that path.
_wheelhouse_prepare_cross_env() {
    local component="$1"
    cd "${src_dir}" && \
    export CMAKE_GENERATOR=Ninja && \
    export CMAKE_ARGS="${cmake_args_string}" && \
    { cross_toolchain_file="$(write_cross_cmake_toolchain_file || true)"; \
      [ -n "${cross_toolchain_file}" ] || { warn "no cross toolchain file for ${component}; cmake would configure a NATIVE build with the cross compiler"; return 1; }; \
      export CMAKE_TOOLCHAIN_FILE="${cross_toolchain_file}"; } && \
    export _PYTHON_HOST_PLATFORM="${wheel_platform}" && \
    if [ -n "${python_sysconfig_export}" ]; then eval "${python_sysconfig_export}"; fi
}

_wheelhouse_build_pip_wheel() {
    "${BUILD_PYTHON}" -m pip install --quiet --disable-pip-version-check \
        "scikit-build-core>=1.0" "setuptools>=77.0.0,<82" numpy "packaging>=24.2" pyyaml || return $?
    "${BUILD_PYTHON}" -m pip wheel --no-build-isolation --no-deps \
        --wheel-dir "${dist_dir}" .
}

_torch_run_setup_py() {
    (
        _wheelhouse_prepare_cross_env torch && \
        export PYTHON_EXECUTABLE="${BUILD_PYTHON}" Python_EXECUTABLE="${BUILD_PYTHON}" Python3_EXECUTABLE="${BUILD_PYTHON}" && \
        export MAX_JOBS="${MAX_JOBS}" && \
        export CCACHE_DIR="${CCACHE_DIR:-/var/cache/ccache}" CCACHE_MAXSIZE="${CCACHE_MAXSIZE:-64G}" CCACHE_COMPRESS=1 && \
        export BLAS=OpenBLAS USE_NUMPY=1 && \
        export USE_CUDA=0 USE_CUDNN=0 USE_CUSPARSELT=0 USE_CUDSS=0 USE_CUFILE=0 USE_ROCM=0 USE_XPU=0 && \
        export USE_DISTRIBUTED=0 USE_GLOO=0 USE_MPI=0 USE_TENSORPIPE=0 USE_NCCL=0 && \
        export BUILD_TEST=0 BUILD_BINARY=0 USE_KINETO=0 && \
        export USE_FBGEMM=0 USE_MKLDNN=0 USE_NNPACK=0 USE_QNNPACK=0 USE_PYTORCH_QNNPACK=0 USE_XNNPACK=0 && \
        export USE_SYSTEM_SLEEF="${use_system_sleef}" && \
        # No OpenMP: the riscv64 cross GCC's libgomp is not reliably coinstallable in the sysroot.
        export USE_FLASH_ATTENTION=0 USE_MEM_EFF_ATTENTION=0 USE_OPENMP=0 && \
        export CFLAGS="${CFLAGS:+${CFLAGS} }-idirafter /usr/include" && \
        export CXXFLAGS="${CXXFLAGS:+${CXXFLAGS} }-idirafter /usr/include" && \
        _wheelhouse_build_pip_wheel
    )
}

_wheelhouse_collect_component() {
    local component="$1" label="$2"
    local -n collected_wheels="$3"
    retag_directory_wheels "${dist_dir}" "$component" "${wheel_platform}" "${BUILD_PYTHON}" || return 1
    shopt -s nullglob
    collected_wheels=("${dist_dir}"/"${component}"-*.whl)
    shopt -u nullglob
    if [ "${#collected_wheels[@]}" -eq 0 ]; then
        warn "${label} cross build completed without producing a wheel"
        return 1
    fi
    cp -a "${collected_wheels[@]}" "${APP_WHEELHOUSE_DIR}/" || return 1
}

_wheelhouse_prepare_torch_source() {
    local label="$1" repository="$2" ref="$3"
    shift 3
    wheel_platform="$(wheel_platform_tag || true)"
    if [ -z "${wheel_platform}" ]; then
        warn "Could not determine the riscv64 wheel platform tag for ${label}"
        return 1
    fi
    python_sysconfig_export="$(resolve_target_python_sysconfig_export)"
    local sysconfig_rc=$?
    [ "$sysconfig_rc" -eq 0 ] || return "$sysconfig_rc"
    git_clone_ref "$repository" "$ref" "${src_dir}" "$@" || {
        warn "Failed to clone ${label} ${ref}"
        return 1
    }
}

# Sets the TARGET_TORCH_WHEEL/TARGET_TORCH_VERSION globals and extracts the wheel.
_collect_torch_wheel() {
    local -a built_wheels=()
    # Repair before retagging so the repacked wheel takes the normal collection path.
    _torch_ensure_c_extension "${dist_dir}" || return 1
    _wheelhouse_collect_component torch PyTorch built_wheels || return 1

    TARGET_TORCH_WHEEL="${APP_WHEELHOUSE_DIR}/$(basename "${built_wheels[0]}")"
    TARGET_TORCH_VERSION="$(parse_wheel_version "${TARGET_TORCH_WHEEL}" torch)"
    extract_torch_wheel || return 1
    log "Built PyTorch cross wheel $(basename "${TARGET_TORCH_WHEEL}")"
}

_wheelhouse_build_component() {
    local component="$1"
    local wheel_platform="" src_dir="${APP_WHEELHOUSE_BUILD_ROOT}/$2" dist_dir="${APP_WHEELHOUSE_BUILD_ROOT}/$3"
    local -a cmake_args=()
    local cmake_args_string="" python_sysconfig_export=""
    case "$component" in
        torch) _build_torch_component ;;
        torchvision) _build_torchvision_component ;;
        *) return 2 ;;
    esac
}

build_torch_wheel() {
    _wheelhouse_build_component torch pytorch dist-torch
}
build_torchvision_wheel() {
    _wheelhouse_build_component torchvision vision dist-vision
}

_build_torch_component() {
    local CROSS_HOST_PROTOC=""   # set by _torch_build_host_protoc; read by toolchain file
    local use_system_sleef=0     # set by _torch_detect_system_sleef

    _wheelhouse_prepare_torch_source PyTorch https://github.com/pytorch/pytorch.git "${PYTORCH_REF}" --recursive --shallow-submodules
    local prepare_rc=$?
    [ "$prepare_rc" -eq 0 ] || return "$prepare_rc"

    rm -rf "${dist_dir}"
    mkdir -p "${dist_dir}"

    _torch_build_host_protoc
    _torch_detect_system_sleef

    _torch_cmake_args cmake_args
    cmake_args_string="$(shell_quote_args "${cmake_args[@]}")"

    if ! _torch_run_setup_py; then
        warn "PyTorch riscv64 cross wheel build failed; leaving it to the native torch stage"
        return 1
    fi

    _collect_torch_wheel || return 1
    _torch_build_free_threaded_wheel
}

# <array name>: torch's CMAKE_ARGS for BUILD_PYTHON and the target Python (CROSS_PYTHON_* for the twin).
_torch_cmake_args() {
    local -n _tca_ref="$1"
    local _cc_l
    append_common_cross_cmake_args _tca_ref
    _tca_ref+=("-DBLAS=OpenBLAS")
    # Cache the multi-hour aten compile; without a launcher the build runs plain.
    compiler_cache_launcher_env 2>/dev/null || true
    _cc_l="$(compiler_cache_launcher 2>/dev/null || true)"
    if [ -n "${_cc_l}" ]; then
        _tca_ref+=("-DCMAKE_C_COMPILER_LAUNCHER=${_cc_l}" "-DCMAKE_CXX_COMPILER_LAUNCHER=${_cc_l}")
    fi
    return 0
}

_wheelhouse_start_twin() {
    local component="$1" venv="$2"
    shift 2
    declare -F ft_twin_start >/dev/null || { warn "${component}: free-threaded-wheels.sh is not mounted; its RUN needs the per-file mount"; return 2; }
    ft_twin_start "${component}" "${venv}" "${BUILD_PYTHON}" pip setuptools wheel numpy "$@" || return $?
    t0="$(date +%s)"
}

# The torch twin, gated by FT_TORCH_TWIN through its table row: the warm tree again on a free-threaded venv, so only what sees Python rebuilds.
_torch_build_free_threaded_wheel() {
    local venv="${APP_WHEELHOUSE_BUILD_ROOT}/torch-ft-venv" t0
    _wheelhouse_start_twin torch "${venv}" packaging pyyaml typing-extensions six \
        || { [ $? -eq 1 ] && return 0; return 1; }
    local BUILD_PYTHON="${venv}/bin/python" dist_dir="${APP_WHEELHOUSE_BUILD_ROOT}/dist-torch-free-threaded"
    local python_sysconfig_export cmake_args_string
    local CROSS_PYTHON_INCLUDE_DIR="${FT_TARGET_INCLUDE}" CROSS_PYTHON_LIBRARY="${FT_TARGET_LIBRARY}"
    local -a cmake_args=()
    python_sysconfig_export="$(ft_target_env)"
    # Built afresh, not the GIL pass's string plus overrides: its -DPYTHON_INCLUDE_DIR heads torch_python's include path (CON79 1b).
    _torch_cmake_args cmake_args
    # On the command line: the toolchain file's CACHE sets cannot move the GIL pass's cached Python, nor its FindPython results.
    cmake_args+=("-U" "_Python*" "-U" "Python_NumPy*" "-U" "Python3_NumPy*"
        "-DPython_INCLUDE_DIR=${FT_TARGET_INCLUDE}" "-DPython3_INCLUDE_DIRS=${FT_TARGET_INCLUDE}" "-DPython_LIBRARY=${FT_TARGET_LIBRARY}")
    cmake_args_string="$(shell_quote_args "${cmake_args[@]}")"
    rm -rf "${dist_dir}"; mkdir -p "${dist_dir}"
    # The GIL pass's module would otherwise ride into the twin, as IREE's did.
    rm -f "${src_dir}"/torch/_C.cpython-*.so
    if ! _torch_run_setup_py; then
        warn "torch: the free-threaded pass over ${src_dir} failed"
        return 1
    fi
    log "torch: the free-threaded pass took $(( $(date +%s) - t0 ))s in the warm tree"
    _torch_ensure_c_extension "${dist_dir}" || return 1
    retag_directory_wheels "${dist_dir}" torch "${wheel_platform}" "${BUILD_PYTHON}"
    ft_twin_store_built "${dist_dir}" "${APP_WHEELHOUSE_FT_DIR}" || return 1
    rm -rf "${venv}" "${dist_dir}"
}

install_host_torch_for_vision() {
    uv pip install --python "${BUILD_PYTHON}" \
        --default-index "${DEFAULT_PYPI_INDEX_URL}" \
        --index "${PYTORCH_HOST_INDEX_URL}" \
        --reinstall-package torch \
        "torch==${PYTORCH_VERSION}+cpu" pillow
}

patch_torchvision_setup() {
    local setup_py="$1"

    bash /opt/scripts/core/apply-patch.sh \
        /opt/scripts/patches/torchvision/001-torch-staging-paths.patch \
        "$(dirname "${setup_py}")" \
        "torchvision setup.py: TORCHVISION_TORCH_STAGING env var support"
}

# Vision phases share component-local staging paths through Bash dynamic scope.
# shellcheck disable=SC2154

# -O3 -DNDEBUG explicitly: a set $CFLAGS replaces sysconfig's, which left every extension at -O0.
_torchvision_run_setup_py() {
    (
        _wheelhouse_prepare_cross_env torchvision && \
        export FORCE_CUDA=0 FORCE_MPS=0 DEBUG=0 && \
        export PYTORCH_VERSION="${TARGET_TORCH_VERSION}" && \
        export TORCHVISION_TORCH_STAGING="${TORCH_STAGING_DIR}" && \
        export TORCHVISION_INCLUDE="${target_torch_include}:${target_torch_csrc}" && \
        export TORCHVISION_LIBRARY="${target_torch_lib}" && \
        _vis_multiarch="$(cross_target_triplet 2>/dev/null || true)" && \
        export CFLAGS="${CFLAGS:+${CFLAGS} }-O3 -DNDEBUG ${_vis_multiarch:+-idirafter /usr/include/${_vis_multiarch} }-idirafter /usr/include" && \
        export CXXFLAGS="${CXXFLAGS:+${CXXFLAGS} }-O3 -DNDEBUG ${_vis_multiarch:+-idirafter /usr/include/${_vis_multiarch} }-idirafter /usr/include" && \
        _wheelhouse_build_pip_wheel
    )
}

# cpp_extension swallows ninja's output; rerun ninja to surface the real compiler error.
_torchvision_ninja_diagnostic() {
    local _vis_ninja_dir
    _vis_ninja_dir="$(find "${src_dir}/build" -name build.ninja -printf '%h\n' -quit 2>/dev/null || true)"
    if [ -n "${_vis_ninja_dir}" ]; then
        warn "torchvision ninja diagnostic (${_vis_ninja_dir}):"
        (cd "${_vis_ninja_dir}" && ninja -v 2>&1 | tail -60) >&2 || true
    fi
}

# Retag, collect, install the built torchvision wheel. Reads dist_dir + wheel_platform.
_collect_torchvision_wheel() {
    local -a built_wheels=()
    _wheelhouse_collect_component torchvision torchvision built_wheels || return 1

    log "Built torchvision cross wheel $(basename "${built_wheels[0]}")"
}

_build_torchvision_component() {
    local target_torch_include="" target_torch_csrc="" target_torch_lib=""
    if [ -z "${TARGET_TORCH_WHEEL}" ] || [ -z "${TORCH_STAGING_DIR}" ]; then
        warn "Skipping torchvision cross wheel build because no target torch wheel is available"
        return 1
    fi

    if ! install_host_torch_for_vision; then
        warn "Failed to install the host torch wheel needed to drive the torchvision build"
        return 1
    fi

    _wheelhouse_prepare_torch_source torchvision https://github.com/pytorch/vision.git "${TORCHVISION_REF}"
    local prepare_rc=$?
    [ "$prepare_rc" -eq 0 ] || return "$prepare_rc"

    patch_torchvision_setup "${src_dir}/setup.py" || {
        warn "Failed to patch torchvision for staged libtorch cross paths"
        return 1
    }

    rm -rf "${dist_dir}"
    mkdir -p "${dist_dir}"

    target_torch_include="${TORCH_STAGING_DIR}/torch/include"
    target_torch_csrc="${target_torch_include}/torch/csrc/api/include"
    target_torch_lib="${TORCH_STAGING_DIR}/torch/lib"

    append_common_cross_cmake_args cmake_args
    cmake_args_string="$(shell_quote_args "${cmake_args[@]}")"

    if ! _torchvision_run_setup_py; then
        warn "torchvision riscv64 cross wheel build failed; leaving it to the native torch stage"
        _torchvision_ninja_diagnostic
        return 1
    fi

    _collect_torchvision_wheel
}

# IREE stages. See docs/iree-two-stage-build.md

# Sets wheel_platform. Returns 1 when IREE cannot be built at all.
# shellcheck source=./iree-wheelhouse.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/iree-wheelhouse.sh"

main() {
    prepare_workspace
    if ! prepare_build_environment; then
        # Deliberate: an empty wheelhouse, not a failed media build.
        warn "app wheelhouse: environment not ready (see the warning above) — shipping an EMPTY wheelhouse"
        return 0
    fi

    # Best-effort riscv64-only torch/vision: a failure must not skip the required IREE build.
    if [ "$(cross_target_arch 2>/dev/null || echo)" = "riscv64" ]; then
        if ! build_torch_wheel; then
            warn "riscv64 torch cross-wheel failed — native torch stage is the fallback; continuing to IREE"
        fi
        if ! build_torchvision_wheel; then
            warn "Continuing without a prebuilt riscv64 torchvision wheel"
        fi
    fi

    # IREE is required on every arch; ALLOW_IREE_BUILD_FAIL=1 only for a deliberate IREE-less image.
    if ! build_iree_wheels; then
        if [ "${ALLOW_IREE_BUILD_FAIL:-0}" = "1" ]; then
            warn "IREE build failed but ALLOW_IREE_BUILD_FAIL=1 set — continuing without it"
        else
            err "IREE build FAILED — IREE is required (see the dumped build log above). Set ALLOW_IREE_BUILD_FAIL=1 only for a deliberate IREE-less image."
        fi
    fi

    shopt -s nullglob
    local wheel_path
    if compgen -G "${APP_WHEELHOUSE_DIR}/*.whl" >/dev/null 2>&1; then
        for wheel_path in "${APP_WHEELHOUSE_DIR}"/*.whl; do
            log "App wheelhouse artifact: $(basename "${wheel_path}")"
        done
    fi
    shopt -u nullglob
}

main "$@"
