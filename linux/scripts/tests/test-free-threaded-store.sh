#!/usr/bin/env bash
# The two wheel stores stay apart: ABI-exact verify, the twins' own ORT manifest, the store record, and the runtime smoke's gate; see docs/consumer-image-contract.md#the-free-threaded-wheels
set -u
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${TESTS_DIR}/test-harness.sh"
SCRIPTS="$(cd "${TESTS_DIR}/.." && pwd)"
RT="${SCRIPTS}/03-media/runtime"
SMOKE="${SCRIPTS}/06-packaging/smoke-runtime-image.sh"

t_skip_unless "a POSIX python3 (the fixtures are zip files it reads by path)" t_posix_python

_work="$(mktemp -d)"; trap 'rm -rf "${_work}"' EXIT
mkdir -p "${_work}/bin" "${_work}/ft/bin"
# Two 3.14 interpreters for verify-wheels.sh: python is the GIL one, python3.14t says it is free-threaded; both lend python3 their scans.
for _py in "${_work}/bin/python:" "${_work}/ft/bin/python3.14t:t"; do
  cat > "${_py%:*}" <<FAKE
#!/usr/bin/env bash
case "\$*" in
  *version_info.major*) echo 3 ;;
  *version_info.minor*) echo 14 ;;
  *Py_GIL_DISABLED*) echo "${_py##*:}" ;;
  *) exec python3 "\$@" ;;
esac
FAKE
  chmod +x "${_py%:*}"
done

# _whl <dir> <name> <member>...: a wheel holding empty members.
_whl() { t_zip "$1/$2" "${@:3}"; }
GIL_SO=.cpython-314-x86_64-linux-gnu.so
FT_SO=.cpython-314t-x86_64-linux-gnu.so
# _verify <gil dir> <ft dir> [--free-threaded]: verify-wheels.sh against the two fixture stores.
_verify() {
  env PATH="${_work}/bin:${PATH}" WHEELS_DIR="$1" FT_WHEELS_DIR="$2" PYTHON_FT_PREFIX="${FT_PREFIX:-${_work}/ft}" TARGET_ARCH=amd64 \
    bash "${RT}/verify-wheels.sh" "${@:3}"
}

_g="${_work}/gil"; _f="${_work}/ft-store"
_whl "${_g}" av-19.0.1-cp314-cp314-linux_x86_64.whl "av/codec/codec${GIL_SO}"
_whl "${_g}" apache_tvm-0.27.0-py3-none-linux_x86_64.whl tvm/libtvm.so
_whl "${_g}" iree_base_runtime-3.12.0-cp312-abi3-linux_x86_64.whl iree/_runtime.abi3.so
_whl "${_f}" av-19.0.1-cp314-cp314t-linux_x86_64.whl "av/codec/codec${FT_SO}"

t_case "the GIL store: cp314, abi3 and py3 wheels pass, as before the twins"
t_assert_ok _verify "${_g}" "${_f}"

t_case "the GIL store: a cp314t twin dropped into it fails loudly and names the twin store"
cp "${_f}/av-19.0.1-cp314-cp314t-linux_x86_64.whl" "${_g}/"
t_assert_fails _verify "${_g}" "${_f}"
t_assert_contains "$(_verify "${_g}" "${_f}" 2>&1)" "a cp3XYt twin belongs in ${_f}"
rm -f "${_g}/av-19.0.1-cp314-cp314t-linux_x86_64.whl"

t_case "the GIL store: a cp314 name over a free-threaded module fails; a foreign arch stays advisory"
_whl "${_work}/gil2" av-19.0.1-cp314-cp314-linux_x86_64.whl "av/codec/codec${FT_SO}"
t_assert_fails _verify "${_work}/gil2" "${_f}"
t_assert_contains "$(_verify "${_work}/gil2" "${_f}" 2>&1)" "carry an extension of the other threading ABI"
_whl "${_work}/gil3" av-19.0.1-cp314-cp314-linux_x86_64.whl av/codec/codec.cpython-314-aarch64-linux-gnu.so
t_assert_ok _verify "${_work}/gil3" "${_f}"
WHEEL_SOABI_STRICT=1 t_assert_fails _verify "${_work}/gil3" "${_f}"

t_case "the twin store: only cp314-cp314t wheels with free-threaded modules of this arch pass"
t_assert_ok _verify "${_g}" "${_f}" --free-threaded
for _bad in "av-19.0.1-cp314-cp314-linux_x86_64.whl:av/codec/codec${GIL_SO}" "apache_tvm-0.27.0-py3-none-linux_x86_64.whl:tvm/libtvm.so" \
            "iree_base_runtime-3.12.0-cp312-abi3-linux_x86_64.whl:iree/_runtime.abi3.so" "gilmod-1-cp314-cp314t-linux_x86_64.whl:m/x${GIL_SO}" \
            "arm-1-cp314-cp314t-linux_x86_64.whl:m/x.cpython-314t-aarch64-linux-gnu.so" "abi-1-cp314-cp314t-linux_x86_64.whl:m/x.abi3.so"; do
  rm -rf "${_work}/bad"; _whl "${_work}/bad" "${_bad%%:*}" "${_bad#*:}"
  t_assert_fails _verify "${_g}" "${_work}/bad" --free-threaded
done
t_assert_eq 2 "$(t_rc _verify "${_g}" "${_f}" --free)" "an unknown flag is a usage error"
t_assert_contains "$(FT_PREFIX="${_work}/none" _verify "${_g}" "${_f}" --free-threaded 2>&1)" "no free-threaded interpreter under ${_work}/none/bin"

t_case "collect-artifacts.sh: the twins keep an ORT manifest of their own, from their own dir"
eval "$(t_fn_src "${RT}/collect-artifacts.sh" write_ort_wheel_manifest)" || exit 1
_p="${_work}/pfx"
_whl "${_p}/wheels" onnxruntime_dnnl-1.30.0-cp314-cp314-linux_x86_64.whl onnxruntime/capi/onnxruntime_pybind11_state.so
_whl "${_p}/wheels-cp314t" onnxruntime_dnnl-1.30.0-cp314-cp314t-linux_x86_64.whl onnxruntime/capi/onnxruntime_pybind11_state.so
ONNXRUNTIME_VERSION=v1.30.0 write_ort_wheel_manifest "${_p}" >/dev/null
ONNXRUNTIME_VERSION=v1.30.0 write_ort_wheel_manifest "${_p}" "" wheels-cp314t ort-provenance-cp314t.sha256 >/dev/null
t_assert_contains "$(cat "${_p}/ort-provenance.sha256")" "onnxruntime_dnnl-1.30.0-cp314-cp314-linux_x86_64.whl!onnxruntime/capi/onnxruntime_pybind11_state.so"
t_assert_eq 0 "$(grep -c cp314t "${_p}/ort-provenance.sha256")" "the GIL manifest names no twin"
t_assert_contains "$(cat "${_p}/ort-provenance-cp314t.sha256")" "onnxruntime_dnnl-1.30.0-cp314-cp314t-linux_x86_64.whl!onnxruntime/capi/onnxruntime_pybind11_state.so"
t_assert_eq 1 "$(wc -l < "${_p}/ort-provenance-cp314t.sha256" | tr -d ' ')" "and the twins' names only it"
_coll="$(cat "${RT}/collect-artifacts.sh")"
for _d in onnxruntime-cpu/wheels onnxruntime-gpu/wheels app tvm; do
  case "${_d}" in onnxruntime-*) _d="/usr/local/lib/${_d}-cp314t" ;; *) _d="/opt/${_d}-wheels-cp314t" ;; esac
  t_assert_contains "${_coll}" "  ${_d}"$'\n' "${_d} is collected into the twin store"
done
t_assert_contains "${_coll}" 'collect_component_wheels "${ft_source_dir}" "${FT_WHEELS_DIR}"'
for _pfx in cpu gpu; do
  t_assert_contains "${_coll}" "write_ort_wheel_manifest /usr/local/lib/onnxruntime-${_pfx} \"\" wheels-cp314t ort-provenance-cp314t.sha256"$'\n'
done

t_case "repair-wheels.sh: --free-threaded repairs the twin store against the twins' manifest only"
_rep="$(cat "${RT}/repair-wheels.sh")"
t_assert_contains "${_rep}" '--free-threaded) FREE_THREADED=1; WHEELS_DIR="${FT_WHEELS_DIR}" ;;'
t_assert_contains "${_rep}" '_ORT_MANIFESTS=(/usr/local/lib/onnxruntime-*/ort-provenance-cp314t.sha256)'
t_assert_eq 2 "$(t_rc env WHEELS_DIR="${_g}" bash "${RT}/repair-wheels.sh" --bogus)"

# The store script without its main call, beside its siblings, over fixture stores; cross_build_is_active is stubbed after it.
mkdir -p "${_work}/tree/03-media/runtime"
cp "${RT}/media-env.sh" "${_work}/tree/03-media/runtime/"
cp "${SCRIPTS}/03-media/free-threaded-wheels.sh" "${_work}/tree/03-media/"
sed '$d' "${RT}/free-threaded-store.sh" > "${_work}/tree/03-media/runtime/free-threaded-store.sh"
cp -r "${_work}/tree" "${_work}/notable"
cp "${SCRIPTS}/03-media/free-threaded-twins.txt" "${_work}/tree/03-media/"
_store() {
  local mode="$1"; shift
  env WHEELS_DIR="${_work}/s-gil" FT_WHEELS_DIR="${_work}/s-ft" TARGET_ARCH=amd64 STORE_MODE="${mode}" \
    bash -c 'source "$1"; shift; cross_build_is_active() { [ "${STORE_MODE}" = cross ]; }; "$@"' _ "${_work}/tree/03-media/runtime/free-threaded-store.sh" "$@"
}
_stores() {
  rm -rf "${_work}/s-gil" "${_work}/s-ft"; mkdir -p "${_work}/s-gil" "${_work}/s-ft"
  local w
  for w in $1; do : > "${_work}/s-gil/${w}"; done
  for w in $2; do : > "${_work}/s-ft/${w}"; done
}
_GIL="onnxruntime_dnnl-1.30.0-cp314-cp314-linux_x86_64.whl onnxruntime_genai-0.17.0-cp314-cp314-linux_x86_64.whl av-19.0.1-cp314-cp314-linux_x86_64.whl apache_tvm-0.27.0-py3-none-linux_x86_64.whl ai_edge_litert-2.2.0-cp314-cp314-linux_x86_64.whl"
_FT="onnxruntime_dnnl-1.30.0-cp314-cp314t-linux_x86_64.whl av-19.0.1-cp314-cp314t-linux_x86_64.whl"

t_case "the store: a native build holds a twin of every GIL wheel whose verdict is twin, and nothing else"
_stores "${_GIL}" "${_FT}"
t_assert_ok _store native ft_store_check_set native
_stores "${_GIL}" "onnxruntime_dnnl-1.30.0-cp314-cp314t-linux_x86_64.whl"
t_assert_fails _store native ft_store_check_set native
t_assert_contains "$(_store native ft_store_check_set native 2>&1)" "av ships a GIL wheel in ${_work}/s-gil and its table verdict is twin, but ${_work}/s-ft has no cp314t twin of it"
_stores "${_GIL}" "${_FT} onnxruntime_genai-0.17.0-cp314-cp314t-linux_x86_64.whl"
t_assert_contains "$(_store native ft_store_check_set native 2>&1)" "holds onnxruntime_genai, which is no twin of a GIL wheel this native build ships"

t_case "the store: native or cross, a GIL wheel the table never classified is refused"
for _m in native cross; do
  _stores "${_GIL} pillow-12.0.0-cp314-cp314-linux_x86_64.whl" "${_FT}"
  t_assert_contains "$(_store "${_m}" ft_store_check_set "${_m}" 2>&1)" "ships pillow, which ft_wheel_table does not classify" "${_m}"
done

t_case "the store: a cross build holds the same twins as a native one (CON75, CON79 1b)"
_k() { FT_TORCH_TWIN="$1" "${@:2}"; }
_RV_GIL="av-19.0.1-cp314-cp314-linux_riscv64.whl apache_tvm_ffi-0.1.14-cp314-cp314-linux_riscv64.whl iree_base_runtime-3.12.0-cp314-cp314-linux_riscv64.whl onnxruntime-1.30.0-cp314-cp314-linux_riscv64.whl onnxruntime_genai-0.17.0-cp314-cp314-linux_riscv64.whl torch-2.14.1-cp314-cp314-linux_riscv64.whl torchvision-0.29.1-cp314-cp314-linux_riscv64.whl"
_RV_FT="av-19.0.1-cp314-cp314t-linux_riscv64.whl apache_tvm_ffi-0.1.14-cp314-cp314t-linux_riscv64.whl iree_base_runtime-3.12.0-cp314-cp314t-linux_riscv64.whl onnxruntime-1.30.0-cp314-cp314t-linux_riscv64.whl"
_stores "${_RV_GIL}" "${_RV_FT} torch-2.14.1-cp314-cp314t-linux_riscv64.whl"
t_assert_ok _k 1 _store cross ft_store_check_set cross
_stores "${_RV_GIL}" "${_RV_FT}"
t_assert_contains "$(FT_TORCH_TWIN=1 _store cross ft_store_check_set cross 2>&1)" "torch ships a GIL wheel in ${_work}/s-gil and its table verdict is twin, but ${_work}/s-ft has no cp314t twin of it"
t_assert_ok _k 0 _store cross ft_store_check_set cross
_stores "${_RV_GIL}" "$(printf '%s\n' ${_RV_FT} | grep -v '^av-')"
t_assert_contains "$(FT_TORCH_TWIN=0 _store cross ft_store_check_set cross 2>&1)" "av ships a GIL wheel in ${_work}/s-gil and its table verdict is twin, but ${_work}/s-ft has no cp314t twin of it"
_stores "${_RV_GIL}" ""
t_assert_fails _k 0 _store cross ft_store_check_set cross

t_case "the store's record: the mode, every twin, and one reasoned line per package without one"
_stores "${_GIL}" "${_FT}"
_store native ft_store_write_record native >/dev/null
_rec="$(cat "${_work}/s-ft/free-threaded-store.txt")"
t_assert_contains "${_rec}" "mode=native"$'\n'"arch=amd64"
t_assert_contains "${_rec}" "twin av-19.0.1-cp314-cp314t-linux_x86_64.whl"
t_assert_contains "${_rec}" "skip onnxruntime-genai gil (ONNXRUNTIME_GENAI_VERSION="
t_assert_contains "${_rec}" "skip apache-tvm none (TVM_REF="
t_assert_eq 0 "$(grep -c '^skip onnxruntime ' "${_work}/s-ft/free-threaded-store.txt")" "a twin package is no skip"

t_case "the store's record: a want line per twin family it holds; a knob row's is there while its knob is 1, a skip line while it is 0"
_stores "${_RV_GIL}" "${_RV_FT} torch-2.14.1-cp314-cp314t-linux_riscv64.whl"
FT_TORCH_TWIN=1 _store cross ft_store_write_record cross >/dev/null
_rec="$(cat "${_work}/s-ft/free-threaded-store.txt")"
t_assert_contains "${_rec}" "mode=cross"
t_assert_contains "${_rec}" "twin torch-2.14.1-cp314-cp314t-linux_riscv64.whl"
t_assert_eq "want apache-tvm-ffi
want av
want iree-base-runtime
want onnxruntime
want torch" "$(grep '^want ' "${_work}/s-ft/free-threaded-store.txt")" "one line per family the chain shipped a GIL wheel of"
t_assert_eq 0 "$(grep -c -e '^skip torch ' -e '^want numpy' "${_work}/s-ft/free-threaded-store.txt")" "numpy ships no GIL wheel, so nothing wants its twin"
FT_TORCH_TWIN=0 _store cross ft_store_write_record cross >/dev/null
t_assert_contains "$(cat "${_work}/s-ft/free-threaded-store.txt")" "skip torch FT_TORCH_TWIN=0 (PYTORCH_VERSION="
t_assert_eq 0 "$(grep -c '^want torch' "${_work}/s-ft/free-threaded-store.txt")"

t_case "the store stops when the twin table is not beside the library, instead of recording no verdicts"
_out="$(env WHEELS_DIR="${_work}/s-gil" FT_WHEELS_DIR="${_work}/s-ft" bash -c 'source "$1"; echo SOURCED' _ "${_work}/notable/03-media/runtime/free-threaded-store.sh" 2>&1)"; _rc=$?
t_assert_eq 1 "${_rc}" "${_out}"
t_assert_contains "${_out}" "free-threaded-twins.txt is missing"
t_assert_eq "" "$(printf '%s\n' "${_out}" | grep -e SOURCED || true)"

t_case "the smoke: without the twin table beside the library every verdict is one BAD line"
mkdir -p "${_work}/smoke-notable/06-packaging" "${_work}/smoke-notable/03-media"
cp "${SCRIPTS}/06-packaging/check-free-threaded-wheels.sh" "${_work}/smoke-notable/06-packaging/"
cp "${SCRIPTS}/03-media/free-threaded-wheels.sh" "${_work}/smoke-notable/03-media/"
_out="$(bash -c 'source "$1"; ft_store_verdict "FTS ENV /opt/wheels-cp314t
FTS DONE"' _ "${_work}/smoke-notable/06-packaging/check-free-threaded-wheels.sh" 2>&1)"
t_assert_eq "BAD the twin table is not at ${_work}/smoke-notable/06-packaging/../03-media/free-threaded-twins.txt" "${_out}"

# shellcheck source=../06-packaging/check-free-threaded-wheels.sh
source "${SCRIPTS}/06-packaging/check-free-threaded-wheels.sh"
_P_NATIVE='FTS ENV /opt/wheels-cp314t
FTS RECORD mode=native
FTS RECORD want apache-tvm-ffi
FTS RECORD want av
FTS RECORD want iree-base-compiler
FTS RECORD want iree-base-runtime
FTS RECORD want onnxruntime
FTS GIL onnxruntime_dnnl
FTS GIL av
FTS GIL apache_tvm
FTS GIL apache_tvm_ffi
FTS GIL iree_base_runtime
FTS GIL iree_base_compiler
FTS GIL onnxruntime_genai
FTS WHEEL onnxruntime_dnnl-1.30.0-cp314-cp314t-linux_x86_64.whl
FTS PROVED onnxruntime_dnnl 1 compiled module(s) of onnxruntime_dnnl loaded on free-threaded 3.14.8; the GIL stayed disabled
FTS WHEEL av-19.0.1-cp314-cp314t-linux_x86_64.whl
FTS PROVED av 50 compiled module(s) of av loaded
FTS WHEEL apache_tvm_ffi-0.1.13-cp314-cp314t-linux_x86_64.whl
FTS PROVED apache_tvm_ffi 1 compiled module(s) of apache_tvm_ffi loaded
FTS WHEEL iree_base_runtime-3.12.0-cp314-cp314t-linux_x86_64.whl
FTS PROVED iree_base_runtime 1 compiled module(s) of iree_base_runtime loaded
FTS WHEEL iree_base_compiler-3.12.0-cp314-cp314t-linux_x86_64.whl
FTS PROVED iree_base_compiler 9 compiled module(s) of iree_base_compiler loaded
FTS DONE'
_bad() { ft_store_verdict "$1" | grep '^BAD' || true; }

t_case "the smoke: a native store with every twin of /opt/venv, each proved, is green"
t_assert_eq "" "$(_bad "${_P_NATIVE}")"
t_assert_contains "$(ft_store_verdict "${_P_NATIVE}")" "OK the store holds exactly the twin families of /opt/venv: apache-tvm-ffi av iree-base-compiler iree-base-runtime onnxruntime"

t_case "the smoke: a missing, an unproved, a stray and a GIL-tagged twin each fail"
t_assert_contains "$(_bad "$(printf '%s\n' "${_P_NATIVE}" | grep -v -e '^FTS WHEEL av-' -e '^FTS PROVED av ')")" "/opt/venv carries av, whose verdict is twin, and the store has no cp314t twin of it"
t_assert_contains "$(_bad "$(printf '%s\n' "${_P_NATIVE}" | sed 's/^FTS PROVED av .*/FTS UNPROVED av ERROR: the GIL was re-enabled/')")" "av-19.0.1-cp314-cp314t-linux_x86_64.whl is not proved on python3.14t: ERROR: the GIL was re-enabled"
t_assert_contains "$(_bad "${_P_NATIVE}"$'\n''FTS WHEEL onnxruntime_genai-0.17.0-cp314-cp314t-linux_x86_64.whl')" "onnxruntime_genai-0.17.0-cp314-cp314t-linux_x86_64.whl is no twin the table allows"
t_assert_contains "$(_bad "$(printf '%s\n' "${_P_NATIVE}" | sed 's/^FTS WHEEL av-19.0.1-cp314-cp314t-/FTS WHEEL av-19.0.1-cp314-cp314-/')")" "is not a cp3XY-cp3XYt wheel"

t_case "the smoke: a proved twin whose GIL package left /opt/venv makes the families differ"
t_assert_contains "$(_bad "$(printf '%s\n' "${_P_NATIVE}" | grep -v -e '^FTS GIL apache_tvm_ffi$')")" \
  "the store holds the families [apache-tvm-ffi av iree-base-compiler iree-base-runtime onnxruntime], /opt/venv wants [av iree-base-compiler iree-base-runtime onnxruntime]"

t_case "the smoke: a GPU store carries both ORT twins, and the installed flavour's own twin is required"
_gpu="$(printf '%s\n' "${_P_NATIVE}" | sed 's/^FTS GIL onnxruntime_dnnl$/FTS GIL onnxruntime_gpu/')"
t_assert_contains "$(_bad "${_gpu}")" "/opt/venv carries onnxruntime_gpu, whose verdict is twin, and the store has no cp314t twin of it"
_gpu="${_gpu/FTS DONE/FTS WHEEL onnxruntime_gpu-1.30.0-cp314-cp314t-linux_x86_64.whl
FTS PROVED onnxruntime_gpu 1 compiled module(s)
FTS DONE}"
t_assert_eq "" "$(_bad "${_gpu}")"

_P_RV='FTS ENV /opt/wheels-cp314t
FTS RECORD mode=cross
FTS RECORD arch=riscv64
FTS RECORD want apache-tvm-ffi
FTS RECORD want av
FTS RECORD want iree-base-runtime
FTS RECORD want onnxruntime
FTS RECORD want torch
FTS GIL iree_base_compiler
FTS GIL av
FTS GIL apache_tvm_ffi
FTS GIL iree_base_runtime
FTS GIL onnxruntime
FTS GIL torch
FTS GIL torchvision
FTS GIL numpy
FTS WHEEL av-19.0.1-cp314-cp314t-linux_riscv64.whl
FTS PROVED av 50 compiled module(s) of av loaded
FTS WHEEL apache_tvm_ffi-0.1.14-cp314-cp314t-linux_riscv64.whl
FTS PROVED apache_tvm_ffi 1 compiled module(s) of apache_tvm_ffi loaded
FTS WHEEL iree_base_runtime-3.12.0-cp314-cp314t-linux_riscv64.whl
FTS PROVED iree_base_runtime 1 compiled module(s) of iree_base_runtime loaded
FTS WHEEL onnxruntime-1.30.0-cp314-cp314t-linux_riscv64.whl
FTS PROVED onnxruntime 1 compiled module(s) of onnxruntime loaded
FTS WHEEL torch-2.14.1-cp314-cp314t-linux_riscv64.whl
FTS PROVED torch 9 compiled module(s) of torch loaded
FTS DONE'

t_case "the smoke: a cross-built arch is held to the table like a native one, its knob twins by the record"
t_assert_eq "" "$(_bad "${_P_RV}")"
t_assert_contains "$(ft_store_verdict "${_P_RV}")" "OK the store records a cross build; its twins are held to the table as on any arch"
t_assert_contains "$(ft_store_verdict "${_P_RV}")" "OK the store holds exactly the twin families of /opt/venv: apache-tvm-ffi av iree-base-runtime onnxruntime torch"
t_assert_contains "$(_bad 'FTS ENV /opt/wheels-cp314t
FTS RECORD mode=cross
FTS RECORD want av
FTS GIL av
FTS DONE')" "/opt/venv carries av, whose verdict is twin, and the store has no cp314t twin of it"
t_assert_contains "$(ft_store_verdict "${_P_RV}")" "OK iree_base_compiler declares free-threading, but the record wants no twin of it" "PyPI's compiler on a cross arch, whose chain builds the runtime only"
t_assert_contains "$(_bad "$(printf '%s\n' "${_P_RV}" | grep -v -e '^FTS WHEEL torch-' -e '^FTS PROVED torch ')")" "/opt/venv carries torch, whose verdict is twin, and the store has no cp314t twin of it"
_nowant="$(printf '%s\n' "${_P_RV}" | grep -v -e '^FTS RECORD want torch$')"
t_assert_contains "$(_bad "${_nowant}")" "torch-2.14.1-cp314-cp314t-linux_riscv64.whl is no twin the table allows here (verdict twin:FT_TORCH_TWIN)"
t_assert_eq "" "$(_bad "$(printf '%s\n' "${_nowant}" | grep -v -e '^FTS WHEEL torch-' -e '^FTS PROVED torch ')")" "knob off: PyPI's torch in /opt/venv wants no twin, as on amd64"

t_case "the smoke: a missing store, record or probe end is red"
t_assert_contains "$(_bad 'FTS NOSTORE
FTS DONE')" "/opt/wheels-cp314t is missing"
t_assert_contains "$(_bad 'FTS NORECORD
FTS DONE')" "has no free-threaded-store.txt"
t_assert_contains "$(_bad 'FTS RECORD mode=native')" "the in-image probe never finished"
t_assert_contains "$(_bad 'FTS RECORD mode=sideways
FTS DONE')" "records mode 'sideways'"

t_case "the smoke: the image names the store in PYTHON_WHEELS_CP314T, the uv reconcile's pointer, on every arch"
t_assert_contains "$(ft_store_verdict "${_P_NATIVE}")" "OK PYTHON_WHEELS_CP314T names /opt/wheels-cp314t"
for _env in '<unset>' /opt/wheels '/opt/wheels-cp314t/'; do
  t_assert_contains "$(_bad "${_P_NATIVE/FTS ENV \/opt\/wheels-cp314t/FTS ENV ${_env}}")" "PYTHON_WHEELS_CP314T is '${_env}', not /opt/wheels-cp314t" "${_env}"
done
t_assert_contains "$(_bad 'FTS RECORD mode=cross
FTS DONE')" "PYTHON_WHEELS_CP314T is '<no probe line>'"
t_assert_contains "$(ft_store_probe_script)" "printf 'FTS ENV %s\\n' \"\${PYTHON_WHEELS_CP314T:-<unset>}\""

t_case "the smoke: its probe is valid bash, and main() runs the gate on every arch"
t_assert_ok bash -n <(ft_store_probe_script)
t_assert_contains "$(sed -n '/^main()/,/^}/p' "${SMOKE}")" 'check_free_threaded_wheels "${image_tag}" "${target_arch}"'
t_assert_contains "$(cat "${SMOKE}")" 'source "${_SCRIPT_DIR}/check-free-threaded-wheels.sh"'

t_summary
