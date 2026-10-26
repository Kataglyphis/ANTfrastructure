#!/usr/bin/env bash
# Pushed runtime images leave the local store after their last local reader (CON141); a stub engine records each rmi. Not covered: a real nerdctl store.
set -u
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${TESTS_DIR}/test-harness.sh"
SUBJECT="${TESTS_DIR}/../build-runtime-manifest.sh"
t_source_functions "${SUBJECT}" _manifest_drop_mode _manifest_drop_pushed_images
t_source_functions "${TESTS_DIR}/../lib-runtime-switch.sh" runtime_switch_mode
t_source_functions "${TESTS_DIR}/../01-core/build-helpers.sh" _bool_truthy is_dry_run
t_source_functions "${TESTS_DIR}/../01-core/platform.sh" is_truthy
t_source_functions "${TESTS_DIR}/../01-core/context-management.sh" runtime_pushes_wrapper_images

# The stub store holds every tag of amd64 and arm64 except arm64's push leftover.
image_exists() { if [ "$2" = img:latest-arm64-tmp-reduced-platform ]; then return 1; fi; return 0; }
remove_local_image_if_exists() { printf 'RMI %s\n' "$2"; if [ "$2" = "${REFUSE:-}" ]; then return 1; fi; return 0; }
runtime_wrapper_tag() { printf 'img:latest-%s' "$1"; }
runtime_package_tag() { printf 'img:latest-package-%s' "$1"; }
arch_list_to_words() { printf '%s' "${1//,/ }"; }
log() { printf 'LOG %s\n' "$*"; }
warn() { printf 'WARN %s\n' "$*"; }

# scenario [VAR=VAL...]: one drop in a subshell, so a case's knobs cannot leak into the next.
scenario() (
  local kv
  for kv in "$@"; do export "${kv?}"; done
  : "${TARGET_ARCHES:=amd64,arm64}" "${BUILD_IMAGES:=1}" "${PUSH_IMAGES:=1}"
  _manifest_drop_pushed_images
)

t_case "a pushed run drops each arch's wrapper, its push leftover and its package"
out="$(scenario)"
for tag in img:latest-amd64 img:latest-amd64-tmp-reduced-platform img:latest-package-amd64 img:latest-arm64 img:latest-package-arm64; do
  t_assert_contains "${out}" "RMI ${tag}"
done
t_assert_eq 0 "$(printf '%s\n' "${out}" | grep -c -e 'RMI img:latest-arm64-tmp-reduced-platform' || true)" "an absent tag is not removed"
t_assert_contains "${out}" "removed 5 pushed runtime image(s) from the local store, 0 refused"

t_case "nothing is removed without a push, on --no-push, in a dry run, or with the knob at 0"
for knobs in "PUSH_IMAGES=0" "CROSS_NO_PUSH=1" "DRY_RUN=1" "RUNTIME_DROP_PUSHED_IMAGES=0" "BUILD_IMAGES=0"; do
  out="$(scenario "${knobs}")"
  t_assert_eq 0 "$(printf '%s\n' "${out}" | grep -c -e '^RMI' || true)" "${knobs} must keep every local image"
done

t_case "a refused rmi is visible and does not fail the run"
rc=0; out="$(scenario REFUSE=img:latest-package-amd64)" || rc=$?
t_assert_eq 0 "${rc}"
t_assert_contains "${out}" "WARN [runtime-drop] img:latest-package-amd64 would not remove; it stays local"
t_assert_contains "${out}" "removed 4 pushed runtime image(s) from the local store, 1 refused"

t_case "an unknown RUNTIME_DROP_PUSHED_IMAGES stops the lane"
rc=0; out="$(scenario RUNTIME_DROP_PUSHED_IMAGES=yes 2>&1)" || rc=$?
t_assert_eq 2 "${rc}"
t_assert_contains "${out}" "RUNTIME_DROP_PUSHED_IMAGES=yes: expected 1"

t_case "main drops only after the index, and validates the knob before any build"
main_src="$(t_fn_src "${SUBJECT}" main)"
t_assert_contains "${main_src}" "_manifest_drop_mode >/dev/null || exit 2"
after_manifest="$(printf '%s\n' "${main_src}" | sed -n '/create_manifest$/,$p')"
t_assert_contains "${after_manifest}" "_manifest_drop_pushed_images" "the image-env gate inside create_manifest reads each wrapper locally"
before_build="$(printf '%s\n' "${main_src}" | sed -n '1,/_manifest_build_and_smoke$/p')"
t_assert_eq 0 "$(printf '%s\n' "${before_build}" | grep -c -e '_manifest_drop_pushed_images' || true)" "the gates after the arch loop read every wrapper locally"

t_summary
