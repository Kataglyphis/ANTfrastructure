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

# What this gate does and does not cover:
# docs/cross-build-verification.md
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
      EXP_TVM="$(_stv_vpin "${versions_env}" TVM_REF)" \
      EXP_OPENCV_MAJOR="${opencv_major}" \
      UVLOCK="${uvlock}" \
      PYTORCH_EXTRA="${PYTORCH_EXTRA:-}" \
      "${PY}" - <<'PYEOF'
import os, re, sys, importlib, platform

# riscv64 has no upstream torch/vision/numpy/pillow wheels: torch/torchvision are
# LOCAL cross-built wheels (+gitXXXX / +hashXXXX variants, never +cpu) and the
# lock-only packages (numpy/pillow/contourpy) are re-resolved+source-built to newer
# versions than the amd64/arm64 uv.lock pins. Both are expected and correct on
# riscv64, so the variant check is not asserted and lock-only version drift is
# accepted there (riscv64 is its own version authority). Packages carrying an
# explicit build-pin (torch/vision base, onnx, litert) are still enforced.
_MACHINE_TO_ARCH = {"x86_64": "amd64", "amd64": "amd64",
                    "aarch64": "arm64", "arm64": "arm64", "riscv64": "riscv64"}
_raw_arch = os.environ.get("STV_ARCH") or platform.machine()
# Repo arch name (amd64/arm64/riscv64). An UNRECOGNISED machine deliberately
# keeps its raw name: it then matches no KNOWN_DRIFT arch below, so an unknown
# host gets the strict assert rather than someone else's tolerance.
ARCH = _MACHINE_TO_ARCH.get(_raw_arch, _raw_arch)
is_riscv64 = ARCH == "riscv64"

def base(v):
    return v.split("+", 1)[0].strip() if v else v

def localseg(v):
    return v.split("+", 1)[1] if v and "+" in v else ""

# PEP440 pre-release/dev marker on the END of a base version (2.13.0a0 -> 2.13.0).
_DEV_MARKER = re.compile(r"(a|b|rc|\.dev)\d*$")

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

# ── KNOWN_DRIFT: dated, per-case tolerances ─────────────────────────────────
# The tightened authority rule below is CORRECT and the drift it exposes is
# REAL — but the producer-side half of that drift is not fixed yet, and this
# assert is a HARD gate (build-runtime-manifest.sh runs the runtime smoke
# before the manifest push), so shipping the strict rule alone would have
# blocked every release on a defect we already know about. Each entry here is
# ONE line: an exact (dist, arch, installed-base, expected) quadruple, so it
# tolerates precisely the deviation that was reviewed and NOTHING else — a new
# version on either side re-arms the assert by itself. Tolerated ≠ silent: the
# drift is printed as a `!!` line and counted in the summary on every run.
# Fix the producer, DELETE the one line, gate is armed again.
#
# (dist_name, arch, installed_base, expected, why)
KNOWN_DRIFT = [
]

def tolerated_drift(dist_name, arch, installed_base, expected):
    for _d, _a, _i, _e, _why in KNOWN_DRIFT:
        if (_d, _a, _i, _e) == (dist_name, arch, installed_base, expected):
            return _why
    return None

tolerated = []

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

# GEN1 inverts the old riscv64 genai carve-out: riscv64 self-builds the wheel now,
# so absence is a DEFECT unless the lane was turned off. docs/gen1-riscv64-genai.md
expected_absent = set()
if is_riscv64 and os.environ.get("GENAI_ALLOW_RISCV64", "true").strip().lower() != "true":
    expected_absent.add("onnxruntime-genai")

fails = []
for import_name, dist_name, build_pin, torchlike in SPECS:
    inst = installed_version(import_name, dist_name)
    if inst is None:
        if dist_name in expected_absent:
            print("  ~~  %-16s not installed (riscv64 GenAI lane off via GENAI_ALLOW_RISCV64; policy, not drift)" % dist_name)
            continue
        fails.append("%s NOT INSTALLED" % dist_name)
        print("  XX  %-16s NOT INSTALLED" % dist_name)
        continue
    ib = base(inst)
    from_lock = lock_bases.get(dist_name, set())
    # GENAI-DRIFT (2026-08-23): a versions.env BUILD pin is AUTHORITATIVE for
    # every arch that builds the package -- the lock gets no vote. The old
    # union (lock u pin) printed "OK onnxruntime-genai 0.14.0 (matches
    # uv.lock)" on arm64 while versions.env pinned v0.15.2, so the per-arch
    # split (amd64 0.15.2 local wheel / arm64 0.14.0 straight from PyPI /
    # riscv64 absent by policy) shipped green and nothing could catch it.
    allowed = pin_set(build_pin) if build_pin else set(from_lock)
    if not allowed:
        print("  ??  %-16s %s: no pin available -- not asserted" % (dist_name, inst))
        continue
    # A locally cross-built wheel carries the build METHOD in its version:
    # torch stamps a checkout of the PINNED v2.13.0 tag as 2.13.0a0+gitcf30153
    # on riscv64. An a0/rc/dev marker on a wheel that also has a local segment
    # is the build method, not a different version -- strip it before comparing
    # against the pin. A genuinely different base (2.14.0a0+git...) still fails.
    ib_cmp = _DEV_MARKER.sub("", ib) if (build_pin and localseg(inst)) else ib
    if ib in allowed or ib_cmp in allowed:
        src = "versions.env" if build_pin else "uv.lock"
        note = ""
        if build_pin and from_lock and not ({ib, ib_cmp} & from_lock):
            # Expected for the packages we build (source-built onnxruntime vs
            # the locked wheel); printed so the split stays visible, not silent.
            note = " [uv.lock says %s; build pin wins]" % ",".join(sorted(from_lock))
        print("  OK  %-16s %-16s (matches %s)%s" % (dist_name, inst, src, note))
    elif is_riscv64 and not build_pin:
        # lock-only package (numpy/pillow/contourpy) re-resolved+source-built newer on
        # riscv64; accept (no upstream riscv64 wheel to pin against).
        print("  ~~  %-16s installed %s (riscv64 re-resolved; accepted, lock pin %s)"
              % (dist_name, inst, sorted(allowed)))
    else:
        why = "versions.env build pin" if build_pin else "uv.lock"
        expected = ",".join(sorted(allowed))
        lock_note = ("; lock has " + ",".join(sorted(from_lock))) if (build_pin and from_lock) else ""
        excuse = tolerated_drift(dist_name, ARCH, ib, expected)
        if excuse:
            # LOUD but non-blocking: a reviewed, dated, single-line tolerance.
            tolerated.append("%s %s != %s on %s" % (dist_name, inst, expected, ARCH))
            print("  !!  %-16s installed %s != expected %s on %s (%s is authoritative%s)"
                  % (dist_name, inst, expected, ARCH, why, lock_note))
            print("  !!  %-16s TOLERATED DRIFT -- %s" % ("", excuse))
        else:
            fails.append("%s installed %s not in %s (%s)" % (dist_name, inst, sorted(allowed), why))
            print("  XX  %-16s installed %s NOT in expected %s (%s is authoritative%s)"
                  % (dist_name, inst, sorted(allowed), why, lock_note))
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


# TVM is now a HARD assert (EXP_TVM set from versions.env TVM_REF). The build
# ships it on all three arches; before this was armed, an absent TVM was
# silently best-effort with no visibility. The wheel version is a dev tag
# (0.26.dev1) that doesn't match the git tag (0.26.0) exactly, so compare
# major.minor only.
try:
    import tvm as _tvm
    _tvm_v = getattr(_tvm, "__version__", "?")
    print("  ok  %-16s %s" % ("tvm", _tvm_v))
    _exp_tvm = os.environ.get("EXP_TVM", "")
    if _exp_tvm:
        _exp_mm = ".".join(_exp_tvm.lstrip("v").split(".")[:2])
        _tvm_mm = ".".join(str(_tvm_v).split(".")[:2])
        if _tvm_mm != _exp_mm:
            fails.append("tvm %s major.minor != %s (from TVM_REF=%s)" % (_tvm_v, _exp_mm, _exp_tvm))
except Exception as _e:
    if os.environ.get("EXP_TVM", ""):
        fails.append("tvm NOT IMPORTABLE but EXP_TVM set: %s" % _e)
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
    # SMK1 (2026-08-17): the opencv TWO-PASS functional gate. Pass-2 rebuilds
    # OpenCV against the source-built GStreamer; if that regresses (e.g. the
    # .pc probe in the opencv-gst stage), cv2 silently loses its gstreamer
    # videoio backend while everything else stays green — this is the assert
    # the original two-pass design called for.
    # Both were once relaxed (riscv64 exempt, FFMPEG advisory); measured
    # 2026-09-01 all three arches report GStreamer 1.29.2 and FFMPEG YES.
    import re as _re
    _binfo = cv2.getBuildInformation()
    def _backend(name):
        m = _re.search(name + r":\s*(\S+)", _binfo)
        return m.group(1) if m else "?"
    _gst = _backend("GStreamer")
    _ff  = _backend("FFMPEG")
    # SMK1-3ARCH (2026-08-23): both backends are now HARD asserts on ALL three
    # arches. The old riscv64 exemption printed "gstreamer OFF by design" on the
    # very line where the probe said GStreamer=YES — wave-5 ships GStreamer:YES
    # AND FFMPEG:YES on amd64/arm64/riscv64 (verified on shipped bytes, and by
    # running real gst/ffmpeg pipelines in the images), so the premise is gone
    # and FFMPEG no longer stays advisory (that was OCV-FF1's on-green rider).
    _gst_ok = _gst.upper().startswith("YES")
    _ff_ok = _ff.upper().startswith("YES")
    if _gst_ok and _ff_ok:
        print("  OK  cv2 videoio      GStreamer=%s; FFMPEG=%s" % (_gst, _ff))
    else:
        if not _gst_ok:
            fails.append("cv2 GStreamer backend=%s (two-pass regressed; expected YES)" % _gst)
        if not _ff_ok:
            fails.append("cv2 FFMPEG backend=%s (OCV-FF1 regressed; expected YES)" % _ff)
        print("  XX  cv2 videoio      GStreamer=%s FFMPEG=%s — REGRESSED (both expected YES)" % (_gst, _ff))
    # SMOKE-DEPTH(a) 2026-08-23: everything above is getBuildInformation()
    # STRINGS -- compile-time linkage, which says nothing about whether a frame
    # can actually move through the backend at runtime (cv2 can report
    # GStreamer:YES and still have no working plugin path, and an FFMPEG:YES
    # muxer set is worthless if the encoder cannot open a file). The strings
    # stay as the cheap pre-filter; THESE are the assert. Both pipelines were
    # run by hand on all three shipped wave-5 images before being promoted
    # here. Cheap enough for qemu: ~1 s native, ~5 s emulated.
    # STV_MEDIA_FUNCTIONAL=0 falls back to the strings alone.
    if os.environ.get("STV_MEDIA_FUNCTIONAL", "1") == "1":
        import shutil as _sh, tempfile as _tf
        _d = _tf.mkdtemp()
        try:
            import numpy as _np
            if _gst_ok:
                _cap = cv2.VideoCapture(
                    "videotestsrc num-buffers=1 ! videoconvert !"
                    " video/x-raw,format=BGR ! appsink drop=false sync=false",
                    cv2.CAP_GSTREAMER)
                _got, _frame = _cap.read()
                _cap.release()
                if _got and _frame is not None and _frame.ndim == 3:
                    print("  OK  cv2 gst pipeline videotestsrc->appsink delivered a %s frame"
                          % (_frame.shape,))
                else:
                    fails.append("cv2 GStreamer pipeline delivered NO frame (backend reports YES)")
                    print("  XX  cv2 gst pipeline videotestsrc->appsink delivered NO frame")
            if _ff_ok:
                # MJPG/AVI on purpose: it is the encoder every ffmpeg build we
                # ship carries, so a failure means the FFMPEG backend is broken,
                # not that a codec is missing.
                _p = os.path.join(_d, "roundtrip.avi")
                _fourcc = getattr(cv2, "VideoWriter_fourcc", None) or cv2.VideoWriter.fourcc
                _w = cv2.VideoWriter(_p, cv2.CAP_FFMPEG, _fourcc(*"MJPG"), 10.0, (64, 48))
                if not _w.isOpened():
                    fails.append("cv2 FFMPEG VideoWriter would not open (backend reports YES)")
                    print("  XX  cv2 ffmpeg roundtrip: VideoWriter did not open")
                else:
                    for _ in range(5):
                        _w.write(_np.full((48, 64, 3), 128, _np.uint8))
                    _w.release()
                    _rc = cv2.VideoCapture(_p, cv2.CAP_FFMPEG)
                    _got, _back = _rc.read()
                    _rc.release()
                    if _got and _back is not None and _back.shape == (48, 64, 3):
                        print("  OK  cv2 ffmpeg roundtrip encode->decode %d bytes, frame %s"
                              % (os.path.getsize(_p), _back.shape))
                    else:
                        fails.append("cv2 FFMPEG roundtrip wrote a file it cannot read back")
                        print("  XX  cv2 ffmpeg roundtrip: encoded clip did not decode")
        except Exception as _me:
            fails.append("cv2 media pipeline raised %s" % _me)
            print("  XX  cv2 media pipeline raised: %s" % _me)
        finally:
            _sh.rmtree(_d, ignore_errors=True)
except Exception as e:
    if cv_required:
        fails.append("cv2 %s" % e)
        print("  XX  cv2 import/version failed: %s" % e)
    else:
        print("  ..  cv2 not importable (optional here): %s" % e)

if not lock_loaded:
    print("  note: uv.lock not loaded -- only build-pinned packages asserted")
if tolerated:
    print("VERSION-ASSERT: %d TOLERATED DRIFT(s): %s -- each is one dated line in "
          "KNOWN_DRIFT; fix the producer and delete the line to re-arm the assert"
          % (len(tolerated), "; ".join(tolerated)))
if fails:
    print("VERSION-ASSERT: FAIL (%d mismatch(es))" % len(fails))
    sys.exit(1)
print("VERSION-ASSERT: PASS")
PYEOF
  )"; then rc=0; else rc=$?; fi
  printf '%s\n' "${out}" | sed 's/^/  /'
  local tolerated
  tolerated="$(printf '%s\n' "${out}" | sed -n 's/^VERSION-ASSERT: \([0-9]*\) TOLERATED.*/\1/p')"
  if [ "${rc}" -eq 0 ]; then
    if [ -n "${tolerated}" ]; then
      # Deliberately still a pass, but never a quiet one: the tolerance is a
      # dated single line in KNOWN_DRIFT above, not a blanket exemption.
      pass "installed ML-stack versions match pins, with ${tolerated} TOLERATED drift(s) (see the !! lines above)"
    else
      pass "installed ML-stack versions match pins (uv.lock + versions.env)"
    fi
  else
    fail "installed ML-stack versions DRIFTED from pins (see XX lines above)"
  fi
}

# APP-PARITY (2026-09-01): assert the venv really carries what `uv sync --extra
# ml-ai --extra docs` promises. riscv64 never runs uv sync (its fallback path
# installed the app's core deps only, which is how it shipped 109 packages fewer
# than amd64), so every riscv64 absence is one dated EXEMPT line with a reason
# instead of silence. docs/riscv64-venv-parity.md
assert_app_venv_parity() {
  echo "--- app venv parity (uv sync extras) ---"
  # Images that carry a venv but never ran assemble-torch-app.sh have no extras
  # to assert; the app package is the marker that it ran.
  if ! "${PY}" -c 'import orchestr_ant_ion' >/dev/null 2>&1; then
    printf '  SKIP app package not installed in this venv -- extras parity not applicable\n'
    return 0
  fi

  local out rc
  if out="$("${PY}" - <<'PYEOF'
import os, platform, sys
import importlib.metadata as M

_MACHINE_TO_ARCH = {"x86_64": "amd64", "amd64": "amd64",
                    "aarch64": "arm64", "arm64": "arm64", "riscv64": "riscv64"}
_raw_arch = os.environ.get("STV_ARCH") or platform.machine()
# An UNRECOGNISED machine keeps its raw name, so it matches no EXEMPT key and
# gets the strict assert rather than someone else's tolerance.
ARCH = _MACHINE_TO_ARCH.get(_raw_arch, _raw_arch)

# (dist, the uv sync extra that must deliver it). captum is deliberately absent:
# it comes from the pytorch-* extra and PYTORCH_EXTRA=none is a supported
# operator override, so requiring it would misfire on a valid configuration.
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
]

# (dist, arch) -> why the absence is a DECISION, not an accident. One line each,
# reviewed; anything not listed here still FAILS. docs/riscv64-venv-parity.md
EXEMPT = {
    ("pandas", "riscv64"):
        "no riscv64 wheel; ml-ai is uninstallable here (its riscv64 opencv-python is a git source pin)",
    ("scipy", "riscv64"):
        "no riscv64 wheel; multi-hour QEMU source build",
    ("scikit-learn", "riscv64"):
        "no riscv64 wheel; needs scipy, which has none either",
    ("optuna", "riscv64"):
        "only reachable via the ml-ai extra, which riscv64 cannot install",
    ("mlflow", "riscv64"):
        "app pyproject gates mlflow (and its ~60-package closure) off riscv64",
    ("boto3", "riscv64"):
        "app pyproject gates boto3 off riscv64",
    ("iree-base-compiler", "riscv64"):
        "riscv64 builds IREE runtime-only (compiler=OFF, upstream-consistent)",
}

fails, exempted, stale = [], [], []
for dist, extra in REQUIRED:
    try:
        installed = M.version(dist)
    except Exception:
        installed = None
    why = EXEMPT.get((dist, ARCH))
    if installed is not None:
        if why:
            stale.append(dist)
            print("  ??  %-20s %s is INSTALLED but listed EXEMPT on %s -- delete the line"
                  % (dist, installed, ARCH))
        else:
            print("  OK  %-20s %-14s (extra %s)" % (dist, installed, extra))
    elif why:
        exempted.append(dist)
        print("  ~~  %-20s absent on %s BY DECISION -- %s" % (dist, ARCH, why))
    else:
        fails.append(dist)
        print("  XX  %-20s MISSING -- extra %s must deliver it on %s" % (dist, extra, ARCH))

if exempted:
    print("APP-PARITY: %d documented exemption(s) on %s: %s"
          % (len(exempted), ARCH, ", ".join(exempted)))
if fails:
    print("APP-PARITY: FAIL (%d missing)" % len(fails))
    sys.exit(1)
print("APP-PARITY: PASS")
PYEOF
  )"; then rc=0; else rc=$?; fi
  printf '%s\n' "${out}" | sed 's/^/  /'
  if [ "${rc}" -eq 0 ]; then
    pass "app venv carries the uv sync extras (documented exemptions aside)"
  else
    fail "app venv is MISSING packages the uv sync extras must deliver (see XX lines above)"
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
    assert_app_venv_parity
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
    # it answers from a library that cannot actually load a graph.
    # SMOKE-DEPTH(c) 2026-08-23: this used to generate the model with
    # torch.onnx.export, which needs `onnxscript` — absent from the shipped
    # venv — so the except-branch exited 3 and the smoke printed "SKIP ort
    # InferenceSession check" on ALL THREE wave-5 arches. Permanently green,
    # never once executed. smoke_minimal_onnx_py emits the graph as raw
    # protobuf instead: no `onnx`/`onnxscript` dependency, no network, and it
    # no longer needs torch either (so a torch-less image is covered too).
    # Same rule as the host-side gate in smoke-runtime-image.sh: exit status is
    # not evidence. `python -` on an EMPTY program exits 0, so a pass requires
    # the program's own `ONNX-EP OK:` sentinel in the OUTPUT.
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
  fi

  # Not just "importable" but "the CORRECT versions": assert each ML package
  # matches its pin (uv.lock for uv-resolved packages, versions.env for the ones
  # we build / force-reinstall from a local wheel).
  assert_pinned_versions
  assert_app_venv_parity

  smoke_summary
}

main "$@"
