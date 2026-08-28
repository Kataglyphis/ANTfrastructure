#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# /opt/scripts first (container layout), then repo layout.
for _bs_path in \
  "/opt/scripts/core/modules.sh" \
  "${SCRIPT_DIR}/../../01-core/modules.sh"; do
  if [ -f "${_bs_path}" ]; then
    source "${_bs_path}"
    source_modules_framework "${SCRIPT_DIR}"
    break
  fi
done

source_module platform.sh
# Loaded intolerantly on purpose: ubuntu_write_deb822_source() is called mid-apt-rewrite
# below, so a missing helper must fail here rather than as a `command not found` there.
source_module ubuntu-mirror.sh
source_module cross-env.sh || true
source_module logging.sh || true
source_module parallelism.sh || true
source_module downloads.sh
# Shared CPython dev-package/extension table (backlog TS3), also feeding
# package-lists.sh and smoke-toolchain.sh — keep the cross and host lists in sync.
source_module cpython-dev-packages.sh

install_err_trap

PYTHON_VERSION="${PYTHON_VERSION:-${1:-3.14.7}}"
PYTHON_MAJOR_MINOR="${PYTHON_MAJOR_MINOR:-$(version_major_minor "${PYTHON_VERSION}")}"
PYTHON_TARBALL="${TMPDIR:-/tmp}/Python-${PYTHON_VERSION}-$$.tgz"
PYTHON_SOURCE_DIR="${TMPDIR:-/tmp}/Python-${PYTHON_VERSION}"
PYTHON_CROSS_STAGE_ROOT="${PYTHON_CROSS_STAGE_ROOT:-/opt/python-cross}"

cleanup() {
  rm -rf \
    "${PYTHON_SOURCE_DIR}" \
    "${PYTHON_TARBALL}" \
    "${TMPDIR:-/tmp}"/Python-"${PYTHON_VERSION}"-cross-* \
    "${TMPDIR:-/tmp}"/python-config-site-*
}

trap cleanup EXIT

python_cross_stage_root_for_arch() {
  local target_arch="$1"

  printf '%s' "${PYTHON_CROSS_STAGE_ROOT}/$(arch_normalize "${target_arch}")"
}

python_cross_stage_prefix_for_arch() {
  local target_arch="$1"

  printf '%s' "$(python_cross_stage_root_for_arch "${target_arch}")/usr/local"
}

for _pc_fix in \
  "/opt/scripts/python/fix-staged-python-pc.sh" \
  "${SCRIPT_DIR}/fix-staged-python-pc.sh"; do
  if [ -f "${_pc_fix}" ]; then
    source "${_pc_fix}"
    break
  fi
done

python_stage_finalize() {
  local target_arch="$1"
  local stage_root="$2"
  local python_mm="$3"
  local target_triplet="$4"
  local pkgconfig_dir="${stage_root}/usr/local/lib/pkgconfig"

  mkdir -p "${stage_root}/usr/local/include/${target_triplet}/python${python_mm}"
  if [ -f "${stage_root}/usr/local/include/python${python_mm}/pyconfig.h" ]; then
    cp -a \
      "${stage_root}/usr/local/include/python${python_mm}/pyconfig.h" \
      "${stage_root}/usr/local/include/${target_triplet}/python${python_mm}/pyconfig.h"
  fi

  if [ -x "${stage_root}/usr/local/bin/python${python_mm}" ]; then
    ln -sfn "python${python_mm}" "${stage_root}/usr/local/bin/python3"
    ln -sfn "python${python_mm}" "${stage_root}/usr/local/bin/python"
  fi

  if [ -x "${stage_root}/usr/local/bin/python${python_mm}-config" ]; then
    ln -sfn "python${python_mm}-config" "${stage_root}/usr/local/bin/python3-config"
  fi

  mkdir -p "${pkgconfig_dir}"
  fix_python_pc_file "${pkgconfig_dir}/python-${python_mm}.pc"
  fix_python_pc_file "${pkgconfig_dir}/python-${python_mm}-embed.pc"
  if [ -f "${pkgconfig_dir}/python-${python_mm}.pc" ]; then
    ln -sfn "python-${python_mm}.pc" "${pkgconfig_dir}/python3.pc"
  fi
  if [ -f "${pkgconfig_dir}/python-${python_mm}-embed.pc" ]; then
    ln -sfn "python-${python_mm}-embed.pc" "${pkgconfig_dir}/python3-embed.pc"
  fi

  info "Target Python ${python_mm} staged for ${target_arch}:"
  info "  prefix: $(python_cross_stage_prefix_for_arch "${target_arch}")"
  info "  include: ${stage_root}/usr/local/include/python${python_mm}"
  info "  arch include: ${stage_root}/usr/local/include/${target_triplet}/python${python_mm}"
  info "  libdir: ${stage_root}/usr/local/lib"
  info "  pkg-config: ${pkgconfig_dir}"
}

stage_host_python_payload() {
  local target_arch="$1"
  local python_mm="${PYTHON_MAJOR_MINOR}"
  local stage_root
  local target_triplet

  stage_root="$(python_cross_stage_root_for_arch "${target_arch}")"
  target_triplet="$(arch_deb_multiarch_triplet_for "${target_arch}")"

  rm -rf "${stage_root}"
  mkdir -p "${stage_root}/usr/local/bin" "${stage_root}/usr/local/lib" "${stage_root}/usr/local/include"

  cp -a "/usr/local/bin/python${python_mm}" "${stage_root}/usr/local/bin/"
  if [ -x "/usr/local/bin/python${python_mm}-config" ]; then
    cp -a "/usr/local/bin/python${python_mm}-config" "${stage_root}/usr/local/bin/"
  fi

  cp -a "/usr/local/lib/python${python_mm}" "${stage_root}/usr/local/lib/"
  cp -a "/usr/local/include/python${python_mm}" "${stage_root}/usr/local/include/"

  shopt -s nullglob
  cp -a /usr/local/lib/libpython"${python_mm}".so* "${stage_root}/usr/local/lib/"
  if [ -d "/usr/local/lib/pkgconfig" ]; then
    mkdir -p "${stage_root}/usr/local/lib/pkgconfig"
    cp -a /usr/local/lib/pkgconfig/python*.pc "${stage_root}/usr/local/lib/pkgconfig/" 2>/dev/null || true
  fi
  shopt -u nullglob

  python_stage_finalize "${target_arch}" "${stage_root}" "${python_mm}" "${target_triplet}"
}

# Enable the target architecture + ports.ubuntu.com apt sources. The base image
# only carries the amd64 archive; arm64/riscv64 packages come from ports.
_python_cross_enable_multiarch_apt() {
  local target_arch="$1"
  if ! dpkg --print-architecture 2>/dev/null | grep -qx "${target_arch}" && \
     ! dpkg --print-foreign-architectures 2>/dev/null | grep -qx "${target_arch}"; then
    dpkg --add-architecture "${target_arch}"
  fi
  if [ ! -f /etc/apt/sources.list.d/ubuntu-ports.sources ]; then
    local _codename
    _codename="$(. /etc/os-release && echo "${UBUNTU_CODENAME:-resolute}")"
    rm -f /etc/apt/sources.list.d/*.sources /etc/apt/sources.list 2>/dev/null || true
    # 5th arg = add "-security" (archive: no, ports: yes). USE_FAST_UBUNTU_MIRROR is
    # deliberately NOT honoured here — that would be a behaviour change (TS8).
    ubuntu_write_deb822_source /etc/apt/sources.list.d/ubuntu.sources \
      "$(ubuntu_default_archive_mirror_url)" "${_codename}" amd64 0
    ubuntu_write_deb822_source /etc/apt/sources.list.d/ubuntu-ports.sources \
      "$(ubuntu_default_ports_mirror_url)" "${_codename}" "arm64 riscv64" 1
    apt-get update -qq 2>&1 || warn "apt-get update failed; multiarch repos may be unavailable"
  fi
}

# Install the target-arch dev packages CPython's extension modules link against.
# Explicit architecture qualifier avoids install_target_packages' silent amd64
# fallback (cross_build_enabled() returns false when TARGET_ARCH == BUILD_ARCH).
_python_cross_stage_target_dev_pkgs() {
  local target_arch="$1"
  # Backlog TS2 (deferred): promoting the table's required rows to a FATAL install
  # needs a cross rebuild to prove Ports outages don't flakily drop one.
  local -a target_pkgs=() _pkg
  while IFS= read -r _pkg; do
    [ -n "${_pkg}" ] && target_pkgs+=("${_pkg}:${target_arch}")
  done < <(cpython_ext_dev_packages)
  # Host-arch libbz2-dev too: the build interpreter links bz2 during the
  # cross configure probes (ac_cv_lib_bz2_* below), so it must exist unqualified.
  target_pkgs+=("libbz2-dev")
  apt-get install -y --no-install-recommends "${target_pkgs[@]}" 2>&1 || \
    warn "Some target dev packages failed to install; extension modules may be missing"
}

_python_cross_configure() {
  local source_dir="$1"
  local target_arch="$2"
  local python_mm="$3"
  local target_triplet="$4"
  local build_triplet="$5"
  local build_python_bin="$6"
  local build_python_libdir="$7"
  local cross_build_dir="$8"
  local config_site="$9"
  local stage_root="${10}"
  local pkg_config_libdir

  info "Cross mode detected; building target Python ${python_mm} for ${target_arch} (${target_triplet})"

  if [ ! -x "${build_python_bin}" ]; then
    err "Expected build Python ${build_python_bin} was not found"
  fi

  prepare_cross_target_env "${target_arch}" "cross Python ${target_arch} staging"

  _python_cross_enable_multiarch_apt "${target_arch}"
  _python_cross_stage_target_dev_pkgs "${target_arch}"

  pkg_config_libdir="$(cross_pkg_config_libdir "${target_triplet}")"
  export CFLAGS="${CFLAGS:--O2} -idirafter /usr/include -idirafter /usr/include/${target_triplet}"
  export CPPFLAGS="${CPPFLAGS:-} -idirafter /usr/include -idirafter /usr/include/${target_triplet}"
  export LDFLAGS="-L/usr/lib/${target_triplet} ${LDFLAGS:-}"
  export LIBRARY_PATH="/usr/lib/${target_triplet}:${LIBRARY_PATH:-}"
  cat > "${config_site}" <<EOF
ac_cv_buggy_getaddrinfo=no
ac_cv_file__dev_ptmx=yes
ac_cv_file__dev_ptc=no
ac_cv_header_ffi_h=no
ac_cv_header_bzlib_h=yes
ac_cv_lib_bz2_BZ2_bzlibVersion=yes
ac_cv_header_uuid_uuid_h=yes
EOF

  rm -f "${source_dir}/Python/frozen_modules/"*.h "${source_dir}/Python/frozen_modules/MANIFEST"
  make -C "${source_dir}" clean 2>/dev/null || true
  rm -f "${source_dir}/pyconfig.h" "${source_dir}/Makefile" "${source_dir}/python" "${source_dir}/Modules/Setup.local"
  rm -rf "${cross_build_dir}" "${stage_root}"
  mkdir -p "${cross_build_dir}/Python/frozen_modules" "${stage_root}"

  # AP5: cross-LTO leans on the target GCC's linker plugin (fragile), so PYTHON_LTO=0
  # is the escape hatch. PGO stays out of reach cross (needs the foreign interpreter).
  local -a _lto_args=()
  [ "${PYTHON_LTO:-1}" = "1" ] && _lto_args=( --with-lto )

  (
    cd "${cross_build_dir}"
    CONFIG_SITE="${config_site}" \
      LDFLAGS="${LDFLAGS}" \
      LD_LIBRARY_PATH="${build_python_libdir}:${LD_LIBRARY_PATH:-}" \
      PKG_CONFIG_ALLOW_CROSS=1 \
      PKG_CONFIG_SYSROOT_DIR=/ \
      PKG_CONFIG_LIBDIR="${pkg_config_libdir}" \
      "${source_dir}/configure" \
        --build="${build_triplet}" \
        --host="${target_triplet}" \
        --prefix=/usr/local \
        --with-build-python="${build_python_bin}" \
        --with-pkg-config=yes \
        --enable-shared \
        "${_lto_args[@]}" \
        --without-ensurepip \
        --disable-test-modules
  )
}

_python_cross_build() {
  local cross_build_dir="$1"
  local target_arch="$2"
  local python_mm="$3"

  (
    cd "${cross_build_dir}"
    make -k -j"$(compute_jobs_with_mem_cap "" 2500)" 2>&1 || true
  )

  if [ ! -x "${cross_build_dir}/python" ] || [ ! -f "${cross_build_dir}/libpython${python_mm}.so.1.0" ]; then
    err "target Python cross build for ${target_arch} did not produce the critical binary or shared library"
  fi
}

_python_cross_install_staging() {
  local cross_build_dir="$1"
  local stage_root="$2"
  local python_mm="$3"
  local source_dir="$4"

  # Copy from the build tree rather than `make altinstall`: the target binary cannot
  # execute on the build host without QEMU, and this needs no HOSTRUNNER.

  mkdir -p "${stage_root}/usr/local/bin" "${stage_root}/usr/local/lib" "${stage_root}/usr/local/include"

  if [ -x "${cross_build_dir}/python" ]; then
    cp -a "${cross_build_dir}/python" "${stage_root}/usr/local/bin/python${python_mm}"
  else
    err "Expected cross-built python binary was not produced in ${cross_build_dir}"
  fi

  shopt -s nullglob
  cp -a "${cross_build_dir}"/libpython"${python_mm}".so* "${stage_root}/usr/local/lib/"
  shopt -u nullglob

  if [ ! -f "${stage_root}/usr/local/lib/libpython${python_mm}.so.1.0" ] && \
     [ ! -f "${stage_root}/usr/local/lib/libpython${python_mm}.so" ]; then
    err "Expected cross-built libpython${python_mm}.so was not produced"
  fi

  cp -a "${source_dir}/Include/." "${stage_root}/usr/local/include/python${python_mm}/"
  cp -a "${cross_build_dir}/pyconfig.h" "${stage_root}/usr/local/include/python${python_mm}/pyconfig.h"

  cp -a "${source_dir}/Lib/." "${stage_root}/usr/local/lib/python${python_mm}/"
}

_python_cross_fixup_libdynload() {
  local cross_build_dir="$1"
  local stage_root="$2"
  local python_mm="$3"
  local dynload_dir ext_build_dir

  # CPython 3.14 leaves RELATIVE symlinks into ../../Modules under build/lib.linux-*/;
  # a plain `cp -a` preserves them and the staged lib-dynload dangles, so the target
  # Python can load no C extension at all. -L dereferences them.
  dynload_dir="${stage_root}/usr/local/lib/python${python_mm}/lib-dynload"
  mkdir -p "${dynload_dir}"
  for ext_build_dir in "${cross_build_dir}/build/lib.linux"*; do
    if [ -d "${ext_build_dir}" ]; then
      cp -a -L "${ext_build_dir}/." "${dynload_dir}/"
    fi
  done

  # Safety net for a build/lib.linux-*/ that was empty or held only links.
  if [ -d "${cross_build_dir}/Modules" ]; then
    find "${cross_build_dir}/Modules" -maxdepth 1 -name '*.so' \
      -exec cp -a -L {} "${dynload_dir}/" \;
  fi

  # Final guard: a dangling extension symlink here silently broke foreign-arch torch.
  if find "${dynload_dir}" -xtype l 2>/dev/null | grep -q .; then
    while read -r symlink; do warn "dangling: ${symlink}"; done < <(find "${dynload_dir}" -xtype l 2>/dev/null || true)
    err "dangling extension symlinks remain in ${dynload_dir} after staging"
  fi

  # `make -k || true` above can skip a failed extension silently, and the symlink check
  # only catches broken links. These have no external deps and must always build.
  local -a _critical_exts=(_struct math cmath _csv _json _pickle _socket)
  local _ext _missing=()
  for _ext in "${_critical_exts[@]}"; do
    if ! ls "${dynload_dir}"/"${_ext}".cpython-*.so >/dev/null 2>&1 && \
       ! ls "${dynload_dir}"/"${_ext}".so >/dev/null 2>&1; then
      _missing+=("$_ext")
    fi
  done
  if [ "${#_missing[@]}" -gt 0 ]; then
    warn "Missing critical C extensions in ${dynload_dir}: ${_missing[*]}"
    err "target Python is missing critical C extensions (make -k may have silently failed)"
  fi

  # These depend on target dev packages. _ctypes is deliberately off via
  # ac_cv_header_ffi_h=no above, so its warning is expected on cross builds.
  local -a _optional_exts=(zlib _bz2 _lzma _ssl _hashlib _ctypes _sqlite3)
  for _ext in "${_optional_exts[@]}"; do
    if ! ls "${dynload_dir}"/"${_ext}".cpython-*.so >/dev/null 2>&1 && \
       ! ls "${dynload_dir}"/"${_ext}".so >/dev/null 2>&1; then
      warn "Optional C extension missing: ${_ext} (target dev package may not be installed)"
    fi
  done
}

_python_cross_stage_into_compiler() {
  local cross_build_dir="$1"
  local stage_root="$2"
  local python_mm="$3"
  local target_arch="$4"
  local target_triplet="$5"

  mkdir -p "${stage_root}/usr/local/lib/pkgconfig"
  if [ -f "${cross_build_dir}/Misc/python.pc" ]; then
    cp -a "${cross_build_dir}/Misc/python.pc" "${stage_root}/usr/local/lib/pkgconfig/python-${python_mm}.pc"
  else
    err "Expected cross-built python-${python_mm}.pc was not produced"
  fi

  if [ -f "${cross_build_dir}/Misc/python-embed.pc" ]; then
    cp -a "${cross_build_dir}/Misc/python-embed.pc" "${stage_root}/usr/local/lib/pkgconfig/python-${python_mm}-embed.pc"
  fi

  python_stage_finalize "${target_arch}" "${stage_root}" "${python_mm}" "${target_triplet}"
}

build_cross_target_python_payload() {
  local source_dir="$1"
  local target_arch="$2"
  local python_mm="${PYTHON_MAJOR_MINOR}"
  local target_triplet build_triplet build_python_bin build_python_libdir
  local cross_build_dir config_site stage_root

  target_triplet="$(arch_deb_multiarch_triplet_for "${target_arch}")"
  build_triplet="$(build_deb_multiarch_triplet)"
  build_python_bin="/usr/local/bin/python${python_mm}"
  build_python_libdir="/usr/local/lib"
  cross_build_dir="${TMPDIR:-/tmp}/Python-${PYTHON_VERSION}-cross-${target_triplet}-$$"
  config_site="${TMPDIR:-/tmp}/python-config-site-${target_triplet}-$$"
  stage_root="$(python_cross_stage_root_for_arch "${target_arch}")"

  _python_cross_configure \
    "${source_dir}" "${target_arch}" "${python_mm}" "${target_triplet}" \
    "${build_triplet}" "${build_python_bin}" "${build_python_libdir}" \
    "${cross_build_dir}" "${config_site}" "${stage_root}"

  _python_cross_build \
    "${cross_build_dir}" "${target_arch}" "${python_mm}"

  _python_cross_install_staging \
    "${cross_build_dir}" "${stage_root}" "${python_mm}" "${source_dir}"

  _python_cross_fixup_libdynload \
    "${cross_build_dir}" "${stage_root}" "${python_mm}"

  _python_cross_stage_into_compiler \
    "${cross_build_dir}" "${stage_root}" "${python_mm}" \
    "${target_arch}" "${target_triplet}"
}

stage_requested_cross_python_payloads() {
  local raw_targets=""
  local normalized_targets=""
  local build_arch=""
  local target_arch=""

  if [ "${BUILD_MODE:-native}" != "cross" ]; then
    return 0
  fi

  raw_targets="$(cross_targets_effective_raw 2>/dev/null || printf '%s' "${CROSS_TARGETS:-}")"
  [ -n "${raw_targets}" ] || return 0

  normalized_targets="$(arch_list_csv_normalize "${raw_targets}")" || {
    err "Unsupported cross target list for Python staging: ${raw_targets}"
  }
  build_arch="$(build_arch_oci 2>/dev/null || arch_oci)"

  rm -rf "${PYTHON_CROSS_STAGE_ROOT}"
  mkdir -p "${PYTHON_CROSS_STAGE_ROOT}"

  # Split via `IFS=',' read`, scoped to the builtin: this script's IFS=$'\n\t' means a
  # `${x//,/ }` expansion would NOT split, leaving one bogus multi-target arch.
  local -a _staging_targets=()
  IFS=',' read -r -a _staging_targets <<< "${normalized_targets}"
  for target_arch in "${_staging_targets[@]}"; do
    if [ "${target_arch}" = "${build_arch}" ]; then
      stage_host_python_payload "${target_arch}"
    else
      build_cross_target_python_payload "${PYTHON_SOURCE_DIR}" "${target_arch}"
    fi
  done
}

info "Building Python ${PYTHON_VERSION} from source..."

if [ "${BUILD_MODE:-native}" = "cross" ]; then
  info "Cross mode detected; building host Python ${PYTHON_VERSION} for shared build tooling"
fi

if [ -n "${PYTHON_TGZ_SHA256:-}" ]; then
  download_verified_file "https://www.python.org/ftp/python/${PYTHON_VERSION}/Python-${PYTHON_VERSION}.tgz" "${PYTHON_TGZ_SHA256}" "${PYTHON_TARBALL}"
else
  # FAIL CLOSED: a PYTHON_VERSION bump that forgets the hash must break loudly here,
  # never silently fetch the interpreter unverified.
  echo "ERROR: PYTHON_TGZ_SHA256 unset — refusing to download the CPython source unverified." >&2
  echo "       Bump PYTHON_TGZ_SHA256 in versions.env together with PYTHON_VERSION." >&2
  exit 1
fi
tar -xf "${PYTHON_TARBALL}" -C "${TMPDIR:-/tmp}"

cd "${PYTHON_SOURCE_DIR}"
# AP5: native interpreter already builds with PGO (--enable-optimizations); add
# LTO too (safe/well-trodden natively). Same PYTHON_LTO=0 escape hatch as the
# cross path. Empty-array expansion is set -u safe (bash 4.4+).
_lto_args=()
[ "${PYTHON_LTO:-1}" = "1" ] && _lto_args=( --with-lto )
./configure --enable-shared --enable-optimizations "${_lto_args[@]}" --prefix=/usr/local
make -j"$(compute_jobs_with_mem_cap "" 2500)"
make altinstall

ln -sf "/usr/local/bin/python${PYTHON_MAJOR_MINOR}" /usr/local/bin/python3
ln -sf "/usr/local/bin/pip${PYTHON_MAJOR_MINOR}" /usr/local/bin/pip3

# Add the lib path to the system linker
echo "/usr/local/lib" > "/etc/ld.so.conf.d/python-${PYTHON_VERSION}.conf"
ldconfig

stage_requested_cross_python_payloads

# Clean up
cd /
apt-get clean
rm -rf /var/lib/apt/lists/*

info "Python ${PYTHON_VERSION} built and installed successfully."
