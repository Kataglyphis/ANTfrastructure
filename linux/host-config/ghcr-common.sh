#!/usr/bin/env bash
# Sourced by the ghcr tools: one Accept header for both, since a short keep-set is how a prune deletes too much.

GHCR_PKG="${GHCR_PKG:-kataglyphis_beschleuniger}"
GHCR_OWNER="${GHCR_OWNER:-kataglyphis}"
GHCR_API="${GHCR_API:-https://api.github.com}"

# Without the index types GHCR collapses a multi-arch tag to one platform manifest and hides its children.
# shellcheck disable=SC2034  # read by the sourcing prune/delete tools
GHCR_MANIFEST_ACCEPT='application/vnd.oci.image.index.v1+json, application/vnd.docker.distribution.manifest.list.v2+json, application/vnd.oci.image.manifest.v1+json, application/vnd.docker.distribution.manifest.v2+json'

# GHCR_TOKEN, else the `docker login ghcr.io` credential; needs read:packages (plus delete:packages to delete).
ghcr_pat() {
  if [ -n "${GHCR_TOKEN:-}" ]; then printf '%s' "${GHCR_TOKEN}"; return 0; fi
  python3 - <<'PY'
import json, base64, os, sys
p = os.path.expanduser("~/.docker/config.json")
try:
    auth = json.load(open(p))["auths"]["ghcr.io"]["auth"]
except Exception:
    sys.exit(1)
print(base64.b64decode(auth).decode().split(":", 1)[1])
PY
}

# ghcr_registry_token <pat>: the registry Bearer for manifest reads.
ghcr_registry_token() {
  curl -fsS -u "x:${1}" \
    "https://ghcr.io/token?service=ghcr.io&scope=repository:${GHCR_OWNER}/${GHCR_PKG}:pull" \
    | python3 -c 'import sys,json;print(json.load(sys.stdin)["token"])'
}
