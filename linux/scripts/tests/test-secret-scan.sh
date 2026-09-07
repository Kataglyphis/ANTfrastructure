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

# _abs <dir>: the path the gate itself will print, so an assertion compares the
# same spelling (mktemp roots are symlinked on some hosts).
_abs() { ( cd "$1" && pwd ); }

# _from <dir> <args...>: run the gate WITH <dir> as the working directory. That
# is how a consumer calls it -- third_party/ContainerHub/linux/scripts/lint-secrets.sh .
# from its own root -- and a relative argument only means the right tree if the
# gate resolves it before it cd's into the hub checkout.
_from() { local d="$1"; shift; ( cd "${d}" && bash "${GATE}" "$@" ); }

# _own_config <dir>: give <dir> a .gitleaks.toml of its OWN. It does not extend
# the default rule set and its single rule matches nothing, so under this config
# the planted credential is not a finding -- a run that still reports the leak is
# a run that read the hub's config instead of the scanned tree's.
_own_config() {
  cat > "$1/.gitleaks.toml" <<'TOML'
title = "consumer fixture"

[[rules]]
id = "fixture-matches-nothing"
description = "proves the SCANNED tree's config is the one in force"
regex = 'zzzz-no-such-token-zzzz'
TOML
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
# The pin is read FROM versions.env, exactly as lint-secrets.sh's NOTE for test
# authors says: the gate holds no literal to grep for (its only GITLEAKS_PIN
# assignment is indented and interpolated from load_versions_env). Grepping the
# gate for one yielded an EMPTY ${_pin}, and the assertion below then degenerated
# into a search for "gitleaks " -- which the banner always prints, so the case
# passed no matter what version ran. The non-empty guard is what stops that
# failure mode from returning silently.
_versions_env="${TESTS_DIR}/../01-core/versions.env"
_pin="$(sed -n 's/^GITLEAKS_VERSION=//p' "${_versions_env}")"
t_assert_ok test -n "${_pin}"
t_assert_contains "$(t_out bash "${GATE}" "${clean}")" "gitleaks ${_pin}" \
  "a scan verdict nobody can reproduce is not a gate"

t_case "a RELATIVE scan root is resolved against the CALLER's cwd, not the hub"
# The shipped bug: `cd "${REPO_ROOT}"` ran BEFORE SCAN_ROOT="${1:-.}", so the
# consumer's own `... lint-secrets.sh .` re-anchored on the hub checkout. The hub
# is clean, so the consumer's leak passed the gate that was supposed to find it.
rel_leaky="$(_dir leaky)"
rel_leaky_abs="$(_abs "${rel_leaky}")"
t_assert_eq "1" "$(t_rc _from "${rel_leaky}" .)" \
  "'.' must mean the caller's tree; the hub checkout is clean and would pass"
_rel_out="$(t_out _from "${rel_leaky}" .)"
t_assert_contains "${_rel_out}" "scan root: ${rel_leaky_abs}" \
  "the resolved root is printed, so a wrong tree is visible in the log"
t_assert_contains "${_rel_out}" "deploy.env" "and the consumer's own file is what was graded"

t_case "a relative scan root that does not exist is refused, not silently reinterpreted"
t_assert_eq "1" "$(t_rc _from "${rel_leaky}" no-such-subdir)"
t_assert_contains "$(t_out _from "${rel_leaky}" no-such-subdir)" "scan root not found" \
  "an unresolvable argument must not fall back to scanning the hub"

t_case "the scanned tree's own .gitleaks.toml wins over the hub's"
# A consumer's allowlist entries are written about ITS false positives; the hub's
# say nothing about them. Grading a consumer tree by the hub config is the same
# category of error as scanning the wrong tree.
consumer="$(_dir leaky)"
_own_config "${consumer}"
consumer_abs="$(_abs "${consumer}")"
t_assert_contains "$(t_out bash "${GATE}" "${consumer}")" "config:    ${consumer_abs}/.gitleaks.toml" \
  "the config actually in force is printed"
t_assert_eq "0" "$(t_rc bash "${GATE}" "${consumer}")" \
  "graded by ITS rules the planted credential is no finding; a red here means the hub config was used"

t_case "a tree WITHOUT a .gitleaks.toml is graded by the hub's"
# The fallback is what grades every consumer that ships no config of its own;
# losing it leaves those trees ungraded.
_hub_root="$(_abs "${TESTS_DIR}/../../..")"
t_assert_contains "$(t_out bash "${GATE}" "${leaky}")" "config:    ${_hub_root}/.gitleaks.toml" \
  "no config in the scanned tree means the hub's, by absolute path"
t_assert_eq "1" "$(t_rc bash "${GATE}" "${leaky}")" \
  "the same leaky tree, minus its own permissive config, is a finding"

# No case scans the real tree: the whole-repo run is the `secret-scan` preflight
# slug's own job, and paying for it again here would cost this suite minutes.

t_summary
