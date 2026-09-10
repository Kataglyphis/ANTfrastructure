#!/usr/bin/env bash
# Tests for building the chain on a NON-amd64 build host, where the Android NDK
# (prebuilt/linux-x86_64 only) cannot be installed and the android stage builds
# payload-off instead. Three mechanisms must agree, none of which had ANY test
# coverage before this suite: the host predicate (platform.sh), swap-native-gcc's
# early return, and the payload-off marker android-sdk.sh writes / smoke-android
# reads. Why the stage is not simply removed from the graph, and what each
# consumer does with the marker: docs/linux-cross-builds.md#non-amd64-build-hosts
#
# Every case pins BUILDARCH — unpinned rows assert whatever machine runs them.
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

# The fallback ladder in _platform_raw_build_arch is BUILDARCH -> BUILDPLATFORM
# -> dpkg -> uname. A caller that only sets BUILDPLATFORM must get the same
# answer, or a Dockerfile that forgets `ARG BUILDARCH` silently takes the amd64
# path on an arm64 machine.
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

# ---------------------------------------------------------------------------
# swap-native-gcc.sh. Neither branch can COMPLETE on a machine with no /opt/gcc-* tree: both end in
# assert_elf_arch / _assert_and_relocate_native_gcc against a path that does not
# exist, and elf_machine_name's unreadable-file return kills the script under
# errexit with no message at all. Asserting on stdout would therefore be an
# absence test that also passes when the script dies for an unrelated reason.
# The execution trace names the branch positively instead.
_swap_trace() {
  TARGET_ARCH="$1" BUILDARCH="$2" BUILD_MODE=cross GCC_VERSION=0.0.0 \
    bash -x "${SWAP}" 2>&1 | grep -E '^\+ (assert_elf_arch|_assert_and_relocate_native_gcc)'
}

t_case "swap-native-gcc keys its early return on the build host"
# THE AMD64 TRIPWIRE: an amd64 host targeting arm64 must still demand the
# Canadian cross prefix. If anyone ever generalises this early return into a
# no-op, the cross build silently ships an amd64 GCC in an arm64 image.
t_assert_contains "$(_swap_trace arm64 amd64)" "_assert_and_relocate_native_gcc /opt/gcc-0.0.0-native-arm64" \
  "the amd64 cross path must be unchanged"
t_assert_contains "$(_swap_trace riscv64 amd64)" "_assert_and_relocate_native_gcc /opt/gcc-0.0.0-native-riscv64"

# target == build host: gcc.sh:376 took link_amd64_host_as_cross and never
# produced a native prefix, so the swap must assert the HOST GCC instead of
# demanding one that is never built.
t_assert_contains "$(_swap_trace arm64 arm64)" "assert_elf_arch /opt/gcc-0.0.0/bin/gcc arm64" \
  "a native arm64 host must accept its own GCC, not demand a Canadian cross"
t_assert_contains "$(_swap_trace riscv64 riscv64)" "assert_elf_arch /opt/gcc-0.0.0/bin/gcc riscv64"
t_assert_contains "$(_swap_trace amd64 amd64)" "assert_elf_arch /opt/gcc-0.0.0/bin/gcc amd64" \
  "an amd64 host targeting amd64 keeps the historical behaviour"

# ...and must NOT have looked for a Canadian prefix at all.
_count() { printf '%s' "$1" | grep -c -- "$2" || true; }
t_assert_eq "0" "$(_count "$(_swap_trace arm64 arm64)" "native-arm64")" \
  "the native host must never reach _assert_and_relocate_native_gcc"

# ---------------------------------------------------------------------------
# The payload-off marker: one literal path written by android-sdk.sh and read by
# smoke-android.sh. Neither file may be run for real here (android-sdk.sh
# installs an SDK; the path is under /opt), so the producer is asserted
# structurally and the reader behaviourally against a redirected copy.
t_case "the marker's producer and reader name the SAME path"
t_assert_contains "$(cat "${ANDROID_SDK}")" "${MARKER_PATH}" \
  "android-sdk.sh must write the marker"
t_assert_contains "$(cat "${SMOKE_ANDROID}")" "${MARKER_PATH}" \
  "smoke-android.sh must read the same literal the producer writes"

t_case "the marker is written inside the skip branch, not unconditionally"
# Everything from the guard to its `exit 0` — the write must live in there, or
# an amd64 build would stamp its own image payload-off.
_skip_branch="$(awk '/android_require_amd64_build_host "Android SDK\/NDK installation"/,/^fi$/' "${ANDROID_SDK}")"
t_assert_contains "${_skip_branch}" "${MARKER_PATH}"
t_assert_contains "${_skip_branch}" "build_host="

# ---------------------------------------------------------------------------
# smoke-android.sh against a redirected marker. Copy both files so the script's
# own `source "${_SCRIPT_DIR}/smoke-common.sh"` still resolves, then rewrite only
# the marker literal. This runs the REAL main(), not a re-implementation.
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

# ---------------------------------------------------------------------------
# The frozen-build-host CLASS, as one checkable row. No test anywhere asserts a
# --platform argument on any code path (`grep -rn -e '--platform' tests/` is
# empty), so the literal count is the only thing standing between this and a
# silent revert to a hardcoded platform.
t_case "linux/amd64 survives in exactly one place: the accessor's own default"
# CODE only — a comment may name the default (and stage-defs.sh's does, to say
# what CROSS_BUILD_PLATFORM defaults to). What must not exist is a second place
# that DECIDES it.
_count_lit() { grep -v '^[[:space:]]*#' "${REPO_SCRIPTS}/$1" | grep -c 'linux/amd64' || true; }
t_assert_eq "1" "$(_count_lit 01-core/platform.sh)" \
  "cross_build_platform owns the default; a second copy is a second answer"
for _f in 01-core/tag-naming.sh 01-core/stage-defs.sh 01-core/chain-verify.sh; do
  t_assert_eq "0" "$(_count_lit "${_f}")" \
    "${_f} must ask cross_build_platform, not freeze the platform"
done

t_case "the platform knob is EXPORTED, or the fix is inert where it is needed"
# build-cross-chain.sh launches build-runtime-manifest.sh through `run env`,
# which forwards only exported vars. Unexported, the child re-sources
# cross-stage-build.sh, re-defaults to linux/amd64, and pins the runtime
# artifact-source to a platform the artifact is not. No in-process test can see
# this, so it is asserted structurally.
# Matches the SC2155-clean two-line form (assign, then bare `export NAME`) as
# well as a single-line export, so splitting for the masked-declaration gate
# cannot silently retire this assertion.
t_assert_eq "1" "$(grep -cE '^export CROSS_BUILD_PLATFORM\b' "${REPO_SCRIPTS}/01-core/cross-stage-build.sh" || true)"

t_case "cross_build_platform reads the knob and defaults to the amd64 lane"
t_assert_eq "linux/amd64"  "$(cross_build_platform)"
t_assert_eq "linux/arm64"  "$(CROSS_BUILD_PLATFORM=linux/arm64 cross_build_platform)"
t_assert_eq "linux/amd64"  "$(BUILDARCH=riscv64 cross_build_platform)" \
  "the knob, never the host — an emulated build must describe itself honestly"

# ---------------------------------------------------------------------------
# LLVM_COMMIT turns the pin from a bookmark into a pin. Before 2026-09-10 the
# key existed, was documented as OPT-IN, and NO consumer read it — while
# apt.llvm.org silently shipped 23.1.1 against LLVM_RELEASE=23.1.0.
t_case "llvm_assert_commit_pin has ONE owner and both clone sites call it"
_CORE="${REPO_SCRIPTS}/01-core"
t_assert_eq "1" "$(grep -c '^llvm_assert_commit_pin()' "${_CORE}/common.sh" || true)"
for _f in 02-toolchain/build-clang.sh 02-toolchain/llvm-cross.sh; do
  t_assert_eq "1" "$(grep -c 'llvm_assert_commit_pin ' "${REPO_SCRIPTS}/${_f}" || true)" \
    "${_f} must verify its checkout, not re-implement the check"
done

t_case "the pin is set, peeled, and matches LLVM_RELEASE's tag"
# Read the file rather than sourcing it: versions.env is a flat KEY=value list
# and the suite runs under `set -u`, where sourcing it would trip on the first
# ${OTHER:-} reference it happens to contain.
_VERS="${_CORE}/versions.env"
_vers_val() { sed -n "s/^$1=//p" "${_VERS}" | head -1; }
t_assert_eq "23.1.0" "$(_vers_val LLVM_RELEASE)"
t_assert_eq "ea7d852a70e8bdfaf601d6626a760f9771b2c4b4" "$(_vers_val LLVM_COMMIT)" \
  "refs/tags/llvmorg-23.1.0^{} — the PEELED sha, per the convention above the key"
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
  "the apt tree was the fallback that shipped 23.1.1 against a 23.1.0 pin"
t_assert_contains "$(cat "${_MAT}")" '/opt/llvm-target-${_arch}' \
  "the pinned source tree must be the first host candidate"

# ---------------------------------------------------------------------------
# Emulating amd64 only becomes necessary once the BUILD HOST is not amd64 —
# which is exactly what this suite is about. Both helpers had no amd64 arm, and
# _binfmt_qemu_name's catch-all produced "qemu-amd64", a handler that does not
# exist under any name (the real one is qemu-x86_64). verify_foreign_binfmt
# therefore err()'d before the build loop on every arm64/riscv64 host.
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

t_summary
