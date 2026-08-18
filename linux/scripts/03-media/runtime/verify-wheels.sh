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

PY_MAJOR="$(python -c 'import sys; print(sys.version_info.major)')"
PY_MINOR="$(python -c 'import sys; print(sys.version_info.minor)')"
PY_TAG="cp${PY_MAJOR}${PY_MINOR}"

if declare -F info >/dev/null 2>&1; then
  info "Verifying wheels in ${WHEELS_DIR} have the correct tag (${PY_TAG} or generic)..."
else
  echo "Verifying wheels in ${WHEELS_DIR} have the correct tag (${PY_TAG} or generic)..."
fi

shopt -s nullglob
for wheel in "${WHEELS_DIR}"/*.whl; do
  base="$(basename "${wheel}")"
  # Accept: exact container interpreter tag (cpXY-), or pure-python (py3-none / py2.py3-none).
  case "${base}" in
    *"${PY_TAG}-"*|*py2.py3-none-*|*py3-none-*) continue ;;
  esac
  # Accept stable-ABI (abi3) wheels whose interpreter floor is <= the container's.
  # abi3 is the CPython stable ABI: a cp3Y-abi3 wheel is forward-compatible and
  # installs/runs on cp3Z for any Z >= Y. This is exactly how IREE ships its
  # iree_base_compiler / iree_base_runtime wheels (cp312-abi3), including the
  # riscv64 cross-build on container Python 3.14. Same tag as the amd64/arm64 PyPI
  # IREE wheels — abi3 is not a defect, it's the intended, correct packaging.
  if [[ "${base}" =~ -cp([0-9])([0-9]+)-abi3- ]]; then
    _w_major="${BASH_REMATCH[1]}"
    _w_minor="${BASH_REMATCH[2]}"
    if [ "${_w_major}" = "${PY_MAJOR}" ] && [ "${_w_minor}" -le "${PY_MINOR}" ]; then
      continue
    fi
  fi
  # Otherwise the tag is genuinely incompatible with the container interpreter.
  if declare -F err >/dev/null 2>&1; then
    err "Wheel ${base} has incorrect tag (expected ${PY_TAG}-, a cp3<=${PY_MINOR}-abi3 stable-ABI, or generic py3)"
  else
    echo "ERROR: Wheel ${base} has incorrect tag (expected ${PY_TAG}-, a cp3<=${PY_MINOR}-abi3 stable-ABI, or generic py3)" >&2
    exit 1
  fi
done
shopt -u nullglob

if declare -F info >/dev/null 2>&1; then
  info "All wheel tags verified"
else
  echo "All wheel tags verified"
fi

# ---------------------------------------------------------------------------
# SOABI / default-triple assert (backlog: cross-wheel SOABI assert). The tag
# loop above only checks the wheel FILENAME's Python tag (cpXY) — which is
# version-matched between the host and the target, so it CANNOT catch an
# arch/SOABI mismatch: a wheel named foo-cp314-cp314-linux_riscv64.whl can still
# carry a native extension stamped `.cpython-314-x86_64-linux-gnu.so` (a
# cross-build that leaked the host BUILD_PYTHON's SOABI), which installs fine and
# only explodes at `import` on-target ("cannot open shared object"). Check the
# ACTUAL extension SOABI inside each wheel against the TARGET triple.
#
# Uses TARGET_ARCH (NOT the running interpreter's EXT_SUFFIX): during a cross
# build this script runs on the amd64 HOST, so the host suffix would falsely
# reject every correct riscv64/arm64 wheel. The Python VERSION is host==target
# (both cp314), so only the arch triple has to be derived from TARGET_ARCH.
#
# Advisory by default (WARN) — a wrong triple map must never break the build we
# cannot re-validate here; WHEEL_SOABI_STRICT=1 promotes mismatches to fatal.
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

_soabi_arch="${TARGET_ARCH:-${TARGETARCH:-}}"
_soabi_triplet="$(_wheel_target_triplet "${_soabi_arch}")"
if [ -z "${_soabi_triplet}" ]; then
  if declare -F warn >/dev/null 2>&1; then
    warn "wheel SOABI check skipped: could not derive target triple (TARGET_ARCH='${_soabi_arch}')"
  else
    echo "WARNING: wheel SOABI check skipped: could not derive target triple (TARGET_ARCH='${_soabi_arch}')" >&2
  fi
else
  _expected_suffix=".cpython-${PY_MAJOR}${PY_MINOR}-${_soabi_triplet}.so"
  _soabi_strict="${WHEEL_SOABI_STRICT:-0}"
  _soabi_bad=0
  shopt -s nullglob
  for wheel in "${WHEELS_DIR}"/*.whl; do
    # List native cpython extension .so members whose SOABI suffix != expected.
    # abi3 (.abi3.so) and generic .so (bundled C libs, no cpython tag) are skipped
    # here — abi3 is intentionally arch/version-forward, and non-extension .so are
    # the runtime .so-closure smoke's job, not the Python-import SOABI's.
    _bad_so="$(python -c '
import sys, zipfile, re
wheel, expected = sys.argv[1], sys.argv[2]
try:
    z = zipfile.ZipFile(wheel)
except Exception as e:
    sys.exit(0)
for n in z.namelist():
    b = n.rsplit("/", 1)[-1]
    if not b.endswith(".so"):
        continue
    if not re.search(r"\.cpython-\d+-", b):
        continue  # abi3 / generic .so
    if not b.endswith(expected):
        print(n)
' "${wheel}" "${_expected_suffix}" 2>/dev/null || true)"
    if [ -n "${_bad_so}" ]; then
      _soabi_bad=1
      while IFS= read -r _so; do
        [ -n "${_so}" ] || continue
        if declare -F warn >/dev/null 2>&1; then
          warn "wheel $(basename "${wheel}"): extension '${_so}' SOABI != expected ${_expected_suffix} (wrong-arch/host SOABI — import would fail on ${_soabi_arch})"
        else
          echo "WARNING: wheel $(basename "${wheel}"): extension '${_so}' SOABI != ${_expected_suffix}" >&2
        fi
      done <<< "${_bad_so}"
    fi
  done
  shopt -u nullglob
  if [ "${_soabi_bad}" -eq 1 ] && [ "${_soabi_strict}" = "1" ]; then
    if declare -F err >/dev/null 2>&1; then
      err "WHEEL_SOABI_STRICT=1 and one or more wheels carry a wrong-SOABI native extension for ${_soabi_arch} (see WARN lines)"
    else
      echo "ERROR: WHEEL_SOABI_STRICT=1 and wrong-SOABI native extension(s) for ${_soabi_arch}" >&2
      exit 1
    fi
  elif [ "${_soabi_bad}" -eq 0 ]; then
    if declare -F info >/dev/null 2>&1; then
      info "Wheel native-extension SOABI matches ${_expected_suffix}"
    else
      echo "Wheel native-extension SOABI matches ${_expected_suffix}"
    fi
  fi
fi
