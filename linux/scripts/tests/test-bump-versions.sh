#!/usr/bin/env bash
# bump_versions.py's report/write machinery, in-process with fake specs. See docs/dependency-updates.md#version-bumping-as-agentsmd-carried-it
set -u
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${TESTS_DIR}/test-harness.sh"
REPO="$(cd "${TESTS_DIR}/../../.." && pwd)"

_WORK="$(mktemp -d)"
trap 'rm -rf "${_WORK}"' EXIT

# The real module on the fixture with one named fake scenario; prints rc, stdout and stderr as three blocks.
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

# _bv <scenario> <fixture> [cli args...] -- install the scenario, then run the real main().
_bv() {
  local scenario="$1" fixture="$2"; shift 2
  { _bv_prelude; printf 'install("%s")\nrun(cli)\n' "${scenario}"; } \
    | python3 - "${REPO}" "${fixture}" "$@"
}

_rc_of() { printf '%s\n' "$1" | sed -n 's/^__RC__ //p' | head -1; }

# _after <text> <start-marker> -- marker to stderr, so an order-sensitive case cannot match elsewhere.
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
files["prebuilt/windows_x86_64/webgpu_dawn.dll"] = "a real DLL, not a git-LFS pointer"
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
t_assert_contains "${_pins}" "RAISED no git-LFS pointer for prebuilt/windows_x86_64/webgpu_dawn.dll" \
  "a file that is not an LFS pointer must fail loudly, never pin a guess"

t_case "protoc_from_protobuf_cmake: the slaved PROTOC_VERSION reads all three protobuf.cmake shapes (offline)"
_protoc="$(python3 - "${REPO}" <<'PY'
import os, sys
sys.path.insert(0, os.path.join(sys.argv[1], "docs/scripts"))
import bump_versions as bv
for label, text in (
    ("0.18", 'set(LITERTLM_PROTOBUF_TAG "v36.1" CACHE STRING "Protobuf git tag")\n    GIT_TAG\n      ${LITERTLM_PROTOBUF_TAG}\n'),
    ("0.17", "    GIT_REPOSITORY\n      https://github.com/protocolbuffers/protobuf\n    GIT_TAG\n      v35.1\n"),
    ("0.14", "    GIT_TAG v6.31.1\n"),
    ("none", "    GIT_TAG ${SOMETHING_ELSE}\n"),
):
    print(f"{label}={bv.protoc_from_protobuf_cmake(text)}")
PY
)"
t_assert_contains "${_protoc}" "0.18=36.1" "LiteRT-LM 0.18's cache variable names protoc's own version"
t_assert_contains "${_protoc}" "0.17=35.1" "a two-part GIT_TAG is protoc's own version"
t_assert_contains "${_protoc}" "0.14=31.1" "a three-part runtime tag maps to protoc MINOR.PATCH"
t_assert_contains "${_protoc}" "none=None" "an unreadable pin is None, never a guess"

t_case "spec_llama_cpp_hip: newest bNNNN with a win-cpu AND a win-vulkan zip wins; source pin, both SHAs and LICENSE move; none = raise"
_fx="$(_fixture llama <<'ENV'
LLAMA_CPP_HIP_BUILD=100
ENV
)"
# Upstream faked: b103 has no Vulkan zip, b102 no CPU zip, v0.4.1 is the other tag family.
_out="$(python3 - "${REPO}" "${_fx}" <<'PY'
import os, sys
from pathlib import Path
sys.path.insert(0, os.path.join(sys.argv[1], "docs/scripts"))
import bump_versions as bv
bv.VERSIONS_ENV = Path(sys.argv[2])
bv.ls_remote_tags = lambda repo: ["b99", "b100", "b101", "b102", "b103", "v0.4.1"]
bv.ls_remote_tag_commit = lambda repo, tag: {"b101": "c" * 40}[tag]
bv.artifact_exists = lambda url: url.rsplit("/", 1)[1] in (
    "llama-b100-bin-win-cpu-x64.zip", "llama-b101-bin-win-cpu-x64.zip", "llama-b103-bin-win-cpu-x64.zip",
    "llama-b100-bin-win-vulkan-x64.zip", "llama-b101-bin-win-vulkan-x64.zip", "llama-b102-bin-win-vulkan-x64.zip")
bv.asset_sha256 = lambda repo, tag, asset, sums=(): ("a" if "-vulkan-" in asset else "f") * 64
bv.sha256_of_url = lambda url: {
    "https://raw.githubusercontent.com/ggml-org/llama.cpp/b101/LICENSE": "e" * 64,
    f"https://github.com/ggml-org/llama.cpp/archive/{'c' * 40}.tar.gz": "d" * 64}.get(url, url)
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
t_assert_contains "${_out}" "bump ('101', {'LLAMA_CPP_HIP_COMMIT': 'cccccccc" \
  "the newest build with both zips wins (not b103 without Vulkan, not b102 without CPU), and its tag's commit is pinned"
t_assert_contains "${_out}" "'LLAMA_CPP_HIP_SOURCE_SHA256': 'dddddddd" \
  "the source pin is the archive of THAT commit, re-hashed, never the tag name"
t_assert_contains "${_out}" "'LLAMA_CPP_CPU_SHA256': 'ffffffff" \
  "the CPU zip pin is its own asset's digest, moved with the one build pin"
t_assert_contains "${_out}" "'LLAMA_CPP_VULKAN_SHA256': 'aaaaaaaa" \
  "the Vulkan pin is its own asset's digest, moved with the one build pin"
t_assert_contains "${_out}" "'LLAMA_CPP_HIP_LICENSE_SHA256': 'eeeeeeee" \
  "the LICENSE pin is re-hashed at the NEW build's tag (b101), never left at the old one"
t_assert_contains "${_out}" "same ('101', {})" "an up-to-date build drags no extras"
t_assert_contains "${_out}" "raised none of the newest 30 ggml-org/llama.cpp builds publishes both a win-cpu-x64 and a win-vulkan-x64 zip" \
  "no matching pair of zips is a lookup failure, never a silent 'up to date'"

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

# _bv_offline <<'PY' ... PY -- a snippet run against the real module, imported as bv; nothing else is set up.
_bv_offline() {
  { printf 'import os, sys\nsys.path.insert(0, os.path.join(sys.argv[1], "docs/scripts"))\nimport bump_versions as bv\n'; cat; } \
    | python3 - "${REPO}"
}

t_case "spec_vulkan: the Windows loader zip's SHA moves with VULKAN_VERSION, LunarG's digest first (offline)"
_out="$(_bv_offline <<'PY'
zip_name = "VulkanRT-X64-1.4.400.0-Components.zip"
sums = {"ok": "ABCD" * 16 + "  " + zip_name + "\n", "other": ("c" * 64) + "  other.zip\n", "boom": None}
mode = {"sums": "ok"}
fetched = []
def http_text(url):
    fetched.append(url)
    if url.endswith("latest.json"):
        return '{"linux": "1.4.400.0", "windows": "1.4.400.0"}'
    if sums[mode["sums"]] is None:
        raise OSError("404")
    return sums[mode["sums"]]
bv.http_text = http_text
bv.sha256_of_url = lambda url: ("f" * 64) if url.endswith(zip_name) else ("e" * 64)
bv.WRITE_MODE = False
print("report", bv.spec_vulkan("1.4.357.0"))
bv.WRITE_MODE = True
for m in ("ok", "other", "boom"):
    mode["sums"] = m
    print(m, bv.spec_vulkan("1.4.357.0")[1]["VULKAN_RT_WINDOWS_ZIP_SHA256"])
print("sums-url", [u for u in fetched if "/sdk/sha/" in u][0])
print("arm64-sums-url", [u for u in fetched if "/sdk/sha/" in u and "ARM64" in u][0])
print("arm64-key", sorted(bv.spec_vulkan("1.4.357.0")[1]))
PY
)"
t_assert_contains "${_out}" "report ('1.4.400.0', {})" "a report run downloads and hashes nothing"
t_assert_contains "${_out}" "ok abcdabcd" "--write takes LunarG's published digest for the zip, lower-cased"
t_assert_contains "${_out}" "other $(printf 'f%.0s' {1..64})" "a digest file that does not name the zip falls back to hashing the zip"
t_assert_contains "${_out}" "boom $(printf 'f%.0s' {1..64})" "an unreachable digest file falls back to hashing the zip"
t_assert_contains "${_out}" "sums-url https://sdk.lunarg.com/sdk/sha/1.4.400.0/windows/VulkanRT-X64-1.4.400.0-Components.zip.txt" \
  "the digest comes from LunarG's sha endpoint for exactly that file"
t_assert_contains "${_out}" "arm64-sums-url https://sdk.lunarg.com/sdk/sha/1.4.400.0/warm/VulkanRT-ARM64-1.4.400.0-Components.zip.txt" \
  "the arm64 zip's digest comes from its warm/ path, not windows/"
t_assert_contains "${_out}" "'VULKAN_RT_WINDOWS_ARM64_ZIP_SHA256'" "the arm64 loader zip's SHA moves with VULKAN_VERSION too"

t_case "spec_ort_webgpu_dxc: DXC's latest release, its one dxc_<date>.zip, and that zip's SHA move together (offline)"
_out="$(_bv_offline <<'PY'
release = {"tag_name": "v1.9.2609", "assets": [{"name": n} for n in (
    "dxc_2026_09_01.zip", "linux_dxc_2026_09_01.x86_64.tar.gz", "pdb_2026_09_01.zip")]}
seen = []
bv.http_json = lambda url: seen.append(url) or release
bv.asset_sha256 = lambda *what, **_: seen.append(what) or "d" * 64
for write, pinned in ((False, "v1.9.2607"), (True, "v1.9.2607"), (True, "v1.9.2609")):
    bv.WRITE_MODE = write
    seen.clear()
    tag, extras = bv.spec_ort_webgpu_dxc(pinned)
    print("write=%s pinned=%s -> %s %s hashed=%s" % (write, pinned, tag, sorted(extras.items()), seen[1:]))
print("asked", seen[0])
for assets in ([], [{"name": "dxc_2026_09_01.zip"}, {"name": "dxc_2026_09_02.zip"}]):
    release["assets"] = assets
    try:
        bv.spec_ort_webgpu_dxc("v1.9.2607")
    except RuntimeError as e:
        print("refused:", e)
PY
)"
_d64="$(printf 'd%.0s' {1..64})"
t_assert_contains "${_out}" "write=False pinned=v1.9.2607 -> v1.9.2609 [] hashed=[]" "a report run names the release and downloads nothing"
t_assert_contains "${_out}" "write=True pinned=v1.9.2607 -> v1.9.2609 [('ORT_WEBGPU_WINDOWS_DXC_ASSET', 'dxc_2026_09_01.zip'), ('ORT_WEBGPU_WINDOWS_DXC_SHA256', '${_d64}')] hashed=[('microsoft/DirectXShaderCompiler', 'v1.9.2609', 'dxc_2026_09_01.zip')]" \
  "--write moves the dated asset name and re-hashes exactly that zip (not the linux tarball or the pdb zip)"
t_assert_contains "${_out}" "write=True pinned=v1.9.2609 -> v1.9.2609 [] hashed=[]" "an up-to-date tag drags no extras"
t_assert_contains "${_out}" "asked https://api.github.com/repos/microsoft/DirectXShaderCompiler/releases/latest" \
  "releases/latest: GitHub's newest NON-prerelease (the v1.10 previews are prereleases)"
t_assert_contains "${_out}" "refused: DXC v1.9.2609: expected one dxc_<date>.zip asset, found []" "no zip is a lookup failure"
t_assert_contains "${_out}" "found ['dxc_2026_09_01.zip', 'dxc_2026_09_02.zip']" "two zips are ambiguous, never a guess"

t_case "--audit-sha-pairs: a SHA beside a hand-moved *_URL passes; beside a renovate-moved *_URL it fails"
_fx="$(_fixture audit_url <<'ENV'
FOO_WHEEL_URL=https://files.example/foo-1.0-py3-none-any.whl
FOO_WHEEL_SHA256=aaaa
# renovate: datasource=github-releases depName=bar/bar
BAR_URL=https://example/bar-1.0.tar.gz
BAR_SHA256=bbbb
ENV
)"
_out="$(_bv empty "${_fx}" --audit-sha-pairs)"
t_assert_eq "1" "$(_rc_of "${_out}")" "a URL Renovate can move is a version mover, so its SHA needs a spec"
t_assert_contains "${_out}" "  BAR_SHA256" "the renovate-moved pair is named"
t_assert_eq "0" "$(printf '%s\n' "${_out}" | grep -c -e FOO_WHEEL_SHA256 || true)" \
  "a pin whose only version is a hand-edited URL beside it is not flagged"

# _audit_src <fixture> <source text> -- the audit with this file's text standing in for bump_versions.py.
_audit_src() {
  local src="${_WORK}/audit_src.py"
  printf '%s\n' "$2" > "${src}"
  _bv_offline <<PY
from pathlib import Path
bv.VERSIONS_ENV = Path("$1")
bv.__file__ = "${src}"
print("rc", bv.audit_sha_pairs())
PY
}

t_case "--audit-sha-pairs: only a quoted key in the source counts as specced, never a comment naming it"
_fx="$(_fixture audit_src <<'ENV'
QUOTED_SHA256=aaaa
COMMENTED_SHA256=bbbb
ENV
)"
_out="$(_audit_src "${_fx}" '# COMMENTED_SHA256 is refreshed somewhere
PINS = {"QUOTED_SHA256": "x"}')"
t_assert_contains "${_out}" "  COMMENTED_SHA256" "a comment is not a refresh spec"
t_assert_eq "0" "$(printf '%s\n' "${_out}" | grep -c -e '  QUOTED_SHA256' || true)" "a quoted key is"
t_assert_contains "${_out}" "rc 1" "and the audit fails"

# _audit_pins <audit> [<pin file> <line>]... -- one offline audit on a copy of the real pin files, lines appended.
_audit_pins() {
  local audit="$1" dir
  dir="$(mktemp -d "${_WORK}/pins.XXXXXX")"
  shift
  cp "${REPO}/linux/scripts/01-core/versions.env" "${REPO}/linux/scripts/01-core/tool-pins.env" "${dir}/"
  while (( $# >= 2 )); do printf '%s\n' "$2" >> "${dir}/$1"; shift 2; done
  _bv_offline <<PY
from pathlib import Path
bv.VERSIONS_ENV = Path("${dir}/versions.env")
print("rc", bv.${audit}())
PY
}

t_case "--audit-sha-pairs on the REAL versions.env + tool-pins.env: rc 0, and one new unspecced SHA key turns it red"
t_assert_contains "$(_audit_pins audit_sha_pairs)" "rc 0" "every committed SHA pin is specced, held, exempt or URL-paired"
_mut="$(_audit_pins audit_sha_pairs tool-pins.env "NEWTOOL_LINUX_X86_64_SHA256=$(printf '%064d' 0)")"
t_assert_contains "${_mut}" "rc 1" "a SHA key added with no spec, hold or exemption fails the audit"
t_assert_eq "1" "$(printf '%s\n' "${_mut}" | grep -c -e '^  [A-Z]' || true)" "and it is the only key named"
t_assert_contains "${_mut}" "  NEWTOOL_LINUX_X86_64_SHA256" "the new key itself"

t_case "--audit-unclassified on the REAL pin files: rc 0, and one new untiered version key turns it red"
_real="$(_audit_pins audit_unclassified)"
t_assert_contains "${_real}" "rc 0" "every committed key is tiered, derived, manual, Renovate-annotated or non-version"
t_assert_eq "0" "$(printf '%s\n' "${_real}" | grep -c -e UNCLASSIFIED || true)" "and none is listed as unclassified"
_mut="$(_audit_pins audit_unclassified versions.env NEWTOOL_VERSION=1.0.0 versions.env PYTEST_WINDOWS_ARM64_NOSHA_URL=https://x/y.whl)"
t_assert_contains "${_mut}" "rc 1" "a version key added with no tier fails the audit"
t_assert_contains "${_mut}" "NEWTOOL_VERSION" "the new key is named"
t_assert_contains "${_mut}" "PYTEST_WINDOWS_ARM64_NOSHA_URL" "a wheel-store *_URL with no *_SHA256 beside it is not a wheel pin"
t_assert_eq "2" "$(printf '%s\n' "${_mut}" | grep -c -e '^  [A-Z]' || true)" "and only those two are named"

t_case "the derived and slaved specs: DeepStream's OSS deps, x264's meson branch, the ROCm torch line (offline)"
_out="$(_bv_offline <<'PY'
script = ("git clone --depth 1 --branch v1.23.0 \\\n      https://github.com/open-telemetry/opentelemetry-cpp.git \"$D\"\n"
          "git clone --depth 1 --branch v1.16 \\\n      https://github.com/civetweb/civetweb.git \"$D\"\n"
          "git clone --depth 1 --branch v1.2.4 \\\n      https://github.com/jupp0r/prometheus-cpp.git \"$D\"\n")
pins = bv.deepstream_oss_pins(script, lambda repo, tag: f"{repo}@{tag}")
print("oss", pins["DEEPSTREAM_CIVETWEB_VERSION"], pins["DEEPSTREAM_OPENTELEMETRY_CPP_COMMIT"])
try:
    bv.deepstream_oss_pins(script.replace("civetweb/civetweb", "elsewhere/civetweb"), lambda r, t: "x")
except RuntimeError as e:
    print("refused:", e)
print("derived", sorted(set(bv.derived_keys().values())), len(bv.derived_keys()))
bv.read_env = lambda: {"GSTREAMER_VERSION": "1.30.0", "PYTORCH_VERSION": "v2.14.1"}
bv.http_text = lambda url: {
    "https://gitlab.freedesktop.org/gstreamer/gstreamer/-/raw/1.30.0/subprojects/x264.wrap":
        "[wrap-git]\nurl = https://gitlab.example/x264.git\nrevision = 165.0-meson\n",
    "https://download.pytorch.org/whl/torch/":
        "torch-2.14.1+rocm7.2-cp314-cp314-manylinux_2_28_x86_64.whl torch-2.14.1%2Brocm7.14-cp314-cp314-manylinux_2_28_x86_64.whl "
        "torch-2.14.1+rocm7.20-cp313-cp313-manylinux_2_28_x86_64.whl torch-2.15.0+rocm8.0-cp314-cp314-manylinux_2_28_x86_64.whl"}[url]
bv.ls_remote_branch_commit = lambda url, branch: f"{url}#{branch}"
bv.WRITE_MODE = True
print("x264", bv.spec_x264_meson("164.3108-meson"), bv.spec_x264_meson("165.0-meson"))
print("rocm", bv.spec_pytorch_rocm_index("rocm7.2"))
PY
)"
t_assert_contains "${_out}" "oss v1.16 open-telemetry/opentelemetry-cpp@v1.23.0" \
  "each dep's tag is the script's --branch, and its commit is that tag's in that repo"
t_assert_contains "${_out}" "refused: install_opensource_deps.sh clones no civetweb/civetweb at a --branch" \
  "a dependency the script no longer clones is a lookup failure, never a stale pin"
t_assert_contains "${_out}" "derived ['CUDA_VERSION', 'DEEPSTREAM_VERSION'] 13" "the derived keys come from the specs' own tables"
t_assert_contains "${_out}" "x264 ('165.0-meson', {'X264_MESON_COMMIT': 'https://gitlab.example/x264.git#165.0-meson'}) ('165.0-meson', {})" \
  "the branch is the wrap's revision at GSTREAMER_VERSION, and a new one re-pins its head commit"
t_assert_contains "${_out}" "rocm ('rocm7.14', {})" \
  "the newest rocm line by number (7.14 over 7.2) for cp314 at PYTORCH_VERSION, not a cp313 or a newer torch's line"

t_case "spec_shellcheck --write refreshes all three shellcheck assets, the aarch64 tarball included (offline)"
_out="$(_bv_offline <<'PY'
bv.gh_latest = lambda repo, pattern=None: "v0.12.0"
bv.asset_sha256 = lambda repo, tag, asset, sums=(): asset
bv.WRITE_MODE = True
for k, v in sorted(bv.spec_shellcheck("v0.11.0")[1].items()):
    print(k, v)
PY
)"
t_assert_contains "${_out}" "SHELLCHECK_LINUX_AARCH64_SHA256 shellcheck-v0.12.0.linux.aarch64.tar.xz" \
  "the arm64-host asset moves with the version"
t_assert_contains "${_out}" "SHELLCHECK_LINUX_X86_64_SHA256 shellcheck-v0.12.0.linux.x86_64.tar.xz" "so does x86_64"
t_assert_contains "${_out}" "SHELLCHECK_WINDOWS_SHA256 shellcheck-v0.12.0.zip" "and the Windows zip"

t_case "the manifest-derived pins: CUDA arm64 redists, cuDNN arm64, TensorRT debs, a GStreamer wrap, HailoRT's protobuf (offline)"
_out="$(_bv_offline <<'PY'
manifest = {c: {"windows-arm64": {"relative_path": f"{c}/windows-arm64/{c}-windows-arm64-1.2.{i}-archive.zip",
                                  "sha256": f"{i:064d}"}}
            for i, (_, _, c) in enumerate(bv._CUDA_WINDOWS_ARM64_COMPONENTS)}
pins = bv.cuda_windows_arm64_pins(manifest)
print("cuda", len(pins), pins["CUDA_WINDOWS_ARM64_CUBLAS_VERSION"], pins["CUDA_WINDOWS_ARM64_CUPTI_SHA256"][-2:])
del manifest["libnpp"]["windows-arm64"]
try:
    bv.cuda_windows_arm64_pins(manifest)
except RuntimeError as e:
    print("refused:", e)
cudnn = {"cudnn": {"windows-arm64": {"cuda12": {"sha256": "12" * 32}, "cuda13": {"sha256": "13" * 32}}}}
print("cudnn", bv.cudnn_windows_arm64_sha256(cudnn, "cuda13")[:4])
stanzas = [{"Package": p, "Version": v, "SHA256": f"{p}@{v}"} for p in
           ("libnvinfer10", "libnvinfer-plugin10", "libnvonnxparsers10", "libnvinfer-headers-dev",
            "libnvinfer-headers-plugin-dev", "libnvonnxparsers-dev")
           for v in ("10.16.1.11-1+cuda12.9", "10.16.1.11-1+cuda13.2")]
print("trt", bv.deepstream_trt_pins(stanzas, "10.16.1.11", "13.2")["DEEPSTREAM_TRT_LIBNVINFER10_SHA256"])
bv.http_text = lambda url: ("[wrap-file]\ndirectory=dav1d-1.5.2\nsource_hash = " + "AB" * 32 + "\n"
                            if url.endswith("/1.30.0/subprojects/dav1d.wrap") else
                            "GIT_TAG         f0dc78d7e6e331b8c6bb2d5283e06aa26883ca7c # v21.12\n")
print("wrap", bv.gstreamer_wrap_pin("1.30.0", "dav1d")[0], bv.gstreamer_wrap_pin("1.30.0", "dav1d")[1][:4])
print("protobuf", bv.hailo_protobuf_version("5.4.0"))
PY
)"
t_assert_contains "${_out}" "cuda 20 1.2.1 09" "each arm64 component's version comes from its archive path, its SHA from the manifest"
t_assert_contains "${_out}" "refused: CUDA redist manifest has no windows-arm64 libnpp" "a missing component is a lookup failure"
t_assert_contains "${_out}" "cudnn 1313" "the arm64 cuDNN zip is the entry for CUDA_VERSION's major"
t_assert_contains "${_out}" "trt libnvinfer10@10.16.1.11-1+cuda13.2" "the TensorRT deb is the one built for the pinned CUDA"
t_assert_contains "${_out}" "wrap 1.5.2 abab" "dav1d's version and hash come from GStreamer's wrap at its tag, lower-cased"
t_assert_contains "${_out}" "protobuf 21.12" "HailoRT's protobuf is the version its FetchContent GIT_TAG names"

t_case "spec_deepstream: the newest tag whose OWN release carries the runtime deb wins (v9.1.0.x tags have none) (offline)"
_out="$(_bv_offline <<'PY'
bv.ls_remote_tags = lambda repo: ["v9.0.2", "v9.1.0", "v9.1.0.1", "v9.1.0.2"]
probed = []
bv.artifact_exists = lambda url: probed.append(url.rsplit("/", 2)[1]) or "/v9.1.0/" in url
bv.WRITE_MODE = False
print("picked", bv.spec_deepstream("9.0.2"), probed)
PY
)"
t_assert_contains "${_out}" "picked ('9.1.0', {}) ['v9.1.0.2', 'v9.1.0.1', 'v9.1.0']" \
  "release-less tags are skipped newest-first, never pinned"

t_summary
