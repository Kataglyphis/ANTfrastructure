#!/usr/bin/env python3
"""Extract one OCI manifest annotation from `nerdctl manifest inspect --verbose` output.

Reads JSON from stdin in the format produced by:
    nerdctl manifest inspect --verbose <ref>

`manifest inspect` reports annotations only inside the base64-encoded `Raw`
field (the verbatim manifest bytes as they exist in the registry) — the decoded
top level does not surface them. So decode `Raw` and read `.annotations[key]`
from there.

Usage:
    nerdctl manifest inspect --verbose REF | manifest-annotation.py KEY

Prints the annotation value and exits 0 when present.
Exits 2 when the manifest parses but carries no such annotation (the caller
distinguishes "unknown provenance" from a hard error).
Exits 1 on unusable input.
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

    # A manifest LIST inspects as a JSON array; the cross lane publishes
    # single-platform (linux/amd64) manifests, so the first entry is the one.
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
