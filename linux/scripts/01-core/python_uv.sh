#!/usr/bin/env bash
# python_uv.sh - shared Python/uv helpers for CI and build scripts

_PYTHON_UV_LOADED="${_PYTHON_UV_LOADED:-}"

if [ -z "$_PYTHON_UV_LOADED" ]; then
set -euo pipefail
_PYTHON_UV_LOADED=1

_MODULE_DIR="${BASH_SOURCE[0]%/*}"
source "$_MODULE_DIR/logging.sh" || { echo "Error: failed to source logging.sh" >&2; exit 1; }

# Keep the default aligned with the images' source-built interpreter.
declare -g EXPERIMENTAL_PYTHON_VERSIONS="${EXPERIMENTAL_PYTHON_VERSIONS:-3.14t}"
# Derived from PYTHON_MAJOR_MINOR, which common.sh derives from PYTHON_VERSION.
declare -g DEFAULT_PYTHON_VERSION="${DEFAULT_PYTHON_VERSION:-${PYTHON_MAJOR_MINOR:-3.14}}"
declare -g _CURRENT_VENV_PATH=""
# The ORT census: the checkout's copy, else the torch image's (Dockerfile.torch COPYs it into final/).
declare -g _UV_ORT_CENSUS
_UV_ORT_CENSUS="$(cd "$_MODULE_DIR/.." && pwd)/03-media/runtime/ort-venv-census.py"
[ -f "${_UV_ORT_CENSUS}" ] || _UV_ORT_CENSUS="${_UV_ORT_CENSUS%/runtime/*}/final/ort-venv-census.py"

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
    # Download to a file, never curl | sh (a truncated stream runs half a script); UV_INSTALL_SH_SHA256 pins it.
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

# uv discovery request for X.Y[.Z]: `+gil`, as a plain 3.14+ may pick a free-threaded build; `uv python install` rejects `+gil`.
uv_python_request() {
  if [[ "$1" =~ ^[0-9]+(\.[0-9]+)*$ ]]; then printf '%s+gil' "$1"; else printf '%s' "$1"; fi
}

# Installs the interpreter through uv when missing; the name keeps a free-threaded `t`, so `3.14t` never matches `python3.14`.
uv_ensure_python_available() {
  local req_version="$1"
  local exe_ver
  if [[ "${req_version}" =~ ^[0-9]+(\.[0-9]+)*t?$ ]]; then
    exe_ver="${req_version}"
  else
    exe_ver="$(printf '%s' "$req_version" | sed 's/[^0-9.]//g')"
    [ -n "$exe_ver" ] || exe_ver="$req_version"
  fi

  local exe_name="python${exe_ver}"
  if command -v "${exe_name}" >/dev/null 2>&1; then
    info "Found interpreter: ${exe_name}"
    return 0
  fi

  info "Interpreter ${exe_name} not found. Trying to install via uv..."
  uv_ensure_installed

  # A failed install only warns; callers decide how to proceed.
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
  # An explicit "" skips the --python pin so uv honours UV_PYTHON; omitted means DEFAULT_PYTHON_VERSION.
  local python_version="${2-$DEFAULT_PYTHON_VERSION}"
  local clear_flag="${3:---clear}"

  info "Creating virtual environment at: $venv_path (Python ${python_version:-<uv default>})"

  if [ -d "$venv_path" ]; then
    info "Removing existing virtual environment"
    rm -rf "$venv_path"
  fi

  local uv_args=(venv --seed "$venv_path")
  if [ -n "$python_version" ]; then
    # Best effort; callers can pass an explicit interpreter path instead.
    uv_ensure_python_available "$python_version" || true
    uv_args+=("--python=$(uv_python_request "$python_version")")
  fi

  uv "${uv_args[@]}" $clear_flag || return 1
  _CURRENT_VENV_PATH="$venv_path"
  # Explicit: the trailing assignment would otherwise BE the exit status.
  return 0
}

# --python is load-bearing: UV_PYTHON beats an activated venv. docs/python-ci.md#trap-2--uv_python-beats-the-activated-venv
uv_pip_install_requirements() {
  local venv_path="${1:-.venv}"
  local requirements_file="${2:-requirements.txt}"

  # Git Bash venvs carry Scripts/python.exe instead of bin/python.
  local venv_python="$venv_path/bin/python"
  [ -x "$venv_python" ] || venv_python="$venv_path/Scripts/python.exe"
  if [ ! -x "$venv_python" ]; then
    die "No usable venv at $venv_path (neither bin/python nor Scripts/python.exe) - create it first with uv_venv_create"
  fi
  if [ ! -f "$requirements_file" ]; then
    die "Requirements file not found: $requirements_file"
  fi

  info "Installing $requirements_file into $venv_path"
  uv pip install --python "$venv_python" -r "$requirements_file"
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

# Conflicting extras, one group per line. docs/python-ci.md#trap-1----all-extras-is-fatal-with-declared-conflicts
_uv_conflict_groups() {
  local pyproject="${1:-pyproject.toml}"
  [ -f "$pyproject" ] || return 0
  awk '
    function extras(s,   out, piece) {
      out = ""
      while (match(s, /extra[[:space:]]*=[[:space:]]*"[^"]+"/)) {
        piece = substr(s, RSTART, RLENGTH)
        s = substr(s, RSTART + RLENGTH)
        if (match(piece, /"[^"]+"/)) out = out " " substr(piece, RSTART + 1, RLENGTH - 2)
      }
      sub(/^ /, "", out)
      return out
    }
    /^[[:space:]]*conflicts[[:space:]]*=/ { inblock = 1; depth = 0; group = "" }
    inblock {
      n = length($0)
      for (i = 1; i <= n; i++) {
        c = substr($0, i, 1)
        if (c == "[") { depth++; if (depth == 2) group = "" }
        else if (c == "]") {
          if (depth == 2) { g = extras(group); if (g != "") print g; group = "" }
          depth--
          if (depth <= 0) { inblock = 0; exit }
        }
        else if (depth >= 2) group = group c
      }
      if (depth >= 2) group = group " "
    }
  ' "$pyproject"
}

# Greedy in declaration order, so each family keeps its first-declared member; UV_SYNC_EXTRAS overrides.
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
      local conflicted=0 x y
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
  
  # Why venv creation branches on the interpreter: docs/cross-build-verification.md
  local _venv="${_CURRENT_VENV_PATH:-${VIRTUAL_ENV:-}}"
  # Pin only a writable venv: an unwritable pin fails deep in the sync instead of falling back.
  local _pinned=0
  if [ -n "$_venv" ] && [ -x "$_venv/bin/python" ] && [ -w "$_venv/lib" ]; then
    sync_args+=(--python "$_venv/bin/python")
    info "uv sync pinned to ${_venv}/bin/python"
    _pinned=1
  elif [ -n "$_venv" ] && [ -x "$_venv/bin/python" ]; then
    warn "Refusing to pin uv sync to ${_venv}: ${_venv}/lib is not writable by uid $(id -u)."
    warn "  Falling back to uv's own discovery rather than failing mid-sync."
  else
    # Say why: a pin that silently does not apply is how the sync ends up in /opt/venv.
    warn "No usable venv resolved for uv sync."
    warn "  VIRTUAL_ENV='${VIRTUAL_ENV:-}'  _CURRENT_VENV_PATH='${_CURRENT_VENV_PATH:-}'"
    if [ -n "$_venv" ]; then
      warn "  '${_venv}/bin/python' is not executable"
    fi
  fi

  # Clear UV_PYTHON and VIRTUAL_ENV for this call only: the images point both at the root-owned /opt/venv.
  local -a _env_clear=(-u UV_PYTHON -u VIRTUAL_ENV)

  if [ "$_pinned" -eq 1 ]; then
    # UV_PROJECT_ENVIRONMENT decides where sync installs; --python only picks the interpreter.
    _env_clear+=("UV_PROJECT_ENVIRONMENT=${_venv}")
    info "uv sync target environment: ${_venv}"
  else
    warn "uv sync is UNPINNED; dropping --active and VIRTUAL_ENV so it cannot target a system venv."
    _venv="${UV_PROJECT_ENVIRONMENT:-${PWD}/.venv}"
  fi

  info "uv ${sync_args[*]}"
  env "${_env_clear[@]}" uv "${sync_args[@]}" || return
  uv_reconcile_chain_ort "${_venv}"
}

# uv run without the images' /opt/venv redirections; our own venv is named explicitly for --active.
uv_run() {
  local _venv="${_CURRENT_VENV_PATH:-}"
  if [ -n "${_venv}" ] && [ -x "${_venv}/bin/python" ]; then
    env -u UV_PYTHON "VIRTUAL_ENV=${_venv}" uv run --active "$@"
  else
    env -u UV_PYTHON -u VIRTUAL_ENV uv run "$@"
  fi
}

# uv run re-syncs to the lock and would restore PyPI ORT, so hold sync off; release only our own hold.
_uv_chain_ort_hold_sync() {
  if [ "$1" = hold ] && [ -z "${UV_NO_SYNC:-}" ]; then
    export UV_NO_SYNC=1
    _UV_CHAIN_ORT_NO_SYNC=1
  elif [ "$1" = release ] && [ "${_UV_CHAIN_ORT_NO_SYNC:-0}" = 1 ]; then
    unset UV_NO_SYNC
    _UV_CHAIN_ORT_NO_SYNC=0
  fi
  return 0
}

# ORT distributions in the venv of interpreter $1, from the same census assemble-torch-app.sh uses.
_uv_chain_ort_names() {
  local out
  out="$("$1" -I "${_UV_ORT_CENSUS}" --purge-list 2>&1)" || { printf '%s\n' "${out}"; return 1; }
  printf '%s\n' "${out}" | sed -n 's/^ORT-CENSUS PURGE \([a-z0-9][a-z0-9-]*\)$/\1/p'
}

# Moves the venv's ORT onto the chain wheels. docs/python-ci.md#trap-3--onnx-runtime-comes-from-the-chain-not-pypi
uv_reconcile_chain_ort() {
  local venv="$1" store="${ORT_CHAIN_WHEEL_DIR:-}" gil py names
  local -a drop=() wheels=()
  py="${venv}/bin/python"
  [ -x "${py}" ] || py="${venv}/Scripts/python.exe"
  _uv_chain_ort_preflight "${store}" "${py}" || return 1
  gil="${store}"
  store="$(_uv_chain_ort_store "${store}" "${py}" "${venv}")"
  if ! names="$(_uv_chain_ort_names "${py}")"; then
    [ -z "${store}" ] || { printf 'ERROR: chain ORT: cannot list %s: %s\n' "${venv}" "${names}" >&2; return 1; }
    warn "chain ORT: ${venv} not inspected; ONNX Runtime provenance unchecked (${names})"
    return 0
  fi
  [ -z "${names}" ] || mapfile -t drop <<< "${names}"
  if [ "${#drop[@]}" -eq 0 ] || [ -z "${store}" ]; then
    _uv_chain_ort_notice "${venv}" "${py}" "${store}" "${drop[@]}"
    return
  fi
  mapfile -t wheels < <(_uv_chain_ort_wheels "${store}" "${gil}")
  if [ "${#wheels[@]}" -eq 0 ]; then
    _uv_chain_ort_no_wheel "${store}" "${gil}" "${drop[*]}"
    return 1
  fi
  _uv_chain_ort_abi_fits "${venv}" "${py}" "${wheels[@]}" || return 1
  info "chain ORT: replacing ${drop[*]} in ${venv} with ${wheels[*]##*/}"
  uv pip uninstall --python "${py}" "${drop[@]}" || return 1
  uv pip install --python "${py}" --no-index --no-deps --force-reinstall "${wheels[@]}" || {
    printf 'ERROR: chain ORT: %s does not take the chain wheels [%s]\n' "${venv}" "${wheels[*]##*/}" >&2
    return 1
  }
  _uv_chain_ort_prove "${venv}" "${py}" "${store}" || return 1
  _uv_chain_ort_hold_sync hold
}

# Inside our images (a store is declared) the store, the interpreter and the census must all exist.
_uv_chain_ort_preflight() {
  if [ -n "$1" ] && { [ ! -d "$1" ] || [ ! -x "$2" ] || [ ! -f "${_UV_ORT_CENSUS}" ]; }; then
    printf 'ERROR: chain ORT: need the store %s, the interpreter %s and the census %s\n' "$1" "$2" "${_UV_ORT_CENSUS}" >&2
    return 1
  fi
  return 0
}

# <store> <py> <venv>: a cp3XYt venv inside our images takes the twins (PYTHON_WHEELS_CP314T), the same chain build, as Windows' Select-UvChainOrtWheelStore does.
_uv_chain_ort_store() {
  local twins="${PYTHON_WHEELS_CP314T:-}"
  if [ -n "$1" ] && [ -n "${twins}" ] && [ -d "${twins}" ]; then
    case "$(_uv_chain_ort_abi "$2" 2>/dev/null)" in
      cp*t) info "chain ORT: $3 is free-threaded, so it takes the twins in ${twins}" >&2; printf '%s\n' "${twins}"; return 0 ;;
    esac
  fi
  printf '%s\n' "$1"
}

# <store> <GIL store> <dists>: why no store wheel can replace the venv's ORT.
_uv_chain_ort_no_wheel() {
  printf 'ERROR: chain ORT: the store %s holds no onnxruntime wheel for %s\n' "$1" "$3" >&2
  [ "$1" = "$2" ] || printf '  It is the twin store of this free-threaded venv, and holds no twin of an ORT flavour in %s.\n' "$2" >&2
}

# <store> <GIL store>: the store's ORT wheels; of the twins only the flavours the GIL store holds, since one venv takes one core.
_uv_chain_ort_wheels() {
  local w d
  for w in "$1"/onnxruntime[-_]*.whl; do
    [ -f "${w}" ] || continue
    d="${w##*/}"
    if [ "$1" = "$2" ] || compgen -G "$2/${d%%-*}-*.whl" >/dev/null; then printf '%s\n' "${w}"; fi
  done
}

# The wheel ABI tag of interpreter $1 (cp313, cp314t); rc 1 with its output.
_uv_chain_ort_abi() {
  local abi
  abi="$("$1" -I -c 'import sys, sysconfig; print("cp%d%d%s" % (*sys.version_info[:2], "t" if sysconfig.get_config_var("Py_GIL_DISABLED") else ""))' 2>&1)" || {
    printf '%s\n' "${abi}"
    return 1
  }
  abi="${abi//$'\r'/}"
  printf '%s\n' "${abi##*$'\n'}"
}

# Every store wheel must fit this venv's ABI tag (cp313, cp314t) before uv touches anything.
_uv_chain_ort_abi_fits() {
  local venv="$1" py="$2" abi w tag bad=""
  shift 2
  abi="$(_uv_chain_ort_abi "${py}")" || {
    printf 'ERROR: chain ORT: cannot read the ABI tag of %s: %s\n' "${py}" "${abi}" >&2
    return 1
  }
  for w in "$@"; do
    tag="${w##*/}"; tag="${tag%.whl}"; tag="${tag%-*}"; tag="${tag##*-}"
    case "${tag}" in "${abi}"|abi3|none) ;; *) bad+=" ${w##*/}" ;; esac
  done
  if [ -z "${bad}" ]; then return 0; fi
  printf 'ERROR: chain ORT: %s is a %s venv, and the chain wheels are built for the image interpreter:%s\n' "${venv}" "${abi}" "${bad}" >&2
  printf '  An ORT project runs its in-image legs on that interpreter: drop this leg or list it in EXPERIMENTAL_PYTHON_VERSIONS.\n' >&2
  return 1
}

# With no ORT dist to purge, nothing may import as ORT either (an unowned copy inside our images).
_uv_chain_ort_unowned() {
  local venv="$1" py="$2" store="$3" out
  out="$("${py}" -I -c 'import importlib.util as u, sys; hits = [p for p in ("onnxruntime", "onnxruntime_genai", "onnxruntime_extensions") if u.find_spec(p)]; print(*hits); sys.exit(1 if hits else 0)' 2>&1)" && return 0
  printf 'ERROR: chain ORT: %s imports ONNX Runtime with no distribution to purge (%s):\n%s\n' "${venv}" "${out//$'\r'/}" \
    "$("${py}" -I "${_UV_ORT_CENSUS}" --check --store "${store}" 2>&1)" >&2
  return 1
}

# The census proves the bytes; the import catches a missing library that the census and ABI check both pass.
_uv_chain_ort_prove() {
  local venv="$1" py="$2" store="$3" out
  out="$("${py}" -I "${_UV_ORT_CENSUS}" --check --store "${store}" 2>&1)" || {
    printf 'ERROR: chain ORT: %s still carries a non-chain ONNX Runtime:\n%s\n' "${venv}" "${out}" >&2
    return 1
  }
  info "${out}"
  out="$("${py}" -I -c 'import sys; print(sys.version); import onnxruntime' 2>&1)" || {
    printf 'ERROR: chain ORT: the chain onnxruntime does not import in %s (the store is built for the image interpreter):\n%s\n' "${venv}" "${out}" >&2
    return 1
  }
  return 0
}

# Nothing to replace: release the hold, or outside our images report what uv resolved. Args: venv py store dists...
_uv_chain_ort_notice() {
  local venv="$1" py="$2" store="$3"
  shift 3
  if [ "$#" -eq 0 ]; then
    [ -z "${store}" ] || _uv_chain_ort_unowned "${venv}" "${py}" "${store}" || return 1
    _uv_chain_ort_hold_sync release
    return 0
  fi
  warn "==== NOTICE: ${venv} runs ONNX Runtime from outside the chain: $* ===="
  warn "  No chain wheel store here (ORT_CHAIN_WHEEL_DIR unset), so it stays as uv resolved it;"
  warn "  inside our images it is reconciled onto the chain wheels or the sync fails."
}

fi
