#!/usr/bin/env bash
# RUNTIME_WHEELS_SOURCE (lib-runtime-wheels.sh): image, the android-image mount every chain
# used before 2026-09-24, and export, a sealed directory staged before each package build.
# Hermetic: nerdctl and every build are stubs, the lib and the 01-core wrapper path are real.
# It proves the argument vectors, the order, the refusals and the seal. It runs no BuildKit,
# so it does NOT prove the named-context override or that both modes mount the same bytes:
# the host A/B does. docs/cross-build-verification.md#measuring-the-torch-runs-wait-before-uv-venv
set -u
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${TESTS_DIR}/test-harness.sh"
source "${TESTS_DIR}/runtime-wheels-fixtures.sh"
rw_hermetic_env
SCRIPTS="${TESTS_DIR}/.."
LIB="${SCRIPTS}/lib-runtime-wheels.sh"
RBF="${SCRIPTS}/01-core/runtime-build-fns.sh"
CTX="${SCRIPTS}/01-core/context-management.sh"
TORCH="${SCRIPTS}/../Dockerfile.torch"
STV="${SCRIPTS}/06-packaging/setup-torch-venv.sh"

# The real wrapper path: argument assembly, the chain, and the context helpers it calls.
_FNS="$(rw_fns "${RBF}" append_wrapper_build_args runtime_wheels_image_ref _append_wheels_image_args \
  runtime_gpu_backend_pair _runtime_timed runtime_build_chain _runtime_build_wrapper runtime_build_wrapper_image)" || exit 1
_FNS+=$'\n'"$(rw_fns "${CTX}" runtime_pushes_wrapper_images runtime_pushes_intermediate_images \
  runtime_use_local_artifact_context runtime_artifact_context_dir runtime_artifact_context_ref \
  _with_throwaway_container _export_cid_wheels runtime_wheels_context_dir)" || exit 1

# Everything below the wrapper build is a recorder. run_nerdctl_build plays BuildKit's local
# exporter for --target wheels-export (EXPORT_WHEELS=0: an empty /opt/wheels, EXPORT_RC fails it).
_STUBS='log() { printf "%s\n" "$*"; }
warn() { printf "%s\n" "$*" >&2; }
is_dry_run() { [ "${DRY_RUN:-0}" = 1 ]; }
_bool_truthy() { case "${1:-0}" in 1|true|yes|on) return 0 ;; esac; return 1; }
trap_push() { printf "TRAP %s\n" "$1" >> "${BLOG}"; }
runtime_android_pin() { printf "%s" "${PIN:-}"; }
cross_build_host_infix() { printf "%s" "${INFIX:-}"; }
cross_variant() { :; }
cross_android_tag() { printf "repo:cross-android%s-%s" "${INFIX:-}" "$1"; }
runtime_artifact_image_ref() { printf "repo:cross-android-other-%s" "$1"; }
runtime_wrapper_tag() { printf "repo:latest-%s" "$1"; }
append_common_build_args() { :; }
append_runtime_accelerator_build_args() { :; }
_runtime_resolve_parent_context() { printf -v "$3" "%s" "repo:latest-package-$2"; }
append_runtime_image_output() { local -n _o=$1; _o+=(-t "$2"); }
runtime_assert_provenance_stamped() { :; }
runtime_remove_stage_context() { :; }
runtime_stage_context_dir() { printf "%s/%s-%s" "${WORK}" "$1" "$2"; }
runtime_push_tag() { printf "PUSH %s\n" "$1" >> "${BLOG}"; }
runtime_build_base_image() { printf "STEP base\n" >> "${BLOG}"; }
runtime_build_package_image() { printf "STEP package\n" >> "${BLOG}"; [ -z "${PACKAGE_HOOK:-}" ] || eval "${PACKAGE_HOOK}"; }
_runtime_run_package_smoke() { printf "STEP smoke\n" >> "${BLOG}"; }
run_nerdctl_build() {
  shift
  local a prev="" dest="" kind=wrapper ctx=""
  for a in "$@"; do
    case "${prev}" in
      --output) dest="${a#type=local,dest=}" ;;
      --target) [ "${a}" = wheels-export ] && kind=export ;;
      --build-context) case "${a}" in runtime_wheels=*) ctx="${a#runtime_wheels=}" ;; esac ;;
    esac
    prev="${a}"
  done
  { printf "BUILD-BEGIN %s\n" "${kind}"; printf "%s\n" "$@"; printf "BUILD-END\n"; } >> "${BLOG}"
  if [ "${kind}" = export ]; then
    mkdir -p "${dest}/opt/wheels"
    if [ "${EXPORT_WHEELS:-2}" != 0 ]; then
      printf a > "${dest}/opt/wheels/torch-2.9.0-cp314-cp314-linux_aarch64.whl"
      printf bb > "${dest}/opt/wheels/onnxruntime-1.30.0-cp314-cp314-linux_aarch64.whl"
    fi
    return "${EXPORT_RC:-0}"
  fi
  if [ -n "${ctx}" ] && compgen -G "${ctx}/opt/wheels/*.whl" >/dev/null; then
    printf "WRAPPER-SAW-WHEELS\n" >> "${BLOG}"
  fi
  return 0
}'$'\n'"${RW_OPTIONAL_ARG_STUB}"

_BIN="$(rw_nerdctl_dir)"
_LOGS="$(mktemp -d)"
export WORK="${_LOGS}/work" BLOG="${_LOGS}/builds.log" NLOG="${_LOGS}/nerdctl.log" ROOTFS
ROOTFS="$(rw_rootfs)"
export RUNTIME_CONTEXT_ROOT="${WORK}/ctxroot" CROSS_BUILD_DATE=D0 CROSS_VCS_REF=R0

_fresh() { rm -rf "${WORK}"; mkdir -p "${WORK}"; : > "${BLOG}"; : > "${NLOG}"; }

# One runtime-lane process: the stubs, the real 01-core functions, the real lib, then $1.
_run() {
  PATH="${_BIN}:${PATH}" bash -c "set -uo pipefail"$'\n'"${_STUBS}"$'\n'"${_FNS}"$'\n'"source $(printf '%q' "${LIB}")"$'\n'"$1" 2>&1
}
_LANE='runtime_wheels_setup || { echo "SETUP-RC=$?"; exit 0; }
runtime_wheels_arch_chain arm64 || echo "CHAIN-RC=$?"
echo "ROOT=${RUNTIME_WHEELS_EXPORT_ROOT}"
[ -z "${RUNTIME_WHEELS_EXPORT_ROOT}" ] || ls -A "${RUNTIME_WHEELS_EXPORT_ROOT}" | sed "s/^/LEFT /"'

_nth() {  # <kind> — that build's argv, one per line
  awk -v k="BUILD-BEGIN $1" '$0 == k {on=1; next} /^BUILD-END$/ {on=0} on {print}' "${BLOG}"
}
_events() { grep -E '^(BUILD-BEGIN|STEP|WRAPPER-SAW|PUSH|TRAP)' "${BLOG}" | tr '\n' ',' || true; }
_wheels_tail() { _nth wrapper | awk 'p {print} $0 == "VCS_REF=R0" {p=1}' | tr '\n' ' '; }
_head() { _nth wrapper | awk '$0 == "VCS_REF=R0" {exit} {print}'; }
_steps() { printf '%s\n' "$1" | sed -n 's/^\[runtime-timing\] arch=arm64 step=\([a-z-]*\) secs=[0-9]* rc=0$/\1/p' | tr '\n' ' '; }

t_case "the knob: auto and image are today's mount, export is the fast path, a typo stops the lane"
for _v in "" auto image; do
  t_assert_eq "image rc=0" "$(RUNTIME_WHEELS_SOURCE="${_v}" _run 'runtime_wheels_source_mode; echo " rc=$?"')" "RUNTIME_WHEELS_SOURCE='${_v}'"
done
t_assert_eq "export rc=0" "$(RUNTIME_WHEELS_SOURCE='export' _run 'runtime_wheels_source_mode; echo " rc=$?"')"
_out="$(RUNTIME_WHEELS_SOURCE=imgae _run 'runtime_wheels_source_mode; echo " rc=$?"')"
t_assert_contains "${_out}" "rc=2" "an unknown value is a usage error, never a silent image"
t_assert_contains "${_out}" "RUNTIME_WHEELS_SOURCE=imgae: expected auto, image or export"
_fresh
_out="$(RUNTIME_WHEELS_SOURCE=imgae _run "${_LANE}")"
t_assert_contains "${_out}" "SETUP-RC=2" "the lanes' setup refuses it before any build"
t_assert_eq "" "$(_events)" "and nothing was built"

t_case "image mode (the native path): no root, no export, and the wrapper vector of today"
for _v in image auto; do
  _fresh
  _out="$(RUNTIME_WHEELS_SOURCE="${_v}" RUNTIME_WHEELS_EXPORT_ROOT=/leaked PIN=repo@sha256:abc _run "${_LANE}")"
  t_assert_contains "${_out}" "ROOT=" "RUNTIME_WHEELS_SOURCE=${_v}: no export root"
  t_assert_eq "" "$(printf '%s\n' "${_out}" | grep -F 'ROOT=/leaked' || true)" "an inherited root cannot switch the wrapper to export"
  t_assert_eq "STEP base,STEP package,STEP smoke,BUILD-BEGIN wrapper," "$(_events)" "exactly base, package, smoke, wrapper, as before"
  t_assert_eq "base package smoke wrapper " "$(_steps "${_out}")" "each of them prints its [runtime-timing] line, in order"
  t_assert_eq "--build-arg WHEELS_IMAGE=repo@sha256:abc . " "$(_wheels_tail)" "the torch RUN mounts the pinned android image"
  t_assert_eq "" "$(ls -A "${RUNTIME_CONTEXT_ROOT}" 2>/dev/null)" "nothing is staged"
done
_IMAGE_HEAD="$(_head)"
_fresh
RUNTIME_WHEELS_SOURCE=image _run "${_LANE}" >/dev/null
t_assert_eq ". " "$(_wheels_tail)" "no pin, infix or variant: no WHEELS_IMAGE, Dockerfile.torch's default"
_fresh
RUNTIME_WHEELS_SOURCE=image ARTIFACT_CONTEXT_ROOT="${WORK}/aa" _run "${_LANE}" >/dev/null
t_assert_eq ". " "$(_wheels_tail)" "the same under ARTIFACT_CONTEXT_ROOT (the empty-pin case the old code fell through)"
t_assert_eq "" "$(cat "${NLOG}")" "and no containerd extraction"
_fresh
RUNTIME_WHEELS_SOURCE=image ARTIFACT_CONTEXT_ROOT="${WORK}/aa" INFIX=-hostarm64 _run "${_LANE}" >/dev/null
t_assert_eq "--build-arg WHEELS_IMAGE=repo:cross-android-hostarm64-arm64 --build-context repo:cross-android-hostarm64-arm64=${WORK}/wheels-arm64 . " \
  "$(_wheels_tail)" "a no-push native host keeps its containerd extraction"
t_assert_contains "$(cat "${NLOG}")" "export cid42" "through nerdctl export, as before"

t_case "export mode: the wheelhouse is staged from the SAME image before the package build"
_fresh
_out="$(RUNTIME_WHEELS_SOURCE='export' PIN=repo@sha256:abc _run "${_LANE}")"
_root="$(printf '%s\n' "${_out}" | sed -n 's/^ROOT=//p')"
case "${_root}" in "${RUNTIME_CONTEXT_ROOT}/runtime-flow.wheels."*) _ok=yes ;; *) _ok="no: ${_root}" ;; esac
t_assert_eq yes "${_ok}" "the root is minted under RUNTIME_CONTEXT_ROOT, named for the orphan sweep"
t_assert_eq "TRAP runtime_wheels_cleanup,BUILD-BEGIN export,STEP base,STEP package,STEP smoke,BUILD-BEGIN wrapper,WRAPPER-SAW-WHEELS," \
  "$(_events)" "export first, then the unchanged chain, and the wrapper finds the wheels"
_exp="$(_nth export | tr '\n' ' ')"
t_assert_eq "--pull=false --platform linux/arm64 --target wheels-export --output type=local,dest=${_root}/arm64 -f linux/Dockerfile.torch --build-arg BASE_IMAGE=scratch --build-arg WHEELS_IMAGE=repo@sha256:abc . " \
  "${_exp}" "the export reads the pin image mode mounts, with the wrapper's pull and platform, and outputs no image"
t_assert_eq "--build-arg WHEELS_IMAGE=runtime_wheels --build-context runtime_wheels=${_root}/arm64 . " "$(_wheels_tail)" \
  "the wrapper mounts the staged directory and never the image"
t_assert_eq "${_IMAGE_HEAD}" "$(_head)" "every other wrapper argument is image mode's, byte for byte"
t_assert_contains "${_out}" "[wheels] arm64: files=2 bytes=3 sha256=" "the export logs what it staged"
t_assert_eq "wheels-export base package smoke wrapper " "$(_steps "${_out}")" \
  "every step prints its [runtime-timing] line, the export first: the A/B reads all five"
t_assert_eq "" "$(printf '%s\n' "${_out}" | grep '^LEFT ' || true)" "the arch's directory and seal are gone after the wrapper"
_out="$(RUNTIME_WHEELS_SOURCE='export' _run 'runtime_wheels_setup; r="${RUNTIME_WHEELS_EXPORT_ROOT}"; runtime_wheels_cleanup; [ -d "${r}" ] && echo KEPT || echo GONE')"
t_assert_contains "${_out}" "GONE" "the EXIT handler removes the root"
_fresh
RUNTIME_WHEELS_SOURCE='export' _run "${_LANE}" >/dev/null
t_assert_eq "" "$(_nth export | grep -F 'WHEELS_IMAGE=' || true)" "no pin, infix or variant: the export reads Dockerfile.torch's default, as image mode does"

t_case "export under ARTIFACT_CONTEXT_ROOT: the android layout, only when its digest is the image's"
_D1="sha256:$(printf '1%.0s' $(seq 64))"
_D2="sha256:$(printf '2%.0s' $(seq 64))"
_layout() { mkdir -p "${WORK}/aa-arm64"; : > "${WORK}/aa-arm64/oci-layout"; printf '%s' "$1" > "${WORK}/aa-arm64/index.json"; }
_fresh; _layout '{"schemaVersion":2,"manifests":[{"mediaType":"x","digest":"'"${_D1}"'","size":1}]}'
_out="$(RUNTIME_WHEELS_SOURCE='export' ARTIFACT_CONTEXT_ROOT="${WORK}/aa" INFIX=-hostarm64 LOCAL_DIGEST="${_D1}" _run "${_LANE}")"
t_assert_contains "$(_nth export | tr '\n' ' ')" "--build-arg WHEELS_IMAGE=runtime_artifact --build-context runtime_artifact=oci-layout://${WORK}/aa-arm64 . " \
  "the export takes the layout the package build reads"
t_assert_contains "$(cat "${NLOG}")" "image inspect --mode=native" "after reading the containerd image's digest"
t_assert_eq "" "$(grep -E '^(create|export) ' "${NLOG}" || true)" "and never streams the rootfs through nerdctl export"
t_assert_contains "$(_events)" "WRAPPER-SAW-WHEELS" "the wrapper still gets the staged directory"
_fresh; _layout '{"schemaVersion":2,"manifests":[{"mediaType":"x","digest":"'"${_D1}"'","size":1}]}'
_out="$(RUNTIME_WHEELS_SOURCE='export' ARTIFACT_CONTEXT_ROOT="${WORK}/aa" INFIX=-hostarm64 LOCAL_DIGEST="${_D2}" _run "${_LANE}")"
t_assert_contains "${_out}" "holds ${_D1}, but repo:cross-android-hostarm64-arm64 is ${_D2} in containerd" "a different image is refused, naming both"
t_assert_contains "${_out}" "CHAIN-RC=1" "and the arch fails"
t_assert_eq "TRAP runtime_wheels_cleanup," "$(_events)" "before any build"
_fresh; _layout '{"manifests":[{"digest":"'"${_D1}"'"},{"digest":"'"${_D2}"'"}]}'
_out="$(RUNTIME_WHEELS_SOURCE='export' ARTIFACT_CONTEXT_ROOT="${WORK}/aa" INFIX=-hostarm64 LOCAL_DIGEST="${_D1}" _run "${_LANE}")"
t_assert_contains "${_out}" "holds no single manifest" "a layout naming two manifests proves nothing"
_fresh; _layout '{}'
_out="$(RUNTIME_WHEELS_SOURCE='export' ARTIFACT_CONTEXT_ROOT="${WORK}/aa" ARTIFACT_CONTEXT_MODE=dir INFIX=-hostarm64 _run "${_LANE}")"
t_assert_contains "${_out}" "needs ARTIFACT_CONTEXT_MODE=oci" "a rootfs-directory artifact cannot be proved and is refused"

t_case "--no-push with the android tag published (the cross host's case): export refuses"
# A --no-push chain threads no pin, so runtime_android_pin falls back to the registry and
# names the PUBLISHED digest; this run's android is in containerd under its tag (_D1).
_R="repo@sha256:$(printf 'a%.0s' $(seq 64))"
for _pulled in "" 1; do
  _fresh; _layout '{"schemaVersion":2,"manifests":[{"mediaType":"x","digest":"'"${_D1}"'","size":1}]}'
  _out="$(RUNTIME_WHEELS_SOURCE='export' ARTIFACT_CONTEXT_ROOT="${WORK}/aa" PIN="${_R}" LOCAL_DIGEST="${_D1}" PINNED_PULLED="${_pulled}" _run "${_LANE}")"
  _want="not present"; [ -z "${_pulled}" ] || _want="${_R##*@}"
  t_assert_contains "${_out}" "holds ${_D1}, but ${_R} is ${_want} in containerd" "registry copy pulled='${_pulled}': the layout is never the digest the lane names"
  t_assert_contains "${_out}" "CHAIN-RC=1" "and the arch fails"
  t_assert_eq "TRAP runtime_wheels_cleanup," "$(_events)" "before its base build"
done
_fresh; _layout '{"schemaVersion":2,"manifests":[{"mediaType":"x","digest":"'"${_D1}"'","size":1}]}'
RUNTIME_WHEELS_SOURCE=image ARTIFACT_CONTEXT_ROOT="${WORK}/aa" PIN="${_R}" LOCAL_DIGEST="${_D1}" _run "${_LANE}" >/dev/null
t_assert_eq "--build-arg WHEELS_IMAGE=${_R} --build-context ${_R}=${WORK}/wheels-arm64 . " "$(_wheels_tail)" \
  "image mode there mounts the PUBLISHED android's wheelhouse (predates the knob, unchanged)"
t_assert_contains "$(cat "${NLOG}")" "create ${_R} /bin/true" "extracted from a container of the registry's digest"

t_case "a failed or empty export stops the arch before any image is built"
_fresh
_out="$(RUNTIME_WHEELS_SOURCE='export' PIN=repo@sha256:abc EXPORT_RC=1 _run "${_LANE}")"
t_assert_contains "${_out}" "CHAIN-RC=1" "the export build's failure is the arch's failure, even with wheels on disk"
t_assert_eq "TRAP runtime_wheels_cleanup,BUILD-BEGIN export," "$(_events)" "no base, package or wrapper after it"
t_assert_eq "" "$(printf '%s\n' "${_out}" | grep '^LEFT ' || true)" "and the partial export is removed"
_fresh
_out="$(RUNTIME_WHEELS_SOURCE='export' PIN=repo@sha256:abc EXPORT_WHEELS=0 _run "${_LANE}")"
t_assert_contains "${_out}" "no wheel in ${RUNTIME_CONTEXT_ROOT}/runtime-flow.wheels." "an export without a wheel is an error naming the directory"
t_assert_contains "${_out}" "/arm64/opt/wheels, exported from repo@sha256:abc" "and the image"
t_assert_eq "TRAP runtime_wheels_cleanup,BUILD-BEGIN export," "$(_events)" "and nothing is built after it"

t_case "the wrapper re-checks the seal: a changed, added or unsealed wheelhouse fails, with no fallback"
for _hook in 'printf x >> "${RUNTIME_WHEELS_EXPORT_ROOT}/arm64/opt/wheels/torch-2.9.0-cp314-cp314-linux_aarch64.whl"' \
             ': > "${RUNTIME_WHEELS_EXPORT_ROOT}/arm64/opt/wheels/stray-0-py3-none-any.whl"' \
             'rm -f "${RUNTIME_WHEELS_EXPORT_ROOT}/arm64.sha256"' \
             'rm -rf "${RUNTIME_WHEELS_EXPORT_ROOT}/arm64"'; do
  _fresh
  _out="$(RUNTIME_WHEELS_SOURCE='export' PIN=repo@sha256:abc PACKAGE_HOOK="${_hook}" _run "${_LANE}")"
  t_assert_contains "${_out}" "is missing or changed since its export" "${_hook%% *}"
  t_assert_eq "TRAP runtime_wheels_cleanup,BUILD-BEGIN export,STEP base,STEP package,STEP smoke," "$(_events)" \
    "no wrapper is built, neither from the directory nor from the image"
done

t_case "--push-all (no local context chain): setup, export and wrapper in ONE shell still agree"
_fresh
_out="$(RUNTIME_WHEELS_SOURCE='export' PIN=repo@sha256:abc PUSH_IMAGES=1 PUSH_INTERMEDIATE_IMAGES=1 _run "${_LANE}")"
_root="$(printf '%s\n' "${_out}" | sed -n 's/^ROOT=//p')"
t_assert_contains "$(_nth export | head -1)" "--pull=true" "the export pulls exactly when the wrapper does"
t_assert_eq "--build-arg WHEELS_IMAGE=runtime_wheels --build-context runtime_wheels=${_root}/arm64 . " "$(_wheels_tail)" \
  "the wrapper names the directory the export wrote, never /wheels-<arch>"
t_assert_contains "$(_events)" "WRAPPER-SAW-WHEELS,PUSH repo:latest-arm64," "and it was there when the wrapper built"

t_case "a dry run stages nothing and builds nothing"
_fresh
_out="$(RUNTIME_WHEELS_SOURCE='export' PIN=repo@sha256:abc DRY_RUN=1 _run "${_LANE}")"
t_assert_contains "${_out}" "[DRY RUN] would export /opt/wheels of repo@sha256:abc for arm64"
t_assert_eq "STEP base,STEP package,STEP smoke," "$(_events)" "no export and no wrapper build"
t_assert_eq "" "$(ls -A "${RUNTIME_CONTEXT_ROOT}" 2>/dev/null)" "and no root"

t_case "_runtime_timed keeps each step's rc, and the chain still stops at the first failure"
t_assert_contains "$(_run '_runtime_timed probe arm64 bash -c "exit 7"; echo "rc=$?"')" "rc=7"
_fresh
_out="$(_run 'runtime_build_package_image() { printf "STEP package\n" >> "${BLOG}"; return 1; }
runtime_build_chain arm64; echo "rc=$?"')"
t_assert_contains "${_out}" "[runtime-timing] arch=arm64 step=package secs=" "each step is timed"
t_assert_contains "${_out}" "rc=1" "a failed package fails the chain"
t_assert_eq "STEP base,STEP package," "$(_events)" "and no smoke or wrapper runs after it"

t_case "the Dockerfile half: one wheels-source, and the export stage copies from it"
_df="$(cat "${TORCH}")"
t_assert_eq 1 "$(grep -c '^FROM ${WHEELS_IMAGE} AS wheels-source$' "${TORCH}")" "the image both modes read is one FROM"
t_assert_eq "COPY --link --from=wheels-source /opt/wheels /opt/wheels" \
  "$(grep -A1 '^FROM scratch AS wheels-export$' "${TORCH}" | sed -n 2p)" "wheels-export copies exactly that stage's /opt/wheels"
t_assert_eq "FROM torch AS final" "$(grep '^FROM ' "${TORCH}" | tail -1)" "wheels-export is not the wrapper's default target"
t_assert_contains "$(grep -A2 -F 'from=wheels-source,source=/opt/wheels,target=/opt/wheels,rw' "${TORCH}" | sed -n 3p)" \
  'echo "[torch-run] start epoch=$(date -u +%s) arch=${TARGETARCH}"' "the torch RUN's first statement stamps its start"

t_case "the lanes: both runtime orchestrators set up and loop through the lib, the chain checks the knob first"
for _o in build-runtime-manifest.sh build-runtime-artifacts.sh; do
  t_assert_eq "  runtime_wheels_setup || exit \$?" "$(grep -A1 'runtime_post_parse_setup TARGET_ARCHES' "${SCRIPTS}/${_o}" | sed -n 2p)" "${_o} sets up after parsing"
  t_assert_eq "" "$(grep -n 'runtime_build_chain' "${SCRIPTS}/${_o}" || true)" "${_o} never calls runtime_build_chain around the lib"
done
t_assert_contains "$(cat "${SCRIPTS}/build-runtime-manifest.sh")" "run_parallel_arch_loop runtime_wheels_arch_chain "
t_assert_contains "$(t_fn_src "${SCRIPTS}/build-cross-chain.sh" _chain_validate_stages)" "runtime_wheels_source_mode >/dev/null || exit 2" \
  "a typo stops the chain at its start, not at the runtime lane hours later"
t_assert_contains "$(cat "${SCRIPTS}/lib-orchestrator.sh")" 'source "${_LIB_ORCHESTRATOR_DIR}/lib-runtime-wheels.sh"'
t_assert_eq "" "$(grep -ln 'lib-runtime-wheels\|source=linux/scripts,\|linux/scripts/ ' "${SCRIPTS}"/../Dockerfile* 2>/dev/null || true)" \
  "no image closure holds the lib, so editing it re-keys no stage"

t_case "setup-torch-venv.sh: the in-RUN wheelhouse line is never fatal and matches the host's"
_STV_FN="$(t_fn_src "${STV}" _stv_wheelhouse_line)" || exit 1
_WH="$(mktemp -d)"
printf a > "${_WH}/torch-2.9.0-cp314-cp314-linux_aarch64.whl"; printf bb > "${_WH}/onnxruntime-1.30.0-cp314-cp314-linux_aarch64.whl"
_strict() { bash -c "set -Eeuo pipefail; trap 'echo ERR-TRAP' ERR"$'\n'"$1"$'\n'"${_STV_FN}"$'\n'"_stv_wheelhouse_line $(printf '%q' "$2"); echo \"rc=\$?\"" 2>&1; }
_out="$(_strict ':' "${_WH}/absent")"
t_assert_eq $'[torch-venv] wheelhouse files=0 bytes=0 sha256=none\nrc=0' "${_out}" "a missing wheelhouse prints zeros"
_out="$(_strict 'find() { command find "$@"; return 3; }' "${_WH}")"
t_assert_contains "${_out}" "rc=0" "a failing find cannot kill the torch RUN"
t_assert_eq "" "$(printf '%s\n' "${_out}" | grep ERR-TRAP || true)" "nor trip its ERR trap"
_in="$(_strict ':' "${_WH}" | sed -n 's/^\[torch-venv\] wheelhouse //p')"
_host="$(_run "runtime_wheels_digest_line $(printf '%q' "${_WH}")")"
t_assert_eq "${_host}" "${_in}" "the in-RUN line and the host's [wheels] line agree on the same bytes"
t_assert_contains "${_in}" "files=2 bytes=3 sha256=" "and count what is there"
_MAIN="$(t_fn_src "${STV}" main)" || exit 1
t_assert_contains "${_MAIN}" $'  _stv_mark start\n  _stv_wheelhouse_line\n  setup_torch_venv\n' "the wheelhouse is described before anything prunes it"
for _step in setup_torch_venv seed_opencv5_bindings setup_torch_deps setup_torch_app stage_chain_ort_wheels bytecompile_venv cleanup_wheelhouse; do
  t_assert_contains "${_MAIN}" $'  '"${_step}"$'\n  _stv_mark '"${_step}" "${_step} is timed"
done
rm -rf "${_WH}"

rm -rf "${_LOGS}" "${_BIN}" "${ROOTFS}"
t_summary
