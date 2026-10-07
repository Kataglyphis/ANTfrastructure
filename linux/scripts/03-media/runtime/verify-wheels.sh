#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

if [ -f /opt/scripts/core/common.sh ]; then
  # shellcheck disable=SC1091
  source /opt/scripts/core/common.sh
fi

# WHEELS_DIR comes from the canonical media-env.sh (sibling of this script).
_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${_SCRIPT_DIR}/media-env.sh"

# <info|warn|err> <message>: the hub's logger when common.sh loaded, else a plain line; err always exits.
_vw_say() {
  local level="$1"
  shift
  if declare -F "${level}" >/dev/null 2>&1; then
    "${level}" "$*"
    return 0
  fi
  case "${level}" in
    info) echo "$*" ;;
    warn) echo "WARNING: $*" >&2 ;;
    *) echo "ERROR: $*" >&2; exit 1 ;;
  esac
}

# --free-threaded grades the cp314t store against the free-threaded interpreter; both runs are ABI-exact, so a misplaced wheel fails either.
FREE_THREADED=0
PY=python
case "${1:-}" in
  --free-threaded)
    FREE_THREADED=1
    WHEELS_DIR="${FT_WHEELS_DIR}"
    PY="$(compgen -G "${PYTHON_FT_PREFIX:-/opt/python-freethreaded}/bin/python3.*t" | head -1 || true)"
    [ -n "${PY}" ] || _vw_say err "no free-threaded interpreter under ${PYTHON_FT_PREFIX:-/opt/python-freethreaded}/bin to grade ${WHEELS_DIR} against"
    ;;
  "") ;;
  *) echo "Usage: $0 [--free-threaded]" >&2; exit 2 ;;
esac

PY_MAJOR="$("${PY}" -c 'import sys; print(sys.version_info.major)')"
PY_MINOR="$("${PY}" -c 'import sys; print(sys.version_info.minor)')"
PY_TAG="cp${PY_MAJOR}${PY_MINOR}"
PY_T="$("${PY}" -c 'import sysconfig; print("t" if sysconfig.get_config_var("Py_GIL_DISABLED") else "")')"
PY_ABI="${PY_TAG}${PY_T}"

# <wheel file name>: 0 when its python and ABI tags load on this interpreter; the other threading build never fits.
_wheel_tag_fits() {
  local stem="${1%.whl}" abi pyt
  stem="${stem%-*}"
  abi="${stem##*-}"
  stem="${stem%-*}"
  pyt="${stem##*-}"
  if [ "${abi}" = "${PY_ABI}" ]; then
    [ "${pyt}" = "${PY_TAG}" ]
    return
  fi
  [ "${FREE_THREADED}" = 0 ] || return 1
  case "${abi}:${pyt}" in
    none:py3 | none:py2.py3 | none:"${PY_TAG}") return 0 ;;
  esac
  # A cp3Y-abi3 wheel runs on any GIL cp3Z with Z >= Y (IREE upstream ships cp312-abi3); a 3.14t interpreter loads no abi3.
  if [ "${abi}" = abi3 ] && [[ "${pyt}" =~ ^cp${PY_MAJOR}([0-9]+)$ ]] && [ "${BASH_REMATCH[1]}" -le "${PY_MINOR}" ]; then
    return 0
  fi
  return 1
}

_vw_say info "Verifying wheels in ${WHEELS_DIR} carry exactly the ${PY_ABI} ABI${PY_T:+ (free-threaded)} or a generic tag..."

shopt -s nullglob
for wheel in "${WHEELS_DIR}"/*.whl; do
  base="$(basename "${wheel}")"
  _wheel_tag_fits "${base}" && continue
  if [ "${FREE_THREADED}" = 1 ]; then
    _vw_say err "Wheel ${base} is not a ${PY_TAG}-${PY_ABI} wheel; only the free-threaded twins belong in ${WHEELS_DIR}"
  fi
  _vw_say err "Wheel ${base} has incorrect tag (expected ${PY_TAG}-${PY_ABI}, a cp3<=${PY_MINOR}-abi3 stable-ABI, or generic py3; a cp3XYt twin belongs in ${FT_WHEELS_DIR})"
done
shopt -u nullglob

_vw_say info "All wheel tags verified"

# Filename tags miss a leaked host SOABI; the triple comes from TARGET_ARCH (this runs on the host).
_wheel_target_triplet() {
  local a="${1:-}"
  if declare -F arch_deb_multiarch_triplet_for >/dev/null 2>&1; then
    arch_deb_multiarch_triplet_for "${a}" 2>/dev/null && return 0
  fi
  case "${a}" in
    amd64|x86_64)  echo "x86_64-linux-gnu" ;;
    arm64|aarch64) echo "aarch64-linux-gnu" ;;
    riscv64)       echo "riscv64-linux-gnu" ;;
    *)             echo "" ;;
  esac
}

# <wheel> <expected suffix>: ABI <member> for the other threading build or an abi3 module in a cp3XYt store (always fatal), ARCH <member> for another triple.
_wheel_soabi_findings() {
  "${PY}" -c '
import re, sys, zipfile
wheel, expected, free = sys.argv[1], sys.argv[2], sys.argv[3] == "1"
want_t = re.search(r"\.cpython-\d+(t?)-", expected).group(1)
try:
    z = zipfile.ZipFile(wheel)
except Exception:
    sys.exit(0)
for n in z.namelist():
    b = n.rsplit("/", 1)[-1]
    if free and b.endswith(".abi3.so"):
        print("ABI " + n)
        continue
    m = re.search(r"\.cpython-\d+(t?)-[^/]*\.so$", b)
    if not m or b.endswith(expected):
        continue
    print(("ABI " if m.group(1) != want_t else "ARCH ") + n)
' "$1" "$2" "${FREE_THREADED}" 2>/dev/null || true
}

_soabi_arch="${TARGET_ARCH:-${TARGETARCH:-}}"
_soabi_triplet="$(_wheel_target_triplet "${_soabi_arch}")"
if [ -z "${_soabi_triplet}" ]; then
  _vw_say warn "wheel SOABI check skipped: could not derive target triple (TARGET_ARCH='${_soabi_arch}')"
else
  _expected_suffix=".cpython-${PY_MAJOR}${PY_MINOR}${PY_T}-${_soabi_triplet}.so"
  # The twins are built natively for this arch only, so a foreign triple there is never advisory.
  _soabi_strict="${WHEEL_SOABI_STRICT:-${FREE_THREADED}}"
  _soabi_bad=0
  _abi_bad=0
  shopt -s nullglob
  for wheel in "${WHEELS_DIR}"/*.whl; do
    while IFS=' ' read -r _kind _so; do
      [ -n "${_so:-}" ] || continue
      if [ "${_kind}" = ABI ]; then
        _abi_bad=1
        _vw_say warn "wheel $(basename "${wheel}"): extension '${_so}' is not built for the ${PY_ABI} ABI (${_expected_suffix}); it cannot load on this interpreter"
      else
        _soabi_bad=1
        _vw_say warn "wheel $(basename "${wheel}"): extension '${_so}' SOABI != expected ${_expected_suffix} (wrong-arch/host SOABI — import would fail on ${_soabi_arch})"
      fi
    done < <(_wheel_soabi_findings "${wheel}" "${_expected_suffix}")
  done
  shopt -u nullglob
  if [ "${_abi_bad}" -eq 1 ]; then
    _vw_say err "one or more wheels in ${WHEELS_DIR} carry an extension of the other threading ABI (see WARN lines)"
  elif [ "${_soabi_bad}" -eq 1 ] && [ "${_soabi_strict}" = "1" ]; then
    _vw_say err "WHEEL_SOABI_STRICT=${_soabi_strict} and one or more wheels carry a wrong-SOABI native extension for ${_soabi_arch} (see WARN lines)"
  elif [ "${_soabi_bad}" -eq 0 ]; then
    _vw_say info "Wheel native-extension SOABI matches ${_expected_suffix}"
  fi
fi
