"""Every task must be solvable, and its tests must reject a wrong solution.

Two failure modes this guards against, both of which silently ruin a ranking:

  * an UNSOLVABLE task (a spec that contradicts its own tests) makes every
    model look incapable, and the benchmark looks decisive while measuring
    nothing;
  * a task whose tests are too weak passes a wrong solution, which is how the
    merge task accepted `return sorted(a + b)` for as long as it did.

So: a reference solution written from the prompt alone must pass, and a
deliberately wrong one must fail.
"""

import os
import sys

import pytest

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from bench_coding import EXTENDED_TASKS, NOVEL_TASKS, TASKS, run_candidate  # noqa: E402

REFERENCE = {
    "merge_sorted": '''
def merge_sorted(a: list, b: list) -> list:
    out, i, j = [], 0, 0
    while i < len(a) and j < len(b):
        if a[i] <= b[j]:
            out.append(a[i]); i += 1
        else:
            out.append(b[j]); j += 1
    out.extend(a[i:]); out.extend(b[j:])
    return out
''',
    "balanced": '''
def balanced(s: str) -> bool:
    pairs = {")": "(", "]": "[", "}": "{"}
    stack = []
    for ch in s:
        if ch in "([{":
            stack.append(ch)
        elif ch in pairs:
            if not stack or stack.pop() != pairs[ch]:
                return False
    return not stack
''',
    "parse_version": '''
def parse_version(v: str) -> tuple:
    if not isinstance(v, str) or not v.strip():
        raise ValueError("empty")
    t = v.strip()
    if t[:1].lower() == "v":
        t = t[1:]
    parts = t.split(".")
    if len(parts) > 3 or not all(p.isdigit() for p in parts) or not parts[0]:
        raise ValueError("bad version")
    nums = [int(p) for p in parts]
    while len(nums) < 3:
        nums.append(0)
    return tuple(nums)
''',
    "parse_lane_spec": '''
def parse_lane(spec: str) -> tuple:
    marker = ",model="
    if marker not in spec:
        raise ValueError("missing ,model= marker")
    head, model = spec.split(marker, 1)
    if "=" not in head:
        raise ValueError("missing = before the marker")
    name, url = head.split("=", 1)
    return (name.strip(), url.strip().rstrip("/"), model.strip())
''',
    "attempt_verdict": '''
def verdict(passed: bool, tokens: int, cap: int, closed_fence: bool) -> str:
    if cap < 1 or tokens < 0:
        raise ValueError("bad bounds")
    if passed:
        return "PASS"
    if tokens >= cap:
        return "CUT"
    if not closed_fence:
        return "CUT"
    return "FAIL"
''',
    "rank_quants": '''
def rank_quants(names: list) -> list:
    def digit(n):
        for ch in n:
            if ch.isdigit():
                return int(ch)
        return None
    kept = [n for n in names if digit(n) is not None]
    return sorted(kept, key=lambda n: (-digit(n), 0 if n.startswith("Q") else 1, n))
''',
}

WRONG = {
    # Ignores the stated constraint -- must be rejected by `forbidden`.
    "merge_sorted": "def merge_sorted(a: list, b: list) -> list:\n    return sorted(a + b)\n",
    # Counts brackets without checking nesting: accepts "([)]".
    "balanced": ("def balanced(s: str) -> bool:\n"
                 "    return s.count('(') == s.count(')') and s.count('[') == s.count(']')\n"),
    # Never raises on garbage.
    "parse_version": ("def parse_version(v: str) -> tuple:\n"
                      "    p = [int(x) for x in v.lstrip('v').split('.') if x.isdigit()]\n"
                      "    return tuple(p + [0] * (3 - len(p)))\n"),
    # Splits on the LAST marker, so a model name containing ',model=' breaks.
    "parse_lane_spec": ("def parse_lane(spec: str) -> tuple:\n"
                        "    head, model = spec.rsplit(',model=', 1)\n"
                        "    name, url = head.split('=', 1)\n"
                        "    return (name.strip(), url.strip().rstrip('/'), model.strip())\n"),
    # Checks the cap before `passed`, inverting rule order 1 and 2.
    "attempt_verdict": ("def verdict(passed, tokens, cap, closed_fence):\n"
                        "    if cap < 1 or tokens < 0: raise ValueError('bad')\n"
                        "    if tokens >= cap: return 'CUT'\n"
                        "    if passed: return 'PASS'\n"
                        "    return 'FAIL' if closed_fence else 'CUT'\n"),
    # Forgets the Q-before-IQ tiebreak.
    "rank_quants": ("def rank_quants(names: list) -> list:\n"
                    "    def d(n):\n"
                    "        for c in n:\n"
                    "            if c.isdigit(): return int(c)\n"
                    "        return None\n"
                    "    return sorted([n for n in names if d(n) is not None],\n"
                    "                  key=lambda n: (-d(n), n))\n"),
}

# The extended set carries its own reference/wrong solutions, so it needs no
# entry in the dicts above — the guard reads them off the task itself.
ALL_TASKS = TASKS + NOVEL_TASKS + EXTENDED_TASKS


def _reference(task):
    return task.get("reference") or REFERENCE[task["name"]]


def _wrong(task):
    return task.get("wrong") or WRONG[task["name"]]


@pytest.mark.parametrize("task", ALL_TASKS, ids=lambda t: t["name"])
def test_reference_solution_passes(task):
    """The task is solvable, and its own tests agree with its own prompt."""
    ok, detail, _credit = run_candidate(_reference(task), task["tests"],
                                        forbidden=task.get("forbidden"))
    assert ok, f"{task['name']}: reference solution rejected — {detail}"


@pytest.mark.parametrize("task", ALL_TASKS, ids=lambda t: t["name"])
def test_wrong_solution_is_rejected(task):
    """The tests are strong enough to catch a plausible wrong answer."""
    ok, _, _credit = run_candidate(_wrong(task), task["tests"],
                                   forbidden=task.get("forbidden"))
    assert not ok, f"{task['name']}: a known-wrong solution PASSED — tests too weak"


class TestTaskShape:
    @pytest.mark.parametrize("task", ALL_TASKS, ids=lambda t: t["name"])
    def test_prompt_states_the_exact_signature(self, task):
        # Grading is mechanical, so the required name must be unambiguous.
        assert "def " in task["prompt"] and "exact signature" in task["prompt"]

    @pytest.mark.parametrize("task", ALL_TASKS, ids=lambda t: t["name"])
    def test_tests_are_not_empty(self, task):
        assert task["tests"].count("assert") >= 4, "too few assertions to be decisive"

    def test_task_names_are_unique(self):
        names = [t["name"] for t in ALL_TASKS]
        assert len(names) == len(set(names))

    def test_novel_tasks_do_not_duplicate_classic_ones(self):
        assert not ({t["name"] for t in TASKS} & {t["name"] for t in NOVEL_TASKS})
