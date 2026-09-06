#!/usr/bin/env bash
set -euo pipefail

# smoke-runtime-image.sh
# Validates the runtime wrapper image: boot + metadata, then functional checks that
# run the ML stack, ffmpeg and GStreamer INSIDE the image (qemu for cross arches).
# RUNTIME_FUNCTIONAL_SMOKE=0 skips the functional half; ALLOW_TORCHLESS_RUNTIME=1
# accepts a torch-less image. What each gate covers:
# docs/cross-build-verification.md#in-image-smoke-tests-need-a-built-image-not-part-of-preflight
#
# Usage:
#   smoke-runtime-image.sh <image-tag> [target-arch]
#   smoke-runtime-image.sh ghcr.io/kataglyphis/kataglyphis_beschleuniger:latest-cross-arm64 arm64

_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${_SCRIPT_DIR}/smoke-common.sh"

NERDCTL_BIN="${NERDCTL_BIN:-nerdctl}"

: "${RUNTIME_CLANG_VERSION_SMOKE:=1}"
: "${RUNTIME_COMPILER_SMOKE:=1}"

# Evaluate a python expression against the image's `nerdctl image inspect` JSON (the
# [0] element on stdin). Uses the caller's ${image_tag} dynamically; empty on any error.
inspect_image_config() {
  "${NERDCTL_BIN}" image inspect "${image_tag}" 2>/dev/null | python3 -c "$1" 2>/dev/null || true
}

# Run a command inside the image under test. Leading `-e KEY=VAL` / `--network X`
# pairs are forwarded to nerdctl run; uses the caller's ${image_tag}/${target_arch}.
_rt_run() {
  local -a _opts=()
  while [ "${1:-}" = "-e" ] || [ "${1:-}" = "--network" ]; do
    _opts+=("$1" "$2")
    shift 2
  done
  "${NERDCTL_BIN}" run --rm --platform "linux/${target_arch}" \
    ${_opts[@]+"${_opts[@]}"} "${image_tag}" "$@"
}

# Host-side versions.env pin reader: env wins, then the file, EMPTY on a miss --
# callers must treat empty as "not asserted". docs/gen1-riscv64-genai.md
_rt_versions_env_pin() {
  local _key="$1" _val="${!1:-}" _venv
  if [ -z "${_val}" ]; then
    _venv="$(cd "$(dirname "${BASH_SOURCE[0]}")/../01-core" 2>/dev/null && pwd)/versions.env"
    [ -f "${_venv}" ] && _val="$(grep -E "^${_key}=" "${_venv}" | head -1 | cut -d= -f2 || true)"
  fi
  printf '%s' "${_val}"
}

# Set by check_torchless_sentinel (1 = torch expected, 0 = sentinel present); read by
# the app-wheel-smoke and version-pin sections.
_SMOKE_TORCH_EXPECTED=1

check_image_availability() {
  local image_tag="$1"
  local target_arch="$2"
  echo "--- Image availability ---"
  if ! "${NERDCTL_BIN}" image inspect "${image_tag}" >/dev/null 2>&1; then
    echo "  Pulling ${image_tag}..."
    "${NERDCTL_BIN}" pull --platform "linux/${target_arch}" "${image_tag}" || {
      fail "Cannot pull image ${image_tag}"
      smoke_summary
    }
  fi
  pass "Image ${image_tag} available"
  echo ""
}

check_trivial_command() {
  local image_tag="$1"
  local target_arch="$2"
  echo "--- Trivial command ---"
  if _rt_run /bin/true 2>/dev/null; then
    pass "Container can run /bin/true"
  else
    fail "Container cannot run /bin/true"
  fi
  echo ""
}

check_entrypoint() {
  local image_tag="$1"
  local target_arch="$2"
  echo "--- Entrypoint ---"
  local config
  config="$(inspect_image_config "import sys,json; print(json.load(sys.stdin)[0].get('Config',{}).get('Entrypoint',''))")"
  if [ -n "${config}" ]; then
    pass "Entrypoint configured: ${config}"
  else
    fail "No entrypoint configured"
  fi
  echo ""
}

# Boot the image the way a USER does: no command, so the shipped ENTRYPOINT runs the
# shipped CMD. Every other check passes an explicit argv, so entrypoint.sh's own
# default path was never executed by the gate and a broken one shipped green. The probe
# arrives on STDIN so the default CMD shell reads it, and `exit 42` proves the exec
# chain hands the child's status back. A gate may not skip itself: a missing CMDOK
# marker (inspect failed) or a CMD whose first word is not a shell FAILS.
# Pure verdict function for the default-boot gate: rc + probe text in, one
# pass/fail out. No container, so the reasoning is unit-testable -- which is how
# the previous version's inert assertion would have been caught.
_boot_verdict() {
  local rc="$1" out="$2" target_arch="$3"
  if [ "${rc}" != "42" ]; then
    fail "default ENTRYPOINT+CMD boot returned ${rc}, expected the script's 42 (${target_arch}) -- entrypoint.sh does not exec the CMD or died before it: ${out}"
  elif ! printf '%s' "${out}" | grep -q "gstma=yes"; then
    # NOT gst=set / vulkan=set: the image ENV sets both on its own, so those
    # answer yes even with the entrypoint's sourcing gone. The multiarch plugin
    # dir comes only from gstreamer-env.sh. docs/refactoring-backlog.md XQ
    fail "the entrypoint did not source gstreamer-env.sh (${target_arch}): ${out} -- GST_PLUGIN_PATH lacks the multiarch dir"
  elif ! printf '%s' "${out}" | grep -q "vkres=yes"; then
    fail "the entrypoint did not resolve VULKAN_SDK past /opt/vulkan/active (${target_arch}): ${out}"
  else
    pass "default ENTRYPOINT+CMD boot: ${out} (exit status propagated)"
  fi
}

check_default_entrypoint_boot() {
  local image_tag="$1"
  local target_arch="$2"
  echo "--- Default ENTRYPOINT + CMD boot ---"
  local raw cmd cmd0
  raw="$(inspect_image_config "import sys,json; c=json.load(sys.stdin)[0].get('Config',{}) or {}; print('CMDOK ' + ' '.join(c.get('Cmd') or []))")"
  case "${raw}" in
    "CMDOK "*) cmd="${raw#CMDOK }" ;;
    *)
      fail "default ENTRYPOINT+CMD boot: could not read Config.Cmd from \`${NERDCTL_BIN} image inspect ${image_tag}\` (${target_arch}) -- the boot probe cannot be skipped just because inspect failed"
      echo ""
      return 0
      ;;
  esac
  cmd0="${cmd%% *}"
  case "${cmd0}" in
    # Empty CMD is legitimate: entrypoint.sh's own `[ $# -eq 0 ]` fallback then
    # supplies /bin/bash, which is still a shell reading our stdin.
    ""|bash|sh|*/bash|*/sh) ;;
    *)
      fail "default ENTRYPOINT+CMD boot: image CMD is '${cmd}' but this probe needs a shell to read its stdin script (${target_arch}) -- Dockerfile.torch ships CMD [\"/bin/bash\"]; if the CMD changed on purpose, update this check instead of letting it self-disable"
      echo ""
      return 0
      ;;
  esac
  local out rc
  out="$(printf '%s\n' \
           'echo "BOOT uid=$(id -u) gst=${GST_PLUGIN_PATH:+set} vulkan=${VULKAN_SDK:+set}"' \
    'case "${GST_PLUGIN_PATH}" in *linux-gnu/gstreamer-1.0*) echo "gstma=yes";; *) echo "gstma=no";; esac' \
    'case "${VULKAN_SDK}" in /opt/vulkan/active|"") echo "vkres=no";; *) echo "vkres=yes";; esac' \
           'exit 42' \
         | "${NERDCTL_BIN}" run --rm -i --platform "linux/${target_arch}" "${image_tag}" 2>/dev/null)" \
    && rc=0 || rc=$?
  _boot_verdict "${rc}" "${out}" "${target_arch}"
  echo ""
}

# The image's OWN healthcheck command. Test[0] is the OCI verb (CMD / CMD-SHELL);
# the probe is what follows it, and reading only [0] can distinguish 'a HEALTHCHECK
# exists' from 'none' but never right from wrong. docs/refactoring-backlog.md WE
_rt_healthcheck_cmd() {
  inspect_image_config "import sys,json; cfg=json.load(sys.stdin)[0].get('Config',{}); t=(cfg.get('Healthcheck') or {}).get('Test') or []; print(' '.join(t[1:]) if len(t) > 1 else '')"
}

check_healthcheck_config() {
  local image_tag="$1"
  local target_arch="$2"
  echo "--- HEALTHCHECK ---"
  local healthcheck
  healthcheck="$(_rt_healthcheck_cmd)"
  if [ -n "${healthcheck}" ]; then
    pass "HEALTHCHECK configured: ${healthcheck}"
  else
    fail "No HEALTHCHECK command configured (Test[0] alone is the OCI verb, not a probe)"
  fi
  echo ""
}

check_kataglyphis_user() {
  local image_tag="$1"
  local target_arch="$2"
  echo "--- kataglyphis user ---"
  if _rt_run id -u kataglyphis >/dev/null 2>&1; then
    pass "kataglyphis user exists"
  else
    fail "kataglyphis user not found"
  fi
  echo ""
}

check_workdir() {
  local image_tag="$1"
  local target_arch="$2"
  echo "--- WORKDIR ---"
  local workdir
  workdir="$(inspect_image_config "import sys,json; print(json.load(sys.stdin)[0].get('Config',{}).get('WorkingDir',''))")"
  if [ -n "${workdir}" ]; then
    pass "WORKDIR: ${workdir}"
  else
    echo "  INFO: No WORKDIR set"
  fi
  echo ""
}

check_volume() {
  local image_tag="$1"
  local target_arch="$2"
  echo "--- VOLUME ---"
  local volumes
  volumes="$(inspect_image_config "import sys,json; vols=json.load(sys.stdin)[0].get('Config',{}).get('Volumes',''); print(':'.join(vols.keys()) if vols and isinstance(vols,dict) else 'NONE')")"
  if [ -n "${volumes}" ] && [ "${volumes}" != "NONE" ]; then
    pass "VOLUME: ${volumes}"
  else
    echo "  INFO: No VOLUME set"
  fi
  echo ""
}

check_oci_labels() {
  local image_tag="$1"
  local target_arch="$2"
  echo "--- OCI labels ---"
  local labels
  labels="$(inspect_image_config "import sys,json; lbs=json.load(sys.stdin)[0].get('Config',{}).get('Labels',{}); [print(f'{k}={v}') for k,v in sorted(lbs.items())]")"
  if [ -n "${labels}" ]; then
    local label_count
    label_count="$(echo "${labels}" | wc -l)"
    pass "${label_count} OCI label(s) configured"
  else
    fail "No OCI labels configured"
  fi
  echo ""
}

check_torchless_sentinel() {
  local image_tag="$1"
  local target_arch="$2"
    echo "--- Functional: torch-less sentinel (A3) ---"
    _SMOKE_TORCH_EXPECTED=1
    if _rt_run \
         test -f /opt/venv/.torch-missing >/dev/null 2>&1; then
      _SMOKE_TORCH_EXPECTED=0
      if [ "${ALLOW_TORCHLESS_RUNTIME:-0}" = "1" ]; then
        echo "  INFO: /opt/venv/.torch-missing present -- image ships WITHOUT torch (allowed)"
      else
        fail "Image ships WITHOUT torch (/opt/venv/.torch-missing present); set ALLOW_TORCHLESS_RUNTIME=1 to accept"
      fi
    else
      pass "No torch-less sentinel (torch expected in image)"
    fi
    echo ""
}

# Wheel smoke -- delegate to the APP's own smoke module (single source of truth):
# `python -m orchestrant.smoke` exercises each shipped wheel with REAL work, and
# the app OWNS what its wheels must do. Torch-less images fall back to a bare
# onnx/numpy import, since the suite treats torch as required.
check_app_wheel_smoke() {
  local image_tag="$1"
  local target_arch="$2"
    if [ "${_SMOKE_TORCH_EXPECTED}" = "1" ]; then
      echo "--- Functional: app wheel smoke (python -m orchestrant.smoke) ---"
      # RATCHET on the ok-count, not the exit status: the smoke exits 0 whenever
      # failures==0 and reports a vanished component as a WARNING, so one identical
      # PASS covered 15/15, 14/15 and 12/15. Floors may only ever go UP - raise one
      # when an arch gains a component, never to make a red run green.
      # GEN1: riscv64 12->13 (run 20260903 printed 14); arm64 held at 14.
      # docs/gen1-riscv64-genai.md#the-app-wheel-floor
      local _wheel_floor _wheel_out _wheel_ok
      case "${target_arch}" in
        amd64)   _wheel_floor=15 ;;
        arm64)   _wheel_floor=14 ;;
        riscv64) _wheel_floor=13 ;;
        *)       _wheel_floor=0  ;;
      esac
      if _wheel_out="$(_rt_run /opt/venv/bin/python -m orchestrant.smoke 2>&1)"; then
        printf '%s\n' "${_wheel_out}"
        _wheel_ok="$(printf '%s\n' "${_wheel_out}" | sed -n 's/.*=== \([0-9]\{1,\}\)\/[0-9]\{1,\} ok.*/\1/p' | tail -1)"
        # An unreadable count must FAIL. Falling through to pass would leave only the
        # exit status, which is what this ratchet exists to distrust.
        if [ -z "${_wheel_ok}" ]; then
          fail "app wheel smoke on ${target_arch}: could not read the ok-count from its summary; the ratchet cannot arm"
        elif [ "${_wheel_ok}" -lt "${_wheel_floor}" ] 2>/dev/null; then
          fail "app wheel smoke degraded on ${target_arch}: ${_wheel_ok} ok, floor ${_wheel_floor}"
        else
          pass "app wheel smoke passed on-target (${target_arch}, ${_wheel_ok} ok >= ${_wheel_floor})"
        fi
      else
        fail "app wheel smoke FAILED in the runtime image (${target_arch})"
      fi
    else
      echo "--- Functional: ML imports (torch-less image) ---"
      if _rt_run \
           /opt/venv/bin/python -c "import onnxruntime, numpy; print('onnxruntime', onnxruntime.__version__, '| numpy', numpy.__version__)"; then
        pass "onnxruntime + numpy import OK (torch-less, ${target_arch})"
      else
        fail "onnxruntime/numpy failed to import in the runtime image (${target_arch})"
      fi
    fi
    echo ""
}

# Run ONE real inference owned by THIS repo: smoke_minimal_onnx_py emits a one-node Add
# graph as raw protobuf (no `onnx` package, no network, ~110 model bytes) and is injected
# as an env var, so this gate also works against images built before the check existed.
# EXIT STATUS IS NOT EVIDENCE: if SMOKE_ONNX_PY arrives empty, `python -` reads an EMPTY
# program and exits 0 - the "green because nothing ran" class. A pass therefore demands
# the `ONNX-EP OK:` sentinel in the program's OUTPUT, whatever the exit status says.
check_onnx_execution_provider() {
  local image_tag="$1"
  local target_arch="$2"
    echo "--- Functional: onnxruntime InferenceSession (generated Add graph) ---"
    local out rc sentinel
    out="$(_rt_run -e "SMOKE_ONNX_PY=$(smoke_minimal_onnx_py)" \
             bash -lc 'if [ -z "${SMOKE_ONNX_PY:-}" ]; then
  echo "ONNX-EP ABSENT: SMOKE_ONNX_PY is empty inside the container -- the program never crossed the boundary"
  exit 4
fi
printf "%s\n" "${SMOKE_ONNX_PY}" | /opt/venv/bin/python -' 2>&1)" \
      && rc=0 || rc=$?
    printf '%s\n' "${out}" | sed 's/^/  /'
    sentinel="$(printf '%s\n' "${out}" | grep -Eo 'ONNX-EP (OK|FAIL|SKIP|ABSENT):.*' | head -1 || true)"
    if [ -z "${sentinel}" ]; then
      fail "onnxruntime session check exited ${rc} but printed NO ONNX-EP sentinel (${target_arch}) -- the generated program did not run; an exit 0 here means python got an EMPTY stdin, not a working provider"
    elif [ "${rc}" = "0" ]; then
      case "${sentinel}" in
        "ONNX-EP OK:"*)
          pass "onnxruntime executed a real graph on-target (${target_arch}) -- ${sentinel}" ;;
        *)
          fail "onnxruntime session check exited 0 but reported '${sentinel}' (${target_arch}) -- a non-OK verdict must never pass" ;;
      esac
    elif [ "${rc}" = "3" ]; then
      # Not a skip in a WRAPPER: the image's own HEALTHCHECK is `import onnxruntime`,
      # so an unimportable onnxruntime means every container would report unhealthy.
      fail "onnxruntime/numpy not importable in the runtime image (${target_arch}) -- the HEALTHCHECK imports onnxruntime, so this is a defect: ${sentinel}"
    else
      fail "onnxruntime InferenceSession FAILED on the generated Add graph (${target_arch}, rc=${rc}): ${sentinel}"
    fi
    echo ""
}

# GEN1: the onnxruntime-genai binding gate (payload smoke_genai_py), every arch.
# Exit status is not evidence -- a pass demands the GENAI-BIND sentinel in the
# OUTPUT. docs/gen1-riscv64-genai.md
check_genai_binding() {
  local image_tag="$1"
  local target_arch="$2"
    echo "--- Functional: onnxruntime-genai native binding (GEN1) ---"
    local expect_version out rc sentinel
    expect_version="$(_rt_versions_env_pin ONNXRUNTIME_GENAI_VERSION)"
    out="$(_rt_run -e "SMOKE_GENAI_PY=$(smoke_genai_py)" \
             -e "GENAI_EXPECT_VERSION=${expect_version}" \
             -e "GENAI_EXPECT_ARCH=${target_arch}" \
             bash -lc 'if [ -z "${SMOKE_GENAI_PY:-}" ]; then
  echo "GENAI-BIND ABSENT: SMOKE_GENAI_PY is empty inside the container -- the program never crossed the boundary"
  exit 4
fi
printf "%s\n" "${SMOKE_GENAI_PY}" | /opt/venv/bin/python -' 2>&1)" \
      && rc=0 || rc=$?
    printf '%s\n' "${out}" | sed 's/^/  /'
    sentinel="$(printf '%s\n' "${out}" | grep -Eo 'GENAI-BIND (OK|FAIL|SKIP|ABSENT):.*' | head -1 || true)"
    if [ -z "${sentinel}" ]; then
      fail "onnxruntime-genai binding check exited ${rc} but printed NO GENAI-BIND sentinel (${target_arch}) -- the generated program did not run; an exit 0 here means python got an EMPTY stdin, not a working binding"
    elif [ "${rc}" = "0" ]; then
      case "${sentinel}" in
        "GENAI-BIND OK:"*)
          pass "onnxruntime-genai native binding exercised on-target (${target_arch}) -- ${sentinel}" ;;
        *)
          fail "onnxruntime-genai binding check exited 0 but reported '${sentinel}' (${target_arch}) -- a non-OK verdict must never pass" ;;
      esac
    elif [ "${rc}" = "3" ]; then
      echo "  SKIP: onnxruntime_genai not installed in this image (${target_arch}); presence is asserted by ARCH-PARITY, not here"
    else
      fail "onnxruntime-genai binding check FAILED (${target_arch}, rc=${rc}): ${sentinel}"
    fi
    echo ""
}

# Not just "importable" but the CORRECT versions: delegate to smoke-torch-venv.sh's
# assert-only mode, which catches a wrong version slipping in (lock drift, a stale local
# wheel, a floated index). Which authority owns which pin, and why they are no longer
# unioned: docs/cross-build-verification.md, "In-image smoke tests".
check_ml_version_pins() {
  local image_tag="$1"
  local target_arch="$2"
    if [ "${_SMOKE_TORCH_EXPECTED}" = "1" ]; then
      echo "--- Functional: ML version-pin assertion (${target_arch}) ---"
      # nerdctl run inherits nothing, and the toggle is ARG/ENV on a BUILDER
      # stage only, so forward it explicitly. docs/failure-modes.md
      # Only forward a NON-EMPTY pin: an empty value would reach the container
      # as a set-but-empty var, and the consumer treats anything != "true" as
      # "lane off" -- i.e. a failed versions.env lookup would silently DISARM
      # the riscv64 genai assertion. Fail safe, not open. docs/failure-modes.md
      _stv_pin="$(_rt_versions_env_pin GENAI_ALLOW_RISCV64)"
      _stv_env=()
      [ -n "${_stv_pin}" ] && _stv_env=(-e "GENAI_ALLOW_RISCV64=${_stv_pin}")
      _stv_out="$(_rt_run "${_stv_env[@]}" \
           bash -lc 'STV_ASSERT_ONLY=1 STV_CV2_REQUIRED=0 bash /opt/scripts/packaging/smoke-torch-venv.sh' 2>&1)" \
        && _stv_rc=0 || _stv_rc=$?
      printf '%s\n' "${_stv_out}"
      if [ "${_stv_rc}" -eq 0 ]; then
        pass "ML-stack versions match pins (${target_arch})"
      else
        # GEN1: the transitional riscv64 genai exemption is gone -- a missing
        # riscv64 wheel is now a real defect. docs/gen1-riscv64-genai.md
        fail "ML-stack version-pin assertion FAILED in the runtime image (${target_arch})"
      fi
      echo ""
    fi
}

# IREE native tools -- the C side of what check_iree exercises in Python: iree-compile
# lowers a one-op MLIR module and iree-run-module executes it (abs(-5)=5), proving the
# compiled binaries interoperate on-target. GATES when the tools are present, WARN-only
# when absent (the cross lane ships runtime-only).
check_iree_native() {
  local image_tag="$1"
  local target_arch="$2"
    echo "--- Functional: IREE native compile + run (iree-compile/iree-run-module) ---"
    if iree_out="$(_rt_run \
         bash -lc 'set -o pipefail
ic="$(command -v iree-compile || echo /opt/venv/bin/iree-compile)"
ir="$(command -v iree-run-module || echo /opt/venv/bin/iree-run-module)"
{ [ -x "$ic" ] && [ -x "$ir" ]; } || { echo "IREE_NATIVE_TOOLS_ABSENT"; exit 3; }
d="$(mktemp -d)"
cat > "$d/abs.mlir" <<MLIR
func.func @abs(%input : tensor<1xf32>) -> tensor<1xf32> {
  %result = math.absf %input : tensor<1xf32>
  return %result : tensor<1xf32>
}
MLIR
"$ic" --iree-hal-target-backends=llvm-cpu "$d/abs.mlir" -o "$d/abs.vmfb" || exit 1
o="$("$ir" --module="$d/abs.vmfb" --function=abs --input=1xf32=-5.0 2>&1)" || { echo "$o"; exit 1; }
echo "$o"
echo "$o" | grep -Eq "\b5(\.0+)?\b" || exit 2' 2>&1)"; then
      pass "IREE native compile+run OK (abs(-5)=5) (${target_arch})"
    else
      if printf '%s' "${iree_out}" | grep -q IREE_NATIVE_TOOLS_ABSENT; then
        echo "  WARN IREE native tools (iree-compile/iree-run-module) absent (${target_arch}) -- riscv64 compiler is best-effort; check_iree stays optional-fail there (non-fatal)"
      elif [ "${target_arch}" = "riscv64" ]; then
        # WARN, don't fail, on riscv64: this runs the riscv64 iree-compile under QEMU,
        # which advertises a synthetic max-ISA CPU that LLVM's RISC-V subtarget rejects
        # ("64-bit code requested on a subtarget that doesn't support it"). An emulation
        # limit, not a wheel defect - the wheels still build, install and import here,
        # so codegen has to be verified on real hardware. amd64/arm64 keep GATING.
        echo "  WARN IREE native compile/run FAILED under QEMU on riscv64 (non-fatal) --"
        echo "       cp314 wheels build/install/import; codegen unverifiable under QEMU's"
        echo "       synthetic max-ISA CPU (LLVM RISC-V subtarget rejects it). Verify on-device."
        printf '%s\n' "${iree_out}" | tail -6
      else
        fail "IREE native tools present but compile/run FAILED (${target_arch})"
        printf '%s\n' "${iree_out}" | tail -6
      fi
    fi
    echo ""
}

check_ffmpeg() {
  local image_tag="$1"
  local target_arch="$2"
    echo "--- Functional: ffmpeg ---"
    # pipefail is REQUIRED: without it `ffmpeg -version | head -1` returns head's 0 and
    # a binary with a missing .so (libopencore-amrwb.so.0, 2026-07-11) silently PASSES.
    if _rt_run \
         bash -lc 'set -o pipefail; v="$(command -v ffmpeg || echo /opt/ffmpeg/bin/ffmpeg)"; "$v" -version | head -1'; then
      pass "ffmpeg executes (${target_arch})"
    else
      fail "ffmpeg failed to execute in the runtime image (${target_arch})"
    fi
    echo ""
}

# Flutter must run as the image user, OFFLINE, on the target-arch Dart SDK the
# package stage cached, and be USABLE by that user: an x86-64 dart in the arm64
# image still executes on this host, and `flutter --version` ran fine while
# `flutter pub get` was denied a root-owned .dart_tool nobody can fix at runtime.
# docs/artifact-copy-completeness.md#bootstrapping-flutter-in-the-package-stage
check_flutter() {
  local image_tag="$1"
  local target_arch="$2"
  local pin machine out
  echo "--- Functional: flutter SDK ---"
  if [ "${target_arch}" = "riscv64" ]; then
    if _rt_run bash -lc 'command -v flutter >/dev/null 2>&1'; then
      fail "flutter present on riscv64 — upstream ships no riscv64 SDK; the image must not advertise it"
    else
      pass "flutter honestly absent on riscv64 (upstream unsupported)"
    fi
    echo ""
    return 0
  fi
  pin="$(_rt_versions_env_pin FLUTTER_VERSION)"
  machine="$(smoke_elf_machine_grep "${target_arch}")"
  out="$(_rt_run --network none bash -lc 'flutter --suppress-analytics --version 2>&1 | grep -m1 -E "^Flutter "; LC_ALL=C readelf -h /opt/flutter/bin/cache/dart-sdk/bin/dart 2>&1 | grep -m1 Machine; for d in /opt/flutter/bin/cache /opt/flutter/packages/flutter_tools/.dart_tool; do [ -w "$d" ] || printf "UNWRITABLE %s\n" "$d"; done; find /opt/flutter ! -user "$(id -u)" -printf "FOREIGN %p\n" 2>/dev/null | head -3' 2>&1 || true)"
  if ! printf '%s\n' "${out}" | grep -qE "^Flutter ${pin:-[0-9]}"; then
    fail "flutter does not run offline as the image user, or is not FLUTTER_VERSION=${pin:-?} (${target_arch}): $(printf '%s' "${out}" | head -1)"
  elif ! printf '%s\n' "${out}" | grep -qF "${machine}"; then
    fail "the cached Dart SDK is not ${machine} on ${target_arch}: $(printf '%s\n' "${out}" | sed -n 2p) -- bootstrapped on the wrong arch"
  elif printf '%s\n' "${out}" | grep -q '^UNWRITABLE '; then
    fail "the shipped SDK is not writable by the image user (${target_arch}): $(printf '%s\n' "${out}" | grep '^UNWRITABLE ' | tr '\n' ' ') -- flutter pub get dies with 'package_config.json (OS Error: Permission denied)', and the dir is in a read-only layer no consumer can chown"
  elif printf '%s\n' "${out}" | grep -q '^FOREIGN '; then
    fail "the shipped SDK still holds paths the image user does not own (${target_arch}): $(printf '%s\n' "${out}" | grep '^FOREIGN ' | tr '\n' ' ') -- a root-run flutter or git command wrote them AFTER the COPY --chown"
  else
    pass "flutter ${pin:-(unpinned)} runs offline as the image user on a ${machine} Dart SDK, whole SDK owned and writable by that user (${target_arch})"
  fi
  echo ""
}

# The Rust toolchain must be the image's OWN arch and run: every arm64/riscv64
# image before 2026-09-03 carried the builder's x86_64 rustup (2 GB, exit 127),
# and the ADV/HAVE table only SKIPs an unreadable rustc. Executes the pinned
# rustc and reads the active toolchain's host triple. docs/failure-modes.md#the-copied-rust-toolchain-is-the-builders-arch
check_rust_toolchain() {
  local image_tag="$1"
  local target_arch="$2"
  local triple pin out
  echo "--- Functional: rust toolchain ---"
  triple="$(smoke_rust_target "${target_arch}")"
  pin="$(_rt_versions_env_pin RUST_VERSION)"
  out="$(_rt_run bash -lc 'rustc --version 2>&1 | head -1; rustup show active-toolchain 2>&1 | head -1; command -v cargo-cbuild' 2>&1 || true)"
  if ! printf '%s\n' "${out}" | grep -qE "^rustc ${pin:-[0-9]}"; then
    fail "rustc does not run or is not RUST_VERSION=${pin:-?} in the ${target_arch} image: $(printf '%s' "${out}" | head -1)"
  elif ! printf '%s\n' "${out}" | grep -qF -- "-${triple}"; then
    fail "the active rust toolchain is not ${triple} on ${target_arch}: $(printf '%s\n' "${out}" | sed -n 2p) -- the builder's toolchain was shipped instead of a native one"
  elif ! printf '%s\n' "${out}" | grep -qE '^/.*/cargo-cbuild$'; then
    fail "cargo-cbuild missing on ${target_arch} (apt cargo-c fallback did not link)"
  else
    pass "rustc ${pin} runs natively as ${triple} with cargo-cbuild (${target_arch})"
  fi
  echo ""
}

# ── CONSUMER CONTRACT (2026-09-04) ───────────────────────────────────────────
# The properties a consuming CI lane depends on and cannot repair from outside the
# image: caches outside the bind-mounted checkout, a writable Rust home, a set
# ANDROID_HOME, and a Flutter SDK the runtime uid owns. All four shipped broken.
# docs/consumer-image-contract.md#the-contract
_CONSUMER_CONTRACT_ROWS="ccache-dir sccache-dir rustup-tmp cargo-home android-home jdk appimagetool dart-tool flutter-owner flatpak-runtimes appimage-runtime web-lane-tools"

# Rows whose entire contract is "this is staged in the image, or every consumer run
# pays for it again". One owner for all three: the verdict has the same shape, and
# the cost is already written down once in _consumer_contract_symptom.
# docs/consumer-image-contract.md#what-the-image-stages-so-a-run-does-not
_consumer_present_verdict() {
  local row="$1" got="$2"
  case "${got}" in
    ''|0|no) printf 'FAIL %s absent -- %s' "${row}" "$(_consumer_contract_symptom "${row}")" ;;
    *)       printf 'OK %s %s' "${row}" "${got}" ;;
  esac
}

# The consumer-visible failure each row prevents, quoted verbatim from the lane that
# hit it, so a red run names the symptom in the OTHER repo and not just our path.
# docs/consumer-image-contract.md#the-contract
_consumer_contract_symptom() {
  case "$1" in
    ccache-dir|sccache-dir) printf '%s' 'the cache lands in the consumer checkout and flatpak-builder aborts: "Can'"'"'t initialize ccache use: Failed to set permissions of .../ccache.conf: Operation not permitted"' ;;
    rustup-tmp)    printf '%s' 'rustup dies with "could not create temp file ...: Permission denied (os error 13)" and Corrosion / cargokit / flutter_rust_bridge_codegen cannot run; redirecting the var does not help, the toolchains live there' ;;
    cargo-home)    printf '%s' 'every consumer has to pass -e CARGO_HOME=... to work around it' ;;
    android-home)  printf '%s' '"flutter build apk" stops with "[!] No Android SDK found"; under CodeQL database create that surfaces three steps later as "bundle source directory not found"' ;;
    jdk)           printf '%s' 'Gradle stops the Android lane with "ERROR: JAVA_HOME is not set and no '"'"'java'"'"' command could be found in your PATH", and flutter doctor reports "No Java Development Kit (JDK) found" -- the SDK COPY leaves the source stage'"'"'s JDK behind in /usr/lib/jvm' ;;
    appimagetool)  printf '%s' 'appimagetool is an AppImage: it reads /proc/self/exe for its own squashfs offset, so a mode that is executable but not READABLE gives "Cannot open /proc/self/exe: Permission denied" and no .AppImage is produced' ;;
    dart-tool)     printf '%s' '"flutter pub get" fails with "Cannot open file ... package_config.json (OS Error: Permission denied, errno = 13)"' ;;
    flutter-owner) printf '%s' 'a root-owned path in a read-only overlay layer a consumer can neither chown, empty nor rename -- the only workaround is mounting a tmpfs over it' ;;
    flatpak-runtimes) printf '%s' 'flatpak list --runtime returns 0 refs, so every run re-downloads seven org.freedesktop refs (~1.9 GB) -- the single largest download in a consumer build' ;;
    appimage-runtime) printf '%s' 'appimagetool refetches runtime-<arch> from the type2-runtime continuous release on every build, so packaging hangs on GitHub being reachable' ;;
    web-lane-tools) printf '%s' 'flutter_rust_bridge_codegen build-web cargo-installs wasm-pack (258 crates) and itself (174) from source in every run' ;;
    *)             printf '%s' 'no symptom recorded for this row' ;;
  esac
}

# Documented per-arch absences, same contract as _parity_exempt: listed = reviewed,
# and an arm that STOPS applying fails so the table cannot rot. Key is <arch>:<row>.
# docs/consumer-image-contract.md#per-arch-exemptions
_consumer_contract_exempt() {
  case "$1:$2" in
    # Upstream publishes no riscv64 Flutter SDK, so the .dart_tool directory the row
    # asks about does not exist there and the row would read as unwritable.
    # flutter-owner is NOT exempt: measured on the shipped riscv64 image, the row
    # already holds. docs/consumer-image-contract.md#per-arch-exemptions
    riscv64:dart-tool) return 0 ;;
    # AppImage publishes no riscv64 build either: packaging-deps.sh's asset table
    # covers x86_64/aarch64/armhf/i686 and refuses the rest, so the tool is absent
    # there by construction and the AppImage format is not offered on riscv64.
    riscv64:appimagetool) return 0 ;;
    # Flathub builds the freedesktop runtimes for x86_64 and aarch64 only, and the
    # AppImage runtime is carved out of the appimagetool AppImage, which riscv64
    # does not have either. Both are absent there by construction.
    riscv64:flatpak-runtimes) return 0 ;;
    riscv64:appimage-runtime) return 0 ;;
    *) return 1 ;;
  esac
}

# The probe FACT that re-checks one exempted row. An exemption re-checked by ANOTHER
# row's fact cannot rot at all — appimagetool's was read from FACT flutter-sdk.
_consumer_exempt_fact() {
  case "$1" in
    appimagetool) printf '%s' 'appimagetool-readable' ;;
    *)            printf '%s' 'flutter-sdk' ;;
  esac
}

# Facts only, ONE process in the image: what the contract-bearing vars say, a REAL
# create+delete in each directory (access(2) answers yes for root and lies about a
# read-only layer), and who owns the Flutter tree. Verdicts are reached on the host.
# docs/consumer-image-contract.md#the-contract
_consumer_contract_probe() {
  cat <<'PROBE'
set -uo pipefail
_u="$(id -u)"
printf 'WHO %s %s\n' "${_u}" "$(id -un 2>/dev/null)"
_w() {
  _t="$2/.contract-probe.$$"
  if [ -n "$2" ] && [ -d "$2" ] && : > "${_t}" 2>/dev/null; then
    rm -f "${_t}"
    printf 'WRITE %s yes\n' "$1"
  else
    printf 'WRITE %s no\n' "$1"
  fi
  printf 'ENV %s %s\n' "$1" "${2:-}"
}
_w ccache-dir  "${CCACHE_DIR:-}"
_w sccache-dir "${SCCACHE_DIR:-}"
_w rustup-tmp  "${RUSTUP_HOME:+${RUSTUP_HOME}/tmp}"
_w cargo-home  "${CARGO_HOME:-}"
_w dart-tool   /opt/flutter/packages/flutter_tools/.dart_tool
printf 'ENV android-home %s\n' "${ANDROID_HOME:-}"
printf 'ENV android-sdk-root %s\n' "${ANDROID_SDK_ROOT:-}"
if [ -d "${ANDROID_HOME:-/nonexistent}/platform-tools" ]; then
  printf 'DIR android-platform-tools yes\n'
else
  printf 'DIR android-platform-tools no\n'
fi
_on_path() { case ":${PATH}:" in *":$1:"*) return 0 ;; *) return 1 ;; esac; }
if [ -n "${ANDROID_HOME:-}" ] && _on_path "${ANDROID_HOME}/platform-tools" \
   && _on_path "${ANDROID_HOME}/cmdline-tools/latest/bin"; then
  printf 'FACT android-path yes\n'
else
  printf 'FACT android-path no\n'
fi
_tool="$(command -v appimagetool 2>/dev/null || true)"
printf 'ENV appimagetool %s\n' "${_tool}"
if [ -n "${_tool}" ] && [ -r "${_tool}" ]; then
  printf 'FACT appimagetool-readable yes\n'
else
  printf 'FACT appimagetool-readable no\n'
fi
printf 'ENV java-home %s\n' "${JAVA_HOME:-}"
if command -v java >/dev/null 2>&1; then
  printf 'FACT java-on-path yes\n'
else
  printf 'FACT java-on-path no\n'
fi
if [ -x "${JAVA_HOME:-/nonexistent}/bin/javac" ]; then
  printf 'FACT javac yes\n'
else
  printf 'FACT javac no\n'
fi
if [ -x /opt/flutter/bin/flutter ]; then
  printf 'FACT flutter-sdk yes\n'
else
  printf 'FACT flutter-sdk no\n'
fi
_n=0
_ex=""
while IFS= read -r _p; do
  _n=$((_n + 1))
  [ "${_n}" -le 5 ] && _ex="${_ex} ${_p}"
done < <(find /opt/flutter ! -uid "${_u}" 2>/dev/null)
printf 'FACT flutter-foreign %s\n' "${_n}"
printf 'FACT flutter-foreign-examples %s\n' "${_ex# }"
printf 'FACT flatpak-runtimes %s\n' "$(flatpak list --runtime 2>/dev/null | grep -c . || echo 0)"
if [ -n "$(ls "${HOME:-/nonexistent}"/.local/share/appimagekit/runtime-* 2>/dev/null | head -1)" ]; then
  printf 'FACT appimage-runtime yes\n'
else
  printf 'FACT appimage-runtime no\n'
fi
if command -v wasm-pack >/dev/null 2>&1 && command -v flutter_rust_bridge_codegen >/dev/null 2>&1; then
  printf 'FACT web-lane-tools yes\n'
else
  printf 'FACT web-lane-tools no\n'
fi
echo CCPROBE_DONE
PROBE
}

# One "<verb> <key> <value>" fact out of the probe text; EMPTY on a miss, which every
# caller turns into NOFACT rather than a pass. docs/consumer-image-contract.md#the-contract
_consumer_contract_fact() {
  printf '%s\n' "$1" | sed -n "s/^$2 $3 //p" | head -1
}

# One directory row: set, outside the consumer's /workspace checkout, and provably
# writable by the image user. docs/consumer-image-contract.md#the-contract
_consumer_dir_verdict() {
  local row="$1" val="$2" write="$3"
  case "${write}" in
    yes|no) ;;
    *) printf 'NOFACT %s no WRITE line\n' "${row}"; return 0 ;;
  esac
  case "${val}" in
    "")          printf 'BAD %s the variable is unset, so the consumer inherits no location at all\n' "${row}" ;;
    /workspace*) printf 'BAD %s points into the bind-mounted checkout: %s\n' "${row}" "${val}" ;;
    *)           if [ "${write}" = yes ]; then
                   printf 'OK %s %s\n' "${row}" "${val}"
                 else
                   printf 'BAD %s not writable by the image user: %s\n' "${row}" "${val}"
                 fi ;;
  esac
}

# An exempted row still has to prove its exemption still applies: the rot signal is the
# row's OWN probe fact, and a missing one is NOFACT, never a grant.
# docs/consumer-image-contract.md#per-arch-exemptions
_consumer_exempt_verdict() {
  case "$3" in
    yes) printf 'STALE %s FACT %s says it IS present on %s -- delete the %s:%s arm from _consumer_contract_exempt' "$1" "$4" "$2" "$2" "$1" ;;
    no)  printf 'EXEMPT %s' "$1" ;;
    *)   printf 'NOFACT %s no FACT %s, so the exemption cannot be re-checked' "$1" "$4" ;;
  esac
}

# The android row: both variables set AND the platform-tools directory really there,
# because an exported path is not an SDK. docs/consumer-image-contract.md#the-contract
# Gradle reads JAVA_HOME; a java on PATH with no JAVA_HOME is the shape the Android
# lane died on. Both, plus a javac under it, or the row is red.
# A tool that is executable but not readable runs for root and fails for everyone
# else; the probe answers for the user the image ships.
_consumer_tool_verdict() {
  local row="$1" path readable
  path="$(_consumer_contract_fact "$2" ENV appimagetool)"
  readable="$(_consumer_contract_fact "$2" FACT appimagetool-readable)"
  if [ -z "${readable}" ]; then
    printf 'NOFACT %s no FACT appimagetool-readable line' "${row}"
  elif [ -z "${path}" ]; then
    printf 'BAD %s appimagetool is not on PATH at all' "${row}"
  elif [ "${readable}" != yes ]; then
    printf 'BAD %s %s is not readable by the image user' "${row}" "${path}"
  else
    printf 'OK %s %s readable' "${row}" "${path}"
  fi
}

_consumer_jdk_verdict() {
  local row="$1" home onpath javac
  home="$(_consumer_contract_fact "$2" ENV java-home)"
  onpath="$(_consumer_contract_fact "$2" FACT java-on-path)"
  javac="$(_consumer_contract_fact "$2" FACT javac)"
  if [ -z "${onpath}" ] || [ -z "${javac}" ]; then
    printf 'NOFACT %s no FACT java-on-path / FACT javac line' "${row}"
  elif [ "${onpath}" != yes ]; then
    printf 'BAD %s no java on PATH' "${row}"
  elif [ -z "${home}" ]; then
    printf 'BAD %s java runs but JAVA_HOME is unset, which is what Gradle reads' "${row}"
  elif [ "${javac}" != yes ]; then
    printf 'BAD %s JAVA_HOME=%s has no bin/javac -- a JRE cannot compile' "${row}" "${home}"
  else
    printf 'OK %s java + JAVA_HOME=%s with javac' "${row}" "${home}"
  fi
}

_consumer_android_verdict() {
  local row="$1" val root dir onpath
  val="$(_consumer_contract_fact "$2" ENV android-home)"
  root="$(_consumer_contract_fact "$2" ENV android-sdk-root)"
  dir="$(_consumer_contract_fact "$2" DIR android-platform-tools)"
  onpath="$(_consumer_contract_fact "$2" FACT android-path)"
  if [ -z "${dir}" ] || [ -z "${onpath}" ]; then
    printf 'NOFACT %s no DIR android-platform-tools / FACT android-path line' "${row}"
  elif [ -z "${val}" ] || [ -z "${root}" ]; then
    printf 'BAD %s ANDROID_HOME=%s / ANDROID_SDK_ROOT=%s while the SDK ships in the image' "${row}" "${val:-<unset>}" "${root:-<unset>}"
  elif [ "${dir}" != yes ]; then
    printf 'BAD %s %s/platform-tools does not exist' "${row}" "${val}"
  elif [ "${onpath}" != yes ]; then
    printf 'BAD %s neither %s/platform-tools nor cmdline-tools/latest/bin is on PATH' "${row}" "${val}"
  else
    printf 'OK %s %s' "${row}" "${val}"
  fi
}

# The ownership row: a missing count is NOFACT, not zero -- the whole defect is that
# root wrote into the tree after the COPY. docs/consumer-image-contract.md#the-contract
_consumer_owner_verdict() {
  local row="$1" n
  n="$(_consumer_contract_fact "$2" FACT flutter-foreign)"
  if [ -z "${n}" ]; then
    printf 'NOFACT %s no FACT flutter-foreign line' "${row}"
  elif [ "${n}" != 0 ]; then
    printf 'BAD %s %s path(s) under /opt/flutter are not owned by the runtime uid: %s' "${row}" "${n}" \
      "$(_consumer_contract_fact "$2" FACT flutter-foreign-examples)"
  else
    printf 'OK %s every path under /opt/flutter belongs to the runtime uid' "${row}"
  fi
}

# Pure verdict function: arch + probe text in, one "OK|BAD|EXEMPT|STALE|NOFACT <row>
# <detail>" line per contract row plus "ASSERTED <n>". No container, so every failure
# path is provable from a recorded probe. docs/consumer-image-contract.md#how-the-gate-proves-it
_consumer_contract_verdicts() {
  local arch="$1" probe="$2" row fact line asserted=0
  for row in ${_CONSUMER_CONTRACT_ROWS}; do
    if _consumer_contract_exempt "${arch}" "${row}"; then
      fact="$(_consumer_exempt_fact "${row}")"
      line="$(_consumer_exempt_verdict "${row}" "${arch}" \
                "$(_consumer_contract_fact "${probe}" FACT "${fact}")" "${fact}")"
    else
      case "${row}" in
        android-home)  line="$(_consumer_android_verdict "${row}" "${probe}")" ;;
        jdk)           line="$(_consumer_jdk_verdict "${row}" "${probe}")" ;;
        appimagetool)  line="$(_consumer_tool_verdict "${row}" "${probe}")" ;;
        flutter-owner) line="$(_consumer_owner_verdict "${row}" "${probe}")" ;;
        flatpak-runtimes|appimage-runtime|web-lane-tools)
                       line="$(_consumer_present_verdict "${row}" \
                                 "$(_consumer_contract_fact "${probe}" FACT "${row}")")" ;;
        *)             line="$(_consumer_dir_verdict "${row}" \
                                 "$(_consumer_contract_fact "${probe}" ENV "${row}")" \
                                 "$(_consumer_contract_fact "${probe}" WRITE "${row}")")" ;;
      esac
    fi
    printf '%s\n' "${line}"
    case "${line}" in OK\ *) asserted=$((asserted + 1)) ;; esac
  done
  printf 'ASSERTED %d\n' "${asserted}"
}

# Why the probe's answers are evidence at all: it completed, and it ran as the image's
# OWN user -- as root every directory answers writable. Prints the reason to stop, EMPTY
# when the capture is usable. docs/consumer-image-contract.md#how-the-gate-proves-it
_consumer_probe_verdict() {
  local probe="$1" want="$2" who
  if ! printf '%s\n' "${probe}" | grep -qxF -- 'CCPROBE_DONE'; then
    printf 'the probe did not complete, so the gate asserted NOTHING: %s' \
      "$(printf '%s' "${probe}" | tr '\n' ';' | head -c 300)"
  elif [ -z "${want}" ]; then
    printf '%s' "the image declares no USER, so nothing pins who a consumer runs as -- every writability answer would be root's"
  else
    who="$(printf '%s\n' "${probe}" | sed -n 's/^WHO //p' | head -1)"
    case " ${who} " in
      *" ${want} "*) ;;
      *) printf "the probe ran as '%s', not the image's own USER '%s' -- as root every directory answers writable and the gate proves nothing" "${who}" "${want}" ;;
    esac
  fi
}

# CONTRACT: what a consuming CI lane may rely on and cannot repair from outside a
# read-only overlay layer. One probe run as the image's OWN user -- a root probe would
# answer yes to every writability question -- then host-side verdicts.
# docs/consumer-image-contract.md#the-contract
check_consumer_contract() {
  local image_tag="$1"
  local target_arch="$2"
  local probe want stop verb row rest asserted=""
  echo "--- CONSUMER CONTRACT (${target_arch}) ---"
  want="$(inspect_image_config "import sys,json; print(json.load(sys.stdin)[0].get('Config',{}).get('User',''))")"
  probe="$(_rt_run -e "RT_CONTRACT_SH=$(_consumer_contract_probe)" \
    bash -lc 'if [ -z "${RT_CONTRACT_SH:-}" ]; then echo "CCPROBE_EMPTY"; exit 4; fi
printf "%s\n" "${RT_CONTRACT_SH}" | bash' 2>/dev/null)" || true
  stop="$(_consumer_probe_verdict "${probe}" "${want}")"
  if [ -n "${stop}" ]; then
    fail "CONSUMER CONTRACT (${target_arch}): ${stop}"
    echo ""
    return 0
  fi
  while read -r verb row rest; do
    [ -n "${verb}" ] || continue
    case "${verb}" in
      OK)       echo "  OK   ${row} ${rest}" ;;
      EXEMPT)   echo "  ~~   ${row} (documented ${target_arch} exception)" ;;
      BAD)      fail "CONSUMER CONTRACT ${row} (${target_arch}): ${rest} -- $(_consumer_contract_symptom "${row}")" ;;
      STALE)    fail "CONSUMER CONTRACT ${row} (${target_arch}): ${rest}" ;;
      NOFACT)   fail "CONSUMER CONTRACT ${row} (${target_arch}): ${rest} -- the probe reported no fact, so the gate could not judge the row" ;;
      ASSERTED) asserted="${row}" ;;
      *)        fail "CONSUMER CONTRACT: unknown verdict '${verb} ${row} ${rest}' -- an unhandled verb is a silently dropped row" ;;
    esac
  done < <(_consumer_contract_verdicts "${target_arch}" "${probe}")
  if [ "${asserted:-0}" = 0 ]; then
    fail "CONSUMER CONTRACT asserted NOTHING on ${target_arch} (${asserted:-no ASSERTED line}) -- an empty row table is a vacuous pass, not a compliant image"
  else
    pass "CONSUMER CONTRACT: ${asserted} row(s) hold as ${want} on ${target_arch}"
  fi
  echo ""
}

# Native shared-library dependency closure over the source-built /opt stacks: any
# NEEDED soname absent from the runtime loader path is a real defect (the class that
# shipped a libopencore-amrwb-broken ffmpeg and a libsleef-broken torch while amd64
# stayed green). Venv extensions are EXCLUDED - they add their own package lib dirs at
# import time, which a bare `ldd` cannot replicate; the import checks are their gate.
check_native_so_closure() {
  local image_tag="$1"
  local target_arch="$2"
    echo "--- Functional: native /opt .so dependency closure ---"
    if _rt_run \
         bash -lc 'set -uo pipefail
n=0
while IFS= read -r f; do
  case "$f" in *.debug|*.a|*.la|*.pc) continue;; esac
  nf="$(ldd "$f" 2>/dev/null | awk "/=> not found/{print \$1}")"
  [ -n "$nf" ] && { printf "  BROKEN %s -> %s\n" "$f" "$(echo $nf | tr "\n" " ")"; n=$((n+1)); }
done < <(find /opt/ffmpeg/bin /opt/ffmpeg/lib /opt/opencv5/lib /opt/libcamera/lib /opt/vulkan/active/lib -type f \( -name "*.so*" -o -perm -u+x \) 2>/dev/null | head -400)
[ "$n" = 0 ]'; then
      pass "native /opt .so closure fully resolves (${target_arch})"
    else
      fail "native /opt library has unresolved shared-object deps (${target_arch}) -- see BROKEN lines above"
    fi
    echo ""
}

# ── HT1: the shipped artifact trees must carry THIS image's arch ─────────────
# artifact-source is the BUILDER's image, so a tree INSTALLED on the host instead of
# cross-built ships x86_64 into the arm64/riscv64 runtime image -- rustup (2 GB, exit
# 127) and Flutter's Dart SDK both did, and only their own gates caught them.
# docs/artifact-copy-completeness.md#the-shipped-trees-must-carry-the-images-own-arch

# Trees whose ELF machine is NOT this image's by design, MEASURED on shipped bytes
# rather than reasoned: the SDK is one linux-x86_64 tree copied unchanged into all
# three images. The arm names the TREE, never an arch, so a newly host-installed tree
# fails by default. docs/artifact-copy-completeness.md#what-the-exemptions-are-worth
# /opt/android is exempt HERE and asserted THERE: an Android payload's arch is the
# ANDROID target's, never the image's, so check_android_abi judges it against the
# ABI the image advertises -- stricter than "matches the image", not a waiver.
# docs/linux-cross-builds.md#the-android-abi-is-a-target-not-the-build-host
_RT_TREE_ARCH_EXEMPT="/opt/android-sdk /opt/android"

# Builder-arch objects a foreign image still ships, frozen WITH their count so a new
# one fails while a known one is tracked: <arch>:<tree>:<machine>:<count>. These are
# defects with a backlog entry, not waivers -- the list only ratchets down, and it is
# EMPTY: the five llvm-target x86-64 libs it held were fixed at the source (HT3).
# docs/artifact-copy-completeness.md#the-llvm-target-prefix-fills-what-it-needs-and-nothing-else
_RT_TREE_ARCH_FROZEN=""

# Prints the frozen count for this finding, empty when it is not frozen.
_rt_tree_arch_frozen() {
  local key="$1:$2:$3" entry
  for entry in ${_RT_TREE_ARCH_FROZEN}; do
    case "${entry}" in "${key}:"*) printf '%s' "${entry##*:}"; return 0 ;; esac
  done
  return 1
}

_rt_tree_arch_exempt() {
  case " ${_RT_TREE_ARCH_EXEMPT} " in *" $1 "*) return 0 ;; *) return 1 ;; esac
}

# Where the gate probes a manifest tree in the image: the manifest carries the COPY
# SOURCE path and one COPY relocates it (ALLOWED_RELOCATIONS in verify-artifact-copy-parity.sh
# owns the other half). /opt/vulkan used to be narrowed to active/ around a builder-arch
# SDK that no longer ships; the WHOLE tree is asserted now.
# docs/artifact-copy-completeness.md#the-vulkan-tree-ships-only-what-the-image-runs
_rt_tree_probe_path() {
  case "$1" in
    /opt/llvm-target) printf '%s' /usr/local/llvm-target ;;
    *)                printf '%s' "$1" ;;
  esac
}

# Manifest paths as they exist IN the image: ${VAR} resolved from the environment, else
# from Dockerfile.package's own `ARG VAR=default`, then relocated. An unresolvable token
# is printed as `UNRESOLVED <var>` so the gate fails rather than scanning nothing.
_rt_manifest_trees() {
  local manifest="${_SCRIPT_DIR}/../runtime-artifacts.manifest"
  local dockerfile="${_SCRIPT_DIR}/../../Dockerfile.package"
  local line path var val guard
  while IFS= read -r line; do
    path="$(printf '%s' "${line%%|*}" | tr -d '[:space:]')"
    case "${path}" in ''|'#'*) continue ;; esac
    guard=0
    while [ "${guard}" -lt 8 ] && [[ "${path}" =~ \$\{([A-Za-z0-9_]+)\} ]]; do
      guard=$((guard + 1))
      var="${BASH_REMATCH[1]}"
      val="${!var:-}"
      [ -n "${val}" ] || val="$(sed -n "s/^ARG ${var}=\(.*\)$/\1/p" "${dockerfile}" | head -1)"
      [ -n "${val}" ] || break
      path="${path//\$\{${var}\}/${val}}"
    done
    case "${path}" in
      *'${'*) printf 'UNRESOLVED %s\n' "${path}" ;;
      *)      _rt_tree_probe_path "${path}"; printf '\n' ;;
    esac
  done < "${manifest}"
}

# ELF machine of every EXECUTABLE-or-.so object under $RT_TREES, aggregated per (tree,
# machine) so the
# verdict reads counts instead of thousands of paths. Only candidates count toward CAP:
# rust-src alone would spend it before reaching toolchains/*/bin/rustc. Header reads in ONE
# process, not a readelf exec per file, which under qemu would cost minutes. docs/artifact-copy-completeness.md#the-shipped-trees-must-carry-the-images-own-arch
_tree_arch_py() {
  cat <<'PY'
import os
import re
# No space in a label: the verdict line is read back with `read -r verb tree machine
# count sample`, and "Intel 80386" ate the count column on 2026-09-04.
EM = {3: "Intel-80386", 40: "ARM", 62: "X86-64", 183: "AArch64", 243: "RISC-V"}
# A cross toolchain SHIPS foreign objects on purpose: these three directory shapes are
# its target payload, not the image's own binaries. Everything else in the tree -- the
# compilers and libraries the image itself runs -- is still asserted.
# docs/artifact-copy-completeness.md#the-shipped-trees-must-carry-the-images-own-arch
CROSS_PAYLOAD = (
    "/lib/rustlib/",              # rustup: per-target std, one dir per --target
    "/lib/clang/",                # clang: multilib sanitizer/builtins runtimes
    "/lib/gcc/",                  # gcc: per-target crt objects, one dir per triple
)
GCC_TARGET_DIR = re.compile(r"/gcc-[^/]+/[a-z0-9_]+(?:-[a-z0-9]+)?-linux-[a-z0-9]+/")


def _cross_payload(path):
    if any(marker in path for marker in CROSS_PAYLOAD):
        return True
    return bool(GCC_TARGET_DIR.search(path))
CAP = int(os.environ.get("RT_TREE_CAP") or "20000")
for tree in os.environ.get("RT_TREES", "").split():
    if not os.path.isdir(tree):
        print("TREEMISS", tree)
        continue
    seen, sample, visited = {}, {}, 0
    first, rest = [], []
    for dirpath, dirnames, filenames in os.walk(tree):
        dirnames.sort()
        for name in sorted(filenames):
            path = os.path.join(dirpath, name)
            if os.path.islink(path):
                continue
            try:
                executable = os.stat(path).st_mode & 0o111
            except OSError:
                continue
            if _cross_payload(path):
                continue
            (first if executable or ".so" in name else rest).append(path)
    for path in first + rest:
        if visited >= CAP:
            print("TREECAP", tree, CAP)
            break
        visited += 1
        try:
            with open(path, "rb") as fh:
                head = fh.read(20)
        except OSError:
            continue
        if len(head) < 20 or head[:4] != b"\x7fELF":
            continue
        order = "little" if head[5] == 1 else "big"
        key = EM.get(int.from_bytes(head[18:20], order), "EM%d" % int.from_bytes(head[18:20], order))
        seen[key] = seen.get(key, 0) + 1
        sample.setdefault(key, path)
    if not seen:
        print("TREENOELF", tree)
    for key in sorted(seen):
        print("TREE", tree, key, seen[key], sample[key])
print("TREESCAN_DONE")
PY
}

# Pure verdict function for the tree-arch gate: scanner text + the expected ELF machine
# in, one "OK|BAD|NOELF|MISSING <tree> ..." line out per tree, NONE when it saw nothing.
_tree_arch_verdicts() {
  local probe="$1" want="$2" tree machine count sample n=0
  while read -r tree; do
    [ -n "${tree}" ] || continue
    printf 'MISSING %s\n' "${tree}"
  done < <(printf '%s\n' "${probe}" | sed -n 's/^TREEMISS //p')
  while read -r tree; do
    [ -n "${tree}" ] || continue
    printf 'NOELF %s\n' "${tree}"
  done < <(printf '%s\n' "${probe}" | sed -n 's/^TREENOELF //p')
  while read -r tree cap; do
    [ -n "${tree}" ] || continue
    n=$((n + 1))
    printf 'CAPPED %s %s -\n' "${tree}" "${cap}"
  done < <(printf '%s\n' "${probe}" | sed -n 's/^TREECAP //p')
  while read -r tree machine count sample; do
    [ -n "${tree}" ] || continue
    n=$((n + 1))
    case "${machine}" in
      *"${want}"*) printf 'OK %s %s %s\n' "${tree}" "${machine}" "${count}" ;;
      *)           printf 'BAD %s %s %s %s\n' "${tree}" "${machine}" "${count}" "${sample}" ;;
    esac
  done < <(printf '%s\n' "${probe}" | sed -n 's/^TREE //p')
  [ "${n}" -gt 0 ] || printf 'NONE - - -\n'
}

# HT1 gate: read the ELF machine of what each manifest tree actually ships.
check_manifest_tree_arch() {
  local image_tag="$1"
  local target_arch="$2"
  echo "--- HT1: shipped artifact trees carry the ${target_arch} ELF machine ---"
  local trees="" tree want out verb machine count sample bad=0 ok=0 _frozen
  while read -r tree; do
    case "${tree}" in
      UNRESOLVED*)
        bad=$((bad + 1))
        fail "tree-arch gate: runtime-artifacts.manifest names ${tree#UNRESOLVED } but neither the environment nor Dockerfile.package's ARG defaults define it -- the tree would be silently skipped"
        continue ;;
    esac
    if _rt_tree_arch_exempt "${tree}"; then
      echo "  ~~   ${tree} not asserted (android-lane payload; its arch is not the image's)"
      continue
    fi
    trees="${trees} ${tree}"
  done < <(_rt_manifest_trees)
  want="$(smoke_elf_machine_grep "${target_arch}")"
  out="$(_rt_run -e "RT_TREES=${trees# }" -e "RT_TREE_PY=$(_tree_arch_py)" \
           bash -lc 'p=/opt/venv/bin/python; [ -x "$p" ] || p="$(command -v python3)"
printf "%s\n" "${RT_TREE_PY:-}" | "$p" -' 2>&1 || true)"
  if ! printf '%s\n' "${out}" | grep -qxF -- 'TREESCAN_DONE'; then
    fail "tree-arch gate could not run in the ${target_arch} image (no TREESCAN_DONE marker) -- a gate that cannot run is not a pass: $(printf '%s' "${out}" | head -1)"
    echo ""
    return 0
  fi

  while read -r verb tree machine count sample; do
    [ -n "${verb}" ] || continue
    case "${verb}" in
      OK)      ok=$((ok + 1)); echo "  OK   ${tree}: ${count} ELF object(s), all ${machine}" ;;
      NOELF)   echo "  ~~   ${tree} ships no ELF object at all (a per-arch empty tree; ARCH-PARITY owns presence)" ;;
      BAD)     _frozen="$(_rt_tree_arch_frozen "${target_arch}" "${tree}" "${machine}" || true)"
               if [ -n "${_frozen}" ] && [ "${_frozen}" = "${count}" ]; then
                 echo "  ~~   ${tree}: ${count} ${machine} object(s) FROZEN on ${target_arch} (backlog HT3) -- known, counted, not waived"
                 continue
               fi
               if [ -n "${_frozen}" ]; then
                 bad=$((bad + 1))
                 fail "tree-arch: ${tree} ships ${count} ${machine} object(s) on ${target_arch}, but ${_frozen} are frozen (backlog HT3) -- the count MOVED; find what changed before re-freezing"
                 continue
               fi
               bad=$((bad + 1))
               fail "tree-arch: ${tree} ships ${count} ${machine} object(s) in the ${target_arch} image, e.g. ${sample} -- artifact-source is the BUILDER's image, so this tree was installed on the host instead of built for the target (the rustup/Flutter class). Build it for the target, or name the tree in _RT_TREE_ARCH_EXEMPT with the reason" ;;
      MISSING) bad=$((bad + 1))
               fail "tree-arch: ${tree} is declared in runtime-artifacts.manifest but is ABSENT from the ${target_arch} image -- the COPY landed elsewhere or the tree was dropped" ;;
      CAPPED)  bad=$((bad + 1))
               fail "tree-arch: the walk of ${tree} hit the ${machine}-file cap, so everything past it was never read -- a partial scan is not a pass. Raise RT_TREE_CAP or narrow the tree" ;;
      NONE)    bad=$((bad + 1))
               fail "tree-arch: the scanner found NO tree at all on ${target_arch} -- a vacuous pass, not a green image" ;;
      *)       bad=$((bad + 1))
               fail "tree-arch gate: unknown verdict '${verb}' for ${tree} on ${target_arch}" ;;
    esac
  done < <(_tree_arch_verdicts "${out}" "${want}")
  [ "${bad}" -ne 0 ] || pass "all ${ok} asserted artifact tree(s) are ${want} on ${target_arch}"
  echo ""
}

# RP1 (security): the shipped image must carry NO usable `sudo` - it was purged from
# the final stage (Dockerfile.torch) as pure LPE surface, since no sudoers/group grants
# exist. Every other setuid binary is inventoried (informational) so a new one is at
# least VISIBLE in the smoke log rather than shipping unnoticed.
check_setuid_inventory() {
  local image_tag="$1"
  local target_arch="$2"
    echo "--- Functional: setuid inventory (sudo must be absent) ---"
    if _rt_run \
         bash -lc 'set -uo pipefail
found=""
while IFS= read -r f; do
  found="${found}${f}\n"
done < <(find / -xdev -perm -4000 -type f 2>/dev/null)
if [ -n "$found" ]; then printf "  setuid binaries present:\n"; printf "%b" "$found" | sed "s/^/    /"; fi
# fail iff a sudo-family setuid binary survived
printf "%b" "$found" | grep -qE "/sudo(edit)?$" && { echo "  VIOLATION: setuid sudo present"; exit 1; }
exit 0'; then
      pass "no setuid sudo in the shipped image (${target_arch})"
    else
      fail "setuid sudo present in the shipped image (${target_arch}) -- RP1 purge regressed (Dockerfile.torch)"
    fi
    echo ""
}

# AP7 (size observability, INFORMATIONAL - never fails): one du block turns every
# "shrink X" item into a number attributable to a prefix. Sorted largest-last.
check_size_observability() {
  local image_tag="$1"
  local target_arch="$2"
    echo "--- Size: per-prefix disk usage (informational, ${target_arch}) ---"
    _rt_run \
      bash -lc 'set -uo pipefail
du -sh /opt/* /opt/venv/lib/python*/site-packages 2>/dev/null | sort -h | sed "s/^/    /"
printf "    ---- total /opt ----\n"
du -sh /opt 2>/dev/null | sed "s/^/    /"' || echo "  (size probe unavailable)"
    echo ""
}

# SMK3: AP2 gate - the venv must ship byte-compiled. The uid-1001 runtime user cannot
# write __pycache__ into the root-owned /opt/venv, so a regressed build-time compileall
# makes every container start re-parse site-packages. HARD fail, not an artifact.
check_venv_bytecode() {
  local image_tag="$1"
  local target_arch="$2"
    echo "--- AP2: venv byte-compiled (.pyc present) ---"
    if _rt_run \
      bash -lc 'find /opt/venv/lib -name "*.pyc" -print -quit 2>/dev/null | grep -q .'; then
      echo "  OK: /opt/venv ships .pyc (AP2 intact)"
    else
      fail "AP2 REGRESSED: no .pyc anywhere under /opt/venv/lib — venv not byte-compiled (VENV_COMPILE gate broken?)"
    fi
    echo ""
}

# ── ARCH-PARITY table (2026-08-23) ──────────────────────────
# TABLE CONFORMANCE, not a cross-arch diff: this smoke sees ONE image, so it asserts
# that every component NAMED below is present on this arch or documented absent, and a
# documented absence that stopped being true FAILS so the table cannot rot in place. A
# component nobody wrote down is invisible to it. That blind spot, and why the stale arm
# fails rather than warns: docs/cross-build-verification.md, "In-image smoke tests".
# Prefix names are version-stripped (cmake-4.4.2 -> cmake) so a pin bump needs no edit.
_PARITY_PREFIXES="OrchestrANT android android-sdk cmake ffmpeg gcc gstreamer libcamera opencv5 python scripts venv vulkan"
# Wheel names in dist-info form ('-' and '.' normalised to '_').
_PARITY_WHEELS="torch torchvision ai_edge_litert iree_base_compiler iree_base_runtime onnxruntime_genai"

# Documented per-arch absences; anything absent and NOT listed here is drift and fails.
# EVERY ARM IS A DELETION CANDIDATE - the moment its component appears, check_arch_parity
# fails and names the line to delete. So an arm may only encode a reason that is true
# TODAY, never "not built yet", which would turn the table into a wish list.
_parity_exempt() {
  case "$1:$2" in
    # Kitware publishes no riscv64 CMake archive, so 02-toolchain/cmake.sh
    # deliberately installs the distro cmake there (4.2.3) instead.
    riscv64:cmake) return 0 ;;
    # NB (GEN1): the riscv64:onnxruntime_genai arm is deleted -- riscv64 now
    # self-builds the wheel. Expect red on older images. docs/gen1-riscv64-genai.md
    # The IREE COMPILER cannot be cross-built and upstream publishes no riscv64 wheel,
    # so the cross target is runtime-only (IREE_CROSS_BUILD_COMPILER defaults OFF); see
    # docs/linux-cross-builds.md, "IREE (Linux lane)". riscv64-only ON PURPOSE: arm64
    # carries the compiler wheel and must keep asserting it.
    riscv64:iree_base_compiler) return 0 ;;
    *) return 1 ;;
  esac
}

# Which onnxruntime flavour each arch is SUPPOSED to carry, and only one of them: the
# 2026-08-21 version shadow shipped a PyPI onnxruntime beside the built one and broke
# every import with a VERS_1.29.0 symbol error.
_parity_ort_flavor() {
  case "$1" in
    amd64)         printf '%s' 'onnxruntime_dnnl' ;;
    arm64|riscv64) printf '%s' 'onnxruntime_webgpu' ;;
    *)             printf '%s' '' ;;
  esac
}

# GStreamer plugins KNOWN not to load on a given arch. Same contract: listed =
# reviewed, unlisted = new drift (reported, still non-fatal). One "<arch>:<plugin>" list
# rather than case arms because check_gstreamer_plugin_health needs both directions of
# the same fact - is this failure documented, and which documented failures stopped
# happening - and a predicate cannot be enumerated.
# arm64:libgstgtk4.so - the distro libgtk-4.so.1 wants vkCreateWaylandSurfaceKHR, which
# the shipped /opt/vulkan loader does not export. A display sink has no role in a
# headless wrapper, so it is accepted rather than fixed.
_PARITY_GST_KNOWN_BROKEN="arm64:libgstgtk4.so"

_parity_gst_plugin_known() {
  case " ${_PARITY_GST_KNOWN_BROKEN} " in
    *" $1:$2 "*) return 0 ;;
    *) return 1 ;;
  esac
}

check_arch_parity() {
  local image_tag="$1"
  local target_arch="$2"
    echo "--- ARCH-PARITY: /opt prefixes + component wheels (${target_arch}) ---"
    local probe
    if ! probe="$(_rt_run bash -lc 'set -uo pipefail
for d in /opt/*/; do printf "PREFIX %s\n" "$(basename "$d")"; done
for m in /opt/venv/lib/python*/site-packages/*.dist-info; do
  [ -d "$m" ] || continue
  printf "DIST %s\n" "$(basename "$m" | sed "s/-[^-]*\.dist-info$//")"
done' 2>/dev/null)"; then
      fail "ARCH-PARITY probe could not run in the ${target_arch} image"
      echo ""
      return 0
    fi
    local prefixes wheels
    prefixes="$(printf '%s\n' "${probe}" | sed -n 's/^PREFIX //p' | sed -E 's/-[0-9][0-9.]*$//' | sort -u)"
    wheels="$(printf '%s\n' "${probe}" | sed -n 's/^DIST //p' | tr '.-' '__' | sort -u)"

    local want present
    for want in ${_PARITY_PREFIXES} ${_PARITY_WHEELS}; do
      case " ${_PARITY_PREFIXES} " in
        *" ${want} "*) present="$(printf '%s\n' "${prefixes}" | grep -cxF -- "${want}" || true)" ;;
        *)             present="$(printf '%s\n' "${wheels}"   | grep -cxF -- "${want}" || true)" ;;
      esac
      if [ "${present}" != "0" ]; then
        if _parity_exempt "${target_arch}" "${want}"; then
          fail "ARCH-PARITY: the documented ${target_arch} exception for ${want} NO LONGER APPLIES -- ${want} is PRESENT in this image. Delete the '${target_arch}:${want})' arm from _parity_exempt in linux/scripts/06-packaging/smoke-runtime-image.sh; the table then asserts ${want} on ${target_arch} like on every other arch."
        fi
      elif _parity_exempt "${target_arch}" "${want}"; then
        echo "  ~~   ${want} absent (documented ${target_arch} exception)"
      else
        fail "ARCH-PARITY: ${want} missing on ${target_arch} and NOT in the documented exception list -- ship it or record the exception in _parity_exempt"
      fi
    done

    # The blind spot, with the raw material beside it: the loop can only judge names the
    # table carries, so print the untracked prefixes - INFO, never a gate, since a gate
    # would need all three images at once. Wheels are excluded: hundreds of dist-infos
    # would bury it.
    local untracked p
    untracked=""
    for p in ${prefixes}; do
      case " ${_PARITY_PREFIXES} " in
        *" ${p} "*) ;;
        *) untracked="${untracked} ${p}" ;;
      esac
    done
    if [ -n "${untracked}" ]; then
      echo "  INFO /opt prefixes NOT in the parity table (${target_arch}):${untracked}"
      echo "  INFO   -- untracked = outside the gate. If one of these is missing on another arch,"
      echo "  INFO      only a human diff of the three smoke logs will see it; add it to"
      echo "  INFO      _PARITY_PREFIXES to put it under the assert."
    else
      echo "  INFO every /opt prefix on ${target_arch} is tracked by the parity table"
    fi

    # ORT: exactly one distribution, and the one this arch is meant to have.
    local ort_have ort_want
    ort_have="$(printf '%s\n' "${wheels}" | grep -E '^onnxruntime(_[a-z0-9]+)?$' | grep -v '^onnxruntime_genai$' | tr '\n' ' ' || true)"
    ort_want="$(_parity_ort_flavor "${target_arch}")"
    case "$(printf '%s' "${ort_have}" | wc -w)" in
      1) if [ "${ort_have% }" = "${ort_want}" ]; then
           pass "ARCH-PARITY: exactly one onnxruntime distribution, ${ort_want} as the table expects (${target_arch})"
         else
           fail "ARCH-PARITY: onnxruntime flavour is '${ort_have% }' but the table says '${ort_want}' for ${target_arch} -- update _parity_ort_flavor if this was intended"
         fi ;;
      0) fail "ARCH-PARITY: no onnxruntime distribution at all in the ${target_arch} venv" ;;
      *) fail "ARCH-PARITY: ${ort_have}-- MORE THAN ONE onnxruntime distribution in the ${target_arch} venv (the 2026-08-21 version-shadow class: the PyPI build shadows the built one and imports die on VERS_1.29.0)" ;;
    esac
    echo ""
}

# ── SHIPPED-TRUTH gates ──────────────────────────────────────
# One in-image probe emits facts only; every verdict is reached on the host, so
# both gates can be driven with recorded probe text.
# See docs/cross-build-verification.md, "Shipped-truth gates".
_probe_advertised() {
  # What the image SAYS it is: the ENV keys it advertises.
  cat <<'PROBE'
set -uo pipefail
py=/opt/venv/bin/python
printf 'ADV PYTHON_MAJOR_MINOR %s\n'  "${PYTHON_MAJOR_MINOR:-}"
printf 'ADV GCC_VERSION %s\n'         "${GCC_VERSION:-}"
printf 'ADV LLVM_RELEASE %s\n'        "${LLVM_RELEASE:-}"
printf 'ADV GSTREAMER_VERSION %s\n'   "${GSTREAMER_VERSION:-}"
printf 'ADV VULKAN_VERSION %s\n'      "${VULKAN_VERSION:-}"
printf 'ADV RUST_VERSION %s\n'        "${RUST_VERSION:-}"
printf 'ADV WASM_PACK_VERSION %s\n' "${WASM_PACK_VERSION:-}"
printf 'ADV FLUTTER_RUST_BRIDGE_VERSION %s\n' "${FLUTTER_RUST_BRIDGE_VERSION:-}"
printf 'ADV UBUNTU_VERSION %s\n'             "${UBUNTU_VERSION:-}"
printf 'ADV CMAKE_VERSION %s\n'              "${CMAKE_VERSION:-}"
printf 'ADV NODE_VERSION %s\n'               "${NODE_VERSION:-}"
printf 'ADV UV_VERSION %s\n'                 "${UV_VERSION:-}"
printf 'ADV OPENCV_VERSION %s\n'             "${OPENCV_VERSION:-}"
printf 'ADV ONNXRUNTIME_VERSION %s\n'        "${ONNXRUNTIME_VERSION:-}"
printf 'ADV ONNXRUNTIME_GENAI_VERSION %s\n'  "${ONNXRUNTIME_GENAI_VERSION:-}"
printf 'ADV PYAV_VERSION %s\n'               "${PYAV_VERSION:-}"
printf 'ADV IREE_VERSION %s\n'               "${IREE_VERSION:-}"
printf 'ADV LITERT_VERSION %s\n'             "${LITERT_VERSION:-}"
printf 'ADV PYTORCH_EXTRA %s\n'       "${PYTORCH_EXTRA:-}"
PROBE
}

_probe_actual_versions() {
  # What the image actually IS: every value read from the shipped thing itself,
  # never from an ENV. The ADV/HAVE pair is what the shipped-truth gate compares.
  cat <<'PROBE'
printf 'HAVE PYTHON_MAJOR_MINOR %s\n' "$("$py" -c 'import sys;print("%d.%d"%sys.version_info[:2])' 2>/dev/null)"
_g="$(command -v gcc || true)"
printf 'HAVE GCC_VERSION %s\n'        "${_g:+$("$_g" -dumpfullversion 2>/dev/null || "$_g" -dumpversion 2>/dev/null)}"
# Independent of the ARG-named dir: loader, else header. See docs/cross-build-verification.md.
_have_vulkan() {
  local v h
  v="$(vulkaninfo --summary 2>/dev/null \
       | sed -n 's/.*Vulkan Instance Version: *\([0-9.]*\).*/\1/p' | head -1)"
  if [ -n "${v}" ]; then printf '%s' "${v}"; return 0; fi
  for h in /opt/vulkan/active/include/vulkan/vulkan_core.h \
           /opt/vulkan/active/*/include/vulkan/vulkan_core.h; do
    [ -r "${h}" ] || continue
    v="$(awk '/#define VK_HEADER_VERSION[ \t]+[0-9]/ {print "1.4." $3; exit}' "${h}")"
    if [ -n "${v}" ]; then printf '%s' "${v}"; return 0; fi
  done
}

_pyver() { "$py" -c "import importlib.metadata as m;print(m.version('$1'))" 2>/dev/null; }

printf 'HAVE RUST_VERSION %s\n'    "$(rustc --version 2>/dev/null | awk '{print $2}')"
printf 'HAVE UBUNTU_VERSION %s\n'   "$(. /etc/os-release 2>/dev/null; printf '%s' "${VERSION_ID:-}")"
printf 'HAVE CMAKE_VERSION %s\n'    "$(cmake --version 2>/dev/null | head -1 | grep -oE '[0-9]+(\.[0-9]+)+' | head -1)"
printf 'HAVE NODE_VERSION %s\n'     "$(node --version 2>/dev/null | tr -d 'v')"
printf 'HAVE UV_VERSION %s\n'       "$(uv --version 2>/dev/null | grep -oE '[0-9]+(\.[0-9]+)+' | head -1)"
printf 'HAVE OPENCV_VERSION %s\n'   "$("$py" -c 'import cv2;print(cv2.__version__)' 2>/dev/null)"
printf 'HAVE ONNXRUNTIME_VERSION %s\n' "$("$py" -c 'import onnxruntime;print(onnxruntime.__version__)' 2>/dev/null)"
printf 'HAVE ONNXRUNTIME_GENAI_VERSION %s\n' "$("$py" -c 'import onnxruntime_genai as g;print(g.__version__)' 2>/dev/null)"
printf 'HAVE PYAV_VERSION %s\n'     "$("$py" -c 'import av;print(av.__version__)' 2>/dev/null)"
printf 'HAVE IREE_VERSION %s\n'     "$(_pyver iree-base-runtime)"
printf 'HAVE LITERT_VERSION %s\n'   "$(_pyver ai-edge-litert)"
printf 'HAVE LLVM_RELEASE %s\n'       "$(clang --version 2>/dev/null | head -1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)"
printf 'HAVE GSTREAMER_VERSION %s\n'  "$(gst-inspect-1.0 --version 2>/dev/null | head -1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)"
printf 'HAVE VULKAN_VERSION %s\n'     "$(_have_vulkan)"
printf 'HAVE WASM_PACK_VERSION %s\n' "$(wasm-pack --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)"
printf 'HAVE FLUTTER_RUST_BRIDGE_VERSION %s\n' "$(flutter_rust_bridge_codegen --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)"
PROBE
}

_probe_venv_inventory() {
  # The venv package set and the app's requirement edges, via importlib.metadata.
  cat <<'PROBE'
"$py" - <<'PY' 2>/dev/null || echo 'VENV ABSENT metadata-probe-crashed'
import importlib.metadata as md
try:
    from packaging.requirements import Requirement
except Exception:
    print("VENV ABSENT packaging-module-missing"); raise SystemExit(0)
def n(s): return s.strip().lower().replace("_", "-").replace(".", "-")
inst = set()
for d in md.distributions():
    nm = d.metadata["Name"]
    if nm:
        inst.add(n(nm))
for x in sorted(inst):
    print("PKG", x)
app = None
for cand in ("orchestrant", "orchestrant"):
    try:
        app = md.distribution(cand); break
    except Exception:
        pass
if app is None:
    print("VENV ABSENT app-dist-not-installed")
else:
    # Per-extra requirement edges, markers evaluated against THIS image's real
    # environment, so an upstream 'platform_machine != riscv64' is honoured for free.
    for e in (app.metadata.get_all("Provides-Extra") or []):
        for r in (app.requires or []):
            try:
                q = Requirement(r)
            except Exception:
                continue
            if q.marker is None or not q.marker.evaluate({"extra": e}):
                continue
            print("REQ", e, n(q.name))
# Dangling edges: any unconditional requirement of an installed dist that is absent.
for d in md.distributions():
    nm = d.metadata["Name"]
    if not nm:
        continue
    for r in (d.requires or []):
        try:
            q = Requirement(r)
        except Exception:
            continue
        if q.marker is not None and not q.marker.evaluate({"extra": ""}):
            continue
        if n(q.name) not in inst:
            print("DANG", n(nm), n(q.name))
PY
# riscv64 only: what the image's own gcc defaults to, then the ISA each
# shipped object was actually built for.
PROBE
}

_probe_elf_and_sonames() {
  # riscv64 ISA attributes and which library wins each soname lookup.
  cat <<'PROBE'
printf 'RVCC %s\n' "$(gcc -v 2>&1 | grep -oE 'with-arch=[a-z0-9_]+' | head -1 | cut -d= -f2)"

for _l in /opt/opencv5/lib/libopencv_core.so* /opt/ffmpeg/lib/libavcodec.so* \
          /opt/gstreamer/lib/libgstreamer-1.0.so* /lib/riscv64-linux-gnu/libc.so.6; do
  [ -r "${_l}" ] || continue
  printf 'RVARCH %s %s\n' "${_l##*/}" \
    "$(readelf -A "${_l}" 2>/dev/null | grep -oE 'rv64[a-z0-9_]*' | head -1)"
done
# Owner rule: OUR build must win over any distro rival exporting the same
# soname. ldconfig -p lists the winner first.
for _d in /opt/gstreamer/lib /opt/ffmpeg/lib /opt/opencv5/lib /opt/libcamera/lib /opt/armnn/lib /opt/acl/lib; do
  [ -d "${_d}" ] || continue
  for _so in "${_d}"/*.so.*; do
    [ -e "${_so}" ] || continue
    _n="${_so##*/}"
    case "${_n}" in *.so.*.*) continue ;; esac   # only the bare soname link
    _win="$(ldconfig -p 2>/dev/null | awk -v s="${_n}" '$1==s {print $NF; exit}')"
    [ -n "${_win}" ] || continue
    printf 'SONAME %s %s %s\n' "${_n}" "${_win}" "${_d}"
  done
done
echo RTPROBE_DONE
PROBE
}


# The probe the runtime smoke runs INSIDE the image, in three named parts:
# what it advertises, what it is, and what it holds. Emitted as one script.
_shipped_truth_probe() {
  _probe_advertised
  _probe_actual_versions
  _probe_venv_inventory
  _probe_elf_and_sonames
}

# Version-carrying env vars the shipped image sets. Each must equal what the image
# ACTUALLY has; there is no exemption arm and no SKIP arm, because neither a label
# that contradicts the artefact nor a row that cannot fail is a documented state.
# A key the image deliberately does not advertise belongs in verify_advertised_keys.py's
# EXCUSED table instead. docs/cross-build-verification.md
_ADVERTISED_VERSION_KEYS="PYTHON_MAJOR_MINOR GCC_VERSION LLVM_RELEASE
GSTREAMER_VERSION VULKAN_VERSION UBUNTU_VERSION CMAKE_VERSION NODE_VERSION UV_VERSION
OPENCV_VERSION ONNXRUNTIME_VERSION ONNXRUNTIME_GENAI_VERSION PYAV_VERSION IREE_VERSION
LITERT_VERSION RUST_VERSION WASM_PACK_VERSION FLUTTER_RUST_BRIDGE_VERSION"

# Extras the wrapper is ALWAYS built with (assemble-torch-app.sh's uv sync); the
# selected pytorch-* extra is read from the image's own PYTORCH_EXTRA instead.
_VENV_CONTRACT_EXTRAS="ml-ai docs"

# Documented package absences, same contract as _parity_exempt: listed = reviewed, and
# an arm that STOPS applying fails so the table cannot rot. Key is <arch>:<extra>:<pkg>,
# with DEP for a dangling transitive edge.
_venv_pkg_exempt() {
  case "$1:$2:$3" in
    # cv2 is the source-built /opt/opencv5 binding injected into the venv, never the
    # PyPI wheel; /opt/opencv5 itself is asserted by ARCH-PARITY.
    *:ml-ai:opencv-python) return 0 ;;
    # onnxruntime ships under its flavour name (onnxruntime_dnnl / _webgpu), which
    # _parity_ort_flavor asserts; the plain name is never installed.
    *:ml-ai:onnxruntime|*:DEP:onnxruntime) return 0 ;;
    # riscv64 ml-ai: scipy/scikit-learn/pandas need a compiled wheel that PyPI
    # does not publish for this arch and offer no pure-Python fallback, so
    # shipping them means BLAS/LAPACK + Fortran from source, hours per run.
    # Measured 2026-09-02; the rest of the extra IS shipped (optuna and the ORT
    # deps were installable and are now installed).
    # OWNER DECISION, one line to reverse. docs/refactoring-backlog.md AA
    riscv64:ml-ai:scipy|riscv64:ml-ai:scikit-learn|riscv64:ml-ai:pandas) return 0 ;;
    *) return 1 ;;
  esac
}

# Pure verdict function for the advertised-vs-actual gate: probe text in, one
# "OK|BAD|UNSET|UNREAD <key> ..." line out per key. No container, no globals.
# Both "the image did not tell us" arms are fatal: docs/cross-build-verification.md
_advert_verdicts() {
  local probe="$1" key adv have
  for key in ${_ADVERTISED_VERSION_KEYS}; do
    adv="$(printf '%s\n' "${probe}" | sed -n "s/^ADV ${key} //p" | head -1)"
    have="$(printf '%s\n' "${probe}" | sed -n "s/^HAVE ${key} //p" | head -1)"
    # ADV carries a git-tag "v", HAVE a ".devN+sha" trailer.
    adv="${adv#v}"
    [ -z "${have}" ] || have="$(printf '%s' "${have}" | grep -oE '^[0-9]+(\.[0-9]+)*' || printf '%s' "${have}")"
    if [ -z "${adv}" ]; then
      printf 'UNSET %s\n' "${key}"
    elif [ -z "${have}" ]; then
      printf 'UNREAD %s %s\n' "${key}" "${adv}"
    elif [ "${adv}" = "${have}" ] || \
         { [ "${key}" = VULKAN_VERSION ] && [ "${adv#"${have}"}" = ".0" ]; }; then
      printf 'OK %s %s\n' "${key}" "${adv}"
    else
      printf 'BAD %s %s %s\n' "${key}" "${adv}" "${have}"
    fi
  done
}

# Pure verdict function for the venv package-set gate: <arch> + probe text in,
# "MISS|STALE|EXEMPT|NOREQ <extra> <pkg> [owner]" lines plus "ASSERTED <n>" out.
_venv_set_verdicts() {
  local arch="$1" probe="$2"
  local pkgs extras extra reqs r asserted=0 owner name
  pkgs="$(printf '%s\n' "${probe}" | sed -n 's/^PKG //p' | LC_ALL=C sort -u)"
  extras="${_VENV_CONTRACT_EXTRAS}"
  # The image's OWN advertisement picks the pytorch-* extra, so a cpu wrapper is never
  # asked for the rocm extra's wheels.
  local torch_extra
  torch_extra="$(printf '%s\n' "${probe}" | sed -n 's/^ADV PYTORCH_EXTRA //p' | head -1)"
  case "${torch_extra}" in
    "") printf 'NOADV PYTORCH_EXTRA -\n' ;;
    none) ;;
    *) extras="${extras} ${torch_extra}" ;;
  esac
  for extra in ${extras}; do
    reqs="$(printf '%s\n' "${probe}" | awk -v e="${extra}" '$1=="REQ" && $2==e {print $3}' | LC_ALL=C sort -u)"
    if [ -z "${reqs}" ]; then
      printf 'NOREQ %s -\n' "${extra}"
      continue
    fi
    for r in ${reqs}; do
      if printf '%s\n' "${pkgs}" | grep -qxF -- "${r}"; then
        if _venv_pkg_exempt "${arch}" "${extra}" "${r}"; then
          printf 'STALE %s %s\n' "${extra}" "${r}"
        else
          asserted=$((asserted + 1))
        fi
      elif _venv_pkg_exempt "${arch}" "${extra}" "${r}"; then
        printf 'EXEMPT %s %s\n' "${extra}" "${r}"
      else
        printf 'MISS %s %s\n' "${extra}" "${r}"
      fi
    done
  done
  while read -r owner name; do
    [ -n "${name}" ] || continue
    if _venv_pkg_exempt "${arch}" DEP "${name}"; then
      printf 'EXEMPT DEP %s %s\n' "${name}" "${owner}"
    else
      printf 'MISS DEP %s %s\n' "${name}" "${owner}"
    fi
  done < <(printf '%s\n' "${probe}" | sed -n 's/^DANG //p' | LC_ALL=C sort -u)
  printf 'ASSERTED %d\n' "${asserted}"
}

# Cached probe text for this image; both gates share the single container run.
_SHIPPED_TRUTH_PROBE=""
_SHIPPED_TRUTH_PROBE_RC=1

run_shipped_truth_probe() {
  local image_tag="$1"
  local target_arch="$2"
  echo "--- SHIPPED-TRUTH probe (${target_arch}) ---"
  _SHIPPED_TRUTH_PROBE="$(_rt_run -e "RT_PROBE_SH=$(_shipped_truth_probe)" \
    bash -lc 'if [ -z "${RT_PROBE_SH:-}" ]; then echo "RTPROBE_EMPTY"; exit 4; fi
printf "%s\n" "${RT_PROBE_SH}" | bash' 2>/dev/null)" || true
  if printf '%s\n' "${_SHIPPED_TRUTH_PROBE}" | grep -qxF -- 'RTPROBE_DONE'; then
    _SHIPPED_TRUTH_PROBE_RC=0
    echo "  probe completed: $(printf '%s\n' "${_SHIPPED_TRUTH_PROBE}" | grep -c '^PKG ' || true) venv distributions, $(printf '%s\n' "${_SHIPPED_TRUTH_PROBE}" | grep -c '^REQ ' || true) requirement edges"
  else
    _SHIPPED_TRUTH_PROBE_RC=1
    echo "  probe did NOT complete (no RTPROBE_DONE marker) -- both shipped-truth gates below will report it"
  fi
  echo ""
}

# A: the image must not advertise a version it does not have.
# Pure verdict function for the riscv64 ISA gate: probe text in, one
# "OK|BAD|SKIP <lib> <attr>" line out per shipped object.
_rvv_verdicts() {
  local probe="$1" lib attr n=0 cc vcc=0
  cc="$(printf '%s\n' "${probe}" | sed -n 's/^RVCC //p' | head -1)"
  # Only demand vector once the image's OWN toolchain defaults to it. Before that
  # switch a plain object is the documented old state, not a regression.
  case "${cc}" in rva23*|*gcv*|*_v|*_v_*) vcc=1 ;; esac
  while read -r lib attr; do
    [ -n "${lib}" ] || continue
    n=$((n + 1))
    case "${attr}" in
      "")        printf 'SKIP %s no ISA attribute could be read\n' "${lib}" ;;
      *_v1p0*)   printf 'OK %s %s\n' "${lib}" "${attr}" ;;
      *)         if [ "${vcc}" = "1" ]; then printf 'BAD %s %s\n' "${lib}" "${attr}"
                 else printf 'OLD %s %s\n' "${lib}" "${attr}"; fi ;;
    esac
  done < <(printf '%s\n' "${probe}" | sed -n 's/^RVARCH //p')
  [ "${n}" -gt 0 ] || printf 'NONE - -\n'
}

# C: riscv64 objects must carry the vector extension Ubuntu's own userland requires.
check_riscv64_isa() {
  local image_tag="$1" target_arch="$2"
  [ "${target_arch}" = riscv64 ] || return 0
  echo "--- SHIPPED-TRUTH C: riscv64 ISA of the shipped objects ---"
  if [ "${_SHIPPED_TRUTH_PROBE_RC}" != "0" ]; then
    fail "riscv64 ISA gate could not run: the in-image probe never printed RTPROBE_DONE"
    echo ""
    return 0
  fi
  local verb lib attr bad=0 ok=0
  while read -r verb lib attr; do
    case "${verb}" in
      OK)   ok=$((ok + 1)) ;;
      BAD)  bad=$((bad + 1))
            fail "RVV: ${lib} was built WITHOUT the vector extension (${attr}) -- the image's own glibc requires it, so this object is below the platform baseline. See docs/riscv64-rva23-baseline.md" ;;
      SKIP) echo "  ~~   ${lib}: ${attr}" ;;
      OLD)  echo "  ~~   ${lib} predates the RVA23 switch (${attr}); the image's own gcc has no vector default either" ;;
      NONE) fail "RVV: the probe found none of the objects it checks -- a vacuous pass, not a green image" ;;
    esac
  done < <(_rvv_verdicts "${_SHIPPED_TRUTH_PROBE}")
  [ "${bad}" -ne 0 ] || [ "${ok}" -eq 0 ] || pass "RVV: all ${ok} checked object(s) carry v1p0"
  echo ""
}

# Pure verdict function for the soname-precedence gate.
_soname_verdicts() {
  local probe="$1" so win ours n=0
  while read -r so win ours; do
    [ -n "${so}" ] || continue
    n=$((n + 1))
    # Ours lives under /opt AND /usr/local (onnxruntime, litert). The failure
    # to catch is a DISTRO copy winning, i.e. a multiarch or plain system dir.
    case "${win}" in
      /opt/*|/usr/local/*) printf 'OK %s %s\n' "${so}" "${win}" ;;
      *)                   printf 'BAD %s %s %s\n' "${so}" "${win}" "${ours}" ;;
    esac
  done < <(printf '%s\n' "${probe}" | sed -n 's/^SONAME //p')
  [ "${n}" -gt 0 ] || printf 'NONE - - -\n'
}

# D: a library we ship must not lose the ld.so lookup to a distro copy.
check_soname_precedence() {
  local image_tag="$1" target_arch="$2"
  echo "--- SHIPPED-TRUTH D: our libraries win the ld.so lookup (${target_arch}) ---"
  if [ "${_SHIPPED_TRUTH_PROBE_RC}" != "0" ]; then
    fail "soname-precedence gate could not run: the in-image probe never printed RTPROBE_DONE"
    echo ""
    return 0
  fi
  local verb so win ours bad=0 ok=0
  while read -r verb so win ours; do
    case "${verb}" in
      OK)   ok=$((ok + 1)) ;;
      BAD)  bad=$((bad + 1))
            fail "SONAME: ${so} resolves to ${win}, NOT to our ${ours} -- a consumer linking it gets the distro build. Give our tree a 000-*.conf in /etc/ld.so.conf.d (docs/cross-build-verification.md)." ;;
      NONE) fail "SONAME: the probe found no shipped sonames at all -- a vacuous pass, not a green image" ;;
    esac
  done < <(_soname_verdicts "${_SHIPPED_TRUTH_PROBE}")
  [ "${bad}" -ne 0 ] || [ "${ok}" -eq 0 ] || pass "SONAME: all ${ok} shipped library(ies) win their lookup"
  echo ""
}

check_advertised_versions() {
  local image_tag="$1"
  local target_arch="$2"
  echo "--- SHIPPED-TRUTH A: advertised env versions == actual (${target_arch}) ---"
  if [ "${_SHIPPED_TRUTH_PROBE_RC}" != "0" ]; then
    fail "advertised-version gate could not run: the in-image probe never printed RTPROBE_DONE (${target_arch}) -- a gate that cannot run is not a pass"
    echo ""
    return 0
  fi
  local verb key rest ok=0 bad=0
  while read -r verb key rest; do
    [ -n "${verb}" ] || continue
    case "${verb}" in
      OK)     echo "  OK   ${key}=${rest} matches the image"; ok=$((ok + 1)) ;;
      BAD)    bad=$((bad + 1))
              fail "the ${target_arch} image ADVERTISES ${key}=${rest%% *} but actually has ${rest##* } -- everything downstream reads the env, so the label must be corrected (or the component rebuilt)" ;;
      UNSET)  bad=$((bad + 1))
              fail "the ${target_arch} image sets NO ${key}, so its row could only ever SKIP -- advertise it as ENV in Dockerfile.package, or excuse it in verify_advertised_keys.py and drop the row from _ADVERTISED_VERSION_KEYS" ;;
      UNREAD) bad=$((bad + 1))
              fail "the ${target_arch} image advertises ${key}=${rest} but the in-image probe could NOT read the actual value -- that is the shape the builder's rustc shipped in for months; fix the probe or the component, never the verdict" ;;
      *)      bad=$((bad + 1))
              fail "advertised-version gate: unknown verdict '${verb}' for ${key} on ${target_arch} -- a verb no arm handles is a silently dropped row" ;;
    esac
  done < <(_advert_verdicts "${_SHIPPED_TRUTH_PROBE}")
  if [ "$((ok + bad))" -eq 0 ]; then
    fail "advertised-version gate asserted NOTHING on ${target_arch}: _ADVERTISED_VERSION_KEYS is empty -- a vacuous pass, not a green image"
  elif [ "${bad}" -eq 0 ]; then
    pass "all ${ok} advertised version(s) match the shipped image (${target_arch})"
  fi
  echo ""
}

# B: the venv must carry what the app's own metadata says this arch needs.
check_venv_package_set() {
  local image_tag="$1"
  local target_arch="$2"
  echo "--- SHIPPED-TRUTH B: venv package set vs the app's declared graph (${target_arch}) ---"
  if [ "${_SHIPPED_TRUTH_PROBE_RC}" != "0" ]; then
    fail "venv package-set gate could not run: the in-image probe never printed RTPROBE_DONE (${target_arch}) -- a gate that cannot run is not a pass"
    echo ""
    return 0
  fi
  local absent
  absent="$(printf '%s\n' "${_SHIPPED_TRUTH_PROBE}" | sed -n 's/^VENV ABSENT //p' | head -1)"
  if [ -n "${absent}" ]; then
    echo "  SKIP venv package-set comparison UNAVAILABLE on ${target_arch}: ${absent}"
    echo "  SKIP   -- this is a loud skip, NOT a pass; the set was never compared"
    echo ""
    return 0
  fi
  local verb extra pkg owner miss=0 asserted=0
  while read -r verb extra pkg owner; do
    case "${verb}" in
      MISS)
        miss=$((miss + 1))
        if [ "${extra}" = "DEP" ]; then
          fail "VENV-SET: ${pkg} is required by the installed ${owner} but is ABSENT from the ${target_arch} venv -- a dangling dependency edge; ship it or record it in _venv_pkg_exempt"
        else
          fail "VENV-SET: the app declares ${pkg} for extra '${extra}' on ${target_arch} (its own marker says this arch needs it) but the venv does NOT have it -- ship it or record the exception in _venv_pkg_exempt"
        fi ;;
      STALE)
        miss=$((miss + 1))
        fail "VENV-SET: the documented exception for ${extra}:${pkg} NO LONGER APPLIES -- ${pkg} is PRESENT on ${target_arch}. Delete that arm from _venv_pkg_exempt in linux/scripts/06-packaging/smoke-runtime-image.sh." ;;
      EXEMPT)
        echo "  ~~   ${extra}:${pkg} absent (documented exception)" ;;
      NOREQ)
        miss=$((miss + 1))
        fail "VENV-SET: the app declares NO requirement at all for extra '${extra}' on ${target_arch} -- either the extra was renamed upstream (update _VENV_CONTRACT_EXTRAS) or the metadata is truncated; the gate refuses to assert an empty set" ;;
      NOADV)
        miss=$((miss + 1))
        fail "VENV-SET: the image advertises NO PYTORCH_EXTRA at all on ${target_arch} -- the gate would silently drop the torch extra from its scope. Set it (the literal 'none' for a torch-less image)." ;;
      ASSERTED)
        asserted="${extra}" ;;
    esac
  done < <(_venv_set_verdicts "${target_arch}" "${_SHIPPED_TRUTH_PROBE}")
  if [ "${asserted}" -eq 0 ] 2>/dev/null; then
    fail "VENV-SET asserted NOTHING on ${target_arch} -- no requirement edge was checked, so a green here would be vacuous"
  elif [ "${miss}" -eq 0 ]; then
    pass "VENV-SET: all ${asserted} arch-applicable requirement edge(s) satisfied in the ${target_arch} venv"
  fi
  echo ""
}

# GStreamer plugin health -- WARN only: unlike ffmpeg/opencv, a plugin whose runtime
# .so is absent degrades gracefully (the element is just unavailable), so it must not
# fail the gate - but it must stay visible. The functional pipeline check below is the
# fail-loud gate for GStreamer CORE.
check_gstreamer_plugin_health() {
  local image_tag="$1"
  local target_arch="$2"
    echo "--- Functional: GStreamer plugin health (informational) ---"
    # gst-inspect drives the plugin SCANNER, which dlopen()s each plugin and so reports
    # UNDEFINED-SYMBOL failures (gtk4 -> vkCreateWaylandSurfaceKHR) that `ldd` cannot see.
    # THE HEADLINE NUMBER IS STILL THE RAW LINE COUNT: classification works on unique
    # libgst*.so basenames, a strictly smaller denominator, and quietly lowering a
    # metric watched since wave-4 would hide a regression. Both are printed, side by side.
    local scan failed p known=0 unknown=0 total named unnamed
    scan="$(_rt_run bash -lc 'command -v gst-inspect-1.0 >/dev/null 2>&1 || { echo "GST_SCAN_ABSENT"; exit 0; }
gst-inspect-1.0 2>&1 >/dev/null || true
echo "GST_SCAN_DONE"' 2>/dev/null)" || true
    # An empty scan is AMBIGUOUS -- a healthy image prints nothing here either -- so the
    # probe stamps its own completion; without it "0 cannot load" is a false green.
    if ! printf '%s\n' "${scan}" | grep -q '^GST_SCAN_DONE$'; then
      if printf '%s\n' "${scan}" | grep -q '^GST_SCAN_ABSENT$'; then
        echo "  WARN gst-inspect-1.0 is not on PATH in the ${target_arch} image -- plugin health UNKNOWN, not 0"
      else
        echo "  WARN the GStreamer plugin scan did not complete in the ${target_arch} image -- plugin health UNKNOWN, not 0"
      fi
      echo ""
      return 0
    fi
    total="$(printf '%s\n' "${scan}" | grep -c "Failed to load plugin" || true)"
    failed="$(printf '%s\n' "${scan}" | grep "Failed to load plugin" \
                | grep -oE 'libgst[A-Za-z0-9_+-]+\.so' | sort -u || true)"
    named="$(printf '%s\n' "${scan}" | grep "Failed to load plugin" \
               | grep -cE 'libgst[A-Za-z0-9_+-]+\.so' || true)"
    unnamed=$((total - named))
    for p in ${failed}; do
      if _parity_gst_plugin_known "${target_arch}" "${p}"; then
        echo "  ~~   ${p} cannot load -- documented ${target_arch} exception (_parity_gst_plugin_known)"
        known=$((known + 1))
      else
        echo "  WARN ${p} cannot load on ${target_arch} and is NOT in the parity table -- new drift; fix it or record it (non-fatal)"
        unknown=$((unknown + 1))
      fi
    done
    printf '%s\n' "${scan}" | grep "Failed to load plugin" \
      | sed "s/^.*Failed/  degraded: Failed/" | sort -u | head -40 || true
    echo "  GStreamer plugins that cannot load: ${total} (non-fatal)"
    local unnamed_note=""
    if [ "${unnamed}" -gt 0 ]; then
      unnamed_note="; ${unnamed} failure line(s) name no libgst*.so and could not be classified"
    fi
    echo "  ... of those, by unique libgst*.so basename: ${known} documented, ${unknown} undocumented${unnamed_note}"

    # The OTHER direction, and why the table is a list: a documented failure that
    # stopped failing. The loop above can only speak about plugins that DID fail, so
    # walk the table's own claims for this arch instead. POSITIVE EVIDENCE ONLY, two
    # signals that must agree - absent from the scanner's failure list AND
    # gst-inspect-1.0 loads the plugin file directly. Absence alone proves nothing (it
    # may simply not be shipped); only both together falsify the entry, which is a
    # defect of the same kind as a stale _parity_exempt arm.
    local _kb_entry _kb_plugin
    for _kb_entry in ${_PARITY_GST_KNOWN_BROKEN}; do
      [ "${_kb_entry%%:*}" = "${target_arch}" ] || continue
      _kb_plugin="${_kb_entry#*:}"
      # `failed` is NEWLINE-separated, so a `case " ${failed} " in *" plugin "*` guard
      # only matched while exactly ONE plugin failed. Match the delimiter the list uses.
      if printf '%s\n' "${failed}" | grep -qxF -- "${_kb_plugin}"; then
        continue   # still failing = entry still true
      fi
      if _rt_run bash -lc '
p="$1"
command -v gst-inspect-1.0 >/dev/null 2>&1 || exit 1
for d in $(printf "%s" "${GST_PLUGIN_PATH:-}" | tr ":" " ") /usr/lib/*/gstreamer-1.0 /usr/local/lib/gstreamer-1.0; do
  [ -f "${d}/${p}" ] || continue
  gst-inspect-1.0 "${d}/${p}" >/dev/null 2>&1 && exit 0
done
exit 1' _ "${_kb_plugin}" >/dev/null 2>&1; then
        fail "ARCH-PARITY: the documented ${target_arch} exception for ${_kb_plugin} NO LONGER APPLIES -- it is absent from the scanner's failure list AND gst-inspect-1.0 loads the plugin file directly. Delete '${target_arch}:${_kb_plugin}' from _PARITY_GST_KNOWN_BROKEN in linux/scripts/06-packaging/smoke-runtime-image.sh."
      else
        echo "  INFO ${_kb_plugin}: not in this run's failure list and not directly loadable either (not shipped, or unloadable without a scanner message) -- ${target_arch} exception retained"
      fi
    done
    echo ""
}

# onnxruntime inference and the cv2 encode/decode round-trip live in the app wheel
# smoke above.

check_gstreamer_core_pipeline() {
  local image_tag="$1"
  local target_arch="$2"
    echo "--- Functional: GStreamer core pipeline ---"
    if _rt_run \
         bash -lc 'gl="$(command -v gst-launch-1.0 || echo /opt/gstreamer/bin/gst-launch-1.0)"; timeout 40 "$gl" -q videotestsrc num-buffers=3 ! videoconvert ! fakesink'; then
      pass "GStreamer core pipeline runs (${target_arch})"
    else
      fail "GStreamer core pipeline FAILED (${target_arch})"
    fi
    echo ""
}

# Mandatory-plugin GATE on the real target arch (smoke-depth R1), mirroring the Windows
# lane's 4-point contract: gst-inspect-1.0 <plugin> exits non-zero if the plugin is
# missing OR fails to dlopen.
check_gstreamer_mandatory_plugins() {
  local image_tag="$1"
  local target_arch="$2"
    echo "--- Functional: GStreamer mandatory plugins (libav opencv onnx tflite) ---"
    if _rt_run \
         bash -lc 'gi="$(command -v gst-inspect-1.0 || echo /opt/gstreamer/bin/gst-inspect-1.0)"; missing=""; for p in libav opencv onnx tflite; do timeout 30 "$gi" "$p" >/dev/null 2>&1 || missing="$missing $p"; done; [ -z "$missing" ] || { echo "MISSING:$missing"; exit 1; }'; then
      pass "GStreamer mandatory plugin set loads on ${target_arch}"
    else
      fail "GStreamer mandatory plugins missing/unloadable on ${target_arch} (see MISSING: line above)"
    fi
    echo ""
}

check_application_import() {
  local image_tag="$1"
  local target_arch="$2"
    echo "--- Functional: application import ---"
    # The actual deliverable: a broken/incomplete app install (missing runtime dep)
    # shipped silently before, so import it through the venv python.
    if _rt_run \
         /opt/venv/bin/python -c "import orchestrant" >/dev/null 2>&1; then
      pass "application module imports (${target_arch})"
    else
      fail "application module (orchestrant) failed to import in the venv (${target_arch})"
    fi
    echo ""
}

# Run the ACTUAL HEALTHCHECK command, not just parse its Test string: a broken
# interpreter path or a mislinked onnxruntime leaves every container perpetually
# `unhealthy` while a string-only check stays green.
check_healthcheck_exec() {
  local image_tag="$1"
  local target_arch="$2"
    echo "--- Functional: HEALTHCHECK command executes ---"
    # Run the image's OWN command. A hardcoded copy passes while the shipped
    # HEALTHCHECK is broken -- the one case this gate exists for.
    local _hc
    _hc="$(_rt_healthcheck_cmd)"
    if [ -z "${_hc}" ]; then
      fail "HEALTHCHECK has no command to run (${target_arch})"
    elif _rt_run bash -lc "${_hc}" >/dev/null 2>&1; then
      pass "HEALTHCHECK command runs as configured (${target_arch}): ${_hc}"
    else
      fail "HEALTHCHECK command FAILED (${target_arch}) -- container would report unhealthy: ${_hc}"
    fi
    echo ""
}

# WebRTC signalling server: start-webrtc-signalling.sh execs this binary. WARN-only --
# same gst-plugins-rs/webrtc lane as the known webrtcbin2 gap (backlog), so its absence
# must not gate the manifest, but a dead signalling entrypoint should stay visible.
check_webrtc_signalling() {
  local image_tag="$1"
  local target_arch="$2"
    echo "--- Functional: WebRTC signalling-server binary (informational) ---"
    if _rt_run \
         bash -lc 's="$(command -v gst-webrtc-signalling-server || echo /opt/gstreamer/bin/gst-webrtc-signalling-server)"; [ -x "$s" ] && "$s" --help >/dev/null 2>&1'; then
      echo "  OK  gst-webrtc-signalling-server present + runnable (${target_arch})"
    else
      echo "  WARN gst-webrtc-signalling-server missing/not runnable (${target_arch}) -- WebRTC signalling entrypoint would fail (non-fatal)"
    fi
    echo ""
}

# The path /proc/self/maps names for the loaded loader, out of the probe's output.
# docs/artifact-copy-completeness.md#the-vulkan-tree-ships-only-what-the-image-runs
_vk_loaded_path() {
  printf '%s' "${1}" | sed -n 's/^VKLIB //p' | head -1
}

# Vulkan loader load test -- the .so-closure gate proves libvulkan resolves, not that
# the loader dlopen()s at runtime. A missing ICD/GPU does NOT stop ctypes.CDLL and the
# runtime image ALWAYS installs the Vulkan runtime files, so a load failure means the
# lib is missing/broken and FAILS; only a container-infra error stays WARN. WHICH
# libvulkan answered is asserted too: Ubuntu's multiarch loader is in every image, so a
# linker fallback to it would pass a load-only check with /opt/vulkan unused or unshipped.
# docs/artifact-copy-completeness.md#the-vulkan-tree-ships-only-what-the-image-runs
check_vulkan_loader() {
  local image_tag="$1"
  local target_arch="$2"
    echo "--- Functional: Vulkan loader ---"
    # vkEnumerateInstanceVersion works with ZERO ICDs and no GPU, so a healthy loader
    # cannot legitimately fail it. The AttributeError guard covers a 1.0 loader.
    _vk_out="$(_rt_run \
         /opt/venv/bin/python -c 'import ctypes
l = ctypes.CDLL("libvulkan.so.1")
try:
    print("VKLIB %s" % [m.rsplit(" ", 1)[-1].strip()
                        for m in open("/proc/self/maps") if "libvulkan" in m][0])
except (OSError, IndexError):
    pass
try:
    v = ctypes.c_uint32()
    assert l.vkEnumerateInstanceVersion(ctypes.byref(v)) == 0
    print("VKOK %d.%d.%d" % (v.value >> 22, (v.value >> 12) & 1023, v.value & 4095))
except AttributeError:
    print("VKOK (pre-1.1 loader)")' 2>&1)" || true
    _vk_lib="$(_vk_loaded_path "${_vk_out}")"
    if printf '%s' "${_vk_out}" | grep -q "VKOK"; then
      case "${_vk_lib}" in
        /opt/vulkan/*) echo "  OK  libvulkan.so.1 loads from ${_vk_lib} (${target_arch})" ;;
        '')            echo "  WARN libvulkan.so.1 loads but /proc/self/maps named no path -- non-fatal" ;;
        *)             fail "libvulkan.so.1 loaded from ${_vk_lib} in the ${target_arch} image, not from /opt/vulkan -- the shipped SDK prefix is not what the loader resolves to (pruned too far, or LD_LIBRARY_PATH lost it)" ;;
      esac
    elif printf '%s' "${_vk_out}" | grep -qiE "OSError|No such file|cannot open shared object|not found"; then
      fail "libvulkan.so.1 missing/unloadable in ${target_arch} image (runtime always ships it): $(printf '%s' "${_vk_out}" | tail -1)"
    else
      echo "  WARN vulkan load check inconclusive (container-infra error?) -- non-fatal: $(printf '%s' "${_vk_out}" | tail -1)"
    fi
    echo ""
}

# A cross-built SDK prefix that carries libraries but no tools links fine and is
# useless to build an application with -- that shipped for months unnoticed because
# every Vulkan check here asked about the loader. REQUIRED is the set proven to
# cross-build; the rest is reported so a silent loss is still visible.
# docs/vulkan-foreign-arch-sdk.md
_VK_REQUIRED_TOOLS="glslangValidator spirv-opt spirv-val spirv-dis spirv-as spirv-link"
_VK_REPORTED_TOOLS="glslc vulkaninfo spirv-cross spirv-reflect spirv-lint spirv-reduce"

check_vulkan_toolset() {
  local image_tag="$1"
  local target_arch="$2"
  local out missing found layer

    echo "--- Functional: Vulkan SDK toolset ---"
    out="$(_rt_run /bin/sh -c '
      for t in '"${_VK_REQUIRED_TOOLS} ${_VK_REPORTED_TOOLS}"'; do
        [ -x "${VULKAN_SDK}/bin/${t}" ] && echo "TOOL ${t}"
      done
      ls "${VULKAN_SDK}"/share/vulkan/explicit_layer.d/*validation*.json >/dev/null 2>&1 \
        && echo LAYER yes' 2>&1)" || true

    missing=""
    for t in ${_VK_REQUIRED_TOOLS}; do
      printf '%s' "${out}" | grep -qx "TOOL ${t}" || missing="${missing} ${t}"
    done
    found="$(printf '%s' "${out}" | grep -c '^TOOL ' || true)"

    if [ -n "${missing}" ]; then
      fail "the ${target_arch} Vulkan SDK prefix is missing required tools:${missing} -- \
the prefix carries libraries the linker is happy with but nothing you can build a shader with \
(see docs/vulkan-foreign-arch-sdk.md)"
    else
      echo "  OK  ${found} SDK tools present in \${VULKAN_SDK}/bin (${target_arch})"
    fi

    for t in ${_VK_REPORTED_TOOLS}; do
      printf '%s' "${out}" | grep -qx "TOOL ${t}" \
        || echo "  WARN ${t} absent from the ${target_arch} SDK prefix -- non-fatal"
    done
    layer="$(printf '%s' "${out}" | grep -c '^LAYER yes' || true)"
    [ "${layer}" -gt 0 ] \
      && echo "  OK  validation layer manifest present (${target_arch})" \
      || echo "  WARN no validation layer manifest in the ${target_arch} SDK -- non-fatal"
    echo ""
}

# The ABI /opt/android is compiled for, asserted against the ABI the image says it
# targets. That tree is tree-arch EXEMPT on purpose -- an Android arm64-v8a payload
# is AArch64 in EVERY image, including the amd64 one -- so nothing else could catch
# a layer built for the wrong ABI, and it derived from the BUILD HOST for months.
# It reached a consumer as a link error, not a missing file.
# docs/linux-cross-builds.md#the-android-abi-is-a-target-not-the-build-host
_ANDROID_ABI_MACHINE="arm64-v8a:183 x86_64:62 x86:3 riscv64:243"

_android_abi_want() {
  local row
  for row in ${_ANDROID_ABI_MACHINE}; do
    [ "${row%%:*}" = "$1" ] && { printf '%s' "${row#*:}"; return 0; }
  done
  return 1
}

# Archives matter as much as shared objects here: the reported failure was a .a
# member, which `file` on the archive itself does not report.
_android_abi_py() {
  cat <<'PY'
import collections, os, struct

def machine(b):
    return struct.unpack_from("<H", b, 18)[0] if b[:4] == b"\x7fELF" else None

def archive_machine(path):
    with open(path, "rb") as fh:
        if fh.read(8) != b"!<arch>\n":
            return None
        for _ in range(6):                      # skip "/" and "//" bookkeeping members
            head = fh.read(60)
            if len(head) < 60:
                return None
            size = int(head[48:58].decode("ascii", "replace").strip() or 0)
            body = fh.read(min(size, 20))
            fh.seek(size - len(body) + (size % 2), 1)
            got = machine(body)
            if got:
                return got
    return None

seen, sample = collections.Counter(), {}
for root, _dirs, files in os.walk("/opt/android"):
    for name in files:
        path = os.path.join(root, name)
        try:
            if name.endswith(".a"):
                got = archive_machine(path)
            elif name.endswith(".so") or ".so." in name:
                with open(path, "rb") as fh:
                    got = machine(fh.read(20))
            else:
                continue
        except OSError:
            continue
        if got:
            seen[got] += 1
            sample.setdefault(got, path)
for got, count in seen.most_common():
    print("MACH %d %d %s" % (got, count, sample[got]))
PY
}

check_android_abi() {
  local image_tag="$1"
  local target_arch="$2"
  local out abi want mach count path bad=0 total=0

    echo "--- Functional: Android SDK ABI ---"
    out="$(_rt_run /bin/sh -c "echo \"ABI \${ANDROID_TARGET_ABI:-unset}\"; \
      /opt/venv/bin/python -c \"$(_android_abi_py | sed 's/"/\\"/g')\"" 2>&1)" || true

    abi="$(printf '%s' "${out}" | sed -n 's/^ABI //p' | head -1)"
    if [ -z "${abi}" ] || [ "${abi}" = unset ]; then
      fail "the ${target_arch} image does not advertise ANDROID_TARGET_ABI -- a consumer cannot tell which Android ABI /opt/android was built for"
      echo ""
      return 0
    fi
    if ! want="$(_android_abi_want "${abi}")"; then
      fail "ANDROID_TARGET_ABI=${abi} in the ${target_arch} image is not an ABI this gate knows (${_ANDROID_ABI_MACHINE})"
      echo ""
      return 0
    fi

    while read -r _tag mach count path; do
      [ "${_tag}" = MACH ] || continue
      total=$((total + count))
      if [ "${mach}" != "${want}" ]; then
        fail "/opt/android carries ${count} object(s) of ELF machine ${mach} but the image advertises ANDROID_TARGET_ABI=${abi} (machine ${want}) -- e.g. ${path}; a consumer linking for ${abi} gets \"is incompatible\" at link time"
        bad=$((bad + 1))
      fi
    done <<EOF
$(printf '%s' "${out}")
EOF

    if [ "${total}" -eq 0 ]; then
      echo "  WARN no Android ELF objects found under /opt/android (${target_arch}) -- non-fatal"
    elif [ "${bad}" -eq 0 ]; then
      echo "  OK  ${total} Android object(s) are all ${abi} (${target_arch})"
    fi
    echo ""
}

# Native compiler compile + link + RUN. The build-time validate-compilers.sh compiles
# and links in every wrapper image but never RUNS the result - a cross arch's binary
# cannot execute on the x86_64 build host, so the shipped native GCC/G++ was only ever
# ELF/link-verified. Here the wrapper runs under binfmt/qemu, so the on-target compiler
# is finally proven end to end. Skip with RUNTIME_COMPILER_SMOKE=0.
check_native_compiler_battery() {
  local image_tag="$1"
  local target_arch="$2"
    if [ "${RUNTIME_COMPILER_SMOKE}" = "1" ]; then
      echo "--- Functional: native compiler battery compile+link+run (${target_arch}) ---"
      # A battery, not a hello-world: each case exercises a distinct piece of the
      # shipped toolchain. C++ exceptions+STL is the load-bearing one - it regression-
      # guards the -idirafter WRAPPER fix in swap-native-gcc.sh, where an installed
      # specs file made throw/catch terminate at runtime. Sources use only double
      # quotes / return codes so they stay clean inside bash -lc.
      if _rt_run \
           bash -lc 'set -uo pipefail
cc="$(command -v gcc || command -v cc || true)"
cxx="$(command -v g++ || command -v c++ || true)"
[ -n "$cc" ] || { echo "no gcc/cc on PATH"; exit 3; }
d="$(mktemp -d)"; rc=0
report(){ if [ "$2" = 0 ]; then echo "  OK  $1"; else echo "  XX  $1"; sed "s/^/       /" "$d/e" 2>/dev/null | head -4; rc=1; fi; }
# C: hello (compile+link+RUN, verify stdout)
printf "#include <stdio.h>\nint main(void){puts(\"c-ok\");return 0;}\n" > "$d/c.c"
{ "$cc" -O2 "$d/c.c" -o "$d/c" 2>"$d/e" && [ "$("$d/c")" = c-ok ]; }; report "C   hello (stdout=c-ok)" $?
# C: pthreads
printf "#include <pthread.h>\nstatic void* w(void*a){*(int*)a=42;return 0;}\nint main(void){pthread_t t;int v=0;pthread_create(&t,0,w,&v);pthread_join(t,0);return v==42?0:1;}\n" > "$d/th.c"
{ "$cc" -O2 "$d/th.c" -o "$d/th" -pthread 2>"$d/e" && "$d/th"; }; report "C   pthreads (-pthread)" $?
# C: libm
printf "#include <math.h>\nint main(void){double x=sqrt(2.0)*sqrt(2.0);return (int)(x+0.5)==2?0:1;}\n" > "$d/m.c"
{ "$cc" -O2 "$d/m.c" -o "$d/m" -lm 2>"$d/e" && "$d/m"; }; report "C   libm (-lm)" $?
# C: libatomic (64-bit atomics; riscv64 requires the runtime lib)
printf "#include <stdio.h>\nint main(void){long long v=0;__atomic_fetch_add(&v,42,__ATOMIC_SEQ_CST);return v==42?0:1;}\n" > "$d/a.c"
{ "$cc" -O2 "$d/a.c" -o "$d/a" -latomic 2>"$d/e" && "$d/a"; }; report "C   libatomic (-latomic)" $?
if [ -n "$cxx" ]; then
  # C++: hello (compile+link+RUN libstdc++, verify stdout)
  printf "#include <iostream>\nint main(){std::cout<<\"cxx-ok\"<<std::endl;return 0;}\n" > "$d/x.cpp"
  { "$cxx" -O2 "$d/x.cpp" -o "$d/x" 2>"$d/e" && [ "$("$d/x")" = cxx-ok ]; }; report "C++ hello (stdout=cxx-ok)" $?
  # C++: exceptions + STL -- regression guard for the -idirafter wrapper fix
  printf "#include <vector>\n#include <string>\n#include <stdexcept>\n#include <algorithm>\nint main(){std::vector<std::string> v{\"c\",\"a\",\"b\"};std::sort(v.begin(),v.end());std::string j;for(auto&s:v)j+=s;try{throw std::runtime_error(\"x\");}catch(const std::exception&e){j+=e.what();}return j==\"abcx\"?0:1;}\n" > "$d/e.cpp"
  { "$cxx" -O2 "$d/e.cpp" -o "$d/ex" 2>"$d/e" && "$d/ex"; }; report "C++ exceptions+STL (throw/catch/sort)" $?
  # C++: std::thread
  printf "#include <thread>\n#include <atomic>\nint main(){std::atomic<int> n{0};std::thread t([&]{n=42;});t.join();return n==42?0:1;}\n" > "$d/t.cpp"
  { "$cxx" -O2 "$d/t.cpp" -o "$d/tt" -pthread 2>"$d/e" && "$d/tt"; }; report "C++ std::thread" $?
  # C++: link-time optimization
  printf "int sq(int x){return x*x;}\nint main(){return sq(7)==49?0:1;}\n" > "$d/l.cpp"
  { "$cxx" -O2 -flto "$d/l.cpp" -o "$d/l" 2>"$d/e" && "$d/l"; }; report "C++ LTO (-flto)" $?
fi
echo "  gcc $("$cc" -dumpversion) [$("$cc" -dumpmachine)]"
exit $rc'; then
        pass "native compiler battery (C hello/pthreads/libm/atomic + C++ hello/exceptions/thread/LTO) all pass on ${target_arch}"
      else
        fail "native compiler battery had FAILURES in the runtime image (${target_arch}) -- see XX lines above"
      fi
      echo ""
    fi
}

# Clang/LLVM version alignment on the ACTUAL shipped image, per-arch under qemu. The
# build-time checks run in the TOOLCHAIN stage where clang and LLVM_RELEASE agree by
# construction, so they cannot catch a STALE toolchain - e.g. a --from-stage media
# publish reusing a cross-sdk whose clang predates an LLVM_RELEASE bump. Disable with
# RUNTIME_CLANG_VERSION_SMOKE=0.
check_clang_llvm_release() {
  local image_tag="$1"
  local target_arch="$2"
    if [ "${RUNTIME_CLANG_VERSION_SMOKE}" = "1" ]; then
      echo "--- Functional: clang/clang++ version == LLVM_RELEASE (${target_arch}) ---"
      local _llvm_release="${LLVM_RELEASE:-}"
      if [ -z "${_llvm_release}" ]; then
        local _venv
        _venv="$(cd "$(dirname "${BASH_SOURCE[0]}")/../01-core" 2>/dev/null && pwd)/versions.env"
        # `|| true`: under set -euo pipefail an absent key would abort the whole
        # smoke with no summary; the explicit fail below reports it instead.
        [ -f "${_venv}" ] && _llvm_release="$(grep -E '^LLVM_RELEASE=' "${_venv}" | head -1 | cut -d= -f2 || true)"
      fi
      if [ -z "${_llvm_release}" ]; then
        fail "clang-version smoke: could not resolve LLVM_RELEASE (env or versions.env)"
      elif _rt_run -e "WANT_LLVM=${_llvm_release}" \
             bash -lc 'set -uo pipefail
rc=0
for tool in clang clang++; do
  p="$(command -v "$tool" || true)"
  [ -n "$p" ] || { echo "  XX  $tool not on PATH"; rc=1; continue; }
  # EXECUTE the tool for its version — never scrape the binary with strings.
  # The old strings-based extraction false-negatived on arm64 (2026-08-11):
  # the dylib-linked target clang keeps its version string in libLLVM.so, so
  # the slim driver binary greps EMPTY while `clang --version` prints 22.1.8
  # perfectly. This smoke runs INSIDE the image (qemu for cross arches), so
  # execution is always available — verify the effect, not the bytes.
  ver="$("$tool" --version 2>/dev/null | head -1 | grep -oE "[0-9]+\.[0-9]+\.[0-9]+" | head -1 || true)"
  if [ "$ver" = "$WANT_LLVM" ]; then echo "  OK  $tool $ver == LLVM_RELEASE"; else echo "  XX  $tool ${ver:-NO-VERSION-OUTPUT} != LLVM_RELEASE $WANT_LLVM"; rc=1; fi
done
exit $rc'; then
        pass "clang/clang++ report LLVM_RELEASE ${_llvm_release} on ${target_arch}"
      else
        fail "clang/clang++ version != LLVM_RELEASE ${_llvm_release} on ${target_arch} (stale toolchain / cross-sdk not rebuilt?)"
      fi
      echo ""
    fi
}

main() {
  local image_tag="${1:-}"
  local target_arch="${2:-}"

  if [ -z "${image_tag}" ]; then
    echo "Usage: $0 <image-tag> [target-arch]" >&2
    exit 1
  fi

  if [ -z "${target_arch}" ]; then
    target_arch="$(smoke_host_arch)"
  fi

  echo "=== Runtime Image Smoke Test ==="
  echo "Image: ${image_tag}"
  echo "Arch: ${target_arch}"
  echo ""

  check_image_availability "${image_tag}" "${target_arch}"
  check_trivial_command "${image_tag}" "${target_arch}"
  check_entrypoint "${image_tag}" "${target_arch}"
  check_default_entrypoint_boot "${image_tag}" "${target_arch}"
  check_healthcheck_config "${image_tag}" "${target_arch}"
  check_kataglyphis_user "${image_tag}" "${target_arch}"
  check_workdir "${image_tag}" "${target_arch}"
  check_volume "${image_tag}" "${target_arch}"
  check_oci_labels "${image_tag}" "${target_arch}"

  # 9. Functional checks (D1/D2): actually LOAD the compiled ML stack and RUN ffmpeg
  #    INSIDE the image, under binfmt/qemu for cross arches - the checks above only
  #    prove the image boots and its metadata is sane. Runs through the entrypoint so
  #    the gstreamer/libcamera/vulkan env matches runtime.
  if [ "${RUNTIME_FUNCTIONAL_SMOKE:-1}" = "1" ]; then
    check_torchless_sentinel "${image_tag}" "${target_arch}"
    check_app_wheel_smoke "${image_tag}" "${target_arch}"
    check_onnx_execution_provider "${image_tag}" "${target_arch}"
    check_ml_version_pins "${image_tag}" "${target_arch}"
    check_genai_binding "${image_tag}" "${target_arch}"
    check_iree_native "${image_tag}" "${target_arch}"
    check_ffmpeg "${image_tag}" "${target_arch}"
    check_flutter "${image_tag}" "${target_arch}"
    check_rust_toolchain "${image_tag}" "${target_arch}"
    check_consumer_contract "${image_tag}" "${target_arch}"
    check_native_so_closure "${image_tag}" "${target_arch}"
    check_manifest_tree_arch "${image_tag}" "${target_arch}"
    check_setuid_inventory "${image_tag}" "${target_arch}"
    check_size_observability "${image_tag}" "${target_arch}"
    check_venv_bytecode "${image_tag}" "${target_arch}"
    check_arch_parity "${image_tag}" "${target_arch}"
    run_shipped_truth_probe "${image_tag}" "${target_arch}"
    check_advertised_versions "${image_tag}" "${target_arch}"
    check_venv_package_set "${image_tag}" "${target_arch}"
    check_riscv64_isa "${image_tag}" "${target_arch}"
    check_soname_precedence "${image_tag}" "${target_arch}"
    check_gstreamer_plugin_health "${image_tag}" "${target_arch}"
    check_gstreamer_core_pipeline "${image_tag}" "${target_arch}"
    check_gstreamer_mandatory_plugins "${image_tag}" "${target_arch}"
    check_application_import "${image_tag}" "${target_arch}"
    check_healthcheck_exec "${image_tag}" "${target_arch}"
    check_webrtc_signalling "${image_tag}" "${target_arch}"
    check_vulkan_loader "${image_tag}" "${target_arch}"
    check_vulkan_toolset "${image_tag}" "${target_arch}"
    check_android_abi "${image_tag}" "${target_arch}"
    check_native_compiler_battery "${image_tag}" "${target_arch}"
    check_clang_llvm_release "${image_tag}" "${target_arch}"
  else
    echo "--- Functional checks skipped (RUNTIME_FUNCTIONAL_SMOKE=0) ---"
    echo ""
  fi

  smoke_summary
}

main "$@"
