#!/usr/bin/env python3
"""Synthetic Cargo records argument boundaries and phase status; it proves no build or linkage."""

import json
import os
import sys
from pathlib import Path

if os.environ.get("CARGO_RELEASE_TEST_WRAPPER") != "loaded":
    raise SystemExit(91)
with Path(os.environ["CARGO_RELEASE_TEST_ARGS"]).open("a", encoding="utf-8") as output:
    output.write(json.dumps(sys.argv[1:]) + "\n")
role = "workspace" if "--workspace" in sys.argv[1:] else "cli"
status = int(os.environ["CARGO_RELEASE_TEST_" + role.upper() + "_STATUS"])
print(json.dumps({"reason": "compiler-artifact", "role": role}))
print(json.dumps({"reason": "build-finished", "success": status == 0}))
print("Cargo diagnostic " + role, file=sys.stderr)
raise SystemExit(status)
