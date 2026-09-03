#!/usr/bin/env bash
# verify-artifact-copy-parity.sh must fail when a manifest artifact is NOT copied
# (the Flutter 2026-09-03 drop-at-the-boundary bug) and when a copy has no manifest
# entry (a stray/renamed COPY). Runs against fixtures, not the real tree.
# docs/artifact-copy-completeness.md
set -u
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${TESTS_DIR}/test-harness.sh"
GATE="${TESTS_DIR}/../verify-artifact-copy-parity.sh"

_work="$(mktemp -d)"
trap 'rm -rf "${_work}"' EXIT

# The gate reads runtime-artifacts.manifest from ITS OWN dir, so a fixture run
# needs a copy of the gate beside a fixture manifest. Symlink the gate, write the
# manifest next to it, and point the gate at a fixture Dockerfile.
_stage() {
  local dir="${_work}/$1"; rm -rf "${dir}"; mkdir -p "${dir}"
  cp "${GATE}" "${dir}/gate.sh"
  printf '%s\n' "$2" > "${dir}/runtime-artifacts.manifest"
  printf '%s\n' "$3" > "${dir}/Dockerfile.pkg"
  ( bash "${dir}/gate.sh" "${dir}/Dockerfile.pkg" ) >"${dir}/out" 2>&1
  printf '%d' "$?"
}

_MANIFEST='/opt/flutter | flutter
/opt/vulkan | vulkan'

# Build a package Dockerfile whose package-image stage COPYs exactly the given
# paths from artifact-source. One owner for the fixture shape (helper-first).
_dockerfile() {
  printf 'FROM base AS artifact-source\nFROM base AS package-image\n'
  local p
  for p in "$@"; do
    printf 'COPY --link --from=artifact-source %s %s\n' "${p}" "${p}"
  done
}

t_case "a complete, consistent Dockerfile passes"
_rc="$(_stage ok "${_MANIFEST}" "$(_dockerfile /opt/flutter /opt/vulkan)")"
t_assert_eq "0" "${_rc}"

t_case "a manifest artifact that is NOT copied fails — the Flutter bug"
_rc="$(_stage dropped "${_MANIFEST}" "$(_dockerfile /opt/vulkan)")"
t_assert_eq "1" "${_rc}"

t_case "and it names the dropped path and the fix"
t_assert_contains "$(cat "${_work}/dropped/out")" "/opt/flutter is in runtime-artifacts.manifest but NOT COPY"

t_case "a COPY with no manifest entry fails — a stray/renamed artifact"
_rc="$(_stage stray "${_MANIFEST}" "$(_dockerfile /opt/flutter /opt/vulkan /opt/surprise)")"
t_assert_eq "1" "${_rc}"

t_case "and it names the undeclared path"
t_assert_contains "$(cat "${_work}/stray/out")" "/opt/surprise is COPY'd from artifact-source but NOT in runtime-artifacts.manifest"

t_case "the REAL manifest and Dockerfile.package agree today"
_rc="$( ( bash "${GATE}" ) >/dev/null 2>&1; printf '%d' "$?" )"
t_assert_eq "0" "${_rc}"

t_case "the real manifest actually lists /opt/flutter (regression guard for this fix)"
t_assert_contains "$(cat "${TESTS_DIR}/../runtime-artifacts.manifest")" "/opt/flutter |"

t_case "Dockerfile.package actually COPYs /opt/flutter (regression guard for this fix)"
t_assert_contains "$(cat "${TESTS_DIR}/../../Dockerfile.package")" "COPY --link --from=artifact-source /opt/flutter /opt/flutter"

t_summary
