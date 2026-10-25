#!/usr/bin/env python3
# Copyright (c) 2025 Kataglyphis
# SPDX-License-Identifier: MIT
"""A published image's env carries no build-host setting: no sccache remote cache, no RFC1918 or link-local address.

docs/build-cache-tiers.md#the-shipped-image-carries-no-build-host-setting"""
import argparse
import ipaddress
import os
import re
import sys
from collections.abc import Iterable, Iterator

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

_HOST_ADDRESS = (r"WEBDAV_\w+|REDIS\w*|MEMCACHED\w*|GCS_\w+|AZURE_\w+|S3_\w+|OSS_\w+|"
                 r"COS_\w+|GHA_\w+|BUCKET|ENDPOINT|REGION")
# The sccache names whose value is a host, a bucket or a region.
BUILD_HOST_ADDRESS_NAME = re.compile(rf"^SCCACHE_(?:{_HOST_ADDRESS})$", re.IGNORECASE)
# Every sccache remote backend and host-layout knob; local defaults like SCCACHE_DIR are allowed.
BUILD_HOST_NAME = re.compile(rf"^SCCACHE_(?:{_HOST_ADDRESS}|MULTILEVEL_CHAIN|FORCE_LOCAL)$", re.IGNORECASE)
# The S3 level's key reaches a RUN only as a BuildKit secret; as a variable it would publish with the image.
CREDENTIAL_NAME = re.compile(r"^AWS_(?:ACCESS_KEY_ID|SECRET_ACCESS_KEY|SESSION_TOKEN)$", re.IGNORECASE)
PRIVATE_V4 = tuple(ipaddress.ip_network(n) for n in
                   ("10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16", "169.254.0.0/16"))
IPV4 = re.compile(r"(?<![\w.])(\d{1,3}(?:\.\d{1,3}){3})(?![\w.])")
IPV6_LINK_LOCAL = re.compile(r"(?:^|[\s,;=\[@\"'(])(fe[89ab][0-9a-f]:[0-9a-f:.%]*)", re.IGNORECASE)
LEAD = set(" \t,;=\"'([")
TRAIL = set(" \t,;\"')]")
AUTHORITY = re.compile(r"//(?:[^/@\s]*@)?$")
REF = re.compile(r"\$\{?([A-Za-z_][A-Za-z0-9_]*)")
# Only a compiling RUN mounts both dirs; either alone is a probe that starts no sccache server.
SCCACHE_MOUNTS = tuple(re.compile(rf"--mount=[^\s]*target=C:\\{d}(?=[,\s]|$)", re.IGNORECASE)
                       for d in ("sccache", "sccache-logs"))
# The WebDAV level reaches a compile only through this mount; an ARG would write the endpoint into the history.
ENDPOINT_SECRET = re.compile(r"--mount=type=secret,id=sccache_webdav_endpoint,env=SCCACHE_WEBDAV_ENDPOINT(?=\s|$)")


def _host_position(value: str, start: int, end: int, name: str) -> bool:
    """Is value[start:end] an address, or a version/path fragment that looks like one?"""
    before, after = value[:start], value[end:end + 1]
    if AUTHORITY.search(before) or before.endswith(("\\\\", "@")):
        return True
    if before and before[-1] not in LEAD:
        return False  # C:\TensorRT-10.13.3.9, rocm10.0.0.1
    if after in (":", "/"):
        return True   # host:port, a CIDR or a URL path
    if after and after not in TRAIL:
        return False
    return "VERSION" not in name.upper()  # CUDA_..._CURAND_VERSION=10.4.4.72


def leak_reasons(name: str, value: str) -> list[str]:
    """Why NAME=VALUE must not ship in a published image; [] when it may."""
    reasons = []
    if BUILD_HOST_NAME.match(name):
        reasons.append("build-host sccache setting (the image may carry local defaults only)")
    if CREDENTIAL_NAME.match(name):
        reasons.append("object-store credential (a key must never ship in an image)")
    return reasons + address_reasons(name, value)


def address_reasons(name: str, value: str) -> list[str]:
    """The RFC1918/link-local addresses VALUE carries in a host position."""
    reasons = []
    for m in IPV4.finditer(value):
        try:
            addr = ipaddress.ip_address(m.group(1))
        except ValueError:
            continue
        if any(addr in net for net in PRIVATE_V4) and _host_position(value, m.start(1), m.end(1), name):
            reasons.append(f"RFC1918/link-local address {m.group(1)}")
    for m in IPV6_LINK_LOCAL.finditer(value):
        reasons.append(f"link-local address {m.group(1)}")
    return reasons


def check_env_lines(lines: Iterable[str], label: str) -> tuple[int, list[str]]:
    """(checked, findings) over NAME=VALUE lines; blanks and comments are skipped."""
    checked, findings = 0, []
    for raw in lines:
        line = raw.rstrip("\r\n")
        if not line.strip() or line.lstrip().startswith("#"):
            continue
        name, _, value = line.partition("=")
        checked += 1
        for why in leak_reasons(name.strip(), value):
            findings.append(f"{label}: {name.strip()}={value} -- {why}")
    return checked, findings


def _escape_char(lines: Iterable[str]) -> str:
    """The `# escape=` parser directive, or the default backslash."""
    for line in lines:
        m = re.match(r"^#\s*escape\s*=\s*(\S)\s*$", line.strip())
        if m:
            return m.group(1)
        if not line.strip().startswith("#"):
            break
    return "\\"


def instructions(path: str | os.PathLike[str]) -> Iterator[tuple[int, str]]:
    """(line, text) per instruction, joined by the file's escape char, interior comments dropped as BuildKit does."""
    with open(path, encoding="utf-8", errors="replace") as fh:
        lines = fh.read().splitlines()
    esc = _escape_char(lines)
    buf, start = [], 0
    for num, line in enumerate(lines, 1):
        if line.lstrip().startswith("#"):
            continue
        if not buf:
            if not line.strip():
                continue
            start = num
        stripped = line.rstrip()
        more = stripped.endswith(esc)
        buf.append(stripped[:-1] if more else stripped)
        if not more:
            yield start, " ".join(t.strip() for t in buf if t.strip())
            buf = []
    if buf:
        yield start, " ".join(t.strip() for t in buf if t.strip())


def _tokens(body: str) -> list[str]:
    out, cur, quote = [], "", ""
    for char in body:
        if quote:
            cur += char
            if char == quote:
                quote = ""
        elif char in "\"'":
            quote = char
            cur += char
        elif char.isspace():
            if cur:
                out.append(cur)
            cur = ""
        else:
            cur += char
    if cur:
        out.append(cur)
    return out


def _unquote(value: str) -> str:
    if len(value) >= 2 and value[0] == value[-1] and value[0] in "\"'":
        return value[1:-1]
    return value


def _pairs(body: str, legacy: bool) -> list[tuple[str, str | None]]:
    """(KEY, VALUE or None) pairs of an ENV/ARG body; `legacy` accepts `ENV KEY value`."""
    toks = _tokens(body)
    if legacy and toks and "=" not in toks[0]:
        return [(toks[0], _unquote(" ".join(toks[1:])))]
    return [(t.split("=", 1)[0], _unquote(t.split("=", 1)[1]) if "=" in t else None) for t in toks]


def _scan_arg(where: str, body: str) -> list[str]:
    findings = []
    for key, value in _pairs(body, legacy=False):
        if BUILD_HOST_ADDRESS_NAME.match(key) or CREDENTIAL_NAME.match(key):
            findings.append(f"{where}: ARG {key} -- BuildKit writes an ARG's value into the image history; "
                            f"mount it as a secret (--mount=type=secret,id={key.lower()},env={key})")
        findings += [f"{where}: ARG {key} default carries a {why}"
                     for why in address_reasons(key, value or "")]
    return findings


def _scan_env(where: str, body: str) -> list[str]:
    findings = []
    for key, value in _pairs(body, legacy=True):
        findings += [f"{where}: ENV {key} -- {why}" for why in leak_reasons(key, value or "")]
        findings += [f"{where}: ENV {key} expands the build-host ARG ${{{ref}}} into the image"
                     for ref in REF.findall(value or "") if BUILD_HOST_NAME.match(ref)]
    return findings


def _scan_run(where: str, body: str) -> list[str]:
    if all(m.search(body) for m in SCCACHE_MOUNTS) and not ENDPOINT_SECRET.search(body):
        message = (f"{where}: RUN compiles through sccache (it mounts C:\\sccache and C:\\sccache-logs) but "
                   "does not mount the secret sccache_webdav_endpoint as SCCACHE_WEBDAV_ENDPOINT "
                   "-- the endpoint never reaches this compile")
        return [message]
    return []


def scan_dockerfile(path: str, rel: str) -> list[str]:
    findings = []
    for line, text in instructions(path):
        head, _, body = text.partition(" ")
        head = head.upper()
        where = f"{rel}:{line}"
        if head == "ARG":
            findings += _scan_arg(where, body)
        elif head == "ENV":
            findings += _scan_env(where, body)
        elif head == "RUN":
            findings += _scan_run(where, body)
    return findings


def main(argv: list[str]) -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    mode = ap.add_mutually_exclusive_group(required=True)
    mode.add_argument("--env-file", help="NAME=VALUE lines of a built image's config; - for stdin")
    mode.add_argument("--dockerfile", nargs="+", help="Dockerfiles to scan statically")
    ap.add_argument("--label", default="image", help="what --env-file describes, for messages")
    ap.add_argument("--min-vars", type=int, default=1,
                    help="--env-file: fewer variables than this is a read failure, not a pass")
    args = ap.parse_args(argv[1:])

    if args.env_file is not None:
        if args.env_file == "-":
            lines = sys.stdin.readlines()
        else:
            with open(args.env_file, encoding="utf-8", errors="replace") as fh:
                lines = fh.readlines()
        checked, findings = check_env_lines(lines, args.label)
        if checked < args.min_vars:
            sys.stderr.write(f"FAIL: {args.label}: read {checked} variable(s), need >= {args.min_vars} "
                             "-- refusing a pass over an environment that was never read\n")
            return 1
        for f in findings:
            sys.stderr.write(f"LEAK {f}\n")
        if findings:
            sys.stderr.write(f"\nIMAGE ENV GATE FAILED: {len(findings)} build-host setting(s) in {args.label}\n")
            return 1
        print(f"  ok: image env ({checked} variable(s) in {args.label}, no build-host setting)")
        return 0

    findings = []
    for rel in args.dockerfile:
        path = rel if os.path.isabs(rel) else os.path.join(ROOT, rel)
        if not os.path.isfile(path):
            findings.append(f"{rel}: not a file")
            continue
        findings.extend(scan_dockerfile(path, rel))
    for f in findings:
        sys.stderr.write(f"{f}\n")
    if findings:
        sys.stderr.write(f"\nIMAGE-ENV LINT FAILED ({len(findings)} finding(s))\n")
        return 1
    print(f"  ok: image env ({len(args.dockerfile)} Dockerfile(s), no build-host setting)")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
