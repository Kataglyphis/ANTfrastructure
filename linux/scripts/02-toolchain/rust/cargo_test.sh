#!/usr/bin/env bash
set -euo pipefail

# shellcheck source=/dev/null
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_cargo_wrapper.sh"
# shellcheck source=/dev/null
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../01-core/vulkan-env.sh"
vulkan_env_default_cpu_driver

# The log and its JUnit land here, so test counts and failures are recorded; an empty value writes neither.
results="${CARGO_TEST_RESULTS_DIR-logs/test-results}"

# Forward args to cargo test (e.g. --features <feature>)
if [ -z "${results}" ]; then
  cargo_step "Running cargo tests..." "Tests completed successfully." -- \
    cargo test --all --verbose "$@"
  exit 0
fi
mkdir -p "${results}"
info "Running cargo tests..."
# Not cargo_step: under `|| rc=$?` set -e is off, and its done line would turn cargo's failure into success.
set +e
cargo test --all --verbose "$@" 2>&1 | tee "${results}/cargo-test.txt"
rc="${PIPESTATUS[0]}"
set -e
[ "${rc}" != 0 ] || info "Tests completed successfully."
# A failed run's record matters most, so the JUnit is written before its status ends the step.
junit_rc=0
python3 "$(dirname "${BASH_SOURCE[0]}")/cargo-test-junit.py" "${results}/cargo-test.txt" "${results}/cargo-test.xml" \
  || junit_rc=$?
[ "${rc}" != 0 ] || rc="${junit_rc}"
exit "${rc}"
