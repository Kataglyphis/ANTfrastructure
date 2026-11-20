#!/usr/bin/env bash
# Checks the ORT package path and alias rules on synthetic trees; wheel byte matching belongs to test-ort-appimage-payload.sh.
set -u
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${TESTS_DIR}/test-harness.sh"
source "${_T_SCRIPTS}/06-packaging/ort-package-proof.sh"
source "${_T_SCRIPTS}/06-packaging/ort-runtime-bundle.sh"
work="$(realpath -e "$(mktemp -d)")"
trap 'rm -rf "$work"' EXIT
root="$work/root"
lib="$root/lib"
required=(libonnxruntime.so.1 libonnxruntime_providers_shared.so libonnxruntime_providers_cuda.so)

plugin_stage() { ort_package_stage_amdgpu_licenses "$root" "$lib" "$@"; }
plugin_verify() { ort_package_verify_amdgpu "$root" "$lib" "$@"; }
assert_plugin_stage_refuses_new() {
  local path
  t_assert_fails plugin_stage "$@"
  for path in "$@"; do t_assert_fails test -e "$path"; done
  return 0
}

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

plugin_tree() {
  reset_tree
  mkdir -p "$work/image/lib" "$work/image/licenses/onnxruntime-ep-amdgpu/LICENSES" "$root/licenses"
  export ORT_AMDGPU_EP_ROOT="$work/image"
  printf 'original plugin' > "$work/image/lib/libmigraphx-ep.so"
  cp "$work/image/lib/libmigraphx-ep.so" "$lib/libmigraphx-ep.so"
  printf 'original license' > "$work/image/licenses/onnxruntime-ep-amdgpu/LICENSE"
  printf 'original transitive text' > "$work/image/licenses/onnxruntime-ep-amdgpu/LICENSES/MIT.txt"
  plugin_stage "$root/licenses/plugin" || return
  contract_original="$work/image/licenses/onnxruntime-ep-amdgpu/LICENSES/MIT.txt"
  contract_packaged="$root/licenses/plugin/onnxruntime-ep-amdgpu/LICENSES/MIT.txt"
}
plugin_proof() { plugin_verify "$root/licenses/plugin"; }


plugin_provenance_tree() {
  plugin_tree || return
  mkdir "$root/provenance" || return
  rm -f "$work/image/provenance.txt" || return
  printf 'original plugin provenance\n' > "$work/image/provenance.txt" || return
  plugin_stage "$root/licenses/source" "$root/provenance/plugin.txt" || return
  contract_original="$work/image/provenance.txt"
  contract_packaged="$root/provenance/plugin.txt"
  plugin_provenance_proof || return
  cmp "$contract_original" "$contract_packaged"
}
plugin_provenance_proof() {
  plugin_verify "$root/licenses/source" "$root/provenance/plugin.txt"
}
mutate_plugin_text() {
  local fault="$1" path="$2"
  case "$fault" in
    changed) printf changed > "$path" ;;
    missing) rm "$path" ;;
    extra) printf unexpected > "$path.extra" ;;
    empty) : > "$path" ;;
    linked)
      mv "$path" "$path.previous"
      ln -s "${path##*/}.previous" "$path" ;;
  esac
}
assert_plugin_text_faults() {
  local fixture="$1" verifier="$2" fault
  shift 2
  for fault in "$@"; do
    t_assert_ok "$fixture"
    mutate_plugin_text "$fault" "$contract_packaged"
    t_assert_fails "$verifier"
  done
  t_assert_ok "$fixture"
}
t_case 'the separate plugin and its complete original tree pass'
t_assert_ok plugin_tree
t_assert_ok plugin_proof
t_assert_ok cmp "$contract_original" "$contract_packaged"
t_case 'an in-tree provider, changed module and module link refuse'
printf stale > "$lib/libonnxruntime_providers_migraphx.so"
t_assert_fails plugin_proof
rm "$lib/libonnxruntime_providers_migraphx.so"
printf changed > "$lib/libmigraphx-ep.so"
t_assert_fails plugin_proof
rm "$lib/libmigraphx-ep.so"
ln -s "$work/image/lib/libmigraphx-ep.so" "$lib/libmigraphx-ep.so"
t_assert_fails plugin_proof
t_assert_ok plugin_tree
t_case 'every original plugin notice and the exact inventory remain required'
assert_plugin_text_faults plugin_tree plugin_proof changed missing extra
t_case 'an existing real destination refuses without being reused'
t_assert_fails plugin_stage "$root/licenses/plugin"
t_case 'escaping plugin license roots and existing destinations refuse'
mv "$root/licenses/plugin" "$work/outside-plugin"
ln -s "$work/outside-plugin" "$root/licenses/plugin"
t_assert_fails plugin_proof
t_assert_fails plugin_stage "$root/licenses/plugin"
assert_plugin_stage_refuses_new "$work/escape-new"
mkdir "$work/outside-parent"
mv "$work/outside-plugin" "$work/outside-parent/plugin"
ln -s "$work/outside-parent" "$root/escaped-licenses"
t_assert_fails plugin_verify "$root/escaped-licenses/plugin"
rm -rf "$work/outside-parent"
t_assert_ok plugin_tree
stage_fault() (
  local status=0
  local -a targets=("$root/licenses/failure")
  case "$1" in
    mkdir) mkdir() { return 43; } ;;
    cp) cp() { return 44; } ;;
    provenance)
      cp() { return 69; }
      targets=("$root/licenses/new" "$root/provenance/new.txt") ;;
  esac
  plugin_stage "${targets[@]}" >/dev/null 2>&1 || status=$?
  printf '%s\n' "$status"
)
t_case 'allocation and copying failures retain their raw statuses under a conditional caller'
t_assert_eq 43 "$(stage_fault mkdir)"
t_assert_eq 44 "$(stage_fault cp)"
t_assert_ok plugin_tree

t_case 'changed, missing and linked packaged provenance refuses'
assert_plugin_text_faults plugin_provenance_tree plugin_provenance_proof changed missing linked
for mutation in missing empty linked; do
  t_case "source provenance refuses $mutation text before writing"
  mutate_plugin_text "$mutation" "$work/image/provenance.txt"
  assert_plugin_stage_refuses_new "$root/licenses/new" "$root/provenance/new.txt"
  t_assert_ok plugin_provenance_tree
done
t_case 'existing files and dangling links refuse overwrite'
printf preserve > "$root/provenance/existing.txt"
t_assert_fails plugin_stage "$root/licenses/new" "$root/provenance/existing.txt"
t_assert_eq preserve "$(cat "$root/provenance/existing.txt")"
ln -s absent "$root/provenance/dangling.txt"
t_assert_fails plugin_stage "$root/licenses/new" "$root/provenance/dangling.txt"
t_assert_ok test -L "$root/provenance/dangling.txt"
t_case 'outside and license-tree destinations refuse before copying'
ln -s "$work" "$root/outside-provenance"
assert_plugin_stage_refuses_new "$root/licenses/new" "$root/outside-provenance/escaped.txt"
t_assert_fails plugin_stage "$root/licenses/plugin" "$root/licenses/plugin/provenance.txt"
t_assert_fails test -e "$root/licenses/plugin/provenance.txt"
t_case 'a provenance copy failure retains its raw status under a conditional caller'
t_assert_eq 69 "$(stage_fault provenance)"
t_assert_ok plugin_tree
t_case 'missing source licenses refuse before writing, including conditional callers'
rm "$work/image/licenses/onnxruntime-ep-amdgpu/LICENSE"
t_assert_fails plugin_proof
if plugin_stage "$root/licenses/missing" 2>/dev/null; then t_assert_eq refused passed; fi
t_assert_fails test -e "$root/licenses/missing"

t_case 'packaged programs must be executable regular files inside their extraction root'
printf program > "$root/program"
chmod +x "$root/program"
t_assert_ok ort_package_require_program "$root" "$root/program"
chmod -x "$root/program"
t_assert_fails ort_package_require_program "$root" "$root/program"
chmod +x "$root/program"
ln -s program "$root/program-link"
t_assert_fails ort_package_require_program "$root" "$root/program-link"
mkdir "$work/outside-bin"
cp "$root/program" "$work/outside-bin/program"
ln -s "$work/outside-bin" "$root/escaped-bin"
t_assert_fails ort_package_require_program "$root" "$root/escaped-bin/program"
t_assert_fails ort_package_require_program "$root" "$root/absent-program"

t_summary
