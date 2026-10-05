#!/usr/bin/env bash
# Sourced (no shell options): KATAGLYPHIS_LINKER=default|lld|mold for C/C++ (LDFLAGS) and host Rust links. docs/shared-script-libraries.md#linker-selectsh--an-opt-in-linker
[ -n "${_LINKER_SELECT_SH_LOADED:-}" ] && return 0
_LINKER_SELECT_SH_LOADED=1

_LINKER_SELECT_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_LINKER_SELECT_CORE_DIR="${_LINKER_SELECT_LIB_DIR}/../01-core"
# shellcheck source=./log-bootstrap.sh
source "${_LINKER_SELECT_LIB_DIR}/log-bootstrap.sh"
# shellcheck source=../01-core/downloads.sh
source "${_LINKER_SELECT_CORE_DIR}/downloads.sh"

# A subshell, so only the MOLD_LINUX_* pins leave versions.env; the environment still wins over the file.
_linker_select_load_mold_pin() {
  local pins line
  # shellcheck source=../01-core/load-versions-env.sh
  pins="$(source "${_LINKER_SELECT_CORE_DIR}/load-versions-env.sh" \
    && load_versions_env "${_LINKER_SELECT_CORE_DIR}/versions.env" && env | grep '^MOLD_LINUX_')" || return 0
  while IFS= read -r line; do
    if [[ -n "${line}" ]]; then export "${line%%=*}=${line#*=}"; fi
  done <<< "${pins}"
}

# <asset> <version> <sha256> <cache root>: the release tarball, unpacked into the cache root only once verified.
_linker_select_fetch_mold() {
  local asset="$1" version="$2" sha="$3" cache_root="$4" rc=0
  local tarball="${cache_root}/${asset}.tar.gz"
  info "ld.mold not on PATH; fetching pinned mold ${version}"
  mkdir -p "${cache_root}" || return 1
  # download_verified_file deletes a tarball whose checksum fails, so tar never sees unverified bytes.
  download_verified_file "https://github.com/rui314/mold/releases/download/v${version}/${asset}.tar.gz" "${sha}" "${tarball}" \
    && tar -xzf "${tarball}" -C "${cache_root}" || rc=$?
  rm -f "${tarball}"
  [[ "${rc}" -eq 0 ]] || warn "Fetching ${asset} failed (checksum mismatch, network error or a bad archive)."
  return "${rc}"
}

# ld.mold from PATH, else the pinned release in a version-keyed cache (LINKER_SELECT_CACHE_DIR); 1 when it cannot.
linker_select_ensure_mold() {
  command -v ld.mold >/dev/null 2>&1 && return 0
  _linker_select_load_mold_pin
  local version="${MOLD_LINUX_VERSION:-}" arch sha
  case "$(uname -m)" in
    x86_64|amd64) arch=x86_64; sha="${MOLD_LINUX_X86_64_SHA256:-}" ;;
    aarch64|arm64) arch=aarch64; sha="${MOLD_LINUX_AARCH64_SHA256:-}" ;;
    riscv64) arch=riscv64; sha="${MOLD_LINUX_RISCV64_SHA256:-}" ;;
    *) warn "No pinned mold release for $(uname -m)."; return 1 ;;
  esac
  if [[ -z "${version}" || -z "${sha}" ]]; then
    warn "No pinned mold version or SHA256 for ${arch} (MOLD_LINUX_* in versions.env)."
    return 1
  fi

  local asset="mold-${version}-${arch}-linux"
  local cache_root="${LINKER_SELECT_CACHE_DIR:-${TMPDIR:-/tmp}}"
  if [[ ! -x "${cache_root}/${asset}/bin/ld.mold" ]]; then
    _linker_select_fetch_mold "${asset}" "${version}" "${sha}" "${cache_root}" || return 1
  fi
  [[ -x "${cache_root}/${asset}/bin/ld.mold" ]] || { warn "ld.mold missing in ${cache_root}/${asset}/bin"; return 1; }
  export PATH="${cache_root}/${asset}/bin:${PATH}"
}

# mold reads clang's LTO bitcode only through LLVMgold.so; GCC's collect2 passes its own plugin.
_linker_select_clang_plugin() {
  local compiler driver
  for compiler in "${CC:-}" "${CXX:-}"; do
    [[ "${compiler}" == *clang* ]] || continue
    driver="$(command -v "${compiler}" 2>/dev/null)" || continue
    driver="$(readlink -f "${driver}")"
    if [[ -f "$(dirname "$(dirname "${driver}")")/lib/LLVMgold.so" ]]; then
      printf '%s\n' "$(dirname "$(dirname "${driver}")")/lib/LLVMgold.so"
      return 0
    fi
  done
  return 1
}

# Opt-in and loud: 2 for an unknown value, 1 when the linker cannot link; a silent fallback would make a measurement lie.
linker_select_env() {
  local want="${KATAGLYPHIS_LINKER:-default}"
  case "${want}" in
    default) return 0 ;;
    lld|mold) ;;
    *) warn "KATAGLYPHIS_LINKER must be default, lld or mold, not '${want}'"; return 2 ;;
  esac
  # Exported, so a child script that runs this again does not append the flags a second time.
  [[ "${_LINKER_SELECT_APPLIED:-}" == "${want}" ]] && return 0
  # Either one replaces the per-target flags set below without a word.
  if [[ -n "${RUSTFLAGS:-}" || -n "${CARGO_ENCODED_RUSTFLAGS:-}" ]]; then
    warn "KATAGLYPHIS_LINKER=${want} sets CARGO_TARGET_<host>_RUSTFLAGS, which RUSTFLAGS/CARGO_ENCODED_RUSTFLAGS would override; unset them"
    return 1
  fi
  if [[ "${want}" == mold ]]; then
    linker_select_ensure_mold || return 1
  fi

  local cc="${CC:-cc}" probe_dir
  probe_dir="$(mktemp -d)" || return 1
  # The probe proves the driver finds ld.<want> now, not an hour into the build.
  if ! printf 'int main(void) { return 0; }\n' | "${cc}" -x c - -fuse-ld="${want}" -o "${probe_dir}/probe" >/dev/null 2>&1; then
    rm -rf "${probe_dir}"
    warn "${cc} cannot link with -fuse-ld=${want} (is ld.${want} on PATH?)"
    return 1
  fi
  rm -rf "${probe_dir}"

  local flags="-fuse-ld=${want}" plugin
  if [[ "${want}" == mold ]] && plugin="$(_linker_select_clang_plugin)"; then
    flags+=" -Wl,-plugin,${plugin}"
  fi
  # CMake folds LDFLAGS into every CMAKE_*_LINKER_FLAGS at the FIRST configure; a reused build tree keeps its old flags.
  export LDFLAGS="${LDFLAGS:+${LDFLAGS} }${flags}"

  # The host target only: wasm32 and the Android targets keep their own linkers.
  local triple var rustflags_var
  if command -v rustc >/dev/null 2>&1; then
    triple="$(rustc -vV 2>/dev/null | sed -n 's/^host: //p')"
    if [[ -n "${triple}" ]]; then
      var="CARGO_TARGET_$(printf '%s' "${triple}" | tr 'a-z-' 'A-Z_')"
      export "${var}_LINKER=${cc}"
      rustflags_var="${var}_RUSTFLAGS"
      export "${rustflags_var}=${!rustflags_var:+${!rustflags_var} }-C link-arg=-fuse-ld=${want}"
    fi
  fi
  export _LINKER_SELECT_APPLIED="${want}"
  info "KATAGLYPHIS_LINKER=${want}: LDFLAGS='${LDFLAGS}'${triple:+, ${var}_LINKER=${cc}}"
}
