#!/usr/bin/env bash
# Filesystem and backend-list fixtures do not prove real Clang code generation, linking or SDK acceptance.
set -u
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${TESTS_DIR}/test-harness.sh"
source "${TESTS_DIR}/../01-core/arch-mapping.sh"
t_private_tmpdir
work="$(t_mktemp -d)"
subject="${TESTS_DIR}/../02-toolchain/llvm.sh"
selection="$(t_fn_src "${subject}" llvm_selected_host_tool)" || exit 1
mapping="$(t_fn_src "${subject}" llvm_cross_backend)" || exit 1
backends="$(t_fn_src "${subject}" llvm_cross_build_backends)" || exit 1
eval "${selection//\/opt\/llvm-target-/${work}\/source LLVM-}"
eval "${mapping}"
eval "${backends}"
FAKE_BUILD_ARCH=amd64
FAKE_HOST_STATUS=0
build_arch_oci() {
    [ "${FAKE_HOST_STATUS}" -eq 0 ] || return "${FAKE_HOST_STATUS}"
    printf '%s' "${FAKE_BUILD_ARCH}"
}
_fixture_tool() {
    mkdir -p "${1%/*}"
    printf '#!/usr/bin/env bash\nexit 0\n' > "$1"
    chmod +x "$1"
}
for tool in clang clang++ clang-23 clang++-23; do _fixture_tool "${work}/bootstrap/${tool}"; done
PATH="${work}/bootstrap:${PATH}"
export CLANG_WANTED=23

t_case "source compilers win the versioned bootstrap on every supported build host"
for FAKE_BUILD_ARCH in amd64 arm64 riscv64; do
    for tool in clang clang++; do
        expected="${work}/source LLVM-${FAKE_BUILD_ARCH}/bin/${tool}"
        _fixture_tool "${expected}"
        t_assert_eq "${expected}" "$(llvm_selected_host_tool "${tool}")"
    done
done

t_case "a missing source install preserves the original versioned bootstrap selection"
FAKE_BUILD_ARCH=amd64
command rm -rf -- "${work}/source LLVM-amd64"
t_assert_eq "${work}/bootstrap/clang-23" "$(llvm_selected_host_tool clang)"
command rm -- "${work}/bootstrap/clang-23"
t_assert_eq "${work}/bootstrap/clang" "$(llvm_selected_host_tool clang)"

t_case "an incomplete source install cannot fall back to apt"
mkdir -p "${work}/source LLVM-amd64"
status=0
selected="$(llvm_selected_host_tool clang)" || status=$?
t_assert_eq 1 "${status}"
t_assert_eq '' "${selected}"

t_case "a dangling source prefix is an incomplete source install"
t_needs 'real symlinks' t_posix_symlinks
rmdir "${work}/source LLVM-amd64"
ln -s missing-source "${work}/source LLVM-amd64"
status=0
selected="$(llvm_selected_host_tool clang++)" || status=$?
t_assert_eq 1 "${status}"
t_assert_eq '' "${selected}"

t_case "failed host lookup retains its status instead of selecting a bootstrap"
FAKE_HOST_STATUS=47
status=0
selected="$(llvm_selected_host_tool clang)" || status=$?
t_assert_eq 47 "${status}"
t_assert_eq '' "${selected}"
FAKE_HOST_STATUS=0

t_case "native LLVM carries its host backend and every configured cross backend"
export CROSS_TARGETS=amd64,arm64,riscv64
while IFS='|' read -r FAKE_BUILD_ARCH expected; do
    t_assert_eq "${expected}" "$(llvm_cross_build_backends "${FAKE_BUILD_ARCH}")"
done <<'HOSTS'
amd64|X86;AArch64;RISCV
arm64|AArch64;X86;RISCV
riscv64|RISCV;X86;AArch64
HOSTS
FAKE_BUILD_ARCH=amd64
CROSS_TARGETS=arm64
t_assert_eq 'X86;AArch64' "$(llvm_cross_build_backends amd64)"
CROSS_TARGETS=riscv64,arm64,amd64,riscv64
t_assert_eq 'X86;RISCV;AArch64' "$(llvm_cross_build_backends amd64)"

t_case "foreign native installs keep only their target backend"
CROSS_TARGETS=amd64,arm64,riscv64
t_assert_eq AArch64 "$(llvm_cross_build_backends arm64)"
t_assert_eq RISCV "$(llvm_cross_build_backends riscv64)"
FAKE_BUILD_ARCH=arm64
t_assert_eq X86 "$(llvm_cross_build_backends amd64)"

t_case "a malformed native target set refuses before emitting a backend list"
CROSS_TARGETS=unsupported
t_assert_fails llvm_cross_build_backends arm64

t_case "backend selection retains failed host and normalization statuses"
FAKE_HOST_STATUS=47
status=0
llvm_cross_build_backends arm64 >/dev/null || status=$?
t_assert_eq 47 "${status}"
FAKE_HOST_STATUS=0
llvm_cross_backend() { return 61; }
CROSS_TARGETS=arm64
status=0
llvm_cross_build_backends arm64 >/dev/null || status=$?
t_assert_eq 61 "${status}"
status=0
llvm_cross_build_backends amd64 >/dev/null || status=$?
t_assert_eq 61 "${status}"
arch_list_csv_normalize() { return 53; }
status=0
llvm_cross_build_backends arm64 >/dev/null || status=$?
t_assert_eq 53 "${status}"

t_case "the real configure state uses host-aware backend selection"
t_assert_contains "$(cat "${TESTS_DIR}/../02-toolchain/llvm-cross.sh")" '$(llvm_cross_build_backends "${target_label}")'

smoke_source="$(t_fn_src "${TESTS_DIR}/../06-packaging/smoke-toolchain.sh" check_cross_clang)" || exit 1
eval "${smoke_source}"
check_clang_version() { smoke_calls+=("version|$1|$2|$3"); }
validate_compiler_for_target() { smoke_calls+=("compile|$1|$2|$3|$4"); }
export LLVM_RELEASE=99.2.3
t_case "every Clang wrapper has the exact version and real target-compiler smoke dispatched"
for target in amd64 arm64 riscv64; do
    for tool in clang clang++; do _fixture_tool "${work}/bootstrap/${tool}-${target}"; done
    smoke_calls=()
    check_cross_clang "${target}"
    t_assert_eq 4 "${#smoke_calls[@]}"
    index=0
    for tool in clang clang++; do
        expected="${work}/bootstrap/${tool}-${target}"
        t_assert_eq "version|${expected}|99.2.3|${tool} (${target} wrapper)" "${smoke_calls[${index}]}"
        index=$((index + 1))
        t_assert_eq "compile|${expected}|${target}|${tool} (${target} wrapper)|cross" "${smoke_calls[${index}]}"
        index=$((index + 1))
    done
done
t_case "the ordinary toolchain target loop runs the Clang wrapper smokes"
target_source="$(t_fn_src "${TESTS_DIR}/../06-packaging/smoke-toolchain.sh" smoke_target)" || exit 1
t_assert_contains "${target_source}" 'check_cross_clang "${target_arch}"'
t_case "the unconditional wrapper smoke retains compiler and version callback failures"
for callback in check_clang_version validate_compiler_for_target; do
    status=0
    bash -ec "${smoke_source}"$'\ncheck_clang_version() { return 0; }\nvalidate_compiler_for_target() { return 0; }\nLLVM_RELEASE=99.2.3\neval "$1() { return 47; }"\ncheck_cross_clang amd64' _ "${callback}" || status=$?
    t_assert_eq 47 "${status}"
done
t_case "ordinary installation binds wrappers after the source build has populated its prefix"
lifecycle_source="$(t_fn_src "${subject}" install_llvm_clang)" || exit 1
eval "${lifecycle_source}"
FAKE_BUILD_ARCH=amd64
command rm -f -- "${work}/source LLVM-amd64"
export TARGET_ARCH=amd64 LLVM_INSTALL_PROFILE=minimal DISTRO=fixture
lifecycle_calls=()
llvm_repo_available() { return 0; }
cross_mode_requested() { return 0; }
install_llvm_clang_minimal() { lifecycle_calls+=(bootstrap); }
register_versioned_llvm_binaries() { lifecycle_calls+=(alternatives); }
tool_version() { :; }
log() { :; }
install_cross_llvm_runner_tools() { lifecycle_calls+=(runners); }
build_cross_llvm_targets() {
    lifecycle_calls+=(build)
    _fixture_tool "${work}/source LLVM-amd64/bin/clang"
}
install_cross_clang_wrappers() { lifecycle_calls+=("wrappers|$(llvm_selected_host_tool clang)"); }
install_llvm_clang
t_assert_eq "bootstrap alternatives runners build wrappers|${work}/source LLVM-amd64/bin/clang" "${lifecycle_calls[*]}"

t_case "a failed source build cannot publish completed cross wrappers"
lifecycle_setup="$(declare -f llvm_repo_available cross_mode_requested install_llvm_clang_minimal register_versioned_llvm_binaries tool_version log install_cross_llvm_runner_tools)"
status=0
bash -ec "${lifecycle_source}"$'\n'"${lifecycle_setup}"$'\nlifecycle_calls=()\narch_normalize() { printf "%s" "$1"; }\nbuild_cross_llvm_targets() { return 47; }\ninstall_cross_clang_wrappers() { printf "invalid-wrapper-publication"; }\ninstall_llvm_clang' > "${work}/failed-install.log" 2>&1 || status=$?
t_assert_eq 47 "${status}"
t_assert_no_grep "${work}/failed-install.log" invalid-wrapper-publication

t_summary
