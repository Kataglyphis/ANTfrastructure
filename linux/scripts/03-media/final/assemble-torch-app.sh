#!/usr/bin/env bash
set -euo pipefail

: "${VENV:?VENV must be set}"
: "${ONNX_PACKAGE:?ONNX_PACKAGE must be set}"
: "${PYTORCH_EXTRA:?PYTORCH_EXTRA must be set}"
: "${LITERT_VERSION:?LITERT_VERSION must be set}"

APP_DIR="/opt/Kataglyphis-Orchestr-ANT-ion"

prepare_project_tree() {
  rm -rf "${APP_DIR}"
  git clone https://github.com/Kataglyphis/Kataglyphis-Orchestr-ANT-ion.git "${APP_DIR}"
  git -C "${APP_DIR}" checkout v0.0.17
}

patch_pyproject() {
  local pyproject="${APP_DIR}/pyproject.toml"

  sed -i "s/\"onnxruntime; /\"${ONNX_PACKAGE}; /g" "${pyproject}"
  sed -i "s/\"onnxruntime\"/\"${ONNX_PACKAGE}\"/g" "${pyproject}"
  sed -i "s/\"onnxruntime>=.*\"/\"${ONNX_PACKAGE}\"/g" "${pyproject}"
  sed -i 's/"opencv-python; /"opencv-contrib-python; /g' "${pyproject}"
  sed -i 's/"opencv-python"/"opencv-contrib-python"/g' "${pyproject}"
  printf '\n[tool.uv]\nconstraint-dependencies = ["ai-edge-litert==%s", "numpy==2.4.4"]\n' "${LITERT_VERSION}" >> "${pyproject}"
}

install_project_environment() {
  source "${VENV}/bin/activate"

  apt-get remove -y pybind11-dev python3-pybind11 || true
  rm -rf /root/.cache/uv/*
  rm -f "${APP_DIR}/uv.lock"

  echo "Debugging local wheels:"
  ls -la /opt/wheels || true
  uv pip install /opt/wheels/ai_edge_litert*.whl || true

  if [ "${ONNX_PACKAGE}" = "onnxruntime-gpu" ] || [ "${ONNX_PACKAGE}" = "onnxruntime-rocm" ]; then
    rm -f /opt/wheels/*webgpu*.whl || true
  else
    rm -f /opt/wheels/*_gpu-*.whl /opt/wheels/*_rocm-*.whl /opt/wheels/*genai*.whl || true
  fi

  patch_pyproject

  cd "${APP_DIR}"
  uv lock --find-links /opt/wheels
  uv sync --find-links /opt/wheels --active --extra "ml-ai" --extra "${PYTORCH_EXTRA}" --extra "test" --extra "frontend" --extra "docs"
  uv pip uninstall onnxruntime opencv-python opencv-python-headless opencv-contrib-python opencv-contrib-python-headless || true
  uv pip install --force-reinstall /opt/wheels/*.whl
  uv pip install PyGObject
}

verify_project_environment() {
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

main() {
  prepare_project_tree
  install_project_environment
  verify_project_environment
}

main "$@"
