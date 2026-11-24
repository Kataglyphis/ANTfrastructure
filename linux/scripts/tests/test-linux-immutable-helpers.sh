#!/usr/bin/env bash
# Real ELF, CMake, TGZ and DEB fixtures prove helper transport; no finished consumer, AppRun, GPU or complete licence closure.
set -u
# shellcheck source=test-harness.sh
source "$(dirname "${BASH_SOURCE[0]}")/test-harness.sh"
ROOT="${_T_SCRIPTS%/linux/scripts}"
t_skip_unless 'Linux ELF packaging' test "$(uname -s)" = Linux
for tool in cmake cpack c++ patchelf readelf sha256sum dpkg-deb; do t_skip_unless "${tool}" command -v "${tool}"; done
# shellcheck source=../01-core/common.sh
source "${ROOT}/linux/scripts/01-core/common.sh" || exit $?
declare -F compiler_cache_launcher_env >/dev/null || exit 2
declare -F compiler_cache_launcher >/dev/null || exit 2
compiler_cache_launcher_env || exit $?
launcher="$(compiler_cache_launcher)" || exit $?
if [[ $# -eq 0 ]]; then
  work="$(mktemp -d)" || exit 2
  trap 'rm -rf -- "${work}"' EXIT
elif [[ $# -eq 2 && "$1" == --output-dir && "$2" == /* && ! -e "$2" && ! -L "$2" ]]; then
  work="$2"
  mkdir -m 0700 -- "${work}" || exit 2
else
  echo 'usage: test-linux-immutable-helpers.sh [--output-dir NEW_ABSOLUTE_DIR]' >&2
  exit 2
fi
loader="${ROOT}/linux/scripts/06-packaging/bundle-loader.sh"
keeper="${ROOT}/linux/scripts/06-packaging/patchelf-keep-glibc.sh"
fixture="${_T_SCRIPTS}/tests/fixtures/immutable-helper"

configure_helper() {
  cmake -S "${fixture}" -B "$1" -DHUB_CMAKE="${ROOT}/cmake" -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_CXX_COMPILER=c++ -DCMAKE_CXX_COMPILER_LAUNCHER="${launcher}" -DCMAKE_INSTALL_LIBDIR=lib "${@:2}"
}

install_helper() {
  cmake --install "$1" --prefix "$2"
}

build_helper() {
  configure_helper "$@" >"$1.configure.log" 2>&1 || return $?
  cmake --build "$1" --parallel 2 >"$1.build.log" 2>&1
}

stage_helper() {
  local build="$1" stage="$2"
  shift 2
  build_helper "${build}" "$@" || return $?
  install_helper "${build}" "${stage}" >"${build}.install.log" 2>&1
}

helper_verdicts() {
  local tree="$1" expected="$2" label="$3"
  t_assert_ok cmp -s "${expected}" "${tree}/lib/fixture/helper worker-bin"
  t_assert_eq "helper 42 literal ; \$value" "$(env -i LD_LIBRARY_PATH=/outside LD_BIND_NOW=1 \
    "${tree}/libexec/helper worker" 'literal ; $value' 2>&1)" "${label}: private host-loader path and argv"
  t_assert_eq 'helper 42 argument' "$(env -i KATAGLYPHIS_BUNDLED_GLIBC=1 LD_BIND_NOW=1 \
    "${tree}/libexec/helper worker" argument 2>&1)" "${label}: private bundled-loader path"
  t_assert_eq 47 "$(t_rc env -i "${tree}/libexec/helper worker" --exit47)" "${label}: host raw worker exit"
  t_assert_eq 47 "$(t_rc env -i KATAGLYPHIS_BUNDLED_GLIBC=1 "${tree}/libexec/helper worker" --exit47)" \
    "${label}: bundled raw worker exit"
}

t_case 'CMake installs a non-bin immutable helper without inventing a bin executable'
stage_helper "${work}/build" "${work}/stage" || { cat "${work}/build."*.log >&2; exit 1; }
expected="${work}/build/helper worker"
t_assert_fails test -e "${work}/stage/bin/helper worker"
helper_verdicts "${work}/stage" "${expected}" staged
mv "${work}/stage" "${work}/relocated bundle" || exit 1
helper_verdicts "${work}/relocated bundle" "${expected}" relocated

t_case 'the generated AppImage patcher preserves helper bytes while still patching unrelated files'
patcher="$(cat "${work}/build/patchelf-path")"
payload="${work}/relocated bundle/lib/fixture/helper worker-bin"
t_assert_ok "${patcher}" --set-rpath changed "${payload}"
t_assert_ok cmp -s "${expected}" "${payload}"
cp "${expected}" "${work}/unrelated" || exit 1
t_assert_ok "${patcher}" --set-rpath 'helper worker-bin' "${work}/unrelated"
t_assert_contains "$(patchelf --print-rpath "${work}/unrelated")" 'helper worker-bin' 'a flag value is not a preserved file'
t_assert_fails cmp -s "${expected}" "${work}/unrelated"

t_case 'both real archive generators retain the original helper and working loader paths'
mkdir "${work}/packages" "${work}/tar" "${work}/deb" || exit 1
cpack --config "${work}/build/CPackConfig.cmake" -B "${work}/packages" >"${work}/cpack.log" 2>&1 || {
  cat "${work}/cpack.log" >&2; exit 1;
}
shopt -s nullglob
archives=("${work}/packages/"*.tar.gz)
debs=("${work}/packages/"*.deb)
t_assert_eq 1 "${#archives[@]}" 'one actual TGZ'
t_assert_eq 1 "${#debs[@]}" 'one actual DEB'
[ "${#archives[@]}" -eq 1 ] && [ "${#debs[@]}" -eq 1 ] || exit 1
tar -xzf "${archives[0]}" -C "${work}/tar" --strip-components=1 || exit 1
dpkg-deb -x "${debs[0]}" "${work}/deb" || exit 1
helper_verdicts "${work}/tar/usr" "${expected}" TGZ
helper_verdicts "${work}/deb/usr" "${expected}" DEB

t_case 'external host SDK paths remain explicit and preserve nonempty argument boundaries'
stage_helper "${work}/external-build" "${work}/external-stage" -DEXTERNAL_PATHS=ON || exit 1
for mode in host bundled; do
  force=()
  [ "${mode}" != bundled ] || force+=(KATAGLYPHIS_BUNDLED_GLIBC=1)
  t_assert_eq 'helper 42 --external' "$(env -i "${force[@]}" LD_LIBRARY_PATH="::${work}/external-build::" \
    "${work}/external-stage/libexec/helper worker" --external 2>&1)" "${mode}: opted-in SDK DSO"
done
external_patcher="$(cat "${work}/external-build/patchelf-path")"
cp "${expected}" "${work}/libmigraphx-ep.so" || exit 1
t_assert_ok "${external_patcher}" --set-rpath changed "${work}/libmigraphx-ep.so"
t_assert_ok cmp -s "${expected}" "${work}/libmigraphx-ep.so"
t_assert_ok "${external_patcher}" --set-rpath changed "${work}/external-stage/lib/fixture/helper worker-bin"
t_assert_ok cmp -s "${work}/external-build/helper worker" "${work}/external-stage/lib/fixture/helper worker-bin"

t_case 'same-policy reruns are idempotent and policy changes require fresh executable staging'
hash="$(sha256sum < "${payload}")"
t_assert_ok bash "${loader}" --preserve-bytes "${work}/relocated bundle" "${work}/relocated bundle/lib/fixture" 'libexec/helper worker'
t_assert_eq "${hash}" "$(sha256sum < "${payload}")" 'payload stays unchanged'
t_assert_fails bash "${loader}" "${work}/relocated bundle" "${work}/relocated bundle/lib/fixture" 'libexec/helper worker'

t_case 'beside mode preserves original bytes and executes on both loader branches'
mkdir -p "${work}/beside/lib" || exit 1
cp "${expected}" "${work}/beside/worker" || exit 1
cp -L "${work}/relocated bundle/lib/fixture/"*.so* "${work}/beside/lib/" || exit 1
t_assert_ok bash "${loader}" --preserve-bytes --beside "${work}/beside" "${work}/beside/lib" worker
t_assert_ok cmp -s "${expected}" "${work}/beside/worker.bin"
t_assert_eq 'helper 42 argument' "$(env -i "${work}/beside/worker" argument 2>&1)" 'beside host loader'
t_assert_eq 'helper 42 argument' "$(env -i KATAGLYPHIS_BUNDLED_GLIBC=1 "${work}/beside/worker" argument 2>&1)" 'beside bundled loader'

t_case 'unsafe or colliding helper selections fail at configure time'
for path in '/outside/worker' '../worker' 'lib/../worker' 'lib/worker;other/worker' 'libexec/helper worker'; do
  t_assert_fails configure_helper "${work}/bad-${RANDOM}" "-DEXTRA_HELPERS=${path}"
done
t_assert_fails configure_helper "${work}/no-loader" -DNO_LOADER=ON
for directory in '/outside/lib' '../lib' 'lib/../private' 'lib/'; do
  t_assert_fails configure_helper "${work}/bad-dir-${RANDOM}" "-DCMAKE_INSTALL_LIBDIR=${directory}"
done

t_case 'a successful closure that changed helper bytes cannot produce a passed install'
build_helper "${work}/corrupt-build" -DCORRUPT_CLOSURE=ON || exit 1
t_assert_fails install_helper "${work}/corrupt-build" "${work}/corrupt-stage"

t_case 'a pre-existing native payload is preserved rather than overwritten'
mkdir -p "${work}/collision/lib" || exit 1
cp "${expected}" "${work}/collision/worker" || exit 1
printf 'existing payload\n' >"${work}/collision/lib/worker-bin"
t_assert_fails bash "${loader}" --preserve-bytes "${work}/collision" "${work}/collision/lib" worker
t_assert_eq 'existing payload' "$(cat "${work}/collision/lib/worker-bin")" 'existing destination unchanged'
t_assert_ok cmp -s "${expected}" "${work}/collision/worker"

t_case 'a successful move with changed bytes cannot publish a launcher'
mkdir -p "${work}/bad-move/bin" "${work}/bad-move/bundle/lib" || exit 1
cp "${fixture}/corrupt-move.sh" "${work}/bad-move/bin/mv" || exit 1
chmod 0755 "${work}/bad-move/bin/mv" || exit 1
cp "${expected}" "${work}/bad-move/bundle/worker" || exit 1
t_assert_fails env REAL_MV_PATH="$(command -v mv)" PATH="${work}/bad-move/bin:${PATH}" \
  bash "${loader}" --preserve-bytes "${work}/bad-move/bundle" "${work}/bad-move/bundle/lib" worker
t_assert_fails test -e "${work}/bad-move/bundle/worker"

t_case 'legacy RPATH and linked helper inputs cannot satisfy immutable transport'
mkdir -p "${work}/bad-input/lib" || exit 1
cp "${expected}" "${work}/bad-input/worker" || exit 1
patchelf --force-rpath --set-rpath /unproven "${work}/bad-input/worker" || exit 1
t_assert_fails bash "${loader}" --preserve-bytes "${work}/bad-input" "${work}/bad-input/lib" worker
ln -s "${expected}" "${work}/bad-input/linked" || exit 1
t_assert_fails bash "${loader}" --preserve-bytes "${work}/bad-input" "${work}/bad-input/lib" linked
t_assert_fails bash "${loader}" --preserve-bytes "${work}/bad-input" "${work}/outside-lib" worker
t_assert_fails test -e "${work}/outside-lib"
cp "${expected}" "${work}/bad-input/not-executable" || exit 1
chmod 0644 "${work}/bad-input/not-executable" || exit 1
t_assert_fails bash "${loader}" --preserve-bytes "${work}/bad-input" "${work}/bad-input/lib" not-executable
mkdir "${work}/outside-executable" || exit 1
cp "${expected}" "${work}/outside-executable/worker" || exit 1
t_assert_fails bash "${loader}" --preserve-bytes "${work}/bad-input" "${work}/bad-input/lib" '../outside-executable/worker'
t_assert_ok cmp -s "${expected}" "${work}/outside-executable/worker"
cp "${expected}" "${work}/bad-input/link-target" || exit 1
ln -s "${work}/bad-input/link-target" "${work}/bad-input/internal-linked" || exit 1
t_assert_fails bash "${loader}" --preserve-bytes "${work}/bad-input" "${work}/bad-input/lib" internal-linked

t_case 'preserved basenames are literal values and malformed names refuse'
for name in /outside ../worker . .. ''; do
  t_assert_eq 2 "$(t_rc bash "${keeper}" --keep-name "${name}" --set-rpath x /unused)" 'invalid basename'
done
t_assert_eq 1 "$(t_rc env KATAGLYPHIS_PATCHELF="$(command -v false)" bash "${keeper}" \
  --keep-name unselected --set-rpath x "${expected}")" 'unselected patchelf raw failure'
t_summary
