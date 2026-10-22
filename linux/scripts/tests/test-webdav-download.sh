#!/usr/bin/env bash
# CLI delegation and failure status only; WebDavClient owns the real path, HTTP and atomic-transfer tests.
set -u
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${TESTS_DIR}/test-harness.sh"
PY="${PREFLIGHT_PYTHON:-python3}"
t_case "WebDAV CLI delegates filtering and propagates failed operations"
t_assert_ok "${PY}" -B "${TESTS_DIR}/webdav_download_tests.py"
t_summary
