#!/usr/bin/env python3
"""Export ordinary Android with native Media ancestry; no licence, inference or FINAL acceptance."""

import runpy
from pathlib import Path

from android_handoff_profile import load_android

TRANSPORT = runpy.run_path(str(Path(__file__).with_name('gpu-oci-handoff.py')))


def main() -> int:
    return TRANSPORT['main_for']('android', load_android)


if __name__ == '__main__':
    raise SystemExit(main())
