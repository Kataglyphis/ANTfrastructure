#!/usr/bin/env bash
set -euo pipefail
# smoke-common.sh
# Shared smoke test utilities: pass/fail with FAILURES tracking, version checks,
# and ELF verification helpers.  Source this in all *-smoke.sh scripts.
#
# Usage:
#   source "$(dirname "$0")/smoke-common.sh"
#   source_module platform.sh   # for ELF/arch helpers if not already loaded

if [ -n "${_SMOKE_COMMON_LOADED:-}" ]; then
  return 0
fi
_SMOKE_COMMON_LOADED=1

FAILURES=0

# Fallback for cross_build_is_active when cross-env.sh is not loaded.
# The real definition in cross-env.sh checks both BUILD_MODE and arch mismatch.
# This fallback approximates it by checking BUILD_MODE and TARGET_ARCH != build arch.
# Both sides are normalized to OCI names via smoke_host_arch (defined below;
# resolved at call time) — TARGET_ARCH is usually an OCI name (amd64/arm64)
# while uname -m yields machine names (x86_64/aarch64), so a raw comparison
# never matched and native wrapper images skipped their functional checks.
if ! command -v cross_build_is_active >/dev/null 2>&1; then
  cross_build_is_active() {
    [ "${BUILD_MODE:-native}" = "cross" ] || return 1
    local _target="${TARGET_ARCH:-${TARGETARCH:-}}"
    [ -n "${_target}" ] && _target="$(smoke_host_arch "${_target}")"
    [ "${_target}" != "$(smoke_host_arch "${BUILDARCH:-$(uname -m)}")" ]
  }
fi

pass() { printf '  PASS %s\n' "$*"; }
fail() { printf '  FAIL %s\n' "$*" >&2; FAILURES=$((FAILURES + 1)); }

# Print the standard result banner and exit non-zero on any failure.
# Replaces the copy-pasted "=== Results: N failure(s) ===" + exit tail (and the
# duplicate print_results() defs in smoke-android.sh / smoke-vulkan.sh).
smoke_summary() {
  echo "=== Results: ${FAILURES} failure(s) ==="
  [ "${FAILURES}" -eq 0 ] || exit 1
}

# ── arch-map helpers ────────────────────────────────────────────────────────
# Always-available thin wrappers over the canonical 01-core/platform.sh arch
# functions.  Each prefers the platform.sh function when it has been sourced,
# and otherwise applies the inline case ONCE.  These replace the ~10 copies of
# `command -v arch_* || case "${arch}" in …` scattered across the smoke scripts.
# All cover the three supported target arches (amd64/arm64/riscv64).

# uname -m style machine name for a target arch (amd64 -> x86_64, …).
smoke_uname_name() {
  if command -v arch_uname_name_for >/dev/null 2>&1; then
    arch_uname_name_for "$1"
  else
    case "$1" in
      amd64)   printf '%s' 'x86_64' ;;
      arm64)   printf '%s' 'aarch64' ;;
      riscv64) printf '%s' 'riscv64' ;;
      *)       return 1 ;;
    esac
  fi
}

# OCI/Docker arch name for a machine name (default: $(uname -m)).
# x86_64 -> amd64, aarch64 -> arm64, riscv64 -> riscv64; unknown passes through.
smoke_host_arch() {
  local raw="${1:-$(uname -m)}"
  if command -v arch_normalize >/dev/null 2>&1; then
    arch_normalize "${raw}"
  else
    case "${raw}" in
      x86_64)  printf '%s' 'amd64' ;;
      aarch64) printf '%s' 'arm64' ;;
      riscv64) printf '%s' 'riscv64' ;;
      *)       printf '%s' "${raw}" ;;
    esac
  fi
}

# Debian multiarch triplet for a target arch (amd64 -> x86_64-linux-gnu, …).
smoke_deb_triplet() {
  if command -v arch_deb_multiarch_triplet_for >/dev/null 2>&1; then
    arch_deb_multiarch_triplet_for "$1"
  else
    case "$1" in
      amd64)   printf '%s' 'x86_64-linux-gnu' ;;
      arm64)   printf '%s' 'aarch64-linux-gnu' ;;
      riscv64) printf '%s' 'riscv64-linux-gnu' ;;
      *)       return 1 ;;
    esac
  fi
}

# LC_ALL=C readelf -h "Machine:" substring for a target arch (amd64 -> X86-64, …).
smoke_elf_machine_grep() {
  if command -v arch_elf_machine_grep_for >/dev/null 2>&1; then
    arch_elf_machine_grep_for "$1"
  else
    case "$1" in
      amd64)   printf '%s' 'X86-64' ;;
      arm64)   printf '%s' 'AArch64' ;;
      riscv64) printf '%s' 'RISC-V' ;;
      *)       return 1 ;;
    esac
  fi
}

# Rust target triple for a target arch (amd64 -> x86_64-unknown-linux-gnu, …).
smoke_rust_target() {
  if command -v arch_rust_target_triple_for >/dev/null 2>&1; then
    arch_rust_target_triple_for "$1"
  elif command -v rust_target_triple >/dev/null 2>&1; then
    rust_target_triple "$1"
  else
    case "$1" in
      amd64)   printf '%s' 'x86_64-unknown-linux-gnu' ;;
      arm64)   printf '%s' 'aarch64-unknown-linux-gnu' ;;
      riscv64) printf '%s' 'riscv64gc-unknown-linux-gnu' ;;
      *)       return 1 ;;
    esac
  fi
}

# Load the canonical 01-core/platform.sh arch helpers when available, from the
# baked-image layout (/opt/scripts/core) or the repo layout — whichever exists
# first. Best-effort: the smoke_* wrappers above fall back to their inline
# maps when platform.sh is absent. Replaces the hand-rolled copies that lived
# in smoke-cross-all-arches.sh, smoke-toolchain.sh, and smoke-wrapper.sh.
smoke_load_platform() {
  local _dir _p
  _dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  for _p in /opt/scripts/core/platform.sh "${_dir}/../01-core/platform.sh"; do
    if [ -f "${_p}" ]; then
      # shellcheck disable=SC1090
      source "${_p}" 2>/dev/null || true
      return 0
    fi
  done
  return 0
}

# ── binary / component gate helpers (backlog D3) ────────────────────────────
# Four idioms that smoke-media.sh had hand-written at 5 + 4 + 2 sites, each
# spelling its message out inline — so a wording or semantics fix only ever
# reached the copy that happened to be edited. They live here now; the drift
# guard in tests/test-smoke-arch-parity.sh keeps them here.

# Resolve a tool to the path the caller should use: its PATH location when it
# has one, else the supplied fallback. ALWAYS succeeds (the fallback branch is
# a printf), so `x="$(smoke_resolve_bin …)"` cannot trip errexit; deciding
# whether the result is usable stays with the caller's [ -x ] test. The
# fallback matters because a build-stage RUN inherits the ENV of the PREVIOUS
# layer: tools that ship under /opt/<pkg>/bin are routinely off PATH there.
smoke_resolve_bin() {
  command -v "$1" 2>/dev/null || printf '%s' "$2"
}

# True when a file carries the ELF magic. Deliberately the same 3-byte test
# (bytes 2-4 of the header) the smoke-media sites used, so lifting them here
# cannot change a verdict. `head` failing on a missing/unreadable file is
# absorbed, so this returns a clean "no" instead of killing the smoke under
# `set -e -o pipefail`.
smoke_is_elf() {
  [ "$(head -c4 "$1" 2>/dev/null | tail -c3 || true)" = "ELF" ]
}

# A binary that is PRESENT but cannot execute *here* is the normal build-sandbox
# state (ld paths and ENV land later, in configure-runtime.sh), so report it as
# INFO — but never as a pass, and never let a zero-byte/truncated/wrong-format
# file through: that is a real defect and fails.
smoke_deferred_if_elf() {
  local label="$1" path="$2" info="$3"
  if smoke_is_elf "${path}"; then
    echo "  INFO: ${info}"
  else
    fail "${label} at ${path} is not an ELF binary"
  fi
}

# Cross build: the artifact is foreign-arch, so nothing in this container can
# run or import it. Prove presence, say so, and report rc 0 = "handled, skip
# the functional half"; rc 1 = "not a cross build — go run the real check".
# The noun/action pair is what distinguishes the binary sites ("binary" /
# "execution") from the library and Python-bindings sites ("import").
smoke_cross_presence_gate() {
  local label="$1" path="$2" noun="${3:-binary}" action="${4:-execution}"
  cross_build_is_active 2>/dev/null || return 1
  pass "${label} ${noun} present at ${path} (cross build — ${action} skipped)"
}

# ELF machine string of a file (the value after "Machine:" in `LC_ALL=C readelf
# -h`). Reads foreign-arch binaries fine — nothing is executed. Kept as the raw
# pipeline rather than delegating to platform.sh's elf_machine_name(): all three
# call sites guard readelf/readability themselves and depend on THIS pipeline's
# exit status under `set -o pipefail`, and platform.sh is not sourced at all in
# smoke-android.sh.
smoke_elf_machine_of() {
  # Same thin-wrapper contract as the arch helpers above: prefer the canonical
  # platform.sh implementation, keep the inline pipeline only as the fallback
  # for smokes that run without platform.sh mounted. Written as a copy first,
  # which would have made this the FOURTH instance of the same readelf|sed|head
  # pipeline — the exact sprawl this helper block exists to end. Delegating
  # also inherits platform.sh's readelf-present and file-readable guards.
  if command -v elf_machine_name >/dev/null 2>&1; then
    elf_machine_name "$1"
    return
  fi
  command -v readelf >/dev/null 2>&1 || return 1
  [ -r "$1" ] || return 1
  LC_ALL=C readelf -h "$1" 2>/dev/null \
    | sed -n 's/^[[:space:]]*Machine:[[:space:]]*//p' \
    | head -n1
}

# Check that a command's output contains an expected string.
# Usage: check_version "gcc --version" "16.1.0" "host gcc"
check_version() {
  local cmd="$1" expected="$2" label="$3"
  local ver
  ver="$(${cmd} 2>/dev/null | head -1 || true)"
  if echo "${ver}" | grep -q "${expected}"; then
    pass "${label}: ${ver}"
  else
    fail "${label}: ${ver:-MISSING} (expected ${expected})"
  fi
}

# Check that a compiler's -dumpmachine starts with the expected prefix.
# Usage: check_dumpmachine "/opt/gcc-16.1.0/bin/gcc" "x86_64" "host gcc"
check_dumpmachine() {
  local cc="$1" expected="$2" label="$3"
  local dump
  [ -x "${cc}" ] || { fail "${label}: ${cc} not found"; return 1; }
  dump="$("${cc}" -dumpmachine 2>/dev/null || true)"
  if echo "${dump}" | grep -q "^${expected}"; then
    pass "${label}: -dumpmachine=${dump}"
  else
    fail "${label}: -dumpmachine=${dump} != ${expected}"
  fi
}

# Full compiler validation for a target architecture.
# Runs: -dumpmachine, ELF machine, cc1 compile-to-object, link smoke.
# Usage: validate_compiler_for_target <cc_path> <target_arch> [label] [mode]
#   mode=native (default) — the compiler BINARY is expected to be target-arch
#     (target-native compiler, e.g. the packaged cc); its ELF machine is checked.
#   mode=cross            — the compiler is a cross compiler whose BINARY is
#     host-arch (it merely emits target code), so the binary-ELF check is skipped;
#     the produced object/exe ELF (checked below) is what must be target-arch.
# (Complexity audit item 9: the old 108-line monolith split into five
# independent checks. fail() accumulates into the shared counter, so the
# driver needs no return plumbing; each helper takes explicit args and is
# callable in isolation — deliberately NOT the _VCS_* implicit-global
# convention validate-compilers.sh uses.)

_cc_check_dumpmachine() {
  local cc_path="$1" label="$2" expected_pattern="$3" target_arch="$4"
  local cc_dump
  cc_dump="$("${cc_path}" -dumpmachine 2>/dev/null || true)"
  if [ -z "${cc_dump}" ]; then
    fail "${label}: -dumpmachine returned empty"
    return 1
  fi
  if echo "${cc_dump}" | grep -q "^${expected_pattern}"; then
    pass "${label}: -dumpmachine=${cc_dump} (expected ${target_arch})"
  else
    fail "${label}: -dumpmachine=${cc_dump} != expected ${expected_pattern}"
  fi
}

# ELF machine check of the compiler BINARY — native mode only. A cross
# compiler's binary is host-arch (it emits target code), so this check does
# not apply; the object/exe ELF checks verify the emitted code instead.
_cc_check_binary_elf() {
  local cc_path="$1" label="$2" expected_machine="$3"
  command -v readelf >/dev/null 2>&1 || return 0
  local cc_machine
  cc_machine="$(smoke_elf_machine_of "${cc_path}")"
  if [ -n "${cc_machine}" ]; then
    case "${cc_machine}" in
      *"${expected_machine}"*) pass "${label}: ELF machine=${cc_machine}" ;;
      *) fail "${label}: ELF machine=${cc_machine} != expected ${expected_machine}" ;;
    esac
  else
    fail "${label}: cannot read ELF machine type"
  fi
}

# cc1 compile-to-object smoke + object ELF-machine assertion.
_cc_check_object() {
  local cc_path="$1" label="$2" expected_machine="$3"
  local tmpdir cc_obj
  tmpdir="$(mktemp -d)"
  cc_obj="${tmpdir}/smoke.o"
  if printf 'int answer(void){return 42;}\n' | "${cc_path}" -x c - -c -o "${cc_obj}" 2>/dev/null; then
    pass "${label}: cc1 compile-to-object smoke OK"
    if command -v readelf >/dev/null 2>&1 && [ -f "${cc_obj}" ]; then
      local obj_machine
      obj_machine="$(smoke_elf_machine_of "${cc_obj}")"
      case "${obj_machine}" in
        *"${expected_machine}"*) pass "${label}: object ELF machine=${obj_machine}" ;;
        *) fail "${label}: object ELF machine=${obj_machine} != expected ${expected_machine}" ;;
      esac
    fi
  else
    fail "${label}: cc1 compile-to-object smoke FAILED"
  fi
  rm -rf "${tmpdir}"
}

# Loader assertion (smoke-depth R8): compile+link succeed with a WRONG
# sysroot too — the classic escapees (bad dynamic-loader path, riscv64
# --with-isa-spec mismatch) all link cleanly and only die on the target.
# The requested ELF interpreter is readable on any host, no execution.
_cc_check_loader() {
  local cc_exe="$1" label="$2" target_arch="$3"
  command -v readelf >/dev/null 2>&1 || return 0
  local want_ld="" got_ld=""
  case "${target_arch}" in
    amd64)   want_ld="ld-linux-x86-64" ;;
    arm64)   want_ld="ld-linux-aarch64" ;;
    riscv64) want_ld="ld-linux-riscv64" ;;
  esac
  [ -n "${want_ld}" ] || return 0
  got_ld="$(LC_ALL=C readelf -l "${cc_exe}" 2>/dev/null | sed -n 's/.*interpreter: \(.*\)]/\1/p' | head -1 || true)"
  case "${got_ld}" in
    *"${want_ld}"*) pass "${label}: emitted ELF requests ${want_ld} (correct loader)" ;;
    "") echo "  INFO: ${label}: no PT_INTERP found (static or unusual link) — loader not asserted" ;;
    *) fail "${label}: emitted ELF requests '${got_ld}', expected *${want_ld}* (wrong sysroot?)" ;;
  esac
}

# Opportunistic real-execution proof when a qemu-user binary is present
# (not installed in the toolchain/package images by default — the loader
# assertion is the always-on gate).
_cc_check_qemu_exec() {
  local cc_path="$1" label="$2" target_arch="$3" tmpdir="$4"
  local qemu_bin=""
  qemu_bin="$(command -v "qemu-$(smoke_uname_name "${target_arch}" 2>/dev/null || true)-static" 2>/dev/null || true)"
  [ -n "${qemu_bin}" ] || qemu_bin="$(command -v "qemu-$(smoke_uname_name "${target_arch}" 2>/dev/null || true)" 2>/dev/null || true)"
  [ -n "${qemu_bin}" ] || return 0
  local q_exe="${tmpdir}/smoke-static"
  if printf 'int main(void){return 42;}\n' | "${cc_path}" -x c - -static -o "${q_exe}" 2>/dev/null; then
    local q_rc=0
    "${qemu_bin}" "${q_exe}" >/dev/null 2>&1 || q_rc=$?
    if [ "${q_rc}" -eq 42 ]; then
      pass "${label}: static binary RUNS under ${qemu_bin##*/} (exit 42)"
    else
      fail "${label}: static binary built but ran wrong under ${qemu_bin##*/} (rc=${q_rc}, want 42)"
    fi
  fi
}

validate_compiler_for_target() {
  local cc_path="$1"
  local target_arch="$2"
  local label="${3:-${cc_path}}"
  local mode="${4:-native}"
  local expected_pattern expected_machine tmpdir

  # `|| true` so the guard below is REACHABLE: smoke_uname_name returns 1 on an
  # unknown arch, and under set -e the bare substitution killed the script
  # before the intended "Unknown arch" fail could fire.
  expected_pattern="$(smoke_uname_name "${target_arch}" 2>/dev/null || true)"
  expected_machine="$(smoke_elf_machine_grep "${target_arch}" 2>/dev/null || true)"
  [ -n "${expected_pattern}" ] || { fail "Unknown arch: ${target_arch}"; return 1; }

  _cc_check_dumpmachine "${cc_path}" "${label}" "${expected_pattern}" "${target_arch}" || return 1
  [ "${mode}" != "cross" ] && _cc_check_binary_elf "${cc_path}" "${label}" "${expected_machine}"
  _cc_check_object "${cc_path}" "${label}" "${expected_machine}"

  # link smoke, then the checks that need the linked exe
  tmpdir="$(mktemp -d)"
  local cc_exe="${tmpdir}/smoke"
  if printf 'int main(void){return 0;}\n' | "${cc_path}" -x c - -o "${cc_exe}" 2>/dev/null; then
    pass "${label}: link smoke OK"
    _cc_check_loader "${cc_exe}" "${label}" "${target_arch}"
    [ "${mode}" = "cross" ] && _cc_check_qemu_exec "${cc_path}" "${label}" "${target_arch}" "${tmpdir}"
  else
    fail "${label}: link smoke FAILED (missing crt/startup files?)"
  fi
  rm -rf "${tmpdir}"
}

# Split a comma/space-separated arch list into words. Self-contained on purpose:
# the smoke scripts source only smoke-common.sh + platform.sh and run under a
# non-login `bash -c` in Dockerfile.package, so they must NOT depend on
# 01-core/build-helpers.sh being sourced. They previously called that file's
# arch_list_to_words unqualified — undefined here, so the cross-compiler loops
# silently produced an empty list ("0 failures" with nothing actually tested).
# NEWLINE-separated on purpose (mirrors build-helpers.sh arch_list_to_words):
# space-separated output silently stops splitting in `for` loops under
# IFS=$'\n\t'; newlines split under both the default and the strict IFS.
smoke_arch_words() {
  printf '%s\n' "${1:-}" | tr ', ' '\n\n'
}

# ── generated ONNX fixture (SMOKE-DEPTH item c, 2026-08-23) ─────────────────
# Print a self-contained Python program that BUILDS a one-node ONNX graph and
# runs it through an InferenceSession. Until this existed nothing in the repo
# ever executed an inference: the venv battery's session check went through
# `torch.onnx.export`, which needs `onnxscript` — not in the venv — so it
# printed "SKIP ort InferenceSession check" on all three shipped wave-5
# arches. A green line with nothing behind it, and therefore no evidence that
# ANY execution provider works.
#
# The model is emitted as RAW protobuf (~110 bytes, opset 13 `Add`) rather than
# via the `onnx` package on purpose: `onnx` is not installed in the runtime
# venv and pulling it in for a smoke would add a heavy build dependency to
# every wrapper. Wire format only, no network, no temp files.
#
# Two consumers, one source of truth: smoke-torch-venv.sh pipes it into the
# venv python in-image, and smoke-runtime-image.sh injects it as an env var
# (so it also gates images that were built before this check existed).
# Exit codes: 0 = ran, 1 = wrong result, 3 = onnxruntime/numpy unavailable.
smoke_minimal_onnx_py() {
  cat <<'ONNX_PY'
import sys

try:
    import numpy as np
    import onnxruntime as ort
except Exception as exc:
    print("ONNX-EP SKIP: onnxruntime/numpy unavailable (%s)" % exc)
    sys.exit(3)


# Minimal protobuf writers (onnx.proto field numbers in the callers below).
def _varint(n):
    out = bytearray()
    while True:
        b = n & 0x7F
        n >>= 7
        if n:
            out.append(b | 0x80)
        else:
            out.append(b)
            return bytes(out)


def _msg(field, payload):
    return _varint((field << 3) | 2) + _varint(len(payload)) + payload


def _int(field, value):
    return _varint(field << 3) + _varint(value)


def _txt(field, value):
    return _msg(field, value.encode())


def _value_info(name, dims):
    # ValueInfoProto{name=1, type=2} -> TypeProto{tensor_type=1}
    #   -> Tensor{elem_type=1 (FLOAT), shape=2} -> Dimension{dim_value=1}
    shape = b"".join(_msg(1, _int(1, d)) for d in dims)
    return _txt(1, name) + _msg(2, _msg(1, _int(1, 1) + _msg(2, shape)))


# NodeProto{input=1, output=2, name=3, op_type=4}
node = _txt(1, "X") + _txt(1, "Y") + _txt(2, "Z") + _txt(3, "add") + _txt(4, "Add")
# GraphProto{node=1, name=2, input=11, output=12}
graph = (_msg(1, node) + _txt(2, "containerhub-smoke")
         + _msg(11, _value_info("X", (1, 4)))
         + _msg(11, _value_info("Y", (1, 4)))
         + _msg(12, _value_info("Z", (1, 4))))
# ModelProto{ir_version=1, producer_name=2, graph=7, opset_import=8}
model = (_int(1, 7) + _txt(2, "containerhub-smoke") + _msg(7, graph)
         + _msg(8, _int(2, 13)))

sess = ort.InferenceSession(model, providers=["CPUExecutionProvider"])
out = sess.run(None, {"X": np.array([[1, 2, 3, 4]], np.float32),
                      "Y": np.array([[10, 20, 30, 40]], np.float32)})[0]
if out.tolist() != [[11.0, 22.0, 33.0, 44.0]]:
    print("ONNX-EP FAIL: Add graph returned %r" % (out.tolist(),))
    sys.exit(1)
print("ONNX-EP OK: onnxruntime %s served the graph on %s (available: %s)"
      % (ort.__version__, ",".join(sess.get_providers()),
         ",".join(ort.get_available_providers())))
ONNX_PY
}
