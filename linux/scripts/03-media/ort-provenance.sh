#!/usr/bin/env bash
# ort-provenance.sh - G2 (owner rule 2026-09-23): a consumer's build tree (dir links followed), records, logs and fetch caches hold
# no ORT but the chain's; a pass stamps it for G1. Source-only, mounted per file. NOT covered: a foreign ORT under a non-ORT name.

# ORT headers and binaries, compared byte for byte by name (.pc/.cmake metadata is not ORT code). Matched lower-cased.
_ORTG_CODE_RE='^(lib)?onnxruntime[^/]*\.(h|hpp|inc|lib|dll|pyd|a|so(\.[0-9]+)*)$|_provider_factory\.h$|^onnxruntime_pybind11_state'
# Any ORT library: the core, a provider, a static component (libonnxruntime_session.a), the pybind module; see _ortg_is_bin.
_ORTG_BIN_RE='^(lib)?onnxruntime(_[a-z0-9_]+)?\.(dll|lib|a|so(\.[0-9]+)*)$|^onnxruntime_pybind11_state[^/]*\.(pyd|so)$'
# A fetch names a download host, a package id, a release archive, or has ORT as a fetch verb's object.
_ORTG_FETCH_RE='github\.com/microsoft/onnxruntime(-genai)?/releases/download|pkgs\.dev\.azure\.com|nuget\.org/[^[:space:]]*onnxruntime|microsoft\.ml\.onnxruntime|microsoft\.(windows\.)?ai\.machinelearning|(cdn|ort)\.pyke\.io|(pythonhosted|pypi)\.org/[^[:space:]]*onnxruntime|onnxruntime-(win|linux|osx|android)-[a-z0-9_]+-[0-9]|(^|[^[:alnum:]_-])(collecting|downloading|fetching|extracting|populating)[[:space:]]+(onnx runtime|onnxruntime|ortlib)|apt(-get)?[[:space:]]+install.*libonnxruntime'
# The flag a path argument may carry in a record (-I/opt/x); it is not part of the path.
_ORTG_FLAG_RE='(-I|-L|-isystem|-idirafter|-iquote)'

_ortg_sha() {  # <file>: its sha256, or "unreadable" (a dangling link), which matches no chain file
  local sum
  sum="$(sha256sum 2>/dev/null < "$1")" || sum="unreadable"
  printf '%s\n' "${sum%% *}"
}

_ortg_under() {  # <path> <root>...: 0 when path is a root or sits below one
  local p="$1" r
  shift
  for r in "$@"; do
    r="${r%/}"
    [ -n "${r}" ] || continue
    case "${p}" in "${r}" | "${r}"/*) return 0 ;; esac
  done
  return 1
}

_ortg_is_bin() {  # <name>: 0 for an ORT library name; GenAI's and extensions' own libraries are not ORT
  local lc="${1,,}"
  case "${lc}" in *onnxruntime[-_.]genai* | *onnxruntime[-_.]extensions*) return 1 ;; esac
  if [[ "${lc}" =~ ${_ORTG_BIN_RE} ]]; then return 0; fi
  return 1
}

_ortg_index() {  # <chain-root>...: fills _ORTG_SHA (name -> " sha ..."), _ORTG_CORE, _ORTG_CAPI; prints anchor gaps
  local root f name sha core all
  all="$(printf '%s ' "$@")"
  declare -gA _ORTG_SHA=() _ORTG_CORE=()
  _ORTG_CAPI=""
  _ORTG_ROOTS=()
  for root in "$@"; do
    [ -d "${root}/lib" ] || continue
    _ORTG_ROOTS+=("${root%/}")
    while IFS= read -r -d '' f; do
      name="${f##*/}"
      [[ "${name,,}" =~ ${_ORTG_CODE_RE} ]] || continue
      sha="$(_ortg_sha "${f}")"
      _ORTG_SHA["${name}"]+=" ${sha} "
      if [ "${name}" = onnxruntime_c_api.h ] && [ -z "${_ORTG_CAPI}" ]; then _ORTG_CAPI="${sha}"; fi
    done < <(find -L "${root}/include" "${root}/lib" -type f -print0 2>/dev/null || true)
    for core in "${root}/lib/libonnxruntime.so.1" "${root}/lib/libonnxruntime.so"; do
      if [ -e "${core}" ]; then _ORTG_CORE["${root%/}"]="$(_ortg_sha "${core}")"; break; fi
    done
  done
  if [ "${#_ORTG_ROOTS[@]}" -eq 0 ]; then echo "no chain ONNX Runtime at any of: ${all% }"; fi
  for name in onnxruntime_c_api.h libonnxruntime.so; do
    [ -n "${_ORTG_SHA[${name}]:-}" ] || echo "the chain ONNX Runtime (${all% }) has no ${name} to compare against"
  done
  return 0
}

_ortg_name_finding() {  # <path> [suffix]: an ORT archive, a chain name with other bytes, or an ORT binary the chain lacks
  local path="$1" sfx="${2:-}" name="${1##*/}" lc
  lc="${name,,}"
  case "${lc}" in
    *onnxruntime[-_.]genai* | *onnxruntime[-_.]extensions* | *onnxruntimegenai*) ;;
    *onnxruntime*.zip | *onnxruntime*.nupkg | *onnxruntime*.tgz | *onnxruntime*.txz | *onnxruntime*.tar | *onnxruntime*.tar.* | \
    *onnxruntime*.whl | *onnxruntime*.aar | *onnxruntime*.7z | *.tar.lzma2)
      echo "an ONNX Runtime archive: ${path}${sfx}"
      return 0 ;;
  esac
  if [ -n "${_ORTG_SHA[${name}]:-}" ]; then
    _ORTG_COMPARED=$((_ORTG_COMPARED + 1))
    case "${_ORTG_SHA[${name}]}" in *" $(_ortg_sha "${path}") "*) ;; *) echo "${path} is not the chain's ${name} (foreign ONNX Runtime bytes)${sfx}" ;; esac
  elif _ortg_is_bin "${name}"; then
    echo "${path} is an ONNX Runtime binary the chain does not build${sfx}"
  fi
  return 0
}

_ortg_scan_root() {  # <root> <via-link>: one root's fetched ORT dirs and ORT-named files; its dir links land in _ORTG_FOUND_LINKS
  local r="$1" sfx="" kind path err n
  if [ -n "$2" ]; then sfx=" (through the link $2)"; fi
  err="$(mktemp)" || { echo "cannot make a temp file to scan ${r}"; return 0; }
  n="$( { find -H "${r}" -type f -printf . 2>/dev/null || true; } | wc -c)"
  _ORTG_FILES=$((_ORTG_FILES + n))
  while IFS=$'\t' read -r kind path; do
    case "${kind}" in
      L) _ORTG_FOUND_LINKS+=("${path}") ;;
      D) echo "fetched ONNX Runtime content at ${path}${sfx}" ;;
      F) _ortg_name_finding "${path}" "${sfx}" ;;
    esac
  done < <(find -H "${r}" \( -type l -xtype d -printf 'L\t%p\n' \) -o \( -type d \( -name 'ortlib-src' -o -name 'ortlib-subbuild' \
        -o -name 'ortlib-build' -o -name 'onnxruntime-src' -o -name 'onnxruntime-subbuild' -o -name 'onnxruntime-build' -o -name 'ort.pyke.io' \
        -o -iname 'onnxruntime-linux-*' -o -iname 'onnxruntime-win-*' -o -iname 'onnxruntime-osx-*' -o -iname 'onnxruntime-android-*' \
        -o \( -iname 'microsoft.ml.onnxruntime*' ! -iname 'microsoft.ml.onnxruntimegenai*' \) \) -printf 'D\t%p\n' \) \
        -o \( \( -type f -o -type l \) \( -iname '*onnxruntime*' -o -name '*_provider_factory.h' -o -name '*.tar.lzma2' \) \
        -printf 'F\t%p\n' \) 2>"${err}" || true)
  if [ -s "${err}" ]; then echo "cannot read all of ${r}: $(head -n 1 "${err}")"; fi
  rm -f "${err}"
  return 0
}

_ortg_holds() {  # <dir> <path>...: 0 when <dir> is / or holds one of the paths
  local d="$1" p
  shift
  if [ "${d}" = / ]; then return 0; fi
  for p in "$@"; do
    if _ortg_under "${p}" "${d}"; then return 0; fi
  done
  return 1
}

_ortg_tree_findings() {  # <root>...: every root, hidden files too, and each dir link's target that leaves the roots and the chain
  local r l real
  local -a within=() queue=() vias=()
  local -A seen=()
  for r in "$@"; do
    if [ ! -d "${r}" ]; then echo "no tree at ${r} to check"; continue; fi
    queue+=("${r}")
    vias+=("")
    within+=("${r%/}" "$(readlink -f -- "${r}" 2>/dev/null || true)")
  done
  while [ "${#queue[@]}" -gt 0 ]; do
    _ORTG_FOUND_LINKS=()
    _ortg_scan_root "${queue[0]}" "${vias[0]}"
    queue=("${queue[@]:1}")
    vias=("${vias[@]:1}")
    for l in "${_ORTG_FOUND_LINKS[@]+"${_ORTG_FOUND_LINKS[@]}"}"; do
      _ORTG_TREE_LINKS+=("${l}")
      real="$(readlink -f -- "${l}" 2>/dev/null || true)"
      if [ ! -d "${real}" ] || _ortg_under "${real}" "${within[@]}" "${_ORTG_REFS_AT[@]+"${_ORTG_REFS_AT[@]}"}"; then continue; fi
      if _ortg_holds "${real}" "${within[@]}"; then echo "the link ${l} points at ${real}, which holds the tree itself"; continue; fi
      if [ -z "${seen[${real}]:-}" ]; then
        seen["${real}"]=1
        queue+=("${real}")
        vias+=("${l}")
      fi
    done
  done
  return 0
}

_ortg_pyke_findings() {  # <cache-dir>...: anything in pyke's ORT download cache is a foreign ORT
  local c f
  for c in "$@"; do
    [ -d "${c}" ] || continue
    f="$(find -H "${c}" -type f -print -quit 2>/dev/null || true)"
    if [ -n "${f}" ]; then echo "pyke's ORT download cache holds ${f}"; fi
  done
  return 0
}

# ort_gate_default_caches: "<kind>TAB<dir>" per fetch cache G2 always grades, each at its tool's override, else its default.
# They cover every fetch-cache mount of a G2 RUN; docs/onnxruntime-single-source.md#the-fetch-caches-g2-grades
ort_gate_default_caches() {
  local xdg="${XDG_CACHE_HOME:-${HOME:-/root}/.cache}" cargo="${CARGO_HOME:-${HOME:-/root}/.cargo}"
  printf '%s\t%s\n' pyke "${xdg}/ort.pyke.io" pip "${PIP_CACHE_DIR:-${xdg}/pip}" uv "${UV_CACHE_DIR:-${xdg}/uv}" \
    tree "${cargo}/registry" tree "${cargo}/git" tree "${FFMPEG_SDK_CACHE:-/var/cache/ffmpeg-sdks}" \
    tree "${NUGET_PACKAGES:-${HOME:-/root}/.nuget/packages}"
}

_ortg_uv_findings() {  # <uv-cache>: an ORT wheel uv fetched over HTTP (.http); a local chain wheel is cached as .rev
  local line pkg
  while IFS= read -r line; do
    case "${line}" in
      H$'\t'*) pkg="${line%/*}" ;;
      *) echo "cannot read all of $1: ${line}"; continue ;;
    esac
    pkg="${pkg##*/}"
    case "${pkg,,}" in
      onnxruntime-genai* | onnxruntime-extensions*) ;;
      onnxruntime | onnxruntime-*)
        echo "uv's cache holds an ONNX Runtime wheel downloaded over HTTP: ${line#H$'\t'}" ;;
    esac
  done < <(find -H "$1" -mindepth 4 -maxdepth 5 -path '*/wheels-v*/*' -type f -name '*.http' -printf 'H\t%p\n' 2>&1 || true)
  return 0
}

_ortg_pip_findings() {  # <pip-cache>: an HTTP body that is an ORT wheel (a zip with onnxruntime/ members); pip >= 23.3
  local rel out
  [ -d "$1/http-v2" ] || return 0
  out="$(python3 - "$1/http-v2" <<'PY'
import os
import sys
import zipfile


def ort_wheel(path):  # open() first: is_zipfile() swallows the OSError of a body it cannot read
    with open(path, "rb") as fh:
        if fh.read(4) != b"PK\x03\x04":
            return False
    with zipfile.ZipFile(path) as zf:
        return any(n.startswith("onnxruntime/") for n in zf.namelist())


for root, _, files in os.walk(sys.argv[1], onerror=lambda e: print("E cannot read %s" % e)):
    for name in files:
        rel = os.path.relpath(os.path.join(root, name), sys.argv[1]).replace(os.sep, "/")
        try:
            if ort_wheel(os.path.join(root, name)):
                print("W " + rel)
        except (OSError, zipfile.BadZipFile) as exc:
            print("E cannot read the cached file %s: %s" % (rel, exc))
PY
)" || { echo "cannot inspect pip's HTTP cache at $1/http-v2 (python3 failed)"; return 0; }
  while IFS= read -r rel; do
    rel="${rel%$'\r'}"
    case "${rel}" in
      "W "*) echo "pip's HTTP cache holds an ONNX Runtime wheel: $1/http-v2/${rel#W }" ;;
      "E "*) echo "pip's HTTP cache at $1/http-v2: ${rel#E }" ;;
    esac
  done <<< "${out}"
  return 0
}

_ortg_cache_findings() {  # <kind> <dir>: one fetch cache, graded by what its tool keeps there; an absent one is skipped
  [ -d "$2" ] || return 0
  case "$1" in
    pyke) _ortg_pyke_findings "$2" ;;
    uv) _ortg_uv_findings "$2" ;;
    pip) _ortg_pip_findings "$2"; _ortg_tree_findings "$2" ;;
    *) if [ "${2##*/}" = ort.pyke.io ]; then _ortg_pyke_findings "$2"; else _ortg_tree_findings "$2"; fi ;;
  esac
  return 0
}

_ortg_caches() {  # the default caches, then each --cache as a tree; a subshell, so no cache walk moves the tree's counters
  local kind dir
  (
    while IFS=$'\t' read -r kind dir; do _ortg_cache_findings "${kind}" "${dir}"; done < <(ort_gate_default_caches)
    for dir in "${_ORTG_CACHES[@]+"${_ORTG_CACHES[@]}"}"; do _ortg_cache_findings tree "${dir}"; done
  )
  return 0
}

_ortg_shim_findings() {  # a shim's links must land in the chain or in the shim itself
  local s l real
  for s in "${_ORTG_SHIMS[@]+"${_ORTG_SHIMS[@]}"}"; do
    if [ ! -d "${s}" ]; then echo "no shim at ${s}"; continue; fi
    while IFS= read -r -d '' l; do
      real="$(readlink -f -- "${l}" 2>/dev/null || true)"
      if [ -z "${real}" ] || [ ! -e "${real}" ]; then echo "the shim link ${l} is dangling"; continue; fi
      if ! _ortg_under "${real}" "${_ORTG_REAL_ROOTS[@]+"${_ORTG_REAL_ROOTS[@]}"}" "$(readlink -f -- "${s}")"; then
        echo "the shim link ${l} leaves the chain for ${real}"
      fi
    done < <(find "${s}" -type l -print0 2>/dev/null || true)
  done
  return 0
}

_ortg_text_paths() {  # stdin: record text; its absolute paths, with ninja's `$ ` kept in the path and a quoted path kept whole
  local q=$'\x03'
  LC_ALL=C sed -E -e 's/\$\$/\x02/g' -e 's/\$ /\x01/g' -e 's/\$:/:/g' -e "s#\"${_ORTG_FLAG_RE}?(/[^\"]+)\"# ${q}\\2${q} #g" \
    | { LC_ALL=C grep -o -E -e "${q}/[^${q}]+${q}" -e "(^|[[:space:]\"'=:,;(])${_ORTG_FLAG_RE}?/[^[:space:]\"';:,()<>|*?${q}]+" || true; } \
    | LC_ALL=C sed -E -e "s#^[^/${q}]*##" -e "s#${q}##g" -e 's/\x01/ /g' -e 's/\x02/$/g'
}

_ortg_arg_paths() {  # stdin: one argument per line; one that is a single absolute path is kept whole, spaces too; the rest is text
  local lines
  lines="$(awk -v flag="^${_ORTG_FLAG_RE}" '{ s = $0; sub(/^[ \t]+/, "", s); sub(/[ \t\r]+$/, "", s); gsub(/^"|"$/, "", s); sub(flag, "", s)
    if (s ~ /^\// && s !~ /[ \t][-\/][A-Za-z]/) print "P" s; else print "T" $0 }')" || return 0
  printf '%s\n' "${lines}" | sed -n -e 's/^P//p'
  printf '%s\n' "${lines}" | sed -n -e 's/^T//p' | _ortg_text_paths
}

_ortg_tokens() {  # <record>: the absolute paths it names, CMakeCache's unquoted values whole; a JSON string is a quoted path
  case "${1##*/}" in
    CMakeCache.txt) { sed -n -E -e 's/^[^#/][^:=]*:[A-Za-z_]+=//p' -- "$1" || true; } | tr ';' '\n' | _ortg_arg_paths ;;
    *) _ortg_text_paths < "$1" ;;
  esac | { grep -v -e '^//' -e '^$' || true; } | LC_ALL=C sort -u || true
}

_ortg_ort_segment() {  # <path>: 0 when a path segment names an ORT distribution or a fetched ORT
  case "${1,,}/" in
    */onnxruntime/* | */ortlib-src/* | */ort.pyke.io/* | */onnxruntime-src/* | */onnxruntime-build/* | */onnxruntime-subbuild/* | \
    */onnxruntime-linux-* | */onnxruntime-win-* | */onnxruntime-osx-* | */onnxruntime-android-*) return 0 ;;
    */microsoft.ml.onnxruntimegenai*) return 1 ;;
    */microsoft.ml.onnxruntime*) return 0 ;;
  esac
  return 1
}

_ortg_record_roots() {  # what a record path is judged against: _ORTG_REFS_AT (chain + shims), _ORTG_TREES_AT
  local d
  _ORTG_REFS_AT=("${_ORTG_ROOTS[@]+"${_ORTG_ROOTS[@]}"}" "${_ORTG_REAL_ROOTS[@]+"${_ORTG_REAL_ROOTS[@]}"}" "${_ORTG_SHIMS[@]+"${_ORTG_SHIMS[@]}"}")
  _ORTG_TREES_AT=("${_ORTG_TREES[@]+"${_ORTG_TREES[@]}"}")
  for d in "${_ORTG_SHIMS[@]+"${_ORTG_SHIMS[@]}"}"; do _ORTG_REFS_AT+=("$(readlink -f -- "${d}" 2>/dev/null || true)"); done
  for d in "${_ORTG_TREES[@]+"${_ORTG_TREES[@]}"}"; do _ORTG_TREES_AT+=("$(readlink -f -- "${d}" 2>/dev/null || true)"); done
  return 0
}

_ortg_intree() {  # <path>: a tree path a record names; an ORT file name lands in _ORTG_INTREE to be graded
  local name="${1##*/}"
  if [ -n "${_ORTG_SHA[${name}]:-}" ] || _ortg_is_bin "${name}"; then _ORTG_INTREE+=("$1"); fi
  return 0
}

_ortg_split_tokens() {  # <record>: counts chain references; tree paths with an ORT name land in _ORTG_INTREE, the rest in _ORTG_OTHERS
  local tok i
  local -a raw=() reals=()
  _ORTG_OTHERS=()
  _ORTG_OTHER_REALS=()
  _ORTG_INTREE=()
  while IFS= read -r tok; do
    [ -n "${tok}" ] || continue
    _ORTG_TOKENS=$((_ORTG_TOKENS + 1))
    if _ortg_under "${tok}" "${_ORTG_REFS_AT[@]+"${_ORTG_REFS_AT[@]}"}"; then _ORTG_REFS=$((_ORTG_REFS + 1))
    elif _ortg_under "${tok}" "${_ORTG_TREES_AT[@]+"${_ORTG_TREES_AT[@]}"}" \
        && ! _ortg_under "${tok}" "${_ORTG_TREE_LINKS[@]+"${_ORTG_TREE_LINKS[@]}"}"; then _ortg_intree "${tok}"
    else raw+=("${tok}"); fi
  done < <(_ortg_tokens "$1")
  [ "${#raw[@]}" -gt 0 ] || return 0
  # One realpath pass per record: an ORT_HOME link to the chain counts as it, a path through a tree's dir link is read at its target.
  mapfile -t reals < <(printf '%s\0' "${raw[@]}" | xargs -0 realpath -m -- 2>/dev/null || true)
  if [ "${#reals[@]}" -ne "${#raw[@]}" ]; then echo "$1: only ${#reals[@]} of its ${#raw[@]} path(s) resolved"; return 0; fi
  for i in "${!raw[@]}"; do
    if _ortg_under "${reals[${i}]:-}" "${_ORTG_REFS_AT[@]+"${_ORTG_REFS_AT[@]}"}"; then _ORTG_REFS=$((_ORTG_REFS + 1))
    elif _ortg_under "${reals[${i}]}" "${_ORTG_TREES_AT[@]+"${_ORTG_TREES_AT[@]}"}"; then _ortg_intree "${raw[${i}]}"
    else
      _ORTG_OTHERS+=("${raw[${i}]}")
      _ORTG_OTHER_REALS+=("${reals[${i}]}")
    fi
  done
  return 0
}

_ortg_token_finding() {  # <record> <path> <real path>: one path outside the chain, shims and trees; a dir to search lands in _ORTG_DIRS
  local rec="$1" tok="$2" name="${2##*/}" sub
  if [ -n "${_ORTG_SHA[${name}]:-}" ] || _ortg_is_bin "${name}"; then
    if [ -f "${tok}" ]; then _ortg_name_finding "${tok}" | sed -e "s#^#${rec}: #"
    else echo "${rec} names ${tok}, an ONNX Runtime file outside the chain (not on disk to compare)"; fi
  elif _ortg_ort_segment "${tok}" || _ortg_ort_segment "$3"; then
    echo "${rec} names an ONNX Runtime path outside the chain: ${tok}"
  elif [ -d "${tok}" ]; then
    _ORTG_DIRS+=("${tok}")
    for sub in onnxruntime onnxruntime/core/session; do
      if [ -d "${tok}/${sub}" ]; then _ORTG_DIRS+=("${tok}/${sub}"); fi
    done
  fi
  return 0
}

_ortg_record_findings() {  # <record>...: ORT only under the chain, a shim or a tree; a foreign search dir holding ORT fails
  local rec i f d
  for rec in "$@"; do
    if [ ! -f "${rec}" ]; then echo "the build record ${rec} is missing"; continue; fi
    _ORTG_DIRS=()
    _ortg_split_tokens "${rec}"
    for f in "${_ORTG_INTREE[@]+"${_ORTG_INTREE[@]}"}"; do
      if [ -f "${f}" ]; then _ortg_name_finding "${f}" | sed -e "s#^#${rec}: #"; fi
    done
    for i in "${!_ORTG_OTHERS[@]}"; do _ortg_token_finding "${rec}" "${_ORTG_OTHERS[${i}]}" "${_ORTG_OTHER_REALS[${i}]}"; done
    [ "${#_ORTG_DIRS[@]}" -gt 0 ] || continue
    while IFS= read -r -d '' d; do
      _ortg_name_finding "${d}" | sed -e "s#^#${rec} searches ${d%/*}: #"
    done < <(find -H "${_ORTG_DIRS[@]}" -maxdepth 1 -mindepth 1 \( -type f -o -type l \) \( -iname '*onnxruntime*' -o -name '*_provider_factory.h' \) \
        -print0 2>/dev/null || true)
  done
  return 0
}

_ortg_log_findings() {  # <log>...: download, FetchContent, NuGet, pip and apt traces of an ORT (GenAI's own do not count)
  local log
  for log in "$@"; do
    if [ ! -f "${log}" ]; then echo "the build log ${log} is missing"; continue; fi
    { sed -E -e 's/onnx ?runtime[-_. ]?(genai|extensions)/GENAI/Ig' -e 's/microsoft\.ml\.onnxruntimegenai/GENAI/Ig' "${log}" || true; } \
      | { grep -n -i -E -e "${_ORTG_FETCH_RE}" || true; } | head -n 20 | sed -e "s#^#${log}:#" -e 's#$# (fetches an ONNX Runtime)#' || true
  done
  return 0
}

_ortg_parse() {  # <option>...: fills the _ORTG_* inputs; a malformed call is a finding
  _ORTG_TREES=()
  _ORTG_SHIMS=()
  _ORTG_CHAINS=()
  _ORTG_RECORDS=()
  _ORTG_LOGS=()
  _ORTG_CACHES=()
  while [ "$#" -gt 0 ]; do
    if [ "$#" -lt 2 ]; then echo "ort_chain_only_findings: $1 needs a value"; return 0; fi
    case "$1" in
      --chain) _ORTG_CHAINS+=("$2") ;;
      --tree) _ORTG_TREES+=("${2%/}") ;;
      --shim) _ORTG_SHIMS+=("${2%/}") ;;
      --record) _ORTG_RECORDS+=("$2") ;;
      --log) _ORTG_LOGS+=("$2") ;;
      --cache) _ORTG_CACHES+=("$2") ;;
      --stamp) ;;
      *) echo "ort_chain_only_findings: unknown argument $1"; return 0 ;;
    esac
    shift 2
  done
  return 0
}

# ort_chain_only_findings <consumer> --chain DIR... --tree DIR... --log F... [--shim DIR]... [--record F]... [--cache DIR]...
# One finding per line; nothing = the chain only. The counters land in _ORTG_* for the stamp.
ort_chain_only_findings() {
  local consumer="${1:-}" c s
  local -a scan=()
  shift || true
  _ORTG_REAL_ROOTS=()
  _ORTG_TREE_LINKS=()
  _ORTG_FILES=0 _ORTG_COMPARED=0 _ORTG_TOKENS=0 _ORTG_REFS=0
  _ortg_parse "$@"
  case "${consumer}" in "" | *[!a-z0-9-]*) echo "ort_chain_only_findings: bad consumer name '${consumer}'" ;; esac
  _ortg_index "${_ORTG_CHAINS[@]+"${_ORTG_CHAINS[@]}"}"
  for c in "${_ORTG_ROOTS[@]+"${_ORTG_ROOTS[@]}"}"; do _ORTG_REAL_ROOTS+=("$(readlink -f -- "${c}")"); done
  _ortg_record_roots
  if [ "${#_ORTG_TREES[@]}" -eq 0 ]; then echo "no source or build tree was given, so nothing was checked"; fi
  scan=("${_ORTG_TREES[@]+"${_ORTG_TREES[@]}"}")
  for s in "${_ORTG_SHIMS[@]+"${_ORTG_SHIMS[@]}"}"; do
    if ! _ortg_under "${s}" "${_ORTG_TREES[@]+"${_ORTG_TREES[@]}"}"; then scan+=("${s}"); fi
  done
  _ortg_tree_findings "${scan[@]+"${scan[@]}"}"
  if [ "${#_ORTG_TREES[@]}" -gt 0 ] && [ "${_ORTG_FILES}" -eq 0 ]; then echo "the tree(s) hold no files: a vacuous scan, not a clean build"; fi
  _ortg_shim_findings
  _ortg_caches
  _ortg_record_findings "${_ORTG_RECORDS[@]+"${_ORTG_RECORDS[@]}"}"
  if [ "${_ORTG_REFS}" -eq 0 ]; then
    echo "no build record names the chain ONNX Runtime ($(printf '%s ' "${_ORTG_CHAINS[@]+"${_ORTG_CHAINS[@]}"}")) or a shim of it, so nothing proves the build used it"
  fi
  if [ "${#_ORTG_LOGS[@]}" -eq 0 ]; then echo "no build log was given, so no configure or build step was checked for an ONNX Runtime fetch"; fi
  _ortg_log_findings "${_ORTG_LOGS[@]+"${_ORTG_LOGS[@]}"}"
  return 0
}

_ortg_json() {  # <string>: a JSON string literal
  local s="${1//\\/\\\\}"
  s="${s//\"/\\\"}"
  printf '"%s"' "${s}"
}

# ort_assert_chain_only <consumer> --stamp FILE <ort_chain_only_findings options>: 1 on any finding, and no stamp;
# 0 after writing FILE, {consumer, the chain core lib's sha256 per root, ...}, which G1 (check-ort-provenance.sh) reads.
ort_assert_chain_only() {
  local consumer="${1:-}" stamp="" out root body line n
  local -a args=("$@")
  while [ "$#" -gt 0 ]; do
    if [ "$1" = --stamp ]; then stamp="${2:-}"; fi
    shift
  done
  if [ -n "${stamp}" ]; then ${SUDO_WRAP:+"${SUDO_WRAP}"} rm -f "${stamp}"; fi
  out="$(mktemp)" || { echo "ORT-GATE FAILED (${consumer}): no temp file for the findings, so nothing was checked" >&2; return 1; }
  if [ -z "${stamp}" ]; then echo "no --stamp file given" > "${out}"; fi
  ort_chain_only_findings "${args[@]}" >> "${out}"
  n="$(grep -c -e . "${out}" || true)"
  if [ "${n}" != 0 ]; then
    while IFS= read -r line; do echo "ORT-GATE FAIL (${consumer}): ${line}" >&2; done < <(head -n 200 "${out}")
    echo "ORT-GATE FAILED (${consumer}): ${n} finding(s), the build reached an ONNX Runtime other than the chain's" >&2
    rm -f "${out}"
    return 1
  fi
  rm -f "${out}"
  body="{\"consumer\": $(_ortg_json "${consumer}"), \"gate\": \"ort_assert_chain_only\""
  for root in "${_ORTG_ROOTS[@]}"; do body+=", $(_ortg_json "core:${root}"): $(_ortg_json "${_ORTG_CORE[${root}]:-}")"; done
  body+=", \"cApiHeaderSha256\": $(_ortg_json "${_ORTG_CAPI}"), \"treeFiles\": \"${_ORTG_FILES}\""
  body+=", \"ortFilesCompared\": \"${_ORTG_COMPARED}\", \"recordPaths\": \"${_ORTG_TOKENS}\", \"chainReferences\": \"${_ORTG_REFS}\"}"
  ${SUDO_WRAP:+"${SUDO_WRAP}"} mkdir -p "${stamp%/*}" || return 1
  printf '%s\n' "${body}" | ${SUDO_WRAP:+"${SUDO_WRAP}"} tee "${stamp}" >/dev/null || return 1
  echo "ORT-GATE OK (${consumer}): ${_ORTG_FILES} file(s), ${_ORTG_COMPARED} ORT file(s) byte-identical to the chain, ${_ORTG_TOKENS} record path(s) (${_ORTG_REFS} naming the chain); stamp ${stamp}"
  return 0
}
