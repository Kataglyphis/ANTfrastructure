#!/usr/bin/env python3
"""Diff two benchmark reports and fail on a regression.

Every tool here writes a report and, until this existed, nothing read two of
them. That made each measurement a one-off: a model swap, a runtime bump or an
edit to the grader could cost accuracy or speed and nobody would know.

Three things it refuses to do, because each is a way to be confidently wrong:

  * call a difference a regression when the sample cannot support it — the
    Wilson intervals are checked first, and overlapping intervals are reported
    as "not separable", not as a change;
  * blame the model when the *grader* moved — provenance carries a hash of the
    benchmark's own source, and a mismatch is stated before any score;
  * compare across hosts or architectures silently.

Usage:
    python3 bench_compare.py old.json new.json
    python3 bench_compare.py --baseline geniex-npu new.json      # vs stored
    python3 bench_compare.py --save-baseline geniex-npu new.json
"""

import argparse
import json
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from bench_provenance import compare as compare_provenance  # noqa: E402
from bench_stats import format_score, intervals_overlap, power_note  # noqa: E402

BASELINE_DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)), "baselines")

# A timing change under this is treated as noise rather than a regression.
DEFAULT_TIME_TOLERANCE = 0.25


def normalise(report):
    """Bring either report shape into one form.

    The suite emits two envelopes: the newer tools write
    {benchmark, provenance, config, reports:[...]} while benchmark_openai_api.py
    writes {timestamp, model, api_url, hardware, config, results:[...]}. Rather
    than break the viewer that reads the older one, adapt here — and record the
    divergence as a debt (roadmap P2.3) instead of hiding it behind this
    function.
    """
    if isinstance(report, dict) and "reports" in report:
        entries = []
        for r in report["reports"]:
            # Per-case outcomes matter more than the aggregate on a
            # deterministic endpoint: a case that flipped is a concrete,
            # attributable change, where the proportion may not move enough to
            # clear a confidence interval.
            cases = {}
            for item in r.get("results", []):
                key = item.get("case") or item.get("task")
                if key is not None:
                    cases.setdefault(key, []).append(bool(item.get("passed")))
            entries.append({
                "label": r.get("label") or r.get("model"),
                "model": r.get("model"),
                "passed": r.get("passed"),
                "total": r.get("total"),
                "wall_s": r.get("total_wall_s"),
                "median_wall_s": r.get("median_wall_s"),
                "effective_n": r.get("effective_n"),
                "deterministic": r.get("deterministic"),
                "cases": {k: all(v) for k, v in cases.items()},
            })
        return {"benchmark": report.get("benchmark", "unknown"),
                "provenance": report.get("provenance", {}),
                "config": report.get("config", {}),
                "entries": entries}

    # older shape: one model, scores live in per-prompt results
    results = report.get("results", []) if isinstance(report, dict) else []
    ok = [r for r in results if "error" not in r]
    walls = [r.get("latency_s") for r in ok if r.get("latency_s") is not None]
    correctness = report.get("correctness") or {}
    return {
        "benchmark": "benchmark_openai_api",
        "provenance": report.get("hardware", {}),
        "config": report.get("config", {}),
        "entries": [{
            "label": report.get("model"),
            "model": report.get("model"),
            # Only the correctness probe is a score; throughput is not pass/fail.
            "passed": correctness.get("score"),
            "total": correctness.get("total"),
            "wall_s": round(sum(walls), 2) if walls else None,
            "median_wall_s": None,
            "effective_n": correctness.get("total"),
            "deterministic": None,
        }],
    }


def load(path):
    with open(path) as f:
        return normalise(json.load(f))


def compare(old, new, time_tolerance=DEFAULT_TIME_TOLERANCE):
    """Returns (findings, regressed). `findings` is a list of printable lines."""
    findings = []
    regressed = False

    if old["benchmark"] != new["benchmark"]:
        findings.append(f"! different benchmarks: {old['benchmark']} vs {new['benchmark']}")
        return findings, True

    for note in compare_provenance(old.get("provenance", {}), new.get("provenance", {})):
        findings.append(f"! {note}")

    old_by = {e["label"]: e for e in old["entries"]}
    new_by = {e["label"]: e for e in new["entries"]}

    for label in sorted(set(old_by) - set(new_by)):
        findings.append(f"- {label}: present in the old run, missing from the new one")
    for label in sorted(set(new_by) - set(old_by)):
        findings.append(f"+ {label}: new, no baseline to compare against")

    for label in sorted(set(old_by) & set(new_by)):
        a, b = old_by[label], new_by[label]

        # --- per-case diff, which needs no statistics to be meaningful
        a_cases, b_cases = a.get("cases") or {}, b.get("cases") or {}
        shared = set(a_cases) & set(b_cases)
        broke = sorted(k for k in shared if a_cases[k] and not b_cases[k])
        fixed = sorted(k for k in shared if not a_cases[k] and b_cases[k])
        if broke:
            findings.append(f"  {label}: {len(broke)} case(s) that PASSED now fail — "
                            f"*** REGRESSION ***")
            for k in broke:
                findings.append(f"      broke: {k}")
            regressed = True
        if fixed:
            findings.append(f"  {label}: {len(fixed)} case(s) now fixed: "
                            f"{', '.join(fixed)}")

        if a.get("total") and b.get("total"):
            a_rate = a["passed"] / a["total"]
            b_rate = b["passed"] / b["total"]
            line = (f"  {label}: {format_score(a['passed'], a['total'])} -> "
                    f"{format_score(b['passed'], b['total'])}")
            if b_rate < a_rate:
                if intervals_overlap(a["passed"], a["total"], b["passed"], b["total"]):
                    note = "   lower; the AGGREGATE is not separable at this sample size"
                    if broke:
                        note += " (but named cases broke — see above)"
                    findings.append(line + note)
                else:
                    findings.append(line + "   *** REGRESSION ***")
                    regressed = True
            elif b_rate > a_rate:
                sep = "" if intervals_overlap(a["passed"], a["total"],
                                              b["passed"], b["total"]) else " (separable)"
                findings.append(line + f"   improved{sep}")
            else:
                findings.append(line + "   unchanged")

        if a.get("wall_s") and b.get("wall_s"):
            delta = (b["wall_s"] - a["wall_s"]) / a["wall_s"]
            mark = ""
            if delta > time_tolerance:
                mark = "   *** SLOWER ***"
                regressed = True
            elif delta < -time_tolerance:
                mark = "   faster"
            findings.append(f"  {label}: {a['wall_s']:.1f}s -> {b['wall_s']:.1f}s "
                            f"({delta:+.0%}){mark}")

    return findings, regressed


def baseline_path(name):
    return os.path.join(BASELINE_DIR, f"{name}.json")


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("reports", nargs="+", help="old.json new.json, or just new.json with --baseline")
    ap.add_argument("--baseline", default=None, help="Compare against a stored baseline by name")
    ap.add_argument("--save-baseline", default=None,
                    help="Store this report as the accepted baseline under that name")
    ap.add_argument("--time-tolerance", type=float, default=DEFAULT_TIME_TOLERANCE,
                    help="Relative slowdown treated as noise (default 0.25)")
    args = ap.parse_args()

    if args.save_baseline:
        os.makedirs(BASELINE_DIR, exist_ok=True)
        with open(args.reports[-1]) as src, open(baseline_path(args.save_baseline), "w") as dst:
            dst.write(src.read())
        print(f"  Baseline '{args.save_baseline}' saved from {args.reports[-1]}")
        return

    if args.baseline:
        path = baseline_path(args.baseline)
        if not os.path.exists(path):
            raise SystemExit(f"no baseline named {args.baseline!r} in {BASELINE_DIR}. "
                             f"Record one with --save-baseline {args.baseline} <report>")
        old, new = load(path), load(args.reports[-1])
        old_name, new_name = f"baseline:{args.baseline}", args.reports[-1]
    else:
        if len(args.reports) < 2:
            ap.error("give two reports, or one report with --baseline")
        old, new = load(args.reports[0]), load(args.reports[1])
        old_name, new_name = args.reports[0], args.reports[1]

    print(f"\n  {old_name}\n  -> {new_name}\n")
    findings, regressed = compare(old, new, args.time_tolerance)
    for line in findings:
        print(f"  {line}")
    print()
    if regressed:
        print("  REGRESSION — see the lines marked ***")
    else:
        # "No regression" must not be mistaken for "nothing changed" when the
        # suite is too small to tell the difference.
        sizes = [e["total"] for e in new["entries"] if e.get("total")]
        has_cases = any(e.get("cases") for e in new["entries"])
        print("  no regression detected")
        if sizes:
            print(f"  {power_note(min(sizes))}")
        if not has_cases:
            print("  (no per-case detail in these reports — only the aggregate "
                  "could be checked, which is the weaker test)")
    sys.exit(1 if regressed else 0)


if __name__ == "__main__":
    main()
