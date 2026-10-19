#!/usr/bin/env bash
# elf-closure.sh on real ELF fixtures: what it copies from where, what it patches, what it leaves to the target. See docs/linux-build-basics.md#the-elf-closure-walker
set -u
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${TESTS_DIR}/test-harness.sh"
CLOSURE="${TESTS_DIR}/../06-packaging/elf-closure.sh"

for _tool in cc patchelf readelf ldd ldconfig; do t_skip_unless "${_tool}" command -v "${_tool}"; done

_work="$(mktemp -d)"
trap 'rm -rf "${_work}"' EXIT

# host/ holds libtop.so.1 -> libdep.so.1, alt/ another libdep; the bundle's app needs libtop.
mkdir -p "${_work}/host" "${_work}/alt" "${_work}/src"
printf 'int dep_value(void) { return 41; }\n' > "${_work}/src/dep.c"
printf 'int dep_value(void) { return 7; }\n' > "${_work}/src/alt.c"
printf 'int dep_value(void);\nint top_value(void) { return dep_value() + 1; }\n' > "${_work}/src/top.c"
printf '#include <stdio.h>\nint top_value(void);\nint main(void) { printf("closure %%d\\n", top_value()); return 0; }\n' > "${_work}/src/app.c"
cc -shared -fPIC -Wl,-soname,libdep.so.1 -o "${_work}/host/libdep.so.1" "${_work}/src/dep.c"
cc -shared -fPIC -Wl,-soname,libdep.so.1 -o "${_work}/alt/libdep.so.1" "${_work}/src/alt.c"
cc -shared -fPIC -Wl,-soname,libtop.so.1 -o "${_work}/host/libtop.so.1" "${_work}/src/top.c" -L"${_work}/host" -l:libdep.so.1
cc -o "${_work}/app" "${_work}/src/app.c" -L"${_work}/host" -l:libtop.so.1 -Wl,-rpath-link,"${_work}/host"

# bundle <name>: a fresh bundle holding bin/app, printed.
bundle() {
  local b="${_work}/$1"
  rm -rf "${b}"
  mkdir -p "${b}/bin"
  cp "${_work}/app" "${b}/bin/app"
  printf '%s' "${b}"
}
closure() { bash "${CLOSURE}" "$@" > "${_work}/log" 2>&1; }
log() { cat "${_work}/log"; }
# walk [options]: the walker over bundle ${b} into its lib/; walk_host also searches host/.
walk() { closure --bundle "${b}" --lib-dir "${b}/lib" "$@"; }
walk_host() { walk --search "${_work}/host" "$@"; }
runpath() { readelf -d "$1" | sed -n 's/.*(RUNPATH).*\[\(.*\)\]/\1/p'; }

t_case "the libraries the bundle lacks land in the lib dir, every user gets an \$ORIGIN RUNPATH, and it runs moved"
b="$(bundle plain)"
t_assert_ok walk_host
t_assert_ok test -f "${b}/lib/libtop.so.1"
t_assert_ok test -f "${b}/lib/libdep.so.1"
t_assert_fails test -e "${b}/lib/libc.so.6"
t_assert_eq '$ORIGIN/../lib' "$(runpath "${b}/bin/app")"
t_assert_eq '$ORIGIN' "$(runpath "${b}/lib/libtop.so.1")"
mv "${b}" "${_work}/moved"
t_assert_eq "closure 42" "$(env -i "${_work}/moved/bin/app" 2>&1)"
t_assert_ok closure --bundle "${_work}/moved" --lib-dir "${_work}/moved/lib" --check

t_case "--check copies nothing and names what is missing"
b="$(bundle check)"
t_assert_fails walk_host --check
t_assert_contains "$(log)" "bin/app: libtop.so.1"
t_assert_fails test -e "${b}/lib/libtop.so.1"

t_case "python-app-closure.sh is the same walker under its old name"
b="$(bundle wrapper)"
t_assert_ok bash "${TESTS_DIR}/../06-packaging/python-app-closure.sh" --bundle "${b}" --lib-dir "${b}/lib" --search "${_work}/host"
t_assert_ok test -f "${b}/lib/libdep.so.1"

t_case "--from: a library comes from its directory or nowhere"
b="$(bundle from)"
t_assert_ok walk_host --from "libdep.so.*=${_work}/alt"
t_assert_ok cmp -s "${_work}/alt/libdep.so.1" "${b}/lib/libdep.so.1"
t_assert_eq "closure 8" "$(env -i "${b}/bin/app" 2>&1)"
b="$(bundle from-missing)"
t_assert_fails walk_host --from "libdep.so.*=${_work}/src"
t_assert_contains "$(log)" "libtop.so.1: libdep.so.1"
t_assert_fails walk --from 'libdep.so.*'
t_assert_contains "$(log)" "--from needs SONAME-GLOB=DIR"

t_case "--exclude and --system leave a library to the target"
b="$(bundle exclude)"
t_assert_ok walk_host --exclude 'libdep.so.*'
t_assert_ok test -f "${b}/lib/libtop.so.1"
t_assert_fails test -e "${b}/lib/libdep.so.1"

t_case "--allow-unresolved lets one named library stay missing"
b="$(bundle allowed)"
cp "${_work}/host/libtop.so.1" "${b}/bin/"
t_assert_fails walk
t_assert_ok walk --allow-unresolved libdep.so.1 --allow-unresolved libtop.so.1
t_assert_contains "$(log)" "allowed unresolved"

t_case "--ldconfig takes a library from the ld.so cache, --ldd from where the loader resolves it"
b="$(bundle ldconfig)"
patchelf --add-needed libz.so.1 "${b}/bin/app"
t_assert_fails walk_host
t_assert_ok walk_host --ldconfig
t_assert_ok cmp -s "$(ldconfig -p | awk '$1 == "libz.so.1" { print $NF; exit }')" "${b}/lib/libz.so.1"
b="$(bundle ldd)"
t_assert_fails walk --ldd
t_assert_contains "$(log)" "bin/app: libtop.so.1"
t_assert_ok env LD_LIBRARY_PATH="${_work}/host" bash "${CLOSURE}" --bundle "${b}" --lib-dir "${b}/lib" --ldd
t_assert_ok cmp -s "${_work}/host/libdep.so.1" "${b}/lib/libdep.so.1"
t_assert_ok test -f "${b}/lib/libtop.so.1"

t_case "--ldd lists a file's libraries transitively, so an excluded library's own still travel"
b="$(bundle ldd-exclude)"
t_assert_ok env LD_LIBRARY_PATH="${_work}/host" bash "${CLOSURE}" --bundle "${b}" --lib-dir "${b}/lib" --ldd --exclude 'libtop.so.*'
t_assert_fails test -e "${b}/lib/libtop.so.1"
t_assert_ok test -f "${b}/lib/libdep.so.1"

t_case "--ldd: a library the loader finds inside the bundle is not copied again"
b="$(bundle ldd-inside)"
cp "${_work}/host/libtop.so.1" "${_work}/host/libdep.so.1" "${b}/bin/"
t_assert_ok env LD_LIBRARY_PATH="${b}/bin" bash "${CLOSURE}" --bundle "${b}" --lib-dir "${b}/lib" --ldd
t_assert_fails test -e "${b}/lib/libtop.so.1"
t_assert_fails test -e "${b}/lib/libdep.so.1"

t_case "--no-default-system carries the C runtime too"
b="$(bundle libc)"
t_assert_ok walk_host --ldconfig --no-default-system
t_assert_ok test -f "${b}/lib/libc.so.6"

t_case "--relocatable: a RUNPATH out of the bundle is dead on the target, so its library is copied"
b="$(bundle reloc)"
patchelf --set-rpath "${_work}/host" "${b}/bin/app"
t_assert_ok walk_host
t_assert_fails test -e "${b}/lib/libtop.so.1"
t_assert_ok walk_host --relocatable
t_assert_ok test -f "${b}/lib/libtop.so.1"
t_assert_ok test -f "${b}/lib/libdep.so.1"

t_case "--no-runpath copies and patches nothing else"
b="$(bundle norunpath)"
t_assert_ok walk_host --no-runpath
t_assert_ok test -f "${b}/lib/libdep.so.1"
t_assert_eq "" "$(runpath "${b}/bin/app")"
t_assert_eq "" "$(runpath "${b}/lib/libtop.so.1")"

t_case "--protect: the file stays byte for byte and its library goes into preload.list"
b="$(bundle protect)"
cp "${_work}/host/libtop.so.1" "${b}/bin/"
t_assert_ok walk_host --protect 'bin/libtop.so.1'
t_assert_ok cmp -s "${_work}/host/libtop.so.1" "${b}/bin/libtop.so.1"
t_assert_eq "libdep.so.1" "$(cat "${b}/lib/preload.list" 2>&1)"
t_assert_ok walk --protect 'bin/libtop.so.1' --check

t_summary
