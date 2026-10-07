#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

: "${PYTHON_LTO:=1}"
# PGO on the native builds; PYTHON_PGO=0 is an iteration escape hatch, never the image's setting.
: "${PYTHON_PGO:=1}"
# gil is /usr/local; freethreaded is its --disable-gil twin in /opt/python-freethreaded. docs/consumer-image-contract.md#the-free-threaded-python
: "${PYTHON_VARIANTS:=gil,freethreaded}"

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
# Loaded intolerantly: a missing deb822 writer must fail here, not in the middle of the apt rewrite.
source_module ubuntu-mirror.sh
source_module cross-env.sh || true
source_module logging.sh || true
source_module parallelism.sh || true
source_module downloads.sh
# The CPython dev-package table package-lists.sh and smoke-toolchain.sh also read.
source_module cpython-dev-packages.sh

install_err_trap

PYTHON_VERSION="${PYTHON_VERSION:-${1:-3.14.8}}"
PYTHON_MAJOR_MINOR="${PYTHON_MAJOR_MINOR:-$(version_major_minor "${PYTHON_VERSION}")}"
PYTHON_TARBALL="${TMPDIR:-/tmp}/Python-${PYTHON_VERSION}-$$.tgz"
PYTHON_SOURCE_DIR="${TMPDIR:-/tmp}/Python-${PYTHON_VERSION}"
PYTHON_CROSS_STAGE_ROOT="${PYTHON_CROSS_STAGE_ROOT:-/opt/python-cross}"
PYTHON_FT_PREFIX="${PYTHON_FT_PREFIX:-/opt/python-freethreaded}"
PYTHON_FT_CROSS_STAGE_ROOT="${PYTHON_FT_CROSS_STAGE_ROOT:-/opt/python-cross-ft}"
PYTHON_FT_SOURCE_PARENT="${TMPDIR:-/tmp}/Python-${PYTHON_VERSION}-ft-src"

cleanup() {
  rm -rf \
    "${PYTHON_SOURCE_DIR}" \
    "${PYTHON_FT_SOURCE_PARENT}" \
    "${PYTHON_TARBALL}" \
    "${TMPDIR:-/tmp}"/Python-"${PYTHON_VERSION}"-cross-* \
    "${TMPDIR:-/tmp}"/python-config-site-*
}

trap cleanup EXIT

# Sets the PY_* globals every build and staging helper reads; the gil values are the ones they hard-coded before.
python_variant_select() {
  case "$1" in
    gil)
      PY_VARIANT=gil
      PY_LDVERSION="${PYTHON_MAJOR_MINOR}"
      PY_PREFIX=/usr/local
      PY_STAGE_ROOT="${PYTHON_CROSS_STAGE_ROOT}"
      PY_SOURCE_DIR="${PYTHON_SOURCE_DIR}"
      PY_CONFIGURE_EXTRA=()
      ;;
    freethreaded)
      PY_VARIANT=freethreaded
      PY_LDVERSION="${PYTHON_MAJOR_MINOR}t"
      PY_PREFIX="${PYTHON_FT_PREFIX}"
      PY_STAGE_ROOT="${PYTHON_FT_CROSS_STAGE_ROOT}"
      PY_SOURCE_DIR="${PYTHON_FT_SOURCE_PARENT}/Python-${PYTHON_VERSION}"
      # _NODIST keeps the rpath out of sysconfig's LDFLAGS, so a cp314t wheel built against it inherits none.
      PY_CONFIGURE_EXTRA=( --disable-gil "LDFLAGS_NODIST=-Wl,-rpath,${PYTHON_FT_PREFIX}/lib" )
      # The tree ships in the image, where its fat-LTO libpython3.14t.a (155-435 MB per arch) links nothing.
      PY_CONFIGURE_EXTRA+=( --without-static-libpython )
      ;;
    *)
      err "Unknown CPython variant '$1' in PYTHON_VARIANTS (gil, freethreaded)"
      ;;
  esac
}

python_cross_stage_root_for_arch() {
  local target_arch="$1"

  printf '%s' "${PY_STAGE_ROOT}/$(arch_normalize "${target_arch}")"
}

python_cross_stage_prefix_for_arch() {
  local target_arch="$1"

  printf '%s' "$(python_cross_stage_root_for_arch "${target_arch}")${PY_PREFIX}"
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
  local prefix="${stage_root}${PY_PREFIX}"
  local pkgconfig_dir="${prefix}/lib/pkgconfig"

  mkdir -p "${prefix}/include/${target_triplet}/python${python_mm}"
  if [ -f "${prefix}/include/python${python_mm}/pyconfig.h" ]; then
    cp -a \
      "${prefix}/include/python${python_mm}/pyconfig.h" \
      "${prefix}/include/${target_triplet}/python${python_mm}/pyconfig.h"
  fi

  mkdir -p "${pkgconfig_dir}"
  fix_python_pc_file "${pkgconfig_dir}/python-${python_mm}.pc" "${PY_PREFIX}"
  fix_python_pc_file "${pkgconfig_dir}/python-${python_mm}-embed.pc" "${PY_PREFIX}"

  # Unversioned names mean the GIL build; the free-threaded tree answers only to its t names.
  if [ "${PY_VARIANT}" = gil ]; then
    if [ -x "${prefix}/bin/python${python_mm}" ]; then
      ln -sfn "python${python_mm}" "${prefix}/bin/python3"
      ln -sfn "python${python_mm}" "${prefix}/bin/python"
    fi

    if [ -x "${prefix}/bin/python${python_mm}-config" ]; then
      ln -sfn "python${python_mm}-config" "${prefix}/bin/python3-config"
    fi

    if [ -f "${pkgconfig_dir}/python-${python_mm}.pc" ]; then
      ln -sfn "python-${python_mm}.pc" "${pkgconfig_dir}/python3.pc"
    fi
    if [ -f "${pkgconfig_dir}/python-${python_mm}-embed.pc" ]; then
      ln -sfn "python-${python_mm}-embed.pc" "${pkgconfig_dir}/python3-embed.pc"
    fi
  fi

  info "Target Python ${python_mm} staged for ${target_arch}:"
  info "  prefix: $(python_cross_stage_prefix_for_arch "${target_arch}")"
  info "  include: ${prefix}/include/python${python_mm}"
  info "  arch include: ${prefix}/include/${target_triplet}/python${python_mm}"
  info "  libdir: ${prefix}/lib"
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
  # Its prefix holds nothing but this Python, so it stages whole, as hardlinks that cost the layer nothing.
  if [ "${PY_VARIANT}" = freethreaded ]; then
    mkdir -p "${stage_root}${PY_PREFIX}"
    cp -al "${PY_PREFIX}/." "${stage_root}${PY_PREFIX}/"
    # The cross trees are built with --disable-test-modules; the shipped build-arch tree matches them.
    rm -rf "${stage_root}${PY_PREFIX}/lib/python${PY_LDVERSION}/test"
    python_stage_finalize "${target_arch}" "${stage_root}" "${PY_LDVERSION}" "${target_triplet}"
    return 0
  fi
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

# The target arch gets its own apt source; ubuntu_arch_uses_ports picks archive or ports for both stanzas.
_python_cross_enable_multiarch_apt() {
  local target_arch="$1"
  local _codename _build_arch _host_url _target_url _target_file
  if ! dpkg --print-architecture 2>/dev/null | grep -qx "${target_arch}" && \
     ! dpkg --print-foreign-architectures 2>/dev/null | grep -qx "${target_arch}"; then
    dpkg --add-architecture "${target_arch}"
  fi
  _codename="$(. /etc/os-release && echo "${UBUNTU_CODENAME:-resolute}")"
  _build_arch="$(build_arch_oci 2>/dev/null || arch_oci)"
  # Reset once, by the first target; targets run in subshells, so the file itself is the marker.
  if [ ! -f /etc/apt/sources.list.d/ubuntu.sources ]; then
    rm -f /etc/apt/sources.list.d/*.sources /etc/apt/sources.list 2>/dev/null || true
    _host_url="$(ubuntu_default_archive_mirror_url)"
    ubuntu_arch_uses_ports "${_build_arch}" && _host_url="$(ubuntu_default_ports_mirror_url)"
    # Host and ports must agree on -security. docs/cross-build-verification.md#host-and-target-apt-sources-must-expose-the-same-pockets
    ubuntu_write_deb822_source /etc/apt/sources.list.d/ubuntu.sources \
      "${_host_url}" "${_codename}" "${_build_arch}" 1
  fi
  _target_file="$(cross_apt_sources_file_for_arch "${target_arch}")"
  if [ ! -f "${_target_file}" ]; then
    _target_url="$(ubuntu_default_archive_mirror_url)"
    ubuntu_arch_uses_ports "${target_arch}" && _target_url="$(ubuntu_default_ports_mirror_url)"
    ubuntu_write_deb822_source "${_target_file}" \
      "${_target_url}" "${_codename}" "${target_arch}" 1
    apt-get update -qq 2>&1 || warn "apt-get update failed; multiarch repos may be unavailable"
  fi
}

# Arch-qualified names: install_target_packages silently installs amd64 when TARGET_ARCH == BUILD_ARCH.
_python_cross_stage_target_dev_pkgs() {
  local target_arch="$1"
  local -a target_pkgs=() _pkg
  while IFS= read -r _pkg; do
    [ -n "${_pkg}" ] && target_pkgs+=("${_pkg}:${target_arch}")
  done < <(cpython_ext_dev_packages)
  # Host-arch libbz2-dev too: the build interpreter links bz2 during the cross configure probes.
  target_pkgs+=("libbz2-dev")
  apt-get install -y --no-install-recommends "${target_pkgs[@]}" 2>&1 || \
    warn "Some target dev packages failed to install; extension modules may be missing"

  # One atomic apt-get: an optional miss takes required packages down, so assert the outcome. docs/failure-modes.md
  local _req _missing=""
  while IFS= read -r _req; do
    [ -n "${_req}" ] || continue
    dpkg-query -W -f='${Status}' "${_req}:${target_arch}" 2>/dev/null \
      | grep -q "install ok installed" || _missing="${_missing} ${_req}"
  done < <(cpython_ext_dev_packages_required)
  if [ -n "${_missing}" ]; then
    err "CPython cross staging: REQUIRED target dev package(s) not installed for ${target_arch}:${_missing}"
    return 1
  fi
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
  # No -O default: CPython appends CFLAGS after its own -O3, so a default would silently downgrade it.
  export CFLAGS="${CFLAGS:-} -idirafter /usr/include -idirafter /usr/include/${target_triplet}"
  export CPPFLAGS="${CPPFLAGS:-} -idirafter /usr/include -idirafter /usr/include/${target_triplet}"
  export LDFLAGS="-L/usr/lib/${target_triplet} ${LDFLAGS:-}"
  export LIBRARY_PATH="/usr/lib/${target_triplet}:${LIBRARY_PATH:-}"
  # The free-threaded tree ships as the image's runtime interpreter, so it keeps _ctypes.
  local ffi_header_line='ac_cv_header_ffi_h=no'
  [ "${PY_VARIANT}" = gil ] || ffi_header_line=''
  cat > "${config_site}" <<EOF
ac_cv_buggy_getaddrinfo=no
ac_cv_file__dev_ptmx=yes
ac_cv_file__dev_ptc=no
${ffi_header_line}
ac_cv_header_bzlib_h=yes
ac_cv_lib_bz2_BZ2_bzlibVersion=yes
ac_cv_header_uuid_uuid_h=yes
EOF

  rm -f "${source_dir}/Python/frozen_modules/"*.h "${source_dir}/Python/frozen_modules/MANIFEST"
  make -C "${source_dir}" clean 2>/dev/null || true
  rm -f "${source_dir}/pyconfig.h" "${source_dir}/Makefile" "${source_dir}/python" "${source_dir}/Modules/Setup.local"
  rm -rf "${cross_build_dir}" "${stage_root}"
  mkdir -p "${cross_build_dir}/Python/frozen_modules" "${stage_root}"

  # PYTHON_LTO=0 escapes the fragile cross linker plugin; PGO would need the foreign interpreter.
  local -a _lto_args=()
  [ "${PYTHON_LTO}" = "1" ] && _lto_args=( --with-lto )

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
        --prefix="${PY_PREFIX}" \
        --with-build-python="${build_python_bin}" \
        --with-pkg-config=yes \
        --enable-shared \
        "${_lto_args[@]}" \
        "${PY_CONFIGURE_EXTRA[@]}" \
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

  # A copy of the build tree; make altinstall runs no target binary either, as the free-threaded twin's staging shows.

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

  # cp -L: CPython leaves relative symlinks into ../../Modules that would dangle once staged.
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

  _python_dynload_audit "${dynload_dir}"
}

_python_dynload_audit() {
  local dynload_dir="$1"

  # make -k can skip a failed extension silently; these have no external deps and must always build.
  local -a _critical_exts=(_struct math cmath _csv _json _pickle _socket)
  # What the image smoke imports from the shipped free-threaded interpreter must exist on every arch.
  if [ "${PY_VARIANT}" = freethreaded ]; then
    _critical_exts+=(_ssl _hashlib _sqlite3 zlib _bz2 _lzma _ctypes)
  fi
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

  # Warn-only, as the fatal assert is on the apt install; the GIL tree's _ctypes is off on purpose (ac_cv_header_ffi_h=no).
  while IFS= read -r _ext; do
    [ -n "${_ext}" ] || continue
    if ! ls "${dynload_dir}"/"${_ext}".cpython-*.so >/dev/null 2>&1 && \
       ! ls "${dynload_dir}"/"${_ext}".so >/dev/null 2>&1; then
      warn "Optional C extension missing: ${_ext} (target dev package may not be installed)"
    fi
  done < <(cpython_ext_modules)
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

# A real install into the stage, unlike the GIL tree's copy: this tree ships, so it needs its bytecode and config dir.
_python_cross_altinstall_staging() {
  local cross_build_dir="$1"
  local stage_root="$2"
  local target_arch="$3"
  local target_triplet="$4"

  make -C "${cross_build_dir}" altinstall DESTDIR="${stage_root}"
  if [ ! -x "${stage_root}${PY_PREFIX}/bin/python${PY_LDVERSION}" ] || \
     [ ! -f "${stage_root}${PY_PREFIX}/lib/libpython${PY_LDVERSION}.so.1.0" ]; then
    err "make altinstall staged no python${PY_LDVERSION} or libpython${PY_LDVERSION}.so.1.0 for ${target_arch}"
  fi
  _python_dynload_audit "${stage_root}${PY_PREFIX}/lib/python${PY_LDVERSION}/lib-dynload"
  python_stage_finalize "${target_arch}" "${stage_root}" "${PY_LDVERSION}" "${target_triplet}"
}

build_cross_target_python_payload() {
  local source_dir="$1"
  local target_arch="$2"
  local python_mm="${PY_LDVERSION}"
  local target_triplet build_triplet build_python_bin build_python_libdir
  local cross_build_dir config_site stage_root

  target_triplet="$(arch_deb_multiarch_triplet_for "${target_arch}")"
  build_triplet="$(build_deb_multiarch_triplet)"
  # The target's own variant: it freezes the stdlib modules the target embeds.
  build_python_bin="${PY_PREFIX}/bin/python${python_mm}"
  build_python_libdir="${PY_PREFIX}/lib"
  # The GIL build dir keeps its old name, which its debug info records.
  local dir_tag="ft-"
  if [ "${PY_VARIANT}" = gil ]; then dir_tag=""; fi
  cross_build_dir="${TMPDIR:-/tmp}/Python-${PYTHON_VERSION}-cross-${dir_tag}${target_triplet}-$$"
  config_site="${TMPDIR:-/tmp}/python-config-site-${target_triplet}-$$"
  stage_root="$(python_cross_stage_root_for_arch "${target_arch}")"

  _python_cross_configure \
    "${source_dir}" "${target_arch}" "${python_mm}" "${target_triplet}" \
    "${build_triplet}" "${build_python_bin}" "${build_python_libdir}" \
    "${cross_build_dir}" "${config_site}" "${stage_root}"

  _python_cross_build \
    "${cross_build_dir}" "${target_arch}" "${python_mm}"

  if [ "${PY_VARIANT}" = freethreaded ]; then
    _python_cross_altinstall_staging \
      "${cross_build_dir}" "${stage_root}" "${target_arch}" "${target_triplet}"
    return 0
  fi

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

  build_arch="$(build_arch_oci 2>/dev/null || arch_oci)"
  if [ "${BUILD_MODE:-native}" != "cross" ]; then
    # Dockerfile.package COPYs the free-threaded tree from here in either mode, so native stages its own arch.
    if [ "${PY_VARIANT}" = freethreaded ]; then
      rm -rf "${PY_STAGE_ROOT}"
      mkdir -p "${PY_STAGE_ROOT}"
      ( stage_host_python_payload "${build_arch}" )
    fi
    return 0
  fi

  raw_targets="$(cross_targets_effective_raw 2>/dev/null || printf '%s' "${CROSS_TARGETS:-}")"
  [ -n "${raw_targets}" ] || return 0

  normalized_targets="$(arch_list_csv_normalize "${raw_targets}")" || {
    err "Unsupported cross target list for Python staging: ${raw_targets}"
  }

  rm -rf "${PY_STAGE_ROOT}"
  mkdir -p "${PY_STAGE_ROOT}"

  # IFS=',' read: under this script's IFS=$'\n\t' a ${x//,/ } expansion would not split.
  local -a _staging_targets=()
  IFS=',' read -r -a _staging_targets <<< "${normalized_targets}"
  # One subshell per target: the cross setup appends to exported flags, which would leak into the next arch.
  for target_arch in "${_staging_targets[@]}"; do
    (
      if [ "${target_arch}" = "${build_arch}" ]; then
        stage_host_python_payload "${target_arch}"
      else
        build_cross_target_python_payload "${PY_SOURCE_DIR}" "${target_arch}"
      fi
    )
  done
}

# The selected variant for the build arch, from its own extraction of the verified tarball.
python_build_native_variant() {
  local -a _pgo_args=() _lto_args=()

  mkdir -p "${PY_SOURCE_DIR%/*}"
  tar -xf "${PYTHON_TARBALL}" -C "${PY_SOURCE_DIR%/*}"
  cd "${PY_SOURCE_DIR}"
  # Native gets PGO plus LTO, with the same PYTHON_LTO=0 escape hatch.
  [ "${PYTHON_PGO}" = "1" ] && _pgo_args=( --enable-optimizations )
  [ "${PYTHON_LTO}" = "1" ] && _lto_args=( --with-lto )
  ./configure --enable-shared "${_pgo_args[@]}" "${_lto_args[@]}" "${PY_CONFIGURE_EXTRA[@]}" --prefix="${PY_PREFIX}"
  make -j"$(compute_jobs_with_mem_cap "" 2500)"
  make altinstall

  if [ "${PY_VARIANT}" = freethreaded ]; then
    # The contract path; its prefix stays off PATH, so python3 and pip3 remain the GIL build's.
    ln -sf "${PY_PREFIX}/bin/python${PY_LDVERSION}" "/usr/local/bin/python${PY_LDVERSION}"
    return 0
  fi

  ln -sf "/usr/local/bin/python${PYTHON_MAJOR_MINOR}" /usr/local/bin/python3
  ln -sf "/usr/local/bin/pip${PYTHON_MAJOR_MINOR}" /usr/local/bin/pip3

  # "00-" is load-bearing: the first conf dir wins a duplicate soname, and the distro ships its own libpython.
  echo "/usr/local/lib" > "/etc/ld.so.conf.d/00-python-${PYTHON_VERSION}.conf"
  ldconfig
}

info "Building Python ${PYTHON_VERSION} from source (${PYTHON_VARIANTS})..."

if [ "${BUILD_MODE:-native}" = "cross" ]; then
  info "Cross mode detected; building host Python ${PYTHON_VERSION} for shared build tooling"
fi

if [ -n "${PYTHON_TGZ_SHA256:-}" ]; then
  download_verified_file "https://www.python.org/ftp/python/${PYTHON_VERSION}/Python-${PYTHON_VERSION}.tgz" "${PYTHON_TGZ_SHA256}" "${PYTHON_TARBALL}"
else
  # Fail closed: a version bump without its hash must never fetch CPython unverified.
  echo "ERROR: PYTHON_TGZ_SHA256 unset — refusing to download the CPython source unverified." >&2
  echo "       Bump PYTHON_TGZ_SHA256 in versions.env together with PYTHON_VERSION." >&2
  exit 1
fi

# IFS=',' read, as for the cross target list; each variant is a native build plus its cross stages.
IFS=',' read -r -a _python_variants <<< "${PYTHON_VARIANTS}"
for _python_variant in "${_python_variants[@]}"; do
  python_variant_select "${_python_variant}"
  python_build_native_variant
  stage_requested_cross_python_payloads
  cd /
  # The next variant extracts and builds its own trees, so the /tmp tmpfs holds one variant's at a time.
  rm -rf "${PY_SOURCE_DIR}" "${TMPDIR:-/tmp}"/Python-"${PYTHON_VERSION}"-cross-*
done

# Clean up
cd /
apt-get clean
rm -rf /var/lib/apt/lists/*

info "Python ${PYTHON_VERSION} built and installed successfully."
