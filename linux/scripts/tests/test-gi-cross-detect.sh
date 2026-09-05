#!/usr/bin/env bash
# Tests for the host-tool detector in 03-media/.../gstreamer/common/pre-setup.sh,
# the phase that names every cross gobject-introspection wrapper the monorepo
# stage later execs. Extracted, not sourced: pre-setup.sh is a stage script that
# installs packages at top level. docs/refactoring-backlog.md CL6
#
# The subject communicates through FILE-SCOPE variables by design (its own
# header says so), so both halves of that contract read as unassigned here.
# shellcheck disable=SC2034,SC2154
set -u
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${TESTS_DIR}/test-harness.sh"
SUBJECT="${TESTS_DIR}/../03-media/build/gstreamer/common/pre-setup.sh"

_src="$(t_fn_src "${SUBJECT}" _gi_cross_detect_host_tools)" || exit 1
eval "${_src}"

# No dpkg-query: the version then comes from the pinned default, which is what a
# scratch cross stage sees.
_stub="$(mktemp -d)"
printf '#!/usr/bin/env bash\nexit 1\n' > "${_stub}/dpkg-query"
chmod +x "${_stub}/dpkg-query"
PATH="${_stub}:${PATH}"

gi_cross_wrapper_arch="riscv64"
target_triplet="riscv64-linux-gnu"
GOBJECT_INTROSPECTION_VERSION="1.99.9"
_gi_cross_detect_host_tools

t_case "every wrapper path the later phases exec is named for the target arch"
t_assert_eq "/usr/local/bin/g-ir-scanner-riscv64-cross"           "${gi_scanner_wrapper}"
t_assert_eq "/usr/bin/riscv64-linux-gnu-g-ir-scanner"             "${gi_scanner_triplet_wrapper}"
t_assert_eq "/usr/local/bin/g-ir-scanner-ldd-riscv64-cross"       "${gi_ldd_wrapper}"
t_assert_eq "/usr/local/bin/g-ir-scanner-riscv64-binary-wrapper"  "${gi_binary_wrapper}"
t_assert_eq "/usr/local/bin/meson-riscv64-exe-wrapper"            "${meson_binary_wrapper}"
t_assert_eq "/usr/local/bin/g-ir-scanner"                         "${gi_scanner_default}"
t_assert_eq "/usr/local/bin/ldd"                                  "${gi_ldd_default}"

t_case "an unqueryable gobject-introspection falls back to the pinned version"
t_assert_eq "1.99.9" "${gi_version}"

t_case "ldd always resolves to something the wrapper can exec"
t_assert_eq "0" "$(t_rc test -n "${gi_host_ldd}")"

t_case "the detector computes no host bindir/libdir any more (CL6)"
# gi_bindir/gi_libdir were assigned here and read by nothing: the .pc metadata is
# written from target_gi_bindir/target_gi_libdir, which _gi_cross_detect_target_metadata
# owns. Set-ness, not emptiness — an assignment of "" would still be dead state.
t_assert_eq "" "${gi_bindir+set}"
t_assert_eq "" "${gi_libdir+set}"

t_case "and the file-scope variable list in the header says the same thing"
t_assert_eq "0" "$(grep -c '\bgi_bindir' "${SUBJECT}")" "code and comment move together"
t_assert_eq "0" "$(grep -c '\bgi_libdir' "${SUBJECT}")"
t_assert_eq "0" "$(grep -c '\bbuild_triplet' "${SUBJECT}")" \
  "the host triplet went with them — the gi_libdir block was its only reader"

t_case "the .pc writer still reads the TARGET metadata it was always meant to"
_pc="$(t_fn_src "${SUBJECT}" _gi_cross_write_pkgconfig)" || exit 1
t_assert_contains "${_pc}" 'bindir=${target_gi_bindir}'
t_assert_contains "${_pc}" 'libdir=${target_gi_libdir}'

t_summary
