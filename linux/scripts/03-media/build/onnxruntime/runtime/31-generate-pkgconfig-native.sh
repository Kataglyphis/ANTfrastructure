#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/../build/lib/common.sh"

parse_common_args "$@"

generate_pkgconfig() {
  local pc_version pc_dir pc_path libdir includedir libs_line onnx_lib

  pc_version="$(pc_numeric_version_from_ort_version "${ORT_VERSION}")"

  pc_dir="${ORT_PKGCONFIG_DIR:-${NATIVE_CPU_OUTPUT_DIR}/runtime/lib/pkgconfig}"
  pc_path="${pc_dir}/libonnxruntime.pc"

  mkdir -p "${pc_dir}"

  libdir="${NATIVE_CPU_OUTPUT_DIR}/lib"
  includedir="${NATIVE_CPU_OUTPUT_DIR}/include"

  if [ ! -d "${libdir}" ]; then
    warn "ONNX Runtime lib directory not found at ${libdir}"
  fi
  if [ ! -d "${includedir}" ]; then
    warn "ONNX Runtime include directory not found at ${includedir}"
  fi

  # Some ONNX Runtime builds only install a versioned SONAME file
  # (e.g. libonnxruntime.so.1.23.2) without the linker-name symlink
  # libonnxruntime.so. In that case, -lonnxruntime fails.
  if [ -f "${libdir}/libonnxruntime.so" ]; then
    libs_line="Libs: -L\\${libdir} -lonnxruntime"
  else
    onnx_lib="$(find "${libdir}" -maxdepth 1 -type f -name 'libonnxruntime.so.*' 2>/dev/null | LC_ALL=C sort | head -n 1 || true)"
    if [ -n "${onnx_lib}" ]; then
      libs_line="Libs: -L\\${libdir} -l:$(basename "${onnx_lib}")"
      ln -sf "$(basename "${onnx_lib}")" "${libdir}/libonnxruntime.so" || true
    else
      warn "No libonnxruntime.so or libonnxruntime.so.* found in ${libdir}"
      libs_line="Libs: -L\\${libdir} -lonnxruntime"
    fi
  fi

  cat >"${pc_path}" <<EOF
prefix=${NATIVE_CPU_OUTPUT_DIR}
exec_prefix=\${prefix}
libdir=${libdir}
includedir=${includedir}

Name: libonnxruntime
Description: ONNX Runtime (native CPU build)
Version: ${pc_version}
${libs_line}
Cflags: -I\${includedir} -I\${includedir}/onnxruntime/core/session -I\${includedir}/onnxruntime/core/providers/cpu
EOF

  info "Wrote pkg-config file: ${pc_path}"
}

generate_pkgconfig

if [ -n "${ORT_SRC_DIR:-}" ] && [ -d "${ORT_SRC_DIR}" ]; then
  rm -rf "${ORT_SRC_DIR}" || true
fi
