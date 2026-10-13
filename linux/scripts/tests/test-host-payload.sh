#!/usr/bin/env bash
# prune-host-payload.sh, its HOST_PAYLOAD resolver and wiring; see docs/artifact-copy-completeness.md#the-host-payload-stays-with-the-host-that-runs-it
set -u
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${TESTS_DIR}/test-harness.sh"
SCRIPTS="${TESTS_DIR}/.."
PRUNE="${SCRIPTS}/06-packaging/prune-host-payload.sh"
DF="${SCRIPTS}/../Dockerfile.package"
RBF="${SCRIPTS}/01-core/runtime-build-fns.sh"
MARKER=.android-payload-off

ROOT="$(mktemp -d)"
trap 'rm -rf "${ROOT}"' EXIT

# _fixture [rustup host triple]: the artifact-source trees, with an x86_64 toolchain unless told otherwise.
_fixture() {
  local triple="${1:-x86_64-unknown-linux-gnu}"
  rm -rf "${ROOT:?}"/*
  mkdir -p "${ROOT}/usr/local/rustup/toolchains/1.99.0-${triple}/bin" "${ROOT}/usr/local/cargo/bin" \
           "${ROOT}/usr/local/cargo/registry/cache" "${ROOT}/opt/android-sdk/platform-tools" \
           "${ROOT}/opt/android/onnxruntime/lib"
  : > "${ROOT}/usr/local/rustup/settings.toml"
  : > "${ROOT}/usr/local/cargo/bin/cargo"
  : > "${ROOT}/usr/local/cargo/registry/cache/crate.crate"
  : > "${ROOT}/opt/android-sdk/platform-tools/adb"
  : > "${ROOT}/opt/android-sdk/.knownPackages"
  : > "${ROOT}/opt/android/onnxruntime/lib/libonnxruntime.so"
}
_run() { HOST_PAYLOAD="$2" bash "${PRUNE}" "$1" "${ROOT}" 2>&1; }
_n() { find "$1" -mindepth 1 | wc -l | tr -d ' '; }

t_case "HOST_PAYLOAD=on copies everything as built -- the old path, on every arch"
_fixture
_out="$(_run arm64 on)"
t_assert_ok test -f "${ROOT}/usr/local/rustup/settings.toml"
t_assert_ok test -f "${ROOT}/opt/android-sdk/platform-tools/adb"
t_assert_ok test -f "${ROOT}/opt/android/onnxruntime/lib/libonnxruntime.so"
t_assert_fails test -e "${ROOT}/opt/android/${MARKER}"
t_assert_contains "${_out}" "HOST_PAYLOAD=on for arm64"

t_case "off on arm64 empties the x86_64 toolchain, the SDK and its payloads, but keeps every directory"
_fixture
_out="$(_run arm64 off)"
for _d in usr/local/rustup usr/local/cargo opt/android-sdk opt/android; do
  t_assert_ok test -d "${ROOT}/${_d}"
done
t_assert_eq 0 "$(_n "${ROOT}/usr/local/rustup")" "the toolchain the package stage would delete anyway"
t_assert_eq 0 "$(_n "${ROOT}/opt/android-sdk")" "dotfiles too"
t_assert_contains "${_out}" "arm64 runs aarch64-unknown-linux-gnu" \
  "the line must name what the image runs instead, or a reader cannot audit the drop"

t_case "cargo keeps its registry, as ensure_native_rust_toolchain does"
t_assert_ok test -f "${ROOT}/usr/local/cargo/registry/cache/crate.crate"
t_assert_fails test -e "${ROOT}/usr/local/cargo/bin"

t_case "the dropped Android payload is recorded where every reader looks"
t_assert_eq "${MARKER}" "$(ls -A "${ROOT}/opt/android")" "the marker and nothing else"
t_assert_contains "$(cat "${ROOT}/opt/android/${MARKER}")" "target_arch=arm64"
t_assert_contains "$(cat "${ROOT}/opt/android/${MARKER}")" "skipped=sdk,ndk"
for _reader in 06-packaging/smoke-android.sh 06-packaging/install-android-emulator.sh 06-packaging/smoke-runtime-image.sh; do
  t_assert_contains "$(cat "${SCRIPTS}/${_reader}")" "${MARKER}" "${_reader} must read the file the prune writes"
done

t_case "a native toolchain stays: a native artifact keeps its own rustup"
_fixture aarch64-unknown-linux-gnu
_out="$(_run arm64 off)"
t_assert_ok test -f "${ROOT}/usr/local/rustup/settings.toml"
t_assert_ok test -f "${ROOT}/usr/local/cargo/bin/cargo"
t_assert_contains "${_out}" "keeping ${ROOT}/usr/local/rustup (it holds a aarch64-unknown-linux-gnu toolchain)"
_fixture
_run amd64 off >/dev/null
# amd64's x86_64 toolchain is its own.
t_assert_ok test -f "${ROOT}/usr/local/rustup/settings.toml"

t_case "riscv64 maps to its own triple"
_fixture
t_assert_contains "$(_run riscv64 off)" "riscv64 runs riscv64gc-unknown-linux-gnu"
t_assert_eq 0 "$(_n "${ROOT}/usr/local/rustup")"

t_case "a marker the android stage already wrote is kept, not overwritten"
_fixture
printf 'reason=Android NDK ships as prebuilt/linux-x86_64 only\nbuild_host=arm64\n' > "${ROOT}/opt/android/${MARKER}"
_run arm64 off >/dev/null
t_assert_contains "$(cat "${ROOT}/opt/android/${MARKER}")" "build_host=arm64"
t_assert_eq "${MARKER}" "$(ls -A "${ROOT}/opt/android")"

t_case "running twice changes nothing and still exits 0"
_fixture
_run arm64 off >/dev/null
t_assert_eq 0 "$(t_rc env HOST_PAYLOAD=off bash "${PRUNE}" arm64 "${ROOT}")"
t_assert_eq "${MARKER}" "$(ls -A "${ROOT}/opt/android")"

t_case "an unknown mode or arch is a hard error, never a guess"
_fixture
t_assert_eq 1 "$(t_rc env HOST_PAYLOAD=maybe bash "${PRUNE}" arm64 "${ROOT}")"
t_assert_contains "$(_run arm64 maybe)" "HOST_PAYLOAD='maybe' (want on or off)"
t_assert_eq 1 "$(t_rc env HOST_PAYLOAD=off bash "${PRUNE}" not-an-arch "${ROOT}")"
# A refused run removed nothing.
t_assert_ok test -f "${ROOT}/opt/android-sdk/platform-tools/adb"

t_case "Dockerfile.package runs it in artifact-source, ahead of every COPY it prunes for"
# After the COPY the bytes are already a layer, so only a prune before it saves anything.
_RUN_LINE="$(grep -n -e 'prune-host-payload.sh "${TARGET_ARCH' "${DF}" | cut -d: -f1)"
t_assert_ok test -n "${_RUN_LINE}"
t_assert_contains "$(sed -n "1,${_RUN_LINE}p" "${DF}" | grep -E '^FROM ' | tail -1)" "AS artifact-source"
for _src in /opt/android-sdk /opt/android /usr/local/rustup /usr/local/cargo; do
  _copy="$(grep -n -e "--from=artifact-source ${_src} ${_src}\$" "${DF}" | cut -d: -f1)"
  t_assert_ok test -n "${_copy}"
  t_assert_ok test "${_RUN_LINE}" -lt "${_copy:-0}"
done
t_assert_ok grep -qx 'ARG HOST_PAYLOAD=on' "${DF}"

t_case "the package stage's Android variables are empty where the payload is pruned"
_PKG="$(sed -n '/^FROM \${PACKAGE_BASE_STAGE} AS package$/,/^FROM /p' "${DF}")"
t_assert_contains "${_PKG}" 'ARG ANDROID_PAYLOAD_ON=${HOST_PAYLOAD/off/}'
for _var in ANDROID_HOME ANDROID_SDK_ROOT GSTREAMER_ROOT_ANDROID ONNXRUNTIME_ROOT_ANDROID LITERT_ROOT_ANDROID \
            OPENCV_ROOT_ANDROID IREE_ROOT_ANDROID OPENCV_ANDROID_JNI_DIR; do
  t_assert_ok grep -qE "^(ENV | +)${_var}=\\$\\{ANDROID_PAYLOAD_ON:\\+/opt/android" <<<"${_PKG}"
done
t_assert_contains "${_PKG}" 'ENV PATH="${PATH}${ANDROID_HOME:+:' "no /cmdline-tools/latest/bin entry from an empty ANDROID_HOME"

# The resolver as the runtime lane runs it, with the real platform helpers.
_RES="$(t_fn_src "${RBF}" runtime_host_payload_arches)
$(t_fn_src "${RBF}" runtime_host_payload)
$(t_fn_src "${SCRIPTS}/01-core/tag-naming.sh" runtime_artifact_platform)" || exit 1
_payload() { bash -c "source '${SCRIPTS}/01-core/platform.sh'; ${_RES}"$'\n'"runtime_host_payload \"\$1\"" _ "$1" 2>&1; }
_payload_rc() { _payload "$1" >/dev/null; echo $?; }

t_case "by default amd64 alone keeps the host payload"
_unset_knobs() { unset HOST_PAYLOAD_ARCHES ARTIFACT_BUILD_MODE CROSS_BUILD_PLATFORM; }
_unset_knobs
t_assert_eq on "$(_payload amd64)"
t_assert_eq off "$(_payload arm64)"
t_assert_eq off "$(_payload riscv64)"

t_case "HOST_PAYLOAD_ARCHES brings it back on any arch, or drops it everywhere"
t_assert_eq on "$(HOST_PAYLOAD_ARCHES=amd64,arm64,riscv64 _payload arm64)" "the pre-2026-10-13 images, one switch away"
t_assert_eq on "$(HOST_PAYLOAD_ARCHES=amd64,arm64,riscv64 _payload riscv64)"
t_assert_eq off "$(HOST_PAYLOAD_ARCHES=none _payload amd64)"
t_assert_eq off "$(HOST_PAYLOAD_ARCHES=arm64 _payload amd64)"

t_case "a bad HOST_PAYLOAD_ARCHES fails instead of picking a shape"
t_assert_eq 2 "$(HOST_PAYLOAD_ARCHES=amd64,x86 _payload_rc arm64)"
t_assert_eq 2 "$(HOST_PAYLOAD_ARCHES=amd64,x86 _payload_rc amd64)" "the typo fails every arch, not only the one it names"
t_assert_contains "$(HOST_PAYLOAD_ARCHES=amd64,x86 _payload arm64)" "HOST_PAYLOAD_ARCHES=amd64,x86: expected a comma list"

t_case "an artifact no amd64 host built has no SDK to keep, whatever the list says"
t_assert_eq off "$(ARTIFACT_BUILD_MODE=native HOST_PAYLOAD_ARCHES=amd64,arm64 _payload arm64)" \
  "a native arm64 artifact: android-sdk.sh skipped the SDK"
t_assert_eq on "$(ARTIFACT_BUILD_MODE=native _payload amd64)"
t_assert_eq off "$(CROSS_BUILD_PLATFORM=linux/arm64 _payload amd64)" "a cross chain hosted on arm64"

t_case "the package build passes it, and every orchestrator checks the knob before it builds"
t_assert_contains "$(t_fn_src "${RBF}" append_package_build_args)" '--build-arg "HOST_PAYLOAD=${_apba_payload}"'
for _o in build-cross-chain.sh build-runtime-manifest.sh build-runtime-artifacts.sh; do
  t_assert_ok grep -q '^  runtime_host_payload_arches >/dev/null || exit 2$' "${SCRIPTS}/${_o}"
done

t_summary
