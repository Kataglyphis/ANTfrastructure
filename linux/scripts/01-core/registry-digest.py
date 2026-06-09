#!/usr/bin/env python3
"""Extract the Descriptor.digest from `nerdctl manifest inspect --verbose` JSON output.

Reads JSON from stdin in the format produced by:
    nerdctl manifest inspect --verbose <tag>

If the input is a JSON array (multi-platform manifest list), the first element is used.
If the input is a JSON object (single manifest), it is used directly.

Prints the digest string to stdout and exits 0 on success.
Exits non-zero if the digest cannot be resolved.
"""
import sys
import json

def main():
    try:
        data = json.load(sys.stdin)
    except (json.JSONDecodeError, ValueError) as exc:
        print(f"ERROR: registry-digest.py: invalid JSON input: {exc}", file=sys.stderr)
        sys.exit(1)

    if isinstance(data, list):
        if not data:
            print("ERROR: registry-digest.py: empty JSON array", file=sys.stderr)
            sys.exit(1)
        entry = data[0]
    else:
        entry = data

    try:
        digest = entry["Descriptor"]["digest"]
    except (KeyError, TypeError) as exc:
        print(f"ERROR: registry-digest.py: cannot resolve Descriptor.digest: {exc}", file=sys.stderr)
        sys.exit(1)

    if not digest:
        print("ERROR: registry-digest.py: empty digest", file=sys.stderr)
        sys.exit(1)

    print(digest)

if __name__ == "__main__":
    main()
