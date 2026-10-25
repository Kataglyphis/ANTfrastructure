#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HUB_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
REPO_ROOT="${HUB_ROOT}"
ROOT_GIVEN=0
MODE=check
MODE_GIVEN=0
REQUESTED=()
RUN_LOG=""

usage() {
  cat <<'EOF'
Usage: bash linux/scripts/refactor-python.sh [--root DIR] [--check|--apply] [--] [tracked/path.py ...]

  --root   Git checkout to refactor (default: ANTfrastructure)
  --check  report Ruff lint and format drift without editing (default)
  --apply  apply safe Ruff fixes and formatting to clean tracked Python files

Paths are exact, target-repo-relative tracked .py files. With no paths, all tracked .py files are selected.
The target's Ruff configuration is used. Reports and the patch stay under its ignored logs/code-quality/.
EOF
}

die() {
  printf 'ERROR: %s\n' "$*" >&2
  if [[ -n "${RUN_LOG}" ]]; then printf 'ERROR: %s\n' "$*" >> "${RUN_LOG}"; fi
  exit 1
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --root)
      [[ $# -gt 1 && -n "$2" ]] || die "--root needs a directory argument"
      [[ "${ROOT_GIVEN}" -eq 0 ]] || die "--root was given twice"
      REPO_ROOT="$2"
      ROOT_GIVEN=1
      shift
      ;;
    --root=*)
      [[ -n "${1#--root=}" ]] || die "--root needs a directory argument"
      [[ "${ROOT_GIVEN}" -eq 0 ]] || die "--root was given twice"
      REPO_ROOT="${1#--root=}"
      ROOT_GIVEN=1
      ;;
    --check|--apply)
      next_mode="${1#--}"
      if [[ "${MODE_GIVEN}" -eq 1 && "${MODE}" != "${next_mode}" ]]; then
        die "choose either --check or --apply"
      fi
      MODE="${next_mode}"
      MODE_GIVEN=1
      ;;
    -h|--help) usage; exit 0 ;;
    --) shift; REQUESTED+=("$@"); break ;;
    -*) die "unknown option: $1" ;;
    *) REQUESTED+=("$1") ;;
  esac
  shift
done

REPO_ROOT="$(cd "${REPO_ROOT}" 2>/dev/null && pwd -P)" || die "target root does not exist"
git -C "${REPO_ROOT}" rev-parse --git-dir >/dev/null 2>&1 || die "${REPO_ROOT} is not a Git checkout"
[[ -z "$(git -C "${REPO_ROOT}" rev-parse --show-prefix)" ]] \
  || die "--root must name the top of a Git checkout"
cd "${REPO_ROOT}" || die "cannot enter ${REPO_ROOT}"
git check-ignore -q --no-index -- logs/code-quality/python-refactor.probe \
  || die "logs/code-quality/ must be ignored by Git"

PIN_FILE="${SCRIPT_DIR}/01-core/tool-pins.env"
LOADER="${SCRIPT_DIR}/01-core/load-versions-env.sh"
SCOPE="${SCRIPT_DIR}/01-core/lint-root.sh"
[[ -f "${PIN_FILE}" && -f "${LOADER}" && -f "${SCOPE}" ]] \
  || die "the pinned Ruff configuration or tracked-file helper is missing"
# shellcheck source=01-core/load-versions-env.sh
source "${LOADER}"
# shellcheck source=01-core/lint-root.sh
source "${SCOPE}"
unset RUFF_VERSION
load_versions_env "${PIN_FILE}"
: "${RUFF_VERSION:?RUFF_VERSION is missing from tool-pins.env}"
command -v uvx >/dev/null 2>&1 || die "uvx is missing; install the pinned uv setup first"

LOG_DIR="${REPO_ROOT}/logs/code-quality"
mkdir -p "${LOG_DIR}" || die "cannot create ${LOG_DIR}"
RUN_DIR="$(mktemp -d "${LOG_DIR}/python-refactor.XXXXXXXX")" \
  || die "cannot allocate a report directory"
RUN_LOG="${RUN_DIR}/refactor.log"
: > "${RUN_LOG}"
: > "${RUN_DIR}/changes.patch"
lint_root_tracked "${REPO_ROOT}" '*.py' > "${RUN_DIR}/tracked-files.z" \
  || die "cannot enumerate tracked Python files"
mapfile -d '' -t TRACKED < "${RUN_DIR}/tracked-files.z"
[[ "${#TRACKED[@]}" -gt 0 ]] || die "the checkout has no tracked Python files"

SELECTED=()
if [[ "${#REQUESTED[@]}" -eq 0 ]]; then
  SELECTED=("${TRACKED[@]}")
else
  for requested in "${REQUESTED[@]}"; do
    found=0
    for tracked in "${TRACKED[@]}"; do
      if [[ "${requested}" == "${tracked}" ]]; then found=1; break; fi
    done
    [[ "${found}" -eq 1 ]] || die "not an exact tracked Python path: ${requested}"
    for selected in "${SELECTED[@]}"; do
      [[ "${requested}" != "${selected}" ]] || die "duplicate path: ${requested}"
    done
    SELECTED+=("${requested}")
  done
fi
for selected in "${SELECTED[@]}"; do
  [[ -f "${selected}" && ! -L "${selected}" ]] \
    || die "selected Python path is missing or a symlink: ${selected}"
done

refactor_log() { printf '%s\n' "$*" | tee -a "${RUN_LOG}"; }

run_ruff() {
  local -a statuses
  refactor_log "== uvx ruff@${RUFF_VERSION} $1 (${#SELECTED[@]} file(s)) =="
  set +e
  uvx "ruff@${RUFF_VERSION}" "$@" 2>&1 | tee -a "${RUN_LOG}"
  statuses=("${PIPESTATUS[@]}")
  set -e
  [[ "${statuses[1]}" -eq 0 ]] || return "${statuses[1]}"
  return "${statuses[0]}"
}

refactor_log "mode=${MODE} scope=${#SELECTED[@]} report=${RUN_DIR#"${REPO_ROOT}"/}"
if [[ "${MODE}" == check ]]; then
  failed=0
  run_ruff check --no-fix --no-unsafe-fixes -- "${SELECTED[@]}" || failed=1
  run_ruff format --check --diff -- "${SELECTED[@]}" || failed=1
  [[ "${failed}" -eq 0 ]] || die "Python lint or format drift remains; see ${RUN_LOG}"
  refactor_log "Ruff lint and format are clean; no files were changed."
  exit 0
fi

git diff --quiet -- "${SELECTED[@]}" \
  || die "selected Python files have unstaged changes; commit or restore them before --apply"
git diff --cached --quiet -- "${SELECTED[@]}" \
  || die "selected Python files have staged changes; commit or restore them before --apply"

BACKUP_DIR="${RUN_DIR}/original"
for selected in "${SELECTED[@]}"; do
  mkdir -p "${BACKUP_DIR}/$(dirname "${selected}")"
  cp -p -- "${selected}" "${BACKUP_DIR}/${selected}"
done
APPLY_STARTED=1
APPLY_DONE=0
restore_on_failure() {
  local status=$?
  trap - EXIT
  if [[ "${APPLY_STARTED}" -eq 1 && "${APPLY_DONE}" -eq 0 ]]; then
    git diff --binary -- "${SELECTED[@]}" > "${RUN_DIR}/failed-attempt.patch" || true
    for selected in "${SELECTED[@]}"; do
      cp -p -- "${BACKUP_DIR}/${selected}" "${selected}" || status=1
    done
    printf 'Restored selected Python files after failure; report: %s\n' "${RUN_DIR}" >&2
  fi
  exit "${status}"
}
trap restore_on_failure EXIT

run_ruff check --fix --no-unsafe-fixes -- "${SELECTED[@]}" \
  || die "Ruff safe fixes failed"
run_ruff format -- "${SELECTED[@]}" \
  || die "Ruff formatting failed"
run_ruff check --no-fix --no-unsafe-fixes -- "${SELECTED[@]}" \
  || die "Ruff lint still reports findings after refactoring"
run_ruff format --check -- "${SELECTED[@]}" \
  || die "Ruff formatting still reports drift after refactoring"
git diff --binary -- "${SELECTED[@]}" > "${RUN_DIR}/changes.patch" \
  || die "cannot write the resulting patch"
APPLY_DONE=1
refactor_log "Refactor complete. Patch: ${RUN_DIR#"${REPO_ROOT}"/}/changes.patch"
