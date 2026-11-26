"""Who updates each pin: one default renovate-local.sh run, the report tier's --write-all, or a hand edit."""
from __future__ import annotations

import inspect
import json
import re
from collections import Counter
from collections.abc import Callable
from pathlib import Path

import bump_versions as bv  # tests patch names on bump_versions; every call reads them through it

# Pin values that are switches, paths or target sets, not upstream versions.
NONVERSION = re.compile(
    r"(SHA256|SHA512|_ENABLE_|^USE_|_ALLOW_CROSS$|^FAST_UBUNTU|^IMAGE_REGISTRY_PREFIX$"
    r"|^CROSS_DEFAULT_ARCHES$|^VENV_PATH$|_OUTPUT_DIR$|^GSTREAMER_PREFIX$"
    r"|^CUDA_ARCHITECTURES$|^WINDOWS_TARGET_ARCH(ES)?$"
    r"|^CI_IMAGE_|^ANDROID_TARGET_ABI$|^GENAI_ALLOW_RISCV64$|^FT_TORCH_TWIN$|^JDK_PACKAGE$"
    r"|^ROCM_WINDOWS_GFX_FAMILY$"  # a GPU target set, like CUDA_ARCHITECTURES
    r"|^APP_REF$)"  # a tracked branch, resolved to a commit per run
)

# Commit, asset and sub-dependency pins no spec writes, each with the pin it is moved with by hand.
FOLLOWS: dict[str, str] = {
    "ONNXRUNTIME_WINDOWS_SOURCE_COMMIT": "ONNXRUNTIME_VERSION",
    "ORT_WEBGPU_WINDOWS_DAWN_VERSION": "ONNXRUNTIME_VERSION",
    "ONNXRUNTIME_GENAI_WINDOWS_SOURCE_COMMIT": "ONNXRUNTIME_GENAI_VERSION",
    "OPENCV_COMMIT": "OPENCV_VERSION",
    "OPENCV_CONTRIB_COMMIT": "OPENCV_VERSION",
    "FFMPEG_COMMIT": "FFMPEG_VERSION",
    "MIGRAPHX_WINDOWS_COMMIT": "MIGRAPHX_VERSION",
    "MIGRAPHX_ROCM_CMAKE_COMMIT": "MIGRAPHX_VERSION",
    "MIGRAPHX_CK_COMMIT": "MIGRAPHX_VERSION",
    "MIGRAPHX_ROCMLIR_COMMIT": "MIGRAPHX_VERSION",
    **{f"ORT_AMDGPU_EP_{dep}_VERSION": "ORT_AMDGPU_EP_COMMIT"
       for dep in ("FMT", "GSL", "JSON", "ZLIB", "PROTOBUF", "ABSEIL", "ONNX", "FLATBUFFERS", "RANGE_V3")},
    "ORT_QNN_EP_CORE_COMMIT": "ORT_QNN_EP_VERSION",
    **{f"ORT_TENSORRT_EP_{dep}": "ORT_TENSORRT_EP_COMMIT"
       for dep in ("PROTOBUF_VERSION", "ONNX_COMMIT", "GSL_VERSION", "FLATBUFFERS_VERSION")},
}

# Pins with no feed a spec could read, each moved by hand on its own.
STANDALONE: dict[str, str] = {
    "ORT_AMDGPU_EP_COMMIT": "the plugin's main commit; upstream tags no releases",
    "ORT_TENSORRT_EP_COMMIT": "the plugin's newest main commit; upstream tags no releases",
    "ORT_QNN_EP_VERSION": "Qualcomm's fork tag, coupled to QAIRT and the chain ORT",
}

ONE_CALL = ("renovate", "bump", "bump extra")


def _spec_source(spec: Callable[..., object]) -> str:
    """The spec's own source plus the bump helpers it calls by name, one level deep."""
    try:
        text = inspect.getsource(spec)
    except (OSError, TypeError):
        return ""
    for name in set(re.findall(r"\b(?:bv\.)?([a-z_][a-z0-9_]+)\(", text)):
        helper = getattr(bv, name, None)
        if callable(helper) and getattr(helper, "__module__", "").startswith("bump"):
            try:
                text += inspect.getsource(helper)
            except (OSError, TypeError):
                continue
    return text


def spec_extras(env: dict[str, str]) -> dict[str, tuple[str, str]]:
    """Keys a spec writes beside its own key, found as quoted key literals in that spec: key -> (owner, tier)."""
    out: dict[str, tuple[str, str]] = {}
    for tier, rows in (("bump", [(k, s) for k, s, _ in bv.SAFE]), ("report", list(bv.REPORT))):
        for owner, spec in rows:
            text = _spec_source(spec)
            for key in env:
                if key != owner and key not in out and re.search(rf"[\"']{key}[\"']", text):
                    out[key] = (owner, tier)
    for key, owner in bv.derived_keys().items():
        out.setdefault(key, (owner, "report"))
    return out


def classify(env: dict[str, str]) -> dict[str, tuple[str, str]]:
    """Every pin-file key -> (class, detail); class UNCLASSIFIED is the gate's failure."""
    renovate = bv.renovate_owned()
    safe = {k for k, _, _ in bv.SAFE}
    report = {k for k, _ in bv.REPORT}
    manual = set(bv.MANUAL)
    extras = spec_extras(env)
    wheels = bv.wheel_url_keys(env)
    out: dict[str, tuple[str, str]] = {}
    for key in env:
        if key in renovate:
            out[key] = ("renovate", "")
        elif key in safe:
            out[key] = ("bump", "")
        elif key in report:
            out[key] = ("report", "written only by --write-all")
        elif key in extras:
            owner, tier = extras[key]
            out[key] = ("bump extra" if tier == "bump" else "report extra", f"with {owner}")
        elif key in FOLLOWS:
            out[key] = ("hand", f"with {FOLLOWS[key]}")
        elif key in STANDALONE:
            out[key] = ("hand", STANDALONE[key])
        elif key in manual or key in wheels:
            out[key] = ("hand", "MANUAL" if key in manual else "wheel group")
        elif NONVERSION.search(key):
            out[key] = ("checksum" if re.search(r"SHA(256|512)", key) else "not a version", "")
        else:
            out[key] = ("UNCLASSIFIED", "")
    return out


def stale_rows(env: dict[str, str], classes: dict[str, tuple[str, str]]) -> list[str]:
    """FOLLOWS/STANDALONE rows that name no key, or whose key another class already covers."""
    problems = []
    for key, owner in FOLLOWS.items():
        if key not in env or owner not in env:
            problems.append(f"FOLLOWS {key} -> {owner}: no such pin")
        elif classes[key] != ("hand", f"with {owner}"):
            problems.append(f"FOLLOWS {key}: already {classes[key][0]}, delete the row")
    for key, reason in STANDALONE.items():
        if key not in env:
            problems.append(f"STANDALONE {key}: no such pin")
        elif classes[key] != ("hand", reason):
            problems.append(f"STANDALONE {key}: already {classes[key][0]}, delete the row")
    return problems


def drift(env: dict[str, str], classes: dict[str, tuple[str, str]]) -> list[tuple[str, str, str]]:
    """Set hand-moved pins whose owner one call moves: (key, owner, owner's class); an empty pin follows the tag."""
    out = []
    for key, owner in FOLLOWS.items():
        if env.get(key) and classes.get(key, ("",))[0] == "hand" and classes.get(owner, ("",))[0] in ONE_CALL:
            out.append((key, owner, classes[owner][0]))
    return out


def _print_report(env: dict[str, str], classes: dict[str, tuple[str, str]], brief: bool) -> None:
    counts = Counter(c for c, _ in classes.values())
    one = sum(counts[c] for c in ONE_CALL)
    print(f"pin coverage: {len(classes)} keys; one renovate-local.sh run writes {one}")
    print("  " + ", ".join(f"{counts[c]} {c}" for c in sorted(counts)))
    risky = drift(env, classes)
    if risky:
        print(f"\nDRIFT ({len(risky)}): one run moves the owner, these stay by hand")
        holds = bv.read_holds()
        for key, owner, cls in risky:
            print(f"  {key:44} with {owner} ({cls}){', held' if key in holds else ''}")
    hand = sorted(k for k, (c, _) in classes.items()
                  if c in ("hand", "report", "report extra") and not re.search(r"SHA(256|512)$|_URL$", k))
    print(f"\nVERSIONS NOT IN ONE CALL ({len(hand)}; their checksums and URLs move with them):")
    if brief:
        print("  listed by: python3 docs/scripts/bump_versions.py --audit-coverage")
        return
    for key in hand:
        cls, detail = classes[key]
        print(f"  {key:44} {cls}{': ' + detail if detail else ''}")


def audit_coverage(json_path: str = "", brief: bool = False) -> int:
    """Print who updates each pin; fail on an unclassified key or a stale FOLLOWS/STANDALONE row."""
    env = bv.read_env()
    classes = classify(env)
    _print_report(env, classes, brief)
    if json_path:
        Path(json_path).write_text(json.dumps({k: list(v) for k, v in sorted(classes.items())}, indent=1) + "\n",
                                   encoding="utf-8")
    bad = [k for k, (c, _) in classes.items() if c == "UNCLASSIFIED"] + stale_rows(env, classes)
    if bad:
        print(f"\nCOVERAGE FAILED ({len(bad)}): a pin with no updater, or a stale table row")
        for item in bad:
            print(f"  {item}")
        return 1
    return 0
