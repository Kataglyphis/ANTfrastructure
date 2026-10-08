#!/usr/bin/env bash
set -euo pipefail

_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${_SCRIPT_DIR}/smoke-common.sh"

echo "=== Media Library Functional Smoke Tests ==="
echo ""

# ONNX Runtime: import and inference
echo "--- ONNX Runtime ---"
_ort_lib_dir="${ONNXRUNTIME_OUTPUT_DIR:-/usr/local/lib/onnxruntime-cpu}"
if cross_build_is_active 2>/dev/null; then
  if find "${_ort_lib_dir}" -name "libonnxruntime.so*" -type f 2>/dev/null | grep -q .; then
    # Called for its message; `|| fail` makes an impossible decline loud instead of a silent set -e exit.
    smoke_cross_presence_gate "onnxruntime" "${_ort_lib_dir}" "library" "import" \
      || fail "onnxruntime presence gate declined inside the cross branch (BUILD_MODE/TARGET_ARCH changed mid-script?)"
  else
    fail "onnxruntime library not found at ${_ort_lib_dir}"
  fi
elif command -v python3 >/dev/null 2>&1; then
  if python3 -c "import onnxruntime" 2>/dev/null; then
    onnx_ver="$(python3 -c "import onnxruntime; print(onnxruntime.__version__)" 2>/dev/null || echo '?')"
    pass "onnxruntime Python module imports (v${onnx_ver})"
    # A check that can both pass and fail.
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
    # Import may fail in the build sandbox, but the library must exist.
    if find "${_ort_lib_dir}" -name "libonnxruntime.so*" -type f 2>/dev/null | grep -q .; then
      echo "  INFO: onnxruntime present but import fails in build sandbox — functional gate is the runtime smoke"
    else
      fail "onnxruntime import fails AND no libonnxruntime.so under ${_ort_lib_dir}"
    fi
  fi
fi

# ONNX Runtime GenAI: import check
echo "--- ONNX Runtime GenAI ---"
if cross_build_is_active 2>/dev/null; then
  # The producer creates its dirs on every path, so require a real file.
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
    # The wheel reaches /opt/venv only at packaging; smoke-torch-venv.sh gates the import there.
    echo "  INFO: onnxruntime_genai lib present but import fails in build sandbox (wheel installs into /opt/venv at packaging) — functional gate is the runtime torch-venv smoke"
  else
    echo "  INFO: onnxruntime_genai not installed (optional)"
  fi
fi

# LiteRT: C API shared library check
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
  # Symbols, not `[ -f ]`: the C API is in libtensorflowlite_c.so, not the C++ lib; nm -D reads foreign ELF too.
  lite_c_lib=""
  for _c in /usr/local/lib/libtensorflowlite_c.so /usr/local/lib/libtensorflowlite_c.so.*; do
    [ -f "${_c}" ] && { lite_c_lib="${_c}"; break; }
  done
  if command -v nm >/dev/null 2>&1; then
    if [ -n "${lite_c_lib}" ]; then
      # Capture, then case: under pipefail `nm | grep -q` turns nm's SIGPIPE into a false "stub" verdict.
      _lite_c_syms="$(nm -D --defined-only "${lite_c_lib}" 2>/dev/null || true)"
      case "${_lite_c_syms}" in
        *TfLiteInterpreterCreate*|*TfLiteModelCreate*)
          pass "LiteRT C API symbols exported by ${lite_c_lib} (TfLiteInterpreterCreate/TfLiteModelCreate)" ;;
        *)
          fail "LiteRT C API lib ${lite_c_lib} exports no TfLite C API symbols (stub/misbuilt)" ;;
      esac
    else
      # INFO, not FAIL: it may not build on every arch, and the web/python paths need no C API.
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

# Browser assets the container never loads: real WASM magic plus a JS loader, and a shortfall only WARNs.
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
# node compiles every module's bytecode, catching corruption the magic check cannot; a rejection only WARNs.
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
# onnxruntime-web comes from the amd64 media build, so it is absent until that has run.
echo "--- onnxruntime web (WASM/JS) ---"
_check_web_runtime "onnxruntime-web" /usr/local/lib/onnxruntime-web 3
_web_wasm_node_compile "onnxruntime-web" /usr/local/lib/onnxruntime-web

# OpenCV: import and functional test
echo "--- OpenCV ---"
if command -v python3 >/dev/null 2>&1; then
  cv2_pkg="$(find /opt/opencv5 -path "*/site-packages" -type d 2>/dev/null | head -1 || true)"
  if [ -n "${cv2_pkg}" ]; then
    if smoke_cross_presence_gate "opencv" "${cv2_pkg}" "Python bindings" "import"; then
      :   # presence proven by the gate; the import half is deliberately skipped
    elif ! python3 -c "import numpy" 2>/dev/null; then
      # numpy arrives only at packaging, so cv2 cannot import here; the torch-venv smoke gates it.
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
        # The import worked, so a failing roundtrip is a real defect.
        fail "opencv functional: cvtColor+BGR2GRAY roundtrip FAILED (import works, so this is real)"
      fi
      # videoio has the worst silent-breakage record of any OpenCV module.
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
      # Cross arches are headless by design (pango is not multiarch-coinstallable); assert that deliberate state.
      _ocv_gui="$(PYTHONPATH="${cv2_pkg}:${PYTHONPATH:-}" python3 -c "
import cv2
for line in cv2.getBuildInformation().splitlines():
    if line.strip().startswith('GUI:'):
        print(line.strip())
        break
" 2>/dev/null || true)"
      if [ -n "${_ocv_gui}" ]; then
        case "${_ocv_gui}" in
          *GTK*) pass "opencv GUI backend: GTK (amd64 expected)" ;;
          *NONE*)
            if cross_build_is_active 2>/dev/null; then
              pass "opencv GUI backend: NONE (cross arch — headless by design, LOG21)"
            else
              fail "opencv GUI backend is NONE on a NATIVE build (GTK dev packages missing?)"
            fi
            ;;
          *) pass "opencv GUI backend: ${_ocv_gui}" ;;
        esac
      fi
      # TBB, not the pthreads fallback a missed probe leaves behind.
      _ocv_pf="$(PYTHONPATH="${cv2_pkg}:${PYTHONPATH:-}" python3 -c "
import cv2
for line in cv2.getBuildInformation().splitlines():
    if 'Parallel framework' in line:
        print(line.strip())
        break
" 2>/dev/null || true)"
      if [ -n "${_ocv_pf}" ]; then
        case "${_ocv_pf}" in
          *TBB*) pass "opencv parallel framework: TBB" ;;
          *)     fail "opencv parallel framework is NOT TBB (got: ${_ocv_pf})" ;;
        esac
      fi
      # cv2.dnn must see the ONNX Runtime the image ships.
      if PYTHONPATH="${cv2_pkg}:${PYTHONPATH:-}" python3 -c "
import cv2
backends = cv2.dnn.getAvailableBackends()
targets = cv2.dnn.getAvailableTargets()
# OpenCV 5.x maps the ORT backend to 'ONNXRuntime' or 'ORT'
if not any('onnx' in str(b).lower() or 'ort' in str(b).lower() for b in backends):
    print('ORT backend missing, got:', backends, file=__import__('sys').stderr)
    exit(1)
" 2>/dev/null; then
        pass "opencv DNN ONNX Runtime backend available"
      else
        fail "opencv DNN ONNX Runtime backend NOT available (WITH_ONNXRUNTIME=ON may have missed)"
      fi
    elif cross_build_is_active 2>/dev/null; then
      # Cross: cv2 is a foreign-arch extension; the runtime smoke imports it on-target.
      pass "opencv Python bindings present at ${cv2_pkg} (import skipped: foreign-arch extension under cross build — validated on-target by the runtime smoke)"
    else
      # Native with numpy present: an import failure is a real defect, so name its error.
      _cv2_import_err="$(PYTHONPATH="${cv2_pkg}:${PYTHONPATH:-}" python3 -c "import cv2" 2>&1 | tail -1)"
      fail "opencv Python bindings FAIL to import on a NATIVE build with numpy present (${_cv2_import_err:-see above}) — real cv2 defect, not a sandbox artifact"
    fi
  else
    echo "  INFO: opencv Python bindings not found in /opt/opencv5"
  fi
fi

# GStreamer: version and pipeline smoke
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
  if smoke_cross_presence_gate "gst-inspect-1.0" "${_gst_inspect}"; then
    :   # presence proven by the gate; execution is deliberately skipped
  elif "${_gst_inspect}" --version >/dev/null 2>&1; then
    gst_ver="$("${_gst_inspect}" --version 2>/dev/null | head -1 || echo '?')"
    pass "gst-inspect-1.0 functional: ${gst_ver}"
  else
    # Not runnable in the sandbox until configure-runtime.sh; INFO, but a non-ELF still fails.
    smoke_deferred_if_elf "gst-inspect-1.0" "${_gst_inspect}" \
      "gst-inspect-1.0 present but not executable in build sandbox — functional gate is the runtime smoke"
  fi
  if ! cross_build_is_active 2>/dev/null && "${_gst_inspect}" --version >/dev/null 2>&1; then
    _gst_launch="$(smoke_resolve_bin gst-launch-1.0 "${_gst_bin}/gst-launch-1.0")"
    if "${_gst_launch}" videotestsrc num-buffers=1 ! fakesink 2>/dev/null; then
      pass "GStreamer pipeline: videotestsrc ! fakesink OK"
    else
      # gst-inspect ran here, so a failing pipeline is a real defect.
      fail "GStreamer pipeline videotestsrc ! fakesink FAILED (gst-inspect executes, so this is real)"
    fi
    # See docs/cross-build-verification.md § smoke-media: the mandatory-plugin gate and its build-sandbox deferrals
    _ffmpeg_execok=0
    { _ff_probe="$(smoke_resolve_bin ffmpeg "${FFMPEG_PREFIX:-/opt/ffmpeg}/bin/ffmpeg")"; \
      [ -x "${_ff_probe}" ] && "${_ff_probe}" -version >/dev/null 2>&1; } && _ffmpeg_execok=1
    _gst_missing=""
    _gst_loaded=""
    _gst_deferred=""
    for _p in libav opencv onnx tflite; do
      if "${_gst_inspect}" "${_p}" >/dev/null 2>&1; then
        _gst_loaded="${_gst_loaded} ${_p}"
        continue
      fi
      if [ "${_ffmpeg_execok}" = "0" ]; then
        _gst_err="$("${_gst_inspect}" "${_p}" 2>&1 >/dev/null | head -1 || true)"
        echo "  INFO: gst '${_p}' plugin not loadable in build sandbox (transitive dep on source-built libs not on the runtime loader path; ffmpeg non-executable here too) — functional gate is the packaging-stage smoke"
        [ -n "${_gst_err}" ] && echo "        detail: ${_gst_err}"
        _gst_deferred="${_gst_deferred} ${_p}"
        continue
      fi
      _gst_missing="${_gst_missing} ${_p}"
    done
    # Name only what loaded; deferred plugins are listed apart.
    if [ -n "${_gst_missing}" ]; then
      fail "GStreamer mandatory plugins MISSING/unloadable:${_gst_missing}"
    elif [ -n "${_gst_loaded}" ]; then
      pass "GStreamer mandatory plugins load:${_gst_loaded}${_gst_deferred:+ (deferred to packaging-stage smoke:${_gst_deferred})}"
    else
      echo "  INFO: every mandatory GStreamer plugin was deferred to the packaging-stage smoke:${_gst_deferred} — nothing verified here"
    fi
    # fakesink proves the registry; this proves real caps survive convert and encode.
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

# FFmpeg: version and encode/decode roundtrip
echo "--- FFmpeg ---"
_ffmpeg_bin="$(smoke_resolve_bin ffmpeg "${FFMPEG_PREFIX:-/opt/ffmpeg}/bin/ffmpeg")"
if [ -x "${_ffmpeg_bin}" ]; then
  if smoke_cross_presence_gate "ffmpeg" "${_ffmpeg_bin}"; then
    :   # presence proven by the gate; execution is deliberately skipped
  else
    ffmpeg_ver="$("${_ffmpeg_bin}" -version 2>/dev/null | head -1 || echo '?')"
    if [ "${ffmpeg_ver}" != "?" ]; then
      pass "ffmpeg functional: ${ffmpeg_ver}"
    else
      # Not runnable here until configure-runtime.sh; INFO, but a non-ELF still fails.
      smoke_deferred_if_elf "ffmpeg" "${_ffmpeg_bin}" \
        "ffmpeg present but not executable in build sandbox (ld paths land in configure-runtime) — functional gate is the runtime smoke"
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
         && grep -q libx264 <<<"$("${_ffmpeg_bin}" -hide_banner -encoders 2>/dev/null || true)"; then
      # ffmpeg executes AND advertises libx264 — a failed encode is real.
      fail "ffmpeg H.264 encode FAILED (binary executes and libx264 encoder is advertised)"
    else
      echo "  INFO: ffmpeg encode test skipped (binary not executable here, or libx264 not built)"
    fi
    # build-ffmpeg.sh probe-gates every --enable-*, and a missed probe drops the codec silently.
    if [ "${ffmpeg_ver}" != "?" ]; then
      _ff_bc="$("${_ffmpeg_bin}" -hide_banner -buildconf 2>/dev/null || true)"
      # Captured once: under pipefail `ffmpeg -encoders | grep -q` reads ffmpeg's SIGPIPE as "not registered".
      _ff_codecs="$("${_ffmpeg_bin}" -hide_banner -encoders 2>/dev/null || true)
$("${_ffmpeg_bin}" -hide_banner -decoders 2>/dev/null || true)"
      _ff_filters="$("${_ffmpeg_bin}" -hide_banner -filters 2>/dev/null || true)"
      for _c in libx265 libdav1d libsvtav1 libvpx libopus libvvdec; do
        case "${_ff_bc}" in
          *"--enable-${_c}"*)
            if grep -q "${_c#lib}" <<<"${_ff_codecs}"; then
              pass "ffmpeg ${_c}: enabled in buildconf and registered"
            else
              fail "ffmpeg buildconf claims --enable-${_c} but no matching codec registered"
            fi ;;
        esac
      done
      # A real roundtrip per codec proves the codepath, not just the registry.
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
      # drawtext needs three probe-gated libraries; assert the filter is registered, not the buildconf.
      if grep -q "drawtext" <<<"${_ff_filters}"; then
        pass "ffmpeg drawtext filter registered"
      else
        fail "ffmpeg drawtext filter NOT registered (libfreetype/libharfbuzz/libfontconfig probe may have missed)"
      fi
      # The *_vulkan filters also need glslangValidator at build time.
      if grep -q "scale_vulkan" <<<"${_ff_filters}"; then
        pass "ffmpeg scale_vulkan filter registered"
      else
        fail "ffmpeg scale_vulkan filter NOT registered (glslangValidator may have been missing at build time)"
      fi
    fi
    rm -rf "${tmpdir}"
  fi
else
  fail "ffmpeg not found (checked PATH and ${FFMPEG_PREFIX:-/opt/ffmpeg}/bin)"
fi

# libcamera: pkg-config and cam binary
echo "--- libcamera ---"
_lc_prefix="${LIBCAMERA_PREFIX:-/opt/libcamera}"
# Native meson installs under lib/<triplet>/pkgconfig, cross under plain lib.
_lc_pc="$(find "${_lc_prefix}/lib" "${_lc_prefix}/lib64" -name libcamera.pc -type f -print -quit 2>/dev/null || true)"
export PKG_CONFIG_PATH="${_lc_pc:+$(dirname "${_lc_pc}"):}${_lc_prefix}/lib/pkgconfig:${_lc_prefix}/lib64/pkgconfig:${PKG_CONFIG_PATH:-}"
if command -v pkg-config >/dev/null 2>&1; then
  if pkg-config --exists libcamera 2>/dev/null; then
    lc_ver="$(pkg-config --modversion libcamera 2>/dev/null || echo '?')"
    pass "libcamera found via pkg-config (v${lc_ver})"
  else
    echo "  INFO: libcamera not in pkg-config path (optional)"
  fi
fi
_cam_bin="$(smoke_resolve_bin cam "${_lc_prefix}/bin/cam")"
if [ -x "${_cam_bin}" ]; then
  if smoke_cross_presence_gate "cam" "${_cam_bin}"; then
    :   # presence proven by the gate; execution is deliberately skipped
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

# GCC
echo "--- GCC ---"
if command -v gcc >/dev/null 2>&1; then
  gcc_ver="$(gcc --version 2>/dev/null | head -1 || echo '?')"
  pass "gcc functional: ${gcc_ver}"
else
  fail "gcc not found"
fi

# Clang
echo "--- Clang ---"
if command -v clang >/dev/null 2>&1; then
  clang_ver="$(clang --version 2>/dev/null | head -1 || echo '?')"
  pass "clang functional: ${clang_ver}"
else
  fail "clang not found"
fi

# CMake
echo "--- CMake ---"
_cmake_bin="$(smoke_resolve_bin cmake /opt/cmake/bin/cmake)"
if [ -x "${_cmake_bin}" ]; then
  _cmake_ver="$("${_cmake_bin}" --version 2>/dev/null | head -1 || echo '?')"
  if [ "${_cmake_ver}" != "?" ]; then
    pass "cmake functional: ${_cmake_ver}"
  else
    fail "cmake at ${_cmake_bin} exists but --version failed"
  fi
else
  fail "cmake not found (checked PATH and /opt/cmake/bin/cmake)"
fi

# CUDA (optional)
echo "--- CUDA (optional) ---"
if command -v nvcc >/dev/null 2>&1; then
  cuda_ver="$(nvcc --version 2>/dev/null | grep "release" | head -1 || echo '?')"
  pass "nvcc functional: ${cuda_ver}"
  # A __global__ kernel proves cudafe, ptxas and the host compiler, with no GPU.
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

# Vulkan SDK: header, active link, glslangValidator
echo "--- Vulkan SDK ---"
_vk_root="${VULKAN_SDK_ROOT:-/opt/vulkan}"
if [ -d "${_vk_root}" ]; then
  # 1. The SDK installs two levels deep (/opt/vulkan/<version>/<arch>/).
  _vk_inc=""
  for _cand in "${_vk_root}/active/include" "${_vk_root}"/*/include "${_vk_root}"/*/*/include; do
    [ -f "${_cand}/vulkan/vulkan.h" ] && { _vk_inc="${_cand}"; break; }
  done
  if [ -n "${_vk_inc}" ]; then
    pass "vulkan/vulkan.h found at ${_vk_inc}"
  else
    fail "vulkan/vulkan.h not found under ${_vk_root}"
  fi
  # 2. The installer creates no active link, so a versioned archdir also counts.
  if [ -L "${_vk_root}/active" ] || [ -d "${_vk_root}/active" ]; then
    pass "Vulkan active link resolves: ${_vk_root}/active"
  elif [ -n "${_vk_inc}" ]; then
    pass "Vulkan SDK versioned directory found (no active symlink; archdir present)"
  else
    fail "Vulkan active link not found at ${_vk_root}/active and no versioned archdir"
  fi
  # 3. glslangValidator runs (host binary — works on all arches in the build sandbox)
  _vk_glslang=""
  for _cand in "${_vk_root}/active/bin/glslangValidator" "${_vk_root}"/*/bin/glslangValidator "${_vk_root}"/*/*/bin/glslangValidator; do
    [ -x "${_cand}" ] && { _vk_glslang="${_cand}"; break; }
  done
  if [ -n "${_vk_glslang}" ]; then
    if "${_vk_glslang}" --version >/dev/null 2>&1; then
      pass "glslangValidator functional: ${_vk_glslang}"
    else
      fail "glslangValidator found but --version failed: ${_vk_glslang}"
    fi
  else
    fail "glslangValidator not found under ${_vk_root}"
  fi
else
  echo "  INFO: Vulkan SDK not found at ${_vk_root} (optional in some images)"
fi

# Torch
echo "--- Torch ---"
# Absent in the media stage, but this also runs in the package wrapper smoke, where /opt/venv is mandatory.
if [ -x /opt/venv/bin/python ]; then
  if /opt/venv/bin/python -c "import torch" 2>/dev/null; then
    pass "torch imports from /opt/venv ($(/opt/venv/bin/python -c 'import torch; print(torch.__version__)' 2>/dev/null || echo '?'))"
  elif [ -f /opt/venv/.torch-missing ]; then
    echo "  INFO: torch-less venv (documented .torch-missing sentinel present)"
  else
    fail "/opt/venv exists but torch does not import and no .torch-missing sentinel"
  fi
else
  echo "  INFO: torch not installed (only in :latest-<arch> wrappers)"
fi

echo ""
smoke_summary
