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

t_case "the refusals, run through the REAL entry points (read-only modes)"
CHAIN="${TESTS_DIR}/../build-cross-chain.sh"; STAGE_SH="${TESTS_DIR}/../build-cross-stage.sh"
# Leading VAR=value words are the environment; the rest runs time-boxed.
_chain() {
  local -a _e=(); while [[ "${1:-}" == *=* ]]; do _e+=("$1"); shift; done
  env -u CROSS_VARIANT -u ENABLE_NVIDIA -u ENABLE_AMD -u CROSS_NO_PUSH -u CROSS_BUILD_PLATFORM "${_e[@]}" timeout 60 "$@" 2>&1 \
    | grep -E '^\[(ERROR|INFO)\] (Cross chain|the |an? )' | head -1
}
t_assert_contains "$(_chain CROSS_VARIANT=nvidia bash "${CHAIN}" --describe-chain --target-arches amd64)" \
  "stages=gpu..runtime" "a variant chain starts at its gpu stage"
t_assert_contains "$(_chain CROSS_VARIANT=nvidia bash "${CHAIN}" --describe-chain --target-arches amd64)" \
  "final=ghcr.io/kataglyphis/kataglyphis_beschleuniger:latest-nvidia"
t_assert_contains "$(_chain CROSS_VARIANT=nvidia bash "${CHAIN}" --describe-chain --from-stage sdk --target-arches amd64)" \
  "cannot build sdk" "and refuses to re-push the shared stages"
t_assert_contains "$(_chain CROSS_VARIANT=rocm bash "${CHAIN}" --describe-chain --target-arches amd64,arm64)" \
  "the rocm variant is amd64-only"
t_assert_contains "$(_chain CROSS_VARIANT=nvidia bash "${CHAIN}" --describe-chain --target-arches amd64,arm64)" \
  "cannot cross-build arm64" "a foreign-arch CUDA build would ship build-platform GPU libraries under its tag"
t_assert_contains "$(_chain CROSS_VARIANT=nvidia CROSS_BUILD_PLATFORM=linux/arm64 bash "${CHAIN}" --describe-chain --target-arches arm64)" \
  "can only PUSH from an amd64 build platform" "off amd64 the shared sdk is the amd64 lane's"
t_assert_contains "$(_chain CROSS_VARIANT=nvidia CROSS_NO_PUSH=1 CROSS_BUILD_PLATFORM=linux/arm64 bash "${CHAIN}" --describe-chain --only media --target-arches arm64)" \
  "stages=media..media" "the local Jetson lane (native, --no-push) stays allowed"
t_assert_contains "$(_chain bash "${CHAIN}" --describe-chain --target-arches amd64)" "stages=base..runtime" \
  "the default chain is untouched"
t_assert_contains "$(_chain CROSS_VARIANT=nvidia bash "${STAGE_SH}" --stage sdk --arch amd64 --dry-run)" \
  "cannot build sdk" "build-cross-stage.sh obeys the same refusals"

t_case "the variant's build args reach every entry point, not just the chain"
_args() { SNIPPET='args=(); cross_stage_build_args args '"$1"' amd64; printf "%s " "${args[@]}"' _graph "${@:2}"; }
t_assert_contains "$(_args media CROSS_VARIANT=nvidia)" "ENABLE_NVIDIA=true" \
  "a variant media stage built through ANY entry point is a CUDA media stage"
t_assert_contains "$(_args gpu CROSS_VARIANT=nvidia)" "ENABLE_TENSORRT=false" "TensorRT is off by default"
t_assert_contains "$(_args media CROSS_VARIANT=rocm)" "ENABLE_AMD=true"
t_assert_eq "" "$(_args media | grep -o 'ENABLE_[A-Z]*=')" "the default media stage forwards no accelerator toggle"

t_case "the runtime lane refuses to write default tags under a variant"
RFNS="${CORE}/runtime-build-fns.sh"
t_assert_eq "onnxruntime-gpu pytorch-cu130" "$(ENABLE_NVIDIA=true bash -c "$(t_fn_src "${RFNS}" runtime_gpu_backend_pair)"$'\nruntime_gpu_backend_pair')"
t_assert_eq "onnxruntime-migraphx pytorch-rocm71" "$(ENABLE_AMD=true bash -c "$(t_fn_src "${RFNS}" runtime_gpu_backend_pair)"$'\nruntime_gpu_backend_pair')"
t_assert_eq "" "$(bash -c "$(t_fn_src "${RFNS}" runtime_gpu_backend_pair)"$'\nruntime_gpu_backend_pair')" "a CPU image keeps the Dockerfile defaults"
# --dry-run is a FLAG here (DRY_RUN in the environment is not read), and every
# call is time-boxed: a regression must fail the suite, never start a real build.
_RT="${TESTS_DIR}/../build-runtime-artifacts.sh"
t_assert_contains "$(env -u CROSS_VARIANT ENABLE_NVIDIA=true timeout 60 bash "${_RT}" --image-prefix example.io/r:latest --target-arches amd64 --dry-run 2>&1)" \
  "carries no -nvidia" "a GPU wrapper can never land on the default :latest-<arch>"
t_assert_contains "$(env -u CROSS_VARIANT ENABLE_NVIDIA=true timeout 60 bash "${_RT}" --target-arches amd64 --dry-run 2>&1)" \
  "latest-nvidia-base-amd64" "and the helper's default prefix is the variant's own"

t_case "one chain at a time: the pidfile is claimed atomically at the check"
_LK="$(mktemp -d)"
_lock_fns="$(t_fn_src "${CHAIN}" _chain_live_sibling_pid)"$'\n'"$(t_fn_src "${CHAIN}" _chain_refuse_live_sibling)"
_lock() { CROSS_CHAIN_PIDFILE="${_LK}/pid" bash -c 'is_dry_run() { return 1; }; err() { echo "ERR $*"; exit 1; }
cross_chain_pidfile_path() { printf "%s" "${CROSS_CHAIN_PIDFILE}"; }
'"${_lock_fns}"'
_chain_refuse_live_sibling; echo "claimed=${_CHAIN_PIDFILE:+yes} own=$([ "$(cat "${CROSS_CHAIN_PIDFILE}")" = "$$" ] && echo yes)"' 2>&1; }
t_assert_contains "$(_lock)" "claimed=yes own=yes" "no pidfile: the check writes OUR pid"
sleep 30 & _live=$!; printf '%s\n' "${_live}" > "${_LK}/pid"
t_assert_contains "$(_lock)" "ERR another cross chain is running (pid ${_live}" "a live chain refuses the second one"
kill "${_live}" 2>/dev/null; wait "${_live}" 2>/dev/null
t_assert_contains "$(_lock)" "claimed=yes own=yes" "a stale pidfile is taken over"
rm -rf "${_LK}"

t_case "the rocm payload reaches the runtime in TheRock's layout, every absolute link re-made relative"
PAY="${TESTS_DIR}/../06-packaging/copy-media-payloads.sh"
_FNS=""
for _fn in _dest copy_path _src_resolve copy_rocm_payload; do _FNS+="$(t_fn_src "${PAY}" "${_fn}")"$'\n'; done
_rocm() { SRCPREFIX="$1" COPY_TARGET_DIR="$2" ENABLE_AMD="${3:-true}" \
  bash -c "set -euo pipefail; warn() { :; }"$'\n'"${_FNS}"$'\ncopy_rocm_payload' 2>&1; }
# TheRock (setup-rocm-repo.sh): real /opt/rocm, core via update-alternatives,
# lib -> core/lib. The alternatives link is ABSOLUTE and lives outside the tree.
_SRC="$(mktemp -d)"; _DST="$(mktemp -d)"
mkdir -p "${_SRC}/opt/rocm/core-10.0/lib" "${_SRC}/etc/alternatives"
: > "${_SRC}/opt/rocm/core-10.0/lib/libamdhip64.so.7"
ln -s /opt/rocm/core-10.0 "${_SRC}/etc/alternatives/amdrocm-core"
ln -s /etc/alternatives/amdrocm-core "${_SRC}/opt/rocm/core"
ln -s core/lib "${_SRC}/opt/rocm/lib"
t_assert_eq "" "$(_rocm "${_SRC}" "${_DST}")" "a usable TheRock tree copies without a word"
t_assert_eq "core-10.0" "$(readlink "${_DST}/opt/rocm/core")" \
  "the update-alternatives link is re-made relative to its real target (it dangled in the image)"
t_assert_eq "yes" "$([ -f "${_DST}/opt/rocm/lib/libamdhip64.so.7" ] && echo yes)" \
  "so /opt/rocm/lib resolves, and publish_rocm_ld_path finds a directory"
# The older layout: /opt/rocm itself is the alternatives link.
_SRC2="$(mktemp -d)"; _DST2="$(mktemp -d)"
mkdir -p "${_SRC2}/opt/rocm-7.2/lib" "${_SRC2}/etc/alternatives"
: > "${_SRC2}/opt/rocm-7.2/lib/libamdhip64.so"
ln -s /opt/rocm-7.2 "${_SRC2}/etc/alternatives/rocm"
ln -s /etc/alternatives/rocm "${_SRC2}/opt/rocm"
_rocm "${_SRC2}" "${_DST2}" >/dev/null
t_assert_eq "rocm-7.2" "$(readlink "${_DST2}/opt/rocm")" "the top-level link resolves through /etc/alternatives too"
t_assert_eq "yes" "$([ -f "${_DST2}/opt/rocm/lib/libamdhip64.so" ] && echo yes)"
# Unusable trees are fatal, never a green build with a ROCm-less image.
_EMPTY="$(mktemp -d)"; _DST3="$(mktemp -d)"
t_assert_contains "$(_rocm "${_EMPTY}" "${_DST3}")" "ENABLE_AMD=true but the artifact has no /opt/rocm"
_SRC4="$(mktemp -d)"; mkdir -p "${_SRC4}/opt/rocm/core-10.0/lib"; ln -s /etc/alternatives/missing "${_SRC4}/opt/rocm/core"; ln -s core/lib "${_SRC4}/opt/rocm/lib"
t_assert_contains "$(_rocm "${_SRC4}" "$(mktemp -d)")" "no libamdhip64" "a dangling core link fails loudly"
t_assert_eq "" "$(_rocm "${_EMPTY}" "${_DST3}" false)" "a non-rocm image copies nothing and says nothing"
rm -rf "${_SRC}" "${_DST}" "${_SRC2}" "${_DST2}" "${_EMPTY}" "${_DST3}" "${_SRC4}"

t_case "the ASAN tree is optional, off, and cannot reach the default rocm image"
# 134.8 GiB installed, gfx942/gfx950 only, no ASAN MIGraphX and no ASAN torch
# wheel (measured against the live repo index 2026-09-22): a default :latest-rocm
# that carries it is not shippable.
_asan_copy() {  # $1 = ENABLE_ROCM_ASAN -> prints "<asan-present> <normal-present>"
  local src dst; src="$(mktemp -d)"; dst="$(mktemp -d)"
  mkdir -p "${src}/opt/rocm/core-10.0/lib" "${src}/opt/rocm/core-asan-10.0/lib"
  : > "${src}/opt/rocm/core-10.0/lib/libamdhip64.so"
  ln -s core-10.0/lib "${src}/opt/rocm/lib"
  SRCPREFIX="${src}" COPY_TARGET_DIR="${dst}" ENABLE_AMD=true ENABLE_ROCM_ASAN="$1" \
    bash -c "set -euo pipefail; warn() { :; }"$'\n'"${_FNS}"$'\ncopy_rocm_payload' >/dev/null
  printf '%s %s' "$([ -d "${dst}/opt/rocm/core-asan-10.0" ] && echo asan || echo none)" \
                 "$([ -f "${dst}/opt/rocm/core-10.0/lib/libamdhip64.so" ] && echo normal || echo MISSING)"
  rm -rf "${src}" "${dst}"
}
t_assert_eq "none normal" "$(_asan_copy false)" \
  "the default image drops the ASAN tree even when the builder installed it"
t_assert_eq "asan normal" "$(_asan_copy true)" "ENABLE_ROCM_ASAN=true is the only way it ships"
_ROCM_SETUP="$(cat "${CORE}/setup-rocm-repo.sh")"
t_assert_contains "${_ROCM_SETUP}" 'if [ "${ENABLE_ROCM_ASAN:-false}" = "true" ]; then' \
  "the repo stanza and the install are both behind the knob"
t_assert_contains "${_ROCM_SETUP}" 'core-asan-*) update-alternatives --set' \
  "the ASAN debs hijack the same alternatives, so every one is re-pointed"
t_assert_contains "${_ROCM_SETUP}" 'resolves into the ASAN tree' \
  "and the build FAILS if /opt/rocm or hipcc still resolves there"
t_assert_contains "$(_args gpu CROSS_VARIANT=rocm ENABLE_ROCM_ASAN=true)" "ENABLE_ROCM_ASAN=true" \
  "the gpu stage forwards the knob when it is set"
t_assert_eq "" "$(_args gpu CROSS_VARIANT=rocm | grep -o 'ENABLE_ROCM_ASAN')" \
  "and forwards nothing by default, so the Dockerfile default (false) stands"

t_case "the package stage hands ENABLE_AMD to the payload copy (it never reached it)"
_pkg="$(sed -n '/^FROM \${BASE_IMAGE} AS package-image/,/^FROM /p' "${TESTS_DIR}/../../Dockerfile.package")"
t_assert_contains "${_pkg}" $'ARG ENABLE_AMD\n' "declared in the package-image stage, where the copy runs"
t_assert_contains "${_pkg}" 'ENABLE_AMD="${ENABLE_AMD:-false}"' "and passed to copy-media-payloads.sh"

t_summary
