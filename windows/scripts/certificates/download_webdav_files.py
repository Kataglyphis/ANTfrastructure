#!/usr/bin/env python3
"""Shim. The downloader is linux/scripts/01-core/download-webdav-files.py.

It moved there on 2026-09-15 because it is platform-neutral and two lanes on two
operating systems reach it. This file stays because WindowsWebDav.Common.psm1
resolves `..\\certificates\\download_webdav_files.py` relative to itself, and a
consumer pinning an older hub would otherwise find nothing here at all.
"""
from __future__ import annotations

import pathlib
import runpy
import sys

_TARGET = (
    pathlib.Path(__file__).resolve().parents[3]
    / "linux" / "scripts" / "01-core" / "download-webdav-files.py"
)

if not _TARGET.is_file():
    sys.stderr.write(
        "download_webdav_files.py moved to %s and it is not there; this is a "
        "broken checkout.\n" % _TARGET
    )
    raise SystemExit(2)

runpy.run_path(str(_TARGET), run_name="__main__")
