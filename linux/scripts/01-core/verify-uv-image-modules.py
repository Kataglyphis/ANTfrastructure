#!/usr/bin/env python3
"""Require runtime modules to come from the image, not the overlay."""

import importlib
import sys
from pathlib import Path


def verify(root: Path, names: list[str]) -> None:
    """Reject missing or shadowed image modules."""
    root = root.resolve()
    for name in names:
        module = importlib.import_module(name)
        filename = module.__file__
        if filename is None:
            raise ValueError(f"Image module {name} has no file")
        path = Path(filename).resolve()
        if not path.is_relative_to(root):
            raise ValueError(f"Image module {name} is shadowed: {path}")


if __name__ == "__main__":
    verify(Path(sys.argv[1]), sys.argv[2:])
