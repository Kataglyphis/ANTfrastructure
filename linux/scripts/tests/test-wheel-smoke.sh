#!/usr/bin/env bash
# The riscv64 lane's wheel smoke: which dist/ wheel it takes, and what wheel-smoke.py calls a pass; see docs/python-ci.md#riscv64-the-image-itself-runs-under-qemu
set -u
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${TESTS_DIR}/test-harness.sh"
SCRIPTS="$(cd "${TESTS_DIR}/.." && pwd)"
PY_DIR="${SCRIPTS}/02-toolchain/python"
SMOKE_PY="${PY_DIR}/wheel-smoke.py"
SMOKE_SH="${PY_DIR}/ci-wheel-smoke.sh"
WORKFLOW="${SCRIPTS}/../../.github/workflows/python-ci-linux.yml"

t_skip_unless "a POSIX python3 with venv" python3 -c 'import venv, os, sys; sys.exit(os.sep != "/")'

_work="$(mktemp -d)"; trap 'rm -rf "${_work}"' EXIT
python3 -m venv --without-pip "${_work}/venv"
_site="$("${_work}/venv/bin/python" -c 'import sysconfig; print(sysconfig.get_paths()["purelib"])')"
_suffix="$("${_work}/venv/bin/python" -c 'import sysconfig; print(sysconfig.get_config_var("EXT_SUFFIX"))')"
_ext="$(python3 -c 'import sysconfig, glob; print((glob.glob(sysconfig.get_paths()["stdlib"] + "/lib-dynload/xxsubtype.*.so") + [""])[0])')"

# <dist> <package> [compiled]: installs a distribution by hand, its RECORD naming every file.
_install() {
  local dist="$1" pkg="$2" info
  mkdir -p "${_site}/${pkg}"
  : > "${_site}/${pkg}/__init__.py"
  info="${_site}/${dist}-1.0.dist-info"
  mkdir -p "${info}"
  printf 'Metadata-Version: 2.1\nName: %s\nVersion: 1.0\n' "${dist}" > "${info}/METADATA"
  printf '%s/__init__.py,,\n%s/METADATA,,\n%s/RECORD,,\n' "${pkg}" "${info##*/}" "${info##*/}" > "${info}/RECORD"
  if [ "${3:-}" = compiled ]; then
    cp "${_ext}" "${_site}/${pkg}/xxsubtype${_suffix}"
    printf '%s/xxsubtype%s,,\n' "${pkg}" "${_suffix}" >> "${info}/RECORD"
  fi
}
_smoke() { (cd "${_work}" && "${_work}/venv/bin/python" -I "${SMOKE_PY}" "$@"); }

t_case "a wheel whose package imports from the venv and whose compiled module loads passes"
t_assert_ok test -n "${_ext}"
_install gooddist goodpkg compiled
_out="$(t_out _smoke gooddist goodpkg --require-compiled)"
t_assert_eq 0 "$(t_rc _smoke gooddist goodpkg --require-compiled)" "${_out}"
t_assert_contains "${_out}" "import goodpkg and 1 compiled module(s) of gooddist load on $(uname -m)"

t_case "a compiled module that does not load fails the smoke, and says which"
_install brokendist brokenpkg
printf 'not an ELF, but it names PyInit_broken\0' > "${_site}/brokenpkg/broken${_suffix}"
printf 'brokenpkg/broken%s,,\n' "${_suffix}" >> "${_site}/brokendist-1.0.dist-info/RECORD"
t_assert_eq 1 "$(t_rc _smoke brokendist brokenpkg --require-compiled)"
t_assert_contains "$(t_out _smoke brokendist brokenpkg)" "ERROR: brokenpkg.broken:"

t_case "a package whose import raises fails the smoke"
_install raisedist raisepkg compiled
printf 'raise ImportError("no matplotlib here")\n' > "${_site}/raisepkg/__init__.py"
t_assert_eq 1 "$(t_rc _smoke raisedist raisepkg)"
t_assert_contains "$(t_out _smoke raisedist raisepkg)" "import raisepkg: ImportError: no matplotlib here"

t_case "a package that resolves outside the venv fails: the smoke must grade the wheel, not a source tree"
_install shadowdist shadowpkg compiled
mkdir -p "${_work}/tree/outsidepkg"; : > "${_work}/tree/outsidepkg/__init__.py"
printf '%s\n' "${_work}/tree" > "${_site}/zz-tree.pth"
t_assert_eq 1 "$(t_rc _smoke shadowdist outsidepkg)"
t_assert_contains "$(t_out _smoke shadowdist outsidepkg)" "import outsidepkg: came from ${_work}/tree/outsidepkg/__init__.py"
rm -f "${_site}/zz-tree.pth"

t_case "no compiled module under --require-compiled, or no such distribution, cannot tell (2)"
_install puredist purepkg
t_assert_eq 2 "$(t_rc _smoke puredist purepkg --require-compiled)"
t_assert_eq 0 "$(t_rc _smoke puredist purepkg)"
t_assert_eq 2 "$(t_rc _smoke nosuchdist goodpkg)"

t_case "ci-wheel-smoke.sh takes exactly one wheel of this arch and ABI from dist/"
mkdir -p "${_work}/ws/dist"; : > "${_work}/ws/pyproject.toml"
_arch="$(uname -m)"
_pick() { WORKSPACE_ROOT="${_work}/ws" bash "${SMOKE_SH}" pkg 3.14 2>&1; }
: > "${_work}/ws/dist/pkg-1.0-cp314-cp314-linux_notmyarch.whl"
: > "${_work}/ws/dist/pkg-1.0-cp313-cp313-linux_${_arch}.whl"
: > "${_work}/ws/dist/pkg-1.0-py3-none-any.whl"
t_assert_contains "$(_pick)" "expected one cp314 ${_arch} wheel in dist/, found 0"
: > "${_work}/ws/dist/pkg-1.0-cp314-cp314-linux_${_arch}.whl"
: > "${_work}/ws/dist/pkg-1.0-cp314-cp314-manylinux_2_39_${_arch}.whl"
t_assert_contains "$(_pick)" "expected one cp314 ${_arch} wheel in dist/, found 2"

t_case "the lane runs the smoke on the riscv64 row it packages, from the hub pin, and fails loudly without it"
_wf="$(cat "${WORKFLOW}")"
t_assert_contains "${_wf}" "bash third_party/ANTfrastructure/linux/scripts/02-toolchain/python/ci-wheel-smoke.sh"
t_assert_contains "${_wf}" "package-emulated needs an ANTfrastructure pin that ships it (CON83)"
t_assert_eq 2 "$(grep -c "if: matrix.arch == 'riscv64' && inputs.package-emulated" "${WORKFLOW}")" "the pin check and the smoke, on the packaged riscv64 row only"

t_summary
