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
# it lived in the workflow.
#
# The version comes from versions.env like the image tag above — it was a
# `SYFT_VERSION="v1.20.0"` literal here until 2026-09-09, three lines under a
# header that already claimed "pinned in ONE place". `:?` and not `:-`: a
# default here would be that literal all over again, and an empty string handed
# to install.sh means "latest", i.e. an unpinned scanner deciding what the SBOM
# we publish says we ship. Refuse instead.
: "${SYFT_VERSION:?SYFT_VERSION is not set (versions.env not found, or the key was removed from it)}"
SYFT_BIN_DIR="${SYFT_BIN_DIR:-${TMPDIR:-/tmp}}/syft-${SYFT_VERSION}"
# Upstream tags carry the leading v; `syft --version` reports the bare number.
SYFT_WANT="${SYFT_VERSION#v}"

# The version a syft binary reports, or EMPTY when it cannot be read.
#
# `|| true` is not a swallowed error, it is the return channel: this file runs
# under `set -euo pipefail`, where a binary that exits non-zero (or a grep that
# finds no version in its output) aborts the whole script from inside the
# command substitution — before the caller can print "ignoring it" and fall back
# to the pinned bootstrap. Measured: a `syft` on PATH that just exits 3 killed
# the script silently, rc=1, no message. The empty string it returns instead is
# not tolerated anywhere: the PATH branch rejects it, and the SYFT_ACTUAL check
# below exits 1 on it.
syft_version_of() {
  "$1" --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -n 1 || true
}

# A syft on PATH is used ONLY when it IS the pinned version. It used to win
# unconditionally ("a workstation run needs no download at all"), which quietly
# made the pin advisory: the package counts and licence percentages in
# docs/sbom.md were measured on 2026-08-25 with the syft that happened to be on
# PATH — 1.51.0, thirty-one minor releases past the pin — while every line
# around them says the scanner is pinned to v1.20.0. Cataloguer coverage and
# licence conclusion both change across that range, so those are numbers from a
# scanner nobody chose, and a re-run on another workstation would not reproduce
# them. Preferring the pin costs one download and buys a reproducible SBOM;
# SYFT_VERSION is the knob for deliberately scanning with a different one.
SYFT=""
if command -v syft >/dev/null 2>&1; then
  _path_syft="$(command -v syft)"
  _path_version="$(syft_version_of "${_path_syft}")"
  if [ "${_path_version}" = "${SYFT_WANT}" ]; then
    echo "== syft on PATH is ${_path_syft} (${_path_version}) — matches versions.env SYFT_VERSION =="
    SYFT="${_path_syft}"
  else
    echo "== syft on PATH is ${_path_syft} (${_path_version:-version unreadable}), versions.env pins ${SYFT_WANT} — ignoring it =="
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

# The bootstrap is checked too, not just the PATH copy: install.sh resolving the
# tag to something else, or a stale cached SYFT_BIN_DIR, would otherwise publish
# an SBOM under a version this repo never pinned.
SYFT_ACTUAL="$(syft_version_of "${SYFT}")"
if [ "${SYFT_ACTUAL}" != "${SYFT_WANT}" ]; then
  echo "${SYFT} reports '${SYFT_ACTUAL:-nothing}', versions.env pins SYFT_VERSION=${SYFT_VERSION}." >&2
  echo "Refusing to publish an SBOM measured with a scanner that is not the pinned one." >&2
  exit 1
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
