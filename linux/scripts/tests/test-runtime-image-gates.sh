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
_flut_ok="$(_flutter "Flutter 3.47.1 • channel stable
  Machine:                           AArch64")"
t_assert_contains "${_flut_ok}" "PASS flutter 3.47.1 runs offline as the image user on a AArch64 Dart SDK, whole SDK owned and writable by that user (arm64)" "what a correct arm64 image prints"

t_case "the gate asks whether the SDK is USABLE, not merely runnable"
t_assert_contains "${_flut_ok}" '[ -w "$d" ] || printf "UNWRITABLE' "flutter --version ran green for a whole ship while pub get could not write .dart_tool"
t_assert_contains "${_flut_ok}" '/opt/flutter/packages/flutter_tools/.dart_tool' "the exact dir pub get opens package_config.json in"
t_assert_contains "${_flut_ok}" 'find /opt/flutter ! -user "$(id -u)"' "and no path in the SDK may belong to anyone but the image user"

t_case "a root-owned .dart_tool fails even though flutter runs (the 2026-09-04 shipped shape)"
t_assert_contains "$(_flutter "Flutter 3.47.1 • channel stable
  Machine:                           AArch64
UNWRITABLE /opt/flutter/packages/flutter_tools/.dart_tool")" \
  "FAIL the shipped SDK is not writable by the image user (arm64): UNWRITABLE /opt/flutter/packages/flutter_tools/.dart_tool" \
  "consumers cannot chown it at runtime -- it sits in a read-only layer"

t_case "root-owned leftovers anywhere in the SDK fail"
t_assert_contains "$(_flutter "Flutter 3.47.1 • channel stable
  Machine:                           AArch64
FOREIGN /opt/flutter/.git/FETCH_HEAD")" \
  "FAIL the shipped SDK still holds paths the image user does not own (arm64): FOREIGN /opt/flutter/.git/FETCH_HEAD" \
  "the 34 git internals a root-run flutter fetch left behind are the same defect, one command later"


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

t_case "a cross toolchain's target payload is not a defect, but its own binaries still are"
# The 2026-09-05 false positives: /opt/gcc-*/aarch64-linux-gnu, rustup's
# lib/rustlib/<triple> and clang's lib/clang/*/lib/linux hold foreign ELF BY DESIGN.
# The exemption must not reach the thing HT1 was written for: a builder-arch rustc.
_XT="$(mktemp -d)"
mkdir -p "${_XT}/rustup/toolchains/1.98.0-x86_64-unknown-linux-gnu"/{bin,lib/rustlib/aarch64-unknown-linux-gnu/lib}
mkdir -p "${_XT}/gcc-16.2.0"/{bin,aarch64-linux-gnu/lib64,lib/gcc/riscv64-linux-gnu/16.2.0} "${_XT}/llvm/lib/clang/23/lib/linux" "${_XT}/llvm/bin"
t_fake_elf "${_XT}/rustup/toolchains/1.98.0-x86_64-unknown-linux-gnu/lib/rustlib/aarch64-unknown-linux-gnu/lib/libstd.so" 183
t_fake_elf "${_XT}/gcc-16.2.0/aarch64-linux-gnu/lib64/libatomic.so.1" 183
t_fake_elf "${_XT}/gcc-16.2.0/lib/gcc/riscv64-linux-gnu/16.2.0/crtbegin.o" 243
t_fake_elf "${_XT}/llvm/lib/clang/23/lib/linux/libclang_rt.asan-i386.so" 3
t_fake_elf "${_XT}/rustup/toolchains/1.98.0-x86_64-unknown-linux-gnu/bin/rustc" 183
t_fake_elf "${_XT}/gcc-16.2.0/bin/gcc" 183
t_fake_elf "${_XT}/llvm/bin/clang" 183
_out="$(_scan "${_XT}/rustup" "${_XT}/gcc-16.2.0" "${_XT}/llvm")"
t_assert_eq 0 "$(printf '%s\n' "${_out}" | grep -c 'Intel-80386')" "clang's multilib runtimes are its target payload"
for _t in rustup gcc-16.2.0 llvm; do
  t_assert_contains "${_out}" "TREE ${_XT}/${_t} AArch64 1" \
    "${_t}: exactly ONE object left to assert -- its own binary, not the target payload"
done
rm -rf "${_XT}"

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

# Every needle of a table read out of ANOTHER owner of the same fact must appear in
# ${haystack}, sentinel first so a table that moved fails loudly instead of iterating
# over nothing. Three cross-checks had copied this shape.
_t_all_present() {
  local haystack="$1" needles="$2" sentinel="$3" why="$4" n
  t_assert_contains "${needles}" "${sentinel}" "the source table moved -- '${why}' reads nothing"
  while IFS= read -r n; do
    [ -n "${n}" ] || continue
    t_assert_contains "${haystack}" "${n}" "${why}: ${n}"
  done < <(printf '%s\n' "${needles}")
}

t_case "the one documented COPY relocation is applied, not the source path"
# verify-artifact-copy-parity.sh's ALLOWED_RELOCATIONS is the other owner of this
# fact; the manifest carries the COPY SOURCE, which does not exist in the image.
_RELOC="$(sed -n 's/^  "\/[^ ]* \(\/[^"]*\)"$/\1/p' "${TESTS_DIR}/../verify-artifact-copy-parity.sh")"
_t_all_present "${_TREES}" "${_RELOC}" "/" "every ALLOWED_RELOCATIONS destination must be the path the gate probes"

t_case "every arch-exempt tree is still a declared artifact"
# An exemption for a tree nobody ships any more silently narrows the gate.
eval "$(sed -n '/^_RT_TREE_ARCH_EXEMPT=/p' "${SMOKE}")"
_t_all_present "${_TREES}" "$(printf '%s\n' ${_RT_TREE_ARCH_EXEMPT})" "/opt/" \
  "every arch-exempt tree must still be a declared artifact"

t_case "the arch-exempt table is what the images MEASURED, not what the graph suggested"
# HT2, measured on the three images shipped 2026-09-05. /opt/android-sdk is one
# linux-x86_64 tree copied unchanged into all three (582 X86-64 objects in the arm64
# and riscv64 images), so it stays. /opt/android was exempt on the same "device .so"
# reasoning and the scan refuted it: 37 X86-64 on amd64, 37 AArch64 on arm64, 34
# RISC-V on riscv64 and NOTHING else, because arch_android_abi_for maps each build
# arch to the ABI with the same ELF machine.
t_assert_contains " ${_RT_TREE_ARCH_EXEMPT} " " /opt/android-sdk " \
  "the SDK's host toolchain is genuinely not this image's to assert"
t_assert_eq 0 "$(printf '%s\n' ${_RT_TREE_ARCH_EXEMPT} | grep -cxF -- '/opt/android' || true)" \
  "/opt/android carries the image's OWN machine on all three arches -- asserting it is free"
t_assert_contains "$(sed -n '/^arch_android_abi_for() {$/,/^}$/p' "${TESTS_DIR}/../01-core/platform.sh")" \
  'arm64) printf '"'"'%s'"'"' "arm64-v8a"' "the mapping the deletion rests on: one ABI per arch, same machine"

t_case "an ELF machine label may not contain a space"
# The verdict line is read back with `read -r verb tree machine count sample`, so a
# label with a space eats the count column: the 2026-09-04 run printed
# "ships 80386 Intel object(s) ... e.g. 6 /usr/local/llvm-target/..." and the frozen
# lookup, which keys on the machine, could never have matched it.
_EM_LABELS="$(_extract _tree_arch_py | sed -n 's/^EM = {\(.*\)}$/\1/p' | tr ',' '\n' \
                | sed -n 's/.*: "\([^"]*\)".*/\1/p')"
t_assert_contains "${_EM_LABELS}" "X86-64" "the EM table moved -- this case reads nothing"
while IFS= read -r _label; do
  [ -n "${_label}" ] || continue
  t_assert_eq "1" "$(printf '%s\n' ${_label} | wc -l | tr -d ' ')" \
    "EM label '${_label}' must be one word"
done < <(printf '%s\n' "${_EM_LABELS}")
t_assert_contains "$(_verdicts "TREE /x Intel-80386 6 /x/libclang_rt.asan-i386.so
TREESCAN_DONE" AArch64)" "BAD /x Intel-80386 6 /x/libclang_rt.asan-i386.so" \
  "count and sample must survive a non-target machine name"

# ── the consumer contract: the four defects a consuming lane reported ────────
# Probe text as the gate would have seen it in :latest-cross-amd64 on 2026-09-04.
# Every line was measured in the shipped image, not invented.
_CC_SHIPPED='WHO 1001 kataglyphis
WRITE ccache-dir no
ENV ccache-dir /workspace/.ccache
WRITE sccache-dir no
ENV sccache-dir /workspace/.sccache
WRITE rustup-tmp no
ENV rustup-tmp /usr/local/rustup/tmp
WRITE cargo-home no
ENV cargo-home /usr/local/cargo
WRITE dart-tool no
ENV dart-tool /opt/flutter/packages/flutter_tools/.dart_tool
ENV android-home
ENV android-sdk-root
DIR android-platform-tools yes
FACT android-path no
FACT flutter-sdk yes
FACT flutter-foreign 37
FACT flutter-foreign-examples /opt/flutter/.git/FETCH_HEAD /opt/flutter/.git/refs/tags
CCPROBE_DONE'

# The same image once every lane has landed.
_CC_FIXED='WHO 1001 kataglyphis
WRITE ccache-dir yes
ENV ccache-dir /var/cache/ccache
WRITE sccache-dir yes
ENV sccache-dir /var/cache/sccache
WRITE rustup-tmp yes
ENV rustup-tmp /usr/local/rustup/tmp
WRITE cargo-home yes
ENV cargo-home /usr/local/cargo
WRITE dart-tool yes
ENV dart-tool /opt/flutter/packages/flutter_tools/.dart_tool
ENV android-home /opt/android-sdk
ENV android-sdk-root /opt/android-sdk
DIR android-platform-tools yes
FACT android-path yes
FACT flutter-sdk yes
FACT flutter-foreign 0
FACT flutter-foreign-examples
CCPROBE_DONE'

# The row list is read from the smoke itself, so a shortened table shortens the
# tests too instead of leaving them asserting a copy.
_CC_ROWS_SRC="$(sed -n '/^_CONSUMER_CONTRACT_ROWS=/p' "${SMOKE}")"
t_assert_contains "${_CC_ROWS_SRC}" "ccache-dir" "the row list moved -- every case below reads nothing"
eval "${_CC_ROWS_SRC}"

_CC_PARTS="${_CC_ROWS_SRC}
$(_extract _consumer_contract_exempt)
$(_extract _consumer_exempt_fact)
$(_extract _consumer_contract_fact)
$(_extract _consumer_dir_verdict)
$(_extract _consumer_exempt_verdict)
$(_extract _consumer_android_verdict)
$(_extract _consumer_owner_verdict)
$(_extract _consumer_probe_verdict)
$(_extract _consumer_contract_verdicts)"

# Verdict lines for one probe capture on one arch. $3 overrides the row table.
_cc_verdicts() {
  CC_PROBE="$1" CC_ROWS="${3-}" bash -c '
    '"${_CC_PARTS}"'
    [ -z "${CC_ROWS}" ] || _CONSUMER_CONTRACT_ROWS="${CC_ROWS}"
    _consumer_contract_verdicts "$1" "${CC_PROBE}"' _ "$2" 2>&1
}

t_case "the shipped image fails every row the consumer reported"
_CC_OUT="$(_cc_verdicts "${_CC_SHIPPED}" amd64)"
t_assert_contains "${_CC_OUT}" "BAD ccache-dir points into the bind-mounted checkout: /workspace/.ccache" \
  "defect 1: the cache lands in the consumer's own repository"
t_assert_contains "${_CC_OUT}" "BAD sccache-dir points into the bind-mounted checkout: /workspace/.sccache" \
  "defect 1, second half"
t_assert_contains "${_CC_OUT}" "BAD rustup-tmp not writable by the image user: /usr/local/rustup/tmp" \
  "defect 2: rustup cannot write its temp files"
t_assert_contains "${_CC_OUT}" "BAD cargo-home not writable by the image user: /usr/local/cargo" \
  "defect 2, second half"
t_assert_contains "${_CC_OUT}" "BAD android-home ANDROID_HOME=<unset>" \
  "defect 3: the SDK ships but nothing points at it"
t_assert_contains "${_CC_OUT}" "BAD dart-tool not writable by the image user" \
  "defect 4: flutter pub get cannot write package_config.json"
t_assert_contains "${_CC_OUT}" "BAD flutter-owner 37 path(s) under /opt/flutter are not owned by the runtime uid" \
  "defect 4, second half -- and the count must survive to the message"
t_assert_contains "${_CC_OUT}" "ASSERTED 0" "a wholly non-compliant image asserts nothing"

t_case "with only the ENV half of the fix, today's bytes leave exactly the two ownership rows red"
# MEASURED 2026-09-04: _consumer_contract_probe run verbatim in :latest-cross-amd64
# as uid 1001 with the ENV Dockerfile.package now bakes returned _CC_FIXED except
# for the three ownership facts below. It separates what this session could confirm
# on shipped bytes -- defects 1 and 3 are ENV-only, /var/cache/{c,sc}cache is already
# 1777 and the appended PATH survives bash -lc -- from what only the rebuild's
# chown can settle. Derived from _CC_FIXED so the two captures cannot drift apart.
_CC_ENVFIX="$(printf '%s\n' "${_CC_FIXED}" \
  | sed -e 's#^WRITE rustup-tmp yes#WRITE rustup-tmp no#' \
        -e 's#^WRITE cargo-home yes#WRITE cargo-home no#' \
        -e 's#^WRITE dart-tool yes#WRITE dart-tool no#' \
        -e 's#^FACT flutter-foreign 0#FACT flutter-foreign 37#')"
_CC_ENVFIX="$(_cc_verdicts "${_CC_ENVFIX}" amd64)"
t_assert_contains "${_CC_ENVFIX}" "OK ccache-dir /var/cache/ccache" "defect 1 needs no chown, only the bake"
t_assert_contains "${_CC_ENVFIX}" "OK sccache-dir /var/cache/sccache" "defect 1, second half"
t_assert_contains "${_CC_ENVFIX}" "OK android-home /opt/android-sdk" \
  "defect 3: both variables, the directory and both PATH entries -- exactly what Dockerfile.package appends, no more"
t_assert_contains "${_CC_ENVFIX}" "BAD rustup-tmp" "defect 2 still needs the COPY --chown to be built"
t_assert_contains "${_CC_ENVFIX}" "BAD flutter-owner 37 path(s)" "defect 4 still needs the same-RUN handover to be built"
t_assert_contains "${_CC_ENVFIX}" "ASSERTED 3" "three of the seven rows hold on today's bytes"

t_case "a cache dir inside the checkout fails even when it IS writable"
# The writable arm alone would have passed the shipped shape on a host where
# /workspace is a writable bind mount, which is every consumer's normal case.
t_assert_contains "$(_cc_verdicts 'WRITE ccache-dir yes
ENV ccache-dir /workspace/.ccache
CCPROBE_DONE' amd64 ccache-dir)" "BAD ccache-dir points into the bind-mounted checkout" \
  "location and writability are two separate assertions"

t_case "a dir outside the checkout that cannot be written fails"
t_assert_contains "$(_cc_verdicts 'WRITE ccache-dir no
ENV ccache-dir /var/cache/ccache
CCPROBE_DONE' amd64 ccache-dir)" "BAD ccache-dir not writable" "moving the cache out is only half the fix"

t_case "an unset directory variable fails instead of being skipped"
t_assert_contains "$(_cc_verdicts 'WRITE cargo-home no
ENV cargo-home
CCPROBE_DONE' amd64 cargo-home)" "BAD cargo-home the variable is unset" \
  "an empty value is a defect, not an absent row"

t_case "a row the probe never reported fails instead of passing"
t_assert_contains "$(_cc_verdicts 'CCPROBE_DONE' amd64 cargo-home)" "NOFACT cargo-home" \
  "no WRITE line means the gate could not judge the row"
t_assert_contains "$(_cc_verdicts 'CCPROBE_DONE' amd64 flutter-owner)" "NOFACT flutter-owner" \
  "the ownership row must not read a missing count as zero"
t_assert_contains "$(_cc_verdicts 'CCPROBE_DONE' amd64 android-home)" "NOFACT android-home" \
  "a missing DIR line must not read as an existing platform-tools"

# An android capture with both variables set: $1 = DIR android-platform-tools,
# $2 = FACT android-path. One shape, so the two halves of the row differ by the
# fact under test and nothing else.
_cc_android() {
  _cc_verdicts "ENV android-home /opt/android-sdk
ENV android-sdk-root /opt/android-sdk
DIR android-platform-tools $1
FACT android-path $2
CCPROBE_DONE" amd64 android-home
}

t_case "ANDROID_HOME set at a path with no platform-tools fails"
t_assert_contains "$(_cc_android no yes)" "platform-tools does not exist" \
  "an exported variable is not an SDK"

t_case "an SDK that is set and present but not on PATH still fails"
# flutter finds it by variable; sdkmanager, adb and avdmanager are found by PATH,
# and the consumer asked for both halves.
t_assert_contains "$(_cc_android yes no)" "is on PATH" "half a wiring is not the contract"

t_case "the android row asserts exactly the two PATH entries Dockerfile.package appends"
t_assert_contains "$(_cc_android yes yes)" "OK android-home" \
  "platform-tools + cmdline-tools/latest/bin is the whole claim -- build-tools and the NDK are deliberately off PATH"

# HT2: what the riscv64 image ACTUALLY reports, read out of the shipped bytes on
# 2026-09-05 -- /opt/flutter exists and is empty, so .dart_tool is absent (the row
# would read unwritable) while `find /opt/flutter ! -uid 1001` is 0 (the row holds).
# Only the first of those needs an exemption.
t_case "the riscv64 flutter rows: dart-tool is exempt, flutter-owner is ASSERTED"
_CC_RV="$(_cc_verdicts 'WRITE ccache-dir yes
ENV ccache-dir /var/cache/ccache
WRITE dart-tool no
ENV dart-tool /opt/flutter/packages/flutter_tools/.dart_tool
FACT flutter-sdk no
FACT flutter-foreign 0
CCPROBE_DONE' riscv64)"
t_assert_contains "${_CC_RV}" "EXEMPT dart-tool" "upstream ships no riscv64 Flutter SDK"
t_assert_contains "${_CC_RV}" "OK flutter-owner" \
  "an empty tree owned by the runtime uid is the row PASSING, not a row to skip"
t_assert_eq 0 "$(printf '%s\n' "${_CC_RV}" | grep -c '^BAD dart-tool')" \
  "the unwritable .dart_tool of an EMPTY riscv64 tree is not a defect"

t_case "a root-owned riscv64 /opt/flutter is now a DEFECT there too"
# The exemption used to hide CC1 defect 4 on riscv64: 37 root-owned paths would
# have read as a documented exception.
t_assert_contains "$(_cc_verdicts 'FACT flutter-sdk no
FACT flutter-foreign 37
FACT flutter-foreign-examples /opt/flutter/bin
CCPROBE_DONE' riscv64 flutter-owner)" "BAD flutter-owner 37 path(s)" \
  "the ownership row must be able to go red on every arch"

t_case "the exemption fails the day a riscv64 Flutter SDK appears"
t_assert_contains "$(_cc_verdicts 'FACT flutter-sdk yes
CCPROBE_DONE' riscv64 dart-tool)" "STALE dart-tool FACT flutter-sdk says it IS present on riscv64" \
  "a table that cannot rot: the arm names itself for deletion"

t_case "each exemption is re-checked by its OWN fact, not by another row's"
# appimagetool's arm was re-checked with FACT flutter-sdk, so a riscv64 appimagetool
# would have read EXEMPT forever -- the one thing the rot signal exists to prevent.
_CC_AI="$(_cc_verdicts 'FACT flutter-sdk no
FACT appimagetool-readable yes
ENV appimagetool /usr/local/bin/appimagetool
CCPROBE_DONE' riscv64 appimagetool)"
t_assert_contains "${_CC_AI}" "STALE appimagetool FACT appimagetool-readable says it IS present on riscv64" \
  "an appimagetool that appeared on riscv64 must name its own arm for deletion"
t_assert_contains "$(_cc_verdicts 'FACT flutter-sdk no
FACT appimagetool-readable no
CCPROBE_DONE' riscv64 appimagetool)" "EXEMPT appimagetool" \
  "and the measured riscv64 shape -- packaging-deps.sh ships no riscv64 asset -- stays exempt"

t_case "every per-arch exemption's rot fact is a fact the probe really emits"
# A rot signal the probe never prints is a NOFACT on every run: the row can then
# never be granted, and the gate reds for a reason that has nothing to do with it.
_CC_PROBE_SRC="$(_extract _consumer_contract_probe)"
while IFS= read -r _row; do
  [ -n "${_row}" ] || continue
  _f="$(bash -c "$(_extract _consumer_exempt_fact)"$'\n'"_consumer_exempt_fact '${_row}'")"
  t_assert_contains "${_CC_PROBE_SRC}" "FACT ${_f} " "row ${_row} is re-checked by FACT ${_f}"
done < <(_extract _consumer_contract_exempt | sed -n 's/^ *\([a-z0-9|:-]*\)) return 0 ;;/\1/p' \
           | tr '|' '\n' | sed 's/^[a-z0-9]*://')

t_case "an exemption whose rot signal is missing fails too"
t_assert_contains "$(_cc_verdicts 'CCPROBE_DONE' riscv64 dart-tool)" "NOFACT dart-tool" \
  "without FACT flutter-sdk the exemption cannot be re-checked, so it may not be granted"

t_case "the fixed image asserts every row"
_CC_OK="$(_cc_verdicts "${_CC_FIXED}" amd64)"
t_assert_contains "${_CC_OK}" "ASSERTED 7" "all seven rows must be provable at once"
t_assert_eq 0 "$(printf '%s\n' "${_CC_OK}" | grep -c '^BAD ')" "and none of them may fail"

# The gate around the verdicts: CC_USER is what the image's Config.User says.
_cc_gate() {
  CC_PROBE="$1" CC_USER="${2-kataglyphis}" CC_ROWS="${4-}" bash -c '
    '"${_STUBS}"'
    inspect_image_config() { printf "%s" "${CC_USER}"; }
    _rt_run() { printf "%s\n" "${CC_PROBE}"; }
    '"${_CC_PARTS}"'
    '"$(_extract _consumer_contract_probe)"'
    '"$(_extract _consumer_contract_symptom)"'
    '"$(_extract check_consumer_contract)"'
    [ -z "${CC_ROWS}" ] || _CONSUMER_CONTRACT_ROWS="${CC_ROWS}"
    check_consumer_contract img '"${3:-amd64}"'
    printf "FAILURES=%s\n" "${FAILURES}"' 2>&1
}

t_case "the probe is one program and reports every verb the verdicts read"
# Run against the HOST: the shell is the code under test, not the image. A dropped
# _w line or a renamed verb is otherwise invisible until a chain runs.
_CC_TMP="$(mktemp -d)"
# The fixture creates them: a probe that mkdir'd its own targets would answer
# "writable" for a directory the consumer's `[ -w ]` calls false.
mkdir -p "${_CC_TMP}"/{cc,sc,ru/tmp,ca,sdk/platform-tools}
_CC_RAW="$(CCACHE_DIR="${_CC_TMP}/cc" SCCACHE_DIR="${_CC_TMP}/sc" RUSTUP_HOME="${_CC_TMP}/ru" \
  CARGO_HOME="${_CC_TMP}/ca" ANDROID_HOME="${_CC_TMP}/sdk" ANDROID_SDK_ROOT="${_CC_TMP}/sdk" \
  bash -c "$(_extract _consumer_contract_probe)"$'\n'"_consumer_contract_probe | bash" 2>&1)"
t_assert_contains "${_CC_RAW}" "CCPROBE_DONE" "exit status is not evidence; the sentinel is"
t_assert_contains "${_CC_RAW}" "WHO " "the gate refuses to judge a probe that did not say who it ran as"
for _r in ccache-dir sccache-dir rustup-tmp cargo-home dart-tool; do
  t_assert_contains "${_CC_RAW}" "WRITE ${_r} " "the probe must report writability for ${_r}"
  t_assert_contains "${_CC_RAW}" "ENV ${_r} " "the probe must report the resolved path for ${_r}"
done
t_assert_contains "${_CC_RAW}" "DIR android-platform-tools " "the android row reads a directory, not a variable"
t_assert_contains "${_CC_RAW}" "FACT android-path " "the android row also reads PATH, where adb and sdkmanager are found"
t_assert_contains "${_CC_RAW}" "FACT flutter-sdk " "the exemption rot signal must be emitted"
t_assert_contains "${_CC_RAW}" "FACT flutter-foreign " "the ownership count must be emitted"

t_case "the probe answers YES only where it really wrote"
t_assert_contains "${_CC_RAW}" "WRITE ccache-dir yes" "a writable directory must read as writable"
t_assert_eq "" "$(ls -A "${_CC_TMP}/cc")" "and the probe must leave nothing behind in it"
: > "${_CC_TMP}/notadir"
t_assert_contains "$(CARGO_HOME="${_CC_TMP}/notadir/x" bash -c "$(_extract _consumer_contract_probe)"$'\n'"_consumer_contract_probe | bash" 2>&1)" \
  "WRITE cargo-home no" "a path the probe cannot create a file in must read as unwritable, for root too"
t_assert_contains "$(CARGO_HOME="${_CC_TMP}/absent" bash -c "$(_extract _consumer_contract_probe)"$'\n'"_consumer_contract_probe | bash" 2>&1)" \
  "WRITE cargo-home no" "a MISSING directory is what the consumer's [ -w ] calls false; a probe that creates it reports green where they fail"
rm -rf "${_CC_TMP}"

t_case "a red row names the symptom the consuming repo actually saw"
_CC_G="$(_cc_gate "${_CC_SHIPPED}")"
t_assert_contains "${_CC_G}" "Permission denied (os error 13)" "the rustup row must quote what the consumer's log says"
t_assert_contains "${_CC_G}" "No Android SDK found" "the android row must name the flutter failure, not our path"
t_assert_contains "${_CC_G}" "package_config.json" "the .dart_tool row must name pub get"
t_assert_contains "${_CC_G}" "tmpfs" "the ownership row must say why a consumer cannot fix it themselves"

t_case "a probe that never ran fails instead of passing empty"
t_assert_contains "$(_cc_gate "bash: line 1: id: command not found")" "asserted NOTHING" \
  "no CCPROBE_DONE marker means the gate proved nothing"

t_case "a probe that ran as root proves nothing and fails"
# Every directory answers writable to uid 0, so the answers are only evidence if
# the probe ran as the user the image ships.
t_assert_contains "$(_cc_gate "$(printf '%s\n' "${_CC_FIXED}" | sed 's/^WHO .*/WHO 0 root/')")" \
  "not the image's own USER" "a root probe is not a consumer"

t_case "an image that declares no USER fails"
t_assert_contains "$(_cc_gate "${_CC_FIXED}" "")" "declares no USER" \
  "nothing pins who a consumer runs as"

t_case "an emptied row table is a vacuous pass, not a green image"
t_assert_contains "$(_cc_gate "${_CC_FIXED}" kataglyphis amd64 " ")" "asserted NOTHING" \
  "the gate reduces to its table, so an empty table must fail rather than print PASS all 0"

t_case "a verdict verb no arm handles fails instead of being dropped"
t_assert_contains "$(_cc_gate "${_CC_FIXED}")" "" "gate ran"
_CC_UNK="$(CC_V="WHAT ccache-dir x" bash -c '
    '"${_STUBS}"'
    _consumer_contract_verdicts() { printf "%s\nASSERTED 1\n" "${CC_V}"; }
    inspect_image_config() { printf "kataglyphis"; }
    _rt_run() { printf "WHO 1001 kataglyphis\nCCPROBE_DONE\n"; }
    '"$(_extract _consumer_contract_symptom)"'
    '"$(_extract check_consumer_contract)"'
    check_consumer_contract img amd64' 2>&1)"
t_assert_contains "${_CC_UNK}" "unknown verdict" "an unhandled verb is a silently dropped row"

t_case "the compliant image passes the gate"
_CC_PASS="$(_cc_gate "${_CC_FIXED}")"
t_assert_contains "${_CC_PASS}" "PASS CONSUMER CONTRACT: 7 row(s) hold as kataglyphis" "what a fixed image prints"
t_assert_contains "${_CC_PASS}" "FAILURES=0" "and nothing else may go red"

t_case "the appimagetool row: executable is not the same as usable"
_toolv() { bash -c '
    '"$(_extract _consumer_contract_fact)"'
    '"$(_extract _consumer_tool_verdict)"'
    _consumer_tool_verdict appimagetool "$1"' _ "$1" 2>&1; }
t_assert_contains "$(_toolv "ENV appimagetool /usr/local/bin/appimagetool
FACT appimagetool-readable no")" "is not readable by the image user" \
  "mode 711 runs for root and fails for uid 1001, which is who ships"
t_assert_contains "$(_toolv "ENV appimagetool 
FACT appimagetool-readable no")" "not on PATH at all" "an absent tool is a different failure than an unreadable one"
t_assert_contains "$(_toolv "ENV appimagetool /usr/local/bin/appimagetool
FACT appimagetool-readable yes")" "OK appimagetool" "the fixed shape"
t_assert_contains "$(_toolv "ENV appimagetool /x")" "NOFACT appimagetool" "a probe with no readability fact proves nothing"

t_case "the JDK row: Gradle reads JAVA_HOME, so java on PATH alone is not enough"
_jdkv() { bash -c '
    '"$(_extract _consumer_contract_fact)"'
    '"$(_extract _consumer_jdk_verdict)"'
    _consumer_jdk_verdict jdk "$1"' _ "$1" 2>&1; }
t_assert_contains "$(_jdkv "FACT java-on-path no
FACT javac no")" "BAD jdk no java on PATH" "the shipped image today: the SDK without its JDK"
t_assert_contains "$(_jdkv "FACT java-on-path yes
FACT javac yes
ENV java-home ")" "JAVA_HOME is unset" "Gradle reads the variable, not the PATH entry"
t_assert_contains "$(_jdkv "FACT java-on-path yes
FACT javac no
ENV java-home /usr/lib/jvm/default-java")" "has no bin/javac" "a JRE cannot compile"
t_assert_contains "$(_jdkv "FACT java-on-path yes
FACT javac yes
ENV java-home /usr/lib/jvm/default-java")" "OK jdk" "the fixed shape"
t_assert_contains "$(_jdkv "ENV java-home /x")" "NOFACT jdk" "a probe that emitted no java facts proves nothing"

t_case "every gate this suite pins is actually CALLED by the smoke"
# A gate can be perfect and never run. Each of these is extracted and driven
# above, which proves the function and says nothing about the call list.
_SMOKE_SRC="$(cat "${SMOKE}")"
for _g in check_consumer_contract check_flutter check_rust_toolchain check_manifest_tree_arch check_advertised_versions; do
  t_assert_eq 1 "$(printf '%s\n' "${_SMOKE_SRC}" | grep -c "^    ${_g} \"\${image_tag}\"")" \
    "${_g} must be invoked once from the smoke's own call list"
done

t_case "the contract asserts every promise the consuming lane depends on"
# The row list IS the contract. A row quietly dropped here takes its guarantee
# with it and every suite below still passes, because they iterate the list.
for _r in ccache-dir sccache-dir rustup-tmp cargo-home android-home jdk appimagetool dart-tool flutter-owner; do
  t_assert_contains " ${_CONSUMER_CONTRACT_ROWS} " " ${_r} " \
    "${_r} is a promise the consumer's acceptance check makes; it must stay in the table"
done

t_case "every contract row carries the consumer symptom it prevents"
# A row with no recorded symptom would fail with our path only -- which is how the
# android defect reached the consumer's log three steps from its cause.
_CC_SYM="$(_extract _consumer_contract_symptom)"
for _r in ${_CONSUMER_CONTRACT_ROWS}; do
  t_assert_eq "" "$(bash -c "${_CC_SYM}"$'\n'"_consumer_contract_symptom ${_r}" | grep -e 'no symptom recorded')" \
    "row ${_r} has no symptom in _consumer_contract_symptom"
done

t_case "every per-arch exemption names a row that still exists"
# An arm for a deleted row silently narrows nothing and hides that it is dead.
_CC_EX="$(_extract _consumer_contract_exempt | sed -n 's/^ *\([a-z0-9|:-]*\)) return 0 ;;/\1/p' | tr '|' '\n' | sed 's/^[a-z0-9]*://')"
_t_all_present " ${_CONSUMER_CONTRACT_ROWS} " "${_CC_EX}" "-" \
  "every per-arch exemption must name a row the gate still asserts"

t_summary
