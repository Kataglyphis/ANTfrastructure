#!/usr/bin/env bash
# Tests for 01-core/tag-naming.sh — the functions that decide every image tag
# the chain builds and pushes.
set -u
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${TESTS_DIR}/test-harness.sh"
# platform.sh first: the shared-stage tags call build_arch_oci, and without it
# _cross_build_host_arch would silently take its amd64 fallback and the arm64 /
# riscv64 cases below would pass for the wrong reason.
source "${TESTS_DIR}/../01-core/platform.sh"
source "${TESTS_DIR}/../01-core/tag-naming.sh"

t_case "cross tags use IMAGE_REPO when set"
IMAGE_REPO="example.io/repo" IMAGE_REGISTRY_PREFIX="WRONG"
# The two shared stages carry the BUILD HOST arch. Pinned explicitly per case:
# the suite must assert the contract for every host, not just whichever machine
# happens to run it — that implicitness is what let the amd64 literal survive
# until a native arm64 sdk build pulled the WRONG parent image (2026-09-10).
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
t_assert_eq "example.io/repo:cross-android-amd64" "$(cross_android_tag amd64)"

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

t_case "runtime_artifact_platform: cross builds on amd64, native on the target"
ARTIFACT_BUILD_MODE=cross
t_assert_eq "linux/amd64" "$(runtime_artifact_platform arm64)"
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

t_summary
