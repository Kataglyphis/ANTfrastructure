#!/usr/bin/env bash
# ROCm TheRock apt repos: install the MIGraphX/ROCm stack, then remove the repos so images never fetch from them.
set -euo pipefail

# amd64-only, enforced up front so arm64 fails loudly instead of as a generic apt miss.
if [ "$(dpkg --print-architecture 2>/dev/null || uname -m)" != "amd64" ] \
   && [ "$(uname -m)" != "x86_64" ]; then
  echo "ERROR: the ROCm/MIGraphX lane is amd64-only (AMD publishes no arm64 ROCm apt packages for this repo layout)." >&2
  exit 1
fi

# Mirror rewrite before any apt access (no-op unless USE_FAST_UBUNTU_MIRROR).
_SETUP_ROCM_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
bash "${_SETUP_ROCM_DIR}/use-fast-ubuntu-mirror.sh"

apt-get update && apt-get install -y --no-install-recommends wget gpg curl ca-certificates
mkdir -p /etc/apt/keyrings
# Verified fetch: this key signs every ROCm/MIGraphX package.
# shellcheck disable=SC1091
source "${_SETUP_ROCM_DIR}/downloads.sh"
_rocm_key_sha="${ROCM_GPG_KEY_SHA256:-}"
if [ -z "${_rocm_key_sha}" ] && [ -f "${_SETUP_ROCM_DIR}/versions.env" ]; then
  _rocm_key_sha="$(sed -n 's/^ROCM_GPG_KEY_SHA256=//p' "${_SETUP_ROCM_DIR}/versions.env")"
fi
_rocm_key_tmp="$(mktemp)"
if [ -n "${_rocm_key_sha}" ]; then
  download_verified_file "https://stable.repo.amd.com/rocm/gpg/packages.gpg" "${_rocm_key_sha}" "${_rocm_key_tmp}"
else
  echo "WARNING: ROCM_GPG_KEY_SHA256 unset — fetching the ROCm apt key UNVERIFIED" >&2
  download_file "https://stable.repo.amd.com/rocm/gpg/packages.gpg" "${_rocm_key_tmp}" 3
fi
gpg --dearmor < "${_rocm_key_tmp}" > /etc/apt/keyrings/rocm.gpg
rm -f "${_rocm_key_tmp}"

# Both stanzas pin amd64 on purpose: AMD publishes no arm64 ROCm packages, so never substitute ${TARGETARCH}.
cat > /etc/apt/sources.list.d/rocm.sources <<'SOURCES'
Types: deb
URIs: https://stable.repo.amd.com/rocm/core/packages/ubuntu2604/
Suites: stable
Components: main
Architectures: amd64
Signed-By: /etc/apt/keyrings/rocm.gpg

Types: deb
URIs: https://stable.repo.amd.com/rocm/migraphx/packages/ubuntu2604/
Suites: stable
Components: main
Architectures: amd64
Signed-By: /etc/apt/keyrings/rocm.gpg
SOURCES

# The ASAN repo is off by default for its size. docs/linux-accelerator-images.md#asan-a-separate-image-never-latest-rocm
if [ "${ENABLE_ROCM_ASAN:-false}" = "true" ]; then
  cat >> /etc/apt/sources.list.d/rocm.sources <<'ASAN_SOURCES'

Types: deb
URIs: https://stable.repo.amd.com/rocm/core/packages-asan/ubuntu2604/
Suites: stable
Components: main
Architectures: amd64
Signed-By: /etc/apt/keyrings/rocm.gpg
ASAN_SOURCES
fi

# Pin: give the AMD repo priority over Ubuntu for its packages.
echo 'Package: *' > /etc/apt/preferences.d/rocm-pin
# shellcheck disable=SC2129
echo 'Pin: release o=AMD ROCm' >> /etc/apt/preferences.d/rocm-pin
echo 'Pin-Priority: 600' >> /etc/apt/preferences.d/rocm-pin
echo '' >> /etc/apt/preferences.d/rocm-pin
echo '# Allow only amdrocm-related packages from the AMD repo' >> /etc/apt/preferences.d/rocm-pin
echo 'Package: amdrocm*' >> /etc/apt/preferences.d/rocm-pin
echo 'Pin: release o=AMD ROCm' >> /etc/apt/preferences.d/rocm-pin
echo 'Pin-Priority: 1001' >> /etc/apt/preferences.d/rocm-pin
apt-get update
# Versionless amdrocm-* metapackages resolve to the repo's ROCm version.
apt-get install -y --no-install-recommends \
    amdrocm-core-dev \
    amdrocm-runtime-dev \
    amdrocm-blas-dev \
    amdrocm-dnn-dev \
    amdrocm-hipblas-common-dev \
    amdrocm-fft-dev \
    amdrocm-rccl-dev \
    amdrocm-sparse-dev \
    amdrocm-solver-dev \
    amdrocm-migraphx \
    amdrocm-migraphx-dev
# ASAN debs claim the same alternatives at the same priority, so re-point any they won, then assert.
if [ "${ENABLE_ROCM_ASAN:-false}" = "true" ]; then
  _rocm_asan_ver="${ROCM_VERSION:-$(sed -n 's/^ROCM_VERSION=//p' "${_SETUP_ROCM_DIR}/versions.env")}"
  apt-get install -y --no-install-recommends "amdrocm-asan${_rocm_asan_ver}"
  while read -r _alt_name _alt_status _alt_path; do
    case "${_alt_path}" in
      */core-asan-*) update-alternatives --set "${_alt_name}" "${_alt_path//\/core-asan-/\/core-}" >/dev/null 2>&1 || true ;;
    esac
  done < <(update-alternatives --get-selections)
  for _rocm_p in /opt/rocm/core /opt/rocm/lib /opt/rocm/bin "$(command -v hipcc || true)"; do
    [ -n "${_rocm_p}" ] && [ -e "${_rocm_p}" ] || continue
    case "$(readlink -f "${_rocm_p}")" in
      *core-asan-*)
        echo "ERROR: ${_rocm_p} resolves into the ASAN tree; the normal ROCm must own every alternative" >&2
        exit 1 ;;
    esac
  done
  echo "rocm-asan: installed beside the normal tree; the normal one still owns /opt/rocm/{core,lib,bin} and hipcc"
fi

# Keep the apt lists (a shared cache mount, not in the layer); only the repo sources go.
rm -f /etc/apt/sources.list.d/rocm.sources /etc/apt/preferences.d/rocm-pin

# TheRock installs into versioned subdirs; recreate the flat /opt/rocm/{bin,include,lib} layout.
[ -d /opt/rocm/core/bin ] && [ ! -e /opt/rocm/bin ] && ln -s core/bin /opt/rocm/bin
[ -d /opt/rocm/core/include ] && [ ! -e /opt/rocm/include ] && ln -s core/include /opt/rocm/include
[ -d /opt/rocm/core/lib ] && [ ! -e /opt/rocm/lib ] && ln -s core/lib /opt/rocm/lib

echo "/opt/rocm/lib" > /etc/ld.so.conf.d/rocm.conf
ldconfig
test -x /opt/rocm/bin/hipcc || command -v hipcc >/dev/null 2>&1 || { echo "hipcc not found"; exit 1; }
test -f /opt/rocm/include/migraphx/migraphx.hpp \
  || test -f /opt/rocm/core/include/migraphx/migraphx.hpp \
  || { echo "migraphx.hpp not found"; exit 1; }
# Math libs sit in per-GFX subdirs, so check the files rather than ldconfig's flat view.
find /opt/rocm -name 'librocblas*' -o -name 'librccl*' -o -name 'librocfft*' -o -name 'librocsparse*' 2>/dev/null | head -1 | grep -q . \
  || { echo "ROCm math libs not found under /opt/rocm"; exit 1; }
