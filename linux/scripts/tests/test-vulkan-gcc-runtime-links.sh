#!/usr/bin/env bash
# vulkan.sh's GCC runtime links: only a library of the multiarch dir's own arch may land there; see BACKLOG CON172
set -u
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${TESTS_DIR}/test-harness.sh"
VULKAN_SH="${TESTS_DIR}/../02-toolchain/vulkan.sh"

t_case "the host's x86-64 libstdc++ on LIBRARY_PATH is refused for /usr/lib/aarch64-linux-gnu, the target's own is linked"
W="$(mktemp -d)"
mkdir -p "${W}/host/lib64" "${W}/target/lib64" "${W}/root/usr/lib/aarch64-linux-gnu" "${W}/root/usr/lib"
printf host > "${W}/host/lib64/libstdc++.so"; printf host > "${W}/host/lib64/libgcc_s.so.1"
printf target > "${W}/target/lib64/libstdc++.so.6"
_out="$(bash -c "$(t_fn_src "${VULKAN_SH}" _vulkan_lib_fits_dir)
$(t_fn_src "${VULKAN_SH}" _vulkan_setup_gcc_runtime)"'
log() { printf "%s\n" "$*"; }
elf_machine_name() { case "$(cat "$1")" in host) printf "Advanced Micro Devices X86-64" ;; target) printf "AArch64" ;; esac; }
dpkg-architecture() { printf aarch64-linux-gnu; }
ldconfig() { :; }
mkdir() { command mkdir "$@"; }
ln() { printf "ln %s -> %s\n" "$3" "$2"; }
SUDO= ARCH=arm64 LIBRARY_PATH="$1/host/lib64:$1/target/lib64" _vulkan_setup_gcc_runtime' _ "${W}" 2>&1)"
t_assert_contains "${_out}" "GCC runtime: ${W}/host/lib64/libstdc++.so is not aarch64-linux-gnu's arch; not linked there (CON172)" \
  "the host library is named and skipped (the sdk stage put the host's x86-64 libstdc++ in the target dir until 2026-10-29)"
t_assert_contains "${_out}" "GCC runtime: ${W}/host/lib64/libgcc_s.so.1 is not aarch64-linux-gnu's arch" "libgcc_s too"
t_assert_contains "${_out}" "ln /usr/lib/aarch64-linux-gnu/libstdc++.so.6 -> ${W}/target/lib64/libstdc++.so.6" "the target's own library is linked"
t_assert_eq "0" "$(printf '%s\n' "${_out}" | grep -c "ln /usr/lib/aarch64-linux-gnu/libstdc++.so ")" "and nothing foreign reaches the dir"

t_case "a dir whose arch the rule does not know keeps the old behaviour"
eval "$(t_fn_src "${VULKAN_SH}" _vulkan_lib_fits_dir)"
elf_machine_name() { printf "Advanced Micro Devices X86-64"; }
t_assert_ok _vulkan_lib_fits_dir /usr/lib/x86_64-linux-gnu "${W}/host/lib64/libstdc++.so" "x86-64 into the x86-64 dir"
t_assert_fails _vulkan_lib_fits_dir /usr/lib/aarch64-linux-gnu "${W}/host/lib64/libstdc++.so" "x86-64 into the aarch64 dir"
t_assert_ok _vulkan_lib_fits_dir /usr/lib/powerpc64le-linux-gnu "${W}/host/lib64/libstdc++.so" "an arch the rule does not name is not judged"
rm -rf "${W}"
t_summary
