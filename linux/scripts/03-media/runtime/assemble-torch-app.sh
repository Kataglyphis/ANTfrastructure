#!/usr/bin/env bash
set -euo pipefail

: "${VENV:?VENV must be set}"
: "${ONNX_PACKAGE:?ONNX_PACKAGE must be set}"
: "${PYTORCH_EXTRA:=pytorch-cpu}"

APP_DIR="/opt/Kataglyphis-Orchestr-ANT-ion"
APP_REF="${APP_REF:-v0.0.27}"

# Uninstall any PyPI opencv-family packages (best-effort). Centralizes the four
# package names that were repeated verbatim across reconcile/install/verify so
# the list can no longer drift between the call sites.
uv_uninstall_pip_opencv() {
  uv pip uninstall opencv-python opencv-python-headless \
    opencv-contrib-python opencv-contrib-python-headless 2>/dev/null || true
}

activate_project_environment() {
  # Verify-only runs may happen in a later image or on real hardware.
  # Vendor sourcing under set -u: suspend nounset for the activate script
  # (not guaranteed nounset-clean across venv generators), restore after.
  local _ape_had_u=0
  case $- in *u*) _ape_had_u=1; set +u ;; esac
  source "${VENV}/bin/activate"
  [ "${_ape_had_u}" = "1" ] && set -u
  export UV_PYTHON="${VENV}/bin/python"
  export MEDIA_HOST_PYTHON="${VENV}/bin/python"
}

prepare_project_tree() {
  local _attempt
  rm -rf "${APP_DIR}"
  # Inline retry (3 attempts, 10s apart): this clone runs hours into the
  # runtime chain and a transient network/GitHub hiccup must not discard the
  # whole build. Inlined rather than 01-core's retry(): this script ships
  # standalone into images (e.g. Dockerfile.torch) that carry no 01-core.
  for _attempt in 1 2 3; do
    if git clone --branch "${APP_REF}" --depth 1 https://github.com/Kataglyphis/Kataglyphis-Orchestr-ANT-ion.git "${APP_DIR}"; then
      break
    fi
    rm -rf "${APP_DIR}"
    if [ "${_attempt}" -eq 3 ]; then
      echo "ERROR: git clone of Kataglyphis-Orchestr-ANT-ion (${APP_REF}) failed after 3 attempts" >&2
      return 1
    fi
    echo "WARNING: git clone attempt ${_attempt}/3 failed; retrying in 10s..." >&2
    sleep 10
  done

  # riscv64: the app's pyproject `[tool.uv] environments` list deliberately
  # EXCLUDES riscv64 (`sys_platform == 'linux' and platform_machine != 'riscv64'`)
  # because the pytorch-custom extra has no lockable upstream riscv64 torch source
  # -- riscv64 torch/vision/opencv ship as local cross-built wheels in /opt/wheels
  # instead. But when `environments` is declared, uv HARD-REJECTS an excluded
  # platform with exit 2 for lock/sync/run -- it does NOT "fall back to a live
  # resolve" as the app's comment claims. Strip the gate from THIS throwaway clone
  # only (the committed app lock stays untouched for every other consumer) so uv
  # can resolve for the riscv64 build platform against --find-links + the
  # riscv64-gated git sources; the local-wheel packages are excluded from the sync
  # via --no-install-package and force-installed separately.
  if [ "$(uname -m)" = "riscv64" ] && [ -f "${APP_DIR}/pyproject.toml" ]; then
    if grep -qE '^environments[[:space:]]*=[[:space:]]*\[' "${APP_DIR}/pyproject.toml"; then
      sed -i '/^environments[[:space:]]*=[[:space:]]*\[/,/^\]/d' "${APP_DIR}/pyproject.toml"
      echo "riscv64: stripped [tool.uv] environments gate from the app clone so uv can resolve for the build platform"
    fi
  fi
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
      iree_base_compiler-*.whl)
        append_unique_arg out_packages_ref iree-base-compiler
        ;;
      iree_base_runtime-*.whl)
        append_unique_arg out_packages_ref iree-base-runtime
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

# `uv lock` regeneration for the fallback paths below. On riscv64 a full lock can
# still fail to resolve every workspace extra (e.g. a pytorch backend extra whose
# torch has no lockable upstream riscv64 source); the runtime only needs the
# packages served by --find-links + the local wheels, so treat a riscv64 lock
# failure as non-fatal and let the subsequent `uv sync` + local-wheel
# force-install carry the venv. On amd64/arm64 a lock failure is a genuine error
# and still aborts (set -e).
uv_lock_regen() {
  if uv lock --find-links /opt/wheels; then
    return 0
  fi
  if [ "$(uname -m)" = "riscv64" ]; then
    # EXPECTED on riscv64: some workspace extras (e.g. a pytorch backend whose
    # torch has no lockable upstream riscv64 source) can't fully resolve under
    # QEMU. This is by design — the caller (run_uv_sync_with_fallback) then
    # force-reinstalls the local /opt/wheels, which is what the runtime actually
    # needs — so this is INFO, not a failure.
    echo "INFO: uv lock not fully regenerated on riscv64 (expected); runtime venv is carried by --find-links + force-installed local wheels"
    return 0
  fi
  return 1
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
      uv_lock_regen
      uv sync "${_sync_args[@]}" || echo "WARNING: uv sync after lock regeneration had issues; force-reinstalling local wheels"
      if [ "${#_locked_wheels[@]}" -gt 0 ]; then
        uv pip install --force-reinstall "${_locked_wheels[@]}" || true
      fi
    fi
  else
    uv_lock_regen
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

  # Partition IREE runtime wheels (riscv64 cross-built, best-effort) out of the
  # main force-reinstall: they pull ml_dtypes, which has no riscv64 PyPI wheel and
  # would source-build under QEMU -- a failure there must NOT abort venv assembly
  # (this function runs under set -e). Install them WITHOUT deps and best-effort;
  # numpy is already present, so iree.runtime + native iree-run-module still work,
  # and if a hard dep is genuinely missing check_iree just optional-fails.
  # TVM is partitioned out for the same reason as IREE: it's an OPTIONAL framework
  # whose deps (ml_dtypes, scipy, ...) may have no riscv64 wheel and source-build
  # under QEMU. Installing it in the main (non-best-effort) force-reinstall could
  # abort venv assembly on a dep failure, breaking the runtime build for a wheel
  # that's meant to be optional. Install it best-effort so `import tvm` degrades to
  # the runtime smoke's optional-fail instead of failing the build.
  local -a iree_wheels=() tvm_wheels=() other_wheels=()
  for wheel_path in "${local_wheels[@]}"; do
    case "$(basename "${wheel_path}")" in
      iree_base_runtime-*.whl|iree_base_compiler-*.whl|iree-*.whl)
        iree_wheels+=("${wheel_path}") ;;
      apache_tvm-*.whl|apache-tvm-*.whl|tvm-*.whl|tvm_ffi-*.whl|apache_tvm_ffi-*.whl)
        tvm_wheels+=("${wheel_path}") ;;
      *)
        other_wheels+=("${wheel_path}") ;;
    esac
  done

  if [ "${#other_wheels[@]}" -gt 0 ]; then
    uv pip install --force-reinstall "${other_wheels[@]}"
  fi
  if [ "${#tvm_wheels[@]}" -gt 0 ]; then
    uv pip install --force-reinstall "${tvm_wheels[@]}" || \
      echo "WARNING: TVM wheel install failed (optional; import tvm will optional-fail; native libs unaffected)"
  fi
  if [ "${#iree_wheels[@]}" -gt 0 ]; then
    if [ "$(uname -m)" = "riscv64" ]; then
      # riscv64: install IREE --no-deps (its ml_dtypes/numpy deps have no riscv64
      # wheels and a full-deps resolve would try to pull them). numpy is already
      # present from the sync.
      uv pip install --no-deps --force-reinstall "${iree_wheels[@]}" || \
        echo "WARNING: IREE riscv64 runtime wheel install failed (non-fatal; check_iree will optional-fail)"
      # ml_dtypes has no riscv64 PyPI wheel, so source-build it INTO this venv
      # (best-effort). It must go here, not via apt in setup-package-image.sh — the
      # from-source py3.14 venv can't see the distro python's dist-packages. Without
      # it `import iree.runtime` fails "No module named 'ml_dtypes'" (the runtime
      # smoke WARN); the native iree-compile path is unaffected either way.
      uv pip install ml_dtypes || \
        echo "WARNING: ml_dtypes source-build failed on riscv64 (iree.runtime bf16 dtypes unavailable; native iree-compile unaffected)"
    else
      # amd64/arm64: resolve IREE's runtime deps (ml_dtypes, numpy) from PyPI so the
      # source-built cp314 wheels are fully functional; the cp314 wheel replaces any
      # PyPI cp312-abi3 build. Hard-fail under set -e -- IREE is REQUIRED here.
      uv pip install --force-reinstall "${iree_wheels[@]}"
    fi
  fi
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

  ensure_project_package_installed
}

# `uv sync` installs the app project itself (Orchestr-ANT-ion -> orchestr_ant_ion)
# alongside its dependencies on amd64/arm64. On riscv64 the [tool.uv] environments-gate
# strip makes uv re-resolve, which drags the riscv64-gated `torch @ git+...` source build
# into the graph; that build times out, so `uv sync` aborts BEFORE installing the app's
# own pure-Python deps (loguru, tqdm, hydra-core, matplotlib, flask, ...) OR the project
# itself. The local-wheel fallback only force-reinstalls the torch closure, so BOTH the
# project and its core deps are absent -> the runtime app-wheel smoke dies with
# `ModuleNotFoundError: No module named 'loguru'` (its first-imported core dep).
#
# Install the project WITH its core dependencies. torch/torchvision live ONLY in the
# `pytorch-*` extras (never in [project].dependencies), so installing without any extra
# pulls just the pure-Python deps and NEVER re-resolves the git torch source. The already
# -installed local torch/vision wheels are left untouched (uv pip install is additive and
# no core dep requires torch). Guarded by an import probe -- a no-op on amd64/arm64 where
# uv sync already installed project + deps (the probe imports cleanly there).
ensure_project_package_installed() {
  if uv run --no-sync --active python -c 'import orchestr_ant_ion' >/dev/null 2>&1; then
    echo "Project package orchestr_ant_ion already installed"
    return 0
  fi
  echo "Project package orchestr_ant_ion (+ core deps) missing after uv sync; installing from ${APP_DIR}"
  uv pip install "${APP_DIR}"
}

verify_project_environment() {
  activate_project_environment

  # Uninstall any pip-installed opencv packages so the source-built
  # OpenCV5 bindings at /opt/opencv5 (visible via .pth) are used.
  if staged_opencv_python_available; then
    uv_uninstall_pip_opencv
  fi

  find "${VENV}" -name "cv2*.so" -exec ldd {} \; || true
  uv run --no-sync --active python -c "import gi, numpy, contourpy; print('gi OK'); print('numpy', numpy.__version__);"
  uv run --no-sync --active python -c "import os; os.environ['OPENCV_LOG_LEVEL']='DEBUG'; import cv2; print('cv2', cv2.__version__);"

  if [ "${ENABLE_NVIDIA:-false}" = "true" ]; then
    echo "Testing GPU Support (Build checks only, not runtime)"
    rm -f /usr/local/tensorrt/lib/libstdc++.so* || true
    uv run --no-sync --active python -c "import torch; cuda_ver = torch.version.cuda; print(f'PyTorch CUDA Build Version: {cuda_ver}'); assert cuda_ver is not None, 'ERROR: PyTorch was NOT built with CUDA!'"
    uv run --no-sync --active python -c "import onnxruntime as ort; providers = ort.get_available_providers(); print(f'ONNX Runtime Available Providers: {providers}'); assert 'CUDAExecutionProvider' in providers, 'ERROR: ONNX Runtime does NOT have CUDAExecutionProvider!'"
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
