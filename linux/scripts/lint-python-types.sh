#!/usr/bin/env bash
# Image-only imports and remaining annotation debt stay report-only; see docs/code-quality-tooling.md#python-type-analysis.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "${ROOT}" || exit 1

# shellcheck source=01-core/load-versions-env.sh
. linux/scripts/01-core/load-versions-env.sh
load_versions_env linux/scripts/01-core/tool-pins.env
: "${TY_VERSION:?TY_VERSION is missing from tool-pins.env}"
: "${RUFF_VERSION:?RUFF_VERSION is missing from tool-pins.env}"
command -v uvx >/dev/null 2>&1 || { echo "uvx is required for ty@${TY_VERSION}" >&2; exit 2; }
command -v uv >/dev/null 2>&1 || { echo "uv is required for the locked Python type environment" >&2; exit 2; }
git rev-parse --is-inside-work-tree >/dev/null 2>&1 || { echo "A Git worktree is required for the Python type scan" >&2; exit 2; }

quality_venv="${ROOT}/quality/.venv"
UV_PROJECT_ENVIRONMENT="${quality_venv}" uv sync --project "${ROOT}/quality" --locked --python 3.14
quality_python="${quality_venv}/bin/python"
if [ ! -f "${quality_python}" ]; then quality_python="${quality_venv}/Scripts/python.exe"; fi
[ -f "${quality_python}" ] || { echo "The locked Python type environment has no interpreter" >&2; exit 2; }

report_dir="${ROOT}/logs/code-quality"
mkdir -p "${report_dir}"
linux_report="${report_dir}/ty-linux.txt"
windows_report="${report_dir}/ty-windows.txt"
strict_report="${report_dir}/ty-quality-gate.txt"
windows_gate_report="${report_dir}/ty-windows-gate.txt"
annotations_report="${report_dir}/ruff-annotations.txt"
annotations_gate_report="${report_dir}/ruff-annotations-gate.txt"
private_returns_report="${report_dir}/ruff-private-returns-gate.txt"
parameter_returns_report="${report_dir}/ruff-parameters-returns-gate.txt"

mapfile -d '' -t py_files < <(git ls-files -z -- '*.py')
mapfile -d '' -t quality_files < <(git ls-files -z -- '.claude/hooks/*.py' 'docs/scripts/*.py' \
  'linux/ansible/scripts/*.py' 'linux/host-config/*.py' 'linux/llm-stack/gateway/*.py' \
  'linux/llm-stack/tests/*.py' \
  'linux/scripts/01-core/manifest-*.py' 'linux/scripts/01-core/registry-*.py' \
  'linux/scripts/02-toolchain/oci-layers-extract.py' \
  'linux/scripts/02-toolchain/registry-platform-digest.py' \
  'linux/scripts/02-toolchain/python/free-threaded-wheel.py' \
  'linux/scripts/02-toolchain/python/free-threaded-wheel-tests.py' \
  'linux/scripts/02-toolchain/python/verify-test-reports.py' \
  'linux/scripts/02-toolchain/python/wheel-smoke.py' \
  'linux/scripts/03-media/*.py' 'linux/scripts/05-frameworks/*.py' \
  'linux/scripts/06-packaging/free-threaded-sysconfig-tools.py' \
  'linux/scripts/06-packaging/ort_census_probe.py' \
  'linux/scripts/06-packaging/python-app-selftest.py' \
  'linux/scripts/develop_red.py' 'linux/scripts/image-acceptance.py' \
  'linux/scripts/layer-audit.py' 'linux/scripts/lib/cmakelang-py315.py' \
  'linux/scripts/lib/fetch-data-lock.py' 'linux/scripts/lib/dartdoc-guides.py' \
  'linux/scripts/renovate_audit.py' 'linux/scripts/renovate_cmake.py' \
  'linux/scripts/renovate_locator.py' 'linux/scripts/renovate_planner.py' \
  'linux/scripts/verify_*.py' \
  'linux/scripts/tests/*.py' 'linux/scripts/gate_scope.py' 'linux/scripts/quality_allow.py' \
  'linux/scripts/extract_embedded_python.py' 'shared/python/*.py')
mapfile -d '' -t windows_quality_files < <(git ls-files -z -- 'windows/scripts/certificates/*.py')
mapfile -d '' -t parameter_return_files < <(git ls-files -z -- \
  'linux/scripts/renovate_cmake.py' 'linux/scripts/renovate_planner.py' \
  'linux/llm-stack/gateway/render_apisix.py' 'linux/llm-stack/tests/test_gateway_render.py' \
  'docs/scripts/verify_code_dupes.py' 'docs/scripts/verify_doc_dupes.py' \
  'docs/scripts/sync_versions.py' 'linux/host-config/ghcr_metadata.py' \
  'linux/scripts/01-core/manifest-base-layer.py' 'linux/scripts/01-core/registry-config-label.py' \
  'linux/scripts/01-core/registry-digest.py' 'linux/scripts/02-toolchain/oci-layers-extract.py' \
  'linux/scripts/02-toolchain/python/wheel-smoke.py' 'linux/scripts/tests/test-wheel-rewrite.py' \
  'linux/scripts/verify_readme_length.py')
[ "${#py_files[@]}" -gt 0 ] || { echo "No tracked Python files found" >&2; exit 2; }
[ "${#quality_files[@]}" -gt 0 ] || { echo "No tracked Python quality or test scripts found" >&2; exit 2; }
[ "${#windows_quality_files[@]}" -gt 0 ] || { echo "No tracked Windows Python certificate scripts found" >&2; exit 2; }
[ "${#parameter_return_files[@]}" -eq 15 ] || { echo "Missing tracked parameter and public-return targets" >&2; exit 2; }

linux_files=()
windows_files=()
for file in "${py_files[@]}"; do
  if [[ "${file}" == windows/* ]]; then
    windows_files+=("${file}")
  else
    linux_files+=("${file}")
  fi
done

ty=(uvx "ty@${TY_VERSION}" check --python "${quality_python}" --python-version 3.14 --output-format concise)
search=(--extra-search-path docs/scripts --extra-search-path linux/scripts --extra-search-path shared/python)

# Findings remain visible during adoption; setup and checker crashes still fail CI.
report_scan() {
  local label="$1" platform="$2" report="$3" rc=0
  shift 3
  [ "$#" -gt 0 ] || return 0
  "${ty[@]}" --python-platform "${platform}" "${search[@]}" "$@" > "${report}" 2>&1 || rc=$?
  case "${rc}" in
    0) printf '%s: clean (%s files)\n' "${label}" "$#" ;;
    1) printf '%s: findings (%s files); %s\n' "${label}" "$#" "${report}" ;;
    *) cat "${report}" >&2; return "${rc}" ;;
  esac
}

report_scan "Linux Python report" linux "${linux_report}" "${linux_files[@]}"
report_scan "Windows Python report" windows "${windows_report}" "${windows_files[@]}"

annotation_rc=0
uvx "ruff@${RUFF_VERSION}" check --no-fix --select ANN001,ANN002,ANN003,ANN201,ANN202,ANN204,ANN205,ANN206 \
  --output-format concise "${py_files[@]}" > "${annotations_report}" 2>&1 || annotation_rc=$?
case "${annotation_rc}" in
  0) printf 'Ruff annotation report: clean (%s files)\n' "${#py_files[@]}" ;;
  1) printf 'Ruff annotation report: findings (%s files); %s\n' "${#py_files[@]}" "${annotations_report}" ;;
  *) cat "${annotations_report}" >&2; exit "${annotation_rc}" ;;
esac

strict_scan() {
  local label="$1" report="$2" count="$3" rc=0
  shift 3
  "$@" > "${report}" 2>&1 || rc=$?
  if [ "${rc}" -ne 0 ]; then
    if [ -f "${report}" ]; then cat "${report}" >&2; fi
    printf '%s failed (exit %s)\n' "${label}" "${rc}" >&2
    exit "${rc}"
  fi
  printf '%s: clean (%s files); %s\n' "${label}" "${count}" "${report}"
}

# Remaining ANN001/ANN201 findings stay report-only outside the selected clean files.
strict_scan "Ruff signature annotation gate" "${annotations_gate_report}" "${#py_files[@]}" \
  uvx "ruff@${RUFF_VERSION}" check --no-fix --select ANN002,ANN003,ANN204,ANN205,ANN206 --output-format concise "${py_files[@]}"
strict_scan "Ruff private return gate" "${private_returns_report}" "${#py_files[@]}" \
  uvx "ruff@${RUFF_VERSION}" check --no-fix --select ANN202 --output-format concise "${py_files[@]}"
strict_scan "Ruff parameter and public return gate" "${parameter_returns_report}" "${#parameter_return_files[@]}" \
  uvx "ruff@${RUFF_VERSION}" check --no-fix --select ANN001,ANN201 --output-format concise "${parameter_return_files[@]}"
strict_scan "ty quality gate" "${strict_report}" "${#quality_files[@]}" \
  "${ty[@]}" --python-platform linux "${search[@]}" "${quality_files[@]}"
strict_scan "ty Windows gate" "${windows_gate_report}" "${#windows_quality_files[@]}" \
  "${ty[@]}" --python-platform windows "${search[@]}" "${windows_quality_files[@]}"
