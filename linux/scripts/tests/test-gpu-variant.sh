#!/usr/bin/env bash
# Tests for the GPU variant chain (owner directive 2026-09-22): CROSS_VARIANT
# (or ENABLE_NVIDIA / ENABLE_AMD) must move EVERY tag the chain writes from its
# gpu stage on under -<variant>, insert that stage between sdk and media, and
# leave the default chain's graph and tags byte-identical. The graph is decided
# when stage-defs.sh is sourced, so each case sources it in a fresh bash.
set -u
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${TESTS_DIR}/test-harness.sh"
CORE="${TESTS_DIR}/../01-core"
CHAIN_SH="${TESTS_DIR}/../build-cross-chain.sh"

# Run <snippet> with the real modules sourced under the given environment.
_graph() {
  env -u CROSS_VARIANT -u ENABLE_NVIDIA -u ENABLE_AMD "$@" bash -c '
    set -u
    source "'"${CORE}"'/platform.sh"; source "'"${CORE}"'/build-helpers.sh"
    source "'"${CORE}"'/tag-naming.sh"; source "'"${CORE}"'/stage-defs.sh" || exit 3
    IMAGE_REPO=example.io/repo; BUILDARCH=amd64
    eval "${SNIPPET}"' 2>&1
}

t_case "the default chain's graph and tags are unchanged"
t_assert_eq "base compiler sdk media android runtime" \
  "$(SNIPPET='echo "${CROSS_STAGE_ORDER[*]}"' _graph)"
t_assert_eq "example.io/repo:cross-media-arm64 example.io/repo:cross-android-arm64 example.io/repo:latest" \
  "$(SNIPPET='echo "$(cross_stage_tag media arm64) $(cross_stage_tag android arm64) $(cross_final_image_tag)"' _graph)"
t_assert_eq "1" "$(SNIPPET='cross_stage_tag gpu amd64 >/dev/null; echo $?' _graph)" \
  "the default chain has no gpu stage to resolve"

t_case "an nvidia chain inserts gpu between sdk and media"
t_assert_eq "base compiler sdk gpu media android runtime" \
  "$(SNIPPET='echo "${CROSS_STAGE_ORDER[*]}"' _graph CROSS_VARIANT=nvidia)"
t_assert_eq "sdk gpu media android" \
  "$(SNIPPET='echo "${CROSS_PER_ARCH_STAGES[*]}"' _graph CROSS_VARIANT=nvidia)"
t_assert_eq "sdk gpu linux/Dockerfile.nvidia GPU_PIN" \
  "$(SNIPPET='echo "$(cross_stage_parent gpu) $(cross_stage_parent media) $(cross_stage_dockerfile gpu) $(cross_stage_pin_varname gpu)"' _graph CROSS_VARIANT=nvidia)"

t_case "every tag from the gpu stage on carries the variant; the shared stages do not"
t_assert_eq "example.io/repo:cross-sdk-amd64 example.io/repo:cross-toolchain-nvidia-amd64 example.io/repo:cross-media-nvidia-amd64 example.io/repo:cross-android-nvidia-amd64 example.io/repo:latest-nvidia" \
  "$(SNIPPET='echo "$(cross_stage_tag sdk amd64) $(cross_stage_tag gpu amd64) $(cross_stage_tag media amd64) $(cross_stage_tag android amd64) $(cross_final_image_tag)"' _graph CROSS_VARIANT=nvidia)"
t_assert_eq "example.io/repo:cross-toolchain-rocm-amd64 example.io/repo:latest-rocm linux/Dockerfile.amd" \
  "$(SNIPPET='echo "$(cross_stage_tag gpu amd64) $(cross_final_image_tag) $(cross_stage_dockerfile gpu)"' _graph CROSS_VARIANT=rocm)"
t_assert_eq "example.io/repo:latest-nvidia-hostarm64" \
  "$(SNIPPET='BUILDARCH=arm64; cross_final_image_tag' _graph CROSS_VARIANT=nvidia)" \
  "variant infix first, then the build-host infix"

t_case "ENABLE_NVIDIA / ENABLE_AMD alone imply the variant (they used to build GPU bytes under the default tags)"
t_assert_eq "example.io/repo:cross-media-nvidia-arm64" \
  "$(SNIPPET='cross_stage_tag media arm64' _graph ENABLE_NVIDIA=true)"
t_assert_eq "example.io/repo:latest-rocm" "$(SNIPPET='cross_final_image_tag' _graph ENABLE_AMD=true)"
t_assert_contains "$(SNIPPET='echo reached' _graph ENABLE_NVIDIA=true ENABLE_AMD=true)" "both true"
t_assert_contains "$(SNIPPET='echo reached' _graph CROSS_VARIANT=cuda)" "unknown CROSS_VARIANT cuda"

t_case "a variant never gets the deprecated :latest-cross alias"
t_assert_eq "" \
  "$(SNIPPET='CROSS_LEGACY_ALIAS_TAG=latest-cross cross_final_image_legacy_alias "$(cross_final_image_tag)"' _graph CROSS_VARIANT=nvidia)"

t_case "the orchestrator guards: shared stages, rocm arches, one chain at a time"
_src="$(cat "${CHAIN_SH}")"
t_assert_contains "${_src}" 'FROM_STAGE="gpu"' "a variant chain defaults to its gpu stage"
t_assert_contains "${_src}" "cannot run --from-stage" "and refuses to re-push base/compiler/sdk"
t_assert_contains "${_src}" "the rocm variant is amd64-only"
t_assert_contains "${_src}" "the nvidia variant cannot cross-build" \
  "a foreign-arch CUDA build would ship host-arch GPU libraries under the target's tag"
t_assert_contains "${_src}" ': "${ENABLE_TENSORRT:=false}"' "TensorRT is off by default on the nvidia chain"
t_assert_contains "${_src}" $'_chain_no_push_guard         # refuse --no-push multi-stage (stale parent)\n  _chain_refuse_live_sibling' \
  "the serial lock runs before any log or state write"
t_assert_contains "${_src}" 'chain-status${CROSS_GPU_VARIANT:+-${CROSS_GPU_VARIANT}}.json' \
  "a variant keeps its own chain-status file"
t_assert_contains "${_src}" 'out/build-logs${CROSS_GPU_VARIANT:+/${CROSS_GPU_VARIANT}}' \
  "and its own log dir"

t_case "the rocm payload reaches the runtime, its /opt/rocm link re-made relatively"
PAY="${TESTS_DIR}/../06-packaging/copy-media-payloads.sh"
_FNS=""
for _fn in _dest copy_path copy_rocm_payload; do _FNS+="$(t_fn_src "${PAY}" "${_fn}")"$'\n'; done
_SRC="$(mktemp -d)"; _DST="$(mktemp -d)"
mkdir -p "${_SRC}/opt/rocm-10.0/lib" && : > "${_SRC}/opt/rocm-10.0/lib/libmigraphx.so"
ln -s /opt/rocm-10.0 "${_SRC}/opt/rocm"
_rocm() { SRCPREFIX="$1" COPY_TARGET_DIR="$2" ENABLE_AMD="${3:-true}" \
  bash -c "set -euo pipefail; warn() { :; }"$'\n'"${_FNS}"$'\ncopy_rocm_payload' 2>&1; }
_rocm "${_SRC}" "${_DST}" >/dev/null
t_assert_eq "rocm-10.0" "$(readlink "${_DST}/opt/rocm")" "a relative link, not the build container's absolute one"
t_assert_eq "yes" "$([ -f "${_DST}/opt/rocm-10.0/lib/libmigraphx.so" ] && echo yes)"
_EMPTY="$(mktemp -d)"; _DST2="$(mktemp -d)"
t_assert_contains "$(_rocm "${_EMPTY}" "${_DST2}")" "ENABLE_AMD=true but the artifact has no /opt/rocm"
t_assert_eq "" "$(_rocm "${_EMPTY}" "${_DST2}" false)" "a non-rocm image copies nothing and says nothing"
rm -rf "${_SRC}" "${_DST}" "${_EMPTY}" "${_DST2}"

t_summary
