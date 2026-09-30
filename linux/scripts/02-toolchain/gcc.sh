#!/usr/bin/env bash
set -euo pipefail
# gcc.sh - GCC toolchain source-only helper.
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  echo "This script is meant to be sourced, not executed" >&2
  exit 1
fi

gcc_reported_version() {
  local tool="$1"
  local version=""

  command -v "$tool" >/dev/null 2>&1 || return 1
  version="$("$tool" -dumpfullversion -dumpversion 2>/dev/null || true)"
  version="${version%%[[:space:]]*}"
  [ -n "${version}" ] || return 1
  printf '%s' "${version}"
}

install_cross_gcc_sysroot_packages() {
  local normalized_target="$1"
  local triplet

  normalized_target="$(arch_normalize "${normalized_target}")"
  triplet="$(arch_deb_multiarch_triplet_for "${normalized_target}")" || die "Unsupported cross target: ${normalized_target}"

  local -a pkgs=()
  case "${normalized_target}" in
    amd64)   pkgs=(binutils-x86-64-linux-gnu) ;;
    arm64)   pkgs=(binutils-aarch64-linux-gnu) ;;
    riscv64) pkgs=(binutils-riscv64-linux-gnu) ;;
    *)       die "Unsupported cross target: ${normalized_target}" ;;
  esac

  # Only foreign targets need a cross sysroot; compare with the build arch, never a literal amd64.
  if [ "${normalized_target}" != "$(build_arch_oci)" ]; then
    pkgs+=("libc6-dev-${normalized_target}-cross" "linux-libc-dev-${normalized_target}-cross")
  fi
  apt_install_available "${pkgs[@]}"

  if [ "${normalized_target}" != "$(build_arch_oci)" ]; then
    [ -d "/usr/${triplet}/include" ] || die "Expected cross headers not found: /usr/${triplet}/include"
    [ -d "/usr/${triplet}/lib" ] || die "Expected cross libs not found: /usr/${triplet}/lib"
    bridge_cross_lib_sysroot "${triplet}"
    log "Prepared cross sysroot packages for ${normalized_target}: /usr/${triplet}"
  fi

  [ -x "/usr/bin/${triplet}-as" ] || die "Expected cross binutils not found: /usr/bin/${triplet}-as"
}

stage_cross_gcc_sysroot_libs() {
  local prefix="$1"
  local triplet="$2"
  local src_dir="/usr/${triplet}/lib"
  local dst_dir="${prefix}/${triplet}/lib"
  local entry base

  [ -d "${src_dir}" ] || return 0

  $SUDO mkdir -p "${dst_dir}"
  for entry in "${src_dir}"/*; do
    [ -e "${entry}" ] || continue
    base="$(basename "${entry}")"
    if [ ! -e "${dst_dir}/${base}" ]; then
      $SUDO ln -sfn "${entry}" "${dst_dir}/${base}"
    fi
  done
  log "Staged target sysroot libs for ${triplet} into ${dst_dir}"
}

# Debian cross packages use /usr/<triplet>/lib, but --with-sysroot=/ searches /usr/lib/<triplet>.
bridge_cross_lib_sysroot() {
  local triplet="$1"
  local src="/usr/${triplet}/lib"
  local dst="/usr/lib/${triplet}"

  [ -d "${src}" ] || return 0
  [ -d "${dst}" ] && return 0

  $SUDO mkdir -p "$(dirname "${dst}")"
  $SUDO ln -sfn "${src}" "${dst}"
  log "Bridged cross sysroot: ${dst} -> ${src}"
}

# Build scratch under $HOME, never a small shared /tmp tmpfs.
gcc_cross_scratch_root() {
  printf '%s' "${GCC_CROSS_SCRATCH_ROOT:-${HOME}/tmp2}"
}

# The ELF machine type, unlike gcc -dumpmachine, tells a target-native compiler from a host-arch cross one.
assert_gcc_elf_arch() {
  local file="$1"
  local arch="$2"
  local label="${3:-${file}}"
  local pattern machine

  pattern="$(arch_elf_machine_grep_for "${arch}" 2>/dev/null || true)"
  if [ -z "${pattern}" ]; then
    warn "No ELF machine pattern known for arch '${arch}'; skipping ELF check for ${label}"
    return 0
  fi
  if ! command -v readelf >/dev/null 2>&1; then
    warn "readelf not available; skipping ELF arch check for ${label}"
    return 0
  fi
  [ -e "${file}" ] || die "Expected binary missing for ELF arch check: ${file} (${label})"
  machine="$(elf_machine_name "${file}" 2>/dev/null || true)"
  [ -n "${machine}" ] || die "Could not read ELF machine type of ${file} (${label})"
  case "${machine}" in
    *"${pattern}"*)
      log "ELF arch OK: ${label} -> Machine='${machine}' matches ${arch}"
      ;;
    *)
      die "ELF arch MISMATCH: ${label} (${file}) Machine='${machine}', expected '${pattern}' for ${arch}. A host-arch binary leaked into the target-native toolchain."
      ;;
  esac
}

# Also link unprefixed into the tooldir: GCC looks there for a bare "as", else it runs the build host's.
link_cross_binutils() {
  local prefix="$1"
  local triplet="$2"
  local tool resolved tooldir

  tooldir="${prefix}/${triplet}/bin"
  $SUDO mkdir -p "${tooldir}"
  for tool in as ld ar nm ranlib strip objcopy objdump; do
    resolved="$(command -v "${triplet}-${tool}" 2>/dev/null || true)"
    if [ -z "${resolved}" ]; then
      # Only the tools GCC drives are fatal; objcopy and objdump are optional.
      case "${tool}" in
        as|ld|ar|nm|ranlib|strip)
          die "Expected cross binutils not found: ${triplet}-${tool}" ;;
        *) continue ;;
      esac
    fi
    $SUDO ln -sfn "${resolved}" "${prefix}/bin/${triplet}-${tool}"
    $SUDO ln -sfn "${resolved}" "${tooldir}/${tool}"
  done
}

# The build-host GCC; GCC_HOST_BOOTSTRAP=0 saves about 2/3 of its time but drops the miscompile self-check.
build_host_gcc() {
  local full_version="$1"
  local prefix="$2"
  local scratch_root
  # Only stage1 of a bootstrapped build is cacheable; the cross and Canadian builds cache fully.
  local -a host_args=(--version "${full_version}" --ccache)

  scratch_root="$(gcc_cross_scratch_root)"
  case "${GCC_HOST_BOOTSTRAP:-1}" in
    0|false|FALSE|no|NO|off|OFF)
      log "Host GCC bootstrap disabled (GCC_HOST_BOOTSTRAP=${GCC_HOST_BOOTSTRAP:-})"
      host_args+=(--disable-bootstrap)
      ;;
  esac

  log "Building host GCC ${full_version} from source -> ${prefix}"
  PREFIX="${prefix}" \
    BUILD_DIR="${scratch_root}/gcc-build-${full_version}-native" \
    JOBS="${JOBS:-$(nproc)}" \
    bash "${GCC_CROSS_BUILDER}" "${host_args[@]}"

  # The host compiler must be a build-host binary (e.g. amd64 on this host).
  assert_gcc_elf_arch "${prefix}/bin/gcc" "$(build_arch_oci)" "host gcc"
}

# A target equal to the build arch just exposes the native GCC under its triplet names.
link_amd64_host_as_cross() {
  local prefix="$1"
  local triplet="$2"
  local tool

  for tool in gcc g++ gcov; do
    [ -x "${prefix}/bin/${tool}" ] || die "Expected host GCC tool not found: ${prefix}/bin/${tool}"
  done
  for tool in gcc g++ cpp gcov gcc-ar gcc-nm gcc-ranlib; do
    $SUDO ln -sfn "${prefix}/bin/${tool}" "${prefix}/bin/${triplet}-${tool}"
  done
  link_cross_binutils "${prefix}" "${triplet}"
}

# A cross GCC that runs on the build host and emits target code, under triplet-prefixed names.
build_cross_gcc_for() {
  local full_version="$1"
  local prefix="$2"
  local triplet="$3"
  local scratch_root tool

  scratch_root="$(gcc_cross_scratch_root)"
  log "Building source cross GCC ${full_version} for ${triplet}"
  PREFIX="${prefix}" \
    BUILD_DIR="${scratch_root}/gcc-build-${full_version}-${triplet}" \
    JOBS="${JOBS:-$(nproc)}" \
    bash "${GCC_CROSS_BUILDER}" \
      --version "${full_version}" \
      --target "${triplet}" \
      --languages c,c++ \
      --sysroot / \
      --native-system-header-dir "/usr/${triplet}/include" \
      --disable-bootstrap \
      --ccache \
      --skip-system-registration

  for tool in gcc g++ gcc-ar gcc-nm gcc-ranlib; do
    [ -x "${prefix}/bin/${triplet}-${tool}" ] || die "Expected cross GCC tool not found: ${prefix}/bin/${triplet}-${tool}"
  done
  link_cross_binutils "${prefix}" "${triplet}"

  # The cross compiler itself is a build-host binary that emits target code.
  assert_gcc_elf_arch "${prefix}/bin/${triplet}-gcc" "$(build_arch_oci)" "cross gcc (${triplet})"
}

# Canadian cross to a GCC that runs natively on the target; Dockerfile.android swaps it in as /usr/bin/cc.
build_canadian_native_gcc_for() {
  local full_version="$1"
  local prefix="$2"
  local triplet="$3"
  local normalized_target="$4"
  local scratch_root native_prefix cross_cc cross_cxx link_err

  scratch_root="$(gcc_cross_scratch_root)"
  native_prefix="/opt/gcc-${full_version}-native-${normalized_target}"
  cross_cc="${prefix}/bin/${triplet}-gcc"
  cross_cxx="${prefix}/bin/${triplet}-g++"
  [ -x "${cross_cc}" ] || die "Cross compiler ${cross_cc} not found for Canadian cross"
  [ -x "${cross_cxx}" ] || die "Cross compiler ${cross_cxx} not found for Canadian cross"
  log "Building native GCC ${full_version} for ${normalized_target} (Canadian cross via ${cross_cc})"

  # Never shadow bare as/ld with target binutils on PATH: GCC's build-side helpers need the native ones.

  # A failed link test almost always means a missing target sysroot; fail here, not in Dockerfile.android.
  log "Testing cross-compiler link capability for ${normalized_target}..."
  if ! link_err="$(printf 'int main(){return 0;}\n' | "${cross_cc}" -x c - -o "${scratch_root}/_cc_linktest_${normalized_target}" 2>&1)"; then
    if [ "${GCC_CANADIAN_CROSS_SKIP_ON_LINK_FAILURE:-0}" = "1" ]; then
      warn "Cross-compiler link test FAILED for ${normalized_target}: ${link_err}"
      warn "GCC_CANADIAN_CROSS_SKIP_ON_LINK_FAILURE=1 set; skipping native GCC for ${normalized_target}."
      warn "Downstream Dockerfile.android WILL fail the GCC swap for ${normalized_target}."
      return 1
    fi
    die "Cross-compiler link test FAILED for ${normalized_target}: ${link_err}
Fix: apt install libc6-dev-${normalized_target}-cross linux-libc-dev-${normalized_target}-cross binutils-${triplet}
(Set GCC_CANADIAN_CROSS_SKIP_ON_LINK_FAILURE=1 to skip the native build instead of failing.)"
  fi
  rm -f "${scratch_root}/_cc_linktest_${normalized_target}"
  log "Cross-compiler link test passed for ${normalized_target}"

  # The caller's `if !` disables errexit here, so die explicitly. docs/failure-modes.md#a-callee-invoked-in-an-if--condition-runs-with-errexit-off
  CC="${cross_cc}" CXX="${cross_cxx}" \
    ac_cv_prog_cc_works=yes \
    ac_cv_prog_CC_works=yes \
    ac_cv_prog_cxx_works=yes \
    PREFIX="${native_prefix}" \
    BUILD_DIR="${scratch_root}/gcc-build-${full_version}-native-${normalized_target}" \
    JOBS="${JOBS:-$(nproc)}" \
    bash "${GCC_CROSS_BUILDER}" \
      --version "${full_version}" \
      --target "${triplet}" \
      --host "${triplet}" \
      --languages c,c++ \
      --sysroot / \
      --native-system-header-dir "/usr/${triplet}/include" \
      --disable-bootstrap \
      --ccache \
      --skip-system-registration \
      || die "Canadian native GCC build FAILED for ${normalized_target}"

  [ -x "${native_prefix}/bin/gcc" ] || die "Expected native GCC not found: ${native_prefix}/bin/gcc"
  [ -x "${native_prefix}/bin/g++" ] || die "Expected native G++ not found: ${native_prefix}/bin/g++"

  # The point of this stage: target-arch ELF, caught here rather than three Dockerfiles later.
  assert_gcc_elf_arch "${native_prefix}/bin/gcc" "${normalized_target}" "target-native gcc (${normalized_target})"
  assert_gcc_elf_arch "${native_prefix}/bin/g++" "${normalized_target}" "target-native g++ (${normalized_target})"
  log "Installed native GCC ${full_version} for ${normalized_target} at ${native_prefix}"
}

# Strict X.Y.Z, else <default>.
gcc_resolve_full_version() {
  local full="$1" default="$2"
  if [[ ! "${full}" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    full="${default}"
  fi
  printf '%s' "${full}"
}

# Path of the executable build-gcc.sh beside this script; dies if missing.
gcc_locate_builder() {
  local script_dir builder
  script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  builder="${script_dir}/build-gcc.sh"
  [ -f "${builder}" ] || die "GCC build script not found: ${builder}"
  chmod +x "${builder}" || true
  printf '%s' "${builder}"
}

# Per-target callback; full_version, prefix and requested_major come from the caller by dynamic scope.
_gcc_build_cross_target() {
  local normalized_target="$1"
  local triplet tool actual_tool actual_version

  # Skipped after the parallel driver's serial apt pass: concurrent callbacks would collide on the dpkg lock.
  if [ "${GCC_SYSROOT_PREINSTALLED:-0}" != "1" ]; then
    install_cross_gcc_sysroot_packages "${normalized_target}"
  fi
  triplet="$(arch_deb_multiarch_triplet_for "${normalized_target}")" || die "Unsupported cross target: ${normalized_target}"

  if [ "${normalized_target}" = "$(build_arch_oci)" ]; then
    link_amd64_host_as_cross "${prefix}" "${triplet}"
  else
    stage_cross_gcc_sysroot_libs "${prefix}" "${triplet}"
    build_cross_gcc_for "${full_version}" "${prefix}" "${triplet}"
    # Returns 1 only for the opt-in skip, which must not abort the remaining targets.
    if ! build_canadian_native_gcc_for "${full_version}" "${prefix}" "${triplet}" "${normalized_target}"; then
      warn "Skipping Canadian native GCC for ${normalized_target}; continuing with remaining targets"
    fi
  fi

  for tool in gcc g++ ar; do
    [ -x "${prefix}/bin/${triplet}-${tool}" ] || die "Expected cross compiler not found: ${prefix}/bin/${triplet}-${tool}"
  done
  log "Installed cross compiler commands for ${normalized_target}: ${triplet}-gcc ${triplet}-g++ ${triplet}-ar"

  actual_tool="${prefix}/bin/${triplet}-g++"
  actual_version="$(gcc_reported_version "${actual_tool}" || true)"
  if [ -n "${actual_version}" ]; then
    if [ -n "${requested_major}" ] && [ "$(version_major "${actual_version}")" != "${requested_major}" ]; then
      warn "Cross mode requested GCC ${full_version}, but ${triplet}-g++ resolves to ${actual_tool} (GCC ${actual_version})."
    else
      log "Cross compiler version for ${normalized_target}: ${actual_tool} (${actual_version})"
    fi
  fi
}

# GCC_PARALLEL_TARGETS=1: serial apt pass, then concurrent builds with JOBS split and one log per target.
_gcc_build_cross_targets_parallel() {
  local targets_csv="$1"
  local -a all_targets=() par_targets=()
  local t
  IFS=',' read -r -a all_targets <<< "${targets_csv}"

  log "GCC_PARALLEL_TARGETS=1: serial apt pre-pass, then concurrent target builds"
  for_each_cross_target install_cross_gcc_sysroot_packages --include-amd64 "${targets_csv}"
  # The callbacks below must not re-run apt (dpkg lock).
  local GCC_SYSROOT_PREINSTALLED=1
  # build_host_gcc already installed build-gcc.sh's deps, and concurrent apt runs would collide on the lock.
  export GCC_SKIP_BUILD_DEPS=1

  local build_arch
  build_arch="$(build_arch_oci 2>/dev/null || arch_oci)"
  for t in "${all_targets[@]}"; do
    [ -n "${t}" ] || continue
    if [ "${t}" = "${build_arch}" ]; then
      _gcc_build_cross_target "${t}"   # symlink-only, cheap, keep serial
    else
      par_targets+=("${t}")
    fi
  done
  [ "${#par_targets[@]}" -gt 0 ] || return 0

  local n="${#par_targets[@]}" total_jobs per_jobs
  total_jobs="$(nproc 2>/dev/null || echo 4)"
  per_jobs=$(( total_jobs / n )); [ "${per_jobs}" -ge 1 ] || per_jobs=1

  local logdir
  logdir="$(gcc_cross_scratch_root)/gcc-parallel-logs"
  mkdir -p "${logdir}"

  local -a pids=() pid_targets=()
  for t in "${par_targets[@]}"; do
    log "  [parallel] ${t}: JOBS=${per_jobs}, log ${logdir}/${t}.log"
    ( JOBS="${per_jobs}" _gcc_build_cross_target "${t}" ) > "${logdir}/${t}.log" 2>&1 &
    pids+=($!); pid_targets+=("${t}")
  done

  local i failed=0
  for i in "${!pids[@]}"; do
    if wait "${pids[$i]}"; then
      log "  [parallel] ${pid_targets[$i]}: OK"
    else
      failed=1
      warn "[parallel] target ${pid_targets[$i]} FAILED — last 100 log lines:"
      tail -n 100 "${logdir}/${pid_targets[$i]}.log" >&2 || true
    fi
  done
  [ "${failed}" -eq 0 ] || die "One or more parallel GCC target builds failed (full logs in ${logdir})"
}

build_source_cross_gcc_targets() {
  local full_version="$1"
  local targets_raw="${CROSS_TARGETS:-amd64,arm64,riscv64}"
  local gcc_major requested_major prefix compat_prefix

  gcc_major="$(version_major "${full_version}")"
  requested_major="${gcc_major}"
  prefix="/opt/gcc-${full_version}"

  GCC_CROSS_BUILDER="$(gcc_locate_builder)"
  targets_raw="$(arch_list_csv_normalize "${targets_raw}")" || die "Unsupported GCC cross target list: ${targets_raw}"

  # One tarball download for every per-target build; build-gcc.sh still verifies each use.
  export GCC_TARBALL_CACHE_DIR="${GCC_TARBALL_CACHE_DIR:-$(gcc_cross_scratch_root)/gcc-tarball-cache}"

  build_host_gcc "${full_version}" "${prefix}"

  log "Building cross GCC toolchains from source for ${targets_raw}"
  if [ "${GCC_PARALLEL_TARGETS:-0}" = "1" ]; then
    _gcc_build_cross_targets_parallel "${targets_raw}"
  else
    # amd64 is included: on an amd64 host it is linked from the native host GCC.
    for_each_cross_target _gcc_build_cross_target --include-amd64 "${targets_raw}"
  fi

  compat_prefix="/opt/gcc-${full_version}"
  if [ ! -d "${compat_prefix}/bin" ]; then
    die "Expected GCC install prefix not found after cross build: ${compat_prefix}/bin"
  fi
}

install_gcc() {
  log "Installing GCC ${GCC_WANTED}"

  local gcc_major="$(version_major "${GCC_WANTED}")"
  local default_full_version
  case "${gcc_major}" in
    16) default_full_version="16.2.0" ;;
    15) default_full_version="15.2.0" ;;
    *) default_full_version="${gcc_major}.1.0" ;;
  esac
  local full_version="${GCC_VERSION:-${default_full_version}}"

  # Cross mode: the host compiler stays native; each target gets a triplet-named toolchain.
  if cross_mode_requested; then
    full_version="$(gcc_resolve_full_version "${full_version}" "${default_full_version}")"

    build_source_cross_gcc_targets "${full_version}"
    gcc --version || true
    return 0
  fi

  # GCC >= 15 builds from source: apt's gcc-16 is a dated snapshot, not the pinned release.
  if [ -n "${gcc_major}" ] && [ "${gcc_major}" -ge 15 ] 2>/dev/null; then
    local builder
    builder="$(gcc_locate_builder)"

    # Determine full version (e.g. 16.2.0 from GCC_WANTED=16)
    full_version="$(gcc_resolve_full_version "${full_version}" "${default_full_version}")"

    log "Building GCC ${full_version} from source..."
    PREFIX="${PREFIX:-/opt/gcc-${full_version}}" \
      BUILD_DIR="${BUILD_DIR:-${HOME}/tmp2/gcc-build-${full_version}}" \
      JOBS="${JOBS:-$(nproc)}" \
      bash "${builder}" --version "${full_version}"
    return 0
  fi

  # For GCC < 15, install from apt
  apt_install gcc-"${GCC_WANTED}" g++-"${GCC_WANTED}" gfortran-"${GCC_WANTED}"
  for t in gcc g++ gcov; do
    if [ -x "/usr/bin/${t}-${GCC_WANTED}" ]; then
      alt_install_and_set "${t}" "/usr/bin/${t}" "/usr/bin/${t}-${GCC_WANTED}" 100
    fi
  done
  gcc --version || true
  g++ --version || true
}
