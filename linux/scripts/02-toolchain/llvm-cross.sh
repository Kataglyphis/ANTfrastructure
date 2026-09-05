#!/usr/bin/env bash
# llvm-cross.sh — LLVM cross-compilation build functions.
# Sourced by llvm.sh; not executed standalone.
[ -n "${_LLVM_CROSS_SH_LOADED:-}" ] && return 0
_LLVM_CROSS_SH_LOADED=1
set -euo pipefail
# CCACHE-CONTENT (2026-08-19): survive compiler rebuilds (see build-gcc.sh note)
export CCACHE_COMPILERCHECK=content

install_cross_llvm_target_packages() {
  local target_label="$1"

  [ "${target_label}" = "amd64" ] && return 0
  command -v install_target_packages >/dev/null 2>&1 || die "install_target_packages is unavailable; cross-env.sh must be sourced before llvm.sh"

  (
    export BUILD_MODE=cross
    export TARGETARCH="${target_label}"
    export TARGET_ARCH="${target_label}"
    install_target_packages \
      zlib1g-dev \
      libzstd-dev \
      libxml2-dev
  )
}

_llvm_cross_resolve_dirs() {
  local -n _r="$1"
  local mode="$2" target_label="$3" triplet

  [ -n "${target_label}" ] || die "_build_llvm_cross_core: target architecture required"
  target_label="$(arch_normalize "${target_label}")"
  [ "${target_label}" = "amd64" ] && { log "Skipping cross LLVM build for amd64 (host already serves)"; return 1; }

  triplet="$(arch_deb_multiarch_triplet_for "${target_label}")" || die "No triplet for ${target_label}"

  _r[mode]="${mode}"
  _r[target_label]="${target_label}"
  _r[triplet]="${triplet}"

  # TG3 — ONE superset build per arch, installed to both prefixes (relocatable);
  # clang_prefix is per-arch or the shared compiler stage clobbers /opt/llvm-target.
  _r[llvm_prefix]="$(llvm_cross_install_prefix "${target_label}")" || die "Unable to resolve LLVM cross install prefix for ${target_label}"
  _r[clang_prefix]="/opt/llvm-target-${target_label}"
  # Configure with the clang prefix; /opt/llvm-cross is a second relocated install.
  _r[prefix]="${_r[clang_prefix]}"
  _r[release]="$(llvm_release_version)"
  _r[tag]="$(llvm_git_tag)"
  # Both entry points describe the SAME unified build, so they name the same tree.
  _r[build_dir_suffix]="${triplet}"
  _r[wrapper_dir_suffix]="${triplet}-tool-bin"

  _r[backend]="$(llvm_cross_backend "${target_label}")" || die "No LLVM backend for ${target_label}"
  _r[source_root]="${LLVM_CROSS_SOURCE_ROOT:-/var/cache/llvm-src}"
  _r[build_root]="${LLVM_CROSS_BUILD_ROOT:-/var/tmp/llvm-cross-build}"
  _r[source_dir]="${_r[source_root]}/llvm-project-${_r[release]}"
  _r[build_dir]="${_r[build_root]}/${_r[build_dir_suffix]}"
  _r[wrapper_dir]="${_r[build_root]}/${_r[wrapper_dir_suffix]}"
  _r[jobs]="$(compute_jobs_with_mem_cap "${LLVM_CROSS_JOBS:-}" "${LLVM_CROSS_MB_PER_JOB:-3500}")"
  return 0
}

_llvm_cross_early_return() {
  local -n _r="$1"
  local target_label="${_r[target_label]}" release="${_r[release]}"
  local llvm_prefix="${_r[llvm_prefix]}" clang_prefix="${_r[clang_prefix]}"
  local installed_version llvm_ok=0 clang_ok=0

  # The unified build produces BOTH trees; reuse only when both are current, so a
  # partial state forces a full rebuild.
  if llvm_cross_install_looks_complete "${target_label}"; then
    llvm_ok=1
  fi
  if [ -x "${clang_prefix}/bin/clang" ]; then
    installed_version="$("${clang_prefix}/bin/clang" --version 2>/dev/null | awk 'NR==1{print $NF}' || true)"
    [ "${installed_version}" = "${release}" ] && clang_ok=1
  fi

  if [ "${llvm_ok}" -eq 1 ] && [ "${clang_ok}" -eq 1 ]; then
    validate_cross_llvm_cmake_package "${target_label}"
    log "Reusing unified target LLVM/clang install for ${target_label} (${llvm_prefix} + ${clang_prefix})"
    return 1
  fi

  # Discard any partial trees so the rebuild starts from a clean slate.
  if [ "${llvm_ok}" -ne 1 ] && [ -d "${llvm_prefix}" ]; then
    log "Discarding incomplete target LLVM install for ${target_label}: ${llvm_prefix}"
    rm -rf "${llvm_prefix}"
  fi
  if [ "${clang_ok}" -ne 1 ] && [ -d "${clang_prefix}" ]; then
    log "Discarding incomplete target clang install for ${target_label}: ${clang_prefix}"
    rm -rf "${clang_prefix}"
  fi
  return 0
}

_llvm_cross_retrieve_source() {
  local -n _r="$1"
  local source_root="${_r[source_root]}" build_root="${_r[build_root]}" source_dir="${_r[source_dir]}" tag="${_r[tag]}" mode="${_r[mode]}" target_label="${_r[target_label]}"

  mkdir -p "${source_root}" "${build_root}"
  # TS4: a truncated clone leaves a .git a bare test accepts forever — require a
  # resolvable HEAD + worktree; evict superseded generations (~2 GB per release).
  local _src_ok=0 _old_src
  if [ -d "${source_dir}/.git" ] \
     && git -C "${source_dir}" rev-parse -q --verify HEAD >/dev/null 2>&1 \
     && [ -f "${source_dir}/llvm/CMakeLists.txt" ]; then
    _src_ok=1
  fi
  if [ "${_src_ok}" != "1" ]; then
    for _old_src in "${source_root}"/llvm-project-*; do
      [ -d "${_old_src}" ] && [ "${_old_src}" != "${source_dir}" ] || continue
      log "Evicting stale llvm checkout $(basename "${_old_src}") (superseded by ${tag})"
      rm -rf "${_old_src}"
    done
    rm -rf "${source_dir}"
    log "Cloning llvm-project ${tag} for ${mode} ${target_label}"
    git clone --depth 1 --branch "${tag}" https://github.com/llvm/llvm-project.git "${source_dir}"
  fi
}

_llvm_cross_pre_build_hooks() {
  local -n _r="$1"
  local target_label="${_r[target_label]}" build_root="${_r[build_root]}"

  # The unified build always needs the host-native helper-tool machinery (host gcc
  # wrappers that compile the NATIVE tablegen/helper sub-build).
  _r[native_wrapper_dir]="${build_root}/${_r[triplet]}-native-tool-bin"
  _r[build_cc_real]="$(resolve_build_gcc_tool gcc 2>/dev/null || command -v gcc 2>/dev/null || true)"
  _r[build_cxx_real]="$(resolve_build_gcc_tool g++ 2>/dev/null || command -v g++ 2>/dev/null || true)"
  [ -n "${_r[build_cc_real]}" ] || die "Host C compiler not found for LLVM native helper tools"
  [ -n "${_r[build_cxx_real]}" ] || die "Host C++ compiler not found for LLVM native helper tools"
  _r[host_path]="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
}

# Empty out-array when the target declares no runtime library path, or none of
# its directories exist.
_llvm_cross_linker_flag_args() {
  local -n _lf_args="$1"
  local target_label="$2"
  local target_runtime_link_path linker_flags_init="" link_dir

  _lf_args=()
  target_runtime_link_path="$(llvm_cross_target_runtime_library_path "${target_label}" || true)"
  if [ -n "${target_runtime_link_path}" ]; then
    # IFS-scoped split (see vulkan.sh): survives strict-IFS callers.
    local -a _lc_link_dirs=()
    IFS=':' read -r -a _lc_link_dirs <<< "${target_runtime_link_path}"
    for link_dir in "${_lc_link_dirs[@]}"; do
      [ -d "${link_dir}" ] || continue
      linker_flags_init="${linker_flags_init:+${linker_flags_init} }-Wl,-rpath-link,${link_dir}"
    done
  fi
  [ -n "${linker_flags_init}" ] || return 0

  _lf_args=(
    "-DCMAKE_EXE_LINKER_FLAGS_INIT=${linker_flags_init}"
    "-DCMAKE_SHARED_LINKER_FLAGS_INIT=${linker_flags_init}"
    "-DCMAKE_MODULE_LINKER_FLAGS_INIT=${linker_flags_init}"
  )
}

# Launcher args for the OUTER (cross) build. The caller resolves the launcher
# string because the NESTED native sub-build needs the same value.
_llvm_cross_launcher_cmake_args() {
  local -n _cl_args="$1"
  local launcher="$2"

  _cl_args=()
  [ -n "${launcher}" ] || return 0

  _cl_args=(
    "-DCMAKE_C_COMPILER_LAUNCHER=${launcher}"
    "-DCMAKE_CXX_COMPILER_LAUNCHER=${launcher}"
  )
}

# Do NOT reintroduce the core-only shape (empty projects / no native tablegen
# wiring): that combination leaves libLLVMSupportLSP.a unbuilt.
_llvm_cross_superset_cmake_args() {
  local -n _ss_args="$1"
  local build_cc="$2" build_cxx="$3" launcher="$4" native_tool_dir="$5"

  _ss_args=(
    -DLLVM_BINUTILS_INCDIR=/usr/include
    -DLLVM_ENABLE_PROJECTS="clang;clang-tools-extra;lld"
    -DLLVM_ENABLE_RUNTIMES="compiler-rt"
    -DCOMPILER_RT_BUILD_SANITIZERS=ON
    -DCOMPILER_RT_BUILD_BUILTINS=ON
    -DCOMPILER_RT_BUILD_XRAY=OFF
    -DCOMPILER_RT_BUILD_LIBFUZZER=OFF
    -DCOMPILER_RT_BUILD_PROFILE=ON
    -DCOMPILER_RT_BUILD_MEMPROF=OFF
    -DCOMPILER_RT_BUILD_ORC=OFF
    -DCOMPILER_RT_BUILD_GWP_ASAN=OFF
    -DCOMPILER_RT_BUILD_CTX_PROFILE=OFF
    -DSANITIZER_CXX_ABI=libstdc++
    -DLLVM_USE_HOST_TOOLS=ON
    # The NESTED native tablegen build compiled launcher-less until this was
    # added (~2h cold); empty when no compiler cache is usable.
    "-DCROSS_TOOLCHAIN_FLAGS_NATIVE=-DCMAKE_C_COMPILER=${build_cc};-DCMAKE_CXX_COMPILER=${build_cxx};-DCMAKE_ASM_COMPILER=${build_cc}${launcher:+;-DCMAKE_C_COMPILER_LAUNCHER=${launcher};-DCMAKE_CXX_COMPILER_LAUNCHER=${launcher}}"
    -DCLANG_TABLEGEN="${native_tool_dir}/clang-tblgen"
  )
}

# Callable ONLY from inside _llvm_cross_setup_and_build's subshell: CC/AR/
# CROSS_TARGET_*/CMAKE_SYSROOT come from the env setup_linux_cross_env exported.
_llvm_cross_cmake_configure() {
  local -n _cfg="$1"
  local clang_triple="$2"
  local -n _cfg_launcher_args="$3"
  local -n _cfg_linker_args="$4"
  local -n _cfg_superset_args="$5"
  local source_dir="${_cfg[source_dir]}" build_dir="${_cfg[build_dir]}" prefix="${_cfg[prefix]}"
  local wrapper_dir="${_cfg[wrapper_dir]}" backend="${_cfg[backend]}"
  local native_tool_dir="${_cfg[native_tool_dir]}"

  cmake -G Ninja \
    "${_cfg_launcher_args[@]}" \
    -S "${source_dir}/llvm" \
    -B "${build_dir}" \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_SYSTEM_NAME=Linux \
    -DCMAKE_SYSTEM_PROCESSOR="${CROSS_TARGET_PROCESSOR}" \
    -DCMAKE_SYSROOT="${CMAKE_SYSROOT:-/}" \
    -DCMAKE_C_COMPILER="${CC}" \
    -DCMAKE_CXX_COMPILER="${CXX}" \
    -DCMAKE_ASM_COMPILER="${CC}" \
    -DCMAKE_AR="${AR}" \
    -DCMAKE_RANLIB="${RANLIB}" \
    -DCMAKE_NM="${NM}" \
    -DCMAKE_OBJCOPY="${OBJCOPY}" \
    -DCMAKE_STRIP="${STRIP}" \
    "${_cfg_linker_args[@]}" \
    -DCMAKE_C_FLAGS_INIT="-B${wrapper_dir}" \
    -DCMAKE_CXX_FLAGS_INIT="-B${wrapper_dir}" \
    -DCMAKE_ASM_FLAGS_INIT="-B${wrapper_dir}" \
    -DCMAKE_LIBRARY_ARCHITECTURE="${CROSS_TARGET_TRIPLET}" \
    -DCMAKE_FIND_ROOT_PATH_MODE_PROGRAM=NEVER \
    -DCMAKE_FIND_ROOT_PATH_MODE_LIBRARY=ONLY \
    -DCMAKE_FIND_ROOT_PATH_MODE_INCLUDE=ONLY \
    -DCMAKE_FIND_ROOT_PATH_MODE_PACKAGE=ONLY \
    -DCMAKE_INSTALL_PREFIX="${prefix}" \
    -DLLVM_HOST_TRIPLE="${clang_triple}" \
    -DLLVM_DEFAULT_TARGET_TRIPLE="${clang_triple}" \
    -DLLVM_TARGETS_TO_BUILD="${backend}" \
    "${_cfg_superset_args[@]}" \
    -DLLVM_BUILD_LLVM_DYLIB=ON \
    -DLLVM_LINK_LLVM_DYLIB=ON \
    -DLLVM_INCLUDE_TOOLS=ON \
    -DLLVM_BUILD_TOOLS=ON \
    -DLLVM_TOOL_LLVM_SHLIB_BUILD=ON \
    -DLLVM_INCLUDE_UTILS=OFF \
    -DLLVM_BUILD_UTILS=OFF \
    -DLLVM_INCLUDE_TESTS=OFF \
    -DLLVM_INCLUDE_BENCHMARKS=OFF \
    -DLLVM_INCLUDE_EXAMPLES=OFF \
    -DLLVM_INCLUDE_DOCS=OFF \
    -DLLVM_ENABLE_TERMINFO=OFF \
    -DLLVM_ENABLE_LIBEDIT=OFF \
    -DLLVM_ENABLE_ASSERTIONS=OFF \
    -DLLVM_ENABLE_WARNINGS=OFF \
    -DLLVM_NATIVE_TOOL_DIR="${native_tool_dir}" \
    -DLLVM_TABLEGEN="${native_tool_dir}/llvm-tblgen"
}

_llvm_cross_build_and_install() {
  local -n _bi="$1"
  local build_dir="${_bi[build_dir]}" jobs="${_bi[jobs]}" llvm_prefix="${_bi[llvm_prefix]}"

  cmake --build "${build_dir}" --parallel "${jobs}"

  # TVM consumes llvm-config out of /opt/llvm-cross; the default "all" target
  # does not guarantee it under cross, so build it explicitly.
  cmake --build "${build_dir}" --parallel "${jobs}" --target llvm-config

  # Install the ONE tree to BOTH prefixes. --strip uses the cross CMAKE_STRIP
  # (host strip no-ops on foreign ELFs); an unstripped tree is multiple GB.
  cmake --install "${build_dir}" --strip
  cmake --install "${build_dir}" --strip --prefix "${llvm_prefix}"
}

_llvm_cross_setup_and_build() {
  local state_name="$1"
  local -n _r="$1"
  local target_label="${_r[target_label]}" triplet="${_r[triplet]}"
  local wrapper_dir="${_r[wrapper_dir]}"
  local native_tool_dir="${_r[native_tool_dir]}"
  local native_wrapper_dir="${_r[native_wrapper_dir]:-}"
  local build_cc build_cxx build_cc_real="${_r[build_cc_real]:-}" build_cxx_real="${_r[build_cxx_real]:-}" host_path="${_r[host_path]:-}"
  local clang_triple

  (
    export BUILD_MODE=cross
    export TARGETARCH="${target_label}"
    export TARGET_ARCH="${target_label}"
    export CCACHE_DIR="/var/cache/ccache"
    export SCCACHE_DIR="/var/cache/sccache"
    setup_linux_cross_env
    llvm_cross_populate_tool_wrapper_dir "${wrapper_dir}"

    # Host gcc wrappers + CLANG_TABLEGEN for the NATIVE tablegen/helper sub-build;
    # without them the native support lib is silently left unbuilt.
    build_cc="$(make_host_compiler_wrapper "${native_wrapper_dir}/host-gcc" "${build_cc_real}" "${host_path}")"
    build_cxx="$(make_host_compiler_wrapper "${native_wrapper_dir}/host-g++" "${build_cxx_real}" "${host_path}")"

    local -a linker_flag_args=()
    _llvm_cross_linker_flag_args linker_flag_args "${target_label}"

    clang_triple="${triplet}"
    case "${target_label}" in
      arm64) clang_triple="aarch64-unknown-linux-gnu" ;;
      riscv64) clang_triple="riscv64-unknown-linux-gnu" ;;
    esac
    export PATH="${wrapper_dir}:${PATH}"

    # preference INVERTED: sccache first, ccache only as the fallback. See
    # docs/build-cache-tiers.md.
    local -a extra_cmake_args=()
    local _xc_launcher
    compiler_cache_launcher_env 2>/dev/null || true
    _xc_launcher="$(compiler_cache_launcher || true)"
    _llvm_cross_launcher_cmake_args extra_cmake_args "${_xc_launcher}"

    local -a superset_args=()
    _llvm_cross_superset_cmake_args superset_args \
      "${build_cc}" "${build_cxx}" "${_xc_launcher}" "${native_tool_dir}"

    _llvm_cross_cmake_configure "${state_name}" "${clang_triple}" \
      extra_cmake_args linker_flag_args superset_args

    _llvm_cross_build_and_install "${state_name}"
  )
}

_llvm_cross_post_build_hooks() {
  local -n _r="$1"
  local target_label="${_r[target_label]}" clang_prefix="${_r[clang_prefix]}" release="${_r[release]}"
  local build_dir="${_r[build_dir]}" cmake_dir

  # Validate both trees. The cross llvm-config is copied from the build tree
  # because the installed one may be stripped.
  install_cross_llvm_config_binary "${target_label}" "${build_dir}"
  cmake_dir="$(llvm_cross_cmake_dir "${target_label}")" || die "Target LLVM CMake package missing after install for ${target_label}"
  validate_cross_llvm_cmake_package "${target_label}"
  log "Installed target LLVM package for ${target_label}: ${cmake_dir}"

  # 2. /opt/llvm-target-<arch> — the native target clang.
  if [ -x "${clang_prefix}/bin/clang" ]; then
    log "Target clang ${release} for ${target_label} installed at ${clang_prefix}"
  else
    die "Target clang build for ${target_label} completed but ${clang_prefix}/bin/clang not found"
  fi
}

_build_llvm_cross_core() {
  local mode="$1"
  local target_label="$2"
  # MUST NOT be named `_r`/`_cfg`/`_bi`, nor collide with the *_args out-arrays:
  # a self-referential `local -n` is a circular ref. docs/refactoring-backlog-archive-2026-08-31.md
  local -A _state=()

  _llvm_cross_resolve_dirs _state "${mode}" "${target_label}" || return 0

  _llvm_cross_early_return _state || return 0

  _llvm_cross_retrieve_source _state

  _llvm_cross_pre_build_hooks _state

  _state[native_tool_dir]="$(llvm_host_native_tool_dir)" || die "Host LLVM native tools not found"

  rm -rf "${_state[llvm_prefix]}" "${_state[clang_prefix]}" "${_state[build_dir]}" "${_state[wrapper_dir]}" ${_state[native_wrapper_dir]:+"${_state[native_wrapper_dir]}"}
  log "Building LLVM ${_state[release]} for ${_state[target_label]} (${_state[triplet]}) — single unified superset build (clang;clang-tools-extra;lld) installed to ${_state[llvm_prefix]} + ${_state[clang_prefix]} — this will take a while"

  _llvm_cross_setup_and_build _state

  _llvm_cross_post_build_hooks _state
}

# RUN 3 entry (build_cross_llvm_targets loop): runs the unified superset build,
# producing BOTH /opt/llvm-cross/<triplet> (verified at RUN 3c) and
# /opt/llvm-target-<arch>. `target-llvm`/`target-clang` now select only the
# early-return reuse check; the compile itself is identical.
build_cross_llvm_target() {
  _build_llvm_cross_core target-llvm "$1"
}

# RUN 3d entry (per-arch `setup-dependencies.sh target-clang`): the unified build
# in RUN 3 already produced /opt/llvm-target-<arch> (+ /opt/llvm-cross), so this
# early-returns without a second compile. If ever run standalone (both trees
# absent) it performs the same unified build.
install_target_clang_toolchain() {
  _build_llvm_cross_core target-clang "${1:-${TARGET_ARCH:-${TARGETARCH:-}}}"
}

# The unified superset build (clang;clang-tools-extra;lld) links LLVMgold against
# the binutils plugin API header (/usr/include/plugin-api.h, from binutils-dev).
# The dedicated target-clang RUN (Dockerfile 3d) apt-installs binutils-dev inline,
# but the LLVM RUN (3) runs with SETUP_DEPENDENCIES_SKIP_CORE_TOOLS=true and never
# installs it — so the clang build that now lives here would silently drop the
# gold plugin from /opt/llvm-target. Install it (host arch; the header is
# arch-neutral) before the RUN-3 unified build. Idempotent + best-effort.
_llvm_cross_ensure_host_binutils_dev() {
  [ -f /usr/include/plugin-api.h ] && return 0
  if declare -F apt_install >/dev/null 2>&1; then
    apt_install binutils-dev || \
      log "WARN: binutils-dev unavailable; LLVMgold plugin will be omitted from the target clang"
  fi
}

# Per-target callback for for_each_cross_target (amd64 is skipped by default).
_build_cross_llvm_for_target() {
  local target_label="$1"
  install_cross_llvm_target_packages "${target_label}"
  build_cross_llvm_target "${target_label}"
}

build_cross_llvm_targets() {
  local targets_raw="${CROSS_TARGETS:-amd64,arm64,riscv64}"

  cross_mode_requested || return 0
  _llvm_cross_ensure_host_binutils_dev
  targets_raw="$(arch_list_csv_normalize "${targets_raw}")" || die "Unsupported LLVM cross target list: ${targets_raw}"

  # amd64 is skipped by default (the host already serves amd64 LLVM).
  for_each_cross_target _build_cross_llvm_for_target "${targets_raw}"
}
