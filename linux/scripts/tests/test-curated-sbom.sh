#!/usr/bin/env bash
# Tests for generate_sbom.py's --check mode, the `sbom` preflight slug. The gate
# is only worth anything if the document is byte-REPRODUCIBLE (hence the frozen
# timestamp) and if a stale committed copy actually goes red -- an SBOM that
# silently drifts from versions.env is worse than none, because it is published
# as the corresponding-source record for the copyleft half of the image.
# docs/code-quality-tooling.md#curated-sbom-sbom
set -u
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${TESTS_DIR}/test-harness.sh"

_work="$(mktemp -d)"
trap 'rm -rf "${_work}"' EXIT
REPO="$(cd "${TESTS_DIR}/../../.." && pwd)"
GATE="${REPO}/docs/scripts/generate_sbom.py"
PY="${PREFLIGHT_PYTHON:-python3}"

# _tree: a throwaway repo root with the generator, the two modules it imports,
# the real deps.json and versions.env -- the gate resolves all four from its own
# path, so a fixture is the only way to make its inputs move.
_tree() {
  local d; d="$(mktemp -d "${_work}/tree.XXXXXX")"
  mkdir -p "${d}/docs/scripts" "${d}/docs/deps" "${d}/linux/scripts/01-core"
  cp "${REPO}/docs/scripts/generate_sbom.py" "${REPO}/docs/scripts/deps_table.py" \
     "${REPO}/docs/scripts/license_obligations.py" "${d}/docs/scripts/"
  cp "${REPO}/docs/deps/deps.json" "${d}/docs/deps/"
  cp "${REPO}/linux/scripts/01-core/versions.env" "${d}/linux/scripts/01-core/"
  printf '%s' "${d}"
}

_sbom() { "${PY}" "$1/docs/scripts/generate_sbom.py" "${@:2}"; }
_out_file() { printf '%s/docs/deps/sbom-curated.spdx.json' "$1"; }

t_case "--check fails when the committed document is missing"
fix="$(_tree)"
t_assert_eq "1" "$(t_rc _sbom "${fix}" --check)" "an absent SBOM is not an up-to-date SBOM"
t_assert_contains "$(t_out _sbom "${fix}" --check)" "out of date"
t_assert_contains "$(t_out _sbom "${fix}" --check)" "--write" "the message has to name the fix"

t_case "--write then --check is green"
_out="$(t_out _sbom "${fix}" --write)"
t_assert_contains "${_out}" "Written:"
t_assert_eq "0" "$(t_rc _sbom "${fix}" --check)" \
  "the gate must be able to be green, or every red here proves only that it is broken"
t_assert_contains "$(t_out _sbom "${fix}" --check)" "up to date"

t_case "the document is byte-reproducible, which is what makes it gateable"
# The creation timestamp is frozen for exactly this reason. A wall-clock stamp
# would make --check fail on every run and the gate would be switched off.
a="$(_sbom "${fix}" --stdout)"
b="$(_sbom "${fix}" --stdout)"
t_assert_eq "${a}" "${b}" "two runs a moment apart must produce identical bytes"
t_assert_contains "${a}" '"created": "1970-01-01T00:00:00Z"'

t_case "a hand-edited committed document is caught"
printf 'tampered\n' >> "$(_out_file "${fix}")"
t_assert_eq "1" "$(t_rc _sbom "${fix}" --check)" "byte equality is the contract; anything less is not a gate"

t_case "a versions.env bump moves the SBOM, and --check notices"
# The point of the curated half: it tracks the source-built inventory. A gate
# that only compared the file against itself would never see this.
fix="$(_tree)"
_sbom "${fix}" --write >/dev/null
t_assert_eq "0" "$(t_rc _sbom "${fix}" --check)"
sed -i 's/^FFMPEG_VERSION=.*/FFMPEG_VERSION=0.0.0-fixture/' "${fix}/linux/scripts/01-core/versions.env"
t_assert_eq "1" "$(t_rc _sbom "${fix}" --check)" \
  "a published corresponding-source record that drifts from the versions it names is worse than none"
t_assert_contains "$(_sbom "${fix}" --stdout)" "0.0.0-fixture" "and the new value is what the document would carry"

t_case "--stdout writes nothing, so it cannot be mistaken for --write"
fix="$(_tree)"
_sbom "${fix}" --stdout >/dev/null
t_assert_fails test -e "$(_out_file "${fix}")"

t_case "the committed SBOM in the REAL tree is current today"
t_assert_eq "0" "$(t_rc "${PY}" "${GATE}" --check)"

t_summary
