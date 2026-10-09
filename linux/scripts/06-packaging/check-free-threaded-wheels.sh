#!/usr/bin/env bash
# The shipped cp314t store: the twins of /opt/venv's free-threading packages, each proved again on the image's python3.14t. See docs/consumer-image-contract.md#the-free-threaded-wheels

# Sourced by smoke-runtime-image.sh; sets no shell options.
_FTS_HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# The table lives with the media scripts, loaded on first use: a sandbox of 06-packaging alone still sources this file.
_ft_store_table() {
  declare -F ft_wheel_row >/dev/null && return 0
  if [ ! -f "${_FTS_HERE}/../03-media/free-threaded-wheels.sh" ]; then
    echo "BAD the twin library is not at ${_FTS_HERE}/../03-media/free-threaded-wheels.sh"
    return 1
  fi
  # shellcheck source=../03-media/free-threaded-wheels.sh
  source "${_FTS_HERE}/../03-media/free-threaded-wheels.sh"
  ft_wheel_table >/dev/null 2>&1 || { echo "BAD the twin table is not at ${_FTS_HERE}/../03-media/free-threaded-twins.txt"; return 1; }
}

# The in-image probe: the store's record, its wheels, /opt/venv's distributions, and one 3.14t proof per wheel.
ft_store_probe_script() {
  cat <<'PROBE'
set -uo pipefail
printf 'FTS ENV %s\n' "${PYTHON_WHEELS_CP314T:-<unset>}"
store=/opt/wheels-cp314t
helper=/opt/scripts/toolchain/python/free-threaded-wheel.py
[ -d "${store}" ] || { echo "FTS NOSTORE"; echo "FTS DONE"; exit 0; }
if [ -f "${store}/free-threaded-store.txt" ]; then sed 's/^/FTS RECORD /' "${store}/free-threaded-store.txt"; else echo "FTS NORECORD"; fi
ls -1 /opt/venv/lib/python3*/site-packages 2>/dev/null | sed -n 's/^\(.*\)-[^-]*\.dist-info$/FTS GIL \1/p'
work="$(mktemp -d /tmp/fts.XXXXXX)"
export UV_CACHE_DIR="${work}/cache"
if compgen -G "${store}/*.whl" >/dev/null; then
  uv venv --quiet --python /usr/local/bin/python3.14t "${work}/venv" >/dev/null 2>&1 \
    && uv pip install --quiet --offline --no-deps --python "${work}/venv/bin/python" "${store}"/*.whl >/dev/null 2>&1 \
    || echo "FTS NOINSTALL the store does not install into a python3.14t venv"
fi
for w in "${store}"/*.whl; do
  [ -f "${w}" ] || continue
  n="${w##*/}"
  printf 'FTS WHEEL %s\n' "${n}"
  if out="$(cd / && "${work}/venv/bin/python" -I "${helper}" prove "${n%%-*}" 2>&1)"; then
    printf 'FTS PROVED %s %s\n' "${n%%-*}" "$(printf '%s' "${out}" | tr '\n' ' ')"
  else
    printf 'FTS UNPROVED %s %s\n' "${n%%-*}" "$(printf '%s' "${out}" | tr '\n' ' ')"
  fi
done
rm -rf "${work}"
echo "FTS DONE"
PROBE
}

# <probe output>: one OK/BAD line per finding; BAD ends the gate red.
ft_store_verdict() {
  local probe="$1" mode have
  _ft_store_table || return 0
  case "${probe}" in *"FTS DONE"*) ;; *) echo "BAD the in-image probe never finished"; return 0 ;; esac
  _ft_store_env_verdict "${probe}"
  case "${probe}" in *"FTS NOSTORE"*) echo "BAD /opt/wheels-cp314t is missing; every arch ships the store"; return 0 ;; esac
  case "${probe}" in *"FTS NORECORD"*) echo "BAD /opt/wheels-cp314t has no free-threaded-store.txt, so nothing says how its arch was built"; return 0 ;; esac
  mode="$(printf '%s\n' "${probe}" | sed -n 's/^FTS RECORD mode=//p' | head -n 1)"
  have="$(printf '%s\n' "${probe}" | sed -n 's/^FTS WHEEL //p')"
  case "${mode}" in
    native | cross) echo "OK the store records a ${mode} build; its twins are held to the table as on any arch" ;;
    *) echo "BAD the store records mode '${mode}', not native or cross"; return 0 ;;
  esac
  _ft_store_verdict_native "${probe}" "${have}"
}

# <probe> <dist>: 0 when its verdict is twin or twin:<KNOB> and the record wants its family, i.e. the chain shipped the GIL wheel.
_ft_store_wants() {
  case "$(ft_wheel_verdict "$2")" in
    twin | twin:*) printf '%s\n' "$1" | grep -q -x -e "FTS RECORD want $(ft_wheel_row "$2" | cut -d'|' -f1)" ;;
    *) return 1 ;;
  esac
}

# <probe>: the image advertises the store as Windows does, since uv_reconcile_chain_ort finds a 3.14t venv's ORT twin only through it.
_ft_store_env_verdict() {
  local env
  env="$(printf '%s\n' "$1" | sed -n 's/^FTS ENV //p' | head -n 1)"
  if [ "${env}" = /opt/wheels-cp314t ]; then
    echo "OK PYTHON_WHEELS_CP314T names /opt/wheels-cp314t for the chain-ORT reconcile"
  else
    echo "BAD PYTHON_WHEELS_CP314T is '${env:-<no probe line>}', not /opt/wheels-cp314t, so a 3.14t venv's chain-ORT reconcile cannot find the ORT twin"
  fi
}

# <probe> <wheels>: the families match /opt/venv's twin packages exactly, each installed flavour has its own twin, and every twin is proved; native and cross alike.
_ft_store_verdict_native() {
  local probe="$1" have="$2" gil d w fam_want="" fam_have=""
  gil="$(printf '%s\n' "${probe}" | sed -n 's/^FTS GIL //p')"
  case "${probe}" in *"FTS NOINSTALL"*) echo "BAD $(printf '%s\n' "${probe}" | sed -n 's/^FTS NOINSTALL //p' | head -n 1)" ;; esac
  for d in ${gil}; do
    if ! _ft_store_wants "${probe}" "${d}"; then
      case "$(ft_wheel_verdict "${d}")" in twin*) echo "OK ${d} declares free-threading, but the record wants no twin of it: no chain wheel of it shipped here, or its knob is off" ;; esac
      continue
    fi
    fam_want+="$(ft_wheel_row "${d}" | cut -d'|' -f1)"$'\n'
    printf '%s\n' "${have}" | grep -q -i -e "^${d//[-_.]/[-_.]}-[^-]*-cp3[0-9]*-cp3[0-9]*t-" \
      || echo "BAD /opt/venv carries ${d}, whose verdict is twin, and the store has no cp314t twin of it"
  done
  for w in ${have}; do
    case "${w}" in *-cp3[0-9]*-cp3[0-9]*t-*.whl) ;; *) echo "BAD ${w} is not a cp3XY-cp3XYt wheel" ;; esac
    _ft_store_wants "${probe}" "${w%%-*}" || echo "BAD ${w} is no twin the table allows here (verdict $(ft_wheel_verdict "${w%%-*}"))"
    fam_have+="$(ft_wheel_row "${w%%-*}" | cut -d'|' -f1)"$'\n'
    if printf '%s\n' "${probe}" | grep -q -e "^FTS PROVED ${w%%-*} "; then
      echo "OK ${w}: $(printf '%s\n' "${probe}" | sed -n "s/^FTS PROVED ${w%%-*} //p" | head -n 1)"
    else
      echo "BAD ${w} is not proved on python3.14t: $(printf '%s\n' "${probe}" | sed -n "s/^FTS UNPROVED ${w%%-*} //p" | head -n 1)"
    fi
  done
  fam_want="$(printf '%s' "${fam_want}" | LC_ALL=C sort -u | tr '\n' ' ')"
  fam_have="$(printf '%s' "${fam_have}" | LC_ALL=C sort -u | tr '\n' ' ')"
  if [ "${fam_want}" = "${fam_have}" ]; then
    echo "OK the store holds exactly the twin families of /opt/venv: ${fam_want% }"
  else
    echo "BAD the store holds the families [${fam_have% }], /opt/venv wants [${fam_want% }]"
  fi
}

# <image> <arch>: runs the probe in the shipped image and turns each verdict line into pass or fail.
check_free_threaded_wheels() {
  # shellcheck disable=SC2034  # _rt_run reads image_tag by dynamic scope
  local image_tag="$1" target_arch="$2" probe line
  echo "--- Free-threaded wheels: the cp314t store on python3.14t (${target_arch}) ---"
  probe="$(_rt_run bash -lc "$(ft_store_probe_script)" 2>/dev/null)" || true
  while IFS= read -r line; do
    case "${line}" in
      OK\ *) pass "FT-STORE: ${line#OK }" ;;
      BAD\ *) fail "FT-STORE: ${line#BAD } (${target_arch})" ;;
    esac
  done < <(ft_store_verdict "${probe}")
  echo ""
}
