#!/usr/bin/env bash
# tvm-python.sh - Python venv + TVM wheel build helpers
# Split out of tvm.sh (pure structural refactor; no behavior change).
# Source-only helper; sourced by tvm.sh — expects its shell options.
# shellcheck disable=SC2154  # tvm_build_wheel reads main()'s locals (tvm_dir, prefix, ...) via bash dynamic scoping

require_toolchain_python() {
  local python_mm="${PYTHON_MAJOR_MINOR:-}"
  local python_bin=""

  if [ -z "$python_mm" ] && command -v host_python_major_minor >/dev/null 2>&1; then
    python_mm="$(host_python_major_minor 2>/dev/null || true)"
  fi

  if [ -z "$python_mm" ]; then
    die "PYTHON_MAJOR_MINOR is not set; cannot resolve the source-built toolchain Python"
  fi

  python_bin="/usr/local/bin/python${python_mm}"
  if [ ! -x "$python_bin" ]; then
    die "Expected source-built toolchain Python at ${python_bin}; TVM must use the interpreter from linux/Dockerfile.toolchain"
  fi

  printf '%s' "$python_bin"
}

tvm_build_wheel() {
    log "Setting up Python venv + TVM Python package"
    HOST_PYTHON="$(require_toolchain_python)"
    uv venv --seed "$tvm_dir/.venv" --python="$HOST_PYTHON"
    # shellcheck disable=SC1091
    source "$tvm_dir/.venv/bin/activate"
    local venv_python="${VIRTUAL_ENV}/bin/python"
    export UV_PYTHON="${VIRTUAL_ENV}/bin/python" \
           MEDIA_HOST_PYTHON="${VIRTUAL_ENV}/bin/python"

    uv pip install -U pip setuptools wheel build scikit-build-core cython setuptools-scm
    uv pip install -U numpy cloudpickle decorator psutil scipy attrs

    local TVM_WHEEL_DIR="${prefix}/wheels"
    local -a wheel_cmake_args=()
    local wheel_cmake_args_string
    mkdir -p "$TVM_WHEEL_DIR"
    rm -f "${TVM_WHEEL_DIR}"/*.whl

append_tvm_cmake_args \
      wheel_cmake_args \
      ON \
      "$build_type" \
      "$desired_cc" \
      "$desired_cxx" \
      "$llvm_cmake_value" \
      "$llvm_dir" \
      "$llvm_ignore_paths" \
      "$use_vulkan" \
      "$use_cuda" \
      "$use_opencl" \
      "$spirv_tools_lib" \
      "$cross_link_flags"

    wheel_cmake_args_string="$(shell_quote_args "${wheel_cmake_args[@]}")"

    if cross_build_is_active; then
      local wheel_platform

      wheel_platform="$(cross_wheel_platform_tag || true)"
      if [ -z "$wheel_platform" ]; then
        log "Skipping TVM wheel build in cross mode; unsupported target architecture $(cross_target_arch 2>/dev/null || echo unknown)"
      elif [ -f "$tvm_dir/pyproject.toml" ]; then
        log "Building cross TVM wheel into $TVM_WHEEL_DIR"
        if CMAKE_GENERATOR=Ninja \
          CMAKE_ARGS="${wheel_cmake_args_string}" \
          "$venv_python" -m build --wheel --no-isolation \
            --outdir "$TVM_WHEEL_DIR" \
            -Cbuild-dir="${tvm_dir}/build-wheel-${wheel_platform}" \
            "$tvm_dir"; then
          shopt -s nullglob
          local -a built_cross_wheels=("${TVM_WHEEL_DIR}"/*.whl)
          shopt -u nullglob
          if [ "${#built_cross_wheels[@]}" -eq 0 ]; then
            log "Warning: cross TVM wheel build succeeded but produced no wheel artifact"
          else
            local cross_wheel
            for cross_wheel in "${built_cross_wheels[@]}"; do
              log "Retagging cross TVM wheel for ${wheel_platform}: $(basename "${cross_wheel}")"
              "$venv_python" -m wheel tags --remove --platform-tag="${wheel_platform}" "${cross_wheel}" || \
                log "Warning: failed to retag cross TVM wheel $(basename "${cross_wheel}")"
            done
          fi
        else
          log "Warning: cross TVM wheel build failed"
        fi
      else
        log "TVM python packaging not detected for wheel build; skipped"
      fi
    else
      if [ -f "$tvm_dir/pyproject.toml" ]; then
        log "Building TVM wheel into $TVM_WHEEL_DIR"
        CMAKE_GENERATOR=Ninja \
        CMAKE_ARGS="${wheel_cmake_args_string}" \
        "$venv_python" -m build --wheel --no-isolation \
          --outdir "$TVM_WHEEL_DIR" \
          -Cbuild-dir="${tvm_dir}/build-wheel-native" \
          "$tvm_dir" || log "Warning: TVM wheel build failed"
      else
        log "TVM python packaging not detected for wheel build; skipped"
      fi

      if [ -f "$tvm_dir/3rdparty/tvm-ffi/pyproject.toml" ]; then
        log "Installing Apache TVM FFI Python package from source tree"
        uv pip install "$tvm_dir/3rdparty/tvm-ffi"
      else
        log "Local Apache TVM FFI package not found; relying on apache-tvm-ffi from the Python package resolver"
      fi

      shopt -s nullglob
      local -a built_wheels=("${TVM_WHEEL_DIR}"/*.whl)
      shopt -u nullglob

      if [ "${#built_wheels[@]}" -gt 0 ]; then
        log "Installing TVM Python wheel ${built_wheels[0]}"
        uv pip install "${built_wheels[0]}"
      else
        log "Wheel build unavailable; installing TVM Python package from source tree"
        uv pip install "$tvm_dir"
      fi

      uv pip install -U pytest
      verify_python_import "tvm" "tvm.__version__"
    fi
}
