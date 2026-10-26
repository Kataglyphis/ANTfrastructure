#!/usr/bin/env bash
# Step-label gate: every chain RUN names its layer; see docs/code-quality-tooling.md#step-labels-dockerfile-lint
set -u
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=linux/scripts/tests/test-workspace-fixture.sh
source "${TESTS_DIR}/test-workspace-fixture.sh"
declare REPO_ROOT
t_fixture_workspace_init '' REPO_ROOT
GATE="${REPO_ROOT}/linux/scripts/verify_dockerfile_step_labels.py"
LINTER="${REPO_ROOT}/linux/scripts/lint-dockerfiles.sh"
PY="${PREFLIGHT_PYTHON:-python3}"
_work="$(mktemp -d)"; trap 'rm -rf "${_work}"' EXIT

_check() { printf '%s\n' "$1" > "${_work}/Dockerfile.fix"; t_out "${PY}" "${GATE}" "${_work}/Dockerfile.fix"; }
_rc() { printf '%s\n' "$1" > "${_work}/Dockerfile.fix"; t_rc "${PY}" "${GATE}" "${_work}/Dockerfile.fix"; }

t_case "a labelled RUN passes, with an ARG and a comment between label and RUN"
good=$'FROM scratch\nLABEL kataglyphis.step=one\nARG X=1\n# why\nRUN true\nCOPY a /a\nLABEL kataglyphis.step=two\nRUN true'
t_assert_eq 0 "$(_rc "${good}")"
t_assert_contains "$(_check "${good}")" "ok: every RUN names its step"

t_case "a RUN without its own label fails, even when an earlier RUN had one"
t_assert_eq 1 "$(_rc $'FROM scratch\nRUN true')"
out="$(_check $'FROM scratch\nLABEL kataglyphis.step=one\nRUN true\nRUN false')"
t_assert_contains "${out}" "Dockerfile.fix:4: RUN has no LABEL kataglyphis.step=<name>"

t_case "a label followed by a COPY names the COPY's layer, so it fails"
out="$(_check $'FROM scratch\nLABEL kataglyphis.step=one\nCOPY a /a\nRUN true')"
t_assert_contains "${out}" "step label 'one' is followed by COPY, not by its RUN"
t_assert_contains "$(_check $'FROM scratch AS a\nLABEL kataglyphis.step=one\nFROM scratch\nRUN true')" "is followed by FROM"

t_case "a repeated or malformed name fails"
t_assert_contains "$(_check $'FROM scratch\nLABEL kataglyphis.step=one\nRUN true\nLABEL kataglyphis.step=one\nRUN true')" "step name 'one' is already used on line 2"
t_assert_contains "$(_check $'FROM scratch\nLABEL kataglyphis.step=One_Step\nRUN true')" "step name 'One_Step' is not lowercase kebab-case"

t_case "a heredoc body is not read as instructions"
here=$'FROM scratch\nLABEL kataglyphis.step=wrapper\nRUN cat > /w <<\'EOF\' && chmod +x /w\nRUN inside the heredoc\nEOF\nLABEL kataglyphis.step=after\nRUN true'
t_assert_eq 0 "$(_rc "${here}")"

t_case "usage and a missing file are failures, not passes"
t_assert_eq 2 "$(t_rc "${PY}" "${GATE}")"
t_assert_eq 1 "$(t_rc "${PY}" "${GATE}" "${_work}/absent")"

t_case "every chain Dockerfile passes, and lint-dockerfiles.sh runs the gate on them"
chain=()
for df in "${REPO_ROOT}"/linux/Dockerfile.*; do chain+=("${df}"); done
t_assert_ok "${PY}" "${GATE}" "${chain[@]}"
t_assert_ok grep -qF 'python3 linux/scripts/verify_dockerfile_step_labels.py "${CHAIN_DOCKERFILES[@]}" || FAILED=1' "${LINTER}"
t_assert_ok grep -qF 'linux/Dockerfile.*|*/linux/Dockerfile.*) CHAIN_DOCKERFILES+=("${df}")' "${LINTER}"

t_summary
