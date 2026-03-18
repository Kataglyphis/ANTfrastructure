#!/usr/bin/env bash
# python_uv.sh - shared Python/uv helpers for CI and build scripts
#
# Exposes:
#   uv_venv_create <path> [python_version]     - Create a uv virtual environment
#   uv_venv_activate <path>                     - Activate a virtual environment
#   uv_venv_deactivate                          - Deactivate current venv
#   uv_venv_remove <path>                       - Remove a virtual environment
#   uv_sync_project [--locked] [--no-wxpython]  - Sync dependencies with uv
#   uv_run <args...>                            - Run command with uv
#   uv_ensure_installed                         - Ensure uv is installed
#   timestamp                                   - Get timestamp for logs
#   detect_workspace                            - Detect and export WORKSPACE_ROOT
#   is_experimental_python <version>            - Check if Python version is experimental

set -euo pipefail

_PYTHON_UV_LOADED="${_PYTHON_UV_LOADED:-}"

if [ -z "$_PYTHON_UV_LOADED" ]; then
_PYTHON_UV_LOADED=1

_MODULE_DIR="${BASH_SOURCE[0]%/*}"
source "$_MODULE_DIR/logging.sh" || { echo "Error: failed to source logging.sh" >&2; exit 1; }

declare -g EXPERIMENTAL_PYTHON_VERSIONS="${EXPERIMENTAL_PYTHON_VERSIONS:-3.14t}"
declare -g DEFAULT_PYTHON_VERSION="${DEFAULT_PYTHON_VERSION:-3.13}"
declare -g _CURRENT_VENV_PATH=""

timestamp() {
  date +%Y%m%d-%H%M%S
}

detect_workspace() {
  local script_dir
  script_dir="$(cd "$(dirname "${BASH_SOURCE[1]:-${BASH_SOURCE[0]}}")" && pwd)"
  local repo_root
  repo_root="$(cd "$script_dir/../.." 2>/dev/null && pwd || cd "$script_dir/.." && pwd)"
  WORKSPACE_ROOT="${WORKSPACE_ROOT:-$repo_root}"
  if [ -d /workspace ] && [ -f /workspace/pyproject.toml ]; then
    WORKSPACE_ROOT="/workspace"
  fi
  export WORKSPACE_ROOT
  info "Workspace: $WORKSPACE_ROOT"
}

is_experimental_python() {
  local version="$1"
  for exp_v in $EXPERIMENTAL_PYTHON_VERSIONS; do
    if [[ "$version" == "$exp_v" ]]; then
      return 0
    fi
  done
  return 1
}

uv_ensure_installed() {
  if ! command -v uv >/dev/null 2>&1; then
    info "Installing uv..."
    curl -LsSf https://astral.sh/uv/install.sh | sh
    export PATH="$HOME/.local/bin:$PATH"
  fi
  info "uv version: $(uv --version)"
}

uv_venv_create() {
  local venv_path="$1"
  local python_version="${2:-$DEFAULT_PYTHON_VERSION}"
  local clear_flag="${3:---clear}"
  
  info "Creating virtual environment at: $venv_path (Python $python_version)"
  
  if [ -d "$venv_path" ]; then
    info "Removing existing virtual environment"
    rm -rf "$venv_path"
  fi
  
  uv venv "$venv_path" --python="$python_version" $clear_flag
  _CURRENT_VENV_PATH="$venv_path"
}

uv_venv_activate() {
  local venv_path="$1"
  
  if [ ! -d "$venv_path" ]; then
    die "Virtual environment not found: $venv_path"
  fi
  
  info "Activating virtual environment: $venv_path"
  # shellcheck disable=SC1090
  source "$venv_path/bin/activate"
  _CURRENT_VENV_PATH="$venv_path"
}

uv_venv_deactivate() {
  if [ -n "${VIRTUAL_ENV:-}" ]; then
    deactivate || true
  fi
  _CURRENT_VENV_PATH=""
}

uv_venv_remove() {
  local venv_path="${1:-$_CURRENT_VENV_PATH}"
  
  if [ -z "$venv_path" ]; then
    return 0
  fi
  
  if [ -d "$venv_path" ]; then
    info "Removing virtual environment: $venv_path"
    rm -rf "$venv_path"
  fi
  
  if [ "$venv_path" = "$_CURRENT_VENV_PATH" ]; then
    _CURRENT_VENV_PATH=""
  fi
}

uv_sync_project() {
  local use_locked=0
  local no_wxpython=0
  local active=1
  
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --locked) use_locked=1; shift ;;
      --no-wxpython) no_wxpython=1; shift ;;
      --active) active=1; shift ;;
      *) shift ;;
    esac
  done
  
  local sync_args=(sync --dev --all-extras)
  
  if [ $use_locked -eq 1 ] || [ -f uv.lock ]; then
    if [ -f uv.lock ]; then
      info "uv.lock found — using locked sync"
    fi
    sync_args+=(--locked)
  else
    info "No uv.lock found — performing non-locked sync"
  fi
  
  if [ $no_wxpython -eq 1 ]; then
    sync_args+=(--no-build-isolation-package wxpython)
  elif [ -f pyproject.toml ] && grep -q "wxpython" pyproject.toml 2>/dev/null; then
    sync_args+=(--no-build-isolation-package wxpython)
  fi
  
  uv "${sync_args[@]}"
}

uv_run() {
  uv run --active "$@"
}

fi