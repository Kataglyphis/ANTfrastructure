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

# Create the venv + install build deps, and assemble the wheel CMake args string.
# Sets venv_python / TVM_WHEEL_DIR / wheel_cmake_args_string in tvm_build_wheel's
# scope (dynamic scoping); reads main()'s build config locals the same way.
_tvm_wheel_setup() {
    log "Setting up Python venv + TVM Python package"
    HOST_PYTHON="$(require_toolchain_python)"
    uv venv --seed "$tvm_dir/.venv" --python="$HOST_PYTHON"
    # shellcheck disable=SC1091
    source "$tvm_dir/.venv/bin/activate"
    venv_python="${VIRTUAL_ENV}/bin/python"
    export UV_PYTHON="${VIRTUAL_ENV}/bin/python" \
           MEDIA_HOST_PYTHON="${VIRTUAL_ENV}/bin/python"

    # Build-executor pins (supply-chain audit #18): these packages EXECUTE code
    # at build time; unpinned installs made every build resolve them fresh.
    # Inline defaults mirror versions.env (safety-net convention).
    uv pip install -U pip \
      "setuptools==${PY_SETUPTOOLS_VERSION:-83.0.0}" \
      "wheel==${PY_WHEEL_VERSION:-0.47.0}" \
      build \
      "scikit-build-core==${PY_SCIKIT_BUILD_CORE_VERSION:-1.0.3}" \
      "cython==${PY_CYTHON_VERSION:-3.2.9}" \
      "setuptools-scm==${PY_SETUPTOOLS_SCM_VERSION:-10.2.1}"
    uv pip install -U numpy cloudpickle decorator psutil scipy attrs

    TVM_WHEEL_DIR="${prefix}/wheels"
    mkdir -p "$TVM_WHEEL_DIR"
    rm -f "${TVM_WHEEL_DIR}"/*.whl

    local -a wheel_cmake_args=()
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
      "$cross_link_flags" \
      "$vulkan_library" \
      "$vulkan_include"
    wheel_cmake_args_string="$(shell_quote_args "${wheel_cmake_args[@]}")"
}

# Run `python -m build` for one mode, mirroring its output into a log file so a
# failure can be EXPLAINED and not merely announced. Returns the builder's rc.
_tvm_run_wheel_build() {
    local build_dir_suffix="$1" build_log="$2"
    # pipefail is LOAD-BEARING for every diagnostic in this file. `... | tee LOG`
    # reports TEE's status (always 0) unless pipefail is on, so `if !
    # _tvm_run_wheel_build` would never fire, TVM_WHEEL_SKIP_REASON would never
    # be set, and a failed wheel build would read as a success again — exactly
    # the silence _tvm_wheel_verdict exists to end. tvm.sh:2 sets it; ASSERT it
    # rather than assume, because the failure mode leaves no trace. Fatal here is
    # safe: Dockerfile.media already treats a non-zero tvm.sh as "ship without
    # TVM python (non-fatal)".
    if [[ ! -o pipefail ]]; then
      die "tvm-python.sh: 'set -o pipefail' is not enabled; the tee'd wheel build would mask its own failure and every TVM diagnostic below would be dead code"
    fi
    CMAKE_GENERATOR=Ninja \
    CMAKE_ARGS="${wheel_cmake_args_string}" \
    "$venv_python" -m build --wheel --no-isolation \
      --outdir "$TVM_WHEEL_DIR" \
      -Cbuild-dir="${tvm_dir}/build-wheel-${build_dir_suffix}" \
      "$tvm_dir" 2>&1 | tee "$build_log"
}

# `--no-isolation` is deliberate (an isolated tree would refetch and recompile
# everything the native build just produced), but it also means nothing installs
# TVM's pyproject build-requires: ONE missing entry aborts at "Getting build
# dependencies for wheel" before a single object is compiled. Echo that list back
# — it is both the diagnosis and the fix (pin it in _tvm_wheel_setup's
# build-executor list). Wave-5 2026-08-21 died this way on all three arches
# ("ERROR Missing dependencies: mlc-z3-static>=4.16.0") AFTER the 2 h (arm64) /
# 7.5 h (amd64) native compile had already succeeded.
_tvm_wheel_missing_build_requires() {
    local build_log="$1"
    [ -s "$build_log" ] || return 0
    # Bounded at BOTH ends. The predecessor was a `sed -n '/Missing
    # dependencies/,/^[[:space:]]*$/p'` range: a sed range whose closing address
    # never matches runs to EOF, and pypa/build prints the dep list as its LAST
    # output with no trailing blank line — so the "missing deps" string absorbed
    # every following log line (tracebacks, ninja noise) into one unreadable
    # blob. Here collection starts at the marker and stops at the first line
    # that is not an indented continuation (build emits '\n\t' + dep per
    # entry), plus a hard line cap. A same-line "Missing dependencies: foo" is
    # picked up too — the old `1d` dropped that spelling entirely.
    awk -v max="${_TVM_MISSING_DEPS_MAX_LINES:-20}" '
      /Missing dependencies/ {
        collecting = 1
        rest = $0
        sub(/^.*Missing dependencies:?[[:space:]]*/, "", rest)
        if (rest != "") { deps = rest; n = 1 }
        next
      }
      collecting {
        if ($0 !~ /^[[:space:]]+[^[:space:]]/) exit
        sub(/^[[:space:]]+/, ""); sub(/[[:space:]]+$/, "")
        deps = deps (deps == "" ? "" : " ") $0
        if (++n >= max) exit
      }
      END { if (deps != "") printf "%s", deps }
    ' "$build_log"
}

# Cross mode: build the wheel for the target platform and retag it. Guard clauses
# handle the unsupported-arch / no-pyproject / build-failed / no-artifact cases;
# each records WHY in TVM_WHEEL_SKIP_REASON for _tvm_wheel_verdict.
_tvm_build_wheel_cross() {
    local wheel_platform
    wheel_platform="$(cross_wheel_platform_tag || true)"
    if [ -z "$wheel_platform" ]; then
      TVM_WHEEL_SKIP_REASON="cross mode: no wheel platform tag for target $(cross_target_arch 2>/dev/null || echo unknown)"
      warn "Skipping TVM wheel build in cross mode; unsupported target architecture $(cross_target_arch 2>/dev/null || echo unknown)"
      return 0
    fi
    if [ ! -f "$tvm_dir/pyproject.toml" ]; then
      TVM_WHEEL_SKIP_REASON="TVM ${ref} ships no pyproject.toml (upstream python packaging layout changed)"
      warn "TVM python packaging not detected for wheel build; skipped"
      return 0
    fi

    local build_log="${tvm_dir}/tvm-wheel-build-cross.log"
    log "Building cross TVM wheel into $TVM_WHEEL_DIR"
    if ! _tvm_run_wheel_build "${wheel_platform}" "${build_log}"; then
      local missing
      missing="$(_tvm_wheel_missing_build_requires "${build_log}")"
      TVM_WHEEL_SKIP_REASON="cross wheel build failed${missing:+ — unsatisfied build-requires under --no-isolation: ${missing}}"
      warn "cross TVM wheel build failed${missing:+; missing build-requires: ${missing}}"
      return 0
    fi

    shopt -s nullglob
    local -a built_cross_wheels=("${TVM_WHEEL_DIR}"/*.whl)
    shopt -u nullglob
    if [ "${#built_cross_wheels[@]}" -eq 0 ]; then
      TVM_WHEEL_SKIP_REASON="cross wheel build reported success but emitted no .whl into ${TVM_WHEEL_DIR}"
      warn "cross TVM wheel build succeeded but produced no wheel artifact"
      return 0
    fi
    log "Retagging cross TVM wheel(s) in ${TVM_WHEEL_DIR} for ${wheel_platform}"
    # Canonical retag helper from 01-core/common.sh (sourced via tvm.sh).
    retag_directory_wheels "${TVM_WHEEL_DIR}" "*" "${wheel_platform}" "$venv_python"
}

# Native mode: build the wheel, then install tvm-ffi + the built wheel (or the
# source-tree fallback) into the BUILD venv.
_tvm_build_wheel_native() {
    local build_log="${tvm_dir}/tvm-wheel-build-native.log"
    if [ -f "$tvm_dir/pyproject.toml" ]; then
      log "Building TVM wheel into $TVM_WHEEL_DIR"
      if ! _tvm_run_wheel_build native "${build_log}"; then
        local missing
        missing="$(_tvm_wheel_missing_build_requires "${build_log}")"
        TVM_WHEEL_SKIP_REASON="native wheel build failed${missing:+ — unsatisfied build-requires under --no-isolation: ${missing}}"
        warn "TVM wheel build failed${missing:+; missing build-requires: ${missing}}"
      fi
    else
      TVM_WHEEL_SKIP_REASON="TVM ${ref} ships no pyproject.toml (upstream python packaging layout changed)"
      warn "TVM python packaging not detected for wheel build; skipped"
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
      # This fallback runs an ISOLATED uv build, so it succeeds exactly where
      # `-m build --no-isolation` failed — and that made the whole step look
      # healthy: apache-tvm installs, the import check below prints a version,
      # tvm.sh exits 0. But it installs into $tvm_dir/.venv, which sits on the
      # stage's tmpfs and dies with the stage; NOTHING reaches ${TVM_WHEEL_DIR},
      # so the image ships without `import tvm`. Keep the skip reason set.
      log "Wheel build unavailable; installing TVM Python package from source tree"
      uv pip install "$tvm_dir"
      TVM_WHEEL_SKIP_REASON="${TVM_WHEEL_SKIP_REASON:-native wheel build produced no artifact}; the source-tree fallback installed apache-tvm into the throwaway build venv (${VIRTUAL_ENV:-$tvm_dir/.venv}) only"
    fi

    uv pip install -U pytest
}

# Final verdict, on stderr so it survives log clipping.
#
# THE defect this closes (backlog ORPHAN-PINS): the media stage prints
# `TVM build OK; wheel(s):` followed by `ls -1 /opt/tvm/wheels/`, which prints
# NOTHING when that directory is empty — so a wheel-less run rendered as the
# reassuring pair "TVM build OK" + "DONE" while `import tvm` was missing from all
# three shipped arches and Dockerfile.media claimed it worked. Never fatal: TVM is
# best-effort by design, the defect was the SILENCE, not the absence.
_tvm_wheel_verdict() {
    shopt -s nullglob
    local -a staged=("${TVM_WHEEL_DIR}"/*.whl)
    shopt -u nullglob

    if [ "${#staged[@]}" -gt 0 ]; then
      log "TVM VERDICT: python wheel staged in ${TVM_WHEEL_DIR}: ${staged[*]##*/}"
      return 0
    fi

    warn "TVM VERDICT: NO python wheel staged in ${TVM_WHEEL_DIR} — 'import tvm' will NOT work in the shipped image"
    warn "TVM VERDICT: reason: ${TVM_WHEEL_SKIP_REASON:-unknown (the wheel step reported success but left ${TVM_WHEEL_DIR} empty)}"

    # The consolation line is only worth printing if it is TRUE. It used to be
    # unconditional — an unverified claim that the native runtime "still ships",
    # printed on the one path where nothing else about the step can be trusted.
    # Both layouts are checked: CMake installs libtvm to lib64 on some
    # distro/arch combinations, which is why Dockerfile.media:431 exists to fold
    # /opt/tvm/lib64 back into /opt/tvm/lib AFTER this script returns.
    shopt -s nullglob
    local -a native_libs=("${prefix}/lib"/libtvm*.so* "${prefix}/lib64"/libtvm*.so*)
    shopt -u nullglob
    if [ "${#native_libs[@]}" -gt 0 ]; then
      warn "TVM VERDICT: the native runtime DOES still ship (${native_libs[*]}); only the Python package is absent (smoke: 'tvm not importable')"
    else
      warn "TVM VERDICT: and NO libtvm*.so under ${prefix}/lib or ${prefix}/lib64 either — this stage produced no usable TVM at all, native or Python"
    fi
    return 0
}

tvm_build_wheel() {
    # Shared across the phase helpers below (assigned by _tvm_wheel_setup).
    local venv_python="" TVM_WHEEL_DIR="" wheel_cmake_args_string=""
    # Filled in by whichever guard clause fired; read by _tvm_wheel_verdict.
    local TVM_WHEEL_SKIP_REASON=""
    _tvm_wheel_setup
    if cross_build_is_active; then
      _tvm_build_wheel_cross
    else
      _tvm_build_wheel_native
    fi
    _tvm_wheel_verdict
    # Native only, and deliberately AFTER the verdict: this checks the BUILD
    # venv, not the image, and its non-zero return aborts tvm.sh under `set -e`
    # — running it first would let the one signal that survives a fully "green"
    # run be suppressed by the one failure mode that is already loud.
    cross_build_is_active || verify_python_import "tvm" "tvm.__version__"
}
