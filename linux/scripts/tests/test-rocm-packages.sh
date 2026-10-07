#!/usr/bin/env bash
# setup-rocm-repo.sh's names and its one-release check, run as extracted code; see docs/linux-accelerator-images.md#the-rocm-release-is-in-every-package-name
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

t_case "MIGraphX was renamed with ROCm 10.1"
_out="$(_resolve ROCM_VERSION=10.1 MIGRAPHX_VERSION=2.18.0)"
t_assert_contains "${_out}" "amdrocm-core-dev10.1"
t_assert_contains "${_out}" $'amdrocm10-migraphx=2.18.0-*\namdrocm10-migraphx-dev=2.18.0-*' \
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

t_summary
