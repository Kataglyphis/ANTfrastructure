#!/usr/bin/env bash
# smoke-runtime-image.sh gates, extracted and run with stubbed collaborators because the script needs a live image.
set -u
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${TESTS_DIR}/test-harness.sh"
SMOKE="${TESTS_DIR}/../06-packaging/smoke-runtime-image.sh"

_extract() {
  # Heredoc-aware: the probe text these functions emit contains `}` lines of its own.
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

# _t_edit_table <fn> [prefix]: each stdin row is <sed edit><TAB><text>; <fn> <edit> must print <prefix><text>.
_t_edit_table() {
  local _sed _want
  while IFS="$(printf '\t')" read -r _sed _want; do
    [ -n "${_sed}" ] || continue
    t_assert_contains "$("$1" "${_sed}")" "${2-}${_want}" "${_sed}"
  done
}

# _gate <fn> [healthcheck] [app smoke output] [in-image rc]
_gate() {
  local fn="$1" hc="${2-}" wheel_out="${3-}" run_rc="${4-0}" hc_json
  if [ -n "${hc}" ]; then
    hc_json="$(python3 -c 'import json,sys; print(json.dumps([{"Config":{"Healthcheck":{"Test":["CMD-SHELL",sys.argv[1]]}}}]))' "${hc}")"
  else
    hc_json='[{"Config":{}}]'
  fi
  HC_JSON="${hc_json}" WHEEL_OUT="${wheel_out}" RUN_RC="${run_rc}" bash -c '
    '"${_STUBS}"'
    # Runs the real extraction program; returning ${HC} directly would bypass the code under test.
    inspect_image_config() { printf "%s" "${HC_JSON}" | python3 -c "$1" 2>/dev/null || true; }
    _rt_run() { printf "%s\n" "${WHEEL_OUT}"; return "${RUN_RC}"; }
    _SMOKE_TORCH_EXPECTED=1
    '"$(_extract _rt_healthcheck_cmd)"'
    '"$(_extract _boot_verdict)"'
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

# WE: the healthcheck
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

# The probe is emitted in parts and must still be one program
t_case "the shipped-truth probe still emits all three of its sections"
# The advertised-keys gate would not notice a part dropped from the caller.
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

# XQ: the default-boot gate must test what only the entrypoint provides
_boot() {
  bash -c '
    '"${_STUBS}"'
    '"$(_extract _boot_verdict)"'
    _boot_verdict "$1" "$2" amd64' _ "$1" "$2" 2>&1
}

t_case "a boot that did not reach the script fails"
t_assert_contains "$(_boot 1 "")" "FAIL" "the entrypoint must exec the command and propagate 42"

t_case "the image ENV alone is NOT enough to pass"
# The image ENV already sets GST_PLUGIN_PATH and VULKAN_SDK, so their presence proves no sourcing.
t_assert_contains "$(_boot 42 "BOOT uid=0 gst=set vulkan=set
gstma=no
vkadd=
vkarch=neutral")" "did not source gstreamer-env.sh" \
  "set-ness of a var the image already exports proves nothing"

t_case "the Vulkan SDK env must be sourced too"
# The image ENV sets VK_LAYER_PATH and VULKAN_SDK; only setup-env.sh sets VK_ADD_LAYER_PATH.
t_assert_contains "$(_boot 42 "gstma=yes
vkadd=
vkarch=neutral")" "did not source the Vulkan SDK" "a bypassed setup-env.sh leaves VK_ADD_LAYER_PATH unset"

t_case "an arch-specific Vulkan dir fails (CON48)"
# What the :latest of 2026-10-01 prints: setup-env.sh resolved every variable to /opt/vulkan/<ver>/x86_64.
for _vk in "VULKAN_SDK,VK_ADD_LAYER_PATH,PATH,LD_LIBRARY_PATH,PKG_CONFIG_PATH,CMAKE_PREFIX_PATH," "LD_LIBRARY_PATH," neutral; do
  _want="arch-specific SDK dir"
  [ "${_vk}" = neutral ] && _want="PASS"
  t_assert_contains "$(_boot 42 "gstma=yes
vkadd=yes
vkarch=${_vk}")" "${_want}" "vkarch=${_vk}: only the arch-neutral shape the patched entrypoint prints may pass"
done

# _boot_probe <env...>: the real check_default_entrypoint_boot through _gate, its probe run by a local bash with that env.
_boot_probe() {
  local fake
  fake="$(mktemp)"
  printf '#!/usr/bin/env bash\nexec env -i %s bash -s\n' "$*" > "${fake}"
  chmod +x "${fake}"
  NERDCTL_BIN="${fake}" _gate check_default_entrypoint_boot
  rm -f "${fake}"
}

t_case "the probe flags each variable setup-env.sh resolves to the arch dir (CON48)"
_vk_ma="GST_PLUGIN_PATH=/opt/gstreamer/lib/x86_64-linux-gnu/gstreamer-1.0"
_out="$(_boot_probe "${_vk_ma}" VULKAN_SDK=/opt/vulkan/1.4.357.0/x86_64 \
  VK_ADD_LAYER_PATH=/opt/vulkan/1.4.357.0/x86_64/share/vulkan/explicit_layer.d \
  PATH=/opt/vulkan/1.4.357.0/x86_64/bin:/opt/vulkan/active/bin:/usr/bin:/bin)"
t_assert_contains "${_out}" "vkarch=VULKAN_SDK,VK_ADD_LAYER_PATH,PATH," "the probe must name every pinned variable"
t_assert_contains "${_out}" "FAIL" "the published 2026-10-01 shape must fail"

t_case "the probe passes the arch-neutral link and a later component"
# Only a set VK_ADD_LAYER_PATH matters for vkadd, so a short one keeps this case its own.
_out="$(_boot_probe "${_vk_ma}" VK_ADD_LAYER_PATH=/x PATH=/usr/bin:/bin:/opt/vulkan/active/bin \
  LD_LIBRARY_PATH=/usr/lib:/opt/vulkan/active/lib)"
t_assert_contains "${_out}" "vkarch=neutral" "the link is not an arch dir"
t_assert_contains "${_out}" "PASS default ENTRYPOINT+CMD boot" "the neutral shape passes end to end"
_out="$(_boot_probe "${_vk_ma}" VULKAN_SDK=/opt/vulkan/active VK_ADD_LAYER_PATH=/x \
  PATH=/usr/bin:/bin LD_LIBRARY_PATH=/usr/lib:/opt/vulkan/1.4.357.0/aarch64/lib)"
t_assert_contains "${_out}" "vkarch=LD_LIBRARY_PATH," "a pinned component after others still counts"

# _rust <what the image prints for rustc --version, rustup show active-toolchain, command -v cargo-cbuild>
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

# _flutter <flutter --version and readelf Machine output> [arch]: prints the gate's output, then the nerdctl options it used.
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


# Advertised keys: neither "the image did not tell us" arm may be a SKIP
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
# Without a default arm a new verb vanishes silently.
t_assert_contains "$(_advert_gate "WHAT RUST_VERSION 1.98.0")" "unknown verdict" \
  "an unhandled verb is a silently dropped row"

t_case "an EMPTY verdict table is a vacuous pass, not a green image"
# An empty key list asserts nothing at all.
t_assert_contains "$(_advert_gate "")" "asserted NOTHING" \
  "an empty table must fail, not print PASS all 0"
t_assert_eq 0 "$(printf '%s' "$(_advert_gate "")" | grep -c 'PASS all')" \
  "and it must not read as a pass while doing so"

t_case "a clean table still passes"
t_assert_contains "$(_advert_gate "OK RUST_VERSION 1.98.0")" "PASS all 1 advertised" \
  "the gate must still be able to pass"

# HT1: the manifest trees must carry the image's own arch (hand-written ELF headers prove the scanner reads e_machine)
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
t_needs "a POSIX python3 (Windows' python sees drive-letter paths)" t_posix_python
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
t_needs "a POSIX python3 (Windows' python sees drive-letter paths)" t_posix_python
t_assert_contains "$(_verdicts "${_SCAN_OUT}" AArch64)" "BAD ${_HT1_FIX}/builder X86-64 1" \
  "the 2 GB x86_64 rustup shipped in every arm64 image for months"
t_assert_contains "$(_verdicts "${_SCAN_OUT}" AArch64)" "OK ${_HT1_FIX}/native AArch64 2" \
  "a target-arch tree must still pass"

t_case "the same trees on the builder's own arch flip the verdict"
t_needs "a POSIX python3 (Windows' python sees drive-letter paths)" t_posix_python
t_assert_contains "$(_verdicts "${_SCAN_OUT}" X86-64)" "BAD ${_HT1_FIX}/native AArch64" \
  "the machine is compared against THIS image's arch, not against x86_64"

t_case "a scan that found no tree at all is a vacuous pass, not a pass"
t_assert_contains "$(_verdicts "TREESCAN_DONE" AArch64)" "NONE" "nothing asserted must be reportable"

t_case "a cross toolchain's target payload is not a defect, but its own binaries still are"
t_needs "a POSIX python3 (Windows' python sees drive-letter paths)" t_posix_python
# Cross toolchains' target dirs hold foreign ELF by design; the exemption must not reach a builder-arch rustc.
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
t_needs "a POSIX python3 (Windows' python sees drive-letter paths)" t_posix_python
# Two rustup toolchains: the first one's rust-src sorts ahead of the second one's bin/ and would starve it.
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

# HT1: the host-side halves of the gate agree with their other owners
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

t_case "the Vulkan tree is probed WHOLE, not narrowed to active/"
# The SDK's host prefix and build tree are pruned before the COPY, so all of /opt/vulkan is the image's arch.
t_assert_contains "${_TREES}" "/opt/vulkan" "the manifest tree must still reach the scanner"
t_assert_eq "" "$(printf '%s\n' "${_TREES}" | grep -e '/opt/vulkan/active')" \
  "a re-narrowed probe would stop seeing a builder-arch prefix that came back"

# Sentinel first, so a source table that moved fails loudly instead of iterating over nothing.
_t_all_present() {
  local haystack="$1" needles="$2" sentinel="$3" why="$4" n
  t_assert_contains "${needles}" "${sentinel}" "the source table moved -- '${why}' reads nothing"
  while IFS= read -r n; do
    [ -n "${n}" ] || continue
    t_assert_contains "${haystack}" "${n}" "${why}: ${n}"
  done < <(printf '%s\n' "${needles}")
}

t_case "the one documented COPY relocation is applied, not the source path"
# The manifest carries the COPY source; verify-artifact-copy-parity.sh's ALLOWED_RELOCATIONS owns the destination.
_RELOC="$(sed -n 's/^  "\/[^ ]* \(\/[^"]*\)"$/\1/p' "${TESTS_DIR}/../verify-artifact-copy-parity.sh")"
_t_all_present "${_TREES}" "${_RELOC}" "/" "every ALLOWED_RELOCATIONS destination must be the path the gate probes"

t_case "every arch-exempt tree is still a declared artifact"
# An exemption for a tree nobody ships any more silently narrows the gate.
eval "$(sed -n '/^_RT_TREE_ARCH_EXEMPT=/p' "${SMOKE}")"
_t_all_present "${_TREES}" "$(printf '%s\n' ${_RT_TREE_ARCH_EXEMPT})" "/opt/" \
  "every arch-exempt tree must still be a declared artifact"

t_case "the arch-exempt table is what the images MEASURED, not what the graph suggested"
# See docs/linux-cross-builds.md#the-android-abi-is-a-target-not-the-build-host
t_assert_contains " ${_RT_TREE_ARCH_EXEMPT} " " /opt/android-sdk " \
  "the SDK's host toolchain is genuinely not this image's to assert"
t_assert_contains " ${_RT_TREE_ARCH_EXEMPT} " " /opt/android " \
  "an Android payload's arch is the ANDROID target's, and check_android_abi owns it"
t_assert_contains "$(sed -n '/^arch_android_abi_for() {$/,/^}$/p' "${TESTS_DIR}/../01-core/platform.sh")" \
  'arm64) printf '"'"'%s'"'"' "arm64-v8a"' "the mapping the deletion rests on: one ABI per arch, same machine"

t_case "an ELF machine label may not contain a space"
# Verdicts are read with `read -r verb tree machine count sample`, so a spaced label eats the count column.
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

# Consumer contract; _CC_SHIPPED is probe output measured in a shipped image, not invented
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
FACT android-payload-off no
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
FACT android-payload-off no
FACT flutter-sdk yes
FACT flutter-foreign 0
FACT flutter-foreign-examples
CCPROBE_DONE'

# Rows are read from the smoke itself, so the tests never assert a stale copy.
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
# The probe exactly as check_consumer_contract sends it: the main body and both fragments it calls.
_CC_PROBE_FNS="$(_extract _consumer_contract_probe)
$(_extract _consumer_ort_env_probe)
$(_extract _consumer_test_runtimes_probe)"

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
# Derived from _CC_FIXED so the two captures cannot drift; only the ownership facts differ.
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
# /workspace is a writable bind mount for every consumer, so writability alone proves nothing.
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

# _cc_android <platform-tools dir> <on PATH> [payload-off, default no]: yes/no facts
_cc_android() {
  _cc_verdicts "ENV android-home /opt/android-sdk
ENV android-sdk-root /opt/android-sdk
DIR android-platform-tools $1
FACT android-path $2
FACT android-payload-off ${3:-no}
CCPROBE_DONE" amd64 android-home
}

t_case "ANDROID_HOME set at a path with no platform-tools fails"
t_assert_contains "$(_cc_android no yes)" "platform-tools does not exist" \
  "an exported variable is not an SDK"

t_case "an SDK that is set and present but not on PATH still fails"
# flutter finds the SDK by variable, but sdkmanager, adb and avdmanager by PATH.
t_assert_contains "$(_cc_android yes no)" "is on PATH" "half a wiring is not the contract"

t_case "a payload-off image SKIPs the row instead of failing it"
# The NDK is linux-x86_64 only, so a non-amd64-hosted android stage legitimately ships empty directories.
t_assert_contains "$(_cc_android no no yes)" "SKIP android-home" \
  "an image that RECORDED why the SDK is absent must not be judged as if it hid it"

t_case "a MISSING payload-off fact is NOFACT, never a silent grant"
# An absent fact is unknown, not false, so an old probe cannot restore the old verdict by omission.
t_assert_contains "$(_cc_verdicts "ENV android-home /opt/android-sdk
ENV android-sdk-root /opt/android-sdk
DIR android-platform-tools yes
FACT android-path yes
CCPROBE_DONE" amd64 android-home)" "NOFACT android-home" \
  "no FACT android-payload-off line means the gate could not judge, not that it passed"

t_case "the android row asserts exactly the two PATH entries Dockerfile.package appends"
t_assert_contains "$(_cc_android yes yes)" "OK android-home" \
  "platform-tools + cmdline-tools/latest/bin is the whole claim -- build-tools and the NDK are deliberately off PATH"

# The riscv64 /opt/flutter is empty: .dart_tool is absent (exempt) but ownership still holds.
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
# The dart-tool exemption must not hide root-owned paths.
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
# Checked against another row's fact, a riscv64 appimagetool would read EXEMPT forever.
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
# A rot fact the probe never prints is a NOFACT on every run.
_CC_PROBE_SRC="${_CC_PROBE_FNS}"
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
    '"${_CC_PROBE_FNS}"'
    '"$(_extract _consumer_contract_symptom)"'
    '"$(_extract check_consumer_contract)"'
    [ -z "${CC_ROWS}" ] || _CONSUMER_CONTRACT_ROWS="${CC_ROWS}"
    check_consumer_contract img '"${3:-amd64}"'
    printf "FAILURES=%s\n" "${FAILURES}"' 2>&1
}

t_case "the probe is one program and reports every verb the verdicts read"
# Run on the host: the probe's shell is the code under test, not the image.
_CC_TMP="$(mktemp -d)"
# The fixture, not the probe, creates the dirs: a missing dir is one the consumer's `[ -w ]` calls false.
mkdir -p "${_CC_TMP}"/{cc,sc,ru/tmp,ca,sdk/platform-tools,ort}
: > "${_CC_TMP}/ort/libonnxruntime.so"
_CC_RAW="$(CCACHE_DIR="${_CC_TMP}/cc" SCCACHE_DIR="${_CC_TMP}/sc" RUSTUP_HOME="${_CC_TMP}/ru" \
  CARGO_HOME="${_CC_TMP}/ca" ANDROID_HOME="${_CC_TMP}/sdk" ANDROID_SDK_ROOT="${_CC_TMP}/sdk" \
  ORT_LIB_LOCATION="${_CC_TMP}/ort" ORT_DYLIB_PATH="${_CC_TMP}/ort/libonnxruntime.so" ORT_SKIP_DOWNLOAD=1 CARGO_NET_OFFLINE='' \
  env -u ORT_LIB_PATH bash -c "${_CC_PROBE_FNS}"$'\n'"_consumer_contract_probe | bash" 2>&1)"
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
# G3: the ort crate env as set, where it resolves, the linker name, and the completion fact.
for _f in "ENV ort-lib-location ${_CC_TMP}/ort" "FACT ort-lib-real $(readlink -e -- "${_CC_TMP}/ort")" \
          "FACT ort-link-lib yes" "ENV ort-skip-download 1" "ENV ort-lib-path <unset>" "FACT ort-probe yes"; do
  t_assert_contains "${_CC_RAW}" "${_f}" "the ort-crate-env row reads it"
done
t_assert_eq 1 "$(printf '%s\n' "${_CC_RAW}" | grep -cx -e 'ENV cargo-net-offline ' || true)" "set-but-empty is set: ort-sys reads it"

t_case "the probe answers YES only where it really wrote"
t_assert_contains "${_CC_RAW}" "WRITE ccache-dir yes" "a writable directory must read as writable"
t_assert_eq "" "$(ls -A "${_CC_TMP}/cc")" "and the probe must leave nothing behind in it"
: > "${_CC_TMP}/notadir"
t_assert_contains "$(CARGO_HOME="${_CC_TMP}/notadir/x" bash -c "${_CC_PROBE_FNS}"$'\n'"_consumer_contract_probe | bash" 2>&1)" \
  "WRITE cargo-home no" "a path the probe cannot create a file in must read as unwritable, for root too"
t_assert_contains "$(CARGO_HOME="${_CC_TMP}/absent" bash -c "${_CC_PROBE_FNS}"$'\n'"_consumer_contract_probe | bash" 2>&1)" \
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
# Every directory is writable to uid 0.
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

# CON50's browser and emulator rows; the pins come from the env, which _rt_versions_env_pin reads first.
_CC_TR_PARTS="${_CC_PARTS}
$(_extract _rt_versions_env_pin)
$(_extract _consumer_chrome_verdict)
$(_extract _consumer_emulator_verdict)
$(_extract _consumer_cargo_qa_verdict)
$(_extract _consumer_free_threaded_verdict)"
# _cc_tr <probe> <arch> <row>
_cc_tr() {
  CC_PROBE="$1" CHROME_FOR_TESTING_VERSION=154.0.8037.92 ANDROID_EMULATOR_VERSION=37.2.12 ANDROID_EMULATOR_API=35 \
    ANDROID_EMULATOR_SYSIMG_REVISION=9 CARGO_AUDIT_VERSION=0.22.2 CARGO_DENY_VERSION=0.20.2 CARGO_TARPAULIN_VERSION=0.37.2 PYTHON_VERSION=3.14.7 bash -c '
    '"${_CC_TR_PARTS}"'
    _CONSUMER_CONTRACT_ROWS="$2"
    _consumer_contract_verdicts "$1" "${CC_PROBE}"' _ "$2" "$3" 2>&1
}
_CC_CHROME='ENV chrome-executable /usr/local/bin/chrome
FACT chrome yes
FACT chrome-version 154.0.8037.92
FACT chromedriver-version 154.0.8037.92
FACT chrome-headless yes'
_CC_EMU='FACT android-payload-off no
FACT android-emulator yes
FACT android-emulator-version 37.2.12
FACT android-emulator-runs yes
FACT android-system-image android-35;google_apis;x86_64;r9
FACT android-avd yes'
_cc_edit() { printf '%s\n' "$1" | sed -e "$2"; }

t_case "CON50: the pinned browser rendering headless holds the chrome row on amd64 and arm64"
for _a in amd64 arm64; do
  t_assert_contains "$(_cc_tr "${_CC_CHROME}" "${_a}" chrome)" "OK chrome Chrome for Testing 154.0.8037.92 renders headless" "${_a}"
done

t_case "CON50: a browser that renders nothing, runs off the pin or lacks its chromedriver is BAD (mutation)"
t_assert_contains "$(_cc_tr "$(_cc_edit "${_CC_CHROME}" 's/^FACT chrome-headless yes/FACT chrome-headless no/')" amd64 chrome)" \
  "BAD chrome headless chrome rendered no page"
t_assert_contains "$(_cc_tr "$(_cc_edit "${_CC_CHROME}" 's/^FACT chrome-version .*/FACT chrome-version 153.0.1.1/')" amd64 chrome)" \
  "BAD chrome chrome reports 153.0.1.1, the pin is 154.0.8037.92"
t_assert_contains "$(_cc_tr "$(_cc_edit "${_CC_CHROME}" '/^FACT chromedriver-version/d')" amd64 chrome)" \
  "BAD chrome chromedriver reports nothing"
t_assert_contains "$(_cc_tr 'ENV chrome-executable
FACT chrome no' arm64 chrome)" "BAD chrome CHROME_EXECUTABLE () names no executable browser" "an arm64 image without its browser"
t_assert_contains "$(_cc_tr 'ENV chrome-executable /x' amd64 chrome)" "NOFACT chrome" "a probe that never answered proves nothing"

t_case "CON50: riscv64 is exempt from the chrome row, and the arm rots the day a browser appears"
t_assert_contains "$(_cc_tr 'FACT chrome no' riscv64 chrome)" "EXEMPT chrome"
t_assert_contains "$(_cc_tr "${_CC_CHROME}" riscv64 chrome)" "STALE chrome FACT chrome says it IS present on riscv64"

t_case "CON50: the pinned emulator, system image and AVD helper hold the row on amd64"
t_assert_contains "$(_cc_tr "${_CC_EMU}" amd64 android-emulator)" \
  "OK android-emulator emulator 37.2.12 with android-35;google_apis;x86_64;r9"

t_case "CON50: every broken part of the emulator payload is BAD (mutation)"
_emu_bad() { _cc_tr "$(_cc_edit "${_CC_EMU}" "$1")" amd64 android-emulator; }
_t_edit_table _emu_bad <<'ROWS'
s/^FACT android-emulator yes/FACT android-emulator no/	BAD android-emulator ANDROID_HOME/emulator/emulator is missing
s/^FACT android-emulator-runs yes/FACT android-emulator-runs no/	BAD android-emulator the emulator does not run as the image user
s/^FACT android-emulator-version .*/FACT android-emulator-version 37.2.11/	BAD android-emulator emulator 37.2.11, the pin is 37.2.12
s/;r9$/;r8/	BAD android-emulator system image android-35;google_apis;x86_64;r8, the pin is android-35;google_apis;x86_64;r9
/^FACT android-system-image/d	BAD android-emulator system image none
s/^FACT android-avd yes/FACT android-avd no/	BAD android-emulator android-avd.sh is not on PATH
s/^FACT android-payload-off no/FACT android-payload-off yes/	SKIP android-emulator
/^FACT android-payload-off/d	NOFACT android-emulator no FACT android-payload-off line
ROWS

t_case "CON50: arm64 and riscv64 are exempt from the emulator row, each re-checked by the emulator's own fact"
for _a in arm64 riscv64; do
  t_assert_contains "$(_cc_tr 'FACT android-emulator no' "${_a}" android-emulator)" "EXEMPT android-emulator" "${_a}"
  t_assert_contains "$(_cc_tr "${_CC_EMU}" "${_a}" android-emulator)" "STALE android-emulator FACT android-emulator says it IS present on ${_a}"
done

_CC_QA='FACT cargo-qa-tools yes
FACT cargo-qa-tools-versions cargo-audit=0.22.2 cargo-deny=0.20.2 cargo-tarpaulin=0.37.2'

t_case "CON65: the three cargo QA tools at their pins hold the row on amd64 and arm64"
for _a in amd64 arm64; do
  t_assert_contains "$(_cc_tr "${_CC_QA}" "${_a}" cargo-qa-tools)" \
    "OK cargo-qa-tools cargo-audit=0.22.2 cargo-deny=0.20.2 cargo-tarpaulin=0.37.2" "${_a}"
done

t_case "CON65: a tool off its pin or missing is BAD, and no fact proves nothing (mutation)"
_qa_bad() { _cc_tr "$(_cc_edit "${_CC_QA}" "$1")" arm64 cargo-qa-tools; }
_t_edit_table _qa_bad <<'ROWS'
s/cargo-deny=0.20.2/cargo-deny=0.19.0/	BAD cargo-qa-tools the image has cargo-audit=0.22.2 cargo-deny=0.19.0
s/cargo-tarpaulin=0.37.2/cargo-tarpaulin=/	BAD cargo-qa-tools the image has cargo-audit=0.22.2 cargo-deny=0.20.2 cargo-tarpaulin=
/^FACT cargo-qa-tools /d	NOFACT cargo-qa-tools no FACT cargo-qa-tools line
ROWS

t_case "CON65: riscv64 is exempt from the cargo QA row, and the arm rots the day one appears"
t_assert_contains "$(_cc_tr 'FACT cargo-qa-tools no' riscv64 cargo-qa-tools)" "EXEMPT cargo-qa-tools"
t_assert_contains "$(_cc_tr "${_CC_QA}" riscv64 cargo-qa-tools)" "STALE cargo-qa-tools FACT cargo-qa-tools says it IS present on riscv64"

_FT_SRC='FACT free-threaded-python-build prefix=/opt/python-freethreaded Py_GIL_DISABLED=1'
t_case "CON66: the toolchain's free-threaded source build at PYTHON_VERSION holds the row on every arch"
for _a in amd64 arm64 riscv64; do
  t_assert_contains "$(_cc_tr "FACT free-threaded-python 3.14.7 gil=False
${_FT_SRC}" "${_a}" free-threaded-python)" \
    "OK free-threaded-python CPython 3.14.7 without the GIL, built from source in /opt/python-freethreaded" "${_a}"
done

t_case "CON66: a GIL build, another patch or no interpreter is BAD, and no fact proves nothing (mutation)"
_ft_bad() { _cc_tr "FACT free-threaded-python $1
${_FT_SRC}" amd64 free-threaded-python; }
t_assert_contains "$(_ft_bad '3.14.7 gil=True')" "BAD free-threaded-python python3.*t reports 3.14.7 gil=True"
t_assert_contains "$(_ft_bad '3.14.4 gil=False')" "BAD free-threaded-python python3.*t reports 3.14.4 gil=False"
t_assert_contains "$(_ft_bad 'none')" "BAD free-threaded-python python3.*t reports none"
t_assert_contains "$(_cc_tr 'FACT other yes' amd64 free-threaded-python)" "NOFACT free-threaded-python"

t_case "CON66: uv's python-build-standalone tree, a missing stdlib module or no build fact is BAD (mutation)"
_ft_src_bad() { _cc_tr "FACT free-threaded-python 3.14.7 gil=False${1:+
FACT free-threaded-python-build $1}" amd64 free-threaded-python; }
t_assert_contains "$(_ft_src_bad 'prefix=/opt/python-freethreaded/cpython-3.14.7+freethreaded-linux-x86_64-gnu Py_GIL_DISABLED=1')" \
  "BAD free-threaded-python python3.*t is not the source build in /opt/python-freethreaded with its stdlib: prefix=/opt/python-freethreaded/cpython-3.14.7"
t_assert_contains "$(_ft_src_bad "ModuleNotFoundError: No module named '_ctypes'")" \
  "with its stdlib: ModuleNotFoundError: No module named '_ctypes'"
t_assert_contains "$(_ft_src_bad '')" "with its stdlib: no FACT free-threaded-python-build line"

t_case "CON50: the probe emits every fact the two rows read, as a real run of it"
_TR_TMP="$(mktemp -d)"
mkdir -p "${_TR_TMP}/bin" "${_TR_TMP}/sdk/emulator" "${_TR_TMP}/sdk/system-images/android-35/google_apis/x86_64"
printf '#!/bin/sh\ncase "$*" in *--version*) echo "Google Chrome for Testing 154.0.8037.92 " ;; *--dump-dom*) echo "<body>kg-42</body>" ;; esac\n' \
  > "${_TR_TMP}/bin/chrome"
printf '#!/bin/sh\necho "ChromeDriver 154.0.8037.92 (x)"\n' > "${_TR_TMP}/bin/chromedriver"
printf '#!/bin/sh\necho "cargo-audit 0.22.2"\n' > "${_TR_TMP}/bin/cargo-audit"
printf '#!/bin/sh\necho "cargo-deny 0.20.2"\n' > "${_TR_TMP}/bin/cargo-deny"
printf '#!/bin/sh\necho "tarpaulin 0.37.2"\n' > "${_TR_TMP}/bin/cargo-tarpaulin"
printf '#!/bin/sh\ncase "$2" in *sysconfig*) echo "prefix=/opt/python-freethreaded Py_GIL_DISABLED=1" ;; *) echo "3.14.7 gil=False" ;; esac\n' \
  > "${_TR_TMP}/bin/python3.14t"
printf '#!/bin/sh\necho "Android emulator version 37.2.12.0 (build_id 16428233)"\n' > "${_TR_TMP}/sdk/emulator/emulator"
: > "${_TR_TMP}/bin/android-avd.sh"
chmod +x "${_TR_TMP}"/bin/* "${_TR_TMP}/sdk/emulator/emulator"
printf 'Pkg.Revision=37.2.12\n' > "${_TR_TMP}/sdk/emulator/source.properties"
printf 'Pkg.Revision=9\nAndroidVersion.ApiLevel=35\nSystemImage.TagId=google_apis\nSystemImage.Abi=x86_64\n' \
  > "${_TR_TMP}/sdk/system-images/android-35/google_apis/x86_64/source.properties"
_TR_RAW="$(PATH="${_TR_TMP}/bin:${PATH}" CHROME_EXECUTABLE="${_TR_TMP}/bin/chrome" ANDROID_HOME="${_TR_TMP}/sdk" \
  bash -c "${_CC_PROBE_FNS}"$'\n'"_consumer_contract_probe | bash" 2>&1)"
for _f in "FACT chrome yes" "FACT chrome-version 154.0.8037.92" "FACT chromedriver-version 154.0.8037.92" \
          "FACT chrome-headless yes" "FACT android-emulator yes" "FACT android-emulator-version 37.2.12" \
          "FACT android-emulator-runs yes" "FACT android-system-image android-35;google_apis;x86_64;r9" "FACT android-avd yes" \
          "FACT cargo-qa-tools yes" "FACT cargo-qa-tools-versions cargo-audit=0.22.2 cargo-deny=0.20.2 cargo-tarpaulin=0.37.2" \
          "FACT free-threaded-python 3.14.7 gil=False" "${_FT_SRC}"; do
  t_assert_contains "${_TR_RAW}" "${_f}" "the probe reads it from the image"
done
t_assert_contains "$(CHROME_EXECUTABLE='' ANDROID_HOME="${_TR_TMP}/none" \
  bash -c "${_CC_PROBE_FNS}"$'\n'"_consumer_contract_probe | bash" 2>&1)" \
  $'FACT chrome no' "an empty CHROME_EXECUTABLE is riscv64's shape"
rm -rf "${_TR_TMP}"

# Vulkan loader: Ubuntu's multiarch libvulkan is in every image, so which one answered matters
_vk_gate() {
  VK_OUT="$1" bash -c '
    '"${_STUBS}"'
    _rt_run() { printf "%s\n" "${VK_OUT}"; }
    '"$(sed -n '/^_VK_WSI_REQUIRED=/p' "${SMOKE}")"'
    '"$(_extract _vk_wsi_verdict)"'
    '"$(_extract _vk_loaded_path)"'
    '"$(_extract check_vulkan_loader)"'
    check_vulkan_loader img arm64'
}

# Probe output: WSI_OK is what the CON41 fix lists on every arch, WSI_NONE what arm64/riscv64 listed before it.
_VK_EXT_WSI_OK='VKEXT VK_KHR_display VK_KHR_get_surface_capabilities2 VK_KHR_surface VK_KHR_wayland_surface VK_KHR_xcb_surface VK_KHR_xlib_surface VK_EXT_acquire_xlib_display VK_EXT_headless_surface'
_VK_EXT_WSI_NONE='VKEXT VK_KHR_display VK_KHR_get_surface_capabilities2 VK_KHR_surface VK_EXT_acquire_drm_display VK_EXT_headless_surface'

# _vk_shipped <VKEXT line>: the gate on a loader resolved inside the shipped /opt/vulkan prefix.
_vk_shipped() {
  _vk_gate "VKLIB /opt/vulkan/1.4.357.0/aarch64/lib/libvulkan.so.1.4.357
VKOK 1.4.357
$1"
}

t_case "a loader resolved inside /opt/vulkan is the pass"
_VK="$(_vk_shipped "${_VK_EXT_WSI_OK}")"
t_assert_contains "${_VK}" "libvulkan.so.1 loads from /opt/vulkan/1.4.357.0/aarch64/lib/libvulkan.so.1.4.357" \
  "the pass line must name the path it read, not just say OK"
t_assert_eq "" "$(printf '%s\n' "${_VK}" | grep -e '^FAIL')" "a shipped-prefix loader is not a failure"

t_case "the distro loader answering instead of the shipped prefix FAILS"
_VK="$(_vk_gate "VKLIB /usr/lib/aarch64-linux-gnu/libvulkan.so.1.4.341
VKOK 1.4.341
${_VK_EXT_WSI_OK}")"
t_assert_contains "${_VK}" "FAIL libvulkan.so.1 loaded from /usr/lib/aarch64-linux-gnu/libvulkan.so.1.4.341" \
  "a prune that took the prefix the image runs would otherwise pass on Ubuntu's loader"

t_case "a load that names no path is a warning, not a verdict either way"
_VK="$(_vk_gate "VKOK 1.4.357
${_VK_EXT_WSI_OK}")"
t_assert_contains "${_VK}" "WARN" "/proc/self/maps can be unreadable; that is not a defect"
t_assert_eq "" "$(printf '%s\n' "${_VK}" | grep -e '^FAIL')" "an unread maps file must not fail the image"

t_case "the loader's window-system extensions are asserted (CON41)"
t_assert_contains "${_VK}" "OK  the arm64 loader lists VK_KHR_surface VK_KHR_xcb_surface VK_KHR_xlib_surface VK_KHR_wayland_surface"

t_case "a loader without X11/XCB/Wayland surfaces FAILS -- the arm64 :latest of 2026-09-29"
_VK="$(_vk_shipped "${_VK_EXT_WSI_NONE}")"
t_assert_contains "${_VK}" "FAIL the arm64 Vulkan loader lacks VK_KHR_xcb_surface VK_KHR_xlib_surface VK_KHR_wayland_surface" \
  "every windowed test aborts on such a loader; the message must name exactly what is missing"
t_assert_eq "" "$(printf '%s\n' "${_VK}" | grep -e 'VK_KHR_surface VK_KHR_xcb' | grep -e '^FAIL')" \
  "VK_KHR_surface is present and must not be reported missing"

t_case "one missing surface is enough to fail"
_VK="$(_vk_shipped "${_VK_EXT_WSI_OK/ VK_KHR_wayland_surface/}")"
t_assert_contains "${_VK}" "FAIL the arm64 Vulkan loader lacks VK_KHR_wayland_surface --"

t_case "a surface name that is only a PREFIX of a listed one does not count"
_VK="$(_vk_shipped "${_VK_EXT_WSI_OK/ VK_KHR_surface / VK_KHR_surface_maintenance1 }")"
t_assert_contains "${_VK}" "FAIL the arm64 Vulkan loader lacks VK_KHR_surface --" \
  "VK_KHR_surface_maintenance1 is not VK_KHR_surface"

t_case "a loaded loader that listed no extensions FAILS rather than passing vacuously"
_VK="$(_vk_gate 'VKLIB /opt/vulkan/1.4.357.0/aarch64/lib/libvulkan.so.1.4.357
VKOK 1.4.357')"
t_assert_contains "${_VK}" "FAIL the arm64 Vulkan loader listed no instance extensions"

t_case "an unloadable libvulkan is still the hard failure it was"
_VK="$(_vk_gate 'OSError: libvulkan.so.1: cannot open shared object file: No such file or directory')"
t_assert_contains "${_VK}" "FAIL libvulkan.so.1 missing/unloadable" "the pre-existing arm must survive the sharpening"

t_case "every gate this suite pins is actually CALLED by the smoke"
# Driving an extracted gate proves the function, not that the smoke calls it.
_SMOKE_SRC="$(cat "${SMOKE}")"
for _g in check_consumer_contract check_flutter check_rust_toolchain check_manifest_tree_arch check_advertised_versions check_vulkan_loader; do
  t_assert_eq 1 "$(printf '%s\n' "${_SMOKE_SRC}" | grep -c "^    ${_g} \"\${image_tag}\"")" \
    "${_g} must be invoked once from the smoke's own call list"
done

t_case "the contract asserts every promise the consuming lane depends on"
# The suites iterate the row list, so a dropped row would take its guarantee with it silently.
for _r in ccache-dir sccache-dir rustup-tmp cargo-home android-home jdk appimagetool dart-tool flutter-owner ort-crate-env chrome android-emulator; do
  t_assert_contains " ${_CONSUMER_CONTRACT_ROWS} " " ${_r} " \
    "${_r} is a promise the consumer's acceptance check makes; it must stay in the table"
done

t_case "every contract row carries the consumer symptom it prevents"
# Without the symptom a red row names only our path, not what the consumer's log shows.
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

# G3: the ort crate env row as Dockerfile.package bakes it; see docs/consumer-image-contract.md
_CC_ORT_OK='ENV ort-lib-location /usr/local/lib/onnxruntime-cpu/lib
ENV ort-dylib-path /usr/local/lib/onnxruntime-cpu/lib/libonnxruntime.so
ENV ort-prefer-dynamic 1
ENV ort-skip-download 1
ENV ort-lib-path <unset>
ENV cargo-net-offline <unset>
FACT ort-lib-real /usr/local/lib/onnxruntime-cpu/lib
FACT ort-dylib-real /usr/local/lib/onnxruntime-cpu/lib/libonnxruntime.so.1.30.0
FACT ort-link-lib yes
FACT ort-probe yes'
_CC_ORT_PARTS="$(_extract _consumer_contract_fact)
$(_extract _consumer_ort_env_problem)
$(_extract _consumer_ort_env_verdict)"
_ortv() { bash -c "${_CC_ORT_PARTS}"$'\n''_consumer_ort_env_verdict ort-crate-env "$1"' _ "$1" 2>&1; }
_ort_edit() { printf '%s\n' "${_CC_ORT_OK}" | sed -e "$1"; }
_ort_bad() { _ortv "$(_ort_edit "$1")"; }

t_case "G3: the chain lib dir, a dynamic link and a disarmed download hold the row"
t_assert_contains "$(_ortv "${_CC_ORT_OK}")" "OK ort-crate-env ORT_LIB_LOCATION -> /usr/local/lib/onnxruntime-cpu/lib" \
  "what Dockerfile.package bakes"
t_assert_contains "$(_ortv "$(_ort_edit 's/^ENV ort-skip-download 1/ENV ort-skip-download TRUE/')")" "OK ort-crate-env" \
  "ort-sys reads 'true' case-insensitively"
t_assert_contains "$(_ortv "$(_ort_edit 's#^ENV cargo-net-offline .*#ENV cargo-net-offline true#')")" "OK ort-crate-env" \
  "a truthy CARGO_NET_OFFLINE only disarms the download harder"
t_assert_contains "$(CC_PROBE="${_CC_ORT_OK}" bash -c "${_CC_PARTS}"$'\n'"${_CC_ORT_PARTS}"$'\n''_consumer_contract_verdicts amd64 "${CC_PROBE}"' 2>&1 \
  | grep -e '^OK ort-crate-env' || true)" "OK ort-crate-env" "the verdict table routes the row to its own verdict"

t_case "G3: every way back to pyke's ORT, or to a non-chain one, is BAD (mutation)"
_t_edit_table _ort_bad "BAD ort-crate-env " <<'ROWS'
s#^ENV ort-lib-location .*#ENV ort-lib-location#;s#^FACT ort-lib-real .*#FACT ort-lib-real#	ORT_LIB_LOCATION () resolves to nothing
s#^FACT ort-lib-real .*#FACT ort-lib-real /opt/opencv5/lib#	ORT_LIB_LOCATION (/usr/local/lib/onnxruntime-cpu/lib) resolves to /opt/opencv5/lib
s#^FACT ort-link-lib yes#FACT ort-link-lib no#	/usr/local/lib/onnxruntime-cpu/lib has no libonnxruntime.so
s#^FACT ort-dylib-real .*#FACT ort-dylib-real /opt/opencv5/lib/libonnxruntime.so.1.25.1#	ORT_DYLIB_PATH (/usr/local/lib/onnxruntime-cpu/lib/libonnxruntime.so) resolves to /opt/opencv5/lib
s#^FACT ort-dylib-real .*#FACT ort-dylib-real#	ORT_DYLIB_PATH (/usr/local/lib/onnxruntime-cpu/lib/libonnxruntime.so) resolves to nothing
s#^ENV ort-prefer-dynamic 1#ENV ort-prefer-dynamic 0#	ENV ort-prefer-dynamic is "0"
/^ENV ort-skip-download/d	ENV ort-skip-download is ""
s#^ENV ort-skip-download 1#ENV ort-skip-download yes#	ENV ort-skip-download is "yes"
s#^ENV ort-lib-path .*#ENV ort-lib-path /root/.cache/ort.pyke.io#	ORT_LIB_PATH is set (/root/.cache/ort.pyke.io)
s#^ENV ort-lib-path .*#ENV ort-lib-path #	ORT_LIB_PATH is set ()
/^ENV ort-lib-path/d	ORT_LIB_PATH is set ()
s#^ENV cargo-net-offline .*#ENV cargo-net-offline false#	CARGO_NET_OFFLINE is falsy
s#^ENV cargo-net-offline .*#ENV cargo-net-offline #	CARGO_NET_OFFLINE is falsy
s#^ENV cargo-net-offline .*#ENV cargo-net-offline yes#	CARGO_NET_OFFLINE is falsy
ROWS

t_case "G3: a probe without its completion fact is NOFACT, never an empty-but-healthy env"
t_assert_contains "$(_ortv "$(_ort_edit '/^FACT ort-probe/d')")" "NOFACT ort-crate-env" \
  "a probe that never finished proves nothing, whatever lines it printed"

# Vulkan SDK toolset; tool lists and frozen floors are read from the smoke so the suite cannot drift
_VK_TOOL_VARS="$(grep -E '^_VK_(REQUIRED|REPORTED)_TOOLS=|^_VK_TOOLSET_FROZEN=' "${SMOKE}")"
eval "${_VK_TOOL_VARS}"
_vk_inventory() { for _t in $1; do printf 'TOOL %s\n' "${_t}"; done; }
# The counts a healthy arm64 prefix prints, so a case that is about TOOLS says so.
_vk_counts() { printf 'TOOLS %s\nLAYERS %s\nLAYER yes\n' "${1:-20}" "${2:-4}"; }
_vk_toolset() {
  VK_OUT="$1" bash -c '
    '"${_STUBS}"'
    '"${_VK_TOOL_VARS}"'
    _rt_run() { printf "%s\n" "${VK_OUT}"; }
    '"$(_extract _vk_toolset_floor)"'
    '"$(_extract _vk_floor_verdict)"'
    '"$(_extract check_vulkan_toolset)"'
    check_vulkan_toolset img '"${2:-arm64}"'' 2>&1
}

t_case "the shipped shape -- full libraries, two binaries -- fails"
t_assert_contains "$(_vk_toolset "TOOL glslangValidator
$(_vk_counts 2)")" \
  "missing required tools:" \
  "a prefix you can link against but cannot compile a shader with is the defect"

t_case "one absent required tool fails and names it"
t_assert_contains "$(_vk_toolset "$(_vk_inventory "${_VK_REQUIRED_TOOLS/spirv-val/}")
$(_vk_counts)")" \
  "spirv-val" "the gate must name what is missing, not just that something is"

t_case "the complete required set passes"
t_assert_contains "$(_vk_toolset "$(_vk_inventory "${_VK_REQUIRED_TOOLS}")
$(_vk_counts)")" \
  "SDK tools present" "what a correctly cross-built prefix prints"

t_case "an absent REPORTED tool warns and does not fail"
t_assert_eq "0" \
  "$(_vk_toolset "$(_vk_inventory "${_VK_REQUIRED_TOOLS}")
$(_vk_counts)" | grep -c '^FAIL')" \
  "gfxrecon and friends are VK2 components; losing one is not a lane failure"

t_case "an absent reported tool is still visible as a WARN"
t_assert_contains "$(_vk_toolset "$(_vk_inventory "${_VK_REQUIRED_TOOLS}")
$(_vk_counts)")" \
  "WARN gfxrecon-info absent" "non-fatal must not mean invisible"

t_case "a missing validation layer manifest FAILS"
t_assert_contains "$(_vk_toolset "$(_vk_inventory "${_VK_REQUIRED_TOOLS}")
TOOLS 20
LAYERS 4")" \
  "FAIL no validation layer manifest" "you cannot develop a Vulkan app without the layers"

t_case "the layer manifest is reported when the prefix carries it"
t_assert_contains "$(_vk_toolset "$(_vk_inventory "${_VK_REQUIRED_TOOLS}")
$(_vk_counts)")" "validation layer manifest present" "the good shape is stated too"

# Frozen floors: without a floor, a shrinking toolset passes
t_case "a prefix below its frozen tool count fails, and says what it is below"
t_assert_contains "$(_vk_toolset "$(_vk_inventory "${_VK_REQUIRED_TOOLS}")
$(_vk_counts 19)")" \
  "carries 19 tools, below its frozen floor of 20" \
  "a lane that LOSES tools while keeping the required names is the regression this catches"

t_case "fewer layer manifests than frozen fails too"
t_assert_contains "$(_vk_toolset "$(_vk_inventory "${_VK_REQUIRED_TOOLS}")
$(_vk_counts 20 3)")" \
  "carries 3 layer manifests, below its frozen floor of 4"

t_case "a prefix that GAINS tools passes and prints the floor to record"
_vk_out="$(_vk_toolset "$(_vk_inventory "${_VK_REQUIRED_TOOLS}")
$(_vk_counts 24)")"
t_assert_contains "${_vk_out}" "RATCHET: floor 20 -> 24" "a gain has to be recorded, not drift"
t_assert_eq "0" "$(printf '%s\n' "${_vk_out}" | grep -c '^FAIL')" "growing is not a failure"

t_case "amd64 carries the downloaded SDK and has its own, higher floor"
t_assert_contains "$(_vk_toolset "$(_vk_inventory "${_VK_REQUIRED_TOOLS}")
$(_vk_counts 40 6)" amd64)" \
  "carries 40 tools, below its frozen floor of 52" \
  "one floor for all three arches would have to be the smallest, which asserts nothing about amd64"

t_case "an arch with no frozen row fails instead of inheriting silence"
t_assert_contains "$(_vk_toolset "$(_vk_inventory "${_VK_REQUIRED_TOOLS}")
$(_vk_counts)" ppc64le)" \
  "FAIL no _VK_TOOLSET_FROZEN row for ppc64le" \
  "a WARN here is the same silence the floors exist to end"

# llvm-target startability: the sdk walk resolves sonames on the builder, so only a runtime-side walk catches a missing one
_llvm_startable() {
  LT_OUT="$1" bash -c '
    '"${_STUBS}"'
    _rt_run() { printf "%s\n" "${LT_OUT}"; }
    '"$(_extract check_llvm_target_startable)"'
    check_llvm_target_startable img amd64' 2>&1
}

t_case "main() actually calls it -- a gate nothing invokes is not a gate"
t_assert_contains "$(grep -e '^    check_' "${SMOKE}")" "check_llvm_target_startable" \
  "the functional battery is the only place this runs; unwired it is 40 lines of dead text"

t_case "a clean prefix passes and says how many it walked"
t_assert_contains "$(_llvm_startable "COUNT 0 142")" "OK  0 of 142 llvm-target binaries"

t_case "the liblldb shape FAILS and names the binaries"
_lt_out="$(_llvm_startable "  BROKEN /usr/local/llvm-target/bin/lldb -> liblldb.so.22
  BROKEN /usr/local/llvm-target/bin/lldb-dap -> liblldb.so.22
  BROKEN /usr/local/llvm-target/bin/lldb-mcp -> liblldb.so.22
COUNT 3 142")"
t_assert_contains "${_lt_out}" "FAIL 3 of 142"
t_assert_contains "${_lt_out}" "BROKEN /usr/local/llvm-target/bin/lldb-dap -> liblldb.so.22" \
  "the operator needs the NAMES, not just the count"

t_case "a probe that did not run is not a clean prefix"
t_assert_contains "$(_llvm_startable "docker: no such container")" \
  "printed no COUNT" "an empty walk reads exactly like a healthy one unless the gate says otherwise"

t_case "an image without the prefix says so instead of failing"
_lt_out="$(_llvm_startable "ABSENT")"
t_assert_contains "${_lt_out}" "WARN /usr/local/llvm-target/bin absent"
t_assert_eq "0" "$(printf '%s\n' "${_lt_out}" | grep -c '^FAIL')"

# Android SDK ABI; the ABI->machine table is read from the smoke so the suite cannot drift
_ABI_TABLE="$(grep -E '^_ANDROID_ABI_MACHINE=' "${SMOKE}")"
_abi_gate() {
  ABI_OUT="$1" bash -c '
    '"${_STUBS}"'
    '"${_ABI_TABLE}"'
    _rt_run() { printf "%s\n" "${ABI_OUT}"; }
    '"$(_extract _android_abi_want)"'
    '"$(_extract check_android_abi)"'
    check_android_abi img arm64' 2>&1
}

# Machine 62 (x86-64) is the broken stage's output; 183 (AArch64) is the fixed one's.
_ABI_SAMPLE=/opt/android/litert/lib/libbenchmark_main.a
_abi_shipped="ABI arm64-v8a
MACH 62 420 ${_ABI_SAMPLE}"
_abi_fixed="ABI arm64-v8a
MACH 183 420 ${_ABI_SAMPLE}"

t_case "the shipped shape -- an arm64-v8a claim over an x86-64 payload -- fails"
t_assert_contains "$(_abi_gate "${_abi_shipped}")" \
  "is incompatible" "this is the consumer's link error, caught before it ships"

t_case "the failure names the count and a sample object"
t_assert_contains "$(_abi_gate "${_abi_shipped}")" \
  "420 object(s) of ELF machine 62" "a count and a path is what makes it actionable"

t_case "a correctly built arm64-v8a payload passes"
t_assert_contains "$(_abi_gate "${_abi_fixed}")" \
  "all arm64-v8a" "what the fixed android stage prints"

t_case "an image that does not advertise the ABI fails"
t_assert_contains "$(_abi_gate "ABI unset")" \
  "does not advertise ANDROID_TARGET_ABI" "a consumer cannot guess which ABI it got"

t_case "an ABI the table does not know fails rather than passing vacuously"
t_assert_contains "$(_abi_gate "ABI mips64
MACH 183 4 /opt/android/x")" "is not an ABI this gate knows" \
  "an unknown claim must never read as satisfied"

t_case "a mixed payload fails on the wrong half even when the right half is there"
t_assert_contains "$(_abi_gate "ABI arm64-v8a
MACH 183 400 /opt/android/ok.so
MACH 62 20 /opt/android/gstreamer/libgstreamer-1.0.a")" \
  "libgstreamer-1.0.a" "one stale ABI among many is exactly how it reached the consumer"

t_case "an empty tree warns instead of passing silently"
t_assert_contains "$(_abi_gate "ABI arm64-v8a")" \
  "no Android ELF objects" "nothing found is not the same as everything correct"

# An exemption is only legitimate when another gate, here check_android_abi, takes the tree over.
t_case "/opt/android is exempt from tree-arch and owned by the ABI gate instead"
_EXEMPT="$(grep -E '^_RT_TREE_ARCH_EXEMPT=' "${SMOKE}")"
t_assert_contains "${_EXEMPT}" "/opt/android" \
  "on amd64 an arm64-v8a payload is legitimately AArch64; tree-arch asks the wrong question"
t_assert_contains "$(_extract _android_abi_py)" "/opt/android" \
  "the exemption is only honest while the ABI gate actually walks that tree"
t_assert_contains "$(_extract check_android_abi)" "ANDROID_TARGET_ABI" \
  "and judges it against the ABI the image advertises, not against the image arch"

# check_consumer_contract's reader reports an unknown verb as a dropped row.
t_case "every verdict verb a producer emits is one the reader's case list handles"
_VERBS_READ="$(_extract check_consumer_contract | sed -n 's/^ *\([A-Z]\{2,\}\)).*/\1/p' | sort -u)"
_VERBS_EMITTED="$(for _f in _consumer_present_verdict _consumer_dir_verdict _consumer_jdk_verdict \
                            _consumer_tool_verdict _consumer_owner_verdict _consumer_android_verdict \
                            _consumer_exempt_verdict; do
    _extract "${_f}" 2>/dev/null | grep -o "printf '[A-Z]\{2,\}" | sed "s/printf '//"
  done | sort -u)"
_unknown=""
for _v in ${_VERBS_EMITTED}; do
  printf '%s\n' "${_VERBS_READ}" | grep -qx "${_v}" || _unknown="${_unknown} ${_v}"
done
t_assert_eq "" "${_unknown}" "a verb no case arm names is a row the gate silently drops"
t_assert_eq "0" "$(printf '%s\n' "${_VERBS_EMITTED}" | grep -c . 2>/dev/null | grep -x 0 || echo 0)" \
  "and the extraction must actually find verbs, or this case proves nothing"

t_summary
