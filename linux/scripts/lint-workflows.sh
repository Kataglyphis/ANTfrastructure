#!/usr/bin/env bash
# [root]: pinned actionlint with its shellcheck half, plus the image-ref and workflow-convention gates.
set -uo pipefail

SCRIPT_REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
LINT_ROOT="$(cd "${1:-${SCRIPT_REPO_ROOT}}" && pwd)" || exit 1
REPO_ROOT="${SCRIPT_REPO_ROOT}"
echo "== linting workflows under ${LINT_ROOT} =="
cd "${LINT_ROOT}" || exit 1

CORE_DIR="${REPO_ROOT}/linux/scripts/01-core"

err() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

actionlint_asset_and_sha() {
  case "$(uname -s)/$(uname -m)" in
    Linux/x86_64|Linux/amd64)
      printf 'actionlint_%s_linux_amd64.tar.gz %s\n' "${ACTIONLINT_VERSION}" "${ACTIONLINT_LINUX_AMD64_SHA256:-}" ;;
    Linux/aarch64|Linux/arm64)
      printf 'actionlint_%s_linux_arm64.tar.gz %s\n' "${ACTIONLINT_VERSION}" "${ACTIONLINT_LINUX_ARM64_SHA256:-}" ;;
    MINGW*/x86_64|MSYS*/x86_64|CYGWIN*/x86_64)
      printf 'actionlint_%s_windows_amd64.zip %s\n' "${ACTIONLINT_VERSION}" "${ACTIONLINT_WINDOWS_AMD64_SHA256:-}" ;;
    *) return 1 ;;
  esac
}

actionlint_ensure() {
  if command -v actionlint >/dev/null 2>&1; then
    ACTIONLINT_BIN="$(command -v actionlint)"
    return 0
  fi

  # shellcheck source=01-core/load-versions-env.sh
  source "${CORE_DIR}/load-versions-env.sh"
  load_versions_env "${CORE_DIR}/versions.env"
  [ -n "${ACTIONLINT_VERSION:-}" ] || err "ACTIONLINT_VERSION is not set (versions.env not found?)."

  local asset expected_sha cache_root bin_name
  read -r asset expected_sha < <(actionlint_asset_and_sha) \
    || err "Unsupported platform for actionlint bootstrap ($(uname -s)/$(uname -m)); install actionlint on PATH instead."
  [ -n "${expected_sha}" ] || err "No pinned actionlint SHA256 for ${asset}; add one to versions.env."

  cache_root="${ACTIONLINT_CACHE_DIR:-${TMPDIR:-/tmp}}/actionlint-${ACTIONLINT_VERSION}"
  bin_name="actionlint"; case "${asset}" in *windows*) bin_name="actionlint.exe" ;; esac
  ACTIONLINT_BIN="${cache_root}/${bin_name}"

  if [ ! -x "${ACTIONLINT_BIN}" ]; then
    # shellcheck source=01-core/downloads.sh
    source "${CORE_DIR}/downloads.sh" || err "downloads.sh not available for verified actionlint fetch"
    download_verified_install \
      "https://github.com/rhysd/actionlint/releases/download/v${ACTIONLINT_VERSION}/${asset}" \
      "${expected_sha}" "${ACTIONLINT_BIN}" "${bin_name}" \
      || err "Verified install of ${asset} failed (checksum mismatch, network or extraction error)."
  fi
}

# actionlint's shell half: without shellcheck on PATH it silently disables the rule.

# lint-shell.sh --print-bin owns the binary; its dir goes on PATH since actionlint looks up the name.
shellcheck_for_actionlint() {
  local bin dir named
  bin="$(bash "${REPO_ROOT}/linux/scripts/lint-shell.sh" --print-bin)" || bin=""
  [ -n "${bin}" ] && [ -x "${bin}" ] || err \
    "shellcheck could not be resolved through lint-shell.sh --print-bin. actionlint would disable its shellcheck rule and grade no run: block at all, so this gate refuses to report a verdict."
  dir="$(cd "$(dirname "${bin}")" && pwd)" \
    || err "the resolved shellcheck (${bin}) is not in a readable directory."
  PATH="${dir}:${PATH}"
  export PATH
  # Prove the name resolves here, where the error can say why, before actionlint drops the rule.
  named="$(command -v shellcheck)" || err \
    "shellcheck resolved to ${bin} but the NAME does not resolve on PATH after adding ${dir}; actionlint looks it up by name and would disable the rule."
  printf '== shellcheck for run: blocks (%s) ==\n' "$("${named}" --version | sed -n 's/^version: //p')"
}

# Proves the rule fires on a shell-only defect (SC1010); --verbose output interleaves too badly to parse.
shellcheck_rule_selftest() {
  local out
  out="$(printf 'name: probe\non: push\njobs:\n  j:\n    runs-on: ubuntu-24.04\n    steps:\n      - run: |\n          if [ "x" = "y" ] then\n            echo hi\n          fi\n' \
    | "${ACTIONLINT_BIN}" -stdin-filename shellcheck-selftest.yml - 2>&1)"
  case "${out}" in
    *"shellcheck reported issue"*) return 0 ;;
  esac
  printf '%s\n' "${out}" >&2
  err "actionlint did not report the planted SC1010 in a run: block, so its shellcheck rule is off and every run: block would be graded for YAML only. The verdict would be void; not reporting one."
}

actionlint_ensure
printf '== actionlint (%s) ==\n' "$("${ACTIONLINT_BIN}" --version | head -n1)"
shellcheck_for_actionlint
shellcheck_rule_selftest

FAILED=0
"${ACTIONLINT_BIN}" || FAILED=1

# This checkout's copy of the script, run against the handed tree.
# shellcheck source=01-core/python-probe.sh
source "${CORE_DIR}/python-probe.sh"
preflight_python_require lint-workflows.sh || exit 1
( cd "${REPO_ROOT}" && ${PREFLIGHT_PYTHON} linux/scripts/verify_ci_image_refs.py "${LINT_ROOT}" ) || FAILED=1

# Its workflow-conventions.allow comes from this repo too, so one table holds every consumer's deviations.
( cd "${REPO_ROOT}" && ${PREFLIGHT_PYTHON} linux/scripts/verify_workflow_conventions.py "${LINT_ROOT}" ) || FAILED=1

if [ "${FAILED}" -eq 0 ]; then
  printf 'WORKFLOW LINT OK\n'
else
  printf 'WORKFLOW LINT FAILED\n' >&2
  exit 1
fi
