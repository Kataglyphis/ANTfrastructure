#!/usr/bin/env bash
# Cross-build collaborators answered from STUB_CROSS and STUB_LAUNCHER, for suites that source a cross helper.
STUB_CROSS=0
STUB_LAUNCHER=""
cross_build_is_active() { if [ "${STUB_CROSS}" -eq 1 ]; then return 0; fi; return 1; }
compiler_cache_launcher() { printf '%s' "${STUB_LAUNCHER}"; }
