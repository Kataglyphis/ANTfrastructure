#!/usr/bin/env bash
# OUT [PINS [CACHE]]: hadolint from its pinned release tag, for an arch it publishes no binary for. docs/consumer-image-contract.md#shellcheck-and-hadolint
set -euo pipefail

OUT="${1:-}"
PINS="${2:-/tmp/pins}"
CACHE="${3:-/root/.cache/cabal}"
[ -n "${OUT}" ] || { printf 'usage: build-hadolint.sh OUT [PINS [CACHE]]\n' >&2; exit 2; }

die() { printf 'build-hadolint: ERROR: %s\n' "$*" >&2; exit 1; }

# shellcheck source=../01-core/load-versions-env.sh
source "${PINS}/load-versions-env.sh"
load_versions_env "${PINS}/tool-pins.env"
# shellcheck source=../01-core/downloads.sh
source "${PINS}/downloads.sh"
: "${HADOLINT_VERSION:?HADOLINT_VERSION missing from tool-pins.env}"
: "${HADOLINT_SOURCE_SHA256:?HADOLINT_SOURCE_SHA256 missing from tool-pins.env}"
: "${HADOLINT_HACKAGE_INDEX_STATE:?HADOLINT_HACKAGE_INDEX_STATE missing from tool-pins.env}"

mkdir -p "${OUT}"
case "$(uname -m)" in
  riscv64) ;;
  *) printf 'build-hadolint: %s takes the release binary; nothing to build\n' "$(uname -m)"; exit 0 ;;
esac

# Keyed by everything that decides the binary, so an unrelated tool-pins.env edit reuses it instead of hours under QEMU.
built="${CACHE}/hadolint-bin/${HADOLINT_VERSION}-${HADOLINT_SOURCE_SHA256:0:16}-${HADOLINT_HACKAGE_INDEX_STATE}/hadolint"
if [ -x "${built}" ]; then
  install -m 0755 "${built}" "${OUT}/hadolint"
  printf 'build-hadolint: reused %s; the torch stage runs it before it ships\n' "${built}"
  exit 0
fi

export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
# Ubuntu's GHC is the one hadolint's cabal file is tested with (9.10.3).
apt-get install -y -qq --no-install-recommends ghc cabal-install ca-certificates curl \
  zlib1g-dev libgmp-dev libffi-dev >/dev/null

src="$(mktemp -d)"
download_verified_file "https://github.com/hadolint/hadolint/archive/refs/tags/${HADOLINT_VERSION}.tar.gz" \
  "${HADOLINT_SOURCE_SHA256}" "${src}/hadolint.tar.gz" || die "the verified hadolint ${HADOLINT_VERSION} source download failed"
tar -xzf "${src}/hadolint.tar.gz" -C "${src}"
cd "${src}/hadolint-${HADOLINT_VERSION#v}"
# The index-state pins every dependency version, and the tag's cabal.project carries upstream's allow-newer.
cabal update -v1 --index-state="${HADOLINT_HACKAGE_INDEX_STATE}"
cabal build exe:hadolint -j"$(nproc)" --index-state="${HADOLINT_HACKAGE_INDEX_STATE}"
install -m 0755 "$(cabal list-bin exe:hadolint)" "${OUT}/hadolint"
strip "${OUT}/hadolint" 2>/dev/null || true
have="$("${OUT}/hadolint" --version)"
case "${have}" in
  *" ${HADOLINT_VERSION#v}"*) ;;
  *) die "the built hadolint reports '${have}', the pin is ${HADOLINT_VERSION}" ;;
esac
printf 'FROM scratch\nRUN apt-get install foo\n' > "${src}/Dockerfile"
if "${OUT}/hadolint" --no-color "${src}/Dockerfile" > "${src}/lint.txt"; then
  die "the built hadolint passed a Dockerfile it must flag (DL3008/DL3027)"
fi
grep -q 'DL30' "${src}/lint.txt" || die "the built hadolint did not name a DL30xx rule: $(cat "${src}/lint.txt")"
rm -rf "${src}"
install -D -m 0755 "${OUT}/hadolint" "${built}"
printf 'build-hadolint: %s for %s in %s\n' "${have}" "$(uname -m)" "${OUT}"
