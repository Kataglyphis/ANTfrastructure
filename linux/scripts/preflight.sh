#!/usr/bin/env bash
# preflight.sh — run every FAST (no-build) verification before a cross rebuild.
#
# The base->:latest-cross rebuild takes hours under QEMU. Whole classes of error
# (see docs/cross-build-verification.md) can be caught in seconds/minutes here
# instead. Run this before kicking off build-cross-chain.sh.
#
# Each check is independent; all run even if an earlier one fails, and the script
# exits non-zero if any failed (so CI/automation sees a single verdict).
#
# Usage: linux/scripts/preflight.sh
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "${REPO_ROOT}"

GREEN='\033[0;32m'; RED='\033[0;31m'; YELLOW='\033[0;33m'; BOLD='\033[1m'; NC='\033[0m'
FAILED=()

run_check() {
  local name="$1"; shift
  printf "\n${BOLD}== %s ==${NC}\n" "${name}"
  if "$@"; then
    printf "${GREEN}✓ %s${NC}\n" "${name}"
  else
    printf "${RED}✗ %s${NC}\n" "${name}"
    FAILED+=("${name}")
  fi
}

# 1. Shell lint gate (shellcheck -S error across all scripts).
run_check "shellcheck gate"            bash linux/scripts/lint-shell.sh

# 2. Every referenced /opt/scripts path is COPY'd/mounted into its image.
run_check "script COPY coverage"       python3 linux/scripts/verify-script-copy-coverage.py

# 3. Critical-fix source integrity (incl. fix6: native-GCC system paths, bugs D/E).
run_check "critical fixes"             bash linux/scripts/verify-critical-fixes.sh

# 3b. Patch files are well-formed unified diffs AND still referenced (no orphans).
run_check "patch integrity"            bash linux/scripts/verify-patch-integrity.sh

# 3c. Dockerfile.package artifact COPY lane: artifact-source stage exists and
#     src/dst paths stay canonical (undocumented relocations fail).
run_check "artifact copy parity"       bash linux/scripts/verify-artifact-copy-parity.sh

# 4. Dockerfile ARG names/values agree with versions.env + forwarding.
run_check "ARG consistency"            bash linux/scripts/01-core/verify-arg-consistency.sh

# 5. Version snapshots / inline markers / deps table are in sync.
if [ -f docs/scripts/sync_versions.py ]; then
  run_check "version snapshot"         python3 docs/scripts/sync_versions.py --check
fi

# 6. Canonical Ubuntu mirror ARGs present across Dockerfiles.
if [ -f linux/scripts/01-core/verify-ubuntu-mirror-consistency.sh ]; then
  run_check "ubuntu mirror consistency" bash linux/scripts/01-core/verify-ubuntu-mirror-consistency.sh
fi

# 7. Runtime PATH/LD_LIBRARY_PATH/PKG_CONFIG_PATH match runtime-paths.env.
if [ -f linux/scripts/04-runtime/verify-runtime-paths.sh ]; then
  run_check "runtime path consistency"  bash linux/scripts/04-runtime/verify-runtime-paths.sh
fi

printf "\n${BOLD}=== preflight summary ===${NC}\n"
if [ "${#FAILED[@]}" -eq 0 ]; then
  printf "${GREEN}All preflight checks passed.${NC} Safe to start the cross rebuild.\n"
  exit 0
fi
printf "${RED}%d check(s) failed:${NC}\n" "${#FAILED[@]}"
printf "${YELLOW}  - %s${NC}\n" "${FAILED[@]}"
printf "Fix these before a multi-hour rebuild.\n"
exit 1
