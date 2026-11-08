#!/usr/bin/env bash
# Match the finished AppImage's GPU ORT files and original texts to one wheel; an AMD image's plugin MIGraphX EP to the image's module.
set -euo pipefail
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${script_dir}/../01-core/platform.sh"
source "${script_dir}/appimage-verification.sh"
source "${script_dir}/ort-runtime-bundle.sh"
source "${script_dir}/ort-package-proof.sh"
declare image target work
appimage_require_args "$#" 5 "$0" 'APPIMAGE ARCH LIB_DIR NOTICE_DIR nvidia|amd'
appimage_init "$1" "$2"
lib_dir="$3"
notice_dir="$4"
variant="$5"
for path in "$lib_dir" "$notice_dir"; do
  appimage_validate_path "$path" 'package path'
done
appimage_require_native "$2"
case "$variant" in
  nvidia) kind=cuda; required=(libonnxruntime.so.1 libonnxruntime_providers_shared.so libonnxruntime_providers_cuda.so) ;;
  amd) [ "$target" = amd64 ] || { echo 'AMD GPU AppImages require Linux x64' >&2; exit 2; }; kind=migraphx; required=(libonnxruntime.so.1 "${ORT_AMDGPU_EP_MODULE}") ;;
  *) printf 'Invalid GPU variant: %s\n' "$variant" >&2; exit 2 ;;
esac
appimage_create_work
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
  libraries=()
  ort_package_collect_libraries "$root" "$lib" libraries "${required[@]}"
  # The plugin is no wheel's: the collector's libonnxruntime* glob leaves it out, and the image's module is its proof.
  [ "$kind" != migraphx ] || ort_assert_plugin_module "${lib}/${ORT_AMDGPU_EP_MODULE}"
  mkdir proven
  python3 "${script_dir}/stage-ort-wheel-licenses.py" --require-unstripped \
    --wheel-dir "${ORT_CHAIN_WHEEL_DIR:-/opt/onnxruntime-wheels}" --destination proven \
    --strip "${STRIP:-strip}" "${libraries[@]}"
  ort_package_verify_notices "$root" "${root}/${notice_dir}" proven/licenses/onnxruntime
  printf 'PASS: finished AppImage ORT payload and notices match one GPU wheel (%s)\n' "$kind"
)
