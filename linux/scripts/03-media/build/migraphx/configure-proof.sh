#!/usr/bin/env bash
# Bounded preparation and selected dependency builds do not compile the full backend or grant acceptance.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/proof-cleanup.sh"
trap 'migraphx_proof_finish "$?" /proof /hub/linux/scripts/01-core /proof /cache' EXIT
export LC_ALL=C ENABLE_AMD=true JOBS=2 BUILD_JOBS=2 MAX_JOBS=2
export SCCACHE_DIR=/cache SCCACHE_BUCKET="" SCCACHE_LOG=debug SCCACHE_ERROR_LOG=/proof/sccache-debug.log
find /opt/rocm -iname '*config.cmake' -o -iname '*-config.cmake' > /proof/sdk-cmake-configs.txt
find /opt /usr/local -maxdepth 6 -name clang++ -printf '%p -> %l\n' > /proof/compiler-paths.txt
case "${1:-configure}" in
  parsers)
    bash /hub/linux/scripts/03-media/build/migraphx/build-source-deps.sh /proof/work /abseil.tar.gz /protobuf.tar.gz > /proof/configure.log 2>&1
    ;;
  configure)
    bash /hub/linux/scripts/03-media/build/migraphx/prepare-source-build.sh /proof/work /source.tar.gz /rocm-cmake.tar.gz /msgpack.tar.gz /opt/rocm \
      > /proof/configure.log 2>&1
    ;;
  sdk)
    bash /hub/linux/scripts/03-media/build/migraphx/check-source-sdk.sh /proof/work /opt/rocm > /proof/configure.log 2>&1
    ;;
  ck)
    bash /hub/linux/scripts/03-media/build/migraphx/build-source-ck.sh /proof/work /source.tar.gz /rocm-cmake.tar.gz > /proof/configure.log 2>&1
    ;;
  ck-consumer)
    bash /hub/linux/scripts/03-media/build/migraphx/verify-source-ck.sh /proof/work /deps-prefix /ck-original-header.hpp > /proof/configure.log 2>&1
    ;;
  rocmlir-consumer)
    bash /hub/linux/scripts/03-media/build/migraphx/verify-source-rocmlir.sh /proof/work /deps-prefix /rocmlir-original-source > /proof/configure.log 2>&1
    ;;
  python-consumer)
    bash /hub/linux/scripts/03-media/build/migraphx/verify-source-python.sh /proof/work /migraphx-original-source > /proof/configure.log 2>&1
    ;;
  rocmlir-build)
    export JOBS=4 BUILD_JOBS=4 MAX_JOBS=4
    bash /hub/linux/scripts/03-media/build/migraphx/build-source-rocmlir.sh /proof/work /source.tar.gz /rocm-cmake.tar.gz /opt/rocm > /proof/configure.log 2>&1
    ;;
  rocmlir)
    bash /hub/linux/scripts/03-media/build/migraphx/prepare-source-rocmlir.sh /proof/work /source.tar.gz /rocm-cmake.tar.gz /opt/rocm > /proof/configure.log 2>&1
    ;;
  *) printf 'Unknown preparation proof mode: %s\n' "$1" >&2; exit 2 ;;
esac
