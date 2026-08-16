#!/usr/bin/env bash
set -euo pipefail

_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${_SCRIPT_DIR}/smoke-common.sh"

echo "=== Media Library Functional Smoke Tests ==="
echo ""

# ---------------------------------------------------------------------------
# ONNX Runtime — import + inference
# ---------------------------------------------------------------------------
echo "--- ONNX Runtime ---"
_ort_lib_dir="${ONNXRUNTIME_OUTPUT_DIR:-/usr/local/lib/onnxruntime-cpu}"
if cross_build_is_active 2>/dev/null; then
  if find "${_ort_lib_dir}" -name "libonnxruntime.so*" -type f 2>/dev/null | grep -q .; then
    pass "onnxruntime library present at ${_ort_lib_dir} (cross build — import skipped)"
  else
    fail "onnxruntime library not found at ${_ort_lib_dir}"
  fi
elif command -v python3 >/dev/null 2>&1; then
  if python3 -c "import onnxruntime" 2>/dev/null; then
    onnx_ver="$(python3 -c "import onnxruntime; print(onnxruntime.__version__)" 2>/dev/null || echo '?')"
    pass "onnxruntime Python module imports (v${onnx_ver})"
    # Functional check that can both pass AND fail: the previous variant fed
    # ort.SessionOptions() to InferenceSession as the model argument (always
    # TypeError) and had no fail branch, so it silently proved nothing.
    if python3 -c "
import sys
import onnxruntime as ort
providers = ort.get_available_providers()
if 'CPUExecutionProvider' not in providers:
    print('CPUExecutionProvider missing, got:', providers, file=sys.stderr)
    sys.exit(1)
" 2>/dev/null; then
      pass "onnxruntime CPUExecutionProvider available"
    else
      fail "onnxruntime CPUExecutionProvider not available (get_available_providers failed or lacks CPU EP)"
    fi
  else
    # Import can legitimately fail in the build sandbox — but then at least
    # PROVE the library exists (the old branch claimed "present" unchecked).
    if find "${_ort_lib_dir}" -name "libonnxruntime.so*" -type f 2>/dev/null | grep -q .; then
      echo "  INFO: onnxruntime present but import fails in build sandbox — functional gate is the runtime smoke"
    else
      fail "onnxruntime import fails AND no libonnxruntime.so under ${_ort_lib_dir}"
    fi
  fi
fi

# ---------------------------------------------------------------------------
# ONNX Runtime GenAI — import check
# ---------------------------------------------------------------------------
echo "--- ONNX Runtime GenAI ---"
if cross_build_is_active 2>/dev/null; then
  # NOT a bare `[ -d ]`: the producer mkdir -p's its output tree on every
  # path, so an existing-but-empty dir is no evidence. Require a real file.
  if find "${ONNXRUNTIME_GENAI_OUTPUT_DIR:-/usr/local/lib/onnxruntime-genai}" /usr/local/lib \
       -name "libonnxruntime*genai*" -type f 2>/dev/null | grep -q .; then
    pass "onnxruntime_genai library present (cross build — import skipped)"
  else
    echo "  INFO: onnxruntime_genai not built for this target (optional)"
  fi
elif command -v python3 >/dev/null 2>&1; then
  if python3 -c "import onnxruntime_genai" 2>/dev/null; then
    pass "onnxruntime_genai Python module imports"
  elif find "${ONNXRUNTIME_GENAI_OUTPUT_DIR:-/usr/local/lib/onnxruntime-genai}" /usr/local/lib \
         -name "libonnxruntime*genai*" -type f 2>/dev/null | grep -q .; then
    # In the MEDIA stage the genai native lib + wheel are produced, but the wheel
    # is only pip-installed into /opt/venv later, at PACKAGING time
    # (assemble-torch-app.sh). System python3 here therefore cannot import it —
    # exactly like plain onnxruntime above (its C libs ship, no wheel installed),
    # which this smoke correctly downgrades to INFO. Mirror that: defer the
    # functional import gate to the runtime torch-venv smoke (smoke-torch-venv.sh),
    # which validates `import onnxruntime_genai` inside /opt/venv. A hard fail here
    # was a false negative (the media stage never installs the genai wheel).
    echo "  INFO: onnxruntime_genai lib present but import fails in build sandbox (wheel installs into /opt/venv at packaging) — functional gate is the runtime torch-venv smoke"
  else
    echo "  INFO: onnxruntime_genai not installed (optional)"
  fi
fi

# ---------------------------------------------------------------------------
# LiteRT — C API shared library check
# ---------------------------------------------------------------------------
echo "--- LiteRT ---"
lite_lib=""
for candidate in \
  /usr/local/lib/libtensorflow-lite.so \
  /usr/local/lib/libtflite.so; do
  if [ -f "${candidate}" ]; then
    lite_lib="${candidate}"
    break
  fi
done
if [ -n "${lite_lib}" ]; then
  pass "LiteRT shared library found: ${lite_lib}"
  # Symbol depth (smoke-depth R7): `[ -f ]` passes on a 12-byte stub. `nm -D`
  # reads foreign-arch ELF fine, so this works on the cross branch too.
  #
  # BUT the TfLite C API (TfLiteInterpreterCreate/TfLiteModelCreate) lives in the
  # SEPARATE C-API library libtensorflowlite_c.so (built by build-litert.sh
  # build_tflite_c_api). ${lite_lib} above is libtensorflow-lite.so, which is the
  # C++ library (a symlink to libLiteRt.so) and LEGITIMATELY exports no C API
  # symbols — checking it was a false negative. Check the C-API lib instead.
  lite_c_lib=""
  for _c in /usr/local/lib/libtensorflowlite_c.so /usr/local/lib/libtensorflowlite_c.so.*; do
    [ -f "${_c}" ] && { lite_c_lib="${_c}"; break; }
  done
  if command -v nm >/dev/null 2>&1; then
    if [ -n "${lite_c_lib}" ]; then
      # Capture nm output to a var FIRST, then match with `case` — NOT
      # `nm | grep -q`. Under `set -o pipefail`, `grep -q` exits on the first
      # match and closes the pipe; nm (still emitting ~130 symbols) then takes
      # SIGPIPE (141), and pipefail reports the whole PIPELINE as failed —
      # turning a successful match into a false "stub/misbuilt" verdict. (The bug
      # is masked when the symbol is ABSENT: grep drains all input, nm never gets
      # SIGPIPE.) Empirically hit 2026-08-10: TfLiteInterpreterCreate@@VERS_1.0 is
      # exported by libtensorflowlite_c.so, yet the old pipeline reported a stub.
      # nm prints versioned names as `TfLiteInterpreterCreate@@VERS_1.0`; the glob
      # substrings match those fine.
      _lite_c_syms="$(nm -D --defined-only "${lite_c_lib}" 2>/dev/null || true)"
      case "${_lite_c_syms}" in
        *TfLiteInterpreterCreate*|*TfLiteModelCreate*)
          pass "LiteRT C API symbols exported by ${lite_c_lib} (TfLiteInterpreterCreate/TfLiteModelCreate)" ;;
        *)
          fail "LiteRT C API lib ${lite_c_lib} exports no TfLite C API symbols (stub/misbuilt)" ;;
      esac
    else
      # C-API lib genuinely absent — real gap for anything linking -ltensorflowlite_c.
      # Soft INFO (not FAIL) to avoid a hard gate on arches where it may not build;
      # the C++ lib above is present, and LiteRT web/python paths do not need it.
      echo "  INFO: LiteRT C-API lib libtensorflowlite_c.so not found (C++ lib present; C API consumers would need it)"
    fi
  fi
else
  echo "  INFO: LiteRT shared library not found (C API may be header-only in this build)"
fi
if [ -d /usr/local/include/tensorflow/lite ]; then
  pass "LiteRT C API headers found"
elif [ -d /usr/local/include/litert ]; then
  pass "LiteRT C API headers found"
else
  echo "  INFO: LiteRT headers not found in standard locations (optional)"
fi

# LiteRT web (WASM/JS) — prebuilt browser runtimes vendored for all arches.
# Validate each .wasm is REAL WebAssembly (4-byte magic \0asm) + a JS loader ships.
# NON-FATAL BY DESIGN: these are OPTIONAL, best-effort-vendored browser assets
# (served to clients, never loaded by the container), and the vendor script itself
# tolerates a registry hiccup. So a shortfall/corruption is SURFACED as WARN for a
# human to fix — it must NOT break the media build (which runs this under set -e).
# Expected counts ($3) are the known-good variant counts; a mismatch (partial vendor
# or an upstream layout change) WARNs rather than fails.
echo "--- LiteRT web (WASM/JS) ---"
_check_web_runtime() {
  local label="$1" dir="$2" expect="${3:-1}"
  local wasm bad=0 n=0 magic
  if [ -z "$(find "${dir}" -name '*.wasm' -print -quit 2>/dev/null)" ]; then
    echo "  INFO: ${label} web assets not found in ${dir} (vendoring may have been skipped)"
    return 0
  fi
  while IFS= read -r wasm; do
    n=$((n + 1))
    magic="$(head -c4 "${wasm}" 2>/dev/null | od -An -tx1 2>/dev/null | tr -d ' \n')"
    [ "${magic}" = "0061736d" ] || { echo "  bad magic (${magic:-empty}) in ${wasm}"; bad=$((bad + 1)); }
  done < <(find "${dir}" -name '*.wasm' 2>/dev/null)
  if find "${dir}" \( -name '*.js' -o -name '*.mjs' \) -print -quit 2>/dev/null | grep -q .; then :; else
    echo "  INFO: ${label} has .wasm but no JS loader alongside"
  fi
  if [ "${bad}" -ne 0 ]; then
    echo "  WARN: ${label} web runtime has ${bad}/${n} corrupt .wasm in ${dir} (optional asset; not gating)"
  elif [ "${n}" -lt "${expect}" ]; then
    echo "  WARN: ${label} web runtime incomplete: ${n}/${expect} expected .wasm in ${dir} (partial vendor / upstream layout change; not gating)"
  else
    pass "${label} web runtime valid (${n} verified .wasm in ${dir})"
  fi
}
# Functional step-up: make the V8 WASM engine (via node) actually COMPILE every
# module's full bytecode — catches body truncation/corruption/invalid-opcode the
# magic check cannot. No shims needed (compile, not instantiate). NON-FATAL: an
# engine rejection WARNs (optional asset; also avoids a hard fail if a future node
# lacks a wasm feature these modules use); absent/no-node is skipped.
_web_wasm_node_compile() {
  local label="$1" dir="$2"
  command -v node >/dev/null 2>&1 || { echo "  INFO: node unavailable; skipping ${label} WASM engine-compile"; return 0; }
  [ -n "$(find "${dir}" -name '*.wasm' -print -quit 2>/dev/null)" ] || return 0
  if WEB_DIR="${dir}" WEB_LABEL="${label}" node <<'NODE_EOF'
const fs = require('fs'), path = require('path');
const dir = process.env.WEB_DIR, label = process.env.WEB_LABEL;
function walk(d){ let o=[]; for(const e of fs.readdirSync(d,{withFileTypes:true})){ const p=path.join(d,e.name); if(e.isDirectory()) o=o.concat(walk(p)); else if(e.name.endsWith('.wasm')) o.push(p);} return o; }
(async () => {
  const ws = walk(dir); let ok=0, bad=0;
  for (const w of ws) {
    try { await WebAssembly.compile(fs.readFileSync(w)); ok++; }
    catch (e) { console.log('  wasm engine-compile FAILED: ' + path.basename(w) + ' :: ' + String(e.message).slice(0,80)); bad++; }
  }
  console.log(`  ${label}: ${ok}/${ws.length} .wasm engine-compiled`);
  process.exit(bad === 0 ? 0 : 1);
})();
NODE_EOF
  then
    pass "${label} WASM engine-compiles in node (V8 accepts every module)"
  else
    echo "  WARN: ${label} has WASM the engine rejects (corrupt module, or a node/V8 that lacks a wasm feature it uses; optional asset, not gating)"
  fi
}

_check_web_runtime "LiteRT.js"  /usr/local/lib/litert-web 4
_web_wasm_node_compile "LiteRT.js" /usr/local/lib/litert-web
_check_web_runtime "LiteRT-LM (mediapipe-genai)" /usr/local/lib/litert-lm-web 3
_web_wasm_node_compile "LiteRT-LM (mediapipe-genai)" /usr/local/lib/litert-lm-web
# onnxruntime-web: compiled once on amd64, shared to all arches. INFO (not FAIL)
# when absent — it is only populated after the amd64 media build in a chain.
echo "--- onnxruntime web (WASM/JS) ---"
_check_web_runtime "onnxruntime-web" /usr/local/lib/onnxruntime-web 3
_web_wasm_node_compile "onnxruntime-web" /usr/local/lib/onnxruntime-web

# ---------------------------------------------------------------------------
# OpenCV — import + functional test
# ---------------------------------------------------------------------------
echo "--- OpenCV ---"
if command -v python3 >/dev/null 2>&1; then
  cv2_pkg="$(find /opt/opencv5 -path "*/site-packages" -type d 2>/dev/null | head -1 || true)"
  if [ -n "${cv2_pkg}" ]; then
    if cross_build_is_active 2>/dev/null; then
      pass "opencv Python bindings present at ${cv2_pkg} (cross build — import skipped)"
    elif ! python3 -c "import numpy" 2>/dev/null; then
      # numpy is a packaging-stage dependency (installed into /opt/venv at
      # packaging), NOT present in the media build sandbox. cv2 cannot import
      # without numpy regardless of cv2's own health, so an import failure here
      # is an environment artifact, not a cv2 defect — defer to the runtime
      # torch-venv smoke (where numpy + cv2 coexist), exactly like the
      # onnxruntime import above. Without this gate, forensic#3's native
      # hard-fail below fired on every full media build (numpy is absent here) —
      # only surfaced now because prior validations were runtime-lane only.
      echo "  INFO: cv2 import needs numpy, absent in the media build sandbox (a /opt/venv packaging dep) — deferred to the runtime torch-venv smoke (functional gate)"
    elif PYTHONPATH="${cv2_pkg}:${PYTHONPATH:-}" python3 -c "import cv2" 2>/dev/null; then
      cv2_ver="$(PYTHONPATH="${cv2_pkg}:${PYTHONPATH:-}" python3 -c "import cv2; print(cv2.__version__)" 2>/dev/null || echo '?')"
      pass "opencv Python module imports (v${cv2_ver})"
      if PYTHONPATH="${cv2_pkg}:${PYTHONPATH:-}" python3 -c "
import cv2
import numpy as np
img = np.zeros((64, 64, 3), dtype=np.uint8)
gray = cv2.cvtColor(img, cv2.COLOR_BGR2GRAY)
assert gray.shape == (64, 64), f'unexpected shape {gray.shape}'
" 2>/dev/null; then
        pass "opencv functional: cvtColor+BGR2GRAY roundtrip OK"
      else
        # import succeeded, so execution demonstrably works here — a failing
        # roundtrip is a real defect, not a sandbox artifact.
        fail "opencv functional: cvtColor+BGR2GRAY roundtrip FAILED (import works, so this is real)"
      fi
      # imencode/imdecode + videoio (smoke-depth R9): videoio has the worst
      # silent-breakage record of any OpenCV module and had ZERO coverage at
      # any layer on Linux.
      if PYTHONPATH="${cv2_pkg}:${PYTHONPATH:-}" python3 -c "
import cv2, numpy as np, tempfile, os
img = np.random.randint(0, 255, (32, 32, 3), dtype=np.uint8)
ok, buf = cv2.imencode('.png', img); assert ok
assert (cv2.imdecode(buf, cv2.IMREAD_COLOR) == img).all(), 'png roundtrip mismatch'
ok, buf = cv2.imencode('.jpg', img); assert ok and cv2.imdecode(buf, 1).shape == img.shape
d = tempfile.mkdtemp(); p = os.path.join(d, 't.avi')
w = cv2.VideoWriter(p, cv2.VideoWriter_fourcc(*'MJPG'), 10, (32, 32))
assert w.isOpened(), 'VideoWriter would not open (videoio backend missing)'
for _ in range(4): w.write(img)
w.release()
c = cv2.VideoCapture(p); assert c.isOpened(), 'VideoCapture would not open'
r, f = c.read(); assert r and f.shape == (32, 32, 3)
" 2>/dev/null; then
        pass "opencv imencode/imdecode + videoio (MJPG write/read) roundtrip OK"
      else
        fail "opencv imencode/videoio roundtrip FAILED (import works, so this is real)"
      fi
    elif cross_build_is_active 2>/dev/null; then
      # CROSS build: the interpreter runs on the amd64 host but cv2 is a
      # foreign-arch extension, so an import failure here is expected — the
      # runtime smoke validates it on-target. Legitimate PASS-with-caveat.
      pass "opencv Python bindings present at ${cv2_pkg} (import skipped: foreign-arch extension under cross build — validated on-target by the runtime smoke)"
    else
      # NATIVE build (forensic#3): the interpreter IS the target arch AND numpy
      # is importable (the elif above already deferred the numpy-absent case), so
      # a cv2 import failure is a REAL defect (missing/broken .so), NOT a sandbox
      # artifact — the old code masked it as an unconditional PASS. Fail loud and
      # surface the actual import error for diagnosis.
      _cv2_import_err="$(PYTHONPATH="${cv2_pkg}:${PYTHONPATH:-}" python3 -c "import cv2" 2>&1 | tail -1)"
      fail "opencv Python bindings FAIL to import on a NATIVE build with numpy present (${_cv2_import_err:-see above}) — real cv2 defect, not a sandbox artifact"
    fi
  else
    echo "  INFO: opencv Python bindings not found in /opt/opencv5"
  fi
fi

# ---------------------------------------------------------------------------
# GStreamer — version + pipeline smoke
# ---------------------------------------------------------------------------
echo "--- GStreamer ---"
_gst_bin="${GSTREAMER_PREFIX:-/opt/gstreamer}/bin"
if command -v gst-inspect-1.0 >/dev/null 2>&1; then
  _gst_inspect="gst-inspect-1.0"
elif [ -x "${_gst_bin}/gst-inspect-1.0" ]; then
  _gst_inspect="${_gst_bin}/gst-inspect-1.0"
else
  _gst_inspect=""
fi
if [ -n "${_gst_inspect}" ]; then
  if cross_build_is_active 2>/dev/null; then
    pass "gst-inspect-1.0 binary present at ${_gst_inspect} (cross build — execution skipped)"
  elif "${_gst_inspect}" --version >/dev/null 2>&1; then
    gst_ver="$("${_gst_inspect}" --version 2>/dev/null | head -1 || echo '?')"
    pass "gst-inspect-1.0 functional: ${gst_ver}"
  else
    # Binary exists but can't execute — likely missing GLIBCXX from source-built GCC
    # in the BuildKit sandbox. Expected during Docker build (ldconfig + ENV land in
    # configure-runtime.sh) — but a broken binary must not count as a PASS: INFO,
    # plus an ELF-magic assertion so corrupt/wrong-format binaries still fail.
    if [ "$(head -c4 "${_gst_inspect}" 2>/dev/null | tail -c3 || true)" = "ELF" ]; then
      echo "  INFO: gst-inspect-1.0 present but not executable in build sandbox — functional gate is the runtime smoke"
    else
      fail "gst-inspect-1.0 at ${_gst_inspect} is not an ELF binary"
    fi
  fi
  if ! cross_build_is_active 2>/dev/null && "${_gst_inspect}" --version >/dev/null 2>&1; then
    _gst_launch="$(command -v gst-launch-1.0 2>/dev/null || echo "${_gst_bin}/gst-launch-1.0")"
    if "${_gst_launch}" videotestsrc num-buffers=1 ! fakesink 2>/dev/null; then
      pass "GStreamer pipeline: videotestsrc ! fakesink OK"
    else
      # gst-inspect --version already executed fine in this environment, so a
      # failing pipeline is a real defect (missing coreelements etc.), not a
      # sandbox artifact.
      fail "GStreamer pipeline videotestsrc ! fakesink FAILED (gst-inspect executes, so this is real)"
    fi
    # Mandatory-plugin gate (smoke-depth R1): meson `enabled` guards CONFIGURE,
    # but a plugin that ships and then fails to dlopen was only a WARN-count.
    # A present-but-unloadable plugin is exactly the observed class
    # (webrtcbin2→librice-proto, gtk4→vkCreateWaylandSurfaceKHR).
    # The `libav` plugin is special: this project's gst-libav links the
    # source-built FFmpeg libav* (incl. libavfilter, which NEEDs the bundled
    # libtensorflow.so.2). Those resolve only once configure-runtime.sh has wired
    # the loader — the SAME reason the ffmpeg binary itself is deferred in the
    # build sandbox below. So gate `libav` on ffmpeg executability HERE: if ffmpeg
    # cannot run in this environment (sandbox), a libav load failure is that same
    # deferral (INFO; re-tested by the packaging-stage smoke, Dockerfile.package,
    # where the loader is wired); if ffmpeg DOES run here but libav still fails,
    # that is a real defect. opencv/onnx/tflite never link ffmpeg, so they stay
    # hard-gated unconditionally.
    _ffmpeg_execok=0
    { _ff_probe="$(command -v ffmpeg 2>/dev/null || echo "${FFMPEG_PREFIX:-/opt/ffmpeg}/bin/ffmpeg")"; \
      [ -x "${_ff_probe}" ] && "${_ff_probe}" -version >/dev/null 2>&1; } && _ffmpeg_execok=1
    _gst_missing=""
    for _p in libav opencv onnx tflite; do
      "${_gst_inspect}" "${_p}" >/dev/null 2>&1 && continue
      if [ "${_p}" = "libav" ] && [ "${_ffmpeg_execok}" = "0" ]; then
        _gst_libav_err="$("${_gst_inspect}" libav 2>&1 >/dev/null | head -1 || true)"
        echo "  INFO: gst 'libav' plugin not loadable in build sandbox (links source-built ffmpeg libav*/libtensorflow; ffmpeg itself non-executable here, loader wired at runtime) — functional gate is the packaging-stage smoke"
        [ -n "${_gst_libav_err}" ] && echo "        detail: ${_gst_libav_err}"
        continue
      fi
      _gst_missing="${_gst_missing} ${_p}"
    done
    if [ -z "${_gst_missing}" ]; then
      pass "GStreamer mandatory plugin set loads (libav opencv onnx tflite)"
    else
      fail "GStreamer mandatory plugins MISSING/unloadable:${_gst_missing}"
    fi
    # Data roundtrip (R2): negotiation + a real encoder + non-empty output —
    # `videotestsrc ! fakesink` proves the registry, not that a buffer with
    # real caps survives convert→encode.
    _gst_tmp="$(mktemp -d)"
    if "${_gst_launch}" -q videotestsrc num-buffers=4 ! video/x-raw,width=64,height=64,framerate=10/1 \
         ! videoconvert ! jpegenc ! multifilesink location="${_gst_tmp}/f%d.jpg" 2>/dev/null \
       && [ "$(find "${_gst_tmp}" -name 'f*.jpg' -size +0c 2>/dev/null | wc -l)" -eq 4 ]; then
      pass "GStreamer data roundtrip: 4 real JPEG frames out of videoconvert!jpegenc"
    else
      fail "GStreamer data roundtrip FAILED (caps negotiation or jpegenc broken)"
    fi
    rm -rf "${_gst_tmp}"
  fi
else
  fail "gst-inspect-1.0 not found (checked PATH and ${_gst_bin})"
fi

# ---------------------------------------------------------------------------
# FFmpeg — version + encode/decode roundtrip
# ---------------------------------------------------------------------------
echo "--- FFmpeg ---"
_ffmpeg_bin="$(command -v ffmpeg 2>/dev/null || echo "${FFMPEG_PREFIX:-/opt/ffmpeg}/bin/ffmpeg")"
if [ -x "${_ffmpeg_bin}" ]; then
  if cross_build_is_active 2>/dev/null; then
    pass "ffmpeg binary present at ${_ffmpeg_bin} (cross build — execution skipped)"
  else
    ffmpeg_ver="$("${_ffmpeg_bin}" -version 2>/dev/null | head -1 || echo '?')"
    if [ "${ffmpeg_ver}" != "?" ]; then
      pass "ffmpeg functional: ${ffmpeg_ver}"
    else
      # Execution can legitimately fail here (ldconfig/ENV land later in
      # configure-runtime.sh) — but a broken binary must not count as a PASS.
      # Downgrade to INFO and at least assert it is a real ELF, so a
      # zero-byte/corrupt/wrong-format ffmpeg still fails the smoke.
      if [ "$(head -c4 "${_ffmpeg_bin}" 2>/dev/null | tail -c3 || true)" = "ELF" ]; then
        echo "  INFO: ffmpeg present but not executable in build sandbox (ld paths land in configure-runtime) — functional gate is the runtime smoke"
      else
        fail "ffmpeg at ${_ffmpeg_bin} is not an ELF binary"
      fi
    fi
    tmpdir="$(mktemp -d)"
    if "${_ffmpeg_bin}" -y -f lavfi -i "testsrc=duration=1:size=32x32:rate=1" \
         -c:v libx264 -preset ultrafast \
         "${tmpdir}/smoke.mp4" 2>/dev/null; then
      pass "ffmpeg H.264 encode OK"
      if "${_ffmpeg_bin}" -y -i "${tmpdir}/smoke.mp4" -f null /dev/null 2>/dev/null; then
        pass "ffmpeg H.264 decode OK"
      else
        fail "ffmpeg H.264 decode failed"
      fi
    elif [ "${ffmpeg_ver}" != "?" ] \
         && "${_ffmpeg_bin}" -hide_banner -encoders 2>/dev/null | grep -q libx264; then
      # ffmpeg executes AND advertises libx264 — a failed encode is real.
      fail "ffmpeg H.264 encode FAILED (binary executes and libx264 encoder is advertised)"
    else
      echo "  INFO: ffmpeg encode test skipped (binary not executable here, or libx264 not built)"
    fi
    # Codec depth beyond H.264 (smoke-depth R4) — only when the binary
    # demonstrably executes. build-ffmpeg.sh probe-gates every --enable-*: a
    # probe that silently misses DROPS the codec and the build stays green,
    # so buildconf-vs-registration consistency is the cheap honest gate...
    if [ "${ffmpeg_ver}" != "?" ]; then
      _ff_bc="$("${_ffmpeg_bin}" -hide_banner -buildconf 2>/dev/null || true)"
      for _c in libx265 libdav1d libsvtav1 libvpx libopus; do
        case "${_ff_bc}" in
          *"--enable-${_c}"*)
            if "${_ffmpeg_bin}" -hide_banner -encoders 2>/dev/null | grep -q "${_c#lib}" \
               || "${_ffmpeg_bin}" -hide_banner -decoders 2>/dev/null | grep -q "${_c#lib}"; then
              pass "ffmpeg ${_c}: enabled in buildconf and registered"
            else
              fail "ffmpeg buildconf claims --enable-${_c} but no matching codec registered"
            fi ;;
        esac
      done
      # ...and a real per-codec encode+decode roundtrip (32x32, 2 frames —
      # sub-second each) proves the codepath, not just the registry.
      for _spec in libx265 libvpx-vp9; do
        "${_ffmpeg_bin}" -hide_banner -h "encoder=${_spec}" >/dev/null 2>&1 || continue
        _ff_tmp="$(mktemp -d)"
        if "${_ffmpeg_bin}" -y -f lavfi -i "testsrc=duration=1:size=32x32:rate=2" \
             -c:v "${_spec}" "${_ff_tmp}/s.mkv" 2>/dev/null \
           && "${_ffmpeg_bin}" -y -i "${_ff_tmp}/s.mkv" -f null /dev/null 2>/dev/null; then
          pass "ffmpeg ${_spec} encode+decode roundtrip OK"
        else
          fail "ffmpeg ${_spec} is advertised but the encode/decode roundtrip FAILED"
        fi
        rm -rf "${_ff_tmp}"
      done
    fi
    rm -rf "${tmpdir}"
  fi
else
  fail "ffmpeg not found (checked PATH and ${FFMPEG_PREFIX:-/opt/ffmpeg}/bin)"
fi

# ---------------------------------------------------------------------------
# libcamera — pkg-config + cam binary
# ---------------------------------------------------------------------------
echo "--- libcamera ---"
_lc_prefix="${LIBCAMERA_PREFIX:-/opt/libcamera}"
# Ensure pkg-config can find libcamera
export PKG_CONFIG_PATH="${_lc_prefix}/lib/pkgconfig:${_lc_prefix}/lib64/pkgconfig:${PKG_CONFIG_PATH:-}"
if command -v pkg-config >/dev/null 2>&1; then
  if pkg-config --exists libcamera 2>/dev/null; then
    lc_ver="$(pkg-config --modversion libcamera 2>/dev/null || echo '?')"
    pass "libcamera found via pkg-config (v${lc_ver})"
  else
    echo "  INFO: libcamera not in pkg-config path (optional)"
  fi
fi
_cam_bin="$(command -v cam 2>/dev/null || echo "${_lc_prefix}/bin/cam")"
if [ -x "${_cam_bin}" ]; then
  if cross_build_is_active 2>/dev/null; then
    pass "cam binary present at ${_cam_bin} (cross build — execution skipped)"
  elif "${_cam_bin}" --help 2>/dev/null | head -1 | grep -q .; then
    pass "cam binary functional"
  else
    echo "  INFO: cam binary found but --help failed (expected without camera hardware)"
  fi
elif command -v lc-compliance >/dev/null 2>&1; then
  pass "lc-compliance binary found"
else
  echo "  INFO: no libcamera CLI tool found (checked PATH and ${_lc_prefix}/bin)"
fi

# ---------------------------------------------------------------------------
# GCC
# ---------------------------------------------------------------------------
echo "--- GCC ---"
if command -v gcc >/dev/null 2>&1; then
  gcc_ver="$(gcc --version 2>/dev/null | head -1 || echo '?')"
  pass "gcc functional: ${gcc_ver}"
else
  fail "gcc not found"
fi

# ---------------------------------------------------------------------------
# Clang
# ---------------------------------------------------------------------------
echo "--- Clang ---"
if command -v clang >/dev/null 2>&1; then
  clang_ver="$(clang --version 2>/dev/null | head -1 || echo '?')"
  pass "clang functional: ${clang_ver}"
else
  fail "clang not found"
fi

# ---------------------------------------------------------------------------
# CUDA (optional)
# ---------------------------------------------------------------------------
echo "--- CUDA (optional) ---"
if command -v nvcc >/dev/null 2>&1; then
  cuda_ver="$(nvcc --version 2>/dev/null | grep "release" | head -1 || echo '?')"
  pass "nvcc functional: ${cuda_ver}"
  # Device-less kernel compile (smoke-depth R11): version output proves the
  # frontend runs; compiling a __global__ kernel proves the full toolchain
  # (cudafe, ptxas, host compiler handshake) — no GPU needed.
  _cu_tmp="$(mktemp -d)"
  printf '__global__ void k(int*o){*o=42;}\nint main(){return 0;}\n' > "${_cu_tmp}/t.cu"
  if nvcc -std=c++17 -c "${_cu_tmp}/t.cu" -o "${_cu_tmp}/t.o" 2>"${_cu_tmp}/e"; then
    pass "nvcc compiles a __global__ kernel (device-less)"
  else
    fail "nvcc present but cannot compile a trivial kernel: $(tail -1 "${_cu_tmp}/e" 2>/dev/null || true)"
  fi
  rm -rf "${_cu_tmp}"
elif [ "${ENABLE_NVIDIA:-false}" = "true" ]; then
  # The old check was fail-open: a GPU image that LOST nvcc passed silently.
  fail "ENABLE_NVIDIA=true but nvcc is not on PATH"
fi

# ---------------------------------------------------------------------------
# Torch
# ---------------------------------------------------------------------------
echo "--- Torch ---"
# In the MEDIA stage torch is genuinely absent (installed later) — but this
# script ALSO runs in the package wrapper-smoke, where /opt/venv is mandatory.
# The old hardcoded "not installed" INFO was false there (smoke-depth R16b).
if [ -x /opt/venv/bin/python ]; then
  if /opt/venv/bin/python -c "import torch" 2>/dev/null; then
    pass "torch imports from /opt/venv ($(/opt/venv/bin/python -c 'import torch; print(torch.__version__)' 2>/dev/null || echo '?'))"
  elif [ -f /opt/venv/.torch-missing ]; then
    echo "  INFO: torch-less venv (documented .torch-missing sentinel present)"
  else
    fail "/opt/venv exists but torch does not import and no .torch-missing sentinel"
  fi
else
  echo "  INFO: torch not installed (only in :latest-cross-<arch> wrappers)"
fi

echo ""
smoke_summary
