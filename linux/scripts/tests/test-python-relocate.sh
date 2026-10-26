#!/usr/bin/env bash
# python-relocate.py over a synthetic CPython prefix with stub patchelf/readelf; the image's own CPython is staged when present.
set -u
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${TESTS_DIR}/test-harness.sh"
PKG="$(cd "${TESTS_DIR}/../06-packaging" && pwd)"
TOOL="${PKG}/python-relocate.py"

_work="$(mktemp -d)"; trap 'rm -rf "${_work}"' EXIT
mkdir -p "${_work}/stubs"

# A fake interpreter: facts and the moved probe answer from its own location, py_compile runs the host's.
cat > "${_work}/stubs/fakepy" <<'EOF'
#!/usr/bin/env bash
root="$(cd "$(dirname "$0")/.." && pwd)"
data="${root}/lib/python3.15/${FAKE_DATA_SUBDIR:-}_sysconfigdata__linux_test.py"
case "$*" in
  *"-m py_compile"*) exec python3 -I -m py_compile "${@: -1}" ;;
  *_get_sysconfigdata_name*)
    printf '{"base_prefix": "%s", "version": "3.15", "ldversion": "3.15", "shared": %s, "instsoname": "libpython3.15.so.1.0", "sysconfigdata": "_sysconfigdata__linux_test", "sysconfigdata_file": "%s", "build_prefix": "/usr/local"}\n' \
      "${FAKE_BASE:-${root}}" "${FAKE_SHARED:-1}" "${data}" ;;
  */proc/self/maps*)
    exec python3 -I - "${root}" "${data}" "${FAKE_LIBPY:-${root}/lib/libpython3.15.so.1.0}" <<'PY'
import json
import runpy
import sys

root, data, lib = sys.argv[1:]
sys.base_prefix = root
ns = runpy.run_path(data)
print(json.dumps({"prefix": root, "base_prefix": root, "os_file": root + "/lib/python3.15/os.py",
                  "libpython": [lib], "vars": {k: v for k, v in ns["build_time_vars"].items() if isinstance(v, str)}}))
PY
    ;;
  *) echo "fakepy: unexpected $*" >&2; exit 9 ;;
esac
EOF
cat > "${_work}/stubs/patchelf" <<'EOF'
#!/usr/bin/env bash
[ "$1" = --set-rpath ] && printf '%s' "$2" > "$3.rpath"
EOF
cat > "${_work}/stubs/readelf" <<'EOF'
#!/usr/bin/env bash
f="$2"
[ ! -e "${f}.readelf-fails" ] || exit 1
[ ! -f "${f}.rpath" ] || printf ' 0x000000000000001d (RUNPATH)            Library runpath: [%s]\n' "$(cat "${f}.rpath")"
if [ -f "${f}.needed" ]; then
  while IFS= read -r n; do printf ' 0x0000000000000001 (NEEDED)             Shared library: [%s]\n' "${n}"; done < "${f}.needed"
fi
exit 0
EOF
chmod +x "${_work}"/stubs/*

# make_prefix <dir>: the files an altinstall of 3.15 leaves under its prefix, with the traps the stage must handle.
make_prefix() {
  local p="$1" lib="$1/lib/python3.15"
  mkdir -p "${p}/bin" "${p}/include/python3.15" "${p}/lib/pkgconfig" "${lib}/__pycache__" "${lib}/site-packages/pip" \
    "${lib}/lib-dynload" "${lib}/config-3.15-test"
  cp "${_work}/stubs/fakepy" "${p}/bin/python3.15"
  printf '#!/bin/sh\n' > "${p}/bin/python3.15-config"
  printf '#!/usr/local/bin/python3.15\n' > "${p}/bin/pip3.15"
  t_fake_elf "${p}/lib/libpython3.15.so.1.0" 62
  ln -s libpython3.15.so.1.0 "${p}/lib/libpython3.15.so"
  : > "${lib}/config-3.15-test/libpython3.15.a"
  : > "${lib}/os.py"
  cat > "${lib}/_sysconfigdata__linux_test.py" <<'PY'
build_time_vars = {'prefix': '/usr/local', 'LIBDIR': '/usr/local/lib', 'CFLAGS': '-I/usr/local/include -O2',
                   'LDFLAGS': '-Wl,-rpath,/usr/local/lib', 'OTHER': '/usr/localfoo', 'NUM': 1}
PY
  : > "${lib}/__pycache__/_sysconfigdata__linux_test.cpython-399.pyc"
  printf '{}' > "${lib}/_sysconfig_vars__linux_test.json"
  : > "${lib}/site-packages/README.txt"
  : > "${lib}/site-packages/pip/__init__.py"
  t_fake_elf "${lib}/lib-dynload/_ssl.cpython-315-test.so" 62
  t_fake_elf "${lib}/lib-dynload/readline.cpython-315-test.so" 62
  printf 'libreadline.so.8\n' > "${lib}/lib-dynload/readline.cpython-315-test.so.needed"
  : > "${p}/include/python3.15/Python.h"
  printf 'prefix=/usr/local\nlibdir=${prefix}/lib\n' > "${p}/lib/pkgconfig/python-3.15.pc"
}

_stage() { PATH="${_work}/stubs:${PATH}" python3 -I "${TOOL}" stage --python "$1/bin/python3.15" --dest "$2" 2>&1; }
_check() { PATH="${_work}/stubs:${PATH}" python3 -I "${TOOL}" check --tree "$1" --readelf readelf 2>&1; }

make_prefix "${_work}/src"
T="${_work}/tree"

t_case "stage copies one interpreter and leaves the system's collection behind"
t_assert_contains "$(_stage "${_work}/src" "${T}")" "OK: staged"
t_assert_ok test -x "${T}/bin/python3.15"
t_assert_eq "python3.15" "$(readlink "${T}/bin/python3")" "python3 names the staged interpreter"
t_assert_eq "python3.15-config" "$(readlink "${T}/bin/python3-config")"
t_assert_fails test -e "${T}/bin/pip3.15"
t_assert_eq "README.txt" "$(ls "${T}/lib/python3.15/site-packages")" "the system site-packages must not travel"
t_assert_fails test -e "${T}/lib/python3.15/config-3.15-test/libpython3.15.a"
t_assert_eq "libpython3.15.so.1.0" "$(readlink "${T}/lib/libpython3.15.so")" "the dev link stays a link"
t_assert_ok test -f "${T}/include/python3.15/Python.h"

t_case "the GPL-3 readline binding never reaches a bundle"
t_assert_fails test -e "${T}/lib/python3.15/lib-dynload/readline.cpython-315-test.so"
t_assert_ok test -e "${T}/lib/python3.15/lib-dynload/_ssl.cpython-315-test.so"

t_case "the interpreter finds libpython beside itself"
t_assert_eq '$ORIGIN/../lib' "$(cat "${T}/bin/python3.15.rpath")"

t_case "sysconfig and pkg-config follow the tree, and stale caches are gone"
t_assert_grep "${T}/lib/python3.15/_sysconfigdata__linux_test.py" "^_KATAGLYPHIS_BUILD_PREFIX = '/usr/local'$"
t_assert_fails test -e "${T}/lib/python3.15/__pycache__/_sysconfigdata__linux_test.cpython-399.pyc"
t_assert_fails test -e "${T}/lib/python3.15/_sysconfig_vars__linux_test.json"
t_assert_grep "${T}/lib/pkgconfig/python-3.15.pc" '^prefix=\$\{pcfiledir\}/\.\./\.\.$'
_vars="$(python3 -I - "${T}/lib/python3.15/_sysconfigdata__linux_test.py" <<'PY'
import runpy
import sys

sys.base_prefix = "/moved/here"
v = runpy.run_path(sys.argv[1])["build_time_vars"]
print(v["LIBDIR"], v["CFLAGS"], v["LDFLAGS"], v["OTHER"], v["NUM"], sep="|")
PY
)"
t_assert_eq "/moved/here/lib|-I/moved/here/include -O2|-Wl,-rpath,/moved/here/lib|/usr/localfoo|1" "${_vars}" \
  "the prefix is replaced as a path component only"

t_case "a moved copy of the staged tree passes the check"
_out="$(_check "${T}")"
t_assert_contains "${_out}" "OK: a moved copy of"

t_case "a cross-built tree keeps its sysconfigdata in lib-dynload, and that one is relocated"
make_prefix "${_work}/src-cross"
mv "${_work}/src-cross/lib/python3.15/_sysconfigdata__linux_test.py" "${_work}/src-cross/lib/python3.15/lib-dynload/"
export FAKE_DATA_SUBDIR=lib-dynload/
t_assert_contains "$(_stage "${_work}/src-cross" "${_work}/t-cross")" "OK: staged"
t_assert_grep "${_work}/t-cross/lib/python3.15/lib-dynload/_sysconfigdata__linux_test.py" "^_KATAGLYPHIS_BUILD_PREFIX = "
t_assert_contains "$(_check "${_work}/t-cross")" "OK: a moved copy of"
unset FAKE_DATA_SUBDIR

t_case "stage refuses what it cannot relocate"
make_prefix "${_work}/src-static"
t_assert_contains "$(FAKE_SHARED=0 _stage "${_work}/src-static" "${_work}/t-static")" "is not a --enable-shared build"
t_assert_contains "$(FAKE_BASE=/usr _stage "${_work}/src-static" "${_work}/t-distro")" "the distribution's interpreter"
t_assert_contains "$(_stage "${_work}/src" "${T}")" "exists; stage into a fresh directory"
t_assert_rc 1 _stage "${_work}/src" "${T}"

# _broken <name> <edit...>: a fresh staged tree, edited by the given command run inside it.
_broken() {
  local name="$1" dir; shift
  dir="${_work}/broken-${name}"
  _stage "${_work}/src" "${dir}" >/dev/null || return 1
  ( cd "${dir}" && "$@" ) || return 1
  printf '%s' "${dir}"
}

t_case "check fails a tree that was copied but not relocated"
_b="$(_broken plain cp "${_work}/src/lib/python3.15/_sysconfigdata__linux_test.py" lib/python3.15/)" || exit 1
t_assert_contains "$(_check "${_b}")" "no relocated _sysconfigdata"
t_assert_rc 1 _check "${_b}"

t_case "check fails an interpreter without its RUNPATH"
_b="$(_broken norunpath rm bin/python3.15.rpath)" || exit 1
t_assert_contains "$(_check "${_b}")" "python3.15 has no RUNPATH \$ORIGIN/../lib"

t_case "check fails a moved interpreter that maps the unmoved libpython"
t_assert_contains "$(FAKE_LIBPY=/usr/local/lib/libpython3.15.so.1.0 _check "${T}")" "libpython is mapped from"

t_case "check fails a build-prefix path the rewrite did not reach"
_b="$(_broken leak sed -i "s|'OTHER': '/usr/localfoo'|'OTHER': '@/usr/local/lib'|" lib/python3.15/_sysconfigdata__linux_test.py)" || exit 1
t_assert_contains "$(_check "${_b}")" "sysconfig OTHER = @/usr/local/lib names /usr/local"

t_case "check fails an absolute RUNPATH, an unreadable ELF and a readline link"
_b="$(_broken abs sh -c 'printf /opt/build/lib > lib/python3.15/lib-dynload/_ssl.cpython-315-test.so.rpath')" || exit 1
t_assert_contains "$(_check "${_b}")" "has an absolute RUNPATH entry /opt/build/lib"
_b="$(_broken unreadable touch lib/libpython3.15.so.1.0.readelf-fails)" || exit 1
t_assert_contains "$(_check "${_b}")" "readelf cannot read lib/libpython3.15.so.1.0"
_b="$(_broken readline sh -c 'printf "libreadline.so.8\n" > lib/python3.15/lib-dynload/_ssl.cpython-315-test.so.needed')" || exit 1
t_assert_contains "$(_check "${_b}")" "links libreadline.so.8 (GPL-3)"

t_case "the bundle builder takes the image's CPython by default and keeps the download behind a flag"
_bundle="${PKG}/python-app-bundle.sh"
t_assert_grep "${_bundle}" '^PYTHON_RUNTIME="image"$'
t_assert_grep "${_bundle}" 'python-relocate.py" stage --python'
t_assert_grep "${_bundle}" 'python-relocate.py" check --tree "\$\{RUNTIME\}"'
_parsed="$(bash -c 'usage() { :; }; source "$1"; PYTHON_RUNTIME=image; parse_python_app_args bundle --python-runtime standalone; printf %s "${PYTHON_RUNTIME}"' _ "${PKG}/python-app-cli.sh")"
t_assert_eq "standalone" "${_parsed}" "--python-runtime selects the runtime"

t_case "the runtime smoke stages and moves the image's CPython"
_SB="$(t_rt_sandbox)"; trap 'rm -rf "${_work}" "${_SB}"' EXIT
t_assert_contains "$(t_fn_src "${PKG}/smoke-runtime-image.sh" main)" 'check_relocatable_python "${image_tag}" "${target_arch}"'
_smoke() { t_rt_recorded "${_SB}" "$1" check_relocatable_python img amd64; }
t_assert_contains "$(_smoke $'OK: staged\nOK: a moved copy\nRELOCATE_DONE')" "FAILURES=0"
t_assert_contains "$(_smoke $'FAIL: libpython is mapped from /usr/local\nRELOCATE_DONE')" "FAILURES=1"
t_assert_contains "$(_smoke 'OK: staged')" "FAILURES=1" "a run without its completion line is no pass"
rm -f "${_SB}/python-relocate.py"
t_assert_contains "$(_smoke $'RELOCATE_DONE')" "FAILURES=1" "a smoke without the tool proves nothing"

t_case "the image's own CPython stages and runs moved (inside the family image only)"
if [ -x /usr/local/bin/python3 ] && command -v patchelf >/dev/null && command -v readelf >/dev/null &&
  /usr/local/bin/python3 -I -c 'import sys, sysconfig; sys.exit(not (sysconfig.get_config_var("Py_ENABLE_SHARED") and sys.base_prefix == "/usr/local"))'; then
  t_assert_contains "$(python3 -I "${TOOL}" stage --python /usr/local/bin/python3 --dest "${_work}/image-tree" 2>&1)" "OK: staged /usr/local"
  t_assert_contains "$(python3 -I "${TOOL}" check --tree "${_work}/image-tree" 2>&1)" "OK: a moved copy of"
else
  echo "  NOTE: no shared /usr/local CPython here; the image case runs in :latest"
fi

t_summary
