#!/usr/bin/env bash
# TVM wheel build helpers; sourced by tvm.sh, whose shell options it expects.
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

# tvm-ffi's Cython core takes the build venv's SOABI, so point sysconfig at the target's; echoes an eval-able export.
_tvm_target_python_sysconfig_export() {
    cross_build_is_active || return 0

    local triplet="" name="" stage_root="" dir="" search_root=""

    triplet="$(cross_target_triplet 2>/dev/null || true)"
    [ -n "${triplet}" ] || return 0
    name="_sysconfigdata__linux_${triplet}"
    stage_root="$(cross_target_python_root 2>/dev/null || true)"

    for search_root in ${stage_root:+"${stage_root}/lib"} "/usr/lib"; do
      [ -d "${search_root}" ] || continue
      # -maxdepth 4: the staged interpreter keeps it in lib/python3.X/lib-dynload/.
      dir="$(find "${search_root}" -maxdepth 4 -name "${name}.py" -printf '%h\n' -quit 2>/dev/null || true)"
      [ -n "${dir}" ] && break
    done

    if [ -z "${dir}" ]; then
      # >&2: this function's stdout is eval'd.
      warn "Target Python sysconfigdata ${name}.py not found under ${stage_root:-<no staged target python>}/lib or /usr/lib; the apache-tvm-ffi extension would be stamped with the amd64 host SOABI and the staged wheels will be withdrawn below" >&2
      return 0
    fi

    printf 'export _PYTHON_SYSCONFIGDATA_NAME=%q; export PYTHONPATH=%q${PYTHONPATH:+:${PYTHONPATH}}' \
      "${name}" "${dir}"
}

# Sets tvm_build_wheel's venv_python/TVM_WHEEL_DIR/wheel_cmake_args_string by dynamic scope.
_tvm_wheel_setup() {
    log "Setting up Python venv + TVM Python package"
    HOST_PYTHON="$(require_toolchain_python)"
    uv venv --seed "$tvm_dir/.venv" --python="$HOST_PYTHON"
    # shellcheck disable=SC1091
    source "$tvm_dir/.venv/bin/activate"
    venv_python="${VIRTUAL_ENV}/bin/python"
    export UV_PYTHON="${VIRTUAL_ENV}/bin/python" \
           MEDIA_HOST_PYTHON="${VIRTUAL_ENV}/bin/python"

    # Pinned build executors, plus mlc-z3-static: --no-isolation installs no build-requires.
    uv pip install -U pip \
      "setuptools==${PY_SETUPTOOLS_VERSION:-84.0.0}" \
      "wheel==${PY_WHEEL_VERSION:-0.48.0}" \
      build \
      "scikit-build-core==${PY_SCIKIT_BUILD_CORE_VERSION:-1.1.1}" \
      "cython==${PY_CYTHON_VERSION:-3.2.9}" \
      "setuptools-scm==${PY_SETUPTOOLS_SCM_VERSION:-10.3.4}" \
      "mlc-z3-static==${PY_MLC_Z3_STATIC_VERSION:-4.16.0}"
    uv pip install -U numpy cloudpickle decorator psutil scipy attrs

    TVM_WHEEL_DIR="${prefix}/wheels"
    mkdir -p "$TVM_WHEEL_DIR"
    rm -f "${TVM_WHEEL_DIR}"/*.whl

    local -a wheel_cmake_args=()
    append_tvm_cmake_args \
      --out wheel_cmake_args \
      --python-module ON \
      --build-type "$build_type" \
      --cc "$desired_cc" \
      --cxx "$desired_cxx" \
      --llvm-cmake-value "$llvm_cmake_value" \
      --llvm-dir "$llvm_dir" \
      --llvm-ignore-paths "$llvm_ignore_paths" \
      --use-vulkan "$use_vulkan" \
      --use-cuda "$use_cuda" \
      --use-opencl "$use_opencl" \
      --spirv-tools-lib "$spirv_tools_lib" \
      --cross-link-flags "$cross_link_flags" \
      --vulkan-library "$vulkan_library" \
      --vulkan-include "$vulkan_include"
    wheel_cmake_args_string="$(shell_quote_args "${wheel_cmake_args[@]}")"

    # Empty on native and when the target sysconfigdata is missing.
    tvm_wheel_sysconfig_export="$(_tvm_target_python_sysconfig_export)"
}

# <suffix> <log> [src] [-C...]: returns the builder's rc; -C settings outrank [tool.scikit-build].
_tvm_run_wheel_build() {
    local build_dir_suffix="$1" build_log="$2" src_dir="${3:-$tvm_dir}"
    shift 2
    [ $# -eq 0 ] || shift
    # Without pipefail `| tee` reports tee's status and every diagnostic below is dead code.
    if [[ ! -o pipefail ]]; then
      die "tvm-python.sh: 'set -o pipefail' is not enabled; the tee'd wheel build would mask its own failure and every TVM diagnostic below would be dead code"
    fi
    # Subshell: only the wheel build may see the sysconfig redirect.
    (
      if [ -n "${tvm_wheel_sysconfig_export:-}" ]; then
        eval "${tvm_wheel_sysconfig_export}"
      fi
      CMAKE_GENERATOR=Ninja \
      CMAKE_ARGS="${wheel_cmake_args_string}" \
      "$venv_python" -m build --wheel --no-isolation \
        --outdir "$TVM_WHEEL_DIR" \
        -Cbuild-dir="${tvm_dir}/build-wheel-${build_dir_suffix}" \
        "$@" \
        "$src_dir"
    ) 2>&1 | tee "$build_log"
}

# <suffix> [-C...]: consumers install --no-deps, so apache_tvm without its ffi sibling cannot import; call after it.
_tvm_stage_ffi_wheel() {
    local mode="$1"; shift
    local ffi_dir="${tvm_dir}/3rdparty/tvm-ffi"
    if [ ! -f "${ffi_dir}/pyproject.toml" ]; then
      warn "tvm-ffi source tree has no pyproject.toml (${ffi_dir}) — cannot stage the ffi wheel"
      # Withdraw the main wheel too, or the verdict reads green.
      rm -f "${TVM_WHEEL_DIR}"/*.whl
      TVM_WHEEL_SKIP_REASON="tvm-ffi ships no pyproject.toml (${ffi_dir}); an apache-tvm wheel without its tvm_ffi companion cannot import (consumer installs --no-deps and tvm_ffi is import #1), so the set was withdrawn"
      return 0
    fi
    local build_log="${tvm_dir}/tvm-ffi-wheel-build-${mode}.log"
    log "Building apache-tvm-ffi wheel into ${TVM_WHEEL_DIR}"
    if ! _tvm_run_wheel_build "ffi-${mode}" "${build_log}" "${ffi_dir}" "$@"; then
      local missing
      missing="$(_tvm_wheel_missing_build_requires "${build_log}")"
      warn "apache-tvm-ffi wheel build failed${missing:+; missing build-requires: ${missing}}"
      rm -f "${TVM_WHEEL_DIR}"/*.whl
      TVM_WHEEL_SKIP_REASON="apache-tvm-ffi wheel build failed${missing:+ — unsatisfied build-requires under --no-isolation: ${missing}}; an apache-tvm wheel without its tvm_ffi companion cannot import, so the set was withdrawn"
    fi
    return 0
}

# tvm-ffi again on a cp314t venv in the GIL pass's build dir, so only its Cython core recompiles; apache-tvm is py3 and needs none.
_tvm_stage_ffi_wheel_free_threaded() {
    local ft_venv="${tvm_dir}/.venv-cp314t" ft_out="${tvm_dir}/dist-cp314t" ft_log="${tvm_dir}/tvm-ffi-wheel-build-cp314t.log" since
    compgen -G "${TVM_WHEEL_DIR}/apache_tvm_ffi-*.whl" >/dev/null || return 0
    # shellcheck source=../03-media/free-threaded-wheels.sh
    source "${SCRIPT_DIR}/../03-media/free-threaded-wheels.sh" || die "TVM: free-threaded-wheels.sh is not mounted; its RUN needs the per-file mount"
    ft_twin_start apache-tvm-ffi "${ft_venv}" "${venv_python}" scikit-build-core cython setuptools-scm setuptools wheel build \
      || { [ $? -eq 1 ] && return 0; die "TVM: the apache-tvm-ffi cp314t twin cannot be built (see above)"; }
    since="${SECONDS}"
    (
      venv_python="${ft_venv}/bin/python" TVM_WHEEL_DIR="${ft_out}"
      _tvm_run_wheel_build "ffi-native" "${ft_log}" "${tvm_dir}/3rdparty/tvm-ffi"
    ) || die "TVM: the free-threaded apache-tvm-ffi build failed (${ft_log})"
    log "TVM: build-wheel-ffi-native rebuilt for cp314t in $(( SECONDS - since ))s"
    ft_twin_store_built "${ft_out}" "${prefix}/wheels-cp314t" || die "TVM: no proved apache-tvm-ffi cp314t twin (see above)"
    rm -rf "${ft_venv}" "${ft_out}"
}

# --no-isolation installs no build-requires; echo the missing ones, to pin in _tvm_wheel_setup.
_tvm_wheel_missing_build_requires() {
    local build_log="$1"
    [ -s "$build_log" ] || return 0
    # Bounded at both ends: pypa/build prints the list last with no closing blank line.
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

# Withdraws every staged wheel if any carries a wrong-SOABI extension: `import tvm` needs both.
_tvm_reject_wrong_soabi_wheels() {
    local triplet="" py_tag="" expected="" bad="" entry=""

    triplet="$(cross_target_triplet 2>/dev/null || true)"
    py_tag="$("$venv_python" -c 'import sys; print(f"{sys.version_info.major}{sys.version_info.minor}")' 2>/dev/null || true)"
    if [ -z "${triplet}" ] || [ -z "${py_tag}" ]; then
      warn "TVM cross wheel SOABI check SKIPPED (triplet='${triplet}' python-tag='${py_tag}'); the staged wheels are NOT proven importable on the target"
      return 0
    fi
    # Host and target Python share a version, so only the triple comes from the cross env.
    expected=".cpython-${py_tag}-${triplet}.so"

    bad="$("$venv_python" -c '
import glob, os, re, sys, zipfile
expected, wheel_dir = sys.argv[1], sys.argv[2]
for wheel in sorted(glob.glob(os.path.join(wheel_dir, "*.whl"))):
    try:
        members = zipfile.ZipFile(wheel).namelist()
    except Exception:
        continue
    for name in members:
        base = name.rsplit("/", 1)[-1]
        if not base.endswith(".so") or not re.search(r"\.cpython-\d+-", base):
            continue
        if not base.endswith(expected):
            print(os.path.basename(wheel) + " :: " + name)
' "${expected}" "${TVM_WHEEL_DIR}")" || {
      # A scanner failure must NOT read as "clean"; say the check did not run.
      warn "TVM cross wheel SOABI check FAILED to run (zip scan errored); the staged wheels are NOT proven importable on the target"
      return 0
    }

    if [ -z "${bad}" ]; then
      log "TVM cross wheels: every native CPython extension carries ${expected}"
      return 0
    fi

    while IFS= read -r entry; do
      [ -n "${entry}" ] || continue
      warn "cross TVM wheel carries a wrong-SOABI extension (expected ${expected}): ${entry}"
    done <<< "${bad}"
    rm -f "${TVM_WHEEL_DIR}"/*.whl
    TVM_WHEEL_SKIP_REASON="cross wheels were stamped with the build-host SOABI instead of ${expected} — they install on $(cross_target_arch 2>/dev/null || echo "the target") and then fail at 'import tvm_ffi'; withdrawn so the image does not ship an unimportable tvm"
}

# Each guard clause records why in TVM_WHEEL_SKIP_REASON for _tvm_wheel_verdict.
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
    # USE_Z3=OFF: Z3.cmake asks the host venv python, so AUTO would link a host libz3.a.
    if ! _tvm_run_wheel_build "${wheel_platform}" "${build_log}" "$tvm_dir" \
         -Ccmake.define.USE_Z3=OFF; then
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
    # Before the retag, so both wheels get the target tag.
    _tvm_stage_ffi_wheel "cross-${wheel_platform}"
    log "Retagging cross TVM wheel(s) in ${TVM_WHEEL_DIR} for ${wheel_platform}"
    retag_directory_wheels "${TVM_WHEEL_DIR}" "*" "${wheel_platform}" "$venv_python"
    # The retag fixed only the file names; judge the final contents last.
    _tvm_reject_wrong_soabi_wheels
}

# Builds the wheel, then installs tvm-ffi and it (or the source tree) into the build venv.
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
      # Build venv only; the shipped tvm_ffi comes from _tvm_stage_ffi_wheel.
      log "Installing Apache TVM FFI Python package from source tree"
      uv pip install "$tvm_dir/3rdparty/tvm-ffi"
    else
      log "Local Apache TVM FFI package not found; relying on apache-tvm-ffi from the Python package resolver"
    fi

    shopt -s nullglob
    local -a built_wheels=("${TVM_WHEEL_DIR}"/*.whl)
    shopt -u nullglob

    if [ "${#built_wheels[@]}" -gt 0 ]; then
      # Globbed before the ffi wheel lands, so [0] is the main wheel; keep that order.
      _tvm_stage_ffi_wheel native
      _tvm_stage_ffi_wheel_free_threaded
      log "Installing TVM Python wheel ${built_wheels[0]}"
      uv pip install "${built_wheels[0]}"
    else
      # Fills only the throwaway build venv, so the skip reason stays set.
      log "Wheel build unavailable; installing TVM Python package from source tree"
      uv pip install "$tvm_dir"
      TVM_WHEEL_SKIP_REASON="${TVM_WHEEL_SKIP_REASON:-native wheel build produced no artifact}; the source-tree fallback installed apache-tvm into the throwaway build venv (${VIRTUAL_ENV:-$tvm_dir/.venv}) only"
    fi

    uv pip install -U pytest
}

# On stderr, which survives log clipping; never fatal, as TVM is best-effort, but never silent.
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

    # lib64 too: CMake installs there on some distro/arch combinations.
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
    # Cross-only sysconfig redirect for the wheel builds; "" on native.
    local tvm_wheel_sysconfig_export=""
    # Filled in by whichever guard clause fired; read by _tvm_wheel_verdict.
    local TVM_WHEEL_SKIP_REASON=""
    _tvm_wheel_setup
    if cross_build_is_active; then
      _tvm_build_wheel_cross
    else
      _tvm_build_wheel_native
    fi
    _tvm_wheel_verdict
    # After the verdict: a failure here aborts tvm.sh under set -e.
    cross_build_is_active || verify_python_import "tvm" "tvm.__version__"
}
