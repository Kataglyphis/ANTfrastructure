#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Use shared module loader instead of ad-hoc _source_first().
# Tries /opt/scripts first (container layout), then repo layout.
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
source_module cross-env.sh || true
source_module logging.sh || true
source_module parallelism.sh || true

install_err_trap

PYTHON_VERSION="${PYTHON_VERSION:-${1:-3.14.6}}"
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

# Source the shared fix_python_pc_file() from its canonical location.
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

build_cross_target_python_payload() {
  local source_dir="$1"
  local target_arch="$2"
  local python_mm="${PYTHON_MAJOR_MINOR}"
  local target_triplet build_triplet build_python_bin build_python_libdir
  local cross_build_dir config_site pkg_config_libdir stage_root
  local ext_build_dir

  target_triplet="$(arch_deb_multiarch_triplet_for "${target_arch}")"
  build_triplet="$(build_deb_multiarch_triplet)"
  build_python_bin="/usr/local/bin/python${python_mm}"
  build_python_libdir="/usr/local/lib"
  cross_build_dir="${TMPDIR:-/tmp}/Python-${PYTHON_VERSION}-cross-${target_triplet}-$$"
  config_site="${TMPDIR:-/tmp}/python-config-site-${target_triplet}-$$"
  stage_root="$(python_cross_stage_root_for_arch "${target_arch}")"

  info "Cross mode detected; building target Python ${python_mm} for ${target_arch} (${target_triplet})"

  if [ ! -x "${build_python_bin}" ]; then
    err "Expected build Python ${build_python_bin} was not found"
  fi

  prepare_cross_target_env "${target_arch}" "cross Python ${target_arch} staging"
  install_target_packages zlib1g-dev libbz2-dev liblzma-dev libzstd-dev libffi-dev libssl-dev || \
    warn "Some target dev packages failed to install; extension modules may be missing"
  pkg_config_libdir="$(cross_pkg_config_libdir "${target_triplet}")"
  export CFLAGS="${CFLAGS:--O2} -idirafter /usr/include -idirafter /usr/include/${target_triplet}"
  export CPPFLAGS="${CPPFLAGS:-} -idirafter /usr/include -idirafter /usr/include/${target_triplet}"
  cat > "${config_site}" <<EOF
ac_cv_buggy_getaddrinfo=no
ac_cv_file__dev_ptmx=yes
ac_cv_file__dev_ptc=no
ac_cv_header_ffi_h=no
EOF

  rm -f "${source_dir}/Python/frozen_modules/"*.h "${source_dir}/Python/frozen_modules/MANIFEST"
  make -C "${source_dir}" clean 2>/dev/null || true
  rm -f "${source_dir}/pyconfig.h" "${source_dir}/Makefile" "${source_dir}/python" "${source_dir}/Modules/Setup.local"
  rm -rf "${cross_build_dir}" "${stage_root}"
  mkdir -p "${cross_build_dir}/Python/frozen_modules" "${stage_root}"

  (
    cd "${cross_build_dir}"
    CONFIG_SITE="${config_site}" \
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
        --without-ensurepip \
        --disable-test-modules
  )

  (
    cd "${cross_build_dir}"
    make -k -j"$(compute_jobs_with_mem_cap "" 2500)" 2>&1 || true
  )

  if [ ! -x "${cross_build_dir}/python" ] || [ ! -f "${cross_build_dir}/libpython${python_mm}.so.1.0" ]; then
    err "target Python cross build for ${target_arch} did not produce the critical binary or shared library"
  fi

  # Stage the cross-built interpreter binary and libraries into the
  # per-architecture root. Do not run `make altinstall` because --
  # with-build-python already sets PYTHON_FOR_BUILD for compileall,
  # --without-ensurepip removes the pip bootstrap, and the target
  # Python binary itself cannot execute on the build host without
  # QEMU. Copying from the build tree is deterministic and avoids
  # depending on HOSTRUNNER availability in the container.

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

  # CPython 3.14's Makefile-based extension build does not place the real
  # extension shared objects under build/lib.linux-*/. Instead it builds them
  # into ${cross_build_dir}/Modules/ and leaves *relative symlinks*
  # (e.g. ../../Modules/_struct.cpython-*.so) inside build/lib.linux-*/.
  # A plain `cp -a` preserves those symlinks, so the installed lib-dynload ends
  # up full of dangling links (../../Modules resolves to <prefix>/lib/Modules,
  # which never gets installed). The result is a target Python that cannot load
  # ANY C extension (import _struct -> ModuleNotFoundError) once it runs under
  # QEMU in the runtime/torch stage. Dereference symlinks (-L) so the real .so
  # files land in lib-dynload.
  local dynload_dir="${stage_root}/usr/local/lib/python${python_mm}/lib-dynload"
  mkdir -p "${dynload_dir}"
  for ext_build_dir in "${cross_build_dir}/build/lib.linux"*; do
    if [ -d "${ext_build_dir}" ]; then
      cp -a -L "${ext_build_dir}/." "${dynload_dir}/"
    fi
  done

  # Safety net: copy the real extension shared objects straight from the build
  # Modules directory in case build/lib.linux-*/ was empty or only held links.
  if [ -d "${cross_build_dir}/Modules" ]; then
    find "${cross_build_dir}/Modules" -maxdepth 1 -name '*.so' \
      -exec cp -a -L {} "${dynload_dir}/" \;
  fi

  # Final guard: refuse to ship a target Python whose lib-dynload still contains
  # dangling extension symlinks (this is what silently broke foreign-arch torch).
  if find "${dynload_dir}" -xtype l 2>/dev/null | grep -q .; then
    while read -r symlink; do warn "dangling: ${symlink}"; done < <(find "${dynload_dir}" -xtype l 2>/dev/null || true)
    err "dangling extension symlinks remain in ${dynload_dir} after staging"
  fi

  # Guard: refuse to ship a target Python missing critical C extensions.
  # make -k || true above can silently skip failed extension builds; the
  # dangling-symlink check only catches broken links, not missing files.
  # These extensions have no external dependencies and must always build.
  local -a _critical_exts=(_struct math cmath _csv _io _json _pickle _socket)
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

  # Warn about missing optional extensions (depend on target dev packages).
  local -a _optional_exts=(zlib bz2 _lzma _ssl _hashlib)
  for _ext in "${_optional_exts[@]}"; do
    if ! ls "${dynload_dir}"/"${_ext}".cpython-*.so >/dev/null 2>&1 && \
       ! ls "${dynload_dir}"/"${_ext}".so >/dev/null 2>&1; then
      warn "Optional C extension missing: ${_ext} (target dev package may not be installed)"
    fi
  done

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

  for target_arch in ${normalized_targets//,/ }; do
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

wget --tries=5 --retry-connrefused --timeout=30 -q "https://www.python.org/ftp/python/${PYTHON_VERSION}/Python-${PYTHON_VERSION}.tgz" -O "${PYTHON_TARBALL}"
tar -xf "${PYTHON_TARBALL}" -C /tmp

cd "${PYTHON_SOURCE_DIR}"
./configure --enable-shared --enable-optimizations --prefix=/usr/local
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
