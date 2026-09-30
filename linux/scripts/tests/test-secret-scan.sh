#!/usr/bin/env bash
# lint-secrets.sh against the real gitleaks; see docs/code-quality-tooling.md#secret-scan-secret-scan
set -u
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${TESTS_DIR}/test-harness.sh"
GATE="${TESTS_DIR}/../lint-secrets.sh"

_work="$(mktemp -d)"
trap 'rm -rf "${_work}"' EXIT

# Assembled at run time: this repo's own secret scan would flag a tracked literal.
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

# _abs <dir>: the gate's own spelling, since mktemp roots are symlinked on some hosts.
_abs() { ( cd "$1" && pwd ); }

# _from <dir> <args...>: run from <dir>, as a consumer does, so relative args must resolve before the gate cd's.
_from() { local d="$1"; shift; ( cd "${d}" && bash "${GATE}" "$@" ); }

# _own_config <dir>: a config matching nothing, so a reported leak means the hub's config was read.
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
# --verbose is what makes a failure diagnosable from a CI log.
t_assert_contains "${_out}" "deploy.env" "the reader must be able to find the leak"
t_assert_contains "${_out}" "Line:" "and the line it is on"
t_assert_contains "${_out}" "RuleID:"

t_case "the value itself is REDACTED, so the log does not become the leak"
t_assert_eq "0" "$(printf '%s' "${_out}" | grep -c -F -e "${_SECRET}")" \
  "dropping --redact copies the credential into every CI log that ran the gate"
t_assert_contains "${_out}" "REDACTED"

t_case "the scan is scoped to the path it was handed"
# Otherwise the tree the script sits in is graded instead.
t_assert_eq "0" "$(t_rc bash "${GATE}" "${clean}")" "the leaky sibling directory must not be scanned"
t_assert_eq "0" "$(t_out bash "${GATE}" "${clean}" | grep -c -F -e "$(basename "${leaky}")")"

t_case "the pinned gitleaks version is the one it reports running"
# The gate holds no pin literal, so read versions.env; an empty pin would match any "gitleaks " banner.
_versions_env="${TESTS_DIR}/../01-core/versions.env"
_pin="$(sed -n 's/^GITLEAKS_VERSION=//p' "${_versions_env}")"
t_assert_ok test -n "${_pin}"
t_assert_contains "$(t_out bash "${GATE}" "${clean}")" "gitleaks ${_pin}" \
  "a scan verdict nobody can reproduce is not a gate"

t_case "a RELATIVE scan root is resolved against the CALLER's cwd, not the hub"
# Resolved after the gate's cd, a consumer's `.` would mean the clean hub checkout.
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
# A consumer's allowlist covers its own false positives, which the hub's config knows nothing about.
consumer="$(_dir leaky)"
_own_config "${consumer}"
consumer_abs="$(_abs "${consumer}")"
t_assert_contains "$(t_out bash "${GATE}" "${consumer}")" "config:    ${consumer_abs}/.gitleaks.toml" \
  "the config actually in force is printed"
t_assert_eq "0" "$(t_rc bash "${GATE}" "${consumer}")" \
  "graded by ITS rules the planted credential is no finding; a red here means the hub config was used"

t_case "a tree WITHOUT a .gitleaks.toml is graded by the hub's"
# Without the fallback, consumers that ship no config go ungraded.
_hub_root="$(_abs "${TESTS_DIR}/../../..")"
t_assert_contains "$(t_out bash "${GATE}" "${leaky}")" "config:    ${_hub_root}/.gitleaks.toml" \
  "no config in the scanned tree means the hub's, by absolute path"
t_assert_eq "1" "$(t_rc bash "${GATE}" "${leaky}")" \
  "the same leaky tree, minus its own permissive config, is a finding"

# The real tree is scanned by the `secret-scan` preflight slug, not here.

t_summary
