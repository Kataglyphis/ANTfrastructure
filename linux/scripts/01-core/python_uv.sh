#!/usr/bin/env bash
# python_uv.sh - shared Python/uv helpers for CI and build scripts
#
# Exposes:
#   uv_venv_create <path> [python_version]     - Create a uv virtual environment
#                                                 (pass "" to let uv/UV_PYTHON pick)
#   uv_pip_install_requirements [venv] [reqs]   - pip install -r into a venv
#                                                 (pins --python; see comment)
#   uv_venv_activate <path>                     - Activate a virtual environment
#   uv_venv_deactivate                          - Deactivate current venv
#   uv_venv_remove <path>                       - Remove a virtual environment
#   uv_sync_project [--locked] [--no-wxpython]  - Sync dependencies with uv
#   uv_run <args...>                            - Run command with uv
#   uv_ensure_installed                         - Ensure uv is installed
#   timestamp                                   - Get timestamp for logs
#   detect_workspace                            - Detect and export WORKSPACE_ROOT
#   is_experimental_python <version>            - Check if Python version is experimental

_PYTHON_UV_LOADED="${_PYTHON_UV_LOADED:-}"

if [ -z "$_PYTHON_UV_LOADED" ]; then
set -euo pipefail
_PYTHON_UV_LOADED=1

_MODULE_DIR="${BASH_SOURCE[0]%/*}"
source "$_MODULE_DIR/logging.sh" || { echo "Error: failed to source logging.sh" >&2; exit 1; }

# Add known experimental Python versions here so callers can test/build
# against newer interpreter releases. Keep the default aligned with the
# source-built interpreter used by the container images.
declare -g EXPERIMENTAL_PYTHON_VERSIONS="${EXPERIMENTAL_PYTHON_VERSIONS:-3.14t}"
# Default interpreter used when callers don't specify one. DEFAULT_PYTHON_VERSION
# was removed from versions.env — derived from the canonical PYTHON_MAJOR_MINOR
# (itself derived from PYTHON_VERSION by common.sh).
declare -g DEFAULT_PYTHON_VERSION="${DEFAULT_PYTHON_VERSION:-${PYTHON_MAJOR_MINOR:-3.14}}"
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
  local uv_install_sh uv_install_sha
  if ! command -v uv >/dev/null 2>&1; then
    info "Installing uv..."
    # Download the installer to a file (never pipe curl into sh: a truncated
    # stream would execute a partial script), then optionally pin it via the
    # UV_INSTALL_SH_SHA256 env var / versions.env key (empty = skip; upstream
    # rotates the script — see the key's comment in versions.env).
    uv_install_sha="${UV_INSTALL_SH_SHA256:-}"
    if [ -z "$uv_install_sha" ] && [ -f "$_MODULE_DIR/versions.env" ]; then
      uv_install_sha="$(sed -n 's/^UV_INSTALL_SH_SHA256=//p' "$_MODULE_DIR/versions.env")"
    fi
    uv_install_sh="$(mktemp "${TMPDIR:-/tmp}/uv-install-XXXXXX.sh")"
    curl --proto '=https' --tlsv1.2 -fsSL --retry 3 -o "$uv_install_sh" https://astral.sh/uv/install.sh
    if [ -n "$uv_install_sha" ]; then
      printf '%s  %s\n' "$uv_install_sha" "$uv_install_sh" | sha256sum -c - || {
        rm -f "$uv_install_sh"
        die "uv install.sh does not match pinned UV_INSTALL_SH_SHA256 (upstream rotated it, or tampering)"
      }
    fi
    sh "$uv_install_sh"
    rm -f "$uv_install_sh"
    export PATH="$HOME/.local/bin:$PATH"
  fi
  info "uv version: $(uv --version)"
}

# Ensure a given Python interpreter is available, attempting to install it via
# Astral uv if it's missing. The function is conservative: it strips any
# non-digit/dot suffix from the requested version to form an executable name
# like `python3.14`, then tries `uv python install <version>` and re-checks.
uv_ensure_python_available() {
  local req_version="$1"
  # Normalize version to numeric+dot only for executable name
  local exe_ver
  exe_ver="$(printf '%s' "$req_version" | sed 's/[^0-9.]//g')"
  [ -n "$exe_ver" ] || exe_ver="$req_version"

  local exe_name="python${exe_ver}"
  if command -v "${exe_name}" >/dev/null 2>&1; then
    info "Found interpreter: ${exe_name}"
    return 0
  fi

  info "Interpreter ${exe_name} not found. Trying to install via uv..."
  uv_ensure_installed

  # Try uv install; don't fail the entire script if uv cannot install — emit
  # a warning and let callers decide how to proceed.
  if uv python install "${exe_ver}" 2>/dev/null; then
    info "uv installed python ${exe_ver}; re-checking for ${exe_name}"
    # Ensure uv's bin is on PATH (uv python install may place runtimes in ~/.local)
    export PATH="$HOME/.local/bin:$PATH"
    if command -v "${exe_name}" >/dev/null 2>&1; then
      info "Successfully installed ${exe_name} via uv"
      return 0
    fi
  else
    warn "uv could not install python ${exe_ver} (uv python install failed)"
  fi

  warn "Interpreter ${exe_name} still not available. Ensure Python ${req_version} is installed on the system or provide an explicit path when creating the venv."
  return 1
}

uv_venv_create() {
  local venv_path="$1"
  # Pass an explicit empty string as python_version to skip the --python pin
  # and let uv resolve the interpreter itself (this honours UV_PYTHON, which
  # the CI container images export to point at their system interpreter).
  # Omitting the argument keeps the historical DEFAULT_PYTHON_VERSION pin.
  local python_version="${2-$DEFAULT_PYTHON_VERSION}"
  local clear_flag="${3:---clear}"

  info "Creating virtual environment at: $venv_path (Python ${python_version:-<uv default>})"

  if [ -d "$venv_path" ]; then
    info "Removing existing virtual environment"
    rm -rf "$venv_path"
  fi

  local uv_args=(venv --seed "$venv_path")
  if [ -n "$python_version" ]; then
    # Try to ensure requested Python is available via uv (if possible) before
    # creating the venv. If uv cannot provide the interpreter, uv venv will
    # still attempt to create the venv with whatever python is available and
    # may fail; callers can override by passing an explicit python path.
    uv_ensure_python_available "$python_version" || true
    uv_args+=("--python=$python_version")
  fi

  uv "${uv_args[@]}" $clear_flag
  _CURRENT_VENV_PATH="$venv_path"
}

# Install a requirements file into a specific venv. The --python pin is
# deliberate and load-bearing: uv honours UV_PYTHON OVER the activated venv,
# and the CI container images export UV_PYTHON=/opt/venv/bin/python (a
# root-owned system venv) - so a plain `uv pip install` inside an activated
# .venv still targets /opt/venv and dies with "Permission denied (os error
# 13)" for the non-root CI user (uid 1001). --python forces the writable
# local environment. Reproduced and verified in the :latest-cross image.
uv_pip_install_requirements() {
  local venv_path="${1:-.venv}"
  local requirements_file="${2:-requirements.txt}"

  if [ ! -x "$venv_path/bin/python" ]; then
    die "No usable venv at $venv_path (missing bin/python) - create it first with uv_venv_create"
  fi
  if [ ! -f "$requirements_file" ]; then
    die "Requirements file not found: $requirements_file"
  fi

  info "Installing $requirements_file into $venv_path"
  uv pip install --python "$venv_path/bin/python" -r "$requirements_file"
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

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --locked) use_locked=1; shift ;;
      --no-wxpython) no_wxpython=1; shift ;;
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
  
  sync_args+=(--active)

  uv "${sync_args[@]}"
}

uv_run() {
  uv run --active "$@"
}

fi
