#!/usr/bin/env bash
# prune-vulkan-host-sdk.sh; see docs/artifact-copy-completeness.md#the-vulkan-tree-ships-only-what-the-image-runs
set -u
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${TESTS_DIR}/test-harness.sh"
PRUNE="${TESTS_DIR}/../06-packaging/prune-vulkan-host-sdk.sh"

ROOT="$(mktemp -d)"
trap 'rm -rf "${ROOT}"' EXIT

# _fixture [arch dir] [loader|symlink|other]: the shipped SDK shape, plus a target prefix when given.
_fixture() {
  local arch_dir="${1:-}" loader="${2:-loader}"
  rm -rf "${ROOT:?}"/*
  mkdir -p "${ROOT}/1.4.357.0/x86_64/lib" "${ROOT}/1.4.357.0/source/glslang"
  : > "${ROOT}/1.4.357.0/x86_64/lib/libvulkan.so.1"
  : > "${ROOT}/1.4.357.0/setup-env.sh"
  [ -n "${arch_dir}" ] || return 0
  case "${loader}" in
    symlink) ln -s x86_64 "${ROOT}/1.4.357.0/${arch_dir}" ;;
    loader)  mkdir -p "${ROOT}/1.4.357.0/${arch_dir}/lib"
             : > "${ROOT}/1.4.357.0/${arch_dir}/lib/libvulkan.so.1" ;;
    *)       mkdir -p "${ROOT}/1.4.357.0/${arch_dir}/lib" ;;
  esac
}

# BUILDARCH pinned: the builder prefix follows the build host, and these cases describe the amd64-hosted lane.
_run() { BUILDARCH="${2:-amd64}" bash "${PRUNE}" "$1" "${ROOT}" 2>&1; }

t_case "a foreign arch with its own loader loses the builder prefix and the sources"
_fixture aarch64
_out="$(_run arm64)"
t_assert_ok test '!' -e "${ROOT}/1.4.357.0/x86_64"
t_assert_ok test '!' -e "${ROOT}/1.4.357.0/source"
t_assert_ok test -e "${ROOT}/1.4.357.0/aarch64/lib/libvulkan.so.1"
t_assert_ok test -e "${ROOT}/1.4.357.0/setup-env.sh"
t_assert_contains "${_out}" "removing ${ROOT}/1.4.357.0/x86_64 (builder-arch SDK; arm64 runs aarch64/lib/libvulkan.so.1)" \
  "the line must name what the image runs instead, or a reader cannot audit the drop"

t_case "riscv64 maps to its own prefix, not to the host one"
_fixture riscv64
_out="$(_run riscv64)"
t_assert_ok test '!' -e "${ROOT}/1.4.357.0/x86_64"
t_assert_ok test -e "${ROOT}/1.4.357.0/riscv64/lib/libvulkan.so.1"

t_case "amd64 keeps x86_64 — it IS the prefix the image runs"
_fixture ""
_out="$(_run amd64)"
t_assert_ok test -e "${ROOT}/1.4.357.0/x86_64/lib/libvulkan.so.1"
t_assert_ok test '!' -e "${ROOT}/1.4.357.0/source"
t_assert_contains "${_out}" "keeping ${ROOT}/1.4.357.0/x86_64 (it is the prefix amd64 runs)"

t_case "a foreign arch whose cross build produced no loader keeps the host prefix and says so"
_fixture aarch64 nothing
_out="$(_run arm64)"
t_assert_ok test -e "${ROOT}/1.4.357.0/x86_64/lib/libvulkan.so.1"
t_assert_contains "${_out}" "WARNING keeping" "a silent prune here would ship an image with no loader at all"

t_case "the setup-vulkan-symlinks fallback shape is not mistaken for a cross build"
# The package stage's aarch64 -> x86_64 fallback link; pruning x86_64 would delete what it points at.
_fixture aarch64 symlink
_out="$(_run arm64)"
t_assert_ok test -e "${ROOT}/1.4.357.0/x86_64/lib/libvulkan.so.1"
t_assert_contains "${_out}" "WARNING keeping"

t_case "running twice changes nothing and still exits 0"
_fixture aarch64
_run arm64 >/dev/null
t_assert_ok bash "${PRUNE}" arm64 "${ROOT}"
t_assert_ok test -e "${ROOT}/1.4.357.0/aarch64/lib/libvulkan.so.1"

t_case "every version directory under the root is visited"
_fixture aarch64
mkdir -p "${ROOT}/1.3.290.0/x86_64/lib" "${ROOT}/1.3.290.0/aarch64/lib" "${ROOT}/1.3.290.0/source"
: > "${ROOT}/1.3.290.0/aarch64/lib/libvulkan.so.1"
_run arm64 >/dev/null
t_assert_ok test '!' -e "${ROOT}/1.3.290.0/x86_64"
t_assert_ok test '!' -e "${ROOT}/1.3.290.0/source"

t_case "an absent root is a no-op, never an error"
t_assert_ok bash "${PRUNE}" arm64 "${ROOT}/does-not-exist"

t_case "an unmappable arch is a hard error, never a guess"
# arch_uname_name_for echoes an unknown arch back, which would silently keep the whole host prefix.
_fixture aarch64
t_assert_fails bash "${PRUNE}" not-an-arch "${ROOT}"
t_assert_contains "$(bash "${PRUNE}" not-an-arch "${ROOT}" 2>&1 || true)" \
  "no Vulkan SDK prefix name for target arch 'not-an-arch'"

t_case "no arch mapper reachable is a hard error, never a default"
_ISOLATED="$(mktemp -d)"
cp "${PRUNE}" "${_ISOLATED}/prune.sh"
t_assert_fails bash "${_ISOLATED}/prune.sh" arm64 "${ROOT}"
t_assert_contains "$(bash "${_ISOLATED}/prune.sh" arm64 "${ROOT}" 2>&1 || true)" \
  "found no platform.sh defining arch_uname_name_for"
rm -rf "${_ISOLATED}"

t_case "Dockerfile.package runs it in artifact-source, ahead of the /opt/vulkan COPY"
# The prune only pays off before the COPY: after it, the bytes are already a layer.
_DF="${TESTS_DIR}/../../Dockerfile.package"
_RUN_LINE="$(grep -n -e 'prune-vulkan-host-sdk.sh "${TARGET_ARCH' "${_DF}" | cut -d: -f1)"
_COPY_LINE="$(grep -n -e 'from=artifact-source /opt/vulkan /opt/vulkan' "${_DF}" | cut -d: -f1)"
t_assert_ok test -n "${_RUN_LINE}"
t_assert_ok test -n "${_COPY_LINE}"
t_assert_ok test "${_RUN_LINE}" -lt "${_COPY_LINE}"
t_assert_contains "$(sed -n "1,${_RUN_LINE}p" "${_DF}")" "AS artifact-source" \
  "the prune must run in the stage the COPY reads from"

t_case "the builder prefix follows the BUILD HOST, not a frozen x86_64"
# The mirror image of the amd64 fixture: an arm64 host's own prefix is aarch64.
rm -rf "${ROOT:?}"/*
mkdir -p "${ROOT}/1.4.357.0/aarch64/lib" "${ROOT}/1.4.357.0/riscv64/lib" \
         "${ROOT}/1.4.357.0/source/glslang"
: > "${ROOT}/1.4.357.0/aarch64/lib/libvulkan.so.1"
: > "${ROOT}/1.4.357.0/riscv64/lib/libvulkan.so.1"
_out="$(_run riscv64 arm64)"
# on an arm64 build host, aarch64 IS the builder prefix and must go
t_assert_ok test '!' -e "${ROOT}/1.4.357.0/aarch64"
# the target's loader must survive
t_assert_ok test -e "${ROOT}/1.4.357.0/riscv64/lib/libvulkan.so.1"
t_assert_contains "${_out}" "riscv64 runs riscv64/lib/libvulkan.so.1"

t_case "a native arm64 build drops the LunarG tarball's x86_64 prefix too"
# Builder == target, so the builder rule alone would keep the tarball's x86_64 prefix.
_fixture aarch64
_out="$(_run arm64 arm64)"
t_assert_eq "" "$(compgen -G "${ROOT}/1.4.357.0/x86_64")" "the x86_64 tarball prefix is gone"
t_assert_eq yes "$([ -e "${ROOT}/1.4.357.0/aarch64/lib/libvulkan.so.1" ] && echo yes)" "the image's own prefix stays"
t_assert_contains "${_out}" "removing ${ROOT}/1.4.357.0/x86_64 (LunarG tarball SDK; arm64 runs aarch64/lib/libvulkan.so.1)" \
  "and the drop names what the image runs instead"

t_case "an arm64 builder targeting amd64 keeps x86_64 -- it IS the target's"
_fixture aarch64
_out="$(_run amd64 arm64)"
t_assert_eq yes "$([ -e "${ROOT}/1.4.357.0/x86_64/lib/libvulkan.so.1" ] && echo yes)" "x86_64 survives"
t_assert_eq "" "$(printf '%s\n' "${_out}" | grep 'LunarG tarball')" "and is never announced as dropped"

t_case "a native arm64 build without its own loader keeps x86_64 rather than ship none"
_fixture aarch64 none
_run arm64 arm64 >/dev/null
t_assert_eq yes "$([ -d "${ROOT}/1.4.357.0/x86_64" ] && echo yes)" "no loader for the target, no drop"

t_summary
