# shellcheck shell=bash
# A shared schema keeps the offline registries consistent while each suite chooses its own versions and tags.
_ghcr_fixture_versions() {
  python3 -c '
import json, sys
versions = []
for line in sys.stdin:
    identifier, digest, created, tags = line.rstrip("\n").split("\t")
    version = {"id": int(identifier), "name": digest, "created_at": created}
    if tags != "-":
        version["metadata"] = {"container": {"tags": tags.split(",") if tags and tags != "[]" else []}}
    versions.append(version)
with open(sys.argv[1], "w") as output:
    json.dump(versions, output)
' "$1"
}
