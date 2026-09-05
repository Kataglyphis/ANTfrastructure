#!/usr/bin/env bash
# Tests for lint-secrets.sh, driven against the real gitleaks. Three things this
# gate has to get right and one it must not: it FAILS on a leak, it names the
# file:line (this gate once reported "2 leaks" and named neither), it REDACTS the
# value so the CI log does not become the leak, and it scans the path it was
# handed rather than whatever tree it happens to sit in.
# docs/code-quality-tooling.md#secret-scan-secret-scan
set -u
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${TESTS_DIR}/test-harness.sh"
GATE="${TESTS_DIR}/../lint-secrets.sh"

_work="$(mktemp -d)"
trap 'rm -rf "${_work}"' EXIT

# A synthetic credential, assembled at run time so the literal is not a string in
# a tracked file -- this repo runs a secret scanner over its own tree.
_SECRET="ghp_$(printf '016C7869F3B69A0B9E2F84F0EE'; printf '1234567890AB')"

# _dir <clean|leaky>: a throwaway scan root.
_dir() {
  local d; d="$(mktemp -d "${_work}/scan.XXXXXX")"
  if [ "$1" = leaky ]; then
    printf 'GITHUB_TOKEN=%s\n' "${_SECRET}" > "${d}/deploy.env"
  else
    printf 'GITHUB_TOKEN=${{ secrets.GITHUB_TOKEN }}\n' > "${d}/deploy.env"
  fi
  printf '%s' "${d}"
}

t_case "a clean directory passes"
clean="$(_dir clean)"
t_assert_eq "0" "$(t_rc bash "${GATE}" "${clean}")" \
  "the gate must be able to be green, or the red below proves only that it is broken"
t_assert_contains "$(t_out bash "${GATE}" "${clean}")" "secret scan: clean"

t_case "a planted credential FAILS the gate"
leaky="$(_dir leaky)"
_out="$(t_out bash "${GATE}" "${leaky}")"
t_assert_eq "1" "$(t_rc bash "${GATE}" "${leaky}")" "a scanner that reports and exits 0 gates nothing"
t_assert_contains "${_out}" "gitleaks found potential secrets"

t_case "the finding names the file and the line, not just a count"
# The gate failed on main once with a summary that said 2 leaks and named
# neither; --verbose is what makes the failure diagnosable from a CI log.
t_assert_contains "${_out}" "deploy.env" "the reader must be able to find the leak"
t_assert_contains "${_out}" "Line:" "and the line it is on"
t_assert_contains "${_out}" "RuleID:"

t_case "the value itself is REDACTED, so the log does not become the leak"
t_assert_eq "0" "$(printf '%s' "${_out}" | grep -c -F -e "${_SECRET}")" \
  "dropping --redact copies the credential into every CI log that ran the gate"
t_assert_contains "${_out}" "REDACTED"

t_case "the scan is scoped to the path it was handed"
# Without the argument reaching gitleaks, a clean sub-checkout would still be
# graded by whatever tree the script sits in -- green or red for the wrong reason.
t_assert_eq "0" "$(t_rc bash "${GATE}" "${clean}")" "the leaky sibling directory must not be scanned"
t_assert_eq "0" "$(t_out bash "${GATE}" "${clean}" | grep -c -F -e "$(basename "${leaky}")")"

t_case "the pinned gitleaks version is the one it reports running"
_pin="$(sed -n 's/^GITLEAKS_PIN="\([^"]*\)".*/\1/p' "${GATE}")"
t_assert_contains "$(t_out bash "${GATE}" "${clean}")" "gitleaks ${_pin}" \
  "a scan verdict nobody can reproduce is not a gate"

# No case scans the real tree: the whole-repo run is the `secret-scan` preflight
# slug's own job, and paying for it again here would cost this suite minutes.

t_summary
