#!/usr/bin/env python3
"""Small statistics helpers, so scores are not published as bare fractions.

A benchmark that prints "8/12" and "12/12" invites the reader to conclude the
second model is better. At that sample size the 95 % Wilson intervals are
[39 %, 86 %] and [76 %, 100 %] — they overlap, and the data does not support
the conclusion. Printing the interval next to the score makes that visible
instead of leaving it to be discovered later.

Wilson rather than the textbook normal approximation: the latter is badly
wrong exactly where this benchmark lives — small n, and proportions at 0 or 1,
where it produces a zero-width interval around a certainty nobody has.
"""

import math


def wilson_interval(successes, trials, z=1.96):
    """95 % confidence interval for a proportion. Returns (low, high) in 0..1."""
    if trials <= 0:
        return (0.0, 1.0)
    if successes < 0 or successes > trials:
        raise ValueError(f"successes {successes} out of range for {trials} trials")
    p = successes / trials
    denom = 1 + z * z / trials
    centre = (p + z * z / (2 * trials)) / denom
    half = z * math.sqrt(p * (1 - p) / trials + z * z / (4 * trials * trials)) / denom
    return (max(0.0, centre - half), min(1.0, centre + half))


def intervals_overlap(a_succ, a_tot, b_succ, b_tot, z=1.96):
    """Do two scores' intervals overlap? If so, they are not separable."""
    a_lo, a_hi = wilson_interval(a_succ, a_tot, z)
    b_lo, b_hi = wilson_interval(b_succ, b_tot, z)
    return a_lo <= b_hi and b_lo <= a_hi


def format_score(successes, trials, width=None):
    """'8/12 = 67% [39-86%]' — the score with what it can actually support."""
    if trials <= 0:
        return "n/a"
    lo, hi = wilson_interval(successes, trials)
    pct = 100 * successes / trials
    s = f"{successes}/{trials} = {pct:.0f}% [{100*lo:.0f}-{100*hi:.0f}%]"
    return f"{s:{width}}" if width else s


def significance_note(a_label, a_succ, a_tot, b_label, b_succ, b_tot):
    """Plain-language verdict on whether two scores are separable at all."""
    if a_tot <= 0 or b_tot <= 0:
        return "one side has no observations — nothing to compare"
    a_rate, b_rate = a_succ / a_tot, b_succ / b_tot
    if intervals_overlap(a_succ, a_tot, b_succ, b_tot):
        better = a_label if a_rate > b_rate else b_label
        if a_rate == b_rate:
            return "identical rates"
        return (f"{better} scores higher, but the 95 % intervals OVERLAP at this "
                f"sample size — not separable on this evidence alone")
    better = a_label if a_rate > b_rate else b_label
    return f"{better} is higher and the intervals do not overlap"


def minimum_detectable_drop(trials, from_rate=1.0, z=1.96):
    """The smallest score drop this many trials could actually prove.

    Without it, "no regression" is ambiguous between "nothing changed" and
    "this suite is too small to tell" — and the second reads exactly like the
    first. Measured example: removing a system prompt took a model from 8/8 to
    6/8, a real and causally understood degradation, and at n=8 the intervals
    still overlapped. Detecting a 100%->75% drop needs 27 cases; 100%->87.5%
    needs 60.

    Returns the rate below `from_rate` that would become separable, or None if
    no drop at all is detectable at this size.
    """
    if trials <= 0:
        return None
    successes = round(from_rate * trials)
    for lower in range(successes - 1, -1, -1):
        if not intervals_overlap(successes, trials, lower, trials, z):
            return lower / trials
    return None


def power_note(trials, from_rate=1.0):
    """One line stating what a 'no regression' verdict is actually worth."""
    mde = minimum_detectable_drop(trials, from_rate)
    if mde is None:
        return (f"at n={trials} this suite cannot prove ANY drop — "
                f"'no regression' here means 'cannot tell'")
    return (f"at n={trials} the smallest provable drop is {100*from_rate:.0f}% -> "
            f"{100*mde:.0f}%; anything subtler passes unnoticed")
