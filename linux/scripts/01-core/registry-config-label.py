#!/usr/bin/env python3
"""Print one image-config LABEL of a REMOTE image, without pulling it.

Why this exists (XC3, 2026-08-23)
---------------------------------
The runtime lane records its provenance (run-id, parent digest, parent stage)
as image LABELS, because RTCACHE3 forced the builds onto plain ``-t`` and that
path cannot carry buildkit exporter annotations.  Labels live in the image
*config blob*, so they do reach the registry with the push -- but ``nerdctl
image inspect`` only ever answers from the LOCAL store.

That gap made the XC3 coherence gate inert in exactly the situation it was
written for: a ``--repair`` / ``--manifest-only`` run, possibly on a different
host, where the per-arch wrapper tags are not in the local store at all.  The
gate then read three empty run-ids, dropped them as "unknown", and happily
assembled a mixed-generation manifest.

Fetching the config blob is cheap (a manifest plus a few KB of JSON), so this
helper does exactly that and nothing else.

Contract (mirrors manifest-annotation.py, whose exit codes callers branch on):
  exit 0 -- label found, value printed on stdout
  exit 2 -- image readable but carries no such label
  exit 1 -- could not read the image at all (network, auth, unsupported ref)

Auth: anonymous Bearer via the registry's own WWW-Authenticate challenge, with
a best-effort fallback to credentials already stored in
``$DOCKER_CONFIG/config.json`` / ``~/.docker/config.json``.  Anything it cannot
authenticate is reported as "could not read" (1), never as "absent" (2) -- the
caller must not mistake a permission problem for missing provenance.
"""

from __future__ import annotations

import base64
import json
import os
import sys
import urllib.error
import urllib.parse
import urllib.request

_TIMEOUT = 20
_ACCEPT = ", ".join(
    (
        "application/vnd.oci.image.manifest.v1+json",
        "application/vnd.docker.distribution.manifest.v2+json",
        "application/vnd.oci.image.index.v1+json",
        "application/vnd.docker.distribution.manifest.list.v2+json",
    )
)

EXIT_OK = 0
EXIT_UNREADABLE = 1
EXIT_ABSENT = 2


def _split_ref(ref: str):
    """Split <host>/<repo>:<tag|@digest> into (host, repo, reference).

    Docker-style short refs (no dot/colon in the first segment) imply Docker
    Hub, which this chain never uses; treat them as unsupported rather than
    guessing a host.
    """
    remainder = ref
    digest = ""
    if "@" in remainder:
        remainder, digest = remainder.rsplit("@", 1)

    if "/" not in remainder:
        return None
    host, path = remainder.split("/", 1)
    if "." not in host and ":" not in host and host != "localhost":
        return None

    if digest:
        return host, path, digest
    if ":" in path:
        path, tag = path.rsplit(":", 1)
        return host, path, tag
    return host, path, "latest"


def _stored_basic_auth(host: str) -> str:
    """Return a Basic credential for <host> from the docker config, or ""."""
    cfg_dir = os.environ.get("DOCKER_CONFIG") or os.path.expanduser("~/.docker")
    try:
        with open(os.path.join(cfg_dir, "config.json"), encoding="utf-8") as handle:
            cfg = json.load(handle)
    except (OSError, ValueError):
        return ""
    for key, entry in (cfg.get("auths") or {}).items():
        # Registry keys appear both bare ("ghcr.io") and as URLs.
        if host not in key:
            continue
        auth = (entry or {}).get("auth")
        if auth:
            return auth
        user, secret = (entry or {}).get("username"), (entry or {}).get("password")
        if user and secret:
            return base64.b64encode(f"{user}:{secret}".encode()).decode()
    return ""


def _bearer_token(challenge: str, host: str, repo: str) -> str:
    """Resolve a Bearer token from a WWW-Authenticate challenge."""
    if not challenge.lower().startswith("bearer "):
        return ""
    params = {}
    for part in challenge[len("bearer "):].split(","):
        if "=" not in part:
            continue
        name, _, value = part.partition("=")
        params[name.strip()] = value.strip().strip('"')

    realm = params.get("realm")
    if not realm:
        return ""
    query = []
    if params.get("service"):
        query.append(f"service={urllib.parse.quote(params['service'])}")
    query.append(f"scope={urllib.parse.quote(params.get('scope') or f'repository:{repo}:pull')}")
    url = f"{realm}?{'&'.join(query)}"

    request = urllib.request.Request(url)
    basic = _stored_basic_auth(host)
    if basic:
        request.add_header("Authorization", f"Basic {basic}")
    try:
        with urllib.request.urlopen(request, timeout=_TIMEOUT) as response:
            payload = json.load(response)
    except (urllib.error.URLError, ValueError, OSError):
        return ""
    return payload.get("token") or payload.get("access_token") or ""


def _get(url: str, host: str, repo: str, accept: str):
    """GET <url>, negotiating a Bearer token on the first 401. Returns bytes."""
    def _attempt(token: str):
        request = urllib.request.Request(url)
        request.add_header("Accept", accept)
        if token:
            request.add_header("Authorization", f"Bearer {token}")
        return urllib.request.urlopen(request, timeout=_TIMEOUT)

    try:
        with _attempt("") as response:
            return response.read()
    except urllib.error.HTTPError as exc:
        if exc.code != 401:
            return None
        token = _bearer_token(exc.headers.get("WWW-Authenticate") or "", host, repo)
        if not token:
            return None
        try:
            with _attempt(token) as response:
                return response.read()
        except (urllib.error.URLError, OSError):
            return None
    except (urllib.error.URLError, OSError):
        return None


def main(argv) -> int:
    if len(argv) != 3:
        print(f"usage: {argv[0]} <image-ref> <label-key>", file=sys.stderr)
        return EXIT_UNREADABLE

    parts = _split_ref(argv[1])
    if not parts:
        return EXIT_UNREADABLE
    host, repo, reference = parts
    base = f"https://{host}/v2/{repo}"

    raw = _get(f"{base}/manifests/{reference}", host, repo, _ACCEPT)
    if raw is None:
        return EXIT_UNREADABLE
    try:
        manifest = json.loads(raw)
    except ValueError:
        return EXIT_UNREADABLE

    # A per-arch wrapper tag is a plain manifest. An index has no single config
    # to read, and picking one arbitrarily would answer about the wrong image.
    config = manifest.get("config") or {}
    config_digest = config.get("digest")
    if not config_digest:
        return EXIT_UNREADABLE

    raw_config = _get(f"{base}/blobs/{config_digest}", host, repo, "application/json")
    if raw_config is None:
        return EXIT_UNREADABLE
    try:
        image_config = json.loads(raw_config)
    except ValueError:
        return EXIT_UNREADABLE

    labels = ((image_config.get("config") or {}).get("Labels")) or {}
    value = labels.get(argv[2])
    if value is None or value == "":
        return EXIT_ABSENT
    sys.stdout.write(value)
    return EXIT_OK


if __name__ == "__main__":
    sys.exit(main(sys.argv))
