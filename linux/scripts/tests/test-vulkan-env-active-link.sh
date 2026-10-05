#!/usr/bin/env bash
# vulkan_env_prefer_active_link (CON48): setup-env.sh's arch dir goes back to <root>/active; docs/failure-modes.md#vulkan-env-names-an-arch-specific-sdk-dir
set -u
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${TESTS_DIR}/test-harness.sh"
ENVMOD="${TESTS_DIR}/../01-core/vulkan-env.sh"

ROOT="$(mktemp -d)"
trap 'rm -rf "${ROOT}"' EXIT
ARCHDIR="${ROOT}/1.4.357.0/x86_64"
mkdir -p "${ARCHDIR}/bin" "${ROOT}/1.4.357.0/aarch64"
ln -s "${ARCHDIR}" "${ROOT}/active"
# LunarG's shape, with the arch fixed so the case does not depend on the test host.
cat > "${ROOT}/1.4.357.0/setup-env.sh" <<SETUP
VULKAN_SDK="${ARCHDIR}"; export VULKAN_SDK
PATH="\$VULKAN_SDK/bin:\$PATH"; export PATH
LD_LIBRARY_PATH="\$VULKAN_SDK/lib/VulkanLoader/lib\${LD_LIBRARY_PATH:+:\$LD_LIBRARY_PATH}"; export LD_LIBRARY_PATH
VK_ADD_LAYER_PATH="\$VULKAN_SDK/share/vulkan/explicit_layer.d"; export VK_ADD_LAYER_PATH
export PKG_CONFIG_PATH="\$VULKAN_SDK/share/pkgconfig:\$VULKAN_SDK/lib/pkgconfig\${PKG_CONFIG_PATH:+:\$PKG_CONFIG_PATH}"
export CMAKE_PREFIX_PATH="\$VULKAN_SDK":"\$VULKAN_SDK/lib/VulkanLoader"
SETUP

# _env <code>: a clean bash with the module loaded, the image ENV's arch-neutral PATH entry first.
_env() {
  env -i HOME=/nonexistent PATH="${ROOT}/active/bin:/usr/bin:/bin" LD_LIBRARY_PATH="${ROOT}/active/lib" \
    bash -c 'set -eu; source "$1"; '"$1"'
      for v in VULKAN_SDK VK_ADD_LAYER_PATH PATH LD_LIBRARY_PATH PKG_CONFIG_PATH CMAKE_PREFIX_PATH; do
        printf "%s=%s\n" "${v}" "${!v-}"; done' _ "${ENVMOD}" 2>&1
}

t_case "vulkan_env_source leaves every variable on the link"
t_needs "real symlinks (ln -s copies under Git Bash)" t_posix_symlinks
_out="$(_env 'vulkan_env_source "'"${ROOT}"'" keep-libs 1')"
t_assert_contains "${_out}" "VULKAN_SDK=${ROOT}/active" "VULKAN_SDK is the link"
t_assert_contains "${_out}" "VK_ADD_LAYER_PATH=${ROOT}/active/share/vulkan/explicit_layer.d" "the layer dir follows the link"
t_assert_contains "${_out}" "CMAKE_PREFIX_PATH=${ROOT}/active:${ROOT}/active/lib/VulkanLoader" "CMake reaches the link"
t_assert_contains "${_out}" "LD_LIBRARY_PATH=${ROOT}/active/lib/VulkanLoader/lib:${ROOT}/active/lib" "the loader dir follows the link"
t_assert_eq "0" "$(printf '%s\n' "${_out}" | grep -c '1.4.357.0/x86_64')" "no variable keeps the arch dir"

t_case "the rewrite does not duplicate a PATH entry the image ENV already has"
t_needs "real symlinks (ln -s copies under Git Bash)" t_posix_symlinks
_out="$(_env 'vulkan_env_source "'"${ROOT}"'" keep-libs 1')"
t_assert_contains "${_out}" "PATH=${ROOT}/active/bin:/usr/bin:/bin" "one link entry, order kept"

t_case "an SDK that is not the link's target is left alone"
_out="$(_env 'VULKAN_SDK="'"${ROOT}"'/1.4.357.0/aarch64"; VK_ADD_LAYER_PATH="$VULKAN_SDK/x"; vulkan_env_prefer_active_link "'"${ROOT}"'"')"
t_assert_contains "${_out}" "VULKAN_SDK=${ROOT}/1.4.357.0/aarch64" "another arch dir is not this link's"
t_assert_contains "${_out}" "VK_ADD_LAYER_PATH=${ROOT}/1.4.357.0/aarch64/x" "nothing is rewritten"

t_case "an explicit setup script goes back to the link too"
t_needs "real symlinks (ln -s copies under Git Bash)" t_posix_symlinks
_out="$(_env 'vulkan_env_source_script "'"${ROOT}"'/1.4.357.0/setup-env.sh"')"
t_assert_contains "${_out}" "VULKAN_SDK=${ROOT}/active" "vulkan_env_source_script ends on the link"

# _lib <lib> <fn>: a lib's prepare step with only the explicit setup script to source.
_lib() {
  env -i HOME="${ROOT}" PATH="/usr/bin:/bin" CARGO_HOME="${ROOT}/cargo" VULKAN_SETUP_SCRIPT="${ROOT}/1.4.357.0/setup-env.sh" \
    CMAKE_BUILD_SAFE_DIRECTORY="" CTEST_RUN_SAFE_DIRECTORY="" \
    bash -c 'source "$1"; "$2" >/dev/null 2>&1; printf "VULKAN_SDK=%s\n" "${VULKAN_SDK-}"' _ "${TESTS_DIR}/../lib/$1" "$2" 2>&1
}

t_case "cmake-build.sh and ctest-run.sh source --vulkan-setup-script onto the link"
t_needs "real symlinks (ln -s copies under Git Bash)" t_posix_symlinks
t_assert_contains "$(_lib cmake-build.sh cmake_build_prepare_env)" "VULKAN_SDK=${ROOT}/active" \
  "cmake_build_prepare_env must not re-pin the arch dir the entrypoint left"
t_assert_contains "$(_lib ctest-run.sh ctest_run_prepare_env)" "VULKAN_SDK=${ROOT}/active" \
  "ctest_run_prepare_env must not re-pin it either"

t_case "no link, no rewrite"
rm "${ROOT}/active"
_out="$(_env 'vulkan_env_source "'"${ROOT}"'" keep-libs 1')"
t_assert_contains "${_out}" "VULKAN_SDK=${ARCHDIR}" "without the link the resolved dir stays"
ln -s "${ARCHDIR}" "${ROOT}/active"

t_case "a prefix match needs a whole path component"
mkdir -p "${ARCHDIR}-other"
_out="$(_env 'vulkan_env_source "'"${ROOT}"'" keep-libs 1; PKG_CONFIG_PATH="'"${ARCHDIR}"'-other/lib:$PKG_CONFIG_PATH"; vulkan_env_prefer_active_link "'"${ROOT}"'"')"
t_assert_contains "${_out}" "PKG_CONFIG_PATH=${ARCHDIR}-other/lib:" "x86_64-other is not under x86_64"

t_summary
