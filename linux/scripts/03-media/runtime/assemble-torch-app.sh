#!/usr/bin/env bash
set -Eeuo pipefail

# See docs/failure-modes.md § A packaging script dies with no message
# shellcheck source=linux/scripts/01-core/logging.sh
source /opt/scripts/core/logging.sh
install_err_trap

: "${VENV:?VENV must be set}"
: "${ONNX_PACKAGE:?ONNX_PACKAGE must be set}"
: "${PYTORCH_EXTRA:=pytorch-cpu}"

APP_DIR="/opt/OrchestrANT"
APP_REF="${APP_REF:-develop}"

# Single list of the PyPI opencv-family names, so the call sites cannot drift.
uv_uninstall_pip_opencv() {
  uv pip uninstall opencv-python opencv-python-headless \
    opencv-contrib-python opencv-contrib-python-headless 2>/dev/null || true
}

activate_project_environment() {
  # activate scripts are not guaranteed nounset-clean; suspend -u across the source.
  local _ape_had_u=0
  case $- in *u*) _ape_had_u=1; set +u ;; esac
  source "${VENV}/bin/activate"
  [ "${_ape_had_u}" = "1" ] && set -u
  export UV_PYTHON="${VENV}/bin/python"
  export MEDIA_HOST_PYTHON="${VENV}/bin/python"
}

# APP_REF into APP_DIR: a commit is fetched as itself (clone --branch takes names only).
fetch_app_tree() {
  local _fat_url=https://github.com/Kataglyphis/OrchestrANT.git
  if [[ "${APP_REF}" =~ ^[0-9a-f]{40}$ ]]; then
    git init -q "${APP_DIR}" \
      && git -C "${APP_DIR}" fetch -q --depth 1 "${_fat_url}" "${APP_REF}" \
      && git -C "${APP_DIR}" checkout -q --detach FETCH_HEAD
  else
    git clone --branch "${APP_REF}" --depth 1 "${_fat_url}" "${APP_DIR}"
  fi
}

prepare_project_tree() {
  local _attempt
  rm -rf "${APP_DIR}"
  if ! [[ "${APP_REF}" =~ ^[0-9a-f]{40}$ ]]; then
    echo "WARNING: APP_REF=${APP_REF} is a name, not a commit: a cached build of this step does not see it move" >&2
  fi
  # Inlined, not 01-core's retry(): Dockerfile.torch images carry no 01-core.
  for _attempt in 1 2 3; do
    if fetch_app_tree; then
      echo "OrchestrANT ${APP_REF} is commit $(git -C "${APP_DIR}" rev-parse HEAD)"
      break
    fi
    rm -rf "${APP_DIR}"
    if [ "${_attempt}" -eq 3 ]; then
      echo "ERROR: git clone of OrchestrANT (${APP_REF}) failed after 3 attempts" >&2
      return 1
    fi
    echo "WARNING: git clone attempt ${_attempt}/3 failed; retrying in 10s..." >&2
    sleep 10
  done

  # uv hard-rejects (exit 2) an arch outside `[tool.uv] environments`; strip the gate from this clone only.
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

# Single source of truth for /opt/wheels basename -> family; extend HERE only.
wheel_family() {
  case "$1" in
    torch-*.whl)              printf 'torch' ;;
    torchvision-*.whl)        printf 'torchvision' ;;
    ai_edge_litert-*.whl|ai-edge-litert-*.whl) printf 'litert' ;;
    iree_base_compiler-*.whl) printf 'iree-compiler' ;;
    iree_base_runtime-*.whl)  printf 'iree-runtime' ;;
    iree-*.whl)               printf 'iree' ;;
    opencv_python-*.whl|opencv_python_headless-*.whl|opencv_contrib_python-*.whl|opencv_contrib_python_headless-*.whl)
                              printf 'opencv' ;;
    # Any ORT runtime flavour by pattern; GenAI, extensions and plugin EPs are not the runtime.
    onnxruntime_genai*.whl|onnxruntime_extensions*.whl|onnxruntime_ep_*.whl) printf 'other' ;;
    onnxruntime-*.whl|onnxruntime_*.whl)
                              printf 'onnx' ;;
    apache_tvm-*.whl|apache-tvm-*.whl|tvm-*.whl|tvm_ffi-*.whl|apache_tvm_ffi-*.whl)
                              printf 'tvm' ;;
    *)                        printf 'other' ;;
  esac
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
    case "$(wheel_family "${wheel_basename}")" in
      torch)         append_unique_arg out_packages_ref torch ;;
      torchvision)   append_unique_arg out_packages_ref torchvision ;;
      litert)        append_unique_arg out_packages_ref ai-edge-litert ;;
      iree-compiler) append_unique_arg out_packages_ref iree-base-compiler ;;
      iree-runtime)  append_unique_arg out_packages_ref iree-base-runtime ;;
      opencv)        append_unique_arg out_packages_ref opencv-python ;;
      # Both own site-packages/onnxruntime/, so a mix leaves a version-skewed capi.
      onnx)          append_unique_arg out_packages_ref onnxruntime ;;
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
    case "$(wheel_family "${wheel_basename}")" in
      torch|torchvision|litert)
        # Always locked: dropping one lets pip resolve upstream torch over the custom build.
        out_wheels_ref+=("${wheel_path}")
        ;;
      opencv)
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

# A missing chain ORT wheel is fatal: the app lock's PyPI onnxruntime would ship in its place.
assert_chain_ort_wheel_staged() {
  local _w _dir="${LOCAL_WHEELS_DIR:-/opt/wheels}"
  for _w in "${_dir}"/*.whl; do
    [ "$(wheel_family "${_w##*/}")" = "onnx" ] && return 0
  done
  echo "ERROR: no chain ONNX Runtime wheel in ${_dir} for ONNX_PACKAGE=${ONNX_PACKAGE}; refusing to fall back to the app lock's PyPI build" >&2
  return 1
}

# $1 = check|purge-list. The census ships beside this script; Build-TorchApp.ps1 embeds the same file.
run_ort_census() {
  local _census
  _census="$(dirname "${BASH_SOURCE[0]}")/ort-venv-census.py"
  "${VENV}/bin/python" -I "${_census}" "--$1" --store "${LOCAL_WHEELS_DIR:-/opt/wheels}"
}

# Every installed ORT distribution by name pattern or import-package ownership, one per line.
_ort_purge_names() {
  local _out
  _out="$(run_ort_census purge-list)" || return 1
  printf '%s\n' "${_out}" | sed -n 's/^ORT-CENSUS PURGE \([a-z0-9][a-z0-9-]*\)$/\1/p'
}

# Fail-closed: every ORT distribution in the venv must be byte-identical to a chain wheel.
assert_ort_chain_only() {
  local _out _rc=0
  _out="$(run_ort_census check 2>&1)" || _rc=$?
  printf '%s\n' "${_out}"
  if [ "${_rc}" -ne 0 ] || [[ $'\n'"${_out}" != *$'\n'"ORT-CENSUS PASS"* ]]; then
    echo "ERROR: the venv carries ONNX Runtime that is not the chain's (census rc=${_rc}); see the ORT-CENSUS lines above" >&2
    return 1
  fi
  return 0
}

# Dockerfile.torch must mount /opt/wheels rw: read-only, these rm calls fail silently.
prune_conflicting_onnx_wheels() {
  case "${ONNX_PACKAGE}" in
    onnxruntime|onnxruntime-webgpu)
      # GPU genai only: a bare *genai* glob deletes the CPU wheel build_uv_sync_args needs.
      rm -f /opt/wheels/*_gpu-*.whl /opt/wheels/*_migraphx-*.whl \
            /opt/wheels/*genai_cuda-*.whl /opt/wheels/*genai_rocm-*.whl \
            /opt/wheels/*genai_directml-*.whl
      ;;
    onnxruntime-gpu|onnxruntime-migraphx)
      # Every other flavour shares site-packages/onnxruntime with the GPU wheel; the last one in owns capi/.
      rm -f /opt/wheels/*webgpu*.whl /opt/wheels/onnxruntime_dnnl-*.whl \
            /opt/wheels/onnxruntime-[0-9]*.whl
      if [ "${ONNX_PACKAGE}" = "onnxruntime-gpu" ]; then
        rm -f /opt/wheels/onnxruntime_migraphx-*.whl
      else
        rm -f /opt/wheels/onnxruntime_gpu-*.whl
      fi
      ;;
    *)
      printf 'Unsupported ONNX package: %s\n' "${ONNX_PACKAGE}" >&2
      exit 1
      ;;
  esac
}

# `uv sync` args into $1; $2/$3 local-wheel names/paths are installed directly. Namerefs _-prefixed.
build_uv_sync_args() {
  local -n _sync_args="$1"
  local -n _locked_skip="$2"
  local -n _locked_wheels="$3"
  local package_name

  # No GUI extra: it pulls wxPython, which is unused here and fails on Python 3.14.
  _sync_args=(--find-links /opt/wheels --active \
    --extra "ml-ai" \
    --extra "docs")

  # With a local torch wheel the backend extra would make uv resolve upstream torch over it.
  local _torch_from_local_wheel=false
  for package_name in "${_locked_skip[@]}"; do
    case "${package_name}" in torch|torchvision) _torch_from_local_wheel=true ;; esac
  done

  # torch lives only in the app's pytorch-* extras; without one the image ships torch-less.
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
      # --no-deps on every local-wheel reinstall, or uv floats numpy/protobuf off the lock.
      uv pip install --no-deps --force-reinstall "${_locked_wheels[@]}"
    fi
  fi

  # --find-links only offers /opt/wheels, so the lock's PyPI genai would win over any chain flavour.
  local _genai_wheel
  _genai_wheel="$(ls /opt/wheels/onnxruntime_genai*.whl 2>/dev/null | head -1 || true)"
  if [ -n "${_genai_wheel}" ]; then
    printf 'Pinning local onnxruntime-genai wheel over the app lock: %s\n' "${_genai_wheel##*/}"
    uv pip install --no-deps --force-reinstall "${_genai_wheel}"
    _sync_args+=(--no-install-package onnxruntime-genai)
  fi

  if [ "${SKIP_TORCH_TEST_EXTRAS:-false}" != "true" ]; then
    _sync_args+=(--extra "test")
  fi
}

# A riscv64 resolution failure is tolerated (the local wheels carry the venv); elsewhere it aborts.
uv_lock_regen() {
  local _ulr_log
  _ulr_log="$(mktemp)"
  if uv lock --find-links /opt/wheels 2>&1 | tee "${_ulr_log}"; then
    rm -f "${_ulr_log}"
    return 0
  fi
  # A lock-FILE timeout is infrastructure, not the riscv64 resolution exemption below.
  if grep -qiE 'Timeout \([0-9]+s\) when waiting for lock|Failed to acquire lock' "${_ulr_log}" 2>/dev/null; then
    echo "ERROR: uv lock TIMED OUT waiting for a lock file — that is not the riscv64 resolution exemption and is not tolerated." >&2
    rm -f "${_ulr_log}"
    return 1
  fi
  rm -f "${_ulr_log}"
  if [ "$(uname -m)" = "riscv64" ]; then
    # Expected: torch has no lockable riscv64 source, and the caller force-installs /opt/wheels anyway.
    echo "INFO: uv lock not fully regenerated on riscv64 (expected); runtime venv is carried by --find-links + force-installed local wheels"
    return 0
  fi
  return 1
}

# <sync-args> <local-wheels> <have-lock>: --frozen first, else relock; ordering is load-bearing.
run_uv_sync_with_fallback() {
  # shellcheck disable=SC2178  # nameref to caller's array (read as "${_sync_args[@]}")
  local -n _sync_args="$1"
  local -n _locked_wheels="$2"
  local have_lock="$3"
  local -a frozen_sync_args=()

  if [ "${have_lock}" = "true" ]; then
    frozen_sync_args=("${_sync_args[@]}" --frozen)
    if uv sync "${frozen_sync_args[@]}"; then
      return 0
    fi
    echo "Frozen upstream uv.lock failed for this Python/platform"
  fi

  # riscv64 skips lock and sync: `uv lock` would build the git torch under QEMU just for metadata.
  if [ "$(uname -m)" = "riscv64" ]; then
    echo "riscv64: skipping uv lock + uv sync (torch from local wheel, not git source build)"
    if [ "${#_locked_wheels[@]}" -gt 0 ]; then
      uv pip install --no-deps --force-reinstall "${_locked_wheels[@]}" || true
    fi
    return 0
  fi

  uv_lock_regen
  uv sync "${_sync_args[@]}" || echo "WARNING: uv sync after lock regeneration had issues; force-reinstalling local wheels"
  if [ "${#_locked_wheels[@]}" -gt 0 ]; then
    uv pip install --no-deps --force-reinstall "${_locked_wheels[@]}" || true
  fi
}

# A transitive PyPI build of a locally shipped family (often a variant name) would shadow ours.
_purge_shadowing_pypi_builds() {
  local have_onnx_family="$1" have_opencv_family="$2"
  local have_torch_family="$3" have_litert_family="$4"
  if [ "${have_onnx_family}" = "true" ]; then
    local _names
    local -a _ort_dists=()
    _names="$(_ort_purge_names)" || { echo "ERROR: the ORT census could not list the venv's ONNX Runtime distributions" >&2; return 1; }
    [ -z "${_names}" ] || mapfile -t _ort_dists <<<"${_names}"
    if [ "${#_ort_dists[@]}" -gt 0 ]; then
      uv pip uninstall "${_ort_dists[@]}" || echo "WARNING: uv could not uninstall ${_ort_dists[*]}; the ORT census decides" >&2
    fi
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
}

# A local torch skips its backend extra, so the lock omits its deps; pairs are package:module.
_backfill_torch_runtime_deps() {
  local _venv_py="${VIRTUAL_ENV:-/opt/venv}/bin/python3"
  local -a _torch_dep_backfill=()
  local _pair _pkg _mod
  for _pair in sympy:sympy mpmath:mpmath networkx:networkx \
               jinja2:jinja2 markupsafe:markupsafe filelock:filelock \
               fsspec:fsspec typing-extensions:typing_extensions; do
    _pkg="${_pair%%:*}"; _mod="${_pair##*:}"
    "${_venv_py}" -c "import ${_mod}" 2>/dev/null || _torch_dep_backfill+=("${_pkg}")
  done
  if [ "${#_torch_dep_backfill[@]}" -gt 0 ]; then
    printf 'Backfilling torch runtime deps missing from the sync graph: %s\n' "${_torch_dep_backfill[*]}"
    uv pip install --no-deps "${_torch_dep_backfill[@]}"
  fi
}

# Install order is load-bearing: other, then tvm, then iree.
_install_wheel_groups() {
  local -n _ow="$1" _tw="$2" _iw="$3"
if [ "${#_ow[@]}" -gt 0 ]; then
  # --no-deps, or uv floats numpy/protobuf off the lock.
  uv pip install --no-deps --force-reinstall "${_ow[@]}"
  # --no-deps skipped the ORT wheel's own deps; protobuf is major-pinned so it cannot float.
  uv pip install 'protobuf>=6,<7' flatbuffers || \
    echo "WARNING: ORT runtime deps (protobuf/flatbuffers) not installed - the venv gate will name them"
fi
if [ "${#_tw[@]}" -gt 0 ]; then
  uv pip install --no-deps --force-reinstall "${_tw[@]}" || \
    echo "WARNING: TVM wheel install failed (optional; import tvm will optional-fail; native libs unaffected)"
fi
if [ "${#_iw[@]}" -gt 0 ]; then
  if [ "$(uname -m)" = "riscv64" ]; then
    # --no-deps: IREE's ml_dtypes/numpy deps have no riscv64 wheels.
    uv pip install --no-deps --force-reinstall "${_iw[@]}" || \
      echo "WARNING: IREE riscv64 runtime wheel install failed (non-fatal; check_iree will optional-fail)"
    # Source-build ml_dtypes into this venv: it cannot see an apt install's dist-packages.
    uv pip install ml_dtypes || \
      echo "WARNING: ml_dtypes source-build failed on riscv64 (iree.runtime bf16 dtypes unavailable; native iree-compile unaffected)"
  else
    # Required here; --no-deps keeps numpy on the lock, and ml_dtypes is not in it.
    uv pip install --no-deps --force-reinstall "${_iw[@]}"
    uv pip install --no-deps ml_dtypes
  fi
fi
}

# Echoes the four family flags in a fixed order: onnx opencv torch litert.
_wheel_families_present() {
  local w onnx=false opencv=false torch=false litert=false
  for w in "$@"; do
    case "$(wheel_family "$(basename "${w}")")" in
      onnx)              onnx=true ;;
      opencv)            opencv=true ;;
      torch|torchvision) torch=true ;;
      litert)            litert=true ;;
    esac
  done
  printf '%s %s %s %s\n' "${onnx}" "${opencv}" "${torch}" "${litert}"
}

# $1..$3 = nameref arrays for iree / tvm / everything else; $4.. = wheel paths.
_partition_wheels_by_install_group() {
  local -n _pi="$1" _pt="$2" _po="$3"; shift 3
  local w
  for w in "$@"; do
    case "$(wheel_family "$(basename "${w}")")" in
      iree|iree-compiler|iree-runtime) _pi+=("${w}") ;;
      tvm)                             _pt+=("${w}") ;;
      *)                               _po+=("${w}") ;;
    esac
  done
}

reconcile_local_wheels() {
  local -a local_wheels=()
  local wheel_path wheel_basename
  local have_onnx_family=false have_opencv_family=false
  local have_torch_family=false have_litert_family=false

  # Overridable only for off-target tests: /opt is root-owned.
  local _wheels_dir="${LOCAL_WHEELS_DIR:-/opt/wheels}"
  shopt -s nullglob
  local_wheels=("${_wheels_dir}"/*.whl)
  shopt -u nullglob

  if [ "${#local_wheels[@]}" -eq 0 ]; then
    echo "No local wheels found; keeping packages installed by uv sync"
    return 0
  fi

  read -r have_onnx_family have_opencv_family have_torch_family have_litert_family \
    <<<"$(_wheel_families_present "${local_wheels[@]}")"

  _purge_shadowing_pypi_builds "${have_onnx_family}" "${have_opencv_family}" \
    "${have_torch_family}" "${have_litert_family}"

  # IREE and TVM install apart: their deps may lack riscv64 wheels, which must not abort venv assembly.
  local -a iree_wheels=() tvm_wheels=() other_wheels=()
  _partition_wheels_by_install_group iree_wheels tvm_wheels other_wheels "${local_wheels[@]}"

  _install_wheel_groups other_wheels tvm_wheels iree_wheels
  if [ "${have_torch_family}" = "true" ]; then
    _backfill_torch_runtime_deps
  fi
}

# The app lock may lag the versions.env pins the smoke asserts; riscv64 keeps its source-built pair.
enforce_torch_version_pins() {
  # uname, not TARGET_ARCH: the wrapper stage does not export it.
  local machine target_arch
  machine="$(uname -m)"
  case "${machine}" in
    x86_64) target_arch=amd64 ;;
    aarch64|arm64) target_arch=arm64 ;;
    riscv64) target_arch=riscv64 ;;
    *) target_arch="${machine}" ;;
  esac
  case "${target_arch}" in
    amd64|arm64) ;;
    *) return 0 ;;
  esac
  [ -n "${PYTORCH_VERSION:-}" ] && [ -n "${TORCHVISION_VERSION:-}" ] || return 0

  local want_torch="${PYTORCH_VERSION#v}" want_tv="${TORCHVISION_VERSION#v}"
  local have_torch have_tv
  have_torch="$(python3 -c 'import torch; print(torch.__version__.split("+")[0])' 2>/dev/null || true)"
  have_tv="$(python3 -c 'import torchvision; print(torchvision.__version__.split("+")[0])' 2>/dev/null || true)"

  if [ "${have_torch}" = "${want_torch}" ] && [ "${have_tv}" = "${want_tv}" ]; then
    echo "torch pins satisfied: ${have_torch} / ${have_tv}"
    return 0
  fi

  echo "enforcing torch pins: ${have_torch:-absent}/${have_tv:-absent} -> ${want_torch}/${want_tv}"
  local gpu_index
  gpu_index="$(_torch_pin_gpu_index "${PYTORCH_EXTRA:-pytorch-cpu}")" || return 1
  if [ -n "${gpu_index}" ]; then
    # See docs/linux-cross-builds.md § Torch pin enforcement on GPU lines
    uv pip install --index-strategy unsafe-best-match \
      --index-url "https://download.pytorch.org/whl/${gpu_index}" \
      --extra-index-url https://pypi.org/simple \
      "torch==${want_torch}+${gpu_index}" "torchvision==${want_tv}+${gpu_index}"
  else
    uv pip install --force-reinstall --no-deps \
      --index-url https://download.pytorch.org/whl/cpu \
      "torch==${want_torch}" "torchvision==${want_tv}"
  fi
}

# The GPU extra's download.pytorch.org line, empty for CPU; ROCm uses the pinned line, as the app's extra does.
_torch_pin_gpu_index() {
  case "$1" in
    pytorch-cu*)   printf '%s' "${1#pytorch-}" ;;
    pytorch-rocm*) printf '%s' "${PYTORCH_ROCM_INDEX:?PYTORCH_ROCM_INDEX unset}" ;;
    *)             printf '' ;;
  esac
}

install_project_environment() {
  activate_project_environment
  # SC2034 cannot see the helpers' nameref use.
  # shellcheck disable=SC2034
  local -a locked_skip_packages=()
  # shellcheck disable=SC2034
  local -a locked_local_wheels=()
  # shellcheck disable=SC2034
  local -a sync_args=()
  local have_lock=false

  prune_conflicting_onnx_wheels
  assert_chain_ort_wheel_staged

  cd "${APP_DIR}"
  collect_locked_local_skip_packages locked_skip_packages
  collect_locked_local_wheels locked_local_wheels
  if [ -f "${APP_DIR}/uv.lock" ]; then
    have_lock=true
  fi

  build_uv_sync_args sync_args locked_skip_packages locked_local_wheels
  run_uv_sync_with_fallback sync_args locked_local_wheels "${have_lock}"
  reconcile_local_wheels
  enforce_torch_version_pins

  # A transitive PyPI opencv-python would shadow the source-built OpenCV5 bindings.
  if staged_opencv_python_available; then
    uv_uninstall_pip_opencv
  fi

  if python3 -c 'import gi; print(gi.__version__)' 2>/dev/null; then
    echo "PyGObject already installed (system package), skipping pip install"
  else
    uv pip install PyGObject
  fi

  ensure_project_package_installed
  assert_ort_chain_only
}

# riscv64 skips uv sync, so the project and its core deps come from here; no extra, so no git torch.
ensure_project_package_installed() {
  if uv run --no-sync --active python -c 'import orchestrant' >/dev/null 2>&1; then
    echo "Project package orchestrant already installed"
    return 0
  fi
  echo "Project package orchestrant (+ core deps) missing after uv sync; installing from ${APP_DIR}"
  uv pip install "${APP_DIR}"
  install_fallback_project_extras || return 1
}

# uv sync requests --extra docs, so the fallback must too. See docs/riscv64-venv-parity.md
install_fallback_project_extras() {
  local _attempt
  for _attempt in 1 2 3; do
    if uv pip install "${APP_DIR}[docs]"; then
      # See docs/riscv64-venv-parity.md § optuna
      uv pip install optuna || \
        echo "WARNING: optuna not installed - the venv gate will name it" >&2
      return 0
    fi
    echo "WARNING: docs-extra install attempt ${_attempt}/3 failed" >&2
    [ "${_attempt}" -eq 3 ] || sleep 10
  done
  # Fail here: assert_app_venv_parity fails on the same condition later, where it is undiagnosable.
  if [ "${APP_EXTRAS_REQUIRED:-1}" = "1" ]; then
    echo "ERROR: docs extra NOT installed after 3 attempts; the venv would ship short and app-venv-parity would fail later. Set APP_EXTRAS_REQUIRED=0 to tolerate." >&2
    return 1
  fi
  echo "WARNING: docs extra NOT installed (APP_EXTRAS_REQUIRED=0); app-venv-parity will report it" >&2
  return 0
}

verify_project_environment() {
  activate_project_environment

  # A pip opencv would shadow the source-built OpenCV5 bindings (.pth to /opt/opencv5).
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
  elif [ "${ENABLE_AMD:-false}" = "true" ]; then
    # Without this a ROCm image with CPU torch and no MIGraphX EP ships green.
    echo "Testing ROCm Support (Build checks only, not runtime)"
    uv run --no-sync --active python -c "import torch; hip = torch.version.hip; print(f'PyTorch HIP Build Version: {hip}'); assert hip is not None, 'ERROR: PyTorch was NOT built with ROCm/HIP!'"
    uv run --no-sync --active python -c "import onnxruntime as ort; providers = ort.get_available_providers(); print(f'ONNX Runtime Available Providers: {providers}'); assert 'MIGraphXExecutionProvider' in providers, 'ERROR: ONNX Runtime does NOT have MIGraphXExecutionProvider!'"
  fi

  echo "Installed packages in the virtual environment:"
  uv pip list
}

usage() {
  printf 'Usage: %s [install|verify|all]\n' "${0##*/}" >&2
}

# No VCS data in the shipped image; the version comes from VERSION.txt and the working tree stays.
cleanup_app_git() {
  [ -d "${APP_DIR}/.git" ] || return 0
  rm -rf "${APP_DIR}/.git" && echo "Removed ${APP_DIR}/.git (POS1: no VCS data in the shipped image)" || true
}

main() {
  local mode="${1:-all}"

  case "${mode}" in
    install)
      prepare_project_tree
      install_project_environment
      cleanup_app_git
      ;;
    verify)
      verify_project_environment
      cleanup_app_git
      ;;
    all)
      prepare_project_tree
      install_project_environment
      verify_project_environment
      cleanup_app_git
      ;;
    *)
      usage
      exit 2
      ;;
  esac
}

main "$@"
