#!/usr/bin/env bash
# lint-workflows.sh — actionlint over .github/workflows/*.yml (composite
# actions under .github/actions are pulled in automatically when referenced),
# PLUS two gates over what valid YAML cannot say. verify_ci_image_refs.py: a
# stale image tag is valid YAML, so actionlint cannot see the drift the fleet
# actually suffers. verify_workflow_conventions.py: the four fleet conventions
# that were transmitted as copied header comments and enforced by nobody - the
# `*-latest` runner ban, job-level `timeout-minutes`, a `permissions:` block and
# `if-no-files-found: error`. Three of the four are ADVISORY until armed with
# WORKFLOW_CONVENTIONS_GATE (preflight.sh arms `permissions` here); the runner
# ban is enforced always, and workflow-conventions.allow freezes every
# repository's remaining count so an advisory check cannot grow. That script's
# header carries the ramp, the ratchet and the reason for both.
#
# actionlint is bootstrapped on demand: PATH copy preferred, otherwise the
# pinned release (ACTIONLINT_VERSION / ACTIONLINT_*_SHA256 in versions.env) is
# downloaded once into a version-keyed cache dir and SHA256-verified — the same
# pattern as lint-dockerfiles.sh / lib/wasm-opt.sh.
#
# actionlint's SHELL half is bootstrapped too, and is not optional here — see
# the shellcheck_for_actionlint function below. Without it actionlint grades no
# `run:` block and still exits 0, which is this file's own hazard from inside.
#
# Usage:
#   linux/scripts/lint-workflows.sh          # lint THIS repo's workflows
#   linux/scripts/lint-workflows.sh <root>   # lint a CONSUMER repo's workflows
#
# The optional root exists so consumers can lint their workflows with the same
# pinned, SHA-verified actionlint instead of bootstrapping their own. It is
# needed because a submodule checkout puts this script INSIDE the consumer,
# where the default root resolves to ContainerHub and would silently lint the
# wrong tree - and a lint gate that checks nothing still reports green. The
# bootstrap cache and versions.env always come from THIS repo regardless.
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

  local asset expected_sha cache_root archive bin_name
  read -r asset expected_sha < <(actionlint_asset_and_sha) \
    || err "Unsupported platform for actionlint bootstrap ($(uname -s)/$(uname -m)); install actionlint on PATH instead."
  [ -n "${expected_sha}" ] || err "No pinned actionlint SHA256 for ${asset}; add one to versions.env."

  cache_root="${ACTIONLINT_CACHE_DIR:-${TMPDIR:-/tmp}}/actionlint-${ACTIONLINT_VERSION}"
  bin_name="actionlint"; case "${asset}" in *windows*) bin_name="actionlint.exe" ;; esac
  ACTIONLINT_BIN="${cache_root}/${bin_name}"

  if [ ! -x "${ACTIONLINT_BIN}" ]; then
    # shellcheck source=01-core/downloads.sh
    source "${CORE_DIR}/downloads.sh" || err "downloads.sh not available for verified actionlint fetch"
    mkdir -p "${cache_root}" || err "Cannot create actionlint cache directory ${cache_root}"
    archive="${cache_root}/${asset}"
    download_verified_file \
      "https://github.com/rhysd/actionlint/releases/download/v${ACTIONLINT_VERSION}/${asset}" \
      "${expected_sha}" \
      "${archive}" \
      || err "Verified download of ${asset} failed (checksum mismatch or network error)."
    case "${asset}" in
      *.tar.gz) tar -xzf "${archive}" -C "${cache_root}" "${bin_name}" || err "Extraction of ${asset} failed." ;;
      *.zip)    unzip -oq "${archive}" "${bin_name}" -d "${cache_root}" || err "Extraction of ${asset} failed." ;;
    esac
    rm -f "${archive}"
    chmod +x "${ACTIONLINT_BIN}"
  fi
}

# --- actionlint's shell half -------------------------------------------------
# actionlint embeds a shellcheck pass over every `run:` block, and it reaches
# that tool by exec'ing the command NAME. When that name is not on PATH it
# DISABLES the rule and says nothing at normal verbosity -- measured on this
# host as
#   verbose: Rule "shellcheck" was disabled: exec: "shellcheck": executable
#            file not found in %PATH%
# while the gate went on printing WORKFLOW LINT OK: half of what it advertises
# was covering nothing, which is the failure its own header warns about.

# lint-shell.sh is the ONE owner of that binary (a PATH copy only AT the pin,
# otherwise the pinned SHA256-verified release), so resolve through its
# --print-bin accessor and put its DIRECTORY in front of PATH -- a name lookup
# is what actionlint does, so a name is what it has to find. A resolution that
# fails FAILS the gate: running the workflow lint without its shell half is the
# defect, not a degraded mode.
shellcheck_for_actionlint() {
  local bin dir named
  bin="$(bash "${REPO_ROOT}/linux/scripts/lint-shell.sh" --print-bin)" || bin=""
  [ -n "${bin}" ] && [ -x "${bin}" ] || err \
    "shellcheck could not be resolved through lint-shell.sh --print-bin. actionlint would disable its shellcheck rule and grade no run: block at all, so this gate refuses to report a verdict."
  dir="$(cd "$(dirname "${bin}")" && pwd)" \
    || err "the resolved shellcheck (${bin}) is not in a readable directory."
  PATH="${dir}:${PATH}"
  export PATH
  # A resolved PATH is not yet a usable rule: actionlint looks the command up by
  # NAME. Prove the name resolves here, where the message can say what is wrong,
  # rather than letting actionlint quietly turn the rule off.
  named="$(command -v shellcheck)" || err \
    "shellcheck resolved to ${bin} but the NAME does not resolve on PATH after adding ${dir}; actionlint looks it up by name and would disable the rule."
  printf '== shellcheck for run: blocks (%s) ==\n' "$("${named}" --version | sed -n 's/^version: //p')"
}

# A resolved binary is a PRECONDITION; a rule that actually fired is the
# guarantee, and only one of those is what the gate claims. So: lint one
# workflow whose ONLY defect is a shell one (SC1010 -- `[ ... ] then` with no
# separator, which actionlint's own YAML/expression rules cannot see) and
# require it to be reported. Reading it off `--verbose` instead was tried and
# discarded: actionlint lints files concurrently and its unsynchronised writes
# mangle the "verbose: " prefix, so the trace cannot be filtered or matched
# reliably. This costs one stdin-sized lint, needs no fixture on disk and no
# enclosing checkout, and it fails for the one reason it is asked about.
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

# Run from the SCRIPT's repo so the relative path resolves to this checkout's
# copy, and hand it the tree actually being linted - the same split, and the
# reason this script takes a root at all.
# Interpreter: the same contract preflight.sh documents at its top — plain
# python3 is NOT trusted, because on Windows Git Bash it is the Microsoft Store
# stub, which prints an install hint and exits non-zero. preflight exports the
# probed interpreter; a standalone run inherits nothing, so verify before use
# rather than letting the gate die inside the Python step with a stub message.
_PY="${PREFLIGHT_PYTHON:-python3}"
if ! command -v "${_PY}" >/dev/null 2>&1 || ! "${_PY}" -c "pass" >/dev/null 2>&1; then
  printf "lint-workflows.sh: no working Python (tried %s).\n" "${_PY}" >&2
  printf "                   Set PREFLIGHT_PYTHON, e.g. PREFLIGHT_PYTHON=\"uv run --no-project python\"\n" >&2
  exit 1
fi
( cd "${REPO_ROOT}" && "${_PY}" linux/scripts/verify_ci_image_refs.py "${LINT_ROOT}" ) || FAILED=1

# The conventions half runs on the same terms: this checkout's copy, the handed
# tree, and its own exit status folded into the one verdict. Its allow file is
# read from THIS repo too, which is what lets one table hold the deviations of
# every consumer that vendors this hub.
( cd "${REPO_ROOT}" && "${_PY}" linux/scripts/verify_workflow_conventions.py "${LINT_ROOT}" ) || FAILED=1

if [ "${FAILED}" -eq 0 ]; then
  printf 'WORKFLOW LINT OK\n'
else
  printf 'WORKFLOW LINT FAILED\n' >&2
  exit 1
fi
