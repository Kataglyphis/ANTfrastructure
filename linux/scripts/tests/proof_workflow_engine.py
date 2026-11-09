#!/usr/bin/env python3
"""Record container transport fixtures; this executable never contacts a daemon."""

import json
import os
import sys
from pathlib import Path

ARGS = sys.argv[1:]
TRACE = Path(os.environ["PROOF_ENGINE_TRACE"])
STATE = Path(os.environ["PROOF_ENGINE_STATE"])
OWNED = "a" * 64
FOREIGN = "b" * 64
MODE = os.environ.get("PROOF_ENGINE_MODE", "success")
with TRACE.open("a") as trace:
    trace.write(json.dumps(ARGS) + "\n")
if ARGS[:2] == ["image", "inspect"]:
    raise SystemExit(0)
if ARGS and ARGS[0] == "run":
    if MODE == "name-collision":
        raise SystemExit(125)
    if "--label" in ARGS:
        STATE.write_text(ARGS[ARGS.index("--label") + 1])
        if MODE != "no-cid":
            Path(ARGS[ARGS.index("--cidfile") + 1]).write_text(OWNED + "\n")
    sys.stdout.buffer.write(b"worker\xff\n")
    raise SystemExit(37 if MODE == "worker-failure" else 0)
if ARGS and ARGS[0] == "ps":
    selected = ARGS[ARGS.index("--filter") + 1]
    if STATE.exists() and selected == "label=" + STATE.read_text():
        print(OWNED)
    elif not selected.startswith("label="):
        print(FOREIGN)
    raise SystemExit(0)
if ARGS[:2] == ["rm", "--force"]:
    raise SystemExit(9 if MODE == "cleanup-failure" else 0)
raise SystemExit("unexpected container fixture command")
