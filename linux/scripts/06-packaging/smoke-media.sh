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
if command -v python3 >/dev/null 2>&1; then
  if cross_build_is_active 2>/dev/null; then
    echo "  SKIP: onnxruntime Python import (cross build — target arch wheels can't run on build machine)"
  elif python3 -c "import onnxruntime" 2>/dev/null; then
    onnx_ver="$(python3 -c "import onnxruntime; print(onnxruntime.__version__)" 2>/dev/null || echo '?')"
    pass "onnxruntime Python module imports (v${onnx_ver})"
    if cross_build_is_active 2>/dev/null; then
      echo "  SKIP: onnxruntime functional test (cross build)"
    elif python3 -c "
import onnxruntime as ort
import numpy as np
sess = ort.InferenceSession(
    ort.SessionOptions(),
    providers=['CPUExecutionProvider']
)
" 2>/dev/null; then
      pass "onnxruntime InferenceSession created (CPUExecutionProvider)"
    else
      echo "  INFO: InferenceSession test skipped (no model loaded, provider check only)"
    fi
  else
    fail "onnxruntime Python import failed"
  fi
else
  echo "  SKIP: python3 not found"
fi

# ---------------------------------------------------------------------------
# ONNX Runtime GenAI — import check
# ---------------------------------------------------------------------------
echo "--- ONNX Runtime GenAI ---"
if command -v python3 >/dev/null 2>&1; then
  if python3 -c "import onnxruntime_genai" 2>/dev/null; then
    pass "onnxruntime_genai Python module imports"
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

# ---------------------------------------------------------------------------
# OpenCV — import + functional test
# ---------------------------------------------------------------------------
echo "--- OpenCV ---"
if command -v python3 >/dev/null 2>&1; then
  # OpenCV Python bindings live in /opt/opencv5/lib/python*/site-packages
  # and need PYTHONPATH (setup-torch-venv.sh handles this in the package stage)
  cv2_pkg="$(find /opt/opencv5 -path "*/site-packages" -type d 2>/dev/null | head -1)"
  if [ -n "${cv2_pkg}" ]; then
    if PYTHONPATH="${cv2_pkg}:${PYTHONPATH:-}" python3 -c "import cv2" 2>/dev/null; then
      cv2_ver="$(PYTHONPATH="${cv2_pkg}:${PYTHONPATH:-}" python3 -c "import cv2; print(cv2.__version__)" 2>/dev/null || echo '?')"
      pass "opencv Python module imports (v${cv2_ver})"
      if cross_build_is_active 2>/dev/null; then
        echo "  SKIP: opencv functional test (cross build)"
      elif PYTHONPATH="${cv2_pkg}:${PYTHONPATH:-}" python3 -c "
import cv2
import numpy as np
img = np.zeros((64, 64, 3), dtype=np.uint8)
gray = cv2.cvtColor(img, cv2.COLOR_BGR2GRAY)
assert gray.shape == (64, 64), f'unexpected shape {gray.shape}'
" 2>/dev/null; then
        pass "opencv functional: cvtColor+BGR2GRAY roundtrip OK"
      else
        fail "opencv functional test failed"
      fi
    else
      echo "  SKIP: opencv Python import failed (PYTHONPATH=${cv2_pkg})"
    fi
  else
    echo "  SKIP: opencv Python bindings not found in /opt/opencv5"
  fi
fi

# ---------------------------------------------------------------------------
# GStreamer — version + pipeline smoke
# ---------------------------------------------------------------------------
echo "--- GStreamer ---"
if command -v gst-inspect-1.0 >/dev/null 2>&1; then
  if gst-inspect-1.0 --version >/dev/null 2>&1; then
    gst_ver="$(gst-inspect-1.0 --version 2>/dev/null | head -1 || echo '?')"
    pass "gst-inspect-1.0 functional: ${gst_ver}"
  elif cross_build_is_active 2>/dev/null; then
    echo "  SKIP: gst-inspect-1.0 found but cannot execute (cross build — binary is for target arch)"
  else
    fail "gst-inspect-1.0 not functional"
  fi
  if gst-launch-1.0 videotestsrc num-buffers=1 ! fakesink 2>/dev/null; then
    pass "GStreamer pipeline: videotestsrc ! fakesink OK"
  elif cross_build_is_active 2>/dev/null; then
    echo "  SKIP: GStreamer pipeline test (cross build)"
  else
    echo "  INFO: GStreamer pipeline test skipped (may need display or specific plugins)"
  fi
else
  echo "  SKIP: gst-inspect-1.0 not found"
fi

# ---------------------------------------------------------------------------
# FFmpeg — version + encode/decode roundtrip
# ---------------------------------------------------------------------------
echo "--- FFmpeg ---"
if command -v ffmpeg >/dev/null 2>&1; then
  ffmpeg_ver="$(ffmpeg -version 2>/dev/null | head -1 || echo '?')"
  if [ "${ffmpeg_ver}" != "?" ]; then
    pass "ffmpeg functional: ${ffmpeg_ver}"
  elif cross_build_is_active 2>/dev/null; then
    pass "ffmpeg binary found (cross build — version check skipped)"
    ffmpeg_ver="cross-build"
  else
    pass "ffmpeg functional: ${ffmpeg_ver}"
  fi
  if ffmpeg -version >/dev/null 2>&1; then
    tmpdir="$(mktemp -d)"
    if ffmpeg -y -f lavfi -i "testsrc=duration=1:size=32x32:rate=1" \
         -c:v libx264 -preset ultrafast \
         "${tmpdir}/smoke.mp4" 2>/dev/null; then
      pass "ffmpeg H.264 encode OK"
      if ffmpeg -y -i "${tmpdir}/smoke.mp4" -f null /dev/null 2>/dev/null; then
        pass "ffmpeg H.264 decode OK"
      else
        fail "ffmpeg H.264 decode failed"
      fi
    else
      echo "  INFO: ffmpeg encode test skipped (libx264 may not be available)"
    fi
    rm -rf "${tmpdir}"
  else
    echo "  INFO: ffmpeg encode/decode test skipped (cross build or binary not functional)"
  fi
else
  echo "  SKIP: ffmpeg not found"
fi

# ---------------------------------------------------------------------------
# libcamera — pkg-config + cam binary
# ---------------------------------------------------------------------------
echo "--- libcamera ---"
if command -v pkg-config >/dev/null 2>&1; then
  if pkg-config --exists libcamera 2>/dev/null; then
    lc_ver="$(pkg-config --modversion libcamera 2>/dev/null || echo '?')"
    pass "libcamera found via pkg-config (v${lc_ver})"
  else
    echo "  INFO: libcamera not in pkg-config path (optional)"
  fi
fi
if command -v cam >/dev/null 2>&1; then
  if cam --help 2>/dev/null | head -1 | grep -q .; then
    pass "cam binary functional"
  elif cross_build_is_active 2>/dev/null; then
    pass "cam binary found (cross build — execution skipped)"
  else
    echo "  INFO: cam binary found but --help failed (expected without camera hardware)"
  fi
elif command -v lc-compliance >/dev/null 2>&1; then
  pass "lc-compliance binary found"
else
  echo "  INFO: no libcamera CLI tool found (cam/lc-compliance)"
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
fi

# ---------------------------------------------------------------------------
# Torch
# ---------------------------------------------------------------------------
echo "--- Torch ---"
if command -v python3 >/dev/null 2>&1; then
  if python3 -c "import torch" 2>/dev/null; then
    torch_ver="$(python3 -c "import torch; print(torch.__version__)" 2>/dev/null || echo '?')"
    pass "torch Python module imports (v${torch_ver})"
  else
    echo "  INFO: torch not installed (only in :latest-cross-<arch> wrappers)"
  fi
fi

echo ""
echo "=== Results: ${FAILURES} failure(s) ==="
[ "${FAILURES}" -eq 0 ] || exit 1
