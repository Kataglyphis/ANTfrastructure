#!/usr/bin/env bash
# Match the failed mandatory smoke's loader setup before collecting actual wrapper diagnostics.
set -euo pipefail
source /opt/scripts/packaging/llvm-loader-path.sh
declare -F publish_llvm_target_ld_path >/dev/null
publish_llvm_target_ld_path /opt/llvm-target-amd64 /etc/ld.so.conf.d/000-llvm-native.conf
exec python3 /probe.py "$@"
