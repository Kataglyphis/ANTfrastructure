#!/usr/bin/env python3
"""Every version-shaped ENV the runtime image advertises must be checked or excused.

docs/cross-build-verification.md#advertised-version-keys-advert-keys
"""
import glob
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
# Globbed, not listed, so a new Dockerfile cannot slip past.
DOCKERFILE_GLOB = "linux/Dockerfile.*"
SMOKE = "linux/scripts/06-packaging/smoke-runtime-image.sh"

# Not a version to compare, with the reason. A stale entry fails.
EXCUSED = {
    "VCS_REF": "a git sha, not a version",
    "PYTHON_VERSION": "ARG-only by design: nothing stages /opt/python-cross into the "
                      "runtime image, so it ships the DISTRO python and the ARG's patch "
                      "level would be a label the artefact contradicts. PYTHON_MAJOR_MINOR "
                      "is ENV and IS checked",
    "APP_REF": "a git ref, not a version string",
    "TVM_REF": "built off-tag; tvm.__version__ reports 0.26.dev1, not the ref",
    "CARGO_C_VERSION": "build-stage only (cargo-c), not shipped",
    "FLUTTER_VERSION": "flutter lane, not the cross runtime image",
    "LITERTJS_VERSION": "a JS package, not importable from the venv",
    "MEDIAPIPE_GENAI_VERSION": "android/mediapipe lane, not the cross runtime image",
    "ANDROID_CMAKE_VERSION": "android lane image, not the cross runtime image",
    "ANDROID_NDK_VERSION": "android lane image, not the cross runtime image",
    "HAILORT_VERSION": "graded by the Hailo RUN in Dockerfile.torch, not the runtime "
                       "smoke: build-hailort.sh fails the build unless hailortcli "
                       "--version and gst-inspect-1.0 hailonet pass (amd64/arm64)",
    "HAILO_PROTOBUF_VERSION": "Hailo build external, build-stage only",
    "TAPPAS_VERSION": "build-stage pin; presence is proven by the build's own gst-inspect-1.0 hailotools",
    "HAILO_LIBZMQ_VERSION": "build-stage pin for TAPPAS's zmq elements; presence is proven by pkg-config in the build",
    "HAILO_CPPZMQ_VERSION": "build-stage pin for the C++ zmq header; presence is proven by the TAPPAS build",
    "ANDROID_SDK_VERSION": "android lane image, not the cross runtime image",
    "CUDA_VERSION": "nvidia lane image, not the 3-arch cross runtime",
    "CUDNN_VERSION": "nvidia lane image, not the 3-arch cross runtime",
    "TENSORRT_VERSION": "nvidia lane image, not the 3-arch cross runtime",
    "ROCM_VERSION": "amd lane image, not the 3-arch cross runtime",
    "MIGRAPHX_VERSION": "amd lane image, not the 3-arch cross runtime",
}
SHAPED = re.compile(r"(VERSION|RELEASE|REF)$")


# Rows the probe never prints can only SKIP; write the probe rather than add an entry.
FROZEN_UNPROBED = set()


def _advertised(seen_files) -> set[str]:
    advertised = set()
    for dpath in seen_files:
        with open(dpath) as fh:
            for ln in fh:
                m = re.match(r"\s*(?:ENV|ARG)\s+([A-Z0-9_]+)", ln)
                if m and SHAPED.search(m.group(1)):
                    advertised.add(m.group(1))
    return advertised


def _report_unchecked(advertised, checked) -> int:
    unchecked = sorted(advertised - checked - set(EXCUSED))
    for k in unchecked:
        sys.stderr.write(
            f"FAIL: {k} is advertised by the image but neither checked by the smoke's "
            "advertised-vs-actual gate nor excused -- add a HAVE probe + a row in "
            "_ADVERTISED_VERSION_KEYS, or an EXCUSED entry saying why not.\n")
    return 1 if unchecked else 0


def _report_stale(advertised, checked) -> int:
    stale = sorted(set(EXCUSED) - advertised - checked)
    for k in stale:
        sys.stderr.write(
            f"FAIL: STALE excuse for {k} ({EXCUSED[k]}) -- the image no longer advertises it; "
            "delete the EXCUSED entry.\n")
    return 1 if stale else 0


def _report_new_unprobed(checked, probed) -> int:
    unprobed = sorted(checked - probed)
    new_unprobed = [k for k in unprobed if k not in FROZEN_UNPROBED]
    if new_unprobed:
        for k in new_unprobed:
            sys.stderr.write(
                f"FAIL: {k} sits in _ADVERTISED_VERSION_KEYS but the in-image probe "
                f"prints no `ADV {k}` line, so its row can only ever SKIP -- add the "
                "printf next to the others, or drop the row.\n")
        return 1
    return 0


def _report_healed(probed) -> int:
    healed = sorted(FROZEN_UNPROBED & probed)
    if healed:
        for k in healed:
            sys.stderr.write(
                f"FAIL: {k} now HAS a probe -- remove it from FROZEN_UNPROBED so the "
                "baseline cannot rot.\n")
        return 1
    return 0


def _report_still_unprobed(checked, probed) -> None:
    still = sorted(FROZEN_UNPROBED - probed)
    if still:
        print("note: {} of {} table rows still have no ADV probe and can only SKIP "
              "(frozen baseline, see backlog WC): {}"
              .format(len(still), len(checked), " ".join(still)))


def _report_phantom(advertised, checked) -> None:
    for k in sorted(checked - advertised):
        print(f"note: {k} is checked but not ENV/ARG-set in any Dockerfile "
              "(it may come from a base image)")


def main():
    spath = os.path.join(ROOT, SMOKE)
    if not os.path.exists(spath):
        sys.stderr.write(f"FAIL: missing {spath}\n")
        return 1

    seen_files = sorted(glob.glob(os.path.join(ROOT, DOCKERFILE_GLOB)))
    if not seen_files:
        sys.stderr.write(f"FAIL: no Dockerfile matched {DOCKERFILE_GLOB}\n")
        return 1
    advertised = _advertised(seen_files)

    with open(spath) as fh:
        smoke = fh.read()
    m = re.search(r'_ADVERTISED_VERSION_KEYS="([^"]*)"', smoke)
    if not m:
        sys.stderr.write(f"FAIL: _ADVERTISED_VERSION_KEYS not found in {SMOKE}\n")
        return 1
    checked = set(m.group(1).split())
    # A row without an `ADV <KEY>` probe line is a permanent SKIP that reads as a pass.
    probed = set(re.findall(r"printf\s+'ADV ([A-Z0-9_]+) ", smoke))

    print("=== advertised version keys ===")
    print(
        f"{len(advertised)} advertised across {len(seen_files)} Dockerfile(s), "
        f"{len(checked)} checked by the smoke, {len(EXCUSED)} excused"
    )

    rc = (_report_unchecked(advertised, checked)
          | _report_stale(advertised, checked)
          | _report_new_unprobed(checked, probed)
          | _report_healed(probed))
    _report_still_unprobed(checked, probed)
    _report_phantom(advertised, checked)
    if rc == 0:
        print("OK: every advertised version key is checked or excused")
    return rc


if __name__ == "__main__":
    sys.exit(main())
