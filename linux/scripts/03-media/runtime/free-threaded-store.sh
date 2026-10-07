#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

# The repaired cp314t store, proved again and checked against the GIL wheelhouse, plus the record the runtime smoke reads. See docs/consumer-image-contract.md#the-free-threaded-wheels

_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${_SCRIPT_DIR}/media-env.sh"
for _f in /opt/scripts/core/cross-env.sh /opt/scripts/03-media/free-threaded-wheels.sh "${_SCRIPT_DIR}/../free-threaded-wheels.sh"; do
  # shellcheck disable=SC1090
  if [ -f "${_f}" ]; then source "${_f}"; fi
done
unset _f
declare -F ft_wheel_verdict >/dev/null || { echo "ERROR: free-threaded-wheels.sh is not mounted into this RUN" >&2; exit 1; }

FT_STORE_RECORD="${FT_WHEELS_DIR}/free-threaded-store.txt"

# <wheel dir>: the distribution of every wheel there, one per line, in the wheel file's spelling.
_ft_store_dists() {
  local w
  for w in "$1"/*.whl; do
    [ -f "${w}" ] || continue
    w="${w##*/}"
    printf '%s\n' "${w%%-*}"
  done | LC_ALL=C sort -u
}

# The GIL wheels whose table verdict is twin: exactly the set the store must hold on a native build.
_ft_store_expected() {
  local d
  while IFS= read -r d; do
    if [ "$(ft_wheel_verdict "${d}")" = twin ]; then printf '%s\n' "${d}"; fi
  done < <(_ft_store_dists "${WHEELS_DIR}")
}

# <mode>: rc 1 with every missing or stray twin named.
ft_store_check_set() {
  local want have bad=0 d
  want="$(_ft_store_expected)"
  have="$(_ft_store_dists "${FT_WHEELS_DIR}")"
  [ "$1" = native ] || want=""
  # A new wheel is classified before it ships natively: the table is the only place its verdict is read.
  for d in $(_ft_store_dists "${WHEELS_DIR}"); do
    if [ "$1" = native ] && [ "$(ft_wheel_verdict "${d}")" = unknown ]; then
      echo "ERROR: ${WHEELS_DIR} ships ${d}, which ft_wheel_table does not classify; read its free-threading support and add its row" >&2
      bad=1
    fi
  done
  for d in $(LC_ALL=C comm -23 <(printf '%s\n' "${want}" | sed '/^$/d') <(printf '%s\n' "${have}" | sed '/^$/d')); do
    echo "ERROR: ${d} ships a GIL wheel in ${WHEELS_DIR} and its table verdict is twin, but ${FT_WHEELS_DIR} has no cp314t twin of it" >&2
    bad=1
  done
  for d in $(LC_ALL=C comm -13 <(printf '%s\n' "${want}" | sed '/^$/d') <(printf '%s\n' "${have}" | sed '/^$/d')); do
    echo "ERROR: ${FT_WHEELS_DIR} holds ${d}, which is no twin of a GIL wheel this ${1} build ships" >&2
    bad=1
  done
  return "${bad}"
}

# Every stored wheel is gated and proved again: the repair may have rewritten its bytes.
ft_store_prove_all() {
  local w name
  for w in "${FT_WHEELS_DIR}"/*.whl; do
    [ -f "${w}" ] || continue
    name="${w##*/}"
    ft_soabi_gate "${w}" || return 1
    ft_prove_wheel "${w}" "${name%%-*}" || return 1
  done
}

# <mode>: the record, then one line per table row this build makes no twin of, with its reason.
ft_store_write_record() {
  local dist verdict pin evidence w
  {
    printf 'mode=%s\n' "$1"
    printf 'arch=%s\n' "${TARGET_ARCH:-${TARGETARCH:-unknown}}"
    for w in "${FT_WHEELS_DIR}"/*.whl; do
      if [ -f "${w}" ]; then printf 'twin %s\n' "${w##*/}"; fi
    done
    while IFS='|' read -r dist verdict pin evidence; do
      if [ "${verdict}" != twin ]; then printf 'skip %s %s (%s): %s\n' "${dist}" "${verdict}" "${pin}" "${evidence}"; fi
    done < <(ft_wheel_table)
  } > "${FT_STORE_RECORD}"
}

main() {
  local mode=native
  mkdir -p "${FT_WHEELS_DIR}"
  if declare -F cross_build_is_active >/dev/null 2>&1 && cross_build_is_active; then
    mode=cross
  fi
  ft_store_check_set "${mode}" || exit 1
  if compgen -G "${FT_WHEELS_DIR}/*.whl" >/dev/null; then
    ft_python_resolve || exit 1
    ft_store_prove_all || exit 1
  else
    echo "free-threaded: ${FT_WHEELS_DIR} is empty (${mode} build)"
  fi
  ft_store_write_record "${mode}"
  sed 's/^/free-threaded store: /' "${FT_STORE_RECORD}"
}

main "$@"
