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

  # 1. Ensure image exists locally (pull if needed)
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

  # 2. Run a trivial command
  echo "--- Trivial command ---"
  if _rt_run /bin/true 2>/dev/null; then
    pass "Container can run /bin/true"
  else
    fail "Container cannot run /bin/true"
  fi
  echo ""

  # 3. Check entrypoint
  echo "--- Entrypoint ---"
  local config
  config="$(inspect_image_config "import sys,json; print(json.load(sys.stdin)[0].get('Config',{}).get('Entrypoint',''))")"
  if [ -n "${config}" ]; then
    pass "Entrypoint configured: ${config}"
  else
    fail "No entrypoint configured"
  fi
  echo ""

  # 4. Check HEALTHCHECK
  echo "--- HEALTHCHECK ---"
  local healthcheck
  healthcheck="$(inspect_image_config "import sys,json; cfg=json.load(sys.stdin)[0].get('Config',{}); hc=cfg.get('Healthcheck',{}); print(hc.get('Test',[''])[0] if hc else 'NONE')")"
  if [ -n "${healthcheck}" ] && [ "${healthcheck}" != "NONE" ]; then
    pass "HEALTHCHECK configured: ${healthcheck}"
  else
    fail "No HEALTHCHECK configured"
  fi
  echo ""

  # 5. Check kataglyphis user exists
  echo "--- kataglyphis user ---"
  if _rt_run id -u kataglyphis >/dev/null 2>&1; then
    pass "kataglyphis user exists"
  else
    fail "kataglyphis user not found"
  fi
  echo ""

  # 6. Check WORKDIR
  echo "--- WORKDIR ---"
  local workdir
  workdir="$(inspect_image_config "import sys,json; print(json.load(sys.stdin)[0].get('Config',{}).get('WorkingDir',''))")"
  if [ -n "${workdir}" ]; then
    pass "WORKDIR: ${workdir}"
  else
    echo "  INFO: No WORKDIR set"
  fi
  echo ""

  # 7. Check VOLUME
  echo "--- VOLUME ---"
  local volumes
  volumes="$(inspect_image_config "import sys,json; vols=json.load(sys.stdin)[0].get('Config',{}).get('Volumes',''); print(':'.join(vols.keys()) if vols and isinstance(vols,dict) else 'NONE')")"
  if [ -n "${volumes}" ] && [ "${volumes}" != "NONE" ]; then
    pass "VOLUME: ${volumes}"
  else
    echo "  INFO: No VOLUME set"
  fi
  echo ""

  # 8. Check OCI labels
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

  # 9. Functional checks (D1/D2): actually LOAD the compiled ML stack and RUN
  #    ffmpeg INSIDE the image -- under binfmt/qemu for cross arches. The checks
  #    above prove the image boots and its metadata is sane; these prove the
  #    arch-specific NATIVE extensions genuinely import/execute on the target
  #    (previously only validated on native amd64 or on real hardware). Runs
  #    through the entrypoint so the gstreamer/libcamera/vulkan env matches
  #    runtime. Gate RUNTIME_FUNCTIONAL_SMOKE=0 to skip (e.g. no qemu handler).
  if [ "${RUNTIME_FUNCTIONAL_SMOKE:-1}" = "1" ]; then
    echo "--- Functional: torch-less sentinel (A3) ---"
    local torch_expected=1
    if _rt_run \
         test -f /opt/venv/.torch-missing >/dev/null 2>&1; then
      torch_expected=0
      if [ "${ALLOW_TORCHLESS_RUNTIME:-0}" = "1" ]; then
        echo "  INFO: /opt/venv/.torch-missing present -- image ships WITHOUT torch (allowed)"
      else
        fail "Image ships WITHOUT torch (/opt/venv/.torch-missing present); set ALLOW_TORCHLESS_RUNTIME=1 to accept"
      fi
    else
      pass "No torch-less sentinel (torch expected in image)"
    fi
    echo ""

    # Wheel smoke -- delegate to the APP's own smoke module (single source of
    # truth). `python -m orchestr_ant_ion.smoke` exercises each shipped wheel with
    # REAL work (torch autograd + a linear forward/backward, torchvision ops.nms,
    # an embedded ONNX inference, an OpenCV encode/decode/cvtColor round-trip,
    # Pillow, the torch<->numpy ABI bridge); LiteRT is optional there (WARN, not a
    # gate failure). The app OWNS what its wheels must do; this gate just runs that
    # suite on-target under qemu. Replaces the old ad-hoc torch/onnx/cv2 import +
    # inference checks. Torch-less images skip it (falling back to a bare
    # onnx/numpy import) since the suite treats torch as required.
    if [ "${torch_expected}" = "1" ]; then
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
    if [ "${torch_expected}" = "1" ]; then
      echo "--- Functional: ML version-pin assertion (${target_arch}) ---"
      if _rt_run \
           bash -lc 'STV_ASSERT_ONLY=1 STV_CV2_REQUIRED=0 bash /opt/scripts/packaging/smoke-torch-venv.sh'; then
        pass "ML-stack versions match pins (${target_arch})"
      else
        fail "ML-stack version-pin assertion FAILED in the runtime image (${target_arch})"
      fi
      echo ""
    fi

    # IREE native tools -- the C side of the same thing check_iree exercises in
    # Python. iree-compile lowers a one-op MLIR module (math.absf) and
    # iree-run-module executes it on the local-task driver (abs(-5)=5), proving
    # the compiled binaries interoperate on-target, not just the Python bindings.
    # The wheels install both as console scripts in /opt/venv/bin. GATES when the
    # tools are present (amd64/arm64 always ship them via the abi3 PyPI wheels;
    # riscv64 only when the best-effort compiler cross-build succeeded) and is
    # WARN-only when absent, mirroring the app's optional-when-missing policy for
    # the riscv64 lane where only the runtime wheel ships.
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

    # Native shared-library dependency closure over the source-built /opt stacks
    # (ffmpeg, opencv5, libcamera, vulkan). GENERALISES the ffmpeg .so gate to the
    # whole native payload: any binary/lib whose NEEDED soname is absent from the
    # runtime loader path is a real defect (this is exactly the class that shipped
    # libopencore-amrwb.so.0-broken ffmpeg + libsleef.so.3-broken torch while amd64
    # stayed green). Python venv extensions are deliberately EXCLUDED here -- torch
    # etc. add their own package lib dirs at import time, which a bare `ldd` cannot
    # replicate (false positives); the import checks above are their real gate.
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

    # GStreamer plugin health -- WARN only. Unlike ffmpeg/opencv, a GStreamer
    # plugin whose runtime .so is absent degrades gracefully (the element is just
    # unavailable), so a broken optional plugin must not fail the gate. But surface
    # them: this is what makes an app-critical regression visible (e.g. webrtcbin2
    # -> librice-proto.so.0, openh264enc -> libopenh264.so.8). The functional
    # pipeline check below is the fail-loud gate for GStreamer CORE.
    echo "--- Functional: GStreamer plugin health (informational) ---"
    # Use gst-inspect (which drives the plugin SCANNER) rather than a plain
    # `ldd => not found` scan: the scanner actually dlopen()s each plugin and
    # reports EVERY load failure to stderr as "Failed to load plugin", including
    # UNDEFINED-SYMBOL failures (e.g. gtk4 -> libgtk-4.so.1: undefined symbol
    # vkCreateWaylandSurfaceKHR) that ldd cannot see (the dep .so is present, just
    # missing a symbol). Still WARN-only: a broken OPTIONAL plugin degrades
    # gracefully; the functional pipeline check below is the fail-loud CORE gate.
    _rt_run \
      bash -lc '
scan="$(gst-inspect-1.0 2>&1 >/dev/null || true)"
printf "%s\n" "${scan}" | grep "Failed to load plugin" | sed "s/^.*Failed/  degraded: Failed/" | sort -u | head -40
g="$(printf "%s\n" "${scan}" | grep -c "Failed to load plugin" || true)"
echo "  GStreamer plugins that cannot load: ${g} (non-fatal)"' 2>/dev/null || true
    echo ""

    # (onnxruntime inference + cv2 encode/decode roundtrip now live in the app
    # wheel smoke above -- `python -m orchestr_ant_ion.smoke` runs the same
    # embedded Add model and the same imencode/imdecode round-trip on-target.)

    echo "--- Functional: GStreamer core pipeline ---"
    if _rt_run \
         bash -lc 'gl="$(command -v gst-launch-1.0 || echo /opt/gstreamer/bin/gst-launch-1.0)"; timeout 40 "$gl" -q videotestsrc num-buffers=3 ! videoconvert ! fakesink'; then
      pass "GStreamer core pipeline runs (${target_arch})"
    else
      fail "GStreamer core pipeline FAILED (${target_arch})"
    fi
    echo ""

    # Mandatory-plugin GATE on the real target arch (smoke-depth R1). The
    # Windows lane has a 4-point plugin contract; Linux shipped these four
    # with only a WARN-only load-failure count. gst-inspect-1.0 <plugin>
    # exits non-zero if the plugin is missing OR fails to dlopen.
    echo "--- Functional: GStreamer mandatory plugins (libav opencv onnx tflite) ---"
    if _rt_run \
         bash -lc 'gi="$(command -v gst-inspect-1.0 || echo /opt/gstreamer/bin/gst-inspect-1.0)"; missing=""; for p in libav opencv onnx tflite; do timeout 30 "$gi" "$p" >/dev/null 2>&1 || missing="$missing $p"; done; [ -z "$missing" ] || { echo "MISSING:$missing"; exit 1; }'; then
      pass "GStreamer mandatory plugin set loads on ${target_arch}"
    else
      fail "GStreamer mandatory plugins missing/unloadable on ${target_arch} (see MISSING: line above)"
    fi
    echo ""

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

    # Run the ACTUAL HEALTHCHECK command, not just parse it. Step 4 above only reads
    # the configured Test string; the HC is `/opt/venv/bin/python3 -c import
    # onnxruntime`, so a broken interpreter path or a mislinked onnxruntime leaves
    # the container perpetually `unhealthy` while a string-only check stays green.
    # This runs the real command so that fail-open class can actually fail.
    echo "--- Functional: HEALTHCHECK command executes ---"
    if _rt_run \
         /opt/venv/bin/python3 -c 'import onnxruntime' >/dev/null 2>&1; then
      pass "HEALTHCHECK command runs (import onnxruntime via /opt/venv/bin/python3) (${target_arch})"
    else
      fail "HEALTHCHECK command FAILED (${target_arch}) -- container would report unhealthy"
    fi
    echo ""

    # WebRTC signalling server: start-webrtc-signalling.sh (a shipped entrypoint)
    # execs gst-webrtc-signalling-server. WARN-only -- it belongs to the same
    # gst-plugins-rs/webrtc lane as the known webrtcbin2 gap (backlog), so its
    # absence must not gate the manifest, but a dead signalling entrypoint should be
    # visible every run.
    echo "--- Functional: WebRTC signalling-server binary (informational) ---"
    if _rt_run \
         bash -lc 's="$(command -v gst-webrtc-signalling-server || echo /opt/gstreamer/bin/gst-webrtc-signalling-server)"; [ -x "$s" ] && "$s" --help >/dev/null 2>&1'; then
      echo "  OK  gst-webrtc-signalling-server present + runnable (${target_arch})"
    else
      echo "  WARN gst-webrtc-signalling-server missing/not runnable (${target_arch}) -- WebRTC signalling entrypoint would fail (non-fatal)"
    fi
    echo ""

    # Vulkan loader load test. The .so-closure gate proves libvulkan resolves, but
    # not that the loader dlopen()s at runtime. WARN-only: a headless CI container
    # has no GPU/ICD so device enumeration legitimately finds nothing -- we only
    # assert the loader library itself loads.
    # Three-way verdict instead of blanket WARN (audit round 2): a missing
    # ICD/GPU does NOT stop ctypes.CDLL from loading the loader library — a
    # load failure means the lib is missing/broken, and the runtime image
    # ALWAYS installs the Vulkan runtime files (base-image
    # install-vulkan-runtime-files). Only a container-infra error stays WARN.
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

    # Native compiler compile + link + RUN. The build-time validate-compilers.sh
    # smoke compiles AND links a program in every wrapper image, but never RUNS
    # the result: on the x86_64 build host a cross arch's binary cannot execute,
    # so the shipped native GCC/G++ was only ever ELF/version/link-verified for
    # arm64+riscv64 (the riscv64 --with-isa-spec GCC especially). HERE the wrapper
    # runs under binfmt/qemu, so we can finally prove the on-target compiler
    # actually compiles, links AND executes a real binary. The C++ case also
    # exercises the libstdc++ runtime. Gate RUNTIME_COMPILER_SMOKE=0 to skip.
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

    # Clang/LLVM version alignment on the ACTUAL shipped image, per-arch under
    # qemu. The build-time smoke-toolchain/validate-compilers checks run in the
    # TOOLCHAIN stage where clang and LLVM_RELEASE are consistent by construction;
    # they do NOT catch a STALE toolchain — e.g. a --from-stage media publish that
    # reuses an old cross-sdk whose clang predates a LLVM_RELEASE bump (shipped
    # clang 22.1.2 while versions.env says 22.1.8). Assert the runtime image's
    # clang == LLVM_RELEASE so that drift fails the smoke on every arch. Disable
    # with RUNTIME_CLANG_VERSION_SMOKE=0.
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
  else
    echo "--- Functional checks skipped (RUNTIME_FUNCTIONAL_SMOKE=0) ---"
    echo ""
  fi

  smoke_summary
}

main "$@"
