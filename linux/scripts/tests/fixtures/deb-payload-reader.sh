#!/usr/bin/env bash
# A complete selected payload must not conceal the owning dpkg transport failure.
set -euo pipefail
cat "$FAKE_DEB_TAR" || exit $?
exit "${FAKE_DEB_STATUS:-0}"
