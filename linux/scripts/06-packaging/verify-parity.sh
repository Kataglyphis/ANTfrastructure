#!/usr/bin/env bash
set -euo pipefail

# This standalone host-side tool only needs the log/warn/err/pass/fail/info/retry
# helpers, which all live in the self-contained logging.sh — no need to pull in
# the heavyweight artifact-common.sh aggregator (~14 transitive modules). (The
# old REPO_ROOT="../.." also mis-resolved: from 06-packaging it lands at
# linux/scripts, so the source path doubled to linux/scripts/linux/scripts/...)
_CORE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../01-core" && pwd)"

# shellcheck disable=SC1091
source "${_CORE_DIR}/logging.sh"

CONTAINER_BIN="${CONTAINER_BIN:-nerdctl}"
NATIVE_IMAGE=""
CROSS_IMAGE=""
TMPDIR="${TMPDIR:-/tmp}"
VERBOSE=0
DIFF_TOOL="${DIFF_TOOL:-diff}"
CHECKS="packages,python,versions,files,libs,imports"

usage() {
  cat <<'EOF'
Usage: verify-parity.sh --native IMAGE --cross IMAGE [options]

Compares a natively-built container image against its cross-built counterpart
to verify they have the same software packages and runtime functionality.

Checks performed:
  packages   OS packages (dpkg -l) match
  python     Python venv packages match
  versions   Key binary version strings match
  files      File tree structure matches
  libs       Shared library inventory matches
  imports    Python import smoke test passes in both

Options:
  --native IMAGE     Native-built image reference (required)
  --cross IMAGE      Cross-built image reference (required)
  --checks LIST      Comma-separated list of checks to run
                     (default: packages,python,versions,files,libs,imports)
  --verbose          Show full diff output for each check
  --diff-tool TOOL   Diff tool to use (default: diff)
  -h, --help         Show this help text

Environment overrides:
  CONTAINER_BIN      Container runtime (default: nerdctl)
  TMPDIR             Temporary directory for output files

Examples:
  verify-parity.sh \
    --native ghcr.io/kataglyphis/kataglyphis_beschleuniger:latest-amd64 \
    --cross  ghcr.io/kataglyphis/kataglyphis_beschleuniger:latest-cross-amd64

  verify-parity.sh --native kataglyphis:native-arm64 --cross kataglyphis:cross-arm64 \
    --checks packages,python,versions,imports
EOF
}

trim() {
  local var="$*"
  var="${var#"${var%%[![:space:]]*}"}"
  var="${var%"${var##*[![:space:]]}"}"
  printf '%s' "$var"
}

container_exec() {
  local image="$1"
  shift
  "${CONTAINER_BIN}" run --rm --entrypoint="/bin/bash" "${image}" -lc "$*"
}

container_exec_strip() {
  local image="$1"
  shift
  local _stderr_log; _stderr_log="$(mktemp)"
  container_exec "${image}" "$@" 2>"${_stderr_log}" || {
    cat "${_stderr_log}" >&2
    rm -f "${_stderr_log}"
    return 1
  }
  rm -f "${_stderr_log}"
}

echo_header() {
  printf '\n%b\n' "\033[1;36m=== $* ===\033[0m"
}

normalize_package_list() {
  # Keep only name and version, strip architecture column
  awk 'NR>5 && NF>=3 { for(i=1;i<=NF;i++) { if($i ~ /^[0-9]/) { printf "%s\t%s\n", prev, $i; break } prev=$i } }' "$1" 2>/dev/null | sort
}

normalize_pip_list() {
  # Keep package name and version, strip build info
  awk 'NR>2 && NF>=2 { gsub(/[[:space:]]+/, "\t", $0); print $1 "\t" $2 }' "$1" 2>/dev/null | sort
}

normalize_find_output() {
  # Remove /proc, /sys, /dev, /tmp paths and caches
  sed -E \
    -e '\,^/proc/,d' \
    -e '\,^/sys/,d' \
    -e '\,^/dev/,d' \
    -e '\,^/tmp/,d' \
    -e '\,^/root/\.cache/,d' \
    -e '\,^/var/cache/,d' \
    -e '\,^/var/lib/apt/,d' \
    -e '\,^/run/,d' \
    -e '\,/\.git/,d' \
    -e '\,/__pycache__/,d' \
    -e '\,\.pyc$,d' \
    -e '\,\.pyo$,d' \
    "$1"
}

# ---------------------------------------------------------------------------
# Shared diff helper -- eliminates duplicated diff/count/report logic
# from check_packages, check_files, check_libs, and check_python.
# ---------------------------------------------------------------------------
run_diff_check() {
  local check_name="$1"
  local native_file="$2"
  local cross_file="$3"
  local ok_msg="${4:-}"
  local diff_out="${WORKDIR}/${check_name}.diff"

  if "${DIFF_TOOL}" "${native_file}" "${cross_file}" > "${diff_out}" 2>&1; then
    local count
    count="$(wc -l < "${native_file}")"
    pass "${ok_msg:-All ${check_name} match (${count} entries)}"
    return 0
  fi

  local added removed
  added="$(grep -c '^> ' "${diff_out}" 2>/dev/null || true)"
  removed="$(grep -c '^< ' "${diff_out}" 2>/dev/null || true)"

  fail "${check_name} differ (+${added:-0} -${removed:-0})"
  if [ "${VERBOSE}" -eq 1 ]; then
    cat "${diff_out}"
  else
    printf '    Run with --verbose to see full diff (diff file: %s)\n' "${diff_out}"
  fi
  return 1
}

# ---------------------------------------------------------------------------
# Check: OS packages (dpkg -l)
# ---------------------------------------------------------------------------
check_packages() {
  echo_header "OS Packages (dpkg -l)"

  local native_file="${WORKDIR}/native-packages.txt"
  local cross_file="${WORKDIR}/cross-packages.txt"

  container_exec_strip "${NATIVE_IMAGE}" dpkg -l > "${native_file}" 2>/dev/null || true
  if [ ! -s "${native_file}" ]; then
    fail "Failed to get packages from native image"
    return 1
  fi
  container_exec_strip "${CROSS_IMAGE}" dpkg -l > "${cross_file}" 2>/dev/null || true
  if [ ! -s "${cross_file}" ]; then
    fail "Failed to get packages from cross image"
    return 1
  fi

  normalize_package_list "${native_file}" > "${native_file}.norm"
  normalize_package_list "${cross_file}" > "${cross_file}.norm"

  run_diff_check "OS packages" "${native_file}.norm" "${cross_file}.norm" "All OS packages match ($(wc -l < "${native_file}.norm") packages)"
}

# Venv-activation prologue run inside the container before a python/pip command.
# MUST be single-quoted so ${_v} stays literal in the value; because shell
# variable expansion is not recursive, splicing it into a double-quoted command
# string (e.g. "${_VENV_ACTIVATE_PROLOGUE} python3 -c '${py_cmd}'") keeps ${_v}
# literal for the container shell while ${py_cmd} still interpolates host-side.
_VENV_ACTIVATE_PROLOGUE='for _v in /opt/venv /opt/python/.venv; do [ -f "${_v}/bin/activate" ] && { . "${_v}/bin/activate"; break; }; done 2>/dev/null || true;'

# ---------------------------------------------------------------------------
# Check: Python packages
# ---------------------------------------------------------------------------
check_python() {
  echo_header "Python Packages"

  local native_file="${WORKDIR}/native-pip.txt"
  local cross_file="${WORKDIR}/cross-pip.txt"

  # NOTE: no `bash -lc` prefix here — container_exec is the single wrapper
  # (it already runs the flattened "$*" via `--entrypoint=/bin/bash ... -lc`).
  # A prefixed `bash -lc "cmd"` used to double-wrap: the inner bash received
  # only `bash` as its -c payload, so the venv prologue never ran and this
  # check silently compared SYSTEM packages instead of the venv.
  container_exec_strip "${NATIVE_IMAGE}" \
    "${_VENV_ACTIVATE_PROLOGUE} pip list --format=columns 2>/dev/null || pip3 list --format=columns" \
    > "${native_file}" 2>/dev/null || {
    container_exec_strip "${NATIVE_IMAGE}" 'pip list --format=columns 2>/dev/null || pip3 list --format=columns' \
      > "${native_file}" 2>/dev/null || {
      warn "Cannot extract Python packages from native image (venv may not exist)"
      return 0
    }
  }

  container_exec_strip "${CROSS_IMAGE}" \
    "${_VENV_ACTIVATE_PROLOGUE} pip list --format=columns 2>/dev/null || pip3 list --format=columns" \
    > "${cross_file}" 2>/dev/null || {
    container_exec_strip "${CROSS_IMAGE}" 'pip list --format=columns 2>/dev/null || pip3 list --format=columns' \
      > "${cross_file}" 2>/dev/null || {
      warn "Cannot extract Python packages from cross image (venv may not exist)"
      return 0
    }
  }

  normalize_pip_list "${native_file}" > "${native_file}.norm"
  normalize_pip_list "${cross_file}" > "${cross_file}.norm"

  run_diff_check "Python packages" "${native_file}.norm" "${cross_file}.norm" "All Python packages match ($(wc -l < "${native_file}.norm") packages)"
}

# ---------------------------------------------------------------------------
# Check: Binary versions
# ---------------------------------------------------------------------------
check_versions() {
  echo_header "Binary Version Checks"

  local tools=(
    "gcc --version"
    "g++ --version"
    "clang --version"
    "python3.14 --version"
    "python3 --version"
    "cmake --version"
    "node --version"
    "cargo --version"
    "rustc --version"
    "pkg-config --version"
    "ninja --version"
    "meson --version"
    "git --version"
    "vim --version | head -1"
    "ffmpeg -version | head -1"
    "gst-inspect-1.0 --version"
    "ccache --version"
  )

  local native_file="${WORKDIR}/native-versions.txt"
  local cross_file="${WORKDIR}/cross-versions.txt"
  local failures=0
  local native_out cross_out compared=0

  :> "${native_file}"
  :> "${cross_file}"

  for tool_spec in "${tools[@]}"; do
    # No `bash -lc` prefix — container_exec already wraps (see check_python).
    native_out="$(container_exec_strip "${NATIVE_IMAGE}" "${tool_spec} 2>&1" 2>/dev/null | head -1 || true)"
    cross_out="$(container_exec_strip "${CROSS_IMAGE}" "${tool_spec} 2>&1" 2>/dev/null | head -1 || true)"

    # Two EMPTY outputs compare equal. Count only checks that read something
    # from BOTH images. docs/failure-modes.md
    [ -n "${native_out}" ] && [ -n "${cross_out}" ] && compared=$((compared + 1))
    printf '%s\t%s\n' "${tool_spec%% *}" "${native_out}" >> "${native_file}"
    printf '%s\t%s\n' "${tool_spec%% *}" "${cross_out}" >> "${cross_file}"

    if [ "${native_out}" != "${cross_out}" ]; then
      if [ "${VERBOSE}" -eq 1 ]; then
        printf '  NATIVE %s: %s\n' "${tool_spec%% *}" "${native_out:-MISSING}"
        printf '  CROSS  %s: %s\n' "${tool_spec%% *}" "${cross_out:-MISSING}"
      else
        printf '  DIFF  %-18s native: %s\n' "${tool_spec%% *}:" "${native_out:-MISSING}"
        printf '  DIFF  %-18s cross:  %s\n' "" "${cross_out:-MISSING}"
      fi
      ((failures++)) || true
    fi
  done

  if [ "${compared}" -eq 0 ]; then
    fail "version checks read NOTHING from either image (${#tools[@]} tools attempted) -- two empty outputs compare equal, so a green here would be vacuous"
    return 1
  fi
  if [ "${failures}" -eq 0 ]; then
    pass "All ${compared}/${#tools[@]} version checks match"
    return 0
  fi

  fail "${failures}/${#tools[@]} version checks differ"
  return 1
}

# ---------------------------------------------------------------------------
# Check: File tree
# ---------------------------------------------------------------------------
check_files() {
  echo_header "File Tree Comparison"

  local native_file="${WORKDIR}/native-files.txt"
  local cross_file="${WORKDIR}/cross-files.txt"

  # Single-quoted so the container shell receives the \( ... \) grouping
  # intact. The prune group must come FIRST (no leading -type f, no trailing
  # slash on the -path patterns) or it never prunes anything.
  local find_cmd='find / \( -path /proc -o -path /sys -o -path /dev \) -prune -o -type f -print'

  container_exec_strip "${NATIVE_IMAGE}" "${find_cmd}" 2>/dev/null | sort > "${native_file}" || true
  if [ ! -s "${native_file}" ]; then
    fail "Failed to list files from native image (empty or missing output)"
    return 1
  fi
  container_exec_strip "${CROSS_IMAGE}" "${find_cmd}" 2>/dev/null | sort > "${cross_file}" || true
  if [ ! -s "${cross_file}" ]; then
    fail "Failed to list files from cross image (empty or missing output)"
    return 1
  fi

  normalize_find_output "${native_file}" > "${native_file}.clean"
  normalize_find_output "${cross_file}" > "${cross_file}.clean"

  run_diff_check "File trees" "${native_file}.clean" "${cross_file}.clean" "File trees match ($(wc -l < "${native_file}.clean") files)"
}

# ---------------------------------------------------------------------------
# Check: Shared library inventory
# ---------------------------------------------------------------------------
check_libs() {
  echo_header "Shared Library Inventory"

  local native_file="${WORKDIR}/native-libs.txt"
  local cross_file="${WORKDIR}/cross-libs.txt"

  # Single-quoted payload so '*.so*' stays quoted for the container shell
  # instead of being re-globbed against the container workdir.
  local libs_cmd="find /usr/lib /usr/local/lib /opt -maxdepth 5 -name '*.so*' -type f"

  container_exec_strip "${NATIVE_IMAGE}" "${libs_cmd}" 2>/dev/null \
    | sed -E 's/\.so\.[0-9.]+$/.so.X/' | sort -u > "${native_file}" || true
  if [ ! -s "${native_file}" ]; then
    warn "Cannot list shared libs from native image"
    return 0
  fi

  container_exec_strip "${CROSS_IMAGE}" "${libs_cmd}" 2>/dev/null \
    | sed -E 's/\.so\.[0-9.]+$/.so.X/' | sort -u > "${cross_file}" || true
  if [ ! -s "${cross_file}" ]; then
    warn "Cannot list shared libs from cross image"
    return 0
  fi

  run_diff_check "Shared library sets" "${native_file}" "${cross_file}" "Shared library sets match ($(wc -l < "${native_file}") libraries)"
}

# ---------------------------------------------------------------------------
# Check: Python import smoke test
# ---------------------------------------------------------------------------
check_imports() {
  echo_header "Python Import Smoke Test"

  local modules=(
    "torch"
    "cv2"
    "onnxruntime"
    "numpy"
    "gst"
    "gi"
  )

  local py_cmd
  local failures=0
  local native_out cross_out

  for mod in "${modules[@]}"; do
    # Python strings use DOUBLE quotes: py_cmd is spliced into a single-quoted
    # `python3 -c '...'` below, so a single quote inside it would terminate
    # that quoting in the container shell and break the -c payload.
    py_cmd="import ${mod}; print(\"${mod} ok:\", ${mod}.__version__ if hasattr(${mod}, \"__version__\") else \"loaded\")"

    # No `bash -lc` prefix — container_exec already wraps (see check_python).
    # Judge by RC, not by a sentinel word: the old `|| echo "FAILED"` appended
    # AFTER the captured traceback (the in-container 2>&1 puts it on stdout),
    # so `${out%% *}` parsed "Traceback", never "FAILED" — an ImportError
    # could not increment failures (audit round 2, failure-path F21).
    local native_rc=0 cross_rc=0
    native_out="$(container_exec_strip "${NATIVE_IMAGE}" \
      "${_VENV_ACTIVATE_PROLOGUE} python3 -c '${py_cmd}' 2>&1" 2>/dev/null)" || native_rc=$?

    cross_out="$(container_exec_strip "${CROSS_IMAGE}" \
      "${_VENV_ACTIVATE_PROLOGUE} python3 -c '${py_cmd}' 2>&1" 2>/dev/null)" || cross_rc=$?

    if [ "${native_rc}" -ne 0 ]; then
      printf '  NATIVE %-15s FAILED (rc=%s): %s\n' "${mod}" "${native_rc}" "$(printf '%s' "${native_out}" | tail -1)"
      ((failures++)) || true
    fi
    if [ "${cross_rc}" -ne 0 ]; then
      printf '  CROSS  %-15s FAILED (rc=%s): %s\n' "${mod}" "${cross_rc}" "$(printf '%s' "${cross_out}" | tail -1)"
      ((failures++)) || true
    fi
  done

  if [ "${failures}" -eq 0 ]; then
    pass "All ${#modules[@]} Python imports succeed in both images"
    return 0
  fi

  fail "${failures} Python imports failed"
  return 1
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
# main() decomposed (complexity audit F-F): it carried five responsibilities in
# 107 lines, while this file already showed the clean per-function shape in its
# check_* functions.

verify_parity_parse_args() {
  while [ $# -gt 0 ]; do
    case "$1" in
      --native)    NATIVE_IMAGE="$2"; shift 2 ;;
      --cross)     CROSS_IMAGE="$2";  shift 2 ;;
      --checks)    CHECKS="$2";       shift 2 ;;
      --verbose)   VERBOSE=1;         shift ;;
      --diff-tool) DIFF_TOOL="$2";    shift 2 ;;
      -h|--help)   usage; exit 0 ;;
      *) warn "Unknown option: $1"; usage >&2; exit 1 ;;
    esac
  done
  if [ -z "${NATIVE_IMAGE}" ] || [ -z "${CROSS_IMAGE}" ]; then
    err "Both --native and --cross are required"
  fi
}

# Pull (when absent) and start-probe one image. Usage: _ensure_image <label> <ref>
_ensure_image() {
  local label="$1" image="$2"
  if ! "${CONTAINER_BIN}" image inspect "${image}" >/dev/null 2>&1; then
    log "Pulling ${label} image: ${image}"
    retry 3 10 "pulling ${image}" "${CONTAINER_BIN}" pull "${image}" || {
      err "Cannot pull ${label} image: ${image}"
    }
  fi
  if ! container_exec_strip "${image}" echo "ok" >/dev/null 2>&1; then
    err "${label} image ${image} failed to start a container"
  fi
}

verify_parity_print_header() {
  printf '%b' "\033[1;37m"
  printf '╔══════════════════════════════════════════════════════════╗\n'
  printf '║         Container Image Parity Verification             ║\n'
  printf '╠══════════════════════════════════════════════════════════╣\n'
  printf '║ Native: %-47s ║\n' "${NATIVE_IMAGE:0:47}"
  printf '║ Cross:  %-47s ║\n' "${CROSS_IMAGE:0:47}"
  printf '╚══════════════════════════════════════════════════════════╝\n'
  printf '%b\n' "\033[0m"
}

# Run the selected checks; returns "<passed> <total>" via namerefs.
verify_parity_run_checks() {
  local -n _vprc_passed=$1
  local -n _vprc_total=$2
  local check_name
  local -a CHECK_LIST=()
  IFS=',' read -ra CHECK_LIST <<< "${CHECKS}"

  # Data-driven dispatch: each known check maps to its check_<name> function, so
  # adding a check is one set entry rather than another copy-pasted case arm.
  local -A KNOWN_CHECKS=(
    [packages]=1 [python]=1 [versions]=1 [files]=1 [libs]=1 [imports]=1
  )

  _vprc_passed=0
  _vprc_total=0
  for check_name in "${CHECK_LIST[@]}"; do
    check_name="$(trim "${check_name}")"
    if [ -z "${KNOWN_CHECKS[${check_name}]:-}" ]; then
      err "Unknown check: ${check_name}"   # err exits; no continue needed
    fi
    ((_vprc_total++)) || true
    "check_${check_name}" && ((_vprc_passed++)) || true
  done
}

verify_parity_report() {
  local passed="$1" total="$2"
  printf '\n%b' "\033[1;37m"
  printf '══════════════════════════════════════════════════════════════\n'
  if [ "${passed}" -eq "${total}" ]; then
    printf '  RESULT: %d/%d checks PASSED - images are equivalent\n' "${passed}" "${total}"
    printf '%b\n' "\033[0m"
    return 0
  fi
  printf '  RESULT: %d/%d checks PASSED, %d FAILED\n' "${passed}" "${total}" "$((total - passed))"
  printf '%b\n' "\033[0m"
  return 1
}

main() {
  verify_parity_parse_args "$@"

  WORKDIR="$(mktemp -d "${TMPDIR}/verify-parity.XXXXXX")"
  cleanup() { rm -rf "${WORKDIR}"; }
  trap cleanup EXIT

  _ensure_image "Native" "${NATIVE_IMAGE}"
  _ensure_image "Cross" "${CROSS_IMAGE}"
  verify_parity_print_header

  local passed=0 total=0
  verify_parity_run_checks passed total
  verify_parity_report "${passed}" "${total}"
}

main "$@"
