#!/usr/bin/env bash
# Native defaults and real architecture wrappers must pass in both ordinary and SDK-login shells.
set -euo pipefail
bash /qualify.sh "$1" "$2" "$3"
python3 /cross-probe.py --evidence /evidence --mode default --gcc-pin "$1" --llvm-pin "$2" --profile "${4:-compiler}"
bash -lc 'exec python3 /cross-probe.py --evidence /evidence --mode login --gcc-pin "$1" --llvm-pin "$2" --profile "$3"' cross-login-qualification "$1" "$2" "${4:-compiler}"
