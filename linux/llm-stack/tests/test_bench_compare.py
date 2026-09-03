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

from bench_compare import compare, load, normalise, pair_directories  # noqa: E402


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
        assert any("not separable" in f.lower() for f in findings)

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


def report_with_cases(label, cases, wall=10.0, benchmark="bench_tools", prov=None):
    """A report carrying per-case detail, as the real tools emit."""
    results = [{"case": k, "passed": v} for k, v in cases.items()]
    passed = sum(1 for v in cases.values() if v)
    return {"benchmark": benchmark, "provenance": prov or {}, "config": {},
            "reports": [{"label": label, "model": label, "passed": passed,
                         "total": len(cases), "total_wall_s": wall,
                         "median_wall_s": None, "effective_n": len(cases),
                         "deterministic": True, "results": results}]}


class TestPerCaseComparison:
    """The aggregate is the weaker test. On a deterministic endpoint a case that
    flipped is a concrete, attributable change, and it needs no statistics --
    which matters because the measured 93%->81% degradation would need 119
    cases to clear a confidence interval, while naming the broken cases needs
    none."""

    def test_a_flipped_case_is_a_regression_even_when_the_aggregate_is_not(self):
        old = normalise(report_with_cases("m", {f"c{i}": True for i in range(27)}))
        new_cases = {f"c{i}": True for i in range(27)}
        for i in range(3):
            new_cases[f"c{i}"] = False
        new = normalise(report_with_cases("m", new_cases))
        findings, regressed = compare(old, new)
        assert regressed, "three named cases broke; that is not noise"
        assert any("case(s) that PASSED now fail" in f for f in findings)

    def test_the_broken_cases_are_named(self):
        old = normalise(report_with_cases("m", {"a": True, "b": True, "c": True}))
        new = normalise(report_with_cases("m", {"a": True, "b": False, "c": True}))
        findings, _ = compare(old, new)
        assert any("broke: b" in f for f in findings)

    def test_fixed_cases_are_reported_without_failing(self):
        old = normalise(report_with_cases("m", {"a": False, "b": True}))
        new = normalise(report_with_cases("m", {"a": True, "b": True}))
        findings, regressed = compare(old, new)
        assert not regressed
        assert any("now fixed" in f for f in findings)

    def test_a_swap_still_regresses_even_at_an_identical_score(self):
        # Same 1/2 both times, but a different case passes. The aggregate sees
        # nothing; that is precisely the blind spot this closes.
        old = normalise(report_with_cases("m", {"a": True, "b": False}))
        new = normalise(report_with_cases("m", {"a": False, "b": True}))
        findings, regressed = compare(old, new)
        assert regressed and any("broke: a" in f for f in findings)

    def test_new_cases_absent_from_the_baseline_are_ignored(self):
        # Adding a case the baseline never ran must not read as a regression.
        old = normalise(report_with_cases("m", {"a": True}))
        new = normalise(report_with_cases("m", {"a": True, "brand_new": False}))
        _, regressed = compare(old, new)
        assert not regressed

    def test_reports_without_per_case_detail_still_compare(self):
        old = normalise(report([("m", 28, 30, 10.0)]))
        new = normalise(report([("m", 5, 30, 10.0)]))
        _, regressed = compare(old, new)
        assert regressed, "the aggregate path must keep working for older reports"


def report_repeats(label, cases, wall=10.0, deterministic=False, config=None,
                   errored=()):
    """A report with N attempts per case, as --repeats produces."""
    results = []
    for name, outcomes in cases.items():
        for i, ok in enumerate(outcomes):
            results.append({"case": name, "attempt": i, "passed": ok,
                            "errored": name in errored})
    passed = sum(1 for v in cases.values() for ok in v if ok)
    total = sum(len(v) for v in cases.values())
    return {"benchmark": "bench_tools", "provenance": {}, "config": config or {},
            "reports": [{"label": label, "model": label, "passed": passed,
                         "total": total, "total_wall_s": wall,
                         "median_wall_s": wall / max(total, 1),
                         "effective_n": len(cases) if deterministic else total,
                         "deterministic": deterministic, "results": results}]}


class TestRepeatsAreNotCollapsed:
    """Collapsing repeats to a bool with all() was wrong in BOTH directions:
    it fired on one flaky draw, and it went silent on a total collapse."""

    def test_one_flaky_draw_does_not_fire_the_alarm(self):
        # 3/3 -> 2/3 on a sampling lane. Firing here mutes the tripwire.
        old = normalise(report_repeats("m", {"a": [True, True, True]}))
        new = normalise(report_repeats("m", {"a": [True, True, False]}))
        findings, regressed = compare(old, new)
        assert not regressed
        assert any("pass less often" in f for f in findings), \
            "the degradation should still be visible, just not alarmed"

    def test_a_total_per_case_collapse_is_caught(self):
        # 2/3 -> 0/3. The old all() rule produced False -> False: nothing at all.
        old = normalise(report_repeats("m", {"a": [True, True, False],
                                             "b": [True, True, True]}))
        new = normalise(report_repeats("m", {"a": [False, False, False],
                                             "b": [True, True, True]}))
        findings, regressed = compare(old, new)
        assert regressed and any("broke: a" in f for f in findings)

    def test_transport_errors_are_excluded_from_the_case_view(self):
        old = normalise(report_repeats("m", {"a": [True]}))
        new = normalise(report_repeats("m", {"a": [False]}, errored=("a",)))
        findings, regressed = compare(old, new)
        assert not regressed, "an HTTP failure is not the model failing"


class TestConfigIsCompared:
    """Dropping --system or changing --repeats changes what the numbers MEAN.
    Both used to surface as the model regressing."""

    def test_a_changed_system_prompt_is_called_out(self):
        old = normalise(report_repeats("m", {"a": [True]},
                                       config={"system_prompt": "p.md", "repeats": 1}))
        new = normalise(report_repeats("m", {"a": [True]},
                                       config={"system_prompt": None, "repeats": 1}))
        findings, _ = compare(old, new)
        assert any("config.system_prompt changed" in f for f in findings)

    def test_timing_is_not_compared_across_a_repeats_change(self):
        # total_wall_s scales linearly with repeats; comparing raw totals
        # reported a slowdown for doing three times the work.
        old = normalise(report_repeats("m", {"a": [True]}, wall=10.0,
                                       config={"repeats": 1}))
        new = normalise(report_repeats("m", {"a": [True, True, True]}, wall=30.0,
                                       config={"repeats": 3}))
        findings, regressed = compare(old, new)
        assert not regressed
        assert any("timing not compared" in f for f in findings)


class TestTimingUsesPerAttempt:
    def test_a_run_that_errored_out_is_not_reported_as_faster(self):
        # Summing only successful requests made a half-failed run look quick.
        old = normalise(report_repeats("m", {"a": [True], "b": [True], "c": [True]},
                                       wall=30.0, config={"repeats": 1}))
        new = normalise(report_repeats("m", {"a": [True], "b": [True], "c": [True]},
                                       wall=60.0, config={"repeats": 1}))
        findings, regressed = compare(old, new)
        assert regressed and any("SLOWER" in f for f in findings)
        assert any("per attempt" in f for f in findings)


class TestIntervalsUseEffectiveN:
    def test_repeats_on_a_deterministic_lane_do_not_manufacture_significance(self):
        # 5 cases repeated 4x looks like n=20; it is 5 observations.
        cases_old = {f"c{i}": [True] * 4 for i in range(5)}
        cases_new = {f"c{i}": [True] * 4 for i in range(5)}
        cases_new["c0"] = [False] * 4
        old = normalise(report_repeats("m", cases_old, deterministic=True,
                                       config={"repeats": 4}))
        new = normalise(report_repeats("m", cases_new, deterministic=True,
                                       config={"repeats": 4}))
        findings, _ = compare(old, new)
        score_line = next(f for f in findings if "->" in f and "/" in f)
        assert "/5" in score_line, f"intervals should use effective_n=5: {score_line}"


class TestDirectoryPairing:
    """Run-to-run comparison over whole result directories.

    The comparer existed and nothing ever called it; the sweep writes one report
    per config, so comparing two runs means pairing those files up. Both
    directions matter here too: a real regression in any config must fail, and a
    config that quietly disappeared must not pass as "nothing to report".
    """

    def _run_dir(self, tmp_path, name, entries):
        d = tmp_path / name
        d.mkdir()
        for fname, ent in entries.items():
            (d / fname).write_text(json.dumps(report(ent)))
        return d

    def test_pairs_by_file_name(self, tmp_path):
        old = self._run_dir(tmp_path, "old", {"a.json": [("m", 9, 10, 5.0)],
                                              "b.json": [("m", 9, 10, 5.0)]})
        new = self._run_dir(tmp_path, "new", {"a.json": [("m", 9, 10, 5.0)],
                                              "c.json": [("m", 9, 10, 5.0)]})
        pairs, only_new, only_old = pair_directories(str(old), str(new))
        assert [p[0] for p in pairs] == ["a.json"]
        assert only_new == ["c.json"] and only_old == ["b.json"]

    def test_manifest_is_an_index_not_a_report(self, tmp_path):
        old = self._run_dir(tmp_path, "old", {"a.json": [("m", 9, 10, 5.0)]})
        new = self._run_dir(tmp_path, "new", {"a.json": [("m", 9, 10, 5.0)]})
        for d in (old, new):
            (d / "_manifest.json").write_text("{}")
        pairs, _, _ = pair_directories(str(old), str(new))
        assert [p[0] for p in pairs] == ["a.json"]

    def _cli(self, old, new):
        import subprocess
        here = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
        return subprocess.run([sys.executable, os.path.join(here, "bench_compare.py"),
                               "--dir", str(old), str(new)],
                              capture_output=True, text=True)

    def test_a_real_regression_in_any_config_fails(self, tmp_path):
        old = self._run_dir(tmp_path, "old", {"a.json": [("m", 10, 10, 5.0)],
                                              "b.json": [("m", 10, 10, 5.0)]})
        new = self._run_dir(tmp_path, "new", {"a.json": [("m", 10, 10, 5.0)],
                                              "b.json": [("m", 2, 10, 5.0)]})
        r = self._cli(old, new)
        assert r.returncode == 1, r.stdout + r.stderr
        assert "REGRESSION" in r.stdout

    def test_identical_runs_do_not_cry_wolf(self, tmp_path):
        same = {"a.json": [("m", 9, 10, 5.0)], "b.json": [("m", 8, 10, 6.0)]}
        old = self._run_dir(tmp_path, "old", same)
        new = self._run_dir(tmp_path, "new", same)
        r = self._cli(old, new)
        assert r.returncode == 0, r.stdout + r.stderr
        assert "2 report(s) compared" in r.stdout

    def test_a_vanished_config_is_reported_not_swallowed(self, tmp_path):
        old = self._run_dir(tmp_path, "old", {"a.json": [("m", 9, 10, 5.0)],
                                              "gone.json": [("m", 9, 10, 5.0)]})
        new = self._run_dir(tmp_path, "new", {"a.json": [("m", 9, 10, 5.0)]})
        r = self._cli(old, new)
        assert "gone.json" in r.stdout and "1 gone" in r.stdout

    def test_no_common_reports_is_an_error_not_a_pass(self, tmp_path):
        old = self._run_dir(tmp_path, "old", {"a.json": [("m", 9, 10, 5.0)]})
        new = self._run_dir(tmp_path, "new", {"z.json": [("m", 9, 10, 5.0)]})
        r = self._cli(old, new)
        assert r.returncode != 0
