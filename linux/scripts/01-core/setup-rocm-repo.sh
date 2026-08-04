#!/usr/bin/env bash
# setup-rocm-repo.sh - add the AMD ROCm apt repo, install the MIGraphX/ROCm
# stack, then remove the repo again so shipped images do not fetch from it.
#
# Extracted verbatim from the RUN in linux/Dockerfile.amd. Invoked via a
# BuildKit bind-mount of linux/scripts/01-core, exactly like the other core
# scripts. Reads ROCM_VERSION from the build environment (declared as an ARG
# in Dockerfile.amd, which Docker exposes as an env var to the RUN command).
set -euo pipefail

# Apply the fast Ubuntu mirror rewrite (if enabled) before any apt access, so the
# repo setup + package installs below use the configured mirror. No-op unless
# USE_FAST_UBUNTU_MIRROR is truthy. Folded in here so callers invoke a single
# script (was a separate use-fast-ubuntu-mirror.sh line in Dockerfile.amd).
_SETUP_ROCM_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
bash "${_SETUP_ROCM_DIR}/use-fast-ubuntu-mirror.sh"

apt-get update && apt-get install -y --no-install-recommends wget gpg
mkdir -p /etc/apt/keyrings
wget -q --tries=3 --waitretry=5 -O- https://repo.radeon.com/rocm/rocm.gpg.key | gpg --dearmor > /etc/apt/keyrings/rocm.gpg
# ==========================================================================
# HARDCODED amd64-ONLY: the ROCm apt line below pins `arch=amd64`, so this
# AMD/MIGraphX layer can ONLY be built for linux/amd64.  AMD publishes no
# arm64 ROCm apt packages for this repo layout; do NOT "fix" this by
# substituting ${TARGETARCH} — an arm64 build must fail loudly here rather
# than silently produce an image without the ROCm stack.
# ==========================================================================
echo "deb [arch=amd64 signed-by=/etc/apt/keyrings/rocm.gpg] https://repo.radeon.com/rocm/apt/${ROCM_VERSION} noble main" > /etc/apt/sources.list.d/rocm.list
# Preserve the original per-line echo form from Dockerfile.amd verbatim.
echo 'Package: *' > /etc/apt/preferences.d/rocm-pin
# shellcheck disable=SC2129
echo 'Pin: release o=repo.radeon.com' >> /etc/apt/preferences.d/rocm-pin
echo 'Pin-Priority: 600' >> /etc/apt/preferences.d/rocm-pin
echo '' >> /etc/apt/preferences.d/rocm-pin
echo '# Allow only rocm-related packages from the AMD repo' >> /etc/apt/preferences.d/rocm-pin
echo 'Package: migraphx* hip* rocblas* miopen* hipblaslt* rocfft* rccl* rocsparse* rocsolver* rocm* half' >> /etc/apt/preferences.d/rocm-pin
echo 'Pin: release o=repo.radeon.com' >> /etc/apt/preferences.d/rocm-pin
echo 'Pin-Priority: 1001' >> /etc/apt/preferences.d/rocm-pin
apt-get update
apt-get install -y --no-install-recommends \
    hip-dev \
    hip-runtime-amd \
    rocblas-dev \
    miopen-hip-dev \
    hipblaslt-dev \
    rocfft-dev \
    rccl-dev \
    rocsparse-dev \
    rocsolver-dev \
    rocm-device-libs \
    migraphx \
    migraphx-dev
rm -rf /var/lib/apt/lists/*
rm -f /etc/apt/sources.list.d/rocm.list /etc/apt/preferences.d/rocm-pin
echo "/opt/rocm/lib" > /etc/ld.so.conf.d/rocm.conf
ldconfig
test -x /opt/rocm/bin/hipcc || { echo "hipcc not found"; exit 1; }
test -f /opt/rocm/include/migraphx/migraphx.hpp || { echo "migraphx.hpp not found"; exit 1; }
ldconfig -p | grep -E 'librocblas|librccl|librocfft|librocsparse|libmiopen' >/dev/null || { echo "ROCm libs not in ldconfig"; exit 1; }
