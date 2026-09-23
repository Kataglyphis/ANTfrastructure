#!/usr/bin/env bash
# test-ort-provenance-build.sh - G2 (03-media/ort-provenance.sh) over fixture trees under the consumers' strict mode, its
# stamp as the census reads it, and its wiring. NOT covered: a real consumer build, record formats beyond these shapes.
set -u
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${TESTS_DIR}/test-harness.sh"
SCRIPTS="$(cd "${TESTS_DIR}/.." && pwd)"
GATE="${SCRIPTS}/03-media/ort-provenance.sh"
CENSUS="${SCRIPTS}/06-packaging/check-ort-provenance.sh"
DF="${SCRIPTS}/../Dockerfile.media"
# Git Bash on a Windows host makes copies for `ln -s` without this; a no-op on Linux.
export MSYS=winsymlinks:nativestrict

_WORK="$(mktemp -d)"
trap 'rm -rf "${_WORK}"' EXIT
# G2 grades the caller's fetch caches by default: every case sees only the ones under its own HOME, or those it names.
unset XDG_CACHE_HOME PIP_CACHE_DIR UV_CACHE_DIR CARGO_HOME NUGET_PACKAGES
export FFMPEG_SDK_CACHE="${_WORK}/no-ffmpeg-sdks"

_put() {  # <file> <text>
  mkdir -p "$(dirname "$1")"
  printf '%s' "$2" > "$1"
}

# _case <name>: a chain (versioned .so + links, nested headers), and an OpenCV-shaped tree built through a compat shim.
_case() {
  CASE="${_WORK}/$1"
  CHAIN="${CASE}/usr/local/lib/onnxruntime-cpu"
  TREE="${CASE}/tmp/opencv-1"
  SHIM="${TREE}/build/ort-compat"
  STAMP="${CASE}/opt/opencv5/ort-provenance/opencv.json"
  _put "${CHAIN}/include/onnxruntime/onnxruntime_c_api.h" "chain c api"
  _put "${CHAIN}/include/onnxruntime/cpu_provider_factory.h" "chain cpu"
  _put "${CHAIN}/lib/libonnxruntime.so.1.30.0" "chain so"
  _put "${CHAIN}/lib/pkgconfig/libonnxruntime.pc" "Libs: -lonnxruntime"
  ln -sf libonnxruntime.so.1.30.0 "${CHAIN}/lib/libonnxruntime.so.1"
  ln -sf libonnxruntime.so.1 "${CHAIN}/lib/libonnxruntime.so"
  _put "${TREE}/opencv/modules/dnn/src/net_onnxruntime.cpp" "int x;"
  mkdir -p "${SHIM}"
  cp -a "${CHAIN}/include" "${SHIM}/include"
  ln -sfn "${CHAIN}/lib" "${SHIM}/lib"
  _put "${TREE}/build/CMakeCache.txt" "ONNXRT_ROOT_DIR:PATH=${SHIM}
ONNX_LIBRARIES:FILEPATH=${SHIM}/lib/libonnxruntime.so
"
  _put "${TREE}/build/build.ninja" "build modules/dnn/libopencv_dnn.so: CXX_SHARED_LIBRARY_LINKER x.o
 LINK_FLAGS = -Wl,-rpath,${CHAIN}/lib -I${SHIM}/include/onnxruntime
"
  _put "${TREE}/build/opencv-configure.log" "-- DNN: ONNX Runtime enabled
"
}

# _run [extra args...]: G2 under build-opencv.sh's strict mode and IFS, with a private HOME; sets RC and OUTPUT.
_run() {
  OUTPUT="$(HOME="${CASE}/home" XDG_CACHE_HOME="" bash -c 'set -euo pipefail; IFS=$'"'"'\n\t'"'"'
    source "$1"; shift
    ort_assert_chain_only opencv "$@"' _ "${GATE}" --stamp "${STAMP}" --chain "${CHAIN}" --chain "${CASE}/no-gpu" --tree "${TREE}" \
    --shim "${SHIM}" --record "${TREE}/build/CMakeCache.txt" --record "${TREE}/build/build.ninja" \
    --log "${TREE}/build/opencv-configure.log" "$@" 2>&1)" && RC=0 || RC=$?
}

# _red <want> [extra args...]: the gate fails with <want> among its findings and leaves no stamp.
_red() {
  local want="$1"
  shift
  _run "$@"
  t_assert_eq 1 "${RC}" "expected a finding '${want}': ${OUTPUT}"
  t_assert_contains "${OUTPUT}" "${want}"
  t_assert_fails test -e "${STAMP}"
}

t_case "a clean build through a shim passes and stamps the chain core lib, which the census accepts (mutation)"
_case clean; _run
t_assert_eq 0 "${RC}" "${OUTPUT}"
t_assert_contains "${OUTPUT}" "ORT-GATE OK (opencv)"
_core="$(sha256sum < "${CHAIN}/lib/libonnxruntime.so.1.30.0")"; _core="${_core%% *}"
# The census's python reads host paths (Git Bash hands a Windows python a POSIX one otherwise).
_host_stamp="$(cd "$(dirname "${STAMP}")" && { pwd -W 2>/dev/null || pwd; })/$(basename "${STAMP}")"
_host_probe="$(cd "${SCRIPTS}/06-packaging" && { pwd -W 2>/dev/null || pwd; })/ort_census_probe.py"
_fields="$(t_gate_probe "${_host_probe}" <<PY
c, shas = g.stamp_fields("/", r"${_host_stamp}")
print(c, " ".join(shas))
PY
)"
t_assert_contains "${_fields}" "opencv ${_core}" "the census reads consumer + the chain core sha from the stamp"
t_assert_ok grep -q -e '"ortFilesCompared": "[1-9]' "${STAMP}"

t_case "another onnxruntime_c_api.h under build/3rdparty/onnxruntime fails (mutation)"
_case foreign-header
_put "${TREE}/build/3rdparty/onnxruntime/include/onnxruntime_c_api.h" "ort 1.25.1"
_red "${TREE}/build/3rdparty/onnxruntime/include/onnxruntime_c_api.h is not the chain's onnxruntime_c_api.h"

t_case "an ORT binary the chain does not build, and a hidden foreign copy, fail (mutation)"
_case foreign-bin
_put "${TREE}/build/lib/libonnxruntime_providers_openvino.so" "x"
_put "${TREE}/.cache/libonnxruntime.so.1.30.0" "pypi so"
_red "libonnxruntime_providers_openvino.so is an ONNX Runtime binary the chain does not build"
t_assert_contains "${OUTPUT}" "${TREE}/.cache/libonnxruntime.so.1.30.0 is not the chain's"

t_case "an ORT archive in _deps fails, a .tar.lzma2 too; GenAI's own wheel does not (mutation)"
_case archive
_put "${TREE}/build/_deps/onnxruntime-linux-x64-1.25.1.tgz" "tgz"
_red "an ONNX Runtime archive: ${TREE}/build/_deps/onnxruntime-linux-x64-1.25.1.tgz"
rm -f "${TREE}/build/_deps/onnxruntime-linux-x64-1.25.1.tgz"
_put "${TREE}/dist/onnxruntime_genai-0.15.2-cp314-cp314-linux_x86_64.whl" "genai"
_run; t_assert_eq 0 "${RC}" "the GenAI wheel is not ORT: ${OUTPUT}"
_put "${CASE}/cache/x/ab12.tar.lzma2" "pyke"
_red "an ONNX Runtime archive: ${CASE}/cache/x/ab12.tar.lzma2" --cache "${CASE}/cache"

t_case "a FetchContent ORT dir, a release dir and anything in pyke's cache fail (mutation)"
_case fetched
mkdir -p "${TREE}/build/_deps/onnxruntime-src"
_red "fetched ONNX Runtime content at ${TREE}/build/_deps/onnxruntime-src"
rm -rf "${TREE}/build/_deps"
mkdir -p "${TREE}/3rdparty/onnxruntime-linux-aarch64-1.25.1"
_red "fetched ONNX Runtime content at ${TREE}/3rdparty/onnxruntime-linux-aarch64-1.25.1"
rm -rf "${TREE}/3rdparty"
_put "${CASE}/home/.cache/ort.pyke.io/dfbin/x86_64-unknown-linux-gnu/abc/libonnxruntime.a" "pyke static"
_red "pyke's ORT download cache holds ${CASE}/home/.cache/ort.pyke.io/"

t_case "pip's HTTP cache: a body that is an ORT wheel fails; GenAI's wheel and a non-wheel body do not (mutation)"
# _zipto <file> <member>: a one-member zip, the shape pip >= 23.3 keeps a downloaded wheel's body in.
_zipto() {
  mkdir -p "$(dirname "$1")"
  (cd "$(dirname "$1")" && "${PREFLIGHT_PYTHON:-python3}" - "$(basename "$1")" "$2" <<'PY'
import sys
import zipfile

with zipfile.ZipFile(sys.argv[1], "w") as body:
    body.writestr(sys.argv[2], "x")
PY
  )
}
_case pip
_zipto "${CASE}/home/.cache/pip/http-v2/a/b/c1.body" onnxruntime_genai/__init__.py
_put "${CASE}/home/.cache/pip/http-v2/a/b/c2.body" "not a zip"
_zipto "${CASE}/home/.cache/pip/http-v2/a/b/c3.body" optimum/onnxruntime/modeling_ort.py
_run; t_assert_eq 0 "${RC}" "GenAI's wheel, optimum's onnxruntime/ subpackage and a non-wheel body pass: ${OUTPUT}"
_zipto "${CASE}/home/.cache/pip/http-v2/a/b/c4.body" onnxruntime/capi/onnxruntime_pybind11_state.so
_red "pip's HTTP cache holds an ONNX Runtime wheel: ${CASE}/home/.cache/pip/http-v2/a/b/c4.body"
_case pip-dir
_zipto "${CASE}/pipc/http-v2/d/e.body" onnxruntime/__init__.py
PIP_CACHE_DIR="${CASE}/pipc" _red "pip's HTTP cache holds an ONNX Runtime wheel: ${CASE}/pipc/http-v2/d/e.body"
_put "${CASE}/pipc/wheels/ab/onnxruntime-1.20.0-cp314-cp314-linux_x86_64.whl" "built from an sdist"
PIP_CACHE_DIR="${CASE}/pipc" _red "an ONNX Runtime archive: ${CASE}/pipc/wheels/ab/onnxruntime-1.20.0-cp314-cp314-linux_x86_64.whl"
_case pip-unread
_zipto "${CASE}/home/.cache/pip/http-v2/a/b/real.body" optimum/__init__.py
# A body the real scanner cannot open (here a dangling link) is a finding, never skipped as "not a zip".
ln -s "${CASE}/gone.body" "${CASE}/home/.cache/pip/http-v2/a/b/c.body"
_red "pip's HTTP cache at ${CASE}/home/.cache/pip/http-v2: cannot read the cached file a/b/c.body"
_case pip-nopy
_zipto "${CASE}/home/.cache/pip/http-v2/a/b/c.body" onnxruntime/__init__.py
mkdir -p "${CASE}/nopy"
printf '#!/bin/sh\nexit 127\n' > "${CASE}/nopy/python3"
chmod +x "${CASE}/nopy/python3"
PATH="${CASE}/nopy:${PATH}" _red "cannot inspect pip's HTTP cache at ${CASE}/home/.cache/pip/http-v2"

t_case "uv's cache: an ORT wheel it fetched over HTTP fails; a local chain wheel, an older chain unpack, GenAI and lock metadata do not (mutation)"
_case uv
_uvw="${CASE}/home/.cache/uv/wheels-v6"
_put "${_uvw}/index/5c361b7f9b49d939/onnxruntime/1.30.0-cp314-cp314-linux_x86_64.rev" "a --find-links /opt/wheels install"
_put "${_uvw}/url/d36823657eddf3aa/onnxruntime/1.30.0-cp314-cp314-linux_x86_64.rev" "a wheel-path install"
_put "${CASE}/home/.cache/uv/archive-v0/Ab12/onnxruntime/capi/onnxruntime_pybind11_state.cpython-314-x86_64-linux-gnu.so" "last month's chain"
_put "${_uvw}/pypi/onnxruntime-genai/0.14.0-cp314-cp314-manylinux_2_28_x86_64.http" "genai"
_put "${_uvw}/pypi/onnxruntime/1.24.0-cp314-cp314-macosx_14_0_arm64.msgpack" "resolver metadata"
_run; t_assert_eq 0 "${RC}" "${OUTPUT}"
_put "${_uvw}/pypi/onnxruntime/1.30.0-cp314-cp314-manylinux_2_27_x86_64.http" "pypi"
_red "uv's cache holds an ONNX Runtime wheel downloaded over HTTP: ${_uvw}/pypi/onnxruntime/1.30.0-cp314-cp314-manylinux_2_27_x86_64.http"
_case uv-index
_put "${CASE}/uvc/wheels-v6/index/09e0bc338403d139/onnxruntime-gpu/1.30.0-cp314-cp314-manylinux_2_28_x86_64.http" "an index"
UV_CACHE_DIR="${CASE}/uvc" _red "uv's cache holds an ONNX Runtime wheel downloaded over HTTP: ${CASE}/uvc/wheels-v6/index/09e0bc338403d139/onnxruntime-gpu/"
_case uv-unreadable
mkdir -p "${CASE}/home/.cache/uv/wheels-v6" "${CASE}/fakefind"
# A find that cannot read uv's wheel index: the scan is a finding, never a quiet pass.
cat > "${CASE}/fakefind/find" <<EOF
#!/usr/bin/env bash
case "\$*" in *wheels-v*) echo "find: '\$2/wheels-v6/pypi': Permission denied" >&2; exit 1 ;; esac
exec "$(command -v find)" "\$@"
EOF
chmod +x "${CASE}/fakefind/find"
PATH="${CASE}/fakefind:${PATH}" _red "cannot read all of ${CASE}/home/.cache/uv: find: "

t_case "cargo, the FFmpeg SDK cache and NuGet are graded like a tree, at each tool's override (mutation)"
_case cargo
_put "${CASE}/home/.cargo/registry/src/index.crates.io-1/foo-0.1.0/lib/libonnxruntime.so.1.20.0" "vendored"
_red "${CASE}/home/.cargo/registry/src/index.crates.io-1/foo-0.1.0/lib/libonnxruntime.so.1.20.0 is an ONNX Runtime binary the chain does not build"
_case cargo-git
mkdir -p "${CASE}/cargo/git/checkouts/foo-1/abc/onnxruntime-linux-x64-1.20.0"
CARGO_HOME="${CASE}/cargo" _red "fetched ONNX Runtime content at ${CASE}/cargo/git/checkouts/foo-1/abc/onnxruntime-linux-x64-1.20.0"
_case sdks
_put "${CASE}/sdks/onnxruntime-linux-x64-1.25.1.tgz" "tgz"
_put "${CASE}/sdks/synth-pkgconfig/libonnxruntime.pc" "Libs: -lonnxruntime"
FFMPEG_SDK_CACHE="${CASE}/sdks" _red "an ONNX Runtime archive: ${CASE}/sdks/onnxruntime-linux-x64-1.25.1.tgz"
t_assert_fails grep -q -e 'libonnxruntime.pc' <<< "${OUTPUT}"
_case nuget
mkdir -p "${CASE}/home/.nuget/packages/microsoft.ml.onnxruntime/1.24.4"
_red "fetched ONNX Runtime content at ${CASE}/home/.nuget/packages/microsoft.ml.onnxruntime"
_case nuget-dir
mkdir -p "${CASE}/nuget/microsoft.ml.onnxruntime.directml/1.24.4" "${CASE}/nuget/microsoft.ml.onnxruntimegenai/0.14.0"
NUGET_PACKAGES="${CASE}/nuget" _red "fetched ONNX Runtime content at ${CASE}/nuget/microsoft.ml.onnxruntime.directml"
t_assert_fails grep -q -e 'onnxruntimegenai' <<< "${OUTPUT}"

t_case "a cache's files are not the tree's: the stamp counts the tree alone (mutation)"
_case stamp-count
_run; t_assert_eq 0 "${RC}" "${OUTPUT}"
_files="$(grep -o -e '"treeFiles": "[0-9]*"' "${STAMP}")"
_put "${CASE}/home/.cargo/registry/src/x/foo-0.1.0/lib.rs" "fn main() {}"
_put "${CASE}/home/.cargo/registry/src/x/foo-0.1.0/Cargo.toml" "[package]"
_run; t_assert_eq 0 "${RC}" "${OUTPUT}"
t_assert_eq "${_files}" "$(grep -o -e '"treeFiles": "[0-9]*"' "${STAMP}")" "the cargo cache's two files are not tree files"

t_case "a record naming ORT outside the chain fails: by file, by path, or a search dir holding one (mutation)"
_case records
_put "${CASE}/deps/onnxruntime-linux-x64-1.25.1/lib/libonnxruntime.so" "foreign so"
printf 'ORT_LIB:FILEPATH=%s\n' "${CASE}/deps/onnxruntime-linux-x64-1.25.1/lib/libonnxruntime.so" >> "${TREE}/build/CMakeCache.txt"
_red "CMakeCache.txt: ${CASE}/deps/onnxruntime-linux-x64-1.25.1/lib/libonnxruntime.so is not the chain's libonnxruntime.so"
_case records-path
printf 'ORT_INCLUDE:PATH=/gone/onnxruntime/include\n' >> "${TREE}/build/CMakeCache.txt"
_red "names an ONNX Runtime path outside the chain: /gone/onnxruntime/include"
_case records-gone
printf 'ORT_LIB:FILEPATH=/gone/lib/libonnxruntime.so.1.25.1\n' >> "${TREE}/build/CMakeCache.txt"
_red "names /gone/lib/libonnxruntime.so.1.25.1, an ONNX Runtime file outside the chain (not on disk to compare)"
_case records-dir
_put "${CASE}/usr/lib/x86_64-linux-gnu/libonnxruntime.so.1.21" "distro so"
printf ' LINK_ARGS = -L%s -lonnxruntime\n' "${CASE}/usr/lib/x86_64-linux-gnu" >> "${TREE}/build/build.ninja"
_red "build.ninja searches ${CASE}/usr/lib/x86_64-linux-gnu: ${CASE}/usr/lib/x86_64-linux-gnu/libonnxruntime.so.1.21 is an ONNX Runtime binary the chain does not build"
_case records-meson
_put "${CASE}/other/include/onnxruntime_c_api.h" "other prefix"
_put "${TREE}/build/meson-info/intro-dependencies.json" "[{\"name\": \"libonnxruntime\", \"compile_args\": [\"-I${CASE}/other/include\"]}]"
_red "intro-dependencies.json searches ${CASE}/other/include: ${CASE}/other/include/onnxruntime_c_api.h is not the chain's" \
  --record "${TREE}/build/meson-info/intro-dependencies.json"
_case records-deep
_put "${CASE}/ext/inc/onnxruntime/core/session/onnxruntime_c_api.h" "older install layout"
printf ' FLAGS = -I%s\n' "${CASE}/ext/inc" >> "${TREE}/build/build.ninja"
_red "build.ninja searches ${CASE}/ext/inc/onnxruntime/core/session: "

t_case "a record naming the chain through a symlink counts as the chain"
_case link-home
ln -sfn "${CHAIN}" "${CASE}/ort-link"
printf 'ORT_HOME:PATH=%s\n' "${CASE}/ort-link" > "${TREE}/build/CMakeCache.txt"
printf 'build x: phony\n' > "${TREE}/build/build.ninja"
_run; t_assert_eq 0 "${RC}" "${OUTPUT}"

t_case "a dir link in the tree is walked when it leaves the tree and the chain, and a record path through it is read at its target (mutation)"
_case link-out
_put "${CASE}/foreign/lib/libonnxruntime.so" "foreign so"
_put "${CASE}/foreign/include/onnxruntime_c_api.h" "foreign c api"
mkdir -p "${TREE}/build/3rdparty"
ln -s "${CASE}/foreign" "${TREE}/build/3rdparty/ort"
_red "${CASE}/foreign/lib/libonnxruntime.so is not the chain's libonnxruntime.so (foreign ONNX Runtime bytes) (through the link ${TREE}/build/3rdparty/ort)"
printf ' FLAGS = -I%s\n' "${TREE}/build/3rdparty/ort/include" >> "${TREE}/build/build.ninja"
_red "build.ninja searches ${TREE}/build/3rdparty/ort/include: ${TREE}/build/3rdparty/ort/include/onnxruntime_c_api.h is not the chain's"
_case link-segment
_put "${CASE}/deps/onnxruntime/include/x.h" "not ort"
mkdir -p "${TREE}/3rdparty"
ln -s "${CASE}/deps/onnxruntime" "${TREE}/3rdparty/ort2"
printf ' FLAGS = -I%s\n' "${TREE}/3rdparty/ort2/include" >> "${TREE}/build/build.ninja"
_red "build.ninja names an ONNX Runtime path outside the chain: ${TREE}/3rdparty/ort2/include"
_case link-ok
ln -s "${CHAIN}" "${TREE}/ort-home"
ln -s "${TREE}/opencv" "${TREE}/alias"
printf 'ORT_HOME:PATH=%s\n' "${TREE}/ort-home" > "${TREE}/build/CMakeCache.txt"
printf 'build x: phony\n LINK_ARGS = %s/lib/libonnxruntime.so\n' "${TREE}/ort-home" > "${TREE}/build/build.ninja"
_run; t_assert_eq 0 "${RC}" "links into the chain and into the tree pass: ${OUTPUT}"
t_assert_ok grep -q -e '"chainReferences": "2"' "${STAMP}"
ln -s "${CASE}" "${TREE}/up"
_red "the link ${TREE}/up points at ${CASE}, which holds the tree itself"

t_case "a static ORT built inside the tree fails, found and as a record names it; GenAI's and extensions' libs do not (mutation)"
_case static
for _l in libonnxruntime_session.a libonnxruntime_providers.a libonnxruntime_mlas.a; do _put "${TREE}/third_party/ort/build/${_l}" "static ${_l}"; done
printf ' LINK_ARGS = %s\n' "${TREE}/third_party/ort/build/libonnxruntime_session.a" >> "${TREE}/build/build.ninja"
_red "${TREE}/third_party/ort/build/libonnxruntime_providers.a is an ONNX Runtime binary the chain does not build"
t_assert_contains "${OUTPUT}" "${TREE}/third_party/ort/build/libonnxruntime_mlas.a is an ONNX Runtime binary the chain does not build"
t_assert_contains "${OUTPUT}" "build.ninja: ${TREE}/third_party/ort/build/libonnxruntime_session.a is an ONNX Runtime binary"
_case static-genai
for _l in libonnxruntime_extensions.so libonnxruntime_extensions.a libonnxruntime_genai.a libonnxruntime-genai.so; do _put "${TREE}/build/lib/${_l}" "not ort"; done
_run; t_assert_eq 0 "${RC}" "GenAI's and extensions' own libs are not ORT: ${OUTPUT}"

t_case "a record path with spaces is read whole: a CMakeCache value, ninja's \$ escape, a quoted flag, meson JSON (mutation)"
_case spaces
_put "${CASE}/opt/My ORT/lib/libonnxruntime.so" "foreign so"
printf 'ORT_LIB:FILEPATH=%s\n' "${CASE}/opt/My ORT/lib/libonnxruntime.so" >> "${TREE}/build/CMakeCache.txt"
_red "CMakeCache.txt: ${CASE}/opt/My ORT/lib/libonnxruntime.so is not the chain's libonnxruntime.so"
_case spaces-ninja
_sp="${CASE}/opt/My ORT"
_put "${_sp}/lib/libonnxruntime.so" "foreign so"
printf ' LINK_ARGS = %s\n' "${_sp// /\$ }/lib/libonnxruntime.so" >> "${TREE}/build/build.ninja"
_red "build.ninja: ${_sp}/lib/libonnxruntime.so is not the chain's"
_case spaces-quoted
_put "${CASE}/My Deps/inc/onnxruntime_c_api.h" "foreign c api"
printf ' FLAGS = -I"%s" -DX\n' "${CASE}/My Deps/inc" >> "${TREE}/build/build.ninja"
_red "build.ninja searches ${CASE}/My Deps/inc: "
_case spaces-json
_put "${CASE}/My Deps/inc/onnxruntime_c_api.h" "foreign c api"
_put "${TREE}/build/meson-info/intro-dependencies.json" "[{\"name\": \"x\", \"compile_args\": [\"-I${CASE}/My Deps/inc\", \"-DX\"]}]"
_red "intro-dependencies.json searches ${CASE}/My Deps/inc: " --record "${TREE}/build/meson-info/intro-dependencies.json"

t_case "each record is read in its own format: CMakeCache values and JSON strings whole, text with ninja escapes (mutation)"
_case tokens
_tokens() { bash -c 'set -euo pipefail; IFS=$'"'"'\n\t'"'"'; source "$1"; _ortg_tokens "$2"' _ "${GATE}" "$1"; }
printf '%s\n' '//comment /no/x' 'A:FILEPATH=/opt/My ORT/lib/x.so' 'B:STRING=/a b;/c' 'C:STRING=-O2 -I/d/inc -I"/e f/inc"' 'D:PATH=' \
  > "${CASE}/CMakeCache.txt"
t_assert_eq "$(printf '%s\n' '/a b' '/c' '/d/inc' '/e f/inc' '/opt/My ORT/lib/x.so')" "$(_tokens "${CASE}/CMakeCache.txt")"
printf '%s\n' 'build x: CXX /s/a$ b.cpp' ' FLAGS = -I"/q r/inc" -L/l/lib -isystem/i https://h.example/x /p$$q' > "${CASE}/build.ninja"
t_assert_eq "$(printf '%s\n' '/i' '/l/lib' '/p$q' '/q r/inc' '/s/a b.cpp')" "$(_tokens "${CASE}/build.ninja")"
printf '%s\n' '[{"name": "x", "compile_args": ["-I/j k/inc", "-DX"], "link_args": ["/m n/lib/x.so"]}]' > "${CASE}/intro-dependencies.json"
t_assert_eq "$(printf '%s\n' '/j k/inc' '/m n/lib/x.so')" "$(_tokens "${CASE}/intro-dependencies.json")"

t_case "a log that fetched ORT fails; GenAI's and extensions' fetches do not (mutation)"
for _line in "-- DNN: Downloading ONNX Runtime from https://github.com/microsoft/onnxruntime/releases/download/v1.25.1/x.tgz" \
             "Collecting onnxruntime==1.27.0" "Downloading onnxruntime-1.27.0-cp314-cp314-manylinux_2_27_x86_64.whl (17.2 MB)" \
             "-- Using ONNX Runtime package Microsoft.ML.OnnxRuntime version 1.24.4" "apt-get install -y libonnxruntime-dev"; do
  _case "log"
  printf '%s\n' "${_line}" >> "${TREE}/build/opencv-configure.log"
  _red "(fetches an ONNX Runtime)"
done
_case log-genai
printf '%s\n' "Collecting onnxruntime_genai==0.15.2" "-- Downloading onnxruntime-extensions headers" "-- Using ONNX Runtime from: /x" \
  >> "${TREE}/build/opencv-configure.log"
_run; t_assert_eq 0 "${RC}" "GenAI/extensions fetches and a plain mention are not ORT fetches: ${OUTPUT}"

t_case "a shim link that leaves the chain, or dangles, fails (mutation)"
_case shim-link
_put "${CASE}/foreign/lib/libonnxruntime.so" "foreign"
ln -sfn "${CASE}/foreign/lib" "${SHIM}/lib"
_red "the shim link ${SHIM}/lib leaves the chain for ${CASE}/foreign/lib"
ln -sfn "${CASE}/nowhere" "${SHIM}/lib"
_red "the shim link ${SHIM}/lib is dangling"

t_case "fails closed: no chain reference, a missing record or log, no tree, an empty tree, no chain, no stamp (mutation)"
_case closed
printf 'WITH_ONNXRUNTIME:BOOL=OFF\n' > "${TREE}/build/CMakeCache.txt"
printf 'build x: phony\n' > "${TREE}/build/build.ninja"
_red "no build record names the chain ONNX Runtime"
_case closed2
_red "the build record ${TREE}/nope.ninja is missing" --record "${TREE}/nope.ninja"
_red "the build log ${TREE}/nope.log is missing" --log "${TREE}/nope.log"
_red "no tree at ${CASE}/absent to check" --tree "${CASE}/absent"
# _bare <args...>: the gate with exactly these arguments (no fixture defaults), under the consumers' IFS.
_bare() {
  OUTPUT="$(HOME="${CASE}/home" bash -c 'set -uo pipefail; IFS=$'"'"'\n\t'"'"'; source "$1"; shift; ort_assert_chain_only "$@"' _ "${GATE}" "$@" 2>&1)" \
    && RC=0 || RC=$?
}
mkdir -p "${CASE}/empty"
_bare opencv --stamp "${STAMP}" --chain "${CHAIN}" --tree "${CASE}/empty" --record "${TREE}/build/CMakeCache.txt"
t_assert_eq 1 "${RC}" "empty tree: ${OUTPUT}"
t_assert_contains "${OUTPUT}" "hold no files: a vacuous scan"
_bare opencv --stamp "${STAMP}" --chain "${CHAIN}" --record "${TREE}/build/CMakeCache.txt"
t_assert_eq 1 "${RC}" "no --tree: ${OUTPUT}"
t_assert_contains "${OUTPUT}" "no source or build tree was given"
_bare opencv --stamp "${STAMP}" --chain "${CASE}/void" --chain "${CASE}/void2" --tree "${TREE}" --record "${TREE}/build/CMakeCache.txt"
t_assert_eq 1 "${RC}" "no chain: ${OUTPUT}"
t_assert_contains "${OUTPUT}" "no chain ONNX Runtime at any of: ${CASE}/void ${CASE}/void2" "one line, even under IFS=\$'\\n\\t'"
rm -f "${CHAIN}/include/onnxruntime/onnxruntime_c_api.h"
_red "has no onnxruntime_c_api.h to compare against"
_bare "Bad Name" --tree /x
t_assert_eq 1 "${RC}" "${OUTPUT}"
t_assert_contains "${OUTPUT}" "no --stamp file given"
t_assert_contains "${OUTPUT}" "bad consumer name"
_bare opencv --stamp "${STAMP}" --tree "${TREE}" --record
t_assert_eq 1 "${RC}" "${OUTPUT}"
t_assert_contains "${OUTPUT}" "--record needs a value"
_case no-log
_bare opencv --stamp "${STAMP}" --chain "${CHAIN}" --tree "${TREE}" --shim "${SHIM}" --record "${TREE}/build/CMakeCache.txt" \
  --record "${TREE}/build/build.ninja"
t_assert_eq 1 "${RC}" "${OUTPUT}"
t_assert_contains "${OUTPUT}" "no build log was given, so no configure or build step was checked for an ONNX Runtime fetch"

t_case "no temp file, a failing count or an unresolved record path fails closed, even after an earlier pass in the same shell (mutation)"
# _twice <override>: the gate passes once, then runs again in the same shell with <override> sourced in between.
_twice() {
  OUTPUT="$(HOME="${CASE}/home" bash -c 'set -uo pipefail; IFS=$'"'"'\n\t'"'"'; source "$1"; override="$2"; shift 2
    ort_assert_chain_only opencv "$@" > /dev/null || exit 9
    eval "${override}"
    ort_assert_chain_only opencv "$@"' _ "${GATE}" "$1" --stamp "${STAMP}" --chain "${CHAIN}" --tree "${TREE}" --shim "${SHIM}" \
    --record "${TREE}/build/CMakeCache.txt" --record "${TREE}/build/build.ninja" --log "${TREE}/build/opencv-configure.log" 2>&1)" \
    && RC=0 || RC=$?
  t_assert_eq 1 "${RC}" "${OUTPUT}"
  t_assert_fails test -e "${STAMP}"
}
_case tmp-gone
_twice 'mktemp() { return 1; }'
t_assert_contains "${OUTPUT}" "ORT-GATE FAILED (opencv): no temp file for the findings, so nothing was checked"
_twice 'grep() { if [ "$1" = -c ]; then return 2; fi; command grep "$@"; }'
t_assert_contains "${OUTPUT}" "ORT-GATE FAILED (opencv)"
_case short-realpath
mkdir -p "${CASE}/fakebin"
printf '#!/bin/sh\nexit 0\n' > "${CASE}/fakebin/realpath"
chmod +x "${CASE}/fakebin/realpath"
printf ' LINK_ARGS = -L/usr/lib/nowhere\n' >> "${TREE}/build/build.ninja"
_twice 'PATH="'"${CASE}"'/fakebin:${PATH}"'
t_assert_contains "${OUTPUT}" "build.ninja: only 0 of its 1 path(s) resolved"

t_case "a fail leaves no stamp, not even an earlier one (mutation)"
_case stale
_run; t_assert_eq 0 "${RC}" "${OUTPUT}"
t_assert_ok test -f "${STAMP}"
_put "${TREE}/build/_deps/ortlib-src/x.h" "x"
_red "fetched ONNX Runtime content at ${TREE}/build/_deps/ortlib-src"

t_case "source-only: sets no shell option, sources nothing, so a per-file mount is all it needs"
t_assert_fails grep -q -E -e '^[[:space:]]*(set|shopt)[[:space:]]+-' "${GATE}"
t_assert_fails grep -q -E -e '^[[:space:]]*(source|\.)[[:space:]]' "${GATE}"

t_case "every consumer sources G2 by its per-file path and calls it once, fatally, after its own gate (mutation)"
# _flat <file>: continuation lines joined, so `call \<nl> || die` reads as one line.
_flat() { sed -e ':a' -e '/\\$/{N;s/[[:space:]]*\\\n[[:space:]]*/ /;ba}' "$1"; }
_ocv="$(_flat "${SCRIPTS}/03-media/build/opencv/build-opencv.sh")"
_ff="$(_flat "${SCRIPTS}/03-media/build/ffmpeg/build-ffmpeg.sh")"
_gst="$(_flat "${SCRIPTS}/03-media/build/gstreamer/common/build-gstreamer-monorepo.sh")"
_gen="$(_flat "${SCRIPTS}/03-media/verify-genai-ort.sh")"
t_assert_contains "${_ocv}" 'source "${SCRIPT_DIR}/../../ort-provenance.sh"'
t_assert_contains "${_ff}" 'source "${SCRIPT_DIR}/../../ort-provenance.sh"'
t_assert_contains "${_gst}" 'source "${_GST_MONOREPO_DIR}/../../../ort-provenance.sh"'
t_assert_contains "${_gen}" 'source "$(dirname "${BASH_SOURCE[0]}")/ort-provenance.sh"'
# Each call's whole record + log set: dropping one stays green as long as another record names the chain.
t_assert_contains "${_ocv}" \
  '--record "${OPENCV_SRC}/build/CMakeCache.txt" --record "${OPENCV_SRC}/build/build.ninja" --log "${OPENCV_SRC}/build/opencv-configure.log" || die'
t_assert_contains "${_ff}" '--record "${FFMPEG_SRC}/ffbuild/config.mak" --log "${FFMPEG_SRC}/ffbuild/config.log" || die'
t_assert_contains "${_gst}" \
  '--record builddir/build.ninja --record builddir/meson-info/intro-dependencies.json --log builddir/meson-logs/meson-log.txt || exit 1'
t_assert_contains "${_gen}" '--tree "${src}" --log "${src}/build/genai-build.log" "${g2[@]}"'
_gb="${SCRIPTS}/03-media/build/onnxruntime/build/60-build-genai.sh"
t_assert_contains "$(cat "${_gb}")" 'GENAI_BUILD_LOG="${GENAI_SRC_DIR}/build/genai-build.log"'
t_assert_eq 2 "$(grep -c -F -e ' 2>&1 | tee -a "${GENAI_BUILD_LOG}"' "${_gb}" || true)" "both GenAI build.py calls tee into the log G2 reads"
t_assert_contains "$(t_fn_src "${SCRIPTS}/03-media/build/opencv/build-opencv.sh" main)" "$(printf '    install_opencv\n    # G2:')"
t_assert_contains "$(t_fn_src "${SCRIPTS}/03-media/build/ffmpeg/build-ffmpeg.sh" main)" "$(printf '    install_ffmpeg\n    # G2:')"
t_assert_contains "$(t_fn_src "${SCRIPTS}/03-media/build/gstreamer/common/build-gstreamer-monorepo.sh" build_gstreamer_monorepo)" \
  "$(printf '  _gst_monorepo_install\n  _gst_monorepo_ort_provenance\n}')"
t_assert_contains "$(t_fn_src "${SCRIPTS}/03-media/verify-genai-ort.sh" main)" "$(printf 'chain bytes"\n  _genai_ort_g2 "${src}" "${out}" "${roots[@]}"\n}')"
for _f in "${_ocv}" "${_ff}" "${_gst}" "${_gen}"; do
  t_assert_eq 1 "$(printf '%s\n' "${_f}" | grep -c -E -e '(^|[[:space:]])ort_assert_chain_only[[:space:]]' || true)" "one call"
done

t_case "each stamp lands where the census contract reads it (mutation)"
# shellcheck source=../06-packaging/check-ort-provenance.sh
source "${CENSUS}"
_contract="$(ort_census_contract)"
_stamp_of() { printf '%s\n' "$1" | grep -o -E -e "ort_assert_chain_only $2 --stamp \"[^\"]+\"" | sed -E 's/.*--stamp "([^"]+)"/\1/' || true; }
declare -A _srcs=([opencv]="${_ocv}" [ffmpeg]="${_ff}" [gstreamer]="${_gst}" [genai]="${_gen}")
for _row in "opencv|OPENCV_PREFIX|/opt/opencv5" "ffmpeg|FFMPEG_PREFIX|/opt/ffmpeg" \
            "gstreamer|GSTREAMER_PREFIX|/opt/gstreamer" "genai|out|/usr/local/lib/onnxruntime-genai"; do
  IFS='|' read -r _n _var _val <<< "${_row}"
  _s="$(_stamp_of "${_srcs[${_n}]}" "${_n}")"
  _want="$(printf '%s\n' "${_contract}" | awk -F'|' -v n="${_n}" '$1 == n { print $3 }')"
  t_assert_eq "${_want}" "${_s//\$\{${_var}\}/${_val}}" "${_n}: stamp path = the census contract's"
done
t_assert_contains "$(sed -n 's/^  local src=[^ ]* out=\([^ ]*\) .*/\1/p' "${SCRIPTS}/03-media/verify-genai-ort.sh")" \
  "/usr/local/lib/onnxruntime-genai" "verify-genai-ort.sh's default --output-dir is the GenAI prefix"
t_assert_eq 1 "$(ort_census_stamps_armed)" "the census arms its STAMP verdict on this helper"

t_case "Dockerfile.media mounts G2 per file into exactly the five consumer RUNs and copies it nowhere (mutation)"
# _runs <needle>: one line per continuation-joined RUN of Dockerfile.media that contains <needle>; a comment line inside
# a RUN is skipped, as BuildKit skips it (the gstreamer RUN carries one between its mounts).
_runs() {
  awk -v needle="$1" '/^RUN / { buf = ""; inrun = 1 } inrun && /^[[:space:]]*#/ { next }
    inrun { buf = buf $0 " "; if ($0 !~ /\\$/) { inrun = 0; if (index(buf, needle)) print buf } }' "${DF}"
}
_mount='source=linux/scripts/03-media/ort-provenance.sh,target=/opt/scripts/03-media/ort-provenance.sh,readonly'
t_assert_eq 5 "$(_runs "${_mount}" | wc -l | tr -d ' ')" "five RUNs mount it"
for _consumer in "03-media/build/opencv/build-opencv.sh" "03-media/build/ffmpeg/build-ffmpeg.sh" \
                 "build-gstreamer-stage.sh" "03-media/verify-genai-ort.sh --src-dir"; do
  _all="$(_runs "${_consumer}" | wc -l | tr -d ' ')"
  t_assert_eq "${_all}" "$(_runs "${_consumer}" | grep -c -F -e "${_mount}" || true)" "every ${_consumer} RUN mounts it"
done
t_assert_fails grep -q -E -e '^(COPY|ADD) .*ort-provenance\.sh' "${DF}"
t_assert_fails grep -q -E -e 'source=linux/scripts/03-media(/core)?,' "${DF}"

t_case "every cache mount of a G2 RUN is a root G2 grades by default, under the image's own HOME and CARGO_HOME (mutation)"
_cargo_env="$(sed -n 's/.*CARGO_HOME=\([^ \\]*\).*/\1/p' "${SCRIPTS}/../Dockerfile.toolchain" | head -n 1)"
t_assert_eq /usr/local/cargo "${_cargo_env}" "the toolchain image's CARGO_HOME"
_defaults="$(HOME=/root CARGO_HOME="${_cargo_env}" FFMPEG_SDK_CACHE='' bash -c 'source "$1"; ort_gate_default_caches' _ "${GATE}" | cut -f2)"
_mounts="$(_runs "${_mount}" | grep -o -E -e 'type=cache,target=[^, ]+' | sed -e 's/.*target=//' | LC_ALL=C sort -u)"
t_assert_contains "${_mounts}" /var/cache/ffmpeg-sdks "the G2 RUNs' cache mounts were read"
t_assert_contains "${_mounts}" /usr/local/cargo/registry "including those after a comment line inside a RUN"
while IFS= read -r _m; do
  # Object caches hold no ORT by name; apt's archive is graded by the apt-plan and dpkg gates (ort-runtime-gate.sh).
  case "${_m}" in /var/cache/ccache | /var/cache/sccache | /var/cache/apt | /var/lib/apt) continue ;; esac
  t_assert_ok grep -q -x -F -e "${_m}" <<< "${_defaults}"
done <<< "${_mounts}"

t_case "GenAI's G2 runs in its own RUN, which mounts every fetch cache of the RUN that built GenAI, same ids (mutation)"
# _fetch_mounts <needle>: the cache --mount tokens of the RUNs holding <needle>, less the ungraded object and apt caches.
_fetch_mounts() {
  _runs "$1" | grep -o -E -e '--mount=type=cache,[^[:space:]]+' \
    | grep -v -E -e 'target=(/var/cache/(ccache|sccache|apt)|/var/lib/apt)(,|$)' | LC_ALL=C sort -u
}
_gbuild="$(_fetch_mounts 'build-onnxruntime.sh --step genai')"
_gg2="$(_fetch_mounts '03-media/verify-genai-ort.sh --src-dir')"
t_assert_contains "${_gbuild}" "target=/root/.cache/uv,id=uv-cache-" "the GenAI build RUN's fetch caches were read"
t_assert_contains "${_gbuild}" "target=/root/.cache/pip,id=pip-cache-"
while IFS= read -r _m; do
  t_assert_ok grep -q -x -F -e "${_m}" <<< "${_gg2}"
done <<< "${_gbuild}"

t_summary
