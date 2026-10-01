#!/usr/bin/env bash
# The image runs lavapipe with 8-lane subgroups on every arch (CON44); recorded probe text, so the in-image vulkaninfo call itself is not run here.
set -u
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${TESTS_DIR}/test-harness.sh"
PKGF="${TESTS_DIR}/../../Dockerfile.package"
RT_SMOKE="${TESTS_DIR}/../06-packaging/smoke-runtime-image.sh"

t_case "the package stage sets LP_NATIVE_VECTOR_WIDTH=256 for every arch, where the wrapper inherits it"
_pkg_stage="$(sed -n '/^FROM \${PACKAGE_BASE_STAGE} AS package$/,/^FROM /p' "${PKGF}")"
t_assert_contains "${_pkg_stage}" $'\nENV LP_NATIVE_VECTOR_WIDTH=256\n' "an arm64 lavapipe draw that builds an acceleration structure SEGVs at 128"
t_assert_eq "1" "$(grep -c 'LP_NATIVE_VECTOR_WIDTH' "${PKGF}")" "one unconditional ENV, no per-arch ARG that could empty it"

_SB="$(t_rt_sandbox)"; trap 'rm -rf "${_SB}"' EXIT
# $1 = arch, $2 = what the in-image probe printed.
_lvp() { t_rt_recorded "${_SB}" "$2" check_lavapipe_subgroup img "$1"; }

t_case "the smoke runs the lavapipe check"
t_assert_contains "$(t_fn_src "${RT_SMOKE}" main)" 'check_lavapipe_subgroup "${image_tag}" "${target_arch}"'

t_case "256 bits and 8-lane subgroups pass on every arch"
for _a in amd64 arm64 riscv64; do
  t_assert_contains "$(_lvp "${_a}" $'WIDTH 256\nSUBGROUP 8')" "FAILURES=0" "${_a}"
done

t_case "the variable missing from the image fails, even where the CPU's default is 256"
t_assert_contains "$(_lvp amd64 $'WIDTH unset\nSUBGROUP 8')" "FAILURES=1" "amd64's AVX2 default hides it"
t_assert_contains "$(_lvp arm64 $'WIDTH 128\nSUBGROUP 4')" "FAILURES=1" "the measured arm64 default"

t_case "4-lane subgroups fail even with the variable set (the cause, not the knob)"
_out="$(_lvp riscv64 $'WIDTH 256\nSUBGROUP 4')"
t_assert_contains "${_out}" "FAILURES=1"
t_assert_contains "${_out}" "subgroupSize '4'"

t_case "no lavapipe, or no answer from vulkaninfo, is not a pass"
t_assert_contains "$(_lvp arm64 $'WIDTH 256\nNO_LVP')" "FAILURES=1" "no ICD"
t_assert_contains "$(_lvp arm64 'WIDTH 256')" "FAILURES=1" "vulkaninfo printed nothing"

t_case "the image-env gate accepts the variable: it names nothing outside the container"
t_assert_ok python3 "${TESTS_DIR}/../verify_image_env.py" --env-file <(echo LP_NATIVE_VECTOR_WIDTH=256) --label probe

t_summary
