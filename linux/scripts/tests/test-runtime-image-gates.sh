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
t_assert_contains "${_probe}" "ADV PYTHON_VERSION"  "the advertised section must be there"
t_assert_contains "${_probe}" "HAVE PYTHON_VERSION" "the actual-versions section must be there"
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

t_summary
