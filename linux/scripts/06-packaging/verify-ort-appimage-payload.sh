#!/usr/bin/env bash
# Match the finished AppImage's GPU ORT files and original texts to one wheel.
set -euo pipefail
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${script_dir}/../01-core/platform.sh"
source "${script_dir}/ort-runtime-bundle.sh"
if [ "$#" -ne 5 ]; then
  printf 'Usage: %s APPIMAGE ARCH LIB_DIR NOTICE_DIR nvidia|amd\n' "$0" >&2
  exit 2
fi
image="$(realpath -e -- "$1")"
target="$(arch_normalize "$2")"
host="$(arch_normalize "$(uname -m)")"
lib_dir="$3"
notice_dir="$4"
variant="$5"
for path in "$lib_dir" "$notice_dir"; do
  case "$path" in
    ''|/*|*/|*//*|*\\*|*'*'*|*'?'*|*'['*|*']'*|*':'*|*[[:cntrl:]]*) printf 'Invalid package path: %s\n' "$path" >&2; exit 2 ;;
  esac
  IFS=/ read -r -a parts <<< "$path"
  for part in "${parts[@]}"; do
    case "$part" in .|..) printf 'Invalid package path: %s\n' "$path" >&2; exit 2 ;; esac
  done
done
case "$target" in amd64|arm64) ;; *) printf 'Unsupported AppImage architecture: %s\n' "$2" >&2; exit 2 ;; esac
if [ "$target" != "$host" ]; then
  printf 'AppImage verification requires a native %s host, got %s\n' "$target" "$host" >&2
  exit 1
fi
case "$variant" in
  nvidia) provider=libonnxruntime_providers_cuda.so; kind=cuda ;;
  amd) [ "$target" = amd64 ] || { echo 'AMD GPU AppImages require Linux x64' >&2; exit 2; }; provider=libonnxruntime_providers_migraphx.so; kind=migraphx ;;
  *) printf 'Invalid GPU variant: %s\n' "$variant" >&2; exit 2 ;;
esac
[ -x "$image" ] || { printf 'AppImage is not executable: %s\n' "$image" >&2; exit 1; }
work="$(mktemp -d)"
trap 'rm -rf -- "$work"' EXIT
(
  cd "$work"
  "$image" --appimage-extract > /dev/null
  root="$(realpath -e squashfs-root)"
  ort_assert_no_bundled_host_runtime "$root" "$kind"
  for path in "$lib_dir" "$notice_dir"; do
    resolved="$(realpath -e "${root}/${path}")"
    case "$resolved/" in "$root/"*) ;; *) echo 'AppImage path escapes its extracted root' >&2; exit 1 ;; esac
  done
  lib="${root}/${lib_dir}"
  for name in libonnxruntime.so.1 libonnxruntime_providers_shared.so "$provider"; do
    [ -f "${lib}/${name}" ] || { printf 'AppImage is missing %s\n' "$name" >&2; exit 1; }
  done
  libraries=()
  shopt -s nullglob
  for path in "$lib"/libonnxruntime*.so*; do
    [ -f "$path" ] || continue
    resolved="$(realpath -e "$path")"
    case "$resolved" in "$root/"*) ;; *) echo 'AppImage library escapes its extracted root' >&2; exit 1 ;; esac
    name="$(basename "$path")"
    case "$name" in
      libonnxruntime_providers_*)
        [ ! -L "$path" ] || { printf 'AppImage provider is a symlink: %s\n' "$name" >&2; exit 1; } ;;
      libonnxruntime.so*)
        [[ "$(basename "$resolved")" =~ ^libonnxruntime\.so(\.[0-9]+)*$ ]] || {
          printf 'AppImage core aliases a different component: %s\n' "$name" >&2; exit 1;
        } ;;
    esac
    libraries+=(--library "$path")
  done
  mkdir proven
  python3 "${script_dir}/stage-ort-wheel-licenses.py" --require-unstripped \
    --wheel-dir "${ORT_CHAIN_WHEEL_DIR:-/opt/onnxruntime-wheels}" --destination proven \
    --strip "${STRIP:-strip}" "${libraries[@]}"
  for name in LICENSE ThirdPartyNotices.txt; do
    notice="${root}/${notice_dir}/${name}"
    [ -f "$notice" ] && [ ! -L "$notice" ] || { printf 'Missing or symlinked AppImage notice: %s\n' "$name" >&2; exit 1; }
    cmp "$notice" "proven/licenses/onnxruntime/${name}"
  done
  printf 'PASS: finished AppImage ORT payload and notices match one GPU wheel\n'
)
