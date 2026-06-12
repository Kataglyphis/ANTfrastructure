#!/usr/bin/env bash
set -euo pipefail

_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${_SCRIPT_DIR}/smoke-common.sh"

echo "=== Media Library Functional Smoke Tests ==="
echo ""

echo "--- ONNX Runtime ---"
if command -v python3 >/dev/null 2>&1; then
  if python3 -c "import onnxruntime" 2>/dev/null; then
    onnx_ver="$(python3 -c "import onnxruntime; print(onnxruntime.__version__)" 2>/dev/null || echo '?')"
    pass "onnxruntime Python module imports (v${onnx_ver})"
  else
    fail "onnxruntime Python import failed"
  fi
else
  echo "  SKIP: python3 not found"
fi

echo "--- ONNX Runtime GenAI ---"
if command -v python3 >/dev/null 2>&1; then
  if python3 -c "import onnxruntime_genai" 2>/dev/null; then
    pass "onnxruntime_genai Python module imports"
  else
    echo "  INFO: onnxruntime_genai not installed (optional)"
  fi
fi

echo "--- OpenCV ---"
if command -v python3 >/dev/null 2>&1; then
  if python3 -c "import cv2" 2>/dev/null; then
    cv2_ver="$(python3 -c "import cv2; print(cv2.__version__)" 2>/dev/null || echo '?')"
    pass "opencv Python module imports (v${cv2_ver})"
  else
    fail "opencv Python import failed"
  fi
fi

echo "--- GStreamer ---"
if command -v gst-inspect-1.0 >/dev/null 2>&1; then
  if gst-inspect-1.0 --version >/dev/null 2>&1; then
    gst_ver="$(gst-inspect-1.0 --version 2>/dev/null | head -1 || echo '?')"
    pass "gst-inspect-1.0 functional: ${gst_ver}"
  else
    fail "gst-inspect-1.0 not functional"
  fi
else
  echo "  SKIP: gst-inspect-1.0 not found"
fi

echo "--- FFmpeg ---"
if command -v ffmpeg >/dev/null 2>&1; then
  ffmpeg_ver="$(ffmpeg -version 2>/dev/null | head -1 || echo '?')"
  pass "ffmpeg functional: ${ffmpeg_ver}"
else
  echo "  SKIP: ffmpeg not found"
fi

echo "--- libcamera ---"
if command -v pkg-config >/dev/null 2>&1; then
  if pkg-config --exists libcamera 2>/dev/null; then
    lc_ver="$(pkg-config --modversion libcamera 2>/dev/null || echo '?')"
    pass "libcamera found via pkg-config (v${lc_ver})"
  else
    echo "  INFO: libcamera not in pkg-config path (optional)"
  fi
fi

echo "--- GCC ---"
if command -v gcc >/dev/null 2>&1; then
  gcc_ver="$(gcc --version 2>/dev/null | head -1 || echo '?')"
  pass "gcc functional: ${gcc_ver}"
else
  fail "gcc not found"
fi

echo "--- Clang ---"
if command -v clang >/dev/null 2>&1; then
  clang_ver="$(clang --version 2>/dev/null | head -1 || echo '?')"
  pass "clang functional: ${clang_ver}"
else
  fail "clang not found"
fi

echo "--- CUDA (optional) ---"
if command -v nvcc >/dev/null 2>&1; then
  cuda_ver="$(nvcc --version 2>/dev/null | grep "release" | head -1 || echo '?')"
  pass "nvcc functional: ${cuda_ver}"
fi

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
