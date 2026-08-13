#!/usr/bin/env bash
set -euo pipefail

# smoke-torch-venv.sh
# Standalone integrity smoke for the shipped PyTorch venv (/opt/venv). Imports
# the critical packages and prints versions, so a broken/incomplete venv is
# caught explicitly rather than surfacing later at app runtime.
#
# Why this exists in addition to assemble-torch-app.sh's build-time verify:
#   - It runs against ANY built or pulled image (post-build / pre-flight),
#     whereas the build-time verify only runs when assembly SUCCEEDS — the numpy
#     wheel-install collision (fix 9f07334) failed *before* that verify ran.
#   - It also catches the subtler "silent drop": when the frozen uv.lock fails
#     for a Python/platform (`Extra 'none' is not defined ...`) and assembly
#     falls back to force-reinstalling wheels, a dependency can go missing while
#     the build still succeeds. An explicit import check surfaces that.
# See docs/cross-build-verification.md (failure class #5).
#
# Usage:  smoke-torch-venv.sh            # uses /opt/venv
#         VENV=/path smoke-torch-venv.sh # override venv location
# Exit:   non-zero if any REQUIRED import fails (skips cleanly if no venv).

_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=linux/scripts/06-packaging/smoke-common.sh
source "${_SCRIPT_DIR}/smoke-common.sh"

VENV="${VENV:-/opt/venv}"
PY="${VENV}/bin/python"

# Required modules: (import_name, pretty_name, version_expr_or_empty)
REQUIRED_MODULES=(
  "numpy|numpy|numpy.__version__"
  "torch|torch|torch.__version__"
  "torchvision|torchvision|torchvision.__version__"
  "PIL|pillow|PIL.__version__"
  "cv2|opencv|cv2.__version__"
  "contourpy|contourpy|contourpy.__version__"
)

# Optional modules (warn, do not fail): the app package name can vary and GPU
# EPs are build-dependent.
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

# Read a pin from versions.env, stripping var=, quotes, trailing comment, and a
# leading `v`. Empty when the file or key is absent.
_stv_vpin() {
  local file="$1" key="$2"
  [ -f "${file}" ] || return 0
  # `|| true`: the doc contract above is "empty when the key is absent", but a
  # zero-match grep exits 1 and pipefail would turn the bare assignment at the
  # OPENCV_VERSION call site into a script abort instead of an empty pin.
  grep -E "^[[:space:]]*${key}=" "${file}" 2>/dev/null | tail -1 \
    | sed -E "s/^[[:space:]]*${key}=//; s/[\"']//g; s/#.*//; s/[[:space:]]+$//; s/^v//" || true
}

# Assert installed ML-stack versions match their pins. Two authorities, unioned
# per package: the app's uv.lock (uv-RESOLVED packages -- numpy/pillow/contourpy
# and the amd64/arm64 torch/vision/onnx wheels) and versions.env build-pins
# (packages we BUILD or force-reinstall from a LOCAL wheel -- the riscv64
# torch/vision, the source-built onnxruntime, ai-edge-litert). A package's
# installed version must equal one of  {uv.lock version(s)} u {its build-pin};
# anything else is drift and FAILS. It uses each module's __version__ (the actual
# runtime version) -- which for onnxruntime intentionally differs from its pip
# dist metadata (1.27.0 source-built lib vs 1.24.4 locked wheel; the union covers
# both). Also asserts the torch/vision build VARIANT (+cpu/+cu130/+rocm7.1)
# matches PYTORCH_EXTRA and that OpenCV's major matches OPENCV_VERSION.
assert_pinned_versions() {
  local versions_env="${VERSIONS_ENV:-/opt/scripts/core/versions.env}"
  [ -f "${versions_env}" ] || versions_env="${_SCRIPT_DIR}/../01-core/versions.env"
  local uvlock="${APP_UV_LOCK:-/opt/Kataglyphis-Orchestr-ANT-ion/uv.lock}"

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
      EXP_OPENCV_MAJOR="${opencv_major}" \
      UVLOCK="${uvlock}" \
      PYTORCH_EXTRA="${PYTORCH_EXTRA:-}" \
      "${PY}" - <<'PYEOF'
import os, sys, importlib, platform

# riscv64 has no upstream torch/vision/numpy/pillow wheels: torch/torchvision are
# LOCAL cross-built wheels (+gitXXXX / +hashXXXX variants, never +cpu) and the
# lock-only packages (numpy/pillow/contourpy) are re-resolved+source-built to newer
# versions than the amd64/arm64 uv.lock pins. Both are expected and correct on
# riscv64, so the variant check is not asserted and lock-only version drift is
# accepted there (riscv64 is its own version authority). Packages carrying an
# explicit build-pin (torch/vision base, onnx, litert) are still enforced.
is_riscv64 = (os.environ.get("STV_ARCH") or platform.machine()) == "riscv64"

def base(v):
    return v.split("+", 1)[0].strip() if v else v

def localseg(v):
    return v.split("+", 1)[1] if v and "+" in v else ""

lock_bases = {}
lock_loaded = False
lock_path = os.environ.get("UVLOCK", "")
if lock_path and os.path.exists(lock_path):
    try:
        import tomllib
        with open(lock_path, "rb") as f:
            data = tomllib.load(f)
        for p in data.get("package", []):
            lock_bases.setdefault(p.get("name", ""), set()).add(base(p.get("version", "")))
        lock_loaded = True
    except Exception as e:
        print("  ??  could not parse uv.lock (%s); lock-sourced pins skipped" % e)

def pin_set(val):
    return {base(val)} if val else set()

# import_name, lock/dist name, build-pin env value, torch-like (variant-checked)
SPECS = [
    ("torch",          "torch",          os.environ.get("EXP_PYTORCH", ""),     True),
    ("torchvision",    "torchvision",    os.environ.get("EXP_TORCHVISION", ""), True),
    ("onnxruntime",    "onnxruntime",    os.environ.get("EXP_ONNX", ""),        False),
    ("numpy",          "numpy",          "",                                    False),
    ("PIL",            "pillow",         "",                                    False),
    ("contourpy",      "contourpy",      "",                                    False),
    ("ai_edge_litert", "ai-edge-litert", os.environ.get("EXP_LITERT", ""),      False),
    # genai was the coverage hole the 2026-08-08 forensic audit found: the
    # chain built 0.15.2, the app lock shipped PyPI 0.14.0, and NOTHING here
    # noticed — genai was absent from this list, so the pin assertion passed.
    ("onnxruntime_genai", "onnxruntime-genai", os.environ.get("EXP_GENAI", ""), False),
]


extra = os.environ.get("PYTORCH_EXTRA", "")
want_variant = {"pytorch-cpu": "cpu", "pytorch-cu130": "cu130",
                "pytorch-rocm71": "rocm7.1"}.get(extra, "")

def installed_version(import_name, dist_name):
    try:
        mod = importlib.import_module(import_name)
        v = getattr(mod, "__version__", None)
        if v:
            return str(v)
    except Exception:
        pass
    try:
        import importlib.metadata as M
        return M.version(dist_name)
    except Exception:
        return None

# Arch policy: genai is a DOCUMENTED riscv64 skip — the producer refuses the
# arch ("Skipping onnxruntime-genai on riscv64 because it is not supported";
# upstream ships no riscv64 wheel in any version and closed its one RISC-V
# field report as not-planned) and verify-media-artifacts SKIPs in agreement,
# so absence there is policy, not drift. STV_REQUIRE_GENAI=1 re-arms the hard
# assert (e.g. should GEN1 ever self-build a riscv64 wheel). Found live
# 2026-08-11: without this, the assert derived EXP_GENAI unconditionally from
# versions.env and flagged the documented absence as a pin failure.
expected_absent = set()
if is_riscv64 and os.environ.get("STV_REQUIRE_GENAI", "") != "1":
    expected_absent.add("onnxruntime-genai")

fails = []
for import_name, dist_name, build_pin, torchlike in SPECS:
    inst = installed_version(import_name, dist_name)
    if inst is None:
        if dist_name in expected_absent:
            print("  ~~  %-16s not installed (documented riscv64 skip; policy, not drift)" % dist_name)
            continue
        fails.append("%s NOT INSTALLED" % dist_name)
        print("  XX  %-16s NOT INSTALLED" % dist_name)
        continue
    ib = base(inst)
    from_lock = lock_bases.get(dist_name, set())
    allowed = set(from_lock) | pin_set(build_pin)
    if not allowed:
        print("  ??  %-16s %s: no pin available -- not asserted" % (dist_name, inst))
        continue
    if ib in allowed:
        src = "uv.lock" if ib in from_lock else "versions.env"
        print("  OK  %-16s %-16s (matches %s)" % (dist_name, inst, src))
    elif is_riscv64 and not build_pin:
        # lock-only package (numpy/pillow/contourpy) re-resolved+source-built newer on
        # riscv64; accept (no upstream riscv64 wheel to pin against).
        print("  ~~  %-16s installed %s (riscv64 re-resolved; accepted, lock pin %s)"
              % (dist_name, inst, sorted(allowed)))
    else:
        fails.append("%s installed %s not in %s" % (dist_name, inst, sorted(allowed)))
        print("  XX  %-16s installed %s NOT in expected %s" % (dist_name, inst, sorted(allowed)))
    if torchlike and want_variant:
        lv = localseg(inst)
        if is_riscv64:
            # torch/torchvision are riscv64 LOCAL cross wheels (+gitXXXX / +hashXXXX),
            # never the +cpu upstream variant; the variant is not asserted here.
            print("  ~~  %-16s build variant +%s (riscv64 local wheel; not asserted)"
                  % (dist_name, lv or "?"))
        elif lv and lv != want_variant:
            fails.append("%s variant +%s != +%s" % (dist_name, lv, want_variant))
            print("  XX  %-16s build variant +%s != expected +%s (PYTORCH_EXTRA=%s)"
                  % (dist_name, lv, want_variant, extra))
        elif lv == want_variant:
            print("  OK  %-16s build variant +%s (matches %s)" % (dist_name, lv, extra))


# TVM is BEST-EFFORT in the media stage (a failed build ships without it, by
# design), so it must not join the hard-required SPECS — but before this
# probe existed there was NO tvm visibility anywhere in the smoke set, and a
# Dockerfile.media comment claimed a runtime `import tvm` gate that did not
# exist. Report presence/version; only fail when EXP_TVM explicitly pins it.
try:
    import tvm as _tvm
    _tvm_v = getattr(_tvm, "__version__", "?")
    print("  ok  %-16s %s (best-effort component)" % ("tvm", _tvm_v))
    _exp_tvm = os.environ.get("EXP_TVM", "")
    if _exp_tvm and not str(_tvm_v).startswith(_exp_tvm.lstrip("v")):
        fails.append("tvm %s != expected %s" % (_tvm_v, _exp_tvm))
except Exception:
    if os.environ.get("EXP_TVM", ""):
        fails.append("tvm NOT IMPORTABLE but EXP_TVM set")
    else:
        print("  --  %-16s not importable (best-effort; media build shipped without it)" % "tvm")

cv_major = os.environ.get("EXP_OPENCV_MAJOR", "")
cv_required = os.environ.get("STV_CV2_REQUIRED", "1") == "1"
try:
    import cv2
    cvv = cv2.__version__
    if cv_major and cvv.split(".")[0] != cv_major:
        fails.append("opencv/cv2 %s major != %s" % (cvv, cv_major))
        print("  XX  %-16s %s: major != %s" % ("opencv/cv2", cvv, cv_major))
    else:
        print("  OK  %-16s %-16s (major %s)" % ("opencv/cv2", cvv, cv_major or "?"))
except Exception as e:
    if cv_required:
        fails.append("cv2 %s" % e)
        print("  XX  cv2 import/version failed: %s" % e)
    else:
        print("  ..  cv2 not importable (optional here): %s" % e)

if not lock_loaded:
    print("  note: uv.lock not loaded -- only build-pinned packages asserted")
if fails:
    print("VERSION-ASSERT: FAIL (%d mismatch(es))" % len(fails))
    sys.exit(1)
print("VERSION-ASSERT: PASS")
PYEOF
  )"; then rc=0; else rc=$?; fi
  printf '%s\n' "${out}" | sed 's/^/  /'
  if [ "${rc}" -eq 0 ]; then
    pass "installed ML-stack versions match pins (uv.lock + versions.env)"
  else
    fail "installed ML-stack versions DRIFTED from pins (see XX lines above)"
  fi
}

main() {
  echo "=== smoke: torch venv integrity (${VENV}) ==="
  if [ ! -x "${PY}" ]; then
    # The skip exists for images that legitimately ship no venv (toolchain,
    # media). Stages where the venv is MANDATORY set STV_REQUIRE_VENV=1 —
    # without it, the package-stage gate passed precisely when setup-torch-venv
    # failed hardest (no /opt/venv at all → SKIP → exit 0 → green).
    if [ "${STV_REQUIRE_VENV:-0}" = "1" ]; then
      echo "  FAIL venv interpreter missing at ${PY} but STV_REQUIRE_VENV=1 (venv is mandatory in this image)" >&2
      exit 1
    fi
    echo "  SKIP no venv interpreter at ${PY} (nothing to check in this image)"
    exit 0
  fi
  pass "venv python present: $("${PY}" --version 2>&1)"

  # STV_ASSERT_ONLY=1 runs ONLY the version-pin assertion (the runtime-image gate
  # already imports torch/onnx/cv2 inline, so it delegates here just for versions
  # -- no need to repeat the import PASS lines / ABI bridge).
  if [ "${STV_ASSERT_ONLY:-0}" = "1" ]; then
    assert_pinned_versions
    smoke_summary
    return 0
  fi

  # cv2 is required by default (package-stage integrity), but callers that ship
  # cv2 as optional on some arches can set STV_CV2_REQUIRED=0.
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

  # numpy<->torch ABI sanity: torch must be able to bridge a numpy array.
  if "${PY}" -c "import torch,numpy; torch.from_numpy(numpy.zeros(1))" 2>/dev/null; then
    pass "torch<->numpy ABI bridge OK"
  else
    fail "torch.from_numpy failed (numpy/torch ABI mismatch)"
  fi

  # Compute battery (smoke-depth R5/R6): before this, the ONLY real torch/
  # torchvision/onnxruntime compute exercise lived in an EXTERNAL repo's app
  # smoke — zero in-repo functional coverage for the core ML stack. Gate with
  # STV_COMPUTE=0 for callers that need the fast presence-only path.
  # (~3 s native, ~8 s under qemu.)
  if [ "${STV_COMPUTE:-1}" = "1" ]; then
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
    # Real InferenceSession: get_available_providers() is a capability LIST —
    # it answers from a library that cannot actually load a graph. The model
    # is generated in-process via torch.onnx.export (no fabricated bytes, no
    # network); skipped cleanly when the exporter is unavailable.
    if "${PY}" - <<'STV_PY' 2>/dev/null
import io, sys
import numpy as np, torch
try:
    import onnxruntime as ort
except Exception:
    sys.exit(3)
buf = io.BytesIO()
m = torch.nn.Linear(4, 2)
m.eval()
try:
    torch.onnx.export(m, torch.zeros(1, 4), buf)
except Exception:
    sys.exit(3)
s = ort.InferenceSession(buf.getvalue(), providers=["CPUExecutionProvider"])
inp = s.get_inputs()[0].name
out = s.run(None, {inp: np.zeros((1, 4), np.float32)})
ref = m(torch.zeros(1, 4)).detach().numpy()
assert np.allclose(out[0], ref, atol=1e-5), (out[0], ref)
STV_PY
    then pass "onnxruntime InferenceSession runs a real graph (torch.onnx.export -> ort, values match)"
    else
      _stv_rc=$?
      if [ "${_stv_rc}" = "3" ]; then
        echo "  SKIP ort InferenceSession check (onnxruntime or the onnx exporter unavailable)"
      else
        fail "onnxruntime InferenceSession FAILED on a trivial exported graph"
      fi
    fi
  fi

  # Not just "importable" but "the CORRECT versions": assert each ML package
  # matches its pin (uv.lock for uv-resolved packages, versions.env for the ones
  # we build / force-reinstall from a local wheel).
  assert_pinned_versions

  smoke_summary
}

main "$@"
