#!/usr/bin/env bash
# Cross-builds C, C++, a GStreamer link and Rust against RISCV64_SYSROOT and runs each under QEMU. See docs/riscv64-cross-test-lanes.md#the-sysroot-from-the-registry-skopeo
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/riscv64-cross.sh
source "${HERE}/../lib/riscv64-cross.sh"
riscv64_cross_env

WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT
CC_RV="${RISCV64_CROSS_BIN}/riscv64-linux-gnu-clang"
CXX_RV="${RISCV64_CROSS_BIN}/riscv64-linux-gnu-clang++"

# A host binary would run too, so each one must also say it is RISC-V (e_machine 243).
run_riscv64() {
  local bin="$1" machine
  machine="$(od -An -tu2 -j18 -N2 "${bin}" | tr -d ' ')"
  [ "${machine}" = 243 ] || { printf 'riscv64-cross-smoke: %s is e_machine %s, not RISC-V\n' "${bin}" "${machine}" >&2; return 1; }
  "${bin}"
}

printf '#include <stdio.h>\nint main(void) { puts("riscv64 C ok"); return 0; }\n' > "${WORK}/c.c"
"${CC_RV}" -O2 -o "${WORK}/c" "${WORK}/c.c"
run_riscv64 "${WORK}/c"

printf '#include <iostream>\n#include <thread>\nint main() { std::thread t([] { std::cout << "riscv64 C++ ok\\n"; }); t.join(); }\n' \
  > "${WORK}/cxx.cpp"
"${CXX_RV}" -O2 -std=c++20 -pthread -o "${WORK}/cxx" "${WORK}/cxx.cpp"
run_riscv64 "${WORK}/cxx"

printf '#include <gst/gst.h>\nint main(void) { gchar *v = gst_version_string(); g_print("riscv64 %%s ok\\n", v); g_free(v); return 0; }\n' \
  > "${WORK}/gst.c"
read -r -a GST_FLAGS <<< "$(PKG_CONFIG_LIBDIR="${RISCV64_PKG_CONFIG_LIBDIR}" PKG_CONFIG_SYSROOT_DIR="${RISCV64_SYSROOT}" \
  pkg-config --cflags --libs gstreamer-1.0)"
"${CC_RV}" -O2 -o "${WORK}/gst" "${WORK}/gst.c" "${GST_FLAGS[@]}"
run_riscv64 "${WORK}/gst"

mkdir -p "${WORK}/rs/src"
printf '[package]\nname = "rvsmoke"\nversion = "0.1.0"\nedition = "2021"\n' > "${WORK}/rs/Cargo.toml"
printf 'fn main() { println!("riscv64 Rust ok"); }\n' > "${WORK}/rs/src/main.rs"
CARGO_HOME="${WORK}/cargo-home" cargo build --quiet --release --target riscv64gc-unknown-linux-gnu \
  --manifest-path "${WORK}/rs/Cargo.toml" --target-dir "${WORK}/rs/target"
run_riscv64 "${WORK}/rs/target/riscv64gc-unknown-linux-gnu/release/rvsmoke"
