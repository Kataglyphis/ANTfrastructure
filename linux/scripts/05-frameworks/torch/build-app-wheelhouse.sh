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
        # ccache is a HOST tool (it wraps the cross-compiler invocations that run
        # on the amd64 build host), so install it host-side. Without it the IREE
        # bundled-LLVM (~1h) and riscv64 torch aten compiles rebuild from scratch
        # every run even though the persistent /var/cache/ccache mount exists and
        # build_iree_wheels/build_torch_wheel already wire the ccache launcher
        # behind `command -v ccache`. This omission was the sole reason those
        # multi-hour cross builds never cache-hit (amd64-native path already had it).
        install_host_packages git ninja-build cmake pkg-config unzip rsync ccache sccache
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
        git ninja-build cmake pkg-config unzip rsync ccache sccache \
        libopenblas-dev liblapack-dev zlib1g-dev libjpeg-dev libpng-dev libtiff-dev libwebp-dev
}

install_native_build_dependencies() {
    # amd64 native IREE build: minimal host toolchain. ccache is the decisive lever
    # (bundled LLVM is a ~1h one-time compile; /var/cache/ccache is a persistent
    # BuildKit mount). git/cmake/ninja are usually already present from the base
    # image; this is a best-effort top-up. No cross apt mirror needed (native).
    apt-get update -y || true
    apt-get install -y --no-install-recommends \
        git ninja-build cmake pkg-config unzip rsync ccache sccache || return 1
}

prepare_build_environment() {
    # NOTE: prepare_workspace is NOT called here — main() already runs it
    # (unconditionally, before this function) so the wheelhouse dir exists
    # even when this function bails out early.
    #
    # Two modes:
    #   * CROSS  (arm64/riscv64 foreign target): stage the foreign target Python
    #     dev tree + cross toolchain (the proven riscv64 machinery, now also arm64).
    #   * NATIVE (amd64 target == build arch): no foreign target-python staging;
    #     IREE builds against the container's own from-source CPython 3.14.
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
        # amd64 NATIVE: only IREE is source-built here (torch/vision come from PyPI
        # on amd64), against the container's own CPython 3.14 — no foreign target
        # Python staging, no cross toolchain.
        install_native_build_dependencies || {
            warn "Failed to install native IREE build dependencies; leaving the app wheelhouse empty"
            return 1
        }
    fi

    BUILD_PYTHON="$(require_host_python)" || return 1

    # Build-executor pins (supply-chain audit #18): setuptools/wheel/ninja
    # EXECUTE code at build time and were resolved fresh from PyPI every run.
    # setuptools keeps the documented <82 torch-compat ceiling — pinned to the
    # newest release under it. Pure-python data deps (pyyaml, sympy, jinja2,
    # ...) stay floating on purpose: they don't shape the emitted binaries.
    uv pip install --python "${BUILD_PYTHON}" -U \
        "setuptools==${PY_SETUPTOOLS_LT82_VERSION:-81.0.0}" \
        "wheel==${PY_WHEEL_VERSION:-0.47.0}" \
        build cmake \
        "ninja==${PY_NINJA_VERSION:-1.13.0}" \
        numpy packaging pyyaml requests six typing-extensions \
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
    cat > "${path}" <<EOF || return 1
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
    # Explicit success: without it, an empty qemu_runner makes the AND-list
    # above this function's exit status (1), and set -e in the callers turns
    # "no emulator configured" into a bogus build failure.
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

# retag_directory_wheels lives in 01-core/common.sh (sourced above); the three
# call sites below pass BUILD_PYTHON as the wheel-tool launcher.

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
    if command -v cross_package_status_present >/dev/null 2>&1 && \
       cross_package_status_present "libsleef-dev:$(cross_target_arch 2>/dev/null || echo none)"; then
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
          [ -n "${cross_toolchain_file}" ] || { warn "no cross toolchain file for torch; cmake would configure a NATIVE build with the cross compiler"; return 1; }; \
          export CMAKE_TOOLCHAIN_FILE="${cross_toolchain_file}"; } && \
        export _PYTHON_HOST_PLATFORM="${wheel_platform}" && \
        if [ -n "${python_sysconfig_export}" ]; then eval "${python_sysconfig_export}"; fi && \
        export PYTHON_EXECUTABLE="${BUILD_PYTHON}" Python_EXECUTABLE="${BUILD_PYTHON}" Python3_EXECUTABLE="${BUILD_PYTHON}" && \
        export MAX_JOBS="${MAX_JOBS}" && \
        export CCACHE_DIR="${CCACHE_DIR:-/var/cache/ccache}" CCACHE_MAXSIZE="${CCACHE_MAXSIZE:-64G}" CCACHE_COMPRESS=1 && \
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
    retag_directory_wheels "${dist_dir}" torch "${wheel_platform}" "${BUILD_PYTHON}"

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
    # Route the (multi-hour) aten compile through ccache so it cache-hits on
    # rebuilds. The launcher works with the cross compiler; CCACHE_DIR is pointed
    # at the persistent /var/cache/ccache mount in _torch_run_setup_py. Guarded so
    # a host without ccache still builds (plain, no launcher).
    _cc_l="$(compiler_cache_launcher 2>/dev/null || true)"
    if [ -n "${_cc_l}" ]; then
        cmake_args+=("-DCMAKE_C_COMPILER_LAUNCHER=${_cc_l}" "-DCMAKE_CXX_COMPILER_LAUNCHER=${_cc_l}")
    fi
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
          [ -n "${cross_toolchain_file}" ] || { warn "no cross toolchain file for torchvision; cmake would configure a NATIVE build with the cross compiler"; return 1; }; \
          export CMAKE_TOOLCHAIN_FILE="${cross_toolchain_file}"; } && \
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
    retag_directory_wheels "${dist_dir}" torchvision "${wheel_platform}" "${BUILD_PYTHON}"

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
# IREE (iree.dev) compiler + runtime wheels — REQUIRED on every arch (see main()).
#
# PyPI ships iree-base-{compiler,runtime} cp312-abi3 wheels for x86_64+aarch64
# only; riscv64 has none, and we need version-specific cp314 everywhere, so we
# source-build both wheels here. IREE cross-builds in two stages
# (https://iree.dev/building-from-source/riscv/):
#   1. a HOST build producing the tools referenced via IREE_HOST_BIN_DIR, and
#   2. a TARGET build that cross-compiles the compiler + runtime + their Python
#      bindings against those host tools.
# The TARGET stage sets BUILD_COMPILER=ON (unlike upstream's runtime-only riscv64
# lane) because we ship the target iree_base_compiler wheel too. That single fact
# is what makes the HOST stage cheap: with COMPILER=ON on the target, IREE never
# imports llvm-link/clang/iree-compile from IREE_HOST_BIN_DIR (that import branch
# is gated `NOT IREE_BUILD_COMPILER`), so the host stage only has to supply
# iree-c-embed-data and iree-flatcc-cli and runs with IREE_BUILD_COMPILER=OFF.
# See the Stage-1 comment below for the full cmake citation trail; run iree-0714c
# (which forced the host compiler ON) predates the target-side COMPILER=ON switch.
#
# Failure handling: build_iree_wheels returning non-zero is FATAL in main() —
# IREE is required on every arch — so each stage dumps its log tail before
# returning. This cannot be validated on the amd64 dev host.
build_iree_wheels() {
    local src_dir="${APP_WHEELHOUSE_BUILD_ROOT}/iree"
    local host_build="${APP_WHEELHOUSE_BUILD_ROOT}/iree-build-host"
    local host_install="${host_build}/install"
    local target_build="${APP_WHEELHOUSE_BUILD_ROOT}/iree-build-target"
    local dist_dir="${APP_WHEELHOUSE_BUILD_ROOT}/dist-iree"
    local wheel_platform="" toolchain_file="" iree_target_triple=""
    local -a cmake_args=()

    command -v cmake >/dev/null 2>&1 || { warn "cmake absent; skipping IREE riscv64 runtime wheel"; return 1; }
    command -v ninja >/dev/null 2>&1 || { warn "ninja absent; skipping IREE riscv64 runtime wheel"; return 1; }

    wheel_platform="$(wheel_platform_tag || true)"
    [ -n "${wheel_platform}" ] || { warn "no riscv64 wheel platform tag; skipping IREE"; return 1; }

    # ccache — the decisive lever for IREE build cost. IREE pins its OWN LLVM fork
    # (github.com/iree-org/llvm-project @ a bleeding-edge commit) and MLIR has no
    # stable API, so we CANNOT substitute ContainerHub's release-tag toolchain LLVM;
    # IREE must compile its bundled LLVM/MLIR (both host tools AND the riscv64 cross)
    # itself — ~1h. But the build tree lives on tmpfs (wiped each run) while
    # /var/cache/ccache is a PERSISTENT BuildKit cache mount (Dockerfile.media
    # app-wheelhouse RUN). Wiring the cmake compiler-launcher to ccache makes that
    # ~1h LLVM compile a ONE-TIME cost: every rerun cache-hits the objects. ccache
    # keys on compiler+flags, so the native-host build and the riscv64-cross build
    # keep separate entries and never collide. Guarded: plain rebuild if ccache is
    # absent. (Applies to the bundled llvm-project add_subdirectory too, which
    # inherits CMAKE_*_COMPILER_LAUNCHER; the small NATIVE tblgen sub-build may not.)
    local -a ccache_cmake_args=()
    if command -v ccache >/dev/null 2>&1; then
        export CCACHE_DIR="${CCACHE_DIR:-/var/cache/ccache}"
        # 64G, not 25G: IREE builds TWO full LLVM object sets (native host tools +
        # the target cross-LLVM), which together overflow a 25G cache and evict each
        # other (0714p thrashed — app-wheelhouse took 3.5h with a warm-but-too-small
        # cache). 64G comfortably holds both so reruns actually hit.
        # MEASURED 2026-08-26 (wave7e, riscv64): this used to read
        # `${CCACHE_MAXSIZE:-64G}` — but Dockerfile.base:87 already exports
        # CCACHE_MAXSIZE=30G, so `:-` NEVER applied the 64G this comment
        # promises, and the two LLVM object sets evicted each other exactly as
        # warned. Live evidence from the riscv64 lane: "Cacheable calls 42888
        # (95%), Hits 28319 (66%), cache size limit 30.0 GB" — every third
        # compile a MISS, which is why the bundled-LLVM build stayed a ~7-9h
        # cost per run instead of becoming one-time. Two fixes, both needed:
        # (1) override UNCONDITIONALLY (IREE_CCACHE_MAXSIZE is the escape
        # hatch, not the inherited base value), and (2) actually APPLY it —
        # the on-disk limit lives in the cache's own config and only changes
        # via `ccache -M`; exporting the env var alone leaves a 30G cache 30G.
        # 2026-08-26 follow-up: the HOST stage no longer builds LLVM at all
        # (IREE_BUILD_COMPILER=OFF, see Stage 1), so only ONE full LLVM object
        # set — the target cross-LLVM — plus the riscv64 torch aten objects now
        # compete for this cache. 64G is kept deliberately: it is now generous
        # rather than merely sufficient, which is what makes reruns hit.
        export CCACHE_MAXSIZE="${IREE_CCACHE_MAXSIZE:-64G}"
        export CCACHE_COMPRESS=1
        export CCACHE_SLOPPINESS="pch_defines,time_macros,include_file_mtime,include_file_ctime"
        mkdir -p "${CCACHE_DIR}" 2>/dev/null || true
        # Apply it to the on-disk cache (see (2) above) and report what the
        # cache ACTUALLY carries afterwards, so a future run's log proves the
        # limit rather than restating the intent.
        ccache -M "${CCACHE_MAXSIZE}" 2>/dev/null || warn "could not set ccache max size to ${CCACHE_MAXSIZE}"
        echo "[INFO] IREE ccache limit now: $(ccache -p 2>/dev/null | awk '/max_size/{print $2, $3}' || echo unknown)"
        # 2026-08-26 (ccache->sccache switch): use whichever cache is actually
        # usable. sccache takes its cap from SCCACHE_CACHE_SIZE, NOT from a
        # `-M` call -- so the IREE_CCACHE_MAXSIZE override above has to be
        # mirrored into the sccache env or IREE silently runs on the 30G
        # inherited from Dockerfile.base, which is the bug fefce7d just fixed
        # for ccache. Same fix, other tool.
        _iree_launcher="$(compiler_cache_launcher 2>/dev/null || echo ccache)"
        # DIAGNOSTIC (2026-08-26, temporary): the IREE target build is the one
        # place sccache died with "failed to spawn Command ... No such file or
        # directory", and eight isolated reproduction attempts all failed to
        # trigger it -- an out-of-band `nerdctl run` cannot recreate BuildKit's
        # cache mounts, so the environment is never faithful. Ask the tool
        # itself instead: SCCACHE_LOG makes the client print what it resolved
        # and why the spawn failed, in the real stage. IREE_SCCACHE_LOG can
        # raise it to debug; default is the quiet-but-useful level. Remove this
        # block once the spawn failure is understood.
        if [ "${_iree_launcher}" = "sccache" ]; then
            export SCCACHE_LOG="${IREE_SCCACHE_LOG:-sccache=info}"
            export SCCACHE_ERROR_LOG="${SCCACHE_ERROR_LOG:-/tmp/sccache-iree.log}"
        fi
        if [ "${_iree_launcher}" = "sccache" ]; then
            export SCCACHE_CACHE_SIZE="${IREE_CCACHE_MAXSIZE:-64G}"
            echo "[INFO] IREE sccache cap: SCCACHE_CACHE_SIZE=${SCCACHE_CACHE_SIZE}"
        fi
        ccache_cmake_args=("-DCMAKE_C_COMPILER_LAUNCHER=${_iree_launcher}" "-DCMAKE_CXX_COMPILER_LAUNCHER=${_iree_launcher}")
        echo "[INFO] IREE ccache ON: CCACHE_DIR=${CCACHE_DIR} MAXSIZE=${CCACHE_MAXSIZE} (LLVM rebuild is one-time; reruns cache-hit)"
    else
        warn "ccache not found — IREE bundled LLVM will rebuild from scratch every run (no cross-run cache)"
    fi

    # Clone at the pinned tag, then init ALL submodules recursively — including
    # third_party/torch-mlir + third_party/stablehlo — so the compiler ships the
    # full frontend set (stablehlo + torch input dialects), not just TOSA/linalg.
    # (--recursive also pulls torch-mlir's nested externals; --depth 1 keeps every
    # clone shallow. Disk is cheap; a complete tree is what we want here.)
    rm -rf "${src_dir}"
    if ! git clone --branch "${IREE_REF}" --depth 1 https://github.com/iree-org/iree.git "${src_dir}"; then
        warn "IREE clone ${IREE_REF} failed"; return 1
    fi
    if ! ( cd "${src_dir}" && git submodule update --init --recursive --depth 1 ); then
        warn "IREE submodule init failed"; return 1
    fi

    # Build VERSION-SPECIFIC Python bindings against the container's from-source
    # CPython (3.14), NOT IREE's default cp312-abi3 stable-ABI wheel. IREE otherwise
    # forces abi3 two ways, and BOTH must be defeated:
    #   1. CMakeLists.txt auto-enables IREE_ENABLE_PYTHON_STABLE_ABI on any CPython
    #      >=3.12 (so nanobind builds a limited-API .so) — countered by passing
    #      -DIREE_ENABLE_PYTHON_STABLE_ABI=OFF on the target configure (below).
    #   2. {runtime,compiler}/setup.py hard-code
    #      `_is_abi3_build = sys.version_info >= (3,12) and not Py_GIL_DISABLED`,
    #      whose bdist_wheel.get_tag() override then stamps the wheel "cp312"/"abi3"
    #      regardless of the built .so — with no env escape hatch. Patch it to False
    #      so the wheel takes its true tag (cp314-cp314) from the version-specific
    #      extension. `False and ...` short-circuits, parens stay balanced.
    # Result: iree_base_{compiler,runtime}-*-cp314-cp314-linux_riscv64.whl, bound to
    # exactly the interpreter we ship. (verify-wheels.sh then matches on cp314-.)
    local _sp
    for _sp in "${src_dir}/runtime/setup.py" "${src_dir}/compiler/setup.py"; do
        if [ -f "${_sp}" ]; then
            sed -i 's/sys\.version_info >= (3, 12) and not /False and /' "${_sp}"
        fi
    done

    if cross_build_is_active; then
        # ===== CROSS (arm64/riscv64 foreign target): two-stage host + target build =====
        # Stage 1 — NATIVE amd64 host build that populates IREE_HOST_BIN_DIR.
        # This function runs inside the riscv64 cross environment, where
        # CC/CXX/*FLAGS/CMAKE_TOOLCHAIN_FILE all point at the riscv64 cross toolchain
        # (set up for the torch build). The host tools MUST be native or they can't
        # execute on the build host to drive the target build — the first run
        # (2026-07-14) failed here precisely because the host cmake inherited the cross
        # CC/CXX. So strip the cross env for BOTH the configure and the build, and pin
        # the host compiler + both Python executables (FindPython/FindPython3 disagreed
        # on the first run).
        #
        # IREE_BUILD_COMPILER=OFF here (2026-08-26). It used to be ON, which made this
        # stage compile IREE's bundled llvm-project + MLIR + Clang + LLD + stablehlo +
        # torch-mlir natively — the multi-hour "IREE" tail that live sampling caught
        # compiling clang/Basic/Targets/ARM.cpp and TargetInfo.cpp. That was a leftover
        # from the era when the TARGET stage was runtime-only (BUILD_COMPILER=OFF), the
        # configuration of incident run iree-0714c: back then tools/CMakeLists.txt's
        #     if(IREE_HOST_BIN_DIR AND NOT IREE_BUILD_COMPILER)
        #       iree_import_binary(NAME iree-tblgen OPTIONAL) ... llvm-link ... clang
        # branch DID fire and the target really did need llvm-link/clang from the host.
        # The target stage below now sets -DIREE_BUILD_COMPILER=ON (it has to: we ship
        # the riscv64 iree_base_compiler wheel), so that branch is gated OFF and
        # IREE_CLANG_BINARY / IREE_LLVM_LINK_BINARY resolve to the target build's own
        # bundled-LLVM targets ($<TARGET_FILE:clang>, $<TARGET_FILE:llvm-link>,
        # build_tools/cmake/iree_llvm.cmake:83-85), never to IREE_HOST_BIN_DIR.
        #
        # With the target on COMPILER=ON, a full grep of IREE v3.11.0 shows exactly TWO
        # places that read a file out of ${IREE_HOST_BIN_DIR}:
        #   build_tools/cmake/iree_c_embed_data.cmake:97-98   iree-c-embed-data
        #   build_tools/cmake/flatbuffer_c_library.cmake:90-91 iree-flatcc-cli
        # Both are tiny host codegen utilities with ZERO LLVM dependency (a single .cc,
        # and the flatcc CLI); both are added unconditionally (CMakeLists.txt:1049 and
        # :1141, neither EXCLUDE_FROM_ALL) and both `install(... RUNTIME DESTINATION
        # bin)` regardless of IREE_BUILD_COMPILER. Upstream's own cross script
        # build_tools/cmake/build_riscv.sh likewise runs `--target install` with
        # -DIREE_BUILD_COMPILER=OFF, so the COMPILER=OFF install path is the supported
        # one. Everything else that touches IREE_HOST_BIN_DIR is either the gated
        # iree_import_binary branch above or tests/samples (BUILD_TESTS=OFF,
        # BUILD_SAMPLES=OFF).
        #
        # Guarded, not assumed: after the install we require both tools to exist.
        #
        # The ON arm is insurance against exactly ONE risk — our reading of IREE's
        # cmake being wrong about those two tools installing under COMPILER=OFF.
        # It is NOT a general retry, and the earlier claim here that it costs "one
        # cheap extra pass" was false: ON is the multi-hour bundled-LLVM build this
        # change exists to avoid. ON's build graph is a strict SUPERSET of OFF's,
        # so anything that breaks the OFF *build* (bad host toolchain, OOM at
        # MAX_JOBS, no disk) breaks ON too, hours later, and the image fails
        # anyway. Hence the three outcomes are treated differently:
        #   configure fails -> escalate (cheap, and could be OFF-path-specific)
        #   BUILD fails     -> fail fast (ON cannot succeed where OFF could not)
        #   tools missing   -> escalate (this is the case ON actually covers)
        local host_cc="" host_cxx=""
        for host_cc in /usr/bin/gcc /usr/bin/cc /usr/bin/clang; do [ -x "${host_cc}" ] && break; done
        for host_cxx in /usr/bin/g++ /usr/bin/c++ /usr/bin/clang++; do [ -x "${host_cxx}" ] && break; done

        # Tools the target stage needs from IREE_HOST_BIN_DIR.
        #
        # iree-tblgen IS REQUIRED HERE (regression fix 2026-08-27). The original
        # list held only the two LLVM-free codegen helpers, on the reading that
        # tools/CMakeLists.txt gates host-tool imports behind
        # `IREE_HOST_BIN_DIR AND NOT IREE_BUILD_COMPILER` and our target sets
        # COMPILER=ON, so nothing else is imported. That is true -- and it is
        # exactly the problem: nothing being imported means the TARGET build
        # builds its own iree-tblgen, FOR THE TARGET ARCH, and then tries to RUN
        # it during the build. On a cross lane that is an arm64 binary on an
        # amd64 host:
        #     /…/iree-build-target/tools/iree-tblgen: Exec format error
        #     FAILED: [code=126] …/VMOpEncoder.cpp.inc
        # It cannot show up on amd64, where host and target are the same arch --
        # which is why the amd64 media stage passed cleanly and arm64 died.
        #
        # Listing it here makes the OFF pass fail its own check and escalate to
        # COMPILER=ON, which is precisely what the fallback loop exists for. The
        # cost is that CROSS lanes go back to building the bundled LLVM in the
        # host stage; the native lane keeps the win. A cheap COMPILER=OFF probe
        # first is still worth it: if upstream ever installs tblgen without the
        # compiler, the saving returns automatically and nothing needs editing.
        local -a host_required_tools=(iree-c-embed-data iree-flatcc-cli iree-tblgen)
        local host_stage_ok=0 host_compiler_mode="" host_tool="" host_tools_missing=""
        for host_compiler_mode in OFF ON; do
            rm -rf "${host_build}" "${host_install}"
            log "IREE host stage: configuring with IREE_BUILD_COMPILER=${host_compiler_mode}"
            if ! env -u CC -u CXX -u CPP -u CFLAGS -u CXXFLAGS -u CPPFLAGS -u LDFLAGS \
                     -u AR -u RANLIB -u CMAKE_TOOLCHAIN_FILE -u CMAKE_ARGS \
                    cmake -G Ninja -S "${src_dir}" -B "${host_build}" \
                    "${ccache_cmake_args[@]}" \
                    -DCMAKE_BUILD_TYPE=Release \
                    -DCMAKE_C_COMPILER="${host_cc}" \
                    -DCMAKE_CXX_COMPILER="${host_cxx}" \
                    -DIREE_BUILD_COMPILER="${host_compiler_mode}" \
                    -DIREE_BUILD_PYTHON_BINDINGS=OFF \
                    -DIREE_BUILD_SAMPLES=OFF \
                    -DIREE_BUILD_TESTS=OFF \
                    -DIREE_ENABLE_WERROR_FLAG=OFF \
                    -DCMAKE_INSTALL_PREFIX="${host_install}" \
                    -DPython_EXECUTABLE="${BUILD_PYTHON}" \
                    -DPython3_EXECUTABLE="${BUILD_PYTHON}"; then
                warn "IREE host configure (IREE_BUILD_COMPILER=${host_compiler_mode}) failed"
                continue
            fi
            # Capture build output to a log and echo its tail on failure. BuildKit
            # collapses the tens-of-thousands of ninja progress lines, so a bare failure
            # surfaces NO error (the silent-fast-fail gotcha, iree-0714f) — the tail dump
            # is the only way to see why the cross build actually died.
            if ! env -u CC -u CXX -u CPP -u CFLAGS -u CXXFLAGS -u CPPFLAGS -u LDFLAGS \
                     -u AR -u RANLIB -u CMAKE_TOOLCHAIN_FILE -u CMAKE_ARGS \
                    cmake --build "${host_build}" --target install -- -j"${MAX_JOBS}" \
                    > "${host_build}.log" 2>&1; then
                warn "IREE host build (IREE_BUILD_COMPILER=${host_compiler_mode}) failed"
                echo "----- IREE host build: last 80 log lines -----"
                tail -n 80 "${host_build}.log" 2>/dev/null
                echo "----- end IREE host build log -----"
                # Deliberately NOT `continue`: escalating a failed BUILD to ON
                # compiles bundled llvm-project/MLIR/Clang for hours and then
                # fails at the same wall, because ON builds everything OFF does
                # and more. Fail now, while the log tail above is the answer.
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

        # Stage 2 — cross the runtime (+ Python bindings) against the host tools.
        # IREE_ENABLE_WERROR_FLAG=OFF is REQUIRED here (iree-0714g): the nanobind Python
        # bindings pull in the cross Python 3.14 pyconfig.h, which defines _POSIX_C_SOURCE/
        # _XOPEN_SOURCE to OLDER values than resolute's glibc features.h (already included
        # via <optional>/<cstdint> in binding.h) — a benign macro redefinition that IREE's
        # default -Werror turns fatal. Dropping -Werror keeps it a warning and lets the
        # riscv64 iree_base_runtime wheel build. (Python.h-include-order can't be fixed from
        # our side without patching IREE headers.)
        # IREE_OUTPUT_FORMAT_C=OFF is REQUIRED here (iree-0714m). It is a
        # cmake_dependent_option that defaults ON whenever IREE_BUILD_COMPILER=ON
        # (CMakeLists.txt:517), enabling the EmitC "vm-c" output format. That pulls in
        # runtime/src/iree/vm/test/emitc/CMakeLists.txt, which is gated on
        # IREE_OUTPUT_FORMAT_C (NOT IREE_BUILD_TESTS — so TESTS=OFF does not stop it) and
        # generates VM headers by RUNNING iree-compile at build time. With COMPILER=ON on
        # the TARGET, the tool name 'iree-compile' resolves to the just-built riscv64
        # binary, not the host tool in IREE_HOST_BIN_DIR, so the codegen tries to execute
        # a riscv64 iree-compile on the amd64 host and dies with
        # 'libIREECompiler.so: cannot open shared object file' (code 127). Turning the
        # format OFF removes the only build-time consumer of the target compiler; the
        # riscv64 libIREECompiler.so + iree-compile still build (so the iree_base_compiler
        # wheel is intact), it just loses the niche vm-c/C-source output — standard .vmfb
        # bytecode compilation, which the app's check_iree uses, is unaffected.
        # CROSS TARGET IS RUNTIME-ONLY (2026-08-27, restored). IREE_BUILD_COMPILER
        # is OFF here, and that is not a preference -- it is the only configuration
        # upstream supports for a cross target.
        #
        # IREE imports host tools only under
        #     if(IREE_HOST_BIN_DIR AND NOT IREE_BUILD_COMPILER)  (tools/CMakeLists.txt)
        # so with COMPILER=ON the target IGNORES IREE_HOST_BIN_DIR entirely, builds
        # its own iree-tblgen FOR THE TARGET ARCH, and then runs it during the build:
        #     /.../iree-build-target/tools/iree-tblgen: Exec format error
        #     FAILED: [code=126] .../Dialect/VM/IR/VMOpEncoder.cpp.inc
        # Proven NOT to be a host-side problem: the host stage completed with
        # COMPILER=ON and reported "tools present: iree-c-embed-data iree-flatcc-cli
        # iree-tblgen", and the target still used its own. Upstream's build_riscv.sh
        # sets the target to COMPILER=OFF for exactly this reason. The same class is
        # already documented below for iree-compile (IREE_OUTPUT_FORMAT_C=OFF).
        #
        # WHAT THIS COSTS, plainly: arm64 and riscv64 ship the IREE RUNTIME wheel but
        # NOT iree_base_compiler. Commit 9b238e7 wanted both on cross; it set the flag
        # without providing a native tblgen, and that configuration cannot build.
        # amd64 is NATIVE, never enters this branch, and keeps both wheels.
        # IREE_CROSS_BUILD_COMPILER=ON re-tries it once IREE supports the combination.
        toolchain_file="$(write_cross_cmake_toolchain_file || true)"
        [ -n "${toolchain_file}" ] || { warn "no cross toolchain file for IREE; skipping"; return 1; }
        append_common_cross_cmake_args cmake_args

        # The cross-built iree-compile bakes in its DEFAULT codegen target triple at
        # compile time via LLVM_HOST_TRIPLE (llvm::sys::getProcessTriple(), which IREE's
        # llvm-cpu backend uses when --iree-llvmcpu-target-triple is unset). Bundled
        # LLVM's CMake auto-detects that triple from the BUILD host during a cross-build,
        # so without this override an arm64/riscv64 iree-compile defaults to the x86_64
        # build host and emits `embedded-elf-x86_64` — iree-run-module on the target then
        # fails "HAL device not found" (INCOMPATIBLE). Pin both triples to the actual
        # target so the shipped compiler defaults to the arch it runs on. (iree-0714t:
        # arm64 native iree-compile smoke failed exactly this way.)
        iree_target_triple="$(cross_target_triplet 2>/dev/null || true)"
        if [ -n "${iree_target_triple}" ]; then
            cmake_args+=(
                "-DLLVM_HOST_TRIPLE=${iree_target_triple}"
                "-DLLVM_DEFAULT_TARGET_TRIPLE=${iree_target_triple}"
            )
        fi

        # Build IREE's nanobind Python extensions with the TARGET Python's SOABI so the
        # compiled module is named _runtime.cpython-314-<target>-linux-gnu.so, not the
        # x86_64 build host's suffix. Without this, FindPython/nanobind introspect the
        # host BUILD_PYTHON and stamp cpython-314-x86_64-linux-gnu.so, which the target
        # (aarch64) Python cannot import — "cannot import name '_runtime' from
        # 'iree._runtime_libs'" (iree-0714t). _PYTHON_SYSCONFIGDATA_NAME redirects the
        # host interpreter's sysconfig to the target's EXT_SUFFIX, the same mechanism the
        # torch/vision cross builds use (resolve_target_python_sysconfig_export). Applied
        # only HERE — after the Stage-1 host tools build (bindings OFF) — so host binaries
        # keep the x86_64 config; it stays in effect for the Stage-2 build + wheel pack.
        local iree_sysconfig_export=""
        iree_sysconfig_export="$(resolve_target_python_sysconfig_export)"
        if [ -n "${iree_sysconfig_export}" ]; then eval "${iree_sysconfig_export}"; fi

        # The bundled LLVM spawns a NATIVE sub-build (llvm-project/NATIVE) for the
        # tblgen family, and LLVM's CrossCompile.cmake DEFAULTS that sub-build's
        # compilers to the outer (CROSS) CMAKE_C(XX)_COMPILER — so llvm-min-tblgen
        # came out arm64 and died "Exec format error" on the amd64 build host
        # (media-arm64, 2026-08-08; riscv64 only ever survived this because host
        # qemu binfmt silently emulated the wrong-arch tblgen — slowly). Pin the
        # NATIVE sub-build to the true host compilers, with ccache so its objects
        # cache like everything else. (';' is CMake's list separator — the whole
        # value is ONE shell word.)
        local native_flags="-DCMAKE_C_COMPILER=${host_cc};-DCMAKE_CXX_COMPILER=${host_cxx}"
        if [ "${#ccache_cmake_args[@]}" -gt 0 ]; then
            native_flags="${native_flags};-DCMAKE_C_COMPILER_LAUNCHER=${_iree_launcher:-ccache};-DCMAKE_CXX_COMPILER_LAUNCHER=${_iree_launcher:-ccache}"
        fi

        rm -rf "${target_build}"
        if ! cmake -G Ninja -S "${src_dir}" -B "${target_build}" \
                -DCMAKE_TOOLCHAIN_FILE="${toolchain_file}" \
                "${cmake_args[@]}" \
                "${ccache_cmake_args[@]}" \
                -DCROSS_TOOLCHAIN_FLAGS_NATIVE="${native_flags}" \
                -DIREE_HOST_BIN_DIR="${host_install}/bin" \
                -DIREE_BUILD_COMPILER="${IREE_CROSS_BUILD_COMPILER:-OFF}" \
                -DIREE_BUILD_PYTHON_BINDINGS=ON \
                -DIREE_ENABLE_PYTHON_STABLE_ABI=OFF \
                -DIREE_BUILD_SAMPLES=OFF \
                -DIREE_BUILD_TESTS=OFF \
                -DIREE_OUTPUT_FORMAT_C=OFF \
                -DIREE_ENABLE_WERROR_FLAG=OFF \
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

    else
        # ===== amd64 NATIVE: single-stage build =====
        # build arch == target arch, so no host/target split, no toolchain file,
        # no IREE_HOST_BIN_DIR, no qemu emulator. One cmake configure builds LLVM
        # + iree-compile + the runtime + the cp314 Python bindings for the host.
        # IREE_ENABLE_PYTHON_STABLE_ABI=OFF (plus the setup.py abi3 sed patch above)
        # forces version-specific cp314-cp314-linux_x86_64 wheels instead of IREE's
        # default cp312-abi3. OUTPUT_FORMAT_C=OFF is harmless natively (iree-compile
        # runs on the host) — kept OFF for parity + speed. Native build => the CPU
        # host-detection that fails the riscv64 iree-compile under QEMU is a non-issue.
        local native_cc="" native_cxx=""
        for native_cc in /usr/bin/gcc /usr/bin/cc /usr/bin/clang; do [ -x "${native_cc}" ] && break; done
        for native_cxx in /usr/bin/g++ /usr/bin/c++ /usr/bin/clang++; do [ -x "${native_cxx}" ] && break; done
        rm -rf "${target_build}"
        if ! cmake -G Ninja -S "${src_dir}" -B "${target_build}" \
                "${ccache_cmake_args[@]}" \
                -DCMAKE_BUILD_TYPE=Release \
                -DCMAKE_C_COMPILER="${native_cc}" \
                -DCMAKE_CXX_COMPILER="${native_cxx}" \
                -DIREE_BUILD_COMPILER=ON \
                -DIREE_BUILD_PYTHON_BINDINGS=ON \
                -DIREE_ENABLE_PYTHON_STABLE_ABI=OFF \
                -DIREE_BUILD_SAMPLES=OFF \
                -DIREE_BUILD_TESTS=OFF \
                -DIREE_OUTPUT_FORMAT_C=OFF \
                -DIREE_ENABLE_WERROR_FLAG=OFF \
                -DIREE_HAL_DRIVER_LOCAL_SYNC=ON \
                -DIREE_HAL_DRIVER_LOCAL_TASK=ON \
                -DPython_EXECUTABLE="${BUILD_PYTHON}" \
                -DPython3_EXECUTABLE="${BUILD_PYTHON}" > "${target_build}.cfg.log" 2>&1; then
            warn "IREE native configure failed"
            echo "----- IREE native configure: last 80 log lines -----"
            tail -n 80 "${target_build}.cfg.log" 2>/dev/null
            echo "----- end IREE native configure log -----"
            return 1
        fi
        if ! cmake --build "${target_build}" -- -j"${MAX_JOBS}" > "${target_build}.log" 2>&1; then
            warn "IREE native build failed"
            echo "----- IREE native build: last 80 log lines -----"
            tail -n 80 "${target_build}.log" 2>/dev/null
            echo "----- end IREE native build log -----"
            return 1
        fi
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
        retag_directory_wheels "${dist_dir}" "${_pkg}" "${wheel_platform}" "${BUILD_PYTHON}"
    done

    shopt -s nullglob
    local -a wheels=("${dist_dir}"/iree_base_compiler-*.whl "${dist_dir}"/iree_base_runtime-*.whl "${dist_dir}"/iree-*.whl)
    shopt -u nullglob
    if [ "${#wheels[@]}" -lt 2 ]; then
        warn "IREE build did not produce BOTH compiler+runtime wheels (got ${#wheels[@]})"; return 1
    fi
    cp -a "${wheels[@]}" "${APP_WHEELHOUSE_DIR}/"
    log "Built IREE wheels: $(cd "${dist_dir}" && echo iree_base_*-*.whl)"
}

main() {
    prepare_workspace
    if ! prepare_build_environment; then
        return 0
    fi

    # torch/torchvision are cross-built ONLY for riscv64 (no upstream riscv64
    # wheels exist). On amd64/arm64 torch/vision come from PyPI; only IREE is
    # source-built there (PyPI ships cp312-abi3, but we need version-specific
    # cp314). They are best-effort even on riscv64 (a native torch stage is the
    # fallback), so a failure must NOT short-circuit main() before the REQUIRED
    # build_iree_wheels runs (that fail-open skipped IREE when a transient
    # ports.ubuntu.com outage broke torch in iree-0714k) — warn and continue.
    if [ "$(cross_target_arch 2>/dev/null || echo)" = "riscv64" ]; then
        if ! build_torch_wheel; then
            warn "riscv64 torch cross-wheel failed — native torch stage is the fallback; continuing to IREE"
        fi
        if ! build_torchvision_wheel; then
            warn "Continuing without a prebuilt riscv64 torchvision wheel"
        fi
    fi

    # IREE is REQUIRED on ALL arches (amd64/arm64/riscv64): we ship version-specific
    # cp314 wheels built from source, never the PyPI cp312-abi3 build. A failed build
    # must FAIL THE IMAGE (fail early) so it gets fixed, never silently ship an image
    # missing iree. The failure paths above dump the real cmake/ninja tail before
    # returning non-zero. Bypass only with an explicit ALLOW_IREE_BUILD_FAIL=1 for a
    # deliberate IREE-less debugging image.
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
