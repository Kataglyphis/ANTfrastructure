#!/usr/bin/env bash
# Characterisation of docs/scripts/bump_versions.py's report/write machinery,
# driven IN-PROCESS: the real main(), tier sweep, write_env_values() and sha-pair
# audit, with every upstream lookup replaced by a deterministic fake spec. That
# is what the F1 row was blocked on -- it WRITES versions.env and checksums.
# NOT covered: the spec_* lookups themselves (network); this suite pins the
# machinery around them, and the fake specs are the offline proof.
# docs/dependency-updates.md#version-bumping-as-agentsmd-carried-it
set -u
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${TESTS_DIR}/test-harness.sh"
REPO="$(cd "${TESTS_DIR}/../../.." && pwd)"

_WORK="$(mktemp -d)"
trap 'rm -rf "${_WORK}"' EXIT

# The driver: load the REAL module, point it at the fixture, install one named
# scenario of fake tiers, and print rc plus stdout/stderr as three blocks, so
# one run answers both "what did it say" and "what did it return". The SCENARIOS
# table is the single owner of every fake spec this suite uses.
_bv_prelude() {
  cat <<'PY'
import contextlib, io, os, sys
from pathlib import Path
repo, fixture = sys.argv[1], sys.argv[2]
cli = sys.argv[3:]
sys.path.insert(0, os.path.join(repo, "docs/scripts"))
import bump_versions as bv
bv.VERSIONS_ENV = Path(fixture)
# The real tool prints VERSIONS_ENV relative to REPO_ROOT; keep the fixture
# under the root it prints against rather than reach outside it.
bv.REPO_ROOT = Path(fixture).parent


def spec(latest, extras=None, boom=False):
    """A deterministic replacement for one upstream lookup."""
    def fn(cur):
        if boom:
            raise RuntimeError("boom-upstream")
        return latest, dict(extras or {})
    return fn


SCENARIOS = {
    "empty": ([], [], []),
    "only": ([("UP_VERSION", spec("1.0.0"), "fake layer")], [], []),
    "boom": ([("BOOM_VERSION", spec("2.0.0", boom=True), "fake layer"),
              ("LATE_VERSION", spec("4.0.0"), "fake layer")], [], []),
    "check": ([("UP_VERSION", spec("1.0.0"), "fake layer"),
               ("BUMP_VERSION", spec("2.0.0"), "fake layer")], [], []),
    "write": ([("BUMP_VERSION", spec("2.0.0", {"BUMP_SHA256": "b" * 64}), "fake layer"),
               ("HELD_VERSION", spec("3.0.0"), "fake layer")], [], []),
    "report": ([], [("REPORTED_VERSION", spec("5.0.0", {"REPORTED_SHA256": "r" * 64}))], []),
    "unclassified": ([], [], ["MANUAL_VERSION"]),
    "nowrite": ([("UP_VERSION", spec("1.0.0"), "fake layer")], [], []),
    "boom-nowrite": ([("UP_VERSION", spec("1.0.0", boom=True), "fake layer")], [], []),
}


def install(name):
    bv.SAFE, bv.REPORT, bv.MANUAL = SCENARIOS[name]


def run(argv):
    sys.argv = ["bump_versions.py"] + list(argv)
    out, err = io.StringIO(), io.StringIO()
    with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
        try:
            rc = bv.main()
        except SystemExit as exc:
            rc = exc.code if isinstance(exc.code, int) else 1
    print("__RC__", rc)
    print(out.getvalue(), end="")
    print("__STDERR__")
    print(err.getvalue(), end="")
PY
}

# _bv <scenario> <fixture> [cli args...] -- install the scenario, then drive the
# real main() with the CLI args.
_bv() {
  local scenario="$1" fixture="$2"; shift 2
  { _bv_prelude; printf 'install("%s")\nrun(cli)\n' "${scenario}"; } \
    | python3 - "${REPO}" "${fixture}" "$@"
}

_rc_of() { printf '%s\n' "$1" | sed -n 's/^__RC__ //p' | head -1; }

# _after <text> <start-marker> -- the slice from the first line matching the
# marker to the stderr block, so an order-sensitive case cannot pass on a line
# from somewhere else in the report.
_after() { printf '%s\n' "$1" | sed -n "/$2/,/^__STDERR__/p"; }

# _fixture <name> <<'ENV' ... ENV -- a versions.env fixture, printed by path.
_fixture() {
  local f="${_WORK}/$1.env"
  cat > "${f}"
  printf '%s\n' "${f}"
}

t_case "--only names a key outside the safe set: rc 2, and the error names it"
_fx="$(_fixture only_bogus <<'ENV'
UP_VERSION=1.0.0
ENV
)"
_out="$(_bv only "${_fx}" --only bogus)"
t_assert_eq "2" "$(_rc_of "${_out}")" "an unknown --only key must be refused, not ignored"
t_assert_contains "${_out}" "ERROR: --only keys not in the safe set: bogus" \
  "and the refusal must name the key the caller typed"

t_case "a raising spec prints 'lookup failed', the sweep reaches the NEXT key, and the run exits 1 INCOMPLETE"
_fx="$(_fixture boom <<'ENV'
BOOM_VERSION=1.0.0
LATE_VERSION=1.0.0
ENV
)"
_out="$(_bv boom "${_fx}" --check)"
t_assert_eq "1" "$(_rc_of "${_out}")" "a partial report must exit nonzero so scripted callers notice"
t_assert_contains "${_out}" "lookup failed: boom-upstream" "the failing spec's message is printed, not swallowed"
t_assert_contains "$(_after "${_out}" 'lookup failed')" "LATE_VERSION" \
  "the sweep must reach the key AFTER the failing one"
t_assert_contains "${_out}" "INCOMPLETE for those keys" "and the verdict must say the report is incomplete"

t_case "--check: an up-to-date spec is rc 0 and 'up to date'; a newer one prints BUMP and writes nothing"
_fx="$(_fixture check <<'ENV'
UP_VERSION=1.0.0
BUMP_VERSION=1.0.0
ENV
)"
_out="$(_bv check "${_fx}" --check)"
t_assert_eq "0" "$(_rc_of "${_out}")" "a sweep with no failure and no newer pin is a success"
t_assert_contains "${_out}" "up to date" "an up-to-date spec must say so per key"
t_assert_contains "${_out}" "BUMP - rebuilds: fake layer" "a newer spec names the version AND the layer cost"
t_assert_eq "$(printf '%s\n' 'UP_VERSION=1.0.0' 'BUMP_VERSION=1.0.0')" "$(cat "${_fx}")" \
  "check mode must leave the file byte-identical"

t_case "--write rewrites the bumped key AND its paired SHA, skips a bump:hold key, and leaves every other byte alone"
_fx="$(_fixture write <<'ENV'
# bump:hold
HELD_VERSION=1.0.0
BUMP_VERSION=1.0.0
BUMP_SHA256=old-sha
KEEP_ME=untouched
ENV
)"
_out="$(_bv write "${_fx}" --write)"
_SHA="$(printf 'b%.0s' {1..64})"
t_assert_eq "0" "$(_rc_of "${_out}")" "a write over a held key is still a clean run"
t_assert_contains "${_out}" "HELD (bump:hold in versions.env)" "the hold must be visible in the report"
t_assert_contains "${_out}" "BUMP_SHA256" "the paired SHA must be reported as an extra"
t_assert_contains "${_out}" "Wrote 2 key(s)" "both the version and its SHA are written in one pass"
t_assert_contains "${_out}" "Finish the ritual:" "the follow-up ritual must still be printed"
t_assert_eq "$(printf '%s\n' '# bump:hold' 'HELD_VERSION=1.0.0' 'BUMP_VERSION=2.0.0' "BUMP_SHA256=${_SHA}" 'KEEP_ME=untouched')" \
  "$(cat "${_fx}")" "the hold and every untouched line stay byte-identical"

t_case "--write-all is the only switch that writes a REPORT-tier key; --check says NEWER AVAILABLE and writes nothing"
_fx="$(_fixture report <<'ENV'
REPORTED_VERSION=1.0.0
REPORTED_SHA256=old-sha
ENV
)"
_check="$(_bv report "${_fx}" --check)"
t_assert_contains "${_check}" "NEWER AVAILABLE" "without --write-all a report key is report-only"
t_assert_contains "$(cat "${_fx}")" "REPORTED_VERSION=1.0.0" "and the version is not written"
t_assert_contains "$(cat "${_fx}")" "REPORTED_SHA256=old-sha" "nor its paired SHA"
_write_all="$(_bv report "${_fx}" --write-all)"
t_assert_eq "0" "$(_rc_of "${_write_all}")" "the write-all run is clean"
t_assert_contains "${_write_all}" "BUMP (--write-all)" "the marker says which switch applies"
t_assert_contains "${_write_all}" "WRITTEN under --write-all" "and the tier heading says so too"
t_assert_contains "$(cat "${_fx}")" "REPORTED_VERSION=5.0.0" "the report key is written"
t_assert_contains "$(cat "${_fx}")" "REPORTED_SHA256=rrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrr" \
  "with its paired SHA in the same pass"

t_case "the coverage self-audit prints an untiered key under UNCLASSIFIED while SHA and renovate-annotated keys stay quiet"
_fx="$(_fixture unclassified <<'ENV'
MYSTERY_VERSION=1.0.0
SOMETHING_SHA256=aaaa
# renovate: datasource=github-releases depName=foo/bar
ANNOTATED_VERSION=1.0.0
MANUAL_VERSION=1.0.0
ENV
)"
_out="$(_bv unclassified "${_fx}" --check)"
t_assert_contains "${_out}" "-- manual (no reliable programmatic source / deliberate pins) --" \
  "the manual registry gets its own section"
t_assert_contains "${_out}" "MANUAL_VERSION" "and its key is listed there"
t_assert_contains "${_out}" "UNCLASSIFIED versions.env keys" "the audit section must appear when a key is untiered"
_sec="$(_after "${_out}" 'UNCLASSIFIED')"
t_assert_contains "${_sec}" "MYSTERY_VERSION" "the untiered key is printed under it"
t_assert_eq "0" "$(printf '%s\n' "${_sec}" | grep -c -e SOMETHING_SHA256 || true)" \
  "a *_SHA256 key is non-version and must not be flagged"
t_assert_eq "0" "$(printf '%s\n' "${_sec}" | grep -c -e ANNOTATED_VERSION || true)" \
  "a renovate-annotated key is classified and must not be flagged"

t_case "--audit-sha-pairs: a spec-covered, an allowlisted and a held SHA key all pass offline (rc 0)"
_fx="$(_fixture audit_ok <<'ENV'
PWSH_ZIP_SHA256=aaaa
TENSORRT_ZIP_SHA256=bbbb
# bump:hold
HELD_SHA256=cccc
ENV
)"
_out="$(_bv empty "${_fx}" --audit-sha-pairs)"
t_assert_eq "0" "$(_rc_of "${_out}")" "every SHA key here is covered, allowlisted or held"
t_assert_contains "${_out}" "every *_SHA256/*_SHA512 key is refresh-covered, held, or allowlisted." \
  "and the audit must say so"

t_case "--audit-sha-pairs: an unpaired SHA key fails rc 1 and is named with the fix"
_fx="$(_fixture audit_stray <<'ENV'
STRAY_UNKNOWN_SHA256=dddd
ENV
)"
_out="$(_bv empty "${_fx}" --audit-sha-pairs)"
t_assert_eq "1" "$(_rc_of "${_out}")" "a SHA pin outside the refresh net must fail the audit"
t_assert_contains "${_out}" "SHA pins with NO refresh spec, NO bump:hold, NO allowlist entry" \
  "the audit names the hazard class"
t_assert_contains "${_out}" "STRAY_UNKNOWN_SHA256" "and the key itself"
t_assert_contains "${_out}" "allowlist it here WITH a justification." "and the fix"

t_case "--write with nothing to write says so and exits 0; a failed lookup makes that same run exit 1 'unverified'"
_fx="$(_fixture nowrite <<'ENV'
UP_VERSION=1.0.0
ENV
)"
_clean="$(_bv nowrite "${_fx}" --write)"
t_assert_eq "0" "$(_rc_of "${_clean}")" "nothing to write is a clean outcome"
t_assert_contains "${_clean}" "Nothing to write — safe set already at latest." "and it must say so"
_unverified="$(_bv boom-nowrite "${_fx}" --write)"
t_assert_eq "1" "$(_rc_of "${_unverified}")" "a lookup failure under --write is not a clean 'already at latest'"
t_assert_contains "${_unverified}" "is unverified for those keys." "the warning names what could not be checked"

t_case "litert_lm_gpu_pins: the rocm-lane LiteRT-LM pins come from a tag's LFS pointers + WORKSPACE (offline)"
_pins="$(python3 - "${REPO}" <<'PY'
import os, sys
sys.path.insert(0, os.path.join(sys.argv[1], "docs/scripts"))
import bump_versions as bv
files = {f"prebuilt/windows_x86_64/{dll}": f"version https://git-lfs.github.com/spec/v1\noid sha256:{c * 64}\nsize 1\n"
         for (_, dll), c in zip(bv._LITERT_LM_GPU_DLL_PINS, "abc")}
files["WORKSPACE"] = ('http_archive(\n    name = "directx_shader_compiler",\n'
                      '    build_file = "@//:BUILD.directx_shader_compiler",\n'
                      f'    sha256 = "{"D" * 64}",\n    url = "https://x/dxc.zip",\n)\n')
for k, v in sorted(bv.litert_lm_gpu_pins(files.__getitem__).items()):
    print(f"{k}={v}")
files["prebuilt/windows_x86_64/libwebgpu_dawn.dll"] = "a real DLL, not a git-LFS pointer"
try:
    bv.litert_lm_gpu_pins(files.__getitem__)
    print("NO-RAISE")
except RuntimeError as exc:
    print(f"RAISED {exc}")
PY
)"
_a64="$(printf 'a%.0s' {1..64})"; _d64="$(printf 'd%.0s' {1..64})"
t_assert_contains "${_pins}" "LITERT_LM_WEBGPU_ACCELERATOR_SHA256=${_a64}" "the accelerator pin is its pointer's oid"
t_assert_contains "${_pins}" "LITERT_LM_DXC_ZIP_SHA256=${_d64}" "the DXC pin is WORKSPACE's sha256, lower-cased"
t_assert_contains "${_pins}" "RAISED no git-LFS pointer for prebuilt/windows_x86_64/libwebgpu_dawn.dll" \
  "a file that is not an LFS pointer must fail loudly, never pin a guess"

t_case "spec_llama_cpp_hip: newest bNNNN with a win-rocm-<ROCm X.Y> zip wins, asset + SHA move with it, none = raise"
_fx="$(_fixture llama <<'ENV'
ROCM_WINDOWS_RELEASE=10.0.0
LLAMA_CPP_HIP_BUILD=100
ENV
)"
# Upstream faked: b102's only zip is for another ROCm, v0.4.1 is the other tag family.
_out="$(python3 - "${REPO}" "${_fx}" <<'PY'
import os, sys
from pathlib import Path
sys.path.insert(0, os.path.join(sys.argv[1], "docs/scripts"))
import bump_versions as bv
bv.VERSIONS_ENV = Path(sys.argv[2])
bv.ls_remote_tags = lambda repo: ["b99", "b100", "b101", "b102", "v0.4.1"]
bv.artifact_exists = lambda url: url.rsplit("/", 1)[1] in (
    "llama-b100-bin-win-rocm-10.0-x64.zip", "llama-b101-bin-win-rocm-10.0-x64.zip", "llama-b102-bin-win-rocm-7.14-x64.zip")
bv.asset_sha256 = lambda repo, tag, asset, sums=(): "f" * 64
bv.sha256_of_url = lambda url: "e" * 64 if url == "https://raw.githubusercontent.com/ggml-org/llama.cpp/b101/LICENSE" else url
bv.WRITE_MODE = True
print("bump", bv.spec_llama_cpp_hip("100"))
print("same", bv.spec_llama_cpp_hip("101"))
bv.artifact_exists = lambda url: False
try:
    bv.spec_llama_cpp_hip("100")
except RuntimeError as e:
    print("raised", e)
PY
)"
t_assert_contains "${_out}" "bump ('101', {'LLAMA_CPP_HIP_ASSET': 'llama-b101-bin-win-rocm-10.0-x64.zip', 'LLAMA_CPP_HIP_SHA256': 'ffffffff" \
  "the newest build with a zip for THIS ROCm wins (not b102's rocm-7.14 one), and its asset and SHA come along"
t_assert_contains "${_out}" "'LLAMA_CPP_HIP_LICENSE_SHA256': 'eeeeeeee" \
  "the LICENSE pin is re-hashed at the NEW build's tag (b101), never left at the old one"
t_assert_contains "${_out}" "same ('101', {})" "an up-to-date build drags no extras"
t_assert_contains "${_out}" "raised none of the newest 30 ggml-org/llama.cpp builds publishes a win-rocm-10.0 zip" \
  "no matching zip is a lookup failure, never a silent 'up to date'"

t_case "spec_amf_headers: only vX.Y.Z tags count, and the header asset's SHA moves with the tag (offline)"
# AMF's real tag shapes (1.4.14, 1.4.16.1, v.1.4.21, v1.4.7.0), faked NEWER than v1.5.3 in each shape.
_out="$(python3 - "${REPO}" <<'PY'
import os, sys
sys.path.insert(0, os.path.join(sys.argv[1], "docs/scripts"))
import bump_versions as bv
bv.ls_remote_tags = lambda repo: ["1.4.14", "v1.4.36", "v1.5.2", "v1.5.3", "1.6.0", "1.6.0.1", "v.1.6.1", "v1.5.3.1"]
hashed = []
bv.asset_sha256 = lambda repo, tag, asset, sums=(): hashed.append((repo, tag, asset)) or "e" * 64
bv.WRITE_MODE = False
print("report", bv.spec_amf_headers("v1.5.2"), hashed)
bv.WRITE_MODE = True
print("bump", bv.spec_amf_headers("v1.5.2"), hashed)
hashed.clear()
print("same", bv.spec_amf_headers("v1.5.3"), hashed)
PY
)"
_e64="$(printf 'e%.0s' {1..64})"
t_assert_contains "${_out}" "report ('v1.5.3', {}) []" "a report run names the newest vX.Y.Z tag and downloads nothing"
t_assert_contains "${_out}" "bump ('v1.5.3', {'AMF_HEADERS_SHA256': '${_e64}'}) [('GPUOpen-LibrariesAndSDKs/AMF', 'v1.5.3', 'AMF-headers-v1.5.3.tar.gz')]" \
  "--write takes v1.5.3 (not 1.6.0, v.1.6.1 or v1.5.3.1) and re-hashes exactly its header asset"
t_assert_contains "${_out}" "same ('v1.5.3', {}) []" "an up-to-date tag drags no SHA and hashes nothing"

t_summary
