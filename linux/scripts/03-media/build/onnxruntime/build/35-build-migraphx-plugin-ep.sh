#!/usr/bin/env bash
# AMD's out-of-tree ONNX Runtime plugin EP for MIGraphX, built against the chain's ORT and the image's MIGraphX: docs/linux-accelerator-images.md#amds-plugin-migraphx-ep
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=plugin-ep-exports.sh
source "${SCRIPT_DIR}/plugin-ep-exports.sh"

# The ROCm root the in-tree EP build used to default; the plugin's MIGraphX and HIP CMake packages are found below it.
MIGRAPHX_HOME="${MIGRAPHX_HOME:-/opt/rocm}"
MGXEP_OUTPUT_DIR="${MGXEP_OUTPUT_DIR:-/usr/local/lib/onnxruntime-ep-amdgpu}"
# The rocm image's only ORT: its GPU EP is this plugin, so there is no ORT GPU build to link against.
MGXEP_ORT_DIR="${MGXEP_ORT_DIR:-/usr/local/lib/onnxruntime-cpu}"
MGXEP_WORK_DIR="${MGXEP_WORK_DIR:-/tmp/onnxruntime-ep-amdgpu}"
# Declared under if(USE_DML), which stays OFF; a seed for them would pin bytes the build never reads.
MGXEP_INACTIVE_SEEDS="${MGXEP_INACTIVE_SEEDS:-eigen d3dx12 boost}"

# <plugin>: that plugin's rows of plugin-ep-seeds.txt (the one table both plugin builds read), without the plugin column.
plugin_ep_seed_table() {
  awk -F'|' -v p="$1" '$1 == p { sub(/^[^|]*\|/, ""); print }' "${SCRIPT_DIR}/plugin-ep-seeds.txt"
}
mgxep_seed_table() { plugin_ep_seed_table amdgpu; }

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
  sha="$(plugin_ep_sha_pin "$3")" || return 1
  printf '%s %s %s\n' "${name}" "${4//\{0\}/${version}}" "${sha}"
}

# "name url" per FetchContent_Declare of a CMake file, lower-cased name, git:<repo> for GIT_REPOSITORY (as the Windows lane reads it).
mgxep_declared_urls() {
  tr '\n' ' ' < "$1" | grep -oE 'FetchContent_Declare\([[:space:]]*[A-Za-z0-9_.+-]+[^)]*' \
    | sed -E 's/FetchContent_Declare\([[:space:]]*([A-Za-z0-9_.+-]+).*[[:space:]](URL|GIT_REPOSITORY)[[:space:]]+"?([^[:space:]")]+).*/\1 \2 \3/' \
    | awk '$2 == "URL" {print tolower($1), $3} $2 == "GIT_REPOSITORY" {print tolower($1), "git:" $3}'
}

# <declared file> <seeded file> <inactive names>: every active declaration ("name <URL>" or "name <repository> <tag>") has a seed for the SAME source, or the build would fetch unpinned.
plugin_ep_assert_seeded() {
  local declared="$1" seeded="$2" inactive=" $3 " name source seed bad=""
  [ -s "${declared}" ] || { printf 'ERROR: no FetchContent_Declare found; the upstream layout moved and this gate would check nothing\n' >&2; return 1; }
  # IFS=' ': the media scripts run under IFS=$'\n\t', where a plain read would put the whole line into name.
  while IFS=' ' read -r name source; do
    case "${inactive}" in *" ${name} "*) continue ;; esac
    seed="$(awk -v n="${name}" '$1 == n {$1 = ""; sub(/^ /, ""); print}' "${seeded}")"
    if [ -z "${seed}" ]; then bad="${bad}; ${name} (${source}) has no hash-pinned seed"
    elif [ "${seed}" != "${source}" ]; then bad="${bad}; ${name} is declared as ${source} but the seed pins ${seed}"; fi
  done < "${declared}"
  [ -z "${bad}" ] || { printf 'ERROR: FetchContent would fetch unpinned%s\n' "${bad}" >&2; return 1; }
}
mgxep_assert_seeded() { plugin_ep_assert_seeded "$@"; }

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
  # The TensorRT plugin's find_library wants the unversioned name under ORT_HOME/lib.
  ln -sf "${so}" "${dir}/lib/libonnxruntime.so"
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

# <so>: the module exists and exports what ORT's plugin loader calls.
plugin_ep_exports_ok() {
  local so="$1" rc=0 sym
  [ -f "${so}" ] || { printf 'ERROR: %s is missing\n' "${so}" >&2; return 1; }
  for sym in CreateEpFactories ReleaseEpFactory; do
    plugin_ep_module_has_export "${so}" "${sym}" || { printf 'ERROR: %s does not export %s\n' "${so}" "${sym}" >&2; rc=1; }
  done
  return "${rc}"
}

# <so> <closure check>: the module exists, exports both entry points, and its closure passes the plugin's own check; every finding is printed, none hides another.
plugin_ep_verify_library() {
  local so="$1" rc=0
  plugin_ep_exports_ok "${so}" || { rc=$?; [ -f "${so}" ] || return "${rc}"; }
  "$2" "${so}" || rc=1
  return "${rc}"
}

# A failed inspector cannot prove a closure; the optional callback uses the target loader without initializing the plugin.
mgxep_closure_ok() {
  local report missing rc=0
  report="$("${2:-ldd}" "$1" 2>&1)" || rc=$?
  if [ "${rc}" -ne 0 ]; then
    printf 'ERROR: %s closure inspection failed (status %s)\n%s\n' "$1" "${rc}" "${report}" >&2
    return 1
  fi
  missing="$(printf '%s\n' "${report}" | awk '$2 == "=>" && $3 == "not" {print $1}' | tr '\n' ' ')"
  [ -z "${missing}" ] || { printf 'ERROR: %s cannot resolve: %s\n' "$1" "${missing}" >&2; return 1; }
}

# <so>: the exports ORT's plugin loader calls and a closure with no unresolved library.
mgxep_verify_library() { plugin_ep_verify_library "$1" mgxep_closure_ok; }

# <work> <seeded-file> <defines-array-name>: fetch every pinned seed; its own locals keep the caller's sha (the first proof image recorded absl's hash as the source's).
mgxep_seed_all() {
  local work="$1" seeded="$2" name vkey skey fmt url sha dir
  local -n _mgxep_defines="$3"
  : > "${seeded}"
  while IFS='|' read -r name vkey skey fmt _; do
    IFS=' ' read -r _ url sha < <(mgxep_seed_spec "${name}" "${vkey}" "${skey}" "${fmt}")
    # absl is protobuf's own fetch, not a declaration of the EP; protobuf_FORCE_FETCH_DEPENDENCIES points it at the seed.
    [ "${name}" = absl ] || printf '%s %s\n' "${name}" "${url}" >> "${seeded}"
    dir="$(mgxep_fetch_seed "${name}" "${url}" "${sha}" "${work}")"
    _mgxep_defines+=("-D$(mgxep_seed_define "${name}"):PATH=${dir}")
  done < <(mgxep_seed_table)
}

# <output dir> <message>: a chain that does not build this plugin leaves the empty tree the media merge COPYs.
plugin_ep_skip() { mkdir -p "$1"; echo "$2"; }


# <sha256 key>: the pin, refused unless it is 64 hex digits, since an odd value would mean "no check" downstream.
plugin_ep_sha_pin() {
  local sha
  sha="$(mgxep_pin "$1")" || return 1
  [[ "${sha}" =~ ^[0-9a-f]{64}$ ]] || { printf 'ERROR: %s=%s is not a 64-hex sha256\n' "$1" "${sha}" >&2; return 1; }
  printf '%s' "${sha}"
}

# <build dir> <module name>: the one module the build produced, or a named failure.
plugin_ep_built_module() {
  local so
  so="$(find "$1" -name "$2" -type f | head -n 1)"
  [ -n "${so}" ] || { printf 'ERROR: the build produced no %s under %s\n' "$2" "$1" >&2; return 1; }
  printf '%s' "${so}"
}

# <module> <output dir> <plugin name> <source dir> <licence file>...: a fresh output tree with the module under lib/ and the plugin's own licence texts beside it.
plugin_ep_install_module() {
  local so="$1" out="$2" name="$3" src="$4" f
  shift 4
  rm -rf "${out}"; mkdir -p "${out}/lib" "${out}/licenses/${name}"
  install -m 0644 "${so}" "${out}/lib/${so##*/}"
  for f in "$@"; do [ -e "${src}/${f}" ] && cp -a "${src}/${f}" "${out}/licenses/${name}/"; done
}

# <seed name> <url> <sha256 key> <work dir>: the plugin's pinned source tree, fetched through the mirror-first verified download.
plugin_ep_source() {
  local sha
  sha="$(plugin_ep_sha_pin "$3")" || return 1
  mgxep_fetch_seed "$1" "$2" "${sha}" "$4"
}

# <output dir> <work dir> <plugin seed name>: every seed linked into the module ships its licence text (the Linux twin of the Windows lane's Save-MigraphxLicense).
plugin_ep_seed_licenses() {
  local out="$1" dir name
  for dir in "$2"/seeds/*/; do
    name="$(basename "${dir}")"; [ "${name}" != "$3" ] || continue
    mkdir -p "${out}/licenses/${name}"
    find "${dir}" -maxdepth 1 -iname 'LICENSE*' -type f -exec cp -a {} "${out}/licenses/${name}/" \;
  done
}

# <module> <output dir> <plugin name> <source dir> <work dir> <licence file>...: the module under lib/ with the plugin's and every seed's licence texts.
plugin_ep_install() {
  plugin_ep_install_module "$1" "$2" "$3" "$4" "${@:6}"
  plugin_ep_seed_licenses "$2" "$5" "$3"
}

# <array name> <work dir>: what G2 reads for a plugin build: the work tree, the ORT shim, both CMake records and the configure log.
plugin_ep_g2_records() {
  local -n _pgr="$1"
  _pgr=(--tree "$2" --shim "$2/ort" --record "$2/build/CMakeCache.txt" --record "$2/build/build.ninja" --log "$2/configure.log")
}

# <output dir> <line>...: provenance.txt, one fact per line, read by the verify stage and by hand.
plugin_ep_provenance() { local out="$1"; shift; printf '%s\n' "$@" > "${out}/provenance.txt"; }

# <output dir> <module> <label> <verify fn>: the installed module passes the plugin's library verdict; its size is the build's last line.
plugin_ep_finish() {
  "$4" "${1}/lib/${2}"
  info "${3} installed: ${1}/lib/${2} ($(stat -c %s "${1}/lib/${2}") bytes)"
}

# <build fn> <verify fn> <default module> <args>...: the build|verify CLI both plugin scripts expose.
plugin_ep_main() {
  local build_fn="$1" verify_fn="$2" default_so="$3"
  shift 3
  case "${1:-build}" in
    build) "${build_fn}" ;;
    verify) "${verify_fn}" "${2:-${default_so}}" ;;
    *) printf 'usage: %s build|verify [so]\n' "${0##*/}" >&2; exit 2 ;;
  esac
}

# <work dir>: the build environment both plugin EPs share (the ORT build library, the acceleration helpers, the job count, versions.env, the verified downloader) and a fresh work tree, since a rerun over an old one fails the fork's patch steps; PLUGIN_EP_CORE names 01-core.
plugin_ep_build_env() {
  rm -rf "$1"; mkdir -p "$1"
  # shellcheck source=lib/common.sh
  source "${SCRIPT_DIR}/lib/common.sh"
  source_build_acceleration_helpers
  detect_jobs
  PLUGIN_EP_CORE="/opt/scripts/core"; [ -d "${PLUGIN_EP_CORE}" ] || PLUGIN_EP_CORE="${SCRIPT_DIR}/../../../../01-core"
  # shellcheck source=../../../../01-core/load-versions-env.sh
  source "${PLUGIN_EP_CORE}/load-versions-env.sh"; load_versions_env "${PLUGIN_EP_CORE}/versions.env"
  command -v download_verified_file >/dev/null 2>&1 || source "${PLUGIN_EP_CORE}/downloads.sh"
}

# The pinned source and every seed into the work tree; sets MGXEP_COMMIT, MGXEP_SHA, MGXEP_SRC and the MGXEP_DEFINES the configure takes.
mgxep_sources() {
  local work="${MGXEP_WORK_DIR}" seeded declared
  MGXEP_COMMIT="$(mgxep_pin ORT_AMDGPU_EP_COMMIT)"; MGXEP_SHA="$(plugin_ep_sha_pin ORT_AMDGPU_EP_SOURCE_SHA256)"
  [[ "${MGXEP_COMMIT}" =~ ^[0-9a-f]{40}$ ]] || err "ORT_AMDGPU_EP_COMMIT=${MGXEP_COMMIT} is not a 40-hex commit"
  MGXEP_SRC="$(plugin_ep_source onnxruntime-ep-amdgpu "$(mgxep_source_url "${MGXEP_COMMIT}")" ORT_AMDGPU_EP_SOURCE_SHA256 "${work}")"
  declared="${work}/declared.txt"; seeded="${work}/seeded.txt"
  mgxep_declared_urls "${MGXEP_SRC}/src/CMakeLists.txt" > "${declared}"
  MGXEP_DEFINES=()
  mgxep_seed_all "${work}" "${seeded}" MGXEP_DEFINES
  mgxep_assert_seeded "${declared}" "${seeded}" "${MGXEP_INACTIVE_SEEDS}"
}

# <work dir> <cmake args array> <seed defines array>: configure (the log G2 reads), assert the compiler-cache pin, build.
plugin_ep_configure_and_build() {
  local -n _pcb_args="$2" _pcb_defines="$3"
  cmake "${_pcb_args[@]}" "${_pcb_defines[@]}" 2>&1 | tee "$1/configure.log"
  cmake_assert_compiler_cache_pin "$1/build" "${CMAKE_COMPILER_CACHE_PIN:-}"
  cmake --build "$1/build" --parallel "${JOBS}"
}

# Configure against the image's MIGraphX and the chain ORT, build, and name the module in MGXEP_SO.
mgxep_compile() {
  local work="${MGXEP_WORK_DIR}" mgx rocm ort_prefix python
  mgx="$(find "${MIGRAPHX_HOME}" -maxdepth 5 -path '*/lib/cmake/migraphx' -type d 2>/dev/null | sort | tail -n 1 || true)"
  [ -f "${mgx}/migraphx-config.cmake" ] || err "no migraphx-config.cmake under ${MIGRAPHX_HOME}"
  mgx="${mgx%/lib/cmake/migraphx}"
  rocm="$(find "${MIGRAPHX_HOME}" -maxdepth 5 -path '*/lib/cmake/hip' -type d 2>/dev/null | sort | tail -n 1 || true)"
  rocm="${rocm%/lib/cmake/hip}"
  ort_prefix="$(mgxep_ort_prefix "${MGXEP_ORT_DIR}" "${work}/ort")"
  setup_host_python_environment; python="${HOST_PYTHON_BIN}"
  # shellcheck disable=SC2034  # read through the nameref in plugin_ep_configure_and_build
  local -a cmake_args=(
    -S "${MGXEP_SRC}" -B "${work}/build" -G Ninja -DCMAKE_BUILD_TYPE=Release
    -DUSE_MIGRAPHX=ON -DUSE_AMDGPU=OFF -DUSE_DML=OFF -DUSE_HIP=OFF
    "-DCMAKE_PREFIX_PATH=${mgx};${rocm:-/opt/rocm}" "-Donnxruntime_DIR=${ort_prefix}/lib/cmake/onnxruntime"
    "-DPython3_EXECUTABLE=${python}" "-DPython_EXECUTABLE=${python}"
    -Dprotobuf_FORCE_FETCH_DEPENDENCIES=ON -Dprotobuf_WITH_ZLIB=OFF
    -DFETCHCONTENT_FULLY_DISCONNECTED=ON -DCMAKE_POLICY_DEFAULT_CMP0170=NEW -DCMAKE_POLICY_VERSION_MINIMUM=3.5
  )
  append_cmake_cache_linker_args cmake_args
  info ">>> MIGraphX plugin EP ${MGXEP_COMMIT:0:12}: ${#MGXEP_DEFINES[@]} pinned seeds, ${JOBS} jobs, MIGraphX at ${mgx}"
  CXXFLAGS="${CXXFLAGS:-} -D__HIP_PLATFORM_AMD__=1" plugin_ep_configure_and_build "${work}" cmake_args MGXEP_DEFINES
  MGXEP_SO="$(plugin_ep_built_module "${work}/build" libmigraphx-ep.so)"
}

# Install the module with every licence text linked into it, write the provenance, and pass G2.
mgxep_stage() {
  local -a g2
  plugin_ep_install "${MGXEP_SO}" "${MGXEP_OUTPUT_DIR}" onnxruntime-ep-amdgpu "${MGXEP_SRC}" "${MGXEP_WORK_DIR}" LICENSE LICENSES
  plugin_ep_provenance "${MGXEP_OUTPUT_DIR}" "onnxruntime-ep-amdgpu ${MGXEP_COMMIT}" "source-sha256 ${MGXEP_SHA}"
  # G2: the work tree, both records and the configure log name no ORT but the chain's; a pass stamps the prefix for the census.
  plugin_ep_g2_records g2 "${MGXEP_WORK_DIR}"
  ort_assert_chain_only amdgpu-ep --stamp "${MGXEP_OUTPUT_DIR}/ort-provenance/amdgpu-ep.json" --chain "${MGXEP_ORT_DIR}" "${g2[@]}" \
    || err "the plugin EP's build inputs reach an ONNX Runtime other than the chain's"
}

mgxep_build() {
  # The empty tree keeps the media merge's COPY --from=onnxruntime valid on the chains that do not build it.
  if [ "${ENABLE_AMD:-false}" != "true" ]; then plugin_ep_skip "${MGXEP_OUTPUT_DIR}" "Skipping the MIGraphX plugin EP (ENABLE_AMD=${ENABLE_AMD:-false})"; return 0; fi
  plugin_ep_build_env "${MGXEP_WORK_DIR}"
  # shellcheck source=../../../../01-core/cmake-cache-linker.sh
  source "${PLUGIN_EP_CORE}/cmake-cache-linker.sh"
  # shellcheck source=../../../ort-provenance.sh
  source "${SCRIPT_DIR}/../../../ort-provenance.sh"
  mgxep_sources
  mgxep_compile
  mgxep_stage
  plugin_ep_finish "${MGXEP_OUTPUT_DIR}" libmigraphx-ep.so "MIGraphX plugin EP" mgxep_verify_library
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  plugin_ep_main mgxep_build mgxep_verify_library "${MGXEP_OUTPUT_DIR}/lib/libmigraphx-ep.so" "$@"
fi
