#!/usr/bin/env python3
"""Check installed venv versions and media behavior; see docs/cross-build-verification.md#smoke-torch-venv-what-the-venv-assertions-cover."""
import os
import re
import importlib
import platform

_MACHINE_TO_ARCH = {"x86_64": "amd64", "amd64": "amd64",
                    "aarch64": "arm64", "arm64": "arm64", "riscv64": "riscv64"}
_raw_arch = os.environ.get("STV_ARCH") or platform.machine()
ARCH = _MACHINE_TO_ARCH.get(_raw_arch, _raw_arch)
is_riscv64 = ARCH == "riscv64"

def base(v):
    return v.split("+", 1)[0].strip() if v else v

def localseg(v):
    return v.split("+", 1)[1] if v and "+" in v else ""

_DEV_MARKER = re.compile(r"(a|b|rc|\.dev)\d*$")

def pin_set(val):
    return {base(val)} if val else set()

KNOWN_DRIFT = [
]

def tolerated_drift(dist_name, arch, installed_base, expected):
    for _d, _a, _i, _e, _why in KNOWN_DRIFT:
        if (_d, _a, _i, _e) == (dist_name, arch, installed_base, expected):
            return _why
    return None


SPECS = [
    ("torch",          "torch",          os.environ.get("EXP_PYTORCH", ""),     True),
    ("torchvision",    "torchvision",    os.environ.get("EXP_TORCHVISION", ""), True),
    ("onnxruntime",    "onnxruntime",    os.environ.get("EXP_ONNX", ""),        False),
    ("numpy",          "numpy",          "",                                    False),
    ("PIL",            "pillow",         "",                                    False),
    ("contourpy",      "contourpy",      "",                                    False),
    ("ai_edge_litert", "ai-edge-litert", os.environ.get("EXP_LITERT", ""),      False),
    ("onnxruntime_genai", "onnxruntime-genai", os.environ.get("EXP_GENAI", ""), False),
]


extra = os.environ.get("PYTORCH_EXTRA", "")
want_variant = {"pytorch-cpu": "cpu", "pytorch-cu130": "cu130",
                "pytorch-rocm10": os.environ.get("PYTORCH_ROCM_INDEX", "rocm7.14")}.get(extra, "")

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

expected_absent = set()
if is_riscv64 and os.environ.get("GENAI_ALLOW_RISCV64", "true").strip().lower() != "true":
    expected_absent.add("onnxruntime-genai")

def load_lock():
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
    return lock_bases, lock_loaded

def report_mismatch(dist_name, inst, ib, build_pin, from_lock, allowed, fails, tolerated):
    why = "versions.env build pin" if build_pin else "uv.lock"
    expected = ",".join(sorted(allowed))
    lock_note = ("; lock has " + ",".join(sorted(from_lock))) if (build_pin and from_lock) else ""
    excuse = tolerated_drift(dist_name, ARCH, ib, expected)
    if excuse:
        tolerated.append("%s %s != %s on %s" % (dist_name, inst, expected, ARCH))
        print("  !!  %-16s installed %s != expected %s on %s (%s is authoritative%s)"
              % (dist_name, inst, expected, ARCH, why, lock_note))
        print("  !!  %-16s TOLERATED DRIFT -- %s" % ("", excuse))
    else:
        fails.append("%s installed %s not in %s (%s)" % (dist_name, inst, sorted(allowed), why))
        print("  XX  %-16s installed %s NOT in expected %s (%s is authoritative%s)"
              % (dist_name, inst, sorted(allowed), why, lock_note))

def check_base_version(dist_name, inst, ib, build_pin, from_lock, allowed, fails, tolerated):
    ib_cmp = _DEV_MARKER.sub("", ib) if (build_pin and localseg(inst)) else ib
    if ib in allowed or ib_cmp in allowed:
        src = "versions.env" if build_pin else "uv.lock"
        note = ""
        if build_pin and from_lock and not ({ib, ib_cmp} & from_lock):
            note = " [uv.lock says %s; build pin wins]" % ",".join(sorted(from_lock))
        print("  OK  %-16s %-16s (matches %s)%s" % (dist_name, inst, src, note))
    elif is_riscv64 and not build_pin:
        print("  ~~  %-16s installed %s (riscv64 re-resolved; accepted, lock pin %s)"
              % (dist_name, inst, sorted(allowed)))
    else:
        report_mismatch(dist_name, inst, ib, build_pin, from_lock, allowed, fails, tolerated)


def check_variant(dist_name, inst, torchlike, fails):
    if torchlike and want_variant:
        lv = localseg(inst)
        if is_riscv64:
            print("  ~~  %-16s build variant +%s (riscv64 local wheel; not asserted)"
                  % (dist_name, lv or "?"))
        elif lv and lv != want_variant:
            fails.append("%s variant +%s != +%s" % (dist_name, lv, want_variant))
            print("  XX  %-16s build variant +%s != expected +%s (PYTORCH_EXTRA=%s)"
                  % (dist_name, lv, want_variant, extra))
        elif lv == want_variant:
            print("  OK  %-16s build variant +%s (matches %s)" % (dist_name, lv, extra))

def check_package(spec, lock_bases, fails, tolerated):
    import_name, dist_name, build_pin, torchlike = spec
    inst = installed_version(import_name, dist_name)
    if inst is None:
        if dist_name in expected_absent:
            print("  ~~  %-16s not installed (riscv64 GenAI lane off via GENAI_ALLOW_RISCV64; policy, not drift)" % dist_name)
            return
        fails.append("%s NOT INSTALLED" % dist_name)
        print("  XX  %-16s NOT INSTALLED" % dist_name)
        return
    ib = base(inst)
    from_lock = lock_bases.get(dist_name, set())
    allowed = pin_set(build_pin) if build_pin else set(from_lock)
    if not allowed:
        print("  ??  %-16s %s: no pin available -- not asserted" % (dist_name, inst))
        return
    check_base_version(dist_name, inst, ib, build_pin, from_lock, allowed, fails, tolerated)
    check_variant(dist_name, inst, torchlike, fails)

def check_tvm(fails):
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

def check_gstreamer(cv2, fails):
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


def check_ffmpeg(cv2, _np, _d, fails):
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

def check_media(cv2, _gst_ok, _ff_ok, fails):
    import shutil as _sh, tempfile as _tf
    _d = _tf.mkdtemp()
    try:
        import numpy as _np
        if _gst_ok:
            check_gstreamer(cv2, fails)
        if _ff_ok:
            check_ffmpeg(cv2, _np, _d, fails)
    except Exception as _me:
        fails.append("cv2 media pipeline raised %s" % _me)
        print("  XX  cv2 media pipeline raised: %s" % _me)
    finally:
        _sh.rmtree(_d, ignore_errors=True)

def check_cv2(fails):
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
        import re as _re
        _binfo = cv2.getBuildInformation()
        def _backend(name):
            m = _re.search(name + r":\s*(\S+)", _binfo)
            return m.group(1) if m else "?"
        _gst = _backend("GStreamer")
        _ff  = _backend("FFMPEG")
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
        if os.environ.get("STV_MEDIA_FUNCTIONAL", "1") == "1":
            check_media(cv2, _gst_ok, _ff_ok, fails)
    except Exception as e:
        if cv_required:
            fails.append("cv2 %s" % e)
            print("  XX  cv2 import/version failed: %s" % e)
        else:
            print("  ..  cv2 not importable (optional here): %s" % e)

def main():
    lock_bases, lock_loaded = load_lock()
    fails, tolerated = [], []
    for spec in SPECS:
        check_package(spec, lock_bases, fails, tolerated)
    check_tvm(fails)
    check_cv2(fails)
    if not lock_loaded:
        print("  note: uv.lock not loaded -- only build-pinned packages asserted")
    if tolerated:
        print("VERSION-ASSERT: %d TOLERATED DRIFT(s): %s -- each is one dated line in "
              "KNOWN_DRIFT; fix the producer and delete the line to re-arm the assert"
              % (len(tolerated), "; ".join(tolerated)))
    if fails:
        print("VERSION-ASSERT: FAIL (%d mismatch(es))" % len(fails))
        return 1
    print("VERSION-ASSERT: PASS")
    return 0

if __name__ == "__main__":
    raise SystemExit(main())
