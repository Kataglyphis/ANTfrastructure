#!/usr/bin/env python3
"""Export actual ordinary ROCm Media with native GPU ancestry; no factory, licence, inference or FINAL acceptance."""

import runpy
from pathlib import Path

from media_handoff_profile import load_media

TRANSPORT = runpy.run_path(str(Path(__file__).with_name('gpu-oci-handoff.py')))


def main() -> int:
    return TRANSPORT['main_for']('media', load_media)


if __name__ == '__main__':
    raise SystemExit(main())
