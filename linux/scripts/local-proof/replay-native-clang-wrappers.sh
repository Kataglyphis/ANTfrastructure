#!/usr/bin/env bash
# A candidate wrapper replay on the old compiler cannot qualify a newly rebuilt multi-target compiler or SDK.
set -euo pipefail
llvm_pin="$1"
native_prefix=/opt/llvm-target-amd64
sha256sum "${native_prefix}/bin/clang" > /evidence/native-clang-before.sha256
"${native_prefix}/bin/llvm-config" --targets-built > /evidence/original-targets-built.txt
"${native_prefix}/bin/clang" --print-targets > /evidence/original-print-targets.txt
python3 -c 'import json,os; print(json.dumps({key:os.environ.get(key) for key in ("PATH","LD_LIBRARY_PATH","LD_PRELOAD","BUILD_MODE","CROSS_TARGETS")}))' > /evidence/environment.json
for driver in clang clang++; do
    cp "/usr/local/bin/${driver}-amd64" "/evidence/original-${driver}-amd64.sh"
done
status=0
clang-amd64 --version > /evidence/original-wrapper.log 2>&1 || status=$?
printf '%s\n' "${status}" > /evidence/original-wrapper.status
test "${status}" -eq 127
grep -F 'LLVMInitializeAArch64TargetInfo' /evidence/original-wrapper.log
mkdir -p /opt/scripts/core /opt/scripts/toolchain
cp -a /candidate/linux/scripts/01-core/. /opt/scripts/core/
cp -a /candidate/linux/scripts/02-toolchain/. /opt/scripts/toolchain/
bash -lc 'source /opt/scripts/core/module-bootstrap.sh
bootstrap_script_modules /opt/scripts/toolchain /opt/scripts/core/modules.sh
source_module common.sh
source_module cross-env.sh
source_module repos.sh
source_module core.sh
source_module gcc.sh
source_module verify.sh
source_module llvm.sh
install_cross_clang_wrappers' > /evidence/candidate-install.log 2>&1
for driver in clang clang++; do
    for target in amd64 arm64 riscv64; do
        wrapper="/usr/local/bin/${driver}-${target}"
        cp "${wrapper}" "/evidence/candidate-${driver}-${target}.sh"
        "${wrapper}" --version > "/evidence/candidate-${driver}-${target}.version"
        grep -F "clang version ${llvm_pin} " "/evidence/candidate-${driver}-${target}.version"
        grep -F "exec \"${native_prefix}/bin/${driver}\"" "${wrapper}"
    done
done
clang-amd64 /inputs/native.c -o /evidence/native-c > /evidence/native-c-build.log 2>&1
clang++-amd64 /inputs/native.cc -o /evidence/native-cxx > /evidence/native-cxx-build.log 2>&1
/evidence/native-c > /evidence/native-c.result
/evidence/native-cxx > /evidence/native-cxx.result
test "$(cat /evidence/native-c.result)" = 42
test "$(cat /evidence/native-cxx.result)" = 42
readelf -h /evidence/native-c > /evidence/native-c.elf
readelf -h /evidence/native-cxx > /evidence/native-cxx.elf
for target in arm64 riscv64; do
    for driver in clang clang++; do
        status=0
        "${driver}-${target}" -x c -c /inputs/native.c -o "/evidence/${driver}-${target}.o" > "/evidence/${driver}-${target}.negative.log" 2>&1 || status=$?
        printf '%s\n' "${status}" > "/evidence/${driver}-${target}.negative.status"
        test "${status}" -eq 1
        test ! -e "/evidence/${driver}-${target}.o"
        grep -E 'No available targets|unable to create target|not a recognized processor' "/evidence/${driver}-${target}.negative.log"
    done
done
sha256sum "${native_prefix}/bin/clang" > /evidence/native-clang-after.sha256
cmp /evidence/native-clang-before.sha256 /evidence/native-clang-after.sha256
printf '%s\n' passed-old-compiler-native-wrapper-replay-only > /evidence/result.txt
