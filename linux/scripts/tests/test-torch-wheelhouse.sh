#!/usr/bin/env bash
# Local wheel files and stubbed builders cover orchestration, not compilation, installation or real wheel ABI validation.
set -u
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${TESTS_DIR}/test-harness.sh"
source "${TESTS_DIR}/../01-core/logging.sh"
WHEELHOUSE="${1:-${TESTS_DIR}/../05-frameworks/torch/build-app-wheelhouse.sh}"
source "${TESTS_DIR}/../05-frameworks/torch/torch-source-pins.sh"
eval "$(t_fn_src "$WHEELHOUSE" install_host_torch_for_vision)"
eval "$(t_fn_src "$WHEELHOUSE" _torch_select_max_jobs)"
for fn in build_torch_wheel build_torchvision_wheel _collect_torch_wheel _collect_torchvision_wheel parse_wheel_version; do
    eval "$(t_fn_src "$WHEELHOUSE" "$fn")"
done
for fn in _wheelhouse_build_component _build_torch_component _build_torchvision_component _wheelhouse_prepare_torch_source _wheelhouse_collect_component; do
    if grep -q "^$fn() {" "$WHEELHOUSE"; then eval "$(t_fn_src "$WHEELHOUSE" "$fn")"; fi
done
eval "$(t_fn_src "${TESTS_DIR}/../01-core/common.sh" shell_quote_args)"
_work=$(mktemp -d)
trap 'rm -rf "$_work"' EXIT

t_case "Torch honors an explicit MAX_JOBS override"
MAX_JOBS=7
t_assert_eq 7 "$MAX_JOBS"
t_assert_eq 7 "$(_torch_select_max_jobs)"
unset MAX_JOBS

t_case "Torch prefers the memory-heavy parallelism profile"
compute_cpp_heavy_jobs() { if [ "$#" -eq 1 ] && [ -z "$1" ]; then printf 'heavy'; fi; }
compute_jobs_with_mem_cap() { printf 'generic-%s-%s' "$1" "$2"; }
nproc() { printf 'cores'; }
t_assert_eq heavy "$(compute_cpp_heavy_jobs '')"
t_assert_eq heavy "$(_torch_select_max_jobs)"
unset -f compute_cpp_heavy_jobs

t_case "Torch falls back to the 4096 MB generic cap"
t_assert_eq generic--4096 "$(compute_jobs_with_mem_cap '' 4096)"
t_assert_eq generic--4096 "$(_torch_select_max_jobs)"
unset -f compute_jobs_with_mem_cap

t_case "Torch falls back to nproc when parallelism helpers are absent"
t_assert_eq cores "$(nproc)"
t_assert_eq cores "$(_torch_select_max_jobs)"

t_case "common.sh remains the single owner of parallelism loading"
t_assert_contains "$(cat "${TESTS_DIR}/../01-core/common.sh")" \
    "[ -f \"\${_COMMON_SH_DIR}/parallelism.sh\" ] && source \"\${_COMMON_SH_DIR}/parallelism.sh\""
t_assert_contains "$(cat "$WHEELHOUSE")" 'for _core_leaf in common.sh '
t_assert_contains "$(cat "$WHEELHOUSE")" '"/opt/scripts/core/${_core_leaf}"'
t_assert_eq 0 "$(grep -c 'source /opt/scripts/core/parallelism.sh' "$WHEELHOUSE" || true)"

t_case "Wheelhouse loads the shared Torch source pin resolver"
t_assert_contains "$(cat "$WHEELHOUSE")" '/torch-source-pins.sh'

t_case "Torch source pins resolve to the package version passed to uv"
_resolved="$(
    unset PYTORCH_REF TORCHVISION_REF
    PYTORCH_VERSION=v2.14.1 TORCHVISION_VERSION=v0.29.1
    export BUILD_PYTHON=fixture-python DEFAULT_PYPI_INDEX_URL=https://pypi.example/simple PYTORCH_HOST_INDEX_URL=https://torch.example/cpu
    uv() { printf '%s\n' "$*"; }
    resolve_torch_source_refs && install_host_torch_for_vision
)"
t_assert_contains "$_resolved" 'torch==2.14.1+cpu pillow'

t_case "Torch source pins have no old fallback when versions.env is absent"
_missing="$(
    unset PYTORCH_REF PYTORCH_VERSION TORCHVISION_REF TORCHVISION_VERSION
    resolve_torch_source_refs 2>&1
)"
_missing_rc=$?
t_assert_eq 1 "$_missing_rc"
t_assert_contains "$_missing" 'Torch source pin missing'

t_case "TorchVision source pins cannot be silently omitted"
_missing="$(
    unset TORCHVISION_REF TORCHVISION_VERSION
    PYTORCH_VERSION=v2.14.1 PYTORCH_REF=v2.14.1
    resolve_torch_source_refs 2>&1
)"
_missing_rc=$?
t_assert_eq 1 "$_missing_rc"
t_assert_contains "$_missing" 'TorchVision source pin missing'

t_case "A commit ref needs an explicit Torch package version"
_missing="$(
    unset PYTORCH_VERSION TORCHVISION_VERSION
    PYTORCH_REF=deadbeefdeadbeefdeadbeefdeadbeefdeadbeef TORCHVISION_REF=v0.29.1
    resolve_torch_source_refs 2>&1
)"
_missing_rc=$?
t_assert_eq 1 "$_missing_rc"
t_assert_contains "$_missing" 'Torch package version is required for a non-release source ref'

t_case "A commit ref can use an explicit package version"
_resolved="$(
    export PYTORCH_VERSION=v2.14.1 PYTORCH_REF=deadbeefdeadbeefdeadbeefdeadbeefdeadbeef TORCHVISION_REF=v0.29.1
    unset TORCHVISION_VERSION
    resolve_torch_source_refs && printf '%s|%s' "$PYTORCH_REF" "$PYTORCH_VERSION"
)"
t_assert_eq 'deadbeefdeadbeefdeadbeefdeadbeefdeadbeef|2.14.1' "$_resolved"

_assert_pin_mismatch() {
    local label="$1" torch_ref="$2" vision_ref="$3" expected="$4" mismatch rc
    t_case "$label"
    mismatch="$(
        export PYTORCH_VERSION=v2.14.1 PYTORCH_REF="$torch_ref" TORCHVISION_VERSION=v0.29.1 TORCHVISION_REF="$vision_ref"
        resolve_torch_source_refs 2>&1
    )"
    rc=$?
    t_assert_eq 1 "$rc"
    t_assert_contains "$mismatch" "$expected"
}
_assert_pin_mismatch "Torch source ref cannot disagree with its release" v2.13.0 v0.29.1 'Torch source ref and package version differ'
_assert_pin_mismatch "Numeric Torch source ref cannot disagree with its release" 2.13.0 v0.29.1 'Torch source ref and package version differ'
_assert_pin_mismatch "TorchVision source ref cannot disagree with its release" v2.14.1 v0.28.0 'TorchVision source ref and version differ'
_assert_pin_mismatch "Numeric TorchVision source ref cannot disagree with its release" v2.14.1 0.28.0 'TorchVision source ref and version differ'

src_dir=parent dist_dir=parent wheel_platform=parent python_sysconfig_export=parent cmake_args_string=parent
target_torch_include=parent target_torch_csrc=parent target_torch_lib=parent

_event() { local IFS='|'; printf '%s\n' "$*" >> "$_case_dir/events"; }
_stage_ok() {
    if [[ "$_failure" == "$1" ]]; then return 1; fi
    return 0
}
wheel_platform_tag() { _event platform; _stage_ok platform || return 7; printf linux_riscv64; }
resolve_target_python_sysconfig_export() { _event sysconfig; _stage_ok sysconfig || return 7; printf 'export FIXTURE_SYS=1'; }
git_clone_ref() {
    _event clone "$@"
    _stage_ok clone || return 7
    mkdir -p "$3"
    printf fixture > "$3/setup.py"
}
install_host_torch_for_vision() { _event host-install; _stage_ok host; }
patch_torchvision_setup() { _event patch "$1"; _stage_ok patch; }
_torch_build_host_protoc() { _event protoc; CROSS_HOST_PROTOC=fixture-protoc; }
_torch_detect_system_sleef() { _event sleef; use_system_sleef=1; }
_fixture_cmake_args() {
    local label="$1"
    local -n output="$2"
    _event "$label" "${@:3}"
    output+=('-DCASE=value with spaces')
}
_torch_cmake_args() { _fixture_cmake_args torch-cmake "$1" "$CROSS_HOST_PROTOC" "$use_system_sleef"; }
append_common_cross_cmake_args() { _fixture_cmake_args vision-cmake "$1"; }
_build_fixture_wheels() {
    local component="$1" fresh=yes
    [[ ! -e "$dist_dir/stale" ]] || fresh=no
    _event setup "$component" "$src_dir" "$dist_dir" "$wheel_platform" "$python_sysconfig_export" "$cmake_args_string" "$fresh"
    if [[ "$component" == torchvision ]]; then _event vision-paths "$target_torch_include" "$target_torch_csrc" "$target_torch_lib" "$TARGET_TORCH_VERSION"; fi
    _stage_ok setup || return 7
    if [[ "$_produce" == yes ]]; then
        printf wheel > "$dist_dir/$component-2.0.0-cp399-cp399-linux_x86_64.whl"
        printf wheel > "$dist_dir/$component-1.0.0-cp399-cp399-linux_x86_64.whl"
    fi
}
_torch_run_setup_py() { _build_fixture_wheels torch; }
_torchvision_run_setup_py() { _build_fixture_wheels torchvision; }
_torchvision_ninja_diagnostic() { _event ninja-diagnostic; }
_torch_ensure_c_extension() {
    _event repair "$1"
    _stage_ok repair || return 7
    local file
    for file in "$1"/torch-*.whl; do [[ ! -f "$file" ]] || printf repaired >> "$file"; done
}
retag_directory_wheels() {
    _event retag "$@"
    _stage_ok retag || return 7
    local file
    for file in "$1"/"$2"-*.whl; do
        [[ ! -f "$file" ]] || mv "$file" "${file%linux_x86_64.whl}$3.whl"
    done
}
cp() { _event copy "$@"; _stage_ok copy || return 7; command cp "$@"; }
extract_torch_wheel() { _event extract "$TARGET_TORCH_WHEEL" "$TARGET_TORCH_VERSION"; _stage_ok extract || return 7; TORCH_STAGING_DIR="$APP_WHEELHOUSE_BUILD_ROOT/torch-staging"; }
_torch_build_free_threaded_wheel() { _event twin "$src_dir" "$dist_dir" "$cmake_args_string" "$TARGET_TORCH_WHEEL"; _stage_ok twin || return 7; }

_reset_case() {
    _case_dir="$_work/$1 case"
    _failure="$2" _produce=yes
    mkdir -p "$_case_dir"
    : > "$_case_dir/events"
    export APP_WHEELHOUSE_BUILD_ROOT="$_case_dir/build" APP_WHEELHOUSE_DIR="$_case_dir/wheels" BUILD_PYTHON=fixture-python
    export PYTORCH_REF=fixture-torch-ref TORCHVISION_REF=fixture-vision-ref
    export TARGET_TORCH_WHEEL=seed-wheel TARGET_TORCH_VERSION=seed-version TORCH_STAGING_DIR="$_case_dir/seed"
    mkdir -p "$APP_WHEELHOUSE_DIR" "$APP_WHEELHOUSE_BUILD_ROOT/dist-torch" "$APP_WHEELHOUSE_BUILD_ROOT/dist-vision"
    printf stale > "$APP_WHEELHOUSE_BUILD_ROOT/dist-torch/stale"
    printf stale > "$APP_WHEELHOUSE_BUILD_ROOT/dist-vision/stale"
}
_run_component() {
    _rc=0
    "build_${1}_wheel" > "$_case_dir/output" 2>&1 || _rc=$?
    _out=$(cat "$_case_dir/output")
    _events=$(cat "$_case_dir/events")
}

for component in torch torchvision; do
    t_case "$component preserves preparation, flags and collection order"
    _reset_case "$component-success" none
    _run_component "$component"
    t_assert_eq 0 "$_rc" "$_out"
    t_assert_eq 'parent|parent|parent|parent|parent|parent|parent|parent' "$src_dir|$dist_dir|$wheel_platform|$python_sysconfig_export|$cmake_args_string|$target_torch_include|$target_torch_csrc|$target_torch_lib"
    if [[ "$component" == torch ]]; then
        t_assert_contains "$_events" $'platform\nsysconfig\nclone|https://github.com/pytorch/pytorch.git|fixture-torch-ref|'"$APP_WHEELHOUSE_BUILD_ROOT/pytorch"$'|--recursive|--shallow-submodules\nprotoc\nsleef\ntorch-cmake|fixture-protoc|1'
        t_assert_contains "$_events" $'repair|'"$APP_WHEELHOUSE_BUILD_ROOT/dist-torch"$'\nretag|'"$APP_WHEELHOUSE_BUILD_ROOT/dist-torch|torch|linux_riscv64|fixture-python"
        t_assert_eq "$APP_WHEELHOUSE_DIR/torch-1.0.0-cp399-cp399-linux_riscv64.whl" "$TARGET_TORCH_WHEEL"
        t_assert_eq 1.0.0 "$TARGET_TORCH_VERSION"
        t_assert_eq "$APP_WHEELHOUSE_BUILD_ROOT/torch-staging" "$TORCH_STAGING_DIR"
        t_assert_contains "$_events" $'extract|'"$TARGET_TORCH_WHEEL|1.0.0"$'\ntwin|'
        t_assert_eq wheelrepaired "$(cat "$TARGET_TORCH_WHEEL")"
    else
        t_assert_contains "$_events" $'host-install\nplatform\nsysconfig\nclone|https://github.com/pytorch/vision.git|fixture-vision-ref|'"$APP_WHEELHOUSE_BUILD_ROOT/vision"$'\npatch|'"$APP_WHEELHOUSE_BUILD_ROOT/vision/setup.py"$'\nvision-cmake'
        t_assert_contains "$_events" "vision-paths|$TORCH_STAGING_DIR/torch/include|$TORCH_STAGING_DIR/torch/include/torch/csrc/api/include|$TORCH_STAGING_DIR/torch/lib|seed-version"
        t_assert_eq seed-wheel "$TARGET_TORCH_WHEEL"
        t_assert_eq seed-version "$TARGET_TORCH_VERSION"
    fi
    t_assert_contains "$_events" '|export FIXTURE_SYS=1|-DCASE=value\ with\ spaces|yes'
    t_assert_ok test -f "$APP_WHEELHOUSE_DIR/$component-1.0.0-cp399-cp399-linux_riscv64.whl"
    t_assert_ok test -f "$APP_WHEELHOUSE_DIR/$component-2.0.0-cp399-cp399-linux_riscv64.whl"
done

for component in torch torchvision; do
    for failure in platform clone setup retag copy; do
        t_case "$component refuses failed $failure phase"
        _reset_case "$component-$failure" "$failure"
        _run_component "$component"
        t_assert_eq 1 "$_rc" "$_out"
        case "$failure" in
            platform) t_assert_eq 0 "$(grep -c '^clone|' "$_case_dir/events" || true)" ;;
            clone) t_assert_eq 0 "$(grep -c '^setup|' "$_case_dir/events" || true)" ;;
            setup) t_assert_eq 0 "$(grep -c '^retag|' "$_case_dir/events" || true)" ;;
            retag) t_assert_eq 0 "$(grep -c '^copy|' "$_case_dir/events" || true)" ;;
            copy) t_assert_eq 0 "$(grep -c '^extract|' "$_case_dir/events" || true)" ;;
        esac
        if [[ "$component" == torchvision && "$failure" == setup ]]; then t_assert_contains "$_events" ninja-diagnostic; fi
    done
    t_case "$component rejects a completed build with no matching wheel"
    _reset_case "$component-empty" none
    _produce=no
    _run_component "$component"
    t_assert_eq 1 "$_rc" "$_out"
    t_assert_contains "$_out" 'cross build completed without producing a wheel'
done

for missing in wheel staging; do
    t_case "vision missing $missing precondition precedes host installation and platform selection"
    _reset_case "vision-no-$missing" none
    if [[ "$missing" == wheel ]]; then TARGET_TORCH_WHEEL=''; else TORCH_STAGING_DIR=''; fi
    _run_component torchvision
    t_assert_eq 1 "$_rc"
    t_assert_eq '' "$_events"
done
for component in torch torchvision; do
    t_case "$component cannot clone after sysconfig resolution fails"
    _reset_case "$component-sysconfig" sysconfig
    _run_component "$component"
    t_assert_eq 7 "$_rc"
    t_assert_eq 0 "$(grep -c '^clone|' "$_case_dir/events" || true)"
done
for failure in host patch; do
    t_case "vision $failure failure stops before build setup"
    _reset_case "vision-$failure" "$failure"
    _run_component torchvision
    t_assert_eq 1 "$_rc"
    t_assert_eq 0 "$(grep -c '^setup|' "$_case_dir/events" || true)"
done
for failure in repair extract twin; do
    t_case "torch $failure failure propagates and cannot finish a later phase"
    _reset_case "torch-$failure" "$failure"
    _run_component torch
    if [[ "$failure" == twin ]]; then expected=7; else expected=1; fi
    t_assert_eq "$expected" "$_rc" "$_out"
    if [[ "$failure" == repair ]]; then t_assert_eq 0 "$(grep -c '^retag|' "$_case_dir/events" || true)"; fi
    if [[ "$failure" == extract ]]; then t_assert_eq 0 "$(grep -c '^twin|' "$_case_dir/events" || true)"; fi
done

t_summary
