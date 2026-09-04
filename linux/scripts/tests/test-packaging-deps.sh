#!/usr/bin/env bash
# ensure_appimagetool's install mode. appimagetool is an AppImage: it reads
# /proc/self/exe for its own squashfs offset, so executable-but-unreadable is a
# tool that works for root and for nobody else.
# docs/consumer-image-contract.md#the-contract
set -u
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${TESTS_DIR}/test-harness.sh"
SUBJECT="${TESTS_DIR}/../02-toolchain/packaging-deps.sh"

t_case "the downloaded tool is made readable, not merely executable"
# mktemp creates 0600; `chmod +x` on that yields 0711, which travels through mv.
_tmp="$(mktemp)"; chmod 0600 "${_tmp}"
chmod +x "${_tmp}"
t_assert_eq "711" "$(stat -c '%a' "${_tmp}")" "this is what the old line produced"
chmod 0755 "${_tmp}"
t_assert_eq "755" "$(stat -c '%a' "${_tmp}")" "and this is what a consumer can read"
rm -f "${_tmp}"

t_case "ensure_appimagetool sets an explicit mode"
_src="$(t_fn_src "${SUBJECT}" ensure_appimagetool)"
t_assert_contains "${_src}" 'chmod 0755 "$tmpfile"' \
  "an explicit mode, because the umask and mktemp decide the rest otherwise"
t_assert_eq 0 "$(printf '%s\n' "${_src}" | grep -c 'chmod +x "\$tmpfile"')" \
  "chmod +x preserves mktemp's 0600 for group and other"

t_summary
