#!/usr/bin/env bash
# Local lane queries and plan shells cover contracts, not actual CI jobs; see docs/python-ci.md#one-arch-per-caller-the-arches-input
set -u
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=linux/scripts/tests/workflow-lane-fixture.sh
source "${TESTS_DIR}/workflow-lane-fixture.sh"
# Plain python3 is a Microsoft Store stub on a Windows host.
_PY="${PREFLIGHT_PYTHON:-python3}"
workflow_lane_fixture_init .github/workflows/python-ci-linux.yml build - "${_PY}" || exit 1

_work="$(mktemp -d)"
trap 'rm -rf "${_work}"' EXIT

t_case "the lane file is where every consumer's uses: line expects it"
t_assert_ok test -f "${LANE}"

_test_report_upload_required() {
  local candidate="$1"
  local query="len([s for s in V.value(build,'steps') if V.value(s,'name') == 'Upload test results' and V.value(s,'if') == 'always()' and V.value(V.value(s,'with'),'path') == 'logs/test-results/' and V.value(V.value(s,'with'),'if-no-files-found') == 'error']) == 1"
  [ "$(LANE="${candidate}" _q "${query}")" = True ]
}

t_case "the test report upload stays fatal and reachable after a failed test"
t_assert_ok _test_report_upload_required "${LANE}"
faulted="${_work}/test-report-upload-warn.yml"
sed 's/if-no-files-found: error/if-no-files-found: warn/g' "${LANE}" > "${faulted}"
t_assert_fails _test_report_upload_required "${faulted}"

t_case "the shared query driver retains multiword interpreter selection and Python errors"
t_assert_eq fixture-query "$(
  workflow_lane_fixture_init .github/workflows/python-ci-linux.yml build - $'env\nWORKFLOW_QUERY_MARKER=fixture-query\n'"${_PY}"
  _q "__import__('os').environ.get('WORKFLOW_QUERY_MARKER')"
)"
t_assert_rc 1 _q '1 / 0'

# Block scalars stay opaque in the loader, so all three cuts live here: the plan step's run body, the container steps' extra-args and every step's if.
STEP="${_work}/plan-step.sh"
EXTRA="${_work}/extra-args"
STEPS="${_work}/conditions"
# shellcheck disable=SC2086
${_PY} - "${ROOT}/linux/scripts" "${LANE}" "${STEP}" "${EXTRA}" "${STEPS}" <<'PY'
import sys, pathlib, textwrap
sys.path.insert(0, sys.argv[1])
import verify_workflow_conventions as V
path = pathlib.Path(sys.argv[2])
lane = V.load_yaml(path)
lines = path.read_text(encoding='utf-8').splitlines()

def cut(at):
    # The block scalar whose key sits on line `at`, cut by indentation.
    key_indent = len(lines[at]) - len(lines[at].lstrip())
    body = []
    for line in lines[at + 1:]:
        if line.strip() and len(line) - len(line.lstrip()) <= key_indent:
            break
        body.append(line)
    return body

plan = next(s for s in V.value(V.value(V.value(lane, 'jobs'), 'plan'), 'steps') if V.value(s, 'id') == 'rows')
pathlib.Path(sys.argv[3]).write_text(textwrap.dedent('\n'.join(cut(V.line_of(plan, 'run') - 1))).strip() + '\n', encoding='utf-8')

build = V.value(V.value(lane, 'jobs'), 'build')
with open(sys.argv[4], 'w', encoding='utf-8') as extra, open(sys.argv[5], 'w', encoding='utf-8') as conds:
    for step in (V.value(build, 'steps') or []):
        name = V.value(step, 'name')
        conds.write(f"{name}|{str(V.value(step, 'if') or '-')}\n")
        if name not in ('Run Python tests', 'Packaging application'):
            continue
        with_at = V.line_of(step, 'with') - 1
        with_indent = len(lines[with_at]) - len(lines[with_at].lstrip())
        j = with_at + 1
        while j < len(lines) and (not lines[j].strip() or len(lines[j]) - len(lines[j].lstrip()) > with_indent):
            if lines[j].strip().startswith('extra-args:'):
                break
            j += 1
        extra.write(f"{name}|{' '.join(x.strip() for x in cut(j))}\n")
PY

# _plan <arches>: run the step under `bash -e`, as the runner does, with a fresh GITHUB_OUTPUT.
OUT="${_work}/github-output"
_plan() {
  : > "${OUT}"
  ARCHES="$1" GITHUB_OUTPUT="${OUT}" bash --noprofile --norc -e "${STEP}" 2>&1
}
_plan_rc() { _plan "$1" >/dev/null; echo $?; }
_matrix() { _plan "$1" >/dev/null; sed -n 's/^matrix=//p' "${OUT}"; }

# _rows <arches>: `arch runs_on platform` per row, via a real JSON parser so a malformed matrix fails.
_rows() {
  local m; m="$(_matrix "$1")"
  # shellcheck disable=SC2086
  ${_PY} -c 'import json, sys
for r in json.loads(sys.argv[1])["include"]:
    print(r["arch"], r["runs_on"], r["platform"])' "${m}" 2>&1 | tr -d '\r'
}

X64_ROW="x64 ubuntu-26.04 linux/amd64"
ARM_ROW="arm64 ubuntu-26.04-arm linux/arm64"

t_case "the step was found and is not empty"
t_assert_ok test -s "${STEP}"
t_assert_contains "$(cat "${STEP}")" 'GITHUB_OUTPUT'

# _input_meta <name>: an input's `type|required|default` triple, via the conventions loader.
_input_meta() {
  _q "'|'.join(str(V.value(inputs.get('$1', ({}, 0))[0], k)) for k in ('type', 'required', 'default'))"
}

t_case "arches is an optional string whose default is today's two rows"
# Every caller that predates the input must keep both rows.
t_assert_eq "string|false|x64 arm64" "$(_input_meta arches)"

t_case "the Python coverage floor reaches each test leg and defaults to an integrity check"
t_assert_eq "string|false|0" "$(_input_meta coverage-min)"
t_assert_contains "$(grep -F 'Run Python tests|' "${EXTRA}")" \
  '-e PYTHON_COVERAGE_MIN=${{ inputs.coverage-min }}' \
  "a declared input with no test-step forwarding cannot raise the coverage floor"

t_case "the DEFAULT yields exactly the rows the static matrix held, in order"
# A changed row silently renames the caller's jobs (matrix.arch) and artifacts (matrix.runs_on).
t_assert_eq "${X64_ROW}
${ARM_ROW}" "$(_rows "x64 arm64")"
t_assert_eq "0" "$(_plan_rc "x64 arm64")"

t_case "one name selects one row"
t_assert_eq "${X64_ROW}" "$(_rows "x64")"
t_assert_eq "${ARM_ROW}" "$(_rows "arm64")"
t_assert_eq "${ARM_ROW}" "$(_rows "  arm64  ")" "surrounding whitespace is not a name"

t_case "a list spread over lines (a block-scalar input) keeps every row"
t_assert_eq "${X64_ROW}
${ARM_ROW}" "$(_rows $'x64\narm64\n')" "a line-at-a-time read would silently drop arm64"

t_case "an unknown name FAILS, even beside a known one"
# A dropped typo would run fewer rows than asked for and stay green.
for bad in amd64 "x64 arn64" "x64,arm64" "X64"; do
  t_assert_eq "1" "$(_plan_rc "${bad}")" "arches='${bad}' must fail"
  t_assert_eq "" "$(sed -n 's/^matrix=//p' "${OUT}")" "arches='${bad}' must write no matrix"
done
t_assert_contains "$(_plan "x64 arn64")" "unknown arch 'arn64'"

t_case "a name listed twice FAILS"
# Two identical rows collide on their artifact names half-way through the run.
t_assert_eq "1" "$(_plan_rc "x64 x64")"
t_assert_contains "$(_plan "arm64 x64 arm64")" "'arm64' is listed twice"

t_case "an empty list FAILS instead of producing an empty matrix"
t_assert_eq "1" "$(_plan_rc "")"
t_assert_eq "1" "$(_plan_rc "   ")"
t_assert_contains "$(_plan "")" "arches is empty"

t_case "no row runs on a moving *-latest label"
# The YAML gate's runner ban cannot see labels emitted from a run: block.
# shellcheck disable=SC2086
t_assert_eq "[]" "$(${_PY} - "${ROOT}/linux/scripts" "$(_matrix "x64 arm64")" <<'PY' 2>&1
import sys, json
sys.path.insert(0, sys.argv[1])
import verify_workflow_conventions as V
print([r["runs_on"] for r in json.loads(sys.argv[2])["include"] if V.LATEST_LABEL.match(r["runs_on"])])
PY
)"

t_case "the build job takes its matrix from the plan job"
t_assert_eq "plan" "$(_q "V.value(build,'needs')")"
t_assert_eq '${{ fromJSON(needs.plan.outputs.matrix) }}' "$(_q "V.value(V.value(build,'strategy'),'matrix')")"
t_assert_eq '${{ steps.rows.outputs.matrix }}' "$(_q "V.value(V.value(plan,'outputs'),'matrix')")"
t_assert_eq "false" "$(_q "V.value(V.value(build,'strategy'),'fail-fast')")" \
  "one arch failing must not hide the other's result"

t_case "the plan job is bounded and on a pinned runner"
t_assert_eq "True" "$(_q "'timeout-minutes' in plan")"
t_assert_eq "ubuntu-26.04" "$(_q "V.value(plan,'runs-on')")"

t_case "the input reaches the step through env, never spliced into the script"
t_assert_eq '${{ inputs.arches }}' "$(_q "V.value(V.value(V.value(plan,'steps')[0],'env'),'ARCHES')")"
t_assert_eq "" "$(grep -F -e '${{' "${STEP}")" "an expression in the script body is a shell injection"

t_case "package-emulated is an optional boolean, off by default"
t_assert_eq "boolean|false|false" "$(_input_meta package-emulated)"

t_case "the emulated packaging leg syncs the caller's extras, never all of them"
t_assert_contains "$(grep -F 'Packaging application|' "${EXTRA}")" "-e SYNC_EXTRAS=\${{ matrix.arch == 'riscv64' && inputs.test-extras || '' }}" "the packaging sync needs the same limit as the test legs"

t_case "the emulated test and packaging legs share one uv cache"
for step_name in "Run Python tests" "Packaging application"; do
  t_assert_contains "$(grep -F "${step_name}|" "${EXTRA}")" "-e UV_CACHE_DIR=/workspace/.uv-cache" "${step_name} must read the cache the other one fills"
done

t_case "the riscv64 row's ceiling covers a cold-cache packaging leg"
t_assert_contains "$(_matrix riscv64)" '"timeout":360' "measured: 169-min test leg + a 151-min cold rebuild"

t_case "the riscv64 packaging leg crosses on the amd64 row"
t_assert_contains "$(grep -F 'Packaging application|' "${EXTRA}")" "--platform \${{ matrix.arch == 'riscv64' && 'linux/amd64' || matrix.platform }}" "the wheel must be built on the native row, not under QEMU"
t_assert_contains "$(grep -F 'Packaging application|' "${EXTRA}")" "-e PACKAGING_CROSS_TARGET=riscv64" "the cross target must reach ci_packaging.sh"
t_assert_contains "$(grep -F 'Packaging application|' "${EXTRA}")" "steps.riscv64-cross.outputs.docker-args" "the sysroot mount and RISCV64_SYSROOT come from the cross setup"
t_assert_contains "$(cat "${LANE}")" "sysroot: \${{ inputs.package-emulated }}" "the sysroot is built only when the packaging leg is asked for"

t_case "the riscv64 packaging arm is the input, and every step downstream of it"
t_assert_contains "$(grep -F 'Packaging application|' "${STEPS}")" "inputs.package-emulated" "the packaging row may run on riscv64"
for step_name in "Fix permissions for dist directory" "Verify dist directory" "Upload packages (source/binary only)"; do
  t_assert_contains "$(grep -F "${step_name}|" "${STEPS}")" "inputs.package-emulated" "${step_name} must follow the packaging row"
done

t_summary
