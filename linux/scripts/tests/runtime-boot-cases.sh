#!/usr/bin/env bash
# Runs in the runtime-image suite's shared fixture shell.

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
    '"$(_extract _rt_run_optional)"'
    '"$(_extract _smoke_runtime_pin_matches)"'
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
    '"$(_extract _rt_run_optional)"'
    '"$(_extract _smoke_runtime_pin_matches)"'
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
_truth_gate_output() {
  local verdicts="$1" probe_rc="$2" gate="$3"
  VERDICTS="${verdicts}" PROBE_RC="${probe_rc}" bash -c '
    '"${_STUBS}"'
    _truth_fixture_verdicts() { printf "%s\n" "${VERDICTS}"; }
    _advert_verdicts() { _truth_fixture_verdicts; }
    _venv_set_verdicts() { _truth_fixture_verdicts; }
    _SHIPPED_TRUTH_PROBE=""
    _SHIPPED_TRUTH_PROBE_RC="${PROBE_RC}"
    '"$(_extract _smoke_probe_required)"'
    '"$(_extract _smoke_unknown_verdict)"'
    '"$(_extract _advertised_probe_failure)"'
    '"$(_extract _venv_probe_failure)"'
    '"$(_extract _shipped_truth_section)"'
    '"$(_extract _shipped_truth_verdict_rows)"'
    '"$(_extract _advertised_verdict_line)"'
    '"$(_extract _check_advertised_versions)"'
    '"$(_extract _check_venv_package_set)"'
    '"$(_extract check_advertised_versions)"'
    '"$(_extract check_venv_package_set)"'
    '"${gate}"' img amd64' 2>&1
}

_advert_gate() { _truth_gate_output "$1" "${2:-0}" check_advertised_versions; }
_venv_gate() { _truth_gate_output "${2:-ASSERTED 1}" "${1:-0}" check_venv_package_set; }

_venv_status_gate() {
  VENV_STATUS="$1" bash -c '
    '"${_STUBS}"'
    target_arch=amd64
    _SHIPPED_TRUTH_PROBE="${VENV_STATUS}"
    _venv_set_verdicts() { printf "ASSERTED 1\n"; }
    '"$(_extract _check_venv_package_set)"'
    _check_venv_package_set
    printf "FAILURES=%s\n" "${FAILURES}"
  ' 2>&1
}

t_case "an incomplete shared probe fails the advertised gate with its own diagnostic"
_out="$(_advert_gate "OK RUST_VERSION 1.98.0" 1)"
t_assert_contains "${_out}" "FAIL advertised-version gate could not run: the in-image probe never printed RTPROBE_DONE (amd64) -- a gate that cannot run is not a pass"
t_assert_eq 0 "$(printf '%s\n' "${_out}" | grep -c '^PASS ')" "the unavailable probe cannot pass"
t_assert_eq 0 "$(printf '%s\n' "${_out}" | grep -c 'matches the image')" "the verdict table is not consumed"

t_case "an incomplete shared probe fails the venv gate with its own diagnostic"
_out="$(_venv_gate 1 "ASSERTED 1")"
t_assert_contains "${_out}" "FAIL venv package-set gate could not run: the in-image probe never printed RTPROBE_DONE (amd64) -- a gate that cannot run is not a pass"
t_assert_eq 0 "$(printf '%s\n' "${_out}" | grep -c '^PASS ')" "the unavailable probe cannot pass"
t_assert_eq 0 "$(printf '%s\n' "${_out}" | grep -c 'requirement edge')" "the verdict table is not consumed"

t_case "an empty venv assertion count remains a failure"
t_assert_contains "$(_venv_gate 0 "ASSERTED 0")" "FAIL VENV-SET asserted NOTHING on amd64" \
  "the common probe check cannot turn an empty contract into a pass"

t_case "a crashed venv metadata probe fails instead of becoming an unavailable skip"
_out="$(_venv_status_gate "VENV ERROR metadata-probe-crashed")"
t_assert_contains "${_out}" "FAIL venv package-set metadata probe failed on amd64: metadata-probe-crashed"
t_assert_contains "${_out}" "FAILURES=1" "a probe error contributes one fatal verdict"

t_case "an absent optional metadata package remains a loud unavailable skip"
_out="$(_venv_status_gate "VENV ABSENT packaging-module-missing")"
t_assert_contains "${_out}" "SKIP venv package-set comparison UNAVAILABLE on amd64: packaging-module-missing"
t_assert_contains "${_out}" "FAILURES=0" "the explicit unavailable state is not reported as a pass or failure"

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
t_assert_contains "$(_advert_gate "WHAT RUST_VERSION 1.98.0")" \
  "advertised-version gate: unknown verdict 'WHAT' for RUST_VERSION on amd64 -- a verb no arm handles is a silently dropped row"

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
    '"$(_extract _smoke_probe_values)"'
    '"$(_extract _smoke_read_probe_records)"'
    '"$(_extract _tree_missing_record)"'
    '"$(_extract _tree_noelf_record)"'
    '"$(_extract _tree_capped_record)"'
    '"$(_extract _tree_machine_record)"'
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
  SCAN="$1" WANT="$2" RAW_VERDICTS="${3:-}" bash -c '
    '"${_STUBS}"'
    _rt_run() { printf "%s\n" "${SCAN}"; }
    smoke_elf_machine_grep() { printf "%s" "${WANT}"; }
    _rt_manifest_trees() { printf "%s\n" "'"${_HT1_FIX}"'/native"; }
    _rt_tree_arch_exempt() { return 1; }
    '"$(_extract _smoke_probe_required)"'
    '"$(_extract _tree_arch_probe_failure)"'
    '"$(_extract _smoke_unknown_verdict)"'
    '"$(_extract _smoke_probe_values)"'
    '"$(_extract _smoke_read_probe_records)"'
    '"$(_extract _tree_missing_record)"'
    '"$(_extract _tree_noelf_record)"'
    '"$(_extract _tree_capped_record)"'
    '"$(_extract _tree_machine_record)"'
    '"$(_extract _tree_arch_verdicts)"'
    '"$(_extract _tree_arch_py)"'
    '"$(_extract _tree_arch_collect_manifest)"'
    '"$(_extract _tree_arch_bad_verdict)"'
    '"$(_extract check_manifest_tree_arch)"'
    if [ -n "${RAW_VERDICTS}" ]; then
      _tree_arch_verdicts() { printf "%s\n" "${RAW_VERDICTS}"; }
    fi
    check_manifest_tree_arch img arm64' 2>&1
}

t_case "the gate fails on a builder-arch tree"
t_assert_contains "$(_ht1_gate TREESCAN_DONE AArch64 "BAD /native X86-64 1 /native/libbad.so")" \
  "FAIL" "a BAD verdict must reach the summary"

t_case "the gate fails on an incomplete tree walk"
t_assert_contains "$(_ht1_gate TREESCAN_DONE AArch64 "CAPPED /native 20 -")" \
  "partial scan is not a pass" "a CAPPED verdict must fail the gate"

t_case "a scanner that never ran fails instead of passing empty"
t_assert_contains "$(_ht1_gate "python3: command not found" AArch64)" "could not run" \
  "no TREESCAN_DONE marker means the gate asserted nothing"

t_case "an unknown tree-arch verdict fails with its gate-specific diagnostic"
_out="$(_ht1_gate TREESCAN_DONE AArch64 "FUTURE /tree - 0 -")"
t_assert_contains "${_out}" "tree-arch gate: unknown verdict 'FUTURE' for /tree on arm64"
t_assert_eq 0 "$(printf '%s\n' "${_out}" | grep -c '^PASS ')" \
  "an unknown tree verdict cannot pass"

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
