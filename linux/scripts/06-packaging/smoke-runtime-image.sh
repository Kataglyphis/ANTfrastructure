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
  if "${NERDCTL_BIN}" run --rm --platform "linux/${target_arch}" "${image_tag}" /bin/true 2>/dev/null; then
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
  if "${NERDCTL_BIN}" run --rm --platform "linux/${target_arch}" "${image_tag}" id -u kataglyphis >/dev/null 2>&1; then
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
    if "${NERDCTL_BIN}" run --rm --platform "linux/${target_arch}" "${image_tag}" \
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
      if "${NERDCTL_BIN}" run --rm --platform "linux/${target_arch}" "${image_tag}" \
           /opt/venv/bin/python -m orchestr_ant_ion.smoke; then
        pass "app wheel smoke passed on-target (${target_arch})"
      else
        fail "app wheel smoke FAILED in the runtime image (${target_arch})"
      fi
    else
      echo "--- Functional: ML imports (torch-less image) ---"
      if "${NERDCTL_BIN}" run --rm --platform "linux/${target_arch}" "${image_tag}" \
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
      if "${NERDCTL_BIN}" run --rm --platform "linux/${target_arch}" "${image_tag}" \
           bash -lc 'STV_ASSERT_ONLY=1 STV_CV2_REQUIRED=0 bash /opt/scripts/packaging/smoke-torch-venv.sh'; then
        pass "ML-stack versions match pins (${target_arch})"
      else
        fail "ML-stack version-pin assertion FAILED in the runtime image (${target_arch})"
      fi
      echo ""
    fi

    echo "--- Functional: ffmpeg ---"
    # pipefail is REQUIRED: without it, `ffmpeg -version | head -1` returns head's
    # exit (0), so a broken binary -- e.g. `error while loading shared libraries:
    # libopencore-amrwb.so.0` (observed 2026-07-11) -- silently PASSES. With
    # pipefail the missing-.so exit code propagates and the smoke fails as it must.
    if "${NERDCTL_BIN}" run --rm --platform "linux/${target_arch}" "${image_tag}" \
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
    if "${NERDCTL_BIN}" run --rm --platform "linux/${target_arch}" "${image_tag}" \
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
    "${NERDCTL_BIN}" run --rm --platform "linux/${target_arch}" "${image_tag}" \
      bash -lc 'g=0
while IFS= read -r p; do
  ldd "$p" 2>/dev/null | grep -q "=> not found" && { g=$((g+1)); printf "  degraded: %s -> %s\n" "$(basename "$p")" "$(ldd "$p" 2>/dev/null | awk "/not found/{print \$1}" | tr "\n" " ")"; }
done < <(find /opt/gstreamer -path "*gstreamer-1.0/*.so" 2>/dev/null | head -300)
echo "  GStreamer plugins that cannot load: ${g} (non-fatal)"' 2>/dev/null || true
    echo ""

    # (onnxruntime inference + cv2 encode/decode roundtrip now live in the app
    # wheel smoke above -- `python -m orchestr_ant_ion.smoke` runs the same
    # embedded Add model and the same imencode/imdecode round-trip on-target.)

    echo "--- Functional: GStreamer core pipeline ---"
    if "${NERDCTL_BIN}" run --rm --platform "linux/${target_arch}" "${image_tag}" \
         bash -lc 'gl="$(command -v gst-launch-1.0 || echo /opt/gstreamer/bin/gst-launch-1.0)"; timeout 40 "$gl" -q videotestsrc num-buffers=3 ! videoconvert ! fakesink'; then
      pass "GStreamer core pipeline runs (${target_arch})"
    else
      fail "GStreamer core pipeline FAILED (${target_arch})"
    fi
    echo ""

    echo "--- Functional: application import ---"
    # The actual deliverable: the Orchestr-ANT-ion app must import in the shipped
    # venv. A broken/incomplete app install (missing runtime dep) shipped silently
    # before -- import it through the venv python to catch that.
    if "${NERDCTL_BIN}" run --rm --platform "linux/${target_arch}" "${image_tag}" \
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
    if "${NERDCTL_BIN}" run --rm --platform "linux/${target_arch}" "${image_tag}" \
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
    if "${NERDCTL_BIN}" run --rm --platform "linux/${target_arch}" "${image_tag}" \
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
    echo "--- Functional: Vulkan loader (informational) ---"
    if "${NERDCTL_BIN}" run --rm --platform "linux/${target_arch}" "${image_tag}" \
         /opt/venv/bin/python -c 'import ctypes; ctypes.CDLL("libvulkan.so.1")' >/dev/null 2>&1; then
      echo "  OK  libvulkan.so.1 loads (${target_arch})"
    else
      echo "  WARN libvulkan.so.1 did not load (${target_arch}) -- non-fatal (no ICD/GPU in CI)"
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
      if "${NERDCTL_BIN}" run --rm --platform "linux/${target_arch}" "${image_tag}" \
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
  else
    echo "--- Functional checks skipped (RUNTIME_FUNCTIONAL_SMOKE=0) ---"
    echo ""
  fi

  smoke_summary
}

main "$@"
