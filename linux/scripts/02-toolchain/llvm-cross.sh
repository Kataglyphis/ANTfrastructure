#!/usr/bin/env bash
# LLVM cross-build functions, sourced by llvm.sh.
[ -n "${_LLVM_CROSS_SH_LOADED:-}" ] && return 0
_LLVM_CROSS_SH_LOADED=1
set -euo pipefail
# Hash the compiler's content, not its mtime, so the cache survives compiler rebuilds.
export CCACHE_COMPILERCHECK=content

install_cross_llvm_target_packages() {
  local target_label="$1"

  # The build host's own arch needs no target packages; compare with build_arch_oci, never a literal amd64.
  [ "${target_label}" = "$(build_arch_oci)" ] && return 0
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
  # The build host's arch is source-built too: apt.llvm.org tracks the branch head, not the pinned release.

  triplet="$(arch_deb_multiarch_triplet_for "${target_label}")" || die "No triplet for ${target_label}"

  _r[mode]="${mode}"
  _r[target_label]="${target_label}"
  _r[triplet]="${triplet}"

  # One superset build per arch, installed to both prefixes; a shared clang_prefix would be clobbered.
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
  _r[zlib_include]="${_r[build_root]}/${triplet}-zlib-include"
  _r[jobs]="$(compute_jobs_with_mem_cap "${LLVM_CROSS_JOBS:-}" "${LLVM_CROSS_MB_PER_JOB:-3500}")"
  return 0
}

_llvm_cross_early_return() {
  local -n _r="$1"
  local target_label="${_r[target_label]}" release="${_r[release]}"
  local llvm_prefix="${_r[llvm_prefix]}" clang_prefix="${_r[clang_prefix]}"
  local installed_version llvm_ok=0 clang_ok=0

  # Reuse only when both trees are current; a partial state forces a full rebuild.
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
  # A truncated clone passes a bare .git test, so require HEAD and tree; evict other ~2 GB checkouts.
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
    llvm_assert_commit_pin "${source_dir}" "${tag}" || die "LLVM_COMMIT pin mismatch"
  fi
}

_llvm_cross_pre_build_hooks() {
  local -n _r="$1"
  local target_label="${_r[target_label]}" build_root="${_r[build_root]}"

  # Host gcc wrappers for the native tablegen/helper sub-build.
  _r[native_wrapper_dir]="${build_root}/${_r[triplet]}-native-tool-bin"
  _r[build_cc_real]="$(resolve_build_gcc_tool gcc 2>/dev/null || command -v gcc 2>/dev/null || true)"
  _r[build_cxx_real]="$(resolve_build_gcc_tool g++ 2>/dev/null || command -v g++ 2>/dev/null || true)"
  [ -n "${_r[build_cc_real]}" ] || die "Host C compiler not found for LLVM native helper tools"
  [ -n "${_r[build_cxx_real]}" ] || die "Host C++ compiler not found for LLVM native helper tools"
  _r[host_path]="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
}

# Empty out-array when the target has no existing runtime library dir.
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

# Outer-build launcher args; the caller resolves the launcher because the nested native build needs it too.
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

# Never return to the core-only shape: it leaves libLLVMSupportLSP.a unbuilt.
_llvm_cross_superset_cmake_args() {
  local -n _ss_args="$1"
  local build_cc="$2" build_cxx="$3" launcher="$4" native_tool_dir="$5"

  _ss_args=(
    -DLLVM_BINUTILS_INCDIR=/usr/include
    # lldb too: every LLVM tool the image names is this release's (BACKLOG CON71).
    -DLLVM_ENABLE_PROJECTS="clang;clang-tools-extra;lld;lldb"
    -DLLVM_ENABLE_RUNTIMES="compiler-rt"
    # The target's Python, Lua, libedit and curses are not in the cross sysroot; lldb runs without them.
    -DLLDB_ENABLE_PYTHON=OFF
    -DLLDB_ENABLE_LUA=OFF
    -DLLDB_ENABLE_LIBEDIT=OFF
    -DLLDB_ENABLE_CURSES=OFF
    -DLLDB_ENABLE_LZMA=OFF
    -DCOMPILER_RT_BUILD_SANITIZERS=ON
    -DCOMPILER_RT_BUILD_BUILTINS=ON
    -DCOMPILER_RT_BUILD_XRAY=OFF
    # libFuzzer for -fsanitize=fuzzer and atheris, on libstdc++: a private libc++ ExternalProject is not worth the risk.
    -DCOMPILER_RT_BUILD_LIBFUZZER=ON
    -DCOMPILER_RT_USE_LIBCXX=OFF
    -DCOMPILER_RT_BUILD_PROFILE=ON
    -DCOMPILER_RT_BUILD_MEMPROF=OFF
    -DCOMPILER_RT_BUILD_ORC=OFF
    -DCOMPILER_RT_BUILD_GWP_ASAN=OFF
    -DCOMPILER_RT_BUILD_CTX_PROFILE=OFF
    -DSANITIZER_CXX_ABI=libstdc++
    -DLLVM_USE_HOST_TOOLS=ON
    # The nested native tablegen build needs the launcher too; empty when no cache is usable.
    "-DCROSS_TOOLCHAIN_FLAGS_NATIVE=-DCMAKE_C_COMPILER=${build_cc};-DCMAKE_CXX_COMPILER=${build_cxx};-DCMAKE_ASM_COMPILER=${build_cc}${launcher:+;-DCMAKE_C_COMPILER_LAUNCHER=${launcher};-DCMAKE_CXX_COMPILER_LAUNCHER=${launcher}}"
    -DCLANG_TABLEGEN="${native_tool_dir}/clang-tblgen"
  )
}

# ${!envvar:-}, not ${!envvar}: an unset var is a legitimate state here.
_llvm_cross_resolve_tool() {
  local -n _rt1="$1"
  local key="$2" envvar="$3" tool="$4" triplet="$5" native_ok="$6"
  local val="${!envvar:-}"
  [ -n "${val}" ] || val="$(require_cross_gcc_tool "${tool}" "${triplet}" 2>/dev/null || true)"
  if [ -z "${val}" ] && [ "${native_ok}" = "1" ]; then
    val="$(resolve_build_gcc_tool "${tool}" 2>/dev/null || true)"
    [ -n "${val}" ] || val="$(command -v "${tool}" 2>/dev/null || true)"
  fi
  [ -n "${val}" ] || die "llvm-cross: cannot resolve '${tool}' for ${triplet:-<no triplet>}: \$${envvar} unset, require_cross_gcc_tool found nothing$( [ "${native_ok}" = "1" ] && printf ', and neither did resolve_build_gcc_tool / command -v' || printf ' (target is foreign, so no host fallback is allowed)' )"
  _rt1["${key}"]="${val}"
}

# Own toolchain, as the cross env exports nothing when target == build: env, target helpers, then host tools.
_llvm_cross_resolve_configure_toolchain() {
  local -n _rt="$1"
  local target_label="$2" triplet="$3"
  local build_triplet native_ok=0

  build_triplet="$(build_deb_multiarch_triplet 2>/dev/null || true)"
  [ -n "${triplet}" ] && [ "${triplet}" = "${build_triplet}" ] && native_ok=1

  _rt[processor]="${CROSS_TARGET_PROCESSOR:-}"
  [ -n "${_rt[processor]}" ] \
    || _rt[processor]="$(arch_cmake_system_processor_for "${target_label}" 2>/dev/null || true)"
  [ -n "${_rt[processor]}" ] \
    || die "llvm-cross: no CMAKE_SYSTEM_PROCESSOR for '${target_label}'"

  _rt[triplet]="${CROSS_TARGET_TRIPLET:-${triplet}}"
  [ -n "${_rt[triplet]}" ] || die "llvm-cross: no target triplet for '${target_label}'"

  _llvm_cross_resolve_tool _rt cc      CC      gcc     "${triplet}" "${native_ok}"
  _llvm_cross_resolve_tool _rt cxx     CXX     g++     "${triplet}" "${native_ok}"
  _llvm_cross_resolve_tool _rt ar      AR      ar      "${triplet}" "${native_ok}"
  _llvm_cross_resolve_tool _rt ranlib  RANLIB  ranlib  "${triplet}" "${native_ok}"
  _llvm_cross_resolve_tool _rt nm      NM      nm      "${triplet}" "${native_ok}"
  _llvm_cross_resolve_tool _rt objcopy OBJCOPY objcopy "${triplet}" "${native_ok}"
  _llvm_cross_resolve_tool _rt strip   STRIP   strip   "${triplet}" "${native_ok}"
}

# Configured and normalized triples must agree. docs/cross-build-verification.md#the-llvm-triple-and-the-compiler-rt-directory
llvm_cross_clang_triple() {
  local deb="$1"
  case "${deb}" in
    *-unknown-linux-gnu) printf '%s' "${deb}" ;;
    ?*-linux-gnu)        printf '%s' "${deb%-linux-gnu}-unknown-linux-gnu" ;;
    *) return 1 ;;
  esac
}

# lldb's SymbolFileCTF includes zlib.h without linking ZLIB::ZLIB, and the cross GCC never searches /usr/include.
llvm_cross_stage_zlib_headers() {
  local dir="$1" sysroot="${2:-/}" h
  rm -rf "${dir}"
  [ -f "${sysroot%/}/usr/include/zlib.h" ] || return 0
  mkdir -p "${dir}"
  for h in zlib.h zconf.h; do
    cp -p "${sysroot%/}/usr/include/${h}" "${dir}/${h}"
  done
}

_llvm_cross_cmake_configure() {
  local -n _cfg="$1"
  local clang_triple="$2"
  local -n _cfg_launcher_args="$3"
  local -n _cfg_linker_args="$4"
  local -n _cfg_superset_args="$5"
  local source_dir="${_cfg[source_dir]}" build_dir="${_cfg[build_dir]}" prefix="${_cfg[prefix]}"
  local wrapper_dir="${_cfg[wrapper_dir]}" backend="${_cfg[backend]}"
  local native_tool_dir="${_cfg[native_tool_dir]}"

  # State keys read with :- because the regression fixture supplies neither.
  local -A _tc=()
  _llvm_cross_resolve_configure_toolchain _tc \
    "${_cfg[target_label]:-}" "${_cfg[triplet]:-}"

  # Only zlib's two headers live there, so nothing of the host's /usr/include can shadow the target's.
  local flags_init="-B${wrapper_dir}"
  [ -f "${_cfg[zlib_include]:-}/zlib.h" ] && flags_init+=" -isystem ${_cfg[zlib_include]}"

  cmake -G Ninja \
    "${_cfg_launcher_args[@]}" \
    -S "${source_dir}/llvm" \
    -B "${build_dir}" \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_SYSTEM_NAME=Linux \
    -DCMAKE_SYSTEM_PROCESSOR="${_tc[processor]}" \
    -DCMAKE_SYSROOT="${CMAKE_SYSROOT:-/}" \
    -DCMAKE_C_COMPILER="${_tc[cc]}" \
    -DCMAKE_CXX_COMPILER="${_tc[cxx]}" \
    -DCMAKE_ASM_COMPILER="${_tc[cc]}" \
    -DCMAKE_AR="${_tc[ar]}" \
    -DCMAKE_RANLIB="${_tc[ranlib]}" \
    -DCMAKE_NM="${_tc[nm]}" \
    -DCMAKE_OBJCOPY="${_tc[objcopy]}" \
    -DCMAKE_STRIP="${_tc[strip]}" \
    "${_cfg_linker_args[@]}" \
    -DCMAKE_C_FLAGS_INIT="${flags_init}" \
    -DCMAKE_CXX_FLAGS_INIT="${flags_init}" \
    -DCMAKE_ASM_FLAGS_INIT="${flags_init}" \
    -DCMAKE_LIBRARY_ARCHITECTURE="${_tc[triplet]}" \
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
    -DLLVM_INCLUDE_UTILS=ON \
    -DLLVM_BUILD_UTILS=ON \
    -DLLVM_INSTALL_UTILS=ON \
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

  # TVM needs llvm-config from /opt/llvm-cross, which "all" does not guarantee under cross.
  cmake --build "${build_dir}" --parallel "${jobs}" --target llvm-config

  # One tree to both prefixes; --strip uses the cross strip, as the host's skips foreign ELFs.
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
    llvm_cross_stage_zlib_headers "${_r[zlib_include]}" "${CMAKE_SYSROOT:-/}"

    # Without host wrappers and CLANG_TABLEGEN the native support lib is silently left unbuilt.
    build_cc="$(make_host_compiler_wrapper "${native_wrapper_dir}/host-gcc" "${build_cc_real}" "${host_path}")"
    build_cxx="$(make_host_compiler_wrapper "${native_wrapper_dir}/host-g++" "${build_cxx_real}" "${host_path}")"

    local -a linker_flag_args=()
    _llvm_cross_linker_flag_args linker_flag_args "${target_label}"

    clang_triple="$(llvm_cross_clang_triple "${triplet}")" \
      || die "no LLVM triple for Debian multiarch triplet '${triplet}' (${target_label})"
    export PATH="${wrapper_dir}:${PATH}"

    # sccache first, ccache only as fallback. See docs/build-cache-tiers.md
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

  # Copy llvm-config from the build tree: the installed one may be stripped.
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
  # Never named _r/_cfg/_bi or like an *_args array: a self-referential local -n is circular.
  local -A _state=()

  _llvm_cross_resolve_dirs _state "${mode}" "${target_label}" || return 0

  _llvm_cross_early_return _state || return 0

  _llvm_cross_retrieve_source _state

  _llvm_cross_pre_build_hooks _state

  _state[native_tool_dir]="$(llvm_host_native_tool_dir)" || die "Host LLVM native tools not found"

  rm -rf "${_state[llvm_prefix]}" "${_state[clang_prefix]}" "${_state[build_dir]}" "${_state[wrapper_dir]}" ${_state[native_wrapper_dir]:+"${_state[native_wrapper_dir]}"}
  log "Building LLVM ${_state[release]} for ${_state[target_label]} (${_state[triplet]}) — single unified superset build (clang;clang-tools-extra;lld;lldb) installed to ${_state[llvm_prefix]} + ${_state[clang_prefix]} — this will take a while"

  _llvm_cross_setup_and_build _state

  _llvm_cross_post_build_hooks _state
}

# RUN 3 entry: the unified build yields /opt/llvm-cross/<triplet> and /opt/llvm-target-<arch> alike.
build_cross_llvm_target() {
  _build_llvm_cross_core target-llvm "$1"
}

# RUN 3d entry: normally reuses RUN 3's trees; run standalone it performs the same unified build.
install_target_clang_toolchain() {
  _build_llvm_cross_core target-clang "${1:-${TARGET_ARCH:-${TARGETARCH:-}}}"
}

# LLVMgold needs binutils-dev's plugin-api.h, which the LLVM RUN never installs; without it the plugin is dropped.
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

  # --include-amd64 keeps the build host's arch, built first so later arches use its pinned tablegen, not apt's.
  local _host_arch _rest
  _host_arch="$(build_arch_oci 2>/dev/null || printf 'amd64')"
  # `|| true` INSIDE a brace group: a host-only list leaves grep -vx empty, which pipefail would make a silent death.
  _rest="$( { printf '%s' "${targets_raw}" | tr ',' '\n' | grep -vx "${_host_arch}" || true; } | paste -sd, - )"
  case ",${targets_raw}," in
    *",${_host_arch},"*) targets_raw="${_host_arch}${_rest:+,${_rest}}" ;;
  esac
  log "LLVM cross targets (build host first): ${targets_raw}"
  for_each_cross_target _build_cross_llvm_for_target --include-amd64 "${targets_raw}"
}
