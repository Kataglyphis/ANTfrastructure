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

# Extras that must NOT be installed together, one per line as a group.
#
# `uv sync --all-extras` is a hard error on any project that declares
# `[tool.uv] conflicts` — uv refuses with
#   error: Extras `a` and `b` are incompatible with the declared conflicts
# and there is no "install as much as possible" flag. Measured 2026-08-11:
# Kataglyphis-Orchestr-ANT-ion declares 12 pairwise conflicts across two
# mutually-exclusive families (the ml-ai backends and the pytorch backends), so
# every one of its CI lanes failed here regardless of what it was asked to do.
_uv_conflict_groups() {
  local pyproject="${1:-pyproject.toml}"
  [ -f "$pyproject" ] || return 0
  awk '
    /^[[:space:]]*conflicts[[:space:]]*=/ { inblock = 1; depth = 0 }
    inblock {
      line = $0
      n = length(line)
      for (i = 1; i <= n; i++) {
        c = substr(line, i, 1)
        if (c == "[") { depth++; if (depth == 2) group = "" }
        else if (c == "]") {
          if (depth == 2 && group != "") { sub(/^ /, "", group); print group }
          depth--
          if (depth <= 0) { inblock = 0; exit }
        }
      }
      if (depth >= 2) {
        tmp = line
        while (match(tmp, /extra[[:space:]]*=[[:space:]]*"[^"]+"/)) {
          piece = substr(tmp, RSTART, RLENGTH)
          tmp = substr(tmp, RSTART + RLENGTH)
          if (match(piece, /"[^"]+"/)) {
            group = group " " substr(piece, RSTART + 1, RLENGTH - 2)
          }
        }
      }
    }
  ' "$pyproject"
}

# Which extras to exclude so that --all-extras becomes satisfiable.
#
# Greedy over the groups in DECLARATION ORDER: keep an extra unless it conflicts
# with one already kept, otherwise exclude it. Deterministic, and it keeps the
# first-declared member of each family — which for Orchestr-ANT-ion means the
# plain `ml-ai` and `pytorch-cpu`, the right choices for CI. A project that wants
# a different member sets UV_SYNC_EXTRAS and skips all of this.
_uv_extras_to_exclude() {
  local groups keep=" " drop=" " a b
  groups="$(_uv_conflict_groups "${1:-pyproject.toml}")" || return 0
  [ -n "$groups" ] || return 0
  while read -r a b; do
    [ -n "$a" ] || continue
    for e in "$a" "$b"; do
      [ -n "$e" ] || continue
      case "$keep$drop" in *" $e "*) continue ;; esac
      # conflicts with something already kept?
      local conflicted=0 g x y
      while read -r x y; do
        case " $x $y " in
          *" $e "*)
            local other="$x"; [ "$x" = "$e" ] && other="$y"
            case "$keep" in *" $other "*) conflicted=1 ;; esac
            ;;
        esac
      done <<< "$groups"
      if [ "$conflicted" -eq 1 ]; then drop="$drop$e "; else keep="$keep$e "; fi
    done
  done <<< "$groups"
  echo "$drop" | tr -s ' ' | sed 's/^ //;s/ $//'
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

  local sync_args=(sync --dev)

  if [ -n "${UV_SYNC_EXTRAS:-}" ]; then
    # Explicit wins: the project knows which combination it wants.
    info "UV_SYNC_EXTRAS set — syncing extras: ${UV_SYNC_EXTRAS}"
    local -a _extras=()
    IFS=',' read -r -a _extras <<<"${UV_SYNC_EXTRAS}"
    local _e
    for _e in "${_extras[@]}"; do
      [ -n "${_e}" ] || continue
      sync_args+=(--extra "$_e")
    done
  else
    sync_args+=(--all-extras)
    local _excl
    _excl="$(_uv_extras_to_exclude pyproject.toml)"
    if [ -n "$_excl" ]; then
      info "Project declares conflicting extras; --all-extras alone would fail."
      info "Excluding (keeping the first-declared of each family): ${_excl}"
      info "Set UV_SYNC_EXTRAS to choose a different combination."
      for _e in $_excl; do
        sync_args+=(--no-extra "$_e")
      done
    fi
  fi

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
  
  # Pin the interpreter for the SAME reason uv_pip_install_requirements does,
  # and it is just as load-bearing here: uv honours UV_PYTHON OVER the activated
  # venv. The CI images export UV_PYTHON=/opt/venv/bin/python and run as the
  # non-root user `kataglyphis`, so `--active` alone still resolves to that
  # root-owned system venv and the sync dies with
  #   error: failed to remove file `/opt/venv/lib/python3.14/site-packages/...`:
  #          Permission denied (os error 13)
  # Observed on both arches in Orchestr-ANT-ion's lane on 2026-08-11, right after
  # the extras fix let the resolve get this far. --python forces the writable
  # local environment; --active stays so uv still prefers it when no venv is set.
  local _venv="${VIRTUAL_ENV:-${_CURRENT_VENV_PATH:-}}"
  if [ -n "$_venv" ] && [ -x "$_venv/bin/python" ]; then
    sync_args+=(--python "$_venv/bin/python")
  fi

  sync_args+=(--active)

  uv "${sync_args[@]}"
}

uv_run() {
  uv run --active "$@"
}

fi
