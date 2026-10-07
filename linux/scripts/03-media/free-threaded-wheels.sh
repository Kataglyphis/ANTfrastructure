#!/usr/bin/env bash
# The cp314t twins of the image's wheels: which get one, and the venv, gate and proof each twin passes. See docs/consumer-image-contract.md#the-free-threaded-wheels

# Mounted per file, never under core/ or runtime/, so an edit re-keys only the RUNs that build or store a twin.
_FTW_HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# dist|twin, gil or none|the versions.env pin the evidence was read at|the evidence; a moved pin fails test-free-threaded-wheels.sh until re-read.
ft_wheel_table() {
  cat <<'FTW'
onnxruntime|twin|ONNXRUNTIME_VERSION=v1.30.0|onnxruntime/python/onnxruntime_pybind_module.cc: PYBIND11_MODULE(onnxruntime_pybind11_state, m, py::mod_gil_not_used()), on pybind11 v3.0.2
av|twin|PYAV_VERSION=19.0.1|setup.py: compiler directive "freethreading_compatible": True
apache-tvm-ffi|twin|TVM_REF=v0.27.0|3rdparty/tvm-ffi daf594da, python/tvm_ffi/cython/core.pyx: # cython: freethreading_compatible = True
iree-base-runtime|twin|IREE_VERSION=v3.12.0|runtime/bindings/python/CMakeLists.txt: nanobind_add_module(... FREE_THREADED ...)
iree-base-compiler|twin|IREE_VERSION=v3.12.0|third_party/llvm-project 6cce5bca, mlir/cmake/modules/AddMLIRPython.cmake: nanobind_add_module(... FREE_THREADED ...)
apache-tvm|none|TVM_REF=v0.27.0|pyproject.toml: wheel.py-api = "py3", no CPython extension, so its one py3 wheel installs on 3.14t
onnxruntime-genai|gil|ONNXRUNTIME_GENAI_VERSION=v0.17.0|pybind11 2.13.6 and no py::mod_gil_not_used()
ai-edge-litert|gil|LITERT_VERSION=v2.2.0|nine PYBIND11_MODULEs, none passes py::mod_gil_not_used()
hailort|gil|HAILORT_VERSION=5.4.0|pyhailort's module declares no free-threading support
libcamera|gil|LIBCAMERA_VERSION=v0.7.2|pycamera declares no free-threading support, and it ships in the tree, not as a wheel
opencv|gil|OPENCV_VERSION=5.0.0|cv2 declares no free-threading support, and it ships in the tree, not as a wheel
FTW
}

# <name>: the PEP 503 form, which is how the table spells every distribution.
_ft_norm() {
  local n="${1,,}"
  n="${n//_/-}"
  printf '%s\n' "${n//./-}"
}

# <dist>: its table row (an ORT flavour reads as onnxruntime, a GenAI flavour as onnxruntime-genai); rc 1 for none.
ft_wheel_row() {
  local want dist rest
  want="$(_ft_norm "$1")"
  case "${want}" in
    onnxruntime-genai*) want=onnxruntime-genai ;;
    onnxruntime-*) want=onnxruntime ;;
  esac
  while IFS='|' read -r dist rest; do
    if [ "${dist}" = "${want}" ]; then
      printf '%s|%s\n' "${dist}" "${rest}"
      return 0
    fi
  done < <(ft_wheel_table)
  return 1
}

# <dist>: twin, gil, none, or unknown for a distribution the table does not know.
ft_wheel_verdict() {
  local row
  row="$(ft_wheel_row "$1")" || { printf 'unknown\n'; return 0; }
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

# <dist>: 0 when this build makes the distribution's cp314t twin, else 1 with its one-line reason; 2 for a dist the table lacks.
ft_twin_wanted() {
  local dist="$1" row
  row="$(ft_wheel_row "${dist}")" || { printf 'free-threaded: %s is not in ft_wheel_table (linux/scripts/03-media/free-threaded-wheels.sh)\n' "${dist}" >&2; return 2; }
  case "${row}" in
    *"|twin|"*) ;;
    *) printf 'free-threaded: no cp314t twin of %s (%s): %s\n' "${dist}" "$(ft_wheel_verdict "${dist}")" "${row##*|}"; return 1 ;;
  esac
  if declare -F cross_build_is_active >/dev/null 2>&1 && cross_build_is_active; then
    printf 'free-threaded: no cp314t twin of %s in a cross build yet (docs/consumer-image-contract.md#the-free-threaded-wheels)\n' "${dist}"
    return 1
  fi
  ft_python_resolve || { printf 'free-threaded: %s needs a cp314t twin, and this image has no interpreter to build it with\n' "${dist}" >&2; return 2; }
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

# <wheel> [ext-suffix]: 0 when the name says cp3XY-cp3XYt and every version-tagged extension carries the free-threaded SOABI.
ft_soabi_gate() {
  local wheel="$1" want="${2:-}" out
  if [ -z "${want}" ]; then
    want="$("${FT_PYTHON:?ft_python_resolve first}" -I -c 'import sysconfig; print(sysconfig.get_config_var("EXT_SUFFIX"))')" || return 1
  fi
  out="$("${FT_PYTHON:-python3}" -I - "${wheel}" "${want}" <<'PY'
import re, sys, zipfile
wheel, want = sys.argv[1], sys.argv[2]
m = re.fullmatch(r"\.cpython-(\d+)t-[^.]+\.so", want)
if not m:
    sys.exit("the expected suffix %s is not a free-threaded one" % want)
tag = "cp" + m.group(1)
parts = wheel.rsplit("/", 1)[-1][:-4].split("-")
bad = [] if parts[-3:-1] == [tag, tag + "t"] else ["the name is %s-%s, not %s-%st" % (parts[-3], parts[-2], tag, tag)]
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
  venv="$(mktemp -d "${TMPDIR:-/tmp}/ft-prove.XXXXXX")"
  if uv venv --clear --quiet --python "${FT_PYTHON:?ft_python_resolve first}" "${venv}" \
     && uv pip install --quiet --python "${venv}/bin/python" --no-deps "${wheel}"; then
    out="$(cd / && "${venv}/bin/python" -I "${helper}" prove "${dist}" 2>&1)" || rc=$?
  else
    out="${wheel##*/} does not install into a fresh ${FT_PYTHON} venv"
    rc=1
  fi
  rm -rf "${venv}"
  if [ "${rc}" -ne 0 ]; then
    printf 'free-threaded: %s is not proved: %s\n' "${wheel##*/}" "${out}" >&2
    return 1
  fi
  printf 'free-threaded: %s: %s\n' "${wheel##*/}" "${out}"
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
