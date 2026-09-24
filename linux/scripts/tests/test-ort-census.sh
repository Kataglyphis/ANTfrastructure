#!/usr/bin/env bash
# The ORT census (06-packaging/check-ort-provenance.sh + ort_census_probe.py): one verdict per case, the
# pure verdicts driven by recorded facts, the probe by synthetic ELF trees, and the smoke wiring.
# NOT covered here: a real image (the smoke runs it) or a real ORT build (fingerprints are typed in).
# docs/cross-build-verification.md#e-ort-single-source
set -u
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${TESTS_DIR}/test-harness.sh"
PKG="${TESTS_DIR}/../06-packaging"
CENSUS="${PKG}/check-ort-provenance.sh"
PY="${PREFLIGHT_PYTHON:-python3}"
# shellcheck source=../06-packaging/check-ort-provenance.sh
source "${CENSUS}"

_work="$(mktemp -d)"
trap 'rm -rf "${_work}"' EXIT

CHAIN_SHA="$(printf 'c%.0s' {1..64})"
FOREIGN_SHA="$(printf 'f%.0s' {1..64})"
_fact() { local IFS=$'\t'; printf '%s\n' "$*"; }
# A healthy image's facts: chain roots, one prefix, its core lib, a capi copy, a registered consumer.
_base() {
  _fact CHAIN /opt/onnxruntime
  _fact CHAIN /opt/onnxruntime-android
  _fact ALLOW /usr/local/lib/onnxruntime-cpu
  _fact REF "${CHAIN_SHA}" /usr/local/lib/onnxruntime-cpu/lib/libonnxruntime.so.1.30.0 '/opt/onnxruntime|/opt/onnxruntime/include'
  _fact CORE "${CHAIN_SHA}" /usr/local/lib/onnxruntime-cpu/lib/libonnxruntime.so.1.30.0
  _fact BIN "${CHAIN_SHA}" /usr/local/lib/onnxruntime-cpu/lib/libonnxruntime.so.1.30.0 /opt/onnxruntime name
  _fact BIN "${CHAIN_SHA}" /opt/venv/lib/python3.14/site-packages/onnxruntime/capi/libonnxruntime.so.1.30.0 /opt/onnxruntime name
  _fact USE /opt/ffmpeg/lib/libavfilter.so.11 ffmpeg OrtGetApiBase libonnxruntime.so.1 "${FOREIGN_SHA}"
  _fact RES /opt/ffmpeg/lib/libavfilter.so.11 libonnxruntime.so.1 /usr/local/lib/onnxruntime-cpu/lib/libonnxruntime.so.1.30.0 "${CHAIN_SHA}"
  _fact DIST /opt/venv/lib/python3.14/site-packages onnxruntime
  _fact STAMP ffmpeg /opt/ffmpeg/ort-provenance/ffmpeg.json ffmpeg "${CHAIN_SHA}"
}
_done() { _fact PROBE_DONE; }
_v() { ort_census_verdicts "$1" "${2:-0}" amd64 "${@:3}"; }

t_case "a healthy image has no finding, armed or not"
t_assert_eq "" "$(_v "$(_base; _done)")" "clean"
t_assert_eq "" "$(_v "$(_base; _done)" 1)" "clean with STAMP armed"
t_assert_eq "" "$(_v "$(_base; _done | sed 's/$/\r/')")" "CRLF probe text (python on Windows) reads the same"

t_case "FOREIGN: another build root, POSIX or Windows, under any name"
t_assert_contains "$(_v "$(_base; _fact BIN "${FOREIGN_SHA}" /opt/x/libfoo.so 'C:\__w\1\s' fp; _done)")" \
  "FOREIGN	/opt/x/libfoo.so	built under C:\\__w\\1\\s" "Windows ML's root, renamed"
t_assert_contains "$(_v "$(_base; _fact BIN "${FOREIGN_SHA}" /opt/x/libonnxruntime.so.1 '/home/tlwu/onnxruntime|/opt/onnxruntime' name; _done)")" \
  "FOREIGN	/opt/x/libonnxruntime.so.1	built under /home/tlwu/onnxruntime" "a foreign root wins over a chain one"
t_assert_contains "$(_v "$(_base; _fact BIN "${FOREIGN_SHA}" /opt/x/libonnxruntime.so '|' name; _done)")" \
  "FOREIGN	/opt/x/libonnxruntime.so	built with relative" "relative source paths"
t_assert_contains "$(_v "$(_base; _fact BIN "${FOREIGN_SHA}" /opt/x/libonnxruntime.so . name; _done)")" \
  "FOREIGN	/opt/x/libonnxruntime.so	built with relative" "a lone relative root, as the probe prints it ('.')"
t_assert_contains "$(_v "$(_base; _fact REF "${FOREIGN_SHA}" /usr/local/lib/onnxruntime-cpu/lib/libx.so .; _done)")" \
  "FOREIGN	/usr/local/lib/onnxruntime-cpu/lib/libx.so	the chain reference itself was built under ." "a reference with relative roots only is not the chain"

t_case "STALE: the chain's root, other bytes; the capi arm names a missing manifest"
t_assert_contains "$(_v "$(_base; _fact BIN "${FOREIGN_SHA}" /opt/old/libonnxruntime.so.1 /opt/onnxruntime name; _done)")" \
  "STALE	/opt/old/libonnxruntime.so.1" "stale chain build"
t_assert_contains "$(_v "$(_base; _fact NOMANIFEST /usr/local/lib/onnxruntime-cpu/ort-provenance.sha256; \
  _fact BIN "${FOREIGN_SHA}" /opt/venv/lib/python3.14/site-packages/onnxruntime/capi/onnxruntime_pybind11_state.so /opt/onnxruntime name; _done)")" \
  "no chain wheel manifest at /usr/local/lib/onnxruntime-cpu/ort-provenance.sha256" "the hint names the cause"
t_assert_contains "$(_v "$(_base; _fact BIN "${FOREIGN_SHA}" /opt/onnxruntime-android-x/libonnxruntime.so '/opt/onnxruntime-androidx' name; _done)")" \
  "FOREIGN" "a root that merely starts with a chain root's text is not under it"

t_case "UNPROVEN: an ORT name, no fingerprint, foreign bytes; an unreadable ORT file"
t_assert_contains "$(_v "$(_base; _fact BIN "${FOREIGN_SHA}" /opt/ep/libonnxruntime_providers_webgpu.so - name; _done)")" \
  "UNPROVEN	/opt/ep/libonnxruntime_providers_webgpu.so" "prebuilt EP"
t_assert_contains "$(_v "$(_base; _fact UNREAD /opt/x/libonnxruntime.so 'Permission denied'; _done)")" \
  "UNPROVEN	/opt/x/libonnxruntime.so	unreadable" "unreadable is not clean"

t_case "ELSEWHERE: a chain copy outside its homes; capi and archives in a home are fine"
t_assert_contains "$(_v "$(_base; _fact BIN "${CHAIN_SHA}" /opt/opencv5/lib/libonnxruntime.so.1.30.0 /opt/onnxruntime name; _done)")" \
  "ELSEWHERE	/opt/opencv5/lib/libonnxruntime.so.1.30.0" "OpenCV's install-rule copy"
t_assert_eq "" "$(_v "$(_base; _fact BIN "${CHAIN_SHA}" '/usr/local/lib/onnxruntime-cpu/w.whl!onnxruntime/capi/x.so' - name; _done)")" \
  "a member of an archive inside a home"
t_assert_eq "" "$(_v "$(_base | grep -v -e '^ALLOW'; _fact BIN "${CHAIN_SHA}" /opt/opencv5/lib/libonnxruntime.so.1.30.0 - name; _done)")" \
  "no ALLOW line (tree mode) = no ELSEWHERE arm"

t_case "UNREGISTERED: an ORT user outside the contract; tree mode and chain artefacts are exempt"
t_assert_contains "$(_v "$(_base; _fact USE /opt/app/libmystery.so - OrtGetApiBase - "${FOREIGN_SHA}"; _done)")" \
  "UNREGISTERED	/opt/app/libmystery.so" "unregistered"
t_assert_eq "" "$(_v "$(_base; _fact USE /opt/app/libmystery.so '*' OrtGetApiBase - "${FOREIGN_SHA}"; _done)")" "no contract = no arm"
t_assert_eq "" "$(_v "$(_base; _fact REF "${FOREIGN_SHA}" /opt/android/onnxruntime/lib/libonnxruntime4j_jni.so -; \
  _fact USE /opt/android/onnxruntime/lib/libonnxruntime4j_jni.so - OrtGetApiBase - "${FOREIGN_SHA}"; _done)")" "a chain file is not a consumer"

t_case "STAMP (armed only): missing, another consumer's, another ORT's"
t_assert_contains "$(_v "$(_base | grep -v -e '^STAMP'; _fact STAMP ffmpeg /opt/ffmpeg/ort-provenance/ffmpeg.json MISSING -; _done)" 1)" \
  "STAMP	/opt/ffmpeg/ort-provenance/ffmpeg.json" "missing"
t_assert_contains "$(_v "$(_base | grep -v -e '^STAMP'; _fact STAMP ffmpeg /opt/ffmpeg/ort-provenance/ffmpeg.json opencv "${CHAIN_SHA}"; _done)" 1)" \
  "STAMP	" "another consumer's stamp"
t_assert_contains "$(_v "$(_base | grep -v -e '^STAMP'; _fact STAMP ffmpeg /opt/ffmpeg/ort-provenance/ffmpeg.json ffmpeg "${FOREIGN_SHA}"; _done)" 1)" \
  "STAMP	" "gated against another ORT"
t_assert_eq "" "$(_v "$(_base | grep -v -e '^STAMP'; _fact STAMP ffmpeg /opt/ffmpeg/ort-provenance/ffmpeg.json MISSING -; _done)" 0)" "unarmed"
t_assert_eq "" "$(_v "$(_base | grep -v -e '^STAMP'; _fact STAMP opencv /opt/opencv5/ort-provenance/opencv.json MISSING -; _fact STAMP ffmpeg /opt/ffmpeg/ort-provenance/ffmpeg.json ffmpeg "${CHAIN_SHA}"; _done)" 1)" \
  "an absent consumer needs no stamp"

t_case "DIST: two distributions own the onnxruntime import package"
t_assert_contains "$(_v "$(_base; _fact DIST /opt/venv/lib/python3.14/site-packages onnxruntime,onnxruntime-gpu; _done)")" \
  "DIST	/opt/venv/lib/python3.14/site-packages" "two owners"

t_case "UNRESOLVED: nothing on the search path, or a non-chain file first"
t_assert_contains "$(_v "$(_base; _fact RES /opt/app/libx.so libonnxruntime.so.1 - -; _done)")" \
  "UNRESOLVED	/opt/app/libx.so	no libonnxruntime.so.1" "nothing found"
t_assert_contains "$(_v "$(_base; _fact RES /opt/app/libx.so libonnxruntime.so.1 /opt/opencv5/lib/libonnxruntime.so.1 "${FOREIGN_SHA}"; _done)")" \
  "resolves to /opt/opencv5/lib/libonnxruntime.so.1, which is not the chain ORT" "shadowed"

t_case "NONE: no probe marker, no reference, no ORT binary"
t_assert_contains "$(_v "$(_base)")" "NONE	-	the probe did not complete" "no PROBE_DONE"
t_assert_contains "$(_v "$(_base | grep -v -e '^REF'; _done)")" "NONE	-	no chain ORT reference" "empty reference"
t_assert_contains "$(_v "$(_base | grep -v -e '^BIN'; _done)")" "NONE	-	the scan found no ORT binary" "nothing scanned"
t_assert_contains "$(_v "")" "NONE" "no probe output at all"

t_case "the reference itself must carry a chain root; a manifest row is graded by the bytes that match it"
t_assert_contains "$(_v "$(_base; _fact REF "${FOREIGN_SHA}" /usr/local/lib/onnxruntime-gpu/lib/libonnxruntime_providers_cuda.so 'N:\_work\1\s'; _done)")" \
  "FOREIGN	/usr/local/lib/onnxruntime-gpu/lib/libonnxruntime_providers_cuda.so	the chain reference itself" "reference self-check"
t_assert_eq "" "$(_v "$(_base; _fact REF "${FOREIGN_SHA}" 'w.whl!onnxruntime/capi/x.so' '?'; _done)")" "manifest rows carry no roots"
_capi=/opt/venv/lib/python3.14/site-packages/onnxruntime/capi/onnxruntime_pybind11_state.so
_mrow() { _fact REF "${FOREIGN_SHA}" 'w.whl!onnxruntime/capi/onnxruntime_pybind11_state.so' '?'; }
t_assert_contains "$(_v "$(_base; _mrow; _fact BIN "${FOREIGN_SHA}" "${_capi}" '/home/tlwu/onnxruntime|N:\_work\1\s' name; _done)")" \
  "FOREIGN	${_capi}	its sha is a chain wheel manifest row, but it was built under /home/tlwu/onnxruntime, N:\\_work\\1\\s" \
  "a manifest does not make PyPI's bytes chain"
t_assert_eq "" "$(_v "$(_base; _mrow; _fact BIN "${FOREIGN_SHA}" "${_capi}" /opt/onnxruntime name; _done)")" "a chain-rooted manifest member"
t_assert_eq "" "$(_v "$(_base; _mrow; _fact BIN "${FOREIGN_SHA}" "${_capi}" - name; _done)")" "an unfingerprinted one (providers_shared)"

t_case "exemptions waive one path, and fail when stale or malformed; another arch's entry waives nothing"
_bad="$(_base; _fact BIN "${CHAIN_SHA}" /opt/opencv5/lib/libonnxruntime.so.1 - name; _done)"
t_assert_contains "$(_v "${_bad}" 0 'amd64:/opt/opencv5/lib/libonnxruntime.so.1:item 6')" \
  "EXEMPT	/opt/opencv5/lib/libonnxruntime.so.1" "waived, still printed"
t_assert_contains "$(_v "${_bad}" 0 'arm64:/opt/opencv5/lib/libonnxruntime.so.1:item 6')" "ELSEWHERE" "another arch"
t_assert_contains "$(_v "$(_base; _done)" 0 '*:/opt/gone.so:fixed')" "EXEMPT-STALE	/opt/gone.so" "stale"
t_assert_contains "$(_v "$(_base; _done)" 0 'no-colons')" "EXEMPT-STALE	no-colons	malformed" "malformed"

# ---- the probe, over synthetic ELF trees ------------------------------------------------------------
PROBE="$(_ort_host_dir "${PKG}")/ort_census_probe.py"
_probe() { MSYS_NO_PATHCONV=1 MSYS2_ARG_CONV_EXCL='*' "${PY}" "${PROBE}" "$@"; }
# _elf <path> <needed,csv> <runpath> <text>... : an x86-64 ELF .so with a dynamic section and strings.
# ORT_TEST_SYM=<gnu|sysv>:<shndx> adds OrtGetApiBase to its dynamic symbols behind that hash table (shndx 0 = an import).
_elf() {
  mkdir -p "$(dirname "$1")"
  MSYS_NO_PATHCONV=1 MSYS2_ARG_CONV_EXCL='*' "${PY}" - "$(_ort_host_dir "$(dirname "$1")")/$(basename "$1")" "${@:2}" <<'PY'
import os
import struct
import sys

path, needed, runpath, texts = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4:]
style, _, shndx = os.environ.get("ORT_TEST_SYM", "").partition(":")
strtab, dyn, syms = b"\0", [], b""
for tag, value in [(1, n) for n in needed.split(",") if n] + ([(29, runpath)] if runpath else []):
    dyn.append((tag, len(strtab)))
    strtab += value.encode() + b"\0"
if style:
    h = 5381
    for c in b"OrtGetApiBase":
        h = (h * 33 + c) & 0xFFFFFFFF
    table = struct.pack("<IIIIQII", 1, 1, 1, 6, 2**64 - 1, 1, h | 1) if style == "gnu" else struct.pack("<IIIII", 1, 2, 1, 0, 0)
    syms = b"\0" * 24 + struct.pack("<IBBHQQ", len(strtab), 0x12, 0, int(shndx), 0x1000 if int(shndx) else 0, 0) + table
    strtab += b"OrtGetApiBase\0"
dyn_off = 64 + 2 * 56
dyn_size = 16 * (len(dyn) + 2 + (3 if style else 0))
str_off = dyn_off + dyn_size + len(syms)
if style:
    dyn += [(6, dyn_off + dyn_size), (11, 24), (0x6FFFFEF5 if style == "gnu" else 4, dyn_off + dyn_size + 48)]
payload = b"".join(b"\0" + t.encode() + b"\0" for t in texts)
total = max(str_off + len(strtab) + len(payload), 2048)
data = b"\x7fELF" + bytes([2, 1, 1, 0]) + b"\0" * 8
data += struct.pack("<HHIQQQIHHHHHH", 3, 62, 1, 0, 64, 0, 0, 64, 56, 2, 64, 0, 0)
data += struct.pack("<IIQQQQQQ", 1, 5, 0, 0, 0, total, total, 0x1000)
data += struct.pack("<IIQQQQQQ", 2, 6, dyn_off, dyn_off, dyn_off, dyn_size, dyn_size, 8)
data += b"".join(struct.pack("<qQ", t, v) for t, v in dyn) + struct.pack("<qQ", 5, str_off) + struct.pack("<qQ", 0, 0)
data += syms + strtab + payload
open(path, "wb").write(data + b"\0" * (total - len(data)))
PY
}
CHAIN_SRC=/opt/onnxruntime/onnxruntime/core/session/inference_session.cc
WINML_SRC='C:\__w\1\s\onnxruntime\core\session\inference_session.cc'
# FFmpeg compiles its configure line into every lib and tool, and the chain's names an ORT include dir.
FFMPEG_CONFIG="--enable-libonnxruntime --extra-cflags='-I/usr/local/lib/onnxruntime-cpu/include -I/usr/local/lib/onnxruntime-cpu/include/onnxruntime/core/session' --extra-ldflags=-L/usr/local/lib/onnxruntime-cpu/lib"

_ref="${_work}/ref"
_elf "${_ref}/lib/libonnxruntime.so.1" "" "" "${CHAIN_SRC}" OrtGetApiBase
_bundle="${_work}/bundle"
_elf "${_bundle}/lib/libAccelerANTgine.so" libonnxruntime.so.1 '$ORIGIN' OrtGetApiBase
cp "${_ref}/lib/libonnxruntime.so.1" "${_bundle}/lib/"

t_case "G6: a bundle carrying the chain ORT beside its importer passes (main, exit 0)"
t_assert_eq 0 "$(t_rc bash "${CENSUS}" --reference "${_ref}/lib" "${_bundle}")" "clean bundle"
t_assert_contains "$(bash "${CENSUS}" --reference "${_ref}/lib" "${_bundle}" 2>&1)" "ORT census PASS" "says so"

t_case "G6: a stale copy, an importer without RUNPATH, a renamed foreign ORT and a foreign wheel fail (exit 1)"
_elf "${_work}/ref2/lib/libonnxruntime.so.1" "" "" "${CHAIN_SRC}" 'FileVersion 1.31'
_out="$(bash "${CENSUS}" --reference "${_work}/ref2/lib" "${_bundle}" 2>&1)"
t_assert_contains "${_out}" "STALE        /lib/libonnxruntime.so.1" "the bundle's copy is not this chain"
t_assert_contains "${_out}" "UNRESOLVED   /lib/libAccelerANTgine.so -- libonnxruntime.so.1 resolves to /lib/libonnxruntime.so.1" "resolved, but to a stale file"
t_assert_eq 1 "$(t_rc bash "${CENSUS}" --reference "${_work}/ref2/lib" "${_bundle}")" "exit 1"
_elf "${_bundle}/bin/libhelper.so" libonnxruntime.so.1 "" OrtGetApiBase
_elf "${_bundle}/lib/libvendored.so" "" "" "${WINML_SRC}"
_elf "${_work}/pypi/libonnxruntime.so.1" "" "" '/home/tlwu/onnxruntime/onnxruntime/core/x.cc'
(cd "${_work}/pypi" && "${PY}" -c 'import zipfile; z = zipfile.ZipFile("../bundle/onnxruntime-1.27.0-cp314-cp314-manylinux_2_28_x86_64.whl", "w"); z.write("libonnxruntime.so.1", "onnxruntime/capi/libonnxruntime.so.1"); z.close()')
_out="$(bash "${CENSUS}" --reference "${_ref}/lib" "${_bundle}" 2>&1)"
t_assert_contains "${_out}" "UNRESOLVED   /bin/libhelper.so -- no libonnxruntime.so.1 on its ld.so search path" "no RUNPATH, no copy"
t_assert_contains "${_out}" "FOREIGN      /lib/libvendored.so -- built under C:\\__w\\1\\s" "renamed, found by content"
t_assert_contains "${_out}" "FOREIGN      /onnxruntime-1.27.0-cp314-cp314-manylinux_2_28_x86_64.whl!onnxruntime/capi/libonnxruntime.so.1" "a wheel member"
t_assert_eq 2 "$(t_rc bash "${CENSUS}")" "no directory = usage error"

t_case "the fingerprint is a whole NUL-terminated ORT source path; a directory literal is not one"
# The roots roots_in reads off each buffer ('.' = relative), ';'-separated.
_roots() {
  MSYS_NO_PATHCONV=1 MSYS2_ARG_CONV_EXCL='*' "${PY}" - "$(_ort_host_dir "${PKG}")" "${FFMPEG_CONFIG}" <<'PY' | tr -d '\r'
import sys
sys.dont_write_bytecode = True  # no __pycache__ in a tree that is a build context
sys.path.insert(0, sys.argv[1])
import ort_census_probe as p
FFMPEG_CONFIG = sys.argv[2]
print(";".join("|".join(r or "." for r in p.roots_in(buf)) for buf in (
    b"\0/opt/onnxruntime/onnxruntime/core/session/inference_session.cc\0",
    b"\0C:\\temp\\onnx-src\\onnxruntime\\core\\providers\\dml\\a.cpp\0",
    b"\0/opt/onnxruntime/onnxruntime/contrib_ops/cuda/bert/b.cuh",
    b"invalid Once state/opt/onnxruntime/onnxruntime/core//workspace/x/crates/inferenceresources\0",
    b"invalid Once stateC:\\temp\\onnx-src\\onnxruntime\\core\\C:\\ws\\crates\\inferenceresources\0",
    b"\0/opt/onnxruntime/onnxruntime/core/x.hpp is missing\0",
    b"\0" + FFMPEG_CONFIG.encode() + b"\0",
)))
PY
}
t_assert_eq '/opt/onnxruntime;C:\temp\onnx-src;/opt/onnxruntime;;;;' "$(_roots)" \
  "__FILE__ paths (.cc, .cpp, a .cuh at the end of the data) count; directory strings (rustc-packed, FFmpeg's configure line) and a path-shaped word without its NUL do not"

# What OxidANT f018bec's liboxidant.so carries: rustc packs &str literals with no NUL between them.
OXIDANT_RUN='Failed to run ONNX model (ort)internal error: entered unreachable code: invalid Once state/opt/onnxruntime/onnxruntime/core//workspace/third_party/OxidANT/crates/inferenceresourcesmodelsyolov10m.onnxModel returned no outputs'
_dl="${_work}/dlopen"
_elf "${_dl}/lib/liboxidant.so" "" '$ORIGIN' "${OXIDANT_RUN}" OrtGetApiBase
cp "${_ref}/lib/libonnxruntime.so.1" "${_dl}/lib/libonnxruntime.so"
mapfile -t _targs < <(_ort_census_tree_args "${_dl}" "${_ref}/lib" "")

t_case "G6: a dlopen-only consumer naming the chain directory is an importer and passes beside the chain ORT"
_facts="$(_probe "${_targs[@]}" | tr -d '\r')"
t_assert_contains "${_facts}" "USE	/lib/liboxidant.so	*	OrtGetApiBase" "an importer"
t_assert_contains "${_facts}" "RES	/lib/liboxidant.so	libonnxruntime.so	/lib/libonnxruntime.so" "resolved through its \$ORIGIN RUNPATH"
t_assert_eq "" "$(printf '%s\n' "${_facts}" | grep -e '^BIN.*liboxidant' || true)" "never an ORT instance"
t_assert_eq 0 "$(t_rc bash "${CENSUS}" --reference "${_ref}/lib" "${_dl}")" "exit 0"

t_case "G6: the same consumer with no ORT beside it, or a one-byte-off one, fails (mutations)"
cp "${_ref}/lib/libonnxruntime.so.1" "${_dl}/lib/libonnxruntime.so"
printf 'x' >> "${_dl}/lib/libonnxruntime.so"
_out="$(bash "${CENSUS}" --reference "${_ref}/lib" "${_dl}" 2>&1)"
t_assert_contains "${_out}" "STALE        /lib/libonnxruntime.so" "the copy is not this chain"
t_assert_contains "${_out}" "UNRESOLVED   /lib/liboxidant.so -- libonnxruntime.so resolves to /lib/libonnxruntime.so, which is not the chain ORT" "and it loads that copy"
rm -f "${_dl}/lib/libonnxruntime.so"
_out="$(bash "${CENSUS}" --reference "${_ref}/lib" "${_dl}" 2>&1)"
t_assert_contains "${_out}" "UNRESOLVED   /lib/liboxidant.so -- no libonnxruntime.so on its ld.so search path" "nothing to dlopen"
t_assert_eq 1 "$(t_rc bash "${CENSUS}" --reference "${_ref}/lib" "${_dl}")" "exit 1"

t_case "G6: an ORT built with relative source paths is FOREIGN, not an unfingerprinted UNPROVEN"
_elf "${_work}/rel/lib/libonnxruntime.so.1" "" "" 'onnxruntime/core/session/inference_session.cc' OrtGetApiBase
t_assert_contains "$(bash "${CENSUS}" --reference "${_ref}/lib" "${_work}/rel" 2>&1)" \
  "FOREIGN      /lib/libonnxruntime.so.1 -- built with relative (remapped) source paths" "a lone relative root survives the probe"

_ren="${_work}/renamed"
mkdir -p "${_ren}/lib"
cp "${_ref}/lib/libonnxruntime.so.1" "${_ren}/lib/libonnxruntime.so"
mapfile -t _targs < <(_ort_census_tree_args "${_ren}" "${_ref}/lib" "")
# _ren_census <gnu|sysv>:<shndx> : libhelper.so with that OrtGetApiBase symbol beside the chain ORT; facts, verdicts, exit.
_ren_census() {
  local out rc
  ORT_TEST_SYM="$1" _elf "${_ren}/lib/libhelper.so" "" '$ORIGIN'
  out="$(bash "${CENSUS}" --reference "${_ref}/lib" "${_ren}" 2>&1)"
  rc=$?
  printf '%s\n%s\nexit %s\n' "$(_probe "${_targs[@]}" | tr -d '\r')" "${out}" "${rc}"
}

t_case "G6: a file that DEFINES OrtGetApiBase is ORT under any name; one that imports it is an importer (mutations)"
# With an $ORIGIN RUNPATH beside the chain ORT an importer's modeled dlopen passes, so a renamed ORT must not be one.
for _style in gnu sysv; do
  _r="$(_ren_census "${_style}:11")"
  t_assert_contains "${_r}" "	/lib/libhelper.so	-	def" "an ORT instance by its dynamic symbols (${_style})"
  t_assert_contains "${_r}" "UNPROVEN     /lib/libhelper.so -- an ORT under another name (it defines OrtGetApiBase)" "graded by its bytes (${_style})"
  t_assert_contains "${_r}" "exit 1" "and red (${_style})"
  _r="$(_ren_census "${_style}:0")"
  t_assert_contains "${_r}" "USE	/lib/libhelper.so	*	OrtGetApiBase" "an undefined symbol is a reference (${_style})"
  t_assert_contains "${_r}" "exit 0" "resolved to the chain ORT beside it (${_style})"
done

t_case "G1 image mode: ld.so.conf order and LD_LIBRARY_PATH decide which copy an importer gets"
_img="${_work}/img"
mkdir -p "${_img}/etc/ld.so.conf.d"
printf 'include /etc/ld.so.conf.d/*.conf\n' > "${_img}/etc/ld.so.conf"
printf '/opt/opencv5/lib\n' > "${_img}/etc/ld.so.conf.d/000-opencv.conf"
printf '/usr/local/lib/onnxruntime-cpu/lib\n' > "${_img}/etc/ld.so.conf.d/onnxruntime.conf"
_elf "${_img}/usr/local/lib/onnxruntime-cpu/lib/libonnxruntime.so.1" "" "" "${CHAIN_SRC}" OrtGetApiBase
_elf "${_img}/opt/ffmpeg/lib/libavfilter.so.11" libonnxruntime.so.1 "" OrtGetApiBase "${FFMPEG_CONFIG}"
mkdir -p "${_img}/opt/opencv5/lib" "${_img}/opt/venv/lib/python3.14/site-packages/onnxruntime/capi"
cp "${_img}/usr/local/lib/onnxruntime-cpu/lib/libonnxruntime.so.1" "${_img}/opt/opencv5/lib/"
cp "${_img}/usr/local/lib/onnxruntime-cpu/lib/libonnxruntime.so.1" "${_img}/opt/venv/lib/python3.14/site-packages/onnxruntime/capi/"
for _d in onnxruntime-1.30.0 onnxruntime_gpu-1.30.0; do
  mkdir -p "${_img}/opt/venv/lib/python3.14/site-packages/${_d}.dist-info"
  printf 'onnxruntime/__init__.py,,\n' > "${_img}/opt/venv/lib/python3.14/site-packages/${_d}.dist-info/RECORD"
done
printf 'not a zip' > "${_img}/opt/venv/lib/python3.14/site-packages/scipy-1.18.0-cp314-cp314-linux_x86_64.whl"
printf 'not a zip' > "${_img}/opt/onnxruntime-1.27.0-cp314-cp314-linux_x86_64.whl"
_iargs=(--image --root "$(_ort_host_dir "${_img}")" --ld-library-path "" --ref /usr/local/lib/onnxruntime-cpu --allow /usr/local/lib/onnxruntime-cpu
  --chain-root /opt/onnxruntime --core /usr/local/lib/onnxruntime-cpu/lib/libonnxruntime.so.1
  --contract 'ffmpeg|libavfilter.so*|/opt/ffmpeg/ort-provenance/ffmpeg.json' --ref-manifest /usr/local/lib/onnxruntime-cpu/ort-provenance.sha256)
_facts="$(_probe "${_iargs[@]}")"
t_assert_contains "${_facts}" "RES	/opt/ffmpeg/lib/libavfilter.so.11	libonnxruntime.so.1	/opt/opencv5/lib/libonnxruntime.so.1" "000-opencv.conf wins the lookup"
t_assert_contains "${_facts}" "NOMANIFEST	/usr/local/lib/onnxruntime-cpu/ort-provenance.sha256" "a missing manifest is reported, not fatal on its own"
t_assert_contains "${_facts}" "UNREAD	/opt/onnxruntime-1.27.0-cp314-cp314-linux_x86_64.whl" "an unreadable ORT archive cannot be proven"
t_assert_eq "" "$(printf '%s\n' "${_facts}" | grep -e scipy || true)" "a corrupt non-ORT archive is not an ORT finding"
_out="$(_v "${_facts}" 1)"
t_assert_contains "${_out}" "ELSEWHERE	/opt/opencv5/lib/libonnxruntime.so.1" "the OpenCV copy is out of place"
t_assert_contains "${_out}" "DIST	/opt/venv/lib/python3.14/site-packages" "two ORT distributions"
t_assert_contains "${_facts}" "DIST	/opt/venv/lib/python3.14/site-packages	onnxruntime,onnxruntime-gpu" "owners are distribution names, not dist-info folder names"
t_assert_contains "${_out}" "STAMP	/opt/ffmpeg/ort-provenance/ffmpeg.json" "armed: ffmpeg is present and unstamped"
_elf "${_img}/opt/opencv5/lib/libonnxruntime.so.1" "" "" "${WINML_SRC}"
_out="$(_v "$(_probe "${_iargs[@]}")")"
t_assert_contains "${_out}" "UNRESOLVED	/opt/ffmpeg/lib/libavfilter.so.11	libonnxruntime.so.1 resolves to /opt/opencv5/lib/libonnxruntime.so.1" "a foreign copy first in ld.so order"
_elf "${_img}/opt/foreign/libonnxruntime.so.1" "" "" "${WINML_SRC}"
_facts="$(_probe "${_iargs[@]}" --ld-library-path /opt/foreign)"
t_assert_contains "${_facts}" "libonnxruntime.so.1	/opt/foreign/libonnxruntime.so.1" "LD_LIBRARY_PATH beats ld.so.conf"
# An absolute symlink behind a relative directory symlink (/lib -> usr/lib, as merged-usr ships it).
if MSYS_NO_PATHCONV=1 MSYS2_ARG_CONV_EXCL='*' "${PY}" -c 'import os, sys
r = sys.argv[1]
os.makedirs(os.path.join(r, "usr", "lib", "abs"))
os.symlink("/usr/local/lib/onnxruntime-cpu/lib/libonnxruntime.so.1", os.path.join(r, "usr", "lib", "abs", "libabs.so.1"))
os.symlink("usr/lib", os.path.join(r, "lib"), target_is_directory=True)' "$(_ort_host_dir "${_img}")" 2>/dev/null; then
  t_assert_contains "$(_probe --root "$(_ort_host_dir "${_img}")" --core /lib/abs/libabs.so.1 --scan /etc)" \
    "	/usr/local/lib/onnxruntime-cpu/lib/libonnxruntime.so.1" "both links resolve inside the root, never on the host"
else
  echo "  note: this host cannot create symlinks; the in-root symlink case runs where it can"
fi

t_case "the manifest collect-artifacts.sh writes is what the census reads, pinned to this build's ORT version"
_fn="$(t_fn_src "${TESTS_DIR}/../03-media/runtime/collect-artifacts.sh" write_ort_wheel_manifest)" || exit 1
_venv="$(_ort_host_dir "${TESTS_DIR}/../01-core")/versions.env"
_ver="$(sed -n '/^ONNXRUNTIME_VERSION=v\{0,1\}/{s///p;q;}' "${_venv}")"
for _p in pfx pfx0; do
  mkdir -p "${_work}/${_p}/wheels"
  (cd "${_ref}/lib" && "${PY}" -c 'import sys, zipfile
for n in ("onnxruntime_gpu-%s-cp314-cp314-linux_x86_64.whl" % sys.argv[1], "onnxruntime_genai-%s-cp314-cp314-linux_x86_64.whl" % sys.argv[1],
          "onnxruntime-1.0.0-cp314-cp314-linux_x86_64.whl"):
    z = zipfile.ZipFile("../../%s/wheels/%s" % (sys.argv[2], n), "w"); z.write("libonnxruntime.so.1", "onnxruntime/capi/libonnxruntime.so.1"); z.close()' "${_ver:-unparsed}" "${_p}")
done
_pfx="${_work}/pfx"
# _wm <prefix> <versions.env>: the extracted writer in its own shell; the caller's ONNXRUNTIME_VERSION reaches it.
_wm() { bash -c "${_fn}"$'\n'"python3() { command ${PY} \"\$@\"; }; write_ort_wheel_manifest '$(_ort_host_dir "$1")' '$2'"; }
ONNXRUNTIME_VERSION='' t_assert_ok _wm "${_pfx}" "${_venv}"
t_assert_eq 1 "$(grep -c -e "onnxruntime_gpu-${_ver:-unparsed}-" "${_pfx}/ort-provenance.sha256" || true)" "the chain gpu wheel member is listed"
t_assert_eq 0 "$(grep -c -e 'genai' "${_pfx}/ort-provenance.sha256" || true)" "genai is not ORT, even at the ORT version"
t_assert_eq 0 "$(grep -c -e 'onnxruntime-1.0.0-' "${_pfx}/ort-provenance.sha256" || true)" "another ORT version is not this chain"
ONNXRUNTIME_VERSION=v1.0.0 t_assert_ok _wm "${_pfx}" "${_venv}"
t_assert_eq 1 "$(grep -c -e 'onnxruntime-1.0.0-' "${_pfx}/ort-provenance.sha256" || true)" "the build's ONNXRUNTIME_VERSION wins over versions.env"
ONNXRUNTIME_VERSION='' t_assert_fails _wm "${_work}/pfx0" /nonexistent
t_assert_ok test ! -e "${_work}/pfx0/ort-provenance.sha256"
t_assert_contains "${_ORT_CENSUS_MANIFESTS}" "/usr/local/lib/onnxruntime-cpu/ort-provenance.sha256" "the census reads the cpu manifest"
t_assert_contains "${_ORT_CENSUS_MANIFESTS}" "/usr/local/lib/onnxruntime-gpu/ort-provenance.sha256" "and the gpu one"
_coll="${TESTS_DIR}/../03-media/runtime/collect-artifacts.sh"
_l_cpu="$(grep -n -x -e 'write_ort_wheel_manifest /usr/local/lib/onnxruntime-cpu' "${_coll}" | cut -d: -f1 || true)"
_l_gpu="$(grep -n -x -e 'write_ort_wheel_manifest /usr/local/lib/onnxruntime-gpu' "${_coll}" | cut -d: -f1 || true)"
_l_mv="$(grep -n -e '^for wheel_source_dir in' "${_coll}" | cut -d: -f1 || true)"
t_assert_ok test "${_l_cpu:-0}" -gt 0
t_assert_ok test "${_l_gpu:-0}" -gt 0
t_assert_ok test "${_l_cpu:-99999}" -lt "${_l_mv:-0}"
t_assert_ok test "${_l_gpu:-99999}" -lt "${_l_mv:-0}"

t_case "the manifest follows the chain wheel through repair-wheels.sh: stripped and retagged it verifies, a foreign one never"
_rw="$(t_fn_src "${TESTS_DIR}/../03-media/runtime/repair-wheels.sh" ort_manifest_rows)" || exit 1
_fw="${_work}/follow"
_fwh="${_fw}/opt/wheels"
_fpfx="${_fw}/usr/local/lib/onnxruntime-cpu"
_fman="${_fpfx}/ort-provenance.sha256"
mkdir -p "${_fwh}" "${_fpfx}/wheels"
# _rows <check|follow>: the extracted rewriter over the fixture wheelhouse and manifest (host paths for a Windows python).
_rows() { bash -c "${_rw}"$'\n'"python3() { command ${PY} \"\$@\"; }; ort_manifest_rows $1 '$(_ort_host_dir "${_fwh}")' '$(_ort_host_dir "${_fpfx}")/ort-provenance.sha256'"; }
# _whl <dir under the fixture> <wheel name> <member file>: a wheel whose pybind module holds that file's bytes.
_whl() {
  (cd "${_fw}" && "${PY}" -c 'import sys, zipfile
z = zipfile.ZipFile(sys.argv[1], "w"); z.write(sys.argv[2], "onnxruntime/capi/onnxruntime_pybind11_state.so"); z.close()' "$1/$2" "$3")
}
_elf "${_fw}/built.so" "" "" "${CHAIN_SRC}" '.symtab .strtab .debug_info'
_elf "${_fw}/stripped.so" "" "" "${CHAIN_SRC}"
_elf "${_fw}/pypi.so" "" "" '/home/tlwu/onnxruntime/onnxruntime/core/session/inference_session.cc'
_built="onnxruntime-${_ver:-unparsed}-cp314-cp314-linux_aarch64.whl"
_retag="onnxruntime-${_ver:-unparsed}-cp314-cp314-manylinux_2_39_aarch64.whl"
_whl usr/local/lib/onnxruntime-cpu/wheels "${_built}" built.so
ONNXRUNTIME_VERSION='' t_assert_ok _wm "${_fpfx}" "${_venv}"
cp "${_fman}" "${_fw}/as-built.sha256"
mv "${_fpfx}/wheels/${_built}" "${_fwh}/"
t_assert_ok _rows check
rm -f "${_fwh}/${_built}"
_whl opt/wheels "${_retag}" stripped.so
t_assert_ok _rows follow
t_assert_contains "$(cat "${_fman}")" "  ${_retag}!onnxruntime/capi/onnxruntime_pybind11_state.so" "re-pointed at the retagged wheel"
_capi_rel=opt/venv/lib/python3.14/site-packages/onnxruntime/capi/onnxruntime_pybind11_state.so
mkdir -p "${_fw}/img/${_capi_rel%/*}" "${_fw}/img/usr/local/lib/onnxruntime-cpu"
# _fcensus <manifest>: G1's verdicts over an image whose venv holds the member at _capi_rel, graded by that manifest.
_fcensus() {
  cp "$1" "${_fw}/img/usr/local/lib/onnxruntime-cpu/ort-provenance.sha256"
  _v "$(_probe --image --root "$(_ort_host_dir "${_fw}/img")" --ld-library-path "" --chain-root /opt/onnxruntime \
    --ref-manifest /usr/local/lib/onnxruntime-cpu/ort-provenance.sha256)"
}
cp "${_fw}/stripped.so" "${_fw}/img/${_capi_rel}"
t_assert_eq "" "$(_fcensus "${_fman}")" "the stripped member verifies against the followed manifest"
t_assert_contains "$(_fcensus "${_fw}/as-built.sha256")" "STALE	/${_capi_rel}" "the as-built hashes call it STALE: the defect"
cp "${_fw}/pypi.so" "${_fw}/img/${_capi_rel}"
t_assert_contains "$(_fcensus "${_fman}")" "FOREIGN	/${_capi_rel}" "a foreign member does not verify"
cp "${_fw}/as-built.sha256" "${_fman}"
rm -f "${_fwh}"/*.whl
_whl opt/wheels "${_built}" pypi.so
t_assert_fails _rows check
t_assert_contains "$(_rows check 2>&1)" "no wheel in" "a foreign wheel under the chain wheel's name is refused"
_whl opt/wheels "${_retag}" stripped.so
t_assert_fails _rows follow
t_assert_eq "$(cat "${_fw}/as-built.sha256")" "$(cat "${_fman}")" "two wheels of that name: nothing is re-pointed"
rm -f "${_fwh}/${_built}"
_whl opt/wheels "onnxruntime_gpu-${_ver:-unparsed}-cp314-cp314-manylinux_2_39_aarch64.whl" pypi.so
t_assert_ok _rows follow
t_assert_eq 0 "$(grep -c -e 'onnxruntime_gpu' "${_fman}" || true)" "another wheel never enters the manifest"
cp "${_fw}/as-built.sha256" "${_fman}"
rm -f "${_fwh}"/*.whl
_whl opt/wheels "${_built}" built.so
_whl opt/wheels "onnxruntime-${_ver:-unparsed}-cp314-cp314-manylinux_2_27_aarch64.whl" pypi.so
t_assert_fails _rows check
t_assert_contains "$(_rows check 2>&1)" "other wheels share its name, platform tag aside" "a twin the retag would rename onto the chain wheel"
_rwf="${TESTS_DIR}/../03-media/runtime/repair-wheels.sh"
_seq="$(grep -E -e '^ *(ort_manifest_rows (check|follow) |strip_cross_wheels$|exit 0$|rmdir "\$\{REPAIRED_WHEELS_DIR\}")' "${_rwf}" \
  | sed -E -e 's/^ +//' -e 's/ ".*$//' -e 's/^rmdir.*/rmdir/' | tr '\n' '|')"
t_assert_eq 'ort_manifest_rows check|strip_cross_wheels|ort_manifest_rows follow|exit 0|rmdir|ort_manifest_rows follow|' "${_seq}" \
  "proved before the strip, followed after it on the cross and the native path"
t_assert_contains "$(cat "${_rwf}")" '_ORT_MANIFESTS=(/usr/local/lib/onnxruntime-*/ort-provenance.sha256)'
t_assert_ok bash -c 'for m in $1; do case "${m}" in /usr/local/lib/onnxruntime-*/ort-provenance.sha256) ;; *) exit 1 ;; esac; done' _ \
  "${_ORT_CENSUS_MANIFESTS}"
_l_rep="$(grep -n -e 'runtime/repair-wheels.sh &&' "${TESTS_DIR}/../../Dockerfile.media" | cut -d: -f1 || true)"
_l_ver="$(grep -n -e 'runtime/verify-wheels.sh &&' "${TESTS_DIR}/../../Dockerfile.media" | cut -d: -f1 || true)"
_l_col="$(grep -n -e 'runtime/collect-artifacts.sh &&' "${TESTS_DIR}/../../Dockerfile.media" | cut -d: -f1 || true)"
_l_ins="$(grep -n -e 'uv pip install --no-deps /opt/wheels/\*\.whl' "${TESTS_DIR}/../../Dockerfile.media" | cut -d: -f1 || true)"
t_assert_ok test "${_l_col:-0}" -gt 0
t_assert_ok test "${_l_col:-0}" -lt "${_l_rep:-0}"
t_assert_ok test "${_l_rep:-99999}" -lt "${_l_ver:-0}"
t_assert_ok test "${_l_ver:-99999}" -lt "${_l_ins:-0}"

t_case "wiring: the runtime smoke runs the census in-image, on every arch, with the image's refs"
SMOKE="${PKG}/smoke-runtime-image.sh"
t_assert_contains "$(sed -n '/^main()/,/^}/p' "${SMOKE}")" 'check_ort_census "${image_tag}" "${target_arch}"' "called from main()"
t_assert_contains "$(cat "${SMOKE}")" 'source "${_SCRIPT_DIR}/check-ort-provenance.sh"' "the census is sourced"
_cc="$(t_fn_src "${SMOKE}" check_ort_census)" || exit 1
t_assert_contains "${_cc}" 'mapfile -t args < <(ort_census_image_args)' "image args"
t_assert_contains "${_cc}" 'ort_census_verdicts "${probe}" "${armed}" "${target_arch}"' "armed STAMP and arch-scoped exemptions"
t_assert_contains "${_cc}" '*) bad=$((bad + 1)); fail "ORT census:' "every non-EXEMPT verdict fails"
_ia="$(ort_census_image_args | tr '\n' ' ')"
for _want in '--image' '--ref /usr/local/lib/onnxruntime-cpu' '--ref /usr/local/lib/onnxruntime-gpu' '--ref /opt/android/onnxruntime' \
  '--ref-manifest /usr/local/lib/onnxruntime-cpu/ort-provenance.sha256' '--core /usr/local/lib/onnxruntime-cpu/lib/libonnxruntime.so.1' \
  '--chain-root /opt/onnxruntime' '--contract genai|'; do
  t_assert_contains "${_ia}" "${_want}" "image args carry ${_want}"
done

t_case "the declared chain roots are where the chain builds ORT"
_common="$(cat "${TESTS_DIR}/../03-media/build/onnxruntime/build/lib/common.sh")"
_src="$(printf '%s\n' "${_common}" | sed -n 's/.*ORT_SRC_DIR="\${ORT_SRC_DIR:-\([^}]*\)}".*/\1/p' | head -1)"
t_assert_contains "$(ort_census_chain_roots)" "${_src:-unparsed}" "ORT_SRC_DIR default"
t_assert_contains "$(cat "${TESTS_DIR}/../03-media/build/onnxruntime/android/build-android.sh")" 'onnxruntime-android' "android clone dir"
t_assert_contains "$(ort_census_chain_roots)" /opt/onnxruntime-android "and its root is declared"

t_summary
