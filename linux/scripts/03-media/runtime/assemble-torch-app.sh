#!/usr/bin/env bash
set -Eeuo pipefail

# A set -e death in these image-side scripts printed nothing at all until
# 2026-09-03. docs/failure-modes.md#a-packaging-script-dies-with-no-message
# shellcheck source=linux/scripts/01-core/logging.sh
source /opt/scripts/core/logging.sh
install_err_trap

: "${VENV:?VENV must be set}"
: "${ONNX_PACKAGE:?ONNX_PACKAGE must be set}"
: "${PYTORCH_EXTRA:=pytorch-cpu}"

APP_DIR="/opt/Kataglyphis-Orchestr-ANT-ion"
APP_REF="${APP_REF:-v0.0.27}"

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

prepare_project_tree() {
  local _attempt
  rm -rf "${APP_DIR}"
  # Retry inlined rather than reusing 01-core's retry(): this script ships
  # standalone into images (Dockerfile.torch) that carry no 01-core.
  for _attempt in 1 2 3; do
    if git clone --branch "${APP_REF}" --depth 1 https://github.com/Kataglyphis/Orchestr-ANT-ion.git "${APP_DIR}"; then
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

  # riscv64 is excluded from the app's `[tool.uv] environments`, and uv then HARD-
  # REJECTS it (exit 2) instead of resolving live. Strip the gate from THIS clone only.
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
    onnxruntime-*.whl|onnxruntime_gpu-*.whl|onnxruntime_migraphx-*.whl|onnxruntime_webgpu-*.whl|onnxruntime_dnnl-*.whl)
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
      # Any local ORT variant must beat the lock's PyPI onnxruntime -- both dists own
      # site-packages/onnxruntime/, and the mix leaves a version-skewed capi behind.
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
        # Always locked, never conditional on opencv: dropping one lets pip resolve
        # UPSTREAM torch over the custom build.
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

# Remove prebuilt wheels that conflict with the selected ONNX_PACKAGE variant.
prune_conflicting_onnx_wheels() {
  case "${ONNX_PACKAGE}" in
    onnxruntime|onnxruntime-webgpu)
      # GPU-flavoured genai only: a bare *genai* glob deletes the CPU wheel
      # build_uv_sync_args needs. docs/failure-modes.md
      rm -f /opt/wheels/*_gpu-*.whl /opt/wheels/*_migraphx-*.whl \
            /opt/wheels/*genai_cuda-*.whl /opt/wheels/*genai_rocm-*.whl \
            /opt/wheels/*genai_directml-*.whl || true
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

# Assemble the `uv sync` args into $1; locked packages from local wheels ($2 names,
# $3 wheels) are skipped and installed directly. Namerefs _-prefixed (circular ref).
build_uv_sync_args() {
  local -n _sync_args="$1"
  local -n _locked_skip="$2"
  local -n _locked_wheels="$3"
  local package_name

  # No GUI extra: it pulls wxPython, which is unused here and fails on Python 3.14.
  _sync_args=(--find-links /opt/wheels --active \
    --extra "ml-ai" \
    --extra "docs")

  # With torch from a local wheel (riscv64), the backend extra below must NOT be
  # requested: its torch entry makes uv resolve the upstream source over our wheel.
  local _torch_from_local_wheel=false
  for package_name in "${_locked_skip[@]}"; do
    case "${package_name}" in torch|torchvision) _torch_from_local_wheel=true ;; esac
  done

  # `torch` is declared ONLY in the app's pytorch-* backend extras, never in ml-ai,
  # so the extra MUST be requested or the image ships torch-less. "none"/"" disables it.
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
      # --no-deps on EVERY local-wheel force-reinstall: without it uv re-resolves the
      # wheels' deps to LATEST and floats the venv off the lock (numpy, protobuf MAJOR).
      uv pip install --no-deps --force-reinstall "${_locked_wheels[@]}"
    fi
  fi

  # --find-links only OFFERS /opt/wheels, so the app lock's pinned genai would win over
  # the freshly built wheel. Same pre-install + --no-install-package idiom as above.
  local _genai_wheel
  _genai_wheel="$(ls /opt/wheels/onnxruntime_genai-*.whl 2>/dev/null | head -1 || true)"
  if [ -n "${_genai_wheel}" ]; then
    printf 'Pinning local onnxruntime-genai wheel over the app lock: %s\n' "${_genai_wheel##*/}"
    uv pip install --no-deps --force-reinstall "${_genai_wheel}"
    _sync_args+=(--no-install-package onnxruntime-genai)
  fi

  if [ "${SKIP_TORCH_TEST_EXTRAS:-false}" != "true" ]; then
    _sync_args+=(--extra "test")
  fi
}

# `uv lock` regeneration for the fallbacks below. A riscv64 RESOLUTION failure is
# tolerated (the local wheels carry the venv); on amd64/arm64 it aborts.
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
    if uv sync "${frozen_sync_args[@]}"; then
      return 0
    fi
    echo "Frozen upstream uv.lock failed for this Python/platform"
  fi

  # riscv64: skip uv lock + uv sync entirely. The app's pyproject declares torch
  # as `torch @ git+...` in the pytorch extras, so `uv lock` builds torch from
  # git source under QEMU (hours of C++ compile) just for metadata — even though
  # a prebuilt wheel is already installed from /opt/wheels. The local wheels are
  # pre-installed by build_uv_sync_args; ensure_project_package_installed then
  # installs the project's pure-Python core deps (no torch extras). This saves
  # ~1h of QEMU emulation per riscv64 build.
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

# After uv sync, force-reinstall the prebuilt local wheels, first uninstalling
# any PyPI onnxruntime/opencv families they replace so the local builds win.
# Uninstall any PyPI build of a family we ship locally, BEFORE force-reinstalling
# ours: an upstream pulled transitively (often under a variant name --
# onnxruntime-gpu, opencv-python 4.x) would otherwise shadow the custom build.
# torch/torchvision/ai-edge-litert are purged here too, for symmetry.
_purge_shadowing_pypi_builds() {
  local have_onnx_family="$1" have_opencv_family="$2"
  local have_torch_family="$3" have_litert_family="$4"
  if [ "${have_onnx_family}" = "true" ]; then
    uv pip uninstall onnxruntime onnxruntime-gpu onnxruntime-migraphx onnxruntime-webgpu onnxruntime-dnnl 2>/dev/null || true
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

# torch's own runtime deps the sync graph can miss. The PACKAGE name is
# installed, the MODULE name imported -- they differ for typing-extensions.
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

# Install order is load-bearing -- other, then tvm, then iree.
# Nameref params carry their own names: -n x="x" is a circular reference.
_install_wheel_groups() {
  local -n _ow="$1" _tw="$2" _iw="$3"
if [ "${#_ow[@]}" -gt 0 ]; then
  # --no-deps: see the locked-wheels comment above — THIS site produced the
  # live numpy/protobuf float (log: "- numpy==2.5.1 / + numpy==2.5.2" 0.5 s
  # after uv sync had just enforced the lock).
  uv pip install --no-deps --force-reinstall "${_ow[@]}"
  # --no-deps above means the ORT wheel's OWN runtime requirements are never
  # installed. On riscv64 the sync did not supply them either, so the shipped
  # venv carried a dangling edge: the wheel declares flatbuffers and protobuf,
  # the venv has neither, and that surfaces as an ImportError in the USER's
  # process -- never in our build. Both publish a pure-Python `any` wheel.
  # protobuf is major-pinned deliberately: an unconstrained resolve is exactly
  # the "protobuf MAJOR" float the comment above warns about (the 2026-09-02
  # run installed 6.33.6 twice and 7.36.1 once).
  # docs/refactoring-backlog.md AB
  uv pip install 'protobuf>=6,<7' flatbuffers || \
    echo "WARNING: ORT runtime deps (protobuf/flatbuffers) not installed - the venv gate will name them"
fi
if [ "${#_tw[@]}" -gt 0 ]; then
  uv pip install --no-deps --force-reinstall "${_tw[@]}" || \
    echo "WARNING: TVM wheel install failed (optional; import tvm will optional-fail; native libs unaffected)"
fi
if [ "${#_iw[@]}" -gt 0 ]; then
  if [ "$(uname -m)" = "riscv64" ]; then
    # riscv64: install IREE --no-deps (its ml_dtypes/numpy deps have no riscv64
    # wheels and a full-deps resolve would try to pull them). numpy is already
    # present from the sync.
    uv pip install --no-deps --force-reinstall "${_iw[@]}" || \
      echo "WARNING: IREE riscv64 runtime wheel install failed (non-fatal; check_iree will optional-fail)"
    # ml_dtypes has no riscv64 PyPI wheel, so source-build it INTO this venv
    # (best-effort). It must go here, not via apt in setup-package-image.sh — the
    # from-source py3.14 venv can't see the distro python's dist-packages. Without
    # it `import iree.runtime` fails "No module named 'ml_dtypes'" (the runtime
    # smoke WARN); the native iree-compile path is unaffected either way.
    uv pip install ml_dtypes || \
      echo "WARNING: ml_dtypes source-build failed on riscv64 (iree.runtime bf16 dtypes unavailable; native iree-compile unaffected)"
  else
    # amd64/arm64: the cp314 wheel replaces any PyPI cp312-abi3 build. IREE's
    # runtime deps (numpy from the lock; ml_dtypes) must NOT be re-resolved
    # here — a full-deps force-reinstall floats numpy off the lock (the
    # 2026-08-11 2.5.2 incident, second injector). Install the wheels
    # --no-deps, then ml_dtypes alone (absent from the app lock).
    # Hard-fail under set -e -- IREE is REQUIRED here.
    uv pip install --no-deps --force-reinstall "${_iw[@]}"
    uv pip install --no-deps ml_dtypes
  fi
fi

# When torch ships as a LOCAL wheel (riscv64) its backend extra is never
# requested from uv sync, so the lock graph omits torch's own runtime deps —
# and the --no-deps force-reinstall above (correctly) no longer drags them
# in as a side effect. Result on riscv64: `import torchvision` dies with
# "No module named 'sympy'" (torch.fx symbolic shapes) while torch's core
# ops happen to work. Backfill exactly the missing pure-python leaves,
# --no-deps each (their own hard deps are in the list: sympy->mpmath,
# jinja2->markupsafe). amd64/arm64 get all of these from the lock and the
# import probes skip everything.
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

  # Overridable ONLY so this function can be exercised off-target: /opt is
  # root-owned, so a test cannot put fixtures where the image keeps its wheels.
  # Unset, this is exactly /opt/wheels. docs/refactoring-backlog.md F1
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
  _partition_wheels_by_install_group iree_wheels tvm_wheels other_wheels "${local_wheels[@]}"

  _install_wheel_groups other_wheels tvm_wheels iree_wheels
  if [ "${have_torch_family}" = "true" ]; then
    _backfill_torch_runtime_deps
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
  install_fallback_project_extras || return 1
}

# uv sync requests --extra docs on every arch, so the fallback above must too or
# riscv64 silently ships ~24 fewer packages. Runs AFTER the project install (that
# one satisfies the closure's only sdist-only member, pyyaml) and never replaces
# it. `ml-ai` stays out on purpose. docs/riscv64-venv-parity.md
install_fallback_project_extras() {
  local _attempt
  for _attempt in 1 2 3; do
    if uv pip install "${APP_DIR}[docs]"; then
      # optuna: pure-Python ml-ai member, absent on riscv64. Must run after the
      # project install above. docs/riscv64-venv-parity.md#optuna
      uv pip install optuna || \
        echo "WARNING: optuna not installed - the venv gate will name it" >&2
      return 0
    fi
    echo "WARNING: docs-extra install attempt ${_attempt}/3 failed" >&2
    [ "${_attempt}" -eq 3 ] || sleep 10
  done
  # Fail HERE, not three stages later. assert_app_venv_parity fails hard on the
  # same condition, so returning 0 only moved the failure somewhere undiagnosable.
  # APP_EXTRAS_REQUIRED=0 downgrades it. docs/riscv64-venv-parity.md
  if [ "${APP_EXTRAS_REQUIRED:-1}" = "1" ]; then
    echo "ERROR: docs extra NOT installed after 3 attempts; the venv would ship short and app-venv-parity would fail later. Set APP_EXTRAS_REQUIRED=0 to tolerate." >&2
    return 1
  fi
  echo "WARNING: docs extra NOT installed (APP_EXTRAS_REQUIRED=0); app-venv-parity will report it" >&2
  return 0
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

# POS1 (2026-08-17): the cloned app tree shipped WITH its .git (packed objects,
# remote URL, history) in the final uid-1001 image — attack-surface/hygiene +
# size + provenance leak. The package is pip-installed into the venv and the
# app's version comes from VERSION.txt (not setuptools-scm), so .git is dead
# weight once install is done. Remove ONLY .git; the working tree stays (it may
# be consulted at runtime). Best-effort — never fails a completed install.
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
