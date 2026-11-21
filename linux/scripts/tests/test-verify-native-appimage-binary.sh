#!/usr/bin/env bash
# The shared fixture exercises native selected-file checks without running a real AppImage runtime.
set -euo pipefail
exec bash "$(dirname "${BASH_SOURCE[0]}")/fixtures/native-appimage-verifier-suite.sh" binary
