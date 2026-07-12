#!/usr/bin/env bash
set -euo pipefail

: "${VENV:?VENV must be set}"
: "${ONNX_PACKAGE:?ONNX_PACKAGE must be set}"
: "${PYTORCH_EXTRA:=pytorch-cpu}"

APP_DIR="/opt/Kataglyphis-Orchestr-ANT-ion"
APP_REF="${APP_REF:-v0.0.19}"

# Uninstall any PyPI opencv-family packages (best-effort). Centralizes the four
# package names that were repeated verbatim across reconcile/install/verify so
# the list can no longer drift between the call sites.
uv_uninstall_pip_opencv() {
  uv pip uninstall opencv-python opencv-python-headless \
    opencv-contrib-python opencv-contrib-python-headless 2>/dev/null || true
}

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
      torch-*.whl|torchvision-*.whl|ai_edge_litert-*.whl|ai-edge-litert-*.whl)
        # Custom-built wheels are ALWAYS pinned as locked local wheels. A
        # broken line-continuation used to merge this branch with the opencv
        # one below (embedded-whitespace pattern), so with staged OpenCV
        # bindings present these wheels were silently dropped from the locked
        # set and pip could resolve UPSTREAM torch instead of the custom build.
        out_wheels_ref+=("${wheel_path}")
        ;;
      opencv_python-*.whl|opencv_python_headless-*.whl|opencv_contrib_python-*.whl|opencv_contrib_python_headless-*.whl)
        if staged_opencv_python_available; then
          echo "Skipping ${wheel_basename} (source-built OpenCV5 bindings found)"
        else
          out_wheels_ref+=("${wheel_path}")
        fi
        ;;
    esac
  done
  shopt -u nullglob
}

# Remove prebuilt wheels that conflict with the selected ONNX_PACKAGE variant.
prune_conflicting_onnx_wheels() {
  case "${ONNX_PACKAGE}" in
    onnxruntime|onnxruntime-webgpu)
      rm -f /opt/wheels/*_gpu-*.whl /opt/wheels/*_migraphx-*.whl /opt/wheels/*genai*.whl || true
      ;;
    onnxruntime-gpu|onnxruntime-migraphx)
      rm -f /opt/wheels/*webgpu*.whl || true
      ;;
    *)
      printf 'Unsupported ONNX package: %s\n' "${ONNX_PACKAGE}" >&2
      exit 1
      ;;
  esac
}

# Assemble the `uv sync` arg array into $1; when locked packages are served from
# prebuilt local wheels ($2 names, $3 wheels), tell uv to skip them and install
# those wheels. Namerefs are underscore-prefixed to avoid circular references.
build_uv_sync_args() {
  local -n _sync_args="$1"
  local -n _locked_skip="$2"
  local -n _locked_wheels="$3"
  local package_name

  # The runtime image only needs the ML/runtime extras; the optional GUI frontend
  # pulls wxPython, which is not required here and currently fails on Python 3.14.
  _sync_args=(--find-links /opt/wheels --active \
    --extra "ml-ai" \
    --extra "docs")

  # Is torch served from a prebuilt LOCAL wheel (the riscv64 cross-build path)?
  # If so, the torch BACKEND extra below must NOT be requested: its torch entry
  # would make uv resolve/clone the upstream torch source instead of our wheel.
  local _torch_from_local_wheel=false
  for package_name in "${_locked_skip[@]}"; do
    case "${package_name}" in torch|torchvision) _torch_from_local_wheel=true ;; esac
  done

  # PYTORCH_EXTRA selects the torch BACKEND index-extra: pytorch-cpu (the default),
  # pytorch-cu130, or pytorch-rocm71. In the app's pyproject, `torch` is declared
  # ONLY inside these backend extras (NEVER in ml-ai), each wired to an explicit
  # uv index (download.pytorch.org/whl/{cpu,cu130,rocm7.1}). So for arches that
  # get torch from uv sync (amd64/arm64) the backend extra MUST be requested --
  # without it uv resolves the whole tree WITHOUT torch and the image ships
  # torch-less (the 2026-07-12 runtime smoke failure). "none"/"" disables it; it
  # is also skipped when torch is supplied by a local wheel (riscv64).
  # (An earlier default of "none" wrongly assumed ml-ai carried torch -- it does not.)
  if [ "${_torch_from_local_wheel}" = "false" ]; then
    case "${PYTORCH_EXTRA:-pytorch-cpu}" in
      none|"") ;;
      *) _sync_args+=(--extra "${PYTORCH_EXTRA}") ;;
    esac
  fi

  if [ "${#_locked_skip[@]}" -gt 0 ]; then
    printf 'Using prebuilt local wheels for locked packages: %s\n' "${_locked_skip[*]}"
    for package_name in "${_locked_skip[@]}"; do
      _sync_args+=(--no-install-package "${package_name}")
    done
    if [ "${#_locked_wheels[@]}" -gt 0 ]; then
      uv pip install --force-reinstall "${_locked_wheels[@]}"
    fi
  fi

  if [ "${SKIP_TORCH_TEST_EXTRAS:-false}" != "true" ]; then
    _sync_args+=(--extra "test")
  fi
}

# Run `uv sync` with $1 args. With a lockfile ($3=true) try --frozen first and
# fall back to regenerating the lock; without one, lock then sync. Either
# fallback force-reinstalls the local wheels ($2). Ordering is load-bearing.
run_uv_sync_with_fallback() {
  # shellcheck disable=SC2178  # nameref to caller's array (read as "${_sync_args[@]}")
  local -n _sync_args="$1"
  local -n _locked_wheels="$2"
  local have_lock="$3"
  local -a frozen_sync_args=()

  if [ "${have_lock}" = "true" ]; then
    frozen_sync_args=("${_sync_args[@]}" --frozen)
    if ! uv sync "${frozen_sync_args[@]}"; then
      echo "Frozen upstream uv.lock failed for this Python/platform; regenerating a local lock"
      uv lock --find-links /opt/wheels
      uv sync "${_sync_args[@]}" || echo "WARNING: uv sync after lock regeneration had issues; force-reinstalling local wheels"
      if [ "${#_locked_wheels[@]}" -gt 0 ]; then
        uv pip install --force-reinstall "${_locked_wheels[@]}" || true
      fi
    fi
  else
    uv lock --find-links /opt/wheels
    uv sync "${_sync_args[@]}" || echo "WARNING: uv sync had issues; force-reinstalling local wheels"
    if [ "${#_locked_wheels[@]}" -gt 0 ]; then
      uv pip install --force-reinstall "${_locked_wheels[@]}" || true
    fi
  fi
}

# After uv sync, force-reinstall the prebuilt local wheels, first uninstalling
# any PyPI onnxruntime/opencv families they replace so the local builds win.
reconcile_local_wheels() {
  local -a local_wheels=()
  local wheel_path wheel_basename
  local have_onnx_family=false have_opencv_family=false
  local have_torch_family=false have_litert_family=false

  shopt -s nullglob
  local_wheels=(/opt/wheels/*.whl)
  shopt -u nullglob

  if [ "${#local_wheels[@]}" -eq 0 ]; then
    echo "No local wheels found; keeping packages installed by uv sync"
    return 0
  fi

  for wheel_path in "${local_wheels[@]}"; do
    wheel_basename="$(basename "${wheel_path}")"
    case "${wheel_basename}" in
      onnxruntime-*.whl|onnxruntime_gpu-*.whl|onnxruntime_migraphx-*.whl|onnxruntime_webgpu-*.whl)
        have_onnx_family=true
        ;;
      opencv_python-*.whl|opencv_python_headless-*.whl|opencv_contrib_python-*.whl|opencv_contrib_python_headless-*.whl)
        have_opencv_family=true
        ;;
      torch-*.whl|torchvision-*.whl)
        have_torch_family=true
        ;;
      ai_edge_litert-*.whl|ai-edge-litert-*.whl)
        have_litert_family=true
        ;;
    esac
  done

  # Uninstall any PyPI build of a family we ship locally BEFORE force-reinstalling
  # our wheels, so an upstream pulled transitively (often under a variant name --
  # onnxruntime-gpu, opencv-python 4.x) can't shadow the custom build. torch/
  # torchvision/ai-edge-litert are purged here too for symmetry -- previously they
  # relied on build_uv_sync_args' --no-install-package + --force-reinstall alone.
  if [ "${have_onnx_family}" = "true" ]; then
    uv pip uninstall onnxruntime onnxruntime-gpu onnxruntime-migraphx onnxruntime-webgpu 2>/dev/null || true
  fi
  if [ "${have_opencv_family}" = "true" ]; then
    uv_uninstall_pip_opencv
  fi
  if [ "${have_torch_family}" = "true" ]; then
    uv pip uninstall torch torchvision 2>/dev/null || true
  fi
  if [ "${have_litert_family}" = "true" ]; then
    uv pip uninstall ai-edge-litert 2>/dev/null || true
  fi

  uv pip install --force-reinstall "${local_wheels[@]}"
}

install_project_environment() {
  activate_project_environment
  # The arrays below are populated/consumed by the helpers via nameref (SC2034
  # can't see cross-function nameref use, hence the per-line disables).
  # shellcheck disable=SC2034
  local -a locked_skip_packages=()
  # shellcheck disable=SC2034
  local -a locked_local_wheels=()
  # shellcheck disable=SC2034
  local -a sync_args=()
  local have_lock=false

  prune_conflicting_onnx_wheels

  cd "${APP_DIR}"
  collect_locked_local_skip_packages locked_skip_packages
  collect_locked_local_wheels locked_local_wheels
  if [ -f "${APP_DIR}/uv.lock" ]; then
    have_lock=true
  fi

  build_uv_sync_args sync_args locked_skip_packages locked_local_wheels
  run_uv_sync_with_fallback sync_args locked_local_wheels "${have_lock}"
  reconcile_local_wheels

  # If any dependency pulled in a PyPI opencv-python (4.x), remove it
  # so the source-built OpenCV5 bindings win.
  if staged_opencv_python_available; then
    uv_uninstall_pip_opencv
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
    uv_uninstall_pip_opencv
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
