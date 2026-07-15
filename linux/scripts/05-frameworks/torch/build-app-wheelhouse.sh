#!/usr/bin/env bash
set -euo pipefail

if [ -f /opt/scripts/core/cross-env.sh ]; then
    # shellcheck disable=SC1091
    source /opt/scripts/core/cross-env.sh
fi

# shell_quote_args lives in common.sh, which cross-env.sh does NOT source.
# Without it both wheel builds died instantly at
# cmake_args_string="$(shell_quote_args ...)" ("command not found"), silently
# absorbed by the best-effort WARN path — the long-standing "riscv64 cross
# wheel build failed" was (at least partly) this.
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

# Source canonical versions.env so PYTORCH_VERSION / TORCHVISION_VERSION are
# always available even when this script is invoked outside the orchestrator
# (which is the typical case in the media app-wheelhouse stage). Fallback paths
# below still exist but now mirror versions.env rather than drifting.
for _lvf in \
    "/opt/scripts/core/load-versions-env.sh" \
    "$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)/../../01-core/load-versions-env.sh"; do
    if [ -f "${_lvf}" ]; then
        # shellcheck disable=SC1091
        source "${_lvf}"
        break
    fi
done
unset _lvf
for _evf in \
    "/opt/scripts/core/versions.env" \
    "$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)/../../01-core/versions.env"; do
    if [ -f "${_evf}" ]; then
        # load_versions_env respects already-set env (orchestrator-forwarded
        # PYTORCH_VERSION/etc. win over the baked copy) — unlike `set -a; source`,
        # which clobbered them and inverted the documented precedence contract.
        load_versions_env "${_evf}"
        break
    fi
done
unset _evf

: "${APP_WHEELHOUSE_DIR:=/opt/app-wheels}"
: "${APP_WHEELHOUSE_BUILD_ROOT:=/tmp/app-wheelhouse}"
: "${PYTORCH_REF:=${PYTORCH_VERSION:-v2.13.0}}"
: "${PYTORCH_VERSION:=${PYTORCH_REF#v}}"
: "${TORCHVISION_REF:=${TORCHVISION_VERSION:-v0.28.0}}"
# IREE (iree.dev) source tag for the riscv64 runtime wheel cross-build. Mirrors
# versions.env IREE_VERSION (load_versions_env sets it above); the v3.11.0
# fallback keeps this runnable outside the orchestrator. See build_iree_wheels.
: "${IREE_REF:=${IREE_VERSION:-v3.11.0}}"
: "${PYTORCH_HOST_INDEX_URL:=https://download.pytorch.org/whl/cpu}"
: "${DEFAULT_PYPI_INDEX_URL:=https://pypi.org/simple}"

if [ -f /opt/scripts/core/parallelism.sh ]; then
  # shellcheck disable=SC1091
  source /opt/scripts/core/parallelism.sh 2>/dev/null || true
  # This wheelhouse compiles PyTorch from source (PYTORCH_REF); its aten/autograd
  # TUs peak ~4GB/cc1plus, so budget ~4GB/job (compute_cpp_heavy_jobs) rather than
  # the generic 2GB -- same OOM class as the litert build. Fall back to the older
  # 2GB helper, then nproc, if the newer helper is absent (older sourced copy).
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

if ! command -v log >/dev/null 2>&1; then
  log() { printf '[INFO] %s\n' "$*"; }
fi
if ! command -v warn >/dev/null 2>&1; then
  warn() { printf '[WARN] %s\n' "$*" >&2; }
fi

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
    if command -v cross_wheel_platform_tag >/dev/null 2>&1; then
        cross_wheel_platform_tag
        return $?
    fi
    if ! command -v arch_linux_platform_tag_for >/dev/null 2>&1; then
        return 1
    fi
    arch_linux_platform_tag_for "$(cross_target_arch 2>/dev/null || true)"
}

prepare_workspace() {
    rm -rf "${APP_WHEELHOUSE_BUILD_ROOT}" "${APP_WHEELHOUSE_DIR}"
    mkdir -p "${APP_WHEELHOUSE_BUILD_ROOT}" "${APP_WHEELHOUSE_DIR}"
}

install_build_dependencies() {
    if command -v cross_apt_update >/dev/null 2>&1; then
        cross_apt_update -y
    else
        apt-get update -y
    fi

    if command -v install_host_packages >/dev/null 2>&1; then
        install_host_packages git ninja-build cmake pkg-config unzip rsync
        install_host_packages libopenblas-dev liblapack-dev zlib1g-dev libjpeg-dev libpng-dev libtiff-dev libwebp-dev
        if ! install_target_packages libopenblas-dev liblapack-dev zlib1g-dev libjpeg-dev libpng-dev libtiff-dev libwebp-dev; then
            warn "Some riscv64 target build dependencies are unavailable; continuing with the staged sysroot"
        fi
        # Target Python stdlib provides /usr/lib/python3.X/_sysconfigdata__linux_<triplet>.py,
        # which resolve_target_python_sysconfig_export needs so the wheel builds
        # use the TARGET Python ABI metadata (correct extension suffixes) instead
        # of falling back to the host sysconfig. Own apt call: best-effort, and
        # install_target_packages groups are all-or-nothing.
        install_target_packages libpython3-stdlib || \
            warn "Target libpython3-stdlib unavailable; wheel builds will use host sysconfig"
        # Target sleef: pytorch's bundled sleef compiles its codegen tools
        # (mkrename/mkdisp) for the TARGET under cross and dies with
        # "Exec format error" when the build runs them on the host. With the
        # target libsleef-dev present, build_torch_wheel sets USE_SYSTEM_SLEEF=1
        # and skips the bundled build entirely. Best-effort (ports coverage).
        install_target_packages libsleef-dev || \
            warn "Target libsleef-dev unavailable; bundled sleef will fail under cross (Exec format error)"
        return 0
    fi

    apt-get install -y --no-install-recommends \
        git ninja-build cmake pkg-config unzip rsync \
        libopenblas-dev liblapack-dev zlib1g-dev libjpeg-dev libpng-dev libtiff-dev libwebp-dev
}

prepare_build_environment() {
    # NOTE: prepare_workspace is NOT called here — main() already runs it
    # (unconditionally, before this function) so the wheelhouse dir exists
    # even when this function bails out early.
    if ! cross_build_is_active; then
        log "Skipping app wheelhouse build outside of amd64-hosted cross mode"
        return 1
    fi

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

    BUILD_PYTHON="$(require_host_python)" || return 1

    uv pip install --python "${BUILD_PYTHON}" -U \
        "setuptools<82" wheel build cmake ninja numpy packaging pyyaml requests six typing-extensions \
        sympy filelock networkx jinja2
}

# pytorch's setup.py does NOT forward our CMAKE_ARGS -D flags into its cmake
# invocation (verified from the logged configure line: none of the cross args
# were present; only CC/CXX env reached the build, so cmake configured as a
# NATIVE x86_64 build with a riscv64 compiler and cpuinfo picked x86 sources).
# CMake >= 3.21 honors the CMAKE_TOOLCHAIN_FILE ENVIRONMENT variable natively
# at project() time — the only reliable way to make a setup.py-driven cmake
# cross-aware. Keep it minimal: system identity only; compilers keep flowing
# via CC/CXX env exactly as they already (working) do.
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
    cat > "${path}" <<EOF
# Generated by build-app-wheelhouse.sh — minimal cross identity for
# setup.py-driven cmake builds (compilers come from CC/CXX env).
set(CMAKE_SYSTEM_NAME Linux)
set(CMAKE_SYSTEM_PROCESSOR ${processor})
set(CMAKE_FIND_ROOT_PATH_MODE_PROGRAM NEVER)
EOF
    # The toolchain file is also our guaranteed channel for cache variables that
    # pytorch's setup.py won't forward from CMAKE_ARGS: hand ProtoBuf.cmake a
    # HOST-runnable protoc (see build_host_protoc in build_torch_wheel).
    if [ -n "${CROSS_HOST_PROTOC:-}" ] && [ -x "${CROSS_HOST_PROTOC}" ]; then
        printf 'set(CAFFE2_CUSTOM_PROTOC_EXECUTABLE "%s" CACHE FILEPATH "host protoc for cross builds")\n' \
            "${CROSS_HOST_PROTOC}" >> "${path}"
    fi
    # Target Python Development artifacts: without these, FindPython reports
    # "missing components: Development" under cross, pytorch silently flips
    # BUILD_PYTHON to OFF, libtorch_python.so is never built, and the final
    # torch._C stub link dies with "cannot find -ltorch_python" (all verified
    # from configure/link logs). Explicit artifact cache vars satisfy
    # FindPython/FindPython3 without probing.
    local py_inc py_lib
    py_inc="$(cross_target_python_include_dir 2>/dev/null || true)"
    py_lib="$(cross_target_python_library 2>/dev/null || true)"
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

# Build the sysconfigdata export string for the target Python, but ONLY if the
# module file is actually importable. Setting _PYTHON_SYSCONFIGDATA_NAME
# without providing the module GUARANTEES an instant ModuleNotFoundError in
# setup.py (that's exactly how the wheel builds used to die once they got past
# shell_quote_args). Searches the staged target Python first, then the apt
# target Python. Prints the export string (name + PYTHONPATH) or nothing.
resolve_target_python_sysconfig_export() {
    local target_triplet="" name="" stage_root="" dir="" search_root
    target_triplet="$(cross_target_triplet 2>/dev/null || true)"
    [ -n "${target_triplet}" ] || return 0
    name="_sysconfigdata__linux_${target_triplet}"

    stage_root="$(cross_target_python_root 2>/dev/null || true)"
    for search_root in \
        ${stage_root:+"${stage_root}/lib"} \
        "/usr/lib" ; do
        [ -d "${search_root}" ] || continue
        dir="$(find "${search_root}" -maxdepth 2 -name "${name}.py" -printf '%h\n' -quit 2>/dev/null || true)"
        [ -n "${dir}" ] && break
    done

    if [ -z "${dir}" ]; then
        warn "Target Python sysconfigdata ${name}.py not found under ${stage_root:-<no staged python>}/lib or /usr/lib; building with the HOST sysconfig (extension tags may need retagging)."
        return 0
    fi

    printf 'export _PYTHON_SYSCONFIGDATA_NAME=%q; export PYTHONPATH=%q${PYTHONPATH:+:${PYTHONPATH}}' \
        "${name}" "${dir}"
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
    target_python_include="$(cross_target_python_include_dir 2>/dev/null || true)"
    target_python_arch_include="$(cross_target_python_arch_include_dir 2>/dev/null || true)"
    target_python_library="$(cross_target_python_library 2>/dev/null || true)"
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

retag_directory_wheels() {
    local dist_dir="$1"
    local glob_prefix="$2"
    local platform_tag="$3"
    local wheel_path

    shopt -s nullglob
    for wheel_path in "${dist_dir}"/${glob_prefix}-*.whl; do
        "${BUILD_PYTHON}" -m wheel tags --remove --platform-tag="${platform_tag}" "${wheel_path}" >/dev/null || \
            warn "Failed to retag $(basename "${wheel_path}") for ${platform_tag}"
    done
    shopt -u nullglob
}

extract_torch_wheel() {
    TORCH_STAGING_DIR="${APP_WHEELHOUSE_BUILD_ROOT}/torch-staging"
    rm -rf "${TORCH_STAGING_DIR}"
    mkdir -p "${TORCH_STAGING_DIR}"
    unzip -q -o "${TARGET_TORCH_WHEEL}" -d "${TORCH_STAGING_DIR}"
}

# pytorch 2.13 restructured how torch._C is built for the wheel and REGRESSED it
# under cross-compile. In 2.12 setup.py compiled the distutils stub torch/csrc/
# stub.c and linked it straight to build/lib/torch/_C.cpython-<abi>.so (correct
# EXT_SUFFIX), which bdist_wheel then packaged. In 2.13 there is no "building
# 'torch._C' extension" step at all: cmake links a generic, un-suffixed
# torch/_C.so (ninja: "Linking C shared module torch/_C.so") and bdist_wheel never
# copies it into the wheel. The wheel then ships ONLY the torch/_C/ *.pyi stub
# folder, so on install `torch._C` resolves to that namespace folder
# (torch._C.__file__ is None) and `import torch` dies with the misleading
# "Failed to load PyTorch C extensions ... loaded the torch/_C folder" (the real
# cause -- no compiled _C extension -- is masked by pytorch's `raise ... from
# None`). The compiled module IS produced by cmake at
# ${src_dir}/torch/_C.so; if the built wheel lacks a top-level torch/_C*.so,
# inject that under the target ABI name and repack (wheel pack recomputes RECORD).
# Version-agnostic: a no-op once the wheel already carries torch/_C*.so.
_torch_ensure_c_extension() {
    local dist_dir="$1"
    local wheel_path built_c_ext staging suffix triplet pyabi
    shopt -s nullglob
    local -a wheels=("${dist_dir}"/torch-*.whl)
    shopt -u nullglob
    [ "${#wheels[@]}" -gt 0 ] || return 0
    wheel_path="${wheels[0]}"

    # Already carries the top-level compiled extension? nothing to do.
    if unzip -l "${wheel_path}" 2>/dev/null | grep -qE ' torch/_C[^/]*\.so$'; then
        return 0
    fi

    built_c_ext="${APP_WHEELHOUSE_BUILD_ROOT}/pytorch/torch/_C.so"
    if [ ! -f "${built_c_ext}" ]; then
        warn "torch wheel lacks torch/_C*.so and cmake-built ${built_c_ext} is absent; import torch WILL fail (missing C extension)"
        return 0
    fi

    # Target extension suffix cpython-<pyABI>-<triplet>.so: pyABI from the wheel's
    # abi tag (…-cpXYZ-cpXYZ-…), triplet from the cross helper.
    triplet="$(cross_target_triplet 2>/dev/null || echo riscv64-linux-gnu)"
    pyabi="$(basename "${wheel_path}" | sed -nE 's/.*-cp([0-9]+)-cp[0-9]+-.*/\1/p')"
    [ -n "${pyabi}" ] || pyabi="314"
    suffix="cpython-${pyabi}-${triplet}.so"

    staging="${APP_WHEELHOUSE_BUILD_ROOT}/torch-cext-repack"
    rm -rf "${staging}"
    mkdir -p "${staging}"
    unzip -q -o "${wheel_path}" -d "${staging}"
    cp "${built_c_ext}" "${staging}/torch/_C.${suffix}"
    log "Injected missing torch/_C.${suffix} into $(basename "${wheel_path}") (pytorch ${PYTORCH_REF} cross bdist_wheel dropped the compiled C extension)"

    rm -f "${wheel_path}"
    if ! ( cd "${staging}" && "${BUILD_PYTHON}" -m wheel pack . -d "${dist_dir}" ); then
        warn "wheel pack failed while repackaging the torch _C extension"
        return 1
    fi
}

# The build_torch_wheel phase helpers below read build_torch_wheel's locals via
# bash dynamic scoping (the subshell inherits them; nested calls resolve them on
# the call stack). They must be called only from build_torch_wheel.
# shellcheck disable=SC2154

# Build the canonical HOST protoc with pytorch's own helper (scrubbed env: no
# cross toolchain). Bundled protobuf otherwise builds protoc for the TARGET and
# onnx codegen execs it on the host -> "Exec format error" (protoc-3.13.0.0).
# Sets CROSS_HOST_PROTOC (consumed by write_cross_cmake_toolchain_file via the
# generated toolchain file).
_torch_build_host_protoc() {
    CROSS_HOST_PROTOC=""
    if [ ! -f "${src_dir}/scripts/build_host_protoc.sh" ]; then
        warn "pytorch has no scripts/build_host_protoc.sh at this ref; onnx codegen will hit Exec format error"
        return 0
    fi
    log "Building host protoc via scripts/build_host_protoc.sh..."
    # CMAKE_POLICY_VERSION_MINIMUM: bundled protobuf 3.13 declares
    # cmake_minimum_required(<3.5), which cmake >=4 refuses outright; the flag is
    # cmake's own documented escape hatch. No PATH scrub needed: /opt/cross-bin
    # carries only triplet-prefixed names (bare cross cc/gcc live in
    # /opt/cross-bin/bare, never on PATH), so bare gcc/g++ resolve to the host
    # toolchain. CC=gcc/CXX=g++ pinning stays as defense-in-depth.
    if (cd "${src_dir}" && \
        env -u AR -u RANLIB -u LD -u CFLAGS -u CXXFLAGS -u CPPFLAGS -u LDFLAGS \
            -u CMAKE_TOOLCHAIN_FILE -u CMAKE_SYSTEM_NAME -u CMAKE_SYSTEM_PROCESSOR \
            CC=gcc CXX=g++ \
            bash scripts/build_host_protoc.sh \
                --other-flags "-DCMAKE_POLICY_VERSION_MINIMUM=3.5" > /tmp/build_host_protoc.log 2>&1); then
        CROSS_HOST_PROTOC="${src_dir}/build_host_protoc/bin/protoc"
    fi
    # Readiness gate = EXECUTE it, not just -x: a cross-built protoc is
    # executable-on-disk but dies with Exec format error at run time.
    if [ -n "${CROSS_HOST_PROTOC}" ] && "${CROSS_HOST_PROTOC}" --version >/dev/null 2>&1; then
        log "Host protoc ready: ${CROSS_HOST_PROTOC} ($("${CROSS_HOST_PROTOC}" --version 2>/dev/null))"
    else
        CROSS_HOST_PROTOC=""
        warn "build_host_protoc.sh failed or produced a non-host binary (tail of /tmp/build_host_protoc.log follows); onnx codegen will hit Exec format error"
        tail -20 /tmp/build_host_protoc.log >&2 || true
    fi
}

# Bundled sleef cross-compiles its host-run codegen (mkrename) for the target ->
# "Exec format error". Prefer the target's system sleef when libsleef-dev landed
# (see install_build_dependencies); otherwise keep the bundled build so the
# failure stays visible. Sets use_system_sleef.
_torch_detect_system_sleef() {
    use_system_sleef=0
    if command -v cross_package_files_present >/dev/null 2>&1 && \
       cross_package_files_present "libsleef-dev:$(cross_target_arch 2>/dev/null || echo none)"; then
        use_system_sleef=1
        log "Using target system sleef (libsleef-dev) instead of pytorch's bundled sleef"
    else
        warn "Target libsleef-dev not present; bundled sleef will likely fail (Exec format error on mkrename)"
    fi
}

# Run pytorch's setup.py bdist_wheel in a scrubbed subshell with the full cross
# env. Reads src_dir/cmake_args_string/wheel_platform/python_sysconfig_export/
# use_system_sleef/dist_dir + CROSS_HOST_PROTOC (via write_cross_cmake_toolchain_
# file) through dynamic scope. Returns non-zero on build failure.
_torch_run_setup_py() {
    (
        cd "${src_dir}" && \
        export CMAKE_GENERATOR=Ninja && \
        export CMAKE_ARGS="${cmake_args_string}" && \
        { cross_toolchain_file="$(write_cross_cmake_toolchain_file || true)"; \
          [ -n "${cross_toolchain_file}" ] && export CMAKE_TOOLCHAIN_FILE="${cross_toolchain_file}"; true; } && \
        export _PYTHON_HOST_PLATFORM="${wheel_platform}" && \
        if [ -n "${python_sysconfig_export}" ]; then eval "${python_sysconfig_export}"; fi && \
        export PYTHON_EXECUTABLE="${BUILD_PYTHON}" Python_EXECUTABLE="${BUILD_PYTHON}" Python3_EXECUTABLE="${BUILD_PYTHON}" && \
        export MAX_JOBS="${MAX_JOBS}" && \
        export BLAS=OpenBLAS USE_NUMPY=1 && \
        export USE_CUDA=0 USE_CUDNN=0 USE_CUSPARSELT=0 USE_CUDSS=0 USE_CUFILE=0 USE_ROCM=0 USE_XPU=0 && \
        export USE_DISTRIBUTED=0 USE_GLOO=0 USE_MPI=0 USE_TENSORPIPE=0 USE_NCCL=0 && \
        export BUILD_TEST=0 BUILD_BINARY=0 USE_KINETO=0 && \
        export USE_FBGEMM=0 USE_MKLDNN=0 USE_NNPACK=0 USE_QNNPACK=0 USE_PYTORCH_QNNPACK=0 USE_XNNPACK=0 && \
        export USE_SYSTEM_SLEEF="${use_system_sleef}" && \
        export USE_FLASH_ATTENTION=0 USE_MEM_EFF_ATTENTION=0 USE_OPENMP=0 && \
        export CFLAGS="${CFLAGS:+${CFLAGS} }-idirafter /usr/include" && \
        export CXXFLAGS="${CXXFLAGS:+${CXXFLAGS} }-idirafter /usr/include" && \
        "${BUILD_PYTHON}" setup.py bdist_wheel --plat-name "${wheel_platform}" -d "${dist_dir}"
    )
}

# Retag, collect, install the built torch wheel; set TARGET_TORCH_WHEEL /
# TARGET_TORCH_VERSION (globals) and extract it. Reads dist_dir + wheel_platform.
_collect_torch_wheel() {
    local -a built_wheels=()
    # Repair the 2.13 cross-build gap (missing torch/_C*.so) BEFORE retag/collect
    # so the fixed wheel flows through the normal path.
    _torch_ensure_c_extension "${dist_dir}"
    retag_directory_wheels "${dist_dir}" torch "${wheel_platform}"

    shopt -s nullglob
    built_wheels=("${dist_dir}"/torch-*.whl)
    shopt -u nullglob
    if [ "${#built_wheels[@]}" -eq 0 ]; then
        warn "PyTorch cross build completed without producing a wheel"
        return 1
    fi

    cp -a "${built_wheels[@]}" "${APP_WHEELHOUSE_DIR}/"

    TARGET_TORCH_WHEEL="${APP_WHEELHOUSE_DIR}/$(basename "${built_wheels[0]}")"
    TARGET_TORCH_VERSION="$(parse_wheel_version "${TARGET_TORCH_WHEEL}" torch)"
    extract_torch_wheel
    log "Built PyTorch cross wheel $(basename "${TARGET_TORCH_WHEEL}")"
}

build_torch_wheel() {
    local wheel_platform=""
    local src_dir="${APP_WHEELHOUSE_BUILD_ROOT}/pytorch"
    local dist_dir="${APP_WHEELHOUSE_BUILD_ROOT}/dist-torch"
    local -a cmake_args=()
    local cmake_args_string=""
    local python_sysconfig_export=""
    local CROSS_HOST_PROTOC=""   # set by _torch_build_host_protoc; read by toolchain file
    local use_system_sleef=0     # set by _torch_detect_system_sleef

    wheel_platform="$(wheel_platform_tag || true)"
    if [ -z "${wheel_platform}" ]; then
        warn "Could not determine the riscv64 wheel platform tag for PyTorch"
        return 1
    fi

    # Export target sysconfigdata ONLY when the module is importable (name +
    # PYTHONPATH together); see resolve_target_python_sysconfig_export.
    python_sysconfig_export="$(resolve_target_python_sysconfig_export)"

    git_clone_ref https://github.com/pytorch/pytorch.git "${PYTORCH_REF}" "${src_dir}" --recursive --shallow-submodules || {
        warn "Failed to clone PyTorch ${PYTORCH_REF}"
        return 1
    }

    rm -rf "${dist_dir}"
    mkdir -p "${dist_dir}"

    _torch_build_host_protoc
    _torch_detect_system_sleef

    append_common_cross_cmake_args cmake_args
    cmake_args+=("-DBLAS=OpenBLAS")
    cmake_args_string="$(shell_quote_args "${cmake_args[@]}")"

    if ! _torch_run_setup_py; then
        warn "PyTorch riscv64 cross wheel build failed; leaving it to the native torch stage"
        return 1
    fi

    _collect_torch_wheel
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

# The build_torchvision_wheel phase helpers read that function's locals via bash
# dynamic scoping; call them only from build_torchvision_wheel.
# shellcheck disable=SC2154

# Run torchvision's setup.py bdist_wheel in a scrubbed subshell with the full
# cross env + staged libtorch paths. Reads src_dir/cmake_args_string/
# wheel_platform/python_sysconfig_export/target_torch_* via dynamic scope.
# Returns non-zero on build failure.
_torchvision_run_setup_py() {
    (
        cd "${src_dir}" && \
        export CMAKE_GENERATOR=Ninja && \
        export CMAKE_ARGS="${cmake_args_string}" && \
        { cross_toolchain_file="$(write_cross_cmake_toolchain_file || true)"; \
          [ -n "${cross_toolchain_file}" ] && export CMAKE_TOOLCHAIN_FILE="${cross_toolchain_file}"; true; } && \
        export _PYTHON_HOST_PLATFORM="${wheel_platform}" && \
        if [ -n "${python_sysconfig_export}" ]; then eval "${python_sysconfig_export}"; fi && \
        export FORCE_CUDA=0 FORCE_MPS=0 DEBUG=0 && \
        export PYTORCH_VERSION="${TARGET_TORCH_VERSION}" && \
        export TORCHVISION_TORCH_STAGING="${TORCH_STAGING_DIR}" && \
        export TORCHVISION_INCLUDE="${target_torch_include}:${target_torch_csrc}" && \
        export TORCHVISION_LIBRARY="${target_torch_lib}" && \
        _vis_multiarch="$(cross_target_triplet 2>/dev/null || true)" && \
        export CFLAGS="${CFLAGS:+${CFLAGS} }${_vis_multiarch:+-idirafter /usr/include/${_vis_multiarch} }-idirafter /usr/include" && \
        export CXXFLAGS="${CXXFLAGS:+${CXXFLAGS} }${_vis_multiarch:+-idirafter /usr/include/${_vis_multiarch} }-idirafter /usr/include" && \
        "${BUILD_PYTHON}" setup.py bdist_wheel --plat-name "${wheel_platform}" -d "${dist_dir}"
    )
}

# torch.utils.cpp_extension swallows ninja's compile output on the non-verbose
# path ("Error compiling objects for extension" with no detail). Re-run ninja in
# the extension build dir to surface the real compiler error. Reads src_dir.
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
    retag_directory_wheels "${dist_dir}" torchvision "${wheel_platform}"

    shopt -s nullglob
    built_wheels=("${dist_dir}"/torchvision-*.whl)
    shopt -u nullglob
    if [ "${#built_wheels[@]}" -eq 0 ]; then
        warn "torchvision cross build completed without producing a wheel"
        return 1
    fi

    cp -a "${built_wheels[@]}" "${APP_WHEELHOUSE_DIR}/"
    log "Built torchvision cross wheel $(basename "${built_wheels[0]}")"
}

build_torchvision_wheel() {
    local wheel_platform=""
    local src_dir="${APP_WHEELHOUSE_BUILD_ROOT}/vision"
    local dist_dir="${APP_WHEELHOUSE_BUILD_ROOT}/dist-vision"
    local -a cmake_args=()
    local cmake_args_string=""
    local target_torch_include=""
    local target_torch_csrc=""
    local target_torch_lib=""
    local python_sysconfig_export=""

    if [ -z "${TARGET_TORCH_WHEEL}" ] || [ -z "${TORCH_STAGING_DIR}" ]; then
        warn "Skipping torchvision cross wheel build because no target torch wheel is available"
        return 1
    fi

    if ! install_host_torch_for_vision; then
        warn "Failed to install the host torch wheel needed to drive the torchvision build"
        return 1
    fi

    wheel_platform="$(wheel_platform_tag || true)"
    if [ -z "${wheel_platform}" ]; then
        warn "Could not determine the riscv64 wheel platform tag for torchvision"
        return 1
    fi

    # Export target sysconfigdata ONLY when the module is importable (name +
    # PYTHONPATH together); see resolve_target_python_sysconfig_export.
    python_sysconfig_export="$(resolve_target_python_sysconfig_export)"

    git_clone_ref https://github.com/pytorch/vision.git "${TORCHVISION_REF}" "${src_dir}" || {
        warn "Failed to clone torchvision ${TORCHVISION_REF}"
        return 1
    }

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

# ---------------------------------------------------------------------------
# IREE (iree.dev) riscv64 runtime wheel — best-effort, NON-GATING.
#
# PyPI ships iree-base-{compiler,runtime} cp312-abi3 wheels for x86_64+aarch64
# only; riscv64 has none, so we cross-build the RUNTIME wheel here. IREE cross-
# builds in two stages (https://iree.dev/building-from-source/riscv/):
#   1. a HOST build producing the tools referenced via IREE_HOST_BIN_DIR, and
#   2. a TARGET build that cross-compiles the runtime + its Python bindings
#      against those host tools.
# HOST build is IREE_BUILD_COMPILER=ON (full LLVM). An earlier LLVM-free host
# (BUILD_COMPILER=OFF) got the host stage passing but the riscv64 TARGET runtime
# build then failed wanting `llvm-link` from IREE_HOST_BIN_DIR — IREE compiles
# its device-bitcode libraries with llvm-link, which only exists when the host
# built LLVM (run iree-0714c, 2026-07-15). So we now init the llvm-project
# submodule and build the host compiler; that produces iree-compile + iree-tblgen
# + llvm-link. The TARGET still sets BUILD_COMPILER=OFF (no riscv64 cross-LLVM;
# upstream's riscv64 lane does the same). Cost: the host LLVM build is heavy
# (~1h+, tens of GB) — bounded only by "host, not cross".
#
# Everything here is best-effort: any failure WARNs and returns 0 so torch/vision
# and the rest of the media build proceed. This cannot be validated on the amd64
# dev host — expect a round of iteration the first time it runs under the real
# cross toolchain.
build_iree_wheels() {
    local src_dir="${APP_WHEELHOUSE_BUILD_ROOT}/iree"
    local host_build="${APP_WHEELHOUSE_BUILD_ROOT}/iree-build-host"
    local host_install="${host_build}/install"
    local target_build="${APP_WHEELHOUSE_BUILD_ROOT}/iree-build-target"
    local dist_dir="${APP_WHEELHOUSE_BUILD_ROOT}/dist-iree"
    local wheel_platform="" toolchain_file=""
    local -a cmake_args=()

    command -v cmake >/dev/null 2>&1 || { warn "cmake absent; skipping IREE riscv64 runtime wheel"; return 1; }
    command -v ninja >/dev/null 2>&1 || { warn "ninja absent; skipping IREE riscv64 runtime wheel"; return 1; }

    wheel_platform="$(wheel_platform_tag || true)"
    [ -n "${wheel_platform}" ] || { warn "no riscv64 wheel platform tag; skipping IREE"; return 1; }

    # Clone at the pinned tag, then init submodules. llvm-project IS initialised
    # now (the host compiler build needs it to produce llvm-link for the target's
    # device-bitcode libs). Still EXCLUDE torch-mlir + stablehlo: they are
    # MLIR-dialect compiler INPUTS the runtime never needs, and torch-mlir drags a
    # second full NESTED externals/llvm-project via --recursive (pure waste).
    # Because those two submodules stay uninitialised, IREE's configure-time
    # check_submodule_init.py (CMakeLists.txt) would hard-fail (run iree-0714d,
    # 2026-07-15), so the host build passes -DIREE_ERROR_ON_MISSING_SUBMODULES=OFF
    # and disables the matching input dialects (-DIREE_INPUT_TORCH/STABLEHLO=OFF).
    rm -rf "${src_dir}"
    if ! git clone --branch "${IREE_REF}" --depth 1 https://github.com/iree-org/iree.git "${src_dir}"; then
        warn "IREE clone ${IREE_REF} failed; skipping riscv64 runtime wheel"; return 1
    fi
    if ! ( cd "${src_dir}" && git \
             -c submodule."third_party/torch-mlir".update=none \
             -c submodule."third_party/stablehlo".update=none \
             submodule update --init --recursive --depth 1 ); then
        warn "IREE submodule init failed; skipping riscv64 runtime wheel"; return 1
    fi

    # Stage 1 — FULL host compiler build (LLVM) for IREE_HOST_BIN_DIR, with the
    # NATIVE amd64 compiler. This produces iree-compile + iree-tblgen + llvm-link.
    # This function runs inside the riscv64 cross environment, where
    # CC/CXX/*FLAGS/CMAKE_TOOLCHAIN_FILE all point at the riscv64 cross toolchain
    # (set up for the torch build). The host tools MUST be native or they can't
    # execute on the build host to drive the target build — the first run
    # (2026-07-14) failed here precisely because the host cmake inherited the cross
    # CC/CXX. So strip the cross env for BOTH the configure and the build, and pin
    # the host compiler + both Python executables (FindPython/FindPython3 disagreed
    # on the first run). The LLVM build is heavy; MAX_JOBS is already the
    # cpp-heavy (≈4GB/job) count for this stage.
    local host_cc="" host_cxx=""
    for host_cc in /usr/bin/gcc /usr/bin/cc /usr/bin/clang; do [ -x "${host_cc}" ] && break; done
    for host_cxx in /usr/bin/g++ /usr/bin/c++ /usr/bin/clang++; do [ -x "${host_cxx}" ] && break; done
    rm -rf "${host_build}"
    if ! env -u CC -u CXX -u CPP -u CFLAGS -u CXXFLAGS -u CPPFLAGS -u LDFLAGS \
             -u AR -u RANLIB -u CMAKE_TOOLCHAIN_FILE -u CMAKE_ARGS \
            cmake -G Ninja -S "${src_dir}" -B "${host_build}" \
            -DCMAKE_BUILD_TYPE=Release \
            -DCMAKE_C_COMPILER="${host_cc}" \
            -DCMAKE_CXX_COMPILER="${host_cxx}" \
            -DIREE_BUILD_COMPILER=ON \
            -DIREE_BUILD_PYTHON_BINDINGS=OFF \
            -DIREE_BUILD_SAMPLES=OFF \
            -DIREE_BUILD_TESTS=OFF \
            -DIREE_ERROR_ON_MISSING_SUBMODULES=OFF \
            -DIREE_ENABLE_WERROR_FLAG=OFF \
            -DIREE_INPUT_TORCH=OFF \
            -DIREE_INPUT_STABLEHLO=OFF \
            -DCMAKE_INSTALL_PREFIX="${host_install}" \
            -DPython_EXECUTABLE="${BUILD_PYTHON}" \
            -DPython3_EXECUTABLE="${BUILD_PYTHON}"; then
        warn "IREE host-compiler configure failed; skipping riscv64 runtime wheel"; return 1
    fi
    # Capture build output to a log and echo its tail on failure. BuildKit
    # collapses the tens-of-thousands of ninja progress lines, so a bare failure
    # surfaces NO error (the silent-fast-fail gotcha, iree-0714f) — the tail dump
    # is the only way to see why the cross build actually died.
    if ! env -u CC -u CXX -u CPP -u CFLAGS -u CXXFLAGS -u CPPFLAGS -u LDFLAGS \
             -u AR -u RANLIB -u CMAKE_TOOLCHAIN_FILE -u CMAKE_ARGS \
            cmake --build "${host_build}" --target install -- -j"${MAX_JOBS}" \
            > "${host_build}.log" 2>&1; then
        warn "IREE host-compiler build failed; skipping riscv64 runtime wheel"
        echo "----- IREE host build: last 80 log lines -----"
        tail -n 80 "${host_build}.log" 2>/dev/null
        echo "----- end IREE host build log -----"
        return 1
    fi

    # Stage 2 — cross the runtime (+ Python bindings) against the host tools.
    # IREE_ENABLE_WERROR_FLAG=OFF is REQUIRED here (iree-0714g): the nanobind Python
    # bindings pull in the cross Python 3.14 pyconfig.h, which defines _POSIX_C_SOURCE/
    # _XOPEN_SOURCE to OLDER values than resolute's glibc features.h (already included
    # via <optional>/<cstdint> in binding.h) — a benign macro redefinition that IREE's
    # default -Werror turns fatal. Dropping -Werror keeps it a warning and lets the
    # riscv64 iree_base_runtime wheel build. (Python.h-include-order can't be fixed from
    # our side without patching IREE headers.)
    toolchain_file="$(write_cross_cmake_toolchain_file || true)"
    [ -n "${toolchain_file}" ] || { warn "no cross toolchain file for IREE; skipping"; return 1; }
    append_common_cross_cmake_args cmake_args

    rm -rf "${target_build}"
    if ! cmake -G Ninja -S "${src_dir}" -B "${target_build}" \
            -DCMAKE_TOOLCHAIN_FILE="${toolchain_file}" \
            "${cmake_args[@]}" \
            -DIREE_HOST_BIN_DIR="${host_install}/bin" \
            -DIREE_BUILD_COMPILER=ON \
            -DIREE_BUILD_PYTHON_BINDINGS=ON \
            -DIREE_BUILD_SAMPLES=OFF \
            -DIREE_BUILD_TESTS=OFF \
            -DIREE_ERROR_ON_MISSING_SUBMODULES=OFF \
            -DIREE_ENABLE_WERROR_FLAG=OFF \
            -DIREE_INPUT_TORCH=OFF \
            -DIREE_INPUT_STABLEHLO=OFF \
            -DIREE_HAL_DRIVER_LOCAL_SYNC=ON \
            -DIREE_HAL_DRIVER_LOCAL_TASK=ON \
            -DCMAKE_BUILD_TYPE=Release > "${target_build}.cfg.log" 2>&1; then
        warn "IREE riscv64 runtime configure failed (best-effort); continuing without it"
        echo "----- IREE target configure: last 80 log lines -----"
        tail -n 80 "${target_build}.cfg.log" 2>/dev/null
        echo "----- end IREE target configure log -----"
        return 1
    fi
    if ! cmake --build "${target_build}" -- -j"${MAX_JOBS}" > "${target_build}.log" 2>&1; then
        warn "IREE riscv64 runtime build failed (best-effort); continuing without it"
        echo "----- IREE target build: last 80 log lines -----"
        tail -n 80 "${target_build}.log" 2>/dev/null
        echo "----- end IREE target build log -----"
        return 1
    fi

    # The build tree exposes compiler/ and runtime/ wheel projects (COMPILER=ON
    # cross-builds LLVM/MLIR for riscv64 so iree-compile + iree.compiler ship too,
    # not just iree.runtime). Package BOTH — both are REQUIRED on riscv64.
    rm -rf "${dist_dir}"; mkdir -p "${dist_dir}"
    local _proj _pkg
    for _proj in compiler runtime; do
        _pkg="iree_base_${_proj}"
        if [ ! -d "${target_build}/${_proj}" ]; then
            warn "IREE target build produced no ${_proj}/ wheel project"; return 1
        fi
        if ! "${BUILD_PYTHON}" -m pip wheel "${target_build}/${_proj}" -w "${dist_dir}" --no-deps --no-build-isolation > "${target_build}.${_proj}-wheel.log" 2>&1; then
            warn "IREE riscv64 ${_proj} wheel packaging failed"
            echo "----- IREE ${_proj} wheel: last 60 log lines -----"
            tail -n 60 "${target_build}.${_proj}-wheel.log" 2>/dev/null
            echo "----- end IREE ${_proj} wheel log -----"
            return 1
        fi
        retag_directory_wheels "${dist_dir}" "${_pkg}" "${wheel_platform}"
    done

    shopt -s nullglob
    local -a wheels=("${dist_dir}"/iree_base_compiler-*.whl "${dist_dir}"/iree_base_runtime-*.whl "${dist_dir}"/iree-*.whl)
    shopt -u nullglob
    if [ "${#wheels[@]}" -lt 2 ]; then
        warn "IREE riscv64 build did not produce BOTH compiler+runtime wheels (got ${#wheels[@]})"; return 1
    fi
    cp -a "${wheels[@]}" "${APP_WHEELHOUSE_DIR}/"
    log "Built IREE riscv64 wheels: $(cd "${dist_dir}" && echo iree_base_*-*.whl)"
}

main() {
    prepare_workspace
    if ! prepare_build_environment; then
        return 0
    fi

    if ! build_torch_wheel; then
        warn "Continuing without prebuilt riscv64 torch/vision wheels"
        return 0
    fi

    if ! build_torchvision_wheel; then
        warn "Continuing without a prebuilt riscv64 torchvision wheel"
    fi

    # IREE is REQUIRED on riscv64 (no PyPI wheel exists for it, unlike amd64/arm64),
    # not best-effort: a failed cross-build must FAIL THE BUILD (fail early) so it gets
    # fixed, never silently ship an image missing iree.runtime. The failure paths above
    # dump the real cmake/ninja tail before returning non-zero. Bypass only with an
    # explicit ALLOW_IREE_BUILD_FAIL=1 for a deliberate IREE-less debugging image.
    if ! build_iree_wheels; then
        if [ "${ALLOW_IREE_BUILD_FAIL:-0}" = "1" ]; then
            warn "riscv64 IREE build failed but ALLOW_IREE_BUILD_FAIL=1 set — continuing without it"
        else
            err "riscv64 IREE runtime build FAILED — IREE is required (see the dumped build log above). Set ALLOW_IREE_BUILD_FAIL=1 only for a deliberate IREE-less image."
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
