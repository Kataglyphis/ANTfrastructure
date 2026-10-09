#!/usr/bin/env bash
# [package] [python]: installs dist/'s wheel for this arch over the lock's core deps and loads it. docs/python-ci.md#riscv64-the-image-itself-runs-under-qemu
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/ci-common.sh" || { echo "Error: failed to source ci-common.sh" >&2; exit 1; }

detect_workspace

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  echo "Usage: ci-wheel-smoke.sh [package_name] [python_version]"
  echo "  Installs the one dist/*.whl built for \$(uname -m) and this interpreter's ABI into a fresh"
  echo "  venv over the lock's core dependencies, imports the package and loads every compiled module."
  exit 0
fi

PACKAGE_NAME="$(derive_package_name "${1:-${PACKAGE_NAME:-}}")"
PYTHON_VERSION="${2:-${PYTHON_VERSION:-3.14}}"

prepare_ci_workspace --cd

# <wheel file> <arch> <abi>: whether its last two tags are <abi> and a platform of <arch>.
wheel_matches() {
  local stem="${1%.whl}" plat abi
  plat="${stem##*-}"
  stem="${stem%-*}"
  abi="${stem##*-}"
  if [ "${abi}" = "$3" ] && [[ "${plat}" == *"_$2" ]]; then
    return 0
  fi
  return 1
}

arch="$(uname -m)"
abi="cp$(printf '%s' "${PYTHON_VERSION%t}" | cut -d. -f1,2 | tr -d .)"
wheels=()
for whl in dist/*.whl; do
  [ -f "${whl}" ] || continue
  if wheel_matches "${whl##*/}" "${arch}" "${abi}"; then
    wheels+=("${whl}")
  fi
done
[ "${#wheels[@]}" -eq 1 ] \
  || err "expected one ${abi} ${arch} wheel in dist/, found ${#wheels[@]}: $(ls dist 2>/dev/null | tr '\n' ' ')"
wheel="${wheels[0]}"
dist="${wheel##*/}"
dist="${dist%%-*}"
info "wheel smoke: ${wheel} on $(uname -m)"

uv_cache_seed_restore

VENV="$WORKSPACE_ROOT/.venv_wheel_smoke"
uv_venv_create "$VENV" "$PYTHON_VERSION"

# The lock's core dependencies, no extra and no project: what a user's `pip install <wheel>` gets.
if [ -f uv.lock ]; then
  env -u UV_PYTHON -u VIRTUAL_ENV UV_PROJECT_ENVIRONMENT="$VENV" \
    uv sync --locked --no-dev --no-install-project --python "$VENV/bin/python" \
    || err "the lock's core dependencies do not install into ${VENV}"
  uv pip install --python "$VENV/bin/python" --no-deps "${wheel}" || err "${wheel} does not install into ${VENV}"
else
  uv pip install --python "$VENV/bin/python" "${wheel}" || err "${wheel} does not install into ${VENV}"
fi

# Outside the checkout: the source tree beside it would satisfy the import instead of the wheel.
smoke_dir="$(mktemp -d)"
verdict_rc=0
(cd "${smoke_dir}" && "$VENV/bin/python" -I "$SCRIPT_DIR/wheel-smoke.py" "${dist}" "${PACKAGE_NAME}" --require-compiled) \
  || verdict_rc=$?
rm -rf "${smoke_dir}" "$VENV"
[ "${verdict_rc}" -eq 0 ] || err "the ${arch} wheel ${wheel##*/} failed its smoke (rc ${verdict_rc})"
info "wheel smoke passed: ${wheel##*/}"
