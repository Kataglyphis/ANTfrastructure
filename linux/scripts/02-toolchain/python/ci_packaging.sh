#!/usr/bin/env bash
# Builds the sdist and wheels, auditwheel-repairing platform wheels, then any packaging/app.json app; PYTHON_VERSION (arg 1) defaults to 3.14.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/ci-common.sh" || { echo "Error: failed to source ci-common.sh" >&2; exit 1; }

detect_workspace

PYTHON_VERSION="${1:-${PYTHON_VERSION:-3.14}}"
info "Using Python version: $PYTHON_VERSION"

prepare_ci_workspace --cd

# The lane's SYNC_EXTRAS input limits the syncs here too: --all-extras cannot build under emulation (docs/python-ci.md#riscv64-the-image-itself-runs-under-qemu).
if [ -n "${SYNC_EXTRAS:-}" ]; then
  export UV_SYNC_EXTRAS="${SYNC_EXTRAS}"
fi

# Cross mode (PACKAGING_CROSS_TARGET): build the target's wheel on the native host; docs/linux-cross-builds.md - Cross Python wheels.
CROSS_TARGET="${PACKAGING_CROSS_TARGET:-}"

packaging_cross_env() {
  local target="$1" cross_env="" riscv_cross="" python_root="" mm=""

  if [ "${target}" != "riscv64" ]; then
    err "PACKAGING_CROSS_TARGET=${target} is not supported; only riscv64 has a staged target Python"
    return 1
  fi

  for candidate in "/opt/scripts/core/cross-env.sh" "$SCRIPT_DIR/../../01-core/cross-env.sh"; do
    [ -f "${candidate}" ] && { cross_env="${candidate}"; break; }
  done
  for candidate in "/opt/scripts/lib/riscv64-cross.sh" "$SCRIPT_DIR/../../lib/riscv64-cross.sh"; do
    [ -f "${candidate}" ] && { riscv_cross="${candidate}"; break; }
  done
  if [ -z "${cross_env}" ] || [ -z "${riscv_cross}" ]; then
    err "cross mode needs cross-env.sh and riscv64-cross.sh beside the scripts or under /opt/scripts"
    return 1
  fi

  # shellcheck disable=SC1090
  source "${cross_env}"
  # shellcheck disable=SC1090
  source "${riscv_cross}"
  riscv64_cross_env || return 1

  python_root="$(cross_target_python_root "${target}" 2>/dev/null || true)"
  local include_flag=""
  if [ -n "${python_root}" ]; then
    include_flag="-I${python_root}/include/python${PYTHON_VERSION}"
  else
    # No staged cross Python in this image: the sysroot carries the target's headers, and the cross wrapper roots absolute -I paths into it.
    [ -d "${RISCV64_SYSROOT}/usr/include/python${PYTHON_VERSION}" ] || {
      err "no staged ${target} Python and no ${RISCV64_SYSROOT}/usr/include/python${PYTHON_VERSION} in the sysroot"
      return 1
    }
    include_flag="-I/usr/include/python${PYTHON_VERSION}"
  fi
  mm="$(printf '%s' "${PYTHON_VERSION}" | tr -d '.')"

  # The same values arch_linux_platform_tag_for/cross_target_python_include_dir resolve in the image.
  local plat_tag="linux_${target}"
  if command -v arch_linux_platform_tag_for >/dev/null 2>&1; then
    plat_tag="$(arch_linux_platform_tag_for "${target}" || printf '%s' "linux_${target}")"
  fi

  export CC="${RISCV64_CROSS_BIN}/riscv64-linux-gnu-clang"
  export LDSHARED="${CC} -shared"
  # NOT _PYTHON_HOST_PLATFORM: uv reads it while inspecting the interpreter and refuses "Unknown operating system: linux_riscv64".
  export PYTHON_HOST_PLATFORM_TARGET="${plat_tag}"
  export SETUPTOOLS_EXT_SUFFIX=".cpython-${mm}-riscv64-linux-gnu.so"
  # CFLAGS REPLACES the sysconfig flags, so the target headers win over the host's and -O2 survives.
  export CFLAGS="-O2 ${include_flag}"
  info "cross packaging for ${target}: ${CC}, include ${include_flag}, platform ${plat_tag}"
}

if [ -n "${CROSS_TARGET}" ]; then
  packaging_cross_env "${CROSS_TARGET}"
fi

# Cross wheels go through pip: uv refuses the target platform tag, so only the build command may see _PYTHON_HOST_PLATFORM.
package_build() {
  local venv="$1"
  if [ -n "${CROSS_TARGET}" ]; then
    uv build --sdist
    _PYTHON_HOST_PLATFORM="${PYTHON_HOST_PLATFORM_TARGET}" "${venv}/bin/python" -m pip wheel . --no-deps -w dist
  else
    uv build
  fi
}

if command -v patchelf >/dev/null 2>&1; then
  info "patchelf already installed"
else
  SUDO_CMD=""
  if command -v sudo >/dev/null 2>&1; then
    SUDO_CMD="sudo"
  fi
  $SUDO_CMD apt-get update
  $SUDO_CMD apt-get install -y patchelf
fi

VENV_SOURCES="$WORKSPACE_ROOT/.venv_packaging_sources"
uv_venv_ensure "$VENV_SOURCES" "$PYTHON_VERSION" "source packaging venv"

uv_sync_project --no-wxpython

package_build "$VENV_SOURCES"

export CYTHONIZE="True"

VENV_BINARIES="$WORKSPACE_ROOT/.venv_packaging_binaries"
uv_venv_ensure "$VENV_BINARIES" "$PYTHON_VERSION" "binary packaging venv"

uv_sync_project --no-wxpython

package_build "$VENV_BINARIES"

mkdir -p dist repaired
shopt -s nullglob
info "Found wheels:"
ls -la dist || true

for whl in dist/*.whl; do
  info "Inspecting wheel: $whl"
  if auditwheel show "$whl" >/dev/null 2>&1; then
    info "  Platform wheel detected -> repairing: $whl"
    auditwheel repair "$whl" -w repaired/ || { err "auditwheel failed on $whl"; exit 1; }
  else
    info "  Pure/Python wheel detected -> copying unchanged: $whl"
    cp "$whl" repaired/
  fi
done

rm -f dist/*.whl || true
mv repaired/*.whl dist/ || true
rmdir repaired || true

info "Final wheels in dist/:"
ls -la dist || true

# packaging/app.json opts the consumer in; its packages need the AppImage tooling amd64/arm64 ships, so riscv64 ships wheels only (docs/python-app-bundles.md § Packages).
if [ -f packaging/app.json ]; then
  if [ "$(uname -m)" = "riscv64" ] || [ "${CROSS_TARGET}" = "riscv64" ]; then
    warn "packaging/app.json present: the tar/deb/AppImage packages are amd64/arm64, so riscv64 ships wheels only"
  else
    bash "$SCRIPT_DIR/../../06-packaging/python-app-bundle.sh" --wheel-dir dist --out-dir build/app-bundle
    bash "$SCRIPT_DIR/../../06-packaging/python-app-package.sh" --bundle build/app-bundle --out-dir dist/packages
  fi
fi