#!/usr/bin/env bash
# ci_packaging.sh's free-threaded twin, the helper that decides and proves it, and the bundle's ABI pick; see docs/python-ci.md#two-wheels-gil-and-free-threaded
set -u
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${TESTS_DIR}/test-harness.sh"
SCRIPTS="$(cd "${TESTS_DIR}/.." && pwd)"
HELPER="${SCRIPTS}/02-toolchain/python/free-threaded-wheel.py"

t_skip_unless "a POSIX python3 (the helper reads the fixture's paths)" t_posix_python

_work="$(mktemp -d)"; trap 'rm -rf "${_work}"' EXIT
WS="${_work}/ws"; TREE="${_work}/tree"; CALLS="${_work}/calls"; OUT="${_work}/out"; BIN="${_work}/bin"
mkdir -p "${TREE}/01-core" "${TREE}/02-toolchain/python" "${WS}" "${BIN}"
cp "${SCRIPTS}/01-core/python_uv.sh" "${SCRIPTS}/01-core/logging.sh" "${TREE}/01-core/"
cp "${SCRIPTS}/02-toolchain/python/ci_packaging.sh" "${HELPER}" "${TREE}/02-toolchain/python/"
# The venv and sync glue is not this suite's subject.
cat > "${TREE}/02-toolchain/python/ci-common.sh" <<'CI_COMMON'
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../../01-core" && pwd)/python_uv.sh"
detect_workspace() { export WORKSPACE_ROOT="${FIXTURE_WS}"; }
prepare_ci_workspace() { cd "${FIXTURE_WS}" || :; }
uv_venv_ensure() { :; }
uv_sync_project() { :; }
CI_COMMON

# A uv that logs each call, finds the fake 3.14t, leaves the wheel each build would, and seeds venvs with a proof stub.
cat > "${BIN}/uv" <<'UV'
#!/usr/bin/env bash
printf 'uv %s\n' "$*" >> "${CALLS}"
if [ "$1 $2" = "python find" ]; then
  [ -z "${FAKE_NO_FT:-}" ] || exit 2
  printf '%s\n' "${FAKE_BIN}/python3.14t"
  exit 0
fi
case "$1" in
  build)
    out=dist
    while [ $# -gt 0 ]; do [ "$1" != --out-dir ] || out="$2"; shift; done
    mkdir -p "${out}"
    if [ "${out}" != dist ]; then
      : > "${out}/${FAKE_FT_WHEEL:-fixture_app-1.0-cp314-cp314t-linux_x86_64.whl}"
    elif [ "${CYTHONIZE:-}" = True ]; then
      : > dist/fixture_app-1.0-cp314-cp314-linux_x86_64.whl
    else
      : > dist/fixture_app-1.0-py3-none-any.whl
    fi
    ;;
  venv)
    dir="${!#}"
    mkdir -p "${dir}/bin"
    printf '#!/usr/bin/env bash\nprintf "proof %%s\\n" "$*" >> "${CALLS}"\nprintf "%%s\\n" "${FAKE_VERDICT:-2 compiled module(s) loaded}"\nexit "${FAKE_PROVE_RC:-0}"\n' > "${dir}/bin/python"
    chmod +x "${dir}/bin/python"
    ;;
esac
exit 0
UV
# auditwheel's repair as a rename to the manylinux tag.
cat > "${_work}/auditwheel" <<'AUDITWHEEL'
#!/usr/bin/env bash
printf 'auditwheel %s\n' "$*" >> "${CALLS}"
[ "$1" = repair ] || exit 0
name="$(basename "$2")"
cp "$2" "$4/${name%-linux_*}-manylinux_2_17_x86_64.whl"
AUDITWHEEL
printf '#!/usr/bin/env bash\n:\n' > "${BIN}/patchelf"
chmod +x "${BIN}/uv" "${BIN}/patchelf" "${_work}/auditwheel"

DECLARED='"Programming Language :: Python :: Free Threading :: 2 - Beta"'
UNOFFICIAL='"Programming Language :: Python :: 3.14t"'
# _pyproject <classifier>...: the fixture project's pyproject.toml.
_pyproject() {
  local joined
  joined="$(printf '%s, ' "$@")"
  printf '[project]\nname = "fixture_app"\nclassifiers = [%s]\n' "${joined%, }" > "${WS}/pyproject.toml"
}
# _run [VAR=value...]: the driver on a bare PATH, so a host auditwheel cannot stand in for the fixture's.
_run() {
  : > "${CALLS}"
  rm -rf "${WS}/dist" "${WS}/build" "${WS}/.venv_packaging_binaries"
  env CALLS="${CALLS}" FIXTURE_WS="${WS}" FAKE_BIN="${BIN}" PATH="${BIN}:/usr/bin:/bin" "$@" \
    bash "${TREE}/02-toolchain/python/ci_packaging.sh" 3.14 > "${OUT}" 2>&1
}
_dist() { (cd "${WS}/dist" 2>/dev/null && LC_ALL=C ls -1 -- *.whl 2>/dev/null) | tr '\n' ' '; }

t_case "a declared project ships both binary wheels, and the free-threaded one is proved"
_pyproject "${DECLARED}"
mkdir -p "${_work}/awbin"; cp "${_work}/auditwheel" "${_work}/awbin/"
t_assert_ok _run PATH="${BIN}:${_work}/awbin:/usr/bin:/bin"
t_assert_contains "$(cat "${OUT}")" "free-threaded wheel: the project declares 'Programming Language :: Python :: Free Threading :: 2 - Beta'"
t_assert_contains "$(cat "${CALLS}")" "uv build --python ${BIN}/python3.14t --out-dir ${WS}/build/free-threaded-dist" "the twin builds on the found 3.14t"
t_assert_eq "fixture_app-1.0-cp314-cp314-manylinux_2_17_x86_64.whl fixture_app-1.0-cp314-cp314t-manylinux_2_17_x86_64.whl fixture_app-1.0-py3-none-any.whl " "$(_dist)" "pure, GIL and free-threaded, both binaries repaired"
t_assert_contains "$(cat "${CALLS}")" "uv venv --python ${BIN}/python3.14t --clear ${WS}/.venv_packaging_free_threaded" "a fresh venv of the same interpreter"
t_assert_contains "$(cat "${CALLS}")" "uv pip install --python ${WS}/.venv_packaging_free_threaded/bin/python --no-deps dist/fixture_app-1.0-cp314-cp314t-manylinux_2_17_x86_64.whl" "the proof installs the shipped, repaired wheel"
t_assert_contains "$(cat "${CALLS}")" "proof -I ${TREE}/02-toolchain/python/free-threaded-wheel.py prove fixture_app" "the helper proves it in that venv"
t_assert_contains "$(cat "${OUT}")" "free-threaded proof: 2 compiled module(s) loaded"
t_assert_ok test ! -e "${WS}/.venv_packaging_free_threaded"

t_case "both GIL builds ask uv for +gil, since uv build never looks at the venv"
t_assert_eq "2" "$(grep -c '^uv build --python 3.14+gil$' "${CALLS}")"

t_case "the packaging venv's auditwheel repairs when PATH has none"
t_assert_ok _run
t_assert_eq "fixture_app-1.0-cp314-cp314-linux_x86_64.whl fixture_app-1.0-cp314-cp314t-linux_x86_64.whl fixture_app-1.0-py3-none-any.whl " "$(_dist)" "no auditwheel anywhere: shipped unrepaired"
t_assert_contains "$(cat "${OUT}")" "no auditwheel on PATH or in ${WS}/.venv_packaging_binaries -> shipping it unrepaired" "the unrepaired wheel is named, not called pure"
_run_with_venv_auditwheel() {
  : > "${CALLS}"
  rm -rf "${WS}/dist" "${WS}/build"
  mkdir -p "${WS}/.venv_packaging_binaries/bin"
  cp "${_work}/auditwheel" "${WS}/.venv_packaging_binaries/bin/"
  env CALLS="${CALLS}" FIXTURE_WS="${WS}" FAKE_BIN="${BIN}" PATH="${BIN}:/usr/bin:/bin" \
    bash "${TREE}/02-toolchain/python/ci_packaging.sh" 3.14 > "${OUT}" 2>&1
}
t_assert_ok _run_with_venv_auditwheel
t_assert_contains "$(cat "${CALLS}")" "auditwheel repair dist/fixture_app-1.0-cp314-cp314t-linux_x86_64.whl -w repaired/"
t_assert_contains "$(_dist)" "fixture_app-1.0-cp314-cp314-manylinux_2_17_x86_64.whl" "the GIL wheel is repaired too"

t_case "an undeclared project builds exactly what it built before, and says why in one line"
_pyproject '"Programming Language :: Python :: 3.14"' "${UNOFFICIAL}"
t_assert_ok _run
t_assert_contains "$(cat "${OUT}")" "free-threaded wheel skipped: the project does not declare support (no 'Programming Language :: Python :: Free Threading' classifier in pyproject.toml)"
t_assert_eq "0" "$(grep -c -e 'out-dir' -e 'python find' -e '^proof' "${CALLS}")" "no twin build, no interpreter lookup, no proof"
t_assert_eq "fixture_app-1.0-cp314-cp314-linux_x86_64.whl fixture_app-1.0-py3-none-any.whl " "$(_dist)"

t_case "PYTHON_FREE_THREADED_WHEEL=on builds an undeclared project's twin; off skips a declared one"
PYTHON_FREE_THREADED_WHEEL=on t_assert_ok _run
t_assert_contains "$(cat "${OUT}")" "free-threaded wheel: PYTHON_FREE_THREADED_WHEEL=on, although no 'Programming Language"
t_assert_contains "$(_dist)" "cp314t"
_pyproject "${DECLARED}"
PYTHON_FREE_THREADED_WHEEL=off t_assert_ok _run
t_assert_contains "$(cat "${OUT}")" "free-threaded wheel skipped: PYTHON_FREE_THREADED_WHEEL=off"
t_assert_eq "0" "$(grep -c 'out-dir' "${CALLS}")"

t_case "an unknown PYTHON_FREE_THREADED_WHEEL fails rather than guessing"
PYTHON_FREE_THREADED_WHEEL=yes t_assert_fails _run
t_assert_contains "$(cat "${OUT}")" "PYTHON_FREE_THREADED_WHEEL must be auto, on or off, not 'yes'"

t_case "a declared project without a free-threaded interpreter fails, and never downloads one"
FAKE_NO_FT=1 t_assert_fails _run
t_assert_contains "$(cat "${OUT}")" "no 3.14t interpreter for the free-threaded wheel"
t_assert_eq "0" "$(grep -c 'python install' "${CALLS}")" "no uv python install"

t_case "a twin build that is not cp314t fails; a pure one is reported and needs no proof"
FAKE_FT_WHEEL=fixture_app-1.0-cp314-cp314-linux_x86_64.whl t_assert_fails _run
t_assert_contains "$(cat "${OUT}")" "the free-threaded build produced fixture_app-1.0-cp314-cp314-linux_x86_64.whl, not a cp314t wheel"
FAKE_FT_WHEEL=fixture_app-1.0-py3-none-any.whl t_assert_ok _run
t_assert_contains "$(cat "${OUT}")" "the build is pure (fixture_app-1.0-py3-none-any.whl)"
t_assert_eq "0" "$(grep -c '^proof' "${CALLS}")"

t_case "a failed proof fails the run and carries the helper's verdict"
FAKE_PROVE_RC=1 FAKE_VERDICT="ERROR: the GIL was re-enabled by fixture_app.core" t_assert_fails _run
t_assert_contains "$(cat "${OUT}")" "free-threaded proof failed for fixture_app-1.0-cp314-cp314t-linux_x86_64.whl: ERROR: the GIL was re-enabled by fixture_app.core"

t_case "a pyproject the helper cannot read fails instead of reading as undeclared"
printf '[project\n' > "${WS}/pyproject.toml"
t_assert_fails _run
t_assert_contains "$(cat "${OUT}")" "cannot tell whether the project declares free-threading support"

t_case "declares: the official classifier family, with or without a level"
_declares() { printf '%s\n' "$1" > "${_work}/p.toml"; python3 -I "${HELPER}" declares "${_work}/p.toml"; }
t_assert_eq "Programming Language :: Python :: Free Threading :: 3 - Stable" \
  "$(_declares '[project]
classifiers = ["Programming Language :: Python :: Free Threading :: 3 - Stable"]')"
t_assert_ok _declares '[project]
classifiers = ["Programming Language :: Python :: Free Threading"]'

t_case "declares: the unofficial 3.14t, a commented line, a lookalike and dynamic classifiers do not count"
t_assert_eq "1" "$(t_rc _declares "[project]
classifiers = [${UNOFFICIAL}]")"
t_assert_eq "1" "$(t_rc _declares '[project]
classifiers = [
  # "Programming Language :: Python :: Free Threading :: 2 - Beta",
]')"
t_assert_eq "1" "$(t_rc _declares '[project]
classifiers = ["Programming Language :: Python :: Free Threadingly"]')"
t_assert_contains "$(_declares '[project]
dynamic = ["classifiers"]')" "leaves its classifiers dynamic"
t_assert_eq "1" "$(t_rc python3 -I "${HELPER}" declares "${_work}/absent.toml")"
t_assert_eq "2" "$(t_rc _declares '[project')" "unreadable TOML is not a verdict"

t_case "prove: a GIL interpreter cannot prove anything"
t_assert_eq "2" "$(t_rc python3 -I "${HELPER}" prove pip)"
t_assert_contains "$(python3 -I "${HELPER}" prove pip 2>&1)" "is not a free-threaded interpreter"

FT_PY="${FT_PYTHON:-/opt/python-freethreaded/bin/python3.14t}"
# _ft_ext <venv> <name> <slot>: a C extension built against the venv's 3.14t headers, installed as distribution <name>.
_ft_ext() {
  local venv="$1" name="$2" slot="$3" paths dist
  mapfile -t paths < <("${venv}/bin/python" -I -c 'import sysconfig as s; print(s.get_paths()["purelib"]); print(s.get_paths()["include"]); print(s.get_config_var("EXT_SUFFIX"))')
  printf '#include <Python.h>\nstatic PyModuleDef_Slot slots[] = {%s{0, NULL}};\nstatic struct PyModuleDef def = {PyModuleDef_HEAD_INIT, "%s", NULL, 0, NULL, slots};\nPyMODINIT_FUNC PyInit_%s(void) { return PyModuleDef_Init(&def); }\n' \
    "${slot}" "${name}" "${name}" > "${_work}/${name}.c"
  cc -shared -fPIC -I"${paths[1]}" -o "${paths[0]}/${name}${paths[2]}" "${_work}/${name}.c" || return 1
  dist="${paths[0]}/${name}-1.0.dist-info"
  mkdir -p "${dist}"
  printf 'Metadata-Version: 2.1\nName: %s\nVersion: 1.0\n' "${name}" > "${dist}/METADATA"
  printf '%s,,\n%s-1.0.dist-info/METADATA,,\n%s-1.0.dist-info/RECORD,,\n' "${name}${paths[2]}" "${name}" "${name}" > "${dist}/RECORD"
}
_ft_prove() { env -u PYTHON_GIL "${_work}/ftvenv/bin/python" -I "${HELPER}" prove "$1" 2>&1; }

t_case "prove, for real: a C extension declaring Py_MOD_GIL_NOT_USED keeps the GIL off; one without the slot re-enables it"
if "${FT_PY}" -c 'import sysconfig, sys; sys.exit(not sysconfig.get_config_var("Py_GIL_DISABLED"))' 2>/dev/null; then
  t_assert_ok "${FT_PY}" -m venv --without-pip "${_work}/ftvenv"
  t_assert_ok _ft_ext "${_work}/ftvenv" ftfix_free "{Py_mod_gil, Py_MOD_GIL_NOT_USED}, "
  t_assert_ok _ft_ext "${_work}/ftvenv" ftfix_gil ""
  t_assert_eq "0" "$(t_rc _ft_prove ftfix_free)" "the declaring extension proves"
  t_assert_contains "$(_ft_prove ftfix_free)" "1 compiled module(s) of ftfix_free loaded on free-threaded 3.14"
  t_assert_contains "$(_ft_prove ftfix_free)" "the GIL stayed disabled"
  t_assert_eq "1" "$(t_rc _ft_prove ftfix_gil)" "the undeclared extension fails the proof"
  t_assert_contains "$(_ft_prove ftfix_gil)" "ERROR: the GIL was re-enabled, first by ftfix_gil; Cython needs freethreading_compatible=True"
else
  # CI's host has no 3.14t; the image's /opt/python-freethreaded does (FT_PYTHON names another).
  printf '  SKIP [%s] no free-threaded interpreter at %s\n' "${_T_CASE}" "${FT_PY}"
fi

# _ftw [args]: the Python on stdin, with the helper imported as ftw and the args from sys.argv[2].
_ftw() {
  python3 -I -c "import importlib.util, sys
spec = importlib.util.spec_from_file_location('ftw', sys.argv[1])
ftw = importlib.util.module_from_spec(spec)
spec.loader.exec_module(ftw)
exec(sys.stdin.read())" "${HELPER}" "$@"
}

# _modules <site root> <file>...: the helper's module list for a fake distribution whose files sit under that root.
_modules() {
  _ftw "$@" <<'PY'
class Rec(str):
    def locate(self):
        return sys.argv[2] + "/" + self
class Dist:
    files = [Rec(f) for f in sys.argv[3:]]
ftw.importlib.metadata.distribution = lambda name: Dist()
ftw.importlib.machinery.EXTENSION_SUFFIXES = [".cpython-314t-x86_64-linux-gnu.so", ".abi3.so", ".so"]
print(" ".join(name for name, _ in ftw.extension_modules("app")))
PY
}

t_case "prove: every compiled module the distribution owns, a compiled __init__ under its package's name"
t_assert_eq "app app.core app.sub" "$(_modules /site app/__init__.cpython-314t-x86_64-linux-gnu.so app/core.cpython-314t-x86_64-linux-gnu.so \
  app/sub/__init__.abi3.so app/core.py ../../bin/app.so)" "a script outside site-packages and the .py sources are not modules to load"

t_case "prove: a bare .so is a module only when it exports PyInit_<name>, so a bundled library is never loaded as one"
mkdir -p "${_work}/site/ort/capi"
printf 'x\0PyInit_onnxruntime_pybind11_state\0y' > "${_work}/site/ort/capi/onnxruntime_pybind11_state.so"
printf 'x\0OrtGetApiBase\0PyInit_libonnxruntime_providers_shared_x\0' > "${_work}/site/ort/capi/libonnxruntime_providers_shared.so"
printf 'x\0PyInit_capi\0' > "${_work}/site/ort/capi/__init__.so"
t_assert_eq "ort.capi ort.capi.onnxruntime_pybind11_state" \
  "$(_modules "${_work}/site" ort/capi/onnxruntime_pybind11_state.so ort/capi/libonnxruntime_providers_shared.so ort/capi/__init__.so)" \
  "a symbol that merely begins with the library's name does not count either"

t_case "prove: FT_PROVE_TRACE names each module while it loads and is empty once every load returned"
t_assert_eq "seen app.a seen app.b left ''" "$(FT_PROVE_TRACE="${_work}/trace" _ftw <<'PY'
import os
trace = os.environ["FT_PROVE_TRACE"]
seen = []
ftw.importlib.util.spec_from_file_location = lambda name, path: name
def load(name):
    seen.append("seen " + open(trace).read())
ftw.importlib.util.module_from_spec = load
ftw.load_all([("app.a", "/a.so"), ("app.b", "/b.so")])
print(" ".join(seen), "left %r" % open(trace).read())
PY
)" "a module that kills the process leaves its name behind for the cross proof's verdict"

t_case "prove: a module whose init imports its own package gets the real package, or else one registered unrun (torch._C, CON79 1b)"
# pkg cannot run here (torch without typing_extensions); okpkg can (numpy, whose test modules need numpy.add).
mkdir -p "${_work}/encl/pkg/sub" "${_work}/encl/okpkg"
printf 'print("noise")\nimport missing_dependency_of_pkg\n' > "${_work}/encl/pkg/__init__.py"
: > "${_work}/encl/pkg/sub/__init__.py"
printf 'import pkg, sys\nINIT = sorted(n for n in sys.modules if n.startswith("pkg"))\n' > "${_work}/encl/pkg/sub/mod.py"
printf 'VALUE = 7\n' > "${_work}/encl/okpkg/__init__.py"
printf 'import okpkg\nINIT = okpkg.VALUE\n' > "${_work}/encl/okpkg/mod.py"
t_assert_eq "[] ['pkg', 'pkg.sub'] 7 ['pkg', 'pkg.sub']" "$(_ftw "${_work}/encl" <<'PY'
sys.path.insert(0, sys.argv[2])
seen = []
real = ftw.importlib.util.module_from_spec
def create(spec):
    module = real(spec)
    if spec.name in ("pkg.sub.mod", "okpkg.mod"):  # the init a single-phase extension runs inside create_module
        spec.loader.exec_module(module)
        seen.append(module.INIT)
    return module
ftw.importlib.util.module_from_spec = create
offenders, failures = ftw.load_all([("pkg.sub.mod", sys.argv[2] + "/pkg/sub/mod.py"), ("okpkg.mod", sys.argv[2] + "/okpkg/mod.py")])
print(failures, *seen, sorted(n for n in sys.modules if n.startswith("pkg") and n != "pkg.sub.mod"))
PY
)" "and the failed import's output never reaches the verdict"

t_case "the bundle takes the wheel built for its runtime's ABI, never the free-threaded twin"
eval "$(t_fn_src "${SCRIPTS}/06-packaging/python-app-bundle.sh" select_app_wheel)" || exit 1
_pick() {
  local d="${_work}/pick" n out rc=0
  rm -rf "${d}"; mkdir -p "${d}"
  for n in "${@:2}"; do : > "${d}/${n}"; done
  out="$(select_app_wheel "${d}" fixture_app x86_64 "$1")" || rc=$?
  printf '%s\n' "${out#"${d}"/}"
  return "${rc}"
}
t_assert_eq "fixture_app-1.0-cp314-cp314-linux_x86_64.whl" \
  "$(_pick cp314 fixture_app-1.0-cp314-cp314t-manylinux_2_17_x86_64.whl fixture_app-1.0-cp314-cp314-linux_x86_64.whl fixture_app-1.0-py3-none-any.whl)" \
  "a repaired cp314t must not win over the runtime's unrepaired cp314"
t_assert_eq "fixture_app-1.0-cp314-cp314t-manylinux_2_17_x86_64.whl" \
  "$(_pick cp314t fixture_app-1.0-cp314-cp314-manylinux_2_17_x86_64.whl fixture_app-1.0-cp314-cp314t-manylinux_2_17_x86_64.whl)"
t_assert_eq "fixture_app-1.0-cp312-abi3-manylinux_2_17_x86_64.whl" "$(_pick cp314 fixture_app-1.0-cp312-abi3-manylinux_2_17_x86_64.whl)"
t_assert_eq "fixture_app-1.0-py3-none-any.whl" "$(_pick cp314 other-1.0-cp314-cp314-linux_x86_64.whl fixture_app-1.0-py3-none-any.whl)" "no binary of this app: its pure wheel"

t_case "the bundle refuses binaries built for another ABI instead of falling back to the pure wheel"
t_assert_eq "1" "$(t_rc _pick cp314 fixture_app-1.0-cp314-cp314t-linux_x86_64.whl fixture_app-1.0-py3-none-any.whl)"
t_assert_contains "$(_pick cp314 fixture_app-1.0-cp314-cp314t-linux_x86_64.whl)" "no cp314 wheel in ${_work}/pick, only fixture_app-1.0-cp314-cp314t-linux_x86_64.whl"

t_summary
