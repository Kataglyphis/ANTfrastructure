#!/usr/bin/env bash
set -euo pipefail

# Runtime image smoke: boot, metadata, then in-image functional gates. docs/cross-build-verification.md#in-image-smoke-tests-need-a-built-image-not-part-of-preflight

_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${_SCRIPT_DIR}/smoke-common.sh"
source "${_SCRIPT_DIR}/check-ort-provenance.sh"
source "${_SCRIPT_DIR}/check-free-threaded-wheels.sh"

NERDCTL_BIN="${NERDCTL_BIN:-nerdctl}"

: "${RUNTIME_CLANG_VERSION_SMOKE:=1}"
: "${RUNTIME_COMPILER_SMOKE:=1}"

# Reads the caller's ${image_tag} (dynamic scope); prints empty on any error.
inspect_image_config() {
  "${NERDCTL_BIN}" image inspect "${image_tag}" 2>/dev/null | python3 -c "$1" 2>/dev/null || true
}

# Leading -e/--network pairs go to nerdctl run; reads the caller's ${image_tag}/${target_arch}.
_rt_run() {
  local -a _opts=()
  while [ "${1:-}" = "-e" ] || [ "${1:-}" = "--network" ]; do
    _opts+=("$1" "$2")
    shift 2
  done
  "${NERDCTL_BIN}" run --rm --platform "linux/${target_arch}" \
    ${_opts[@]+"${_opts[@]}"} "${image_tag}" "$@"
}

# Env wins over versions.env; EMPTY on a miss means "not asserted" (docs/gen1-riscv64-genai.md).
_rt_versions_env_pin() {
  local _key="$1" _val="${!1:-}" _venv
  if [ -z "${_val}" ]; then
    _venv="$(cd "$(dirname "${BASH_SOURCE[0]}")/../01-core" 2>/dev/null && pwd)/versions.env"
    [ -f "${_venv}" ] && _val="$(grep -E "^${_key}=" "${_venv}" | head -1 | cut -d= -f2 || true)"
  fi
  printf '%s' "${_val}"
}

# check_torchless_sentinel sets 0 when the torch-less sentinel is present; later gates read it.
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

# Default boot runs no argv, so the shipped ENTRYPOINT runs the shipped CMD; exit 42 proves status propagates.
_boot_verdict() {
  local rc="$1" out="$2" target_arch="$3"
  if [ "${rc}" != "42" ]; then
    fail "default ENTRYPOINT+CMD boot returned ${rc}, expected the script's 42 (${target_arch}) -- entrypoint.sh does not exec the CMD or died before it: ${out}"
  elif ! printf '%s' "${out}" | grep -q "gstma=yes"; then
    # Not gst=set/vulkan=set: the image ENV sets both; only gstreamer-env.sh adds the multiarch dir.
    fail "the entrypoint did not source gstreamer-env.sh (${target_arch}): ${out} -- GST_PLUGIN_PATH lacks the multiarch dir"
  elif ! printf '%s' "${out}" | grep -q "vkadd=yes"; then
    # VK_ADD_LAYER_PATH, not VULKAN_SDK: the image ENV sets VULKAN_SDK, only setup-env.sh sets this one.
    fail "the entrypoint did not source the Vulkan SDK's setup-env.sh (${target_arch}): ${out} -- VK_ADD_LAYER_PATH is unset"
  elif ! printf '%s' "${out}" | grep -q "vkarch=neutral"; then
    fail "the entrypoint left a Vulkan variable on an arch-specific SDK dir (${target_arch}): ${out} -- a foreign-arch process (riscv64 under QEMU in the amd64 image) then loads this arch's layers; docs/failure-modes.md#vulkan-env-names-an-arch-specific-sdk-dir"
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
    # Empty CMD is fine: entrypoint.sh falls back to /bin/bash, still a shell reading stdin.
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
    'echo "vkadd=${VK_ADD_LAYER_PATH:+yes}"' \
    'p=""; for v in VULKAN_SDK VK_ADD_LAYER_PATH PATH LD_LIBRARY_PATH PKG_CONFIG_PATH CMAKE_PREFIX_PATH; do eval "val=\${${v}-}"; case ":${val}:" in *:/opt/vulkan/[0-9]*) p="${p}${v},";; esac; done; echo "vkarch=${p:-neutral}"' \
           'exit 42' \
         | "${NERDCTL_BIN}" run --rm -i --platform "linux/${target_arch}" "${image_tag}" 2>/dev/null)" \
    && rc=0 || rc=$?
  _boot_verdict "${rc}" "${out}" "${target_arch}"
  echo ""
}

# Test[0] is the OCI verb (CMD/CMD-SHELL); the command is what follows it.
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

# The app owns what its wheels must do; torch-less images fall back to an onnx/numpy import.
check_app_wheel_smoke() {
  local image_tag="$1"
  local target_arch="$2"
    if [ "${_SMOKE_TORCH_EXPECTED}" = "1" ]; then
      echo "--- Functional: app wheel smoke (python -m orchestrant.smoke) ---"
      # Ratchet the ok-count, not exit 0 (a lost component only warns); floors only rise. docs/gen1-riscv64-genai.md#the-app-wheel-floor
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
        # An unreadable count fails; passing would fall back to the exit status this ratchet distrusts.
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

# A pass needs the ONNX-EP OK: sentinel: an empty SMOKE_ONNX_PY makes `python -` exit 0 having run nothing.
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
      # Fail, not skip: the image's own HEALTHCHECK imports onnxruntime.
      fail "onnxruntime/numpy not importable in the runtime image (${target_arch}) -- the HEALTHCHECK imports onnxruntime, so this is a defect: ${sentinel}"
    else
      fail "onnxruntime InferenceSession FAILED on the generated Add graph (${target_arch}, rc=${rc}): ${sentinel}"
    fi
    echo ""
}

# A pass needs the GENAI-BIND sentinel in the output, not exit 0 (docs/gen1-riscv64-genai.md).
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

# Asserts pinned versions, not just imports; pin owners: docs/cross-build-verification.md#in-image-smoke-tests-need-a-built-image-not-part-of-preflight
check_ml_version_pins() {
  local image_tag="$1"
  local target_arch="$2"
    if [ "${_SMOKE_TORCH_EXPECTED}" = "1" ]; then
      echo "--- Functional: ML version-pin assertion (${target_arch}) ---"
      # Forward only a non-empty pin: an empty one reads as "lane off" and disarms the riscv64 genai assert.
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
        # A missing riscv64 genai wheel is a real defect (docs/gen1-riscv64-genai.md).
        fail "ML-stack version-pin assertion FAILED in the runtime image (${target_arch})"
      fi
      echo ""
    fi
}

# Gates when the IREE tools are present, warns when absent (the cross lane ships runtime-only).
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
        # Warn on riscv64 only: LLVM rejects QEMU's synthetic max-ISA CPU, an emulation limit.
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
    # pipefail is required: head's 0 would hide an ffmpeg that cannot load a .so.
    if _rt_run \
         bash -lc 'set -o pipefail; v="$(command -v ffmpeg || echo /opt/ffmpeg/bin/ffmpeg)"; "$v" -version | head -1'; then
      pass "ffmpeg executes (${target_arch})"
    else
      fail "ffmpeg failed to execute in the runtime image (${target_arch})"
    fi
    echo ""
}

# As the image user, offline: --version alone passes a foreign-arch dart or root-owned .dart_tool. docs/artifact-copy-completeness.md#bootstrapping-flutter-in-the-package-stage
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

# Runs rustc for its host triple; the ADV/HAVE table only SKIPs an unreadable one. docs/failure-modes.md#the-copied-rust-toolchain-is-the-builders-arch
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

# Consumer contract. See docs/consumer-image-contract.md#the-contract
_CONSUMER_CONTRACT_ROWS="ccache-dir sccache-dir rustup-tmp cargo-home android-home jdk appimagetool dart-tool flutter-owner flatpak-runtimes appimage-runtime web-lane-tools ort-crate-env chrome android-emulator cargo-qa-tools free-threaded-python lint-tools uv-cache-seed"

# Staged-or-every-run-pays rows. See docs/consumer-image-contract.md#what-the-image-stages-so-a-run-does-not
_consumer_present_verdict() {
  local row="$1" got="$2"
  case "${got}" in
    ''|0|no) printf 'BAD %s absent' "${row}" ;;
    *)       printf 'OK %s %s' "${row}" "${got}" ;;
  esac
}

# Quotes each row's consumer-side symptom so a red run names the failure in the other repo.
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
    ort-crate-env) printf '%s' 'an ort-sys build (OxidANT'"'"'s onnxruntime feature) statically links pyke'"'"'s ORT 1.28.0 from pyke'"'"'s CDN instead of the chain ORT, and ort load-dynamic opens whichever libonnxruntime.so the loader finds first' ;;
    chrome)        printf '%s' 'flutter doctor reports "Cannot find Chrome executable at google-chrome" and "flutter test --platform chrome" has no browser, so the web lane tests nothing in one' ;;
    android-emulator) printf '%s' 'an Android lane has no device to install on: adb reports "no devices/emulators found" and every on-device test is skipped' ;;
    cargo-qa-tools) printf '%s' 'every OxidANT security and coverage step cargo-installs cargo-audit, cargo-deny and cargo-tarpaulin from crates.io first, minutes of compiles per run' ;;
    free-threaded-python) printf '%s' 'every 3.14t leg has uv download a free-threaded CPython first, its patch version unpinned' ;;
    lint-tools)    printf '%s' 'OrchestrANT'"'"'s coding bench reports "[shellcheck SKIPPED: not on PATH]" and "[hadolint SKIPPED: not on PATH]" on every row, so no bash or Dockerfile answer is linted' ;;
    uv-cache-seed) printf '%s' 'the riscv64 Python lane'"'"'s uv sync of the test extra builds numpy, matplotlib, contourpy, pillow, line-profiler, psutil and pyyaml under QEMU: 108 min of a 6 h job' ;;
    *)             printf '%s' 'no symptom recorded for this row' ;;
  esac
}

# Key <arch>:<row>; an arm that stops applying fails. docs/consumer-image-contract.md#per-arch-exemptions
_consumer_contract_exempt() {
  case "$1:$2" in
    # No upstream riscv64 Flutter SDK, so there is no .dart_tool (flutter-owner still holds there).
    riscv64:dart-tool) return 0 ;;
    # No riscv64 AppImage build; packaging-deps.sh refuses the arch.
    riscv64:appimagetool) return 0 ;;
    # Flathub runtimes are x86_64/aarch64 only; the AppImage runtime comes from appimagetool.
    riscv64:flatpak-runtimes) return 0 ;;
    riscv64:appimage-runtime) return 0 ;;
    # Chrome for Testing ships linux64 and linux-arm64 builds only.
    riscv64:chrome) return 0 ;;
    # Google ships the Linux emulator for x86_64 hosts only, and it needs KVM.
    arm64:android-emulator|riscv64:android-emulator) return 0 ;;
    # None of the three publishes a riscv64 binary, and the riscv64 lanes cross-build on amd64.
    riscv64:cargo-qa-tools) return 0 ;;
    *) return 1 ;;
  esac
}

# Each exemption is re-checked by its own row's fact; another row's fact never goes stale.
_consumer_exempt_fact() {
  case "$1" in
    appimagetool) printf '%s' 'appimagetool-readable' ;;
    chrome|android-emulator|cargo-qa-tools) printf '%s' "$1" ;;
    *)            printf '%s' 'flutter-sdk' ;;
  esac
}

# Real create+delete per dir: access(2) says yes for root and lies about a read-only layer.
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
printf 'FACT android-payload-off %s\n' "$(if [ -f /opt/android/.android-payload-off ]; then echo yes; else echo no; fi)"
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
PROBE
  _consumer_ort_env_probe; _consumer_test_runtimes_probe; printf '%s\n' 'echo CCPROBE_DONE'
}

# CON50's browser and emulator, run as the image user: docs/consumer-image-contract.md#browser-tests-run-in-chrome-for-testing
_consumer_test_runtimes_probe() {
  cat <<'PROBE'
_qa=""
for _t in cargo-audit cargo-deny cargo-tarpaulin; do
  _qa="${_qa} ${_t}=$("${_t}" --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)"
done
case "${_qa}" in
  *=[0-9]*) printf 'FACT cargo-qa-tools yes\n' ;;
  *)        printf 'FACT cargo-qa-tools no\n' ;;
esac
printf 'FACT cargo-qa-tools-versions %s\n' "${_qa# }"
_ft="$(compgen -c | grep -E '^python3\.[0-9]+t$' | sort -u | head -1)"
if [ -n "${_ft}" ]; then
  printf 'FACT free-threaded-python %s\n' "$("${_ft}" -c 'import sys; print(sys.version.split()[0], "gil=" + str(sys._is_gil_enabled()))' 2>/dev/null)"
  printf 'FACT free-threaded-python-build %s\n' "$("${_ft}" -c 'import sysconfig, ssl, sqlite3, ctypes, zlib, lzma, bz2; print("prefix=" + str(sysconfig.get_config_var("prefix")), "Py_GIL_DISABLED=" + str(sysconfig.get_config_var("Py_GIL_DISABLED")))' 2>&1 | tail -1)"
else
  printf 'FACT free-threaded-python none\n'
fi
printf 'ENV chrome-executable %s\n' "${CHROME_EXECUTABLE:-}"
if [ -n "${CHROME_EXECUTABLE:-}" ] && [ -x "${CHROME_EXECUTABLE}" ]; then
  printf 'FACT chrome yes\n'
  printf 'FACT chrome-version %s\n' "$("${CHROME_EXECUTABLE}" --version 2>/dev/null | grep -oE '[0-9]+(\.[0-9]+){3}' | head -1)"
  printf 'FACT chromedriver-version %s\n' "$(chromedriver --version 2>/dev/null | grep -oE '[0-9]+(\.[0-9]+){3}' | head -1)"
  case "$(timeout 300 "${CHROME_EXECUTABLE}" --headless --dump-dom 'data:text/html,<script>document.write("kg-"+6*7)</script>' 2>/dev/null)" in
    *kg-42*) printf 'FACT chrome-headless yes\n' ;;
    *)       printf 'FACT chrome-headless no\n' ;;
  esac
else
  printf 'FACT chrome no\n'
fi
_emu="${ANDROID_HOME:-/nonexistent}/emulator"
if [ -x "${_emu}/emulator" ]; then
  printf 'FACT android-emulator yes\n'
  printf 'FACT android-emulator-version %s\n' "$(sed -n 's/^Pkg.Revision=//p' "${_emu}/source.properties" 2>/dev/null)"
  if "${_emu}/emulator" -version 2>/dev/null | grep -q 'Android emulator version'; then
    printf 'FACT android-emulator-runs yes\n'
  else
    printf 'FACT android-emulator-runs no\n'
  fi
  for _sp in "${ANDROID_HOME}"/system-images/*/*/x86_64/source.properties; do
    [ -f "${_sp}" ] || continue
    printf 'FACT android-system-image android-%s;%s;%s;r%s\n' "$(sed -n 's/^AndroidVersion.ApiLevel=//p' "${_sp}")" \
      "$(sed -n 's/^SystemImage.TagId=//p' "${_sp}")" "$(sed -n 's/^SystemImage.Abi=//p' "${_sp}")" "$(sed -n 's/^Pkg.Revision=//p' "${_sp}")"
  done
  if command -v android-avd.sh >/dev/null 2>&1; then
    printf 'FACT android-avd yes\n'
  else
    printf 'FACT android-avd no\n'
  fi
else
  printf 'FACT android-emulator no\n'
fi
printf 'FACT lint-tools shellcheck=%s hadolint=%s\n' "$(shellcheck --version 2>/dev/null | sed -n 's/^version: //p')" \
  "$(hadolint --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)"
printf 'ENV uv-cache-seed %s\n' "${PYTHON_UV_CACHE_SEED:-}"
printf 'FACT uv-cache-seed %s\n' "$(bash /opt/scripts/packaging/uv-cache-seed.sh verify "${PYTHON_UV_CACHE_SEED:-/nonexistent}" 2>&1 | tail -1)"
PROBE
}

# '<unset>' is not '': ort-sys reads a set-but-empty variable. docs/consumer-image-contract.md#the-ort-crate-links-the-chain-onnx-runtime
_consumer_ort_env_probe() {
  cat <<'PROBE'
printf 'ENV ort-lib-location %s\nENV ort-dylib-path %s\n' "${ORT_LIB_LOCATION:-}" "${ORT_DYLIB_PATH:-}"
printf 'ENV ort-prefer-dynamic %s\nENV ort-skip-download %s\n' "${ORT_PREFER_DYNAMIC_LINK:-}" "${ORT_SKIP_DOWNLOAD:-}"
printf 'ENV ort-lib-path %s\nENV cargo-net-offline %s\n' "${ORT_LIB_PATH-<unset>}" "${CARGO_NET_OFFLINE-<unset>}"
printf 'FACT ort-lib-real %s\n' "$(readlink -e -- "${ORT_LIB_LOCATION:-/nonexistent}" 2>/dev/null || true)"
printf 'FACT ort-dylib-real %s\n' "$(readlink -e -- "${ORT_DYLIB_PATH:-/nonexistent}" 2>/dev/null || true)"
printf 'FACT ort-link-lib %s\n' "$(if [ -e "${ORT_LIB_LOCATION:-/nonexistent}/libonnxruntime.so" ]; then echo yes; else echo no; fi)"
printf 'FACT ort-probe yes\n'
PROBE
}

# EMPTY on a miss, which every caller turns into NOFACT, never a pass.
_consumer_contract_fact() {
  printf '%s\n' "$1" | sed -n "s/^$2 $3 //p" | head -1
}

# Outside /workspace, the consumer's bind-mounted checkout, and writable by the image user.
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

# An exemption re-proves itself from the row's own fact; a missing fact is NOFACT, never a grant.
_consumer_exempt_verdict() {
  case "$3" in
    yes) printf 'STALE %s FACT %s says it IS present on %s -- delete the %s:%s arm from _consumer_contract_exempt' "$1" "$4" "$2" "$2" "$1" ;;
    no)  printf 'EXEMPT %s' "$1" ;;
    *)   printf 'NOFACT %s no FACT %s, so the exemption cannot be re-checked' "$1" "$4" ;;
  esac
}

# Executable-but-unreadable runs for root only; the probe answers as the shipped image user.
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
  local row="$1" val root dir onpath off
  # The NDK is linux-x86_64 only, so the build host decides; read android-sdk.sh's payload-off record.
  off="$(_consumer_contract_fact "$2" FACT android-payload-off)"
  if [ -z "${off}" ]; then
    printf 'NOFACT %s no FACT android-payload-off line' "${row}"
    return 0
  fi
  if [ "${off}" = yes ]; then
    printf 'SKIP %s the android payload is off for this build host (/opt/android/.android-payload-off)' "${row}"
    return 0
  fi
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

# A missing count is NOFACT, not zero: the defect is root writing into the tree after the COPY.
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

# EMPTY when ort-sys and load-dynamic both resolve the chain ORT. docs/consumer-image-contract.md#the-ort-crate-links-the-chain-onnx-runtime
_consumer_ort_env_problem() {
  local p="$1" lreal dreal v
  lreal="$(_consumer_contract_fact "${p}" FACT ort-lib-real)"
  dreal="$(_consumer_contract_fact "${p}" FACT ort-dylib-real)"
  case "${lreal}" in
    /usr/local/lib/onnxruntime-cpu/lib|/usr/local/lib/onnxruntime-gpu/lib) ;;
    *) printf 'ORT_LIB_LOCATION (%s) resolves to %s, not the chain ORT lib dir' \
         "$(_consumer_contract_fact "${p}" ENV ort-lib-location)" "${lreal:-nothing}"; return 0 ;;
  esac
  if [ "$(_consumer_contract_fact "${p}" FACT ort-link-lib)" != yes ]; then
    printf '%s has no libonnxruntime.so for ort-sys to link' "${lreal}"
    return 0
  fi
  case "${dreal}" in
    "${lreal}"/libonnxruntime.so*) ;;
    *) printf 'ORT_DYLIB_PATH (%s) resolves to %s, not a chain libonnxruntime.so' \
         "$(_consumer_contract_fact "${p}" ENV ort-dylib-path)" "${dreal:-nothing}"; return 0 ;;
  esac
  for v in ort-prefer-dynamic ort-skip-download; do
    case "$(_consumer_contract_fact "${p}" ENV "${v}" | tr '[:upper:]' '[:lower:]')" in
      1|true) ;;
      *) printf 'ENV %s is "%s", not 1' "${v}" "$(_consumer_contract_fact "${p}" ENV "${v}")"; return 0 ;;
    esac
  done
  v="$(_consumer_contract_fact "${p}" ENV ort-lib-path)"
  if [ "${v}" != '<unset>' ]; then
    printf 'ORT_LIB_PATH is set (%s), and ort-sys reads it before ORT_LIB_LOCATION, even empty' "${v}"
    return 0
  fi
  case "$(_consumer_contract_fact "${p}" ENV cargo-net-offline | tr '[:upper:]' '[:lower:]')" in
    '<unset>'|1|true) ;;
    *) printf 'CARGO_NET_OFFLINE is falsy (set, and not 1/true), and ort-sys reads it before ORT_SKIP_DOWNLOAD' ;;
  esac
}

_consumer_ort_env_verdict() {
  local row="$1" problem
  if [ "$(_consumer_contract_fact "$2" FACT ort-probe)" != yes ]; then
    printf 'NOFACT %s no FACT ort-probe line' "${row}"
    return 0
  fi
  problem="$(_consumer_ort_env_problem "$2")"
  if [ -n "${problem}" ]; then
    printf 'BAD %s %s' "${row}" "${problem}"
  else
    printf 'OK %s ORT_LIB_LOCATION -> %s, dynamic link, download disarmed' "${row}" \
      "$(_consumer_contract_fact "$2" FACT ort-lib-real)"
  fi
}

# CON65's three tools at their pins: docs/consumer-image-contract.md#the-cargo-qa-tools
_consumer_cargo_qa_verdict() {
  local row="$1" p="$2" pins="$3" have
  case "$(_consumer_contract_fact "${p}" FACT cargo-qa-tools)" in
    yes|no) ;;
    *) printf 'NOFACT %s no FACT cargo-qa-tools line' "${row}"; return 0 ;;
  esac
  have="$(_consumer_contract_fact "${p}" FACT cargo-qa-tools-versions)"
  if [ "${have}" = "${pins}" ]; then
    printf 'OK %s %s' "${row}" "${have}"
  else
    printf 'BAD %s the image has %s, the pins are %s' "${row}" "${have:-nothing}" "${pins}"
  fi
}

# CON66's interpreter: PYTHON_VERSION, the GIL really off, and the toolchain's source build. docs/consumer-image-contract.md#the-free-threaded-python
_consumer_free_threaded_verdict() {
  local row="$1" want="$3" have build
  have="$(_consumer_contract_fact "$2" FACT free-threaded-python)"
  build="$(_consumer_contract_fact "$2" FACT free-threaded-python-build)"
  if [ -z "${have}" ]; then
    printf 'NOFACT %s no FACT free-threaded-python line' "${row}"
  elif [ "${have}" != "${want} gil=False" ]; then
    printf 'BAD %s python3.*t reports %s, expected %s gil=False' "${row}" "${have}" "${want}"
  # A python-build-standalone tree reports its own prefix; a missing stdlib module leaves its ImportError here.
  elif [ "${build}" != "prefix=/opt/python-freethreaded Py_GIL_DISABLED=1" ]; then
    printf 'BAD %s python3.*t is not the source build in /opt/python-freethreaded with its stdlib: %s' "${row}" "${build:-no FACT free-threaded-python-build line}"
  else
    printf 'OK %s CPython %s without the GIL, built from source in /opt/python-freethreaded' "${row}" "${want}"
  fi
}

# A tool-pins.env pin, for the rows whose tools the torch stage installs from it (CON83).
_rt_tool_pin() {
  local _key="$1" _val="${!1:-}" _pins
  if [ -z "${_val}" ]; then
    _pins="$(cd "$(dirname "${BASH_SOURCE[0]}")/../01-core" 2>/dev/null && pwd)/tool-pins.env"
    [ -f "${_pins}" ] && _val="$(grep -E "^${_key}=" "${_pins}" | head -1 | cut -d= -f2 || true)"
  fi
  printf '%s' "${_val}"
}

# CON83's lint tools on PATH at their pins: docs/consumer-image-contract.md#shellcheck-and-hadolint
_consumer_lint_tools_verdict() {
  local row="$1" want="$3" have
  have="$(_consumer_contract_fact "$2" FACT lint-tools)"
  if [ -z "${have}" ]; then
    printf 'NOFACT %s no FACT lint-tools line' "${row}"
  elif [ "${have}" != "${want}" ]; then
    printf 'BAD %s the image has %s, the pins are %s' "${row}" "${have}" "${want}"
  else
    printf 'OK %s %s' "${row}" "${have}"
  fi
}

# CON83's seed, read through its own verify: docs/consumer-image-contract.md#the-riscv64-uv-cache-seed
_consumer_uv_seed_verdict() {
  local row="$1" arch="$3" env have
  env="$(_consumer_contract_fact "$2" ENV uv-cache-seed)"
  have="$(_consumer_contract_fact "$2" FACT uv-cache-seed)"
  if [ -z "${have}" ]; then
    printf 'NOFACT %s no FACT uv-cache-seed line' "${row}"
  elif [ "${env}" != /opt/uv-cache-seed ]; then
    printf 'BAD %s PYTHON_UV_CACHE_SEED is "%s", not /opt/uv-cache-seed' "${row}" "${env}"
  elif [ "${arch}" = riscv64 ]; then
    case "${have}" in
      "[uv-cache-seed] seeded for riscv64: "*", proved") printf 'OK %s %s' "${row}" "${have#*seeded for riscv64: }" ;;
      *) printf 'BAD %s the riscv64 seed does not verify: %s' "${row}" "${have}" ;;
    esac
  else
    case "${have}" in
      "[uv-cache-seed] not seeded: "*) printf 'OK %s not seeded on %s, by its record' "${row}" "${arch}" ;;
      *) printf 'BAD %s the %s record is not a "not seeded" one: %s' "${row}" "${arch}" "${have}" ;;
    esac
  fi
}

# <row> <probe> <pin>; a rendered page proves V8 and the renderer, not only that the binary exists.
_consumer_chrome_verdict() {
  local row="$1" p="$2" want="$3" have drv
  case "$(_consumer_contract_fact "${p}" FACT chrome)" in
    yes) ;;
    no) printf 'BAD %s CHROME_EXECUTABLE (%s) names no executable browser' "${row}" \
          "$(_consumer_contract_fact "${p}" ENV chrome-executable)"; return 0 ;;
    *)  printf 'NOFACT %s no FACT chrome line' "${row}"; return 0 ;;
  esac
  have="$(_consumer_contract_fact "${p}" FACT chrome-version)"
  drv="$(_consumer_contract_fact "${p}" FACT chromedriver-version)"
  if [ -z "${want}" ]; then
    printf 'BAD %s no CHROME_FOR_TESTING_VERSION pin to compare with' "${row}"
  elif [ "${have}" != "${want}" ]; then
    printf 'BAD %s chrome reports %s, the pin is %s' "${row}" "${have:-nothing}" "${want}"
  elif [ "${drv}" != "${want}" ]; then
    printf 'BAD %s chromedriver reports %s, the pin is %s' "${row}" "${drv:-nothing}" "${want}"
  elif [ "$(_consumer_contract_fact "${p}" FACT chrome-headless)" != yes ]; then
    printf 'BAD %s headless chrome rendered no page as the image user' "${row}"
  else
    printf 'OK %s Chrome for Testing %s renders headless' "${row}" "${want}"
  fi
}

# <row> <probe> <emulator pin> <system image pin>; booting needs KVM, so the image proves the parts only.
_consumer_emulator_verdict() {
  local row="$1" p="$2" want="$3" img="$4" have got
  case "$(_consumer_contract_fact "${p}" FACT android-payload-off)" in
    yes) printf 'SKIP %s the android payload is off for this build host' "${row}"; return 0 ;;
    no) ;;
    *)  printf 'NOFACT %s no FACT android-payload-off line' "${row}"; return 0 ;;
  esac
  case "$(_consumer_contract_fact "${p}" FACT android-emulator)" in
    yes) ;;
    no) printf 'BAD %s ANDROID_HOME/emulator/emulator is missing' "${row}"; return 0 ;;
    *)  printf 'NOFACT %s no FACT android-emulator line' "${row}"; return 0 ;;
  esac
  have="$(_consumer_contract_fact "${p}" FACT android-emulator-version)"
  got="$(_consumer_contract_fact "${p}" FACT android-system-image)"
  if [ "$(_consumer_contract_fact "${p}" FACT android-emulator-runs)" != yes ]; then
    printf 'BAD %s the emulator does not run as the image user' "${row}"
  elif [ "${have}" != "${want}" ]; then
    printf 'BAD %s emulator %s, the pin is %s' "${row}" "${have:-unknown}" "${want:-unset}"
  elif [ "${got}" != "${img}" ]; then
    printf 'BAD %s system image %s, the pin is %s' "${row}" "${got:-none}" "${img}"
  elif [ "$(_consumer_contract_fact "${p}" FACT android-avd)" != yes ]; then
    printf 'BAD %s android-avd.sh is not on PATH' "${row}"
  else
    printf 'OK %s emulator %s with %s' "${row}" "${want}" "${img}"
  fi
}

# Pure verdicts from probe text, so every failure path is testable. docs/consumer-image-contract.md#how-the-gate-proves-it
_consumer_contract_verdicts() {
  local arch="$1" probe="$2" row fact line asserted=0 _sc _hl
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
        ort-crate-env) line="$(_consumer_ort_env_verdict "${row}" "${probe}")" ;;
        chrome)        line="$(_consumer_chrome_verdict "${row}" "${probe}" "$(_rt_versions_env_pin CHROME_FOR_TESTING_VERSION)")" ;;
        android-emulator)
                       line="$(_consumer_emulator_verdict "${row}" "${probe}" "$(_rt_versions_env_pin ANDROID_EMULATOR_VERSION)" \
                                 "android-$(_rt_versions_env_pin ANDROID_EMULATOR_API);google_apis;x86_64;r$(_rt_versions_env_pin ANDROID_EMULATOR_SYSIMG_REVISION)")" ;;
        cargo-qa-tools)
                       line="$(_consumer_cargo_qa_verdict "${row}" "${probe}" \
                                 "cargo-audit=$(_rt_versions_env_pin CARGO_AUDIT_VERSION) cargo-deny=$(_rt_versions_env_pin CARGO_DENY_VERSION) cargo-tarpaulin=$(_rt_versions_env_pin CARGO_TARPAULIN_VERSION)")" ;;
        free-threaded-python)
                       line="$(_consumer_free_threaded_verdict "${row}" "${probe}" "$(_rt_versions_env_pin PYTHON_VERSION)")" ;;
        lint-tools)    _sc="$(_rt_tool_pin SHELLCHECK_VERSION)"; _hl="$(_rt_tool_pin HADOLINT_VERSION)"
                       line="$(_consumer_lint_tools_verdict "${row}" "${probe}" "shellcheck=${_sc#v} hadolint=${_hl#v}")" ;;
        uv-cache-seed) line="$(_consumer_uv_seed_verdict "${row}" "${probe}" "${arch}")" ;;
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

# Usable only if the probe completed as the image user (root sees every dir writable); EMPTY when usable.
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

# Probe as the image's own user: a root probe answers yes to every writability question.
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
      SKIP)     echo "  --   ${row} ${rest}" ;;
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

# Venv extensions are excluded: they add package lib dirs at import time, which bare ldd cannot see.
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

# The sdk stage checks sonames against the builder's ldconfig, so only a runtime check sees one missing here. docs/artifact-copy-completeness.md#the-llvm-target-prefix-fills-what-it-needs-and-nothing-else
check_llvm_target_startable() {
  local image_tag="$1"
  local target_arch="$2"
  local out

    echo "--- Functional: /usr/local/llvm-target/bin starts ---"
    out="$(_rt_run bash -lc 'set -uo pipefail
d=/usr/local/llvm-target/bin
[ -d "$d" ] || { echo "ABSENT"; exit 0; }
n=0; b=0
for f in "$d"/*; do
  [ -f "$f" ] && [ -x "$f" ] || continue
  n=$((n+1))
  nf="$(ldd "$f" 2>/dev/null | awk "/=> not found/{print \$1}" | sort -u | tr "\n" " ")"
  [ -n "$nf" ] && { printf "  BROKEN %s -> %s\n" "$f" "$nf"; b=$((b+1)); }
done
printf "COUNT %s %s\n" "$b" "$n"' 2>&1)" || true

    printf '%s\n' "${out}" | grep -e '^  BROKEN ' || true
    case "${out}" in
      *ABSENT*)
        echo "  WARN /usr/local/llvm-target/bin absent in the ${target_arch} image -- nothing to check"
        echo ""
        return 0 ;;
    esac
    local broken total
    broken="$(printf '%s\n' "${out}" | sed -n 's/^COUNT \([0-9]*\) [0-9]*$/\1/p' | tail -1)"
    total="$(printf '%s\n' "${out}" | sed -n 's/^COUNT [0-9]* \([0-9]*\)$/\1/p' | tail -1)"
    if [ -z "${total}" ]; then
      fail "the ${target_arch} llvm-target walk printed no COUNT -- the probe did not run, which is not the same as a clean prefix"
    elif [ "${broken:-1}" -gt 0 ]; then
      fail "${broken} of ${total} /usr/local/llvm-target/bin binaries have an unresolved NEEDED in the ${target_arch} image -- \
the sdk stage resolved them against the BUILDER's ldconfig cache (see BROKEN lines above)"
    else
      echo "  OK  0 of ${total} llvm-target binaries have an unresolved NEEDED (${target_arch})"
    fi
    echo ""
}

# Shipped trees must carry this image's arch. See docs/artifact-copy-completeness.md#the-shipped-trees-must-carry-the-images-own-arch

# Foreign by design: the x86_64 SDK tree, and /opt/android (check_android_abi judges it). docs/artifact-copy-completeness.md#what-the-exemptions-are-worth
_RT_TREE_ARCH_EXEMPT="/opt/android-sdk /opt/android"

# Known builder-arch defects as <arch>:<tree>:<machine>:<count>; ratchets down only, never a waiver.
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

# The manifest names the COPY source; mirror ALLOWED_RELOCATIONS in verify-artifact-copy-parity.sh.
_rt_tree_probe_path() {
  case "$1" in
    /opt/llvm-target) printf '%s' /usr/local/llvm-target ;;
    # Whatever arch the source path names, the tree lands in one place.
    /opt/python-cross-ft/*/opt/python-freethreaded) printf '%s' /opt/python-freethreaded ;;
    *)                printf '%s' "$1" ;;
  esac
}

# An unresolvable ${VAR} prints UNRESOLVED <var> so the gate fails instead of scanning nothing.
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
    # Relocated first: a relocation may drop a ${VAR:-...} the loop above cannot resolve.
    path="$(_rt_tree_probe_path "${path}")"
    case "${path}" in
      *'${'*) printf 'UNRESOLVED %s\n' "${path}" ;;
      *)      printf '%s\n' "${path}" ;;
    esac
  done < "${manifest}"
}

# One process, not a readelf per file (minutes under qemu); only candidates count toward CAP.
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

# One OK|BAD|NOELF|MISSING line per tree; NONE when the scanner saw nothing.
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

# No usable sudo (pure LPE surface, no grants exist); other setuid binaries are listed so a new one shows.
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

# Informational only: per-prefix sizes, so every shrink item has a number.
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

# uid 1001 cannot write __pycache__ into root-owned /opt/venv, so an uncompiled venv re-parses every start.
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

# Arch-parity table conformance, not a cross-arch diff. See docs/cross-build-verification.md#in-image-smoke-tests-need-a-built-image-not-part-of-preflight
_PARITY_PREFIXES="OrchestrANT android android-sdk cmake ffmpeg gcc gstreamer libcamera opencv5 python scripts venv vulkan"
# Wheel names in dist-info form ('-' and '.' normalised to '_').
_PARITY_WHEELS="torch torchvision ai_edge_litert iree_base_compiler iree_base_runtime onnxruntime_genai"

# A GPU GenAI ships under its flavour name (onnxruntime-genai-cuda/-trt-rtx), so every flavour counts.
_pkg_count() {
  local want="${1//_/-}" names="${2//_/-}"
  case "${want}" in
    onnxruntime-genai) grep -cE '^onnxruntime-genai(-[a-z0-9-]+)?$' <<<"${names}" || true ;;
    *)                 grep -cxF -- "${want}" <<<"${names}" || true ;;
  esac
}

# An arm fails once its component appears, so encode only reasons true today, never "not built yet".
_parity_exempt() {
  case "$1:$2" in
    # No Kitware riscv64 archive; 02-toolchain/cmake.sh installs the distro cmake there.
    riscv64:cmake) return 0 ;;
    # The IREE compiler cannot be cross-built and has no riscv64 wheel; arm64 ships it and keeps asserting.
    riscv64:iree_base_compiler) return 0 ;;
    *) return 1 ;;
  esac
}

# Exactly one onnxruntime flavour per arch; $2/$3 are the image's ENABLE_NVIDIA/ENABLE_AMD.
_parity_ort_flavor() {
  [ "${2:-false}" = "true" ] && { printf '%s' 'onnxruntime_gpu'; return 0; }
  [ "${3:-false}" = "true" ] && { printf '%s' 'onnxruntime_migraphx'; return 0; }
  case "$1" in
    amd64)         printf '%s' 'onnxruntime_dnnl' ;;
    arm64|riscv64) printf '%s' 'onnxruntime_webgpu' ;;
    *)             printf '%s' '' ;;
  esac
}

# A list, not case arms, so the health check can enumerate stale entries; empty since CON41 (arm64 gtk4 loads).
_PARITY_GST_KNOWN_BROKEN=""

# The gtk4 entry holds only where the resolved libvulkan lacks vkCreateWaylandSurfaceKHR.
_rt_gtk4_vulkan_wayland() {
  _rt_run bash -lc 'p=""
for d in $(printf "%s" "${GST_PLUGIN_PATH:-}" | tr ":" " "); do
  [ -f "${d}/libgstgtk4.so" ] && { p="${d}/libgstgtk4.so"; break; }
done
v="$([ -n "${p}" ] && ldd "${p}" 2>/dev/null | awk "/libvulkan\.so/{print \$3; exit}")"
if [ -z "${v}" ] || ! command -v nm >/dev/null 2>&1; then echo "WAYLAND unknown"; exit 0; fi
syms="$(nm -D --defined-only "${v}" 2>/dev/null)"
case "${syms}" in *" vkCreateWaylandSurfaceKHR"*) echo "WAYLAND yes" ;; *) echo "WAYLAND no" ;; esac' 2>/dev/null | sed -n 's/^WAYLAND //p' | head -1
}

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
printf "NVIDIA %s\n" "${ENABLE_NVIDIA:-false}"
printf "AMD %s\n" "${ENABLE_AMD:-false}"
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
        *)             present="$(_pkg_count "${want}" "${wheels}")" ;;
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

    # Info only: untracked prefixes are the table's blind spot, and gating would need all three images.
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
    ort_want="$(_parity_ort_flavor "${target_arch}" "$(printf '%s\n' "${probe}" | sed -n 's/^NVIDIA //p')" \
      "$(printf '%s\n' "${probe}" | sed -n 's/^AMD //p')")"
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

# Shipped-truth gates. See docs/cross-build-verification.md § Shipped-truth gates
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
printf 'ADV PYTORCH_VERSION %s\n'            "${PYTORCH_VERSION:-}"
printf 'ADV TORCHVISION_VERSION %s\n'        "${TORCHVISION_VERSION:-}"
printf 'ADV PYAV_VERSION %s\n'               "${PYAV_VERSION:-}"
printf 'ADV IREE_VERSION %s\n'               "${IREE_VERSION:-}"
printf 'ADV LITERT_VERSION %s\n'             "${LITERT_VERSION:-}"
printf 'ADV PYTORCH_EXTRA %s\n'       "${PYTORCH_EXTRA:-}"
PROBE
}

_probe_actual_versions() {
  # HAVE values come from the shipped thing itself, never from an ENV.
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
printf 'HAVE PYTORCH_VERSION %s\n'    "$("$py" -c 'import torch;print(torch.__version__)' 2>/dev/null)"
printf 'HAVE TORCHVISION_VERSION %s\n' "$("$py" -c 'import torchvision;print(torchvision.__version__)' 2>/dev/null)"
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


# One in-image script: what the image advertises, what it is, and what it holds.
_shipped_truth_probe() {
  _probe_advertised
  _probe_actual_versions
  _probe_venv_inventory
  _probe_elf_and_sonames
}

# No exemption or SKIP arm; a deliberately unadvertised key goes in verify_advertised_keys.py's EXCUSED.
_ADVERTISED_VERSION_KEYS="PYTHON_MAJOR_MINOR GCC_VERSION LLVM_RELEASE
GSTREAMER_VERSION VULKAN_VERSION UBUNTU_VERSION CMAKE_VERSION NODE_VERSION UV_VERSION
OPENCV_VERSION ONNXRUNTIME_VERSION ONNXRUNTIME_GENAI_VERSION PYAV_VERSION IREE_VERSION
LITERT_VERSION RUST_VERSION WASM_PACK_VERSION FLUTTER_RUST_BRIDGE_VERSION
PYTORCH_VERSION TORCHVISION_VERSION"

# Mirrors assemble-torch-app.sh's uv sync; the pytorch-* extra comes from the image's PYTORCH_EXTRA.
_VENV_CONTRACT_EXTRAS="ml-ai docs"

# Key <arch>:<extra>:<pkg> (DEP = dangling transitive edge); an arm that stops applying fails.
_venv_pkg_exempt() {
  case "$1:$2:$3" in
    # cv2 is the source-built /opt/opencv5 binding, never the PyPI wheel.
    *:ml-ai:opencv-python) return 0 ;;
    # onnxruntime ships under its flavour name, which _parity_ort_flavor asserts.
    *:ml-ai:onnxruntime|*:DEP:onnxruntime) return 0 ;;
    # No riscv64 wheels on PyPI; building BLAS/LAPACK and Fortran from source costs hours per run.
    riscv64:ml-ai:scipy|riscv64:ml-ai:scikit-learn|riscv64:ml-ai:pandas) return 0 ;;
    *) return 1 ;;
  esac
}

# One OK|BAD|UNSET|UNREAD line per key; UNSET and UNREAD are both fatal.
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

# Emits MISS|STALE|EXEMPT|NOREQ <extra> <pkg> [owner] lines plus ASSERTED <n>.
_venv_set_verdicts() {
  local arch="$1" probe="$2"
  local pkgs extras extra reqs r asserted=0 owner name
  pkgs="$(printf '%s\n' "${probe}" | sed -n 's/^PKG //p' | LC_ALL=C sort -u)"
  extras="${_VENV_CONTRACT_EXTRAS}"
  # The image's own PYTORCH_EXTRA picks the torch extra, so a cpu wrapper is never asked for rocm wheels.
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
      if [ "$(_pkg_count "${r}" "${pkgs}")" -gt 0 ]; then
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

# riscv64 ISA gate: one OK|BAD|SKIP <lib> <attr> line per shipped object.
_rvv_verdicts() {
  local probe="$1" lib attr n=0 cc vcc=0
  cc="$(printf '%s\n' "${probe}" | sed -n 's/^RVCC //p' | head -1)"
  # Demand vector only once the image's own toolchain defaults to it; before that plain objects are expected.
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
    # Ours lives under /opt and /usr/local; the failure is a distro copy from a system dir winning.
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

# Probes in-image so ld.so and LD_LIBRARY_PATH are the image's own; check-ort-provenance.sh decides.
check_ort_census() {
  local image_tag="$1" target_arch="$2" probe armed verb path detail bad=0
  local -a args=()
  echo "--- SHIPPED-TRUTH E: one ONNX Runtime, the chain's (${target_arch}) ---"
  mapfile -t args < <(ort_census_image_args)
  probe="$(_rt_run -e "ORT_CENSUS_PY=$(cat "${_SCRIPT_DIR}/ort_census_probe.py")" bash -lc \
    'p=/opt/venv/bin/python; [ -x "$p" ] || p="$(command -v python3)"; f="$(mktemp)"; printf "%s\n" "$ORT_CENSUS_PY" > "$f"; exec "$p" "$f" "$@"' \
    ort-census "${args[@]}" 2>/dev/null)" || true
  armed="$(ort_census_stamps_armed)"
  [ "${armed}" = 1 ] || echo "  ~~   STAMP arm unarmed: no ort_assert_chain_only (G2) in this hub, so no consumer writes a stamp yet"
  while IFS=$'\t' read -r verb path detail; do
    case "${verb}" in
      "") ;;
      EXEMPT) echo "  ~~   ORT census: ${path} -- ${detail}" ;;
      *) bad=$((bad + 1)); fail "ORT census: ${verb} ${path} -- ${detail}" ;;
    esac
  done < <(ort_census_verdicts "${probe}" "${armed}" "${target_arch}" ${_ORT_CENSUS_IMAGE_EXEMPT[@]+"${_ORT_CENSUS_IMAGE_EXEMPT[@]}"})
  [ "${bad}" -ne 0 ] || pass "ORT census: every ONNX Runtime binary in the ${target_arch} image is the chain build"
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

# Plugin failures only warn (the element is just unavailable); returns 0 when documented.
_gst_classify_failure() {
  local target_arch="$1" p="$2" gtk4_wl="$3"
  if [ "${p}" = libgstgtk4.so ] && [ "${gtk4_wl}" = yes ]; then
    echo "  WARN ${p} cannot load although its libvulkan exports vkCreateWaylandSurfaceKHR -- the documented cause is gone, so this is new drift (non-fatal)"
    return 1
  fi
  if _parity_gst_plugin_known "${target_arch}" "${p}"; then
    echo "  ~~   ${p} cannot load -- documented ${target_arch} exception (_parity_gst_plugin_known)"
    return 0
  fi
  echo "  WARN ${p} cannot load on ${target_arch} and is NOT in the parity table -- new drift; fix it or record it (non-fatal)"
  return 1
}

# <arch> <failed basenames, newline-separated> <gtk4 wayland verdict>
_gst_check_stale_exceptions() {
  local target_arch="$1" failed="$2" _gtk4_wl="$3"
  # Stale only if the scanner did not fail it AND gst-inspect loads the file; absence proves nothing.
  local _kb_entry _kb_plugin
  for _kb_entry in ${_PARITY_GST_KNOWN_BROKEN}; do
    [ "${_kb_entry%%:*}" = "${target_arch}" ] || continue
    _kb_plugin="${_kb_entry#*:}"
    # `failed` is newline-separated: a space-delimited case pattern matches only a single entry.
    if printf '%s\n' "${failed}" | grep -qxF -- "${_kb_plugin}"; then
      continue   # still failing = entry still true
    fi
    if [ "${_kb_plugin}" = libgstgtk4.so ] && [ "${_gtk4_wl}" = yes ]; then
      echo "  OK   ${_kb_plugin} loads: this image's libvulkan exports vkCreateWaylandSurfaceKHR, so the ${target_arch} exception does not apply here (it still covers loaders without it)"
      continue
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
}

check_gstreamer_plugin_health() {
  local image_tag="$1"
  local target_arch="$2"
    echo "--- Functional: GStreamer plugin health (scanner lines informational, blacklist fatal) ---"
    # The scanner dlopen()s plugins, catching undefined symbols ldd misses; the headline stays the raw count.
    local scan failed p known=0 unknown=0 total named unnamed
    scan="$(_rt_run bash -lc 'command -v gst-inspect-1.0 >/dev/null 2>&1 || { echo "GST_SCAN_ABSENT"; exit 0; }
gst-inspect-1.0 2>&1 >/dev/null || true
echo "GST_SCAN_DONE"' 2>/dev/null)" || true
    # A healthy image also prints nothing, so the probe stamps completion to avoid a false green.
    if ! printf '%s\n' "${scan}" | grep -q '^GST_SCAN_DONE$'; then
      if printf '%s\n' "${scan}" | grep -q '^GST_SCAN_ABSENT$'; then
        echo "  WARN gst-inspect-1.0 is not on PATH in the ${target_arch} image -- plugin health UNKNOWN, not 0"
      else
        echo "  WARN the GStreamer plugin scan did not complete in the ${target_arch} image -- plugin health UNKNOWN, not 0"
      fi
      _gst_check_blacklist "${target_arch}"
      echo ""
      return 0
    fi
    total="$(printf '%s\n' "${scan}" | grep -c "Failed to load plugin" || true)"
    failed="$(printf '%s\n' "${scan}" | grep "Failed to load plugin" \
                | grep -oE 'libgst[A-Za-z0-9_+-]+\.so' | sort -u || true)"
    named="$(printf '%s\n' "${scan}" | grep "Failed to load plugin" \
               | grep -cE 'libgst[A-Za-z0-9_+-]+\.so' || true)"
    unnamed=$((total - named))
    local _gtk4_wl=""
    _parity_gst_plugin_known "${target_arch}" libgstgtk4.so && _gtk4_wl="$(_rt_gtk4_vulkan_wayland)"
    for p in ${failed}; do
      if _gst_classify_failure "${target_arch}" "${p}" "${_gtk4_wl}"; then
        known=$((known + 1))
      else
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

    _gst_check_stale_exceptions "${target_arch}" "${failed}" "${_gtk4_wl}"
    _gst_check_blacklist "${target_arch}"
    echo ""
}

# DeepStream's UCX plugin needs libucs, which deepstream-verify.sh documents as missing (Ubuntu's libucx0 pulls ROCm's HIP runtime).
_GST_BLACKLIST_DOCUMENTED="amd64:libnvdsgst_ucx.so"
_GST_BLACKLIST_DOCUMENTED_WHY="documented: libucs.so.0 is not shipped (deepstream-verify.sh DSV_ALLOWED_MISSING)"
_gst_blacklist_documented() {
  case " ${_GST_BLACKLIST_DOCUMENTED} " in *" $1:$2 "*) return 0 ;; *) return 1 ;; esac
}

# The registry blacklists a plugin whose dlopen or plugin_init failed, with no scanner line; docs/failure-modes.md#the-core-registry-blacklists-libgstvalidatessimso
_gst_check_blacklist() {
  local target_arch="$1" out p undocumented=""
  out="$(_rt_run bash -lc 'gi="$(command -v gst-inspect-1.0 || echo /opt/gstreamer/bin/gst-inspect-1.0)"
stubs="${CUDA_HOME:-/usr/local/cuda}/lib64/stubs"
if [ -f "${stubs}/libcuda.so" ] && ! ldconfig -p 2>/dev/null | grep -q "libcuda\.so\.1 "; then
  d="$(mktemp -d)"; ln -s "${stubs}/libcuda.so" "${d}/libcuda.so.1"; ln -s "${stubs}/libnvidia-ml.so" "${d}/libnvidia-ml.so.1"
  export LD_LIBRARY_PATH="${d}${LD_LIBRARY_PATH:+:${LD_LIBRARY_PATH}}" GST_REGISTRY="${d}/registry.bin"
  echo "DRIVER_STUBS ${stubs}"
fi
"$gi" -b 2>/dev/null | sed -n "s/^  *\([^ ]*\.so\)\$/BLACKLISTED \1/p"
echo "GST_BLACKLIST_DONE"' 2>/dev/null)" || true
  if ! printf '%s\n' "${out}" | grep -q '^GST_BLACKLIST_DONE$'; then
    fail "the GStreamer registry blacklist could not be read in the ${target_arch} image"
    return 0
  fi
  # A GPU-less smoke has no driver libcuda; the CUDA stubs stand in, as deepstream-verify.sh's element check does.
  if printf '%s\n' "${out}" | grep -q '^DRIVER_STUBS '; then
    echo "  ~~   scanned with the CUDA driver stubs ($(printf '%s\n' "${out}" | sed -n 's/^DRIVER_STUBS //p' | head -1)): no GPU in this container"
  fi
  while IFS= read -r p; do
    [ -n "${p}" ] || continue
    p="${p##*/}"
    if _gst_blacklist_documented "${target_arch}" "${p}"; then
      echo "  ~~   ${p} is blacklisted -- ${_GST_BLACKLIST_DOCUMENTED_WHY}"
    elif _parity_gst_plugin_known "${target_arch}" "${p}"; then
      echo "  ~~   ${p} is blacklisted -- documented ${target_arch} exception (_parity_gst_plugin_known)"
    else
      undocumented="${undocumented} ${p}"
    fi
  done <<< "$(printf '%s\n' "${out}" | sed -n 's/^BLACKLISTED //p' | sort -u)"
  if [ -n "${undocumented}" ]; then
    fail "the GStreamer registry blacklists${undocumented} on ${target_arch}: dlopen or plugin_init failed (gst-inspect-1.0 <file> names the cause)"
  else
    pass "the GStreamer registry blacklists no plugin on ${target_arch}"
  fi
}

# gst-devtools is native-only (cross builds disable it), so amd64 must ship it and its SSIM override must work.
check_gst_validate_ssim() {
  local image_tag="$1"
  local target_arch="$2"
    echo "--- Functional: gst-validate SSIM plugin ---"
    local out frames
    out="$(_rt_run bash -lc 'command -v gst-validate-1.0 >/dev/null 2>&1 || { echo "NO_VALIDATE"; exit 0; }
d="$(mktemp -d)"
GST_VALIDATE_CONFIG="validatessim, element-classification=Video/Sink, output-dir=${d}" \
  timeout 120 gst-validate-1.0 videotestsrc num-buffers=3 ! video/x-raw,format=I420,width=64,height=48 ! fakevideosink >/dev/null 2>&1
echo "SSIM_FRAMES $(find "${d}" -name "*.png" | wc -l)"' 2>/dev/null)" || true
    frames="$(printf '%s\n' "${out}" | sed -n 's/^SSIM_FRAMES //p' | head -1)"
    if printf '%s\n' "${out}" | grep -q '^NO_VALIDATE$'; then
      if [ "${target_arch}" = amd64 ]; then
        fail "gst-validate-1.0 is missing from the amd64 image (gst-devtools is built natively there)"
      else
        echo "  INFO no gst-devtools on ${target_arch}: cross builds disable it"
      fi
    elif [ "${frames:-0}" -ge 1 ] 2>/dev/null; then
      pass "gst-validate's SSIM override writes frames (${frames}) on ${target_arch}"
    else
      fail "gst-validate's SSIM override wrote no frame on ${target_arch}: ${out:-no output}"
    fi
    echo ""
}

# libunwind.so.8 ahead of libgcc_s turns an exception through std::call_once into a segfault: docs/failure-modes.md#an-exception-through-stdcall_once-segfaults-in-libunwind
check_no_libunwind_closure() {
  local image_tag="$1"
  local target_arch="$2"
    echo "--- SHIPPED: nothing under /opt or /usr/local needs libunwind.so.8 ---"
    local out hits scanned
    out="$(_rt_run bash -lc 'command -v readelf >/dev/null 2>&1 || { echo "NO_READELF"; exit 0; }
find /opt /usr/local -xdev \( -path /opt/android -o -path /opt/android-sdk -o -path /opt/flutter \) -prune \
  -o -type f -name "*.so*" -print 2>/dev/null > /tmp/elfs
echo "SCANNED $(wc -l < /tmp/elfs)"
xargs -a /tmp/elfs -d "\n" -P "$(nproc)" -n 64 sh -c "for f; do readelf -d \"\$f\" 2>/dev/null | grep -q \"Shared library: .libunwind\\.so\\.8.\" && echo \"NEEDS \$f\"; done; exit 0" _
echo "UNWIND_SCAN_DONE"' 2>/dev/null)" || true
    if ! printf '%s\n' "${out}" | grep -q '^UNWIND_SCAN_DONE$'; then
      fail "the libunwind scan did not complete in the ${target_arch} image: $(printf '%s\n' "${out}" | tail -1)"
      echo ""
      return 0
    fi
    scanned="$(printf '%s\n' "${out}" | sed -n 's/^SCANNED //p' | head -1)"
    hits="$(printf '%s\n' "${out}" | sed -n 's/^NEEDS //p' | sort)"
    if [ -n "${hits}" ]; then
      printf '%s\n' "${hits}" | sed 's/^/    /'
      fail "$(printf '%s\n' "${hits}" | wc -l) shipped file(s) need libunwind.so.8 on ${target_arch}: build them without it (-Dlibunwind=disabled)"
    elif ! [ "${scanned:-0}" -ge 1 ] 2>/dev/null; then
      fail "the libunwind scan found no shared object under /opt or /usr/local on ${target_arch}"
    else
      pass "none of ${scanned} shared objects under /opt and /usr/local needs libunwind.so.8 (${target_arch})"
    fi
    echo ""
}

# Mesa 26.0's lavapipe BVH sort needs 8-lane subgroups: docs/failure-modes.md#lavapipe-segfaults-building-an-acceleration-structure-on-arm64
check_lavapipe_subgroup() {
  local image_tag="$1"
  local target_arch="$2"
    echo "--- Functional: lavapipe subgroup size ---"
    local out width sub
    out="$(_rt_run bash -lc 'printf "WIDTH %s\n" "${LP_NATIVE_VECTOR_WIDTH:-unset}"
icd=/usr/share/vulkan/icd.d/lvp_icd.json
[ -f "${icd}" ] || { echo "NO_LVP"; exit 0; }
VK_DRIVER_FILES="${icd}" VK_ICD_FILENAMES="${icd}" timeout 120 vulkaninfo 2>/dev/null \
  | sed -n "s/^[[:space:]]*subgroupSize[[:space:]]*= *\([0-9][0-9]*\).*/SUBGROUP \1/p" | head -1' 2>/dev/null)" || true
    width="$(printf '%s\n' "${out}" | sed -n 's/^WIDTH //p' | head -1)"
    sub="$(printf '%s\n' "${out}" | sed -n 's/^SUBGROUP //p' | head -1)"
    if [ "${width}" != 256 ]; then
      fail "LP_NATIVE_VECTOR_WIDTH is '${width:-unreadable}' in the ${target_arch} image, not 256"
    elif printf '%s\n' "${out}" | grep -q '^NO_LVP$'; then
      fail "lavapipe's ICD (lvp_icd.json) is missing from the ${target_arch} image"
    elif [ "${sub}" != 8 ]; then
      fail "lavapipe reports subgroupSize '${sub:-none}' on ${target_arch}, not 8: its BVH build would SEGV"
    else
      pass "lavapipe runs 8-lane subgroups on ${target_arch} (LP_NATIVE_VECTOR_WIDTH=256)"
    fi
    echo ""
}

# onnxruntime inference and the cv2 round-trip live in check_app_wheel_smoke.

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

# gst-inspect-1.0 <plugin> fails on a missing or undlopenable plugin; mirrors the Windows lane's contract.
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
    # Import via the venv python so a missing runtime dependency of the app fails here.
    if _rt_run \
         /opt/venv/bin/python -c "import orchestrant" >/dev/null 2>&1; then
      pass "application module imports (${target_arch})"
    else
      fail "application module (orchestrant) failed to import in the venv (${target_arch})"
    fi
    echo ""
}

# Execute the HEALTHCHECK, not just parse it: a broken interpreter path passes a string check.
check_healthcheck_exec() {
  local image_tag="$1"
  local target_arch="$2"
    echo "--- Functional: HEALTHCHECK command executes ---"
    # The image's own command: a hardcoded copy would pass while the shipped HEALTHCHECK is broken.
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

# Warn only: same gst-plugins-rs webrtc lane as the known webrtcbin2 gap, but keep it visible.
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

# The loader path /proc/self/maps names. docs/artifact-copy-completeness.md#the-vulkan-tree-ships-only-what-the-image-runs
_vk_loaded_path() {
  printf '%s' "${1}" | sed -n 's/^VKLIB //p' | head -1
}

# Surface extensions every arch's loader must list, as LunarG's amd64 one does (docs/vulkan-foreign-arch-sdk.md#the-loader-carries-the-window-systems).
_VK_WSI_REQUIRED="VK_KHR_surface VK_KHR_xcb_surface VK_KHR_xlib_surface VK_KHR_wayland_surface"

# <probe output> <arch>: the VKEXT line against _VK_WSI_REQUIRED; a loader lists extensions even with zero ICDs, so none is a failure.
_vk_wsi_verdict() {
  local exts e missing=""
  exts="$(printf '%s\n' "$1" | sed -n 's/^VKEXT //p' | head -1)"
  if [ -z "${exts}" ]; then
    fail "the ${2} Vulkan loader listed no instance extensions, so its window-system support is unproven"
    return 0
  fi
  for e in ${_VK_WSI_REQUIRED}; do
    case " ${exts} " in *" ${e} "*) ;; *) missing="${missing} ${e}" ;; esac
  done
  if [ -n "${missing}" ]; then
    fail "the ${2} Vulkan loader lacks${missing} -- every windowed Vulkan app aborts (docs/vulkan-foreign-arch-sdk.md#the-loader-carries-the-window-systems)"
  else
    echo "  OK  the ${2} loader lists ${_VK_WSI_REQUIRED}"
  fi
}

# Asserts which libvulkan loaded: Ubuntu's multiarch fallback would pass with /opt/vulkan unused.
check_vulkan_loader() {
  local image_tag="$1"
  local target_arch="$2"
    echo "--- Functional: Vulkan loader ---"
    # vkEnumerateInstanceVersion needs no ICD or GPU; the AttributeError guard covers a 1.0 loader.
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
    print("VKOK (pre-1.1 loader)")
class E(ctypes.Structure):
    _fields_ = [("name", ctypes.c_char * 256), ("rev", ctypes.c_uint32)]
n = ctypes.c_uint32()
if l.vkEnumerateInstanceExtensionProperties(None, ctypes.byref(n), None) == 0:
    a = (E * n.value)()
    if l.vkEnumerateInstanceExtensionProperties(None, ctypes.byref(n), a) == 0:
        print("VKEXT " + " ".join(e.name.decode() for e in a[:n.value]))' 2>&1)" || true
    _vk_lib="$(_vk_loaded_path "${_vk_out}")"
    if printf '%s' "${_vk_out}" | grep -q "VKOK"; then
      case "${_vk_lib}" in
        /opt/vulkan/*) echo "  OK  libvulkan.so.1 loads from ${_vk_lib} (${target_arch})" ;;
        '')            echo "  WARN libvulkan.so.1 loads but /proc/self/maps named no path -- non-fatal" ;;
        *)             fail "libvulkan.so.1 loaded from ${_vk_lib} in the ${target_arch} image, not from /opt/vulkan -- the shipped SDK prefix is not what the loader resolves to (pruned too far, or LD_LIBRARY_PATH lost it)" ;;
      esac
      _vk_wsi_verdict "${_vk_out}" "${target_arch}"
    elif printf '%s' "${_vk_out}" | grep -qiE "OSError|No such file|cannot open shared object|not found"; then
      fail "libvulkan.so.1 missing/unloadable in ${target_arch} image (runtime always ships it): $(printf '%s' "${_vk_out}" | tail -1)"
    else
      echo "  WARN vulkan load check inconclusive (container-infra error?) -- non-fatal: $(printf '%s' "${_vk_out}" | tail -1)"
    fi
    echo ""
}

# REQUIRED fails when absent, REPORTED only warns until a lane ships it. docs/vulkan-foreign-arch-sdk.md#the-toolset-floor-only-ratchets-up
_VK_REQUIRED_TOOLS="glslang glslangValidator glslc spirv-as spirv-cfg spirv-cross spirv-diff spirv-dis spirv-lesspipe.sh spirv-link spirv-lint spirv-objdump spirv-opt spirv-reduce spirv-reflect spirv-reflect-pp spirv-val vkcube vkcubepp vulkaninfo"
_VK_REPORTED_TOOLS="gfxrecon-info gfxrecon-replay slangc vulkanCapsViewer"

# <arch>:<tools>:<layer manifests> floors; below fails, above prints the new floor to record.
_VK_TOOLSET_FROZEN="amd64:>=52:>=1 arm64:>=20:>=4 riscv64:>=20:>=4"

# Prints "<tools> <layers>" for this arch, empty when the arch has no row.
_vk_toolset_floor() {
  local entry
  for entry in ${_VK_TOOLSET_FROZEN}; do
    case "${entry}" in
      "$1:"*) printf '%s %s' "$(echo "${entry}" | cut -d: -f2 | tr -d '>=')" \
                             "$(echo "${entry}" | cut -d: -f3 | tr -d '>=')"; return 0 ;;
    esac
  done
  return 1
}

check_vulkan_toolset() {
  local image_tag="$1"
  local target_arch="$2"
  local out missing found layer tools layers floor floor_tools floor_layers

    echo "--- Functional: Vulkan SDK toolset ---"
    out="$(_rt_run /bin/sh -c '
      for t in '"${_VK_REQUIRED_TOOLS} ${_VK_REPORTED_TOOLS}"'; do
        [ -x "${VULKAN_SDK}/bin/${t}" ] && echo "TOOL ${t}"
      done
      echo "TOOLS $(ls "${VULKAN_SDK}"/bin 2>/dev/null | wc -l)"
      echo "LAYERS $(ls "${VULKAN_SDK}"/share/vulkan/explicit_layer.d/*.json 2>/dev/null | wc -l)"
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

    tools="$(printf '%s\n' "${out}" | sed -n 's/^TOOLS \([0-9]*\)$/\1/p' | tail -1)"
    layers="$(printf '%s\n' "${out}" | sed -n 's/^LAYERS \([0-9]*\)$/\1/p' | tail -1)"
    layer="$(printf '%s' "${out}" | grep -c '^LAYER yes' || true)"
    # read < <(fn) fails on a last line without newline, which looks like "no row".
    if floor="$(_vk_toolset_floor "${target_arch}")"; then
      read -r floor_tools floor_layers <<< "${floor}"
      _vk_floor_verdict "${target_arch}" tools "${tools:-0}" "${floor_tools}"
      _vk_floor_verdict "${target_arch}" "layer manifests" "${layers:-0}" "${floor_layers}"
    else
      fail "no _VK_TOOLSET_FROZEN row for ${target_arch} -- a new arch has to record its floor, not inherit silence"
    fi
    [ "${layer}" -gt 0 ] \
      && echo "  OK  validation layer manifest present (${target_arch})" \
      || fail "no validation layer manifest in the ${target_arch} SDK prefix -- \
the layers are what the whole foreign-arch SDK exercise was for (docs/vulkan-foreign-arch-sdk.md)"
    echo ""
}

# One frozen floor, judged: below fails, above says what to record.
_vk_floor_verdict() {
  local target_arch="$1" what="$2" have="$3" floor="$4"

  if [ "${have}" -lt "${floor}" ]; then
    fail "the ${target_arch} Vulkan SDK prefix carries ${have} ${what}, below its frozen floor of ${floor} -- \
the target SDK only ratchets up (docs/vulkan-foreign-arch-sdk.md#the-toolset-floor-only-ratchets-up)"
  elif [ "${have}" -gt "${floor}" ]; then
    echo "  OK  ${have} ${what} (${target_arch}) -- RATCHET: floor ${floor} -> ${have}, record it in _VK_TOOLSET_FROZEN"
  else
    echo "  OK  ${have} ${what} (${target_arch}), at the frozen floor"
  fi
}

# /opt/android is tree-arch exempt, so only this catches a wrong-ABI payload. docs/linux-cross-builds.md#the-android-abi-is-a-target-not-the-build-host
_ANDROID_ABI_MACHINE="arm64-v8a:183 x86_64:62 x86:3 riscv64:243"

_android_abi_want() {
  local row
  for row in ${_ANDROID_ABI_MACHINE}; do
    [ "${row%%:*}" = "$1" ] && { printf '%s' "${row#*:}"; return 0; }
  done
  return 1
}

# Scans .a members too: `file` on an archive does not report its members' machine.
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

# Runs the compiled programs on-target, which the x86_64 build host never can; RUNTIME_COMPILER_SMOKE=0 skips.
check_native_compiler_battery() {
  local image_tag="$1"
  local target_arch="$2"
    if [ "${RUNTIME_COMPILER_SMOKE}" = "1" ]; then
      echo "--- Functional: native compiler battery compile+link+run (${target_arch}) ---"
      # Exceptions+STL guards swap-native-gcc.sh's -idirafter fix; sources avoid single quotes for bash -lc.
      local _san_run=0
      if [ "${target_arch}" = "$(smoke_host_arch)" ]; then _san_run=1; fi
      if _rt_run -e "SAN_RUN=${_san_run}" \
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
  # C++: the header abseil includes, libasan+libubsan NEEDED ((8>>c) is a UBSan call under C++20 too); RUN only natively
  printf "#include <sanitizer/common_interface_defs.h>\nalignas(8) static char b[8];\nint main(int c,char**){__sanitizer_annotate_contiguous_container(b,b+8,b+8,b+8);return (8>>c)==4?0:1;}\n" > "$d/s.cpp"
  { "$cxx" -O1 -fsanitize=address,undefined "$d/s.cpp" -o "$d/s" 2>"$d/e" && readelf -d "$d/s" > "$d/dyn" && grep -q "NEEDED.*libasan" "$d/dyn" && grep -q "NEEDED.*libubsan" "$d/dyn"; }; report "C++ -fsanitize=address,undefined compile+link" $?
  if [ "$SAN_RUN" = 1 ]; then { ASAN_OPTIONS=detect_leaks=0 "$d/s" 2>"$d/e"; }; report "C++ sanitizer RUN (native)" $?
  else echo "  --  sanitizer RUN skipped: emulated arch (qemu-user cannot host ASan/LSan reliably)"; fi
fi
echo "  gcc $("$cc" -dumpversion) [$("$cc" -dumpmachine)]"
exit $rc'; then
        pass "native compiler battery (C hello/pthreads/libm/atomic + C++ hello/exceptions/thread/LTO/sanitizers) all pass on ${target_arch}"
      else
        fail "native compiler battery had FAILURES in the runtime image (${target_arch}) -- see XX lines above"
      fi
      echo ""
    fi
}

# Clang/LLVM version on the shipped image, per arch: the toolchain-stage checks cannot see a stale reused sdk (RUNTIME_CLANG_VERSION_SMOKE=0 disables).
check_clang_llvm_release() {
  local image_tag="$1"
  local target_arch="$2"
    if [ "${RUNTIME_CLANG_VERSION_SMOKE}" = "1" ]; then
      echo "--- Functional: clang/clang++ version == LLVM_RELEASE (${target_arch}) ---"
      local _llvm_release="${LLVM_RELEASE:-}"
      if [ -z "${_llvm_release}" ]; then
        local _venv
        _venv="$(cd "$(dirname "${BASH_SOURCE[0]}")/../01-core" 2>/dev/null && pwd)/versions.env"
        # `|| true`: under pipefail an absent key would abort the smoke without a summary; the fail below reports it.
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
  # Run the tool for its version, never strings(1): a dylib-linked clang keeps its version in libLLVM.so.
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

# DeepStream only on the nvidia variant, then its own gates in the image: docs/linux-accelerator-images.md#deepstream-nvidia-variant
check_deepstream() {
  local image_tag="$1"
  local target_arch="$2"
    echo "--- Functional: DeepStream (nvidia variant only) ---"
    local out rc=0
    out="$(_rt_run bash -lc 'set -uo pipefail
[ -e /opt/nvidia/deepstream ] || { echo "ABSENT"; exit 0; }
[ "${ENABLE_NVIDIA:-false}" = true ] || { echo "PRESENT-IN-A-NON-NVIDIA-IMAGE"; exit 1; }
root="$(readlink -f /opt/nvidia/deepstream/deepstream)"; trt="$(ls -d /opt/nvidia/deepstream/tensorrt-* | head -1)"
DSV_WIRED=1 DS_ROOT="${root}" DS_TRT_PREFIX="${trt}" bash /opt/scripts/frameworks/deepstream-verify.sh' 2>&1)" || rc=$?
    printf '%s\n' "${out}" | sed 's/^/    /'
    if [ "${rc}" != 0 ]; then
      fail "DeepStream gates failed in the runtime image (${target_arch})"
    elif [ "${out}" = "ABSENT" ]; then
      pass "no DeepStream in this image (${target_arch})"
    else
      pass "DeepStream elements register and resolve (${target_arch})"
    fi
    echo ""
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

  # 9. Functional checks: load the ML stack and run ffmpeg inside the image, through the entrypoint so the runtime env applies.
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
    check_llvm_target_startable "${image_tag}" "${target_arch}"
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
    check_ort_census "${image_tag}" "${target_arch}"
    check_free_threaded_wheels "${image_tag}" "${target_arch}"
    check_gstreamer_plugin_health "${image_tag}" "${target_arch}"
    check_gst_validate_ssim "${image_tag}" "${target_arch}"
    check_no_libunwind_closure "${image_tag}" "${target_arch}"
    check_gstreamer_core_pipeline "${image_tag}" "${target_arch}"
    check_gstreamer_mandatory_plugins "${image_tag}" "${target_arch}"
    check_deepstream "${image_tag}" "${target_arch}"
    check_application_import "${image_tag}" "${target_arch}"
    check_healthcheck_exec "${image_tag}" "${target_arch}"
    check_webrtc_signalling "${image_tag}" "${target_arch}"
    check_vulkan_loader "${image_tag}" "${target_arch}"
    check_lavapipe_subgroup "${image_tag}" "${target_arch}"
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
