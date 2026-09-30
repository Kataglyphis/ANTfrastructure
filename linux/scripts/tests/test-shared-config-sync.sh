#!/usr/bin/env bash
# sync-shared-config.sh must agree with its twin Sync-SharedConfig.ps1 on verdicts, exit codes and both modes.
set -u
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${TESTS_DIR}/test-harness.sh"
HUB="$(cd "${TESTS_DIR}/../../.." && pwd)"
SYNC="${HUB}/shared/config/sync-shared-config.sh"
CANON_EXACT="${HUB}/shared/config/.clang-format"
CANON_BODY="${HUB}/shared/linux/templates/antfrastructure.sh"

_work="$(mktemp -d)"
trap 'rm -rf "${_work}"' EXIT

# A faithful consumer with one 'exact' and one 'body' asset; each case breaks one thing.
_consumer() {
  local d
  d="$(mktemp -d "${_work}/consumer.XXXXXX")"
  mkdir -p "${d}/scripts/linux/lib"
  cp "${CANON_EXACT}" "${d}/.clang-format"
  cp "${CANON_BODY}" "${d}/scripts/linux/lib/antfrastructure.sh"
  printf '# what this repo takes from ANTfrastructure\nclang-format\nantfrastructure-sh\n' \
    > "${d}/.antfrastructure-shared.manifest"
  printf '%s' "${d}"
}

OUT=""; rc=0
_check() { OUT="$(bash "${SYNC}" --repo-root "$1" --check 2>&1)"; rc=$?; }

# Replaces the leading comment/blank lines with the consumer's own header prose.
_reheader() {
  local f="$1" tmp
  tmp="$(mktemp "${_work}/reheader.XXXXXX")"
  {
    printf '#!/usr/bin/env bash\n# This consumer wrote its own header prose.\n\n'
    awk 'started || (!/^[[:space:]]*#/ && NF) { started = 1; print }' "${f}"
  } > "${tmp}"
  mv "${tmp}" "${f}"
}

t_case "a faithful consumer is in sync (exit 0), and says so"
_d="$(_consumer)"; _check "${_d}"
t_assert_eq "0" "${rc}" "a correct copy of both assets must pass; output was: ${OUT}"
t_assert_contains "${OUT}" "Shared config in sync." \
  "the pass must be the script's verdict, not silence"

t_case "an 'exact' asset is byte for byte: even an added HEADER COMMENT is DRIFTED"
# 'body' mode would forgive this, so it also pins .clang-format's manifest row as exact.
_d="$(_consumer)"
_tmp_clang="$(mktemp "${_work}/clang.XXXXXX")"
{ printf '# a comment this consumer added\n'; cat "${_d}/.clang-format"; } > "${_tmp_clang}"
mv "${_tmp_clang}" "${_d}/.clang-format"
_check "${_d}"
t_assert_eq "1" "${rc}" "printing is not enough; drift must decide the exit code"
t_assert_contains "${OUT}" "DRIFTED .clang-format" "the offender must be named"
t_assert_contains "${OUT}" "Edit the file UPSTREAM" "the report must name the fix"

t_case "a declared copy that is not there is MISSING, not skipped"
_d="$(_consumer)"
rm "${_d}/.clang-format"
_check "${_d}"
t_assert_eq "1" "${rc}" "a declared asset that vanished must fail, not pass quietly"
t_assert_contains "${OUT}" "MISSING .clang-format"

t_case "line endings alone are not drift (the same content with CRLF passes)"
# The canonical file is LF, so the fixture must add the CRs or the case proves nothing.
_d="$(_consumer)"
sed -i 's/$/\r/' "${_d}/.clang-format"
t_assert_ok grep -q -e $'\r' "${_d}/.clang-format"
_check "${_d}"
t_assert_eq "0" "${rc}" \
  "line endings are normalised on both sides before comparing; output was: ${OUT}"

t_case "'body' mode: the consumer's own header prose is a legitimate delta"
_d="$(_consumer)"
_reheader "${_d}/scripts/linux/lib/antfrastructure.sh"
_check "${_d}"
t_assert_eq "0" "${rc}" \
  "body mode compares from the first CODE line down; output was: ${OUT}"

t_case "'body' mode: a declared knob may carry any VALUE"
_d="$(_consumer)"
sed -i 's|KATAGLYPHIS_REPO_ROOT_RELATIVE:=\.\./\.\./\.\.|KATAGLYPHIS_REPO_ROOT_RELATIVE:=../..|' \
  "${_d}/scripts/linux/lib/antfrastructure.sh"
_check "${_d}"
t_assert_eq "0" "${rc}" \
  "the knob is the one line a consumer is expected to adjust; output was: ${OUT}"

t_case "'body' mode forgives the header and the knobs, and NOTHING else"
_d="$(_consumer)"
_reheader "${_d}/scripts/linux/lib/antfrastructure.sh"
printf 'export ANTFRASTRUCTURE_EXTRA=1\n' >> "${_d}/scripts/linux/lib/antfrastructure.sh"
_check "${_d}"
t_assert_eq "1" "${rc}" "an edited code line is drift even under a rewritten header"
t_assert_contains "${OUT}" "DRIFTED scripts/linux/lib/antfrastructure.sh"

t_case "an id ANTfrastructure does not own is broken INPUT (2), not a finding"
_d="$(_consumer)"
printf 'not-an-asset\n' >> "${_d}/.antfrastructure-shared.manifest"
_check "${_d}"
t_assert_eq "2" "${rc}" "2 separates 'your manifest is wrong' from 'your copies drifted'"
t_assert_contains "${OUT}" "which ANTfrastructure does not own"
t_assert_contains "${OUT}" "Known ids:" "the message must list what it could have meant"

t_case "--ignore and a manifest cannot be combined"
_d="$(_consumer)"
OUT="$(bash "${SYNC}" --repo-root "${_d}" --check --ignore .clang-format 2>&1)"; rc=$?
t_assert_eq "2" "${rc}" \
  "a stale --ignore silently overriding a declaration is the drift this refuses"
t_assert_contains "${OUT}" "cannot be combined"

t_case "--write refuses a body-mode asset instead of clobbering the header"
# It has to be DRIFTED first: --write only touches what --check would report.
_d="$(_consumer)"
_reheader "${_d}/scripts/linux/lib/antfrastructure.sh"
printf 'export ANTFRASTRUCTURE_EXTRA=1\n' >> "${_d}/scripts/linux/lib/antfrastructure.sh"
OUT="$(bash "${SYNC}" --repo-root "${_d}" --write 2>&1)"; rc=$?
t_assert_eq "2" "${rc}" "a verbatim copy would delete the consumer's header and knob values"
t_assert_contains "${OUT}" "body-mode"

t_case "no --repo-root at all is refused; the root is never guessed"
OUT="$(bash "${SYNC}" --check 2>&1)"; rc=$?
t_assert_eq "2" "${rc}" "a guessed root grades the wrong tree, which is how this gate reports green"
t_assert_contains "${OUT}" "Missing --repo-root"

t_case "without a manifest the legacy --ignore list still works, and SKIPs are named"
_d="$(mktemp -d "${_work}/legacy.XXXXXX")"
cp "${CANON_EXACT}" "${_d}/.clang-format"
OUT="$(bash "${SYNC}" --repo-root "${_d}" --check \
  --ignore .clang-tidy,.cmake-format.yaml,gcovr.cfg,.pre-commit-config.yaml 2>&1)"; rc=$?
t_assert_eq "0" "${rc}" "the four ignored names have no copy here; output was: ${OUT}"
t_assert_contains "${OUT}" "no consumer manifest"
t_assert_contains "${OUT}" "SKIP  .clang-tidy (project-owned override)" \
  "an ignored file must be a NAMED skip, not a silent one"

t_case "--ignore naming something the script does not manage is refused"
_d="$(mktemp -d "${_work}/legacy2.XXXXXX")"
OUT="$(bash "${SYNC}" --repo-root "${_d}" --check --ignore .not-managed 2>&1)"; rc=$?
t_assert_eq "2" "${rc}" "a typo'd ignore name would silently protect nothing"
t_assert_contains "${OUT}" "names nothing this script manages"

t_summary
