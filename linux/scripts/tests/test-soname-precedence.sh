#!/usr/bin/env bash
# Tests for the soname-precedence gate in 06-packaging/smoke-runtime-image.sh.
# Owner rule: our /opt build must win the ld.so lookup over any distro rival.
# The BAD case below is what the shipped arm64 image actually did on 2026-09-01.
# See docs/cross-build-verification.md.
set -u
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${TESTS_DIR}/test-harness.sh"
SMOKE="${TESTS_DIR}/../06-packaging/smoke-runtime-image.sh"
eval "$(sed -n '/^_soname_verdicts()/,/^}/p' "${SMOKE}")"

_GST=libgstreamer-1.0.so.0

t_case "a distro copy winning the lookup FAILS"
t_assert_contains \
  "$(_soname_verdicts "SONAME ${_GST} /usr/lib/aarch64-linux-gnu/${_GST} /opt/gstreamer/lib")" \
  "BAD ${_GST}" "this is exactly what the 2026-09-01 image did"

t_case "our copy winning passes"
t_assert_contains \
  "$(_soname_verdicts "SONAME ${_GST} /opt/gstreamer/lib/${_GST} /opt/gstreamer/lib")" \
  "OK ${_GST}"

t_case "our OTHER prefix counts as ours: /usr/local, not just /opt"
# This exact line failed the 2026-09-01 riscv64 manifest run: libonnxruntime.so.1
# sits in /opt/opencv5/lib and resolves to our canonical /usr/local ORT install.
# The gate called that a distro win and stopped the chain.
t_assert_contains \
  "$(_soname_verdicts "SONAME libonnxruntime.so.1 /usr/local/lib/onnxruntime-cpu/lib/libonnxruntime.so.1 /opt/opencv5/lib")" \
  "OK libonnxruntime.so.1"

t_case "ArmNN counts too, now that it ships"
t_assert_contains \
  "$(_soname_verdicts "SONAME libarmnn.so.33 /opt/armnn/lib/libarmnn.so.33 /opt/armnn/lib")" \
  "OK libarmnn.so.33"

t_case "a probe that found nothing is NONE, never a silent pass"
t_assert_contains "$(_soname_verdicts "")" "NONE"
t_assert_contains "$(_soname_verdicts "PKG numpy")" "NONE" \
  "unrelated probe lines must not look like coverage"

t_case "the gate is wired into the smoke run"
t_assert_contains "$(cat "${SMOKE}")" 'check_soname_precedence "${image_tag}" "${target_arch}"'

t_case "every /opt tree with a distro rival gets a 000- prefixed ld.so conf"
_conf="$(cat "${TESTS_DIR}/../03-media/runtime/configure-runtime.sh")"
for _t in gstreamer ffmpeg opencv libcamera armnn; do
  t_assert_contains "${_conf}" "000-${_t}.conf" "${_t} must sort before the multiarch dir"
done

t_case "ArmNN + ACL actually reach the package image"
_pkg="$(cat "${TESTS_DIR}/../../Dockerfile.package")"
t_assert_contains "${_pkg}" "artifact-source /opt/armnn /opt/armnn" \
  "they were built and dropped here until 2026-09-01"
t_assert_contains "${_pkg}" "artifact-source /opt/acl /opt/acl"

t_summary
