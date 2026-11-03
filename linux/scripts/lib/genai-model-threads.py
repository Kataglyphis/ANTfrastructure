#!/usr/bin/env python3
# Copyright (c) 2026 Kataglyphis
# SPDX-License-Identifier: MIT
"""Copy a GenAI model directory with a fixed intra-op thread count; it does not check that the count suits the host.

ORT's default ignores the affinity mask, so on a pinned host it oversubscribes: docs/fleet-health.md#perf-host"""

from __future__ import annotations

import argparse
import json
import shutil
import sys
from pathlib import Path


def main(argv: list[str] | None = None) -> int:
    """Replace --out with a copy of --model whose decoder session uses --threads threads."""
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--model", required=True, type=Path, help="a GenAI model directory")
    ap.add_argument("--out", required=True, type=Path, help="the directory to replace")
    ap.add_argument("--threads", required=True, type=int)
    args = ap.parse_args(argv)
    if args.threads < 1:
        ap.error("--threads must be at least 1")
    config = json.loads((args.model / "genai_config.json").read_text(encoding="utf-8"))
    session = config["model"]["decoder"].setdefault("session_options", {})
    session["intra_op_num_threads"] = args.threads
    shutil.rmtree(args.out, ignore_errors=True)
    shutil.copytree(args.model, args.out)
    (args.out / "genai_config.json").write_text(json.dumps(config, indent=4) + "\n", encoding="utf-8")
    return 0


if __name__ == "__main__":
    sys.exit(main())
