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

t_case "--direct-only leaves an excluded host runtime's transitive dependencies to the host"
b="$(bundle ldd-direct-only)"
t_assert_ok env LD_LIBRARY_PATH="${_work}/host" bash "${CLOSURE}" --bundle "${b}" --lib-dir "${b}/lib" --ldd --relocatable --direct-only 'bin/app' --system 'libtop.so.*'
t_assert_fails test -e "${b}/lib/libtop.so.1"
t_assert_fails test -e "${b}/lib/libdep.so.1"

t_case "--direct-only still copies direct dependencies not explicitly left to the host"
b="$(bundle ldd-direct-copy)"
t_assert_ok env LD_LIBRARY_PATH="${_work}/host" bash "${CLOSURE}" --bundle "${b}" --lib-dir "${b}/lib" --search "${_work}/host" --ldd --relocatable --direct-only 'bin/app'
t_assert_ok test -f "${b}/lib/libtop.so.1"
t_assert_ok test -f "${b}/lib/libdep.so.1"

t_case "--reject-source-root refuses to copy a library from a host runtime tree"
b="$(bundle reject-source-root)"
t_assert_fails walk_host --reject-source-root "${_work}/host"
t_assert_contains "$(log)" 'from host runtime'
t_assert_fails test -e "${b}/lib/libtop.so.1"

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

t_case "--ldd --relocatable rejects an absolute library path outside the bundle"
b="$(bundle absolute-ldd)"
patchelf --replace-needed libtop.so.1 "${_work}/host/libtop.so.1" "${b}/bin/app"
t_assert_fails env LD_LIBRARY_PATH="${_work}/host" bash "${CLOSURE}" --bundle "${b}" --lib-dir "${b}/lib" --ldd --relocatable

t_case "--ldd ignores the loader alias that names the inspected file itself"
b="$(bundle loader-alias)"
mkdir -p "${_work}/fake-bin"
_real_ldd="$(command -v ldd)"
# shellcheck disable=SC2016 # Expand variables only in the generated wrapper.
printf '#!/usr/bin/env bash\n"$REAL_LDD" "$@" || exit $?\nprintf "%%s => /lib64/ld-linux-x86-64.so.2 (0x0)\\n" "$1"\n' > "${_work}/fake-bin/ldd"
chmod +x "${_work}/fake-bin/ldd"
t_assert_ok env REAL_LDD="${_real_ldd}" LD_LIBRARY_PATH="${_work}/host" PATH="${_work}/fake-bin:${PATH}" \
  bash "${CLOSURE}" --bundle "${b}" --lib-dir "${b}/lib" --ldd --relocatable

t_case '--ldd recognizes a direct loader shown under the inspected file alias'
b="$(bundle loader-direct-alias)"
_loader_path="$(readelf -l "$(command -v bash)" | sed -n 's/.*Requesting program interpreter: \(.*\)]/\1/p')"
_loader_name="${_loader_path##*/}"
patchelf --add-needed "${_loader_name}" "${b}/bin/app"
cat > "${_work}/fake-bin/ldd" <<'SH'
#!/usr/bin/env bash
"$REAL_LDD" "$@" | awk -v loader="$LOADER_NAME" 'index($0, loader) == 0' || exit $?
case "$1" in */bin/app) [ "$ALIAS_KIND" = missing ] || printf '%s => %s (0x0)\n' "${ALIAS_NAME:-$1}" "$LOADER_PATH" ;; esac
SH
chmod +x "${_work}/fake-bin/ldd"
loader_walk() {
  env REAL_LDD="${_real_ldd}" LOADER_NAME="${_loader_name}" LOADER_PATH="${_loader_path}" \
    ALIAS_KIND="${1:-present}" ALIAS_NAME="${2:-}" LD_LIBRARY_PATH="${_work}/host" PATH="${_work}/fake-bin:${PATH}" \
    bash "${CLOSURE}" --bundle "${b}" --lib-dir "${b}/lib" --ldd > "${_work}/log" 2>&1
}
t_assert_ok loader_walk
t_assert_fails loader_walk missing
t_assert_contains "$(log)" "ldd omitted direct dependency ${_loader_name}"
t_assert_fails loader_walk present /not/the/inspected/file
t_assert_contains "$(log)" "ldd omitted direct dependency ${_loader_name}"

t_case '--ldd fails closed when ldd fails, emits nothing, or omits a direct dependency'
b="$(bundle ldd-errors)"
fake_walk() { env PATH="${_work}/fake-bin:${PATH}" bash "${CLOSURE}" --bundle "${b}" --lib-dir "${b}/lib" "$@" > "${_work}/log" 2>&1; }
printf '#!/usr/bin/env bash\necho "emulated loader crashed" >&2\nexit 17\n' > "${_work}/fake-bin/ldd"
t_assert_fails fake_walk --ldd
t_assert_contains "$(log)" 'ldd failed'
printf '#!/usr/bin/env bash\nprintf "libtop.so.1 => /tmp/libtop.so.1 (0x0)\\n"\nexit 139\n' > "${_work}/fake-bin/ldd"
t_assert_fails fake_walk --ldd
t_assert_contains "$(log)" 'ldd failed'
printf '#!/usr/bin/env bash\nexit 0\n' > "${_work}/fake-bin/ldd"
t_assert_fails fake_walk --ldd
t_assert_contains "$(log)" 'ldd omitted direct dependency'
printf '#!/usr/bin/env bash\nprintf "libc.so.6 => /lib/libc.so.6 (0x0)\\n"\n' > "${_work}/fake-bin/ldd"
t_assert_fails fake_walk --ldd
t_assert_contains "$(log)" 'ldd omitted direct dependency'

t_case 'direct-only inspection does not invoke ldd for the selected file'
printf '#!/usr/bin/env bash\nexit 17\n' > "${_work}/fake-bin/ldd"
b="$(bundle direct-no-ldd)"
t_assert_ok env PATH="${_work}/fake-bin:${PATH}" bash "${CLOSURE}" --bundle "${b}" --lib-dir "${b}/lib" \
  --ldd --direct-only 'bin/app' --system 'libtop.so.*'

t_case 'empty readelf output is not a valid dependency-free ELF'
printf '#!/usr/bin/env bash\nexit 0\n' > "${_work}/fake-bin/readelf"
chmod +x "${_work}/fake-bin/readelf"
b="$(bundle empty-readelf)"
t_assert_fails fake_walk
t_assert_contains "$(log)" 'incomplete ELF dynamic section'
_real_readelf="$(command -v readelf)"
# shellcheck disable=SC2016 # Expand variables only in the generated wrapper.
printf '#!/usr/bin/env bash\n"$REAL_READELF" "$@" | sed "/(NULL)/d"\n' > "${_work}/fake-bin/readelf"
t_assert_fails env REAL_READELF="${_real_readelf}" PATH="${_work}/fake-bin:${PATH}" \
  bash "${CLOSURE}" --bundle "${b}" --lib-dir "${b}/lib"
# shellcheck disable=SC2016 # Expand variables only in the generated wrapper.
printf '#!/usr/bin/env bash\necho "There is no dynamic section in this file."\n"$REAL_READELF" "$@"\n' > "${_work}/fake-bin/readelf"
export REAL_READELF="${_real_readelf}"
t_assert_fails fake_walk
t_assert_contains "$(log)" 'conflicting ELF dynamic section output'
unset REAL_READELF
printf '#!/usr/bin/env bash\necho "readelf failed" >&2\nexit 19\n' > "${_work}/fake-bin/readelf"
t_assert_fails fake_walk
t_assert_contains "$(log)" 'cannot inspect ELF dynamic section'
rm "${_work}/fake-bin/readelf"

t_case 'a statically linked ELF and the dynamic loader remain valid'
printf 'void _start(void) { for (;;) {} }\n' > "${_work}/src/static.c"
cc -nostdlib -static -o "${_work}/static" "${_work}/src/static.c"
mkdir -p "${_work}/static-bundle/bin"
cp "${_work}/static" "${_work}/static-bundle/bin/static"
t_assert_ok closure --bundle "${_work}/static-bundle" --lib-dir "${_work}/static-bundle/lib" --ldd --check
b="${_work}/static-bundle"
printf '#!/usr/bin/env bash\necho "unexpected crash" >&2\nexit 139\n' > "${_work}/fake-bin/ldd"
t_assert_fails fake_walk --ldd --check
t_assert_contains "$(log)" 'ldd failed'
mkdir -p "${_work}/loader-bundle/bin"
_loader="$(readelf -l "$(command -v bash)" | sed -n 's/.*Requesting program interpreter: \(.*\)]/\1/p')"
cp "$(readlink -f "${_loader}")" "${_work}/loader-bundle/bin/loader"
t_assert_ok closure --bundle "${_work}/loader-bundle" --lib-dir "${_work}/loader-bundle/lib" --ldd --check

t_case 'ldd resolves an ORIGIN-relative direct dependency inside the bundle'
b="$(bundle origin-needed)"
cp "${_work}/host/libtop.so.1" "${_work}/host/libdep.so.1" "${b}/bin/"
# shellcheck disable=SC2016 # Store a literal ORIGIN token in DT_NEEDED.
patchelf --replace-needed libtop.so.1 '$ORIGIN/libtop.so.1' "${b}/bin/app"
t_assert_ok env LD_LIBRARY_PATH="${b}/bin" bash "${CLOSURE}" --bundle "${b}" --lib-dir "${b}/lib" --ldd --relocatable

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
