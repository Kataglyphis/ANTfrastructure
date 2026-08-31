#!/usr/bin/env python3
"""Record WHAT produced a measurement, so two reports can be compared later.

A benchmark result without provenance is a number without a claim. Four weeks
on you cannot say which model build, which runtime, or which repository state
produced it -- which makes run-to-run regression comparison impossible, and
makes an old number worse than no number because it looks authoritative.

Every field that cannot be determined is recorded as an explicit `null` and
listed in `incomplete`, rather than being silently omitted: a gap you can see
is a gap you can fix.
"""

import hashlib
import json
import os
import platform
import subprocess
import time
import urllib.request
from datetime import datetime, timezone

SCHEMA_VERSION = 1


def _git(*args):
    try:
        out = subprocess.run(["git", *args], capture_output=True, text=True,
                             timeout=10, cwd=os.path.dirname(os.path.abspath(__file__)))
        return out.stdout.strip() or None if out.returncode == 0 else None
    except Exception:
        return None


def _server_models(base_url, timeout=5):
    """Model ids the endpoint advertises — cheap fingerprint of what is served."""
    try:
        with urllib.request.urlopen(f"{base_url}/v1/models", timeout=timeout) as r:
            return sorted(m["id"] for m in json.load(r).get("data", []))
    except Exception:
        return None


def tool_fingerprint(*paths):
    """Hash of the benchmark's own source.

    A ranking can shift because the GRADER changed, not because a model did.
    Without this, that is indistinguishable from a real regression.
    """
    h = hashlib.sha256()
    here = os.path.dirname(os.path.abspath(__file__))
    for name in sorted(paths):
        try:
            with open(os.path.join(here, name), "rb") as f:
                h.update(f.read())
        except OSError:
            return None
    return h.hexdigest()[:16]


def busy_lanes(registry_path=None):
    """Which other endpoints were serving while this ran.

    Results shift with what else is running: a CPU lane measured 23.7 tok/s
    alone and 18.6 next to a busy NPU lane. Two runs taken under different load
    are not comparable, and without recording it nobody can tell which was
    which.
    """
    try:
        from benchmark_openai_api import load_backends
        backends, _ = load_backends(registry_path)
    except Exception:
        return None
    live = []
    for name, entry in sorted(backends.items()):
        url = entry.get("base_url")
        if not url:
            continue
        try:
            with urllib.request.urlopen(f"{url.rstrip('/')}/v1/models", timeout=2):
                live.append(name)
        except Exception:
            continue
    return live


def collect(base_url=None, tool_files=(), extra=None):
    """Return a provenance block for a report."""
    prov = {
        "schema_version": SCHEMA_VERSION,
        "timestamp_utc": datetime.now(timezone.utc).isoformat(),
        "monotonic_ns": time.monotonic_ns(),
        "host": platform.node() or None,
        "os": f"{platform.system()} {platform.release()}" if platform.system() else None,
        "architecture": platform.machine() or None,
        "python": platform.python_version(),
        "git_sha": _git("rev-parse", "HEAD"),
        "git_branch": _git("rev-parse", "--abbrev-ref", "HEAD"),
        # A dirty tree means the recorded SHA does not describe what actually ran.
        "git_dirty": bool(_git("status", "--porcelain")),
        "base_url": base_url,
        "server_models": _server_models(base_url) if base_url else None,
        "tool_sha256": tool_fingerprint(*tool_files) if tool_files else None,
        # Everything else that was answering when this started. A lane that was
        # busy slows the one being measured; recording it is the difference
        # between a comparable number and an unexplained one.
        "live_lanes": busy_lanes(),
    }
    if extra:
        prov.update(extra)

    required = ("timestamp_utc", "host", "architecture", "git_sha")
    prov["incomplete"] = [k for k in required if not prov.get(k)]
    return prov


def compare(old, new):
    """Differences between two provenance blocks, worst first.

    Used when diffing two runs: a result that moved while the runtime, the
    grader or the served models also moved is not evidence about the model.
    """
    notes = []
    if old.get("tool_sha256") != new.get("tool_sha256"):
        notes.append("BENCHMARK SOURCE CHANGED — a score difference may be the "
                     "grader, not the model")
    if old.get("server_models") != new.get("server_models"):
        notes.append("served models differ between the runs")
    if old.get("architecture") != new.get("architecture") or old.get("host") != new.get("host"):
        notes.append("different host or architecture")
    if old.get("live_lanes") is not None and new.get("live_lanes") is not None \
            and old["live_lanes"] != new["live_lanes"]:
        notes.append(f"different lanes were live: {old['live_lanes']} vs "
                     f"{new['live_lanes']} — a busy lane slows the one measured")
    if new.get("git_dirty") or old.get("git_dirty"):
        notes.append("at least one run came from a dirty working tree")
    if old.get("git_sha") != new.get("git_sha"):
        notes.append(f"repository moved {str(old.get('git_sha'))[:8]} → "
                     f"{str(new.get('git_sha'))[:8]}")
    return notes
