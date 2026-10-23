#!/usr/bin/env bash
# Fake compiler and builder fixtures cover invocation and failure contracts, not GCC compilation or ELF validation.
set -uo pipefail
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${TESTS_DIR}/test-harness.sh"
GCC_SH="${TESTS_DIR}/../02-toolchain/gcc.sh"
t_source_functions "${GCC_SH}" _gcc_invoke_cross_builder build_cross_gcc_for build_canadian_native_gcc_for
w="$(mktemp -d)"
trap 'rm -rf "${w}"' EXIT
export GCC_CROSS_BUILDER="${w}/fake builder" GCC_BUILDER_TRACE="${w}/trace" GCC_BUILDER_RC=0 JOBS=3
cat > "${GCC_CROSS_BUILDER}" <<'BUILDER'
printf '%s\n' "$@" > "${GCC_BUILDER_TRACE}.args"
printf '%s\n' "${PREFIX}" "${BUILD_DIR}" "${JOBS}" "${CC:-}" "${CXX:-}" "${ac_cv_prog_cc_works:-}" "${ac_cv_prog_CC_works:-}" "${ac_cv_prog_cxx_works:-}" > "${GCC_BUILDER_TRACE}.env"
exit "${GCC_BUILDER_RC}"
BUILDER

triplet=aarch64-linux-gnu
for host in '' "${triplet}"; do
  t_case "the shared launch preserves argument order and environment (host=${host:-build-host})"
  CC='fixture cc' CXX='fixture cxx' ac_cv_prog_cc_works=yes ac_cv_prog_CC_works=yes ac_cv_prog_cxx_works=yes \
    _gcc_invoke_cross_builder "${w}/prefix with spaces" "${w}/build with spaces" fixture-version "${triplet}" "${host}"
  expected=(--version fixture-version --target "${triplet}")
  if [ -n "${host}" ]; then expected+=(--host "${host}"); fi
  expected+=(--languages 'c,c++' --sysroot / --native-system-header-dir /usr/aarch64-linux-gnu/include --disable-bootstrap --ccache --skip-system-registration)
  t_assert_eq "$(printf '%s\n' "${expected[@]}")" "$(cat "${GCC_BUILDER_TRACE}.args")"
  t_assert_eq "$(printf '%s\n' "${w}/prefix with spaces" "${w}/build with spaces" 3 'fixture cc' 'fixture cxx' yes yes yes)" "$(cat "${GCC_BUILDER_TRACE}.env")"
done

t_case "unset job configuration retains the detected parallelism"
nproc() { printf 7; }
JOBS='' _gcc_invoke_cross_builder "${w}/prefix" "${w}/build" fixture-version "${triplet}"
unset -f nproc
t_assert_eq 7 "$(sed -n '3p' "${GCC_BUILDER_TRACE}.env")"

t_case "builder failure reaches a conditional caller without relying on errexit"
GCC_BUILDER_RC=29 t_assert_rc 29 _gcc_invoke_cross_builder "${w}/prefix" "${w}/build" fixture-version "${triplet}"

GCC_LAUNCH_FUNCTIONS="$(declare -f _gcc_invoke_cross_builder build_cross_gcc_for build_canadian_native_gcc_for)"
export GCC_LAUNCH_FUNCTIONS GCC_FIXTURE_ROOT="${w}" GCC_LINK_RC=0
mkdir -p "${w}/cross prefix/bin"
for tool in gcc g++ gcc-ar gcc-nm gcc-ranlib; do
  printf '#!/usr/bin/env bash\nexit "${GCC_LINK_RC:-0}"\n' > "${w}/cross prefix/bin/${triplet}-${tool}"
  chmod +x "${w}/cross prefix/bin/${triplet}-${tool}"
done

run_cross_case() {
  bash -euo pipefail -c '
    eval "$GCC_LAUNCH_FUNCTIONS"
    gcc_cross_scratch_root() { printf "%s" "$GCC_FIXTURE_ROOT"; }
    build_arch_oci() { printf amd64; }
    log() { :; }
    warn() { printf "%s\n" "$*" >&2; }
    die() { printf "%s\n" "$*" >&2; exit 93; }
    link_cross_binutils() { printf "binutils\n" >> "$GCC_BUILDER_TRACE.after"; }
    assert_gcc_elf_arch() { printf "elf %s\n" "$2" >> "$GCC_BUILDER_TRACE.after"; }
    if ! "$1" fixture-version "$GCC_FIXTURE_ROOT/cross prefix" aarch64-linux-gnu arm64; then exit 17; fi
  ' _ "$1"
}

t_case "both public builders fail before inspecting stale installed tools when the builder fails"
for builder in build_cross_gcc_for build_canadian_native_gcc_for; do
  rm -f "${GCC_BUILDER_TRACE}.after"
  rc=0
  output="$(GCC_BUILDER_RC=29 run_cross_case "${builder}" 2>&1)" || rc=$?
  t_assert_eq 93 "${rc}"
  if [ "${builder}" = build_cross_gcc_for ]; then
    t_assert_contains "${output}" 'Source cross GCC build FAILED for aarch64-linux-gnu'
  else
    t_assert_contains "${output}" 'Canadian native GCC build FAILED for arm64'
    t_assert_eq "$(printf '%s\n' /opt/gcc-fixture-version-native-arm64 "${w}/gcc-build-fixture-version-native-arm64" 3 "${w}/cross prefix/bin/${triplet}-gcc" "${w}/cross prefix/bin/${triplet}-g++" yes yes yes)" "$(cat "${GCC_BUILDER_TRACE}.env")"
  fi
  t_assert_ok test ! -e "${GCC_BUILDER_TRACE}.after"
done

t_case "cross GCC still validates its tools, links binutils and checks the build-host ELF"
t_assert_ok run_cross_case build_cross_gcc_for
t_assert_eq $'binutils\nelf amd64' "$(cat "${GCC_BUILDER_TRACE}.after")"

t_case "the Canadian link failure remains an explicit opt-in skip and never launches a builder"
rm -f "${GCC_BUILDER_TRACE}.args"
GCC_LINK_RC=23 GCC_CANADIAN_CROSS_SKIP_ON_LINK_FAILURE=1 t_assert_rc 17 run_cross_case build_canadian_native_gcc_for
t_assert_ok test ! -e "${GCC_BUILDER_TRACE}.args"
GCC_LINK_RC=23 GCC_CANADIAN_CROSS_SKIP_ON_LINK_FAILURE=0 t_assert_rc 93 run_cross_case build_canadian_native_gcc_for
unset GCC_CANADIAN_CROSS_SKIP_ON_LINK_FAILURE
t_summary
