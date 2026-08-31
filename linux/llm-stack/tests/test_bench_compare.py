"""Tests for the regression comparer.

A comparer is only useful if it is trustworthy in both directions: it must
catch a real regression, and it must NOT cry wolf. A tripwire that fires on
noise gets muted, and a muted tripwire is the same as none.

The three ways to be confidently wrong, each tested here:
  * calling a difference a regression the sample cannot support,
  * blaming the model when the grader changed,
  * comparing two different things and not noticing.
"""

import json
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from bench_compare import compare, load, normalise  # noqa: E402


def report(entries, benchmark="bench_tools", prov=None):
    return {"benchmark": benchmark, "provenance": prov or {}, "config": {},
            "reports": [dict(label=l, model=l, passed=p, total=t,
                             total_wall_s=w, median_wall_s=None,
                             effective_n=t, deterministic=False)
                        for l, p, t, w in entries]}


class TestNormalisation:
    def test_reads_the_new_envelope(self):
        n = normalise(report([("m", 8, 12, 20.0)]))
        assert n["benchmark"] == "bench_tools"
        assert n["entries"][0]["passed"] == 8

    def test_reads_the_older_benchmark_openai_api_envelope(self):
        # The suite emits two shapes; refusing one would leave half the history
        # uncomparable.
        old = {"model": "m", "hardware": {"host": "h"}, "config": {},
               "correctness": {"score": 5, "total": 6},
               "results": [{"latency_s": 1.5}, {"latency_s": 2.5}]}
        n = normalise(old)
        assert n["benchmark"] == "benchmark_openai_api"
        assert n["entries"][0]["passed"] == 5 and n["entries"][0]["wall_s"] == 4.0

    def test_a_run_without_a_correctness_probe_has_no_score(self):
        n = normalise({"model": "m", "results": [{"latency_s": 1.0}]})
        assert n["entries"][0]["passed"] is None


class TestRegressionDetection:
    def test_a_large_drop_is_a_regression(self):
        old = normalise(report([("m", 28, 30, 10.0)]))
        new = normalise(report([("m", 5, 30, 10.0)]))
        findings, regressed = compare(old, new)
        assert regressed and any("REGRESSION" in f for f in findings)

    def test_a_drop_the_sample_cannot_support_is_NOT_a_regression(self):
        # 12/12 -> 8/12 looks alarming and is not separable at n=12. Firing here
        # is how a tripwire gets muted.
        old = normalise(report([("m", 12, 12, 10.0)]))
        new = normalise(report([("m", 8, 12, 10.0)]))
        findings, regressed = compare(old, new)
        assert not regressed
        assert any("NOT SEPARABLE" in f for f in findings)

    def test_an_improvement_is_not_flagged(self):
        old = normalise(report([("m", 5, 30, 10.0)]))
        new = normalise(report([("m", 28, 30, 10.0)]))
        _, regressed = compare(old, new)
        assert not regressed

    def test_unchanged_scores_are_reported_as_such(self):
        old = normalise(report([("m", 9, 9, 10.0)]))
        findings, regressed = compare(old, old)
        assert not regressed and any("unchanged" in f for f in findings)


class TestTiming:
    def test_a_large_slowdown_is_a_regression(self):
        old = normalise(report([("m", 9, 9, 10.0)]))
        new = normalise(report([("m", 9, 9, 20.0)]))
        findings, regressed = compare(old, new)
        assert regressed and any("SLOWER" in f for f in findings)

    def test_small_timing_noise_is_tolerated(self):
        old = normalise(report([("m", 9, 9, 10.0)]))
        new = normalise(report([("m", 9, 9, 11.0)]))
        _, regressed = compare(old, new)
        assert not regressed, "10% is noise on this hardware; firing here mutes the alarm"

    def test_the_tolerance_is_adjustable(self):
        old = normalise(report([("m", 9, 9, 10.0)]))
        new = normalise(report([("m", 9, 9, 11.0)]))
        _, regressed = compare(old, new, time_tolerance=0.05)
        assert regressed


class TestProvenanceGuards:
    def test_a_changed_grader_is_surfaced(self):
        # The trap: the ranking moved because the BENCHMARK changed.
        old = normalise(report([("m", 9, 9, 10.0)], prov={"tool_sha256": "aaa"}))
        new = normalise(report([("m", 9, 9, 10.0)], prov={"tool_sha256": "bbb"}))
        findings, _ = compare(old, new)
        assert any("BENCHMARK SOURCE CHANGED" in f for f in findings)

    def test_comparing_different_benchmarks_is_refused(self):
        old = normalise(report([("m", 9, 9, 10.0)], benchmark="bench_tools"))
        new = normalise(report([("m", 9, 9, 10.0)], benchmark="bench_coding"))
        findings, regressed = compare(old, new)
        assert regressed and any("different benchmarks" in f for f in findings)


class TestEntrySetChanges:
    def test_a_disappeared_model_is_reported(self):
        old = normalise(report([("a", 9, 9, 10.0), ("b", 9, 9, 10.0)]))
        new = normalise(report([("a", 9, 9, 10.0)]))
        findings, _ = compare(old, new)
        assert any("missing from the new one" in f for f in findings)

    def test_a_new_model_is_reported_without_failing(self):
        old = normalise(report([("a", 9, 9, 10.0)]))
        new = normalise(report([("a", 9, 9, 10.0), ("b", 9, 9, 10.0)]))
        findings, regressed = compare(old, new)
        assert not regressed and any("no baseline" in f for f in findings)


class TestRoundTrip:
    def test_loads_a_report_written_to_disk(self, tmp_path):
        p = tmp_path / "r.json"
        p.write_text(json.dumps(report([("m", 9, 9, 10.0)])))
        assert load(str(p))["entries"][0]["passed"] == 9
