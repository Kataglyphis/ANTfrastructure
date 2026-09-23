#!/usr/bin/env python3
# Copyright (c) 2025 Kataglyphis
# SPDX-License-Identifier: MIT
"""A published image's environment carries no build-host setting: no sccache
remote-cache variable, no RFC1918 or link-local address. The Windows image shipped
SCCACHE_WEBDAV_ENDPOINT=http://192.168.x.x:5000 and every consumer's sccache died
on it (2026-09-23).

--env-file FILE|-   the NAME=VALUE lines of a BUILT image's config (the publish gate).
--dockerfile FILE.. static: ENV instructions and ARG defaults, plus every Windows
                    RUN that runs an sccache server must see ARG SCCACHE_WEBDAV_ENDPOINT.

Not covered: hostnames and loopback, image history (a RUN records its build args),
files inside the image. docs/build-cache-tiers.md#the-shipped-image-carries-no-build-host-setting"""
import argparse
import ipaddress
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

# The build host's cache layout and every sccache REMOTE backend. Local defaults
# (SCCACHE_DIR, _CACHE_SIZE, _ERROR_LOG, _LOG, _IDLE_TIMEOUT) are allowed.
BUILD_HOST_NAME = re.compile(
    r"^SCCACHE_(?:WEBDAV_\w+|REDIS\w*|MEMCACHED\w*|GCS_\w+|AZURE_\w+|S3_\w+|OSS_\w+|"
    r"COS_\w+|GHA_\w+|BUCKET|ENDPOINT|REGION|MULTILEVEL_CHAIN|FORCE_LOCAL)$",
    re.IGNORECASE)
PRIVATE_V4 = tuple(ipaddress.ip_network(n) for n in
                   ("10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16", "169.254.0.0/16"))
IPV4 = re.compile(r"(?<![\w.])(\d{1,3}(?:\.\d{1,3}){3})(?![\w.])")
IPV6_LINK_LOCAL = re.compile(r"(?:^|[\s,;=\[@\"'(])(fe[89ab][0-9a-f]:[0-9a-f:.%]*)", re.IGNORECASE)
LEAD = set(" \t,;=\"'([")
TRAIL = set(" \t,;\"')]")
AUTHORITY = re.compile(r"//(?:[^/@\s]*@)?$")
REF = re.compile(r"\$\{?([A-Za-z_][A-Za-z0-9_]*)")
# A compiling RUN mounts BOTH the cache and its error-log dir (#90); either alone is a
# probe (the cache cleaner, the persistent-log reader) that starts no sccache server.
SCCACHE_MOUNTS = tuple(re.compile(r"--mount=[^\s]*target=C:\\%s(?=[,\s]|$)" % d, re.IGNORECASE)
                       for d in ("sccache", "sccache-logs"))
ENDPOINT_ARG = "SCCACHE_WEBDAV_ENDPOINT"


def _host_position(value, start, end, name):
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


def leak_reasons(name, value):
    """Why NAME=VALUE must not ship in a published image; [] when it may."""
    reasons = []
    if BUILD_HOST_NAME.match(name):
        reasons.append("build-host sccache setting (the image may carry local defaults only)")
    return reasons + address_reasons(name, value)


def address_reasons(name, value):
    """The RFC1918/link-local addresses VALUE carries in a host position."""
    reasons = []
    for m in IPV4.finditer(value):
        try:
            addr = ipaddress.ip_address(m.group(1))
        except ValueError:
            continue
        if any(addr in net for net in PRIVATE_V4) and _host_position(value, m.start(1), m.end(1), name):
            reasons.append("RFC1918/link-local address %s" % m.group(1))
    for m in IPV6_LINK_LOCAL.finditer(value):
        reasons.append("link-local address %s" % m.group(1))
    return reasons


def check_env_lines(lines, label):
    """(checked, findings) over NAME=VALUE lines; blanks and comments are skipped."""
    checked, findings = 0, []
    for raw in lines:
        line = raw.rstrip("\r\n")
        if not line.strip() or line.lstrip().startswith("#"):
            continue
        name, _, value = line.partition("=")
        checked += 1
        for why in leak_reasons(name.strip(), value):
            findings.append("%s: %s=%s -- %s" % (label, name.strip(), value, why))
    return checked, findings


def _escape_char(lines):
    """The `# escape=` parser directive, or the default backslash."""
    for line in lines:
        m = re.match(r"^#\s*escape\s*=\s*(\S)\s*$", line.strip())
        if m:
            return m.group(1)
        if not line.strip().startswith("#"):
            break
    return "\\"


def instructions(path):
    """(line, text) per instruction: continuations joined with the file's own escape
    character, comment lines inside a continuation dropped as BuildKit drops them."""
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


def _tokens(body):
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


def _unquote(value):
    if len(value) >= 2 and value[0] == value[-1] and value[0] in "\"'":
        return value[1:-1]
    return value


def _pairs(body, legacy):
    """KEY=VALUE pairs of an ENV/ARG body; `legacy` accepts ENV's old `ENV KEY value` form.
    An ARG with no default yields (name, None)."""
    toks = _tokens(body)
    if legacy and toks and "=" not in toks[0]:
        return [(toks[0], _unquote(" ".join(toks[1:])))]
    return [(t.split("=", 1)[0], _unquote(t.split("=", 1)[1]) if "=" in t else None) for t in toks]


def _scan_arg(where, body, stage_args):
    findings = []
    for key, value in _pairs(body, legacy=False):
        stage_args.add(key)
        findings += ["%s: ARG %s default carries a %s" % (where, key, why)
                     for why in address_reasons(key, value or "")]
    return findings


def _scan_env(where, body):
    findings = []
    for key, value in _pairs(body, legacy=True):
        findings += ["%s: ENV %s -- %s" % (where, key, why) for why in leak_reasons(key, value or "")]
        findings += ["%s: ENV %s expands the build-host ARG ${%s} into the image" % (where, key, ref)
                     for ref in REF.findall(value or "") if BUILD_HOST_NAME.match(ref)]
    return findings


def _scan_run(where, body, stage_args):
    if all(m.search(body) for m in SCCACHE_MOUNTS) and ENDPOINT_ARG not in stage_args:
        return ["%s: RUN compiles through sccache (it mounts C:\\sccache and C:\\sccache-logs) but "
                "its stage declares no ARG %s above it -- the endpoint never reaches this compile"
                % (where, ENDPOINT_ARG)]
    return []


def scan_dockerfile(path, rel):
    findings, stage_args = [], set()
    for line, text in instructions(path):
        head, _, body = text.partition(" ")
        head = head.upper()
        where = "%s:%d" % (rel, line)
        if head == "FROM":
            stage_args = set()
        elif head == "ARG":
            findings += _scan_arg(where, body, stage_args)
        elif head == "ENV":
            findings += _scan_env(where, body)
        elif head == "RUN":
            findings += _scan_run(where, body, stage_args)
    return findings


def main(argv):
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
            sys.stderr.write("FAIL: %s: read %d variable(s), need >= %d -- refusing a pass over "
                             "an environment that was never read\n" % (args.label, checked, args.min_vars))
            return 1
        for f in findings:
            sys.stderr.write("LEAK %s\n" % f)
        if findings:
            sys.stderr.write("\nIMAGE ENV GATE FAILED: %d build-host setting(s) in %s\n"
                             % (len(findings), args.label))
            return 1
        print("  ok: image env (%d variable(s) in %s, no build-host setting)" % (checked, args.label))
        return 0

    findings = []
    for rel in args.dockerfile:
        path = rel if os.path.isabs(rel) else os.path.join(ROOT, rel)
        if not os.path.isfile(path):
            findings.append("%s: not a file" % rel)
            continue
        findings.extend(scan_dockerfile(path, rel))
    for f in findings:
        sys.stderr.write("%s\n" % f)
    if findings:
        sys.stderr.write("\nIMAGE-ENV LINT FAILED (%d finding(s))\n" % len(findings))
        return 1
    print("  ok: image env (%d Dockerfile(s), no build-host setting)" % len(args.dockerfile))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
