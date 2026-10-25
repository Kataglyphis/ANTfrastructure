#!/usr/bin/env bash
# Remaining image-only imports and annotation debt stay report-only; see docs/code-quality-tooling.md#python-type-analysis.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "${ROOT}" || exit 1
case "${1:-}" in
  ''|--docs-conf) ;;
  *) echo "Unknown Python type scan mode: $1" >&2; exit 2 ;;
esac
[ "$#" -le 1 ] || { echo "Python type scan accepts at most one mode" >&2; exit 2; }

# shellcheck source=01-core/load-ty-tool.sh
. linux/scripts/01-core/load-ty-tool.sh
unset RUFF_VERSION
load_ty_tool linux/scripts/01-core/tool-pins.env
: "${RUFF_VERSION:?RUFF_VERSION is missing from tool-pins.env}"
command -v uv >/dev/null 2>&1 || { echo "uv is required for the locked Python type environment" >&2; exit 2; }
git rev-parse --is-inside-work-tree >/dev/null 2>&1 || { echo "A Git worktree is required for the Python type scan" >&2; exit 2; }
if [ "${1:-}" = --docs-conf ]; then
  theme="${ROOT}/third_party/DocumANTation/sphinx-kataglyphis-theme"
  [ -f "${theme}/sphinx_kataglyphis/__init__.py" ] || { echo "Pinned DocumANTation theme source is missing" >&2; exit 2; }
  mapfile -d '' -t docs_conf_files < <(git ls-files -z -- 'docs/conf.py')
  [ "${#docs_conf_files[@]}" -eq 1 ] || { echo "Tracked docs/conf.py is missing" >&2; exit 2; }
fi

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
  'linux/scripts/extract_embedded_python.py' 'linux/webserver/scripts/*.py' 'shared/python/*.py')
mapfile -d '' -t windows_quality_files < <(git ls-files -z -- 'windows/scripts/certificates/*.py')
mapfile -d '' -t parameter_return_files < <(git ls-files -z -- \
  'linux/scripts/develop_red.py' 'linux/scripts/layer-audit.py' \
  'linux/scripts/renovate_audit.py' 'linux/scripts/renovate_cmake.py' 'linux/scripts/renovate_locator.py' \
  'linux/scripts/renovate_planner.py' \
  'linux/scripts/verify_large_files.py' 'linux/scripts/verify_masked_assignments.py' \
  'linux/scripts/verify_package_names.py' \
  'linux/llm-stack/gateway/render_apisix.py' 'linux/llm-stack/tests/test_gateway_render.py' \
  'docs/scripts/verify_code_dupes.py' 'docs/scripts/verify_doc_dupes.py' \
  'docs/scripts/sync_versions.py' 'docs/scripts/bump_tools.py' 'docs/scripts/bump_fetch.py' \
  'linux/host-config/ghcr_metadata.py' \
  'linux/scripts/01-core/manifest-base-layer.py' 'linux/scripts/01-core/registry-config-label.py' \
  'linux/scripts/01-core/registry-digest.py' 'linux/scripts/02-toolchain/oci-layers-extract.py' \
  'linux/scripts/02-toolchain/python/wheel-smoke.py' 'linux/scripts/tests/test-wheel-rewrite.py' \
  'linux/scripts/verify_readme_length.py')
[ "${#py_files[@]}" -gt 0 ] || { echo "No tracked Python files found" >&2; exit 2; }
[ "${#quality_files[@]}" -gt 0 ] || { echo "No tracked Python quality or test scripts found" >&2; exit 2; }
[ "${#windows_quality_files[@]}" -gt 0 ] || { echo "No tracked Windows Python certificate scripts found" >&2; exit 2; }
[ "${#parameter_return_files[@]}" -eq 24 ] || { echo "Missing tracked parameter and public-return targets" >&2; exit 2; }

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

if [ "${1:-}" = --docs-conf ]; then
  # Sphinx rendering stays in the docs build; this checks static configuration types only.
  strict_scan "ty docs configuration gate" "${report_dir}/ty-docs-conf-gate.txt" "${#docs_conf_files[@]}" \
    "${ty[@]}" --python-platform linux "${search[@]}" --extra-search-path "${theme}" "${docs_conf_files[@]}"
  exit 0
fi

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
