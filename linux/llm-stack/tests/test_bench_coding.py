"""Tests for the coding grader.

If the grader is wrong, every measurement it produces is worthless -- so the
cases below are the ones that would silently corrupt a ranking: code hidden in
a <think> block, a plausible-but-wrong implementation, an infinite loop, and a
reply with no code at all.
"""

import os
import sys

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from bench_coding import TASKS, extract_code, run_candidate  # noqa: E402

MERGE = next(t for t in TASKS if t["name"] == "merge_sorted")
BALANCED = next(t for t in TASKS if t["name"] == "balanced")

GOOD_MERGE = '''
def merge_sorted(a: list, b: list) -> list:
    out, i, j = [], 0, 0
    while i < len(a) and j < len(b):
        if a[i] <= b[j]:
            out.append(a[i]); i += 1
        else:
            out.append(b[j]); j += 1
    out.extend(a[i:]); out.extend(b[j:])
    return out
'''


class TestExtraction:
    def test_fenced_python_block(self):
        assert "def f" in extract_code("blah\n```python\ndef f(): pass\n```\ndone")

    def test_unfenced_code_is_still_graded(self):
        # Refusing bare code would measure formatting compliance, not ability.
        assert extract_code("Here you go:\ndef f():\n    return 1").startswith("def f")

    def test_thinking_block_is_dropped(self):
        # A discarded draft inside <think> must never be graded instead of the
        # real answer -- that would score a model on code it rejected.
        text = ("<think>maybe\n```python\ndef merge_sorted(a,b): return None\n```"
                "</think>\n```python\ndef merge_sorted(a,b): return sorted(a+b)\n```")
        code = extract_code(text)
        assert "return sorted" in code and "return None" not in code

    def test_longest_block_wins(self):
        text = "```python\nx=1\n```\ntext\n```python\ndef f():\n    return 42\n```"
        assert "def f" in extract_code(text)

    def test_no_code_yields_empty(self):
        assert extract_code("I cannot help with that.") == ""


class TestGrading:
    def test_correct_implementation_passes(self):
        ok, detail = run_candidate(GOOD_MERGE, MERGE["tests"])
        assert ok, detail

    def test_plausible_but_wrong_fails(self):
        # Drops duplicates -- looks right, fails merge_sorted([1,1,2],[1,3]).
        bad = '''
def merge_sorted(a: list, b: list) -> list:
    out = []
    for x in a + b:
        if x not in out:
            out.append(x)
    return out
'''
        ok, _ = run_candidate(bad, MERGE["tests"])
        assert not ok

    def test_infinite_loop_is_caught_not_hung(self):
        spin = '''
def merge_sorted(a: list, b: list) -> list:
    while True:
        pass
'''
        ok, detail = run_candidate(spin, MERGE["tests"], timeout=3)
        assert not ok and "timed out" in detail

    def test_empty_reply_fails_with_a_clear_reason(self):
        ok, detail = run_candidate("", MERGE["tests"])
        assert not ok and "no code" in detail

    def test_syntax_error_fails(self):
        ok, _ = run_candidate("def merge_sorted(a, b) return a", MERGE["tests"])
        assert not ok

    def test_wrong_function_name_fails(self):
        ok, _ = run_candidate("def merge(a, b): return a + b", MERGE["tests"])
        assert not ok

    def test_balanced_task_rejects_a_naive_counter(self):
        # Counting brackets without checking nesting passes "([)]" wrongly.
        naive = '''
def balanced(s: str) -> bool:
    return s.count("(") == s.count(")") and s.count("[") == s.count("]") and s.count("{") == s.count("}")
'''
        ok, _ = run_candidate(naive, BALANCED["tests"])
        assert not ok, "the test set must catch a counter that ignores nesting"


class TestTruncationDetection:
    """Cut off != wrong. Grading a truncated reply as incompetence is how a
    server limit gets misreported as a model's ability -- the exact mistake the
    first run of this benchmark made against Qwen3-4B."""

    def test_hitting_the_generation_cap_counts_as_truncated(self):
        from bench_coding import GENERATION_CAP, looks_truncated
        assert looks_truncated("some text", GENERATION_CAP, "def f(): pass")

    def test_short_reply_is_not_truncated(self):
        from bench_coding import looks_truncated
        assert not looks_truncated("```python\ndef f(): pass\n```", 120, "def f(): pass")

    def test_unclosed_fence_with_broken_code_is_truncated(self):
        from bench_coding import looks_truncated
        text = "```python\ndef f(:\n    return ("      # fence never closed
        assert looks_truncated(text, 100, "def f(:\n    return (")

    def test_valid_code_in_a_closed_fence_is_never_truncated(self):
        from bench_coding import looks_truncated
        text = "```python\ndef f():\n    return 1\n```"
        assert not looks_truncated(text, 100, "def f():\n    return 1")

    def test_a_plain_typo_in_a_closed_fence_is_wrong_not_truncated(self):
        # Closed fence + syntax error = the model wrote bad code on purpose.
        from bench_coding import looks_truncated
        text = "```python\ndef f() return 1\n```"
        assert not looks_truncated(text, 100, "def f() return 1")
