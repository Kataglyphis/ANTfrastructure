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
  grep -E "^[[:space:]]*${key}=" "${file}" 2>/dev/null | tail -1 \
    | sed -E "s/^[[:space:]]*${key}=//; s/[\"']//g; s/#.*//; s/[[:space:]]+$//; s/^v//"
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
      EXP_OPENCV_MAJOR="${opencv_major}" \
      UVLOCK="${uvlock}" \
      PYTORCH_EXTRA="${PYTORCH_EXTRA:-}" \
      "${PY}" - <<'PYEOF'
import os, sys, importlib

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

fails = []
for import_name, dist_name, build_pin, torchlike in SPECS:
    inst = installed_version(import_name, dist_name)
    if inst is None:
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
    else:
        fails.append("%s installed %s not in %s" % (dist_name, inst, sorted(allowed)))
        print("  XX  %-16s installed %s NOT in expected %s" % (dist_name, inst, sorted(allowed)))
    if torchlike and want_variant:
        lv = localseg(inst)
        if lv and lv != want_variant:
            fails.append("%s variant +%s != +%s" % (dist_name, lv, want_variant))
            print("  XX  %-16s build variant +%s != expected +%s (PYTORCH_EXTRA=%s)"
                  % (dist_name, lv, want_variant, extra))
        elif lv == want_variant:
            print("  OK  %-16s build variant +%s (matches %s)" % (dist_name, lv, extra))

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

  # Not just "importable" but "the CORRECT versions": assert each ML package
  # matches its pin (uv.lock for uv-resolved packages, versions.env for the ones
  # we build / force-reinstall from a local wheel).
  assert_pinned_versions

  smoke_summary
}

main "$@"
