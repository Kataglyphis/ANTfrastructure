#!/usr/bin/env bash
# Every case pins BUILDARCH, or it asserts whatever machine runs it; see docs/linux-cross-builds.md#non-amd64-build-hosts
set -u
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${TESTS_DIR}/test-harness.sh"
source "${TESTS_DIR}/../01-core/platform.sh"

REPO_SCRIPTS="${TESTS_DIR}/.."
SWAP="${REPO_SCRIPTS}/06-packaging/swap-native-gcc.sh"
SMOKE_ANDROID="${REPO_SCRIPTS}/06-packaging/smoke-android.sh"
SMOKE_COMMON="${REPO_SCRIPTS}/06-packaging/smoke-common.sh"
ANDROID_SDK="${REPO_SCRIPTS}/02-toolchain/android-sdk.sh"

MARKER_PATH="/opt/android/.android-payload-off"

# ---------------------------------------------------------------------------
t_case "android_build_host_supported answers for the BUILD host, not the target"
BUILDARCH=amd64   t_assert_ok android_build_host_supported
BUILDARCH=arm64   t_assert_fails    android_build_host_supported
BUILDARCH=riscv64 t_assert_fails    android_build_host_supported

# BUILDPLATFORM alone must give the same answer, or a Dockerfile without `ARG BUILDARCH` takes the amd64 path.
_supported_via_buildplatform() {
  ( unset BUILDARCH; BUILDPLATFORM="$1" android_build_host_supported )
}
t_assert_ok _supported_via_buildplatform linux/amd64
t_assert_fails    _supported_via_buildplatform linux/arm64
t_assert_fails    _supported_via_buildplatform linux/riscv64

t_case "android_require_amd64_build_host names the scope it is skipping"
_require_msg="$(BUILDARCH=arm64 android_require_amd64_build_host "Android SDK/NDK installation" 2>&1)"
t_assert_eq "Skipping Android SDK/NDK installation on non-amd64 build host" "${_require_msg}"
BUILDARCH=arm64 t_assert_fails    android_require_amd64_build_host "X"
BUILDARCH=amd64 t_assert_ok android_require_amd64_build_host "X"

# swap-native-gcc.sh cannot complete without /opt/gcc-*, so the execution trace names the branch it took.
_swap_trace() {
  TARGET_ARCH="$1" BUILDARCH="$2" BUILD_MODE=cross GCC_VERSION=0.0.0 \
    bash -x "${SWAP}" 2>&1 | grep -E '^\+ (assert_elf_arch|_assert_and_relocate_native_gcc)'
}

t_case "swap-native-gcc keys its early return on the build host"
# Tripwire: an amd64 host targeting arm64 must still demand the Canadian cross prefix.
t_assert_contains "$(_swap_trace arm64 amd64)" "_assert_and_relocate_native_gcc /opt/gcc-0.0.0-native-arm64" \
  "the amd64 cross path must be unchanged"
t_assert_contains "$(_swap_trace riscv64 amd64)" "_assert_and_relocate_native_gcc /opt/gcc-0.0.0-native-riscv64"

# target == build host builds no native prefix, so the swap asserts the host GCC.
t_assert_contains "$(_swap_trace arm64 arm64)" "assert_elf_arch /opt/gcc-0.0.0/bin/gcc arm64" \
  "a native arm64 host must accept its own GCC, not demand a Canadian cross"
t_assert_contains "$(_swap_trace riscv64 riscv64)" "assert_elf_arch /opt/gcc-0.0.0/bin/gcc riscv64"
t_assert_contains "$(_swap_trace amd64 amd64)" "assert_elf_arch /opt/gcc-0.0.0/bin/gcc amd64" \
  "an amd64 host targeting amd64 keeps the historical behaviour"

# ...and must NOT have looked for a Canadian prefix at all.
_count() { printf '%s' "$1" | grep -c -- "$2" || true; }
t_assert_eq "0" "$(_count "$(_swap_trace arm64 arm64)" "native-arm64")" \
  "the native host must never reach _assert_and_relocate_native_gcc"

# The payload-off marker: producer checked structurally, reader run against a redirected copy.
t_case "the marker's producer and reader name the SAME path"
t_assert_contains "$(cat "${ANDROID_SDK}")" "${MARKER_PATH}" \
  "android-sdk.sh must write the marker"
t_assert_contains "$(cat "${SMOKE_ANDROID}")" "${MARKER_PATH}" \
  "smoke-android.sh must read the same literal the producer writes"

t_case "the marker is written inside the skip branch, not unconditionally"
# The write must sit between the guard and its `exit 0`, or amd64 stamps its own image payload-off.
_skip_branch="$(awk '/android_require_amd64_build_host "Android SDK\/NDK installation"/,/^fi$/' "${ANDROID_SDK}")"
t_assert_contains "${_skip_branch}" "${MARKER_PATH}"
t_assert_contains "${_skip_branch}" "build_host="

# smoke-android.sh copied beside smoke-common.sh with only the marker rewritten, so the real main() runs.
_SMOKE_DIR="$(mktemp -d)"
trap 'rm -rf "${_SMOKE_DIR}"' EXIT
cp "${SMOKE_COMMON}" "${_SMOKE_DIR}/smoke-common.sh"
sed "s|${MARKER_PATH}|${_SMOKE_DIR}/marker|g" "${SMOKE_ANDROID}" > "${_SMOKE_DIR}/smoke-android.sh"

t_case "smoke-android runs every check when no marker is present"
rm -f "${_SMOKE_DIR}/marker"
_no_marker="$(bash "${_SMOKE_DIR}/smoke-android.sh" 2>&1)"
t_assert_contains "${_no_marker}" "--- Android SDK root ---" \
  "an amd64 image has no marker, so the strict path must be unchanged"
t_assert_eq "0" "$(_count "${_no_marker}" "android payload off")"

t_case "smoke-android self-skips, green, on a recorded payload-off marker"
printf 'reason=Android NDK ships as prebuilt/linux-x86_64 only\nbuild_host=arm64\n' \
  > "${_SMOKE_DIR}/marker"
_with_marker="$(bash "${_SMOKE_DIR}/smoke-android.sh" 2>&1)"
_with_marker_rc=$?
t_assert_eq "0" "${_with_marker_rc}" "a payload-off image must not fail its own smoke"
t_assert_contains "${_with_marker}" "build_host=arm64" \
  "the smoke must echo WHY the payload is absent, not just skip silently"
for _c in sdk_root sdkmanager adb ndk build_tools android_cmake opencv; do
  t_assert_contains "${_with_marker}" "SKIP ${_c}"
done
t_assert_eq "0" "$(_count "${_with_marker}" -- "--- sdkmanager ---")" \
  "the strict checks must not run at all"

# No test asserts a --platform argument, so this literal count is what stops a revert to a frozen platform.
t_case "linux/amd64 survives in exactly one place: the accessor's own default"
# Code only: a comment may name the default, but no second place may decide it.
_count_lit() { grep -v '^[[:space:]]*#' "${REPO_SCRIPTS}/$1" | grep -c 'linux/amd64' || true; }
t_assert_eq "1" "$(_count_lit 01-core/platform.sh)" \
  "cross_build_platform owns the default; a second copy is a second answer"
for _f in 01-core/tag-naming.sh 01-core/stage-defs.sh 01-core/chain-verify.sh; do
  t_assert_eq "0" "$(_count_lit "${_f}")" \
    "${_f} must ask cross_build_platform, not freeze the platform"
done

t_case "the platform knob is EXPORTED, or the fix is inert where it is needed"
# `run env` forwards only exported vars; the regex accepts both the one-line and the two-line export.
t_assert_eq "1" "$(grep -cE '^export CROSS_BUILD_PLATFORM\b' "${REPO_SCRIPTS}/01-core/cross-stage-build.sh" || true)"

t_case "cross_build_platform reads the knob and defaults to the amd64 lane"
t_assert_eq "linux/amd64"  "$(cross_build_platform)"
t_assert_eq "linux/arm64"  "$(CROSS_BUILD_PLATFORM=linux/arm64 cross_build_platform)"
t_assert_eq "linux/amd64"  "$(BUILDARCH=riscv64 cross_build_platform)" \
  "the knob, never the host — an emulated build must describe itself honestly"

# LLVM_COMMIT makes the release a real pin: apt.llvm.org can ship a tree other than the one LLVM_RELEASE names.
t_case "llvm_assert_commit_pin has ONE owner and both clone sites call it"
_CORE="${REPO_SCRIPTS}/01-core"
t_assert_eq "1" "$(grep -c '^llvm_assert_commit_pin()' "${_CORE}/common.sh" || true)"
for _f in 02-toolchain/build-clang.sh 02-toolchain/llvm-cross.sh; do
  t_assert_eq "1" "$(grep -c 'llvm_assert_commit_pin ' "${REPO_SCRIPTS}/${_f}" || true)" \
    "${_f} must verify its checkout, not re-implement the check"
done

t_case "the pin is set, peeled, and matches LLVM_RELEASE's tag"
# Read, not sourced: sourcing versions.env under this suite's `set -u` can trip on its references.
_VERS="${_CORE}/versions.env"
_vers_val() { sed -n "s/^$1=//p" "${_VERS}" | head -1; }
t_assert_eq "23.1.1" "$(_vers_val LLVM_RELEASE)"
t_assert_eq "6dfe1677ab8dffbc6ec13d53a1e0215d75147689" "$(_vers_val LLVM_COMMIT)" \
  "refs/tags/llvmorg-23.1.1^{} — the PEELED sha, per the convention above the key"
t_assert_eq "40" "$(printf '%s' "$(_vers_val LLVM_COMMIT)" | wc -c | tr -d ' ')"

t_case "llvm_assert_commit_pin fails on a mismatch and is quiet when unset"
# shellcheck disable=SC1090
. "${_CORE}/common.sh" 2>/dev/null || true
_TMPGIT="$(mktemp -d)"
git -C "${_TMPGIT}" init -q 2>/dev/null
git -C "${_TMPGIT}" -c user.email=t@t -c user.name=t commit -q --allow-empty -m x 2>/dev/null
LLVM_COMMIT="" t_assert_ok llvm_assert_commit_pin "${_TMPGIT}" sometag
LLVM_COMMIT="0000000000000000000000000000000000000000" \
  t_assert_fails llvm_assert_commit_pin "${_TMPGIT}" sometag
_real="$(git -C "${_TMPGIT}" rev-parse HEAD)"
LLVM_COMMIT="${_real}" t_assert_ok llvm_assert_commit_pin "${_TMPGIT}" sometag
rm -rf "${_TMPGIT}"

t_case "the apt bootstrap can no longer become the shipped clang"
_MAT="${REPO_SCRIPTS}/02-toolchain/materialize-llvm-target.sh"
t_assert_eq "0" "$(grep -c '/usr/lib/llvm-\${_major}' "${_MAT}" || true)" \
  "the apt tree was the fallback that once shipped a 23.1.1 tree against a 23.1.0 pin"
t_assert_contains "$(cat "${_MAT}")" '/opt/llvm-target-${_arch}' \
  "the pinned source tree must be the first host candidate"

# A non-amd64 host must emulate amd64, whose QEMU handler is qemu-x86_64, never qemu-amd64.
t_case "every arch maps to a QEMU handler that really exists"
_BRM="${REPO_SCRIPTS}/build-runtime-manifest.sh"
_qemu_name() {
  bash -c "$(sed -n '/^_binfmt_qemu_name()/,/^}/p' "${_BRM}")"$'\n''_binfmt_qemu_name "$1"' _ "$1"
}
t_assert_eq "qemu-x86_64"  "$(_qemu_name amd64)" \
  "qemu-amd64 is not a handler name anywhere; the binary is qemu-x86_64"
t_assert_eq "qemu-x86_64"  "$(_qemu_name x86_64)"
t_assert_eq "qemu-aarch64" "$(_qemu_name arm64)"
t_assert_eq "qemu-riscv64" "$(_qemu_name riscv64)"

t_case "the registrar can register the arch the chain now has to emulate"
_REG="${REPO_SCRIPTS}/setup-rootless-binfmt.sh"
_reg_bin() {
  bash -c "$(sed -n '/^qemu_bin_for()/,/^}/p' "${_REG}")"$'\n''qemu_bin_for "$1"' _ "$1"
}
t_assert_eq "qemu-x86_64"  "$(_reg_bin amd64)"
t_assert_eq "qemu-aarch64" "$(_reg_bin arm64)"
# e_machine 0x3e is x86-64; the byte pair is what binfmt_misc matches on.
t_assert_contains "$(sed -n '/^elf_magic_for()/,/^}/p' "${_REG}")" 'x3e' \
  "without the ELF magic the registrar cannot install the amd64 handler"

# The bare-run default must skip the host's own arch: binfmt_misc would route native ELF through QEMU too.
t_case "the registrar's default emulates every chain target EXCEPT the host's own"
_reg_src() { sed -n '/^_binfmt_host_arch()/,/^}/p;/^_binfmt_default_arches()/,/^}/p' "${_REG}"; }
# _reg_call <fn> <uname -m>: one runner for both helpers, so the code-dupes gate sees no copy.
_reg_call() {
  bash -c "
    uname() { [ \"\$1\" = -m ] && echo '$2' || command uname \"\$@\"; }
    $(_reg_src)
    $1"
}
_reg_default_for()   { _reg_call _binfmt_default_arches "$1"; }
_reg_host_arch_for() { _reg_call _binfmt_host_arch      "$1"; }
# THE REGRESSION TRIPWIRE: the amd64 lane's answer must not move a byte.
t_assert_eq "arm64,riscv64"   "$(_reg_default_for x86_64)" \
  "the historical default was correct FOR AMD64 and must stay byte-identical"
t_assert_eq "amd64,riscv64"   "$(_reg_default_for aarch64)" \
  "an arm64 host emulates amd64 and riscv64 -- never its own arch"
t_assert_eq "amd64,arm64"     "$(_reg_default_for riscv64)"
# Unknown host: emulate everything rather than silently registering nothing.
t_assert_eq "amd64,arm64,riscv64" "$(_reg_default_for ppc64le)"

# qemu-user binaries run on the host, so the emulator image must match it; amd64's ships no qemu-x86_64.
t_case "the emulator image platform follows the host, not a frozen amd64"
t_assert_eq "amd64"   "$(_reg_host_arch_for x86_64)" \
  "the amd64 lane must still pull the amd64 emulator image"
t_assert_eq "arm64"   "$(_reg_host_arch_for aarch64)" \
  "an arm64 host needs aarch64-ELF emulators, incl. the qemu-x86_64 amd64 lacks"
t_assert_eq "riscv64" "$(_reg_host_arch_for riscv64)"
t_assert_eq ""        "$(_reg_host_arch_for ppc64le)" \
  "an unrecognized host must not silently claim to be amd64"
# The frozen literal must not come back.
t_assert_eq "0" "$(grep -cE -- '--platform linux/amd64' "${_REG}" || true)" \
  "extract_emulators must ask for the host platform, not freeze amd64"
# An EXIT trap fires after the function returns, so a `local` in it dies under set -u and masks the failure.
t_assert_eq "0" "$(grep -cE "trap 'rm -rf \"\\$\{tmp\}\"' EXIT" "${_REG}" || true)" \
  "an EXIT trap must not dereference a function-local"

# With target == build host no AS/LD/AR is exported, so the wrapper populator must not read them bare.
_LLVM_SH="${REPO_SCRIPTS}/02-toolchain/llvm.sh"
_FN_SRC="$(mktemp)"
sed -n '/^llvm_cross_populate_tool_wrapper_dir()/,/^}/p' "${_LLVM_SH}" > "${_FN_SRC}"
# shellcheck disable=SC1090
. "${_FN_SRC}"

t_case "the tool wrapper dir survives an unset AS/LD/AR (target == build host)"
t_needs "real symlinks (ln -s copies under Git Bash)" t_posix_symlinks
_WD="$(mktemp -d)"
( set -u
  unset AS LD AR NM RANLIB STRIP OBJCOPY
  llvm_cross_populate_tool_wrapper_dir "${_WD}"
) >/dev/null 2>&1
for _t in as ld ar nm ranlib strip objcopy; do
  t_assert_ok test -L "${_WD}/${_t}"
done
t_assert_eq "$(command -v as)" "$(readlink "${_WD}/as")" \
  "with no AS exported the native assembler is the right one"
rm -rf "${_WD}"

t_case "an exported tool var still wins over PATH"
t_needs "real symlinks (ln -s copies under Git Bash)" t_posix_symlinks
_FAKE="$(mktemp -d)"; : > "${_FAKE}/fake-as"; chmod +x "${_FAKE}/fake-as"
_WD2="$(mktemp -d)"
( set -u
  unset LD AR NM RANLIB STRIP OBJCOPY
  AS="${_FAKE}/fake-as" llvm_cross_populate_tool_wrapper_dir "${_WD2}"
) >/dev/null 2>&1
t_assert_eq "${_FAKE}/fake-as" "$(readlink "${_WD2}/as")" \
  "the cross path must keep using the target's assembler, not the host's"
rm -rf "${_FAKE}" "${_WD2}" "${_FN_SRC}"


# A host-only target list leaves `grep -vx` nothing to print; under pipefail that exit 1 killed the RUN silently.
t_case "the host-first reorder survives a target list that is ONLY the host arch"
_LLVM_CROSS="${REPO_SCRIPTS}/02-toolchain/llvm-cross.sh"
_reorder() {
  bash -c '
set -euo pipefail
targets_raw="$1"; _host_arch="$2"
'"$(sed -n '/^  # `|| true` INSIDE a brace group/,/^  esac$/p' "${_LLVM_CROSS}" | sed 's/^  //')"'
printf "%s" "${targets_raw}"' _ "$1" "$2"
}
t_assert_eq "arm64" "$(_reorder arm64 arm64)" \
  "a native-only list must not kill the RUN (this exited 1 before the fix)"
t_assert_eq "riscv64" "$(_reorder riscv64 riscv64)"
t_assert_eq "amd64"   "$(_reorder amd64 amd64)"
# THE REORDER ITSELF still has to work -- the point of the code.
t_assert_eq "arm64,amd64,riscv64" "$(_reorder amd64,arm64,riscv64 arm64)" \
  "the build host must still be moved to the FRONT"
t_assert_eq "amd64,arm64,riscv64" "$(_reorder amd64,arm64,riscv64 amd64)" \
  "the amd64 lane's order must not move"
# Host not in the list at all: unchanged.
t_assert_eq "riscv64" "$(_reorder riscv64 arm64)"
# The bare-pipeline form must not come back.
t_assert_eq "0" "$(grep -cE 'grep -vx "\$\{_host_arch\}" \| paste' "${_LLVM_CROSS}" || true)" \
  "an unguarded grep -vx in a pipefail pipeline is the bug this suite pins"

t_summary
