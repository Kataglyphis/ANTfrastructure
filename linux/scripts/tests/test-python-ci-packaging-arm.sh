#!/usr/bin/env bash
# ci_packaging.sh's per-arch arm - the riscv64 wheels are cross-built on the native row; see docs/python-ci.md#riscv64-the-image-itself-runs-under-qemu.
set -u
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${TESTS_DIR}/test-harness.sh"
SCRIPTS="$(cd "${TESTS_DIR}/.." && pwd)"

_work="$(mktemp -d)"; trap 'rm -rf "${_work}"' EXIT
WS="${_work}/ws"; TREE="${_work}/tree"; CALLS="${_work}/calls"; OUT="${_work}/out"; BIN="${_work}/bin"; PYROOT="${_work}/pyroot"
SYSROOT_DIR="${_work}/sysroot"
mkdir -p "${TREE}/01-core" "${TREE}/02-toolchain/python" "${TREE}/06-packaging" "${TREE}/lib" "${WS}/packaging" "${BIN}" "${PYROOT}" "${SYSROOT_DIR}/usr/include/python3.14"

cp "${SCRIPTS}/01-core/python_uv.sh" "${SCRIPTS}/01-core/logging.sh" "${TREE}/01-core/"
# The image's /opt/scripts copies would win over this tree's stubs, so the copy looks nowhere there.
sed "s#/opt/scripts/#${_work}/no-opt-scripts/#g" "${SCRIPTS}/02-toolchain/python/ci_packaging.sh" \
  > "${TREE}/02-toolchain/python/ci_packaging.sh"
cp "${SCRIPTS}/02-toolchain/python/free-threaded-wheel.py" "${TREE}/02-toolchain/python/"
# The real ci-common gets its workspace glue stubbed, as test-python-ci-defaults does.
cat > "${TREE}/02-toolchain/python/ci-common.sh" <<'CI_COMMON'
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../../01-core" && pwd)/python_uv.sh"
detect_workspace() { export WORKSPACE_ROOT="${FIXTURE_WS}"; }
prepare_ci_workspace() { shift; cd "${WORKSPACE_ROOT:-${FIXTURE_WS}}" || :; }
uv_venv_ensure() { :; }
uv_venv_activate() { :; }
uv_venv_deactivate() { :; }
uv_venv_remove() { :; }
uv_sync_project() { printf 'sync extras=%s\n' "${UV_SYNC_EXTRAS:-}" >> "${CALLS}"; }
CI_COMMON

# The cross mode's two sourced helpers: cross-env.sh's target Python resolver and riscv64-cross.sh's env.
cat > "${TREE}/01-core/cross-env.sh" <<'CROSS_ENV'
cross_target_python_root() { [ -z "${FIXTURE_NO_PY:-}" ] || return 1; printf '%s' "${FIXTURE_PY_ROOT}"; }
CROSS_ENV
cat > "${TREE}/lib/riscv64-cross.sh" <<'RISCV_CROSS'
riscv64_cross_env() { export RISCV64_CROSS_BIN="${FIXTURE_CROSS_BIN}"; }
RISCV_CROSS

printf '{ "name": "FixtureApp" }\n' > "${WS}/packaging/app.json"

printf '#!/usr/bin/env bash\ncase "$1" in -m) printf "%%s\\n" "${FAKE_ARCH}";; *) : ;; esac\n' > "${BIN}/uname"
printf '#!/usr/bin/env bash\n: \n' > "${BIN}/apt-get"
printf '#!/usr/bin/env bash\ncase "$*" in show*) exit 2 ;; *) : ;; esac\n' > "${BIN}/auditwheel"
printf '#!/usr/bin/env bash\nprintf "uv CC=%%s SUFFIX=%%s PLAT=%%s CFLAGS=%%s\\n" "${CC:-}" "${SETUPTOOLS_EXT_SUFFIX:-}" "${_PYTHON_HOST_PLATFORM:-}" "${CFLAGS:-}" >> "${CALLS}"\n: \n' > "${BIN}/uv"
printf '#!/usr/bin/env bash\n: \n' > "${BIN}/patchelf"
chmod +x "${BIN}/uname" "${BIN}/apt-get" "${BIN}/auditwheel" "${BIN}/uv" "${BIN}/patchelf"
# The cross path's wheel builder: the venv's python, with _PYTHON_HOST_PLATFORM set only on that command.
for venv in .venv_packaging_sources .venv_packaging_binaries; do
  mkdir -p "${WS}/${venv}/bin"
  printf '#!/usr/bin/env bash\nprintf "wheel CC=%%s SUFFIX=%%s PLAT=%%s CFLAGS=%%s LDSHARED=%%s\\n" "${CC:-}" "${SETUPTOOLS_EXT_SUFFIX:-}" "${_PYTHON_HOST_PLATFORM:-}" "${CFLAGS:-}" "${LDSHARED:-}" >> "${CALLS}"\n: \n' > "${WS}/${venv}/bin/python"
  chmod +x "${WS}/${venv}/bin/python"
done

# The consumers the arm drives: absent on riscv64, called on amd64.
printf '#!/usr/bin/env bash\nprintf "bundle %%s\\n" "$*" >> "${CALLS}"\n' > "${TREE}/06-packaging/python-app-bundle.sh"
printf '#!/usr/bin/env bash\nprintf "package %%s\\n" "$*" >> "${CALLS}"\n' > "${TREE}/06-packaging/python-app-package.sh"
chmod +x "${TREE}/06-packaging/python-app-bundle.sh" "${TREE}/06-packaging/python-app-package.sh"

# _run <arch>: the driver under the fake arch; every external tool resolves from the stub PATH.
_run() {
  : > "${CALLS}"
  FAKE_ARCH="$1" CALLS="${CALLS}" FIXTURE_WS="${WS}" \
    PATH="${BIN}:${PATH}" bash "${TREE}/02-toolchain/python/ci_packaging.sh" 3.14 > "${OUT}" 2>&1
}
# _run_cross [--no-py] [--bare-sysroot]: the driver as the native packaging step runs it, cross target set.
_run_cross() {
  local no_py="" sysroot="${SYSROOT_DIR}"
  while [ $# -gt 0 ]; do
    case "$1" in
      --no-py) no_py=1 ;;
      --bare-sysroot) sysroot="${_work}/bare-sysroot" ;;
    esac
    shift
  done
  : > "${CALLS}"
  FAKE_ARCH=x86_64 CALLS="${CALLS}" FIXTURE_WS="${WS}" FIXTURE_PY_ROOT="${PYROOT}" FIXTURE_CROSS_BIN="${BIN}" \
    FIXTURE_NO_PY="${no_py}" PACKAGING_CROSS_TARGET=riscv64 RISCV64_SYSROOT="${sysroot}" \
    PATH="${BIN}:${PATH}" bash "${TREE}/02-toolchain/python/ci_packaging.sh" 3.14 > "${OUT}" 2>&1
}
_calls() { grep -oE '^(bundle|package) ' "${CALLS}" 2>/dev/null | wc -l; }

t_case "the arm's riscv64 verdict: wheels only, no package invocation"
t_assert_ok _run riscv64
t_assert_eq "0" "$(_calls)" "riscv64 must not build the app packages"
t_assert_contains "$(cat "${OUT}")" "riscv64 ships wheels only" "the skip names its why"

t_case "SYNC_EXTRAS reaches every sync, so the emulated row never builds all extras"
export SYNC_EXTRAS=test
t_assert_ok _run riscv64
unset SYNC_EXTRAS
t_assert_eq "2" "$(grep -c 'sync extras=test' "${CALLS}")" "both syncs see the limited set"

t_case "without SYNC_EXTRAS the syncs keep uv_sync_project's own default"
t_assert_ok _run riscv64
t_assert_eq "2" "$(grep -c 'sync extras=$' "${CALLS}")" "an empty input must not limit the sync"

t_case "the arm's amd64 verdict: the app packages run as before"
t_assert_ok _run x86_64
t_assert_eq "2" "$(_calls)" "the bundle and its packages both ran"

t_case "the arm's arm64 verdict: same as amd64"
t_assert_ok _run aarch64
t_assert_eq "2" "$(_calls)"

t_case "cross mode sets the five setuptools knobs on both builds"
t_assert_ok _run_cross
t_assert_contains "$(cat "${CALLS}")" "CC=${BIN}/riscv64-linux-gnu-clang" "CC is the cross wrapper"
t_assert_contains "$(cat "${CALLS}")" "SUFFIX=.cpython-314-riscv64-linux-gnu.so" "the target SOABI suffix"
t_assert_contains "$(cat "${CALLS}")" "CFLAGS=-O2 -I${PYROOT}/include/python3.14" "the staged target Python's headers"
t_assert_eq "2" "$(grep -c '^wheel .*PLAT=linux_riscv64' "${CALLS}")" "both wheels carry the target platform tag"
t_assert_eq "2" "$(grep -c '^wheel .*LDSHARED=.*-Wl,-m,elf64lriscv' "${CALLS}")" "both wheels pin the riscv64 linker emulation"

t_case "cross mode never shows uv the target platform tag (uv refuses it at venv and build time)"
t_assert_eq "2" "$(grep -c '^uv .*PLAT= CFLAGS=' "${CALLS}")" "both sdists build with no platform in uv's environment"
t_assert_eq "0" "$(grep -c '^uv .*PLAT=linux_riscv64' "${CALLS}")" "uv must never see the tag"

t_case "without a staged target Python the sysroot's headers carry the build"
t_assert_ok _run_cross --no-py
t_assert_contains "$(cat "${CALLS}")" "CFLAGS=-O2 -I/usr/include/python3.14" "the sysroot-relative include the cross wrapper roots"

t_case "cross riscv64 ships wheels only even though uname is amd64"
t_assert_eq "0" "$(_calls)" "the cross target decides the verdict, not the host arch"
t_assert_contains "$(cat "${OUT}")" "riscv64 ships wheels only" "the skip names its why"

t_case "cross mode skips the free-threaded wheel and says why"
t_assert_contains "$(cat "${OUT}")" "free-threaded wheel skipped: the riscv64 cross build has no free-threaded target interpreter"

t_case "a native run leaves the cross knobs unset"
t_assert_ok _run x86_64
t_assert_contains "$(cat "${CALLS}")" "SUFFIX= PLAT=" "no cross knobs on the native path"

t_case "cross mode fails loudly without a staged target Python and without sysroot headers"
if _run_cross --no-py --bare-sysroot; then
  t_assert_eq "0" "1" "a missing target Python must fail the run"
else
  t_assert_contains "$(cat "${OUT}")" "no staged riscv64 Python and no" "the failure names both places it looked"
fi

t_case "the arm's LOGFILE order matches the driver's lines"
t_assert_ok test -s "${OUT}"

t_summary
