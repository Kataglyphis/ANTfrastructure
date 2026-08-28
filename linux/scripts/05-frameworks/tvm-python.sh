#!/usr/bin/env bash
# tvm-python.sh - Python venv + TVM wheel build helpers
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

# ── target-Python sysconfig redirect (cross only) ─────────────────────────────
# apache-tvm-ffi builds its Cython core WITH_SOABI (no abi3), and CMake reads the
# SOABI off the amd64 build venv, so a cross wheel installs and then dies at
# `import tvm` (its first statement is `from tvm_ffi import ...`). Point the host
# interpreter's sysconfig at the TARGET's _sysconfigdata, as build-app-wheelhouse.sh
# does for torch/vision/IREE. Echoes an eval-able export string, or NOTHING when the
# target sysconfigdata is absent (both halves ship together or neither does).
# Duplicates resolve_target_python_sysconfig_export in torch/build-app-wheelhouse.sh;
# fold both into 01-core/cross-python.sh the next time both are in scope.
_tvm_target_python_sysconfig_export() {
    cross_build_is_active || return 0

    local triplet="" name="" stage_root="" dir="" search_root=""

    triplet="$(cross_target_triplet 2>/dev/null || true)"
    [ -n "${triplet}" ] || return 0
    name="_sysconfigdata__linux_${triplet}"
    stage_root="$(cross_target_python_root 2>/dev/null || true)"

    for search_root in ${stage_root:+"${stage_root}/lib"} "/usr/lib"; do
      [ -d "${search_root}" ] || continue
      # -maxdepth 4, not 2: the staged cross interpreter keeps _sysconfigdata_*.py
      # in lib/python3.X/lib-dynload/ (depth 3). A miss is silent - the wheel gets
      # the build-host SOABI and _tvm_reject_wrong_soabi_wheels withdraws it.
      dir="$(find "${search_root}" -maxdepth 4 -name "${name}.py" -printf '%h\n' -quit 2>/dev/null || true)"
      [ -n "${dir}" ] && break
    done

    if [ -z "${dir}" ]; then
      # Explicit >&2: this function's STDOUT is eval'd, so a stray byte on it
      # becomes a command.
      warn "Target Python sysconfigdata ${name}.py not found under ${stage_root:-<no staged target python>}/lib or /usr/lib; the apache-tvm-ffi extension would be stamped with the amd64 host SOABI and the staged wheels will be withdrawn below" >&2
      return 0
    fi

    printf 'export _PYTHON_SYSCONFIGDATA_NAME=%q; export PYTHONPATH=%q${PYTHONPATH:+:${PYTHONPATH}}' \
      "${name}" "${dir}"
}

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

    # Build-executor pins (supply-chain audit #18): these EXECUTE code at build
    # time. Inline defaults mirror versions.env (safety-net convention).
    # mlc-z3-static is not an executor but sits in TVM's [build-system].requires,
    # and --no-isolation installs no build-requires — without it every wheel build
    # aborts at "Getting build dependencies for wheel", after the hours-long compile.
    uv pip install -U pip \
      "setuptools==${PY_SETUPTOOLS_VERSION:-84.0.0}" \
      "wheel==${PY_WHEEL_VERSION:-0.48.0}" \
      build \
      "scikit-build-core==${PY_SCIKIT_BUILD_CORE_VERSION:-1.0.3}" \
      "cython==${PY_CYTHON_VERSION:-3.2.9}" \
      "setuptools-scm==${PY_SETUPTOOLS_SCM_VERSION:-10.2.1}" \
      "mlc-z3-static==${PY_MLC_Z3_STATIC_VERSION:-4.16.0}"
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

    # Cross only; empty string on native and whenever the target sysconfigdata
    # is missing. Read by _tvm_run_wheel_build (see the helper's header).
    tvm_wheel_sysconfig_export="$(_tvm_target_python_sysconfig_export)"
}

# Runs `python -m build` for one mode, tee'd to a log; returns the builder's rc.
# $3 = source tree (default: the main TVM checkout). Further args are `-C`
# config-settings, which OUTRANK the tree's own [tool.scikit-build] values.
_tvm_run_wheel_build() {
    local build_dir_suffix="$1" build_log="$2" src_dir="${3:-$tvm_dir}"
    shift 2
    [ $# -eq 0 ] || shift
    # pipefail is LOAD-BEARING: without it `| tee` reports tee's status and every
    # failure diagnostic below is dead code. Assert it — the failure leaves no trace.
    if [[ ! -o pipefail ]]; then
      die "tvm-python.sh: 'set -o pipefail' is not enabled; the tee'd wheel build would mask its own failure and every TVM diagnostic below would be dead code"
    fi
    # The sysconfig redirect stays in a SUBSHELL: it rewrites what `sysconfig`
    # answers process-tree-wide, and only the wheel build may see it.
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

# Stage the apache-tvm-ffi wheel NEXT TO the main one: the consumer installs the
# staged wheels --no-deps, so an apache_tvm wheel without its ffi sibling ships an
# unimportable tvm. Call ONLY after the main wheel exists, so the verdict's "wheel
# staged" keeps implying a usable tvm. Never fatal, but LOUD on failure.
# $1 = build-dir/log suffix; extra args pass through as -C settings.
_tvm_stage_ffi_wheel() {
    local mode="$1"; shift
    local ffi_dir="${tvm_dir}/3rdparty/tvm-ffi"
    if [ ! -f "${ffi_dir}/pyproject.toml" ]; then
      warn "tvm-ffi source tree has no pyproject.toml (${ffi_dir}) — cannot stage the ffi wheel"
      # Withdraw the main wheel too - staged without its ffi sibling it would read
      # as green in the verdict. TVM_WHEEL_SKIP_REASON reaches us by dynamic scope.
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

# `--no-isolation` (deliberate: an isolated tree would recompile everything) installs
# no build-requires, so ONE missing entry aborts the build. Echo the list back — it
# is both diagnosis and fix (pin it in _tvm_wheel_setup's build-executor list).
_tvm_wheel_missing_build_requires() {
    local build_log="$1"
    [ -s "$build_log" ] || return 0
    # Bounded at BOTH ends (marker -> first non-indented line, plus a hard cap):
    # pypa/build prints the dep list last with no trailing blank line, so a range
    # whose closing address never matches swallows the rest of the log.
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

# Withdraw staged cross wheels whose native CPython extensions carry the WRONG
# SOABI — they install on the target and then fail at `import`. Same rule as
# 03-media/runtime/verify-wheels.sh (only `.cpython-<n>-...so` members are judged),
# but at the PRODUCER, where the artifact can still be withdrawn. Every staged wheel
# goes, not just the offender: `import tvm` needs both wheels, so a survivor would
# read as green in the verdict. Never fatal; the verdict does the shouting.
_tvm_reject_wrong_soabi_wheels() {
    local triplet="" py_tag="" expected="" bad="" entry=""

    triplet="$(cross_target_triplet 2>/dev/null || true)"
    py_tag="$("$venv_python" -c 'import sys; print(f"{sys.version_info.major}{sys.version_info.minor}")' 2>/dev/null || true)"
    if [ -z "${triplet}" ] || [ -z "${py_tag}" ]; then
      warn "TVM cross wheel SOABI check SKIPPED (triplet='${triplet}' python-tag='${py_tag}'); the staged wheels are NOT proven importable on the target"
      return 0
    fi
    # Host and target Python share a version by construction, so only the arch
    # triple has to come from the cross env.
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
    # USE_Z3=OFF (cross only): Z3.cmake locates mlc-z3-static by EXECUTING the venv
    # python — always the amd64 host — so pyproject's USE_Z3=AUTO would link a
    # HOST-arch libz3.a into the target libtvm. `-C` because it outranks pyproject.
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
    # Stage the ffi sibling BEFORE the retag so both get retagged for the target.
    # Its extension is WITH_SOABI, NOT abi3, so the file name carries the building
    # interpreter's SOABI — hence the redirect above and the rejection below.
    _tvm_stage_ffi_wheel "cross-${wheel_platform}"
    log "Retagging cross TVM wheel(s) in ${TVM_WHEEL_DIR} for ${wheel_platform}"
    # Canonical retag helper from 01-core/common.sh (sourced via tvm.sh).
    retag_directory_wheels "${TVM_WHEEL_DIR}" "*" "${wheel_platform}" "$venv_python"
    # Retagging fixed the FILENAME; prove the wheel CONTENTS are target-arch
    # too, or withdraw them. Runs last so it judges the final staged set.
    _tvm_reject_wrong_soabi_wheels
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
      # BUILD-venv install only (feeds verify_python_import); the SHIPPED tvm_ffi
      # comes from _tvm_stage_ffi_wheel below.
      log "Installing Apache TVM FFI Python package from source tree"
      uv pip install "$tvm_dir/3rdparty/tvm-ffi"
    else
      log "Local Apache TVM FFI package not found; relying on apache-tvm-ffi from the Python package resolver"
    fi

    shopt -s nullglob
    local -a built_wheels=("${TVM_WHEEL_DIR}"/*.whl)
    shopt -u nullglob

    if [ "${#built_wheels[@]}" -gt 0 ]; then
      # built_wheels was globbed BEFORE the ffi wheel lands, so [0] is always
      # the main apache_tvm wheel — do not move this glob below the staging.
      _tvm_stage_ffi_wheel native
      log "Installing TVM Python wheel ${built_wheels[0]}"
      uv pip install "${built_wheels[0]}"
    else
      # This ISOLATED uv build succeeds where `--no-isolation` failed and makes the
      # step look healthy, but it only populates the throwaway build venv — nothing
      # reaches ${TVM_WHEEL_DIR}, so the skip reason stays set.
      log "Wheel build unavailable; installing TVM Python package from source tree"
      uv pip install "$tvm_dir"
      TVM_WHEEL_SKIP_REASON="${TVM_WHEEL_SKIP_REASON:-native wheel build produced no artifact}; the source-tree fallback installed apache-tvm into the throwaway build venv (${VIRTUAL_ENV:-$tvm_dir/.venv}) only"
    fi

    uv pip install -U pytest
}

# Final verdict, on stderr so it survives log clipping. Never fatal: TVM is
# best-effort by design and the defect this closes was the SILENCE, not the
# absence — an empty wheel dir used to render as "TVM build OK" (backlog ORPHAN-PINS).
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

    # The consolation line is only printed if it is TRUE. Both layouts are checked:
    # CMake installs libtvm to lib64 on some distro/arch combinations, which is why
    # Dockerfile.media folds /opt/tvm/lib64 back into lib after this script returns.
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
    # AFTER the verdict on purpose: this checks the BUILD venv and its non-zero
    # return aborts tvm.sh under `set -e`, suppressing the verdict.
    cross_build_is_active || verify_python_import "tvm" "tvm.__version__"
}
