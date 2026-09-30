#!/usr/bin/env bash
# The versions.env apply arm; which keys are self-contained is policy, not tested; see docs/dependency-updates.md#the-annotated-env-manifest
set -u
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${TESTS_DIR}/renovate-fixtures.sh"

ENV_REL="linux/scripts/01-core/versions.env"

# One allowlisted dep and one approval-gated, so both verdicts come from one file and one config.
ENV_REPO="$(_repo env-manifest)"
mkdir -p "${ENV_REPO}/linux/scripts/01-core"
cat > "${ENV_REPO}/${ENV_REL}" <<'ENV'
# renovate: datasource=github-tags depName=rust-lang/rust
RUST_VERSION=1.98.0
# renovate: datasource=github-releases depName=Kitware/CMake extractVersion=^v(?<version>.*)$
CMAKE_VERSION=4.4.2
# renovate: datasource=node-version depName=node
NODE_VERSION=26.8.1
# renovate: datasource=node-version depName=node
RENOVATE_NODE_VERSION=24.21.0
ENV
_commit "${ENV_REPO}"

ENV_CONFIG="${WORK}/config-env.json"
cat > "${ENV_CONFIG}" <<'JSON'
{
 "packageRules": [
  {"description": "versions.env goes to a human by default",
   "matchFileNames": ["linux/scripts/01-core/versions.env"],
   "dependencyDashboardApproval": true},
  {"description": "the self-contained set under test",
   "matchFileNames": ["linux/scripts/01-core/versions.env"],
   "matchDepNames": ["rust-lang/rust", "node"],
   "dependencyDashboardApproval": false}
 ]
}
JSON

RUST_REPORT="${WORK}/env-rust.json"
_report "${RUST_REPORT}" regex "${ENV_REL}" rust-lang/rust 1.98.0 1.98.1
CMAKE_REPORT="${WORK}/env-cmake.json"
_report "${CMAKE_REPORT}" regex "${ENV_REL}" Kitware/CMake 4.4.2 4.4.3
NODE_REPORT="${WORK}/env-node.json"
_report "${NODE_REPORT}" regex "${ENV_REL}" node 24.21.0 24.22.0

# One owner for the apply call, so it cannot drift between cases.
_apply_regex() { RUN_CONFIG="${ENV_CONFIG}" _run "$1" "$2" --apply --managers custom.regex; }

t_case "an allowlisted annotated key is written"
_apply_regex "${ENV_REPO}" "${RUST_REPORT}"
t_assert_eq "0" "${RC}" "an apply over a self-contained key exits 0"
t_assert_eq "RUST_VERSION=1.98.1" "$(_line "${ENV_REPO}/${ENV_REL}" 2)" \
  "the version the report named is the version on disk"
t_assert_eq "CMAKE_VERSION=4.4.2" "$(_line "${ENV_REPO}/${ENV_REL}" 4)" \
  "and nothing else on the file moved"

t_case "a key the file-scoped rule gates is refused, unwritten"
_apply_regex "${ENV_REPO}" "${CMAKE_REPORT}"
t_assert_eq "2" "${RC}" "a refused update exits 2 -- the caller-visible fact"
t_assert_contains "${OUT}" "REFUSED" "the plan names it a refusal"
t_assert_eq "CMAKE_VERSION=4.4.2" "$(_line "${ENV_REPO}/${ENV_REL}" 4)" \
  "the refused key is exactly as it was"

t_case "one dep name over two keys: only the key carrying the reported value moves"
_commit "${ENV_REPO}"   # the first case left the file written; apply refuses a dirty tree
_apply_regex "${ENV_REPO}" "${NODE_REPORT}"
t_assert_eq "0" "${RC}" "a dep name shared by two keys is not itself a refusal"
t_assert_eq "RENOVATE_NODE_VERSION=24.22.0" \
  "$(_line "${ENV_REPO}/${ENV_REL}" 8)" "the key carrying the reported value moved"
t_assert_eq "NODE_VERSION=26.8.1" "$(_line "${ENV_REPO}/${ENV_REL}" 6)" \
  "the key that did not is untouched"

t_case "a hint with no readable KEY= line is refused, never guessed"
BARE_REPO="$(_repo env-bare-hint)"
mkdir -p "${BARE_REPO}/linux/scripts/01-core"
printf '%s\n' '# renovate: datasource=github-tags depName=rust-lang/rust' \
  > "${BARE_REPO}/${ENV_REL}"
_commit "${BARE_REPO}"
_apply_regex "${BARE_REPO}" "${RUST_REPORT}"
t_assert_eq "2" "${RC}" "a dep the locator cannot place is not written"
t_assert_contains "${OUT}" "no regex declaration" \
  "and the reason says it is the locator, not the file's value"

t_summary
