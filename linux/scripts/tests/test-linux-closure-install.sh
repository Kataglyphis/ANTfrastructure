#!/usr/bin/env bash
# kataglyphis_install_linux_closure (cmake/CPackCommon.cmake) on a real three-file project: what it bundles, patches and leaves alone.
set -u
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${TESTS_DIR}/test-harness.sh"
CMAKE_MODULES="$(cd "${TESTS_DIR}/../../../cmake" && pwd)"

for _tool in cmake c++ patchelf readelf; do t_skip_unless "${_tool}" command -v "${_tool}"; done

_work="$(mktemp -d)"
trap 'rm -rf "${_work}"' EXIT

# libvendor stands in for the chain ORT: prebuilt outside the project, found only through SEARCH.
mkdir -p "${_work}/vendor" "${_work}/src"
printf 'int vendor_value() { return 41; }\n' > "${_work}/vendor/vendor.cpp"
c++ -shared -fPIC -Wl,-soname,libvendor.so.1 -o "${_work}/vendor/libvendor.so.1" "${_work}/vendor/vendor.cpp"
cat > "${_work}/src/core.cpp" <<'EOF'
#include <string>
int vendor_value();
std::string core_greeting() { return std::to_string(vendor_value() + 1); }
EOF
cat > "${_work}/src/app.cpp" <<'EOF'
#include <iostream>
#include <string>
std::string core_greeting();
int main() { std::cout << "closure-ok " << core_greeting() << '\n'; }
EOF
_project() {
  cat > "${_work}/src/CMakeLists.txt" <<EOF
cmake_minimum_required(VERSION 3.25)
project(fixture CXX)
list(APPEND CMAKE_MODULE_PATH "${CMAKE_MODULES}")
include(CPackCommon)
add_library(vendor SHARED IMPORTED)
set_target_properties(vendor PROPERTIES IMPORTED_LOCATION "${_work}/vendor/libvendor.so.1" IMPORTED_SONAME libvendor.so.1)
add_library(core SHARED core.cpp)
target_link_libraries(core PRIVATE vendor)
add_executable(app app.cpp)
target_link_libraries(app PRIVATE core \${CMAKE_DL_LIBS})
add_executable(demo app.cpp)
target_link_libraries(demo PRIVATE core \${CMAKE_DL_LIBS})
install(TARGETS app demo core)
kataglyphis_install_linux_closure(PRIVATE_DIR fixture TARGETS app demo core missing_target SEARCH "${_work}/vendor" $1)
EOF
}
_install() {
  rm -rf "${_work}/build" "${_work}/stage"
  cmake -S "${_work}/src" -B "${_work}/build" -DCMAKE_BUILD_TYPE=Release >/dev/null || return 1
  cmake --build "${_work}/build" >/dev/null || return 1
  cmake --install "${_work}/build" --prefix "${_work}/stage" >/dev/null 2>&1
}
_runpath() { readelf -d "$1" | sed -n 's/.*(RUNPATH).*\[\(.*\)\]/\1/p'; }

t_case "the compiler's libstdc++ and the SEARCH library land in lib/<PRIVATE_DIR>, glibc does not"
_project 'PROTECT "lib/fixture/libvendor*"'
t_assert_ok _install
t_assert_ok test -f "${_work}/stage/lib/fixture/libstdc++.so.6"
t_assert_ok test -f "${_work}/stage/lib/fixture/libvendor.so.1"
t_assert_fails test -e "${_work}/stage/lib/fixture/libc.so.6"
t_assert_fails test -e "${_work}/stage/lib/libstdc++.so.6"

t_case "RUNPATHs point at the project's own lib/ and the private dir, relative to \$ORIGIN"
t_assert_contains "$(_runpath "${_work}/stage/bin/app")" '$ORIGIN/../lib' "app finds libcore"
t_assert_contains "$(_runpath "${_work}/stage/bin/app")" '$ORIGIN/../lib/fixture' "app finds libstdc++"
t_assert_contains "$(_runpath "${_work}/stage/lib/libcore.so")" '$ORIGIN/fixture' "libcore finds libvendor"

t_case "a PROTECT file is copied byte for byte, never patched"
t_assert_ok cmp -s "${_work}/vendor/libvendor.so.1" "${_work}/stage/lib/fixture/libvendor.so.1"

t_case "the installed tree runs from anywhere, with the bundled libraries"
mv "${_work}/stage" "${_work}/moved"
t_assert_eq "closure-ok 42" "$(env -i LD_BIND_NOW=1 "${_work}/moved/bin/app" 2>&1)" "relocated app runs"
t_assert_eq "${_work}/moved/lib/fixture/libstdc++.so.6" \
  "$(env -i ldd "${_work}/moved/bin/app" | awk '$1 == "libstdc++.so.6" { print $3 }' | xargs realpath)" "libstdc++ is the bundled one"
mv "${_work}/moved" "${_work}/stage"

t_case "SYSTEM keeps a library out: the package's Depends bring it"
_project 'SYSTEM "libvendor.so.*"'
t_assert_ok _install
t_assert_fails test -e "${_work}/stage/lib/fixture/libvendor.so.1"
t_assert_ok test -f "${_work}/stage/lib/fixture/libstdc++.so.6"

t_case "an embedded project adds no closure: it would rewrite its parent's install tree"
_project 'PROTECT "lib/fixture/libvendor*"'
mkdir -p "${_work}/parent"
printf 'cmake_minimum_required(VERSION 3.25)\nproject(parent CXX)\nadd_subdirectory("%s" fixture)\n' "${_work}/src" > "${_work}/parent/CMakeLists.txt"
rm -rf "${_work}/pbuild" "${_work}/pstage"
cmake -S "${_work}/parent" -B "${_work}/pbuild" >/dev/null && cmake --build "${_work}/pbuild" >/dev/null &&
  cmake --install "${_work}/pbuild" --prefix "${_work}/pstage" >/dev/null 2>&1
t_assert_ok test -f "${_work}/pstage/bin/app"
t_assert_fails test -e "${_work}/pstage/lib/fixture"

t_case "LOADER: a launcher takes the executable's place; glibc travels apart from lib/, with the loader"
_project 'LOADER PROTECT "lib/fixture/libvendor*"'
t_assert_ok _install
t_assert_eq "#!/bin/bash" "$(head -1 "${_work}/stage/bin/app")" "bin/app is the launcher"
t_assert_ok test -f "${_work}/stage/lib/fixture/app"
t_assert_ok test -f "${_work}/stage/lib/fixture/glibc/libc.so.6"
# A host loader would find it through the RUNPATH and mix two glibcs.
t_assert_fails test -e "${_work}/stage/lib/fixture/libc.so.6"
t_assert_eq 1 "$(find "${_work}/stage/lib/fixture" -name 'ld-linux*' | wc -l)" "the loader travels"
t_assert_eq "${_work}/stage/lib/fixture/libstdc++.so.6" \
  "$(env -i ldd "${_work}/stage/lib/fixture/app" | awk '$1 == "libstdc++.so.6" { print $3 }' | xargs realpath)" \
  "the moved program's own RUNPATH finds the bundled libstdc++, launcher or not"
mv "${_work}/stage" "${_work}/moved"
t_assert_eq "closure-ok 42" "$(env -i LD_BIND_NOW=1 "${_work}/moved/bin/app" 2>&1)" "relocated launcher runs"
t_assert_eq "closure-ok 42" "$(env -i KATAGLYPHIS_BUNDLED_GLIBC=1 LD_BIND_NOW=1 "${_work}/moved/bin/app" 2>&1)" \
  "relocated launcher runs through the bundled loader too"
t_assert_eq "#!/bin/bash" "$(head -1 "${_work}/moved/bin/demo")" "the second executable is also a launcher"
t_assert_eq "closure-ok 42" "$(env -i LD_BIND_NOW=1 "${_work}/moved/bin/demo" 2>&1)" "second launcher runs on the host loader"
t_assert_eq "closure-ok 42" "$(env -i KATAGLYPHIS_BUNDLED_GLIBC=1 LD_BIND_NOW=1 "${_work}/moved/bin/demo" 2>&1)" \
  "second launcher also runs through the bundled loader"
mv "${_work}/moved" "${_work}/stage"

t_case "--beside: data/ beside /proc/self/exe is found on both paths, argv[0] stays, no child is left behind; a rerun changes nothing"
_loader="${CMAKE_MODULES}/../linux/scripts/06-packaging/bundle-loader.sh"
# <dir> <exe> [loader options]: stages a --beside launcher twice, since a rerun must change nothing.
_beside_twice() {
  local dir="${_work}/$1" exe="$2"
  shift 2
  t_assert_ok bash "${_loader}" --beside "$@" "${dir}" "${dir}/lib" "${exe}"
  t_assert_ok bash "${_loader}" --beside "$@" "${dir}" "${dir}/lib" "${exe}"
}
mkdir -p "${_work}/beside/lib" "${_work}/beside/data"
cat > "${_work}/runner.cpp" <<'EOF'
#include <sys/wait.h>
#include <filesystem>
#include <iostream>
int main(int, char **argv) {
  auto exe = std::filesystem::read_symlink("/proc/self/exe");
  std::cout << (std::filesystem::is_directory(exe.parent_path() / "data") ? "data-found" : "data-missing") << ' '
            << exe.filename().string() << ' ' << std::filesystem::path(argv[0]).filename().string() << ' '
            << (waitpid(-1, nullptr, WNOHANG) == -1 ? "no-child" : "stray-child") << '\n';
}
EOF
c++ -std=c++17 -o "${_work}/beside/runner" "${_work}/runner.cpp"
_beside_twice beside runner
t_assert_ok test -f "${_work}/beside/runner.bin"
t_assert_ok test -f "${_work}/beside/lib/glibc/libc.so.6"
t_assert_eq "data-found runner.bin runner no-child" "$(env -i "${_work}/beside/runner")" \
  "a host glibc as new as the bundled one runs the program itself, under the launcher's name"
_bundled="$(env -i KATAGLYPHIS_BUNDLED_GLIBC=1 "${_work}/beside/runner")"
t_assert_contains "${_bundled}" "data-found ld-linux" "KATAGLYPHIS_BUNDLED_GLIBC=1 starts it through the bundled loader"
t_assert_contains "${_bundled}" " runner no-child" "and keeps argv[0] there too, with no child of the launcher's left"
sed 's/-ge [0-9][0-9]* \]/-ge 999 ]/' "${_work}/beside/runner" > "${_work}/beside/runner-old-host"
sed 's#$("[^"]*" --version#$("/nonexistent/ld.so" --version#' "${_work}/beside/runner" > "${_work}/beside/runner-no-loader"
chmod +x "${_work}/beside/runner-old-host" "${_work}/beside/runner-no-loader"
t_assert_contains "$(env -i "${_work}/beside/runner-old-host")" "data-found ld-linux" "an older host glibc takes the bundled loader"
t_assert_contains "$(env -i "${_work}/beside/runner-no-loader")" "data-found ld-linux" "so does a host without that loader"

t_case "--gcc-unwinder: the bundled libgcc_s owns _Unwind_RaiseException on both paths, only the host path exports LD_PRELOAD"
mkdir -p "${_work}/unwind/lib"
printf 'void _Unwind_RaiseException(void) {}\n' > "${_work}/fake-unwind.c"
cc -shared -fPIC -o "${_work}/unwind/lib/libfakeunwind.so" "${_work}/fake-unwind.c"
cp -L "$(c++ -print-file-name=libgcc_s.so.1)" "${_work}/unwind/lib/libgcc_s.so.1"
c++ -std=c++17 -o "${_work}/unwind/plain" "$(dirname "${BASH_SOURCE[0]}")/fixtures/unwinder-owner.cpp" -Wl,--no-as-needed -L"${_work}/unwind/lib" -lfakeunwind -Wl,-rpath,'$ORIGIN/lib'
cp "${_work}/unwind/plain" "${_work}/unwind/fixed"
t_assert_eq "libfakeunwind.so preload-unset" "$(env -i "${_work}/unwind/plain")" "the fixture's earlier library wins the lookup, as Flutter's engine does"
_beside_twice unwind plain
_beside_twice unwind fixed --gcc-unwinder
t_assert_eq "libfakeunwind.so preload-unset" "$(env -i "${_work}/unwind/plain")" "without the option the launcher changes nothing"
t_assert_eq "libgcc_s.so.1 preload-exported" "$(env -i "${_work}/unwind/fixed")" "the host path preloads the bundled unwinder"
t_assert_eq "libgcc_s.so.1 preload-unset" "$(env -i KATAGLYPHIS_BUNDLED_GLIBC=1 "${_work}/unwind/fixed")" \
  "the bundled loader preloads it without handing LD_PRELOAD to host children"
t_assert_contains "$(env -i LD_PRELOAD=/nonexistent/keep.so "${_work}/unwind/fixed" 2>&1)" "libgcc_s.so.1 preload-exported" "a caller's LD_PRELOAD is kept behind it"
t_assert_contains "$(bash "${_loader}" --beside "${_work}/unwind" "${_work}/unwind/lib" fixed 2>&1)" "different unwinder policy"
t_assert_contains "$(bash "${_loader}" --beside --gcc-unwinder "${_work}/unwind" "${_work}/unwind/lib" plain 2>&1)" "different unwinder policy"
mkdir -p "${_work}/no-unwind/lib"
cp "${_work}/unwind/plain.bin" "${_work}/no-unwind/runner"
t_assert_contains "$(bash "${_loader}" --beside --gcc-unwinder "${_work}/no-unwind" "${_work}/no-unwind/lib" runner 2>&1)" "--gcc-unwinder needs a regular"
t_assert_ok test -f "${_work}/no-unwind/runner"

t_case "the AppImage generator's patchelf leaves glibc as built and passes everything else on"
_keep="${CMAKE_MODULES}/../linux/scripts/06-packaging/patchelf-keep-glibc.sh"
printf '#!/bin/sh\necho "patched $*"\n' > "${_work}/stub-patchelf"
chmod +x "${_work}/stub-patchelf"
_assert_patchelf() {
  local expected="$1" label="$2"
  shift 2
  t_assert_eq "$expected" "$(KATAGLYPHIS_PATCHELF="${_work}/stub-patchelf" "$@")" "$label"
}
t_assert_eq "" "$(KATAGLYPHIS_PATCHELF="${_work}/stub-patchelf" bash "${_keep}" --set-rpath x /a/ld-linux-x86-64.so.2)" "loader kept"
t_assert_eq "" "$(KATAGLYPHIS_PATCHELF="${_work}/stub-patchelf" bash "${_keep}" --set-rpath x /a/libc.so.6)" "libc kept"
t_assert_eq "patched --set-rpath x /a/libfoo.so" \
  "$(KATAGLYPHIS_PATCHELF="${_work}/stub-patchelf" bash "${_keep}" --set-rpath x /a/libfoo.so)" "others patched"
t_assert_eq "patched --set-rpath x /a/libonnxruntime.so.1" \
  "$(KATAGLYPHIS_PATCHELF="${_work}/stub-patchelf" bash "${_keep}" --set-rpath x /a/libonnxruntime.so.1)" "CPU behavior unchanged"
_assert_patchelf "" "GPU provider kept" bash "${_keep}" --keep-ort --set-rpath x /a/libonnxruntime_providers_shared.so
_assert_patchelf "" "GPU core kept" bash "${_keep}" --keep-ort --set-rpath x /a/libonnxruntime.so.1
_assert_patchelf "" "AMD plugin kept" bash "${_keep}" --keep-ort --set-rpath x "/a path/libmigraphx-ep.so"
_assert_patchelf "patched --set-rpath x /a/libmigraphx-ep.so" "unselected AMD plugin patched" bash "${_keep}" --set-rpath x /a/libmigraphx-ep.so
_assert_patchelf "patched --set-rpath x /a/libfoo.so" "other GPU bundle libraries patched" bash "${_keep}" --keep-ort --set-rpath x /a/libfoo.so

t_case "an unresolvable library fails the install instead of shipping"
_project ''
mv "${_work}/vendor/libvendor.so.1" "${_work}/vendor/hidden.so"
t_assert_fails _install
mv "${_work}/vendor/hidden.so" "${_work}/vendor/libvendor.so.1"

t_case "NO_DEFAULT_SYSTEM copies a default graphics dependency when the caller leaves it out of SYSTEM"
printf 'int graphics_value() { return 1; }\n' > "${_work}/vendor/graphics.cpp"
c++ -shared -fPIC -Wl,-soname,libGL.so.1 -o "${_work}/vendor/libGL.so.1" "${_work}/vendor/graphics.cpp"
patchelf --add-needed libGL.so.1 "${_work}/vendor/libvendor.so.1"
_project ''
t_assert_ok _install
t_assert_fails test -e "${_work}/stage/lib/fixture/libGL.so.1"
_project 'NO_DEFAULT_SYSTEM SYSTEM "libc.so.6" "libm.so.6" "libgcc_s.so.1" "libpthread.so.0" "libdl.so.2" "librt.so.1" "ld-linux*.so*"'
t_assert_ok _install
t_assert_ok test -f "${_work}/stage/lib/fixture/libGL.so.1"
patchelf --remove-needed libGL.so.1 "${_work}/vendor/libvendor.so.1"

t_case "EXTERNAL_LIBRARY_PATH requires LOADER and preserves nonempty SDK paths for dlopen on both loader branches"
_project 'EXTERNAL_LIBRARY_PATH'
t_assert_fails _install
mkdir -p "${_work}/sdk"
printf 'extern "C" int external_value() { return 17; }\n' > "${_work}/sdk/external.cpp"
c++ -shared -fPIC -o "${_work}/sdk/libexternal.so" "${_work}/sdk/external.cpp"
cat > "${_work}/src/app.cpp" <<'EOF'
#include <dlfcn.h>
#include <cstdlib>
#include <iostream>
#include <string>
int main() {
  void *module = dlopen("libexternal.so", RTLD_NOW);
  if (!module) return 1;
  auto fn = reinterpret_cast<int (*)()>(dlsym(module, "external_value"));
  std::string path = std::getenv("LD_LIBRARY_PATH") ? std::getenv("LD_LIBRARY_PATH") : "";
  if (!fn || fn() != 17 || path.empty() || path.front() == ':' || path.back() == ':' || path.find("::") != path.npos) return 2;
  std::cout << "external-ok\n";
}
EOF
_project 'LOADER EXTERNAL_LIBRARY_PATH PROTECT "lib/fixture/libvendor*"'
t_assert_ok _install
t_assert_fails env -i "${_work}/stage/bin/app"
t_assert_eq "external-ok" "$(env -i LD_LIBRARY_PATH="::${_work}/sdk::" "${_work}/stage/bin/app")" "host loader finds external runtime"
t_assert_eq "external-ok" "$(env -i KATAGLYPHIS_BUNDLED_GLIBC=1 LD_LIBRARY_PATH="::${_work}/sdk::" "${_work}/stage/bin/app")" "bundled loader finds external runtime"

t_case "AppImage ORT preservation requires the external launcher and creates an executable wrapper"
_project 'LOADER PRESERVE_ORT_IN_APPIMAGE'
t_assert_fails _install
_project 'LOADER EXTERNAL_LIBRARY_PATH PRESERVE_ORT_IN_APPIMAGE'
t_assert_ok _install
_appimage_wrapper="${_work}/build/tools/patchelf-keep-glibc-and-ort.sh"
t_assert_ok test -x "${_appimage_wrapper}"
_assert_patchelf "" "generated wrapper preserves provider" "${_appimage_wrapper}" --set-rpath x /a/libonnxruntime_providers_migraphx.so
_assert_patchelf "patched --set-rpath x /a/libfoo.so" "generated wrapper patches unrelated libraries" "${_appimage_wrapper}" --set-rpath x /a/libfoo.so

t_case "--beside and --external-library-path work together and are idempotent"
mkdir -p "${_work}/external-beside/lib"
c++ -o "${_work}/external-beside/app" "${_work}/src/app.cpp" -ldl
t_assert_ok bash "${_loader}" --external-library-path --beside "${_work}/external-beside" "${_work}/external-beside/lib" app
t_assert_ok bash "${_loader}" --beside --external-library-path "${_work}/external-beside" "${_work}/external-beside/lib" app
t_assert_eq "external-ok" "$(env -i LD_LIBRARY_PATH="::${_work}/sdk::" "${_work}/external-beside/app")" "beside host loader finds external runtime"
t_assert_eq "external-ok" "$(env -i KATAGLYPHIS_BUNDLED_GLIBC=1 LD_LIBRARY_PATH="::${_work}/sdk::" "${_work}/external-beside/app")" "beside bundled loader finds external runtime"

t_case "--library-path: the stated bundle directory reaches the loader on both glibc paths, external or not; a rerun keeps it"
# The rocm Python bundle's capi: the plugin module's core sits there and no RUNPATH may name it.
for _mode in plain external; do
  _dir="${_work}/stated-${_mode}"
  mkdir -p "${_dir}/lib" "${_dir}/runtime/capi"
  cp "${_work}/sdk/libexternal.so" "${_dir}/runtime/capi/"
  c++ -o "${_dir}/app" "${_work}/src/app.cpp" -ldl
  _flags=(--beside --library-path runtime/capi)
  [ "${_mode}" = plain ] || _flags+=(--external-library-path)
  t_assert_ok bash "${_loader}" "${_flags[@]}" "${_dir}" "${_dir}/lib" app
  t_assert_ok bash "${_loader}" "${_flags[@]}" "${_dir}" "${_dir}/lib" app
  t_assert_eq "external-ok" "$(env -i "${_dir}/app")" "${_mode}: the host glibc path loads from the stated directory"
  t_assert_eq "external-ok" "$(env -i KATAGLYPHIS_BUNDLED_GLIBC=1 "${_dir}/app")" "${_mode}: so does the bundled loader"
  t_assert_contains "$(bash "${_loader}" --beside "${_dir}" "${_dir}/lib" app 2>&1)" "different library path"
done
mkdir -p "${_work}/unstated/lib" "${_work}/unstated/runtime/capi"
cp "${_work}/sdk/libexternal.so" "${_work}/unstated/runtime/capi/"
c++ -o "${_work}/unstated/app" "${_work}/src/app.cpp" -ldl
for _path in ../stated-plain/runtime/capi /runtime/capi runtime/nope; do
  t_assert_contains "$(bash "${_loader}" --beside --library-path "${_path}" "${_work}/unstated" "${_work}/unstated/lib" app 2>&1)" \
    "a launcher's --library-path must name directories inside"
done
t_assert_ok bash "${_loader}" --beside "${_work}/unstated" "${_work}/unstated/lib" app
t_assert_fails env -i "${_work}/unstated/app"
t_assert_contains "$(bash "${_loader}" --beside --library-path runtime/capi "${_work}/unstated" "${_work}/unstated/lib" app 2>&1)" "different library path"

t_case "an existing non-external launcher is not silently accepted as external"
mkdir -p "${_work}/upgrade/lib"
cp "${_work}/stage/lib/fixture/app" "${_work}/upgrade/app"
t_assert_ok bash "${_loader}" --beside "${_work}/upgrade" "${_work}/upgrade/lib" app
t_assert_fails bash "${_loader}" --beside --external-library-path "${_work}/upgrade" "${_work}/upgrade/lib" app

t_summary
