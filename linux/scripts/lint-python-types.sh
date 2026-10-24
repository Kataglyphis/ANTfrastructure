#!/usr/bin/env bash
# See docs/code-quality-tooling.md#python-type-analysis for the strict scope and report policy.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "${ROOT}" || exit 1

# shellcheck source=01-core/load-versions-env.sh
. linux/scripts/01-core/load-versions-env.sh
load_versions_env linux/scripts/01-core/tool-pins.env
: "${TY_VERSION:?TY_VERSION is missing from tool-pins.env}"
: "${RUFF_VERSION:?RUFF_VERSION is missing from tool-pins.env}"
command -v uvx >/dev/null 2>&1 || { echo "uvx is required for ty@${TY_VERSION}" >&2; exit 2; }
git rev-parse --is-inside-work-tree >/dev/null 2>&1 || { echo "A Git worktree is required for the Python type scan" >&2; exit 2; }

report_dir="${ROOT}/logs/code-quality"
mkdir -p "${report_dir}"
linux_report="${report_dir}/ty-linux.txt"
windows_report="${report_dir}/ty-windows.txt"
strict_report="${report_dir}/ty-quality-gate.txt"
annotations_report="${report_dir}/ruff-annotations.txt"

mapfile -d '' -t py_files < <(git ls-files -z -- '*.py')
mapfile -d '' -t quality_files < <(git ls-files -z -- 'docs/scripts/*.py' 'linux/scripts/verify_*.py' \
  'linux/scripts/gate_scope.py' 'linux/scripts/quality_allow.py' 'linux/scripts/extract_embedded_python.py')
[ "${#py_files[@]}" -gt 0 ] || { echo "No tracked Python files found" >&2; exit 2; }
[ "${#quality_files[@]}" -gt 0 ] || { echo "No tracked Python quality scripts found" >&2; exit 2; }

linux_files=()
windows_files=()
for file in "${py_files[@]}"; do
  if [[ "${file}" == windows/* ]]; then
    windows_files+=("${file}")
  else
    linux_files+=("${file}")
  fi
done

ty=(uvx "ty@${TY_VERSION}" check --python-version 3.14 --output-format concise)
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

if "${ty[@]}" --python-platform linux "${search[@]}" "${quality_files[@]}" > "${strict_report}" 2>&1; then
  printf 'ty quality gate: clean (%s files); %s\n' "${#quality_files[@]}" "${strict_report}"
else
  rc=$?
  cat "${strict_report}" >&2
  printf 'ty quality gate failed (exit %s)\n' "${rc}" >&2
  exit "${rc}"
fi
