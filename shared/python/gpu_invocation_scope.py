# Copyright (c) 2026 Kataglyphis. All rights reserved.
# GPU_INVOCATION_SCOPE_API=1
"""Validate a GPU workflow invocation scope before publishing its suffix."""

import os
import re
import sys
from pathlib import Path


def invocation_suffix(scope: str) -> str:
    """Return a safe, unambiguous artifact suffix for the requested scope."""
    if re.fullmatch(r"[a-z][a-z0-9-]{0,31}", scope, flags=re.ASCII) is None:
        raise ValueError(
            "invocation scope must be 1–32 lowercase letters, digits or hyphens and start with a letter"
        )
    return "" if scope == "default" else f"-scope-{scope}"


def main() -> int:
    """Write the suffix only after validating the complete input."""
    try:
        if len(sys.argv) != 1:
            raise ValueError("this helper takes no command-line arguments")
        suffix = invocation_suffix(os.environ.get("GPU_INVOCATION_SCOPE", "default"))
        with Path(os.environ["GITHUB_OUTPUT"]).open("a", encoding="utf-8") as output:
            output.write(f"suffix={suffix}\n")
    except (KeyError, OSError, ValueError) as error:
        print(f"GPU invocation scope: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
