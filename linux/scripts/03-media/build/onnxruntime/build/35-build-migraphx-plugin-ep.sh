#!/usr/bin/env bash
# AMD's out-of-tree ONNX Runtime plugin EP for MIGraphX, built against the chain's ORT and the image's MIGraphX: docs/linux-accelerator-images.md#amds-plugin-migraphx-ep
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

MGXEP_OUTPUT_DIR="${MGXEP_OUTPUT_DIR:-/usr/local/lib/onnxruntime-ep-amdgpu}"
MGXEP_ORT_DIR="${MGXEP_ORT_DIR:-/usr/local/lib/onnxruntime-gpu}"
MGXEP_WORK_DIR="${MGXEP_WORK_DIR:-/tmp/onnxruntime-ep-amdgpu}"
# Declared under if(USE_DML), which stays OFF; a seed for them would pin bytes the build never reads.
MGXEP_INACTIVE_SEEDS="${MGXEP_INACTIVE_SEEDS:-eigen d3dx12 boost}"

# name|VERSION key|SHA256 key|URL with {0} for the version: one row per FetchContent_Declare, URL exactly as upstream declares it.
mgxep_seed_table() {
  cat <<'TABLE'
fmt|ORT_AMDGPU_EP_FMT_VERSION|ORT_AMDGPU_EP_FMT_SHA256|https://github.com/fmtlib/fmt/releases/download/{0}/fmt-{0}.zip
gsl|ORT_AMDGPU_EP_GSL_VERSION|ORT_AMDGPU_EP_GSL_SHA256|https://github.com/microsoft/GSL/archive/refs/tags/v{0}.zip
json|ORT_AMDGPU_EP_JSON_VERSION|ORT_AMDGPU_EP_JSON_SHA256|https://github.com/nlohmann/json/releases/download/v{0}/json.tar.xz
zlib|ORT_AMDGPU_EP_ZLIB_VERSION|ORT_AMDGPU_EP_ZLIB_SHA256|https://github.com/madler/zlib/releases/download/v{0}/zlib-{0}.tar.xz
protobuf|ORT_AMDGPU_EP_PROTOBUF_VERSION|ORT_AMDGPU_EP_PROTOBUF_SHA256|https://github.com/protocolbuffers/protobuf/archive/refs/tags/v{0}.zip
onnx|ORT_AMDGPU_EP_ONNX_VERSION|ORT_AMDGPU_EP_ONNX_SHA256|https://github.com/onnx/onnx/archive/refs/tags/v{0}.zip
flatbuffers|ORT_AMDGPU_EP_FLATBUFFERS_VERSION|ORT_AMDGPU_EP_FLATBUFFERS_SHA256|https://github.com/google/flatbuffers/archive/refs/tags/v{0}.zip
range-v3|ORT_AMDGPU_EP_RANGE_V3_VERSION|ORT_AMDGPU_EP_RANGE_V3_SHA256|https://github.com/ericniebler/range-v3/archive/refs/tags/{0}.zip
absl|ORT_AMDGPU_EP_ABSEIL_VERSION|ORT_AMDGPU_EP_ABSEIL_SHA256|https://github.com/abseil/abseil-cpp/archive/refs/tags/{0}.tar.gz
TABLE
}

mgxep_source_url() { printf 'https://github.com/onnxruntime/onnxruntime-ep-amdgpu/archive/%s.tar.gz' "$1"; }

# <key>: the pin's value, refused when empty or not a plain token, since an empty sha256 would mean "no check" downstream.
mgxep_pin() {
  local key="$1" value="${!1:-}"
  case "${value}" in
    '') printf 'ERROR: %s is not set (stale versions.env?); refusing to fetch unpinned\n' "${key}" >&2; return 1 ;;
    *[!A-Za-z0-9._+-]*) printf 'ERROR: %s=%s is not a plain version token\n' "${key}" "${value}" >&2; return 1 ;;
  esac
  printf '%s' "${value}"
}

# <name> <version key> <sha key> <url format>: "name url sha256", every pin checked.
mgxep_seed_spec() {
  local name="$1" version sha
  version="$(mgxep_pin "$2")" || return 1
  sha="$(mgxep_pin "$3")" || return 1
  [[ "${sha}" =~ ^[0-9a-f]{64}$ ]] || { printf 'ERROR: %s=%s is not a 64-hex sha256\n' "$3" "${sha}" >&2; return 1; }
  printf '%s %s %s\n' "${name}" "${4//\{0\}/${version}}" "${sha}"
}

# "name url" per FetchContent_Declare of a CMake file, lower-cased name, git:<repo> for GIT_REPOSITORY (as the Windows lane reads it).
mgxep_declared_urls() {
  tr '\n' ' ' < "$1" | grep -oE 'FetchContent_Declare\([[:space:]]*[A-Za-z0-9_.+-]+[^)]*' \
    | sed -E 's/FetchContent_Declare\([[:space:]]*([A-Za-z0-9_.+-]+).*[[:space:]](URL|GIT_REPOSITORY)[[:space:]]+"?([^[:space:]")]+).*/\1 \2 \3/' \
    | awk '$2 == "URL" {print tolower($1), $3} $2 == "GIT_REPOSITORY" {print tolower($1), "git:" $3}'
}

# <declared file> <seeded file> <inactive names>: every active declaration has a seed for the SAME URL, or the build would download unpinned.
mgxep_assert_seeded() {
  local declared="$1" seeded="$2" inactive=" $3 " name url seed bad=""
  [ -s "${declared}" ] || { printf 'ERROR: no FetchContent_Declare found; the upstream layout moved and this gate would check nothing\n' >&2; return 1; }
  # IFS=' ': the media scripts run under IFS=$'\n\t', where a plain read would put the whole line into name.
  while IFS=' ' read -r name url; do
    case "${inactive}" in *" ${name} "*) continue ;; esac
    seed="$(awk -v n="${name}" '$1 == n {print $2}' "${seeded}")"
    if [ -z "${seed}" ]; then bad="${bad}; ${name} (${url}) has no hash-pinned seed"
    elif [ "${seed}" != "${url}" ]; then bad="${bad}; ${name} is declared as ${url} but the seed pins ${seed}"; fi
  done < "${declared}"
  [ -z "${bad}" ] || { printf 'ERROR: FetchContent would download unpinned%s\n' "${bad}" >&2; return 1; }
}

# <archive> <dir>: the archive's single top-level directory, extracted into <dir>.
mgxep_extract() {
  local archive="$1" dir="$2" top
  rm -rf "${dir}"; mkdir -p "${dir}.x"
  case "${archive}" in
    *.zip) unzip -q "${archive}" -d "${dir}.x" ;;
    *) tar -xf "${archive}" -C "${dir}.x" ;;
  esac
  top="$(find "${dir}.x" -mindepth 1 -maxdepth 1 | head -n 1)"
  [ -n "${top}" ] && [ "$(find "${dir}.x" -mindepth 1 -maxdepth 1 | wc -l)" -eq 1 ] || { printf 'ERROR: %s does not hold one top-level directory\n' "${archive}" >&2; return 1; }
  mv "${top}" "${dir}"; rmdir "${dir}.x"
}

# <name> <url> <sha256> <work dir>: the verified archive extracted under <work>/seeds/<name>; prints that directory.
mgxep_fetch_seed() {
  local name="$1" url="$2" sha="$3" work="$4" archive
  # On its own line: `local` expands every word before it assigns, so ${url##*/} above would read the caller's url.
  archive="${work}/dl/${url##*/}"
  mkdir -p "${work}/dl" "${work}/seeds"
  download_verified_file "${url}" "${sha}" "${archive}" || return 1
  mgxep_extract "${archive}" "${work}/seeds/${name}" || return 1
  printf '%s' "${work}/seeds/${name}"
}

# ORT's install ships no CMake package; the EP's find_package(onnxruntime) gets an imported target over the chain's library.
mgxep_ort_prefix() {
  local ort="$1" dir="$2" so inc
  so="$(find "${ort}/lib" -maxdepth 1 -name 'libonnxruntime.so.[0-9]*' -type f | sort -V | tail -n 1)"
  [ -n "${so}" ] || { printf 'ERROR: no libonnxruntime.so.N under %s/lib\n' "${ort}" >&2; return 1; }
  inc="${ort}/include"; [ -f "${inc}/onnxruntime_c_api.h" ] || inc="$(dirname "$(find "${ort}/include" -name onnxruntime_c_api.h | head -n 1)")"
  [ -f "${inc}/onnxruntime_c_api.h" ] || { printf 'ERROR: no onnxruntime_c_api.h under %s/include\n' "${ort}" >&2; return 1; }
  mkdir -p "${dir}/lib/cmake/onnxruntime"
  ln -sfn "${ort}/include" "${dir}/include"; ln -sf "${so}" "${dir}/lib/$(basename "${so}")"; ln -sf "${so}" "${dir}/lib/libonnxruntime.so.1"
  cat > "${dir}/lib/cmake/onnxruntime/onnxruntimeConfig.cmake" <<EOF
if(NOT TARGET onnxruntime::onnxruntime)
    add_library(onnxruntime::onnxruntime SHARED IMPORTED)
    set_target_properties(onnxruntime::onnxruntime PROPERTIES IMPORTED_LOCATION "${so}" INTERFACE_INCLUDE_DIRECTORIES "${inc}")
endif()
EOF
  printf '%s' "${dir}"
}

# <seed name>: CMake's FETCHCONTENT_SOURCE_DIR_<NAME> key, upper-cased with the dash kept (range-v3 -> RANGE-V3).
mgxep_seed_define() { printf 'FETCHCONTENT_SOURCE_DIR_%s' "$(printf '%s' "$1" | tr '[:lower:]' '[:upper:]')"; }

# <so>: the exports ORT's plugin loader calls and a closure with no unresolved library.
mgxep_verify_library() {
  local so="$1" rc=0 missing
  [ -f "${so}" ] || { printf 'ERROR: %s is missing\n' "${so}" >&2; return 1; }
  # The EP's version script tags its exports (CreateEpFactories@@VERS_1.0), so the suffix is optional here.
  for sym in CreateEpFactories ReleaseEpFactory; do
    readelf --dyn-syms -W "${so}" 2>/dev/null | grep -qE " ${sym}(@@[A-Za-z0-9_.]+)?$" || { printf 'ERROR: %s does not export %s\n' "${so}" "${sym}" >&2; rc=1; }
  done
  missing="$(ldd "${so}" 2>/dev/null | awk '$2 == "=>" && $3 == "not" {print $1}' | tr '\n' ' ')"
  [ -z "${missing}" ] || { printf 'ERROR: %s cannot resolve: %s\n' "${so}" "${missing}" >&2; rc=1; }
  return "${rc}"
}

mgxep_build() {
  # The empty tree keeps the media merge's COPY --from=onnxruntime valid on the chains that do not build it.
  if [ "${ENABLE_AMD:-false}" != "true" ]; then mkdir -p "${MGXEP_OUTPUT_DIR}"; echo "Skipping the MIGraphX plugin EP (ENABLE_AMD=${ENABLE_AMD:-false})"; return 0; fi
  # shellcheck source=lib/common.sh
  source "${SCRIPT_DIR}/lib/common.sh"
  source_build_acceleration_helpers
  detect_jobs
  local core="/opt/scripts/core"; [ -d "${core}" ] || core="${SCRIPT_DIR}/../../../../01-core"
  # shellcheck source=../../../../01-core/load-versions-env.sh
  source "${core}/load-versions-env.sh"; load_versions_env "${core}/versions.env"
  # shellcheck source=../../../../01-core/cmake-cache-linker.sh
  source "${core}/cmake-cache-linker.sh"
  command -v download_verified_file >/dev/null 2>&1 || source "${core}/downloads.sh"
  local work="${MGXEP_WORK_DIR}" commit sha src seeded declared name url seed dir mgx rocm ort_prefix python
  rm -rf "${work}"; mkdir -p "${work}"
  commit="$(mgxep_pin ORT_AMDGPU_EP_COMMIT)"; sha="$(mgxep_pin ORT_AMDGPU_EP_SOURCE_SHA256)"
  [[ "${commit}" =~ ^[0-9a-f]{40}$ ]] || err "ORT_AMDGPU_EP_COMMIT=${commit} is not a 40-hex commit"
  src="$(mgxep_fetch_seed onnxruntime-ep-amdgpu "$(mgxep_source_url "${commit}")" "${sha}" "${work}")"
  declared="${work}/declared.txt"; seeded="${work}/seeded.txt"
  mgxep_declared_urls "${src}/src/CMakeLists.txt" > "${declared}"
  : > "${seeded}"
  local -a defines=()
  while IFS='|' read -r name vkey skey fmt; do
    IFS=' ' read -r _ url sha < <(mgxep_seed_spec "${name}" "${vkey}" "${skey}" "${fmt}")
    # absl is protobuf's own fetch, not a declaration of the EP; protobuf_FORCE_FETCH_DEPENDENCIES points it at the seed.
    [ "${name}" = absl ] || printf '%s %s\n' "${name}" "${url}" >> "${seeded}"
    dir="$(mgxep_fetch_seed "${name}" "${url}" "${sha}" "${work}")"
    defines+=("-D$(mgxep_seed_define "${name}"):PATH=${dir}")
  done < <(mgxep_seed_table)
  mgxep_assert_seeded "${declared}" "${seeded}" "${MGXEP_INACTIVE_SEEDS}"
  mgx="$(find "${MIGRAPHX_HOME:-/opt/rocm}" -maxdepth 5 -path '*/lib/cmake/migraphx' -type d 2>/dev/null | sort | tail -n 1 || true)"
  [ -f "${mgx}/migraphx-config.cmake" ] || err "no migraphx-config.cmake under ${MIGRAPHX_HOME:-/opt/rocm}"
  mgx="${mgx%/lib/cmake/migraphx}"
  rocm="$(find "${MIGRAPHX_HOME:-/opt/rocm}" -maxdepth 5 -path '*/lib/cmake/hip' -type d 2>/dev/null | sort | tail -n 1 || true)"
  rocm="${rocm%/lib/cmake/hip}"
  ort_prefix="$(mgxep_ort_prefix "${MGXEP_ORT_DIR}" "${work}/ort")"
  setup_host_python_environment; python="${HOST_PYTHON_BIN}"
  local -a cmake_args=(
    -S "${src}" -B "${work}/build" -G Ninja -DCMAKE_BUILD_TYPE=Release
    -DUSE_MIGRAPHX=ON -DUSE_AMDGPU=OFF -DUSE_DML=OFF -DUSE_HIP=OFF
    "-DCMAKE_PREFIX_PATH=${mgx};${rocm:-/opt/rocm}" "-Donnxruntime_DIR=${ort_prefix}/lib/cmake/onnxruntime"
    "-DPython3_EXECUTABLE=${python}" "-DPython_EXECUTABLE=${python}"
    -Dprotobuf_FORCE_FETCH_DEPENDENCIES=ON -Dprotobuf_WITH_ZLIB=OFF
    -DFETCHCONTENT_FULLY_DISCONNECTED=ON -DCMAKE_POLICY_DEFAULT_CMP0170=NEW -DCMAKE_POLICY_VERSION_MINIMUM=3.5
  )
  append_cmake_cache_linker_args cmake_args
  info ">>> MIGraphX plugin EP ${commit:0:12}: ${#defines[@]} pinned seeds, ${JOBS} jobs, MIGraphX at ${mgx}"
  CXXFLAGS="${CXXFLAGS:-} -D__HIP_PLATFORM_AMD__=1" cmake "${cmake_args[@]}" "${defines[@]}"
  cmake_assert_compiler_cache_pin "${work}/build" "${CMAKE_COMPILER_CACHE_PIN:-}"
  cmake --build "${work}/build" --parallel "${JOBS}"
  local so
  so="$(find "${work}/build" -name 'libmigraphx-ep.so' -type f | head -n 1)"
  [ -n "${so}" ] || err "the build produced no libmigraphx-ep.so"
  rm -rf "${MGXEP_OUTPUT_DIR}"; mkdir -p "${MGXEP_OUTPUT_DIR}/lib" "${MGXEP_OUTPUT_DIR}/licenses/onnxruntime-ep-amdgpu"
  install -m 0644 "${so}" "${MGXEP_OUTPUT_DIR}/lib/libmigraphx-ep.so"
  cp -a "${src}/LICENSE" "${MGXEP_OUTPUT_DIR}/licenses/onnxruntime-ep-amdgpu/"; [ ! -d "${src}/LICENSES" ] || cp -a "${src}/LICENSES" "${MGXEP_OUTPUT_DIR}/licenses/onnxruntime-ep-amdgpu/"
  # Everything linked into the module ships its text: the Linux twin of the Windows lane's Save-MigraphxLicense.
  for dir in "${work}"/seeds/*/; do
    name="$(basename "${dir}")"; [ "${name}" != onnxruntime-ep-amdgpu ] || continue
    mkdir -p "${MGXEP_OUTPUT_DIR}/licenses/${name}"
    find "${dir}" -maxdepth 1 -iname 'LICENSE*' -type f -exec cp -a {} "${MGXEP_OUTPUT_DIR}/licenses/${name}/" \;
  done
  printf 'onnxruntime-ep-amdgpu %s\nsource-sha256 %s\n' "${commit}" "${sha}" > "${MGXEP_OUTPUT_DIR}/provenance.txt"
  mgxep_verify_library "${MGXEP_OUTPUT_DIR}/lib/libmigraphx-ep.so"
  info "MIGraphX plugin EP installed: ${MGXEP_OUTPUT_DIR}/lib/libmigraphx-ep.so ($(stat -c %s "${MGXEP_OUTPUT_DIR}/lib/libmigraphx-ep.so") bytes)"
}

main() {
  case "${1:-build}" in
    build) mgxep_build ;;
    verify) mgxep_verify_library "${2:-${MGXEP_OUTPUT_DIR}/lib/libmigraphx-ep.so}" ;;
    *) printf 'usage: %s build|verify [so]\n' "${0##*/}" >&2; exit 2 ;;
  esac
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  main "$@"
fi
