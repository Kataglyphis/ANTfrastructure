#!/usr/bin/env bash
# uv_reconcile_chain_ort, uv_sync_project's call of it and stage_chain_ort_wheels, on a real venv with the real census.
# NOT covered: real uv (chain-ort-fixtures.py stands in), a real ORT wheel. docs/python-ci.md#trap-3--onnx-runtime-comes-from-the-chain-not-pypi
set -u
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${TESTS_DIR}/test-harness.sh"
UV_SH="${TESTS_DIR}/../01-core/python_uv.sh"
STV_SH="${TESTS_DIR}/../06-packaging/setup-torch-venv.sh"
CENSUS="${TESTS_DIR}/../03-media/runtime/ort-venv-census.py"
FIX="${TESTS_DIR}/chain-ort-fixtures.py"
_PY="${PREFLIGHT_PYTHON:-python3}"

_work="$(mktemp -d)"; trap 'rm -rf "${_work}"' EXIT
VENV="${_work}/venv"
"${_PY}" -m venv --without-pip "${VENV}" >/dev/null 2>&1 || { echo "FAIL: ${_PY} -m venv failed" >&2; exit 1; }
VPY="${VENV}/bin/python"; [ -x "${VPY}" ] || VPY="${VENV}/Scripts/python.exe"
SITE="$("${VPY}" "${FIX}" site)"
STORE="${_work}/store"; FEED="${_work}/feed"; LOG="${_work}/uv.log"
mkdir -p "${_work}/bin" "${_work}/proj"
printf '#!/usr/bin/env bash\nexec %q %q uv "$@"\n' "${_PY}" "${FIX}" > "${_work}/bin/uv"
chmod +x "${_work}/bin/uv"

# A venv the way `uv sync` of OrchestrANT's lock leaves it: three PyPI ORT dists in one site-packages.
_pypi_venv() {
  "${VPY}" "${FIX}" reset "${SITE}" "${STORE}" "${FEED}"
  : > "${LOG}"
  "${VPY}" "${FIX}" pypi "${SITE}" onnxruntime 1.27.0 onnxruntime "pypi core"
  "${VPY}" "${FIX}" pypi "${SITE}" onnxruntime-gpu 1.27.0 onnxruntime "pypi gpu"
  "${VPY}" "${FIX}" pypi "${SITE}" onnxruntime-genai 0.14.0 onnxruntime_genai "pypi genai"
  "${VPY}" "${FIX}" wheel "${STORE}" onnxruntime 1.30.0 onnxruntime "chain core"
  "${VPY}" "${FIX}" wheel "${STORE}" onnxruntime-genai 0.15.2 onnxruntime_genai "chain genai"
  "${VPY}" "${FIX}" wheel "${STORE}" tvm 0.25.0 tvm "not ort"
}

# The census the image runs, against the venv: rc 0 = every ORT dist is a chain wheel.
_census_ok() { "${VPY}" -I "${CENSUS}" --check --store "${STORE}" >/dev/null 2>&1; }

# uv_reconcile_chain_ort in its own bash, the way a lane sources python_uv.sh; the env prefix is the fixture.
_reconcile() {
  local body
  body="$(printf 'set -uo pipefail\nsource %q\nrc=0; uv_reconcile_chain_ort %q || rc=$?\n' "${UV_SH}" "${VENV}")"
  body+=$'\nprintf "rc=%s NO_SYNC=%s\\n" "${rc}" "${UV_NO_SYNC-<unset>}"'
  PATH="${_work}/bin:${PATH}" STUB_UV_LOG="${LOG}" bash -c "${body}" 2>&1
}

t_case "in our image, PyPI onnxruntime + -gpu + -genai are replaced by the chain wheels and proven"
_pypi_venv
_out="$(ORT_CHAIN_WHEEL_DIR="${STORE}" _reconcile)"
t_assert_contains "${_out}" "rc=0 NO_SYNC=1" "a proven venv holds uv run off the lock"
t_assert_contains "$(grep -e 'pip uninstall --python ' "${LOG}")" " onnxruntime onnxruntime-genai onnxruntime-gpu" \
  "every ORT dist the census lists is uninstalled, the overlapping -gpu included"
t_assert_contains "$(grep -e 'pip install' "${LOG}")" "--no-index --no-deps --force-reinstall " \
  "the chain wheels install offline, without their PyPI dependency metadata"
t_assert_contains "$(grep -e 'pip install' "${LOG}")" "/store/onnxruntime-1.30.0-" "the chain core wheel"
t_assert_contains "$(grep -e 'pip install' "${LOG}")" "/store/onnxruntime_genai-0.15.2-" "the chain GenAI wheel comes along"
t_assert_eq "" "$(grep -e 'tvm-' "${LOG}" || true)" "only ORT wheels are taken from the store"
t_assert_ok _census_ok
t_assert_contains "${_out}" "ORT-CENSUS PASS" "the census verdict is printed"

t_case "outside our images the venv is left as uv resolved it, with a loud notice"
_pypi_venv
_out="$(ORT_CHAIN_WHEEL_DIR='' _reconcile)"
t_assert_contains "${_out}" "rc=0 NO_SYNC=<unset>" "outside the images nothing fails and nothing is held"
t_assert_contains "${_out}" "NOTICE: ${VENV} runs ONNX Runtime from outside the chain: onnxruntime onnxruntime-genai onnxruntime-gpu"
t_assert_eq "" "$(grep -e 'pip ' "${LOG}" || true)" "uv is not asked to change anything"
t_assert_fails _census_ok

t_case "a uv that leaves a PyPI dist behind fails the sync (the census, not uv, decides)"
_pypi_venv
_out="$(ORT_CHAIN_WHEEL_DIR="${STORE}" STUB_UV_KEEP=1 _reconcile)"
t_assert_contains "${_out}" "rc=1 NO_SYNC=<unset>"
t_assert_contains "${_out}" "still carries a non-chain ONNX Runtime" "the census findings are the error"
t_assert_contains "${_out}" "onnxruntime-gpu 1.27.0" "the leftover is named"

t_case "chain wheels that fit the ABI tag but do not import in this venv fail the sync"
_pypi_venv
"${VPY}" "${FIX}" reset "${STORE}"
"${VPY}" "${FIX}" wheel "${STORE}" onnxruntime 1.30.0 onnxruntime broken
_out="$(ORT_CHAIN_WHEEL_DIR="${STORE}" _reconcile)"
t_assert_contains "${_out}" "rc=1 NO_SYNC=<unset>" "the byte census passes; only the import shows the venv cannot load it"
t_assert_contains "${_out}" "does not import in ${VENV}"
t_assert_contains "${_out}" "built for another interpreter" "the import error is shown"

# A store wheel renamed to another ABI tag: $1 = its name-version prefix, $2 = the tag pair.
_retag() {
  local f
  f="$(compgen -G "${STORE}/$1-*.whl")"
  mv "${f}" "${STORE}/$1-$2-${f##*-}"
}

t_case "chain wheels for another ABI tag (a cp313 leg against cp314 wheels) fail before the venv is touched"
_pypi_venv
_retag onnxruntime-1.30.0 cp399-cp399
"${VPY}" "${FIX}" wheel "${STORE}" onnxruntime-extensions 0.14.0 onnxruntime_extensions "chain ext"
_retag onnxruntime_extensions-0.14.0 cp39-abi3
_out="$(ORT_CHAIN_WHEEL_DIR="${STORE}" _reconcile)"
t_assert_contains "${_out}" "rc=1 NO_SYNC=<unset>" "uv would install a path wheel of another cp tag without complaint"
t_assert_contains "${_out}" "chain wheels are built for the image interpreter: onnxruntime-1.30.0-cp399-cp399-" "the misfit wheel is named"
t_assert_eq "" "$(printf '%s\n' "${_out}" | grep -e 'image interpreter:.*onnxruntime_extensions' || true)" \
  "an abi3 wheel fits every interpreter"
t_assert_contains "${_out}" "list it in EXPERIMENTAL_PYTHON_VERSIONS" "the remedy is part of the error"
t_assert_eq "" "$(grep -e 'pip ' "${LOG}" || true)" "no uninstall without a wheel this venv can load"

t_case "an ONNX Runtime import package no distribution owns fails inside our images, not outside"
"${VPY}" "${FIX}" reset "${SITE}"; : > "${LOG}"
mkdir -p "${SITE}/onnxruntime"; : > "${SITE}/onnxruntime/__init__.py"
_out="$(ORT_CHAIN_WHEEL_DIR="${STORE}" _reconcile)"
t_assert_contains "${_out}" "rc=1 NO_SYNC=<unset>" "an empty purge list is not proof of no ORT"
t_assert_contains "${_out}" "imports ONNX Runtime with no distribution to purge (onnxruntime)"
t_assert_contains "${_out}" "the onnxruntime import package has 0 owners" "the census findings are the evidence"
_out="$(ORT_CHAIN_WHEEL_DIR='' _reconcile)"
t_assert_contains "${_out}" "rc=0 NO_SYNC=<unset>" "outside our images nothing fails"

t_case "a store without an onnxruntime wheel fails before the venv is touched"
_pypi_venv
"${VPY}" "${FIX}" reset "${STORE}"
_out="$(ORT_CHAIN_WHEEL_DIR="${STORE}" _reconcile)"
t_assert_contains "${_out}" "rc=1"
t_assert_contains "${_out}" "holds no onnxruntime wheel"
t_assert_eq "" "$(grep -e 'pip ' "${LOG}" || true)" "no uninstall without a replacement"

t_case "a declared but missing store is an image regression, not the outside case"
_pypi_venv
_out="$(ORT_CHAIN_WHEEL_DIR="${_work}/no-such-store" _reconcile)"
t_assert_contains "${_out}" "rc=1"
t_assert_contains "${_out}" "need the store ${_work}/no-such-store"

t_case "a venv without ONNX Runtime is untouched and releases only this module's own hold"
"${VPY}" "${FIX}" reset "${SITE}"; : > "${LOG}"
_out="$(ORT_CHAIN_WHEEL_DIR="${STORE}" _reconcile)"
t_assert_contains "${_out}" "rc=0 NO_SYNC=<unset>"
t_assert_eq "" "$(cat "${LOG}")" "nothing to replace, uv not called"
_out="$(ORT_CHAIN_WHEEL_DIR="${STORE}" UV_NO_SYNC=1 _reconcile)"
t_assert_contains "${_out}" "rc=0 NO_SYNC=1" "a caller's own UV_NO_SYNC is never unset"
_pypi_venv
_body="$(printf 'set -uo pipefail\nsource %q\nuv_reconcile_chain_ort %q >/dev/null 2>&1\n%q %q reset %q\nuv_reconcile_chain_ort %q >/dev/null 2>&1\n' \
  "${UV_SH}" "${VENV}" "${VPY}" "${FIX}" "${SITE}" "${VENV}")"
_out="$(ORT_CHAIN_WHEEL_DIR="${STORE}" PATH="${_work}/bin:${PATH}" STUB_UV_LOG="${LOG}" bash -c "${_body}"$'\nprintf "NO_SYNC=%s\\n" "${UV_NO_SYNC-<unset>}"' 2>&1)"
t_assert_contains "${_out}" "NO_SYNC=<unset>" "the hold taken for one venv is released when the next has no ORT"

t_case "the image's own python_uv.sh finds the census, in the layout Dockerfile.torch (the ORT_CHAIN_WHEEL_DIR image) COPYs"
_torch_df="${TESTS_DIR}/../../Dockerfile.torch"
_core="$(sed -n 's|^COPY [^/]* linux/scripts/01-core/ /\(.*\)/$|\1|p' "${_torch_df}")"
_cen="$(sed -n 's|^COPY [^/]* linux/scripts/03-media/runtime/ort-venv-census.py /\(.*\)$|\1|p' "${_torch_df}")"
t_assert_ok test -n "${_core}" -a -n "${_cen}"
_img="${_work}/img"; mkdir -p "${_img}/${_core}" "$(dirname "${_img}/${_cen}")"
cp "${UV_SH}" "${TESTS_DIR}/../01-core/logging.sh" "${_img}/${_core}/"; cp "${CENSUS}" "${_img}/${_cen}"
t_assert_eq "${_img}/${_cen}" \
  "$(bash -c 'source "$1"; printf %s "${_UV_ORT_CENSUS}"' _ "${_img}/${_core}/python_uv.sh")"
t_assert_eq "03-media/runtime/ort-venv-census.py" "$(bash -c 'source "$1"; printf %s "${_UV_ORT_CENSUS##*/scripts/}"' _ "${UV_SH}")" \
  "a checkout uses its own copy"

# uv_sync_project with the stand-in uv: sync installs the PyPI feed, then the reconcile runs.
# $1 = a venv pinned through _CURRENT_VENV_PATH, as uv_venv_create leaves it; empty = UV_PROJECT_ENVIRONMENT.
_sync() {
  local body target
  target="$(printf 'export UV_PROJECT_ENVIRONMENT=%q' "${VENV}")"
  [ -z "${1:-}" ] || target="$(printf 'unset UV_PROJECT_ENVIRONMENT\n_CURRENT_VENV_PATH=%q' "$1")"
  body="$(printf 'set -uo pipefail\nunset VIRTUAL_ENV UV_PYTHON\nsource %q\n%s\ncd %q\nrc=0; uv_sync_project --no-wxpython || rc=$?\n' "${UV_SH}" "${target}" "${_work}/proj")"
  body+=$'\nprintf "rc=%s NO_SYNC=%s\\n" "${rc}" "${UV_NO_SYNC-<unset>}"'
  PATH="${_work}/bin:${PATH}" STUB_UV_LOG="${LOG}" STUB_SYNC_WHEELS="${FEED}" bash -c "${body}" 2>&1
}

t_case "uv_sync_project reconciles the environment it just synced"
_pypi_venv
"${VPY}" "${FIX}" reset "${SITE}"
"${VPY}" "${FIX}" wheel "${FEED}" onnxruntime-directml 1.24.4 onnxruntime "pypi dml"
_out="$(ORT_CHAIN_WHEEL_DIR="${STORE}" _sync)"
t_assert_contains "${_out}" "rc=0 NO_SYNC=1"
t_assert_contains "$(head -1 "${LOG}")" "uv sync --dev --all-extras" "the sync runs first"
t_assert_contains "$(sed -n 2p "${LOG}")" "pip uninstall --python " "then the reconcile"
t_assert_contains "$(sed -n 2p "${LOG}")" " onnxruntime-directml" "removes the synced PyPI dist"
t_assert_ok _census_ok

t_case "a failed uv sync fails uv_sync_project and is not papered over by the reconcile"
_pypi_venv
_out="$(ORT_CHAIN_WHEEL_DIR="${STORE}" STUB_UV_FAIL_SYNC=1 _sync)"
t_assert_contains "${_out}" "rc=1"
t_assert_eq "" "$(grep -e 'pip ' "${LOG}" || true)" "no reconcile after a failed sync"

t_case "the pinned branch every hub driver takes reconciles _CURRENT_VENV_PATH, not UV_PROJECT_ENVIRONMENT or \$PWD/.venv"
_pin_bin=""
if [ ! -e "${VENV}/bin/python" ]; then
  # A Windows venv: its launcher runs from bin/ too (it reads the parent's pyvenv.cfg).
  mkdir -p "${VENV}/bin" && cp "${VENV}/Scripts/python.exe" "${VENV}/bin/python.exe" && _pin_bin="${VENV}/bin"
fi
_pypi_venv
"${VPY}" "${FIX}" reset "${SITE}"
"${VPY}" "${FIX}" wheel "${FEED}" onnxruntime-directml 1.24.4 onnxruntime "pypi dml"
_out="$(ORT_CHAIN_WHEEL_DIR="${STORE}" _sync "${VENV}")"
t_assert_contains "${_out}" "uv sync pinned to ${VENV}/bin/python" "the pinned branch is the one under test"
t_assert_contains "${_out}" "rc=0 NO_SYNC=1"
t_assert_contains "$(sed -n 2p "${LOG}")" "venv/bin/python onnxruntime-directml" "the reconcile targets the pinned venv"
t_assert_ok _census_ok
[ -z "${_pin_bin}" ] || rm -r "${_pin_bin}"

# stage_chain_ort_wheels, lifted out of setup-torch-venv.sh onto the fixture paths.
_stage() {
  local src body
  src="$(t_fn_src "${STV_SH}" stage_chain_ort_wheels)" || return 1
  src="${src//\$\{VENV\}\/bin\/python/${VPY}}"
  src="${src//\/opt\/scripts\/03-media\/final\/ort-venv-census.py/${CENSUS}}"
  src="${src//\/opt\/wheels/${FEED}}"
  body="$(printf 'set -euo pipefail\ncross_skip() { return 1; }\nVENV=%q\n%s\nstage_chain_ort_wheels\n' "${VENV}" "${src}")"
  ORT_CHAIN_WHEEL_DIR="${STORE}" bash -c "${body}" 2>&1
}
_install_from_feed() {
  local w
  for w in "$@"; do
    PATH="${_work}/bin:${PATH}" STUB_UV_LOG="${LOG}" uv pip install --python "${VPY}" "$(compgen -G "${FEED}/${w}")"
  done
}

t_case "the image keeps exactly the chain wheels its venv was installed from"
"${VPY}" "${FIX}" reset "${SITE}" "${STORE}" "${FEED}"
"${VPY}" "${FIX}" wheel "${FEED}" onnxruntime-dnnl 1.30.0 onnxruntime "chain dnnl"
"${VPY}" "${FIX}" wheel "${FEED}" onnxruntime 1.30.0 onnxruntime "chain plain"
"${VPY}" "${FIX}" wheel "${FEED}" onnxruntime-genai 0.15.2 onnxruntime_genai "chain genai"
_install_from_feed 'onnxruntime_dnnl-*.whl' 'onnxruntime_genai-*.whl'
_out="$(_stage)"; _rc=$?
t_assert_eq "0" "${_rc}" "stage failed: ${_out}"
t_assert_eq "onnxruntime_dnnl onnxruntime_genai" "$(cd "${STORE}" && ls | sed 's/-.*//' | sort | tr '\n' ' ' | sed 's/ $//')" \
  "the store holds the installed flavour only; a second core wheel would make every consumer venv ambiguous"
t_assert_ok _census_ok

t_case "a venv ORT dist without a chain wheel stops the image build"
"${VPY}" "${FIX}" reset "${SITE}" "${STORE}"
"${VPY}" "${FIX}" pypi "${SITE}" onnxruntime 1.27.0 onnxruntime "pypi core"
_out="$(_stage)"; _rc=$?
t_assert_eq "1" "${_rc}" "stage must fail: ${_out}"
t_assert_contains "${_out}" "is not the chain's"

t_case "a venv without ONNX Runtime stages an empty store"
"${VPY}" "${FIX}" reset "${SITE}" "${STORE}"
_out="$(_stage)"; _rc=$?
t_assert_eq "0" "${_rc}" "stage failed: ${_out}"
t_assert_eq "" "$(ls -A "${STORE}")"

t_summary
