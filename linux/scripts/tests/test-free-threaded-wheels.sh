#!/usr/bin/env bash
# The media wheels' cp314t twins: the table, the venv, gate and proof each twin passes, and the RUNs wired to them; see docs/consumer-image-contract.md#the-free-threaded-wheels
set -u
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${TESTS_DIR}/test-harness.sh"
SCRIPTS="$(cd "${TESTS_DIR}/.." && pwd)"
LIB="${SCRIPTS}/03-media/free-threaded-wheels.sh"
TABLE="${SCRIPTS}/03-media/free-threaded-twins.txt"
WINMOD="${SCRIPTS}/../../windows/scripts/modules/WindowsPythonWheel.Common.psm1"
VERSIONS="${SCRIPTS}/01-core/versions.env"
MEDIA="${SCRIPTS}/../Dockerfile.media"
ORT_BUILD="${SCRIPTS}/03-media/build/onnxruntime/build"

t_skip_unless "a POSIX python3 (the fixtures are zip files it reads by path)" t_posix_python

_work="$(mktemp -d)"; trap 'rm -rf "${_work}"' EXIT
# shellcheck source=../03-media/free-threaded-wheels.sh
source "${LIB}"

t_case "every table row is well formed, and its pin is versions.env's: a bump re-reads the evidence"
while IFS='|' read -r _dist _verdict _pin _evidence; do
  t_assert_eq "${_dist}" "$(_ft_norm "${_dist}")" "${_dist} is spelled in PEP 503 form"
  case "${_verdict}" in twin | gil | none) t_assert_eq 1 1 ;; twin:*) t_assert_eq 1 "$(grep -c -x -e "${_verdict#twin:}=[01]" "${VERSIONS}")" "${_dist}'s knob is a 0/1 versions.env key" ;; *) t_assert_eq "twin, twin:<KNOB>, gil or none" "${_verdict}" "${_dist}'s verdict" ;; esac
  t_assert_eq "${_pin#*=}" "$(sed -n "s/^${_pin%%=*}=//p" "${VERSIONS}" | head -n 1)" \
    "${_dist} was read at ${_pin}; re-read its free-threading support at the new pin and update its row"
  t_assert_ok test -n "${_evidence}"
done < <(ft_wheel_table)

t_case "one table for both lanes: ft_wheel_table is the shared file's rows, and neither reader keeps a copy"
t_assert_eq "$(sed -e '/^#/d' -e '/^[[:space:]]*$/d' "${TABLE}")" "$(ft_wheel_table)" "the shared file, row for row"
t_assert_ok test "$(ft_wheel_table | wc -l)" -ge 10
t_assert_eq "${TABLE}" "${_FTW_TABLE}" "the library reads the file beside it"
t_assert_contains "$(cat "${WINMOD}")" "03-media\\free-threaded-twins.txt" "Get-FreeThreadedTwinTable reads the same file"
t_assert_eq 0 "$(cat "${LIB}" "${WINMOD}" | grep -c -E '[a-z0-9-]+\|(twin|twin:[A-Z0-9_]+|gil|none)\|[A-Z0-9_]+=')" "no row literal left in either reader"

t_case "a missing table is an error naming the file, never an unknown verdict"
mkdir -p "${_work}/notable"; cp "${LIB}" "${_work}/notable/"
_nt() { bash -c 'source "$1"; shift; "$@"' _ "${_work}/notable/free-threaded-wheels.sh" "$@"; }
t_assert_eq 1 "$(t_rc _nt ft_wheel_table)"
t_assert_contains "$(_nt ft_wheel_table 2>&1)" "the twin table ${_work}/notable/free-threaded-twins.txt is missing"
t_assert_eq 2 "$(t_rc _nt ft_wheel_verdict av)" "no table is no verdict"
t_assert_eq "" "$(_nt ft_wheel_verdict av 2>/dev/null)" "and prints none, so no caller reads unknown"
t_assert_eq 2 "$(t_rc _nt ft_twin_wanted av)"
t_assert_eq "" "$(_nt ft_twin_wanted av 2>&1 | grep -e 'is not in ft_wheel_table' || true)" "the missing table is not reported as an unclassified package"

t_case "the twins are exactly the five packages whose own code declares free-threading"
t_assert_eq "apache-tvm-ffi av iree-base-compiler iree-base-runtime onnxruntime" \
  "$(ft_wheel_table | awk -F'|' '$2 == "twin" { print $1 }' | LC_ALL=C sort | tr '\n' ' ' | sed 's/ $//')"

t_case "a wheel's verdict: ORT flavours are onnxruntime, GenAI flavours stay GIL-only, apache-tvm needs none"
for _w in onnxruntime onnxruntime_dnnl onnxruntime-gpu onnxruntime_webgpu onnxruntime_migraphx av apache_tvm_ffi iree_base_runtime iree_base_compiler; do
  t_assert_eq twin "$(ft_wheel_verdict "${_w}")" "${_w}"
done
for _w in onnxruntime_genai onnxruntime_genai_cuda ai_edge_litert hailort; do
  t_assert_eq gil "$(ft_wheel_verdict "${_w}")" "${_w}"
done
t_assert_eq none "$(ft_wheel_verdict apache_tvm)"
t_assert_eq unknown "$(ft_wheel_verdict pillow)" "a wheel nobody classified"

t_case "the knob rows: torch and numpy declare free-threading, and the riscv64 torch twin follows FT_TORCH_TWIN"
t_assert_eq "twin:FT_TORCH_TWIN" "$(ft_wheel_verdict torch)"
t_assert_eq "twin:FT_TORCH_TWIN" "$(ft_wheel_verdict numpy)"
t_assert_eq 1 "$(grep -c -x -e 'FT_TORCH_TWIN=1' "${VERSIONS}")" "on by default: the twin pass reuses the warm tree (BACKLOG CON79 1b)"
t_assert_eq 2 "$(grep -c -x -e 'ARG FT_TORCH_TWIN=1' "${MEDIA}")" "app-wheelhouse builds it, the final RUN's store expects it"
t_assert_eq 0 "$(FT_TORCH_TWIN=1 t_rc ft_twin_expected torch)"
t_assert_eq 1 "$(FT_TORCH_TWIN=0 t_rc ft_twin_expected torch)"
t_assert_eq 1 "$(unset FT_TORCH_TWIN; t_rc ft_twin_expected torch)" "an unset knob is off"
t_assert_eq 0 "$(t_rc ft_twin_expected av)"
t_assert_eq 1 "$(t_rc ft_twin_expected apache-tvm)"
t_assert_eq 1 "$(FT_TORCH_TWIN=0 t_rc ft_twin_wanted torch)"
t_assert_contains "$(FT_TORCH_TWIN=0 ft_twin_wanted torch)" "no cp314t twin of torch: the FT_TORCH_TWIN knob is off"

t_case "ft_twin_wanted: GIL-only and py3 packages say why in one line, an unknown one is an error"
t_assert_eq 1 "$(t_rc ft_twin_wanted onnxruntime-genai)"
t_assert_contains "$(ft_twin_wanted onnxruntime-genai)" "no cp314t twin of onnxruntime-genai (gil): pybind11 2.13.6"
t_assert_contains "$(ft_twin_wanted apache-tvm)" "no cp314t twin of apache-tvm (none): pyproject.toml: wheel.py-api"
t_assert_eq 2 "$(t_rc ft_twin_wanted pillow)"
t_assert_contains "$(ft_twin_wanted pillow 2>&1)" "pillow is not in ft_wheel_table"

t_case "ft_twin_wanted: a native build without the interpreter is an error"
t_assert_eq 2 "$(cross_build_is_active() { return 1; }; PYTHON_FT_PREFIX="${_work}/none" t_rc ft_twin_wanted av)"
# A cross target's staged 3.14t tree (CON66's /opt/python-cross-ft/<arch>), with its sysconfigdata and headers.
_tgt() {
  local root="$1" arch="$2" suffix="$3"
  mkdir -p "${root}/bin" "${root}/include/python3.14t" "${root}/lib/python3.14t"
  : > "${root}/bin/python3.14t"; chmod +x "${root}/bin/python3.14t"; : > "${root}/include/python3.14t/Python.h"
  printf 'build_time_vars = {"EXT_SUFFIX": "%s", "Py_GIL_DISABLED": 1}\n' "${suffix}" > "${root}/lib/python3.14t/_sysconfigdata_t_linux_${arch}-linux-gnu.py"
}
_tgt "${_work}/rv/riscv64/opt/python-freethreaded" riscv64 .cpython-314t-riscv64-linux-gnu.so
_tgt "${_work}/rvbad/riscv64/opt/python-freethreaded" riscv64 .cpython-314-riscv64-linux-gnu.so
# <stage root> <snippet> [args]: the snippet in a riscv64 cross build of the library whose host 3.14t is python3.
_x() {
  local root="$1"; shift
  env FT_PYTHON=python3 PYTHON_FT_PREFIX=/opt/python-freethreaded PYTHON_FT_CROSS_STAGE_ROOT="${root}" TMPDIR="${_work}" \
    bash -c 'source "$1"; shift; cross_build_is_active() { return 0; }; cross_target_arch() { echo "${XARCH:-riscv64}"; }
             ft_python_resolve() { FT_PYTHON=python3; }; cross_target_qemu_runner() { echo "${QEMU:-}"; }
             snippet="$1"; shift; eval "${snippet} \"\$@\""' _ "${LIB}" "$@"
}

t_case "cross: ft_target_resolve reads the target 3.14t's EXT_SUFFIX, headers, libpython and platform from its staged tree"
_out="$(_x "${_work}/rv" 'ft_target_resolve && printf "%s\n" "${FT_TARGET_EXT_SUFFIX}" "${FT_TARGET_INCLUDE}" "${FT_TARGET_LIBRARY}" "${FT_TARGET_PLATFORM_TAG}" "${FT_TARGET_SYSCONFIG_NAME}"' 2>&1)"
t_assert_eq ".cpython-314t-riscv64-linux-gnu.so
${_work}/rv/riscv64/opt/python-freethreaded/include/python3.14t
${_work}/rv/riscv64/opt/python-freethreaded/lib/libpython3.14t.so
linux_riscv64
_sysconfigdata_t_linux_riscv64-linux-gnu" "${_out}"
_tgt "${_work}/a64/arm64/opt/python-freethreaded" aarch64 .cpython-314t-aarch64-linux-gnu.so
t_assert_eq ".cpython-314t-aarch64-linux-gnu.so linux_aarch64" "$(XARCH=arm64 _x "${_work}/a64" 'ft_target_resolve && echo "${FT_TARGET_EXT_SUFFIX} ${FT_TARGET_PLATFORM_TAG}"')" "the arm64 cross lane reads its own tree"
t_assert_contains "$(XARCH=arm64 _x "${_work}/rv" ft_target_resolve 2>&1)" "the arm64 3.14t tree ${_work}/rv/arm64/opt/python-freethreaded has no bin/python3.*t" "never another arch's tree"
t_assert_fails _x "${_work}/rvbad" ft_target_resolve
t_assert_contains "$(_x "${_work}/rvbad" ft_target_resolve 2>&1)" "not a free-threaded riscv64 one"
t_assert_contains "$(_x "${_work}/none" ft_target_resolve 2>&1)" "has no bin/python3.*t or _sysconfigdata_t_*.py"

t_case "cross: ft_twin_wanted builds the twin against the target tree; without one it is an error, not a skip"
t_assert_eq 0 "$(_x "${_work}/rv" 'ft_twin_wanted av >/dev/null; echo $?')"
t_assert_contains "$(_x "${_work}/rv" ft_twin_wanted av)" "building the cp314t twin of av for riscv64 (.cpython-314t-riscv64-linux-gnu.so"
t_assert_eq 2 "$(_x "${_work}/none" 'ft_twin_wanted av >/dev/null 2>&1; echo $?')"
t_assert_contains "$(_x "${_work}/none" ft_twin_wanted av 2>&1)" "this cross build has no target 3.14t tree to build it against"
t_assert_eq 1 "$(_x "${_work}/rv" 'ft_twin_wanted onnxruntime-genai >/dev/null; echo $?')" "a GIL-only package stays a skip"

t_case "cross: ft_target_env hands a wheel build the target's sysconfig and platform; native gets nothing"
_out="$(_x "${_work}/rv" 'ft_target_resolve; ft_target_env')"
t_assert_contains "${_out}" "_PYTHON_SYSCONFIGDATA_NAME=_sysconfigdata_t_linux_riscv64-linux-gnu _PYTHON_HOST_PLATFORM=linux_riscv64"
t_assert_contains "${_out}" "PYTHONPATH=${_work}/ft-target-sysconfig-riscv64"
t_assert_ok test -f "${_work}/ft-target-sysconfig-riscv64/_sysconfigdata_t_linux_riscv64-linux-gnu.py"
t_assert_eq "" "$(bash -c 'source "$1"; ft_target_env' _ "${LIB}")"
mkdir -p "${_work}/gilpy/bin"
printf '#!/usr/bin/env bash\necho 0\n' > "${_work}/gilpy/bin/python3.14t"; chmod +x "${_work}/gilpy/bin/python3.14t"
t_assert_contains "$(PYTHON_FT_PREFIX="${_work}/gilpy" ft_python_resolve 2>&1)" "is not a --disable-gil build"
mkdir -p "${_work}/ftenv/bin"
printf '#!/usr/bin/env bash\nif [ -n "${_PYTHON_SYSCONFIGDATA_NAME:-}${PYTHONPATH:-}" ]; then echo 0; else echo 1; fi\n' > "${_work}/ftenv/bin/python3.14t"
chmod +x "${_work}/ftenv/bin/python3.14t"
t_assert_ok env _PYTHON_SYSCONFIGDATA_NAME=_sysconfigdata__linux_aarch64-linux-gnu PYTHONPATH=/x _PYTHON_HOST_PLATFORM=linux_aarch64 \
  bash -c 'source "$1"; PYTHON_FT_PREFIX="$2" ft_python_resolve' _ "${LIB}" "${_work}/ftenv"

# _whl <name> <member>...: a wheel holding empty members.
_whl() { t_zip "${_work}/$1" "${@:2}"; }
_SUF=.cpython-314t-x86_64-linux-gnu.so
_gate() { FT_PYTHON=python3 ft_soabi_gate "${_work}/$1" "${_SUF}"; }

t_case "the SOABI gate: a cp314-cp314t name and free-threaded modules pass, a bundled library is no module"
_whl av-19.0.1-cp314-cp314t-linux_x86_64.whl "av/codec/codec${_SUF}" av/__init__.py av.libs/libavcodec.so.62 onnxruntime/capi/libonnxruntime_providers_shared.so
t_assert_ok _gate av-19.0.1-cp314-cp314t-linux_x86_64.whl

t_case "the SOABI gate: a GIL name, a GIL module, an abi3 module and another arch all fail"
_whl av-19.0.1-cp314-cp314-linux_x86_64.whl "av/codec/codec${_SUF}"
t_assert_fails _gate av-19.0.1-cp314-cp314-linux_x86_64.whl
t_assert_contains "$(_gate av-19.0.1-cp314-cp314-linux_x86_64.whl 2>&1)" "the name is cp314-cp314, not cp314-cp314t"
_whl gilmod-1-cp314-cp314t-linux_x86_64.whl av/codec/codec.cpython-314-x86_64-linux-gnu.so
t_assert_fails _gate gilmod-1-cp314-cp314t-linux_x86_64.whl
_whl abi3mod-1-cp314-cp314t-linux_x86_64.whl iree/_runtime.abi3.so
t_assert_fails _gate abi3mod-1-cp314-cp314t-linux_x86_64.whl
_whl arm-1-cp314-cp314t-linux_x86_64.whl av/codec/codec.cpython-314t-aarch64-linux-gnu.so
t_assert_fails _gate arm-1-cp314-cp314t-linux_x86_64.whl
t_assert_fails env FT_PYTHON=python3 bash -c 'source "$1"; ft_soabi_gate "$2" .cpython-314-x86_64-linux-gnu.so' _ "${LIB}" "${_work}/av-19.0.1-cp314-cp314t-linux_x86_64.whl"

t_case "the SOABI gate: the platform tag must name the suffix's machine; a cross build gates against the target's suffix"
_whl rvx-1-cp314-cp314t-linux_x86_64.whl m/x.cpython-314t-riscv64-linux-gnu.so
_whl rv-1-cp314-cp314t-linux_riscv64.whl m/x.cpython-314t-riscv64-linux-gnu.so
_whl hostso-1-cp314-cp314t-linux_riscv64.whl "m/x${_SUF}"
t_assert_fails env FT_PYTHON=python3 bash -c 'source "$1"; ft_soabi_gate "$2" .cpython-314t-riscv64-linux-gnu.so' _ "${LIB}" "${_work}/rvx-1-cp314-cp314t-linux_x86_64.whl"
t_assert_contains "$(FT_PYTHON=python3 bash -c 'source "$1"; ft_soabi_gate "$2" .cpython-314t-riscv64-linux-gnu.so' _ "${LIB}" "${_work}/rvx-1-cp314-cp314t-linux_x86_64.whl" 2>&1)" "the platform tag is linux_x86_64, not one for riscv64"
t_assert_ok _x "${_work}/rv" ft_soabi_gate "${_work}/rv-1-cp314-cp314t-linux_riscv64.whl"
t_assert_fails _x "${_work}/rv" ft_soabi_gate "${_work}/hostso-1-cp314-cp314t-linux_riscv64.whl"
t_assert_contains "$(_x "${_work}/rv" ft_soabi_gate "${_work}/hostso-1-cp314-cp314t-linux_riscv64.whl" 2>&1)" "m/x${_SUF} is not .cpython-314t-riscv64-linux-gnu.so"
_whl many-1-cp314-cp314t-manylinux_2_28_riscv64.whl m/x.cpython-314t-riscv64-linux-gnu.so
t_assert_ok _x "${_work}/rv" ft_soabi_gate "${_work}/many-1-cp314-cp314t-manylinux_2_28_riscv64.whl"

# A uv that logs, makes venvs whose python prints the helper's verdict, and installs nothing.
mkdir -p "${_work}/bin"
cat > "${_work}/bin/uv" <<'UV'
#!/usr/bin/env bash
printf 'uv %s\n' "$*" >> "${CALLS}"
if [ "$1" = venv ]; then
  d="${!#}"; mkdir -p "${d}/bin"
  printf '#!/usr/bin/env bash\nprintf "py %%s\\n" "$*" >> "${CALLS}"\nprintf "%%s\\n" "${VERDICT:-3 compiled module(s) of av loaded}"\nexit "${PROVE_RC:-0}"\n' > "${d}/bin/python"
  chmod +x "${d}/bin/python"
fi
exit 0
UV
chmod +x "${_work}/bin/uv"
export CALLS="${_work}/calls"
# The GIL build venv's interpreter: it knows cython 3.3.0 and setuptools 84.0.0, nothing else.
cat > "${_work}/gil-python" <<'GIL'
#!/usr/bin/env bash
case "${!#}" in cython) echo 3.3.0 ;; setuptools) echo 84.0.0 ;; *) exit 1 ;; esac
GIL
chmod +x "${_work}/gil-python"
_venv() { PATH="${_work}/bin:${PATH}" FT_PYTHON=/ft/python3.14t bash -c 'source "$1"; shift; ft_build_venv "$@"' _ "${LIB}" "$@"; }

t_case "the twin's build venv takes the GIL build venv's own versions; one it lacks is an error"
: > "${CALLS}"
t_assert_ok _venv "${_work}/v" "${_work}/gil-python" cython setuptools numpy==2.5.3
t_assert_contains "$(cat "${CALLS}")" "uv venv --clear --quiet --python /ft/python3.14t ${_work}/v"
t_assert_contains "$(cat "${CALLS}")" "uv pip install --quiet --python ${_work}/v/bin/python cython==3.3.0 setuptools==84.0.0 numpy==2.5.3"
t_assert_fails _venv "${_work}/v" "${_work}/gil-python" cython numpy
t_assert_contains "$(_venv "${_work}/v" "${_work}/gil-python" numpy 2>&1)" "has no numpy, so its twin has no version to match"

# A 3.14t that answers the free-threaded EXT_SUFFIX and lends python3 to the gate's zip scan.
cat > "${_work}/python3.14t" <<'FT'
#!/usr/bin/env bash
case "$*" in *EXT_SUFFIX*) echo .cpython-314t-x86_64-linux-gnu.so; exit 0 ;; esac
exec python3 "$@"
FT
chmod +x "${_work}/python3.14t"
_store() { PATH="${_work}/bin:${PATH}" FT_PYTHON="${_work}/python3.14t" TMPDIR="${_work}" bash -c 'source "$1"; ft_store_twin "$2" "$3"' _ "${LIB}" "$@"; }
_AV="${_work}/av-19.0.1-cp314-cp314t-linux_x86_64.whl"
t_case "a twin is proved with the hub's helper in a fresh venv before it is stored"
: > "${CALLS}"
t_assert_ok _store "${_AV}" "${_work}/store"
t_assert_contains "$(cat "${CALLS}")" "--no-deps ${_AV}" "the wheel alone"
t_assert_contains "$(cat "${CALLS}")" "py -I ${LIB%/*}/../02-toolchain/python/free-threaded-wheel.py prove av" "proved by the shared helper"
t_assert_ok test -f "${_work}/store/av-19.0.1-cp314-cp314t-linux_x86_64.whl"
t_assert_eq "" "$(compgen -G "${_work}/ft-prove.*")" "the proof venv is gone"

t_case "an unproved or GIL-tagged twin is never stored"
_out="$(PROVE_RC=1 VERDICT="ERROR: the GIL was re-enabled, first by av.codec" _store "${_AV}" "${_work}/store2" 2>&1)"; _rc=$?
t_assert_eq 1 "${_rc}"
t_assert_contains "${_out}" "is not proved: ERROR: the GIL was re-enabled, first by av.codec"
t_assert_fails _store "${_work}/av-19.0.1-cp314-cp314-linux_x86_64.whl" "${_work}/store2"
t_assert_eq "" "$(compgen -G "${_work}/store2/*.whl")" "nothing reached the store"

t_case "cross: the proof unpacks the twin and runs the target 3.14t under qemu-user, with the target's libraries first"
mkdir -p "${_work}/sysroot/lib"; : > "${_work}/sysroot/lib/ld-linux-riscv64-lp64d.so.1"
cat > "${_work}/qemu-riscv64" <<'QEMU'
#!/usr/bin/env bash
printf 'qemu %s\n' "$*" >> "${CALLS}"
while [ "${1#-}" != "$1" ]; do shift 2; done
# The target python, -I -c <bootstrap>, then the unpacked site dir, the helper, prove, the dist.
site="$5"
[ -f "${site}/m/x.cpython-314t-riscv64-linux-gnu.so" ] && [ -d "${site}/rv-1.dist-info" ] && [ -f "${site}/m/data.txt" ] || { echo "the wheel was not unpacked whole"; exit 3; }
echo "${QEMU_SAYS:-1 compiled module(s) of rv loaded on free-threaded 3.14.8; the GIL stayed disabled}"
exit "${QEMU_RC:-0}"
QEMU
chmod +x "${_work}/qemu-riscv64"
_whl rvp-1-cp314-cp314t-linux_riscv64.whl m/x.cpython-314t-riscv64-linux-gnu.so rv-1.dist-info/METADATA rv-1.data/purelib/m/data.txt
_qx() { _x "${_work}/rv" ft_prove_wheel "$@"; }
export QEMU="${_work}/qemu-riscv64"
: > "${CALLS}"
_out="$(FT_QEMU_SYSROOT="${_work}/sysroot" LD_LIBRARY_PATH=/opt/ffmpeg/lib _qx "${_work}/rvp-1-cp314-cp314t-linux_riscv64.whl" rv 2>&1)"; _rc=$?
t_assert_eq 0 "${_rc}" "${_out}"
t_assert_contains "${_out}" "free-threaded: rvp-1-cp314-cp314t-linux_riscv64.whl: 1 compiled module(s) of rv loaded on free-threaded 3.14.8; the GIL stayed disabled (on riscv64 under qemu-riscv64)"
t_assert_contains "$(cat "${CALLS}")" "qemu -L ${_work}/sysroot -E LD_LIBRARY_PATH=${_work}/rv/riscv64/opt/python-freethreaded/lib:"
t_assert_contains "$(cat "${CALLS}")" ":/opt/ffmpeg/lib -U PYTHONPATH -U PYTHONHOME ${_work}/rv/riscv64/opt/python-freethreaded/bin/python3.14t -I -c"
mkdir -p "${_work}/gcc16/riscv64-linux-gnu/lib" "${_work}/xbin"; : > "${_work}/gcc16/riscv64-linux-gnu/lib/libstdc++.so.6"
printf '#!/usr/bin/env bash\necho "%s/gcc16/lib/gcc/riscv64-linux-gnu/16.2.0/../../../../riscv64-linux-gnu/lib/libstdc++.so.6"\n' "${_work}" > "${_work}/xbin/riscv64-linux-gnu-g++"
chmod +x "${_work}/xbin/riscv64-linux-gnu-g++"; mkdir -p "${_work}/gcc16/lib/gcc/riscv64-linux-gnu/16.2.0"
: > "${CALLS}"
PATH="${_work}/xbin:${PATH}" FT_QEMU_SYSROOT="${_work}/sysroot" _qx "${_work}/rvp-1-cp314-cp314t-linux_riscv64.whl" rv >/dev/null 2>&1
t_assert_contains "$(cat "${CALLS}")" "LD_LIBRARY_PATH=${_work}/rv/riscv64/opt/python-freethreaded/lib:${_work}/gcc16/riscv64-linux-gnu/lib:${_work}/sysroot/lib/riscv64-linux-gnu:" \
  "the cross GCC's target libstdc++ comes before the sysroot's older one (an ORT twin needs GLIBCXX_3.4.36)"
t_assert_contains "$(cat "${CALLS}")" "free-threaded-wheel.py prove rv"
t_assert_eq "" "$(compgen -G "${_work}/ft-prove.*")" "the unpacked site is gone"
_out="$(QEMU_RC=1 QEMU_SAYS="ERROR: the GIL was re-enabled, first by m.x" FT_QEMU_SYSROOT="${_work}/sysroot" _qx "${_work}/rvp-1-cp314-cp314t-linux_riscv64.whl" rv 2>&1)"; _rc=$?
t_assert_eq 1 "${_rc}"
t_assert_contains "${_out}" "is not proved: ERROR: the GIL was re-enabled, first by m.x (on riscv64 under qemu-riscv64)"
t_assert_contains "$(FT_QEMU_SYSROOT="${_work}/nosysroot" _qx "${_work}/rvp-1-cp314-cp314t-linux_riscv64.whl" rv 2>&1)" "no ld-linux-riscv64-lp64d.so.1"
t_assert_contains "$(QEMU='' FT_QEMU_SYSROOT="${_work}/sysroot" _qx "${_work}/rvp-1-cp314-cp314t-linux_riscv64.whl" rv 2>&1)" "no qemu-user for riscv64"

t_case "ft_twin_start: 0 with a venv for a twin, 1 for a package without one, 2 for an error"
_start() { PATH="${_work}/bin:${PATH}" PYTHON_FT_PREFIX="${_work}/gilpy" bash -c 'source "$1"; shift; ft_twin_start "$@"' _ "${LIB}" "$@"; }
t_assert_eq 1 "$(t_rc _start onnxruntime-genai "${_work}/v2" "${_work}/gil-python" cython)"
t_assert_eq 2 "$(t_rc _start pillow "${_work}/v2" "${_work}/gil-python" cython)"
t_assert_eq 2 "$(t_rc _start av "${_work}/v2" "${_work}/gil-python" cython)" "a native build whose 3.14t is a GIL build"
mkdir -p "${_work}/ftpy/bin"; cp "${_work}/python3.14t" "${_work}/ftpy/bin/python3.14t"
printf '#!/usr/bin/env bash\ncase "$*" in *Py_GIL_DISABLED*) echo 1; exit 0 ;; esac\nexec %q "$@"\n' "${_work}/python3.14t" > "${_work}/ftpy/bin/python3.14t"
: > "${CALLS}"
t_assert_eq 0 "$(PATH="${_work}/bin:${PATH}" PYTHON_FT_PREFIX="${_work}/ftpy" bash -c 'source "$1"; shift; ft_twin_start "$@" >/dev/null; echo $?' _ "${LIB}" av "${_work}/v2" "${_work}/gil-python" cython)"
t_assert_contains "$(cat "${CALLS}")" "uv pip install --quiet --python ${_work}/v2/bin/python cython==3.3.0" "the venv is built only for a twin"

t_case "ft_twin_store_built: the twin leaves the build tree once it is stored"
mkdir -p "${_work}/tree-dist"; cp "${_AV}" "${_work}/tree-dist/"
t_assert_ok env PATH="${_work}/bin:${PATH}" FT_PYTHON="${_work}/python3.14t" TMPDIR="${_work}" bash -c 'source "$1"; ft_twin_store_built "$2" "$3"' _ "${LIB}" "${_work}/tree-dist" "${_work}/store3"
t_assert_ok test -f "${_work}/store3/av-19.0.1-cp314-cp314t-linux_x86_64.whl"
t_assert_eq "" "$(compgen -G "${_work}/tree-dist/*.whl")" "a later GIL collection of the tree cannot pick it up"

t_case "ft_built_wheel: exactly one cp3XYt wheel, or a named failure"
mkdir -p "${_work}/one" "${_work}/two" "${_work}/none"
: > "${_work}/one/x-1-cp314-cp314t-linux_x86_64.whl"; : > "${_work}/one/x-1-cp314-cp314-linux_x86_64.whl"
: > "${_work}/two/x-1-cp314-cp314t-linux_x86_64.whl"; : > "${_work}/two/y-1-cp314-cp314t-linux_x86_64.whl"
t_assert_eq "${_work}/one/x-1-cp314-cp314t-linux_x86_64.whl" "$(ft_built_wheel "${_work}/one")" "the GIL wheel beside it is ignored"
t_assert_fails ft_built_wheel "${_work}/two"
t_assert_fails ft_built_wheel "${_work}/none"

t_case "the GIL wheel collection never picks up a twin left in a build tree"
eval "$(t_fn_src "${ORT_BUILD}/lib/common.sh" collect_wheels_from_tree)" || exit 1
info() { :; }
mkdir -p "${_work}/tree/dist" "${_work}/out"
: > "${_work}/tree/dist/onnxruntime-1.30.0-cp314-cp314-linux_x86_64.whl"
: > "${_work}/tree/dist/onnxruntime-1.30.0-cp314-cp314t-linux_x86_64.whl"
collect_wheels_from_tree "${_work}/tree" "${_work}/out" >/dev/null
t_assert_eq "onnxruntime-1.30.0-cp314-cp314-linux_x86_64.whl" "$(ls "${_work}/out/wheels")"

t_case "wiring: every RUN that builds or stores a twin mounts the library and the helper, each per file"
t_assert_eq 6 "$(grep -c -e '--mount=type=bind,source=linux/scripts/03-media/free-threaded-wheels.sh,target=/opt/scripts/03-media/free-threaded-wheels.sh,readonly' "${MEDIA}")" "ORT cpu, ORT gpu, TVM, app-wheelhouse, PyAV, final"
t_assert_eq 6 "$(grep -c -e '--mount=type=bind,source=linux/scripts/02-toolchain/python/free-threaded-wheel.py,target=/opt/scripts/03-media/free-threaded-wheel.py,readonly' "${MEDIA}")"
t_assert_eq 6 "$(grep -c -e '--mount=type=bind,source=linux/scripts/03-media/free-threaded-twins.txt,target=/opt/scripts/03-media/free-threaded-twins.txt,readonly' "${MEDIA}")" \
  "the twin table beside the library in each of them"
t_assert_eq "" "$(compgen -G "${SCRIPTS}/03-media/core/*free-threaded*"; compgen -G "${SCRIPTS}/01-core/*free-threaded*")" "never under core/, which re-keys every media RUN"

t_case "wiring: each build asks the table for its own package and stores into the dir the final stage collects"
_onnx_fn="$(t_fn_src "${ORT_BUILD}/lib/common.sh" onnx_build_free_threaded_wheel)" || exit 1
t_assert_contains "${_onnx_fn}" 'ft_twin_start onnxruntime '
t_assert_contains "${_onnx_fn}" '"${output_dir}/wheels-cp314t"'
t_assert_contains "$(t_fn_src "${SCRIPTS}/03-media/build/pyav/build-pyav.sh" pyav_build_free_threaded_wheel)" 'ft_twin_start av '
t_assert_contains "$(t_fn_src "${SCRIPTS}/05-frameworks/tvm-python.sh" _tvm_stage_ffi_wheel_free_threaded)" 'ft_twin_start apache-tvm-ffi '
t_assert_contains "$(t_fn_src "${SCRIPTS}/05-frameworks/torch/build-app-wheelhouse.sh" _iree_package_free_threaded_wheels)" 'ft_twin_wanted "iree-base-${_proj}"'
_ort_steps=0
for _s in "${ORT_BUILD}"/30-build-native*.sh; do
  _ort_steps=$((_ort_steps + 1))
  t_assert_eq 1 "$(grep -c -e '^onnx_build_free_threaded_wheel ' "${_s}")" "${_s##*/} builds its ORT flavour's twin"
done
t_assert_eq 3 "${_ort_steps}" "the CPU build and both GPU flavours"
t_assert_contains "$(cat "${MEDIA}")" "COPY --link --from=pyav /opt/pyav/wheels-cp314t /opt/wheels-cp314t"
t_assert_contains "$(cat "${MEDIA}")" "COPY --link --from=tvm /opt/tvm/wheels-cp314t /opt/tvm-wheels-cp314t"
t_assert_contains "$(cat "${MEDIA}")" "COPY --link --from=app-wheelhouse /opt/app-wheels-cp314t /opt/app-wheels-cp314t"

t_case "wiring: the GIL store is verified before the twins are touched, and only it is installed"
_line() { grep -n -e "$1" "${MEDIA}" | cut -d: -f1 | head -n 1; }
t_assert_ok test "$(_line 'runtime/verify-wheels.sh &&')" -lt "$(_line 'runtime/repair-wheels.sh --free-threaded &&')"
t_assert_ok test "$(_line 'runtime/repair-wheels.sh --free-threaded &&')" -lt "$(_line 'runtime/verify-wheels.sh --free-threaded &&')"
t_assert_ok test "$(_line 'runtime/verify-wheels.sh --free-threaded &&')" -lt "$(_line 'runtime/free-threaded-store.sh &&')"
t_assert_ok test "$(_line 'runtime/free-threaded-store.sh &&')" -lt "$(_line 'uv pip install --no-deps /opt/wheels/\*\.whl')"
t_assert_eq 0 "$(grep -c -e 'uv pip install.*wheels-cp314t' "${MEDIA}")" "no GIL venv ever installs a twin"

t_summary
