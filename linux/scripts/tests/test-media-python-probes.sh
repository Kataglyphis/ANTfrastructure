#!/usr/bin/env bash
# Extracted caller receipts cover ordered optional probes and binding decisions, not target Python execution or real builds.
set -euo pipefail
# shellcheck source=linux/scripts/tests/media-probe-fixture.sh
source "$(dirname "${BASH_SOURCE[0]}")/media-probe-fixture.sh"
t_source_functions "$repo/linux/scripts/03-media/build/gstreamer/common/setup-gstreamer.sh" _gst_xpy_resolve_target_paths
t_source_functions "$repo/linux/scripts/03-media/build/opencv/build-opencv.sh" _opencv_cmake_python_opts
mkdir -p "$work/include" "$work/numpy"
export probe_trace="$work/probes"
cross_target_triplet() { printf triplet; }
cross_target_python_include_dir() { media_probe_answer include "$work/include" "$mode" "$probe_trace"; }
cross_target_python_library() { media_probe_answer library "$work/libpython.so" "$mode" "$probe_trace"; }
cross_target_python_pkgconfig_dir() { media_probe_answer pkgconfig "$work/pkgconfig" "$mode" "$probe_trace"; }
setup_host_python_environment() { :; }
uv() { printf 'uv:%s\n' "$*" >> "$probe_trace"; }
python_module_include() { printf 'numpy\n' >> "$probe_trace"; printf '%s' "$work/numpy"; }
HOST_PYTHON='/host python'; export OPENCV_PYTHON_VERSION=3.99 WITH_PYTHON
for caller in gst opencv; do
  for mode in ready empty partial absent disabled native; do
    t_case "$caller $mode retains values, status, argv and probe sequence"
    : > "$probe_trace"
    target_python_include=previous-include; target_python_library=previous-library; target_python_pkgconfig_dir=previous-pkgconfig
    WITH_PYTHON=true; [ "$mode" != disabled ] || WITH_PYTHON=false
    if [ "$mode" = absent ]; then media_probe_hide_commands cross_target_python_include_dir cross_target_python_library cross_target_python_pkgconfig_dir; fi
    rc=0; args=()
    if [ "$caller" = gst ]; then
      _gst_xpy_resolve_target_paths > "$work/out" 2>&1 || rc=$?
      expected_rc=0; [ "$mode" != empty ] || expected_rc=1
      t_assert_eq "$expected_rc" "$rc"
      expected="$work/include|$work/libpython.so|$work/pkgconfig"
      [ "$mode" != empty ] || expected='||'
      [ "$mode" != absent ] || expected='previous-include|previous-library|previous-pkgconfig'
      t_assert_eq "$expected" "$target_python_include|$target_python_library|$target_python_pkgconfig_dir"
      trace=$'include\nlibrary\npkgconfig'; [ "$mode" != absent ] || trace=''
      t_assert_eq "$trace" "$(cat "$probe_trace")"
    else
      _opencv_cmake_python_opts args > "$work/out" 2>&1 || rc=$?
      t_assert_eq 0 "$rc"
      expected="<-DPYTHON3_EXECUTABLE=$HOST_PYTHON>"
      trace=$'uv:pip install numpy wheel\nlibrary\ninclude\nnumpy'
      case "$mode" in
        ready|partial) expected+=$'\n'"<-DPYTHON3_LIBRARY=$work/libpython.so>"$'\n'"<-DPYTHON3_INCLUDE_DIR=$work/include>" ;;
        absent) trace=$'uv:pip install numpy wheel\nnumpy' ;;
        disabled) expected=''; trace='' ;;
        native) trace='uv:pip install numpy wheel' ;;
      esac
      case "$mode" in disabled|native) ;; *) expected+=$'\n'"<-DPYTHON3_NUMPY_INCLUDE_DIRS=$work/numpy>" ;; esac
      actual=''; [ "${#args[@]}" -eq 0 ] || actual="$(printf '<%s>\n' "${args[@]}")"
      t_assert_eq "$expected" "$actual"
      t_assert_eq "$trace" "$(cat "$probe_trace")"
    fi
    media_probe_record python "$caller" "$mode" "$rc" "$target_python_include|$target_python_library|$target_python_pkgconfig_dir" "$(cat "$probe_trace")" "$(cat "$work/out")" "${args[@]}"
    media_probe_restore_commands
  done
done
t_case 'quiet failed probes retain partial stdout under active errexit in both build callers'
cat > "$work/direct.sh" <<'BASH'
set -euo pipefail
work=$1
mode=partial
probe_trace="$work/direct.trace"
WITH_PYTHON=true
HOST_PYTHON='/host python'
OPENCV_PYTHON_VERSION=3.99
target_python_include=''; target_python_library=''; target_python_pkgconfig_dir=''
BASH
t_emit_optional_functions media_probe_answer cross_collect_python_dev_paths cross_capture_python_dev_path cross_python_provider_api_ready _gst_xpy_resolve_target_paths _opencv_cmake_python_opts cross_target_triplet cross_target_python_include_dir cross_target_python_library cross_target_python_pkgconfig_dir setup_host_python_environment uv python_module_include cross_build_is_active >> "$work/direct.sh"
cat >> "$work/direct.sh" <<'BASH'
_gst_xpy_resolve_target_paths
args=()
_opencv_cmake_python_opts args >/dev/null
printf '%s\n' "$target_python_include|$target_python_library|$target_python_pkgconfig_dir" "${args[@]}"
BASH
out=''; rc=0
t_capture_command out rc bash "$work/direct.sh" "$work"
t_assert_eq 0 "$rc"
t_assert_contains "$out" "$work/include|$work/libpython.so|$work/pkgconfig"
t_assert_contains "$out" "-DPYTHON3_LIBRARY=$work/libpython.so"
media_probe_record direct "$rc" "$out"
t_case 'shared fake probes distinguish failed partial output from a failed empty response'
t_capture_command out rc media_probe_answer fixture payload partial "$work/protocol"
t_assert_eq 8 "$rc"
t_assert_eq payload "$out"
t_capture_command out rc media_probe_answer fixture payload empty "$work/protocol"
t_assert_eq 7 "$rc"
t_assert_eq '' "$out"
media_probe_record protocol "$rc" "$out"
t_summary
