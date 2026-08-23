#!/usr/bin/env bash
set -euo pipefail

# smoke-runtime-image.sh
# Validates that the runtime wrapper image starts correctly:
#   - Image can run a trivial command
#   - Entrypoint is functional
#   - HEALTHCHECK responds
#   - Kataglyphis user exists
#   - Key runtime paths exist
#   - Functional: onnxruntime/numpy/torch import + ffmpeg executes inside the
#     image (under qemu for cross arches); torch-less sentinel is flagged.
#     Skip with RUNTIME_FUNCTIONAL_SMOKE=0; accept torch-less with
#     ALLOW_TORCHLESS_RUNTIME=1.
#   - The DEFAULT entrypoint+CMD actually boots (not just the argv path)
#   - One real InferenceSession on a generated ONNX graph
#   - ARCH-PARITY: every /opt prefix and component wheel NAMED in the table is
#     present on this arch, or its absence is documented (see _parity_exempt /
#     _parity_ort_flavor). Single-image scope: it conforms this arch to the
#     table, it does NOT diff one arch against another — a component missing
#     from the table is outside the gate. See the table's own comment block.
#
# Usage:
#   smoke-runtime-image.sh <image-tag> [target-arch]
#   smoke-runtime-image.sh ghcr.io/kataglyphis/kataglyphis_beschleuniger:latest-cross-arm64 arm64

_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${_SCRIPT_DIR}/smoke-common.sh"

NERDCTL_BIN="${NERDCTL_BIN:-nerdctl}"

# Evaluate a python expression against the image's `nerdctl image inspect` JSON
# (the [0] element on stdin). Prints the expr's output, empty on any error.
# DRYs the repeated `nerdctl image inspect | python3 -c` boilerplate. Uses the
# caller's ${image_tag} via dynamic scope.
inspect_image_config() {
  "${NERDCTL_BIN}" image inspect "${image_tag}" 2>/dev/null | python3 -c "$1" 2>/dev/null || true
}

# Run a command inside the image under test (backlog 2026-08-10 D1: this exact
# invocation preamble appeared verbatim at 18 call sites). Uses the caller's
# ${image_tag}/${target_arch} via dynamic scope, same convention as
# inspect_image_config above. Leading `-e KEY=VAL` pairs are forwarded as
# nerdctl-run env options (extend here — one place — if a future check needs
# more run options, timeouts, mounts, …); everything else is the in-image
# command. Exit code is nerdctl's, so `if _rt_run …` keeps working.
_rt_run() {
  local -a _opts=()
  while [ "${1:-}" = "-e" ]; do
    _opts+=(-e "$2")
    shift 2
  done
  "${NERDCTL_BIN}" run --rm --platform "linux/${target_arch}" \
    ${_opts[@]+"${_opts[@]}"} "${image_tag}" "$@"
}

# Cross-section state (backlog B5 main() split): the torch-less-sentinel check
# decides whether torch is expected in the image; the app-wheel-smoke and
# version-pin sections consume that decision. Set by check_torchless_sentinel
# (1 = torch expected, 0 = sentinel present), read by the later checks.
_SMOKE_TORCH_EXPECTED=1

# 1. Ensure image exists locally (pull if needed)
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

# 2. Run a trivial command
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

# 3. Check entrypoint
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

# 3b. Boot the image the way a USER does (SMOKE-DEPTH b, 2026-08-23): with NO
# command, so the shipped ENTRYPOINT runs the shipped CMD. Step 3 only reads the
# configured string and every other check here passes an explicit argv, so
# entrypoint.sh's own default path — the env sourcing, the one-time-setup hook
# and the final `exec "$@"` — was never once executed by the gate: a broken
# entrypoint.sh ships green. The probe script arrives on STDIN (`-i`, no
# command) precisely so the default CMD /bin/bash is what reads it, and the
# `exit 42` proves the exec chain hands the child's status back instead of
# swallowing it (a wrapper that forgets `exec` returns its own 0).
#
# NOT covered, despite an earlier comment here claiming it: entrypoint.sh's
# `[ $# -eq 0 ]` fallback. Dockerfile.torch declares CMD ["/bin/bash"], and the
# container runtime always appends the image CMD to the ENTRYPOINT argv, so the
# entrypoint runs with $# == 1 and that branch is dead on this image. Only an
# image with NO CMD at all would take it (handled below).
#
# This is a GATE, so neither of its two "cannot run the probe" situations may
# turn into a quiet skip:
#   * inspect_image_config swallows every error into an empty string (`|| true`),
#     so the CMD probe carries a CMDOK marker — no marker means inspect failed
#     and that is a FAILURE, not a reason to stand down;
#   * a CMD whose first word is not a shell FAILS too. This script smokes the
#     runtime wrapper, whose contract is CMD ["/bin/bash"]; if that contract
#     changes deliberately, this probe has to change with it. A gate that
#     reconfigures itself out of existence is exactly the defect being fixed.
# `CMD ["bash","-l"]` and friends still run the probe — only the FIRST word is
# matched, and that used to skip the whole check.
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
           'exit 42' \
         | "${NERDCTL_BIN}" run --rm -i --platform "linux/${target_arch}" "${image_tag}" 2>/dev/null)" \
    && rc=0 || rc=$?
  if [ "${rc}" != "42" ]; then
    fail "default ENTRYPOINT+CMD boot returned ${rc}, expected the script's 42 (${target_arch}) -- entrypoint.sh does not exec the CMD or died before it: ${out}"
  elif ! printf '%s' "${out}" | grep -q "gst=set"; then
    fail "default boot ran but the entrypoint exported no GStreamer env (${target_arch}): ${out} -- gstreamer-env.sh sourcing regressed"
  else
    pass "default ENTRYPOINT+CMD boot: ${out} (exit status propagated)"
  fi
  echo ""
}

# 4. Check HEALTHCHECK
check_healthcheck_config() {
  local image_tag="$1"
  local target_arch="$2"
  echo "--- HEALTHCHECK ---"
  local healthcheck
  healthcheck="$(inspect_image_config "import sys,json; cfg=json.load(sys.stdin)[0].get('Config',{}); hc=cfg.get('Healthcheck',{}); print(hc.get('Test',[''])[0] if hc else 'NONE')")"
  if [ -n "${healthcheck}" ] && [ "${healthcheck}" != "NONE" ]; then
    pass "HEALTHCHECK configured: ${healthcheck}"
  else
    fail "No HEALTHCHECK configured"
  fi
  echo ""
}

# 5. Check kataglyphis user exists
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

# 6. Check WORKDIR
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

# 7. Check VOLUME
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

# 8. Check OCI labels
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

# Wheel smoke -- delegate to the APP's own smoke module (single source of
# truth). `python -m orchestr_ant_ion.smoke` exercises each shipped wheel with
# REAL work (torch autograd + a linear forward/backward, torchvision ops.nms,
# an embedded ONNX inference, an OpenCV encode/decode/cvtColor round-trip,
# Pillow, the torch<->numpy ABI bridge); LiteRT is optional there (WARN, not a
# gate failure). The app OWNS what its wheels must do; this gate just runs that
# suite on-target under qemu. Replaces the old ad-hoc torch/onnx/cv2 import +
# inference checks. Torch-less images skip it (falling back to a bare
# onnx/numpy import) since the suite treats torch as required.
check_app_wheel_smoke() {
  local image_tag="$1"
  local target_arch="$2"
    if [ "${_SMOKE_TORCH_EXPECTED}" = "1" ]; then
      echo "--- Functional: app wheel smoke (python -m orchestr_ant_ion.smoke) ---"
      if _rt_run \
           /opt/venv/bin/python -m orchestr_ant_ion.smoke; then
        pass "app wheel smoke passed on-target (${target_arch})"
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

# SMOKE-DEPTH(c) 2026-08-23: run ONE real inference from THIS repo. The
# in-image battery's session check used to build its model with
# torch.onnx.export, which needs `onnxscript` — not in the venv — so it printed
# "SKIP ort InferenceSession check" on all three shipped wave-5 arches: no
# execution provider was ever proven to work by anything we own. (The app wheel
# smoke above does run one, but it lives in ANOTHER repo and skips entirely on
# torch-less images.) smoke_minimal_onnx_py emits a one-node Add graph as raw
# protobuf — no `onnx` package, no network, ~110 model bytes — and is injected
# as an env var rather than read from /opt/scripts so this gate also works
# against images built before the check existed.
#
# EXIT STATUS IS NOT EVIDENCE HERE. The program crosses the container boundary
# as an env var and is fed to `python -` on stdin: if SMOKE_ONNX_PY arrives
# empty (env not forwarded, `-e` swallowed, a `bash -l` profile clobbering it,
# a quoting regression in _rt_run), python reads an EMPTY program and exits 0
# — the exact "green because nothing ran" class this repo has shipped three
# times. So the check demands POSITIVE evidence from the program's OUTPUT: an
# `ONNX-EP <verdict>:` sentinel that only smoke_minimal_onnx_py can print, and
# for a pass specifically `ONNX-EP OK:` carrying the provider it actually used.
# No sentinel => FAIL, whatever the exit status says. The in-image guard below
# is the second half: it turns an empty program into a loud sentinel instead of
# silence, so the failure names its own cause.
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
      # Not a skip in a WRAPPER: the image's own HEALTHCHECK is
      # `python3 -c "import onnxruntime"`, so an unimportable onnxruntime here
      # means every container would report unhealthy.
      fail "onnxruntime/numpy not importable in the runtime image (${target_arch}) -- the HEALTHCHECK imports onnxruntime, so this is a defect: ${sentinel}"
    else
      fail "onnxruntime InferenceSession FAILED on the generated Add graph (${target_arch}, rc=${rc}): ${sentinel}"
    fi
    echo ""
}

# Not just "importable" but the CORRECT versions. Delegate to the canonical
# venv-integrity smoke's assert-only mode: it asserts each ML package matches
# its pin -- uv.lock for uv-resolved packages (numpy/pillow/contourpy + the
# amd64/arm64 torch/vision/onnx wheels) and versions.env for the ones we build
# or force-reinstall from a LOCAL wheel (riscv64 torch/vision, source-built
# onnxruntime, ai-edge-litert) -- plus the +cpu/+cu130 build variant and
# OpenCV major. This is the check that catches a wrong version silently
# slipping in (lock drift, a stale local wheel, a floated index). cv2 stays
# optional here to match the informational import above. Torch-less images
# skip it (no versions to assert).
check_ml_version_pins() {
  local image_tag="$1"
  local target_arch="$2"
    if [ "${_SMOKE_TORCH_EXPECTED}" = "1" ]; then
      echo "--- Functional: ML version-pin assertion (${target_arch}) ---"
      _stv_out="$(_rt_run \
           bash -lc 'STV_ASSERT_ONLY=1 STV_CV2_REQUIRED=0 bash /opt/scripts/packaging/smoke-torch-venv.sh' 2>&1)" \
        && _stv_rc=0 || _stv_rc=$?
      printf '%s\n' "${_stv_out}"
      if [ "${_stv_rc}" -eq 0 ]; then
        pass "ML-stack versions match pins (${target_arch})"
      elif [ "${target_arch}" = "riscv64" ] \
           && [ "$(printf '%s\n' "${_stv_out}" | grep -cE '^[[:space:]]*XX ')" = "1" ] \
           && printf '%s\n' "${_stv_out}" | grep -qE '^[[:space:]]*XX[[:space:]]+onnxruntime-genai[[:space:]]+NOT INSTALLED'; then
        # TRANSITIONAL exemption (2026-08-11) — root fix LANDED 2026-08-12:
        # smoke-torch-venv now carries the arch policy itself (expected_absent
        # on riscv64, STV_REQUIRE_GENAI=1 re-arms), so images built after the
        # 2026-08-12 window return rc 0 and never reach this branch. It stays
        # only so this host-side gate can still pass the PRE-window wrappers
        # (e.g. the shipped 2026-08-12 :latest-cross) whose baked assert
        # predates the policy. DELETE after the next validated full rebuild.
        pass "ML-stack versions match pins (${target_arch}; genai absent = documented riscv64 exemption)"
      else
        fail "ML-stack version-pin assertion FAILED in the runtime image (${target_arch})"
      fi
      echo ""
    fi
}

# IREE native tools -- the C side of the same thing check_iree exercises in
# Python. iree-compile lowers a one-op MLIR module (math.absf) and
# iree-run-module executes it on the local-task driver (abs(-5)=5), proving
# the compiled binaries interoperate on-target, not just the Python bindings.
# The wheels install both as console scripts in /opt/venv/bin. GATES when the
# tools are present (amd64/arm64 always ship them via the abi3 PyPI wheels;
# riscv64 only when the best-effort compiler cross-build succeeded) and is
# WARN-only when absent, mirroring the app's optional-when-missing policy for
# the riscv64 lane where only the runtime wheel ships.
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
        # WARN, don't fail, on riscv64: this smoke runs the riscv64 iree-compile under
        # QEMU on the amd64 host, and QEMU advertises a synthetic max-ISA riscv64 CPU
        # (every extension: ...zvksh_zvkt_zvksed...). iree-compile auto-detects that
        # host CPU and hands LLVM a processor/feature set its RISC-V subtarget rejects
        # ('generic-rv64' unrecognized -> RV32 fallback -> "64-bit code requested on a
        # subtarget that doesn't support it"). It reproduces on pre-cp314 images, so it
        # is a QEMU-emulation limitation, not a wheel defect: the cp314
        # iree_base_compiler/iree_base_runtime wheels still BUILD, install, and import
        # here. Real riscv64 hardware reports a sane ISA, so codegen must be verified
        # on-device. amd64/arm64 run natively and keep GATING (the else branch).
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
    # pipefail is REQUIRED: without it, `ffmpeg -version | head -1` returns head's
    # exit (0), so a broken binary -- e.g. `error while loading shared libraries:
    # libopencore-amrwb.so.0` (observed 2026-07-11) -- silently PASSES. With
    # pipefail the missing-.so exit code propagates and the smoke fails as it must.
    if _rt_run \
         bash -lc 'set -o pipefail; v="$(command -v ffmpeg || echo /opt/ffmpeg/bin/ffmpeg)"; "$v" -version | head -1'; then
      pass "ffmpeg executes (${target_arch})"
    else
      fail "ffmpeg failed to execute in the runtime image (${target_arch})"
    fi
    echo ""
}

# Native shared-library dependency closure over the source-built /opt stacks
# (ffmpeg, opencv5, libcamera, vulkan). GENERALISES the ffmpeg .so gate to the
# whole native payload: any binary/lib whose NEEDED soname is absent from the
# runtime loader path is a real defect (this is exactly the class that shipped
# libopencore-amrwb.so.0-broken ffmpeg + libsleef.so.3-broken torch while amd64
# stayed green). Python venv extensions are deliberately EXCLUDED here -- torch
# etc. add their own package lib dirs at import time, which a bare `ldd` cannot
# replicate (false positives); the import checks above are their real gate.
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

# RP1 (security): assert the shipped image carries NO usable `sudo` — it was
# purged from the final stage (Dockerfile.torch) because no sudoers/group grants
# exist and USER kataglyphis can never use it, so it is pure LPE attack surface.
# This gate fails loud if a future base/package change reintroduces it. Every
# OTHER setuid binary is inventoried (informational) so a new one is at least
# VISIBLE in the smoke log rather than shipping unnoticed.
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

# AP7 (size observability, INFORMATIONAL — never fails): the shipped image has no
# per-prefix size breakdown anywhere, so every "shrink X" item (strip passes,
# dead wheels, the TF removal, byte-compile) is un-measurable. One du block turns
# them all into numbers visible in the smoke log — run it so size regressions and
# wins are at least attributable to a prefix. Sorted largest-last for eyeballing.
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

# SMK3 (2026-08-17): AP2 gate — the venv must ship byte-compiled. The runtime
# user (uid-1001) cannot write __pycache__ into the root-owned /opt/venv, so if
# the build-time compileall regresses, every container start silently re-parses
# site-packages again (the exact cost AP2 removed). HARD fail: a shipped venv
# without any .pyc is a real regression, not an environment artifact.
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

# ── ARCH-PARITY table (2026-08-23) ──────────────────────────────────────────
# The three wrappers are supposed to be the same image with a different arch,
# and verified live on the wave-5 ship they are not: riscv64 carries no
# /opt/cmake (amd64 207M, arm64 130M), onnxruntime-genai ships on amd64+arm64
# only, and the ORT flavour differs by arch. None of it was gated anywhere, so
# every delta was silent.
#
# WHAT THIS ACTUALLY CHECKS — and what it does NOT. This smoke runs against ONE
# image at a time (build-runtime-manifest.sh invokes it per arch), so it cannot
# diff arch A against arch B. It is not a cross-arch differ; it is a
# TABLE-CONFORMANCE check:
#   * every component NAMED in _PARITY_PREFIXES/_PARITY_WHEELS must be present
#     on this arch, unless _parity_exempt documents its absence  -> FAILS;
#   * a documented exemption whose component turns out to be PRESENT is called
#     out as a stale table entry                                  -> WARN;
#   * exactly one onnxruntime distribution, the flavour the table names -> FAILS.
# It therefore CANNOT see a one-sided EXTRA: a component that exists on one arch
# and not another while being absent from the table above is invisible to the
# loop, because the loop only iterates over names the table already lists. The
# untracked /opt prefixes are printed (INFO) on every run so that diffing the
# three per-arch smoke logs still surfaces such a delta by eye; making that
# automatic needs a cross-arch step in the caller and is left on the ARCH-PARITY
# backlog item. Adding a component to the table is what puts it under the gate.
#
# Prefix names are version-stripped (cmake-4.4.2 -> cmake) so a pin bump does
# not need a table edit.
_PARITY_PREFIXES="Kataglyphis-Orchestr-ANT-ion android android-sdk cmake ffmpeg gcc gstreamer libcamera opencv5 python scripts venv vulkan"
# Wheel names in dist-info form ('-' and '.' normalised to '_').
_PARITY_WHEELS="torch torchvision ai_edge_litert iree_base_compiler iree_base_runtime onnxruntime_genai"

# Documented per-arch absences. Each arm is a REVIEWED decision with its reason;
# anything absent that is NOT listed here is drift and fails.
_parity_exempt() {
  case "$1:$2" in
    # Kitware publishes no riscv64 CMake archive, so 02-toolchain/cmake.sh
    # deliberately installs the distro cmake there (4.2.3) instead.
    riscv64:cmake) return 0 ;;
    # GEN1: upstream ships no riscv64 onnxruntime-genai wheel in any version
    # and closed its one RISC-V request as not-planned; the producer skips the
    # arch and verify-media-artifacts agrees. Policy, not drift.
    riscv64:onnxruntime_genai) return 0 ;;
    *) return 1 ;;
  esac
}

# Which onnxruntime flavour each arch is SUPPOSED to carry, and only one of
# them: the 2026-08-21 version shadow shipped a PyPI onnxruntime 1.27 beside
# the built one and broke every import with a VERS_1.29.0 symbol error. Wave-5
# fixed it to exactly one distribution per image — dnnl on amd64, webgpu on
# arm64/riscv64 — which is a decision, so it belongs in the table.
_parity_ort_flavor() {
  case "$1" in
    amd64)         printf '%s' 'onnxruntime_dnnl' ;;
    arm64|riscv64) printf '%s' 'onnxruntime_webgpu' ;;
    *)             printf '%s' '' ;;
  esac
}

# GStreamer plugins that are KNOWN not to load on a given arch. Same contract:
# listed = reviewed, unlisted = new drift (reported, still non-fatal — a broken
# optional plugin degrades gracefully; see check_gstreamer_plugin_health).
_parity_gst_plugin_known() {
  case "$1:$2" in
    # arm64 only: the distro libgtk-4.so.1 resolves vkCreateWaylandSurfaceKHR
    # against the system Vulkan loader, which the shipped /opt/vulkan loader
    # does not export here. The gtk4 SINK is a desktop-display element with no
    # role in a headless wrapper, so it is accepted rather than fixed.
    arm64:libgstgtk4.so) return 0 ;;
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
          echo "  WARN ${want} is PRESENT on ${target_arch} although the parity table exempts it -- drop the exemption (it is stale)"
        fi
      elif _parity_exempt "${target_arch}" "${want}"; then
        echo "  ~~   ${want} absent (documented ${target_arch} exception)"
      else
        fail "ARCH-PARITY: ${want} missing on ${target_arch} and NOT in the documented exception list -- ship it or record the exception in _parity_exempt"
      fi
    done

    # The blind spot, stated out loud and with the raw material next to it: the
    # loop above can only judge names the table already carries, so a prefix
    # that exists here and nowhere else is invisible to it. Print the untracked
    # prefixes (a short list — /opt has ~13 entries) so comparing the three
    # per-arch smoke logs still exposes a one-sided extra. INFO, never a gate:
    # a gate would need to see all three images at once. Wheels are excluded on
    # purpose — the venv has hundreds of dist-infos and the noise would bury it.
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

# GStreamer plugin health -- WARN only. Unlike ffmpeg/opencv, a GStreamer
# plugin whose runtime .so is absent degrades gracefully (the element is just
# unavailable), so a broken optional plugin must not fail the gate. But surface
# them: this is what makes an app-critical regression visible (e.g. webrtcbin2
# -> librice-proto.so.0, openh264enc -> libopenh264.so.8). The functional
# pipeline check below is the fail-loud gate for GStreamer CORE.
check_gstreamer_plugin_health() {
  local image_tag="$1"
  local target_arch="$2"
    echo "--- Functional: GStreamer plugin health (informational) ---"
    # Use gst-inspect (which drives the plugin SCANNER) rather than a plain
    # `ldd => not found` scan: the scanner actually dlopen()s each plugin and
    # reports EVERY load failure to stderr as "Failed to load plugin", including
    # UNDEFINED-SYMBOL failures (e.g. gtk4 -> libgtk-4.so.1: undefined symbol
    # vkCreateWaylandSurfaceKHR) that ldd cannot see (the dep .so is present, just
    # missing a symbol). Still WARN-only: a broken OPTIONAL plugin degrades
    # gracefully; the functional pipeline check below is the fail-loud CORE gate.
    # ARCH-PARITY (2026-08-23): classify the failures instead of only counting
    # them. arm64 has shipped a gtk4 plugin that cannot load since wave-4
    # (undefined symbol vkCreateWaylandSurfaceKHR) and the count line looked
    # exactly like a healthy run with a different number in it. Known-and-
    # reviewed failures now say so; anything else is called out as new drift.
    #
    # THE HEADLINE NUMBER IS STILL THE RAW LINE COUNT. Classification works on
    # UNIQUE libgst*.so basenames, which is strictly fewer than the failure
    # lines: a message that names no libgst*.so basename (a plugin outside the
    # naming convention, or an error whose text never reaches the basename)
    # contributes nothing, and the same basename failing from two plugin
    # directories collapses to one. Reporting known+unknown as "plugins that
    # cannot load" would have quietly LOWERED a regression metric that has been
    # watched since wave-4, so the pre-classification count is kept verbatim
    # and the classification is printed beside it, not instead of it.
    local scan failed p known=0 unknown=0 total named unnamed
    scan="$(_rt_run bash -lc 'command -v gst-inspect-1.0 >/dev/null 2>&1 || { echo "GST_SCAN_ABSENT"; exit 0; }
gst-inspect-1.0 2>&1 >/dev/null || true
echo "GST_SCAN_DONE"' 2>/dev/null)" || true
    # An empty scan is AMBIGUOUS -- a perfectly healthy image also prints
    # nothing here -- so the probe stamps its own completion. Without the
    # stamp, "0 plugins cannot load" would be a false green for a probe that
    # never ran.
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
    # Line 1 = the metric as it has always been counted (comparable across runs).
    echo "  GStreamer plugins that cannot load: ${total} (non-fatal)"
    # Line 2 = the new detail, explicitly on a different denominator.
    local unnamed_note=""
    if [ "${unnamed}" -gt 0 ]; then
      unnamed_note="; ${unnamed} failure line(s) name no libgst*.so and could not be classified"
    fi
    echo "  ... of those, by unique libgst*.so basename: ${known} documented, ${unknown} undocumented${unnamed_note}"
    echo ""
}

# (onnxruntime inference + cv2 encode/decode roundtrip now live in the app
# wheel smoke above -- `python -m orchestr_ant_ion.smoke` runs the same
# embedded Add model and the same imencode/imdecode round-trip on-target.)

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

# Mandatory-plugin GATE on the real target arch (smoke-depth R1). The
# Windows lane has a 4-point plugin contract; Linux shipped these four
# with only a WARN-only load-failure count. gst-inspect-1.0 <plugin>
# exits non-zero if the plugin is missing OR fails to dlopen.
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
    # The actual deliverable: the Orchestr-ANT-ion app must import in the shipped
    # venv. A broken/incomplete app install (missing runtime dep) shipped silently
    # before -- import it through the venv python to catch that.
    if _rt_run \
         /opt/venv/bin/python -c "import orchestr_ant_ion" >/dev/null 2>&1; then
      pass "application module imports (${target_arch})"
    else
      fail "application module (orchestr_ant_ion) failed to import in the venv (${target_arch})"
    fi
    echo ""
}

# Run the ACTUAL HEALTHCHECK command, not just parse it. Step 4 above only reads
# the configured Test string; the HC is `/opt/venv/bin/python3 -c import
# onnxruntime`, so a broken interpreter path or a mislinked onnxruntime leaves
# the container perpetually `unhealthy` while a string-only check stays green.
# This runs the real command so that fail-open class can actually fail.
check_healthcheck_exec() {
  local image_tag="$1"
  local target_arch="$2"
    echo "--- Functional: HEALTHCHECK command executes ---"
    if _rt_run \
         /opt/venv/bin/python3 -c 'import onnxruntime' >/dev/null 2>&1; then
      pass "HEALTHCHECK command runs (import onnxruntime via /opt/venv/bin/python3) (${target_arch})"
    else
      fail "HEALTHCHECK command FAILED (${target_arch}) -- container would report unhealthy"
    fi
    echo ""
}

# WebRTC signalling server: start-webrtc-signalling.sh (a shipped entrypoint)
# execs gst-webrtc-signalling-server. WARN-only -- it belongs to the same
# gst-plugins-rs/webrtc lane as the known webrtcbin2 gap (backlog), so its
# absence must not gate the manifest, but a dead signalling entrypoint should be
# visible every run.
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

# Vulkan loader load test. The .so-closure gate proves libvulkan resolves, but
# not that the loader dlopen()s at runtime. WARN-only: a headless CI container
# has no GPU/ICD so device enumeration legitimately finds nothing -- we only
# assert the loader library itself loads.
# Three-way verdict instead of blanket WARN (audit round 2): a missing
# ICD/GPU does NOT stop ctypes.CDLL from loading the loader library — a
# load failure means the lib is missing/broken, and the runtime image
# ALWAYS installs the Vulkan runtime files (base-image
# install-vulkan-runtime-files). Only a container-infra error stays WARN.
check_vulkan_loader() {
  local image_tag="$1"
  local target_arch="$2"
    echo "--- Functional: Vulkan loader ---"
    # vkEnumerateInstanceVersion works with ZERO ICDs and no GPU — a healthy
    # loader cannot legitimately fail it (smoke-depth R12). AttributeError
    # guard keeps a hypothetical 1.0 loader from false-failing.
    _vk_out="$(_rt_run \
         /opt/venv/bin/python -c 'import ctypes
l = ctypes.CDLL("libvulkan.so.1")
try:
    v = ctypes.c_uint32()
    assert l.vkEnumerateInstanceVersion(ctypes.byref(v)) == 0
    print("VKOK %d.%d.%d" % (v.value >> 22, (v.value >> 12) & 1023, v.value & 4095))
except AttributeError:
    print("VKOK (pre-1.1 loader)")' 2>&1)" || true
    if printf '%s' "${_vk_out}" | grep -q "VKOK"; then
      echo "  OK  libvulkan.so.1 loads (${target_arch})"
    elif printf '%s' "${_vk_out}" | grep -qiE "OSError|No such file|cannot open shared object|not found"; then
      fail "libvulkan.so.1 missing/unloadable in ${target_arch} image (runtime always ships it): $(printf '%s' "${_vk_out}" | tail -1)"
    else
      echo "  WARN vulkan load check inconclusive (container-infra error?) -- non-fatal: $(printf '%s' "${_vk_out}" | tail -1)"
    fi
    echo ""
}

# Native compiler compile + link + RUN. The build-time validate-compilers.sh
# smoke compiles AND links a program in every wrapper image, but never RUNS
# the result: on the x86_64 build host a cross arch's binary cannot execute,
# so the shipped native GCC/G++ was only ever ELF/version/link-verified for
# arm64+riscv64 (the riscv64 --with-isa-spec GCC especially). HERE the wrapper
# runs under binfmt/qemu, so we can finally prove the on-target compiler
# actually compiles, links AND executes a real binary. The C++ case also
# exercises the libstdc++ runtime. Gate RUNTIME_COMPILER_SMOKE=0 to skip.
check_native_compiler_battery() {
  local image_tag="$1"
  local target_arch="$2"
    if [ "${RUNTIME_COMPILER_SMOKE:-1}" = "1" ]; then
      echo "--- Functional: native compiler battery compile+link+run (${target_arch}) ---"
      # A battery, not just hello-world: each case exercises a distinct piece of
      # the shipped toolchain that a hello-world would not. C++ exceptions+STL is
      # the load-bearing one -- it regression-guards the -idirafter WRAPPER fix in
      # swap-native-gcc.sh (an installed specs file made throw/catch terminate at
      # runtime; the wrapper leaves the EH link specs intact). std::thread proves
      # libstdc++ threading + libpthread; libatomic proves 64-bit atomics link
      # (riscv64 needs the runtime lib); -flto proves the LTO plugin loads. All six
      # validated to pass on arm64+riscv64 with the wrapper fix. Sources use only
      # double quotes / return-code checks so they stay clean inside bash -lc.
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

# Clang/LLVM version alignment on the ACTUAL shipped image, per-arch under
# qemu. The build-time smoke-toolchain/validate-compilers checks run in the
# TOOLCHAIN stage where clang and LLVM_RELEASE are consistent by construction;
# they do NOT catch a STALE toolchain — e.g. a --from-stage media publish that
# reuses an old cross-sdk whose clang predates a LLVM_RELEASE bump (shipped
# clang 22.1.2 while versions.env says 22.1.8). Assert the runtime image's
# clang == LLVM_RELEASE so that drift fails the smoke on every arch. Disable
# with RUNTIME_CLANG_VERSION_SMOKE=0.
check_clang_llvm_release() {
  local image_tag="$1"
  local target_arch="$2"
    if [ "${RUNTIME_CLANG_VERSION_SMOKE:-1}" = "1" ]; then
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

  # 9. Functional checks (D1/D2): actually LOAD the compiled ML stack and RUN
  #    ffmpeg INSIDE the image -- under binfmt/qemu for cross arches. The checks
  #    above prove the image boots and its metadata is sane; these prove the
  #    arch-specific NATIVE extensions genuinely import/execute on the target
  #    (previously only validated on native amd64 or on real hardware). Runs
  #    through the entrypoint so the gstreamer/libcamera/vulkan env matches
  #    runtime. Gate RUNTIME_FUNCTIONAL_SMOKE=0 to skip (e.g. no qemu handler).
  if [ "${RUNTIME_FUNCTIONAL_SMOKE:-1}" = "1" ]; then
    check_torchless_sentinel "${image_tag}" "${target_arch}"
    check_app_wheel_smoke "${image_tag}" "${target_arch}"
    check_onnx_execution_provider "${image_tag}" "${target_arch}"
    check_ml_version_pins "${image_tag}" "${target_arch}"
    check_iree_native "${image_tag}" "${target_arch}"
    check_ffmpeg "${image_tag}" "${target_arch}"
    check_native_so_closure "${image_tag}" "${target_arch}"
    check_setuid_inventory "${image_tag}" "${target_arch}"
    check_size_observability "${image_tag}" "${target_arch}"
    check_venv_bytecode "${image_tag}" "${target_arch}"
    check_arch_parity "${image_tag}" "${target_arch}"
    check_gstreamer_plugin_health "${image_tag}" "${target_arch}"
    check_gstreamer_core_pipeline "${image_tag}" "${target_arch}"
    check_gstreamer_mandatory_plugins "${image_tag}" "${target_arch}"
    check_application_import "${image_tag}" "${target_arch}"
    check_healthcheck_exec "${image_tag}" "${target_arch}"
    check_webrtc_signalling "${image_tag}" "${target_arch}"
    check_vulkan_loader "${image_tag}" "${target_arch}"
    check_native_compiler_battery "${image_tag}" "${target_arch}"
    check_clang_llvm_release "${image_tag}" "${target_arch}"
  else
    echo "--- Functional checks skipped (RUNTIME_FUNCTIONAL_SMOKE=0) ---"
    echo ""
  fi

  smoke_summary
}

main "$@"
