#!/usr/bin/env bash
# Tests for shared/config/sync-shared-config.sh -- the BASH twin of
# Sync-SharedConfig.ps1, and the only one of the two that runs on a hub Linux
# image (none ship pwsh). Nothing exercised it: test-shared-config.sh drives the
# preflight gate, which shells out to the PowerShell half and cannot start on a
# Linux runner at all. Pinned here is what the two must agree on, since a gate
# passing under one and failing under the other is the failure mode: the three
# verdicts, the exit codes (0 / 1 / 2 for broken input), and the two comparison
# modes -- exact is byte for byte, body forgives the header prose and the
# declared knob VALUES and nothing else.
set -u
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${TESTS_DIR}/test-harness.sh"
HUB="$(cd "${TESTS_DIR}/../../.." && pwd)"
SYNC="${HUB}/shared/config/sync-shared-config.sh"
CANON_EXACT="${HUB}/shared/config/.clang-format"
CANON_BODY="${HUB}/shared/linux/templates/containerhub.sh"

_work="$(mktemp -d)"
trap 'rm -rf "${_work}"' EXIT

# A consumer checkout declaring one 'exact' asset and one 'body' asset, each
# holding a faithful copy. Every case below breaks exactly one thing about it.
_consumer() {
  local d
  d="$(mktemp -d "${_work}/consumer.XXXXXX")"
  mkdir -p "${d}/scripts/linux/lib"
  cp "${CANON_EXACT}" "${d}/.clang-format"
  cp "${CANON_BODY}" "${d}/scripts/linux/lib/containerhub.sh"
  printf '# what this repo takes from ContainerHub\nclang-format\ncontainerhub-sh\n' \
    > "${d}/.containerhub-shared.manifest"
  printf '%s' "${d}"
}

OUT=""; rc=0
_check() { OUT="$(bash "${SYNC}" --repo-root "$1" --check 2>&1)"; rc=$?; }

# Everything from the first line that is neither blank nor a comment: the
# consumer's own header prose replaces the template's.
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
# A leading comment is exactly what 'body' mode forgives, so this also pins the
# manifest row: .clang-format is declared exact, and must be graded that way.
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
# A Windows checkout holds the same content with CRLF and must not read as
# drifted. The fixture has to CREATE that difference: the canonical
# .clang-format is plain LF here (0 CR bytes), so the old `sed 's/\r$//'` was a
# no-op on a file that had none and the assertion passed with the normalisation
# removed -- the mutation over it survived, invisibly.
_d="$(_consumer)"
sed -i 's/$/\r/' "${_d}/.clang-format"
t_assert_ok grep -q -e $'\r' "${_d}/.clang-format"
_check "${_d}"
t_assert_eq "0" "${rc}" \
  "line endings are normalised on both sides before comparing; output was: ${OUT}"

t_case "'body' mode: the consumer's own header prose is a legitimate delta"
_d="$(_consumer)"
_reheader "${_d}/scripts/linux/lib/containerhub.sh"
_check "${_d}"
t_assert_eq "0" "${rc}" \
  "body mode compares from the first CODE line down; output was: ${OUT}"

t_case "'body' mode: a declared knob may carry any VALUE"
_d="$(_consumer)"
sed -i 's|KATAGLYPHIS_REPO_ROOT_RELATIVE:=\.\./\.\./\.\.|KATAGLYPHIS_REPO_ROOT_RELATIVE:=../..|' \
  "${_d}/scripts/linux/lib/containerhub.sh"
_check "${_d}"
t_assert_eq "0" "${rc}" \
  "the knob is the one line a consumer is expected to adjust; output was: ${OUT}"

t_case "'body' mode forgives the header and the knobs, and NOTHING else"
_d="$(_consumer)"
_reheader "${_d}/scripts/linux/lib/containerhub.sh"
printf 'export CONTAINERHUB_EXTRA=1\n' >> "${_d}/scripts/linux/lib/containerhub.sh"
_check "${_d}"
t_assert_eq "1" "${rc}" "an edited code line is drift even under a rewritten header"
t_assert_contains "${OUT}" "DRIFTED scripts/linux/lib/containerhub.sh"

t_case "an id ContainerHub does not own is broken INPUT (2), not a finding"
_d="$(_consumer)"
printf 'not-an-asset\n' >> "${_d}/.containerhub-shared.manifest"
_check "${_d}"
t_assert_eq "2" "${rc}" "2 separates 'your manifest is wrong' from 'your copies drifted'"
t_assert_contains "${OUT}" "which ContainerHub does not own"
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
_reheader "${_d}/scripts/linux/lib/containerhub.sh"
printf 'export CONTAINERHUB_EXTRA=1\n' >> "${_d}/scripts/linux/lib/containerhub.sh"
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
