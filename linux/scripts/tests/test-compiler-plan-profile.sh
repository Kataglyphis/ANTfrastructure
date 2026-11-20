#!/usr/bin/env bash
# Synthetic source files and Git/manager doubles prove planner refusals, not real provenance, builds or cache reuse.
set -euo pipefail
python3 "$(dirname "${BASH_SOURCE[0]}")/compiler_plan_profile_tests.py"
