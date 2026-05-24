#!/usr/bin/env bash
set -euo pipefail

: "${VENV:?VENV must be set}"
: "${ONNX_PACKAGE:?ONNX_PACKAGE must be set}"
: "${PYTORCH_EXTRA:?PYTORCH_EXTRA must be set}"

APP_DIR="/opt/Kataglyphis-Orchestr-ANT-ion"
APP_REF="v0.0.19"

activate_project_environment() {
  # Verify-only runs may happen in a later image or on real hardware.
  source "${VENV}/bin/activate"
  export UV_PYTHON="${VENV}/bin/python"
  export MEDIA_HOST_PYTHON="${VENV}/bin/python"
}

prepare_project_tree() {
  rm -rf "${APP_DIR}"
  git clone --branch "${APP_REF}" --depth 1 https://github.com/Kataglyphis/Kataglyphis-Orchestr-ANT-ion.git "${APP_DIR}"
}

install_project_environment() {
  activate_project_environment

  rm -f "${APP_DIR}/uv.lock"

  case "${ONNX_PACKAGE}" in
    onnxruntime|onnxruntime-webgpu)
      rm -f /opt/wheels/*_gpu-*.whl /opt/wheels/*_rocm-*.whl /opt/wheels/*genai*.whl || true
      ;;
    onnxruntime-gpu|onnxruntime-rocm)
      rm -f /opt/wheels/*webgpu*.whl || true
      ;;
    *)
      printf 'Unsupported ONNX package: %s\n' "${ONNX_PACKAGE}" >&2
      exit 1
      ;;
  esac

  cd "${APP_DIR}"
  uv lock --find-links /opt/wheels
  # The runtime image only needs the ML/runtime extras; the optional GUI frontend
  # pulls wxPython, which is not required here and currently fails on Python 3.14.
  local -a sync_args=(--find-links /opt/wheels --active \
    --extra "ml-ai" \
    --extra "${PYTORCH_EXTRA}" \
    --extra "docs")
  if [ "${SKIP_TORCH_TEST_EXTRAS:-false}" != "true" ]; then
    sync_args+=(--extra "test")
  fi
  uv sync "${sync_args[@]}"
  uv pip uninstall onnxruntime onnxruntime-gpu onnxruntime-rocm onnxruntime-webgpu opencv-python opencv-python-headless opencv-contrib-python opencv-contrib-python-headless || true
  uv pip install --force-reinstall /opt/wheels/*.whl
  uv pip install PyGObject
}

verify_project_environment() {
  activate_project_environment

  find "${VENV}" -name "cv2*.so" -exec ldd {} \; || true
  uv run --active python -c "import gi, numpy, contourpy; print('gi OK'); print('numpy', numpy.__version__);"
  uv run --active python -c "import os; os.environ['OPENCV_LOG_LEVEL']='DEBUG'; import cv2; print('cv2', cv2.__version__);"

  if [ "${ENABLE_NVIDIA:-false}" = "true" ]; then
    echo "Testing GPU Support (Build checks only, not runtime)"
    rm -f /usr/local/tensorrt/lib/libstdc++.so* || true
    uv run --active python -c "import torch; cuda_ver = torch.version.cuda; print(f'PyTorch CUDA Build Version: {cuda_ver}'); assert cuda_ver is not None, 'ERROR: PyTorch was NOT built with CUDA!'"
    uv run --active python -c "import onnxruntime as ort; providers = ort.get_available_providers(); print(f'ONNX Runtime Available Providers: {providers}'); assert 'CUDAExecutionProvider' in providers, 'ERROR: ONNX Runtime does NOT have CUDAExecutionProvider!'"
  fi

  echo "Installed packages in the virtual environment:"
  uv pip list
}

usage() {
  printf 'Usage: %s [install|verify|all]\n' "${0##*/}" >&2
}

main() {
  local mode="${1:-all}"

  case "${mode}" in
    install)
      prepare_project_tree
      install_project_environment
      ;;
    verify)
      verify_project_environment
      ;;
    all)
      prepare_project_tree
      install_project_environment
      verify_project_environment
      ;;
    *)
      usage
      exit 2
      ;;
  esac
}

main "$@"
