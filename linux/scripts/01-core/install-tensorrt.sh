#!/usr/bin/env bash
# TensorRT at TENSORRT_VERSION for TENSORRT_LINUX_CUDA from NVIDIA's apt repo (or a staged local repo); any other version fails.
set -euo pipefail

# The runtime libraries plus the headers ORT builds against; the metapackages would add the 1.9 GB Windows builder resource.
trt_packages() {
  local major="$1" ver="$2" p
  for p in "libnvinfer${major}" "libnvinfer-plugin${major}" "libnvonnxparsers${major}" \
           "libnvinfer-lean${major}" "libnvinfer-dispatch${major}" "libnvinfer-vc-plugin${major}" \
           libnvinfer-dev libnvinfer-headers-dev libnvinfer-safe-headers-dev \
           libnvinfer-plugin-dev libnvinfer-headers-plugin-dev libnvonnxparsers-dev; do
    printf '%s=%s\n' "${p}" "${ver}"
  done
}

# <"pkg=version" lines wanted> <"pkg version" lines installed>: one line per package off its pin.
trt_version_mismatches() {
  local want="$1" row pkg ver
  local -A got=()
  while IFS= read -r row; do
    [ -n "${row}" ] || continue
    got["${row%% *}"]="${row#* }"
  done <<< "$2"
  while IFS='=' read -r pkg ver; do
    [ -n "${pkg}" ] || continue
    [ "${got[${pkg}]:-<none>}" = "${ver}" ] || printf '%s wants %s, has %s\n' "${pkg}" "${ver}" "${got[${pkg}]:-<none>}"
  done <<< "${want}"
}

trt_main() {
  : "${TENSORRT_VERSION:?TENSORRT_VERSION is unset}" "${TENSORRT_LINUX_CUDA:?TENSORRT_LINUX_CUDA is unset}"
  local ver="${TENSORRT_VERSION}-1+cuda${TENSORRT_LINUX_CUDA}" want key bad f
  local -a pkgs
  want="$(trt_packages "${TENSORRT_VERSION%%.*}" "${ver}")"
  if [ -f /tmp/tensorrt-local-repo.deb ]; then
    echo "TensorRT: registering the staged local repo"
    dpkg -i /tmp/tensorrt-local-repo.deb
    key="$(find /var -name 'nv-tensorrt-local-*-keyring.gpg' -print -quit 2>/dev/null || true)"
    [ -z "${key}" ] || cp "${key}" /usr/share/keyrings/
  fi
  apt-get update -qq
  mapfile -t pkgs <<< "${want}"
  if ! apt-get install -y --no-install-recommends "${pkgs[@]}"; then
    echo "ERROR: TensorRT ${ver} is not served; the repo has libnvinfer${TENSORRT_VERSION%%.*}:" >&2
    apt-cache madison "libnvinfer${TENSORRT_VERSION%%.*}" >&2 || true
    return 1
  fi
  bad="$(trt_version_mismatches "${want}" "$(dpkg-query -W -f='${Package} ${Version}\n' "${pkgs[@]%%=*}" 2>/dev/null || true)")"
  [ -z "${bad}" ] || { printf 'ERROR: TensorRT is not at %s:\n%s\n' "${ver}" "${bad}" >&2; return 1; }
  echo "TensorRT: ${ver} installed (${#pkgs[@]} packages)"
  # TensorRT's own files only: Dockerfile.nvidia puts TENSORRT_HOME/lib on LD_LIBRARY_PATH, which must not become /usr/lib/<triplet>.
  mkdir -p /usr/local/tensorrt/include /usr/local/tensorrt/lib
  while IFS= read -r f; do
    case "${f}" in
      /usr/include/*/Nv*.h) ln -sf "${f}" /usr/local/tensorrt/include/ ;;
      /usr/lib/*/lib*.so*) ln -sf "${f}" /usr/local/tensorrt/lib/ ;;
    esac
  done < <(dpkg -L "${pkgs[@]%%=*}")
  [ -e /usr/local/tensorrt/include/NvInfer.h ] && [ -e "/usr/local/tensorrt/lib/libnvinfer.so.${TENSORRT_VERSION%%.*}" ] \
    || { echo "ERROR: TENSORRT_HOME=/usr/local/tensorrt lacks NvInfer.h or libnvinfer.so.${TENSORRT_VERSION%%.*}" >&2; return 1; }
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  trt_main "$@"
fi
