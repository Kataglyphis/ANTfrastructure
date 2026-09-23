#!/usr/bin/env bash
# test-genai-ort.sh - verify-genai-ort.sh on fixture trees: ORT_HOME, FetchContent dirs, the byte rule, archives, the skip.
# NOT covered: a real GenAI build (build.py --ort_home), which libonnxruntime GenAI dlopens at run time, a ${VAR} COPY source.
set -u
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${TESTS_DIR}/test-harness.sh"
GATE="${TESTS_DIR}/../03-media/verify-genai-ort.sh"
# Git Bash on a Windows host makes copies for `ln -s` without this; a no-op on Linux.
export MSYS=winsymlinks:nativestrict

_WORK="$(mktemp -d)"
trap 'rm -rf "${_WORK}"' EXIT

# _put <file> <text>: one fixture file, parents created.
_put() {
  mkdir -p "$(dirname "$1")"
  printf '%s' "$2" > "$1"
}

# _chain <root> <tag>: a chain ORT prefix as the Linux lane installs it (flat headers, versioned .so + links).
_chain() {
  _put "$1/include/onnxruntime_c_api.h" "c api $2"
  _put "$1/include/cpu_provider_factory.h" "cpu $2"
  _put "$1/lib/libonnxruntime.so.1.30.0" "so $2"
  ln -sf libonnxruntime.so.1.30.0 "$1/lib/libonnxruntime.so.1"
  ln -sf libonnxruntime.so.1 "$1/lib/libonnxruntime.so"
}

# _case <name>: a fresh chain (cpu + gpu), a GenAI tree built with ORT_HOME=cpu, and its output dir.
_case() {
  CASE="${_WORK}/$1"
  CPU="${CASE}/onnxruntime-cpu"
  GPU="${CASE}/onnxruntime-gpu"
  SRC="${CASE}/onnxruntime-genai"
  OUT="${CASE}/out"
  _chain "${CPU}" cpu
  _chain "${GPU}" gpu
  _put "${SRC}/build/Linux/Release/CMakeCache.txt" "ORT_HOME:UNINITIALIZED=${CPU}
USE_CUDA:BOOL=OFF
"
  _put "${SRC}/build/Linux/Release/_deps/pybind11_project-subbuild/CMakeCache.txt" "CMAKE_BUILD_TYPE:STRING=Release
"
  _put "${SRC}/src/models/onnxruntime_api.h" "genai's own"
  _put "${SRC}/build/Linux/Release/_deps/onnxruntime_extensions-src/include/onnxruntime_extensions.h" "ext"
  _put "${SRC}/build/Linux/Release/libonnxruntime-genai.so" "genai"
  _put "${SRC}/build/Linux/Release/wheel/dist/onnxruntime_genai-0.15.2-cp314-cp314-linux_x86_64.whl" "whl"
  _put "${SRC}/build/genai-build.log" "-- Using ONNX Runtime from: ${CPU} [absolute]
"
  _put "${OUT}/lib/libonnxruntime-genai.so" "genai"
}

# _run: the gate over the current case; sets RC and OUTPUT.
_run() {
  # A private HOME: G2 (run on a pass) reads pyke's cache under it.
  OUTPUT="$(HOME="${CASE}/home" XDG_CACHE_HOME="" bash "${GATE}" --src-dir "${SRC}" --output-dir "${OUT}" --ort-root "${CPU}" \
    --ort-root "${GPU}" 2>&1)" && RC=0 || RC=$?
}

t_case "a GenAI tree built against the chain passes; its own onnxruntime_* names and a sub-build cache are ignored"
_case healthy; _run
t_assert_eq 0 "${RC}" "${OUTPUT}"
t_assert_contains "${OUTPUT}" "GENAI-ORT OK"
t_assert_contains "${OUTPUT}" "ORT-GATE OK (genai)" "G2 ran over the same tree"
t_assert_ok grep -q -e '"consumer": "genai"' "${OUT}/ort-provenance/genai.json"

t_case "G2 reads the build log 60-build-genai.sh tees: an ORT fetch in it fails, a missing log fails (mutation)"
_case build-log
printf '%s\n' "Collecting onnxruntime==1.27.0" >> "${SRC}/build/genai-build.log"
_run; t_assert_eq 1 "${RC}" "${OUTPUT}"
t_assert_contains "${OUTPUT}" "genai-build.log:2:Collecting onnxruntime==1.27.0 (fetches an ONNX Runtime)"
rm -f "${SRC}/build/genai-build.log"
_run; t_assert_eq 1 "${RC}" "${OUTPUT}"
t_assert_contains "${OUTPUT}" "the build log ${SRC}/build/genai-build.log is missing"
t_assert_fails test -e "${OUT}/ort-provenance/genai.json"

t_case "ORT_HOME may be the GPU chain root, or a symlink to a chain root"
_case gpu-home
sed -i "s#^ORT_HOME:UNINITIALIZED=.*#ORT_HOME:UNINITIALIZED=${GPU}#" "${SRC}/build/Linux/Release/CMakeCache.txt"
_run; t_assert_eq 0 "${RC}" "${OUTPUT}"
ln -s "${CPU}" "${CASE}/cpu-link"
sed -i "s#^ORT_HOME:UNINITIALIZED=.*#ORT_HOME:PATH=${CASE}/cpu-link#" "${SRC}/build/Linux/Release/CMakeCache.txt"
_run; t_assert_eq 0 "${RC}" "${OUTPUT}"

t_case "no ORT_HOME in the top-level cache fails: ortlib.cmake took its download branch (mutation)"
_case no-home
sed -i '/^ORT_HOME:/d' "${SRC}/build/Linux/Release/CMakeCache.txt"
_run; t_assert_eq 1 "${RC}" "${OUTPUT}"
t_assert_contains "${OUTPUT}" "has no ORT_HOME, so ortlib.cmake fetched its own ONNX Runtime"

t_case "an ORT_HOME outside the chain roots fails (mutation)"
_case foreign-home
_chain "${CASE}/pypi-ort" pypi
sed -i "s#^ORT_HOME:UNINITIALIZED=.*#ORT_HOME:UNINITIALIZED=${CASE}/pypi-ort#" "${SRC}/build/Linux/Release/CMakeCache.txt"
_run; t_assert_eq 1 "${RC}" "${OUTPUT}"
t_assert_contains "${OUTPUT}" "is not a chain ONNX Runtime root"

t_case "no top-level CMakeCache.txt fails: nothing proves the ORT (mutation)"
_case no-cache
rm -f "${SRC}/build/Linux/Release/CMakeCache.txt"
_run; t_assert_eq 1 "${RC}" "${OUTPUT}"
t_assert_contains "${OUTPUT}" "nothing proves GenAI's ONNX Runtime"

t_case "an ortlib or onnxruntime FetchContent dir fails, extensions' does not (mutation)"
_case fetchcontent
mkdir -p "${SRC}/build/Linux/Release/_deps/ortlib-subbuild" "${SRC}/build/Linux/Release/_deps/onnxruntime-src"
_run; t_assert_eq 1 "${RC}" "${OUTPUT}"
t_assert_contains "${OUTPUT}" "FetchContent populated ONNX Runtime content at ${SRC}/build/Linux/Release/_deps/ortlib-subbuild"
t_assert_contains "${OUTPUT}" "_deps/onnxruntime-src"
t_assert_eq 2 "$(printf '%s\n' "${OUTPUT}" | grep -c -e 'GENAI-ORT FAIL' || true)" "exactly the two dirs"

t_case "a foreign header or libonnxruntime under a chain name fails, wherever it sits (mutation)"
for _rel in build/Linux/Release/_deps/ortpkg/include/onnxruntime_c_api.h build/x/libonnxruntime.so.1 build/y/cpu_provider_factory.h; do
  _case "foreign-$(basename "${_rel}")"
  _put "${SRC}/${_rel}" "nuget bytes"
  _run; t_assert_eq 1 "${RC}" "${_rel}: ${OUTPUT}"
  # GenAI's own verdict, by its prefix: G2 runs after it and words the same finding the same way.
  t_assert_contains "${OUTPUT}" "GENAI-ORT FAIL: ${SRC}/${_rel} is not the chain's $(basename "${_rel}")"
done

t_case "a chain-identical copy passes, a dangling link under a chain name fails"
_case copies
cp "${CPU}/include/onnxruntime_c_api.h" "${SRC}/build/Linux/Release/onnxruntime_c_api.h"
_run; t_assert_eq 0 "${RC}" "${OUTPUT}"
ln -s /nonexistent/libonnxruntime.so.1 "${SRC}/build/Linux/Release/libonnxruntime.so"
_run; t_assert_eq 1 "${RC}" "${OUTPUT}"
t_assert_contains "${OUTPUT}" "GENAI-ORT FAIL: ${SRC}/build/Linux/Release/libonnxruntime.so is not the chain's libonnxruntime.so"

t_case "an ORT archive fails, the GenAI wheel does not (mutation)"
_case archive
_put "${SRC}/build/Linux/Release/_deps/onnxruntime-linux-x64-1.19.2.tgz" "tgz"
_run; t_assert_eq 1 "${RC}" "${OUTPUT}"
t_assert_contains "${OUTPUT}" "an ONNX Runtime archive sits in the tree: ${SRC}/build/Linux/Release/_deps/onnxruntime-linux-x64-1.19.2.tgz"
t_assert_eq 1 "$(printf '%s\n' "${OUTPUT}" | grep -c -e 'GENAI-ORT FAIL' || true)" "only the archive"

t_case "a chain root with nothing to compare against fails (mutation)"
_case empty-chain
rm -f "${CPU}/include/onnxruntime_c_api.h" "${GPU}/include/onnxruntime_c_api.h"
_run; t_assert_eq 1 "${RC}" "${OUTPUT}"
t_assert_contains "${OUTPUT}" "no chain onnxruntime_c_api.h under"

t_case "no build tree: a skip without GenAI artifacts, a failure with them (mutation)"
_case no-tree
rm -rf "${SRC}/build" "${OUT}"
_run; t_assert_eq 0 "${RC}" "${OUTPUT}"
t_assert_contains "${OUTPUT}" "GENAI-ORT SKIP"
_put "${OUT}/wheels/onnxruntime_genai-0.15.2-cp314-cp314-linux_aarch64.whl" "whl"
_run; t_assert_eq 1 "${RC}" "${OUTPUT}"
t_assert_contains "${OUTPUT}" "no build tree at ${SRC}/build to prove their ONNX Runtime"

t_case "Dockerfile.media runs the gate in the genai verify RUN (per-file mount), never in the build RUN (mutation)"
# _run_of <needle>: the continuation-joined RUN instruction of Dockerfile.media that contains <needle>.
_run_of() {
  awk -v needle="$1" '/^RUN / { buf = ""; inrun = 1 } inrun { buf = buf $0 "\n"; if ($0 !~ /\\$/) { inrun = 0; if (index(buf, needle)) { printf "%s", buf; exit } } }' \
    "${TESTS_DIR}/../../Dockerfile.media"
}
_verify_run="$(_run_of 'verify-media-artifacts.sh onnxruntime-genai;')"
t_assert_contains "${_verify_run}" "source=linux/scripts/03-media/verify-genai-ort.sh,target=/opt/scripts/03-media/verify-genai-ort.sh,readonly"
t_assert_contains "${_verify_run}" "bash /opt/scripts/03-media/verify-genai-ort.sh --src-dir /opt/onnxruntime-genai"
t_assert_contains "${_verify_run}" '--ort-root "${ONNXRUNTIME_OUTPUT_DIR}" --ort-root /usr/local/lib/onnxruntime-gpu'
t_assert_eq 1 "$(printf '%s' "${_verify_run}" | grep -c -e 'verify-genai-ort.sh --src-dir' || true)" "invoked once, unguarded by anything but BUILD_GENAI"
_build_run="$(_run_of 'build-onnxruntime.sh --step genai')"
t_assert_contains "${_build_run}" "--mount=type=bind,source=linux/scripts/03-media/build/onnxruntime,"
t_assert_eq 0 "$(printf '%s' "${_build_run}" | grep -c -e 'verify-genai-ort' || true)" "the build RUN does not mount it"

t_case "the gate ships in no image: one per-file mount, no COPY of it, no COPY or mount of a dir holding it (mutation)"
# In runtime/ or build/onnxruntime/ (whole-copied/-mounted) every edit re-keyed final, package or the GPU ORT RUN.
# _context_sources <file>...: "copy|mount <source>" per build-context COPY/ADD operand and bind mount, trailing / and ./ cut.
_context_sources() {
  {
    awk '/^[[:space:]]*(COPY|ADD)[[:space:]]/ && !/--from=/ { n = 0; for (i = 2; i <= NF; i++) if ($i !~ /^--/ && $i != "\\" && $i != "`") a[++n] = $i; for (i = 1; i < n; i++) print "copy " a[i] }' "$@"
    grep -h -o -E -e '--mount=[^[:space:]`]+' "$@" | grep -v -E -e '(=|,)from=' | sed -n -e 's/.*[=,]source=\([^,]*\).*/mount \1/p'
  } | sed -E -e 's#\\#/#g' -e 's#/+$##' -e 's#^(copy|mount) \./#\1 #'
}
_fixture="${_WORK}/Dockerfile.sources"
printf '%s\n' 'FROM x' 'COPY --chmod=755 linux/scripts/03-media/ /opt/scripts/03-media/' 'COPY ./ /ws/' \
  'COPY linux/scripts/03-media/verify-genai-ort.sh a/b.sh /x/' 'COPY --link --from=y / /' 'COPY linux\scripts\ C:\ws\' \
  'RUN --mount=type=bind,source=linux/scripts,target=/s \' '    --mount=type=bind,from=y,source=linux,target=/t true' > "${_fixture}"
t_assert_eq "copy linux/scripts/03-media|copy .|copy linux/scripts/03-media/verify-genai-ort.sh|copy a/b.sh|copy linux/scripts|mount linux/scripts" \
  "$(_context_sources "${_fixture}" | paste -s -d '|' -)" "the scan reads context COPYs and bind mounts, not stage copies"
_dockerfiles=()
for _df in "${TESTS_DIR}/../../"Dockerfile* "${TESTS_DIR}/../../"*/Dockerfile* "${TESTS_DIR}/../../../windows/"Dockerfile*; do
  if [ -f "${_df}" ]; then _dockerfiles+=("${_df}"); fi
done
t_assert_eq 1 "$([ "${#_dockerfiles[@]}" -gt 20 ] && echo 1 || echo 0)" "found both platforms' Dockerfiles: ${#_dockerfiles[@]}"
_srcs="$(_context_sources "${_dockerfiles[@]}")"
t_assert_eq 1 "$(printf '%s\n' "${_srcs}" | grep -c -x -F -e 'mount linux/scripts/03-media/verify-genai-ort.sh' || true)" "exactly one per-file mount"
t_assert_eq "" "$(printf '%s\n' "${_srcs}" | grep -x -F -e 'copy linux/scripts/03-media/verify-genai-ort.sh' || true)" "no COPY ships it"
t_assert_eq "" "$(printf '%s\n' "${_srcs}" | grep -x -E -e '(copy|mount) (\.|linux|linux/scripts|linux/scripts/03-media)' || true)" "no dir holding it"

t_case "usage: --help exits 0, an unknown argument or a missing value exits 2"
t_assert_eq 0 "$(t_rc bash "${GATE}" --help)"
t_assert_eq 2 "$(t_rc bash "${GATE}" --bogus)"
t_assert_eq 2 "$(t_rc bash "${GATE}" --ort-root)"

t_summary
