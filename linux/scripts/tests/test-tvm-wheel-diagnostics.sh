#!/usr/bin/env bash
# Tests for the TVM wheel DIAGNOSTICS in 05-frameworks/tvm-python.sh — the
# machinery added to end backlog ORPHAN-PINS, where a wheel-less TVM stage
# rendered as "TVM build OK" + "DONE" while `import tvm` was missing from all
# three shipped arches.
#
# Every one of those diagnostics is downstream of ONE shell option. The wheel
# build is `python -m build ... 2>&1 | tee LOG`, and without `set -o pipefail`
# (tvm.sh:2) a pipeline reports TEE's status — always 0. `if !
# _tvm_run_wheel_build` would then never fire, TVM_WHEEL_SKIP_REASON would never
# be set, and the whole diagnostic layer would be dead code that still reads as
# covered. That mutation — or an `|| true` on the tee'd build — used to leave
# the suite fully green, which is exactly the class this repo keeps getting
# burned by. Hence the behavioural assertions below rather than a grep.
#
# Pure unit tests: no container, no network, no real python; the builder is a
# fake script whose exit status the tests choose.
set -u
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${TESTS_DIR}/test-harness.sh"
# shellcheck source=../05-frameworks/tvm-python.sh
source "${TESTS_DIR}/../05-frameworks/tvm-python.sh"

_tmp="$(mktemp -d)"
trap 'rm -rf "${_tmp}"' EXIT

# Collaborators tvm.sh normally supplies. `die` must ABORT like the real one
# (logging.sh's die -> err -> exit), with a status the tests can recognise.
log()  { printf 'LOG:%s\n'  "$*"; }
warn() { printf 'WARN:%s\n' "$*" >&2; }
die()  { printf 'DIE:%s\n'  "$*" >&2; exit 97; }

# ── _tvm_wheel_missing_build_requires ────────────────────────────────────────
# pypa/build prints `Missing dependencies:` followed by one '\n\t'-indented
# requirement per entry, as its LAST output. The predecessor used a sed range
# `/Missing dependencies/,/^[[:space:]]*$/p`, and a sed range whose closing
# address never matches runs to EOF — so anything printed after the list (a
# traceback, ninja noise) was flattened into the "missing deps" string.
_log_with_trailer="${_tmp}/build-trailer.log"
cat > "${_log_with_trailer}" <<'LOG'
* Getting build dependencies for wheel...
ERROR Missing dependencies:
	mlc-z3-static>=4.16.0
	cython>=3
Traceback (most recent call last):
  File "/x/y.py", line 3
SomeError: boom
LOG

t_case "missing build-requires are extracted from the indented list"
_deps="$(_tvm_wheel_missing_build_requires "${_log_with_trailer}")"
t_assert_eq "mlc-z3-static>=4.16.0 cython>=3" "${_deps}"

t_case "the extraction STOPS at the end of the list (the unbounded-range bug)"
case "${_deps}" in
  *Traceback*|*SomeError*|*"File "*) _bleed="leaked" ;;
  *) _bleed="bounded" ;;
esac
t_assert_eq "bounded" "${_bleed}" \
  "unrelated log lines must not be flattened into the missing-deps string"

t_case "a list that runs to EOF with no trailing blank line still works"
printf 'ERROR Missing dependencies:\n\tonly-one>=1\n' > "${_tmp}/eof.log"
t_assert_eq "only-one>=1" "$(_tvm_wheel_missing_build_requires "${_tmp}/eof.log")"

t_case "the same-line 'Missing dependencies: foo' spelling is captured too"
printf 'ERROR Missing dependencies: inline-dep>=2\nunrelated flush-left line\n' > "${_tmp}/inline.log"
t_assert_eq "inline-dep>=2" "$(_tvm_wheel_missing_build_requires "${_tmp}/inline.log")"

t_case "a log without the marker yields the empty string"
printf 'just noise\nmore noise\n' > "${_tmp}/none.log"
t_assert_eq "" "$(_tvm_wheel_missing_build_requires "${_tmp}/none.log")"

t_case "an empty or missing log yields the empty string"
: > "${_tmp}/empty.log"
t_assert_eq "" "$(_tvm_wheel_missing_build_requires "${_tmp}/empty.log")"
t_assert_eq "" "$(_tvm_wheel_missing_build_requires "${_tmp}/does-not-exist.log")"

t_case "the line cap bounds a pathological list"
{ printf 'ERROR Missing dependencies:\n'; for i in $(seq 1 50); do printf '\tdep%s\n' "${i}"; done; } > "${_tmp}/many.log"
_capped="$(_TVM_MISSING_DEPS_MAX_LINES=3 _tvm_wheel_missing_build_requires "${_tmp}/many.log")"
t_assert_eq "dep1 dep2 dep3" "${_capped}"

# ── _tvm_run_wheel_build: the pipefail contract ──────────────────────────────
# Shared state the function reads via bash dynamic scoping (tvm_build_wheel's
# locals in production).
tvm_dir="${_tmp}/src"
TVM_WHEEL_DIR="${_tmp}/wheels"
wheel_cmake_args_string=""
mkdir -p "${tvm_dir}" "${TVM_WHEEL_DIR}"

# Fake builder: prints a realistic missing-deps report, exits with $FAKE_RC.
venv_python="${_tmp}/fake-python"
cat > "${venv_python}" <<'FAKE'
#!/usr/bin/env bash
printf '* Getting build dependencies for wheel...\n'
printf 'ERROR Missing dependencies:\n\tmlc-z3-static>=4.16.0\n'
exit "${FAKE_RC:-0}"
FAKE
chmod +x "${venv_python}"

_bl="${_tmp}/run.log"
_err="${_tmp}/run.err"

t_case "a FAILING wheel build propagates its own status through the tee"
: > "${_bl}"
_rc=0
( export FAKE_RC=42; set -o pipefail; _tvm_run_wheel_build probe "${_bl}" ) >/dev/null 2>"${_err}" || _rc=$?
t_assert_eq "42" "${_rc}" \
  "THE regression assertion: pipefail must carry the builder's rc past tee. If this reads 0, either pipefail was dropped or the tee'd build grew an '|| true' — and every TVM diagnostic downstream is dead code"

t_case "the tee still mirrors the build output into the log"
t_assert_contains "$(cat "${_bl}")" "Missing dependencies" \
  "the log is the input to _tvm_wheel_missing_build_requires"

t_case "a SUCCEEDING wheel build returns 0"
_rc=0
( export FAKE_RC=0; set -o pipefail; _tvm_run_wheel_build probe "${_bl}" ) >/dev/null 2>&1 || _rc=$?
t_assert_eq "0" "${_rc}"

t_case "running WITHOUT pipefail is refused loudly instead of silently lying"
: > "${_err}"
_rc=0
( export FAKE_RC=42; set +o pipefail; _tvm_run_wheel_build probe "${_bl}" ) >/dev/null 2>"${_err}" || _rc=$?
t_assert_eq "97" "${_rc}" "the die stub's status — the guard must abort, not fall through"
t_assert_contains "$(cat "${_err}")" "pipefail" \
  "the refusal must name the option, since the failure it prevents leaves no other trace"

# ── _tvm_wheel_verdict: the consolation line must be TRUE ────────────────────
# "the native runtime still ships (${prefix}/lib/libtvm*.so)" used to be printed
# unconditionally, with no check behind it, on the one path where nothing about
# the step can be trusted. CMake installs libtvm to lib64 on some distro/arch
# combinations — which is why Dockerfile.media:431 folds /opt/tvm/lib64 back
# into /opt/tvm/lib after this script returns — so both layouts count.
TVM_WHEEL_SKIP_REASON="probe reason"

_verdict() {  # <prefix-dir> -> stderr of the verdict
  prefix="$1" _tvm_wheel_verdict 2>&1 >/dev/null
}

t_case "a staged wheel reports success and no 'native runtime' consolation"
prefix="${_tmp}/px-wheel"
mkdir -p "${prefix}/lib" "${TVM_WHEEL_DIR}"
: > "${TVM_WHEEL_DIR}/apache_tvm-0.1-py3-none-any.whl"
_out="$(prefix="${prefix}" _tvm_wheel_verdict 2>&1)"
t_assert_contains "${_out}" "python wheel staged"
case "${_out}" in *"NO python wheel staged"*) _v="wrong" ;; *) _v="right" ;; esac
t_assert_eq "right" "${_v}"
rm -f "${TVM_WHEEL_DIR}"/*.whl

t_case "no wheel + libtvm under lib/ -> the native-runtime claim is made and NAMES the file"
prefix="${_tmp}/px-lib"
mkdir -p "${prefix}/lib"
: > "${prefix}/lib/libtvm.so"
_out="$(_verdict "${prefix}")"
t_assert_contains "${_out}" "NO python wheel staged"
t_assert_contains "${_out}" "native runtime DOES still ship"
t_assert_contains "${_out}" "${prefix}/lib/libtvm.so" "the claim must cite the file it verified"

t_case "no wheel + libtvm under lib64/ -> still found (the lib64 layout)"
prefix="${_tmp}/px-lib64"
mkdir -p "${prefix}/lib64"
: > "${prefix}/lib64/libtvm_runtime.so"
_out="$(_verdict "${prefix}")"
t_assert_contains "${_out}" "native runtime DOES still ship"
t_assert_contains "${_out}" "${prefix}/lib64/libtvm_runtime.so"

t_case "no wheel and NO libtvm anywhere -> the claim is NOT made"
prefix="${_tmp}/px-empty"
mkdir -p "${prefix}/lib" "${prefix}/lib64"
_out="$(_verdict "${prefix}")"
case "${_out}" in *"native runtime DOES still ship"*) _c="claimed" ;; *) _c="withheld" ;; esac
t_assert_eq "withheld" "${_c}" \
  "the unconditional version of this line asserted a runtime that was not there"
t_assert_contains "${_out}" "no usable TVM at all" \
  "and it must say so, rather than going quiet"

t_case "the recorded skip reason is surfaced in the verdict"
t_assert_contains "${_out}" "probe reason"

t_summary
