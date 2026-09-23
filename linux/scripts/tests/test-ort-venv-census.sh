#!/usr/bin/env bash
# ort-venv-census.py (each case on the .py AND Build-TorchApp.ps1's copy) and its assemble-torch-app.sh wiring.
# NOT covered: a real uv venv or a real ORT wheel (fixture dists), and the Windows wrapper.
set -u
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${TESTS_DIR}/test-harness.sh"
CENSUS="${TESTS_DIR}/../03-media/runtime/ort-venv-census.py"
ASSEMBLE="${TESTS_DIR}/../03-media/runtime/assemble-torch-app.sh"
TORCH_APP_PS1="${TESTS_DIR}/../../../windows/scripts/build/Build-TorchApp.ps1"
_PY="${PREFLIGHT_PYTHON:-python3}"

_work="$(mktemp -d)"; trap 'rm -rf "${_work}"' EXIT

# The Windows copy, lifted from its here-string.
_WIN_COPY="${_work}/ort-venv-census-win.py"
awk '/^function Get-TorchAppOrtCensusSource/ {f=1} f && /^'"'"'@$/ {exit} p {print} f && /^    return @'"'"'$/ {p=1}' \
  "${TORCH_APP_PS1}" > "${_WIN_COPY}"
t_case "Build-TorchApp.ps1 embeds a census"
t_assert_contains "$(cat "${_WIN_COPY}")" "def check(store):" "the here-string was found and lifted"

# Fixture dists: `wheel|install NAME VERSION TOP [flag...]` and `dir TOP`. An install is the wheel's
# payload unless a flag bends it: tamper, drop, extra, stray, norecord; datalib moves the wheel's payload.
_fixture_py() {
  cat <<'FIXTURE_PY'
import base64
import hashlib
import os
import sys
import zipfile

root = sys.argv[1]
store, site = os.path.join(root, "store"), os.path.join(root, "site")
os.makedirs(store, exist_ok=True)
os.makedirs(site, exist_ok=True)


def payload(name, version, top):
    return {top + "/__init__.py": ("# %s %s\n" % (name, version)).encode(),
            top + "/capi/native.bin": ("native %s %s" % (name, version)).encode()}


def distinfo(name, version):
    return "%s-%s.dist-info" % (name.replace("-", "_"), version)


def meta(name, version):
    return ("Metadata-Version: 2.1\nName: %s\nVersion: %s\n" % (name, version)).encode()


def record(path, data):
    digest = base64.urlsafe_b64encode(hashlib.sha256(data).digest()).rstrip(b"=").decode()
    return "%s,sha256=%s,%d" % (path, digest, len(data))


def put(rel, data):
    full = os.path.join(site, *rel.split("/"))
    os.makedirs(os.path.dirname(full), exist_ok=True)
    with open(full, "wb") as out:
        out.write(data)


def wheel(name, version, top, flags):
    meta_dir = distinfo(name, version)
    path = os.path.join(store, "%s-%s-py3-none-any.whl" % (name.replace("-", "_"), version))
    with zipfile.ZipFile(path, "w") as whl:
        for rel, data in payload(name, version, top).items():
            whl.writestr(("%s.data/purelib/%s" % (meta_dir[:-10], rel)) if "datalib" in flags else rel, data)
        whl.writestr(meta_dir + "/METADATA", meta(name, version))
        whl.writestr(meta_dir + "/RECORD", "")


def install(name, version, top, flags):
    files = payload(name, version, top)
    if "tamper" in flags:
        files[top + "/capi/native.bin"] = b"a PyPI build of the same version"
    if "extra" in flags:
        files[top + "/extra.py"] = b"only in the installed copy"
    meta_dir = distinfo(name, version)
    files[meta_dir + "/METADATA"] = meta(name, version)
    files[meta_dir + "/top_level.txt"] = (top + "\n").encode()
    lines = []
    for rel, data in files.items():
        if not ("drop" in flags and rel.endswith("native.bin")):
            put(rel, data)
        lines.append(record(rel, data))
    put(top + "/__pycache__/__init__.cpython-314.pyc", b"bytecode")
    lines += ["../../bin/%s-launcher,," % top, top + "/__pycache__/__init__.cpython-314.pyc,,", meta_dir + "/RECORD,,"]
    if "norecord" not in flags:
        put(meta_dir + "/RECORD", ("\n".join(lines) + "\n").encode())
    if "stray" in flags:
        put(top + "/capi/dropped_in.dll", b"no RECORD names me")


for spec in sys.argv[2:]:
    kind, *rest = spec.split()
    if kind == "dir":
        put(rest[0] + "/__init__.py", b"# a copy with no distribution\n")
    else:
        (wheel if kind == "wheel" else install)(rest[0], rest[1], rest[2], rest[3:])
FIXTURE_PY
}

# The census as the interpreter under test would run it, with the fixture site first on sys.path.
_BOOT='import runpy, sys; sys.path.insert(0, sys.argv[1]); sys.argv = sys.argv[2:]; runpy.run_path(sys.argv[0], run_name="__main__")'
_scenario() {
  local copy="$1" mode="$2" root; shift 2
  root="$(mktemp -d "${_work}/case.XXXXXX")"
  "${_PY}" -c "$(_fixture_py)" "${root}" "$@" || { echo "FIXTURE FAILED"; return 0; }
  (cd "${root}" && "${_PY}" -S -c "${_BOOT}" "${root}/site" "${copy}" "--${mode}" --store "${root}/store" 2>&1; echo "rc=$?")
}

CHAIN=("wheel onnxruntime 1.30.0 onnxruntime" "wheel onnxruntime-genai 0.15.2 onnxruntime_genai")
HEALTHY=("${CHAIN[@]}" "install onnxruntime 1.30.0 onnxruntime" "install onnxruntime-genai 0.15.2 onnxruntime_genai")

for _copy in "${CENSUS}" "${_WIN_COPY}"; do
  _tag="(${_copy##*/})"

  t_case "a venv of chain wheels passes ${_tag}"
  _out="$(_scenario "${_copy}" check "${HEALTHY[@]}")"
  t_assert_contains "${_out}" "rc=0" "healthy venv"
  t_assert_contains "${_out}" "ORT-CENSUS PASS: 2 chain distribution(s)" "both dists proven"
  # setup-torch-venv.sh's stage_chain_ort_wheels reads the wheel back out of this exact line shape.
  t_assert_eq "onnxruntime-1.30.0-py3-none-any.whl" \
    "$(printf '%s\n' "${_out}" | tr -d '\r' | sed -n 's/^ORT-CENSUS chain onnxruntime 1\.30\.0 at .* = \([^/]*\.whl\)$/\1/p')" "the chain line names its wheel"
  t_assert_eq "" "$(printf '%s\n' "${_out}" | grep -e 'ORT-CENSUS FAIL' || true)" "no finding; launchers and bytecode are not payload"

  t_case "a same-version PyPI build is caught by its bytes alone ${_tag}"
  _out="$(_scenario "${_copy}" check "${CHAIN[@]}" "install onnxruntime 1.30.0 onnxruntime tamper" \
          "install onnxruntime-genai 0.15.2 onnxruntime_genai")"
  t_assert_contains "${_out}" "onnxruntime/capi/native.bin" "the differing file is named"
  t_assert_contains "${_out}" "differ from the chain wheel's bytes" "name and version match; bytes do not"
  t_assert_contains "${_out}" "rc=1" "fails"

  t_case "a missing chain file and an extra installed file both fail ${_tag}"
  _out="$(_scenario "${_copy}" check "${CHAIN[@]}" "install onnxruntime 1.30.0 onnxruntime drop extra")"
  t_assert_contains "${_out}" "of the chain wheel are missing, e.g. onnxruntime/capi/native.bin" "drop"
  t_assert_contains "${_out}" "installed but not in the chain wheel, e.g. onnxruntime/extra.py" "extra"

  t_case "any onnxruntime* name outside the store fails, by name alone (the rocm lane's PyPI plugin EP) ${_tag}"
  _out="$(_scenario "${_copy}" check "${HEALTHY[@]}" "install onnxruntime-ep-webgpu 0.4.0 onnxruntime_ep_webgpu")"
  t_assert_contains "${_out}" "ORT-CENSUS FAIL onnxruntime-ep-webgpu 0.4.0 at" "the EP dist is named"
  t_assert_contains "${_out}" "is not a chain wheel" "and refused"
  t_assert_contains "${_out}" "rc=1" "fails"

  t_case "a co-installed PyPI variant is two owners of one import package ${_tag}"
  _out="$(_scenario "${_copy}" check "${HEALTHY[@]}" "install onnxruntime-webgpu 1.27.0 onnxruntime")"
  t_assert_contains "${_out}" "onnxruntime-webgpu 1.27.0 at" "the variant is named"
  t_assert_contains "${_out}" "the onnxruntime import package has 2 owners" "sole ownership"

  t_case "an owner with an unrelated name is a candidate too (ort-nightly) ${_tag}"
  _out="$(_scenario "${_copy}" check "${CHAIN[@]}" "install ort-nightly 1.31.0 onnxruntime")"
  t_assert_contains "${_out}" "ORT-CENSUS FAIL ort-nightly 1.31.0 at" "ownership makes it a candidate"
  t_assert_contains "${_out}" "rc=1" "fails"

  t_case "the app lock's PyPI version is not the chain's ${_tag}"
  _out="$(_scenario "${_copy}" check "${CHAIN[@]}" "install onnxruntime 1.27.0 onnxruntime")"
  t_assert_contains "${_out}" "onnxruntime 1.27.0 at" "the version is named"
  t_assert_contains "${_out}" "is not a chain wheel" "no 1.27.0 wheel in the store"

  t_case "no ORT at all, or a store with no ORT wheel, fails ${_tag}"
  _out="$(_scenario "${_copy}" check "${CHAIN[@]}" "install onnxruntime-genai 0.15.2 onnxruntime_genai")"
  t_assert_contains "${_out}" "the onnxruntime import package has 0 owners" "nobody owns onnxruntime"
  t_assert_contains "${_out}" "import onnxruntime finds nothing" "and nothing imports"
  _out="$(_scenario "${_copy}" check "wheel onnxruntime-genai 0.15.2 onnxruntime_genai" \
          "install onnxruntime-genai 0.15.2 onnxruntime_genai")"
  t_assert_contains "${_out}" "holds no onnxruntime wheel" "a store without the chain ORT wheel"

  t_case "a file in the package that no RECORD owns, and a dist-less copy, fail ${_tag}"
  _out="$(_scenario "${_copy}" check "${CHAIN[@]}" "install onnxruntime 1.30.0 onnxruntime stray")"
  t_assert_contains "${_out}" "in the onnxruntime package are in no owner's RECORD" "stray"
  t_assert_contains "${_out}" "dropped_in.dll" "the stray file is named"
  _out="$(_scenario "${_copy}" check "${CHAIN[@]}" "dir onnxruntime")"
  t_assert_contains "${_out}" "which no owning distribution installed" "the import resolves to an unowned copy"

  t_case "a dist without a RECORD cannot be proven ${_tag}"
  _out="$(_scenario "${_copy}" check "${CHAIN[@]}" "install onnxruntime 1.30.0 onnxruntime norecord")"
  t_assert_contains "${_out}" "has no RECORD" "norecord"
  t_assert_contains "${_out}" "rc=1" "fails"

  t_case "two GenAI builds are two owners of onnxruntime_genai ${_tag}"
  _out="$(_scenario "${_copy}" check "${HEALTHY[@]}" "wheel onnxruntime-genai-cuda 0.15.2 onnxruntime_genai" \
          "install onnxruntime-genai-cuda 0.15.2 onnxruntime_genai")"
  t_assert_contains "${_out}" "the onnxruntime_genai import package has 2 owners" "genai"
  t_assert_contains "${_out}" "expected at most one" "genai may be absent, never doubled"

  t_case "a purelib .data payload is compared where it lands ${_tag}"
  _out="$(_scenario "${_copy}" check "wheel onnxruntime 1.30.0 onnxruntime datalib" "install onnxruntime 1.30.0 onnxruntime")"
  t_assert_contains "${_out}" "ORT-CENSUS PASS: 1 chain distribution(s)" "datalib"

  t_case "an unreadable store is a failure, never a pass ${_tag}"
  _root="$(mktemp -d "${_work}/case.XXXXXX")"
  _out="$(cd "${_root}" && "${_PY}" -S "${_copy}" --check --store "${_root}/no-such-store" 2>&1; echo "rc=$?")"
  t_assert_contains "${_out}" "ORT-CENSUS FAIL the census could not complete" "the crash is a finding"
  t_assert_contains "${_out}" "rc=1" "exit 1"
  t_assert_eq "" "$(printf '%s\n' "${_out}" | grep -e 'ORT-CENSUS PASS' || true)" "no PASS line"

  t_case "--purge-list names every candidate and nothing else ${_tag}"
  _out="$(_scenario "${_copy}" purge-list "${HEALTHY[@]}" "install ort-nightly 1.31.0 onnxruntime" \
          "install onnxruntime-ep-webgpu 0.4.0 onnxruntime_ep_webgpu" "install numpy 2.5.2 numpy")"
  t_assert_eq "onnxruntime onnxruntime-ep-webgpu onnxruntime-genai ort-nightly" \
    "$(printf '%s\n' "${_out}" | sed -n 's/^ORT-CENSUS PURGE //p' | tr '\n' ' ' | sed 's/ $//')" "pattern + owners, no numpy"
done

# The assemble-torch-app.sh wiring, off-target: collaborators stubbed, the census faked.
_LIB="${_work}/assemble-lib.sh"
for _fn in wheel_family assert_chain_ort_wheel_staged run_ort_census _ort_purge_names assert_ort_chain_only; do
  t_fn_src "${ASSEMBLE}" "${_fn}" >> "${_LIB}" || exit 1
done
_fake_census() {  # $1 = rc, $2 = output; run_ort_census replaced
  printf 'run_ort_census() { printf "%%s\\n" %q; return %s; }\n' "$2" "$1"
}
_wiring() {  # $1 = stub source, rest = the call
  local stub="$1"; shift
  bash -c "set -Eeuo pipefail"$'\n'"source $(printf '%q' "${_LIB}")"$'\n'"${stub}"$'\n'"$(printf '%q ' "$@")" 2>&1
  echo "rc=$?"
}

t_case "assert_ort_chain_only passes only on exit 0 AND a PASS line"
t_assert_contains "$(_wiring "$(_fake_census 0 'ORT-CENSUS PASS: 2 chain distribution(s) from /opt/wheels')" assert_ort_chain_only)" "rc=0" "pass"
t_assert_contains "$(_wiring "$(_fake_census 1 'ORT-CENSUS FAIL x')" assert_ort_chain_only)" "rc=1" "a failing census"
t_assert_contains "$(_wiring "$(_fake_census 0 '')" assert_ort_chain_only)" "rc=1" "exit 0 with no output is not a pass"
t_assert_contains "$(_wiring "$(_fake_census 0 'noise ORT-CENSUS PASS')" assert_ort_chain_only)" "rc=1" "PASS must start a line"
t_assert_contains "$(_wiring "$(_fake_census 1 'ORT-CENSUS PASS: 1')" assert_ort_chain_only)" "rc=1" "a PASS line never beats a non-zero exit"
t_assert_contains "$(_wiring "$(_fake_census 1 'ORT-CENSUS FAIL onnxruntime-ep-webgpu')" assert_ort_chain_only)" \
  "ORT-CENSUS FAIL onnxruntime-ep-webgpu" "the census output reaches the build log"

t_case "a missing chain ORT wheel is fatal, whatever else the store holds"
_wh="${_work}/wheels"; mkdir -p "${_wh}"
: > "${_wh}/onnxruntime_genai-0.15.2-cp314-cp314-linux_x86_64.whl"
: > "${_wh}/torch-2.14.0-cp314-cp314-linux_x86_64.whl"
t_assert_contains "$(LOCAL_WHEELS_DIR="${_wh}" ONNX_PACKAGE=onnxruntime _wiring : assert_chain_ort_wheel_staged)" "rc=1" "genai + torch only"
t_assert_contains "$(LOCAL_WHEELS_DIR="${_work}/empty" ONNX_PACKAGE=onnxruntime _wiring : assert_chain_ort_wheel_staged)" "rc=1" "no store"
: > "${_wh}/onnxruntime_ep_webgpu-0.4.0-py3-none-linux_x86_64.whl"
: > "${_wh}/onnxruntime_extensions-0.15.0-cp314-cp314-linux_x86_64.whl"
t_assert_contains "$(LOCAL_WHEELS_DIR="${_wh}" ONNX_PACKAGE=onnxruntime _wiring : assert_chain_ort_wheel_staged)" "rc=1" \
  "a plugin EP or extensions wheel is not the runtime"
: > "${_wh}/onnxruntime_qnn-1.30.0-cp314-cp314-linux_aarch64.whl"
t_assert_contains "$(LOCAL_WHEELS_DIR="${_wh}" ONNX_PACKAGE=onnxruntime _wiring : assert_chain_ort_wheel_staged)" "rc=0" \
  "a flavour no list names is still the runtime (pattern, not a list)"

t_case "uv sync never installs the lock's PyPI genai while any chain GenAI flavour is staged"
_bua="$(t_fn_src "${ASSEMBLE}" build_uv_sync_args)" || exit 1
_sync_for() {  # $@ = the staged wheel basenames; prints the uv sync args
  local d; d="$(mktemp -d "${_work}/sync.XXXXXX")"
  for _w in "$@"; do : > "${d}/${_w}"; done
  bash -c "uv() { :; }"$'\n'"${_bua//\/opt\/wheels/${d}}"$'\n''declare -a a=() s=() w=(); build_uv_sync_args a s w; printf "%s\n" "${a[@]}"' 2>&1
}
for _g in onnxruntime_genai-0.15.2 onnxruntime_genai_cuda-0.15.2 onnxruntime_genai_trt_rtx-0.15.2; do
  t_assert_contains "$(_sync_for onnxruntime_gpu-1.30.0-cp314-cp314-linux_x86_64.whl "${_g}-cp314-cp314-linux_x86_64.whl")" \
    $'--no-install-package\nonnxruntime-genai' "${_g}"
done
t_assert_eq "" "$(_sync_for onnxruntime_gpu-1.30.0-cp314-cp314-linux_x86_64.whl | grep -x -e onnxruntime-genai || true)" \
  "no chain GenAI staged: the lock decides (control)"

t_case "the purge takes the census's names and nothing else"
_out="$(_wiring "$(_fake_census 0 $'noise\nORT-CENSUS PURGE onnxruntime\nORT-CENSUS PURGE onnxruntime-genai\nORT-CENSUS PURGE bad;name')" _ort_purge_names)"
t_assert_eq $'onnxruntime\nonnxruntime-genai\nrc=0' "${_out}" "only well-formed PURGE lines"
t_assert_contains "$(_wiring "$(_fake_census 1 'Traceback')" _ort_purge_names)" "rc=1" "a failing census stops the purge"

t_case "run_ort_census runs the census beside the script with the venv python, isolated"
mkdir -p "${_work}/venv/bin"
printf '#!/usr/bin/env bash\nprintf "%%s|" "$@"\necho\n' > "${_work}/venv/bin/python"; chmod +x "${_work}/venv/bin/python"
_out="$(VENV="${_work}/venv" LOCAL_WHEELS_DIR=/opt/wheels _wiring : run_ort_census check)"
t_assert_eq "-I|${_work}/ort-venv-census.py|--check|--store|/opt/wheels|"$'\n'"rc=0" "${_out}" "argv"

t_case "install_project_environment stages-checks first and censuses last; the image ships the census"
_ipe="$(t_fn_src "${ASSEMBLE}" install_project_environment)" || exit 1
t_assert_eq "prune_conflicting_onnx_wheels assert_chain_ort_wheel_staged" \
  "$(printf '%s\n' "${_ipe}" | grep -oE -e '^  (prune_conflicting_onnx_wheels|assert_chain_ort_wheel_staged)$' | tr -d ' ' | tr '\n' ' ' | sed 's/ $//')" \
  "the wheel check follows the prune, before any uv sync"
t_assert_eq "  assert_ort_chain_only" "$(printf '%s\n' "${_ipe}" | grep -v -e '^}' | grep -v -e '^[[:space:]]*$' | tail -1)" \
  "the census is the last step of the assembly"
t_assert_contains "$(cat "${TESTS_DIR}/../../Dockerfile.torch")" \
  "COPY --chmod=755 linux/scripts/03-media/runtime/ort-venv-census.py /opt/scripts/03-media/final/ort-venv-census.py" \
  "beside /opt/scripts/03-media/final/assemble-torch-app.sh"

t_summary
