#!/usr/bin/env bash
# Tests for the D5 free-space gate on the post-failure cache-export salvage
# (_cross_salvage_disk_ok in 01-core/cross-stage-build.sh). The salvage re-drives
# up to 15 named media targets and writes GBs of cache export for stages that get
# rebuilt anyway — at exactly the moment disk is scarce. Rationale:
# docs/build-cache-tiers.md#31-preflight-trim-d4-and-the-salvage-disk-gate-d5
set -u
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${TESTS_DIR}/test-harness.sh"
source "${TESTS_DIR}/../01-core/cross-stage-build.sh"

warn() { printf '[WARN] %s\n' "$*" >&2; }

_STUB_FREE=""
_disk_guard_free_gb() { printf '%s' "${_STUB_FREE}"; }

t_case "salvage RUNS when free space is ample"
_STUB_FREE=100
t_assert_ok _cross_salvage_disk_ok /tmp

t_case "salvage is SKIPPED below the threshold, with a warning that says so"
_STUB_FREE=10
t_assert_fails _cross_salvage_disk_ok /tmp
t_assert_contains "$(_cross_salvage_disk_ok /tmp 2>&1 || true)" "SKIPPING the local cache-export salvage"
t_assert_contains "$(_cross_salvage_disk_ok /tmp 2>&1 || true)" "10G free (< 40G)"

t_case "the threshold follows CROSS_DISK_GUARD_GB and SALVAGE_MIN_FREE_GB"
_STUB_FREE=30
CROSS_DISK_GUARD_GB=20 t_assert_ok _cross_salvage_disk_ok /tmp
CROSS_DISK_GUARD_GB=60 t_assert_fails _cross_salvage_disk_ok /tmp
SALVAGE_MIN_FREE_GB=10 CROSS_DISK_GUARD_GB=60 t_assert_ok _cross_salvage_disk_ok /tmp

t_case "SALVAGE_MIN_FREE_GB=0 restores the always-salvage behaviour"
_STUB_FREE=1
SALVAGE_MIN_FREE_GB=0 t_assert_ok _cross_salvage_disk_ok /tmp

t_case "unknown or unparsable free space keeps the old behaviour (salvage runs)"
_STUB_FREE=""
t_assert_ok _cross_salvage_disk_ok /tmp
_STUB_FREE=10
SALVAGE_MIN_FREE_GB=plenty t_assert_ok _cross_salvage_disk_ok /tmp

t_case "the gate is actually wired into the salvage branch"
# A pure helper nothing calls is the failure mode this repo has paid for.
t_assert_contains \
  "$(grep -c -e '_cross_salvage_disk_ok "\${_cache_dir}"' "${TESTS_DIR}/../01-core/cross-stage-build.sh")" "1"

t_summary
