#!/usr/bin/env python3
"""Check installed venv versions and media behavior; see docs/cross-build-verification.md#smoke-torch-venv-what-the-venv-assertions-cover."""

import importlib
import os
import platform
import re
import tomllib
from importlib import metadata
from typing import Any

_MACHINE_TO_ARCH: dict[str, str] = {
    "x86_64": "amd64",
    "amd64": "amd64",
    "aarch64": "arm64",
    "arm64": "arm64",
    "riscv64": "riscv64",
}
_raw_arch: str = os.environ.get("STV_ARCH") or platform.machine()
ARCH: str = _MACHINE_TO_ARCH.get(_raw_arch, _raw_arch)
is_riscv64: bool = ARCH == "riscv64"


def base(v: str) -> str:
    return v.split("+", 1)[0].strip() if v else v


def localseg(v: str) -> str:
    return v.split("+", 1)[1] if v and "+" in v else ""


_DEV_MARKER = re.compile(r"(a|b|rc|\.dev)\d*$")


def pin_set(val: str) -> set[str]:
    return {base(val)} if val else set()


KNOWN_DRIFT: list[tuple[str, str, str, str, str]] = []


def tolerated_drift(
    dist_name: str, arch: str, installed_base: str, expected: str
) -> str | None:
    for _d, _a, _i, _e, _why in KNOWN_DRIFT:
        if (_d, _a, _i, _e) == (dist_name, arch, installed_base, expected):
            return _why
    return None


SPECS = [
    ("torch", "torch", os.environ.get("EXP_PYTORCH", ""), True),
    ("torchvision", "torchvision", os.environ.get("EXP_TORCHVISION", ""), True),
    ("onnxruntime", "onnxruntime", os.environ.get("EXP_ONNX", ""), False),
    ("numpy", "numpy", "", False),
    ("PIL", "pillow", "", False),
    ("contourpy", "contourpy", "", False),
    ("ai_edge_litert", "ai-edge-litert", os.environ.get("EXP_LITERT", ""), False),
    ("onnxruntime_genai", "onnxruntime-genai", os.environ.get("EXP_GENAI", ""), False),
]


extra = os.environ.get("PYTORCH_EXTRA", "")
want_variant = {
    "pytorch-cpu": "cpu",
    "pytorch-cu130": "cu130",
    "pytorch-rocm10": os.environ.get("PYTORCH_ROCM_INDEX", "rocm7.14"),
}.get(extra, "")


def installed_version(import_name: str, dist_name: str) -> str | None:
    try:
        mod = importlib.import_module(import_name)
    except (ImportError, OSError):
        mod = None
    if mod is not None:
        version = getattr(mod, "__version__", None)
        if version:
            return str(version)
    try:
        return metadata.version(dist_name)
    except metadata.PackageNotFoundError:
        return None


expected_absent: set[str] = set()
if (
    is_riscv64
    and os.environ.get("GENAI_ALLOW_RISCV64", "true").strip().lower() != "true"
):
    expected_absent.add("onnxruntime-genai")


def load_lock() -> tuple[dict[str, set[str]], bool]:
    lock_bases: dict[str, set[str]] = {}
    lock_loaded = False
    lock_path = os.environ.get("UVLOCK", "")
    if lock_path and os.path.exists(lock_path):
        try:
            with open(lock_path, "rb") as f:
                data = tomllib.load(f)
            for p in data.get("package", []):
                lock_bases.setdefault(p.get("name", ""), set()).add(
                    base(p.get("version", ""))
                )
            lock_loaded = True
        except (OSError, tomllib.TOMLDecodeError) as error:
            raise SystemExit(f"ERROR: could not parse uv.lock at {lock_path}: {error}")
    return lock_bases, lock_loaded


def report_mismatch(
    dist_name: str,
    inst: str,
    ib: str,
    build_pin: str,
    from_lock: set[str],
    allowed: set[str],
    fails: list[str],
    tolerated: list[str],
) -> None:
    why = "versions.env build pin" if build_pin else "uv.lock"
    expected = ",".join(sorted(allowed))
    lock_note = (
        ("; lock has " + ",".join(sorted(from_lock)))
        if (build_pin and from_lock)
        else ""
    )
    excuse = tolerated_drift(dist_name, ARCH, ib, expected)
    if excuse:
        tolerated.append(f"{dist_name} {inst} != {expected} on {ARCH}")
        print(
            f"  !!  {dist_name:<16} installed {inst} != expected {expected} on {ARCH} "
            f"({why} is authoritative{lock_note})"
        )
        print(f"  !!  {'':<16} TOLERATED DRIFT -- {excuse}")
    else:
        fails.append(f"{dist_name} installed {inst} not in {sorted(allowed)} ({why})")
        print(
            f"  XX  {dist_name:<16} installed {inst} NOT in expected {sorted(allowed)} "
            f"({why} is authoritative{lock_note})"
        )


def check_base_version(
    dist_name: str,
    inst: str,
    ib: str,
    build_pin: str,
    from_lock: set[str],
    allowed: set[str],
    fails: list[str],
    tolerated: list[str],
) -> None:
    ib_cmp = _DEV_MARKER.sub("", ib) if (build_pin and localseg(inst)) else ib
    if ib in allowed or ib_cmp in allowed:
        src = "versions.env" if build_pin else "uv.lock"
        note = ""
        if build_pin and from_lock and not ({ib, ib_cmp} & from_lock):
            note = " [uv.lock says {}; build pin wins]".format(
                ",".join(sorted(from_lock))
            )
        print(f"  OK  {dist_name:<16} {inst:<16} (matches {src}){note}")
    elif is_riscv64 and not build_pin:
        print(
            f"  ~~  {dist_name:<16} installed {inst} "
            f"(riscv64 re-resolved; accepted, lock pin {sorted(allowed)})"
        )
    else:
        report_mismatch(
            dist_name, inst, ib, build_pin, from_lock, allowed, fails, tolerated
        )


def check_variant(dist_name: str, inst: str, torchlike: bool, fails: list[str]) -> None:
    if torchlike and want_variant:
        lv = localseg(inst)
        if is_riscv64:
            print(
                f"  ~~  {dist_name:<16} build variant +{lv or '?'} "
                "(riscv64 local wheel; not asserted)"
            )
        elif lv and lv != want_variant:
            fails.append(f"{dist_name} variant +{lv} != +{want_variant}")
            print(
                f"  XX  {dist_name:<16} build variant +{lv} != expected +{want_variant} "
                f"(PYTORCH_EXTRA={extra})"
            )
        elif lv == want_variant:
            print(f"  OK  {dist_name:<16} build variant +{lv} (matches {extra})")


def check_package(
    spec: tuple[str, str, str, bool],
    lock_bases: dict[str, set[str]],
    fails: list[str],
    tolerated: list[str],
) -> None:
    import_name, dist_name, build_pin, torchlike = spec
    inst = installed_version(import_name, dist_name)
    if inst is None:
        if dist_name in expected_absent:
            print(
                f"  ~~  {dist_name:<16} not installed "
                "(riscv64 GenAI lane off via GENAI_ALLOW_RISCV64; policy, not drift)"
            )
            return
        fails.append(f"{dist_name} NOT INSTALLED")
        print(f"  XX  {dist_name:<16} NOT INSTALLED")
        return
    ib = base(inst)
    from_lock = lock_bases.get(dist_name, set())
    allowed = pin_set(build_pin) if build_pin else set(from_lock)
    if not allowed:
        print(f"  ??  {dist_name:<16} {inst}: no pin available -- not asserted")
        return
    check_base_version(
        dist_name, inst, ib, build_pin, from_lock, allowed, fails, tolerated
    )
    check_variant(dist_name, inst, torchlike, fails)


def check_tvm(fails: list[str]) -> None:
    try:
        import tvm as _tvm

        _tvm_v = getattr(_tvm, "__version__", "?")
        print(f"  ok  {'tvm':<16} {_tvm_v}")
        _exp_tvm = os.environ.get("EXP_TVM", "")
        if _exp_tvm:
            _exp_mm = ".".join(_exp_tvm.lstrip("v").split(".")[:2])
            _tvm_mm = ".".join(str(_tvm_v).split(".")[:2])
            if _tvm_mm != _exp_mm:
                fails.append(
                    f"tvm {_tvm_v} major.minor != {_exp_mm} (from TVM_REF={_exp_tvm})"
                )
    except (ImportError, OSError, RuntimeError) as _e:
        if os.environ.get("EXP_TVM", ""):
            fails.append(f"tvm NOT IMPORTABLE but EXP_TVM set: {_e}")
        else:
            print(
                f"  --  {'tvm':<16} not importable (best-effort; media build shipped without it)"
            )


def check_gstreamer(cv2: Any, fails: list[str]) -> None:
    _cap = cv2.VideoCapture(
        "videotestsrc num-buffers=1 ! videoconvert !"
        " video/x-raw,format=BGR ! appsink drop=false sync=false",
        cv2.CAP_GSTREAMER,
    )
    _got, _frame = _cap.read()
    _cap.release()
    if _got and _frame is not None and _frame.ndim == 3:
        print(
            f"  OK  cv2 gst pipeline videotestsrc->appsink delivered a {_frame.shape} frame"
        )
    else:
        fails.append("cv2 GStreamer pipeline delivered NO frame (backend reports YES)")
        print("  XX  cv2 gst pipeline videotestsrc->appsink delivered NO frame")


def check_ffmpeg(cv2: Any, _np: Any, _d: str, fails: list[str]) -> None:
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
            print(
                f"  OK  cv2 ffmpeg roundtrip encode->decode {os.path.getsize(_p)} bytes, "
                f"frame {_back.shape}"
            )
        else:
            fails.append("cv2 FFMPEG roundtrip wrote a file it cannot read back")
            print("  XX  cv2 ffmpeg roundtrip: encoded clip did not decode")


def _cv2_error_types(cv2: Any) -> tuple[type[Exception], ...]:
    return (
        ImportError,
        OSError,
        RuntimeError,
        ValueError,
        TypeError,
        AttributeError,
        cv2.error,
    )


def check_media(cv2: Any, _gst_ok: bool, _ff_ok: bool, fails: list[str]) -> None:
    import shutil as _sh
    import tempfile as _tf

    _d = _tf.mkdtemp()
    try:
        import numpy as _np

        if _gst_ok:
            check_gstreamer(cv2, fails)
        if _ff_ok:
            check_ffmpeg(cv2, _np, _d, fails)
    except _cv2_error_types(cv2) as _me:
        fails.append(f"cv2 media pipeline raised {_me}")
        print(f"  XX  cv2 media pipeline raised: {_me}")
    finally:
        _sh.rmtree(_d, ignore_errors=True)


def _report_cv2_error(error: Exception, cv_required: bool, fails: list[str]) -> None:
    if cv_required:
        fails.append(f"cv2 {error}")
        print(f"  XX  cv2 import/version failed: {error}")
    else:
        print(f"  ..  cv2 not importable (optional here): {error}")


def check_cv2(fails: list[str]) -> None:
    cv_major = os.environ.get("EXP_OPENCV_MAJOR", "")
    cv_required = os.environ.get("STV_CV2_REQUIRED", "1") == "1"
    try:
        import cv2
    except (ImportError, OSError, RuntimeError) as error:
        _report_cv2_error(error, cv_required, fails)
        return

    try:
        cvv = cv2.__version__
        if cv_major and cvv.split(".")[0] != cv_major:
            fails.append(f"opencv/cv2 {cvv} major != {cv_major}")
            print(f"  XX  {'opencv/cv2':<16} {cvv}: major != {cv_major}")
        else:
            print(f"  OK  {'opencv/cv2':<16} {cvv:<16} (major {cv_major or '?'})")
        import re as _re

        _binfo = cv2.getBuildInformation()

        def _backend(name: str) -> str:
            m = _re.search(name + r":\s*(\S+)", _binfo)
            return m.group(1) if m else "?"

        _gst = _backend("GStreamer")
        _ff = _backend("FFMPEG")
        _gst_ok = _gst.upper().startswith("YES")
        _ff_ok = _ff.upper().startswith("YES")
        if _gst_ok and _ff_ok:
            print(f"  OK  cv2 videoio      GStreamer={_gst}; FFMPEG={_ff}")
        else:
            if not _gst_ok:
                fails.append(
                    f"cv2 GStreamer backend={_gst} (two-pass regressed; expected YES)"
                )
            if not _ff_ok:
                fails.append(
                    f"cv2 FFMPEG backend={_ff} (OCV-FF1 regressed; expected YES)"
                )
            print(
                f"  XX  cv2 videoio      GStreamer={_gst} FFMPEG={_ff} — REGRESSED (both expected YES)"
            )
        if os.environ.get("STV_MEDIA_FUNCTIONAL", "1") == "1":
            check_media(cv2, _gst_ok, _ff_ok, fails)
    except _cv2_error_types(cv2) as error:
        _report_cv2_error(error, cv_required, fails)


def main() -> int:
    lock_bases, lock_loaded = load_lock()
    fails, tolerated = [], []
    for spec in SPECS:
        check_package(spec, lock_bases, fails, tolerated)
    check_tvm(fails)
    check_cv2(fails)
    if not lock_loaded:
        print("  note: uv.lock not loaded -- only build-pinned packages asserted")
    if tolerated:
        print(
            f"VERSION-ASSERT: {len(tolerated)} TOLERATED DRIFT(s): {'; '.join(tolerated)} "
            "-- each is one dated line in KNOWN_DRIFT; fix the producer and delete the line "
            "to re-arm the assert"
        )
    if fails:
        print(f"VERSION-ASSERT: FAIL ({len(fails)} mismatch(es))")
        return 1
    print("VERSION-ASSERT: PASS")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
