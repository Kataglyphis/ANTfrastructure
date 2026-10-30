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

# <label> <"pkg=version" lines> <farm dir> <header glob> <lib glob>: installs the set, refuses any version off its pin, farms headers and libs.
trt_install_set() {
  local label="$1" want="$2" farm="$3" hdr_glob="$4" lib_glob="$5" bad f major="${TENSORRT_VERSION%%.*}"
  local -a pkgs
  mapfile -t pkgs <<< "${want}"
  if ! apt-get install -y --no-install-recommends "${pkgs[@]}"; then
    echo "ERROR: TensorRT ${label} ${pkgs[0]#*=} is not served; the repo has ${pkgs[0]%%=*}:" >&2
    apt-cache madison "${pkgs[0]%%=*}" >&2 || true
    return 1
  fi
  bad="$(trt_version_mismatches "${want}" "$(dpkg-query -W -f='${Package} ${Version}\n' "${pkgs[@]%%=*}" 2>/dev/null || true)")"
  [ -z "${bad}" ] || { printf 'ERROR: TensorRT %s is not at %s:\n%s\n' "${label}" "${pkgs[0]#*=}" "${bad}" >&2; return 1; }
  echo "TensorRT ${label}: ${pkgs[0]#*=} installed (${#pkgs[@]} packages)"
  # The set's own files only: the farm goes on LD_LIBRARY_PATH (host) or is the cross consumers' TENSORRT_HOME, never /usr/lib/<triplet>.
  mkdir -p "${farm}/include" "${farm}/lib"
  while IFS= read -r f; do
    # shellcheck disable=SC2254 # the globs are the point
    case "${f}" in
      ${hdr_glob}) ln -sf "${f}" "${farm}/include/" ;;
      ${lib_glob}) ln -sf "${f}" "${farm}/lib/" ;;
    esac
  done < <(dpkg -L "${pkgs[@]%%=*}")
  [ -e "${farm}/include/NvInfer.h" ] && [ -e "${farm}/lib/libnvinfer.so.${major}" ] \
    || { echo "ERROR: ${farm} lacks NvInfer.h or libnvinfer.so.${major}" >&2; return 1; }
}

trt_main() {
  : "${TENSORRT_VERSION:?TENSORRT_VERSION is unset}" "${TENSORRT_LINUX_CUDA:?TENSORRT_LINUX_CUDA is unset}"
  local ver="${TENSORRT_VERSION}-1+cuda${TENSORRT_LINUX_CUDA}" key
  if [ -f /tmp/tensorrt-local-repo.deb ]; then
    echo "TensorRT: registering the staged local repo"
    dpkg -i /tmp/tensorrt-local-repo.deb
    key="$(find /var -name 'nv-tensorrt-local-*-keyring.gpg' -print -quit 2>/dev/null || true)"
    [ -z "${key}" ] || cp "${key}" /usr/share/keyrings/
  fi
  apt-get update -qq
  trt_install_set host "$(trt_packages "${TENSORRT_VERSION%%.*}" "${ver}")" /usr/local/tensorrt '/usr/include/*/Nv*.h' '/usr/lib/*/lib*.so*'
}

# <"pkg=version" lines>: the same twelve packages as NVIDIA names them for the sbsa cross target.
trt_cross_packages() {
  local row
  while IFS= read -r row; do
    [ -n "${row}" ] || continue
    printf '%s-cross-sbsa=%s\n' "${row%%=*}" "${row#*=}"
  done <<< "$1"
}

# The target's TensorRT (libs and headers under its multiarch dirs) in its own farm, AArch64-checked.
trt_cross_main() {
  local env="${CUDA_HOME:-/usr/local/cuda}/cross-target.env" farm f machine
  [ -f "${env}" ] || return 0
  # shellcheck disable=SC1090 # written by install-cuda-stack.sh in the previous RUN
  source "${env}"
  farm="/usr/local/tensorrt-${CUDA_CROSS_TARGET_DIR}"
  trt_install_set "cross (${CUDA_CROSS_TARGET_DIR})" \
    "$(trt_cross_packages "$(trt_packages "${TENSORRT_VERSION%%.*}" "${TENSORRT_VERSION}-1+cuda${TENSORRT_LINUX_CUDA}")")" \
    "${farm}" "/usr/include/${CUDA_CROSS_TARGET_TRIPLET}/Nv*.h" "/usr/lib/${CUDA_CROSS_TARGET_TRIPLET}/lib*.so*"
  f="${farm}/lib/libnvinfer.so.${TENSORRT_VERSION%%.*}"
  machine="$(readelf -h "${f}" 2>/dev/null | sed -n 's/^[[:space:]]*Machine:[[:space:]]*//p')"
  case "${machine}" in *AArch64*) echo "TensorRT cross: farm ${farm}, libnvinfer is AArch64" ;; *) echo "ERROR: ${f} is ${machine:-unreadable}, not AArch64" >&2; return 1 ;; esac
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  trt_main "$@"
  trt_cross_main
fi
