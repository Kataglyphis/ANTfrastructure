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
  if [ "$(LANE="${candidate}" _q "${query}")" = True ]; then
    return 0
  fi
  return 1
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
GPU_PIN="${_work}/gpu-pin-check.sh"
GPU_FORMATS="${_work}/gpu-format-check.sh"
# shellcheck disable=SC2086
${_PY} "${ROOT}/linux/scripts/tests/reusable_linux_lane_fixture.py" "${ROOT}/linux/scripts" "${LANE}" "${STEP}" "${EXTRA}" "${STEPS}" "${GPU_PIN}" "${GPU_FORMATS}"

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

t_case "host GPU runtime is an explicit packaging-only opt-in"
t_assert_eq "boolean|false|false" "$(_input_meta host-gpu-runtime)"
t_assert_eq "string|false|" "$(_input_meta gpu-artifact-label)"
t_assert_eq "string|false|image" "$(_input_meta app-python-runtime)"
t_assert_contains "$(grep -F 'Packaging application|' "${EXTRA}")" '-e PYTHON_APP_PYTHON_RUNTIME=${{ inputs.app-python-runtime }}'
t_assert_fails grep -F 'PYTHON_APP_PYTHON_RUNTIME=' < <(grep -F 'Run Python tests|' "${EXTRA}")

t_case "GPU reruns replace each vendor and architecture artifact without changing CPU behavior"
_gpu_overwrite_query='all(V.value(V.value(s,"with"),"overwrite") == "${{ inputs.host-gpu-runtime }}" for s in V.value(build,"steps") if V.value(s,"name") in ("Upload test results", "Upload packages (source/binary only)"))'
t_assert_eq 'True' "$(_q "${_gpu_overwrite_query}")"
_gpu_overwrite_count='len([s for s in V.value(build,"steps") if V.value(s,"name") in ("Upload test results", "Upload packages (source/binary only)")]) == 2'
t_assert_eq 'True' "$(_q "${_gpu_overwrite_count}")"
t_assert_contains "$(grep -F 'Packaging application|' "${EXTRA}")" \
  "inputs.host-gpu-runtime && '-e PYTHON_APP_HOST_GPU_RUNTIME=true' || ''"
t_assert_contains "$(grep -F 'Packaging application|' "${EXTRA}")" "inputs.host-gpu-runtime && format('-e PYTHON_APP_REQUIRE_PROVIDER={0}'"
t_assert_fails grep -F 'PYTHON_APP_HOST_GPU_RUNTIME=' < <(grep -F 'Run Python tests|' "${EXTRA}")
_gpu_packaging_forwarded() {
  grep -F 'Packaging application|' "$1" | grep -Fq -- "inputs.host-gpu-runtime && '-e PYTHON_APP_HOST_GPU_RUNTIME=true' || ''"
}
_gpu_plan() {
  env HOST_GPU_RUNTIME=true GPU_CONTAINER_IMAGE=image GITHUB_OUTPUT="${OUT}" "$@" bash --noprofile --norc -e "${STEP}"
}
t_assert_ok _gpu_packaging_forwarded "${EXTRA}"
sed 's/PYTHON_APP_HOST_GPU_RUNTIME/PYTHON_APP_MISSING_GPU_RUNTIME/' "${EXTRA}" > "${_work}/missing-gpu-extra"
t_assert_fails _gpu_packaging_forwarded "${_work}/missing-gpu-extra"
t_assert_ok _gpu_plan GPU_ARTIFACT_LABEL=amd ARCHES=x64
t_assert_ok _gpu_plan GPU_ARTIFACT_LABEL=amd APP_PYTHON_RUNTIME=standalone ARCHES=x64
t_assert_fails _gpu_plan GPU_ARTIFACT_LABEL=amd APP_PYTHON_RUNTIME=unsafe ARCHES=x64
t_assert_fails env HOST_GPU_RUNTIME=false APP_PYTHON_RUNTIME=standalone ARCHES=x64 GITHUB_OUTPUT="${OUT}" bash --noprofile --norc -e "${STEP}"
t_assert_ok _gpu_plan GPU_ARTIFACT_LABEL=nvidia ARCHES='x64 arm64'
t_assert_fails _gpu_plan GPU_ARTIFACT_LABEL=amd ARCHES=arm64
t_assert_fails _gpu_plan GPU_ARTIFACT_LABEL=nvidia ARCHES=riscv64
t_assert_fails _gpu_plan GPU_ARTIFACT_LABEL=amd GPU_CONTAINER_IMAGE='' ARCHES=x64
t_assert_fails _gpu_plan GPU_ARTIFACT_LABEL='' ARCHES=x64
t_assert_fails _gpu_plan GPU_ARTIFACT_LABEL='AMD/unsafe' ARCHES=x64
t_assert_fails env HOST_GPU_RUNTIME=false GPU_ARTIFACT_LABEL=amd ARCHES=x64 GITHUB_OUTPUT="${OUT}" bash --noprofile --norc -e "${STEP}"
t_assert_contains "$(grep -F 'Upload packages (source/binary only)|' "${STEPS}")" '!inputs.host-gpu-runtime || success()'
_artifact_name="$(_q "V.value(V.value(next(s for s in V.value(build,'steps') if V.value(s,'name') == 'Upload packages (source/binary only)'), 'with'), 'name')")"
t_assert_contains "${_artifact_name}" 'unverified-gpu-{0}-packages-linux-{1}'
t_assert_contains "${_artifact_name}" 'packages-linux-{0}-source-and-binary'
t_case "the GPU path refuses an old or incomplete consumer hub pin"
t_assert_eq 'inputs.host-gpu-runtime' "$(_q "V.value(next(s for s in V.value(build,'steps') if V.value(s,'name') == 'Check pinned host GPU packaging contract'), 'if')")"
t_assert_eq 'True' "$(_q "[V.value(s,'name') for s in V.value(build,'steps')].index('Check pinned host GPU packaging contract') < [V.value(s,'name') for s in V.value(build,'steps')].index('Prepare CI host')")"
t_assert_contains "$(_q "V.value(V.value(next(s for s in V.value(build,'steps') if V.value(s,'name') == 'Prepare CI host'),'with'),'checkout')")" "inputs.host-gpu-runtime && 'false' || 'true'"
t_assert_contains "$(_q "V.value(V.value(next(s for s in V.value(build,'steps') if V.value(s,'name') == 'Prepare CI host'),'with'),'pull-first')")" "inputs.host-gpu-runtime && 'false' || 'true'"
_pin_dir="${_work}/pin/third_party/ANTfrastructure/linux/scripts/06-packaging"
mkdir -p "${_pin_dir}"
mkdir -p "${_work}/pin/third_party/ANTfrastructure/linux/scripts/02-toolchain/python"
cp "${ROOT}/linux/scripts/02-toolchain/python/ci_packaging.sh" "${_work}/pin/third_party/ANTfrastructure/linux/scripts/02-toolchain/python/"
mkdir -p "${_work}/pin/packaging"
touch "${_work}/pin/packaging/app.json"
cp "${ROOT}/linux/scripts/06-packaging/python-app-bundle.sh" "${_pin_dir}/"
cp "${ROOT}/linux/scripts/06-packaging/python-app-package.sh" "${_pin_dir}/"
cp "${ROOT}/linux/scripts/06-packaging/ort-runtime-bundle.sh" "${_pin_dir}/"
cp "${ROOT}/linux/scripts/06-packaging/elf-needed.sh" "${_pin_dir}/"
cp "${ROOT}/linux/scripts/06-packaging/verify-python-gpu-package.py" "${_pin_dir}/"
cp "${ROOT}/linux/scripts/06-packaging/python-app-deb-depends.py" "${_pin_dir}/"
t_assert_ok bash -c 'cd "$1" && bash "$2"' _ "${_work}/pin" "${GPU_PIN}"
sed -i '/^# PYTHON_APP_PYTHON_RUNTIME_API=1$/d' "${_work}/pin/third_party/ANTfrastructure/linux/scripts/02-toolchain/python/ci_packaging.sh"
t_assert_fails bash -c 'cd "$1" && bash "$2"' _ "${_work}/pin" "${GPU_PIN}"
cp "${ROOT}/linux/scripts/02-toolchain/python/ci_packaging.sh" "${_work}/pin/third_party/ANTfrastructure/linux/scripts/02-toolchain/python/"
rm "${_pin_dir}/python-app-deb-depends.py"
t_assert_fails bash -c 'cd "$1" && bash "$2"' _ "${_work}/pin" "${GPU_PIN}"
cp "${ROOT}/linux/scripts/06-packaging/python-app-deb-depends.py" "${_pin_dir}/"
rm "${_pin_dir}/verify-python-gpu-package.py"
t_assert_fails bash -c 'cd "$1" && bash "$2"' _ "${_work}/pin" "${GPU_PIN}"
cp "${ROOT}/linux/scripts/06-packaging/verify-python-gpu-package.py" "${_pin_dir}/"
sed -i '/^# PYTHON_APP_GPU_FINISHED_BINARY_API=1$/d' "${_pin_dir}/python-app-package.sh"
t_assert_fails bash -c 'cd "$1" && bash "$2"' _ "${_work}/pin" "${GPU_PIN}"
cp "${ROOT}/linux/scripts/06-packaging/python-app-package.sh" "${_pin_dir}/"
sed -i '/^# PYTHON_APP_OPTIONAL_TENSORRT_HOST_RUNTIME_API=1$/d' "${_pin_dir}/python-app-bundle.sh"
t_assert_fails bash -c 'cd "$1" && bash "$2"' _ "${_work}/pin" "${GPU_PIN}"
cp "${ROOT}/linux/scripts/06-packaging/python-app-bundle.sh" "${_pin_dir}/"
sed -i '/^# ORT_PYTHON_GPU_HOST_IMPORTS_API=1$/d' "${_pin_dir}/ort-runtime-bundle.sh"
t_assert_fails bash -c 'cd "$1" && bash "$2"' _ "${_work}/pin" "${GPU_PIN}"
cp "${ROOT}/linux/scripts/06-packaging/ort-runtime-bundle.sh" "${_pin_dir}/"
sed -i '/^# ELF_NEEDED_API=1$/d' "${_pin_dir}/elf-needed.sh"
t_assert_fails bash -c 'cd "$1" && bash "$2"' _ "${_work}/pin" "${GPU_PIN}"
cp "${ROOT}/linux/scripts/06-packaging/elf-needed.sh" "${_pin_dir}/"
sed -i '/^# PYTHON_APP_GPU_PACKAGE_API=1$/d' "${_pin_dir}/python-app-package.sh"
t_assert_fails bash -c 'cd "$1" && bash "$2"' _ "${_work}/pin" "${GPU_PIN}"
rm "${_work}/pin/packaging/app.json"
t_assert_fails bash -c 'cd "$1" && bash "$2"' _ "${_work}/pin" "${GPU_PIN}"
t_case "GPU outputs require all matching package formats and do not publish docs"
mkdir -p "${_work}/formats/dist/packages"
touch "${_work}/formats/dist/packages/app-gpu-amd-1-linux-x86_64.tar.gz" \
  "${_work}/formats/dist/packages/app-gpu-amd_1_amd64.deb" \
  "${_work}/formats/dist/packages/app-gpu-amd-1-x86_64.AppImage"
t_assert_ok env GPU_LABEL=amd GPU_ARCH=x64 bash -c 'cd "$1" && bash "$2"' _ "${_work}/formats" "${GPU_FORMATS}"
t_assert_fails env GPU_LABEL=nvidia GPU_ARCH=x64 bash -c 'cd "$1" && bash "$2"' _ "${_work}/formats" "${GPU_FORMATS}"
t_assert_fails env GPU_LABEL=amd GPU_ARCH=arm64 bash -c 'cd "$1" && bash "$2"' _ "${_work}/formats" "${GPU_FORMATS}"
t_assert_contains "$(grep -F 'Build Docs|' "${STEPS}")" '!inputs.host-gpu-runtime'
t_assert_contains "$(_q "V.value(V.value(V.value(lane,'jobs'),'docs'),'if')")" '!inputs.host-gpu-runtime'
_test_artifact_name="$(_q "V.value(V.value(next(s for s in V.value(build,'steps') if V.value(s,'name') == 'Upload test results'), 'with'), 'name')")"
t_assert_contains "${_test_artifact_name}" 'unverified-gpu-{0}-test-reports-{1}'

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
import importlib
import json
import sys

sys.path.insert(0, sys.argv[1])
V = importlib.import_module("verify_workflow_conventions")
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
