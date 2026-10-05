#!/usr/bin/env bash
# scan-image-sbom.sh <platform> [image] — the scanner half of the SBOM. See docs/sbom.md#generating-them

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "${REPO_ROOT}"

CORE_DIR="${REPO_ROOT}/linux/scripts/01-core"

# The tag comes from versions.env, so a scan targets exactly the image CI runs; the syft pin from tool-pins.env.
# shellcheck source=01-core/load-versions-env.sh
source "${CORE_DIR}/load-versions-env.sh"
load_versions_env "${CORE_DIR}/versions.env"
load_versions_env "${CORE_DIR}/tool-pins.env"

PLATFORM="${1:?platform required, e.g. linux/amd64}"
IMAGE="${2:-${IMAGE_REGISTRY_PREFIX}:${CI_IMAGE_LINUX_TAG}}"

# `:?`, not `:-`: an empty version makes install.sh fetch the latest, unpinned scanner.
: "${SYFT_VERSION:?SYFT_VERSION is not set (tool-pins.env not found, or the key was removed from it)}"
SYFT_BIN_DIR="${SYFT_BIN_DIR:-${TMPDIR:-/tmp}}/syft-${SYFT_VERSION}"
# Upstream tags carry the leading v; `syft --version` reports the bare number.
SYFT_WANT="${SYFT_VERSION#v}"

# Empty when unreadable; `|| true` stops set -e killing the script inside the substitution, and both callers reject empty.
syft_version_of() {
  "$1" --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -n 1 || true
}

# A PATH syft only at the pinned version: cataloguer coverage and licences change between releases.
SYFT=""
if command -v syft >/dev/null 2>&1; then
  _path_syft="$(command -v syft)"
  _path_version="$(syft_version_of "${_path_syft}")"
  if [ "${_path_version}" = "${SYFT_WANT}" ]; then
    echo "== syft on PATH is ${_path_syft} (${_path_version}) — matches tool-pins.env SYFT_VERSION =="
    SYFT="${_path_syft}"
  else
    echo "== syft on PATH is ${_path_syft} (${_path_version:-version unreadable}), tool-pins.env pins ${SYFT_WANT} — ignoring it =="
  fi
fi

if [ -z "${SYFT}" ]; then
  if [ ! -x "${SYFT_BIN_DIR}/syft" ]; then
    mkdir -p "${SYFT_BIN_DIR}"
    curl -sSfL https://raw.githubusercontent.com/anchore/syft/main/install.sh \
      | sh -s -- -b "${SYFT_BIN_DIR}" "${SYFT_VERSION}"
  fi
  SYFT="${SYFT_BIN_DIR}/syft"
fi

# Check the bootstrap too: install.sh or a stale SYFT_BIN_DIR could yield another version.
SYFT_ACTUAL="$(syft_version_of "${SYFT}")"
if [ "${SYFT_ACTUAL}" != "${SYFT_WANT}" ]; then
  echo "${SYFT} reports '${SYFT_ACTUAL:-nothing}', tool-pins.env pins SYFT_VERSION=${SYFT_VERSION}." >&2
  echo "Refusing to publish an SBOM measured with a scanner that is not the pinned one." >&2
  exit 1
fi
"${SYFT}" version

# compare_sbom.py reads the OS out of this name to pick the curated section.
OS_NAME="${PLATFORM%%/*}"
ARCH="${PLATFORM##*/}"
STEM="out/sbom/scanned-${OS_NAME}-${ARCH}"
mkdir -p out/sbom

echo "== syft registry:${IMAGE} --platform ${PLATFORM} =="
"${SYFT}" "registry:${IMAGE}" \
  --platform "${PLATFORM}" \
  -o "spdx-json=${STEM}.spdx.json" \
  -o "cyclonedx-json=${STEM}.cdx.json"

# Almost nothing found means a broken reference or cataloguer regression, not a clean image.
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
