#!/usr/bin/env bash
# verify-elf-hardening.sh on compiled fixtures: each property it requires, each one missing on its own, and its specs.
set -u
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${TESTS_DIR}/test-harness.sh"
GATE="${TESTS_DIR}/../06-packaging/verify-elf-hardening.sh"

for _tool in cc readelf; do t_skip_unless "${_tool}" command -v "${_tool}"; done
WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT

cat > "${WORK}/fixture.c" <<'C'
#include <stdio.h>
#include <string.h>
int fixture(const char *text) {
  char buffer[32];
  strcpy(buffer, text);
  printf("%s\n", buffer);
  return (int)strlen(buffer);
}
#ifdef FIXTURE_MAIN
int main(int argc, char **argv) { return fixture(argc > 1 ? argv[1] : "fixture"); }
#endif
C

# Explicit on every side, so a distro compiler's defaults can neither add nor remove a property.
HARDENED=(-O2 -fstack-protector-all -U_FORTIFY_SOURCE -D_FORTIFY_SOURCE=2 '-Wl,-z,relro' '-Wl,-z,now')
# _build OUT executable|library [extra cc flags...]: the fixture, hardened unless the extra flags take a property away.
_build() {
  local out="$1" kind="$2"
  shift 2
  if [ "${kind}" = executable ]; then
    cc -DFIXTURE_MAIN -fPIE -pie "${HARDENED[@]}" "$@" -o "${WORK}/${out}" "${WORK}/fixture.c"
  else
    cc -shared -fPIC "${HARDENED[@]}" "$@" -o "${WORK}/${out}" "${WORK}/fixture.c"
  fi
}
_gate() { bash "${GATE}" "$@" 2>&1; }

_build app executable
_build libfixture.so library
_build app-no-pie executable -fno-PIE -no-pie
_build app-no-relro executable -Wl,-z,norelro
_build app-lazy executable -Wl,-z,lazy
_build app-no-ssp executable -fno-stack-protector
_build app-no-fortify executable -U_FORTIFY_SOURCE

t_case "a hardened executable and a hardened library pass, and the line says what was found"
out="$(_gate "${WORK}/app" "${WORK}/libfixture.so:library")"
t_assert_contains "${out}" "hardening ok: ${WORK}/app: PIE RELRO BIND_NOW __stack_chk_fail __"
t_assert_contains "${out}" "hardening ok: ${WORK}/libfixture.so: RELRO BIND_NOW __stack_chk_fail __"
t_assert_contains "${out}" "hardening: 2 ELF file(s) passed"

t_case "each property missing on its own fails, and the line names it"
t_assert_rc 1 bash "${GATE}" "${WORK}/app-no-pie"
t_assert_contains "$(_gate "${WORK}/app-no-pie")" "app-no-pie: not PIE"
t_assert_contains "$(_gate "${WORK}/app-no-relro")" "app-no-relro: no GNU_RELRO segment"
t_assert_contains "$(_gate "${WORK}/app-lazy")" "app-lazy: no BIND_NOW"
t_assert_contains "$(_gate "${WORK}/app-no-ssp")" "app-no-ssp: no __stack_chk_fail import"
t_assert_contains "$(_gate "${WORK}/app-no-fortify")" "app-no-fortify: no __*_chk import"

t_case "a no-fortify spec waives only _FORTIFY_SOURCE, and a library is never asked for PIE"
t_assert_rc 0 bash "${GATE}" "${WORK}/app-no-fortify:executable:no-fortify"
t_assert_rc 1 bash "${GATE}" "${WORK}/app-no-ssp:executable:no-fortify"
t_assert_rc 0 bash "${GATE}" "${WORK}/libfixture.so:library"

t_case "a missing file fails, while a spec the gate cannot read and no spec at all are usage errors"
t_assert_contains "$(_gate "${WORK}/gone")" "${WORK}/gone: no such file"
t_assert_rc 1 bash "${GATE}" "${WORK}/gone"
t_assert_rc 2 bash "${GATE}" "${WORK}/app:program"
t_assert_rc 2 bash "${GATE}" "${WORK}/app:executable:fortify:extra"
t_assert_rc 2 bash "${GATE}"

t_summary
