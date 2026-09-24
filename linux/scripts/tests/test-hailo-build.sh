#!/usr/bin/env bash
# 03-media/build/hailo/hailo-build-lib.sh off-target: the two switches, the nested-build carrier and
# its gate, the cache counters, the pyhailort LTO patch and module check, install_pyhailort, and the
# wiring around them. Not covered: a real HailoRT or pyhailort build, which needs the build host.
# docs/hailo-support.md#the-nested-build-cache-and-pyhailort-two-switches
set -u
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${TESTS_DIR}/test-harness.sh"
SCRIPTS="$(cd "${TESTS_DIR}/.." && pwd)"
HAILO_DIR="${SCRIPTS}/03-media/build/hailo"
LIB="${HAILO_DIR}/hailo-build-lib.sh"
BUILD="${HAILO_DIR}/build-hailort.sh"
TORCH="${SCRIPTS}/../Dockerfile.torch"
BASE="${SCRIPTS}/../Dockerfile.base"
CCSH="${SCRIPTS}/01-core/compiler-cache.sh"
_SB_ROOT="$(mktemp -d)"
trap 'rm -rf "${_SB_ROOT}"' EXIT

# The fakes every sandbox gets. sccache and ccache report counters from files in $SB; readelf
# prints $SB/machine and $SB/dynsym for a file that exists; cmake spawns a nested build the way
# HailoRT's execute_cmake does and records what that build saw.
_fakes() {
  local b="$1/bin"
  cat > "${b}/sccache" <<'SH'
#!/bin/sh
case "$1" in --version) echo "sccache 0.17.0"; exit 0 ;; --show-stats) ;; *) exit 0 ;; esac
[ -e "$SB/sccache.dead" ] && exit 2
printf 'Compile requests                    %s\nCompile requests executed           999\n' "$(cat "$SB/req" 2>/dev/null || echo 0)"
printf 'Cache hits                          %s\nCache hits (C/C++)                  999\n' "$(cat "$SB/hits" 2>/dev/null || echo 0)"
printf 'Cache misses                        %s\nCache misses (C/C++)                999\n' "$(cat "$SB/miss" 2>/dev/null || echo 0)"
printf 'Cache hits rate                   50.00 %%\nMax cache size                       30 GiB\n'
SH
  cat > "${b}/ccache" <<'SH'
#!/bin/sh
case "$1" in
  --print-stats) [ -f "$SB/ccache.stats" ] && cat "$SB/ccache.stats" ;;
  --get-config) echo "30.0 GB" ;;
esac
exit 0
SH
  cat > "${b}/readelf" <<'SH'
#!/bin/sh
for f; do :; done
[ -f "$f" ] || exit 1
case "$1" in
  -h) printf '  Class:                             ELF64\n  Machine:                           %s\n' "$(cat "$SB/machine")" ;;
  --dyn-syms) cat "$SB/dynsym" ;;
esac
SH
  cat > "${b}/cmake" <<'SH'
#!/bin/sh
[ -f "$SB/cmake.rc" ] && exit "$(cat "$SB/cmake.rc")"
printf '%s\n' "$HOME" > "$SB/cmake-home"
env -i HOME="$HOME" PATH=/usr/bin:/bin bash -l -c '
  printf "%s\n" "${CMAKE_CXX_COMPILER_LAUNCHER:-NONE}" > "$1/nested-launcher"
  if [ -n "${CMAKE_CXX_COMPILER_LAUNCHER:-}" ]; then
    n=$(cat "$1/req" 2>/dev/null || echo 0); echo $((n + 10)) > "$1/req"
  fi' _ "$SB"
mkdir -p "$SB/nested"
{ printf '# ninja log v5\n'; for i in 0 1 2 3 4 5 6 7 8 9; do printf '1\t2\t3\tCMakeFiles/p.dir/t%s.cc.o\tabc\n' "$i"; done; } > "$SB/nested/.ninja_log"
SH
  # uv installs an empty module into the sandbox venv (readelf answers for it), or fails like uv.
  cat > "${b}/uv" <<'SH'
#!/bin/sh
printf '%s\n' "$*" > "$SB/uv-args"
[ -e "$SB/uv.fails" ] && { echo "error: hailort-5.4.0 is not a supported wheel on this platform (fake uv)" >&2; exit 2; }
mkdir -p "$SB/venv/site/hailo_platform/pyhailort"
: > "$SB/venv/site/hailo_platform/pyhailort/_pyhailort.cpython-314-aarch64-linux-gnu.so"
SH
  mkdir -p "$1/venv/bin"
  cat > "$1/venv/bin/python" <<'SH'
#!/bin/sh
case "$2" in
  *sysconfig*) printf '%s\n' "$SB/venv/site" ;;
  *hailo_platform*) [ -d "$SB/venv/site/hailo_platform" ] && [ ! -e "$SB/import.fails" ] ;;
  *) exit 1 ;;
esac
SH
  chmod +x "${b}"/* "$1/venv/bin/python"
  printf '%s\n' AArch64 > "$1/machine"
}

# _hb <snippet>: <snippet> in a child bash with the library loaded, a sandbox $SB (the fakes first on
# PATH, TMPDIR and HOME inside it) and no cache env inherited from the caller; then "rc=<n>".
_hb() {
  local sb
  sb="$(mktemp -d "${_SB_ROOT}/sb.XXXXXX")"
  mkdir -p "${sb}/bin" "${sb}/home" "${sb}/tmp"
  _fakes "${sb}"
  # shellcheck disable=SC2046  # one "-u NAME" pair per inherited cache/switch variable
  env $(compgen -e | grep -E -e '^(SCCACHE_|CCACHE_|HAILO_|CMAKE_(C|CXX)_COMPILER_LAUNCHER$|USE_(CCACHE|SCCACHE|LLD)$)' | sed 's/^/-u /') \
    PATH="${sb}/bin:${PATH}" SB="${sb}" TMPDIR="${sb}/tmp" HOME="${sb}/home" \
    bash -c 'set -uo pipefail; source "$1"; eval "$2"; echo "rc=$?"' _ "${LIB}" "$1" 2>&1
}

# HailoRT 5.4.0's execute_cmake.cmake:7, the channel the carrier is derived for.
_CHANNEL_LINE='        execute_process(COMMAND env -i HOME=$ENV{HOME} PATH=/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin bash -l -c "${cmdline}" OUTPUT_QUIET RESULT_VARIABLE result)'

# ---- 1. the switches ------------------------------------------------------------------
t_case "defaults: carry and off, from unset and from empty"
_out="$(_hb 'echo "N=$(hailo_nested_cache_mode) I=$(hailo_pyhailort_ipo_mode)"; HAILO_NESTED_CACHE="" HAILO_PYHAILORT_IPO="" hailo_validate_knobs')"
t_assert_contains "${_out}" "N=carry I=off"
t_assert_contains "${_out}" "rc=0"

t_case "every documented value is accepted as itself"
_out="$(_hb 'for v in carry off; do HAILO_NESTED_CACHE="$v" hailo_nested_cache_mode; echo; done
  for v in off upstream; do HAILO_PYHAILORT_IPO="$v" hailo_pyhailort_ipo_mode; echo; done')"
t_assert_eq $'carry\noff\noff\nupstream\nrc=0' "${_out}"

t_case "a typo in either switch is rc 2 and names the switch"
_out="$(_hb 'HAILO_NESTED_CACHE=cary hailo_validate_knobs')"
t_assert_contains "${_out}" "HAILO_NESTED_CACHE=cary: expected carry or off"
t_assert_contains "${_out}" "rc=2"
_out="$(_hb 'HAILO_PYHAILORT_IPO=on hailo_validate_knobs')"
t_assert_contains "${_out}" "HAILO_PYHAILORT_IPO=on: expected off or upstream"
t_assert_contains "${_out}" "rc=2"

t_case "loading the library changes no shell option and defines no die/info/warn"
_out="$(bash -c 'o1="$(set +o)"; i1="${IFS}"; source "$1"; [ "$(set +o)" = "${o1}" ] && echo SAME-OPTS
  [ "${IFS}" = "${i1}" ] && echo SAME-IFS; for f in die info warn log err; do declare -F "$f" >/dev/null && echo "DEFINES $f"; done' _ "${LIB}" 2>&1)"
t_assert_eq $'SAME-OPTS\nSAME-IFS' "${_out}" "lib-orchestrator.sh sources it on the host"

# ---- 2. the carrier -------------------------------------------------------------------------
t_case "the nested bash -l sees the exported cache env, the real login file, and nothing else"
# The login file sets PATH and a cache variable itself: the carrier's exports must come after it.
_out="$(_hb '
  printf "export hailo_t_profile=ran SCCACHE_DIR=/from-login-file PATH=/usr/bin:/bin\n" > "${HOME}/.profile"
  printf "[user]\n  name = t\n" > "${HOME}/.gitconfig"
  export CMAKE_CXX_COMPILER_LAUNCHER=/opt/scripts/core/sccache-launcher.sh CMAKE_C_COMPILER_LAUNCHER=/opt/scripts/core/sccache-launcher.sh
  export SCCACHE_SERVER_UDS=/tmp/sccache-0.sock SCCACHE_DIR=/var/cache/sccache CCACHE_DIR=/var/cache/ccache
  export CCACHE_SLOPPINESS="pch_defines, \"quoted\" word" LDFLAGS=-fuse-ld=lld CC=gcc CXX=g++ CFLAGS=-O2
  export SCCACHE_LINUX_VERSION=0.18.0 SCCACHE_LINUX_X86_64_SHA256=abc
  SCCACHE_CACHE_SIZE=10G
  export PATH="${SB}/marker-bin:${PATH}"
  mkdir -p "${SB}/carrier" && hailo_nested_env_home "${SB}/carrier" || echo CARRIER-FAILED
  env -i HOME="${SB}/carrier" PATH=/usr/bin:/bin bash -l -c '"'"'
    printf "L=%s C=%s U=%s D=%s CD=%s\n" "${CMAKE_CXX_COMPILER_LAUNCHER:-}" "${CMAKE_C_COMPILER_LAUNCHER:-}" "${SCCACHE_SERVER_UDS:-}" "${SCCACHE_DIR:-}" "${CCACHE_DIR:-}"
    printf "SLOPPY=[%s]\n" "${CCACHE_SLOPPINESS:-}"
    printf "SIZE=[%s] LD=[%s] CC=[%s] CXX=[%s] CF=[%s] PINS=[%s%s]\n" "${SCCACHE_CACHE_SIZE:-}" "${LDFLAGS:-}" "${CC:-}" "${CXX:-}" "${CFLAGS:-}" "${SCCACHE_LINUX_VERSION:-}" "${SCCACHE_LINUX_X86_64_SHA256:-}"
    printf "PROFILE=%s GIT=%s\n" "${hailo_t_profile-}" "$(grep -c "name = t" "${HOME}/.gitconfig" 2>/dev/null)"
    printf "SCCACHE=%s (%s)\n" "$(command -v sccache)" "$(sccache --version)"
    case "${PATH}" in *marker-bin*) echo PATH-LEAKED ;; esac'"'"'
  grep -cE "^export (LDFLAGS|CC|CXX|CFLAGS)=" "${SB}/carrier/.bash_profile" || true
  grep "^export PATH=" "${SB}/carrier/.bash_profile"; ls "${SB}/carrier/.hailo-cache-bin"')"
t_assert_contains "${_out}" "L=/opt/scripts/core/sccache-launcher.sh C=/opt/scripts/core/sccache-launcher.sh U=/tmp/sccache-0.sock D=/var/cache/sccache CD=/var/cache/ccache" \
  "both launchers, the server address and the cache dirs must cross env -i"
t_assert_contains "${_out}" 'SLOPPY=[pch_defines, "quoted" word]' "a value is quoted, not re-split"
t_assert_contains "${_out}" "SIZE=[] LD=[] CC=[] CXX=[] CF=[] PINS=[]" \
  "an unexported default (compiler-cache.sh's := 10G), versions.env's pins and the compiler/linker flags must NOT cross"
t_assert_contains "${_out}" "PROFILE=ran GIT=1" "the real login file runs and the real HOME's files read through the carrier"
t_assert_contains "${_out}" " D=/var/cache/sccache " "the carrier's exports come after the real login file, which sets SCCACHE_DIR too"
t_assert_contains "${_out}" "SCCACHE=${_SB_ROOT}/" "the nested client is the parent's sccache"
t_assert_contains "${_out}" "/carrier/.hailo-cache-bin/sccache (sccache 0.17.0)" \
  "the nested client is the server's own binary, not the distro 0.13 the clean PATH finds first"
t_assert_eq 0 "$(printf '%s\n' "${_out}" | grep -c -e PATH-LEAKED -e CARRIER-FAILED)" "nothing of the parent's PATH crosses"
t_assert_contains "${_out}" $'\n0\nexport PATH='"${_SB_ROOT}" "no compiler or linker flags in the carrier file"
t_assert_contains "${_out}" $'/carrier/.hailo-cache-bin:"${PATH}"\nccache\nsccache\nrc=0' \
  "the one PATH entry the carrier adds holds the parent's sccache and ccache, nothing else"

t_case "every variable setup_ccache exports is carried, and setup_lld_linker's are not"
_out="$(_hb '
  printf "#!/bin/sh\nexit 0\n" > "${SB}/bin/ld.lld"; chmod +x "${SB}/bin/ld.lld"
  source "'"${CCSH}"'"
  before="$(compgen -e | LC_ALL=C sort)"
  setup_ccache >/dev/null 2>&1; setup_lld_linker >/dev/null 2>&1
  new="$(LC_ALL=C comm -13 <(printf "%s\n" "${before}") <(compgen -e | LC_ALL=C sort))"
  carried="$(hailo_cache_env_names | LC_ALL=C sort)"
  echo "UNCARRIED=$(LC_ALL=C comm -23 <(printf "%s\n" "${new}") <(printf "%s\n" "${carried}") | tr "\n" " ")"
  echo "CARRIED=$(printf "%s\n" "${carried}" | grep -xE "SCCACHE_SERVER_UDS|CMAKE_CXX_COMPILER_LAUNCHER|CCACHE_DIR" | tr "\n" " ")"')"
t_assert_eq "UNCARRIED=CMAKE_EXE_LINKER_FLAGS CMAKE_MODULE_LINKER_FLAGS CMAKE_SHARED_LINKER_FLAGS LDFLAGS RUSTFLAGS " \
  "$(printf '%s\n' "${_out}" | grep '^UNCARRIED=')" \
  "a cache variable compiler-cache.sh exports that the carrier drops is a nested build that loses its cache"
t_assert_eq "CARRIED=CCACHE_DIR CMAKE_CXX_COMPILER_LAUNCHER SCCACHE_SERVER_UDS " "$(printf '%s\n' "${_out}" | grep '^CARRIED=')" \
  "the launcher, the server address and the cache dir are among them"

# ---- 3. hailo_nested_configure, against the fake cmake ----------------------------------------
_configure() {  # <mode> <launcher> [channel|nochannel] -> the library call and what the nested build saw
  _hb "printf '%s\n' '${_CHANNEL_LINE}' > \"\${SB}/execute_cmake.cmake\"
    [ '${3:-channel}' = channel ] || printf 'execute_process(COMMAND bash -c x)\n' > \"\${SB}/execute_cmake.cmake\"
    [ -z '$2' ] || export CMAKE_CXX_COMPILER_LAUNCHER='$2'
    real_home=\"\${HOME}\"
    HAILO_NESTED_CACHE='$1' hailo_nested_configure t3 \"\${SB}/nested\" \"\${SB}/execute_cmake.cmake\" -S src -B build; r=\$?
    echo \"NESTED=\$(cat \"\${SB}/nested-launcher\" 2>/dev/null || echo NOT-RUN)\"
    case \"\$(cat \"\${SB}/cmake-home\" 2>/dev/null || echo NOT-RUN)\" in
      NOT-RUN) echo CMAKE-HOME=NOT-RUN ;;
      \"\${real_home}\") echo CMAKE-HOME=caller ;;
      \"\${TMPDIR}\"/hailo-nested-home.*) echo CMAKE-HOME=carrier ;;
      *) echo CMAKE-HOME=other ;;
    esac
    [ \"\${HOME}\" = \"\${real_home}\" ] && echo HOME-KEPT
    ls \"\${TMPDIR}\" | grep -c hailo-nested-home
    (exit \"\${r}\")"
}

t_case "carry: the nested build gets the launcher, the gate passes, the carrier is gone"
_out="$(_configure carry /opt/scripts/core/sccache-launcher.sh)"
t_assert_contains "${_out}" "NESTED=/opt/scripts/core/sccache-launcher.sh" "the carrier must reach the build upstream spawns under env -i"
t_assert_contains "${_out}" "CMAKE-HOME=carrier" "carry runs the configure with HOME at the carrier"
t_assert_contains "${_out}" "[CACHE] hailo/t3: secs=" "one stats line per phase"
t_assert_contains "${_out}" "requests=+10 hits=+0 misses=+0 launcher=/opt/scripts/core/sccache-launcher.sh cap=30 GiB"
t_assert_contains "${_out}" "the nested build's 10 objects reached"
t_assert_contains "${_out}" $'HOME-KEPT\n0\nrc=0' "HOME is redirected for the configure only, and the carrier is removed"

t_case "off: today's nested build, uncached, and the gate only warns"
_out="$(_configure off /opt/scripts/core/sccache-launcher.sh)"
t_assert_contains "${_out}" "NESTED=NONE" "off must leave upstream's clean env exactly as it was"
t_assert_contains "${_out}" "CMAKE-HOME=caller" "off runs the configure with the caller's HOME, as before 2026-09-24"
t_assert_contains "${_out}" "WARNING: HAILO_NESTED_CACHE=off: the nested build compiled 10 objects uncached"
t_assert_contains "${_out}" "rc=0"

t_case "carry without a launcher (USE_CCACHE off): nothing to carry, a warning, no failure"
_out="$(_configure carry "")"
t_assert_contains "${_out}" "NESTED=NONE"
t_assert_contains "${_out}" "CMAKE-HOME=caller" "with nothing to carry the configure keeps the caller's HOME"
t_assert_contains "${_out}" "no compiler-cache launcher resolved"
t_assert_contains "${_out}" "rc=0"

t_case "carry when the spawner no longer carries upstream's channel: rc 1 before cmake runs"
_out="$(_configure carry /opt/scripts/core/sccache-launcher.sh nochannel)"
t_assert_contains "${_out}" "re-derive the carrier (HAILO_NESTED_CACHE=off builds without it)"
t_assert_contains "${_out}" "NESTED=NOT-RUN"
t_assert_contains "${_out}" "CMAKE-HOME=NOT-RUN"
t_assert_contains "${_out}" "rc=1"

t_case "a failed configure keeps its own rc and skips the gate"
_out="$(_hb "printf '%s\n' '${_CHANNEL_LINE}' > \"\${SB}/execute_cmake.cmake\"; printf '7\n' > \"\${SB}/cmake.rc\"
  export CMAKE_CXX_COMPILER_LAUNCHER=sccache
  hailo_nested_configure t3 \"\${SB}/nested\" \"\${SB}/execute_cmake.cmake\" -S s -B b")"
t_assert_contains "${_out}" "the nested build runs through sccache" "the configure was reached"
t_assert_contains "${_out}" "rc=7"
t_assert_eq 0 "$(printf '%s\n' "${_out}" | grep -c -e '\[CACHE\]' -e 'objects')" "no gate verdict on a build that never ran"

# ---- 4. the gate, against a 200-object nested build --------------------------------------------
# $1 mode, $2 launcher, $3 compile requests after (before is 0), $4 nolog|dead|"".
_gate() {
  _hb "mkdir -p \"\${SB}/n\"
    [ '${4:-}' = nolog ] || { printf '# ninja log v5\n'
      for i in \$(seq 1 200); do printf '1\t2\t3\tobj/t%s.cc.o\tabc\n' \"\${i}\"; done
      for i in 1 2 3 4 5; do printf '1\t2\t3\tobj/t%s.cc.o\tabc\n' \"\${i}\"; done
      printf '1\t2\t3\tlibprotobuf.a\tabc\n1\t2\t3\tprotoc\tabc\n'; } > \"\${SB}/n/.ninja_log\"
    echo '$3' > \"\${SB}/req\"
    [ '${4:-}' != dead ] || touch \"\${SB}/sccache.dead\"
    echo \"OBJS=\$(hailo_ninja_objects \"\${SB}/n/.ninja_log\")\"
    hailo_assert_nested_cache_reached \"\${SB}/n\" '$1' '$2' '1700000000|0|0|0|30 GiB'"
}
_L=/opt/scripts/core/sccache-launcher.sh

t_case "object count: unique .o outputs only"
t_assert_contains "$(_gate carry "${_L}" 206)" "OBJS=200"

# _gate_is <rc> <message part> <_gate args...>
_gate_is() {
  local rc="$1" msg="$2" out
  shift 2
  out="$(_gate "$@")"
  t_assert_contains "${out}" "${msg}"
  t_assert_contains "${out}" "rc=${rc}" "the gate's verdict for: $*"
}

t_case "the gate: reached, partial, bypassed, boundary"
_gate_is 0 "reached ${_L} (206 requests)" carry "${_L}" 206
_gate_is 0 "some bypassed it" carry "${_L}" 150
_gate_is 0 "some bypassed it" carry "${_L}" 100   # exactly half the objects: partial, not a bypass
_gate_is 1 "the carrier did not reach it" carry "${_L}" 99
# The as-is number the design probe measured: 1 request for 200 objects.
_gate_is 1 "compiled 200 objects and the cache saw 1 requests: the carrier did not reach it" carry "${_L}" 1

t_case "the gate: what it does not fail on"
_gate_is 0 "HAILO_NESTED_CACHE=off" off "${_L}" 1
_gate_is 0 "no compiler-cache launcher resolved" carry "" 1
_gate_is 0 "counters are unreadable" carry "${_L}" 1 dead

t_case "the gate: a nested build that left no log is a moved build, and fails"
_gate_is 1 "no objects in" carry "${_L}" 206 nolog

# ---- 5. the counters ---------------------------------------------------------------------------
t_case "sccache: the anchored lines, never 'Compile requests executed' or 'Cache hits (C/C++)'"
_out="$(_hb 'echo 206 > "${SB}/req"; echo 34 > "${SB}/hits"; echo 172 > "${SB}/miss"; hailo_cache_counters /opt/scripts/core/sccache-launcher.sh')"
t_assert_contains "${_out}" "206|34|172|30 GiB"
t_assert_contains "$(_hb 'touch "${SB}/sccache.dead"; hailo_cache_counters sccache')" $'-|-|-|-\nrc=0' "an unreadable server is '-', never a failure"

t_case "ccache: hits are direct + preprocessed, requests are hits + misses"
_out="$(_hb 'printf "cache_miss\t1\ndirect_cache_hit\t1\npreprocessed_cache_hit\t2\nlocal_storage_hit\t9\n" > "${SB}/ccache.stats"; hailo_cache_counters ccache')"
t_assert_contains "${_out}" "4|3|1|30.0 GB"
t_assert_contains "$(_hb 'hailo_cache_counters ""; hailo_cache_counters /usr/bin/gcc')" $'-|-|-|-\n-|-|-|-\nrc=0'

t_case "the per-phase line: seconds and deltas from the mark"
_out="$(_hb 'echo 10 > "${SB}/req"; echo 4 > "${SB}/hits"; echo 6 > "${SB}/miss"; m="$(hailo_cache_mark sccache)"
  echo 25 > "${SB}/req"; echo 13 > "${SB}/hits"; echo 12 > "${SB}/miss"; hailo_cache_report tappas sccache "${m}"')"
t_assert_contains "${_out}" "[CACHE] hailo/tappas: secs="
t_assert_contains "${_out}" " requests=+15 hits=+9 misses=+6 launcher=sccache cap=30 GiB"

# ---- 6. pyhailort -------------------------------------------------------------------------------
_IPO_CMAKE='project(pyhailort)

if(CMAKE_VERSION VERSION_GREATER_EQUAL "3.9")
    set(CMAKE_INTERPROCEDURAL_OPTIMIZATION TRUE)
endif()'
t_case "HAILO_PYHAILORT_IPO: off patches upstream's forced IPO out, idempotently; upstream restores it"
_out="$(_hb "printf '%s\n' '${_IPO_CMAKE}' > \"\${SB}/c.txt\"
  hailo_pyhailort_ipo off \"\${SB}/c.txt\" && hailo_pyhailort_ipo off \"\${SB}/c.txt\" && grep -c 'OPTIMIZATION FALSE)' \"\${SB}/c.txt\"
  hailo_pyhailort_ipo upstream \"\${SB}/c.txt\" && grep -c 'OPTIMIZATION TRUE)' \"\${SB}/c.txt\"")"
t_assert_contains "${_out}" "CMAKE_INTERPROCEDURAL_OPTIMIZATION FALSE"$'\n'"1" "off must leave exactly one FALSE line"
t_assert_contains "${_out}" "CMAKE_INTERPROCEDURAL_OPTIMIZATION TRUE"$'\n'"1" "upstream must restore upstream's line in the cached source"
t_assert_contains "${_out}" "rc=0"
_out="$(_hb 'printf "project(pyhailort)\n" > "${SB}/c.txt"; hailo_pyhailort_ipo off "${SB}/c.txt"')"
t_assert_contains "${_out}" "re-derive the pyhailort LTO patch"
t_assert_contains "${_out}" "rc=1"

# The stub every shipped image carried (arm64, 2026-09-22), and a module that exports its init.
_STUB_SYMS='Symbol table '"'"'.dynsym'"'"' contains 6 entries:
   Num:    Value          Size Type    Bind   Vis      Ndx Name
     0: 0000000000000000     0 NOTYPE  LOCAL  DEFAULT  UND
     1: 0000000000000000     0 NOTYPE  WEAK   DEFAULT  UND __gmon_start__
     4: 0000000000000000     0 FUNC    WEAK   DEFAULT  UND __cxa_finalize@GLIBC_2.17 (2)
     5: 0000000000030960     1 OBJECT  GLOBAL DEFAULT   23 __gnu_lto_slim'
_REAL_SYMS='Symbol table '"'"'.dynsym'"'"' contains 3 entries:
   Num:    Value          Size Type    Bind   Vis      Ndx Name
     1: 0000000000000000     0 FUNC    GLOBAL DEFAULT  UND PyModule_Create2
     2: 00000000000a1b20   124 FUNC    GLOBAL DEFAULT   12 PyInit__pyhailort'
_UND_SYMS='     2: 0000000000000000     0 FUNC    GLOBAL DEFAULT  UND PyInit__pyhailort'
# _pyext <dynsym> <machine> <arch> <ipo mode> [wheel|nowheel]
_pyext() {
  _hb "cat > \"\${SB}/dynsym\" <<'SYMS'
$1
SYMS
    printf '%s\n' '$2' > \"\${SB}/machine\"
    so=\"\${SB}/_pyhailort.cpython-314-aarch64-linux-gnu.so\"; : > \"\${so}\"
    case '${5:-so}' in
      wheel|nowheel) mkdir -p \"\${SB}/w/hailo_platform/pyhailort\"
        [ '${5:-so}' = nowheel ] || cp \"\${so}\" \"\${SB}/w/hailo_platform/pyhailort/\"
        : > \"\${SB}/w/hailo_platform/__init__.py\"
        (cd \"\${SB}/w\" && python3 -m zipfile -c \"\${SB}/hailort-5.4.0-cp314-cp314-linux_aarch64.whl\" hailo_platform)
        so=\"\${SB}/hailort-5.4.0-cp314-cp314-linux_aarch64.whl\" ;;
    esac
    hailo_check_pyext \"\${so}\" '$3' '$4'"
}

t_case "a real module passes; the stub, an imported-only init and a wrong machine fail"
t_assert_contains "$(_pyext "${_REAL_SYMS}" AArch64 arm64 off)" "rc=0"
_out="$(_pyext "${_STUB_SYMS}" AArch64 arm64 off)"
t_assert_contains "${_out}" "does not export PyInit__pyhailort: pyhailort linked an empty module"
t_assert_contains "${_out}" "rc=1" "the stub that shipped under all-green gates must now stop the build"
t_assert_contains "$(_pyext "${_UND_SYMS}" AArch64 arm64 off)" "rc=1" "an UND PyInit is an import, not an export"
_out="$(_pyext "${_REAL_SYMS}" 'Advanced Micro Devices X86-64' arm64 off)"
t_assert_contains "${_out}" "ELF machine 'Advanced Micro Devices X86-64', expected 'AArch64'"
t_assert_contains "${_out}" "rc=1"
t_assert_contains "$(_pyext "${_REAL_SYMS}" 'Advanced Micro Devices X86-64' amd64 off)" "rc=0"

t_case "HAILO_PYHAILORT_IPO=upstream: the stub only warns, which is how the image has always shipped"
_out="$(_pyext "${_STUB_SYMS}" AArch64 arm64 upstream)"
t_assert_contains "${_out}" "WARNING: HAILO_PYHAILORT_IPO=upstream ships what upstream's forced LTO builds under lld: "
t_assert_contains "${_out}" "does not export PyInit__pyhailort"
t_assert_eq 0 "$(printf '%s\n' "${_out}" | grep -c 'ERROR')" "a green upstream build prints no ERROR line"
t_assert_contains "${_out}" "rc=0"

t_case "a wheel is checked by the module it carries"
t_assert_contains "$(_pyext "${_REAL_SYMS}" AArch64 arm64 off wheel)" "rc=0"
t_assert_contains "$(_pyext "${_STUB_SYMS}" AArch64 arm64 off wheel)" "rc=1"
_out="$(_pyext "${_REAL_SYMS}" AArch64 arm64 off nowheel)"
t_assert_contains "${_out}" "no _pyhailort*.so in"
t_assert_contains "${_out}" "rc=1"

# build-hailort.sh's install_pyhailort, with /opt/venv moved into the sandbox, under set -e as in the build.
_INSTALL_FN="$(t_fn_src "${BUILD}" install_pyhailort)" || exit 1
_INSTALL_FN="$(printf '%s\n' "${_INSTALL_FN}" | sed 's#/opt/venv#${SB}/venv#g')"
# _install <ipo mode> [stub|install-fails|import-fails|nowheel|novenv]
_install() {
  local syms="${_REAL_SYMS}"
  [ "${2:-}" != stub ] || syms="${_STUB_SYMS}"
  _hb "${_INSTALL_FN}
    die() { printf 'ERROR: %s\n' \"\$*\" >&2; exit 1; }
    info() { printf '[INFO] %s\n' \"\$*\"; }
    warn() { printf 'WARN: %s\n' \"\$*\" >&2; }
    cat > \"\${SB}/dynsym\" <<'SYMS'
${syms}
SYMS
    HAILO_PREFIX=\"\${SB}/hailo\" TARGET_ARCH=arm64 HAILO_PYHAILORT_IPO='$1'
    mkdir -p \"\${HAILO_PREFIX}/wheels\"
    [ '${2:-}' = nowheel ] || : > \"\${HAILO_PREFIX}/wheels/hailort-5.4.0-cp314-cp314-linux_aarch64.whl\"
    case '${2:-}' in
      install-fails) touch \"\${SB}/uv.fails\" ;;
      import-fails) touch \"\${SB}/import.fails\" ;;
      novenv) rm -f \"\${SB}/venv/bin/python\" ;;
    esac
    ( set -e; install_pyhailort ); echo \"IRC=\$?\"
    cat \"\${SB}/uv-args\" 2>/dev/null || echo UV-NOT-RUN"
}

t_case "install_pyhailort: the module installed into /opt/venv is checked; the 3.14 import only warns"
_out="$(_install off)"
t_assert_contains "${_out}" "exports PyInit__pyhailort"
t_assert_contains "${_out}" "[INFO] pyhailort installed into"
t_assert_contains "${_out}" "IRC=0"
t_assert_contains "${_out}" "/venv/bin/python --no-deps --reinstall ${_SB_ROOT}/" "the wheel goes into the app venv"
_out="$(_install off stub)"
t_assert_contains "${_out}" "does not export PyInit__pyhailort"
t_assert_contains "${_out}" "IRC=1" "an off build stops on the stub in /opt/venv"
_out="$(_install off import-fails)"
t_assert_contains "${_out}" "WARN: pyhailort installed but 'import hailo_platform' fails on Python 3.14"
t_assert_contains "${_out}" "IRC=0" "the import is checked but only warns: upstream declares <3.14"

t_case "install_pyhailort under off: a failed install or no wheel stops the build"
_out="$(_install off install-fails)"
t_assert_contains "${_out}" "(fake uv)" "uv's own reason is shown"
t_assert_contains "${_out}" "failed, so the module that ships is unchecked (HAILO_PYHAILORT_IPO=upstream only warns)"
t_assert_contains "${_out}" "IRC=1" "a failed install would ship /opt/venv without a checked module"
_out="$(_install off nowheel)"
t_assert_contains "${_out}" "ERROR: pyhailort: no hailort-*.whl in"
t_assert_contains "${_out}" $'IRC=1\nUV-NOT-RUN'

t_case "install_pyhailort under upstream: the old warnings, never a failure"
_out="$(_install upstream install-fails)"
t_assert_contains "${_out}" "WARN: pyhailort wheel staged at"
t_assert_eq 0 "$(printf '%s\n' "${_out}" | grep -c 'ERROR')" "upstream's failed install is a warning, as before"
t_assert_contains "${_out}" "IRC=0"
_out="$(_install upstream nowheel)"
t_assert_contains "${_out}" "nothing installed into"
t_assert_contains "${_out}" "IRC=0" "no wheel under upstream is a warning, not errexit's silent rc 2"
_out="$(_install upstream stub)"
t_assert_contains "${_out}" "WARNING: HAILO_PYHAILORT_IPO=upstream ships what upstream's forced LTO builds under lld"
t_assert_contains "${_out}" "IRC=0"

t_case "install_pyhailort without /opt/venv (a run outside the image): the wheel stays staged"
for _m in off upstream; do
  _out="$(_install "${_m}" novenv)"
  t_assert_contains "${_out}" "pyhailort wheel stays staged at"
  t_assert_contains "${_out}" $'IRC=0\nUV-NOT-RUN' "${_m}"
done

# ---- 7. cap parity ------------------------------------------------------------------------------
t_case "the Hailo RUN's cache caps are Dockerfile.base's (the runtime image lost base's ENV)"
_hailo_run="$(awk '/id=hailo-build-\$\{TARGETARCH\}/,/^ENV HAILO_PREFIX=/' "${TORCH}")"
for _k in SCCACHE_CACHE_SIZE CCACHE_MAXSIZE; do
  _want="$(grep -oE "^[[:space:]]*${_k}=[^ ]+" "${BASE}" | head -1 | sed -E 's/^[[:space:]]*[A-Z_]+=//')"
  _got="$(printf '%s\n' "${_hailo_run}" | grep -oE "${_k}=[^ ;\\]+" | head -1 | sed 's/^[A-Z_]*=//')"
  t_assert_ok test -n "${_want}"
  t_assert_eq "${_want}" "${_got}" "${_k}: a smaller cap in the Hailo RUN trims the shared cache mount to it"
done

# ---- 8. the wiring -------------------------------------------------------------------------------
t_case "Dockerfile.torch: both switches are final-stage ARGs whose defaults are the library's"
_final="$(sed -n '/^FROM torch AS final$/,$p' "${TORCH}")"
_torch_stage="$(sed -n '/ AS torch$/,/^FROM torch AS final$/p' "${TORCH}")"
t_assert_contains "${_final}" $'\n'"ARG HAILO_NESTED_CACHE=$(_hb 'hailo_nested_cache_mode; echo' | head -1)"$'\n'
t_assert_contains "${_final}" $'\n'"ARG HAILO_PYHAILORT_IPO=$(_hb 'hailo_pyhailort_ipo_mode; echo' | head -1)"$'\n'
t_assert_contains "${_hailo_run}" 'HAILO_NESTED_CACHE="${HAILO_NESTED_CACHE}"'
t_assert_contains "${_hailo_run}" 'HAILO_PYHAILORT_IPO="${HAILO_PYHAILORT_IPO}"'
t_assert_eq 0 "$(printf '%s\n' "${_torch_stage}" | grep -c 'HAILO_')" "the torch stage never sees them, so its venv RUN keeps its key"

t_case "the orchestrators: forwarded like a pin when set, checked before the first stage"
_hailo_args() {  # how many build args a stage gets, then the HAILO_* ones
  t_stage_build_args "$(cd "${SCRIPTS}/../.." && pwd)" arm64 \
    | grep -e '^ARGS=' -e '^HAILO_NESTED_CACHE=' -e '^HAILO_PYHAILORT_IPO=' || true
}
_set="$(HAILO_NESTED_CACHE=off HAILO_PYHAILORT_IPO=upstream _hailo_args)"
t_assert_contains "${_set}" $'\nHAILO_NESTED_CACHE=off\nHAILO_PYHAILORT_IPO=upstream' "an exported switch reaches every stage's build args"
_unset="$(unset HAILO_NESTED_CACHE HAILO_PYHAILORT_IPO; _hailo_args)"
t_assert_ok test "$(printf '%s\n' "${_unset}" | sed -n 's/^ARGS=//p')" -gt 100
t_assert_eq 0 "$(printf '%s\n' "${_unset}" | grep -c '^HAILO_')" "unset, no build arg: the Dockerfile default decides"
t_assert_contains "$(cat "${SCRIPTS}/lib-orchestrator.sh")" "_VERSION_BUILD_ARG_VARS+=(HAILO_NESTED_CACHE HAILO_PYHAILORT_IPO)"
t_assert_contains "$(cat "${SCRIPTS}/lib-orchestrator.sh")" 'source "${_LIB_ORCHESTRATOR_DIR}/03-media/build/hailo/hailo-build-lib.sh"'
t_assert_contains "$(t_fn_src "${SCRIPTS}/build-cross-chain.sh" _chain_validate_stages)" "hailo_validate_knobs || exit 2" \
  "a typo stops the chain at its start, not at the wrapper hours later"
for _o in build-runtime-manifest.sh build-runtime-artifacts.sh; do
  t_assert_eq "  hailo_validate_knobs || exit 2" "$(grep -A1 'runtime_wheels_setup || exit \$?' "${SCRIPTS}/${_o}" | sed -n 2p)" "${_o}"
done

t_case "build-hailort.sh: the configure goes through the carrier, pyhailort through both checks"
_bh="$(cat "${BUILD}")"
t_assert_contains "$(t_fn_src "${BUILD}" build_hailort)" 'hailo_nested_configure hailort-configure "${HAILORT_SRC}/hailort/external/protobuf-build"'
t_assert_contains "$(t_fn_src "${BUILD}" build_hailort)" '"${HAILORT_SRC}/hailort/cmake/execute_cmake.cmake"'
t_assert_eq 0 "$(printf '%s\n' "${_bh}" | grep -c 'cmake -S "${HAILORT_SRC}"')" "a bare configure would bypass the carrier"
t_assert_contains "$(t_fn_src "${BUILD}" build_pyhailort)" 'hailo_pyhailort_ipo "${ipo}" "${platform_dir}/../src/CMakeLists.txt"'
t_assert_contains "$(t_fn_src "${BUILD}" build_pyhailort)" 'CMAKE_BUILD_PARALLEL_LEVEL="$(compute_cpp_heavy_jobs "")"'
t_assert_contains "$(t_fn_src "${BUILD}" build_pyhailort)" 'hailo_check_pyext "${w}"'
t_assert_contains "$(t_fn_src "${BUILD}" install_pyhailort)" 'hailo_check_pyext "${so:-/opt/venv/<no _pyhailort*.so>}"' \
  "the installed bytes are what ships"

t_case "build-hailort.sh stops on a typo with rc 2 before it builds anything, and documents both switches"
# USE_CCACHE=0: media_common_init must not start an sccache server on the host running the suite.
_out="$(env -u HAILO_PYHAILORT_IPO USE_CCACHE=0 USE_LLD=0 HAILO_NESTED_CACHE=bogus TMPDIR="${_SB_ROOT}" bash "${BUILD}" 2>&1)"; _rc=$?
t_assert_eq 2 "${_rc}"
t_assert_contains "${_out}" "HAILO_NESTED_CACHE=bogus: expected carry or off"
t_assert_eq 0 "$(printf '%s\n' "${_out}" | grep -c -e 'fetching' -e 'configuring')" "nothing was fetched or built"
_out="$(env USE_CCACHE=0 USE_LLD=0 bash "${BUILD}" --help 2>/dev/null)"
t_assert_contains "${_out}" "HAILO_NESTED_CACHE    carry (default)"
t_assert_contains "${_out}" "HAILO_PYHAILORT_IPO   off (default)"

t_summary
