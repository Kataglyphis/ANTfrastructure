#!/usr/bin/env bash
# Checks the ORT package path and alias rules on synthetic trees; wheel byte matching belongs to test-ort-appimage-payload.sh.
set -u
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${TESTS_DIR}/test-harness.sh"
source "${_T_SCRIPTS}/06-packaging/ort-package-proof.sh"
work="$(realpath -e "$(mktemp -d)")"
trap 'rm -rf "$work"' EXIT
root="$work/root"
lib="$root/lib"
required=(libonnxruntime.so.1 libonnxruntime_providers_shared.so libonnxruntime_providers_cuda.so)

reset_tree() {
  rm -rf "$root"
  mkdir -p "$lib" "$root/notices" "$work/proof"
  local name
  for name in "${required[@]}"; do printf x > "$lib/$name"; done
  ln -s libonnxruntime.so.1 "$lib/libonnxruntime.so"
  printf license > "$root/notices/LICENSE"
  printf notices > "$root/notices/ThirdPartyNotices.txt"
  cp "$root/notices/LICENSE" "$root/notices/ThirdPartyNotices.txt" "$work/proof/"
}

collect() {
  collected=()
  ort_package_collect_libraries "$@" "$root" "$lib" collected "${required[@]}"
}

notices() { ort_package_verify_notices "$root" "$root/notices" "$work/proof"; }

t_case 'a clean tree yields every library and passes its notices'
reset_tree
t_assert_ok collect
t_assert_eq 8 "${#collected[@]}"
t_assert_contains "${collected[*]}" "--library $lib/libonnxruntime_providers_cuda.so"
t_assert_ok notices

t_case 'a dangling entry is skipped by default and refused when asked'
ln -s absent "$lib/libonnxruntime.so.9"
t_assert_ok collect
t_assert_fails collect --reject-invalid
reset_tree

t_case 'a linked core is accepted by default and refused when asked'
t_assert_fails collect --reject-links
rm "$lib/libonnxruntime.so"
t_assert_ok collect --reject-links

t_case 'a required library that is missing fails, even in a conditional caller'
reset_tree
rm "$lib/libonnxruntime_providers_cuda.so"
if collect --reject-invalid 2>/dev/null; then t_assert_eq 'refused' 'passed'; fi
t_assert_fails collect

t_case 'an escaping library, a linked provider and a core alias fail'
reset_tree
printf x > "$work/outside.so"
ln -s "$work/outside.so" "$lib/libonnxruntime_extra.so"
t_assert_fails collect
rm "$lib/libonnxruntime_extra.so"
rm "$lib/libonnxruntime_providers_cuda.so"
ln -s libonnxruntime_providers_shared.so "$lib/libonnxruntime_providers_cuda.so"
t_assert_fails collect
reset_tree
rm "$lib/libonnxruntime.so"
ln -s libonnxruntime_providers_shared.so "$lib/libonnxruntime.so"
t_assert_fails collect

t_case 'a changed, linked, missing or escaping notice fails'
reset_tree
printf changed > "$root/notices/LICENSE"
t_assert_fails notices
reset_tree
mv "$root/notices/LICENSE" "$root/notices/LICENSE.real"
t_assert_fails notices
ln -s LICENSE.real "$root/notices/LICENSE"
t_assert_fails notices
reset_tree
mv "$root/notices" "$work/notices-outside"
ln -s "$work/notices-outside" "$root/notices"
t_assert_fails notices
rm -rf "$work/notices-outside"

t_summary
