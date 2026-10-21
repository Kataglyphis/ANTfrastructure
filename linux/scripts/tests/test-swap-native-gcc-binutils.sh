#!/usr/bin/env bash
# The relocated native GCC reports AR/AS under its own prefix; without these links the target build ran the host's x86 tools (2026-10-20).
set -u
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${TESTS_DIR}/test-harness.sh"
SWAP="${TESTS_DIR}/../06-packaging/swap-native-gcc.sh"

_work="$(mktemp -d)"
trap 'rm -rf "${_work}"' EXIT
mkdir -p "${_work}/bin" "${_work}/usr/bin"
for _t in as ar ld nm ranlib strip objcopy; do
  printf '#!/bin/sh\n' > "${_work}/usr/bin/riscv64-linux-gnu-${_t}"
  chmod +x "${_work}/usr/bin/riscv64-linux-gnu-${_t}"
done
# The host's own tools share the names and must never be linked in.
printf '#!/bin/sh\n' > "${_work}/usr/bin/as"
chmod +x "${_work}/usr/bin/as"
# A pre-existing entry wins: re-running the swap must not repoint it.
printf '#!/bin/sh\n' > "${_work}/bin/riscv64-linux-gnu-ar"
chmod +x "${_work}/bin/riscv64-linux-gnu-ar"

eval "$(t_fn_src "${SWAP}" _link_target_binutils)"
_link() {
  SWAP_GCC_BINDIR="${_work}/bin" SWAP_BINUTILS_DIR="${_work}/usr/bin" _link_target_binutils riscv64-linux-gnu
}

t_case "every target binutils lands in the prefix under its prefixed name"
_link
for _t in as ld nm ranlib strip objcopy; do
  t_assert_ok test -L "${_work}/bin/riscv64-linux-gnu-${_t}"
done
t_assert_eq "0" "$(readlink -f "${_work}/bin/riscv64-linux-gnu-as" | grep -c x86)" \
  "the link must point at the target's as, not the host's"

t_case "a tool that is already there is left alone"
_link
t_assert_eq "$(readlink -f "${_work}/bin/riscv64-linux-gnu-ar")" "${_work}/bin/riscv64-linux-gnu-ar" \
  "the pre-existing ar must not be replaced by a symlink"

t_case "an arch whose binutils are absent changes nothing"
SWAP_GCC_BINDIR="${_work}/bin" SWAP_BINUTILS_DIR="${_work}/usr/bin" _link_target_binutils aarch64-linux-gnu
t_assert_eq "0" "$(ls "${_work}/bin" | grep -c aarch64)" "no link without a target tool to point at"

t_summary
