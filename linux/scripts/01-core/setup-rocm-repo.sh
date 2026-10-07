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

# The pinned release's apt arguments: the suite is rolling, and a versionless amdrocm-* name follows its newest ROCm.
rocm_packages() {
  local _p _mgx _ver
  case "$1" in
    # MIGraphX was renamed with 10.1; before that only its version names the ROCm it was built for.
    10.0) _mgx="amdrocm-migraphx" _ver="$2+rocm$1.*" ;;
    10.*) _mgx="amdrocm${1%%.*}-migraphx" _ver="$2-*" ;;
    *) echo "ERROR: no MIGraphX package name known for ROCm $1; add it to rocm_packages" >&2; return 1 ;;
  esac
  for _p in core-dev runtime-dev blas-dev dnn-dev hipblas-common-dev fft-dev rccl-dev sparse-dev solver-dev; do
    printf 'amdrocm-%s%s\n' "${_p}" "$1"
  done
  printf '%s\n' "${_mgx}=${_ver}" "${_mgx}-dev=${_ver}"
}

# Reads dpkg-query "<status> <package>" lines and prints each installed package naming a ROCm release other than $1.
rocm_foreign_releases() {
  awk -v rel="$1" '$1 == "installed" && match($2, /[0-9]+\.[0-9]+/) && substr($2, RSTART, RLENGTH) != rel { print $2 }'
}

_rocm_ver="${ROCM_VERSION:-$(sed -n 's/^ROCM_VERSION=//p' "${_SETUP_ROCM_DIR}/versions.env")}"
_migraphx_ver="${MIGRAPHX_VERSION:-$(sed -n 's/^MIGRAPHX_VERSION=//p' "${_SETUP_ROCM_DIR}/versions.env")}"
if ! [[ "${_rocm_ver}" =~ ^[0-9]+\.[0-9]+$ ]] || [ -z "${_migraphx_ver}" ]; then
  echo "ERROR: need ROCM_VERSION as X.Y and a MIGRAPHX_VERSION (env or versions.env), got '${_rocm_ver}' and '${_migraphx_ver}'" >&2
  exit 1
fi
# Resolved before any download, so an unknown release fails here and not after the repo setup.
_rocm_list="$(rocm_packages "${_rocm_ver}" "${_migraphx_ver}")"
mapfile -t _rocm_pkgs <<< "${_rocm_list}"

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
apt-get install -y --no-install-recommends "${_rocm_pkgs[@]}"
# ASAN debs claim the same alternatives at the same priority, so re-point any they won, then assert.
if [ "${ENABLE_ROCM_ASAN:-false}" = "true" ]; then
  apt-get install -y --no-install-recommends "amdrocm-asan${_rocm_ver}"
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

# One versionless dependency is enough to install a second ROCm tree beside the pinned one.
_rocm_foreign="$(dpkg-query -W -f '${db:Status-Status} ${Package}\n' 'amdrocm*' | rocm_foreign_releases "${_rocm_ver}")"
if [ -n "${_rocm_foreign}" ]; then
  echo "ERROR: ROCm ${_rocm_ver} is pinned, but these installed packages belong to another release:" >&2
  echo "${_rocm_foreign}" >&2
  exit 1
fi
echo "rocm: every installed amdrocm package belongs to ROCm ${_rocm_ver}"

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
