#!/usr/bin/env python3
# Copyright (c) 2026 Kataglyphis
# SPDX-License-Identifier: MIT
"""Copy a GenAI model directory with a fixed intra-op thread count; `auto` and `text` take the family's rules here.

ORT's default ignores the affinity mask, so on a pinned host it oversubscribes: docs/fleet-health.md#perf-host.
`auto` is the usable CPUs but one, 1 to 8 (docs/onnxruntime-single-source.md#the-ort-thread-rule); `text` is half of
that, 1 to 4, the shipped default of a text decoder (docs/onnxruntime-single-source.md#the-text-thread-rule)."""

from __future__ import annotations

import argparse
import json
import os
import shutil
import sys
from pathlib import Path

MAX_THREADS = 8
MAX_TEXT_THREADS = 4


def family_threads(usable: int | None = None) -> int:
    """The usable CPUs (the affinity mask) but one, at least 1 and at most MAX_THREADS."""
    if usable is None:
        usable = len(os.sched_getaffinity(0)) if hasattr(os, "sched_getaffinity") else os.cpu_count() or 1
    return min(max(usable - 1, 1), MAX_THREADS)


def text_threads(usable: int | None = None) -> int:
    """Half of family_threads, at least 1 and at most MAX_TEXT_THREADS: decoding is memory-bound."""
    return min(max(family_threads(usable) // 2, 1), MAX_TEXT_THREADS)


def thread_count(text: str) -> int:
    """`auto`, `text` or a whole number of threads, at least 1."""
    if text == "auto":
        return family_threads()
    if text == "text":
        return text_threads()
    try:
        count = int(text)
    except ValueError:
        raise argparse.ArgumentTypeError(f"{text!r} is neither auto, text nor a whole number") from None
    if count < 1:
        raise argparse.ArgumentTypeError("--threads must be at least 1")
    return count


def main(argv: list[str] | None = None) -> int:
    """Replace --out with a copy of --model whose decoder session uses --threads threads."""
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--model", required=True, type=Path, help="a GenAI model directory")
    ap.add_argument("--out", required=True, type=Path, help="the directory to replace")
    ap.add_argument("--threads", required=True, type=thread_count, help="a count, auto for the detector's rule, text for the text rule")
    args = ap.parse_args(argv)
    config = json.loads((args.model / "genai_config.json").read_text(encoding="utf-8"))
    session = config["model"]["decoder"].setdefault("session_options", {})
    session["intra_op_num_threads"] = args.threads
    shutil.rmtree(args.out, ignore_errors=True)
    shutil.copytree(args.model, args.out)
    (args.out / "genai_config.json").write_text(json.dumps(config, indent=4) + "\n", encoding="utf-8")
    return 0


if __name__ == "__main__":
    sys.exit(main())
