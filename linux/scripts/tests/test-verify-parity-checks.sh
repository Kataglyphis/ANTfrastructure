#!/usr/bin/env bash
# verify-parity.sh reaches its checks only through "check_${name}", so each is extracted and run against a stub runtime.
set -u
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=linux/scripts/tests/lib-contract-fixture.sh
source "${TESTS_DIR}/lib-contract-fixture.sh"
source "${TESTS_DIR}/test-workspace-fixture.sh"
declare _work
t_fixture_workspace_init _work || exit 1
lc_init "${_work}" || exit 1
SCRIPT="${TESTS_DIR}/../06-packaging/verify-parity.sh"
declare out rc

{
  printf 'source %q\n' "${TESTS_DIR}/../01-core/logging.sh"
  sed -n '/^_VENV_ACTIVATE_PROLOGUE=/p' "${SCRIPT}"
  for _fn in container_exec container_exec_strip echo_header normalize_package_list normalize_pip_list \
             normalize_find_output run_diff_check check_files check_libs check_packages check_python; do
    t_fn_src "${SCRIPT}" "${_fn}" || exit 1
  done
} > "${_work}/parity.sh"
[ -n "$(sed -n '/^_VENV_ACTIVATE_PROLOGUE=/p' "${SCRIPT}")" ] || { echo "FAIL: the venv prologue left verify-parity.sh" >&2; exit 1; }

# The runtime answers `run --rm --entrypoint=/bin/bash <image> -lc <cmd>` from out/<image>.<kind>.
mkdir -p "${_work}/out" "${_work}/wd"
lc_stub nerdctl 'img="$4" cmd="$6" o="${0%/bin/*}/out"
case "${cmd}" in
  *"dpkg -l"*) kind=packages ;; *"pip list"*) kind=pip ;; *"*.so*"*) kind=libs ;; *"find /"*) kind=files ;; *) exit 9 ;;
esac
case "${cmd}" in *activate*) [ ! -e "${o}/${img}.no-venv" ] || exit 1 ;; esac
[ -f "${o}/${img}.${kind}" ] || exit 1
cat "${o}/${img}.${kind}"'
_answer() { printf '%s\n' "${@:3}" > "${_work}/out/$1.$2"; }
RUN='NO_COLOR=1 CONTAINER_BIN=nerdctl NATIVE_IMAGE=native CROSS_IMAGE=cross WORKDIR=wd DIFF_TOOL=diff VERBOSE=0'
# _verdict <check> <status> <text>: the check, run as verify-parity.sh would, ends with <status> and prints <text>.
_verdict() { lc_expect "$2" "$3" "${_work}/parity.sh" "${RUN}; check_$1"; }

t_case "check_files lists every file outside /proc, /sys and /dev and passes when the normalised trees agree"
_answer native files /usr/bin/python3 /tmp/build.log /usr/lib/a/__pycache__/m.pyc /etc/hostname
_answer cross files /usr/bin/python3 /etc/hostname /var/cache/apt/x
lc_reset
_verdict files 0 "PASS File trees match (2 files)"
t_assert_eq "nerdctl run --rm --entrypoint=/bin/bash native -lc find / \\( -path /proc -o -path /sys -o -path /dev \\) -prune -o -type f -print" \
  "$(lc_argv | sed -n 1p)"

t_case "check_files fails on a differing tree and on an image that lists nothing"
_answer cross files /usr/bin/python3 /etc/hostname /opt/extra
lc_call out rc "${_work}/parity.sh" "${RUN}; check_files"
t_assert_eq "1" "${rc}"
t_assert_contains "${out}" "FAIL File trees differ (+1 -0)"
t_assert_contains "${out}" "Run with --verbose to see full diff (diff file: wd/File trees.diff)"
lc_call out rc "${_work}/parity.sh" "${RUN} VERBOSE=1; check_files"
t_assert_contains "${out}" "> /opt/extra" "--verbose prints the diff itself"
: > "${_work}/out/native.files"
_verdict files 1 "Failed to list files from native image (empty or missing output)"

t_case "check_libs compares soname sets with the version folded, and only warns when an image lists none"
_answer native libs /usr/lib/libz.so.1.3.1 /opt/x/libort.so.1.31.0
_answer cross libs /opt/x/libort.so.1.30.0 /usr/lib/libz.so.1.3
_verdict libs 0 "PASS Shared library sets match (2 libraries)"
_answer cross libs /usr/lib/libz.so.1.3
_verdict libs 1 "FAIL Shared library sets differ (+0 -1)"
rm -f "${_work}/out/cross.libs"
_verdict libs 0 "Cannot list shared libs from cross image"

t_case "check_packages compares dpkg name and version, ignoring the architecture column and the header"
_dpkg_head=(Desired=Unknown "| Status=Not" "|/ Err?=(none)" "||/ Name Version Architecture Description" "+++-====")
_answer native packages "${_dpkg_head[@]}" "ii  zlib1g 1:1.3 amd64 compression" "ii  bash 5.3 amd64 shell"
_answer cross packages "${_dpkg_head[@]}" "ii  bash 5.3 arm64 shell" "ii  zlib1g 1:1.3 arm64 compression"
_verdict packages 0 "PASS All OS packages match (2 packages)"
_answer cross packages "${_dpkg_head[@]}" "ii  bash 5.2 arm64 shell" "ii  zlib1g 1:1.3 arm64 compression"
_verdict packages 1 "FAIL OS packages differ (+1 -1)"
rm -f "${_work}/out/cross.packages"
_verdict packages 1 "Failed to get packages from cross image"

t_case "check_python reads pip in the venv, falls back to the system pip, and only warns when neither answers"
_answer native pip "Package Version" "------- -------" "numpy 2.3.0" "torch 2.11.0+cpu"
_answer cross pip "Package Version" "------- -------" "torch 2.11.0+cpu" "numpy 2.3.0"
: > "${_work}/out/cross.no-venv"
lc_reset
_verdict python 0 "PASS All Python packages match (2 packages)"
t_assert_eq "3" "$(lc_argv | grep -c -e 'pip list' || true)" "native in its venv; cross tried there, then without"
t_assert_contains "$(lc_argv | sed -n 3p)" "nerdctl run --rm --entrypoint=/bin/bash cross -lc pip list --format=columns 2>/dev/null || pip3 list --format=columns"
_answer cross pip "Package Version" "------- -------" "torch 2.11.0+cpu" "numpy 2.2.6"
_verdict python 1 "FAIL Python packages differ (+1 -1)"
rm -f "${_work}/out/native.pip"
_verdict python 0 "Cannot extract Python packages from native image (venv may not exist)"

t_summary
