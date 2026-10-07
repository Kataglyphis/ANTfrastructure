#!/usr/bin/env bash
# Builds the sdist and wheels (GIL, plus free-threaded when declared), auditwheel-repairing platform wheels, then any packaging/app.json app; PYTHON_VERSION (arg 1) defaults to 3.14.

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
  # The sysroot's libc before the host LIBDIR setuptools adds, whose libc.so script forces elf64-x86-64 on lld (run 37329297990).
  export LDSHARED="${CC} -shared -L${RISCV64_SYSROOT}/lib/riscv64-linux-gnu -L${RISCV64_SYSROOT}/usr/lib/riscv64-linux-gnu"
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
    # uv build ignores the venv; +gil, as a plain request may take the image's python3.14t.
    uv build --python "$(uv_python_request "${PYTHON_VERSION}")"
  fi
}

# See docs/python-ci.md#two-wheels-gil-and-free-threaded
FT_HELPER="$SCRIPT_DIR/free-threaded-wheel.py"
FT_MODE="${PYTHON_FREE_THREADED_WHEEL:-auto}"
FT_VERSION="$(printf '%s' "${PYTHON_VERSION%t}" | cut -d. -f1,2)t"
FT_ABI="cp$(printf '%s' "${FT_VERSION%t}" | tr -d .)t"
FT_PYTHON=""
FT_WHEEL=""
case "${FT_MODE}" in
  auto|on|off) ;;
  *) err "PYTHON_FREE_THREADED_WHEEL must be auto, on or off, not '${FT_MODE}'" ;;
esac

# 0 when this run builds the free-threaded wheel; every skip logs its reason.
free_threaded_wheel_wanted() {
  local verdict rc=0
  if [ -n "${CROSS_TARGET}" ]; then
    info "free-threaded wheel skipped: the ${CROSS_TARGET} cross build has no free-threaded target interpreter"
    return 1
  fi
  if [ "${FT_MODE}" = off ]; then
    info "free-threaded wheel skipped: PYTHON_FREE_THREADED_WHEEL=off"
    return 1
  fi
  verdict="$(python3 -I "${FT_HELPER}" declares pyproject.toml 2>&1)" || rc=$?
  case "${FT_MODE}:${rc}" in
    *:0) info "free-threaded wheel: the project declares '${verdict}'" ;;
    on:1) info "free-threaded wheel: PYTHON_FREE_THREADED_WHEEL=on, although ${verdict}" ;;
    auto:1) info "free-threaded wheel skipped: the project does not declare support (${verdict})"; return 1 ;;
    *) err "cannot tell whether the project declares free-threading support: ${verdict}" ;;
  esac
}

# The binary build again on the image's free-threaded interpreter, which is found, never downloaded.
build_free_threaded_wheel() {
  local out="$WORKSPACE_ROOT/build/free-threaded-dist" name abi
  local -a wheels=()
  FT_PYTHON="$(uv python find "${FT_VERSION}" 2>/dev/null)" ||
    err "no ${FT_VERSION} interpreter for the free-threaded wheel (the image ships python${FT_VERSION}); PYTHON_FREE_THREADED_WHEEL=off skips it"
  info "free-threaded wheel: building with ${FT_PYTHON}"
  rm -rf "${out}"
  uv build --python "${FT_PYTHON}" --out-dir "${out}" || err "the free-threaded build failed"
  wheels=("${out}"/*.whl)
  [ "${#wheels[@]}" -eq 1 ] || err "the free-threaded build left ${#wheels[@]} wheels in ${out}, not one"
  name="${wheels[0]##*/}"
  abi="${name%-*}"
  abi="${abi##*-}"
  case "${abi}" in
    "${FT_ABI}") mv "${wheels[0]}" dist/; FT_WHEEL="${name}" ;;
    none) info "free-threaded wheel: the build is pure (${name}), and the py3-none-any wheel already serves ${FT_VERSION}" ;;
    *) err "the free-threaded build produced ${name}, not a ${FT_ABI} wheel" ;;
  esac
  rm -rf "${out}"
}

# A fresh venv of the free-threaded interpreter takes the shipped wheel, and its modules must leave the GIL off.
prove_free_threaded_wheel() {
  local venv="$WORKSPACE_ROOT/.venv_packaging_free_threaded" verdict
  local -a wheels=(dist/*-"${FT_ABI}"-*.whl)
  [ "${#wheels[@]}" -eq 1 ] || err "expected one ${FT_ABI} wheel in dist/ after the repair, found ${#wheels[@]}"
  uv venv --python "${FT_PYTHON}" --clear "${venv}" || err "cannot create the proof venv ${venv}"
  uv pip install --python "${venv}/bin/python" --no-deps "${wheels[0]}" || err "${wheels[0]} does not install into ${venv}"
  verdict="$("${venv}/bin/python" -I "${FT_HELPER}" prove "${FT_WHEEL%%-*}" 2>&1)" ||
    err "free-threaded proof failed for ${wheels[0]##*/}: ${verdict}"
  info "free-threaded proof: ${verdict}"
  rm -rf "${venv}"
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

if free_threaded_wheel_wanted; then
  build_free_threaded_wheel
fi

info "Found wheels:"
ls -la dist || true

# The packaging venv's auditwheel counts too: the fresh venv is never activated, so PATH alone found none.
AUDITWHEEL="$(command -v auditwheel || true)"
[ -n "${AUDITWHEEL}" ] || [ ! -x "${VENV_BINARIES}/bin/auditwheel" ] || AUDITWHEEL="${VENV_BINARIES}/bin/auditwheel"

for whl in dist/*.whl; do
  info "Inspecting wheel: $whl"
  if [[ "${whl}" == *-none-any.whl ]]; then
    info "  Pure wheel -> copying unchanged: $whl"
    cp "$whl" repaired/
  elif [ -n "${CROSS_TARGET}" ]; then
    info "  ${CROSS_TARGET} cross wheel -> copying unrepaired, as auditwheel would graft host libraries: $whl"
    cp "$whl" repaired/
  elif [ -z "${AUDITWHEEL}" ]; then
    warn "  Platform wheel, but no auditwheel on PATH or in ${VENV_BINARIES} -> shipping it unrepaired: $whl"
    cp "$whl" repaired/
  else
    info "  Platform wheel -> repairing with ${AUDITWHEEL}: $whl"
    "${AUDITWHEEL}" repair "$whl" -w repaired/ || err "auditwheel failed on $whl"
  fi
done

rm -f dist/*.whl || true
mv repaired/*.whl dist/ || true
rmdir repaired || true

info "Final wheels in dist/:"
ls -la dist || true

if [ -n "${FT_WHEEL}" ]; then
  prove_free_threaded_wheel
fi

# packaging/app.json opts the consumer in; its packages need the AppImage tooling amd64/arm64 ships, so riscv64 ships wheels only (docs/python-app-bundles.md § Packages).
if [ -f packaging/app.json ]; then
  if [ "$(uname -m)" = "riscv64" ] || [ "${CROSS_TARGET}" = "riscv64" ]; then
    warn "packaging/app.json present: the tar/deb/AppImage packages are amd64/arm64, so riscv64 ships wheels only"
  else
    bash "$SCRIPT_DIR/../../06-packaging/python-app-bundle.sh" --wheel-dir dist --out-dir build/app-bundle
    bash "$SCRIPT_DIR/../../06-packaging/python-app-package.sh" --bundle build/app-bundle --out-dir dist/packages
  fi
fi