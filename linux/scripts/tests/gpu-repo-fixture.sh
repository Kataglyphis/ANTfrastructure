#!/usr/bin/env bash
# Repository drivers run against sandbox paths and fake tools, retaining real shell redirections and errexit.
source "$(dirname "${BASH_SOURCE[0]}")/test-harness.sh"
GPU_REPO_ROOT="${1:-${_T_SCRIPTS}/../..}"
GPU_REPO_RECEIPT="${2:-}"
GPU_REPO_WORK="$(mktemp -d)"
trap 'rm -rf "$GPU_REPO_WORK"' EXIT

gpu_repo_plant() {
  local sandbox="$1" component="$2" pins="$3" context="${4:-direct}"
  mkdir -p "$sandbox/core" "$sandbox/etc/apt/keyrings" "$sandbox/etc/apt/sources.list.d" "$sandbox/etc/apt/preferences.d" "$sandbox/etc/ld.so.conf.d" "$sandbox/tmp" "$sandbox/opt/rocm/core/bin" "$sandbox/opt/rocm/core/include" "$sandbox/opt/rocm/core/lib"
  python3 - "$GPU_REPO_ROOT/linux/scripts/01-core/setup-$component-repo.sh" "$sandbox/core/driver.sh" "$sandbox" "$component" "$context" <<'PY'
import re
import sys
from pathlib import Path

source, target, root, component, context = sys.argv[1:]
text=Path(source).read_text()
text=re.sub(r'/etc/|/opt/rocm|/tmp/', lambda match: root+match.group(), text)
if context == 'conditional':
    marker='if [ -n "${_cuda_keyring_sha}" ]' if component == 'cuda' else 'if [ -n "${_rocm_key_sha}" ]'
    start=text.index('download_optional_verified_file') if 'download_optional_verified_file' in text else text.index(marker)
    end=text.index('dpkg -i' if component == 'cuda' else 'gpg --dearmor', start)
    text=text[:start]+'gpu_fetch_policy() {\n'+text[start:end]+'\n}\nif gpu_fetch_policy; then status=0; else status=$?; fi\nexit "$status"\n'
Path(target).write_text(text)
PY
  cp "$GPU_REPO_ROOT/linux/scripts/01-core/downloads.sh" "$sandbox/core/downloads.sh"
  cat >> "$sandbox/core/downloads.sh" <<'BASH'
download_verified_file() {
  gpu_repo_call verified "$@"
  printf 'fetch stdout\n'; printf 'fetch stderr\n' >&2
  printf 'key payload' > "$3"
  return "$GPU_FETCH_RC"
}
download_file() {
  gpu_repo_call unverified "$@"
  printf 'fetch stdout\n'; printf 'fetch stderr\n' >&2
  printf 'key payload' > "$2"
  return "$GPU_FETCH_RC"
}
BASH
  cat > "$sandbox/core/use-fast-ubuntu-mirror.sh" <<'BASH'
printf 'mirror stdout\n'; printf 'mirror stderr\n' >&2
exit 0
BASH
  printf 'ROCM_VERSION=10.0\nMIGRAPHX_VERSION=2.15\n' > "$sandbox/core/versions.env"
  if [ "$pins" = file ]; then
    printf 'CUDA_KEYRING_DEB_SHA256_X86_64=file-x86\nCUDA_KEYRING_DEB_SHA256_SBSA=file-arm\nROCM_GPG_KEY_SHA256=file-rocm\n' >> "$sandbox/core/versions.env"
  fi
  printf '#!/bin/sh\nexit 0\n' > "$sandbox/opt/rocm/core/bin/hipcc"
  chmod +x "$sandbox/opt/rocm/core/bin/hipcc"
  mkdir -p "$sandbox/opt/rocm/extras/include/migraphx"
  printf header > "$sandbox/opt/rocm/extras/include/migraphx/migraphx.hpp"
  printf library > "$sandbox/opt/rocm/core/lib/libmigraphx_c.so.1"
  printf library > "$sandbox/opt/rocm/core/lib/librocblas.so.1"
  : > "$sandbox/trace"
  cat > "$sandbox/tools.sh" <<'BASH'
gpu_repo_call() { local argc=$(($# - 1)); printf '%s' "$1" >> "$GPU_TRACE"; shift; printf ' <%s>' "$@" >> "$GPU_TRACE"; printf ' argc=%s\n' "$argc" >> "$GPU_TRACE"; }
dpkg() {
  case "$1" in
    --print-architecture) printf '%s' "$GPU_ARCH" ;;
    -i) gpu_repo_call dpkg "$@"; printf 'install stdout\n'; printf 'install stderr\n' >&2 ;;
    *) return 2 ;;
  esac
}
uname() { printf '%s' "$GPU_UNAME"; }
apt-get() { gpu_repo_call apt "$@"; }
gpg() { gpu_repo_call gpg "$@"; cat; printf 'gpg stderr\n' >&2; }
mktemp() { gpu_repo_call mktemp "$@"; : > "$GPU_SANDBOX/key temporary"; printf '%s' "$GPU_SANDBOX/key temporary"; }
rm() {
  gpu_repo_call rm "$@"
  for file in "$@"; do
    case "$file" in */rocm.sources) [ ! -f "$file" ] || /bin/cp "$file" "$GPU_SANDBOX/rocm.sources" ;; esac
  done
  /bin/rm "$@"
}
ln() { gpu_repo_call ln "$@"; /bin/ln "$@"; }
ldconfig() { gpu_repo_call ldconfig "$@"; if [ "${1:-}" = -p ]; then printf 'libmigraphx_c.so.1 => fixture\n'; fi; }
dpkg-query() { gpu_repo_call dpkg-query "$@"; printf 'installed amdrocm-core-dev%s\n' "${GPU_INSTALLED_RELEASE}"; }
update-alternatives() { gpu_repo_call alternatives "$@"; }
BASH
}

gpu_repo_run() {
  local component="$1" pins="$2" arch="$3" target="$4" fetch_rc="$5" asan="$6" release="$7" context="${8:-direct}"
  GPU_CASE="$GPU_REPO_WORK/$component-$pins-$arch-$target-$fetch_rc-$asan-$release-$context"
  gpu_repo_plant "$GPU_CASE" "$component" "$pins" "$context"
  local x86='' arm='' rocm=''
  if [ "$pins" = env ]; then x86=env-x86; arm=env-arm; rocm=env-rocm; fi
  export GPU_STATUS=0
  env BASH_ENV="$GPU_CASE/tools.sh" GPU_TRACE="$GPU_CASE/trace" GPU_SANDBOX="$GPU_CASE" GPU_ARCH="$arch" GPU_UNAME="$([ "$arch" = arm64 ] && echo aarch64 || echo x86_64)" GPU_FETCH_RC="$fetch_rc" GPU_INSTALLED_RELEASE="$release" \
    UBUNTU_VERSION=26.04 TARGET_ARCH="$target" CUDA_KEYRING_DEB_SHA256_X86_64="$x86" CUDA_KEYRING_DEB_SHA256_SBSA="$arm" ROCM_GPG_KEY_SHA256="$rocm" ROCM_VERSION=10.0 MIGRAPHX_VERSION=2.15 ENABLE_ROCM_ASAN="$asan" \
    bash "$GPU_CASE/core/driver.sh" > "$GPU_CASE/stdout" 2> "$GPU_CASE/stderr" || GPU_STATUS=$?
}

gpu_repo_record() {
  local field
  local -a fields=()
  for field in "$@"; do fields+=("${field//"$GPU_CASE"/@ROOT@}"); done
  t_record_fixture_receipt "$GPU_REPO_RECEIPT" "${fields[@]}"
}

gpu_repo_bytes() {
  python3 - "$GPU_CASE" "$1" <<'PYCODE'
import sys
from pathlib import Path

root, name = sys.argv[1:]
path=Path(name)
print(path.read_bytes().replace(root.encode(), b'@ROOT@').hex() if path.is_file() else '<missing>', end='')
PYCODE
}
