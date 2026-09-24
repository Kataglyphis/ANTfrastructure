#!/usr/bin/env bash
# check-ort-provenance.sh -- the ORT census: every ONNX Runtime binary under a root is the chain build,
# byte for byte, and every importer resolves to it. G1 (the runtime smoke's check_ort_census) and G6
# (consumer bundles: `check-ort-provenance.sh <dir>`). ort_census_probe.py gathers facts; the verdict
# function below is pure. Does NOT cover header-only provenance (foreign headers or import libs ship no
# bytes), files the running user cannot read, or a dlopen by absolute path chosen at run time.
# docs/cross-build-verification.md#e-ort-single-source
#
# Usage: check-ort-provenance.sh [--reference DIR]... [--manifest FILE]... [--exempt ARCH:PATH:WHY]... <dir> | --image
# Defaults to the chain ORT of the image it runs in. Exit 0 = clean, 1 = findings, 2 = usage.

_ORT_CENSUS_HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Where the Linux chain builds ORT (onnxruntime/build/lib/common.sh ORT_SRC_DIR, the android clone).
ort_census_chain_roots() {
  printf '%s\n' /opt/onnxruntime /opt/onnxruntime-android
}

# The image components allowed to use ORT: name|file globs|G2 stamp. Anything else is UNREGISTERED.
ort_census_contract() {
  printf '%s\n' \
    'opencv|libopencv_dnn.so*,libopencv_gapi.so*,cv2*.so|/opt/opencv5/ort-provenance/opencv.json' \
    'gstreamer|libgstonnx.so*|/opt/gstreamer/ort-provenance/gstreamer.json' \
    'ffmpeg|libavfilter.so*|/opt/ffmpeg/ort-provenance/ffmpeg.json' \
    'genai|libonnxruntime-genai.so*,onnxruntime_genai*.so|/usr/local/lib/onnxruntime-genai/ort-provenance/genai.json'
}

# The chain ORT of a Linux image: its prefixes and the wheel manifest collect-artifacts.sh writes.
_ORT_CENSUS_REFS="/usr/local/lib/onnxruntime-cpu /usr/local/lib/onnxruntime-gpu /usr/local/lib/onnxruntime-web /opt/android/onnxruntime"
_ORT_CENSUS_MANIFESTS="/usr/local/lib/onnxruntime-cpu/ort-provenance.sha256 /usr/local/lib/onnxruntime-gpu/ort-provenance.sha256"
_ORT_CENSUS_CORES="/usr/local/lib/onnxruntime-cpu/lib/libonnxruntime.so.1 /usr/local/lib/onnxruntime-gpu/lib/libonnxruntime.so.1"
# Reviewed image exceptions, '<arch>:<path>:<reason>' (check_ort_census); one that stops matching fails.
_ORT_CENSUS_IMAGE_EXEMPT=()

# The probe arguments for a whole image (G1), one per line.
ort_census_image_args() {
  local d r c
  printf '%s\n' --image --root /
  for d in ${_ORT_CENSUS_REFS}; do printf '%s\n' --ref "${d}" --allow "${d}"; done
  for d in ${_ORT_CENSUS_MANIFESTS}; do printf '%s\n' --ref-manifest "${d}"; done
  for d in ${_ORT_CENSUS_CORES}; do printf '%s\n' --core "${d}"; done
  while IFS= read -r r; do printf '%s\n' --chain-root "${r}"; done < <(ort_census_chain_roots)
  while IFS= read -r c; do printf '%s\n' --contract "${c}"; done < <(ort_census_contract)
}

# STAMP arms itself with G2: stamps exist only once ort_assert_chain_only writes them.
ort_census_stamps_armed() {
  local g2="${_ORT_CENSUS_HERE}/../03-media/ort-provenance.sh"
  if [ -f "${g2}" ] && grep -q -e '^ort_assert_chain_only()' "${g2}"; then echo 1; else echo 0; fi
}

_ort_under() {  # <path> <prefix>... : 0 when path is a prefix or sits below one
  local p="$1" q
  shift
  for q in "$@"; do
    q="${q%/}"
    [ -n "${q}" ] || continue
    case "${p}" in "${q}" | "${q}"/* | "${q}"\\*) return 0 ;; esac
  done
  return 1
}

_ort_census_load() {  # <probe>: the tables every verdict consults
  declare -gA _ORTC_REF=() _ORTC_CORE=() _ORTC_ENTRY=()
  _ORTC_CHAIN=()
  _ORTC_ALLOW=()
  _ORTC_DONE=0
  _ORTC_NBIN=0
  _ORTC_NOMANIFEST=""
  local kind a b c d e
  while IFS=$'\t' read -r kind a b c d e; do
    case "${kind}" in
      CHAIN) _ORTC_CHAIN+=("${a}") ;;
      ALLOW) _ORTC_ALLOW+=("${a}") ;;
      # 'm' = known only from a wheel manifest row, whose roots nobody has read yet (_ort_bin_verdict grades them).
      REF) if [ "${c}" = '?' ]; then _ORTC_REF["${a}"]="${_ORTC_REF[${a}]:-m}"; else _ORTC_REF["${a}"]=1; fi ;;
      CORE) _ORTC_CORE["${a}"]=1 ;;
      BIN) _ORTC_NBIN=$((_ORTC_NBIN + 1)) ;;
      USE) if [ -z "${_ORTC_REF[${e}]:-}" ]; then _ORTC_ENTRY["${b}"]=1; fi ;;
      NOMANIFEST) _ORTC_NOMANIFEST="${_ORTC_NOMANIFEST} ${a}" ;;
      PROBE_DONE) _ORTC_DONE=1 ;;
    esac
  done <<< "$1"
  return 0
}

_ort_bytes_verdict() {  # <path> <roots|-> [name|fp|def] : a non-chain ORT instance, by its build roots
  local path="$1" r foreign="" chain=0 relative=0 hint=""
  local -a roots=()
  [ "$2" = "-" ] || IFS='|' read -r -a roots <<< "$2"
  for r in ${roots[@]+"${roots[@]}"}; do
    if [ -z "${r}" ] || [ "${r}" = . ]; then relative=1
    elif _ort_under "${r}" "${_ORTC_CHAIN[@]}"; then chain=1
    else foreign="${foreign:+${foreign}, }${r}"; fi
  done
  case "${path}" in */site-packages/onnxruntime/capi/*) [ -z "${_ORTC_NOMANIFEST}" ] || hint=" (no chain wheel manifest at${_ORTC_NOMANIFEST})" ;; esac
  if [ -n "${foreign}" ]; then printf 'FOREIGN\t%s\tbuilt under %s, not the chain (%s)\n' "${path}" "${foreign}" "${_ORTC_CHAIN[*]}"
  elif [ "${chain}" = 1 ]; then printf 'STALE\t%s\ta chain-rooted build whose bytes match no file of this chain ORT%s\n' "${path}" "${hint}"
  elif [ "${relative}" = 1 ]; then printf 'FOREIGN\t%s\tbuilt with relative (remapped) source paths, which the chain never does\n' "${path}"
  elif [ "${3:-}" = def ]; then printf 'UNPROVEN\t%s\tan ORT under another name (it defines OrtGetApiBase) with no source fingerprint that matches no chain file\n' "${path}"
  else printf 'UNPROVEN\t%s\tan ORT-named binary with no source fingerprint that matches no chain file%s\n' "${path}" "${hint}"; fi
}

_ort_roots_chain() {  # <roots|-> : 0 when there is no fingerprint or one root sits under a chain root
  local rest="$1|" one
  [ "$1" != "-" ] || return 0
  while [ -n "${rest}" ]; do
    one="${rest%%|*}"
    rest="${rest#*|}"
    if [ -n "${one}" ] && _ort_under "${one}" "${_ORTC_CHAIN[@]}"; then return 0; fi
  done
  return 1
}

_ort_bin_verdict() {  # <sha> <path> <roots> [name|fp|def]
  if [ -z "${_ORTC_REF[$1]:-}" ]; then
    _ort_bytes_verdict "$2" "$3" "${4:-}"
    return 0
  fi
  # Check (a) for a manifest-only sha: the reference's own bytes, read here, must name a chain root.
  if [ "${_ORTC_REF[$1]}" = m ] && ! _ort_roots_chain "$3"; then
    printf 'FOREIGN\t%s\tits sha is a chain wheel manifest row, but it was built under %s\n' "$2" "${3//|/, }"
    return 0
  fi
  [ "${#_ORTC_ALLOW[@]}" -gt 0 ] || return 0
  case "$2" in */site-packages/onnxruntime/capi/* | */dist-packages/onnxruntime/capi/*) return 0 ;; esac
  _ort_under "${2%%!*}" "${_ORTC_ALLOW[@]}" || printf 'ELSEWHERE\t%s\ta chain ORT copy outside the chain prefixes and */site-packages/onnxruntime/capi\n' "$2"
  return 0
}

_ort_ref_verdict() {  # <label> <roots|-|?> : the reference itself must carry a chain root ('?' is graded per BIN)
  if [ "$2" != '?' ] && ! _ort_roots_chain "$2"; then
    printf 'FOREIGN\t%s\tthe chain reference itself was built under %s\n' "$1" "${2//|/, }"
  fi
  return 0
}

_ort_res_verdict() {  # <importer> <soname> <hit|-> <sha|->
  if [ "$3" = "-" ]; then
    printf 'UNRESOLVED\t%s\tno %s on its ld.so search path\n' "$1" "$2"
  elif [ -z "${_ORTC_REF[$4]:-}" ]; then
    printf 'UNRESOLVED\t%s\t%s resolves to %s, which is not the chain ORT\n' "$1" "$2" "$3"
  fi
  return 0
}

_ort_dist_verdict() {  # <site> <owners,|->
  local -a owners=()
  [ "$2" = "-" ] || IFS=',' read -r -a owners <<< "$2"
  if [ "${#owners[@]}" -gt 1 ]; then printf 'DIST\t%s\tthe onnxruntime import package is owned by %s\n' "$1" "${2//,/, }"; fi
  return 0
}

_ort_stamp_verdict() {  # <entry> <path> <consumer|MISSING> <shas,|->
  local s
  local -a shas=()
  [ -n "${_ORTC_ENTRY[$1]:-}" ] || return 0
  [ "$4" = "-" ] || IFS=',' read -r -a shas <<< "$4"
  if [ "$3" = "$1" ]; then
    for s in ${shas[@]+"${shas[@]}"}; do [ -z "${_ORTC_CORE[${s}]:-}" ] || return 0; done
  fi
  printf "STAMP\t%s\tmissing, or not naming this image's chain core lib\n" "$2"
}

_ort_census_findings() {  # <probe> <stamps armed 0|1>
  local kind a b c d e
  _ort_census_load "$1"
  [ "${_ORTC_DONE}" = 1 ] || printf 'NONE\t-\tthe probe did not complete (no PROBE_DONE)\n'
  [ "${#_ORTC_REF[@]}" -gt 0 ] || printf 'NONE\t-\tno chain ORT reference was found, so nothing can be proven\n'
  [ "${_ORTC_NBIN}" -gt 0 ] || printf 'NONE\t-\tthe scan found no ORT binary at all: a vacuous pass, not a clean tree\n'
  while IFS=$'\t' read -r kind a b c d e; do
    case "${kind}" in
      REF) _ort_ref_verdict "${b}" "${c}" ;;
      BIN) _ort_bin_verdict "${a}" "${b}" "${c}" "${d}" ;;
      UNREAD) printf 'UNPROVEN\t%s\tunreadable: %s\n' "${a}" "${b}" ;;
      USE) if [ "${b}" = "-" ] && [ -z "${_ORTC_REF[${e}]:-}" ]; then
             printf 'UNREGISTERED\t%s\tuses the ORT ABI (%s) but no ort_census_contract entry covers it\n' "${a}" "${c},${d}"
           fi ;;
      RES) _ort_res_verdict "${a}" "${b}" "${c}" "${d}" ;;
      DIST) _ort_dist_verdict "${a}" "${b}" ;;
      STAMP) if [ "$2" = 1 ]; then _ort_stamp_verdict "${a}" "${b}" "${c}" "${d}"; fi ;;
    esac
  done <<< "$1"
  return 0
}

# '<arch>:<path>:<reason>' waives every finding on that path; an entry that waives nothing fails.
_ort_census_exempt() {  # <findings> <arch> <exemption>...
  local lines="$1" arch="$2" e e_arch rest e_path verb path detail
  local -A waived=() seen=()
  shift 2
  while IFS=$'\t' read -r verb path detail; do
    if [ -n "${verb}" ]; then seen["${path}"]=1; fi
  done <<< "${lines}"
  for e in "$@"; do
    case "${e}" in *:*:*) ;; *) printf 'EXEMPT-STALE\t%s\tmalformed; expected <arch>:<path>:<reason>\n' "${e}"; continue ;; esac
    e_arch="${e%%:*}"
    rest="${e#*:}"
    e_path="${rest%:*}"
    [ "${e_arch}" = '*' ] || [ "${e_arch}" = "${arch}" ] || continue
    if [ -n "${seen[${e_path}]:-}" ]; then waived["${e_path}"]="${rest##*:}"
    else printf "EXEMPT-STALE\t%s\tthe exemption '%s' matches no finding any more: delete it\n" "${e_path}" "${rest##*:}"; fi
  done
  while IFS=$'\t' read -r verb path detail; do
    [ -n "${verb}" ] || continue
    if [ -n "${waived[${path}]:-}" ]; then printf 'EXEMPT\t%s\t%s [exempt: %s]\n' "${path}" "${detail}" "${waived[${path}]}"
    else printf '%s\t%s\t%s\n' "${verb}" "${path}" "${detail}"; fi
  done <<< "${lines}"
  return 0
}

# PURE: probe text, stamps-armed flag, arch and exemptions in; one TAB line per finding out.
# Every verb but EXEMPT is fatal; no output at all is a pass.
ort_census_verdicts() {
  local probe="${1//$'\r'/}" armed="${2:-0}" arch="${3:-}"
  if [ "$#" -ge 3 ]; then shift 3; else shift "$#"; fi
  _ort_census_exempt "$(_ort_census_findings "${probe}" "${armed}")" "${arch}" "$@"
}

# Host form of a directory for the python probe (Git Bash hands it a Windows path).
_ort_host_dir() {
  (cd "$1" && { pwd -W 2>/dev/null || pwd; })
}

_ort_host_arch() {
  case "$(uname -m)" in x86_64) echo amd64 ;; aarch64) echo arm64 ;; *) uname -m ;; esac
}

_ort_census_usage() {
  sed -n 's/^# \(Usage: .*\)$/\1/p; s/^# \(Defaults .*\)$/\1/p' "${BASH_SOURCE[0]}"
}

# The probe arguments for one bundle (G6): its root, and by default the chain ORT of the image this runs in.
_ort_census_tree_args() {  # <root> <refs, one per line> <manifests, one per line>
  local d refs="$2" manifests="$3"
  if [ -z "${refs}" ]; then
    for d in ${_ORT_CENSUS_REFS}; do [ ! -d "${d}/lib" ] || refs+="${d}/lib"$'\n'; done
    for d in ${_ORT_CENSUS_MANIFESTS}; do [ ! -f "${d}" ] || manifests+="${d}"$'\n'; done
  fi
  printf '%s\n' --root "$(_ort_host_dir "$1")" --ref-root /
  while IFS= read -r d; do [ -z "${d}" ] || printf '%s\n' --ref "$(_ort_host_dir "${d}")"; done <<< "${refs}"
  while IFS= read -r d; do
    [ -z "${d}" ] || printf '%s\n' --ref-manifest "$(_ort_host_dir "$(dirname "${d}")")/$(basename "${d}")"
  done <<< "${manifests}"
  while IFS= read -r d; do printf '%s\n' --chain-root "${d}"; done < <(ort_census_chain_roots)
}

_ort_census_run() {  # <label> <stamps armed> <probe args, one per line> <exemption>...
  local label="$1" armed="$2" probe py verb path detail bad=0
  local -a args=()
  mapfile -t args <<< "$3"
  shift 3
  py="$(command -v python3 || command -v python)"
  probe="$(MSYS_NO_PATHCONV=1 MSYS2_ARG_CONV_EXCL='*' "${py}" "$(_ort_host_dir "${_ORT_CENSUS_HERE}")/ort_census_probe.py" \
    "${args[@]}")" || true
  while IFS=$'\t' read -r verb path detail; do
    [ -n "${verb}" ] || continue
    printf '  %-12s %s -- %s\n' "${verb}" "${path}" "${detail}"
    [ "${verb}" = EXEMPT ] || bad=$((bad + 1))
  done < <(ort_census_verdicts "${probe}" "${armed}" "$(_ort_host_arch)" "$@")
  if [ "${bad}" -gt 0 ]; then echo "ORT census FAILED: ${bad} finding(s) in ${label}" >&2; return 1; fi
  echo "ORT census PASS: every ONNX Runtime binary in ${label} is the chain build"
}

# G6 over one bundle; --image runs G1 over the system this runs in (what check_ort_census does in-image).
ort_census_main() {
  local root="" image=0 refs="" manifests=""
  local -a exempt=()
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --image) image=1; shift ;;
      --reference) refs+="${2:?--reference needs a directory}"$'\n'; shift 2 ;;
      --manifest) manifests+="${2:?--manifest needs a file}"$'\n'; shift 2 ;;
      --exempt) exempt+=("${2:?--exempt needs ARCH:PATH:WHY}"); shift 2 ;;
      -h | --help) _ort_census_usage; return 0 ;;
      -*) echo "check-ort-provenance: unknown option $1" >&2; return 2 ;;
      *) root="$1"; shift ;;
    esac
  done
  if [ "${image}" = 1 ]; then
    _ort_census_run / "$(ort_census_stamps_armed)" "$(ort_census_image_args)" \
      ${_ORT_CENSUS_IMAGE_EXEMPT[@]+"${_ORT_CENSUS_IMAGE_EXEMPT[@]}"} ${exempt[@]+"${exempt[@]}"}
  elif [ -n "${root}" ] && [ -d "${root}" ]; then
    _ort_census_run "${root}" 0 "$(_ort_census_tree_args "${root}" "${refs}" "${manifests}")" ${exempt[@]+"${exempt[@]}"}
  else
    _ort_census_usage >&2
    return 2
  fi
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  set -euo pipefail
  ort_census_main "$@"
fi
