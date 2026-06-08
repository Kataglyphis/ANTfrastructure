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

append_unique_arg() {
  local -n out_args_ref=$1
  local new_arg="$2"
  local existing_arg

  for existing_arg in "${out_args_ref[@]:-}"; do
    if [ "${existing_arg}" = "${new_arg}" ]; then
      return 0
    fi
  done

  out_args_ref+=("${new_arg}")
}

staged_opencv_python_available() {
  local dir

  shopt -s nullglob
  for dir in \
    /opt/opencv5/lib/python3*/site-packages \
    /opt/opencv5/lib/python3*/dist-packages \
    /opt/opencv5/lib64/python3*/site-packages \
    /opt/opencv5/lib64/python3*/dist-packages \
    /opt/opencv5/python/cv2/python-*; do
    [ -d "${dir}" ] || continue
    shopt -u nullglob
    return 0
  done
  shopt -u nullglob

  return 1
}

collect_locked_local_skip_packages() {
  local -n out_packages_ref=$1
  local wheel_path wheel_basename

  if staged_opencv_python_available; then
    append_unique_arg out_packages_ref opencv-python
  fi

  shopt -s nullglob
  for wheel_path in /opt/wheels/*.whl; do
    wheel_basename="$(basename "${wheel_path}")"
    case "${wheel_basename}" in
      torch-*.whl)
        append_unique_arg out_packages_ref torch
        ;;
      torchvision-*.whl)
        append_unique_arg out_packages_ref torchvision
        ;;
      ai_edge_litert-*.whl|ai-edge-litert-*.whl)
        append_unique_arg out_packages_ref ai-edge-litert
        ;;
      opencv_python-*.whl|opencv_python_headless-*.whl|opencv_contrib_python-*.whl|opencv_contrib_python_headless-*.whl)
        append_unique_arg out_packages_ref opencv-python
        ;;
    esac
  done
  shopt -u nullglob
}

collect_locked_local_wheels() {
  local -n out_wheels_ref=$1
  local wheel_path wheel_basename

  shopt -s nullglob
  for wheel_path in /opt/wheels/*.whl; do
    wheel_basename="$(basename "${wheel_path}")"
    case "${wheel_basename}" in
      torch-*.whl|torchvision-*.whl|ai_edge_litert-*.whl|ai-edge-litert-*.whl|      opencv_python-*.whl|opencv_python_headless-*.whl|opencv_contrib_python-*.whl|opencv_contrib_python_headless-*.whl)
        if staged_opencv_python_available; then
          echo "Skipping /opt/wheels/ opencv wheel (source-built OpenCV5 bindings found)"
        else
          out_wheels_ref+=("${wheel_path}")
        fi
        ;;      
    esac
  done
  shopt -u nullglob
}

install_project_environment() {
  activate_project_environment
  local -a local_wheels=()
  local -a locked_skip_packages=()
  local -a locked_local_wheels=()
  local -a sync_args=()
  local -a frozen_sync_args=()
  local have_lock=false
  local wheel_path wheel_basename
  local have_onnx_family=false
  local have_opencv_family=false

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
  collect_locked_local_skip_packages locked_skip_packages
  collect_locked_local_wheels locked_local_wheels
  if [ -f "${APP_DIR}/uv.lock" ]; then
    have_lock=true
  fi

  # The runtime image only needs the ML/runtime extras; the optional GUI frontend
  # pulls wxPython, which is not required here and currently fails on Python 3.14.
  sync_args=(--find-links /opt/wheels --active \
    --extra "ml-ai" \
    --extra "${PYTORCH_EXTRA}" \
    --extra "docs")

  if [ "${#locked_skip_packages[@]}" -gt 0 ]; then
    printf 'Using prebuilt local wheels for locked packages: %s\n' "${locked_skip_packages[*]}"
    local package_name
    for package_name in "${locked_skip_packages[@]}"; do
      sync_args+=(--no-install-package "${package_name}")
    done
    if [ "${#locked_local_wheels[@]}" -gt 0 ]; then
      uv pip install --force-reinstall "${locked_local_wheels[@]}"
    fi
  fi

  if [ "${SKIP_TORCH_TEST_EXTRAS:-false}" != "true" ]; then
    sync_args+=(--extra "test")
  fi

  if [ "${have_lock}" = "true" ]; then
    frozen_sync_args=("${sync_args[@]}" --frozen)
    if ! uv sync "${frozen_sync_args[@]}"; then
      echo "Frozen upstream uv.lock failed for this Python/platform; regenerating a local lock"
      uv lock --find-links /opt/wheels
      uv sync "${sync_args[@]}" || echo "WARNING: uv sync after lock regeneration had issues; force-reinstalling local wheels"
      if [ "${#locked_local_wheels[@]}" -gt 0 ]; then
        uv pip install --force-reinstall "${locked_local_wheels[@]}" || true
      fi
    fi
  else
    uv lock --find-links /opt/wheels
    uv sync "${sync_args[@]}" || echo "WARNING: uv sync had issues; force-reinstalling local wheels"
    if [ "${#locked_local_wheels[@]}" -gt 0 ]; then
      uv pip install --force-reinstall "${locked_local_wheels[@]}" || true
    fi
  fi

  shopt -s nullglob
  local_wheels=(/opt/wheels/*.whl)
  shopt -u nullglob

  if [ "${#local_wheels[@]}" -eq 0 ]; then
    echo "No local wheels found; keeping packages installed by uv sync"
  else
    for wheel_path in "${local_wheels[@]}"; do
      wheel_basename="$(basename "${wheel_path}")"
      case "${wheel_basename}" in
        onnxruntime-*.whl|onnxruntime_gpu-*.whl|onnxruntime_rocm-*.whl|onnxruntime_webgpu-*.whl)
          have_onnx_family=true
          ;;
        opencv_python-*.whl|opencv_python_headless-*.whl|opencv_contrib_python-*.whl|opencv_contrib_python_headless-*.whl)
          have_opencv_family=true
          ;;
      esac
    done

    if [ "${have_onnx_family}" = "true" ]; then
      uv pip uninstall onnxruntime onnxruntime-gpu onnxruntime-rocm onnxruntime-webgpu 2>/dev/null || true
    fi
    if [ "${have_opencv_family}" = "true" ]; then
      uv pip uninstall opencv-python opencv-python-headless opencv-contrib-python opencv-contrib-python-headless 2>/dev/null || true
    fi

    uv pip install --force-reinstall "${local_wheels[@]}"
  fi

  # If any dependency pulled in a PyPI opencv-python (4.x), remove it
  # so the source-built OpenCV5 bindings win.
  if staged_opencv_python_available; then
    uv pip uninstall opencv-python opencv-python-headless opencv-contrib-python opencv-contrib-python-headless 2>/dev/null || true
  fi

  if python3 -c 'import gi; print(gi.__version__)' 2>/dev/null; then
    echo "PyGObject already installed (system package), skipping pip install"
  else
    uv pip install PyGObject
  fi
}

verify_project_environment() {
  activate_project_environment

  # Uninstall any pip-installed opencv packages so the source-built
  # OpenCV5 bindings at /opt/opencv5 (visible via .pth) are used.
  if staged_opencv_python_available; then
    uv pip uninstall opencv-python opencv-python-headless opencv-contrib-python opencv-contrib-python-headless 2>/dev/null || true
  fi

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
