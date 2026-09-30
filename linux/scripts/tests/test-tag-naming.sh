#!/usr/bin/env bash
# tag-naming.sh, which decides every image tag the chain builds and pushes.
set -u
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${TESTS_DIR}/test-harness.sh"
# The default chain only: an inherited ENABLE_NVIDIA would move every tag (test-gpu-variant.sh owns variants).
unset CROSS_VARIANT ENABLE_NVIDIA ENABLE_AMD
# platform.sh first, or _cross_build_host_arch silently falls back to amd64.
source "${TESTS_DIR}/../01-core/platform.sh"
source "${TESTS_DIR}/../01-core/tag-naming.sh"

t_case "cross tags use IMAGE_REPO when set"
IMAGE_REPO="example.io/repo" IMAGE_REGISTRY_PREFIX="WRONG"
# Shared stages carry the build host's arch, so every case pins BUILDARCH rather than trusting the runner.
BUILDARCH=amd64 t_assert_eq "example.io/repo:base"                  "$(BUILDARCH=amd64 cross_base_tag)"
BUILDARCH=amd64 t_assert_eq "example.io/repo:cross-compiler-amd64"  "$(BUILDARCH=amd64 cross_compiler_tag)" \
  "an amd64 build host keeps BOTH historical names byte-for-byte"
t_assert_eq "example.io/repo:base-arm64"            "$(BUILDARCH=arm64 cross_base_tag)" \
  "a non-amd64 host must not collide with the registry's amd64 artifact"
t_assert_eq "example.io/repo:cross-compiler-arm64"  "$(BUILDARCH=arm64 cross_compiler_tag)"
t_assert_eq "example.io/repo:base-riscv64"          "$(BUILDARCH=riscv64 cross_base_tag)"
t_assert_eq "example.io/repo:cross-compiler-riscv64" "$(BUILDARCH=riscv64 cross_compiler_tag)"
t_assert_eq "example.io/repo:cross-sdk-arm64"     "$(cross_sdk_tag arm64)"
t_assert_eq "example.io/repo:cross-media-riscv64" "$(cross_media_tag riscv64)"
# android's payload depends on the build host, so its tag does too.
t_assert_eq "example.io/repo:cross-android-amd64" "$(BUILDARCH=amd64 cross_android_tag amd64)"

t_case "cross tags fall back to IMAGE_REGISTRY_PREFIX"
unset IMAGE_REPO
IMAGE_REGISTRY_PREFIX="ghcr.io/kataglyphis/kataglyphis_beschleuniger"
t_assert_eq "ghcr.io/kataglyphis/kataglyphis_beschleuniger:cross-sdk-amd64" "$(cross_sdk_tag amd64)"

t_case "runtime tags require RUNTIME_IMAGE_PREFIX"
unset RUNTIME_IMAGE_PREFIX
t_assert_fails runtime_require_image_prefix

t_case "runtime tags compose <prefix>-<role>-<arch>"
RUNTIME_IMAGE_PREFIX="example.io/repo:runtime"
t_assert_ok runtime_require_image_prefix
t_assert_eq "example.io/repo:runtime-base-arm64"    "$(runtime_base_tag arm64)"
t_assert_eq "example.io/repo:runtime-package-amd64" "$(runtime_package_tag amd64)"
t_assert_eq "example.io/repo:runtime-riscv64"       "$(runtime_wrapper_tag riscv64)"

t_case "runtime_artifact_platform: the cross arm follows the KNOB, not a literal"
# Every row pins CROSS_BUILD_PLATFORM: asserting only the default would pass either way.
ARTIFACT_BUILD_MODE=cross
t_assert_eq "linux/amd64" "$(CROSS_BUILD_PLATFORM=linux/amd64 runtime_artifact_platform arm64)" \
  "the amd64 production lane keeps the old literal byte-for-byte"
t_assert_eq "linux/arm64" "$(CROSS_BUILD_PLATFORM=linux/arm64 runtime_artifact_platform arm64)" \
  "a native arm64 lane's artifact IS arm64, and the package FROM must say so"
t_assert_eq "linux/amd64" "$(runtime_artifact_platform arm64)" \
  "the shipped default survives with the knob unset"
# An arm64 machine still builds amd64-under-QEMU by default, so never derive this from the host.
t_assert_eq "linux/amd64" "$(BUILDARCH=arm64 runtime_artifact_platform arm64)" \
  "the platform follows the knob, never the host"
ARTIFACT_BUILD_MODE=native
t_assert_eq "linux/arm64" "$(runtime_artifact_platform arm64)"
t_assert_eq "linux/riscv64" "$(runtime_artifact_platform riscv64)"
ARTIFACT_BUILD_MODE=bogus
t_assert_fails runtime_artifact_platform arm64
unset ARTIFACT_BUILD_MODE

t_case "runtime_artifact_image_ref: cross gets the per-arch suffix"
ARTIFACT_IMAGE_PREFIX="example.io/repo:cross-android"
ARTIFACT_BUILD_MODE=cross
t_assert_eq "example.io/repo:cross-android-arm64" "$(runtime_artifact_image_ref arm64)"
ARTIFACT_BUILD_MODE=native
t_assert_eq "example.io/repo:cross-android" "$(runtime_artifact_image_ref arm64)"
unset ARTIFACT_BUILD_MODE ARTIFACT_IMAGE_PREFIX

# cross_android_tag and cross-stage-build.sh's --artifact-image-prefix must stay one function.
t_case "the android tag's two spellings cannot drift apart"
IMAGE_REPO="example.io/repo" IMAGE_REGISTRY_PREFIX="WRONG"
for _h in amd64 arm64 riscv64; do
  t_assert_eq "$(BUILDARCH="${_h}" cross_android_tag_prefix)-arm64" \
    "$(BUILDARCH="${_h}" cross_android_tag arm64)" \
    "cross_android_tag must be the prefix plus the target arch (host=${_h})"
done

t_case "the build-host infix is empty on amd64 and present elsewhere"
t_assert_eq "" "$(BUILDARCH=amd64 cross_build_host_infix)" \
  "an amd64 build host keeps the historical android tag byte-for-byte"
t_assert_eq "-hostarm64"   "$(BUILDARCH=arm64 cross_build_host_infix)"
t_assert_eq "-hostriscv64" "$(BUILDARCH=riscv64 cross_build_host_infix)"
t_assert_eq "example.io/repo:cross-android-amd64" \
  "$(BUILDARCH=amd64 cross_android_tag amd64)"
t_assert_eq "example.io/repo:cross-android-hostarm64-amd64" \
  "$(BUILDARCH=arm64 cross_android_tag amd64)" \
  "a payload-off android built on arm64 must not overwrite the amd64 lane's artifact"

t_case "the final image carries the build host, like the android tag"
IMAGE_REPO="example.io/repo" IMAGE_REGISTRY_PREFIX="WRONG"
t_assert_eq "example.io/repo:latest" "$(BUILDARCH=amd64 cross_final_image_tag)"
t_assert_eq "example.io/repo:latest-hostarm64" "$(BUILDARCH=arm64 cross_final_image_tag)" \
  "a native arm64 run must never write the amd64 lane's :latest-<arch> children"

t_case "the retired :latest-cross alias is gone, and nothing resurrects it"
# The tag functions are the only place that could compose the retired name.
t_assert_eq "" "$(declare -F cross_final_image_legacy_alias || true)" \
  "no tag function may compose the old name"
t_assert_eq "" "$(grep -n 'latest-cross' "${TESTS_DIR}/../01-core/tag-naming.sh" || true)" \
  "nor may the module mention it as a live tag"

t_case "the final image and the android prefix carry the SAME infix"
# build-cross-chain.sh and cross-stage-build.sh must agree on the host, for every host.
for _h in amd64 arm64 riscv64; do
  _inf="$(BUILDARCH="${_h}" cross_build_host_infix)"
  t_assert_eq "example.io/repo:latest${_inf}" "$(BUILDARCH="${_h}" cross_final_image_tag)"
  t_assert_eq "example.io/repo:cross-android${_inf}" "$(BUILDARCH="${_h}" cross_android_tag_prefix)"
done

t_summary
