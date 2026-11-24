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
    # Each answer is empty unless a test names it: no local copy, and an image that runs as root.
    wanted = "PROOF_ENGINE_IMAGE_USER" if ".Config.User" in " ".join(ARGS) else "PROOF_ENGINE_CREATED"
    if ".Created" in " ".join(ARGS) or ".Config.User" in " ".join(ARGS):
        print(os.environ.get(wanted, ""))
    raise SystemExit(0)
if ARGS and ARGS[0] in ("info", "pull"):
    print(os.environ.get("PROOF_ENGINE_INFO", "") if ARGS[0] == "info" else "")
    raise SystemExit(0)
if ARGS and ARGS[0] == "run":
    if MODE == "name-collision":
        raise SystemExit(125)
    reports = next((value.rsplit(":", 1)[0] for value in ARGS if value.endswith(":/evidence")), None)
    if reports is not None and Path(reports).stat().st_mode & 0o222 != 0o222:
        raise SystemExit("nonroot evidence mount is not writable")
    if "--label" in ARGS:
        STATE.write_text(ARGS[ARGS.index("--label") + 1])
        if MODE != "no-cid":
            Path(ARGS[ARGS.index("--cidfile") + 1]).write_text(OWNED + "\n")
    if reports is not None and MODE != "missing-transcript":
        transcript = Path(reports) / "isolated-preflight-command.log"
        if MODE == "transcript-symlink":
            transcript.symlink_to(TRACE)
        else:
            transcript.write_bytes(b"worker\xff\n" + (b"final footer\n" if MODE == "clipped-attach" else b""))
    sys.stdout.buffer.write(b"worker\xff\n")
    raise SystemExit(37 if MODE == "worker-failure" else 0)
if ARGS and ARGS[0] == "ps":
    if MODE == "list-failure":
        raise SystemExit(24)
    selected = ARGS[ARGS.index("--filter") + 1] if "--filter" in ARGS else ""
    if STATE.exists() and selected in ("", "label=" + STATE.read_text()):
        print(OWNED)
    if not selected.startswith("label="):
        print(FOREIGN)
    raise SystemExit(0)
if ARGS[:1] == ["inspect"]:
    if MODE == "inspect-failure":
        raise SystemExit(23)
    if MODE == "malformed":
        print("[]")
        raise SystemExit(0)
    label, token = STATE.read_text().split("=", 1) if STATE.exists() else ("foreign", "run")
    cid = ARGS[1]
    if cid == FOREIGN or MODE == "wrong-label":
        token = "foreign"
    running = STATE.with_suffix(".running").exists()
    print(json.dumps([{"Id": FOREIGN if MODE == "wrong-id" else cid,
                       "Config": {"Labels": {label: token}},
                       "State": None if MODE == "missing-state" else
                       {"Running": running, "Pid": 42 if running else 0,
                        "Status": "running" if running else "exited"}}]))
    raise SystemExit(0)
if ARGS[:2] == ["rm", "--force"]:
    if MODE not in ("cleanup-failure", "remove-lies"):
        STATE.unlink()
    raise SystemExit(9 if MODE == "cleanup-failure" else 0)
if ARGS[:1] == ["stop"]:
    if MODE == "stop-failure":
        raise SystemExit(17)
    if MODE != "stop-lies":
        STATE.with_suffix(".running").unlink(missing_ok=True)
    raise SystemExit(0)
raise SystemExit("unexpected container fixture command")
