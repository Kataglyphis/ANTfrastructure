"""Tests for the interval maths.

The reason this module exists: the suite published "8/12" and "12/12" as though
the second were demonstrably better. It is not, at that sample size — and a
benchmark that hides its own uncertainty is worse than one with no numbers,
because it invites confident wrong conclusions.
"""

import os
import sys

import pytest

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from bench_stats import (format_score, intervals_overlap,  # noqa: E402
                         significance_note, wilson_interval)


class TestWilsonInterval:
    def test_certainty_does_not_produce_a_zero_width_interval(self):
        # The normal approximation gives [1.0, 1.0] here, claiming certainty
        # nobody has after 9 observations. Wilson does not.
        lo, hi = wilson_interval(9, 9)
        assert hi == 1.0
        assert lo < 0.9, "an interval this narrow would overstate 9 observations"

    def test_zero_successes_is_handled(self):
        lo, hi = wilson_interval(0, 9)
        assert lo == 0.0 and 0 < hi < 0.5

    def test_more_trials_narrow_the_interval(self):
        small = wilson_interval(8, 12)
        large = wilson_interval(80, 120)
        assert (large[1] - large[0]) < (small[1] - small[0])

    def test_no_trials_yields_full_range(self):
        assert wilson_interval(0, 0) == (0.0, 1.0)

    def test_rejects_impossible_input(self):
        with pytest.raises(ValueError):
            wilson_interval(5, 3)

    def test_interval_always_contains_the_point_estimate(self):
        for k, n in ((0, 5), (1, 5), (3, 5), (5, 5), (8, 12), (12, 12)):
            lo, hi = wilson_interval(k, n)
            assert lo <= k / n <= hi, (k, n)


class TestSeparability:
    def test_the_case_that_motivated_this(self):
        # 8/12 vs 12/12 was reported as an improvement. It is not separable.
        assert intervals_overlap(8, 12, 12, 12)

    def test_a_large_clear_difference_is_separable(self):
        assert not intervals_overlap(2, 30, 28, 30)

    def test_identical_scores_overlap(self):
        assert intervals_overlap(5, 10, 5, 10)

    def test_note_names_the_overlap_explicitly(self):
        note = significance_note("new", 12, 12, "old", 8, 12)
        assert "OVERLAP" in note and "not separable" in note.lower()

    def test_note_confirms_a_real_difference(self):
        note = significance_note("A", 30, 30, "B", 5, 30)
        assert "do not overlap" in note

    def test_note_handles_empty_input(self):
        assert "nothing to compare" in significance_note("A", 0, 0, "B", 1, 1)


class TestFormatting:
    def test_score_carries_its_interval(self):
        s = format_score(8, 12)
        assert "8/12" in s and "67%" in s and "[" in s and "]" in s

    def test_no_trials_is_not_rendered_as_zero_percent(self):
        assert format_score(0, 0) == "n/a"


class TestStatisticalPower:
    """'No regression' and 'too small to tell' read identically unless the
    suite says which one it means. These numbers are why the case count is a
    blocker rather than a nice-to-have."""

    def test_a_tiny_suite_can_only_prove_a_collapse(self):
        from bench_stats import smallest_separable_rate
        mde = smallest_separable_rate(8)
        assert mde is not None and mde <= 0.35, \
            "at n=8 only a near-total collapse is provable"

    def test_more_cases_detect_subtler_drops(self):
        from bench_stats import smallest_separable_rate
        assert smallest_separable_rate(60) > smallest_separable_rate(8)

    def test_the_measured_case_needs_about_27(self):
        # Removing the system prompt took a model 100% -> 75%: real, causally
        # understood, and invisible at n=8.
        from bench_stats import intervals_overlap
        assert intervals_overlap(8, 8, 6, 8), "n=8 cannot separate it"
        assert not intervals_overlap(27, 27, 20, 27), "n=27 can"

    def test_a_suite_too_small_to_prove_anything_says_so(self):
        from bench_stats import smallest_separable_rate, power_note
        assert smallest_separable_rate(2) is None
        assert "cannot prove ANY drop" in power_note(2)

    def test_power_note_states_the_threshold(self):
        from bench_stats import power_note
        note = power_note(8)
        assert "n=8" in note and "smallest provable drop" in note

    def test_zero_trials_is_not_a_crash(self):
        from bench_stats import smallest_separable_rate
        assert smallest_separable_rate(0) is None
