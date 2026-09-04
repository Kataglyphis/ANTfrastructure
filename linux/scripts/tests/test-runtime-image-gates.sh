#!/usr/bin/env bash
# Two gates in smoke-runtime-image.sh that could not fail, and now can:
#   * the app-wheel ratchet fell back to exit-status-only when its ok-count did
#     not parse -- the very thing it exists to distrust (backlog WF);
#   * the HEALTHCHECK gates ran a hardcoded copy of the probe and read only
#     Test[0], the OCI verb, so a wrong HEALTHCHECK shipped green (backlog WE).
# smoke-runtime-image.sh runs against a live image, so the functions are
# extracted and their collaborators stubbed.
set -u
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${TESTS_DIR}/test-harness.sh"
SMOKE="${TESTS_DIR}/../06-packaging/smoke-runtime-image.sh"

_extract() {
  # Heredoc-aware: an awk that stops at the first ^} cuts these functions in half,
  # because the emitted probe text contains such lines itself.
  python3 - "${SMOKE}" "$1" <<'EXTRACT'
import io, sys
lines = io.open(sys.argv[1], encoding="utf-8").read().splitlines(True)
name = sys.argv[2]
start = next(i for i, l in enumerate(lines) if l.startswith(name + "() {"))
i, here = start + 1, None
while i < len(lines):
    line = lines[i]
    if here is None:
        if "<<'" in line:
            here = line.split("<<'", 1)[1].split("'", 1)[0]
        elif line.rstrip() == "}":
            break
    elif line.rstrip() == here:
        here = None
    i += 1
sys.stdout.write("".join(lines[start:i + 1]))
EXTRACT
}

# What every stubbed in-container run starts with: the smoke's pass/fail vocabulary.
_STUBS='set -u
    FAILURES=0
    fail() { printf "FAIL %s\n" "$*"; FAILURES=$((FAILURES+1)); }
    pass() { printf "PASS %s\n" "$*"; }'

# One run of a gate with its collaborators stubbed. HC is what the image reports
# as its healthcheck; WHEEL_OUT is what the app smoke prints; RUN_RC is what a
# command executed in the image returns.
_gate() {
  local fn="$1" hc="${2-}" wheel_out="${3-}" run_rc="${4-0}" hc_json
  if [ -n "${hc}" ]; then
    hc_json="$(python3 -c 'import json,sys; print(json.dumps([{"Config":{"Healthcheck":{"Test":["CMD-SHELL",sys.argv[1]]}}}]))' "${hc}")"
  else
    hc_json='[{"Config":{}}]'
  fi
  HC_JSON="${hc_json}" WHEEL_OUT="${wheel_out}" RUN_RC="${run_rc}" bash -c '
    '"${_STUBS}"'
    # Runs the REAL extraction program against a fixture, exactly as the live
    # helper does. Returning ${HC} directly would bypass the code under test.
    inspect_image_config() { printf "%s" "${HC_JSON}" | python3 -c "$1" 2>/dev/null || true; }
    _rt_run() { printf "%s\n" "${WHEEL_OUT}"; return "${RUN_RC}"; }
    _SMOKE_TORCH_EXPECTED=1
    '"$(_extract _rt_healthcheck_cmd)"'
    '"$(_extract "$1")"'
    '"${fn}"' img amd64
    printf "FAILURES=%s\n" "${FAILURES}"' 2>&1
}

# The three ratchet cases differ only in the summary line and what must appear.
_ratchet_says() {
  local summary="$1" want="$2" why="$3"
  t_assert_contains "$(_gate check_app_wheel_smoke "" "${summary}" 0)" "${want}" "${why}"
}

t_case "an unreadable ok-count fails instead of falling back to the exit status"
_ratchet_says "=== 15/15 passed, 0 failure(s) ===" "could not read the ok-count" \
  "a summary the ratchet cannot parse must fail, not pass with '?'"

t_case "a degraded count still fails"
_ratchet_says "=== 12/15 ok, 3 failure(s) ===" "degraded" "below the floor must fail"

t_case "a full count passes"
_ratchet_says "=== 15/15 ok, 0 failure(s) ===" "PASS app wheel smoke passed" \
  "at the floor must pass"

# ── WE: the healthcheck ──────────────────────────────────────────────────────
t_case "the healthcheck gate reads the command, not the OCI verb"
_out="$(_gate check_healthcheck_config '/opt/venv/bin/python3 -c "import onnxruntime" || exit 1')"
t_assert_contains "${_out}" "import onnxruntime" \
  "the configured probe itself must appear, not just CMD-SHELL"

t_case "a HEALTHCHECK with no command fails"
_out="$(_gate check_healthcheck_config "")"
t_assert_contains "${_out}" "FAIL" "an empty command must fail"

t_case "the exec gate runs the image's own command and reports it"
_out="$(_gate check_healthcheck_exec '/opt/venv/bin/python3 -c "import onnxruntime" || exit 1' "" 1)"
t_assert_contains "${_out}" "import onnxruntime" \
  "a failing healthcheck must name the command it actually ran"

# ── the probe is emitted in three parts and must still be one program ────────
t_case "the shipped-truth probe still emits all three of its sections"
# Nothing else guards the concatenation: the ADV printfs stay in the file even if
# a part is dropped from the caller, so the advertised-keys gate would not notice.
_probe="$(bash -c '
  '"$(_extract _probe_advertised)"'
  '"$(_extract _probe_actual_versions)"'
  '"$(_extract _probe_venv_inventory)"'
  '"$(_extract _probe_elf_and_sonames)"'
  '"$(_extract _shipped_truth_probe)"'
  _shipped_truth_probe' 2>/dev/null)"
t_assert_contains "${_probe}" "ADV PYTHON_MAJOR_MINOR"  "the advertised section must be there"
t_assert_contains "${_probe}" "HAVE PYTHON_MAJOR_MINOR" "the actual-versions section must be there"
t_assert_contains "${_probe}" "REQ"                 "the venv inventory section must be there"
t_assert_contains "${_probe}" "SONAME"              "the inventory section must be there"

# ── XQ: the default-boot gate must test what only the entrypoint provides ────
_boot() {
  bash -c '
    '"${_STUBS}"'
    '"$(_extract _boot_verdict)"'
    _boot_verdict "$1" "$2" amd64' _ "$1" "$2" 2>&1
}

t_case "a boot that did not reach the script fails"
t_assert_contains "$(_boot 1 "")" "FAIL" "the entrypoint must exec the command and propagate 42"

t_case "the image ENV alone is NOT enough to pass"
# This is the whole point: GST_PLUGIN_PATH and VULKAN_SDK are set by the image
# ENV, so the old gst=set/vulkan=set assertion answered yes with the entrypoint's
# sourcing gone. Measured in the shipped image before changing this.
t_assert_contains "$(_boot 42 "BOOT uid=0 gst=set vulkan=set
gstma=no
vkres=no")" "did not source gstreamer-env.sh" \
  "set-ness of a var the image already exports proves nothing"

t_case "a resolved VULKAN_SDK is required too"
t_assert_contains "$(_boot 42 "gstma=yes
vkres=no")" "did not resolve VULKAN_SDK" "the entrypoint resolves it past /opt/vulkan/active"

t_case "the real shipped shape passes"
t_assert_contains "$(_boot 42 "BOOT uid=0 gst=set vulkan=set
gstma=yes
vkres=yes")" "PASS" "what the published image actually prints"

# The rust gate with the container stubbed: RUST_OUT is what the image prints for
# rustc --version / rustup show active-toolchain / command -v cargo-cbuild.
_rust() {
  RUST_OUT="$1" bash -c '
    '"${_STUBS}"'
    _rt_run() { printf "%s\n" "${RUST_OUT}"; }
    smoke_rust_target() { printf "x86_64-unknown-linux-gnu"; }
    _rt_versions_env_pin() { printf "1.98.0"; }
    '"$(_extract check_rust_toolchain)"'
    check_rust_toolchain img amd64' 2>&1
}

t_case "the 2026-09-03 shipped shape (builder-arch rustup, exit 127) fails"
t_assert_contains "$(_rust "bash: line 1: rustc: cannot execute: required file not found")"   "FAIL rustc does not run" "a toolchain that cannot execute is not a toolchain"

t_case "a rustc that runs but is not the image's own triple fails"
t_assert_contains "$(_rust "rustc 1.98.0 (88d9e12ae 2026-08-18)
1.98.0-aarch64-unknown-linux-gnu (default)
/usr/local/cargo/bin/cargo-cbuild")" "is not x86_64-unknown-linux-gnu" "the ADV/HAVE table cannot see the host triple"

t_case "a version skew against the RUST_VERSION pin fails"
t_assert_contains "$(_rust "rustc 1.93.1 (ubuntu)
1.93.1-x86_64-unknown-linux-gnu (default)
/usr/bin/cargo-cbuild")" "FAIL rustc does not run or is not RUST_VERSION=1.98.0" "the apt fallback must not pass"

t_case "a native toolchain without cargo-cbuild fails"
t_assert_contains "$(_rust "rustc 1.98.0 (88d9e12ae 2026-08-18)
1.98.0-x86_64-unknown-linux-gnu (default)")" "cargo-cbuild missing" "the apt cargo-c fallback is part of the contract"

t_case "the native shape passes"
t_assert_contains "$(_rust "rustc 1.98.0 (88d9e12ae 2026-08-18)
1.98.0-x86_64-unknown-linux-gnu (default)
/usr/local/cargo/bin/cargo-cbuild")" "PASS rustc 1.98.0 runs natively as x86_64-unknown-linux-gnu" "what a correct image prints"

# The flutter gate with the container stubbed: FLUTTER_OUT is what the image prints
# for `flutter --version | grep ^Flutter` and `readelf -h dart | grep Machine`; ARGS
# records the nerdctl options the gate asked for. $2 = target arch.
_flutter() {
  local opts; opts="$(mktemp)"
  FLUTTER_OUT="$1" OPTS="${opts}" bash -c '
    '"${_STUBS}"'
    _rt_run() { printf "opts=%s\n" "$*" > "${OPTS}"; printf "%s\n" "${FLUTTER_OUT}"; }
    smoke_elf_machine_grep() { case "$1" in amd64) printf "X86-64";; arm64) printf "AArch64";; esac; }
    _rt_versions_env_pin() { printf "3.47.1"; }
    '"$(_extract check_flutter)"'
    check_flutter img '"${2:-arm64}"'' 2>&1
  cat "${opts}"; rm -f "${opts}"
}

t_case "the flutter gate runs the image offline"
t_assert_contains "$(_flutter "Flutter 3.47.1 • channel stable
  Machine:                           AArch64")" "opts=--network none bash" "a cache that still downloads at runtime must not pass"

t_case "an SDK that cannot run as the image user fails (the root-owned bin/cache shape)"
t_assert_contains "$(_flutter "/opt/flutter/bin/internal/update_engine_version.sh: line 71: /opt/flutter/bin/cache/engine.stamp.tmp.3038: Permission denied")" \
  "FAIL flutter does not run offline as the image user" "what the uid-1001 runtime user saw on 2026-09-03"

t_case "a version other than the FLUTTER_VERSION pin fails"
t_assert_contains "$(_flutter "Flutter 3.44.9 • channel stable
  Machine:                           AArch64")" "is not FLUTTER_VERSION=3.47.1" "the pin is the contract"

t_case "a Dart SDK of the builder's arch in the arm64 image fails even though it ran"
t_assert_contains "$(_flutter "Flutter 3.47.1 • channel stable
  Machine:                           Advanced Micro Devices X86-64")" "the cached Dart SDK is not AArch64 on arm64" "an x86-64 dart executes natively on this host"

t_case "the bootstrapped shape passes"
t_assert_contains "$(_flutter "Flutter 3.47.1 • channel stable
  Machine:                           AArch64")" "PASS flutter 3.47.1 runs offline as the image user on a AArch64 Dart SDK (arm64)" "what a correct arm64 image prints"


# ── advertised keys: neither "the image did not tell us" arm may be a SKIP ───
# check_advertised_versions with the verdict function stubbed: VERDICTS is what
# _advert_verdicts would print for the probe.
_advert_gate() {
  VERDICTS="$1" bash -c '
    '"${_STUBS}"'
    _advert_verdicts() { printf "%s\n" "${VERDICTS}"; }
    _SHIPPED_TRUTH_PROBE=""
    _SHIPPED_TRUTH_PROBE_RC=0
    '"$(_extract check_advertised_versions)"'
    check_advertised_versions img amd64' 2>&1
}

t_case "an unset key fails the gate instead of printing a SKIP"
t_assert_contains "$(_advert_gate "UNSET RUST_VERSION")" "could only ever SKIP" \
  "a row that cannot fail is the hole that hid eleven ARG-only keys"

t_case "an unreadable actual value fails the gate"
t_assert_contains "$(_advert_gate "UNREAD RUST_VERSION 1.98.0")" "could NOT read the actual value" \
  "the rust defect shape: rustc did not run and the gate said SKIP"

t_case "a verdict verb no arm handles fails instead of being dropped"
# The case had no default arm, so any new verb would have vanished silently --
# the same class as the SKIP arms themselves.
t_assert_contains "$(_advert_gate "WHAT RUST_VERSION 1.98.0")" "unknown verdict" \
  "an unhandled verb is a silently dropped row"

t_case "an EMPTY verdict table is a vacuous pass, not a green image"
# The whole gate reduces to "check every advertised key" -- so a key list that
# came back empty asserts nothing at all, which is the same hole one level up.
t_assert_contains "$(_advert_gate "")" "asserted NOTHING" \
  "an empty table must fail, not print PASS all 0"
t_assert_eq 0 "$(printf '%s' "$(_advert_gate "")" | grep -c 'PASS all')" \
  "and it must not read as a pass while doing so"

t_case "a clean table still passes"
t_assert_contains "$(_advert_gate "OK RUST_VERSION 1.98.0")" "PASS all 1 advertised" \
  "the gate must still be able to pass"

# ── HT1: the manifest trees must carry the image's own arch ──────────────────
# The scanner is the real program from the smoke, run against a fixture tree of
# hand-written ELF headers -- the only way to prove it reads e_machine and not
# some other header word.
_HT1_FIX="$(mktemp -d)"
mkdir -p "${_HT1_FIX}"/{native,builder,empty}/bin
t_fake_elf "${_HT1_FIX}/native/bin/dart" 183
t_fake_elf "${_HT1_FIX}/native/bin/rustc" 183
t_fake_elf "${_HT1_FIX}/builder/bin/rustc" 62
printf 'not an ELF\n' > "${_HT1_FIX}/empty/bin/README"

_scan() {
  RT_TREES="$*" RT_TREE_CAP="${RT_TREE_CAP:-}" bash -c '
    '"$(_extract _tree_arch_py)"'
    RT_TREES="${RT_TREES}" python3 -c "$(_tree_arch_py)"' 2>&1
}
_SCAN_OUT="$(_scan "${_HT1_FIX}/native" "${_HT1_FIX}/builder" "${_HT1_FIX}/empty" "${_HT1_FIX}/gone")"

t_case "the scanner reads the ELF machine of what a tree actually ships"
t_assert_contains "${_SCAN_OUT}" "TREE ${_HT1_FIX}/native AArch64 2" "two aarch64 objects"
t_assert_contains "${_SCAN_OUT}" "TREE ${_HT1_FIX}/builder X86-64 1" "the builder-arch tree names its machine"
t_assert_contains "${_SCAN_OUT}" "TREENOELF ${_HT1_FIX}/empty" "a per-arch empty tree is not a machine"
t_assert_contains "${_SCAN_OUT}" "TREEMISS ${_HT1_FIX}/gone" "a declared tree that is absent must be reported"
t_assert_contains "${_SCAN_OUT}" "TREESCAN_DONE" "exit status is not evidence; the sentinel is"

_verdicts() {
  bash -c '
    '"$(_extract _tree_arch_verdicts)"'
    _tree_arch_verdicts "$1" "$2"' _ "$1" "$2" 2>&1
}

t_case "a builder-arch tree in a foreign image is BAD, not a note"
t_assert_contains "$(_verdicts "${_SCAN_OUT}" AArch64)" "BAD ${_HT1_FIX}/builder X86-64 1" \
  "the 2 GB x86_64 rustup shipped in every arm64 image for months"
t_assert_contains "$(_verdicts "${_SCAN_OUT}" AArch64)" "OK ${_HT1_FIX}/native AArch64 2" \
  "a target-arch tree must still pass"

t_case "the same trees on the builder's own arch flip the verdict"
t_assert_contains "$(_verdicts "${_SCAN_OUT}" X86-64)" "BAD ${_HT1_FIX}/native AArch64" \
  "the machine is compared against THIS image's arch, not against x86_64"

t_case "a scan that found no tree at all is a vacuous pass, not a pass"
t_assert_contains "$(_verdicts "TREESCAN_DONE" AArch64)" "NONE" "nothing asserted must be reportable"

t_case "a huge tree cannot crowd the shipped binaries out of the scan"
# The rustup layout that motivated this gate carries tens of thousands of rust-src
# .rs files under toolchains/*/lib, sorted BEFORE toolchains/*/bin/rustc — the one
# object that shipped as x86_64 for months. Candidates are read first for that reason.
# The real shape: /usr/local/rustup holds TWO toolchains, so the first one's
# rust-src sorts ahead of the second one's bin/ and starves it.
_HT1_BIG="$(mktemp -d)"
mkdir -p "${_HT1_BIG}/tree/toolchains/a-stable/lib/src" "${_HT1_BIG}/tree/toolchains/b-nightly/bin"
_i=0; while [ "${_i}" -lt 60 ]; do printf 'source\n' > "${_HT1_BIG}/tree/toolchains/a-stable/lib/src/mod_${_i}.rs"; _i=$((_i + 1)); done
t_fake_elf "${_HT1_BIG}/tree/toolchains/b-nightly/bin/rustc" 62
chmod +x "${_HT1_BIG}/tree/toolchains/b-nightly/bin/rustc"
_out="$(RT_TREE_CAP=20 _scan "${_HT1_BIG}/tree")"
t_assert_contains "${_out}" "X86-64 1" "the second toolchain's binary is found though 60 sources of the first sort ahead of it"
t_assert_contains "${_out}" "TREECAP" "and the walk still reports that it did not finish"

t_case "a walk that ran out of budget is not a pass"
t_assert_contains "$(_verdicts "TREECAP /x 20
TREESCAN_DONE" AArch64)" "CAPPED /x" "a partial scan must reach the verdict layer, not be an INFO line"
rm -rf "${_HT1_BIG}"

# The gate itself with the container stubbed: SCAN is what the image's scanner printed.
_ht1_gate() {
  SCAN="$1" WANT="$2" bash -c '
    '"${_STUBS}"'
    _rt_run() { printf "%s\n" "${SCAN}"; }
    smoke_elf_machine_grep() { printf "%s" "${WANT}"; }
    _rt_manifest_trees() { printf "%s\n" "'"${_HT1_FIX}"'/native"; }
    _rt_tree_arch_exempt() { return 1; }
    '"$(_extract _tree_arch_verdicts)"'
    '"$(_extract _tree_arch_py)"'
    '"$(_extract check_manifest_tree_arch)"'
    check_manifest_tree_arch img arm64' 2>&1
}

t_case "the gate fails on a builder-arch tree"
t_assert_contains "$(_ht1_gate "${_SCAN_OUT}" AArch64)" "FAIL" "a BAD verdict must reach the summary"

t_case "a scanner that never ran fails instead of passing empty"
t_assert_contains "$(_ht1_gate "python3: command not found" AArch64)" "could not run" \
  "no TREESCAN_DONE marker means the gate asserted nothing"

t_case "the correct shape passes"
t_assert_contains "$(_ht1_gate "TREE ${_HT1_FIX}/native AArch64 2 x
TREESCAN_DONE" AArch64)" "PASS all 1 asserted artifact tree(s)" "what a correct image prints"

rm -rf "${_HT1_FIX}"

# ── HT1: the host-side halves of the gate agree with their other owners ──────
t_case "every manifest path resolves to a real absolute path"
_TREES="$(bash -c '
  _SCRIPT_DIR="'"${TESTS_DIR}/../06-packaging"'"
  '"$(_extract _rt_tree_probe_path)"'
  '"$(_extract _rt_manifest_trees)"'
  _rt_manifest_trees' 2>&1)"
t_assert_eq "" "$(printf '%s\n' "${_TREES}" | grep -e UNRESOLVED)" \
  "an unresolved \${VAR} would scan nothing and say nothing"
t_assert_eq "" "$(printf '%s\n' "${_TREES}" | grep -ve '^/')" \
  "every resolved tree must be an absolute path"
t_assert_contains "${_TREES}" "/opt/opencv5" "\${OPENCV_OUTPUT_DIR} comes from Dockerfile.package's ARG default"

t_case "the Vulkan tree is probed at what VULKAN_SDK resolves to"
# /opt/vulkan carries the SDK's x86_64 HOST tools (glslang, spirv-tools -- built for
# the build host, never loaded by a cross consumer) beside the cross-built target
# libs under active/. Scanning the whole tree would red every foreign image on
# purpose-built host tooling; scanning active/ asserts exactly what the image runs.
t_assert_contains "${_TREES}" "/opt/vulkan/active" "the host-tool half of the SDK is not this image's to assert"

t_case "the one documented COPY relocation is applied, not the source path"
# verify-artifact-copy-parity.sh's ALLOWED_RELOCATIONS is the other owner of this
# fact; the manifest carries the COPY SOURCE, which does not exist in the image.
_RELOC="$(sed -n 's/^  "\(\/[^ ]*\) \(\/[^"]*\)"$/\1 \2/p' "${TESTS_DIR}/../verify-artifact-copy-parity.sh")"
t_assert_contains "${_RELOC}" "/" "ALLOWED_RELOCATIONS moved or changed shape -- this cross-check reads nothing"
while read -r _src _dst; do
  [ -n "${_src}" ] || continue
  t_assert_contains "${_TREES}" "${_dst}" "relocated ${_src} must be probed at ${_dst}"
done < <(printf '%s\n' "${_RELOC}")

t_case "every arch-exempt tree is still a declared artifact"
# An exemption for a tree nobody ships any more silently narrows the gate.
eval "$(sed -n '/^_RT_TREE_ARCH_EXEMPT=/p' "${SMOKE}")"
t_assert_contains "${_RT_TREE_ARCH_EXEMPT}" "/opt/" "the exemption list moved -- this cross-check reads nothing"
for _t in ${_RT_TREE_ARCH_EXEMPT}; do
  t_assert_contains "${_TREES}" "${_t}" "exempt tree ${_t} is no longer in the manifest"
done

t_summary
