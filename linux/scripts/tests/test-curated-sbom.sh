#!/usr/bin/env bash
# generate_sbom.py --check, the `sbom` slug; see docs/code-quality-tooling.md#curated-sbom-sbom
set -u
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${TESTS_DIR}/test-harness.sh"

_work="$(mktemp -d)"
trap 'rm -rf "${_work}"' EXIT
REPO="$(cd "${TESTS_DIR}/../../.." && pwd)"
GATE="${REPO}/docs/scripts/generate_sbom.py"
PY="${PREFLIGHT_PYTHON:-python3}"

# _tree: a fixture root, because the gate resolves its inputs from its own path.
_tree() {
  local d; d="$(mktemp -d "${_work}/tree.XXXXXX")"
  mkdir -p "${d}/docs/scripts" "${d}/docs/deps" "${d}/linux/scripts/01-core"
  cp "${REPO}/docs/scripts/generate_sbom.py" "${REPO}/docs/scripts/deps_table.py" \
     "${REPO}/docs/scripts/license_obligations.py" "${d}/docs/scripts/"
  cp "${REPO}/docs/deps/deps.json" "${d}/docs/deps/"
  cp "${REPO}/linux/scripts/01-core/versions.env" "${REPO}/linux/scripts/01-core/tool-pins.env" "${d}/linux/scripts/01-core/"
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
# The frozen creation timestamp is what keeps --check from failing on every run.
a="$(_sbom "${fix}" --stdout)"
b="$(_sbom "${fix}" --stdout)"
t_assert_eq "${a}" "${b}" "two runs a moment apart must produce identical bytes"
t_assert_contains "${a}" '"created": "1970-01-01T00:00:00Z"'

t_case "a hand-edited committed document is caught"
printf 'tampered\n' >> "$(_out_file "${fix}")"
t_assert_eq "1" "$(t_rc _sbom "${fix}" --check)" "byte equality is the contract; anything less is not a gate"

t_case "a versions.env bump moves the SBOM, and --check notices"
# A gate that only compared the file against itself would never see this.
fix="$(_tree)"
_sbom "${fix}" --write >/dev/null
t_assert_eq "0" "$(t_rc _sbom "${fix}" --check)"
sed -i 's/^FFMPEG_VERSION=.*/FFMPEG_VERSION=0.0.0-fixture/' "${fix}/linux/scripts/01-core/versions.env"
t_assert_eq "1" "$(t_rc _sbom "${fix}" --check)" \
  "a published corresponding-source record that drifts from the versions it names is worse than none"
t_assert_contains "$(_sbom "${fix}" --stdout)" "0.0.0-fixture" "and the new value is what the document would carry"

t_case "a tool-pins.env bump moves the documentation tool's SBOM entry"
sed -i 's/^DARTDOC_VERSION=.*/DARTDOC_VERSION=0.0.0-doc-fixture/' "${fix}/linux/scripts/01-core/tool-pins.env"
t_assert_contains "$(_sbom "${fix}" --stdout)" "0.0.0-doc-fixture"
t_assert_eq "1" "$(t_rc _sbom "${fix}" --check)"

t_case "--stdout writes nothing, so it cannot be mistaken for --write"
fix="$(_tree)"
_sbom "${fix}" --stdout >/dev/null
t_assert_fails test -e "$(_out_file "${fix}")"

t_case "package extraction preserves the complete committed SPDX document"
actual="${_work}/actual.json"
"${PY}" "${GATE}" --stdout > "${actual}"
t_assert_eq "0" "$(t_rc cmp "${REPO}/docs/deps/sbom-curated.spdx.json" "${actual}")" \
  "all package fields, source obligations and relationships must retain their bytes"

t_case "the committed SBOM in the REAL tree is current today"
t_assert_eq "0" "$(t_rc "${PY}" "${GATE}" --check)"

t_case "scanner comparison keeps package counts, image scope and source obligations distinct"
comparison="$("${PY}" - "${REPO}" "${_work}" <<'PY_COMPARE'
import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(sys.argv[1]) / "docs/scripts"))
import compare_sbom as comparison

work = Path(sys.argv[2])
scanned = work / "scanned-linux.spdx.json"
scanned.write_text(json.dumps({"packages": [
    {"name": "gstreamer1.0", "externalRefs": [{"referenceType": "purl", "referenceLocator": "pkg:deb/gstreamer"}]},
    {"name": "torch"}, {"name": "torch"},
]}))
curated = work / "comparison-curated.json"
curated_rows = [
    ("GStreamer", "Linux", ""),
    ("PyTorch", "Linux", ""),
    ("FFmpeg", "Linux", "offer-source"),
    ("TeX Live", "Windows", ""),
]
curated.write_text(json.dumps({"packages": [
    {"name": name, "comment": f"Image section: {image} / fixture",
     "licenseComments": obligation, "licenseDeclared": "GPL" if obligation else ""}
    for name, image, obligation in curated_rows
]}))
comparison.CURATED = curated
sys.argv = ["compare_sbom.py", str(scanned)]
raise SystemExit(comparison.main())
PY_COMPARE
)"
t_assert_contains "${comparison}" '3 (2 distinct names)'
t_assert_contains "${comparison}" 'deb 1'
t_assert_contains "${comparison}" 'no-purl 2'
t_assert_contains "${comparison}" '3   [1 belong to other images, excluded]'
t_assert_contains "${comparison}" 'NOT visible to the scanner  : 1'
t_assert_contains "${comparison}" 'source-obligated: 1'
t_assert_contains "${comparison}" 'FFmpeg  [GPL]'

t_summary
