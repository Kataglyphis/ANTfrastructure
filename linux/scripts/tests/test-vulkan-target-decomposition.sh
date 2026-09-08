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
           _vulkan_setup_cross_pkgconfig \
           _vulkan_target_copy_headers \
           _vulkan_target_build_loader \
           _vulkan_target_build_spirv_tools \
           _vk_note_failure \
           _vulkan_target_install_component \
           _vulkan_target_src \
           _vulkan_patch_component \
           _vulkan_target_dynamic_args \
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

t_case "vulkan.sh still names the components whose loss is fatal"
_VK_REQ_SRC="$(sed -n '/^_VK_REQUIRED_COMPONENTS=/p' "${VULKAN_SH}")"
t_assert_contains "${_VK_REQ_SRC}" "vulkan-loader spirv-tools glslang" "required set renamed or removed?"
_FNS="${_FNS}
${_VK_REQ_SRC}"

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

# CMAKE_LIBRARY_ARCHITECTURE is part of the contract: it is what makes
# find_library look in /usr/lib/<triplet> instead of reporting the target's X11,
# XCB, ZSTD and OpenGL as "NOT found". docs/vulkan-foreign-arch-sdk.md
_XTOOL='-G Ninja -DCMAKE_BUILD_TYPE=Release -DCMAKE_SYSTEM_NAME=Linux -DCMAKE_SYSTEM_PROCESSOR=aarch64 -DCMAKE_C_COMPILER=aarch64-linux-gnu-gcc -DCMAKE_CXX_COMPILER=aarch64-linux-gnu-g++ -DCMAKE_LIBRARY_ARCHITECTURE=aarch64-linux-gnu -DCMAKE_INSTALL_LIBDIR=lib -DCMAKE_POSITION_INDEPENDENT_CODE=ON'

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
t_case "a REQUIRED component that fails is fatal HERE, not a mystery hours later"
_fixture full
_out="$(_trace 1 0)"
t_assert_contains "${_out}" "LOG Vulkan cross-targets aarch64: 0/4 component(s) built"
t_assert_contains "${_out}" "DIE REQUIRED Vulkan cross-component(s) failed for aarch64: vulkan-loader spirv-tools glslang" \
  "the loader/SPIRV/glslang trio built on both foreign lanes; losing one is a regression"


t_case "VULKAN_CROSS_REQUIRED='' hands the decision back to the operator"
_fixture full
_out="$( VULKAN_CROSS_REQUIRED='' _trace 1 0 )"
t_assert_contains "${_out}" "WARN ALL 4 Vulkan cross-component(s) FAILED for aarch64"
t_assert_contains "${_out}" "broken aarch64-linux-gnu toolchain?"
t_assert_contains "${_out}" "EXIT 0" "with no required set, per-component failure stays non-fatal"

t_case "VULKAN_CROSS_STRICT=1 promotes the all-failed verdict to fatal"
_fixture full
_out="$( VULKAN_CROSS_REQUIRED='' VULKAN_CROSS_STRICT=1 _trace 1 0 )"
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

# volk alone: an OPTIONAL row. The `rest` fixture cannot serve here any more —
# it also carries shaderc, whose loss is fatal by _VK_REQUIRED_COMPONENTS.
t_case "a row that FAILS to build degrades the prefix, it does not fail the lane"
_fixture empty
mkdir -p "${SDK}/x86_64/include/vulkan" "${SDK}/source/volk"
: > "${SDK}/x86_64/include/vulkan/vulkan.h"
_out="$(_trace 1 0)"
t_assert_contains "${_out}" "LOG volk unavailable on aarch64; the target SDK ships without it"
t_assert_contains "${_out}" "EXIT 0" "an OPTIONAL component that will not cross-build is non-fatal by contract"

# ---------------------------------------------------------------------------
# The two config packages vulkan-profiles resolves through find_package: they are
# in the SDK's own source/ tree and had no row, which is the whole reason
# vulkan-profiles reported "Could not find ... valijson".
t_case "jsoncpp and valijson are cross-built BEFORE vulkan-profiles"
_fixture empty
mkdir -p "${SDK}/x86_64/include/vulkan" "${SDK}/source/jsoncpp" \
         "${SDK}/source/valijson" "${SDK}/source/Vulkan-Profiles"
: > "${SDK}/x86_64/include/vulkan/vulkan.h"
_out="$(_trace 0 0)"
t_assert_eq "jsoncpp-aarch64 valijson-aarch64 vulkan-profiles-aarch64" \
  "$(printf '%s\n' "${_out}" | sed -n 's/^CMAKE -S .* -B TMP\/\([a-z-]*[0-9]*\) .*/\1/p' | tr '\n' ' ' | sed 's/ $//')" \
  "a config package that lands AFTER its consumer is the same failure as no row at all"
t_assert_contains "${_out}" "-DBUILD_STATIC_LIBS=ON" "jsoncpp must ship a linkable library"
t_assert_contains "${_out}" "-Dvalijson_INSTALL_HEADERS=ON" "valijson is header-only; the headers ARE the install"

# ---------------------------------------------------------------------------
# The Canadian-cross rows: a generator or a moc that must run on the BUILD HOST.
t_case "slang takes the host generators when ./vulkansdk left them behind"
_fixture empty
mkdir -p "${SDK}/x86_64/include/vulkan" "${SDK}/source/slang" \
         "${SDK}/source/slang/build/generators/Release/bin"
: > "${SDK}/x86_64/include/vulkan/vulkan.h"
printf '#!/bin/sh\n' > "${SDK}/source/slang/build/generators/Release/bin/slang-embed"
chmod +x "${SDK}/source/slang/build/generators/Release/bin/slang-embed"
_out="$(_trace 0 0)"
t_assert_contains "${_out}" "-DSLANG_GENERATORS_PATH=SDK/source/slang/build/generators/Release/bin" \
  "without this the cross build links slang-embed for the TARGET and runs it: exit 127"
t_assert_contains "${_out}" "-DSLANG_ENABLE_DXIL=OFF" "the DXC slang fetches is an x86_64 prebuilt"

t_case "slang without host generators says so instead of passing an empty path"
_fixture empty
mkdir -p "${SDK}/x86_64/include/vulkan" "${SDK}/source/slang"
: > "${SDK}/x86_64/include/vulkan/vulkan.h"
_out="$(_trace 0 0)"
t_assert_contains "${_out}" "LOG slang: no host generators at SDK/source/slang/build/generators/Release/bin"
t_assert_eq "" "$(printf '%s\n' "${_out}" | grep -e '-DSLANG_GENERATORS_PATH' || true)"

t_case "the caps viewer gets target Qt6 from the sysroot and host moc from /usr"
_fixture rest
_out="$(_trace 0 0)"
t_assert_contains "${_out}" "-DQT_HOST_PATH=/usr"
t_assert_contains "${_out}" "-DCMAKE_PREFIX_PATH=SDK/aarch64;/usr/lib/aarch64-linux-gnu" \
  "the dynamic prefix path must come AFTER the shared one so it wins"
t_assert_contains "${_out}" "-DVULKAN_LOADER_INSTALL_DIR=SDK/aarch64" \
  "upstream interpolates \${VULKAN_LOADER_INSTALL_DIR}/lib/libvulkan.so RAW -- unset it resolves to the HOST /lib/libvulkan.so and ninja refuses the graph before any rule runs"

# ── the four defects the 2026-09-08 chain measured behind the VK2 routes ────
# Each route worked; each component then died at something new. These pin the
# answers. docs/vulkan-foreign-arch-sdk.md
t_case "every target-side SDK component is built PIC"
t_assert_contains "$(awk '/^_cross_build_sdk_component\(\) \{/,/^\}/' "${VULKAN_SH}")" \
  "-DCMAKE_POSITION_INDEPENDENT_CODE=ON" \
  "jsoncpp_static inherits no PIC from jsoncpp_object, so libjsoncpp.a could not go into libVkLayer_khronos_profiles.so: R_AARCH64_ADR_PREL_PG_HI21"

t_case "the GL header family is bridged into the cross include dir, not just X11/xcb"
_bridge="$(grep -e 'for entry in X11 xcb' "${VULKAN_SH}")"
for _h in GL KHR EGL; do
  t_assert_contains "${_bridge}" "${_h}" \
    "gfxreconstruct finds the target LIBS but not the headers; GL/gl.h includes <KHR/khrplatform.h>, so KHR is not optional"
done

t_case "slang gets the vendor's between-build-and-install copy step"
_fixture empty
mkdir -p "${SDK}/x86_64/include/vulkan" "${SDK}/source/slang" \
         "${SDK}/source/slang/build/generators/Release/bin"
: > "${SDK}/x86_64/include/vulkan/vulkan.h"
printf '#!/bin/sh\n' > "${SDK}/source/slang/build/generators/Release/bin/slang-embed"
chmod +x "${SDK}/source/slang/build/generators/Release/bin/slang-embed"
t_assert_contains "$(awk '/^_vulkan_target_dynamic_args\(\) \{/,/^\}/' "${VULKAN_SH}")" \
  "copy-gfx-slang-modules" \
  "./vulkansdk build_slang() copies gfx.slang and slang.slang between --build and --install; the generic helper had no such step"
t_assert_contains "$(awk '/^_cross_build_sdk_component\(\) \{/,/^\}/' "${VULKAN_SH}")" \
  '--target "${_t}"' \
  "and the helper has to actually drive them, between build and install"

t_case "slang keeps WebGPU where Dawn has a prebuilt, and drops it where it does not"
# slang-rhi picks a PREBUILT Dawn zip; upstream ships x86_64 and aarch64 only and
# its arch cascade FATAL_ERRORs on anything else -- UNCONDITIONALLY, so the option
# alone is not enough and the URL has to be defined too. This is the one place an
# arch may differ, and only because no riscv64 Dawn binary exists upstream.
_slangargs() {
  ( eval "$(awk '/^_vulkan_target_dynamic_args\(\) \{/,/^\}/' "${VULKAN_SH}")"
    log() { :; }
    local -a _o=(); local -a _xbuild_extra_targets=()
    _vulkan_target_dynamic_args slang SDK SDK/"$2" "$1" _o
    printf '%s ' "${_o[@]}" )
}
t_assert_eq "" "$(_slangargs aarch64-linux-gnu aarch64 | grep -oe 'SLANG_RHI_ENABLE_WGPU=OFF' || true)" \
  "aarch64 HAS a Dawn prebuilt -- turning WebGPU off there would be a regression"
t_assert_contains "$(_slangargs riscv64-linux-gnu riscv64)" "-DSLANG_RHI_ENABLE_WGPU=OFF" \
  "no riscv64 Dawn binary exists upstream"
t_assert_contains "$(_slangargs riscv64-linux-gnu riscv64)" "-DSLANG_RHI_DAWN_URL=" \
  "the URL-default block runs even with the backend off; defining it is what skips the FATAL_ERROR"

t_case "no SDK component is skipped for the target arch -- amd64 is the reference"
# slang was skipped on riscv64 as "not yet ported upstream". That gated the HOST
# x86_64 ./vulkansdk build on the TARGET arch, which cannot be a reason, and the
# skip took the CHECKOUT with it -- so the cross build could not attempt it either:
# 19 host components vs arm64's 20, 15 cross attempts vs 16. All three arches must
# build the same set; what cannot cross-build says so with a measured reason.
# CODE only: the comment above the list explains the removal and names riscv64,
# which is exactly what this case must not read.
_bcsrc="$(awk '/^_vulkan_build_components\(\) \{/,/^\}/' "${VULKAN_SH}" | grep -ve '^[[:space:]]*#')"
t_assert_eq "" "$(printf '%s\n' "${_bcsrc}" | grep -e '_vulkan_skip' || true)" \
  "an arch-keyed skip table is exactly what cost riscv64 slang"
t_assert_eq "" "$(printf '%s\n' "${_bcsrc}" | grep -e 'riscv64' || true)" \
  "no arch name may appear in the component selection at all"
for _c in vulkan-tools gfxreconstruct vcv slang; do
  t_assert_contains "${_bcsrc}" "${_c}" "every arch builds ${_c}"
done

t_case "gfxreconstruct is configured the way ./vulkansdk configures it"
# The cross row built OpenXR that the VENDOR never builds -- build_gfxreconstruct()
# passes GFXRECON_ENABLE_OPENXR=OFF. Its bundled OpenXR-SDK carries its OWN older
# jsoncpp SOURCE, and our target prefix precedes it on the include path, so that
# source compiled against our 1.9.6 header: 'skipCommentTokens' was not declared.
# Parity with the vendor, not a skip: amd64 ships no openxr_loader either.
_gfxrow="$(grep -e '^gfxreconstruct|' "${VULKAN_SH}")"
for _f in GFXRECON_ENABLE_OPENXR=OFF D3D12_SUPPORT=OFF GFXRECON_TOCPP_SUPPORT=OFF \
          GFXRECON_INCLUDE_TEST_APPS=OFF; do
  t_assert_contains "${_gfxrow}" "${_f}" "./vulkansdk build_gfxreconstruct() passes it; the cross row must not diverge"
done

t_case "the extra-target list is RESET per component, or it leaks across rows"
t_assert_contains "$(awk '/^_vulkan_target_dynamic_args\(\) \{/,/^\}/' "${VULKAN_SH}")" \
  "_xbuild_extra_targets=()" \
  "the table is walked in one loop; without a reset slang's target would be driven for every component after it"

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

# ── the host half of the pkg-config path ────────────────────────────────────
# _vulkan_run_vulkansdk builds HOST tools while the cross search path is still
# exported, and is sudo --preserve-env'd with it. A host tool asking for xcb was
# handed the TARGET module, whose LIBRARY_DIRS became a find_library HINT and
# resolved to an absolute foreign path -- which ld cannot skip the way it skips
# an incompatible -l. That took the sdk stage down on 2026-09-05.
_pkgconf_env() {
  bash -c '
    set -u
    cross_build_is_active() { return 0; }
    cross_pkg_config_libdir() { printf "/usr/%s/lib/pkgconfig:/usr/lib/%s/pkgconfig" "$1" "$1"; }
    log() { :; }
    dpkg-architecture() { printf "x86_64-linux-gnu"; }
    '"$(sed -n '/^_vulkan_setup_cross_pkgconfig()/,/^}/p' "${VULKAN_SH}")"'
    _vulkan_setup_cross_pkgconfig aarch64-linux-gnu
    printf "CROSS=%s\nHOST=%s\n" "${PKG_CONFIG_LIBDIR}" "${VULKAN_HOST_PKG_CONFIG_LIBDIR}"' 2>&1
}

t_case "the cross path leads with the target triplet -- that is what it is for"
t_assert_contains "$(_pkgconf_env | sed -n 's/^CROSS=//p')" "aarch64-linux-gnu" \
  "the target build must find the target's modules first"

t_case "the HOST half is exported separately and names no target triplet"
_host_half="$(_pkgconf_env | sed -n 's/^HOST=//p')"
t_assert_eq "0" "$(printf '%s' "${_host_half}" | grep -c aarch64-linux-gnu || true)" \
  "a host tool searching here is how vulkaninfo got an absolute aarch64 libxcb"
t_assert_contains "${_host_half}" "pkgconfig" "it still has to be a real search path"

t_case "the host swap is applied and then undone around the host SDK build"
_run_src="$(sed -n '/^_vulkan_run_vulkansdk()/,/^}/p' "${VULKAN_SH}")"
t_assert_contains "${_run_src}" "_vulkan_pkgconfig_use_host" \
  "the host build must not inherit the cross search path"
t_assert_contains "${_run_src}" "_vulkan_pkgconfig_restore" \
  "and the cross value has to come back for the target build that follows"

t_case "the swap actually replaces the path, and the restore puts it back"
_swapped="$(bash -c '
  set -u
  log() { :; }
  '"$(sed -n '/^_vulkan_pkgconfig_use_host()/,/^}/p' "${VULKAN_SH}")"'
  '"$(sed -n '/^_vulkan_pkgconfig_restore()/,/^}/p' "${VULKAN_SH}")"'
  export PKG_CONFIG_LIBDIR=/cross/aarch64-linux-gnu/pkgconfig
  export PKG_CONFIG_SYSROOT_DIR=/ PKG_CONFIG_ALLOW_CROSS=1
  VULKAN_HOST_PKG_CONFIG_LIBDIR=/host/pkgconfig
  _saved=$PKG_CONFIG_LIBDIR
  _vulkan_pkgconfig_use_host
  printf "during=%s sysroot=%s\n" "${PKG_CONFIG_LIBDIR}" "${PKG_CONFIG_SYSROOT_DIR:-unset}"
  _vulkan_pkgconfig_restore "$_saved" "/" "1"
  printf "after=%s\n" "${PKG_CONFIG_LIBDIR}"' 2>&1)"
t_assert_contains "${_swapped}" "during=/host/pkgconfig" "the host build searches the host half only"
t_assert_contains "${_swapped}" "sysroot=unset" "a cross sysroot has no meaning for a host tool"
t_assert_contains "${_swapped}" "after=/cross/aarch64-linux-gnu/pkgconfig" \
  "the target build that follows still needs the cross path"

t_summary
