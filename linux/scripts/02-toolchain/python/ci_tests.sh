#!/usr/bin/env bash
# PY_VERSIONS defaults to the image interpreter. docs/python-ci.md#trap-3--onnx-runtime-comes-from-the-chain-not-pypi

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/ci-common.sh" || { echo "Error: failed to source ci-common.sh" >&2; exit 1; }

detect_workspace

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  echo "Usage: ci_tests.sh [package_name] [py_versions_string]"
  echo "  package_name defaults to \$PACKAGE_NAME or derived from pyproject.toml"
  echo "  py_versions_string defaults to \$PY_VERSIONS or '3.14'"
  echo "  log file defaults to \$CI_TESTS_LOG_FILE or 'docs/test_results/ci_tests-<timestamp>.log'"
  echo "  \$PYTEST_PATHS (comma list) narrows pytest; empty runs the project's configured testpaths"
  echo "  \$FREE_THREADED_SYNC_EXTRAS (comma list) makes a free-threaded leg sync only those extras and gate"
  echo "  \$SYNC_EXTRAS (comma list) makes every leg sync only those extras and gate"
  exit 0
fi

PACKAGE_NAME="$(derive_package_name "${1:-${PACKAGE_NAME:-}}")"

PY_VERSIONS="${2:-${PY_VERSIONS:-3.14}}"
# EXPERIMENTAL_PYTHON_VERSIONS is owned and read by 01-core/python_uv.sh; nothing to set here.

# Empty runs the project's own testpaths: a hard-coded subdir once left a consumer's real suite on no lane.
PYTEST_PATHS="${PYTEST_PATHS:-}"
# Set, a free-threaded leg syncs only these extras and gates like any other; unset, it stays experimental.
FREE_THREADED_SYNC_EXTRAS="${FREE_THREADED_SYNC_EXTRAS:-}"
# Set, every leg syncs only these extras (a riscv64 row cannot build the full extra set under QEMU).
SYNC_EXTRAS="${SYNC_EXTRAS:-}"

LOG_FILE="${CI_TESTS_LOG_FILE:-$WORKSPACE_ROOT/docs/test_results/ci_tests-$(timestamp).log}"
mkdir -p "$(dirname "$LOG_FILE")"

exec > >(tee -a "$LOG_FILE") 2>&1

info "Logging to: $LOG_FILE"
info "PACKAGE_NAME=$PACKAGE_NAME"
info "PY_VERSIONS=$PY_VERSIONS"
info "EXPERIMENTAL_PYTHON_VERSIONS=$EXPERIMENTAL_PYTHON_VERSIONS"

git config --global --add safe.directory "$WORKSPACE_ROOT" || true

mkdir -p "$WORKSPACE_ROOT/docs/test_results"

# On riscv64 the image's seed holds what the lock builds from source under QEMU (108 min of the sync).
uv_cache_seed_restore

TEST_EXIT=0

read -r -a test_paths <<< "${PYTEST_PATHS//,/ }"

for V in $PY_VERSIONS; do
  # A free-threaded leg with its own extras is a real leg; its sync can no longer fail on GIL-only wheels.
  leg_extras=""
  experimental=0
  if [ -n "$SYNC_EXTRAS" ]; then
    leg_extras="$SYNC_EXTRAS"
    info "[stable] Running Python $V with extras '${leg_extras}' only"
  elif [[ "$V" == *t ]] && [ -n "$FREE_THREADED_SYNC_EXTRAS" ]; then
    leg_extras="$FREE_THREADED_SYNC_EXTRAS"
    info "[stable] Running Python $V with extras '${leg_extras}' only"
  elif is_experimental_python "$V"; then
    experimental=1
    info "[experimental] Running Python $V in non-blocking mode"
  else
    info "[stable] Running Python $V"
  fi

  VENV_DIR="$WORKSPACE_ROOT/.venv-${V}"

  if [ "$experimental" -eq 1 ]; then
    if ! uv_venv_create "$VENV_DIR" "$V"; then
      echo "::warning title=Python ${V} not tested::its venv could not be created (experimental leg)"
      warn "[experimental] Failed to create venv for $V; continuing"
      continue
    fi
  else
    uv_venv_create "$VENV_DIR" "$V"
  fi

  uv_venv_activate "$VENV_DIR"

  # An experimental interpreter may fail its sync without failing the matrix, but never silently.
  if [ "$experimental" -eq 1 ]; then
    if ! uv_sync_project --no-wxpython; then
      echo "::warning title=Python ${V} not tested::its dependencies did not sync, so no test ran on it (experimental leg)"
      warn "[experimental] Failed to sync dependencies for $V; continuing"
      uv_venv_deactivate
      uv_venv_remove "$VENV_DIR"
      continue
    fi
  elif [ -n "$leg_extras" ]; then
    UV_SYNC_EXTRAS="$leg_extras" uv_sync_project --no-wxpython
  else
    uv_sync_project --no-wxpython
  fi

  pytest_args=(
    "${test_paths[@]}" -v
    --cov="$PACKAGE_NAME"
    --cov-report=term-missing
    --cov-report="html:$WORKSPACE_ROOT/docs/test_results/coverage-html-${V}"
    --cov-report="xml:$WORKSPACE_ROOT/docs/test_results/coverage-${V}.xml"
    --junitxml="$WORKSPACE_ROOT/docs/test_results/report-${V}.xml"
    --html="$WORKSPACE_ROOT/docs/test_results/pytest-report-${V}.html"
    --self-contained-html
    --md-report
    --md-report-verbose=1
    --md-report-output "$WORKSPACE_ROOT/docs/test_results/pytest-report-${V}.md"
  )

  if [ "$experimental" -eq 1 ]; then
    uv_run pytest "${pytest_args[@]}" || {
      echo "::warning title=Python ${V} tests failed::the experimental leg's tests failed; see report-${V}.xml"
      warn "[experimental] Tests failed for $V; continuing"
    }
  else
    uv_run pytest "${pytest_args[@]}" || TEST_EXIT=$?
  fi

  uv_run python bench/demo_cprofile.py 2>/dev/null || info "demo_cprofile.py skipped"
  uv_run python bench/demo_line_profiler.py 2>/dev/null || info "demo_line_profiler.py skipped"
  uv_run -m memory_profiler bench/demo_memory_profiling.py 2>/dev/null || info "memory profiling skipped"

  uv_run py-spy record --rate 200 --duration 10 -o "$WORKSPACE_ROOT/docs/test_results/profile.svg" -- python bench/demo_py_spy.py 2>/dev/null \
    || info "py-spy profiling skipped (may require a longer-running process or py-spy missing)"

  uv_run pytest bench/demo_pytest_benchmark.py 2>/dev/null || info "benchmark tests skipped or failed"

  uv_venv_deactivate
  uv_venv_remove "$VENV_DIR"
done

exit "$TEST_EXIT"