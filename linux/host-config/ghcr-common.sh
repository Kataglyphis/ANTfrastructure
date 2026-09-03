#!/usr/bin/env bash
# ==============================================================================
# ghcr-common.sh — the pieces every ghcr operator tool needs
#
# WHY (2026-08-27)
# ----------------
# ghcr-prune-package.sh (untagged versions) and ghcr-delete-tags.sh (named
# legacy tags) are two tools on one registry, and both had grown their own
# copy of the same three things: reading the PAT out of the docker login,
# exchanging it for a registry Bearer, and the Accept header that makes GHCR
# return an index rather than a per-platform manifest. Thirteen lines were
# byte-identical.
#
# That duplication is not merely untidy. The Accept header decides whether a
# multi-arch tag resolves to its INDEX (children visible, keep-set complete)
# or to one platform manifest (children invisible, keep-set short) — and a
# short keep-set is how a prune tool deletes something it should not. One
# definition, used by both, is the safety property here.
#
# Sourced, never executed. Sets nothing global beyond the two defaults below.
# ==============================================================================

GHCR_PKG="${GHCR_PKG:-kataglyphis_beschleuniger}"
GHCR_OWNER="${GHCR_OWNER:-kataglyphis}"
GHCR_API="${GHCR_API:-https://api.github.com}"

# The one Accept header. Listing all four types makes GHCR hand back the index
# for multi-arch tags; omitting the index types silently collapses a tag to a
# single platform manifest and hides its children.
# shellcheck disable=SC2034  # read by the sourcing prune/delete tools
GHCR_MANIFEST_ACCEPT='application/vnd.oci.image.index.v1+json, application/vnd.docker.distribution.manifest.list.v2+json, application/vnd.oci.image.manifest.v1+json, application/vnd.docker.distribution.manifest.v2+json'

# The PAT: explicit override first, otherwise the credential `docker login
# ghcr.io` already stored. Needs read:packages, plus delete:packages to delete.
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

# Registry-side Bearer for manifest reads (token exchange with the PAT).
# $1 = PAT
ghcr_registry_token() {
  curl -fsS -u "x:${1}" \
    "https://ghcr.io/token?service=ghcr.io&scope=repository:${GHCR_OWNER}/${GHCR_PKG}:pull" \
    | python3 -c 'import sys,json;print(json.load(sys.stdin)["token"])'
}
