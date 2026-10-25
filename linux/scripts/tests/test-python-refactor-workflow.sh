#!/usr/bin/env bash
# The dispatch lane is checked statically; this suite does not execute GitHub Actions.
set -u
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=linux/scripts/tests/workflow-lane-fixture.sh
source "${TESTS_DIR}/workflow-lane-fixture.sh"
_PY="${PREFLIGHT_PYTHON:-python3}"
workflow_lane_fixture_init .github/workflows/python-refactor.yml patch patch "${_PY}" || exit 1

_query_true() {
  [ "$(_q "$1")" = True ] || return 1
  return 0
}

_dispatch_readonly() {
  _query_true 'list(V.value(lane,"on")) == ["workflow_dispatch"] and V.value(V.value(lane,"permissions"),"contents") == "read" and len(V.value(lane,"permissions")) == 1 and all(V.value(j,"permissions") is None for j,_ in V.value(lane,"jobs").values())' || return 1
  _query_true 'V.value(V.value(V.value(V.value(lane,"on"),"workflow_dispatch"),"inputs"),"path") is not None and V.value(V.value(V.value(V.value(V.value(lane,"on"),"workflow_dispatch"),"inputs"),"path"),"required") == "true" and V.value(V.value(V.value(V.value(V.value(lane,"on"),"workflow_dispatch"),"inputs"),"path"),"type") == "string"' || return 1
  return 0
}

_credentialless_checkout() {
  _query_true 'any(re.fullmatch(r"actions/checkout@[0-9a-f]{40}",V.value(s,"uses") or "") and V.value(V.value(s,"with"),"persist-credentials") == "false" for s in steps)' || return 1
  return 0
}

_locked_quality_sync() {
  _query_true 'any(re.fullmatch(r"astral-sh/setup-uv@[0-9a-f]{40}",V.value(s,"uses") or "") for s in steps) and any(V.value(s,"name") == "Sync locked quality environment" and V.value(s,"run") == "uv sync --project quality --locked --python 3.14" for s in steps)' || return 1
  return 0
}

_runner_test_deps() {
  _query_true 'V.value(V.value(job,"env"),"PREFLIGHT_PYTHON") is None and not re.search(r"quality/\.venv/bin[^\n]*GITHUB_PATH",raw) and any(V.value(s,"name") == "Install runner test dependencies" and V.value(s,"run") == "pip install --quiet pytest pyyaml" for s in steps)' || return 1
  return 0
}

_safe_refactor_path() {
  _query_true 'V.value(V.value(job,"env"),"REFACTOR_PATH") == "${{ inputs.path }}" and any(V.value(s,"name") == "Apply pinned safe Ruff edits" and V.value(s,"run") == "bash linux/scripts/refactor-python.sh --apply -- \"$REFACTOR_PATH\"" for s in steps)' || return 1
  return 0
}

_quality_gates() {
  _query_true 'any(V.value(s,"name") == "Verify mutation recipes still match" and V.value(s,"run") == "python3 docs/scripts/verify_mutations.py --stale-check" for s in steps) and any(V.value(s,"name") == "Run affected quality gates" and V.value(s,"run") == "PREFLIGHT_ONLY=python-lint,python-types,code-dupes,code-size,code-complexity,comment-size,script-tests bash linux/scripts/preflight.sh" for s in steps)' || return 1
  return 0
}

_patch_artifact() {
  _query_true 'any(V.value(s,"name") == "Save proposed patch" and V.value(s,"if") == "always()" for s in steps) and "mkdir -p logs/code-quality/python-refactor" in run_blocks("patch") and "git diff --binary > logs/code-quality/python-refactor/proposed.patch" in run_blocks("patch") and "git diff --check" in run_blocks("patch") and any(V.value(s,"name") == "Upload proposed patch and logs" and V.value(s,"if") == "always()" and re.fullmatch(r"actions/upload-artifact@[0-9a-f]{40}",V.value(s,"uses") or "") and V.value(V.value(s,"with"),"path") == "logs/code-quality/python-refactor*/" and V.value(V.value(s,"with"),"if-no-files-found") == "error" for s in steps)' || return 1
  return 0
}

_no_publish_step() {
  _query_true 'not re.search(r"(?i)(?:\bgit\s+push\b|\bgh\s+pr\s+(?:create|merge|review)\b|\bgh\s+release\s+create\b|\bdocker\s+push\b|\buv\s+publish\b|\btwine\s+upload\b|create-pull-request@|\bcontents:\s*write\b|\bpull-requests:\s*write\b)",raw)' || return 1
  return 0
}

_contract() {
  _dispatch_readonly || return 1
  _credentialless_checkout || return 1
  _locked_quality_sync || return 1
  _runner_test_deps || return 1
  _safe_refactor_path || return 1
  _quality_gates || return 1
  _patch_artifact || return 1
  _no_publish_step || return 1
  return 0
}

_mutated_contract() { LANE="$1" _contract; }

t_case "the lane runs only on manual dispatch with a required path and read-only token"
t_assert_ok test -f "${LANE}"
t_assert_ok _dispatch_readonly
t_assert_ok _no_publish_step

t_case "checkout and dependency resolution cannot use write credentials or an unlocked environment"
t_assert_ok _credentialless_checkout
t_assert_ok _locked_quality_sync
t_assert_ok _runner_test_deps

t_case "the input reaches only the safe refactor script as a quoted argument"
t_assert_ok _safe_refactor_path

t_case "mutation recipes and affected quality gates run before the patch is uploaded"
t_assert_ok _quality_gates
t_assert_ok _patch_artifact

# Mutated workflow copies must make the contract fail without executing their jobs.
mkdir -p "${ROOT}/logs/code-quality" || exit 1
_work="$(mktemp -d "${ROOT}/logs/code-quality/python-refactor-workflow-test.XXXXXX")" || exit 1
trap 'rm -rf -- "${_work}"' EXIT

t_case "a checkout that persists credentials is rejected"
_bad="${_work}/checkout-credentials.yml"
sed 's/persist-credentials: false/persist-credentials: true/' "${LANE}" > "${_bad}"
t_assert_fails cmp -s "${LANE}" "${_bad}"
t_assert_fails _mutated_contract "${_bad}"

t_case "an unlocked quality sync is rejected"
_bad="${_work}/unlocked-sync.yml"
sed 's/uv sync --project quality --locked --python 3.14/uv sync --project quality --python 3.14/' "${LANE}" > "${_bad}"
t_assert_fails cmp -s "${LANE}" "${_bad}"
t_assert_fails _mutated_contract "${_bad}"

t_case "a patch artifact that runs only on success is rejected"
_bad="${_work}/artifact-success-only.yml"
sed 's/if: always()/if: success()/g' "${LANE}" > "${_bad}"
t_assert_fails cmp -s "${LANE}" "${_bad}"
t_assert_fails _mutated_contract "${_bad}"

t_case "an added push step is rejected"
_bad="${_work}/push-step.yml"
cp "${LANE}" "${_bad}"
printf '\n      - run: git push origin develop\n' >> "${_bad}"
t_assert_fails _mutated_contract "${_bad}"

t_case "a quality venv PATH override is rejected"
_bad="${_work}/venv-path.yml"
cp "${LANE}" "${_bad}"
printf '\n      - run: echo "$GITHUB_WORKSPACE/quality/.venv/bin" >> "$GITHUB_PATH"\n' >> "${_bad}"
t_assert_fails _mutated_contract "${_bad}"

t_summary
