#!/usr/bin/env python3
"""Extract the first layer digest from `nerdctl manifest inspect` JSON output.

Reads JSON from stdin in the format produced by:
    nerdctl manifest inspect <tag>

Prints the first layer's digest string to stdout and exits 0 on success.
If the input is empty, the manifest is a list, or no layers exist, prints nothing
and exits 0 (caller should handle empty output).
"""
import sys
import json

def main():
    try:
        data = json.load(sys.stdin)
    except (json.JSONDecodeError, ValueError):
        # Empty or invalid input — caller should handle
        sys.exit(0)

    if isinstance(data, list):
        if not data:
            sys.exit(0)
        data = data[0]

    layers = data.get("layers", [])
    if not layers:
        sys.exit(0)

    digest = layers[0].get("digest", "")
    if digest:
        print(digest)

if __name__ == "__main__":
    main()
