#!/usr/bin/env bash
# The cp314t twins of the image's wheels: which get one, and the venv, gate and proof each twin passes. See docs/consumer-image-contract.md#the-free-threaded-wheels

# Mounted per file, never under core/ or runtime/, so an edit re-keys only the RUNs that build or store a twin.
_FTW_HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# The one twin table, which Windows' Get-FreeThreadedTwinTable reads too; every RUN that sources this file mounts it beside it.
_FTW_TABLE="${_FTW_HERE}/free-threaded-twins.txt"

# dist|twin, gil or none|pin|evidence, one row per line; rc 1 when the table is missing, so no lookup reads as unclassified.
ft_wheel_table() {
  if [ ! -f "${_FTW_TABLE}" ]; then
    printf 'free-threaded: the twin table %s is missing; mount linux/scripts/03-media/free-threaded-twins.txt beside free-threaded-wheels.sh\n' "${_FTW_TABLE}" >&2
    return 1
  fi
  sed -e '/^#/d' -e '/^[[:space:]]*$/d' "${_FTW_TABLE}"
}

# <name>: the PEP 503 form, which is how the table spells every distribution.
_ft_norm() {
  local n="${1,,}"
  n="${n//_/-}"
  printf '%s\n' "${n//./-}"
}

# <dist>: its table row (an ORT flavour reads as onnxruntime, a GenAI flavour as onnxruntime-genai); rc 1 for none, 2 without a table.
ft_wheel_row() {
  local want dist rest table
  want="$(_ft_norm "$1")"
  case "${want}" in
    onnxruntime-genai*) want=onnxruntime-genai ;;
    onnxruntime-*) want=onnxruntime ;;
  esac
  table="$(ft_wheel_table)" || return 2
  while IFS='|' read -r dist rest; do
    if [ "${dist}" = "${want}" ]; then
      printf '%s|%s\n' "${dist}" "${rest}"
      return 0
    fi
  done <<< "${table}"
  return 1
}

# <dist>: twin, gil, none, or unknown for a distribution the table does not know; rc 2 and no verdict without a table.
ft_wheel_verdict() {
  local row rc=0
  row="$(ft_wheel_row "$1")" || rc=$?
  case "${rc}" in
    0) ;;
    1) printf 'unknown\n'; return 0 ;;
    *) return "${rc}" ;;
  esac
  row="${row#*|}"
  printf '%s\n' "${row%%|*}"
}

# The free-threaded interpreter of this image into FT_PYTHON; rc 1 says why on stderr.
ft_python_resolve() {
  local prefix="${PYTHON_FT_PREFIX:-/opt/python-freethreaded}" py
  py="$(compgen -G "${prefix}/bin/python3.*t" | head -1 || true)"
  if [ -z "${py}" ] || [ ! -x "${py}" ]; then
    printf 'no free-threaded interpreter under %s/bin\n' "${prefix}" >&2
    return 1
  fi
  if [ "$("${py}" -I -c 'import sysconfig; print(sysconfig.get_config_var("Py_GIL_DISABLED"))' 2>/dev/null)" != 1 ]; then
    printf '%s is not a --disable-gil build\n' "${py}" >&2
    return 1
  fi
  FT_PYTHON="${py}"
}

# <dist>: 0 when the table expects its twin from a build that ships its GIL wheel; twin:<KNOB> rows only while that knob is 1.
ft_twin_expected() {
  local verdict knob
  verdict="$(ft_wheel_verdict "$1")" || return 2
  case "${verdict}" in
    twin) return 0 ;;
    twin:*) knob="${verdict#twin:}"; [ "${!knob:-0}" = 1 ] ;;
    *) return 1 ;;
  esac
}

# 0 in a cross build of this image; the twin then builds on the host's 3.14t against the target's.
_ft_cross() {
  declare -F cross_build_is_active >/dev/null 2>&1 || return 1
  cross_build_is_active
}

# <arch>: the wheel machine of an image arch (the SOABI triplet's first field).
_ft_machine() {
  case "$1" in
    amd64 | x86_64) printf 'x86_64\n' ;;
    arm64 | aarch64) printf 'aarch64\n' ;;
    riscv64) printf 'riscv64\n' ;;
    *) return 1 ;;
  esac
}

# The cross target's 3.14t tree into FT_TARGET_*: prefix, interpreter, include, libpython, EXT_SUFFIX, wheel platform, sysconfig; rc 1 says why.
ft_target_resolve() {
  local arch machine prefix sc
  arch="$(cross_target_arch 2>/dev/null || true)"
  machine="$(_ft_machine "${arch}")" || { printf 'free-threaded: no wheel machine for cross target arch %s\n' "${arch:-<unset>}" >&2; return 1; }
  prefix="${FT_TARGET_PREFIX:-${PYTHON_FT_CROSS_STAGE_ROOT:-/opt/python-cross-ft}/${arch}${PYTHON_FT_PREFIX:-/opt/python-freethreaded}}"
  FT_TARGET_PYTHON="$(compgen -G "${prefix}/bin/python3.*t" | head -1 || true)"
  sc="$(compgen -G "${prefix}/lib/python3.*t/_sysconfigdata_t_*.py" | head -1 || true)"
  if [ -z "${FT_TARGET_PYTHON}" ] || [ -z "${sc}" ]; then
    printf 'free-threaded: the %s 3.14t tree %s has no bin/python3.*t or _sysconfigdata_t_*.py (the toolchain stages it, CON66)\n' "${arch}" "${prefix}" >&2
    return 1
  fi
  FT_TARGET_EXT_SUFFIX="$("${FT_PYTHON:?ft_python_resolve first}" -I -c 'import runpy, sys; print(runpy.run_path(sys.argv[1])["build_time_vars"]["EXT_SUFFIX"])' "${sc}")" || return 1
  if [[ ! "${FT_TARGET_EXT_SUFFIX}" =~ ^\.cpython-[0-9]+t-${machine}-linux-gnu\.so$ ]]; then
    printf 'free-threaded: %s gives EXT_SUFFIX %s, not a free-threaded %s one\n' "${sc}" "${FT_TARGET_EXT_SUFFIX}" "${machine}" >&2
    return 1
  fi
  FT_TARGET_ARCH="${arch}"
  FT_TARGET_PREFIX="${prefix}"
  FT_TARGET_LDVERSION="${FT_TARGET_PYTHON##*/python}"
  FT_TARGET_INCLUDE="${prefix}/include/python${FT_TARGET_LDVERSION}"
  # shellcheck disable=SC2034  # read by the IREE and torch twins, which source this file
  FT_TARGET_LIBRARY="${prefix}/lib/libpython${FT_TARGET_LDVERSION}.so"
  FT_TARGET_PLATFORM_TAG="linux_${machine}"
  FT_TARGET_SYSCONFIG_NAME="$(basename "${sc}" .py)"
  # A dir of its own: the target stdlib beside it must never shadow the host interpreter's.
  FT_TARGET_SYSCONFIG_DIR="${TMPDIR:-/tmp}/ft-target-sysconfig-${arch}"
  mkdir -p "${FT_TARGET_SYSCONFIG_DIR}" && cp -f "${sc}" "${FT_TARGET_SYSCONFIG_DIR}/" || return 1
  [ -f "${FT_TARGET_INCLUDE}/Python.h" ] || { printf 'free-threaded: no %s/Python.h\n' "${FT_TARGET_INCLUDE}" >&2; return 1; }
}

# Eval-able exports that make the host 3.14t report the target's EXT_SUFFIX and platform to a wheel build; empty on a native build.
ft_target_env() {
  _ft_cross || return 0
  printf 'export _PYTHON_SYSCONFIGDATA_NAME=%q _PYTHON_HOST_PLATFORM=%q; export PYTHONPATH=%q${PYTHONPATH:+:${PYTHONPATH}}\n' \
    "${FT_TARGET_SYSCONFIG_NAME:?ft_target_resolve first}" "${FT_TARGET_PLATFORM_TAG}" "${FT_TARGET_SYSCONFIG_DIR}"
}

# <dist>: 0 when this build makes the distribution's cp314t twin, else 1 with its one-line reason; 2 for a dist the table lacks.
ft_twin_wanted() {
  local dist="$1" row rc=0 verdict
  row="$(ft_wheel_row "${dist}")" || rc=$?
  if [ "${rc}" -eq 1 ]; then
    printf 'free-threaded: %s is not in ft_wheel_table (linux/scripts/03-media/free-threaded-twins.txt)\n' "${dist}" >&2
  fi
  [ "${rc}" -eq 0 ] || return 2
  verdict="$(ft_wheel_verdict "${dist}")"
  case "${verdict}" in
    twin) ;;
    twin:*)
      if ! ft_twin_expected "${dist}"; then
        printf 'free-threaded: no cp314t twin of %s: the %s knob is off (%s)\n' "${dist}" "${verdict#twin:}" "${row##*|}"
        return 1
      fi ;;
    *) printf 'free-threaded: no cp314t twin of %s (%s): %s\n' "${dist}" "${verdict}" "${row##*|}"; return 1 ;;
  esac
  ft_python_resolve || { printf 'free-threaded: %s needs a cp314t twin, and this image has no interpreter to build it with\n' "${dist}" >&2; return 2; }
  if _ft_cross; then
    ft_target_resolve || { printf 'free-threaded: %s needs a cp314t twin, and this cross build has no target 3.14t tree to build it against\n' "${dist}" >&2; return 2; }
    printf 'free-threaded: building the cp314t twin of %s for %s (%s, %s)\n' "${dist}" "${FT_TARGET_ARCH}" "${FT_TARGET_EXT_SUFFIX}" "${FT_TARGET_PYTHON}"
  fi
}

# <venv> <gil-python> <pkg>...: a free-threaded build venv whose executors are the GIL build venv's own versions; pkg==ver passes as given.
ft_build_venv() {
  local venv="$1" gil="$2" pkg ver
  shift 2
  local -a reqs=()
  for pkg in "$@"; do
    case "${pkg}" in
      *==*) reqs+=("${pkg}"); continue ;;
    esac
    ver="$("${gil}" -I -c 'import importlib.metadata as m, sys; print(m.version(sys.argv[1]))' "${pkg}" 2>/dev/null || true)"
    if [ -z "${ver}" ]; then
      printf 'free-threaded: the GIL build venv %s has no %s, so its twin has no version to match\n' "${gil}" "${pkg}" >&2
      return 1
    fi
    reqs+=("${pkg}==${ver}")
  done
  uv venv --clear --quiet --python "${FT_PYTHON:?ft_python_resolve first}" "${venv}" || return 1
  if [ "${#reqs[@]}" -gt 0 ]; then
    uv pip install --quiet --python "${venv}/bin/python" "${reqs[@]}" || return 1
  fi
  printf 'free-threaded: build venv %s on %s with' "${venv}" "${FT_PYTHON}"
  printf ' %s' "${reqs[@]}" ''
  printf '\n'
}

# <dist> <venv> <gil-python> <pkg>...: 0 with the twin's build venv ready, 1 when this build makes no twin (reason printed), 2 on an error.
ft_twin_start() {
  local dist="$1" rc=0
  shift
  ft_twin_wanted "${dist}" || rc=$?
  if [ "${rc}" -ne 0 ]; then
    return "${rc}"
  fi
  ft_build_venv "$@" || return 2
}

# <wheel> [ext-suffix]: 0 when the name says cp3XY-cp3XYt for the suffix's machine and every version-tagged extension carries the free-threaded SOABI.
ft_soabi_gate() {
  local wheel="$1" want="${2:-}" out
  if [ -z "${want}" ] && _ft_cross; then
    # The target's suffix: the host 3.14t's would pass an x86_64 module in a riscv64 twin.
    [ -n "${FT_TARGET_EXT_SUFFIX:-}" ] || ft_target_resolve || return 1
    want="${FT_TARGET_EXT_SUFFIX}"
  fi
  if [ -z "${want}" ]; then
    want="$("${FT_PYTHON:?ft_python_resolve first}" -I -c 'import sysconfig; print(sysconfig.get_config_var("EXT_SUFFIX"))')" || return 1
  fi
  out="$("${FT_PYTHON:-python3}" -I - "${wheel}" "${want}" <<'PY'
import re, sys, zipfile
wheel, want = sys.argv[1], sys.argv[2]
m = re.fullmatch(r"\.cpython-(\d+)t-([^-.]+)-[^.]+\.so", want)
if not m:
    sys.exit("the expected suffix %s is not a free-threaded one" % want)
tag, machine = "cp" + m.group(1), m.group(2)
parts = wheel.rsplit("/", 1)[-1][:-4].split("-")
if len(parts) < 5 or not wheel.endswith(".whl"):
    sys.exit("%s is no wheel file name" % wheel)
bad = [] if parts[-3:-1] == [tag, tag + "t"] else ["the name is %s-%s, not %s-%st" % (parts[-3], parts[-2], tag, tag)]
if not all(p.endswith("_" + machine) for p in parts[-1].split(".")):
    bad.append("the platform tag is %s, not one for %s" % (parts[-1], machine))
for name in zipfile.ZipFile(wheel).namelist():
    base = name.rsplit("/", 1)[-1]
    if base.endswith(".abi3.so") or (re.search(r"\.cpython-\d+t?-", base) and base.endswith(".so") and not base.endswith(want)):
        bad.append("%s is not %s" % (name, want))
print("\n".join(bad))
PY
)" || return 1
  if [ -n "${out}" ]; then
    printf 'free-threaded: %s fails the cp314t SOABI gate:\n%s\n' "${wheel##*/}" "${out}" >&2
    return 1
  fi
}

# free-threaded-wheel.py beside this file in an image RUN, else in the repo.
_ft_helper() {
  local f
  for f in "${_FTW_HERE}/free-threaded-wheel.py" "${_FTW_HERE}/../02-toolchain/python/free-threaded-wheel.py"; do
    if [ -f "${f}" ]; then
      printf '%s\n' "${f}"
      return 0
    fi
  done
  printf 'free-threaded-wheel.py is neither beside %s nor in the repo\n' "${_FTW_HERE}" >&2
  return 1
}

# <wheel> <dist>: a fresh venv of the free-threaded interpreter takes the wheel alone, and loading every compiled module leaves the GIL off.
ft_prove_wheel() {
  local wheel="$1" dist="$2" helper venv out rc=0
  helper="$(_ft_helper)" || return 1
  if _ft_cross; then
    ft_prove_wheel_on_target "${wheel}" "${dist}" "${helper}"
    return
  fi
  venv="$(mktemp -d "${TMPDIR:-/tmp}/ft-prove.XXXXXX")"
  if uv venv --clear --quiet --python "${FT_PYTHON:?ft_python_resolve first}" "${venv}" \
     && uv pip install --quiet --python "${venv}/bin/python" --no-deps "${wheel}"; then
    out="$(cd / && "${venv}/bin/python" -I "${helper}" prove "${dist}" 2>&1)" || rc=$?
  else
    out="${wheel##*/} does not install into a fresh ${FT_PYTHON} venv"
    rc=1
  fi
  rm -rf "${venv}"
  _ft_prove_verdict "${wheel}" "${rc}" "${out}"
}

# <wheel> <rc> <output>: the proof's one line, on stdout when it held, else on stderr with rc 1.
_ft_prove_verdict() {
  if [ "$2" -ne 0 ]; then
    printf 'free-threaded: %s is not proved: %s\n' "${1##*/}" "$3" >&2
    return 1
  fi
  printf 'free-threaded: %s: %s\n' "${1##*/}" "$3"
}

# <arch>: the root under which qemu-user finds the target's dynamic loader (the multiarch / or the cross sysroot).
_ft_qemu_sysroot() {
  local machine root loader
  machine="$(_ft_machine "$1")" || return 1
  case "${machine}" in
    aarch64) loader=ld-linux-aarch64.so.1 ;;
    riscv64) loader=ld-linux-riscv64-lp64d.so.1 ;;
    *) loader=ld-linux-x86-64.so.2 ;;
  esac
  for root in "${FT_QEMU_SYSROOT:-}" "/usr/${machine}-linux-gnu" /; do
    [ -n "${root}" ] || continue
    if [ -e "${root%/}/lib/${loader}" ]; then printf '%s\n' "${root}"; return 0; fi
  done
  printf 'free-threaded: no %s under /usr/%s-linux-gnu/lib or /lib for qemu-user\n' "${loader}" "${machine}" >&2
  return 1
}

# <wheel> <dist> <helper>: the cross twin unpacked beside the target's own 3.14t, which loads every compiled module under qemu-user.
ft_prove_wheel_on_target() {
  local wheel="$1" dist="$2" helper="$3" qemu sysroot site out rc=0 d triplet
  [ -n "${FT_TARGET_PYTHON:-}" ] || ft_target_resolve || return 1
  qemu="$(cross_target_qemu_runner 2>/dev/null || true)"
  [ -n "${qemu}" ] || { printf 'free-threaded: %s cannot be proved: no qemu-user for %s\n' "${wheel##*/}" "${FT_TARGET_ARCH}" >&2; return 1; }
  sysroot="$(_ft_qemu_sysroot "${FT_TARGET_ARCH}")" || return 1
  triplet="$(_ft_machine "${FT_TARGET_ARCH}")-linux-gnu"
  site="$(mktemp -d "${TMPDIR:-/tmp}/ft-prove.XXXXXX")"
  # A wheel install is an unzip plus its .data/{purelib,platlib} moved up; the target interpreter cannot drive uv here.
  if out="$("${FT_PYTHON:?ft_python_resolve first}" -I -c '
import pathlib, sys, zipfile
site = pathlib.Path(sys.argv[2])
zipfile.ZipFile(sys.argv[1]).extractall(site)
for data in site.glob("*.data"):
    for part in ("purelib", "platlib"):
        for item in sorted((data / part).rglob("*")):
            if item.is_file():
                dest = site / item.relative_to(data / part)
                dest.parent.mkdir(parents=True, exist_ok=True)
                item.replace(dest)
' "${wheel}" "${site}" 2>&1)"; then
    d="${FT_TARGET_PREFIX}/lib:${sysroot%/}/lib/${triplet}:${sysroot%/}/usr/lib/${triplet}:${sysroot%/}/lib${LD_LIBRARY_PATH:+:${LD_LIBRARY_PATH}}"
    out="$(cd / && "${qemu}" -L "${sysroot}" -E "LD_LIBRARY_PATH=${d}" -U PYTHONPATH -U PYTHONHOME \
      "${FT_TARGET_PYTHON}" -I -c 'import runpy, sys; sys.path.insert(0, sys.argv[1]); sys.argv = sys.argv[2:]; runpy.run_path(sys.argv[0], run_name="__main__")' \
      "${site}" "${helper}" prove "${dist}" 2>&1)" || rc=$?
    out="${out} (on ${FT_TARGET_ARCH} under ${qemu##*/})"
  else
    out="${wheel##*/} does not unpack: ${out}"
    rc=1
  fi
  rm -rf "${site}"
  _ft_prove_verdict "${wheel}" "${rc}" "${out}"
}

# <wheel> <store>: gate, proof, then the store; nothing unproved is ever stored.
ft_store_twin() {
  local wheel="$1" store="$2" dist
  dist="${wheel##*/}"
  dist="${dist%%-*}"
  ft_soabi_gate "${wheel}" || return 1
  ft_prove_wheel "${wheel}" "${dist}" || return 1
  mkdir -p "${store}" && cp -f "${wheel}" "${store}/" || return 1
  printf 'free-threaded: stored %s in %s\n' "${wheel##*/}" "${store}"
}

# <dist dir> <store>: the one twin a free-threaded build left there, gated, proved and stored, then gone from the build tree.
ft_twin_store_built() {
  local wheel
  wheel="$(ft_built_wheel "$1")" || return 1
  ft_store_twin "${wheel}" "$2" || return 1
  rm -f "${wheel}"
}

# <dir>: the one cp3XYt wheel a free-threaded build left there; rc 1 says what it found instead.
ft_built_wheel() {
  local -a found=()
  mapfile -t found < <(compgen -G "$1/*-cp3[0-9]*t-*.whl" || true)
  if [ "${#found[@]}" -ne 1 ]; then
    printf 'free-threaded: expected one cp3XYt wheel in %s, found %s among: %s\n' "$1" "${#found[@]}" "$(cd "$1" 2>/dev/null && printf '%s ' ./*)" >&2
    return 1
  fi
  printf '%s\n' "${found[0]}"
}
