#!/usr/bin/env bash
# scan-image-sbom.sh — the scanner half of the SBOM, as one command.
# Exactly what docs/sbom.md#generating-them documents: a `registry:` syft read
# of the PUBLISHED image (no pull, no daemon — how an amd64 runner catalogues
# the riscv64 child), the >=50-package refusal, then docs/scripts/compare_sbom.py.
# All of it was inline in .github/workflows/sbom.yml, where the output filename
# had drifted from what compare_sbom.py reads and the comparison ran nowhere.
# Usage: bash linux/scripts/scan-image-sbom.sh <platform> [image]

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "${REPO_ROOT}"

CORE_DIR="${REPO_ROOT}/linux/scripts/01-core"

# Pinned, and pinned in ONE place: the tag every lane runs comes from
# versions.env, so a scan cannot quietly target a different image than CI runs.
# shellcheck source=01-core/load-versions-env.sh
source "${CORE_DIR}/load-versions-env.sh"
load_versions_env "${CORE_DIR}/versions.env"

PLATFORM="${1:?platform required, e.g. linux/amd64}"
IMAGE="${2:-${IMAGE_REGISTRY_PREFIX}:${CI_IMAGE_LINUX_TAG}}"

# The upstream installer with an explicit version, which is what this did while
# it lived in the workflow. A syft already on PATH wins so a workstation run
# needs no download at all.
SYFT_VERSION="v1.20.0"
SYFT_BIN_DIR="${SYFT_BIN_DIR:-${TMPDIR:-/tmp}}/syft-${SYFT_VERSION}"

if command -v syft >/dev/null 2>&1; then
  SYFT="$(command -v syft)"
else
  if [ ! -x "${SYFT_BIN_DIR}/syft" ]; then
    mkdir -p "${SYFT_BIN_DIR}"
    curl -sSfL https://raw.githubusercontent.com/anchore/syft/main/install.sh \
      | sh -s -- -b "${SYFT_BIN_DIR}" "${SYFT_VERSION}"
  fi
  SYFT="${SYFT_BIN_DIR}/syft"
fi
"${SYFT}" version

# scanned-linux-amd64, not scanned-amd64: compare_sbom.py reads the OS out of
# this name to pick which curated section it is allowed to compare against.
OS_NAME="${PLATFORM%%/*}"
ARCH="${PLATFORM##*/}"
STEM="out/sbom/scanned-${OS_NAME}-${ARCH}"
mkdir -p out/sbom

echo "== syft registry:${IMAGE} --platform ${PLATFORM} =="
"${SYFT}" "registry:${IMAGE}" \
  --platform "${PLATFORM}" \
  -o "spdx-json=${STEM}.spdx.json" \
  -o "cyclonedx-json=${STEM}.cdx.json"

# A scan that finds almost nothing means a broken reference or a cataloguer
# regression, not a clean image. Fail rather than publish it.
python3 - "${STEM}.spdx.json" <<'PY'
import json
import sys

path = sys.argv[1]
with open(path, encoding="utf-8") as fh:
    n = len(json.load(fh).get("packages", []))
print("%s: %d packages catalogued" % (path, n))
if n < 50:
    raise SystemExit("only %d packages catalogued -- refusing to publish" % n)
PY

# The two-SBOM claim, checked against a real scan instead of asserted in prose.
python3 docs/scripts/compare_sbom.py "${STEM}.spdx.json"
