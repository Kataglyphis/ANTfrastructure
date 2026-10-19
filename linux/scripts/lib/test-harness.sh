#!/usr/bin/env bash
# test-harness.sh: the hub's assert helpers for a consumer's bash suites, sourced; docs/shared-script-libraries.md#libtest-harnesssh
_TEST_HARNESS_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./log-bootstrap.sh
source "${_TEST_HARNESS_LIB_DIR}/log-bootstrap.sh"
# shellcheck source=../tests/test-harness.sh
source "${_TEST_HARNESS_LIB_DIR}/../tests/test-harness.sh"
