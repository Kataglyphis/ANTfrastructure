#!/usr/bin/env bash
# The image's own GStreamer plugins into a package, and proof its elements load from them alone; see docs/python-app-bundles.md § GStreamer
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../01-core/logging.sh
source "${SCRIPT_DIR}/../01-core/logging.sh"

usage() {
  printf 'usage: %s copy --dest DIR [--plugin NAME]... [--optional NAME]... [--plugin-dir DIR]...\n' "$0"
  printf '       %s check --plugins DIR [--lib-dir DIR] ELEMENT...\n' "$0"
}

# copy: libgst<NAME>.so from the image's plugin directories, symlinks resolved; a missing required one fails.
gst_copy() {
  local dest="" name dir file found
  local -a required=() optional=() dirs=()
  while [ $# -gt 0 ]; do
    case "$1" in
      --dest) dest="${2:?}"; shift 2 ;;
      --plugin) required+=("${2:?}"); shift 2 ;;
      --optional) optional+=("${2:?}"); shift 2 ;;
      --plugin-dir) dirs+=("${2:?}"); shift 2 ;;
      *) usage >&2; return 2 ;;
    esac
  done
  [ -n "${dest}" ] || { usage >&2; return 2; }
  if [ "${#dirs[@]}" -eq 0 ]; then
    dirs+=("$(pkg-config --variable=pluginsdir gstreamer-1.0)")
    dirs+=("${LIBCAMERA_PREFIX:-/opt/libcamera}/lib/gstreamer-1.0")
  fi
  mkdir -p "${dest}"
  for name in "${required[@]}" "${optional[@]}"; do
    found=""
    for dir in "${dirs[@]}"; do
      file="${dir}/libgst${name}.so"
      [ -f "${file}" ] && { found="${file}"; break; }
    done
    if [ -z "${found}" ]; then
      case " ${optional[*]} " in
        *" ${name} "*) info "  optional GStreamer plugin ${name}: not in this image" ;;
        *) err "GStreamer plugin ${name} is in none of: ${dirs[*]}" ;;
      esac
      continue
    fi
    cp -L "${found}" "${dest}/libgst${name}.so"
    info "  GStreamer plugin ${name} <- ${found}"
  done
  return 0
}

# check: each element through the image's gst-inspect, under the environment a package gives GStreamer.
gst_check() {
  local plugins="" libdir="" element out file failures=0 work
  local inspect="${GST_INSPECT:-gst-inspect-1.0}"
  while [ $# -gt 0 ]; do
    case "$1" in
      --plugins) plugins="${2:?}"; shift 2 ;;
      --lib-dir) libdir="${2:?}"; shift 2 ;;
      --) shift; break ;;
      -*) usage >&2; return 2 ;;
      *) break ;;
    esac
  done
  [ -d "${plugins}" ] || err "no plugin directory at ${plugins:-<unset>}"
  [ $# -gt 0 ] || err "check names no element"
  command -v "${inspect}" >/dev/null 2>&1 || err "no ${inspect} to ask"
  work="$(mktemp -d)"
  for element in "$@"; do
    out="$(env -u GST_PLUGIN_PATH_1_0 GST_PLUGIN_PATH="${plugins}" GST_PLUGIN_SYSTEM_PATH= \
      GST_PLUGIN_SYSTEM_PATH_1_0= GST_REGISTRY="${work}/registry.bin" GST_REGISTRY_FORK=no \
      LD_LIBRARY_PATH="${libdir:-${plugins}/..}" "${inspect}" "${element}" 2>&1)" || {
      printf 'FAIL %s: no bundled plugin provides it\n' "${element}"
      failures=$((failures + 1))
      continue
    }
    file="$(awk '$1 == "Filename" { print $2; exit }' <<<"${out}")"
    case "${file}" in
      "${plugins}"/*) printf 'ok   %s (%s)\n' "${element}" "${file#"${plugins}"/}" ;;
      *) printf 'FAIL %s: loaded from %s, outside the package\n' "${element}" "${file:-<no Filename>}"
        failures=$((failures + 1)) ;;
    esac
  done
  rm -rf "${work}"
  [ "${failures}" -eq 0 ] || err "${failures} element(s) would be missing on a host without the image"
  info "  $# GStreamer element(s) load from ${plugins} alone"
  return 0
}

subcommand="${1:-}"
[ $# -eq 0 ] || shift
if [ "${subcommand}" = copy ]; then
  gst_copy "$@"
elif [ "${subcommand}" = check ]; then
  gst_check "$@"
else
  usage >&2
  [ "${subcommand}" = --help ] || exit 2
fi
