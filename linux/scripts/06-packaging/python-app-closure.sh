#!/usr/bin/env bash
# python-app-closure.sh: elf-closure.sh under the name python-app-bundle.sh, CPackCommon.cmake and the consumers call it by.
set -euo pipefail
exec bash "$(dirname "${BASH_SOURCE[0]}")/elf-closure.sh" "$@"
