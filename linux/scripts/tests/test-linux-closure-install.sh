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
t_assert_ok bash "${_loader}" --beside "${_work}/beside" "${_work}/beside/lib" runner
t_assert_ok bash "${_loader}" --beside "${_work}/beside" "${_work}/beside/lib" runner
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

t_case "the AppImage generator's patchelf leaves glibc as built and passes everything else on"
_keep="${CMAKE_MODULES}/../linux/scripts/06-packaging/patchelf-keep-glibc.sh"
printf '#!/bin/sh\necho "patched $*"\n' > "${_work}/stub-patchelf"
chmod +x "${_work}/stub-patchelf"
t_assert_eq "" "$(KATAGLYPHIS_PATCHELF="${_work}/stub-patchelf" bash "${_keep}" --set-rpath x /a/ld-linux-x86-64.so.2)" "loader kept"
t_assert_eq "" "$(KATAGLYPHIS_PATCHELF="${_work}/stub-patchelf" bash "${_keep}" --set-rpath x /a/libc.so.6)" "libc kept"
t_assert_eq "patched --set-rpath x /a/libfoo.so" \
  "$(KATAGLYPHIS_PATCHELF="${_work}/stub-patchelf" bash "${_keep}" --set-rpath x /a/libfoo.so)" "others patched"
t_assert_eq "patched --set-rpath x /a/libonnxruntime.so.1" \
  "$(KATAGLYPHIS_PATCHELF="${_work}/stub-patchelf" bash "${_keep}" --set-rpath x /a/libonnxruntime.so.1)" "CPU behavior unchanged"
t_assert_eq "" "$(KATAGLYPHIS_PATCHELF="${_work}/stub-patchelf" bash "${_keep}" --keep-ort --set-rpath x /a/libonnxruntime_providers_shared.so)" "GPU provider kept"
t_assert_eq "" "$(KATAGLYPHIS_PATCHELF="${_work}/stub-patchelf" bash "${_keep}" --keep-ort --set-rpath x /a/libonnxruntime.so.1)" "GPU core kept"
t_assert_eq "patched --set-rpath x /a/libfoo.so" \
  "$(KATAGLYPHIS_PATCHELF="${_work}/stub-patchelf" bash "${_keep}" --keep-ort --set-rpath x /a/libfoo.so)" "other GPU bundle libraries patched"

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
t_assert_eq "" "$(KATAGLYPHIS_PATCHELF="${_work}/stub-patchelf" "${_appimage_wrapper}" --set-rpath x /a/libonnxruntime_providers_migraphx.so)" "generated wrapper preserves provider"
t_assert_eq "patched --set-rpath x /a/libfoo.so" "$(KATAGLYPHIS_PATCHELF="${_work}/stub-patchelf" "${_appimage_wrapper}" --set-rpath x /a/libfoo.so)" "generated wrapper patches unrelated libraries"

t_case "--beside and --external-library-path work together and are idempotent"
mkdir -p "${_work}/external-beside/lib"
c++ -o "${_work}/external-beside/app" "${_work}/src/app.cpp" -ldl
t_assert_ok bash "${_loader}" --external-library-path --beside "${_work}/external-beside" "${_work}/external-beside/lib" app
t_assert_ok bash "${_loader}" --beside --external-library-path "${_work}/external-beside" "${_work}/external-beside/lib" app
t_assert_eq "external-ok" "$(env -i LD_LIBRARY_PATH="::${_work}/sdk::" "${_work}/external-beside/app")" "beside host loader finds external runtime"
t_assert_eq "external-ok" "$(env -i KATAGLYPHIS_BUNDLED_GLIBC=1 LD_LIBRARY_PATH="::${_work}/sdk::" "${_work}/external-beside/app")" "beside bundled loader finds external runtime"

t_case "an existing non-external launcher is not silently accepted as external"
mkdir -p "${_work}/upgrade/lib"
cp "${_work}/stage/lib/fixture/app" "${_work}/upgrade/app"
t_assert_ok bash "${_loader}" --beside "${_work}/upgrade" "${_work}/upgrade/lib" app
t_assert_fails bash "${_loader}" --beside --external-library-path "${_work}/upgrade" "${_work}/upgrade/lib" app

t_summary
