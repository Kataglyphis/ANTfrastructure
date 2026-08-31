#!/usr/bin/env python3
"""The front end bench_coding.py and bench_tools.py share.

Not extracted for tidiness. The candidate-resolution block was byte-identical
across 17 lines in both tools, comment included — and the None-label defect an
audit found existed in BOTH copies and had to be fixed twice, in one commit,
because a sweep happened to walk every file. The next such lesson would have
been written into one copy only.

Extracting it also gives that lesson a test seam it never had: nothing in
tests/ imports either tool's main(), so candidate resolution — the code that
decides WHICH endpoint gets measured — had no coverage at all.

Deliberately NOT here:
  * grading logic (TASKS, extract_code, run_candidate, grade, evaluate) stays
    in each tool, and this module is deliberately kept OUT of the
    `tool_sha256` fingerprint. That hash exists so bench_compare can say "a
    score difference may be the grader, not the model"; folding plumbing into
    it would fire that alarm on every --compare-schema edit while the grader is
    provably unchanged — a false-positive generator on the suite's headline
    safety signal.
  * bench_lanes.resolve_lane, which parses a different surface
    (`name=URL,model=MODEL` strings, not a JSON candidate file). Merging them
    would produce one resolver with two input grammars.
"""

import json
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))


def resolve_candidates(args, resolve_backend):
    """Return [(label, base_url, model)] from --compare or the single-run flags.

    `resolve_backend` is passed in rather than imported so this module does not
    drag benchmark_openai_api into every importer, and so tests can substitute
    a stub without a server.

    The label fallback chain is load-bearing: both `label` and `model` are
    optional in a --compare file (the model may come from backends.json), and a
    None label used to crash the ranking print AFTER every request had been
    made and BEFORE the report was written — destroying hours of measurement
    over a format string.
    """
    candidates = []
    compare_file = getattr(args, "compare", None)
    if compare_file:
        with open(compare_file) as f:
            entries = json.load(f)
        if not isinstance(entries, list):
            raise SystemExit(f"{compare_file}: expected a JSON list of candidates")
        for entry in entries:
            url, model, _ = resolve_backend(entry.get("backend"), entry.get("base_url"))
            resolved = entry.get("model") or model
            label = (entry.get("label") or resolved
                     or entry.get("backend") or url or "unnamed")
            candidates.append((label, url, resolved))
    else:
        url, model, _ = resolve_backend(getattr(args, "backend", None),
                                        getattr(args, "base_url", None))
        resolved = getattr(args, "model", None) or model
        label = (getattr(args, "label", None) or resolved
                 or getattr(args, "backend", None) or url or "unnamed")
        candidates.append((label, url, resolved))
    return candidates


def write_report(path, benchmark, config, reports, base_url, tool_files):
    """Write one report in the shared envelope.

    Written BEFORE anything that merely prints: a ranking table must never be
    able to destroy a completed measurement, which is exactly what happened
    when a format string raised on a None label.

    `tool_files` stays per-tool on purpose — see the module docstring on why
    this file is not in the fingerprint.
    """
    from bench_provenance import collect

    payload = {
        "benchmark": benchmark,
        "provenance": collect(base_url, tool_files),
        "config": config,
        "reports": reports,
    }
    tmp = f"{path}.tmp"
    with open(tmp, "w") as f:
        json.dump(payload, f, indent=2)
    # Atomic: a Ctrl-C during the write used to be able to leave a truncated
    # JSON that a later comparison would silently misread.
    os.replace(tmp, path)
    return payload
