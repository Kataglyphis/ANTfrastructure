#!/usr/bin/env bash
# ci-common.sh — shared helpers for the Python ci_*.sh runners. Sourced (not
# executed). Pulls in 01-core/python_uv.sh (logging, detect_workspace,
# uv_venv_*, ...) and adds the CI glue previously duplicated across
# ci_tests.sh, ci_static_analysis.sh, ci_packaging.sh and ci_build_docs.sh.
#
# 01-core is off-limits for this refactor, so these helpers live here (a file we
# own) rather than in 01-core/python_uv.sh.

_CI_COMMON_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# ../../ not ../ : this file lives in 02-toolchain/PYTHON/, one level deeper
# than 02-toolchain/bootstrap.sh where `../01-core` is correct. At the wrong
# depth it resolved to 02-toolchain/01-core/python_uv.sh, which does not exist,
# so every driver in this directory died on its first helper call
# ("detect_workspace: command not found"). That is almost certainly why both
# Python consumers - OrchestrANT and WebDavClient - carried full local
# reimplementations of all four drivers: the shared ones could never run.
# Found 2026-08-11 while collapsing those copies back onto these drivers.
# shellcheck source=/dev/null
source "$_CI_COMMON_DIR/../../01-core/python_uv.sh"

# derive_package_name <initial>
# Echo the effective package name: <initial> when non-empty, else the
# `name = "…"` field of $WORKSPACE_ROOT/pyproject.toml, else the basename of
# $WORKSPACE_ROOT. (detect_workspace must have set WORKSPACE_ROOT first.)
derive_package_name() {
  local name="${1:-}"
  if [ -z "$name" ] && [ -f "$WORKSPACE_ROOT/pyproject.toml" ]; then
    name=$(grep -m1 'name[[:space:]]*=' "$WORKSPACE_ROOT/pyproject.toml" | sed 's/.*=[[:space:]]*"\([^"]*\)".*/\1/' || echo "")
  fi
  printf '%s' "${name:-$(basename "$WORKSPACE_ROOT")}"
}

# prepare_ci_workspace [--cd]
# Apply the bind-mounted /workspace override, optionally chdir into the
# workspace, put a local flutter SDK on PATH, and register the workspace as a
# git safe.directory. Mutates the global WORKSPACE_ROOT.
prepare_ci_workspace() {
  if [ -d /workspace ] && [ -f /workspace/pyproject.toml ]; then
    WORKSPACE_ROOT="/workspace"
  fi
  if [ "${1:-}" = "--cd" ]; then
    cd "$WORKSPACE_ROOT" || die "Cannot cd into workspace: $WORKSPACE_ROOT"
  fi
  if [ -d "$WORKSPACE_ROOT/flutter/bin" ]; then
    export PATH="$WORKSPACE_ROOT/flutter/bin:$PATH"
  fi
  git config --global --add safe.directory "$WORKSPACE_ROOT" || true
}

# uv_venv_ensure <dir> <python-version> [label] [existed-outvar]
# Reuse the venv at <dir> if it already exists (activating it), otherwise create
# it. Matches the create-does-not-activate semantics of uv_venv_create so the
# packaging scripts keep behaving exactly as their previous inline blocks did.
# When <existed-outvar> is given, that variable is set to 1 if the venv
# pre-existed and 0 if it was freshly created.
uv_venv_ensure() {
  local dir="$1" pyver="$2" label="${3:-venv}" existed_outvar="${4:-}"
  local existed=0
  if [ -f "$dir/bin/activate" ]; then
    existed=1
    info "Using existing ${label} at $dir"
    uv_venv_activate "$dir"
  else
    info "Creating ${label} with Python $pyver at $dir"
    uv_venv_create "$dir" "$pyver"
  fi
  if [ -n "$existed_outvar" ]; then
    printf -v "$existed_outvar" '%s' "$existed"
  fi
}
