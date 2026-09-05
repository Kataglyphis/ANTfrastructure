#!/usr/bin/env python3
"""Every version-shaped ENV the runtime image advertises must be checked or excused.

A new ARG/ENV added to Dockerfile.package is otherwise silently unverified by the
smoke's advertised-vs-actual gate. See docs/cross-build-verification.md.
"""
import glob
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
# Both forms reach the image config the smoke reads. Globbed, not listed, so a
# new Dockerfile cannot slip past. See docs/cross-build-verification.md.
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
    "ANDROID_SDK_VERSION": "android lane image, not the cross runtime image",
    "CUDA_VERSION": "nvidia lane image, not the 3-arch cross runtime",
    "CUDNN_VERSION": "nvidia lane image, not the 3-arch cross runtime",
    "TENSORRT_VERSION": "nvidia lane image, not the 3-arch cross runtime",
    "ROCM_VERSION": "amd lane image, not the 3-arch cross runtime",
    "MIGRAPHX_VERSION": "amd lane image, not the 3-arch cross runtime",
}
SHAPED = re.compile(r"(VERSION|RELEASE|REF)$")


# Table rows whose value the in-image probe never prints, so the row can only
# SKIP. EMPTY since 2026-09-03: all ten were given probes and checked against the
# shipped image. Adding an entry here accepts a row that cannot fail -- write the
# probe instead. docs/refactoring-backlog.md WC
FROZEN_UNPROBED = set()


def main():
    spath = os.path.join(ROOT, SMOKE)
    if not os.path.exists(spath):
        sys.stderr.write("FAIL: missing {}\n".format(spath))
        return 1

    seen_files = sorted(glob.glob(os.path.join(ROOT, DOCKERFILE_GLOB)))
    if not seen_files:
        sys.stderr.write("FAIL: no Dockerfile matched {}\n".format(DOCKERFILE_GLOB))
        return 1
    advertised = set()
    for dpath in seen_files:
        with open(dpath) as fh:
            for ln in fh:
                m = re.match(r"\s*(?:ENV|ARG)\s+([A-Z0-9_]+)", ln)
                if m and SHAPED.search(m.group(1)):
                    advertised.add(m.group(1))

    with open(spath) as fh:
        smoke = fh.read()
    m = re.search(r'_ADVERTISED_VERSION_KEYS="([^"]*)"', smoke)
    if not m:
        sys.stderr.write("FAIL: _ADVERTISED_VERSION_KEYS not found in {}\n".format(SMOKE))
        return 1
    checked = set(m.group(1).split())

    print("=== advertised version keys ===")
    print("{} advertised across {} Dockerfile(s), {} checked by the smoke, {} excused"
          .format(len(advertised), len(seen_files), len(checked), len(EXCUSED)))

    rc = 0
    unchecked = sorted(advertised - checked - set(EXCUSED))
    if unchecked:
        rc = 1
        for k in unchecked:
            sys.stderr.write(
                "FAIL: {} is advertised by the image but neither checked by the smoke's "
                "advertised-vs-actual gate nor excused -- add a HAVE probe + a row in "
                "_ADVERTISED_VERSION_KEYS, or an EXCUSED entry saying why not.\n".format(k))
    stale = sorted(set(EXCUSED) - advertised - checked)
    if stale:
        rc = 1
        for k in stale:
            sys.stderr.write(
                "FAIL: STALE excuse for {} ({}) -- the image no longer advertises it; "
                "delete the EXCUSED entry.\n".format(k, EXCUSED[k]))
    # A row in the table only says the smoke INTENDS to check the key. The value
    # comes from an `ADV <KEY>` line the in-image probe prints, and a row without
    # one is a permanent SKIP that reads as a pass. Frozen at the 10 that were
    # already inert; a NEW row without a probe fails. docs/refactoring-backlog.md WC
    probed = set(re.findall(r"printf\s+'ADV ([A-Z0-9_]+) ", smoke))
    unprobed = sorted(checked - probed)
    new_unprobed = [k for k in unprobed if k not in FROZEN_UNPROBED]
    if new_unprobed:
        rc = 1
        for k in new_unprobed:
            sys.stderr.write(
                "FAIL: {} sits in _ADVERTISED_VERSION_KEYS but the in-image probe "
                "prints no `ADV {}` line, so its row can only ever SKIP -- add the "
                "printf next to the others, or drop the row.\n".format(k, k))
    healed = sorted(FROZEN_UNPROBED & probed)
    if healed:
        rc = 1
        for k in healed:
            sys.stderr.write(
                "FAIL: {} now HAS a probe -- remove it from FROZEN_UNPROBED so the "
                "baseline cannot rot.\n".format(k))
    still = sorted(FROZEN_UNPROBED - probed)
    if still:
        print("note: {} of {} table rows still have no ADV probe and can only SKIP "
              "(frozen baseline, see backlog WC): {}"
              .format(len(still), len(checked), " ".join(still)))

    phantom = sorted(checked - advertised)
    for k in phantom:
        print("note: {} is checked but not ENV/ARG-set in any Dockerfile "
              "(it may come from a base image)".format(k))
    if rc == 0:
        print("OK: every advertised version key is checked or excused")
    return rc


if __name__ == "__main__":
    sys.exit(main())
