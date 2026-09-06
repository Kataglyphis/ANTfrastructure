#!/usr/bin/env python3
# Copyright (c) 2025 Kataglyphis. All rights reserved.
# SPDX-License-Identifier: Apache-2.0
#
# Linux port of the PreToolUse delete guard. Rationale, incident history and
# the pattern-design rules (quote-stripping, proximity, why there are NO
# verb-only rules) live in guard-destructive-deletes.ps1 next door and
# docs/failure-modes.md — this file only carries the Linux rule table.
# Contract: PreToolUse JSON on stdin, decision on stdout, ALWAYS exit 0.
# Tested by linux/scripts/tests/test-delete-guard.sh.

import json
import re
import sys

# The negative lookbehind for "-" keeps container flags out of the verb match:
# the PowerShell original documents that exact false positive firing six times
# on 2026-08-25, and this port reproduced it on its first real container run.
VERB = re.compile(
    r"(?<!git )(?<!-)\brm\b|\brmdir\b|\bunlink\b|\bshred\b|\bdd\b"
    r"|\bfind\b[^\n]*-delete\b|\bmkfs(\.|\s)|\btruncate\b"
)

# Uninstalling the host's software is never the agent's call.
PKG_REMOVE = re.compile(
    r"\b(?:apt|apt-get|aptitude|dnf|yum|zypper)\b[^\n|;&]*\b(?:purge|remove|autoremove)\b"
    r"|\bdpkg\b[^\n|;&]*(?:\s-r\b|\s-P\b|--remove|--purge)"
    r"|\bsnap\s+remove\b|\bflatpak\s+uninstall\b"
)

# Blanked out (INCLUDING a trailing /*) before the protected checks: the
# genuinely reclaimable set. A bare /* left behind read as the filesystem root.
RECLAIMABLE = (
    "<home>/.cache/kata-buildcache",
    "/var/tmp",
)

# (pattern, what) — any hit under a delete verb is a hard deny.
PROTECTED = (
    (re.compile(r"(^|[\s\"'=])/\*?([\s\"';|&]|$)"), "the filesystem root"),
    (re.compile(r"(^|[\s\"'=])/(usr|etc|var|boot|bin|sbin|lib|lib64|srv|root|opt)\b"), "a system directory"),
    (re.compile(r"<home>(/\*|/?([\s\"';|&]|$))"), "the home directory root"),
    (re.compile(
        r"<home>/\.(ssh|gnupg|aws|kube|docker|claude|config|gitconfig|bashrc|profile|vscode|cargo"
        r"|local/share/containerd|local/share/buildkit|local/bin)\b"
    ), "a credential, config or store directory in the user profile"),
    (re.compile(r"(of=)?/dev/(sd|hd|vd|nvme|mmcblk|dm-|loop)[a-z0-9]*\b"), "a block device"),
)

EXEMPT_FILES = {
    "guard-destructive-deletes.py",
    "guard-destructive-deletes.ps1",
    "test-delete-guard.sh",
    "prune-safe.sh",
    "Clear-DiskSpace.ps1",
}


def deny(reason: str) -> None:
    print(json.dumps({
        "hookSpecificOutput": {
            "hookEventName": "PreToolUse",
            "permissionDecision": "deny",
            "permissionDecisionReason": (
                "Blocked by guard-destructive-deletes: this " + reason + ". "
                "Host disk reclaim goes through linux/host-config/prune-safe.sh. "
                "A delete that must reach a protected root is for the user to run "
                "themselves, not the agent."
            ),
        }
    }))
    sys.exit(0)


_SEGMENT = re.compile(r"[;&|\n]+")
_CD = re.compile(r"\bcd\s+([^\s;&|]+)")


def _split_outside_quotes(text: str):
    """Split on ; & | and newline, but never inside a quoted span.

    A regex split cuts through quotes, so the quote-stripping below has nothing
    to strip. docs/failure-modes.md#delete-guard-scope
    """
    out, buf, quote = [], [], ""
    for ch in text:
        if quote:
            buf.append(ch)
            if ch == quote:
                quote = ""
        elif ch in "'\"":
            quote = ch
            buf.append(ch)
        elif ch in ";&|\n":
            out.append("".join(buf))
            buf = []
        else:
            buf.append(ch)
    out.append("".join(buf))
    return [s for s in out if s.strip()]


def _delete_segments(norm: str):
    """Segments that carry a delete verb, each prefixed with the directory a
    preceding `cd` established. docs/failure-modes.md#delete-guard-scope"""
    cwd = ""
    for seg in _split_outside_quotes(norm):
        bare = re.sub(r"'[^']*'|\"[^\"]*\"", " ", seg)
        if VERB.search(bare):
            yield f"{cwd} {seg}" if cwd else seg
        found = _CD.search(bare)
        if found:
            cwd = found.group(1)


def verdict(text: str) -> str | None:
    if not text or not text.strip():
        return None
    # Verbs match with quoted spans removed (prose about a delete is not one);
    # paths match on the full text, where a real delete's path usually lives.
    bare = re.sub(r"'[^']*'|\"[^\"]*\"", " ", text).lower()
    if PKG_REMOVE.search(bare):
        return "command removes software from this host"
    if not VERB.search(bare):
        return None
    norm = text.lower()
    norm = re.sub(r"\$\{?home\}?|(?<![\w.])~(?=/|\s|$)", "<home>", norm)
    for ok in RECLAIMABLE:
        norm = re.sub(re.escape(ok) + r"(/\*)?", " <reclaimable> ", norm)
    # Verb and path were matched across the WHOLE command, so a delete of a
    # scratch path was denied whenever the command merely MENTIONED /opt — that
    # blocked real work five times on 2026-09-02. Scope the path check to the
    # segments that actually delete. The bare-root pattern additionally matches
    # on quote-stripped text: on the full text it fires on ordinary shell such
    # as `sed 's/^/  /'`. docs/failure-modes.md#delete-guard-scope
    for seg in _delete_segments(norm):
        seg_bare = re.sub(r"'[^']*'|\"[^\"]*\"", " ", seg)
        for rx, what in PROTECTED:
            if rx.search(seg_bare if what == "the filesystem root" else seg):
                return "command deletes from " + what
    return None


def main() -> None:
    try:
        ev = json.load(sys.stdin)
    except Exception:
        sys.exit(0)
    tool = str(ev.get("tool_name", ""))
    tin = ev.get("tool_input") or {}

    if tool in ("Bash", "PowerShell", ""):
        v = verdict(str(tin.get("command", "")))
        if v:
            deny(v)
    if tool in ("Write", "Edit", "MultiEdit"):
        path = str(tin.get("file_path", ""))
        leaf = path.replace("\\", "/").rsplit("/", 1)[-1].lower()
        if leaf in EXEMPT_FILES:
            sys.exit(0)
        body = str(tin.get("content", "") or tin.get("new_string", ""))
        v = verdict(body)
        if v:
            deny("file content " + v.removeprefix("command "))
    sys.exit(0)


if __name__ == "__main__":
    main()
