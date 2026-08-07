#!/usr/bin/env bash
# Tests for 01-core/ancestry.sh + 01-core/manifest-annotation.py — the
# stale-ancestor guard that makes cross-INVOCATION staleness a hard failure
# instead of a rule in a document.
set -u
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CORE_DIR="${TESTS_DIR}/../01-core"
source "${TESTS_DIR}/test-harness.sh"

# ancestry.sh expects logging + the stage graph from its caller; stub them so
# the unit under test stays isolated.
log()  { printf '[INFO] %s\n' "$*"; }
warn() { printf '[WARN] %s\n' "$*" >&2; }

CROSS_STAGE_ORDER=(base compiler sdk media android runtime)
declare -A _PARENT=( [compiler]=base [sdk]=compiler [media]=sdk [android]=media )
cross_stage_parent()      { printf '%s' "${_PARENT[$1]:-}"; }
cross_stage_is_per_arch() { case "$1" in sdk|media|android) return 0 ;; *) return 1 ;; esac; }
cross_stage_tag() {
  if cross_stage_is_per_arch "$1"; then printf 'repo/img:cross-%s-%s' "$1" "${2:-}"
  else printf 'repo/img:%s' "$1"; fi
}
arch_list_to_words() { printf '%s' "${1//,/ }"; }

source "${CORE_DIR}/ancestry.sh"

# ---------------------------------------------------------------------------
t_case "ancestry_output_annotations emits nothing without a parent (base stage)"
t_assert_eq "" "$(ancestry_output_annotations "" "")"
t_assert_eq "" "$(ancestry_output_annotations "" "base")"

t_case "ancestry_output_annotations records the pin and the parent stage name"
t_assert_eq ",annotation.org.kataglyphis.parent-digest=repo/img@sha256:aaa,annotation.org.kataglyphis.parent-stage=compiler" \
            "$(ancestry_output_annotations "repo/img@sha256:aaa" "compiler")"

t_case "ancestry_output_annotations omits the stage key when the name is unknown"
t_assert_eq ",annotation.org.kataglyphis.parent-digest=repo/img@sha256:aaa" \
            "$(ancestry_output_annotations "repo/img@sha256:aaa" "")"

t_case "a comma in the pin is refused, never emitted into the --output spec"
# A comma would be parsed as an output-opt separator and silently corrupt the
# exporter spec, so the annotation is dropped instead.
t_assert_eq "" "$(ancestry_output_annotations "repo/img@sha256:a,b" "sdk" 2>/dev/null)"

# ---------------------------------------------------------------------------
t_case "_ancestry_digest_of reduces a pinned ref to its digest"
t_assert_eq "sha256:abc" "$(_ancestry_digest_of "ghcr.io/o/r:tag@sha256:abc")"
t_assert_eq "sha256:abc" "$(_ancestry_digest_of "sha256:abc")"

# ---------------------------------------------------------------------------
# manifest-annotation.py: annotations live only in the base64 `Raw` field of
# `nerdctl manifest inspect --verbose` output.
_mk_inspect_json() {
  local annotations="$1"
  python3 - "${annotations}" <<'PY'
import base64, json, sys
manifest = {"schemaVersion": 2, "layers": []}
ann = json.loads(sys.argv[1])
if ann:
    manifest["annotations"] = ann
raw = base64.b64encode(json.dumps(manifest).encode()).decode()
print(json.dumps({"Ref": "repo/img:t", "Descriptor": {"digest": "sha256:x"}, "Raw": raw}))
PY
}

KEY="org.kataglyphis.parent-digest"

t_case "manifest-annotation.py extracts the annotation out of Raw"
out="$(_mk_inspect_json '{"org.kataglyphis.parent-digest":"repo/img@sha256:parent"}' \
       | python3 "${CORE_DIR}/manifest-annotation.py" "${KEY}")"
t_assert_eq "repo/img@sha256:parent" "${out}"

t_case "absent annotation exits 2 (unknown provenance, not a hard error)"
_mk_inspect_json '{}' | python3 "${CORE_DIR}/manifest-annotation.py" "${KEY}" >/dev/null 2>&1
t_assert_eq "2" "$?"

t_case "unusable input exits 1"
printf 'not json' | python3 "${CORE_DIR}/manifest-annotation.py" "${KEY}" >/dev/null 2>&1
t_assert_eq "1" "$?"

t_case "a manifest list uses its first entry"
out="$( { printf '['; _mk_inspect_json '{"org.kataglyphis.parent-digest":"repo/img@sha256:first"}'; printf ']'; } \
       | python3 "${CORE_DIR}/manifest-annotation.py" "${KEY}")"
t_assert_eq "repo/img@sha256:first" "${out}"

# ---------------------------------------------------------------------------
# _ancestry_check_link: the actual verdict. Stub the two registry reads.
RECORDED=""
CURRENT=""
ancestry_recorded_parent() { [ -n "${RECORDED}" ] || return 2; printf '%s' "${RECORDED}"; }
registry_pin_ref()         { [ -n "${CURRENT}" ]  || return 1; printf '%s' "${CURRENT}"; }

t_case "matching digests pass"
RECORDED="repo/img@sha256:same"; CURRENT="repo/img@sha256:same"
t_assert_ok _ancestry_check_link "repo/img:child" "repo/img:parent" "compiler->sdk"

t_case "a parent rebuilt after the child is a hard failure"
RECORDED="repo/img@sha256:old"; CURRENT="repo/img@sha256:new"
t_assert_fails _ancestry_check_link "repo/img:child" "repo/img:parent" "compiler->sdk"

t_case "repo prefix may differ; the digest is the identity claim"
# --image-repo can legitimately move the chain to another registry path.
RECORDED="old/repo@sha256:same"; CURRENT="new/repo@sha256:same"
t_assert_ok _ancestry_check_link "repo/img:child" "repo/img:parent" "compiler->sdk"

t_case "an image without the annotation warns but does not fail the build"
# Pre-existing images predate the annotation: provenance is unknown, not bad.
RECORDED=""; CURRENT="repo/img@sha256:new"
t_assert_ok _ancestry_check_link "repo/img:child" "repo/img:parent" "compiler->sdk"

t_case "an unresolvable parent tag is the build's problem, not an ancestry violation"
RECORDED="repo/img@sha256:old"; CURRENT=""
t_assert_ok _ancestry_check_link "repo/img:child" "repo/img:parent" "compiler->sdk"

# ---------------------------------------------------------------------------
t_case "ancestry_assert_chain is a no-op from base (nothing prior can be stale)"
RECORDED="repo/img@sha256:old"; CURRENT="repo/img@sha256:new"   # would fail if checked
t_assert_ok ancestry_assert_chain "base" "amd64"

t_case "a partial run walks the ancestors and fails on the stale one"
RECORDED="repo/img@sha256:old"; CURRENT="repo/img@sha256:new"
t_assert_fails ancestry_assert_chain "media" "amd64"

t_case "a partial run passes when every ancestor is current"
RECORDED="repo/img@sha256:same"; CURRENT="repo/img@sha256:same"
t_assert_ok ancestry_assert_chain "media" "amd64,arm64"

t_summary
