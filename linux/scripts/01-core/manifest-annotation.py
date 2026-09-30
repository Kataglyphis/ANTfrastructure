#!/usr/bin/env python3
"""Print one annotation from `nerdctl manifest inspect --verbose` stdin, read from the base64 `Raw` manifest.

Exit 2 when the annotation is absent (unknown provenance), 1 on unusable input.
"""
import base64
import binascii
import json
import sys

EXIT_BAD_INPUT = 1
EXIT_ABSENT = 2


def fail(msg, code=EXIT_BAD_INPUT):
    print(f"ERROR: manifest-annotation.py: {msg}", file=sys.stderr)
    sys.exit(code)


def main():
    if len(sys.argv) != 2:
        fail("usage: manifest-annotation.py <annotation-key>")
    key = sys.argv[1]

    try:
        data = json.load(sys.stdin)
    except (json.JSONDecodeError, ValueError) as exc:
        fail(f"invalid JSON input: {exc}")

    # A manifest list inspects as an array; the cross lane publishes single-platform manifests.
    if isinstance(data, list):
        if not data:
            fail("empty JSON array")
        entry = data[0]
    else:
        entry = data

    if not isinstance(entry, dict):
        fail("expected a JSON object")

    raw = entry.get("Raw")
    if not raw:
        fail("no Raw field in manifest inspect output")

    try:
        manifest = json.loads(base64.b64decode(raw))
    except (binascii.Error, ValueError, TypeError) as exc:
        fail(f"cannot decode Raw manifest: {exc}")

    annotations = manifest.get("annotations") or {}
    if not isinstance(annotations, dict):
        fail("manifest annotations is not an object")

    value = annotations.get(key)
    if not value:
        fail(f"annotation {key!r} not present on this manifest", EXIT_ABSENT)

    print(value)


if __name__ == "__main__":
    main()
