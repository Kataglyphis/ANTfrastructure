#!/usr/bin/env bash
# setup-rocm-repo.sh's names, its one-release check and where MIGraphX lands, run as extracted code; see docs/linux-accelerator-images.md#the-rocm-release-is-in-every-package-name
set -u
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${TESTS_DIR}/test-harness.sh"
CORE="${TESTS_DIR}/../01-core"
SETUP="${CORE}/setup-rocm-repo.sh"
SETUP_TEXT="$(cat "${SETUP}")"
_FNS="$(t_fn_src "${SETUP}" rocm_packages)"$'\n'"$(t_fn_src "${SETUP}" rocm_foreign_releases)"
# _block <first line prefix> <last line prefix>: that top-level stretch of the script, verbatim.
_block() { awk -v a="$1" -v b="$2" 'index($0, a) == 1 {p = 1} p {print} p && index($0, b) == 1 {exit}' "${SETUP}"; }
_RESOLVE="$(_block '_rocm_ver="${ROCM_VERSION:-' 'mapfile -t _rocm_pkgs')"
_CHECK="$(_block '_rocm_foreign="$(dpkg-query' 'echo "rocm: every installed')"
_PINNED_ROCM="$(sed -n 's/^ROCM_VERSION=//p' "${CORE}/versions.env")"
_PINNED_MGX="$(sed -n 's/^MIGRAPHX_VERSION=//p' "${CORE}/versions.env")"

# _resolve [VAR=value...]: the script's own version resolution (versions.env from _RES_DIR), printing its apt arguments.
_resolve() {
  env -u ROCM_VERSION -u MIGRAPHX_VERSION "$@" bash -c "set -euo pipefail; _SETUP_ROCM_DIR='${_RES_DIR:-${CORE}}'"$'\n'"${_FNS}"$'\n'"${_RESOLVE}"$'\nprintf "%s\\n" "${_rocm_pkgs[@]}"' 2>&1
}
# _check <rocm release> <dpkg-query lines>: the script's own post-install check against a stubbed dpkg-query.
_check() {
  _ROCM_REL="$1" _DPKG_LINES="$2" bash -c 'set -euo pipefail; _rocm_ver="${_ROCM_REL}"
dpkg-query() { printf "%s\n" "${_DPKG_LINES}"; }'$'\n'"${_FNS}"$'\n'"${_CHECK}" 2>&1
}

t_case "ROCm 10.0: every name carries the release, and MIGraphX is pinned to its 10.0 build"
t_assert_eq "amdrocm-core-dev10.0
amdrocm-runtime-dev10.0
amdrocm-blas-dev10.0
amdrocm-dnn-dev10.0
amdrocm-hipblas-common-dev10.0
amdrocm-fft-dev10.0
amdrocm-rccl-dev10.0
amdrocm-sparse-dev10.0
amdrocm-solver-dev10.0
amdrocm-migraphx=2.17.0+rocm10.0.*
amdrocm-migraphx-dev=2.17.0+rocm10.0.*" "$(_resolve ROCM_VERSION=10.0 MIGRAPHX_VERSION=2.17.0)" \
  "a versionless amdrocm-core-dev resolved to 10.1.0-3 once 10.1 joined the rolling suite (2026-09-30)"

t_case "ROCm 10.1: MIGraphX was renamed, and the list is the one apt resolved to 262 x 10.1.0-3 + 2.18.0-1 (2026-10-07)"
t_assert_eq "amdrocm-core-dev10.1
amdrocm-runtime-dev10.1
amdrocm-blas-dev10.1
amdrocm-dnn-dev10.1
amdrocm-hipblas-common-dev10.1
amdrocm-fft-dev10.1
amdrocm-rccl-dev10.1
amdrocm-sparse-dev10.1
amdrocm-solver-dev10.1
amdrocm10-migraphx=2.18.0-*
amdrocm10-migraphx-dev=2.18.0-*" "$(_resolve ROCM_VERSION=10.1 MIGRAPHX_VERSION=2.18.0)" \
  "amdrocm-migraphx stops at 2.17.0+rocm10.0.0 and would pull the 10.0 libraries"

t_case "no env: the versions.env pins give a list with no versionless name"
_out="$(_resolve)"; _rc=$?
t_assert_eq "0" "${_rc}" "the pinned release must be one rocm_packages knows: ${_out}"
t_assert_contains "${_out}" "amdrocm-core-dev${_PINNED_ROCM}"
t_assert_contains "${_out}" "-migraphx=${_PINNED_MGX}"
t_assert_eq "" "$(grep -E '^amdrocm-[a-z-]+$' <<< "${_out}")" "every name carries the release or a version pin"

t_case "an unknown or malformed release fails before any apt argument exists"
_out="$(_resolve ROCM_VERSION=11.0 MIGRAPHX_VERSION=2.19.0)"; _rc=$?
t_assert_eq "1" "${_rc}" "an unknown release must stop the build"
t_assert_eq "ERROR: no MIGraphX package name known for ROCm 11.0; add it to rocm_packages" "${_out}" \
  "and print the reason, with no partial list behind it"
_out="$(_resolve ROCM_VERSION=10.0.1 MIGRAPHX_VERSION=2.17.0)"; _rc=$?
t_assert_eq "1" "${_rc}"
t_assert_contains "${_out}" "need ROCM_VERSION as X.Y" "10.0.1 would otherwise name packages that do not exist"
_RES_DIR="$(mktemp -d)"; echo "ROCM_VERSION=10.0" > "${_RES_DIR}/versions.env"
_out="$(_resolve)"; _rc=$?
t_assert_eq "1" "${_rc}" "a missing MIGRAPHX_VERSION must not reach apt as amdrocm-migraphx=+rocm10.0.*"
t_assert_contains "${_out}" "a MIGRAPHX_VERSION"
rm -rf "${_RES_DIR}"; unset _RES_DIR

t_case "the release check: only installed packages, and only the pinned release"
_clean="installed amdrocm-core-dev10.0
installed amdrocm-blas10.0-gfx1201
installed amdrocm10.0-gfx1100
installed amdrocm-asan10.0
installed amdrocm-migraphx
config-files amdrocm-core-dev10.1"
_out="$(_check 10.0 "${_clean}")"; _rc=$?
t_assert_eq "0" "${_rc}" "one tree passes: ${_out}"
t_assert_eq "rocm: every installed amdrocm package belongs to ROCm 10.0" "${_out}" \
  "a removed package's leftover config is no second tree"
_out="$(_check 10.0 "${_clean}
installed amdrocm-core-dev10.1
installed amdrocm-dnn10.1-gfx942")"; _rc=$?
t_assert_eq "1" "${_rc}" "a second tree must fail the build"
t_assert_contains "${_out}" $'another release:\namdrocm-core-dev10.1\namdrocm-dnn10.1-gfx942' "and name every package of it"
_out="$(_check 10.1 "installed amdrocm-core-dev10.10")"; _rc=$?
t_assert_eq "1" "${_rc}" "10.10 is not 10.1"
_out="$(_check 10.1 "installed amdrocm-core-dev10.1
installed amdrocm-blas10.1-gfx1201
installed amdrocm-asan10.1-gfx942
installed amdrocm10-migraphx
installed amdrocm10-migraphx-dev")"; _rc=$?
t_assert_eq "0" "${_rc}" "the 10.1 tree passes; amdrocm10-migraphx names a major, not a release: ${_out}"

t_case "the script installs that list and checks after every install"
t_assert_contains "${SETUP_TEXT}" 'apt-get install -y --no-install-recommends "${_rocm_pkgs[@]}"'
t_assert_contains "${SETUP_TEXT}" 'apt-get install -y --no-install-recommends "amdrocm-asan${_rocm_ver}"' \
  "the ASAN package is versioned too"
t_assert_eq "" "$(grep -nE '^[[:space:]]+amdrocm-[a-z-]+( \\)?$' "${SETUP}")" "no versionless name is listed by hand"
_asan_end="$(grep -n '^  echo "rocm-asan: installed beside' "${SETUP}" | cut -d: -f1)"
_check_at="$(grep -n '^_rocm_foreign="$(dpkg-query' "${SETUP}" | cut -d: -f1)"
_repo_rm="$(grep -n '^rm -f /etc/apt/sources.list.d/rocm.sources' "${SETUP}" | cut -d: -f1)"
t_assert_eq "yes" "$([ "${_asan_end:-0}" -lt "${_check_at:-0}" ] && [ "${_check_at:-0}" -lt "${_repo_rm:-0}" ] && echo yes)" \
  "the check sees the ASAN closure too, and runs while the build can still fail"

# MIGraphX's own prefix: /opt/rocm/lib up to 10.0, /opt/rocm/extras-10 from 10.1 (installed and listed 2026-10-07).
_LAYOUT="$(_block '# MIGraphX left /opt/rocm/lib' 'esac')"
_PUB="$(t_fn_src "${TESTS_DIR}/../06-packaging/copy-media-payloads.sh" publish_rocm_ld_path)" || exit 1
# _tree <root> <path>...: empty files (and their directories) under <root>.
_tree() { local r="$1" p; shift; for p in "$@"; do mkdir -p "${r}/$(dirname "${p}")"; : > "${r}/${p}"; done; }
# _root <path>...: a fresh root holding /opt/rocm/lib and those files, printed.
_root() { local r; r="$(mktemp -d)"; mkdir -p "${r}/opt/rocm/lib"; _tree "${r}" "$@"; printf '%s' "${r}"; }
# _under <root> <conf> <code>: the code with /opt/rocm and that conf file moved under <root>.
_under() { sed "s#/opt/rocm#${1}/opt/rocm#g; s#${2}#${1}/${2##*/}#g" <<< "$3"; }
# _layout <root>: the script's loader-path write and its MIGraphX checks, ldconfig answering from the conf it wrote.
_layout() {
  _R="$1" bash -c 'set -euo pipefail; hipcc() { :; }
ldconfig() { [ "${1:-}" = -p ] || return 0; local d f; while read -r d; do for f in "${d}"/libmigraphx_c.so.*; do if [ -e "${f}" ]; then printf "\t%s => %s\n" "${f##*/}" "${f}"; fi; done; done < "${_R}/rocm.conf"; }'$'\n'"$(_under "$1" /etc/ld.so.conf.d/rocm.conf "${_LAYOUT}")" 2>&1
}

t_case "setup-rocm-repo.sh puts MIGraphX's own lib dir on the loader path and checks it there"
_R101="$(_root opt/rocm/extras-10/lib/libmigraphx_c.so.3 opt/rocm/extras-10/include/migraphx/migraphx.hpp)"
_out="$(_layout "${_R101}")"; _rc=$?
t_assert_eq "0" "${_rc}" "the 10.1 layout passes: ${_out}"
t_assert_eq "${_R101}/opt/rocm/extras-10/lib
${_R101}/opt/rocm/lib" "$(cat "${_R101}/rocm.conf" 2>/dev/null)" \
  "/opt/rocm/lib is core's since 10.1, so libmigraphx_c resolved through nothing"
_R100="$(_root opt/rocm/lib/libmigraphx_c.so.3 opt/rocm/core/include/migraphx/migraphx.hpp)"
_out="$(_layout "${_R100}")"; _rc=$?
t_assert_eq "0" "${_rc}" "the 10.0 layout still passes: ${_out}"
t_assert_eq "${_R100}/opt/rocm/lib" "$(cat "${_R100}/rocm.conf" 2>/dev/null)" "one line when MIGraphX is in /opt/rocm/lib"
rm -f "${_R101:?}/opt/rocm/extras-10/lib/libmigraphx_c.so.3"
_out="$(_layout "${_R101}")"; _rc=$?
t_assert_eq "1" "${_rc}" "an EP library the loader cannot find must stop the build"
t_assert_contains "${_out}" "libmigraphx_c is on no loader path"
_tree "${_R101}" opt/rocm/extras-10/lib/libmigraphx_c.so.3
rm -rf "${_R101:?}/opt/rocm/extras-10/include"
_out="$(_layout "${_R101}")"; _rc=$?
t_assert_eq "1" "${_rc}"
t_assert_contains "${_out}" "migraphx.hpp not found" "no MIGraphX headers anywhere under /opt/rocm"
rm -rf "${_R101}" "${_R100}"

t_case "the ORT MIGraphX EP build hands ORT MIGraphX's own prefix, not the ROCm root"
AMD_ORT="${TESTS_DIR}/../03-media/build/onnxruntime/build/30-build-native-amd.sh"
_PREFIX="$(awk 'index($0, "_migraphx_config_dir=\"$(find") == 1 {p = 1} p {print} p && index($0, "_migraphx_prefix=") == 1 {exit}' "${AMD_ORT}")"
_prefix() { MIGRAPHX_HOME="$1" bash -c 'set -euo pipefail; err() { echo "ERR $*"; exit 1; }'$'\n'"${_PREFIX}"$'\necho "${_migraphx_prefix}"' 2>&1; }
_H="$(mktemp -d)"
_tree "${_H}" core-10.1/lib/cmake/hip/hip-config.cmake extras-10/lib/cmake/migraphx/migraphx-config.cmake
t_assert_eq "${_H}/extras-10" "$(_prefix "${_H}")" "find_package(migraphx PATHS /opt/rocm) misses extras-10 (CMake probe, 2026-10-07)"
rm -rf "${_H:?}/extras-10"; _tree "${_H}" lib/cmake/migraphx/migraphx-config.cmake
t_assert_eq "${_H}" "$(_prefix "${_H}")" "the 10.0 layout keeps the ROCm root"
rm -rf "${_H:?}/lib"
t_assert_contains "$(_prefix "${_H}")" "ERR MIGraphX not found" "no MIGraphX config fails before ORT's configure"
rm -rf "${_H}"
t_assert_contains "$(_prefix "${_H}")" "ERR MIGraphX not found" "a missing root says so, not a silent pipefail exit"
t_assert_contains "$(cat "${AMD_ORT}")" '--migraphx_home "${_migraphx_prefix}"' "and that prefix is what ORT gets"

t_case "the runtime's 000-rocm.conf carries MIGraphX's lib dir beside HIP's, and never the ASAN tree's"
# _published <root>: publish_rocm_ld_path over <root>, then the 000-rocm.conf it wrote.
_published() { bash -c 'set -euo pipefail'$'\n'"$(_under "$1" /etc/ld.so.conf.d/000-rocm.conf "${_PUB}")"$'\npublish_rocm_ld_path'; cat "$1/000-rocm.conf"; }
_RT="$(_root opt/rocm/{core,core-asan}-10.1/lib/libamdhip64.so.7 opt/rocm/extras-10/lib/libmigraphx_c.so.3)"
t_assert_eq "$(printf '%s\n' "${_RT}/opt/rocm/"{core-10.1/lib,extras-10/lib,lib})" "$(_published "${_RT}" 2>&1)" \
  "libonnxruntime_providers_migraphx.so needs libmigraphx_c.so.3 at run time; the ASAN libraries are preloaded by hand"
rm -rf "${_RT}"

t_summary
