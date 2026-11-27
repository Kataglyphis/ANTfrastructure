#!/usr/bin/env bash
# The unwinder-order gate on executables linked against a stand-in for Flutter 3.50's engine, which exports _Unwind_RaiseException.
set -u
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=linux/scripts/tests/test-harness.sh
source "${TESTS_DIR}/test-harness.sh"
GATE="${TESTS_DIR}/../05-frameworks/flutter/check-flutter-unwinder-order.sh"

t_case "no executable is a usage error, and --help is not"
t_assert_rc 2 bash "${GATE}"
t_assert_rc 0 bash "${GATE}" --help

for _tool in cc ldd readelf; do
  t_skip_unless "${_tool}" command -v "${_tool}"
done

_work="$(t_mktemp -d)"
printf 'int _Unwind_RaiseException(void *e) { (void)e; return 5; }\n' > "${_work}/engine.c"
cc -shared -fPIC -o "${_work}/libengine.so" "${_work}/engine.c" || exit 1
printf 'int g(void) { return 1; }\n' > "${_work}/gone.c"
cc -shared -fPIC -o "${_work}/libgone.so" "${_work}/gone.c" || exit 1
printf 'int main(void) { return 0; }\n' > "${_work}/main.c"
# _link <name> <libs...>: --no-as-needed keeps every library, as a runner's real calls into the engine would.
_link() {
  local out="$1"
  shift
  cc -o "${_work}/${out}" "${_work}/main.c" -L"${_work}" -Wl,-rpath,"${_work}" -Wl,--no-as-needed "$@" || exit 1
}
_link engine-first -lengine -lgcc_s
_link gcc-first -lgcc_s -lengine
_link gcc-only -lgcc_s
_link no-unwinder
_link unresolved -lgcc_s -lgone
rm -f "${_work}/libgone.so"
# bundle-loader.sh --beside's layout: a launcher script, and the ELF it starts beside it as <name>.bin.
for _name in good-launcher bad-launcher bare-launcher; do printf '#!/bin/sh\nexec "$0.bin" "$@"\n' > "${_work}/${_name}"; done
cp "${_work}/gcc-first" "${_work}/good-launcher.bin"
cp "${_work}/engine-first" "${_work}/bad-launcher.bin"

t_case "libgcc_s ahead of an engine that exports the unwinder"
t_assert_rc 0 bash "${GATE}" "${_work}/gcc-first"
t_assert_contains "$(bash "${GATE}" "${_work}/gcc-first" 2>&1)" "libgcc_s.so.1 defines _Unwind_RaiseException first"

t_case "the engine's unwinder ahead of libgcc_s fails, by name"
t_assert_rc 1 bash "${GATE}" "${_work}/engine-first"
t_assert_contains "$(bash "${GATE}" "${_work}/engine-first" 2>&1)" "libengine.so defines _Unwind_RaiseException ahead of libgcc_s.so.1"

t_case "only libgcc_s defines the unwinder"
t_assert_rc 0 bash "${GATE}" "${_work}/gcc-only"

t_case "a load order where nothing defines it proves nothing"
t_assert_rc 1 bash "${GATE}" "${_work}/no-unwinder"

t_case "an unresolved library is not graded on a partial list"
t_assert_rc 1 bash "${GATE}" "${_work}/unresolved"
t_assert_contains "$(bash "${GATE}" "${_work}/unresolved" 2>&1)" "has unresolved libraries"

t_case "a launcher is graded by the .bin it starts"
t_assert_rc 0 bash "${GATE}" "${_work}/good-launcher"
t_assert_contains "$(bash "${GATE}" "${_work}/good-launcher" 2>&1)" "first for ${_work}/good-launcher.bin" "the verdict names the ELF it read"

t_case "a launcher whose .bin loads the engine's unwinder first"
t_assert_rc 1 bash "${GATE}" "${_work}/bad-launcher"

t_case "a launcher without its .bin"
t_assert_rc 1 bash "${GATE}" "${_work}/bare-launcher"
t_assert_contains "$(bash "${GATE}" "${_work}/bare-launcher" 2>&1)" "is a script with no bare-launcher.bin beside it"

t_case "a missing executable"
t_assert_rc 1 bash "${GATE}" "${_work}/absent"

t_case "every executable is checked: one wrong order fails the run"
_out="$(bash "${GATE}" "${_work}/engine-first" "${_work}/gcc-first" 2>&1)"
t_assert_rc 1 bash "${GATE}" "${_work}/engine-first" "${_work}/gcc-first"
t_assert_contains "${_out}" "for ${_work}/gcc-first" "the good executable after a bad one is still graded"

t_case "a readelf that fails is an error, not an object without the symbol"
mkdir -p "${_work}/bin"
printf '#!/bin/sh\necho "readelf: Error: stub" >&2\nexit 1\n' > "${_work}/bin/readelf"
chmod +x "${_work}/bin/readelf"
_out="$(PATH="${_work}/bin:${PATH}" bash "${GATE}" "${_work}/gcc-first" 2>&1)"
t_assert_rc 1 env PATH="${_work}/bin:${PATH}" bash "${GATE}" "${_work}/gcc-first"
t_assert_contains "${_out}" "readelf failed on" "an unreadable library must not pass as one that lacks the unwinder"

t_summary
