#!/usr/bin/env bash
# Stubbed Android stages cover configure profiles, argument order and advisory failures, not builds or downloads.
set -u
# shellcheck source=linux/scripts/tests/script-stage-fixture.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/script-stage-fixture.sh"
declare work STEP
script_stage_fixture_init work STEP build-android.sh "${1:-}" scripts/03-media/build/iree/android scripts/01-core opt || exit 1
sed "s#/opt#${work}/opt#g" "${STEP}" > "${work}/scripts/03-media/build/iree/android/step.sh"
cat > "${work}/scripts/01-core/logging.sh" <<'STUB'
warn() { printf 'WARN:%s\n' "$*" >&2; }
STUB
cat > "${work}/scripts/03-media/build/android-build-preamble.sh" <<'STUB'
_fixture_stage() {
  printf '%s\n' "$1" >> "$FIXTURE_ROOT/events"
  [ "$FIXTURE_FAILURE" != "$1" ]
}
android_build_preamble_init() { printf '<%s>' "$@" > "$FIXTURE_ROOT/preamble"; ANDROID_ABI=arm64-v8a; ANDROID_API_LEVEL=35; }
resolve_host_compiler() { printf 'host %s' "$1"; }
media_jobs() { printf 4; }
android_cmake_target_args() {
  local -n args="$1"
  args=("-DCMAKE_TOOLCHAIN_FILE=$ANDROID_NDK_HOME/toolchain.cmake" -DANDROID_ABI=arm64-v8a -DANDROID_PLATFORM=android-35)
}
apt-get() { _fixture_stage "apt-$1"; }
git() {
  if [ "$1" = clone ]; then
    printf '<%s>' "$@" > "$FIXTURE_ROOT/clone"
    _fixture_stage clone || return 7
    mkdir -p iree-android
  else
    printf '<%s>' "$@" > "$FIXTURE_ROOT/submodules"
    _fixture_stage submodules
  fi
}
cmake() {
  local kind=configure stage=host arg
  [ "$1" != --build ] || kind=build
  for arg in "$@"; do case "$arg" in */build-android) stage=target ;; esac; done
  printf '<%s>' "$@" > "$FIXTURE_ROOT/$stage-$kind"
  if [ "$stage-$kind" = target-build ] && [ "$FIXTURE_FAILURE" = ninja-fallback ]; then return 0; fi
  _fixture_stage "$stage-$kind"
}
ninja() {
  printf '<%s>' "$@" > "$FIXTURE_ROOT/ninja"
  _fixture_stage ninja || return 7
  [ "$FIXTURE_FAILURE" != target-build ] && [ "$FIXTURE_FAILURE" != ninja-fallback ]
}
STUB
_iree_case() {
  rm -f "${work}"/{host-configure,host-build,target-configure,target-build,ninja,clone,submodules,preamble}
  : > "${work}/events"
  status=0
  output="$(env FIXTURE_ROOT="${work}" FIXTURE_FAILURE="$1" IREE_VERSION=fixture \
    ANDROID_NDK_HOME="${work}/ndk with space" IREE_ROOT_ANDROID="${work}/install tree" ANDROID_API_LEVEL=34 \
    CMAKE_POLICY_VERSION_MINIMUM=3.5 bash "${work}/scripts/03-media/build/iree/android/step.sh" 2>&1)" || status=$?
}
t_case "host and target configurations retain their complete distinct ordered argument lists"
_iree_case ''
t_assert_eq 0 "${status}" "${output}"
t_assert_eq '<Android IREE build><34>' "$(cat "${work}/preamble")"
t_assert_eq '<clone><--depth><1><-b><fixture><https://github.com/iree-org/iree.git><iree-android>' "$(cat "${work}/clone")"
t_assert_eq '<-c><submodule.third_party/llvm-project.update=none><-c><submodule.third_party/torch-mlir.update=none><-c><submodule.third_party/stablehlo.update=none><submodule><update><--init><--recursive><--depth><1>' "$(cat "${work}/submodules")"
src="${work}/opt/iree-android"
profile='<-DIREE_BUILD_COMPILER=OFF><-DIREE_BUILD_PYTHON_BINDINGS=OFF><-DIREE_BUILD_SAMPLES=OFF><-DIREE_BUILD_TESTS=OFF>'
t_assert_eq "<-GNinja><-S><${src}><-B><${src}/build-host><-DCMAKE_BUILD_TYPE=Release>${profile}<-DCMAKE_C_COMPILER=host c><-DCMAKE_CXX_COMPILER=host cxx><-DCMAKE_INSTALL_PREFIX=${src}/build-host/install>" "$(cat "${work}/host-configure")"
t_assert_eq "<--build><${src}/build-host><--target><install><--><-j4>" "$(cat "${work}/host-build")"
t_assert_eq "<-GNinja><-S><${src}><-B><${src}/build-android><-DCMAKE_TOOLCHAIN_FILE=${work}/ndk with space/toolchain.cmake><-DANDROID_ABI=arm64-v8a><-DANDROID_PLATFORM=android-35><-DCMAKE_BUILD_TYPE=Release><-DCMAKE_POLICY_VERSION_MINIMUM=3.5><-DCMAKE_POSITION_INDEPENDENT_CODE=ON><-DIREE_HOST_BIN_DIR=${src}/build-host/install/bin>${profile}<-DIREE_HAL_DRIVER_LOCAL_SYNC=ON><-DIREE_HAL_DRIVER_LOCAL_TASK=ON><-DCMAKE_INSTALL_PREFIX=${work}/install tree>" "$(cat "${work}/target-configure")"
t_assert_eq "<-C><${src}/build-android><-j4><install>" "$(cat "${work}/ninja")"
t_assert_eq $'apt-update\napt-install\nclone\nsubmodules\nhost-configure\nhost-build\ntarget-configure\nninja' "$(cat "${work}/events")"
t_assert_fails test -d "${src}"
t_assert_contains "${output}" 'ABI arm64-v8a, API 35; compiler intentionally not built'

for scenario in 'apt-update:apt deps install' 'apt-install:apt deps install' 'clone:clone fixture' \
                'submodules:submodule init' 'host-configure:host-tools configure' \
                'host-build:host-tools build' 'target-configure:target configure' 'target-build:target build/install'; do
  failure="${scenario%%:*}" diagnostic="${scenario#*:}"
  t_case "${failure}: failures remain advisory and stop subsequent stages"
  _iree_case "${failure}"
  t_assert_eq 0 "${status}" "${output}"
  t_assert_contains "${output}" "Android IREE: ${diagnostic} failed; skipping (non-gating)"
  last="${failure}"
  [ "${failure}" != target-build ] || last=target-build
  t_assert_eq "${last}" "$(tail -1 "${work}/events")"
done
t_case "a failed ninja install gets the existing serial CMake fallback"
_iree_case ninja-fallback
t_assert_eq 0 "${status}" "${output}"
t_assert_eq "<--build><${src}/build-android><--target><install><-j1>" "$(cat "${work}/target-build")"
t_assert_contains "${output}" 'runtime installed'
t_assert_fails test -d "${src}"
t_summary
