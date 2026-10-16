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
target_link_libraries(app PRIVATE core)
install(TARGETS app core)
kataglyphis_install_linux_closure(PRIVATE_DIR fixture TARGETS app core missing_target SEARCH "${_work}/vendor" $1)
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

t_case "LOADER: a launcher takes the executable's place and starts it with the bundled loader and glibc"
_project 'LOADER PROTECT "lib/fixture/libvendor*"'
t_assert_ok _install
t_assert_eq "#!/bin/sh" "$(head -1 "${_work}/stage/bin/app")" "bin/app is the launcher"
t_assert_ok test -f "${_work}/stage/lib/fixture/app"
t_assert_ok test -f "${_work}/stage/lib/fixture/libc.so.6"
t_assert_eq 1 "$(find "${_work}/stage/lib/fixture" -name 'ld-linux*' | wc -l)" "the loader travels"
mv "${_work}/stage" "${_work}/moved"
t_assert_eq "closure-ok 42" "$(env -i LD_BIND_NOW=1 "${_work}/moved/bin/app" 2>&1)" "relocated launcher runs"
mv "${_work}/moved" "${_work}/stage"

t_case "--beside: the program keeps its directory, so data/ beside /proc/self/exe is found; a rerun changes nothing"
_loader="${CMAKE_MODULES}/../linux/scripts/06-packaging/bundle-loader.sh"
mkdir -p "${_work}/beside/lib" "${_work}/beside/data"
cat > "${_work}/runner.cpp" <<'EOF'
#include <filesystem>
#include <iostream>
int main() {
  auto dir = std::filesystem::read_symlink("/proc/self/exe").parent_path();
  std::cout << (std::filesystem::is_directory(dir / "data") ? "data-found" : "data-missing") << '\n';
}
EOF
c++ -std=c++17 -o "${_work}/beside/runner" "${_work}/runner.cpp"
t_assert_ok bash "${_loader}" --beside "${_work}/beside" "${_work}/beside/lib" runner
t_assert_ok bash "${_loader}" --beside "${_work}/beside" "${_work}/beside/lib" runner
t_assert_ok test -f "${_work}/beside/runner.bin"
t_assert_ok test -f "${_work}/beside/lib/libc.so.6"
t_assert_eq "data-found" "$(env -i "${_work}/beside/runner")" "the runner finds data/ through the launcher"

t_case "the AppImage generator's patchelf leaves glibc as built and passes everything else on"
_keep="${CMAKE_MODULES}/../linux/scripts/06-packaging/patchelf-keep-glibc.sh"
printf '#!/bin/sh\necho "patched $*"\n' > "${_work}/stub-patchelf"
chmod +x "${_work}/stub-patchelf"
t_assert_eq "" "$(KATAGLYPHIS_PATCHELF="${_work}/stub-patchelf" bash "${_keep}" --set-rpath x /a/ld-linux-x86-64.so.2)" "loader kept"
t_assert_eq "" "$(KATAGLYPHIS_PATCHELF="${_work}/stub-patchelf" bash "${_keep}" --set-rpath x /a/libc.so.6)" "libc kept"
t_assert_eq "patched --set-rpath x /a/libfoo.so" \
  "$(KATAGLYPHIS_PATCHELF="${_work}/stub-patchelf" bash "${_keep}" --set-rpath x /a/libfoo.so)" "others patched"

t_case "an unresolvable library fails the install instead of shipping"
_project ''
mv "${_work}/vendor/libvendor.so.1" "${_work}/vendor/hidden.so"
t_assert_fails _install
mv "${_work}/vendor/hidden.so" "${_work}/vendor/libvendor.so.1"

t_summary
