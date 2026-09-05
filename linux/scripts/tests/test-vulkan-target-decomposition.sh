#!/usr/bin/env bash
# Golden trace of _build_vulkan_targets + the _vulkan_target_* helpers it was
# decomposed into (02-toolchain/vulkan.sh).
# docs/cross-build-verification.md#the-linuxscriptstests-suites
set -u
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${TESTS_DIR}/test-harness.sh"
VULKAN_SH="${TESTS_DIR}/../02-toolchain/vulkan.sh"

# Source ONLY the functions under test: vulkan.sh sets `set -euo pipefail` at
# file scope and pulls 01-core modules on source.
_FNS=""
for _fn in _cross_build_sdk_component \
           _vulkan_target_copy_headers \
           _vulkan_target_build_loader \
           _vulkan_target_build_spirv_tools \
           _vulkan_target_install_component \
           _vulkan_target_src \
           _vulkan_target_build_sdk_rest \
           _vulkan_target_link_glslang_aliases \
           _vulkan_target_build_glslang \
           _vulkan_target_verdict \
           _vulkan_prune_sdk_sources \
           _build_vulkan_targets; do
  _src="$(awk "/^${_fn}\(\) \{/,/^\}/" "${VULKAN_SH}")"
  t_case "vulkan.sh still defines ${_fn}"
  t_assert_contains "${_src}" "${_fn}() {" "helper renamed or removed?"
  _FNS="${_FNS}
${_src}"
done

# _vulkan_target_build_sdk_rest reads a TABLE, not arguments: a row lost here is
# a component that silently stops being cross-built, so the suite drives the
# real one rather than a fixture of its own.
t_case "vulkan.sh still defines the _VK_TARGET_COMPONENTS table"
_VK_TABLE_SRC="$(awk '/^_VK_TARGET_COMPONENTS="/,/^"$/' "${VULKAN_SH}")"
t_assert_contains "${_VK_TABLE_SRC}" 'shaderc|shaderc/src,shaderc|' "table renamed or removed?"
_FNS="${_FNS}
${_VK_TABLE_SRC}"

SDK="$(mktemp -d)"
trap 'rm -rf "${SDK}"' EXIT

# mktemp honours TMPDIR, so the argv normaliser must too; every non-word byte is
# escaped for the ERE. docs/cross-build-verification.md
_TMP_RE="$(printf '%s' "${TMPDIR:-/tmp}" | sed -e 's#/*$##' -e 's#[^A-Za-z0-9_/-]#\\&#g')"

# Fake extracted SDK tree; `full` = every source + host headers, the rest
# exercise the skip branches.
_fixture() {
  rm -rf "${SDK:?}"/*
  case "$1" in
    empty) ;;
    glslang-main)
      mkdir -p "${SDK}/x86_64/include/vulkan" "${SDK}/source/glslang-main"
      : > "${SDK}/x86_64/include/vulkan/vulkan.h"
      ;;
    rest)
      # None of the four TVM needs; one component per _vulkan_target_src shape:
      # `volk` matches its only candidate, `shaderc` its FIRST (one level down),
      # `vulkancapsviewer` its THIRD.
      mkdir -p "${SDK}/x86_64/include/vulkan" "${SDK}/x86_64/include/vk_video"
      : > "${SDK}/x86_64/include/vulkan/vulkan.h"
      mkdir -p "${SDK}/source/volk" "${SDK}/source/shaderc/src" "${SDK}/source/vcv"
      ;;
    *)
      mkdir -p "${SDK}/x86_64/include/vulkan" "${SDK}/x86_64/include/vk_video"
      : > "${SDK}/x86_64/include/vulkan/vulkan.h"
      : > "${SDK}/x86_64/include/vk_video/vk_video.h"
      mkdir -p "${SDK}/source/Vulkan-Loader" "${SDK}/source/SPIRV-Tools" \
               "${SDK}/source/SPIRV-Headers" "${SDK}/source/glslang"
      ;;
  esac
}

# Runs it under the caller's `set -euo pipefail` with cmake/log/warn/die stubbed;
# an errexit abort shows up as a MISSING "EXIT 0". $1=cmake rc $2=record SUDO
_trace() {
  local rc="$1" record_sudo="$2"
  (
    set -euo pipefail
    eval "${_FNS}"
    log()  { printf 'LOG %s\n' "$*"; }
    warn() { printf 'WARN %s\n' "$*"; }
    die()  { printf 'DIE %s\n' "$*"; exit 9; }
    compute_jobs() { printf '4\n'; }
    cmake() { printf 'CMAKE %s\n' "$*"; return "${rc}"; }
    _sudo_rec() { printf 'SUDO %s\n' "$*"; }
    SUDO=""
    [ "${record_sudo}" = "1" ] && SUDO=_sudo_rec
    unset CC CXX
    _build_vulkan_targets aarch64 "${SDK}" aarch64-linux-gnu
    printf 'EXIT %s\n' "$?"
  ) 2>&1 | sed -E "s#-B ${_TMP_RE}/[A-Za-z0-9._]+/#-B TMP/#; s#(--build|--install) ${_TMP_RE}/[A-Za-z0-9._]+/#\1 TMP/#; s#${SDK}#SDK#g"
}

_XTOOL='-G Ninja -DCMAKE_BUILD_TYPE=Release -DCMAKE_SYSTEM_NAME=Linux -DCMAKE_SYSTEM_PROCESSOR=aarch64 -DCMAKE_C_COMPILER=aarch64-linux-gnu-gcc -DCMAKE_CXX_COMPILER=aarch64-linux-gnu-g++ -DCMAKE_INSTALL_LIBDIR=lib'

# ---------------------------------------------------------------------------
_fixture full
_out="$(_trace 0 0)"

t_case "all three components: cmake argv is byte-for-byte the cross contract"
t_assert_contains "${_out}" \
  "CMAKE -S SDK/source/Vulkan-Loader -B TMP/vulkan-loader-aarch64 ${_XTOOL} -DCMAKE_INSTALL_PREFIX=SDK/aarch64 -DVULKAN_HEADERS_INSTALL_DIR=SDK/x86_64 -DBUILD_TESTS=OFF -DBUILD_WSI_XCB_SUPPORT=OFF -DBUILD_WSI_XLIB_SUPPORT=OFF -DBUILD_WSI_WAYLAND_SUPPORT=OFF -DBUILD_WSI_DIRECTFB_SUPPORT=OFF" \
  "loader flags/WSI-off set changed"
t_assert_contains "${_out}" \
  "CMAKE -S SDK/source/SPIRV-Tools -B TMP/spirv-tools-aarch64 ${_XTOOL} -DCMAKE_INSTALL_PREFIX=SDK/aarch64 -DSPIRV-Headers_SOURCE_DIR=SDK/source/SPIRV-Headers -DSPIRV_SKIP_TESTS=ON -DSPIRV_SKIP_EXECUTABLES=OFF -DSPIRV_WERROR=OFF" \
  "SPIRV-Tools flags changed (SPIRV_WERROR=OFF guards GCC 16 -Warray-bounds)"
t_assert_contains "${_out}" \
  "CMAKE -S SDK/source/glslang -B TMP/glslang-aarch64 ${_XTOOL} -DCMAKE_INSTALL_PREFIX=SDK/aarch64 -DENABLE_OPT=OFF -DGLSLANG_TESTS=OFF -DBUILD_TESTING=OFF -DENABLE_GLSLANG_BINARIES=ON -DENABLE_SPVREMAPPER=OFF" \
  "glslang flags changed"

t_case "step order: the four TVM needs, then the rest of the SDK, then the verdict"
t_assert_eq "vulkan-loader-aarch64 spirv-tools-aarch64 glslang-aarch64 spirv-headers-aarch64" \
  "$(printf '%s\n' "${_out}" | sed -n 's/^CMAKE -S .* -B TMP\/\([a-z-]*[0-9]*\) .*/\1/p' | tr '\n' ' ' | sed 's/ $//')"
t_assert_contains "${_out}" "LOG Vulkan cross-targets aarch64: 4/4 component(s) built"
t_assert_contains "${_out}" "EXIT 0"

t_case "headers are copied into the target archdir BEFORE the loader configures"
t_assert_ok test -d "${SDK}/aarch64/include/vulkan"
t_assert_ok test -d "${SDK}/aarch64/include/vk_video"
t_assert_ok test -d "${SDK}/aarch64/lib"

# ---------------------------------------------------------------------------
t_case "every component failing is an env-shaped verdict, not silent success"
_fixture full
_out="$(_trace 1 0)"
t_assert_contains "${_out}" "LOG Vulkan cross-targets aarch64: 0/4 component(s) built"
t_assert_contains "${_out}" "WARN ALL 4 Vulkan cross-component(s) FAILED for aarch64"
t_assert_contains "${_out}" "broken aarch64-linux-gnu toolchain?"
t_assert_contains "${_out}" "EXIT 0" "per-component failure stays non-fatal by default"

t_case "VULKAN_CROSS_STRICT=1 promotes the all-failed verdict to fatal"
_fixture full
_out="$( VULKAN_CROSS_STRICT=1 _trace 1 0 )"
t_assert_contains "${_out}" "DIE VULKAN_CROSS_STRICT=1 and all 4 Vulkan cross-components failed for aarch64"

# ---------------------------------------------------------------------------
t_case "missing sources: each component logs its own skip, verdict is 0/0"
_fixture empty
_out="$(_trace 0 0)"
t_assert_contains "${_out}" "LOG Vulkan-Loader source or host headers missing; skipping target loader"
t_assert_contains "${_out}" "LOG SPIRV-Tools source missing at SDK/source/SPIRV-Tools; skipping target SPIRV-Tools"
t_assert_contains "${_out}" "LOG glslang source missing at SDK/source/glslang; skipping target glslang"
t_assert_contains "${_out}" "LOG Vulkan cross-targets aarch64: 0/0 component(s) built"
t_assert_eq "" "$(printf '%s\n' "${_out}" | grep '^CMAKE' || true)" "nothing may configure"
t_assert_contains "${_out}" "EXIT 0"

t_case "glslang falls back to the source/glslang-main checkout name"
_fixture glslang-main
_out="$(_trace 0 0)"
t_assert_contains "${_out}" "CMAKE -S SDK/source/glslang-main -B TMP/glslang-aarch64"
t_assert_contains "${_out}" "LOG Vulkan cross-targets aarch64: 1/1 component(s) built"

# ---------------------------------------------------------------------------
# ${SUDO} is recorded, not run: no host symlinks.
t_case "glslang installed as 'glslang' also gets the glslangValidator alias"
_fixture full
mkdir -p "${SDK}/aarch64/bin"
printf '#!/bin/sh\n' > "${SDK}/aarch64/bin/glslang"
chmod +x "${SDK}/aarch64/bin/glslang"
_out="$(_trace 0 1)"
t_assert_contains "${_out}" "SUDO ln -s glslang SDK/aarch64/bin/glslangValidator"
t_assert_contains "${_out}" "SUDO ln -sf SDK/aarch64/bin/glslang /usr/local/bin/glslang"
# The recorder creates no alias, so the loop's last `[ -e ]` is false: EXIT 0
# proves the helper's trailing `return 0` still absorbs it under errexit.
t_assert_contains "${_out}" "EXIT 0" \
  "_vulkan_target_link_glslang_aliases must not leak a false [ -e ] test under set -e"

t_case "glslang installed as 'glslangValidator' gets the reverse alias"
_fixture full
mkdir -p "${SDK}/aarch64/bin"
printf '#!/bin/sh\n' > "${SDK}/aarch64/bin/glslangValidator"
chmod +x "${SDK}/aarch64/bin/glslangValidator"
_out="$(_trace 0 1)"
t_assert_contains "${_out}" "SUDO ln -s glslangValidator SDK/aarch64/bin/glslang"
t_assert_contains "${_out}" "EXIT 0"

# ---------------------------------------------------------------------------
# Everything the SDK ships beyond the four TVM needs is table-driven, so the
# table IS the behaviour. docs/vulkan-foreign-arch-sdk.md
_fixture rest
_out="$(_trace 0 0)"

t_case "the component table drives one cross-install per row that has a source"
t_assert_eq "volk-aarch64 shaderc-aarch64 vulkancapsviewer-aarch64" \
  "$(printf '%s\n' "${_out}" | sed -n 's/^CMAKE -S .* -B TMP\/\([a-z-]*[0-9]*\) .*/\1/p' | tr '\n' ' ' | sed 's/ $//')" \
  "table order is dependency order: config packages before the components that find_package them"
t_assert_contains "${_out}" "LOG Vulkan cross-targets aarch64: 3/3 component(s) built"
t_assert_contains "${_out}" "EXIT 0"

t_case "_vulkan_target_src picks the FIRST candidate directory that exists"
t_assert_contains "${_out}" "CMAKE -S SDK/source/shaderc/src -B TMP/shaderc-aarch64" \
  "shaderc keeps its CMake project one level down; the bare checkout name must lose to it"
t_assert_contains "${_out}" "CMAKE -S SDK/source/vcv -B TMP/vulkancapsviewer-aarch64" \
  "a third candidate must be reached, not just the first two"

t_case "every row gets the shared cross contract plus its own extra args"
t_assert_contains "${_out}" \
  "CMAKE -S SDK/source/volk -B TMP/volk-aarch64 ${_XTOOL} -DCMAKE_INSTALL_PREFIX=SDK/aarch64 -DCMAKE_PREFIX_PATH=SDK/aarch64 -DBUILD_TESTS=OFF -DBUILD_TESTING=OFF -DVULKAN_HEADERS_INSTALL_DIR=SDK/aarch64 -DSPIRV_HEADERS_INSTALL_DIR=SDK/aarch64 -DVOLK_INSTALL=ON" \
  "the row's extra column must survive word-splitting onto the argv"
t_assert_contains "${_out}" "-DSHADERC_SKIP_TESTS=ON -DSHADERC_SKIP_EXAMPLES=ON -DSHADERC_ENABLE_INSTALL=ON" \
  "a multi-flag extra column must not collapse to one word"

t_case "a row with no source skips, logs, and is not counted as attempted"
t_assert_contains "${_out}" "LOG vulkan-validationlayers: source missing at SDK/source/Vulkan-ValidationLayers; skipping"
t_assert_eq "" "$(printf '%s\n' "${_out}" | grep -e '-B TMP/vulkan-validationlayers-aarch64' || true)" \
  "a skipped row must not configure"

t_case "a row that FAILS to build degrades the prefix, it does not fail the lane"
_fixture rest
_out="$(_trace 1 0)"
t_assert_contains "${_out}" "LOG volk unavailable on aarch64; the target SDK ships without it"
t_assert_contains "${_out}" "EXIT 0" "a component that will not cross-build is non-fatal by contract"

# ---------------------------------------------------------------------------
# The ./vulkansdk build tree is dropped in the RUN that produced it, so no layer
# downstream of the SDK stage carries it.
_prune() {
  (
    set -euo pipefail
    eval "${_FNS}"
    log() { printf 'LOG %s\n' "$*"; }
    unset SUDO
    _vulkan_prune_sdk_sources "$1"
    printf 'EXIT %s\n' "$?"
  ) 2>&1 | sed "s#${SDK}#SDK#g"
}

t_case "the SDK source tree is pruned, the host prefix the SDK stage still uses is not"
_fixture full
_out="$(_prune "${SDK}")"
t_assert_contains "${_out}" "LOG Pruning the Vulkan SDK build tree at SDK/source"
t_assert_ok test '!' -e "${SDK}/source"
t_assert_ok test -d "${SDK}/x86_64"
t_assert_contains "${_out}" "EXIT 0"

t_case "no source/ prunes to a no-op that errexit does not turn into an abort"
_fixture empty
mkdir -p "${SDK}/x86_64"
_out="$(_prune "${SDK}")"
t_assert_eq "" "$(printf '%s\n' "${_out}" | grep -e '^LOG Pruning')" "nothing to prune must log nothing"
t_assert_contains "${_out}" "EXIT 0" "the directory guard must absorb the miss under errexit"

t_case "the cross install prunes AFTER _build_vulkan_targets consumed the sources"
_XSRC="$(awk '/^_build_vulkan_sdk_cross\(\) \{/,/^\}/' "${VULKAN_SH}")"
t_assert_contains "${_XSRC}" '_vulkan_prune_sdk_sources "${target_dir}"' \
  "the prune is unreachable unless the cross install calls it"
t_assert_eq "targets prune" \
  "$(printf '%s\n' "${_XSRC}" | sed -n 's/.*_build_vulkan_targets .*/targets/p; s/.*_vulkan_prune_sdk_sources .*/prune/p' | tr '\n' ' ' | sed 's/ $//')" \
  "pruning before the targets build would delete the loader/SPIRV-Tools/glslang sources"

# A hardcoded /tmp left 5 of 35 assertions un-normalised under an override.
if [ -z "${VULKAN_TMPDIR_CASE:-}" ]; then
  t_case "the whole suite still passes with TMPDIR pointed elsewhere"
  _alt="$(mktemp -d)"
  t_assert_ok env "TMPDIR=${_alt}" VULKAN_TMPDIR_CASE=1 bash "${TESTS_DIR}/$(basename "${BASH_SOURCE[0]}")"
  rm -rf "${_alt}"
fi

t_summary
