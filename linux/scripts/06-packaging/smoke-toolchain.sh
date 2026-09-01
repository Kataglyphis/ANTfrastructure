#!/usr/bin/env bash
set -euo pipefail

# smoke-toolchain.sh
# Validates the compiler toolchain inside the cross-compiler image:
#   - GCC ${GCC_VERSION} (versions.env pin) for all cross targets
#   - LLVM/Clang 22.1.8
#   - Rust/Cargo
#   - Python 3.14
#   - All cross-linkers produce correct ELF for each target
#
# Usage:
#   smoke-toolchain.sh                          # test all arches
#   smoke-toolchain.sh amd64,arm64              # test specific arches
#
# Designed to run inside Dockerfile.toolchain during the final bundle step.

# Prefer canonical versions.env over the fallback literals below (a stale
# PYTHON_VERSION default here once made smoke fail against a correctly built
# newer interpreter). Env values passed by the orchestrator still win.
for _sve in /opt/scripts/core/load-versions-env.sh \
            "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../01-core/load-versions-env.sh"; do
  if [ -f "${_sve}" ]; then
    # shellcheck disable=SC1090
    source "${_sve}"
    for _vef in /opt/scripts/core/versions.env \
                "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../01-core/versions.env"; do
      [ -f "${_vef}" ] && { load_versions_env "${_vef}"; break; }
    done
    break
  fi
done
unset _sve _vef
: "${GCC_VERSION:=16.2.0}"
: "${LLVM_RELEASE:=22.1.8}"
: "${PYTHON_VERSION:=3.14.7}"
: "${PYTHON_MAJOR_MINOR:=3.14}"
: "${GCC_PREFIX:=/opt/gcc-${GCC_VERSION}}"

# Source shared smoke utilities
_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${_SCRIPT_DIR}/smoke-common.sh"

# Load platform helpers (from 01-core or /opt/scripts/core) if available
smoke_load_platform

smoke_target() {
  local target_arch="$1"
  local triplet

  triplet="$(smoke_deb_triplet "${target_arch}" 2>/dev/null || true)"
  [ -n "${triplet}" ] || { fail "Unknown arch: ${target_arch}"; return; }

  echo "--- Target: ${target_arch} (${triplet}) ---"

  local cross_gcc="${GCC_PREFIX}/bin/${triplet}-gcc"
  local cross_gpp="${GCC_PREFIX}/bin/${triplet}-g++"
  local cross_ld="${GCC_PREFIX}/bin/${triplet}-ld"

  validate_compiler_for_target "${cross_gcc}" "${target_arch}" "cross-gcc (${target_arch})" cross

  if [ -x "${cross_gpp}" ]; then
    local expected_pat
    expected_pat="$(smoke_uname_name "${target_arch}" 2>/dev/null || true)"
    check_dumpmachine "${cross_gpp}" "${expected_pat}" "cross-g++ (${target_arch})"
  fi
  if [ -x "${cross_ld}" ]; then
    pass "cross-ld exists for ${target_arch}"
  else
    fail "cross-ld (${triplet}-ld) not found"
  fi

  echo ""
}

print_smoke_header() {
  local host_arch="$1"
  local target_arches="$2"

  echo "=== Toolchain Smoke Test ==="
  echo "Host: ${host_arch}"
  echo "Targets: ${target_arches}"
  echo ""
}

check_host_gcc() {
  # Host GCC
  echo "--- Host GCC (amd64) ---"
  check_version "${GCC_PREFIX}/bin/gcc --version" "${GCC_VERSION}" "host gcc"
  check_dumpmachine "${GCC_PREFIX}/bin/gcc" "x86_64" "host gcc"
  check_version "${GCC_PREFIX}/bin/g++ --version" "${GCC_VERSION}" "host g++"
  echo ""
}

check_llvm_clang() {
  # LLVM/Clang
  echo "--- LLVM/Clang ---"
  check_version "clang --version" "${LLVM_RELEASE}" "clang"
  check_dumpmachine "$(command -v clang)" "x86_64" "host clang"
  check_version "clang++ --version" "${LLVM_RELEASE}" "clang++"
  echo ""
}

check_rust() {
  local target_arches="$1"

  # Rust
  echo "--- Rust/Cargo ---"
  # Both pin the versions.env value: grepping the tool's own name could never
  # fail, and an unset pin must fail loudly rather than pass vacuously.
  if [ -z "${RUST_VERSION:-}" ]; then
    fail "rustc/cargo: RUST_VERSION is unset, so there is nothing to pin against"
  else
    check_version "rustc --version" "${RUST_VERSION}" "rustc"
    check_version "cargo --version" "${CARGO_VERSION:-${RUST_VERSION}}" "cargo"
  fi
  # Host compile+RUN: the version banner proves the driver starts, nothing
  # more. A miscompiled/rlib-broken toolchain still prints a version.
  local _rs_tmp
  _rs_tmp="$(mktemp -d)"
  printf 'fn main(){assert_eq!(2+2,4);}\n' > "${_rs_tmp}/m.rs"
  if rustc -O "${_rs_tmp}/m.rs" -o "${_rs_tmp}/m" 2>/dev/null && "${_rs_tmp}/m"; then
    pass "rustc compiles and RUNS a host binary"
  else
    fail "rustc host compile/run FAILED"
  fi
  for target in $(smoke_arch_words "${target_arches}"); do
    local rust_target
    rust_target="$(smoke_rust_target "${target}" 2>/dev/null || true)"
    # Guard: an unknown arch yields an empty rust_target, and `grep -q ""`
    # matches every line — which used to fake-pass the check.
    if [ -z "${rust_target}" ]; then
      fail "Rust target unknown for arch ${target} (no triple mapping)"
    elif rustup target list --installed 2>/dev/null | grep -q "${rust_target}"; then
      # `--installed` lists a target even when its std rlibs are missing —
      # emit-obj is the cheapest proof the target std is genuinely usable
      # (no execution, so it works for every arch).
      printf 'pub fn f(x:i32)->i32{x*2}\n' > "${_rs_tmp}/l.rs"
      if rustc --target "${rust_target}" --crate-type=lib --emit=obj \
           "${_rs_tmp}/l.rs" -o "${_rs_tmp}/l.o" 2>/dev/null; then
        pass "Rust target ${rust_target} installed and usable (emit-obj OK)"
      else
        fail "Rust target ${rust_target} LISTED but cannot emit an object (std rlibs missing/broken)"
      fi
    else
      fail "Rust target ${rust_target} not installed"
    fi
  done
  rm -rf "${_rs_tmp}"
  echo ""
}

check_node() {
  echo "--- Node.js ---"
  # node had ZERO smoke coverage (smoke-depth R15) although the WASM gate in
  # smoke-media silently self-disables when node is absent.
  if ! command -v node >/dev/null 2>&1; then
    fail "node not on PATH (the LiteRT-web WASM gate silently self-disables without it)"
    echo ""
    return 0
  fi
  if [ -n "${NODE_VERSION:-}" ]; then
    # EXACT match, not a prefix (tightened 2026-08-27). `grep "^v26.8.0"` also
    # matched `v26.8.0-alpha.0.0.0`, so the gate passed while the image shipped
    # a prerelease whose own npm refused to support it -- and it would equally
    # have matched v26.8.01 or v26.8.0x. The suffix is the whole point here.
    if [ "$(node --version 2>/dev/null)" = "v${NODE_VERSION}" ]; then
      pass "node version matches pin (v${NODE_VERSION})"
    else
      fail "node $(node --version 2>/dev/null || echo '?') != pinned v${NODE_VERSION}"
    fi
  fi
  if node -e 'const a=require("assert");a.strictEqual(JSON.parse(JSON.stringify({x:1})).x,1);a.ok(require("crypto").createHash("sha256").update("x").digest("hex").length===64);' 2>/dev/null; then
    pass "node executes JS (JSON + crypto OK)"
  else
    fail "node present but cannot execute a trivial script"
  fi
  command -v npm >/dev/null 2>&1 && pass "npm present alongside node" || fail "npm missing alongside node"
  echo ""
}

check_python() {
  local target_arches="$1"

  # Python
  echo "--- Python ---"
  check_version "/usr/local/bin/python${PYTHON_MAJOR_MINOR} --version" "${PYTHON_VERSION}" "python${PYTHON_MAJOR_MINOR}"
  local py_sysver
  py_sysver="$(/usr/local/bin/python${PYTHON_MAJOR_MINOR} -c "import sys; print(sys.version)" 2>/dev/null | head -1 || true)"
  if echo "${py_sysver}" | grep -q "${PYTHON_VERSION}"; then
    pass "python${PYTHON_MAJOR_MINOR} sys.version: ${py_sysver}"
  else
    fail "python${PYTHON_MAJOR_MINOR} sys.version: ${py_sysver:-MISSING} (expected ${PYTHON_VERSION})"
  fi
  # Stdlib extension-module battery (smoke-depth R3): this is a FROM-SOURCE
  # CPython — silently dropping _ssl/_sqlite3/_lzma when a dev header is
  # missing at configure time is the textbook failure, and no ssl means every
  # HTTPS/pip call dies at runtime. Exercise, don't just import.
  if /usr/local/bin/python${PYTHON_MAJOR_MINOR} -c "
import ssl, sqlite3, lzma, bz2, zlib, hashlib, ctypes, decimal, uuid
ssl.create_default_context()
c = sqlite3.connect(':memory:'); c.execute('create table t(x int)')
c.execute('insert into t values(1)')
assert c.execute('select x from t').fetchone() == (1,)
assert lzma.decompress(lzma.compress(b'k'*100)) == b'k'*100
assert bz2.decompress(bz2.compress(b'k'*100)) == b'k'*100
assert hashlib.sha256(b'x').hexdigest().startswith('2d711642')
" 2>/dev/null; then
    pass "python stdlib battery (ssl/sqlite3/lzma/bz2/zlib/hashlib/ctypes) OK"
  else
    fail "python stdlib battery FAILED — from-source CPython is missing/mis-built an extension module (ssl? sqlite3? lzma?)"
  fi
  local host_arch_py
  host_arch_py="$(smoke_host_arch)"
  for cross_arch in $(smoke_arch_words "${target_arches}"); do
    local py_root="/opt/python-cross/${cross_arch}"
    # A staged dir that is missing its .pc or binary is a broken staging —
    # fail explicitly instead of only pass-ing on the happy path.
    # And a WHOLLY ABSENT staging dir for a requested foreign arch is the
    # worst case, not a skip (smoke-depth R16a: the old `if [ -d ]` wrapper
    # ran ZERO checks then).
    if [ ! -d "${py_root}" ]; then
      if [ "${cross_arch}" != "${host_arch_py}" ]; then
        fail "cross-Python staging entirely ABSENT for ${cross_arch} (expected ${py_root})"
      fi
      continue
    fi
    if [ -d "${py_root}" ]; then
      if [ -f "${py_root}/usr/local/lib/pkgconfig/python-${PYTHON_MAJOR_MINOR}.pc" ]; then
        pass "Python ${PYTHON_MAJOR_MINOR} pkg-config exists for ${cross_arch}"
      else
        fail "Python ${PYTHON_MAJOR_MINOR} pkg-config missing for ${cross_arch} (expected ${py_root}/usr/local/lib/pkgconfig/python-${PYTHON_MAJOR_MINOR}.pc)"
      fi
      if [ -f "${py_root}/usr/local/bin/python${PYTHON_MAJOR_MINOR}" ]; then
        pass "Python ${PYTHON_MAJOR_MINOR} binary staged for ${cross_arch}"
      else
        fail "Python ${PYTHON_MAJOR_MINOR} binary not staged for ${cross_arch} (expected ${py_root}/usr/local/bin/python${PYTHON_MAJOR_MINOR})"
      fi
    fi
  done
  echo ""
}

run_cross_targets() {
  local target_arches="$1"
  local host_arch="$2"

  # Cross-compilers for each target
  for arch in $(smoke_arch_words "${target_arches}"); do
    [ "${arch}" = "${host_arch}" ] && continue
    smoke_target "${arch}"
  done
}

main() {
  local target_arches="${1:-amd64,arm64,riscv64}"
  local host_arch

  host_arch="$(smoke_host_arch)"
  print_smoke_header "${host_arch}" "${target_arches}"
  check_host_gcc
  check_llvm_clang
  check_rust "${target_arches}"
  check_node
  check_python "${target_arches}"
  run_cross_targets "${target_arches}" "${host_arch}"

  smoke_summary
}

main "$@"
