#!/usr/bin/env bash
# Copyright (c) 2025 Kataglyphis
# SPDX-License-Identifier: MIT
# verify-genai-ort.sh - GenAI was built against the chain ONNX Runtime (owner rule 2026-09-23): ORT_HOME is a chain root,
# no ortlib/onnxruntime FetchContent ran, and every ORT-named file in its tree is chain bytes. NOT covered: run-time loading.
set -euo pipefail
# G2's shared gate, mounted per file beside this one.
# shellcheck source=ort-provenance.sh
source "$(dirname "${BASH_SOURCE[0]}")/ort-provenance.sh"

usage() {
  cat <<'EOF'
Usage: verify-genai-ort.sh [--src-dir DIR] [--output-dir DIR] [--ort-root DIR]...

Prove the onnxruntime-genai build in --src-dir (default /opt/onnxruntime-genai) used a chain
ONNX Runtime (--ort-root, repeatable; default /usr/local/lib/onnxruntime-cpu and -gpu).
No build tree and no GenAI artifacts in --output-dir (default /usr/local/lib/onnxruntime-genai)
is a skip; artifacts without a build tree fail. Exit 0 pass/skip, 1 finding, 2 usage.
EOF
}

# basename -> " sha256 sha256 ..." of every ORT-named file under the chain roots; GENAI_ORT_NAMED is that name filter.
declare -A GENAI_ORT_CHAIN_SHA=()
GENAI_ORT_NAMED=( \( -name '*onnxruntime*' -o -name '*_provider_factory.h' \) )

# _genai_ort_sha <file>: its sha256, or "unreadable" (a dangling link), which matches no chain file.
_genai_ort_sha() {
  local sum
  sum="$(sha256sum 2>/dev/null < "$1")" || sum="unreadable"
  printf '%s\n' "${sum%% *}"
}

# _genai_ort_index_chain <ort_root>...: fills GENAI_ORT_CHAIN_SHA; a chain without its two anchors is a finding.
_genai_ort_index_chain() {
  local root f sha
  for root in "$@"; do
    while IFS= read -r -d '' f; do
      sha="$(_genai_ort_sha "${f}")"
      if [ "${sha}" = unreadable ]; then echo "cannot hash chain file ${f}"; continue; fi
      GENAI_ORT_CHAIN_SHA["${f##*/}"]+=" ${sha}"
    done < <(find -L "${root}/include" "${root}/lib" -type f "${GENAI_ORT_NAMED[@]}" -print0 2>/dev/null || true)
  done
  for f in onnxruntime_c_api.h libonnxruntime.so; do
    [ -n "${GENAI_ORT_CHAIN_SHA[${f}]:-}" ] || echo "no chain ${f} under $* to compare against"
  done
  return 0
}

# _genai_ort_home_findings <src_dir> <ort_root>...: the top-level CMakeCache.txt names a chain root as ORT_HOME.
_genai_ort_home_findings() {
  local src="$1" cache home real_home root ok have_cache=0
  shift
  while IFS= read -r -d '' cache; do
    have_cache=1
    home="$(sed -n '/^ORT_HOME:[A-Za-z_]*=/{s///p;q;}' "${cache}")"
    if [ -z "${home}" ]; then
      echo "${cache} has no ORT_HOME, so ortlib.cmake fetched its own ONNX Runtime"
      continue
    fi
    real_home="$(realpath -m -- "${home}")"
    ok=0
    for root in "$@"; do
      if [ "${real_home}" = "$(realpath -m -- "${root}")" ]; then ok=1; fi
    done
    if [ "${ok}" != 1 ]; then echo "${cache}: ORT_HOME=${home} is not a chain ONNX Runtime root ($*)"; fi
  done < <(find "${src}/build" -mindepth 3 -maxdepth 3 -name CMakeCache.txt -print0 2>/dev/null || true)
  if [ "${have_cache}" != 1 ]; then echo "no ${src}/build/<platform>/<config>/CMakeCache.txt, so nothing proves GenAI's ONNX Runtime"; fi
  return 0
}

# _genai_ort_tree_findings <src_dir>: no FetchContent'd ORT dir, no ORT archive, chain bytes under every chain ORT name.
_genai_ort_tree_findings() {
  local src="$1" f name
  find "${src}" -type d -path '*/_deps/*' \( -name 'ortlib-*' -o -name 'onnxruntime-src' -o -name 'onnxruntime-subbuild' -o -name 'onnxruntime-build' \) \
    -prune -printf 'FetchContent populated ONNX Runtime content at %p\n' 2>/dev/null || true
  while IFS= read -r -d '' f; do
    name="${f##*/}"
    case "${name}" in
      onnxruntime[-_]genai*|onnxruntime[-_]extensions*) ;;
      *onnxruntime*.tgz|*onnxruntime*.zip|*onnxruntime*.nupkg|*onnxruntime*.aar|*onnxruntime*.whl|*onnxruntime*.tar|*onnxruntime*.tar.*)
        echo "an ONNX Runtime archive sits in the tree: ${f}"
        continue ;;
    esac
    [ -n "${GENAI_ORT_CHAIN_SHA[${name}]:-}" ] || continue
    case "${GENAI_ORT_CHAIN_SHA[${name}]} " in
      *" $(_genai_ort_sha "${f}") "*) ;;
      *) echo "${f} is not the chain's ${name} (foreign ONNX Runtime bytes)" ;;
    esac
  done < <(find "${src}" \( -type f -o -type l \) "${GENAI_ORT_NAMED[@]}" -print0 2>/dev/null || true)
  return 0
}

# genai_ort_findings <src_dir> <ort_root>... -> one finding per line on stdout; nothing = pass.
genai_ort_findings() {
  local src="$1"
  shift
  _genai_ort_index_chain "$@"
  _genai_ort_home_findings "${src}" "$@"
  _genai_ort_tree_findings "${src}"
}

# _genai_ort_no_tree <src_dir> <output_dir>: GenAI not built here is a skip, unless its artifacts exist anyway.
_genai_ort_no_tree() {
  if [ -n "$(find "$2" -maxdepth 2 \( -name 'libonnxruntime-genai*.so*' -o -name 'onnxruntime_genai*.whl' \) -print -quit 2>/dev/null || true)" ]; then
    echo "GENAI-ORT FAIL: GenAI artifacts in $2 but no build tree at $1/build to prove their ONNX Runtime" >&2
    return 1
  fi
  echo "GENAI-ORT SKIP: no GenAI build tree at $1/build and no GenAI artifacts in $2"
}

main() {
  local src=/opt/onnxruntime-genai out=/usr/local/lib/onnxruntime-genai findings line
  local -a roots=()
  while [ $# -gt 0 ]; do
    case "$1" in
      -h|--help) usage; return 0 ;;
      --src-dir|--output-dir|--ort-root) ;;
      *) echo "verify-genai-ort: unknown argument: $1" >&2; usage >&2; return 2 ;;
    esac
    if [ $# -lt 2 ]; then usage >&2; return 2; fi
    case "$1" in
      --src-dir) src="$2" ;;
      --output-dir) out="$2" ;;
      *) roots+=("$2") ;;
    esac
    shift 2
  done
  [ "${#roots[@]}" -gt 0 ] || roots=(/usr/local/lib/onnxruntime-cpu /usr/local/lib/onnxruntime-gpu)
  if [ ! -d "${src}/build" ]; then
    _genai_ort_no_tree "${src}" "${out}"
    return
  fi
  findings="$(genai_ort_findings "${src}" "${roots[@]}")"
  if [ -n "${findings}" ]; then
    while IFS= read -r line; do echo "GENAI-ORT FAIL: ${line}" >&2; done <<< "${findings}"
    return 1
  fi
  echo "GENAI-ORT OK: ORT_HOME is a chain root, no ONNX Runtime was fetched, every ORT-named file under ${src} is chain bytes"
  _genai_ort_g2 "${src}" "${out}" "${roots[@]}"
}

# _genai_ort_g2 <src_dir> <output_dir> <ort_root>...: G2 over the same tree, its build records and the build log 60-build-genai.sh
# tees there; a pass stamps GenAI for G1.
_genai_ort_g2() {
  local src="$1" out="$2" r rec
  local -a g2=()
  shift 2
  for r in "$@"; do g2+=(--chain "${r}"); done
  while IFS= read -r -d '' rec; do g2+=(--record "${rec}"); done \
    < <(find "${src}/build" -mindepth 3 -maxdepth 3 \( -name CMakeCache.txt -o -name build.ninja \) -print0 2>/dev/null || true)
  ort_assert_chain_only genai --stamp "${out}/ort-provenance/genai.json" --tree "${src}" --log "${src}/build/genai-build.log" "${g2[@]}"
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  main "$@"
fi
