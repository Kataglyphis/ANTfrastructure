#!/usr/bin/env python3
"""Rank models by whether their code actually RUNS (LB-coding).

The generic correctness probe in benchmark_openai_api.py answers "is this model
working at all". It cannot answer "is this model good at code" -- a model can
recite Canberra and still emit a broken function.

So: give each model a small set of coding tasks with an exact required
signature, extract the code it produces, execute it against hidden test cases
in a subprocess, and report how many tasks passed alongside the time it took to
get there. Everything here is measured, nothing is judged by eye.

Ranking uses time to a FINISHED answer, not tok/s: a reasoning model can be the
fastest per token and the slowest to usable code.

SAFETY: this executes model-generated code. Each candidate runs in a temporary
directory as a separate process with a hard timeout. Do not point it at an
untrusted endpoint.

Usage:
    python3 bench_coding.py --backend geniex-npu
    python3 bench_coding.py --backend geniex-cpu --model unsloth/Qwen3-4B-GGUF:Q4_0
    python3 bench_coding.py --compare candidates.json --output coding.json
"""

import argparse
import json
import os
import re
import subprocess
import sys
import tempfile
import time
import urllib.request

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

# ── Tasks ─────────────────────────────────────────────────────────────────────
# Each task pins an exact signature so the check is mechanical, and the tests
# include the edge cases a plausible-looking wrong answer trips over.

TASKS = [
    {
        "name": "merge_sorted",
        "prompt": (
            "Write a Python function with this exact signature:\n"
            "    def merge_sorted(a: list, b: list) -> list\n"
            "It merges two already-sorted lists into one sorted list. "
            "Do not use sorted() or list.sort(). "
            "Reply with the function in a single ```python code block and nothing else."
        ),
        "tests": """
assert merge_sorted([], []) == []
assert merge_sorted([1], []) == [1]
assert merge_sorted([], [2]) == [2]
assert merge_sorted([1,3,5], [2,4,6]) == [1,2,3,4,5,6]
assert merge_sorted([1,1,2], [1,3]) == [1,1,1,2,3]
assert merge_sorted([-5,0], [-9,-1,7]) == [-9,-5,-1,0,7]
assert merge_sorted([1,2,3], []) == [1,2,3]
""",
    },
    {
        "name": "balanced",
        "prompt": (
            "Write a Python function with this exact signature:\n"
            "    def balanced(s: str) -> bool\n"
            "It returns True if the brackets (), [] and {} in s are correctly "
            "balanced and nested, ignoring all other characters. "
            "Reply with the function in a single ```python code block and nothing else."
        ),
        "tests": """
assert balanced("") is True
assert balanced("()") is True
assert balanced("([]{})") is True
assert balanced("(]") is False
assert balanced("([)]") is False
assert balanced("(") is False
assert balanced(")(") is False
assert balanced("a(b[c]{d})e") is True
""",
    },
    {
        "name": "parse_version",
        "prompt": (
            "Write a Python function with this exact signature:\n"
            "    def parse_version(v: str) -> tuple\n"
            "It parses a version string like '1.2.3' into a tuple of ints (1, 2, 3). "
            "Missing components default to 0, so '1.2' gives (1, 2, 0) and '2' gives (2, 0, 0). "
            "A leading 'v' is allowed and ignored. Raise ValueError on anything else. "
            "Reply with the function in a single ```python code block and nothing else."
        ),
        "tests": """
assert parse_version("1.2.3") == (1, 2, 3)
assert parse_version("1.2") == (1, 2, 0)
assert parse_version("2") == (2, 0, 0)
assert parse_version("v3.4.5") == (3, 4, 5)
assert parse_version("0.0.0") == (0, 0, 0)
try:
    parse_version("abc"); raise AssertionError("should have raised")
except ValueError:
    pass
try:
    parse_version(""); raise AssertionError("should have raised")
except ValueError:
    pass
""",
    },
]

CODE_FENCE = re.compile(r"```(?:python|py)?\s*\n(.*?)```", re.S | re.I)

# GenieX v0.5.0 stops generating at 2048 tokens regardless of max_tokens (which
# it ignores outright: max_tokens=3000 produced 642 tokens, max_tokens=500
# produced 1249). A reasoning model can spend that entire budget inside <think>
# and get cut off mid-function -- which grades as a SyntaxError and looks like
# incompetence. It is neither: it is an unmeasured task. Detected and reported
# apart from a genuine wrong answer, exactly as the correctness probe does.
GENERATION_CAP = int(os.environ.get("BENCH_GENERATION_CAP", "2048"))


def extract_code(text):
    """Pull the code out of a reply.

    Prefers a fenced block. Falls back to the first `def ...` onwards, because
    some models answer with bare code -- refusing to grade that would measure
    formatting compliance rather than coding ability.
    """
    # Strip a reasoning block first: a discarded draft inside <think> must not
    # be graded instead of the real answer.
    if "</think>" in text:
        text = text.split("</think>")[-1]
    blocks = CODE_FENCE.findall(text)
    if blocks:
        return max(blocks, key=len).strip()
    idx = text.find("def ")
    return text[idx:].strip() if idx != -1 else ""


def looks_truncated(text, chunks, code):
    """Was the reply cut off by the server rather than finished by the model?

    Two independent signals, either of which is enough:
      * the generation hit the server's hard cap, or
      * the code does not even parse as complete Python (an unclosed bracket or
        string is what a mid-token cut looks like).
    Requiring both would miss a cut that lands on a syntactically valid prefix.
    """
    if chunks >= GENERATION_CAP:
        return True
    if code:
        try:
            compile(code, "<candidate>", "exec")
        except SyntaxError:
            # An unterminated construct is a cut; a plain typo usually is not,
            # but a fenced block that never closed is decisive.
            if text.count("```") % 2 == 1:
                return True
    return False


def run_candidate(code, tests, timeout=15):
    """Execute the generated function against the tests. Returns (ok, detail)."""
    if not code.strip():
        return False, "no code found in reply"
    program = code + "\n\n" + tests + "\nprint('PASS')\n"
    with tempfile.TemporaryDirectory() as tmp:
        path = os.path.join(tmp, "candidate.py")
        with open(path, "w") as f:
            f.write(program)
        try:
            proc = subprocess.run([sys.executable, path], cwd=tmp,
                                  capture_output=True, text=True, timeout=timeout)
        except subprocess.TimeoutExpired:
            return False, f"timed out after {timeout}s (likely an infinite loop)"
    if proc.returncode == 0 and "PASS" in proc.stdout:
        return True, "all assertions passed"
    err = (proc.stderr or proc.stdout or "").strip().splitlines()
    return False, (err[-1][:120] if err else f"exit {proc.returncode}")


def ask(base_url, model, prompt, max_tokens, timeout=1800):
    """One streamed request. Returns (text, ttft_s, wall_s, chunks)."""
    body = json.dumps({
        "model": model, "stream": True, "max_tokens": max_tokens,
        "temperature": 0, "messages": [{"role": "user", "content": prompt}],
    }).encode()
    req = urllib.request.Request(f"{base_url}/v1/chat/completions", data=body,
                                 headers={"Content-Type": "application/json"})
    started = time.monotonic()
    ttft = None
    parts = []
    with urllib.request.urlopen(req, timeout=timeout) as resp:
        for raw in resp:
            line = raw.decode("utf-8", "replace").strip()
            if not line.startswith("data:"):
                continue
            payload = line[5:].lstrip()
            if payload == "[DONE]":
                break
            try:
                chunk = json.loads(payload)
            except json.JSONDecodeError:
                continue
            choices = chunk.get("choices") or []
            if choices:
                piece = choices[0].get("delta", {}).get("content")
                if piece:
                    if ttft is None:
                        ttft = time.monotonic() - started
                    parts.append(piece)
    text = "".join(parts)
    return text, ttft, time.monotonic() - started, len(parts)


def evaluate(base_url, model, label, max_tokens, keep_output=False, repeats=1):
    """Run every task against one model. Returns a report dict.

    `repeats` matters more than it looks: GenieX honours neither `max_tokens`
    nor `temperature`, so the llama.cpp lanes SAMPLE even at temperature=0 --
    five identical requests to the 2B produced five different answers, four
    passing and one failing the same task. A single run therefore measures one
    draw, not the model. (The QAIRT/NPU path is deterministic: four identical
    requests, one unique output, so repeats there only cost time.)
    """
    print(f"\n  === {label} ===", flush=True)
    results = []
    for task in TASKS:
      for attempt in range(repeats):
        suffix = f" [{attempt+1}/{repeats}]" if repeats > 1 else ""
        try:
            text, ttft, wall, chunks = ask(base_url, model, task["prompt"], max_tokens)
        except Exception as e:  # noqa: BLE001 — one dead task must not end the sweep
            print(f"    {task['name']:15s}{suffix} ERROR {type(e).__name__}: {e}", flush=True)
            results.append({"task": task["name"], "attempt": attempt, "passed": False,
                            "detail": f"request failed: {e}", "wall_s": None})
            continue
        code = extract_code(text)
        ok, detail = run_candidate(code, task["tests"])
        truncated = (not ok) and looks_truncated(text, chunks, code)
        if truncated:
            detail = f"CUT OFF at {chunks} tokens (server cap) - not graded as wrong"
        think_share = 0.0
        if "</think>" in text:
            think_share = 1 - len(text.split("</think>")[-1]) / len(text)
        verdict = "PASS" if ok else ("CUT " if truncated else "FAIL")
        print(f"    {task['name']:15s}{suffix} {verdict}  "
              f"{wall:6.1f}s  ttft={ttft or 0:5.2f}s  tokens={chunks:5d}  "
              f"think={100*think_share:3.0f}%  {'' if ok else detail}", flush=True)
        entry = {"task": task["name"], "attempt": attempt,
                 "passed": ok, "truncated": truncated, "detail": detail,
                 "wall_s": round(wall, 2), "ttft_s": round(ttft, 3) if ttft else None,
                 "tokens": chunks, "thinking_char_share": round(think_share, 3)}
        if keep_output:
            entry["code"] = code
        results.append(entry)

    done = [r for r in results if r["wall_s"] is not None]
    passed = sum(1 for r in results if r["passed"])
    cut = sum(1 for r in results if r.get("truncated"))
    attempts = len(TASKS) * repeats
    wrong = attempts - passed - cut
    total_wall = sum(r["wall_s"] for r in done)
    extra = f", {cut} cut off" if cut else ""
    # With repeats the headline is a RATE, not a score: "4/6 attempts" says
    # something a single 2/3 cannot.
    unit = "attempts" if repeats > 1 else "tasks"
    print(f"    -> {passed}/{attempts} {unit} pass{extra}, {total_wall:.1f}s total",
          flush=True)
    return {"label": label, "model": model, "base_url": base_url,
            "passed": passed, "wrong": wrong, "truncated": cut,
            "total": attempts, "repeats": repeats, "tasks": len(TASKS),
            "total_wall_s": round(total_wall, 2),
            "avg_wall_s": round(total_wall / len(done), 2) if done else None,
            "results": results}


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--backend", default=None, help="Named backend from backends.json")
    ap.add_argument("--base-url", default=None)
    ap.add_argument("--model", default=None)
    ap.add_argument("--label", default=None)
    ap.add_argument("--max-tokens", type=int, default=3000,
                    help="Budget per task. Reasoning models need room; a model cut "
                         "off mid-thought produces no code and scores 0 (default 3000)")
    ap.add_argument("--compare", default=None,
                    help="JSON file: [{label, backend|base_url, model}, ...]")
    ap.add_argument("--keep-output", action="store_true",
                    help="Store the generated code in the report")
    ap.add_argument("--repeats", type=int, default=1,
                    help="Run each task N times. The llama.cpp lanes sample even at "
                         "temperature=0 (GenieX ignores it), so a single run measures "
                         "one draw rather than the model. 3+ for a defensible number.")
    ap.add_argument("--output", default=None)
    args = ap.parse_args()

    from benchmark_openai_api import resolve_backend

    candidates = []
    if args.compare:
        with open(args.compare) as f:
            for entry in json.load(f):
                url, model, _ = resolve_backend(entry.get("backend"), entry.get("base_url"))
                candidates.append((entry.get("label") or entry.get("model"),
                                   url, entry.get("model") or model))
    else:
        url, model, _ = resolve_backend(args.backend, args.base_url)
        candidates.append((args.label or args.model or model, url, args.model or model))

    reports = [evaluate(url, model, label, args.max_tokens, args.keep_output,
                        repeats=args.repeats)
               for label, url, model in candidates]

    if len(reports) > 1:
        print("\n" + "=" * 78)
        print("  RANKING — by tasks passed, then by time to a finished answer")
        print("=" * 78)
        ranked = sorted(reports, key=lambda r: (-r["passed"], r["total_wall_s"]))
        print(f"  {'model':42s} {'pass':>5s} {'wrong':>6s} {'cut':>4s} "
              f"{'total':>9s} {'avg/task':>9s}")
        for r in ranked:
            print(f"  {r['label'][:42]:42s} {r['passed']}/{r['total']:<3d} "
                  f"{r.get('wrong', 0):5d} {r.get('truncated', 0):4d} "
                  f"{r['total_wall_s']:8.1f}s {r['avg_wall_s'] or 0:8.1f}s")
        if any(r.get("truncated") for r in ranked):
            print("\n  'cut' = the server stopped generation at its 2048-token cap "
                  "before the model\n  finished. Those tasks are UNMEASURED, not failed "
                  "- a reasoning model can\n  spend the whole budget inside <think>.")
        print()

    if args.output:
        with open(args.output, "w") as f:
            json.dump(reports, f, indent=2)
        print(f"  Report written to {args.output}")


if __name__ == "__main__":
    main()
