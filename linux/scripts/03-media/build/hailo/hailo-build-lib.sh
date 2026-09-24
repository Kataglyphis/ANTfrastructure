# shellcheck shell=bash
# hailo-build-lib.sh — the Hailo build's two switches and the checks behind them.
#   HAILO_NESTED_CACHE=carry|off      carry (default): HailoRT's clean-env nested protobuf build gets
#                                     the compiler cache. off: it builds uncached, as before 2026-09-24.
#   HAILO_PYHAILORT_IPO=off|upstream  off (default): upstream's forced LTO is patched out, so pyhailort
#                                     links a real module. upstream: as shipped, which lld links empty.
# Sourced by build-hailort.sh and (for the knob check) lib-orchestrator.sh: no shell options, nothing
# runs at load. docs/hailo-support.md#the-nested-build-cache-and-pyhailort-two-switches
[ -n "${_HAILO_BUILD_LIB_LOADED:-}" ] && return 0
_HAILO_BUILD_LIB_LOADED=1

# HailoRT 5.4.0 runs every nested cmake step through this (hailort/cmake/execute_cmake.cmake:7).
# shellcheck disable=SC2016  # CMake text, not a shell expansion
_HAILO_CLEAN_ENV_CHANNEL='env -i HOME=$ENV{HOME} PATH=/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin bash -l -c'

_hailo_note() { printf '[hailo] %s\n' "$*" >&2; }
_hailo_warn() { printf '[hailo] WARNING: %s\n' "$*" >&2; }
_hailo_fail() { printf '[hailo] ERROR: %s\n' "$*" >&2; }

# Prints carry or off. Anything else is rc 2.
hailo_nested_cache_mode() {
  case "${HAILO_NESTED_CACHE:-carry}" in
    carry|off) printf '%s' "${HAILO_NESTED_CACHE:-carry}" ;;
    *) _hailo_fail "HAILO_NESTED_CACHE=${HAILO_NESTED_CACHE}: expected carry or off"; return 2 ;;
  esac
}

# Prints off or upstream. Anything else is rc 2.
hailo_pyhailort_ipo_mode() {
  case "${HAILO_PYHAILORT_IPO:-off}" in
    off|upstream) printf '%s' "${HAILO_PYHAILORT_IPO:-off}" ;;
    *) _hailo_fail "HAILO_PYHAILORT_IPO=${HAILO_PYHAILORT_IPO}: expected off or upstream"; return 2 ;;
  esac
}

# Both switches. The chain calls it before its first stage, so a typo never waits for the wrapper.
hailo_validate_knobs() {
  hailo_nested_cache_mode >/dev/null || return 2
  hailo_pyhailort_ipo_mode >/dev/null || return 2
  return 0
}

# The EXPORTED variables a compile reads its cache from: both CMake launchers and every
# SCCACHE_*/CCACHE_* (the sccache server address among them), minus versions.env's pins.
hailo_cache_env_names() {
  compgen -e | grep -E -e '^(SCCACHE_[A-Z0-9_]+|CCACHE_[A-Z0-9_]+|CMAKE_(C|CXX)_COMPILER_LAUNCHER)$' \
    | grep -vE -e '_(VERSION|SHA256)$' || true
}

# hailo_nested_env_home <dir>: the HOME the nested `bash -l` starts in. It mirrors the real HOME
# with symlinks, and its .bash_profile runs the real login file, then exports the cache env.
hailo_nested_env_home() {
  local dir="$1" real="${HOME:-/root}" entry name login="" v tool bin
  for entry in "${real}"/.[!.]* "${real}"/..?* "${real}"/*; do
    [ -e "${entry}" ] || [ -L "${entry}" ] || continue
    name="${entry##*/}"
    [ "${name}" = .bash_profile ] || ln -s "${entry}" "${dir}/${name}" || return 1
  done
  # The clean PATH finds the distro sccache 0.13 first; client and server must be one binary.
  mkdir -p "${dir}/.hailo-cache-bin" || return 1
  for tool in sccache ccache; do
    bin="$(command -v "${tool}" 2>/dev/null || true)"
    [ -z "${bin}" ] || ln -s "${bin}" "${dir}/.hailo-cache-bin/${tool}" || return 1
  done
  for name in .bash_profile .bash_login .profile; do
    if [ -f "${real}/${name}" ]; then login="${real}/${name}"; break; fi
  done
  {
    printf '# hailo-build-lib.sh (HAILO_NESTED_CACHE=carry): the real login file, then the cache env.\n'
    [ -z "${login}" ] || printf '. %q\n' "${login}"
    # shellcheck disable=SC2016  # ${PATH} is the nested shell's
    printf 'export PATH=%q:"${PATH}"\n' "${dir}/.hailo-cache-bin"
    while IFS= read -r v; do printf 'export %s=%q\n' "${v}" "${!v}"; done < <(hailo_cache_env_names)
  } > "${dir}/.bash_profile"
}

# hailo_assert_clean_env_channel <file>: the carrier rides that exact line. A HailoRT bump that
# changes it must re-derive the carrier, so its absence is fatal in carry mode.
hailo_assert_clean_env_channel() {
  if grep -Fq -e "${_HAILO_CLEAN_ENV_CHANNEL}" "$1" 2>/dev/null; then
    return 0
  fi
  _hailo_fail "$1 no longer spawns its nested build through '${_HAILO_CLEAN_ENV_CHANNEL}': re-derive the carrier (HAILO_NESTED_CACHE=off builds without it)"
  return 1
}

# hailo_cache_counters <launcher> -> "requests|hits|misses|cap" of the cache that launcher feeds, or
# "-|-|-|-". Anchored: sccache also prints "Compile requests executed" and "Cache hits (C/C++)".
hailo_cache_counters() {
  case "${1:-}" in
    *sccache*)
      { sccache --show-stats 2>/dev/null || true; } | awk '
        /^Compile requests[[:space:]]+[0-9]+[[:space:]]*$/ { r = $NF }
        /^Cache hits[[:space:]]+[0-9]+[[:space:]]*$/ { h = $NF }
        /^Cache misses[[:space:]]+[0-9]+[[:space:]]*$/ { m = $NF }
        /^Max cache size[[:space:]]/ { c = $0; sub(/^Max cache size[[:space:]]+/, "", c) }
        END { if (r == "") print "-|-|-|-"; else printf "%d|%d|%d|%s\n", r, h, m, c }' ;;
    *ccache*)
      { ccache --print-stats 2>/dev/null || true
        printf 'max_size\t%s\n' "$(ccache --get-config max_size 2>/dev/null || true)"; } | awk -F'\t' '
        $1 == "direct_cache_hit" || $1 == "preprocessed_cache_hit" { h += $2; seen = 1 }
        $1 == "cache_miss" { m = $2; seen = 1 }
        $1 == "max_size" { c = $2 }
        END { if (!seen) print "-|-|-|-"; else printf "%d|%d|%d|%s\n", h + m, h, m, c }' ;;
    *) printf '%s\n' '-|-|-|-' ;;
  esac
}

# hailo_cache_mark <launcher> -> "epoch|requests|hits|misses|cap": where a phase starts.
hailo_cache_mark() {
  printf '%s|%s\n' "$(date +%s)" "$(hailo_cache_counters "${1:-}")"
}

# hailo_cache_report <phase> <launcher> <mark>: one stderr line, this phase's time and cache deltas.
hailo_cache_report() {
  local t0 r0 h0 m0 r1 h1 m1 cap secs
  IFS='|' read -r t0 r0 h0 m0 _ <<<"$3"
  IFS='|' read -r r1 h1 m1 cap <<<"$(hailo_cache_counters "$2")"
  secs=$(( $(date +%s) - ${t0:-0} ))
  if [ "${r0}" = - ] || [ "${r1}" = - ]; then
    printf '[CACHE] hailo/%s: secs=%d, no counters (launcher=%s)\n' "$1" "${secs}" "${2:-none}" >&2
    return 0
  fi
  printf '[CACHE] hailo/%s: secs=%d requests=+%d hits=+%d misses=+%d launcher=%s cap=%s\n' \
    "$1" "${secs}" "$((r1 - r0))" "$((h1 - h0))" "$((m1 - m0))" "$2" "${cap:-?}" >&2
}

# hailo_ninja_objects <.ninja_log>: the object files that build compiled; empty without the log.
hailo_ninja_objects() {
  [ -f "$1" ] || return 0
  awk -F'\t' 'NR > 1 && $4 ~ /\.o(bj)?$/ && !seen[$4]++ { n++ } END { print n + 0 }' "$1"
}

# hailo_assert_nested_cache_reached <nested build dir> <mode> <launcher> <mark before>
# carry with a launcher: rc 1 when fewer requests reached the cache than half the objects the
# nested build compiled, or it left no .ninja_log. Everything else warns and returns 0.
hailo_assert_nested_cache_reached() {
  local dir="$1" mode="$2" launcher="$3" objs req r0 r1
  objs="$(hailo_ninja_objects "${dir}/.ninja_log")"
  if [ "${mode}" = off ]; then
    _hailo_warn "HAILO_NESTED_CACHE=off: the nested build compiled ${objs:-its} objects uncached, as before 2026-09-24"
    return 0
  fi
  if [ -z "${launcher}" ]; then
    _hailo_warn "no compiler-cache launcher resolved (USE_CCACHE=${USE_CCACHE:-}): the nested build ran uncached"
    return 0
  fi
  if [ -z "${objs}" ] || [ "${objs}" -eq 0 ]; then
    _hailo_fail "no objects in ${dir}/.ninja_log: the nested build moved; re-derive the carrier (HAILO_NESTED_CACHE=off builds without it)"
    return 1
  fi
  IFS='|' read -r _ r0 _ <<<"$4"
  IFS='|' read -r r1 _ <<<"$(hailo_cache_counters "${launcher}")"
  if [ "${r0}" = - ] || [ "${r1}" = - ]; then
    _hailo_warn "the ${launcher} counters are unreadable: the nested build's ${objs} objects are unverified"
    return 0
  fi
  req=$((r1 - r0))
  if [ $((2 * req)) -lt "${objs}" ]; then
    _hailo_fail "the nested build compiled ${objs} objects and the cache saw ${req} requests: the carrier did not reach it, or no server of this RUN answered it (sccache-launcher lines above; HAILO_NESTED_CACHE=off builds without it)"
    return 1
  fi
  if [ "${req}" -lt "${objs}" ]; then
    _hailo_warn "the nested build compiled ${objs} objects and the cache saw ${req} requests: some bypassed it"
    return 0
  fi
  _hailo_note "the nested build's ${objs} objects reached ${launcher} (${req} requests)"
}

# hailo_nested_configure <phase> <nested build dir> <file that spawns it> <cmake args...>: the
# configure under HAILO_NESTED_CACHE, then the gate on the nested build it ran.
hailo_nested_configure() {
  local phase="$1" nested="$2" spawner="$3" mode launcher before carrier rc=0
  shift 3
  mode="$(hailo_nested_cache_mode)" || return 2
  launcher="${CMAKE_CXX_COMPILER_LAUNCHER:-}"
  before="$(hailo_cache_mark "${launcher}")"
  if [ "${mode}" = carry ] && [ -n "${launcher}" ]; then
    hailo_assert_clean_env_channel "${spawner}" || return 1
    carrier="$(mktemp -d "${TMPDIR:-/tmp}/hailo-nested-home.XXXXXX")" || return 1
    if hailo_nested_env_home "${carrier}"; then
      _hailo_note "HAILO_NESTED_CACHE=carry: the nested build runs through ${launcher}"
      HOME="${carrier}" cmake "$@" || rc=$?
    else
      rc=1
    fi
    rm -rf "${carrier}"
  else
    cmake "$@" || rc=$?
  fi
  [ "${rc}" -eq 0 ] || return "${rc}"
  hailo_cache_report "${phase}" "${launcher}" "${before}"
  hailo_assert_nested_cache_reached "${nested}" "${mode}" "${launcher}" "${before}"
}

# hailo_pyhailort_ipo <off|upstream> <bindings/python/src/CMakeLists.txt>: off turns upstream's forced
# IPO off (a normal variable, so no -D reaches it); upstream restores it. rc 1 without the line.
hailo_pyhailort_ipo() {
  local mode="$1" file="$2" from=TRUE to=FALSE
  if [ "${mode}" = upstream ]; then from=FALSE; to=TRUE; fi
  if ! grep -Eq -e '^[[:space:]]*set\(CMAKE_INTERPROCEDURAL_OPTIMIZATION (TRUE|FALSE)\)' "${file}" 2>/dev/null; then
    _hailo_fail "${file}: no set(CMAKE_INTERPROCEDURAL_OPTIMIZATION ...) line; re-derive the pyhailort LTO patch"
    return 1
  fi
  sed -i -E "s/^([[:space:]]*set\(CMAKE_INTERPROCEDURAL_OPTIMIZATION) ${from}\)/\1 ${to})/" "${file}" || return 1
  grep -Eq -e "^[[:space:]]*set\(CMAKE_INTERPROCEDURAL_OPTIMIZATION ${to}\)" "${file}" || return 1
  _hailo_note "HAILO_PYHAILORT_IPO=${mode}: pyhailort builds with CMAKE_INTERPROCEDURAL_OPTIMIZATION ${to}"
}

# readelf's Machine: text for a Hailo target arch.
_hailo_elf_machine() {
  case "$1" in
    amd64) printf '%s' 'Advanced Micro Devices X86-64' ;;
    arm64) printf '%s' 'AArch64' ;;
    *) printf '%s' "$1" ;;
  esac
}

# hailo_assert_pyext_exports <.so> <target arch>: rc 1, with the reason in _HAILO_PYEXT_WHY, unless it
# is built for that arch and exports PyInit__pyhailort. The stub that shipped had slim-LTO objects.
hailo_assert_pyext_exports() {
  local so="$1" want machine
  want="$(_hailo_elf_machine "$2")"
  machine="$({ readelf -h "${so}" 2>/dev/null || true; } | awk -F': *' '/^ *Machine:/ { print $2; exit }')"
  if [ "${machine}" != "${want}" ]; then
    _HAILO_PYEXT_WHY="${so##*/}: ELF machine '${machine:-unreadable}', expected '${want}'"
    return 1
  fi
  if ! { readelf --dyn-syms -W "${so}" 2>/dev/null || true; } \
       | awk '$4 == "FUNC" && $7 != "UND" && $8 == "PyInit__pyhailort" { f = 1 } END { exit !f }'; then
    _HAILO_PYEXT_WHY="${so##*/} does not export PyInit__pyhailort: pyhailort linked an empty module"
    return 1
  fi
  _hailo_note "${so##*/}: ${machine}, exports PyInit__pyhailort"
}

# hailo_check_pyext <wheel or .so> <target arch> <ipo mode>: the export check. Fatal when the
# build claims a real module (HAILO_PYHAILORT_IPO=off); upstream's own build only warns.
hailo_check_pyext() {
  local subject="$1" so="$1" tmp="" rc=0
  _HAILO_PYEXT_WHY="no _pyhailort*.so in ${subject}"
  case "${subject}" in
    *.whl)
      tmp="$(mktemp -d "${TMPDIR:-/tmp}/hailo-pyext.XXXXXX")" || return 1
      python3 -m zipfile -e "${subject}" "${tmp}" >/dev/null 2>&1 || true
      so="$(find "${tmp}" -name '_pyhailort*.so' -print -quit 2>/dev/null || true)" ;;
  esac
  if [ -z "${so}" ] || [ ! -f "${so}" ]; then
    rc=1
  else
    hailo_assert_pyext_exports "${so}" "$2" || rc=1
  fi
  [ -z "${tmp}" ] || rm -rf "${tmp}"
  if [ "${rc}" -eq 0 ]; then
    return 0
  fi
  if [ "$3" = upstream ]; then
    _hailo_warn "HAILO_PYHAILORT_IPO=upstream ships what upstream's forced LTO builds under lld: ${_HAILO_PYEXT_WHY}"
    return 0
  fi
  _hailo_fail "${_HAILO_PYEXT_WHY}"
  return 1
}
