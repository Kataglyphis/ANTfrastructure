#!/usr/bin/env bash
# kataglyphis_flutter_unwinder_first: the link order it sets, the order it refuses, and a real runner against a stand-in engine.
set -u
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=linux/scripts/tests/cmake-project-fixture.sh
source "${TESTS_DIR}/cmake-project-fixture.sh"
HUB_CMAKE="$(cmake_fixture_module_root --native)"
GATE="${TESTS_DIR}/../05-frameworks/flutter/check-flutter-unwinder-order.sh"

# _configured <system> <body>: everything cmake said on one line, since it wraps an error's text.
_configured() {
  cmake_fixture_output "set(CMAKE_SYSTEM_NAME \"$1\")
include(\"${HUB_CMAKE}/KataglyphisFlutterUnwinder.cmake\")
add_library(flutter INTERFACE)
add_library(plugin INTERFACE)
add_executable(app)
$2
get_target_property(_l app LINK_LIBRARIES)
message(STATUS \"LINK=[\${_l}]\")" | tr -s ' \n' '  '
}
# _linked <system> <body>: the LINK=[...] that body leaves on 'app'.
_linked() { _configured "$@" | sed -n 's/.*\(LINK=\[[^]]*\]\).*/\1/p'; }

t_case "cmake is here: the cases below configure a real project"
t_assert_ok cmake --version

t_case "called before flutter, libgcc_s leads the link line and keeps its entry"
t_assert_eq "LINK=[-Wl,--push-state,--no-as-needed;gcc_s;-Wl,--pop-state;flutter;plugin]" \
  "$(_linked Linux 'kataglyphis_flutter_unwinder_first(app)
target_link_libraries(app PRIVATE flutter)
target_link_libraries(app PRIVATE plugin)')" "gcc_s must come first, with --no-as-needed scoped to it alone"

t_case "called after flutter, the configure fails and names the order"
t_assert_contains "$(_configured Linux 'target_link_libraries(app PRIVATE flutter)
kataglyphis_flutter_unwinder_first(app)')" "'app' already links flutter, so libgcc_s would come after Flutter's unwinder" \
  "a late call cannot move libgcc_s ahead and must not pass"

t_case "the engine linked by path counts as flutter"
t_assert_contains "$(_configured Linux 'target_link_libraries(app PRIVATE /x/lib/libflutter_linux_gtk.so)
kataglyphis_flutter_unwinder_first(app)')" "already links /x/lib/libflutter_linux_gtk.so" "the library path is the engine too"

t_case "a library linked before the call is no refusal"
t_assert_eq "LINK=[plugin;-Wl,--push-state,--no-as-needed;gcc_s;-Wl,--pop-state;flutter]" \
  "$(_linked Linux 'target_link_libraries(app PRIVATE plugin)
kataglyphis_flutter_unwinder_first(app)
target_link_libraries(app PRIVATE flutter)')" "only the engine decides the order"

t_case "a Windows or macOS runner is left alone"
for _system in Windows Darwin; do
  t_assert_eq "LINK=[flutter]" "$(_linked "${_system}" 'kataglyphis_flutter_unwinder_first(app)
target_link_libraries(app PRIVATE flutter)')" "${_system} has no libgcc_s to put first"
done

t_case "a library or a missing target fails the configure"
t_assert_contains "$(_configured Linux 'kataglyphis_flutter_unwinder_first(plugin)')" "'plugin' is a INTERFACE_LIBRARY, not an executable"
t_assert_contains "$(_configured Linux 'kataglyphis_flutter_unwinder_first(runner)')" "'runner' is not a target"

for _tool in cc c++ readelf ldd; do
  t_skip_unless "${_tool}" command -v "${_tool}"
done

_work="$(t_mktemp -d)"
printf '%s\n' 'int engine_version(void) { return 1; }' \
  'int _Unwind_RaiseException(void *e) { (void)e; return 5; }' > "${_work}/engine.c"
printf '%s\n' '#include <cstdio>' '#include <stdexcept>' 'extern "C" int engine_version(void);' 'int main() {' \
  '  try {' '    throw std::runtime_error("caught");' '  } catch (const std::exception &e) {' '    std::puts(e.what());' '  }' \
  '  return engine_version() == 1 ? 0 : 1;' '}' > "${_work}/main.cc"
printf '%s\n' 'cmake_minimum_required(VERSION 3.20)' 'project(p LANGUAGES C CXX)' \
  "include(\"${HUB_CMAKE}/KataglyphisFlutterUnwinder.cmake\")" \
  'add_library(engine SHARED engine.c)' 'add_library(flutter INTERFACE)' 'target_link_libraries(flutter INTERFACE engine)' \
  'add_executable(runner main.cc)' 'kataglyphis_flutter_unwinder_first(runner)' 'target_link_libraries(runner PRIVATE flutter)' \
  'add_executable(control main.cc)' 'target_link_libraries(control PRIVATE flutter)' > "${_work}/CMakeLists.txt"
if ! { cmake -S "${_work}" -B "${_work}/b" && cmake --build "${_work}/b"; } > "${_work}/build.log" 2>&1; then
  cat "${_work}/build.log" >&2
  exit 1
fi
# _needed <exe>: its NEEDED entries in order, space-separated.
_needed() { readelf -d "$1" | awk '/\(NEEDED\)/ {gsub(/[][]/, "", $5); printf "%s ", $5}'; }
# _run <exe>: the program's exit code with no core file written into the tree.
_run() { bash -c 'ulimit -c 0; exec "$1"' _ "$1"; }

t_case "the runner's NEEDED list starts with libgcc_s, the control's with the engine"
t_assert_eq "libgcc_s.so.1 libengine.so" "$(_needed "${_work}/b/runner" | awk '{print $1, $2}')" \
  "libgcc_s.so.1 must come first, then the engine"
t_assert_eq "libengine.so" "$(_needed "${_work}/b/control" | awk '{print $1}')" "without the call the engine leads, as in Flutter's runner"

t_case "the runner catches its exception; without the call the engine's unwinder aborts it"
t_assert_rc 0 _run "${_work}/b/runner"
t_assert_eq "caught" "$(_run "${_work}/b/runner" 2>&1)" "the throw must reach its catch"
t_assert_rc 134 _run "${_work}/b/control"

t_case "the unwinder-order gate agrees with the behaviour"
t_assert_rc 0 bash "${GATE}" "${_work}/b/runner"
t_assert_rc 1 bash "${GATE}" "${_work}/b/control"

t_summary
