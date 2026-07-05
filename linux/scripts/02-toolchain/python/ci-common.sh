#!/usr/bin/env bash
# ci-common.sh — shared helpers for the Python ci_*.sh runners. Sourced (not
# executed). Pulls in 01-core/python_uv.sh (logging, detect_workspace,
# uv_venv_*, ...) and adds the CI glue previously duplicated across
# ci_tests.sh, ci_static_analysis.sh, ci_packaging.sh and ci_build_docs.sh.
#
# 01-core is off-limits for this refactor, so these helpers live here (a file we
# own) rather than in 01-core/python_uv.sh.

_CI_COMMON_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "$_CI_COMMON_DIR/../01-core/python_uv.sh"

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

# uv_venv_ensure <dir> <python-version> [label]
# Reuse the venv at <dir> if it already exists (activating it), otherwise create
# it. Matches the create-does-not-activate semantics of uv_venv_create so the
# packaging scripts keep behaving exactly as their previous inline blocks did.
uv_venv_ensure() {
  local dir="$1" pyver="$2" label="${3:-venv}"
  if [ -f "$dir/bin/activate" ]; then
    info "Using existing ${label} at $dir"
    uv_venv_activate "$dir"
  else
    info "Creating ${label} with Python $pyver at $dir"
    uv_venv_create "$dir" "$pyver"
  fi
}
