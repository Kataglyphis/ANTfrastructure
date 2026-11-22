#!/usr/bin/env bash
# Real parent-image replay complements fixtures without proving a completed SDK or GPU inference.
set -euo pipefail
target="$1"
gcc_pin="$2"
llvm_pin="$3"
host_arch="$(dpkg --print-architecture)"
sha256sum "/opt/llvm-target-${target}/bin/clang" > /evidence/target-clang-before.sha256
sha256sum "/opt/llvm-target-${host_arch}/bin/clang" > /evidence/host-clang-before.sha256
python3 /opt/scripts/packaging/probe-compiler-defaults.py --llvm-version "$llvm_pin" \
  --native-llvm-prefix "/opt/llvm-target-${host_arch}" > /evidence/before-native.json
TARGET_ARCH="$target" LLVM_RELEASE="$llvm_pin" bash /candidate-materializer.sh > /evidence/materializer.log 2>&1
test -L "/opt/llvm-target-${target}"
test "$(readlink "/opt/llvm-target-${target}")" = /opt/llvm-target
sha256sum /opt/llvm-target/bin/clang > /evidence/target-clang-after.sha256
sha256sum "/opt/llvm-target-${host_arch}/bin/clang" > /evidence/host-clang-after.sha256
readelf -h /opt/llvm-target/bin/clang > /evidence/target-elf-header.txt
find /opt -maxdepth 1 -name 'llvm-target-*' -printf '%f\n' | LC_ALL=C sort > /evidence/architecture-prefixes.txt
bash /qualify.sh "$gcc_pin" "$llvm_pin" "/opt/llvm-target-${host_arch}"
