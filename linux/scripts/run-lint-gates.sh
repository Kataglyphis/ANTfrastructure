#!/usr/bin/env bash
# run-lint-gates.sh - shellcheck, actionlint, gitleaks, ruff, shared config, pins (+ratchets) over ONE consumer tree.

#   run-lint-gates.sh <consumer-root> [--exclude <top-level-dir>]... [--ratchets]

# The root is mandatory: derived from BASH_SOURCE inside a submodule, it would grade ANTfrastructure instead.

# --exclude (default third_party) still keeps the tracked plain files directly inside the excluded directory.

# --ratchets reads freeze files at <consumer-root>/<gate>.allow; seed them from the first run.
set -uo pipefail

_LINT_GATES_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=01-core/gates.sh
source "${_LINT_GATES_DIR}/01-core/gates.sh"
# shellcheck source=01-core/python-probe.sh
source "${_LINT_GATES_DIR}/01-core/python-probe.sh"

_LINT_GATES_EXCLUDE=()
_LINT_GATES_ROOT=""
_LINT_GATES_HUB_FILE=""
_LINT_GATES_RATCHETS=0
_LINT_GATES_PY=""

_lint_gates_die() { printf 'run-lint-gates.sh: %s\n' "$*" >&2; exit 2; }

# Publishes _LINT_GATES_HUB_FILE rather than printing it; a missing hub file is a broken checkout, never a skip.
_lint_gates_hub() {
  _LINT_GATES_HUB_FILE="${_LINT_GATES_DIR}/../../$1"
  [ -f "${_LINT_GATES_HUB_FILE}" ] && return 0
  printf '%s is missing from the hub half (looked at %s).\n' "$1" "${_LINT_GATES_HUB_FILE}" >&2
  printf 'It ships in this repo, so this is a broken checkout and not a gate to skip.\n' >&2
  return 1
}

_lint_gates_parse_args() {
  [ "$#" -ge 1 ] || _lint_gates_die "the consumer repo root is required (got no arguments)"
  _LINT_GATES_ROOT="$(cd "$1" 2>/dev/null && pwd)" \
    || _lint_gates_die "consumer root not found: $1"
  shift
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --exclude)
        [ "$#" -ge 2 ] || _lint_gates_die "--exclude needs a top-level directory name"
        _LINT_GATES_EXCLUDE+=("${2%/}")
        shift 2
        ;;
      --ratchets)
        _LINT_GATES_RATCHETS=1
        shift
        ;;
      *) _lint_gates_die "unknown argument '$1' (expected --exclude <dir> or --ratchets)" ;;
    esac
  done
  [ "${#_LINT_GATES_EXCLUDE[@]}" -gt 0 ] || _LINT_GATES_EXCLUDE=(third_party)
  git -C "${_LINT_GATES_ROOT}" rev-parse --git-dir >/dev/null 2>&1 \
    || _lint_gates_die "${_LINT_GATES_ROOT} is not a git checkout; every scope here comes from git ls-files"
}

# 0 when the path's FIRST segment is an excluded directory.
_lint_gates_excluded() {
  local path="$1" head="${1%%/*}" skip
  for skip in "${_LINT_GATES_EXCLUDE[@]}"; do
    [ "${head}" = "${skip}" ] && [ "${path}" != "${head}" ] && return 0
  done
  return 1
}

# File walk: git ls-files, as a glob without globstar skips subdirectories. See docs/shared-script-libraries.md#the-empty-scope-rule
_lint_gates_scope() {
  local label="$1" spec="$2" on_empty="${3:-refuse-empty}" f
  _LINT_GATES_SCOPE=()
  # -z: otherwise git quotes a non-ASCII path, and the quoted string names nothing.
  while IFS= read -r -d '' f; do
    _lint_gates_excluded "${f}" || _LINT_GATES_SCOPE+=("${f}")
  done < <(git -C "${_LINT_GATES_ROOT}" ls-files -z -- "${spec}")
  if [ "${#_LINT_GATES_SCOPE[@]}" -eq 0 ]; then
    if [ "${on_empty}" = allow-empty ]; then
      printf '%s: no tracked %s outside %s - nothing to grade in this repo.\n' \
        "${label}" "${spec}" "${_LINT_GATES_EXCLUDE[*]}"
      printf '  (safe here: this gate passes explicit paths, so an empty list\n'
      printf '   cannot fall back to grading ANTfrastructure OWN tree.)\n'
      return 2
    fi
    printf 'no tracked %s outside %s - the list driving this gate is empty;\n' \
      "${spec}" "${_LINT_GATES_EXCLUDE[*]}" >&2
    printf 'refusing to report green over nothing. (the underlying linter with\n' >&2
    printf 'zero file arguments falls back to ANTfrastructure OWN tree and passes.)\n' >&2
    return 1
  fi
  printf '%s scope (%d file(s)):\n' "${label}" "${#_LINT_GATES_SCOPE[@]}"
  printf '  %s\n' "${_LINT_GATES_SCOPE[@]}"
}

_lint_gates_shell() {
  _lint_gates_scope shellcheck '*.sh' || return 1
  bash "${_LINT_GATES_DIR}/lint-shell.sh" "${_LINT_GATES_SCOPE[@]}"
}

# Absolute paths: lint-python.sh cds to the hub root before resolving its arguments.
_lint_gates_python() {
  local rc=0
  _lint_gates_scope ruff '*.py' allow-empty || rc=$?
  # 2 = no python here, which is an answer; 1 = a real scope failure.
  [ "${rc}" -eq 2 ] && return 0
  [ "${rc}" -eq 0 ] || return "${rc}"
  local abs=() f
  for f in "${_LINT_GATES_SCOPE[@]}"; do abs+=("${_LINT_GATES_ROOT}/${f}"); done
  bash "${_LINT_GATES_DIR}/lint-python.sh" "${abs[@]}"
}

_lint_gates_workflows() {
  bash "${_LINT_GATES_DIR}/lint-workflows.sh" "${_LINT_GATES_ROOT}"
}

# Shared-config drift via the bash half (no hub Linux image ships pwsh); a missing manifest fails, never skips.
_lint_gates_shared_config() {
  _lint_gates_hub shared/config/sync-shared-config.sh || return 1
  local sync="${_LINT_GATES_HUB_FILE}"
  local manifest="${_LINT_GATES_ROOT}/.antfrastructure-shared.manifest"
  if [ ! -f "${manifest}" ]; then
    printf 'no .antfrastructure-shared.manifest at %s\n' "${_LINT_GATES_ROOT}" >&2
    printf 'This gate compares the ANTfrastructure-owned files this repo holds a COPY of, and\n' >&2
    printf 'it will not guess which those are: guessing is what made it unrunnable before.\n' >&2
    printf 'Declare them - one id per line, from the registry in\n' >&2
    printf '  third_party/ANTfrastructure/shared/config/shared-assets.manifest\n' >&2
    printf 'A repo that takes only the two bootstrap templates writes exactly:\n' >&2
    printf '  antfrastructure-sh\n  resolve-build-module\n' >&2
    printf 'An asset left out is never compared - that is how an intentional\n' >&2
    printf 'project-owned override is recorded. See shared/config/README.md.\n' >&2
    return 1
  fi
  bash "${sync}" --repo-root "${_LINT_GATES_ROOT}" --check
}

# Consumer pins: only a consumer lane sees hand-copied pins drift. See docs/code-quality-tooling.md#the-two-that-stay-frozen-with-better-reasons
_lint_gates_consumer_pins() {
  _lint_gates_hub docs/scripts/sync_versions.py || return 1
  _lint_gates_interpreter || return 1
  ${_LINT_GATES_PY} "${_LINT_GATES_HUB_FILE}" --consumer-pins --consumer-root "${_LINT_GATES_ROOT}"
}

# _LINT_GATES_PY is expanded unquoted: it may be a command line such as `uv run --no-project python`.
_lint_gates_interpreter() {
  preflight_python_require run-lint-gates.sh || return 1
  _LINT_GATES_PY="${PREFLIGHT_PYTHON}"
}

# Ratchets are opt-in: a tree without freeze files is red on its first run. See docs/code-quality-tooling.md#the-scan-root-contract
_LINT_GATES_RATCHET_GATES=(verify_stdout_returns verify_masked_assignments verify_trailing_conditional
  verify_comment_size verify_code_size verify_code_complexity verify_dead_functions verify_shellcheck_warnings)
# Freeze-free and shell-independent, so it also grades pure Dart and Python consumers.
_LINT_GATES_RATCHET_DOC_GATES=(docs/scripts/verify_doc_links.py)
# The caller decides an empty shell scope is allowed; exit 0 grade, 1 nothing to grade, 2 unusable root.
_lint_gates_ratchet_scope() {
  # shellcheck disable=SC2086  # a multi-word PREFLIGHT_PYTHON is a command line
  ${_LINT_GATES_PY} - "${_LINT_GATES_DIR}" "${_LINT_GATES_ROOT}" <<'RATCHETSCOPE'
import sys

sys.path.insert(0, sys.argv[1])
import gate_scope  # noqa: E402

ROOT = sys.argv[2]
try:
    RELS = gate_scope.tracked(ROOT, ["*.sh"])
except gate_scope.ScopeError as exc:
    sys.exit(gate_scope.die(exc))
sys.exit(0 if gate_scope.assert_non_empty(RELS, ROOT, ["*.sh"], "allow", "ratchets") else 1)
RATCHETSCOPE
}

_lint_gates_ratchet() {
  local gate rc=0
  _lint_gates_interpreter || return 1
  _lint_gates_ratchet_scope
  local shell_scope="$?"
  if [ "${shell_scope}" -eq 2 ]; then
    return 1
  fi
  for gate in "${_LINT_GATES_RATCHET_DOC_GATES[@]}"; do
    _lint_gates_hub "${gate}" || return 1
    printf '== %s --root %s ==\n' "${gate##*/}" "${_LINT_GATES_ROOT}"
    # shellcheck disable=SC2086  # a multi-word PREFLIGHT_PYTHON is a command line
    ${_LINT_GATES_PY} "${_LINT_GATES_HUB_FILE}" --root "${_LINT_GATES_ROOT}" || rc=1
  done
  if [ "${shell_scope}" -eq 1 ]; then
    return "${rc}"
  fi
  for gate in "${_LINT_GATES_RATCHET_GATES[@]}"; do
    _lint_gates_hub "linux/scripts/${gate}.py" || return 1
    printf '== %s --root %s ==\n' "${gate}" "${_LINT_GATES_ROOT}"
    # shellcheck disable=SC2086  # a multi-word PREFLIGHT_PYTHON is a command line
    ${_LINT_GATES_PY} "${_LINT_GATES_HUB_FILE}" --root "${_LINT_GATES_ROOT}" || rc=1
  done
  return "${rc}"
}

# Gitleaks skips vendored subtrees, which their own repositories grade, but keeps the files directly inside them.
_lint_gates_secret_scope() {
  local entry skip
  {
    while IFS= read -r -d '' entry; do
      printf '%s
' "${entry%%/*}"
    done < <(git -C "${_LINT_GATES_ROOT}" ls-files -z)
    for skip in "${_LINT_GATES_EXCLUDE[@]}"; do
      while IFS= read -r -d '' entry; do
        # Depth 2 exactly: a file the consumer owns inside a vendored directory.
        case "${entry}" in */*/*) ;; */*) printf '%s
' "${entry}" ;; esac
      done < <(git -C "${_LINT_GATES_ROOT}" ls-files -z -- "${skip}/*")
    done
  } | sort -u | while IFS= read -r entry; do
    # A depth-2 survivor is the consumer's own file inside a vendored directory.
    if _lint_gates_excluded "${entry}"; then
      [ -f "${_LINT_GATES_ROOT}/${entry}" ] || continue
    else
      for skip in "${_LINT_GATES_EXCLUDE[@]}"; do
        [ "${entry}" = "${skip}" ] && continue 2
      done
    fi
    printf '%s\n' "${entry}"
  done
}

# The consumer's own .gitleaks.toml wins: its allowlist carries its justifications.
_lint_gates_secret_config() {
  if [ -f "${_LINT_GATES_ROOT}/.gitleaks.toml" ]; then
    printf '%s\n' "${_LINT_GATES_ROOT}/.gitleaks.toml"
  fi
}

# Published, not returned: a non-zero exit alone would accept a gate that never started.
_LINT_GATES_SCAN_RC=0
_lint_gates_scan() {
  _LINT_GATES_SCAN_RC=0
  bash "${_LINT_GATES_DIR}/lint-secrets.sh" "$1" > "$2" 2>&1 || _LINT_GATES_SCAN_RC=$?
}

_lint_gates_selftest_fail() {
  local log="$1"
  shift
  cat "${log}" >&2
  printf 'secret-gate self-test FAILED: %s\n' "$*" >&2
  return 1
}

# (1) An empty tree must scan clean, before the canary, so a bootstrap failure cannot pass as detection.
_lint_gates_selftest_clean() {
  local dir="$1" log="$2"
  _lint_gates_scan "${dir}" "${log}"
  if [ "${_LINT_GATES_SCAN_RC}" -ne 0 ] || ! grep -qF 'secret scan: clean' "${log}"; then
    _lint_gates_selftest_fail "${log}" \
      "it could not complete a scan of an empty tree (exit ${_LINT_GATES_SCAN_RC}). gitleaks did not bootstrap or could not run, so every result below would be meaningless."
    return 1
  fi
  return 0
}

# (2) A planted PAT must be reported at the given path, proving the scan root was honoured.
_lint_gates_selftest_canary() {
  local dir="$1" log="$2" alnum tok file
  alnum='abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789'
  tok=""
  for _ in $(seq 1 36); do tok="${tok}${alnum:RANDOM%62:1}"; done
  # gitleaks runs from the scan root, so its fingerprint path is relative.
  local rel="planted-credential.txt"
  file="${dir}/${rel}"
  printf 'token = "ghp_%s"\n' "${tok}" > "${file}"
  _lint_gates_scan "${dir}" "${log}"
  if ! grep -qF "${rel}:github-pat:" "${log}"; then
    _lint_gates_selftest_fail "${log}" \
      "the planted GitHub token at ${file} was not reported (exit ${_LINT_GATES_SCAN_RC}). It scanned another tree, the rule is allowlisted away, or it never ran."
    return 1
  fi
  if [ "${_LINT_GATES_SCAN_RC}" -eq 0 ]; then
    _lint_gates_selftest_fail "${log}" \
      "the planted token was REPORTED and the gate still exited 0 - a finding is not fatal, so the real scan below could not fail on a real leak."
    return 1
  fi
  return 0
}

_lint_gates_secret_selftest() {
  local work rc=0
  work="$(mktemp -d)" || return 1
  mkdir -p "${work}/clean" "${work}/canary" || rc=1
  [ "${rc}" -eq 0 ] && { _lint_gates_selftest_clean "${work}/clean" "${work}/clean.log" || rc=1; }
  [ "${rc}" -eq 0 ] && { _lint_gates_selftest_canary "${work}/canary" "${work}/canary.log" || rc=1; }
  rm -rf "${work}"
  [ "${rc}" -eq 0 ] && printf 'self-test: the gate bootstraps, scans the path it is given, detects a planted credential and exits non-zero on it\n'
  return "${rc}"
}

_lint_gates_secrets() {
  local scope=() path config rc=0
  _lint_gates_secret_selftest || return 1
  mapfile -t scope < <(_lint_gates_secret_scope)
  if [ "${#scope[@]}" -eq 0 ]; then
    printf 'no tracked first-party paths - the list driving this gate is empty;\n' >&2
    printf 'refusing to report green over nothing.\n' >&2
    return 1
  fi
  config="$(_lint_gates_secret_config)"
  printf 'secret-scan scope (%d path(s)):\n' "${#scope[@]}"
  printf '  %s\n' "${scope[@]}"
  # One invocation per path: lint-secrets.sh grades its FIRST argument only.
  for path in "${scope[@]}"; do
    bash "${_LINT_GATES_DIR}/lint-secrets.sh" "${_LINT_GATES_ROOT}/${path}" ${config:+"${config}"} || rc=1
  done
  return "${rc}"
}

_lint_gates_main() {
  _lint_gates_parse_args "$@"
  cd "${_LINT_GATES_ROOT}" || _lint_gates_die "cannot enter ${_LINT_GATES_ROOT}"
  printf 'lint gates over %s (excluding: %s)\n' "${_LINT_GATES_ROOT}" "${_LINT_GATES_EXCLUDE[*]}"
  gate_reset "LINT GATES"
  run_gate "shellcheck" _lint_gates_shell
  run_gate "actionlint + CI image refs" _lint_gates_workflows
  run_gate "gitleaks" _lint_gates_secrets
  run_gate "ruff" _lint_gates_python
  run_gate "shared-config drift" _lint_gates_shared_config
  run_gate "consumer pins" _lint_gates_consumer_pins
  if [ "${_LINT_GATES_RATCHETS}" -eq 1 ]; then
    run_gate "ratchets" _lint_gates_ratchet
  fi
  assert_gates
}

# Sourceable, so test-lint-gates.sh can drive the scope construction without network.
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  _lint_gates_main "$@"
fi
