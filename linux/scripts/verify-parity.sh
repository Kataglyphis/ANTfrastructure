#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

# shellcheck disable=SC1091
source "${REPO_ROOT}/linux/scripts/01-core/artifact-common.sh"

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
  "${CONTAINER_BIN}" run --rm --entrypoint="" "${image}" "$@"
}

container_exec_strip() {
  local image="$1"
  shift
  container_exec "${image}" "$@" 2>/dev/null
}

result_pass() {
  printf '  %b\n' "\033[1;32mPASS\033[0m $*"
}

result_fail() {
  printf '  %b\n' "\033[1;31mFAIL\033[0m $*"
  return 1
}

result_warn() {
  printf '  %b\n' "\033[1;33mWARN\033[0m $*"
}

echo_header() {
  printf '\n%b\n' "\033[1;36m=== $* ===\033[0m"
}

sort_file() {
  sort -o "$1" "$1"
}

strip_container_noise() {
  sed -E \
    -e '/^(WARNING|removed|Cannot|time=|level=|docker|nerdctl)/d' \
    -e 's/\r//g' \
    -e '/^$/d'
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
    result_pass "${ok_msg:-All ${check_name} match (${count} entries)}"
    return 0
  fi

  local added removed
  added="$(grep -c '^> ' "${diff_out}" 2>/dev/null || echo 0)"
  removed="$(grep -c '^< ' "${diff_out}" 2>/dev/null || echo 0)"

  result_fail "${check_name} differ (+${added:-0} -${removed:-0})"
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
    result_fail "Failed to get packages from native image"
    return 1
  fi
  container_exec_strip "${CROSS_IMAGE}" dpkg -l > "${cross_file}" 2>/dev/null || true
  if [ ! -s "${cross_file}" ]; then
    result_fail "Failed to get packages from cross image"
    return 1
  fi

  normalize_package_list "${native_file}" > "${native_file}.norm"
  normalize_package_list "${cross_file}" > "${cross_file}.norm"

  run_diff_check "OS packages" "${native_file}.norm" "${cross_file}.norm" "All OS packages match ($(wc -l < "${native_file}.norm") packages)"
}

# ---------------------------------------------------------------------------
# Check: Python packages
# ---------------------------------------------------------------------------
check_python() {
  echo_header "Python Packages"

  local native_file="${WORKDIR}/native-pip.txt"
  local cross_file="${WORKDIR}/cross-pip.txt"

  container_exec_strip "${NATIVE_IMAGE}" bash -lc \
    'source /opt/python/.venv/bin/activate 2>/dev/null || true; pip list --format=columns 2>/dev/null || pip3 list --format=columns' \
    > "${native_file}" 2>/dev/null || {
    container_exec_strip "${NATIVE_IMAGE}" bash -lc 'pip list --format=columns 2>/dev/null || pip3 list --format=columns' \
      > "${native_file}" 2>/dev/null || {
      result_warn "Cannot extract Python packages from native image (venv may not exist)"
      return 0
    }
  }

  container_exec_strip "${CROSS_IMAGE}" bash -lc \
    'source /opt/python/.venv/bin/activate 2>/dev/null || true; pip list --format=columns 2>/dev/null || pip3 list --format=columns' \
    > "${cross_file}" 2>/dev/null || {
    container_exec_strip "${CROSS_IMAGE}" bash -lc 'pip list --format=columns 2>/dev/null || pip3 list --format=columns' \
      > "${cross_file}" 2>/dev/null || {
      result_warn "Cannot extract Python packages from cross image (venv may not exist)"
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
  local native_out cross_out

  :> "${native_file}"
  :> "${cross_file}"

  for tool_spec in "${tools[@]}"; do
    native_out="$(container_exec_strip "${NATIVE_IMAGE}" bash -lc "${tool_spec} 2>&1" 2>/dev/null | head -1 || true)"
    cross_out="$(container_exec_strip "${CROSS_IMAGE}" bash -lc "${tool_spec} 2>&1" 2>/dev/null | head -1 || true)"

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

  if [ "${failures}" -eq 0 ]; then
    result_pass "All ${#tools[@]} version checks match"
    return 0
  fi

  result_fail "${failures}/${#tools[@]} version checks differ"
  return 1
}

# ---------------------------------------------------------------------------
# Check: File tree
# ---------------------------------------------------------------------------
check_files() {
  echo_header "File Tree Comparison"

  local native_file="${WORKDIR}/native-files.txt"
  local cross_file="${WORKDIR}/cross-files.txt"

  container_exec_strip "${NATIVE_IMAGE}" find / -type f 2>/dev/null | sort > "${native_file}" || true
  if [ ! -s "${native_file}" ]; then
    result_fail "Failed to list files from native image (empty or missing output)"
    return 1
  fi
  container_exec_strip "${CROSS_IMAGE}" find / -type f 2>/dev/null | sort > "${cross_file}" || true
  if [ ! -s "${cross_file}" ]; then
    result_fail "Failed to list files from cross image (empty or missing output)"
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

  container_exec_strip "${NATIVE_IMAGE}" find \
    /usr/lib /usr/local/lib /opt \
    -maxdepth 5 -name '*.so*' -type f 2>/dev/null \
    | sed -E 's/\.so\.[0-9.]+$/.so.X/' | sort -u > "${native_file}" || true
  if [ ! -s "${native_file}" ]; then
    result_warn "Cannot list shared libs from native image"
    return 0
  fi

  container_exec_strip "${CROSS_IMAGE}" find \
    /usr/lib /usr/local/lib /opt \
    -maxdepth 5 -name '*.so*' -type f 2>/dev/null \
    | sed -E 's/\.so\.[0-9.]+$/.so.X/' | sort -u > "${cross_file}" || true
  if [ ! -s "${cross_file}" ]; then
    result_warn "Cannot list shared libs from cross image"
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
    py_cmd="import ${mod}; print('${mod} ok:', ${mod}.__version__ if hasattr(${mod}, '__version__') else 'loaded')"

    native_out="$(container_exec_strip "${NATIVE_IMAGE}" bash -lc \
      "source /opt/python/.venv/bin/activate 2>/dev/null || true; python3 -c '${py_cmd}' 2>&1" 2>/dev/null || echo "FAILED")"

    cross_out="$(container_exec_strip "${CROSS_IMAGE}" bash -lc \
      "source /opt/python/.venv/bin/activate 2>/dev/null || true; python3 -c '${py_cmd}' 2>&1" 2>/dev/null || echo "FAILED")"

    local native_status="${native_out%% *}"
    local cross_status="${cross_out%% *}"

    if [ "${native_status}" = "FAILED" ]; then
      printf '  NATIVE %-15s FAILED: %s\n' "${mod}" "${native_out}"
      ((failures++)) || true
    fi
    if [ "${cross_status}" = "FAILED" ]; then
      printf '  CROSS  %-15s FAILED: %s\n' "${mod}" "${cross_out}"
      ((failures++)) || true
    fi
  done

  if [ "${failures}" -eq 0 ]; then
    result_pass "All ${#modules[@]} Python imports succeed in both images"
    return 0
  fi

  result_fail "${failures} Python imports failed"
  return 1
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
main() {
  while [ $# -gt 0 ]; do
    case "$1" in
      --native)
        NATIVE_IMAGE="$2"
        shift 2
        ;;
      --cross)
        CROSS_IMAGE="$2"
        shift 2
        ;;
      --checks)
        CHECKS="$2"
        shift 2
        ;;
      --verbose)
        VERBOSE=1
        shift
        ;;
      --diff-tool)
        DIFF_TOOL="$2"
        shift 2
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        err "Unknown option: $1"
        ;;
    esac
  done

  if [ -z "${NATIVE_IMAGE}" ] || [ -z "${CROSS_IMAGE}" ]; then
    err "Both --native and --cross are required"
  fi

  WORKDIR="$(mktemp -d "${TMPDIR}/verify-parity.XXXXXX")"
  cleanup() { rm -rf "${WORKDIR}"; }
  trap cleanup EXIT

  # Pre-flight: verify both images are runnable
  if ! "${CONTAINER_BIN}" image inspect "${NATIVE_IMAGE}" >/dev/null 2>&1; then
    log "Pulling native image: ${NATIVE_IMAGE}"
    "${CONTAINER_BIN}" pull "${NATIVE_IMAGE}" || {
      err "Cannot pull native image: ${NATIVE_IMAGE}"
    }
  fi

  if ! "${CONTAINER_BIN}" image inspect "${CROSS_IMAGE}" >/dev/null 2>&1; then
    log "Pulling cross image: ${CROSS_IMAGE}"
    "${CONTAINER_BIN}" pull "${CROSS_IMAGE}" || {
      err "Cannot pull cross image: ${CROSS_IMAGE}"
    }
  fi

  # Quick sanity check that both containers can start
  if ! container_exec_strip "${NATIVE_IMAGE}" echo "ok" >/dev/null 2>&1; then
    err "Native image ${NATIVE_IMAGE} failed to start a container"
  fi

  if ! container_exec_strip "${CROSS_IMAGE}" echo "ok" >/dev/null 2>&1; then
    err "Cross image ${CROSS_IMAGE} failed to start a container"
  fi

  printf '%b' "\033[1;37m"
  printf '╔══════════════════════════════════════════════════════════╗\n'
  printf '║         Container Image Parity Verification             ║\n'
  printf '╠══════════════════════════════════════════════════════════╣\n'
  printf '║ Native: %-47s ║\n' "${NATIVE_IMAGE:0:47}"
  printf '║ Cross:  %-47s ║\n' "${CROSS_IMAGE:0:47}"
  printf '╚══════════════════════════════════════════════════════════╝\n'
  printf '%b\n' "\033[0m"

  IFS=',' read -ra CHECK_LIST <<< "${CHECKS}"

  local total=0
  local passed=0
  local check_name

  for check_name in "${CHECK_LIST[@]}"; do
    check_name="$(trim "${check_name}")"
    case "${check_name}" in
      packages)
        ((total++)) || true
        check_packages && ((passed++)) || true
        ;;
      python)
        ((total++)) || true
        check_python && ((passed++)) || true
        ;;
      versions)
        ((total++)) || true
        check_versions && ((passed++)) || true
        ;;
      files)
        ((total++)) || true
        check_files && ((passed++)) || true
        ;;
      libs)
        ((total++)) || true
        check_libs && ((passed++)) || true
        ;;
      imports)
        ((total++)) || true
        check_imports && ((passed++)) || true
        ;;
      *)
        err "Unknown check: ${check_name}"
        ;;
    esac
  done

  printf '\n%b' "\033[1;37m"
  printf '══════════════════════════════════════════════════════════════\n'
  if [ "${passed}" -eq "${total}" ]; then
    printf '  RESULT: %d/%d checks PASSED - images are equivalent\n' "${passed}" "${total}"
    printf '%b\n' "\033[0m"
    exit 0
  else
    printf '  RESULT: %d/%d checks PASSED, %d FAILED\n' "${passed}" "${total}" "$((total - passed))"
    printf '%b\n' "\033[0m"
    exit 1
  fi
}

main "$@"
