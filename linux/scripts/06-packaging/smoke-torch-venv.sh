#!/usr/bin/env bash
set -euo pipefail

# Venv smoke (VENV, default /opt/venv) for any built image; a wheel fallback can drop deps silently. docs/cross-build-verification.md#smoke-torch-venv-what-the-venv-assertions-cover

_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=linux/scripts/06-packaging/smoke-common.sh
source "${_SCRIPT_DIR}/smoke-common.sh"

VENV="${VENV:-/opt/venv}"
PY="${VENV}/bin/python"
: "${STV_COMPUTE:=1}"

# Required modules: (import_name, pretty_name, version_expr_or_empty)
REQUIRED_MODULES=(
  "numpy|numpy|numpy.__version__"
  "torch|torch|torch.__version__"
  "torchvision|torchvision|torchvision.__version__"
  "PIL|pillow|PIL.__version__"
  "cv2|opencv|cv2.__version__"
  "contourpy|contourpy|contourpy.__version__"
)

# Warn only: GPU EPs are build-dependent.
OPTIONAL_MODULES=(
  "onnxruntime|onnxruntime|onnxruntime.__version__"
)

try_import() {
  # $1 import name, $2 pretty, $3 version expr, $4 required(1)/optional(0)
  local mod="$1" pretty="$2" ver_expr="$3" required="$4" out
  if out="$("${PY}" -c "import ${mod}; print(${ver_expr:-\"ok\"})" 2>&1)"; then
    pass "${pretty} import OK (${out})"
    return 0
  fi
  if [ "${required}" = "1" ]; then
    fail "${pretty} import FAILED: $(printf '%s' "${out}" | tail -1)"
  else
    printf '  SKIP %s not importable (optional): %s\n' "${pretty}" "$(printf '%s' "${out}" | tail -1)"
  fi
  return 1
}

# A versions.env pin without quotes, comment or leading v; empty when the file or key is absent.
_stv_vpin() {
  local file="$1" key="$2"
  [ -f "${file}" ] || return 0
  # || true: under pipefail a zero-match grep would abort the caller instead of returning empty.
  grep -E "^[[:space:]]*${key}=" "${file}" 2>/dev/null | tail -1 \
    | sed -E "s/^[[:space:]]*${key}=//; s/[\"']//g; s/#.*//; s/[[:space:]]+$//; s/^v//" || true
}

# See docs/cross-build-verification.md#smoke-torch-venv-what-the-venv-assertions-cover
assert_pinned_versions() {
  local versions_env="${VERSIONS_ENV:-/opt/scripts/core/versions.env}"
  [ -f "${versions_env}" ] || versions_env="${_SCRIPT_DIR}/../01-core/versions.env"
  local uvlock="${APP_UV_LOCK:-/opt/OrchestrANT/uv.lock}"

  echo "--- version-pin assertion (uv.lock + versions.env) ---"
  if [ ! -f "${versions_env}" ] && [ ! -f "${uvlock}" ]; then
    printf '  SKIP no versions.env and no uv.lock present -- cannot assert pins\n'
    return 0
  fi

  local opencv_major
  opencv_major="$(_stv_vpin "${versions_env}" OPENCV_VERSION)"
  opencv_major="${opencv_major%%.*}"

  local out rc
  if out="$(
      EXP_PYTORCH="$(_stv_vpin "${versions_env}" PYTORCH_VERSION)" \
      EXP_TORCHVISION="$(_stv_vpin "${versions_env}" TORCHVISION_VERSION)" \
      EXP_ONNX="$(_stv_vpin "${versions_env}" ONNXRUNTIME_VERSION)" \
      EXP_LITERT="$(_stv_vpin "${versions_env}" LITERT_VERSION)" \
      EXP_GENAI="$(_stv_vpin "${versions_env}" ONNXRUNTIME_GENAI_VERSION)" \
      EXP_TVM="$(_stv_vpin "${versions_env}" TVM_REF)" \
      EXP_OPENCV_MAJOR="${opencv_major}" \
      UVLOCK="${uvlock}" \
      PYTORCH_EXTRA="${PYTORCH_EXTRA:-}" \
      "${PY}" "${_SCRIPT_DIR}/venv-version-probe.py"
  )"; then rc=0; else rc=$?; fi
  printf '%s\n' "${out}" | sed 's/^/  /'
  local tolerated
  tolerated="$(printf '%s\n' "${out}" | sed -n 's/^VERSION-ASSERT: \([0-9]*\) TOLERATED.*/\1/p')"
  if [ "${rc}" -eq 0 ]; then
    if [ -n "${tolerated}" ]; then
      # A pass, but never a quiet one: each tolerance is one KNOWN_DRIFT line, not a blanket exemption.
      pass "installed ML-stack versions match pins, with ${tolerated} TOLERATED drift(s) (see the !! lines above)"
    else
      pass "installed ML-stack versions match pins (uv.lock + versions.env)"
    fi
  else
    fail "installed ML-stack versions DRIFTED from pins (see XX lines above)"
  fi
}

# riscv64 never runs uv sync, so each absence there needs an EXEMPT line with a reason. docs/riscv64-venv-parity.md
_stv_probe_app_venv_parity() {
  "${PY}" - <<'PYEOF'
import importlib.metadata as M
import os
import platform
import sys

_MACHINE_TO_ARCH = {"x86_64": "amd64", "amd64": "amd64",
                    "aarch64": "arm64", "arm64": "arm64", "riscv64": "riscv64"}
_raw_arch = os.environ.get("STV_ARCH") or platform.machine()
# Unknown machines must not inherit another architecture’s exemption.
ARCH = _MACHINE_TO_ARCH.get(_raw_arch, _raw_arch)

# captum is optional because PYTORCH_EXTRA=none is supported.
REQUIRED = [
    ("pandas",             "ml-ai"),
    ("scipy",              "ml-ai"),
    ("scikit-learn",       "ml-ai"),
    ("optuna",             "ml-ai"),
    ("mlflow",             "ml-ai"),
    ("boto3",              "ml-ai"),
    ("iree-base-compiler", "ml-ai"),
    ("sphinx",             "docs"),
    ("sphinx-book-theme",  "docs"),
    ("sphinx-design",      "docs"),
    ("myst-parser",        "docs"),
    ("flet",               "frontend"),
    ("flet-desktop",       "frontend"),
    ("flet-web",           "frontend"),
    ("fastapi",            "frontend"),
]

# Only reviewed per-architecture absences are tolerated; see docs/riscv64-venv-parity.md.
EXEMPT = {
    ("pandas", "riscv64"):
        "no riscv64 wheel; ml-ai is uninstallable here (its riscv64 opencv-python is a git source pin)",
    ("scipy", "riscv64"):
        "no riscv64 wheel; multi-hour QEMU source build",
    ("scikit-learn", "riscv64"):
        "no riscv64 wheel; needs scipy, which has none either",
    ("mlflow", "riscv64"):
        "app pyproject gates mlflow (and its ~60-package closure) off riscv64",
    ("boto3", "riscv64"):
        "app pyproject gates boto3 off riscv64",
    ("iree-base-compiler", "riscv64"):
        "riscv64 builds IREE runtime-only (compiler=OFF, upstream-consistent)",
}
EXEMPT.update({(dist, "riscv64"): "app pyproject gates the frontend extra off riscv64; Flet publishes no riscv64 client"
               for dist, extra in REQUIRED if extra == "frontend"})

fails, exempted, stale = [], [], []
for dist, extra in REQUIRED:
    try:
        installed = M.version(dist)
    except M.PackageNotFoundError:
        installed = None
    why = EXEMPT.get((dist, ARCH))
    if installed is not None:
        if why:
            stale.append(dist)
            print(f"  ??  {dist:<20} {installed} is INSTALLED but listed EXEMPT on {ARCH} -- delete the line")
        else:
            print(f"  OK  {dist:<20} {installed:<14} (extra {extra})")
    elif why:
        exempted.append(dist)
        print(f"  ~~  {dist:<20} absent on {ARCH} BY DECISION -- {why}")
    else:
        fails.append(dist)
        print(f"  XX  {dist:<20} MISSING -- extra {extra} must deliver it on {ARCH}")

if exempted:
    print(f"APP-PARITY: {len(exempted)} documented exemption(s) on {ARCH}: {', '.join(exempted)}")
if fails:
    print(f"APP-PARITY: FAIL ({len(fails)} missing)")
    sys.exit(1)
print("APP-PARITY: PASS")
PYEOF
}

assert_app_venv_parity() {
  echo "--- app venv parity (uv sync extras) ---"
  # The app package marks that assemble-torch-app.sh ran; without it there are no extras to assert.
  if ! "${PY}" -c 'import orchestrant' >/dev/null 2>&1; then
    printf '  SKIP app package not installed in this venv -- extras parity not applicable\n'
    return 0
  fi

  local out rc
  if out="$(_stv_probe_app_venv_parity
  )"; then rc=0; else rc=$?; fi
  printf '%s\n' "${out}" | sed 's/^/  /'
  if [ "${rc}" -eq 0 ]; then
    pass "app venv carries the uv sync extras (documented exemptions aside)"
  else
    fail "app venv is MISSING packages the uv sync extras must deliver (see XX lines above)"
  fi
}

# import tvm silently falls back to runtime-only when libtvm_compiler.so fails to load; a pass needs the OK sentinel.
assert_tvm_codegen() {
  local out rc
  if out="$("${PY}" - 2>&1 <<'PYEOF'
import os
import sys

try:
    import tvm
except ImportError as e:
    print(f"TVM-CODEGEN SKIP: tvm not importable ({e})")
    sys.exit(3)
if not os.path.exists(os.path.join(os.path.dirname(tvm.__file__), "lib", "libtvm_compiler.so")):
    print("TVM-CODEGEN SKIP: a runtime-only tvm, no libtvm_compiler.so")
    sys.exit(3)
if tvm.base._RUNTIME_ONLY:
    print("TVM-CODEGEN FAIL: libtvm_compiler.so ships but did not load")
    sys.exit(1)
llvm = str(tvm.support.libinfo().get("USE_LLVM", "OFF"))
if llvm.upper() in ("", "OFF", "0", "FALSE"):
    print(f"TVM-CODEGEN SKIP: built without LLVM (USE_LLVM={llvm})")
    sys.exit(3)
from tvm import te

a = te.placeholder((8,), name="a")
f = te.create_prim_func([a, te.compute((8,), lambda i: a[i] * 2.0, name="b")])
(tvm.compile if hasattr(tvm, "compile") else tvm.build)(f, target="llvm")
print(f"TVM-CODEGEN OK: one PrimFunc compiled for llvm (USE_LLVM={llvm})")
PYEOF
  )"; then rc=0; else rc=$?; fi
  case "${rc}:${out}" in
    0:*"TVM-CODEGEN OK: "*) pass "tvm codegen: ${out##*TVM-CODEGEN OK: }" ;;
    3:*"TVM-CODEGEN SKIP: "*) echo "  SKIP tvm codegen: ${out##*TVM-CODEGEN SKIP: }" ;;
    *) fail "tvm codegen (rc=${rc}): ${out:-no output}" ;;
  esac
}

_stv_compute_battery() {
  # numpy<->torch ABI sanity: torch must be able to bridge a numpy array.
  if "${PY}" -c "import torch,numpy; torch.from_numpy(numpy.zeros(1))" 2>/dev/null; then
    pass "torch<->numpy ABI bridge OK"
  else
    fail "torch.from_numpy failed (numpy/torch ABI mismatch)"
  fi

  # Real compute, not just imports; STV_COMPUTE=0 gives the fast presence-only path.
  if [ "${STV_COMPUTE}" = "1" ]; then
    if "${PY}" - <<'STV_PY' 2>/dev/null
import torch

torch.manual_seed(0)
x = torch.randn(8, 4, requires_grad=True)
m = torch.nn.Linear(4, 2)
m(x).sum().backward()
assert x.grad is not None and x.grad.shape == (8, 4)
assert torch.allclose(torch.mm(torch.eye(3), torch.eye(3)), torch.eye(3))
STV_PY
    then pass "torch compute: forward+backward+mm OK"
    else fail "torch compute FAILED (import works, so this is real)"
    fi
    if "${PY}" - <<'STV_PY' 2>/dev/null
import torch
from torchvision.ops import nms
from torchvision.transforms import v2

b = torch.tensor([[0.,0.,10.,10.],[1.,1.,11.,11.],[50.,50.,60.,60.]])
assert nms(b, torch.tensor([0.9,0.8,0.7]), 0.5).numel() == 2   # exercises torchvision._C
assert v2.Resize((8,8))(torch.zeros(3,16,16)).shape == (3,8,8)
STV_PY
    then pass "torchvision compute: nms (._C ext) + v2.Resize OK"
    else fail "torchvision compute FAILED (the _C extension is the classic ABI-drift victim)"
    fi
    # A pass needs the ONNX-EP OK: sentinel: an empty program makes `python -` exit 0 having run nothing.
    if _stv_onnx_out="$(smoke_minimal_onnx_py | "${PY}" - 2>&1)"
    then _stv_rc=0
    else _stv_rc=$?
    fi
    if ! printf '%s\n' "${_stv_onnx_out}" | grep -q 'ONNX-EP '; then
      fail "onnxruntime InferenceSession check produced NO ONNX-EP sentinel (rc=${_stv_rc}) -- the generated program did not run: ${_stv_onnx_out}"
    elif [ "${_stv_rc}" = "0" ] && printf '%s\n' "${_stv_onnx_out}" | grep -q 'ONNX-EP OK:'; then
      pass "onnxruntime InferenceSession runs a real graph — ${_stv_onnx_out}"
    elif [ "${_stv_rc}" = "3" ]; then
      echo "  SKIP ${_stv_onnx_out}"
    else
      fail "onnxruntime InferenceSession FAILED on the generated Add graph: ${_stv_onnx_out}"
    fi
    assert_tvm_codegen
  fi
}

main() {
  echo "=== smoke: torch venv integrity (${VENV}) ==="
  if [ ! -x "${PY}" ]; then
    # Stages that must ship a venv set STV_REQUIRE_VENV=1, or a missing venv would skip to green.
    if [ "${STV_REQUIRE_VENV:-0}" = "1" ]; then
      echo "  FAIL venv interpreter missing at ${PY} but STV_REQUIRE_VENV=1 (venv is mandatory in this image)" >&2
      exit 1
    fi
    echo "  SKIP no venv interpreter at ${PY} (nothing to check in this image)"
    exit 0
  fi
  pass "venv python present: $("${PY}" --version 2>&1)"

  # The runtime-image gate does its own imports and delegates only the version asserts here.
  if [ "${STV_ASSERT_ONLY:-0}" = "1" ]; then
    assert_pinned_versions
    assert_app_venv_parity
    smoke_summary
    return 0
  fi

  # Callers whose cv2 is optional on some arches set STV_CV2_REQUIRED=0.
  local cv2_required="${STV_CV2_REQUIRED:-1}"

  local spec
  for spec in "${REQUIRED_MODULES[@]}"; do
    IFS='|' read -r mod pretty ver <<<"${spec}"
    if [ "${mod}" = "cv2" ] && [ "${cv2_required}" != "1" ]; then
      try_import "${mod}" "${pretty}" "${ver}" 0 || true
    else
      try_import "${mod}" "${pretty}" "${ver}" 1 || true
    fi
  done
  for spec in "${OPTIONAL_MODULES[@]}"; do
    IFS='|' read -r mod pretty ver <<<"${spec}"
    try_import "${mod}" "${pretty}" "${ver}" 0 || true
  done

  _stv_compute_battery

  # Pins: uv.lock for resolved packages, versions.env for the ones we build or force-reinstall.
  assert_pinned_versions
  assert_app_venv_parity

  smoke_summary
}

main "$@"
