#!/usr/bin/env bash
# Filesystem fixtures prove ordering, publication and raw failures; not ELF ABI, real loader selection or image/GPU acceptance.
set -u
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${TESTS_DIR}/test-harness.sh"
source "${TESTS_DIR}/../06-packaging/media-payloads.sh"
t_source_functions "${TESTS_DIR}/../06-packaging/copy-media-payloads.sh" publish_rocm_ld_path || exit 1
t_private_tmpdir
work="$(t_mktemp -d)"
image="${work}/image with spaces"
mkdir -p "${image}/etc/ld.so.conf.d"
for path in migraphx/lib migraphx/lib64 extras-10/lib/migraphx core/lib lib lib64 core-asan-10/lib; do
  mkdir -p "${image}/opt/rocm/${path}"
done
for path in migraphx/lib extras-10/lib/migraphx core-asan-10/lib; do
  : >"${image}/opt/rocm/${path}/libmigraphx_c.so.2"
done
: >"${image}/opt/rocm/core/lib/libamdhip64.so.10"
expected=$'/opt/rocm/migraphx/lib\n/opt/rocm/migraphx/lib64\n/opt/rocm/core/lib\n/opt/rocm/extras-10/lib/migraphx\n/opt/rocm/lib\n/opt/rocm/lib64'
t_case 'source directories lead before the lexically earlier distro extras; duplicates and ASAN stay absent'
t_assert_eq "${expected}" "$(media_rocm_library_paths "${image}")"
t_assert_eq 1 "$(media_rocm_library_paths "${image}" | grep -c -x -e /opt/rocm/migraphx/lib)"
t_case 'the shipped 000-rocm configuration uses that complete order and image-relative paths'
t_assert_ok publish_rocm_ld_path "${image}"
t_assert_eq "${expected}" "$(cat "${image}/etc/ld.so.conf.d/000-rocm.conf")"
t_case 'a command-line ROCm symlink is followed while ASAN remains excluded'
mv "${image}/opt/rocm" "${image}/opt/rocm-10"
ln -s rocm-10 "${image}/opt/rocm"
t_assert_eq "${expected}" "$(media_rocm_library_paths "${image}")"
t_case 'an absent source prefix preserves the existing HIP, extras and legacy directories'
command rm -r -- "${image}/opt/rocm/migraphx"
t_assert_eq $'/opt/rocm/core/lib\n/opt/rocm/extras-10/lib/migraphx\n/opt/rocm/lib\n/opt/rocm/lib64' "$(media_rocm_library_paths "${image}")"
t_case 'CPU images publish no ROCm path and remove a stale configuration'
empty="${work}/empty image"
mkdir -p "${empty}/etc/ld.so.conf.d"
printf 'stale\n' >"${empty}/etc/ld.so.conf.d/000-rocm.conf"
t_assert_eq '' "$(media_rocm_library_paths "${empty}")"
t_assert_ok publish_rocm_ld_path "${empty}"
t_assert_fails test -e "${empty}/etc/ld.so.conf.d/000-rocm.conf"

_probe_failure() (
  find() { printf 'required path scan failed\n' >&2; return 37; }
  media_rocm_library_paths "${image}"
)
_sort_failure() (
  sort() { printf 'required ordering failed\n' >&2; return 41; }
  media_rocm_library_paths "${image}"
)
t_case 'failed discovery and ordering retain raw status and diagnostics'
out='' raw=125
t_capture_command out raw _probe_failure
t_assert_eq 37 "${raw}"
t_assert_contains "${out}" 'required path scan failed'
t_capture_command out raw _sort_failure
t_assert_eq 41 "${raw}"
t_assert_contains "${out}" 'required ordering failed'
_publish_failure() (
  find() { printf 'required path scan failed\n' >&2; return 37; }
  if publish_rocm_ld_path "${image}"; then return 0; else return "$?"; fi
)
t_case 'conditional callers retain discovery failure without truncating the existing configuration'
printf 'healthy\n' >"${image}/etc/ld.so.conf.d/000-rocm.conf"
t_assert_rc 37 _publish_failure
t_assert_eq healthy "$(cat "${image}/etc/ld.so.conf.d/000-rocm.conf")"
t_case 'a required output failure remains fatal'
command rm -- "${image}/etc/ld.so.conf.d/000-rocm.conf"
mkdir "${image}/etc/ld.so.conf.d/000-rocm.conf"
t_assert_fails publish_rocm_ld_path "${image}"
t_case 'the regular copy entry point executes the ROCm publisher'
t_assert_contains "$(t_fn_src "${TESTS_DIR}/../06-packaging/copy-media-payloads.sh" main)" '  publish_rocm_ld_path'
t_summary
