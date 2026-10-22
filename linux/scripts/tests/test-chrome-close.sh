#!/usr/bin/env bash
# Real Node child exits and injected exhausted cleanup failures; no browser/CDP coverage.
set -u
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${TESTS_DIR}/test-harness.sh"
t_skip_unless "node with the built-in test runner" node -e 'require("node:test")'
t_case "Chrome cleanup reaps children, retains bounded retries and propagates failures"
t_assert_rc 0 node --test "${TESTS_DIR}/test-chrome-close.js"
t_summary
