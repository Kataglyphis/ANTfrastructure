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
import statistics
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
        # The prompt states a constraint; without this the tests cannot see it.
        # `return sorted(a + b)` passed every assertion until this was added.
        "forbidden": ["sorted", "list.sort", ".sort("],
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

# ── Novel tasks ───────────────────────────────────────────────────────────────
#
# The tasks above (merging sorted lists, bracket balancing, version parsing) are
# textbook problems that appear thousands of times in any training corpus, so a
# model can ace them from RECALL without composing anything. That measures
# memorisation, not coding.
#
# These three are built from formats invented in this repository, with every
# rule stated in full in the prompt. The primitives are ordinary; the
# COMBINATION cannot have been memorised, so passing requires reading the spec
# and following it. Run both sets and compare: a model far better on the
# classic set than on this one is recalling, not reasoning.

NOVEL_TASKS = [
    {
        "name": "parse_lane_spec",
        "prompt": (
            "Write a Python function with this exact signature:\n"
            "    def parse_lane(spec: str) -> tuple\n"
            "It parses a benchmark lane specification of the form\n"
            "    name=URL,model=MODEL\n"
            "into the tuple (name, url, model). Rules:\n"
            "- Split on the FIRST occurrence of the literal ',model=' — the model "
            "name itself may contain commas and equals signs, and everything after "
            "that marker belongs to the model.\n"
            "- Split the part before it on the FIRST '=' into name and url.\n"
            "- Strip surrounding whitespace from all three, and strip any trailing "
            "'/' from the url.\n"
            "- Raise ValueError if the ',model=' marker is absent or if there is no "
            "'=' before it.\n"
            "Reply with the function in a single ```python code block and nothing else."
        ),
        "tests": """
assert parse_lane("npu=http://h:1,model=org/M:Q4") == ("npu", "http://h:1", "org/M:Q4")
assert parse_lane("cpu=http://h:1/,model=m") == ("cpu", "http://h:1", "m")
assert parse_lane(" a = http://h:2 ,model= weird,name=x ") == ("a", "http://h:2", "weird,name=x")
assert parse_lane("a=http://h:1,model=a,model=b") == ("a", "http://h:1", "a,model=b")
try:
    parse_lane("no-marker-here"); raise AssertionError("should have raised")
except ValueError:
    pass
try:
    parse_lane("nomodelequals,model=m"); raise AssertionError("should have raised")
except ValueError:
    pass
""",
    },
    {
        "name": "attempt_verdict",
        "prompt": (
            "Write a Python function with this exact signature:\n"
            "    def verdict(passed: bool, tokens: int, cap: int, closed_fence: bool) -> str\n"
            "It classifies one benchmark attempt, returning exactly one of the "
            "strings 'PASS', 'CUT' or 'FAIL'. Apply the rules IN THIS ORDER:\n"
            "1. If passed is True, return 'PASS' — regardless of every other argument.\n"
            "2. Otherwise, if tokens >= cap, return 'CUT'.\n"
            "3. Otherwise, if closed_fence is False, return 'CUT'.\n"
            "4. Otherwise return 'FAIL'.\n"
            "Raise ValueError if cap is less than 1 or tokens is negative.\n"
            "Reply with the function in a single ```python code block and nothing else."
        ),
        "tests": """
assert verdict(True, 5000, 2048, False) == 'PASS'
assert verdict(True, 10, 2048, True) == 'PASS'
assert verdict(False, 2048, 2048, True) == 'CUT'
assert verdict(False, 3000, 2048, True) == 'CUT'
assert verdict(False, 100, 2048, False) == 'CUT'
assert verdict(False, 100, 2048, True) == 'FAIL'
assert verdict(False, 0, 1, True) == 'FAIL'
try:
    verdict(False, 10, 0, True); raise AssertionError("should have raised")
except ValueError:
    pass
try:
    verdict(False, -1, 10, True); raise AssertionError("should have raised")
except ValueError:
    pass
""",
    },
    {
        "name": "rank_quants",
        "prompt": (
            "Write a Python function with this exact signature:\n"
            "    def rank_quants(names: list) -> list\n"
            "It sorts GGUF quantisation names from most to least precise, using "
            "ONLY these rules:\n"
            "- The precision of a name is the first digit appearing in it. "
            "'Q4_K_M' is 4, 'IQ3_XXS' is 3, 'Q8_0' is 8.\n"
            "- Higher digit sorts first.\n"
            "- Among names with the SAME digit, a name starting with 'Q' sorts "
            "before one starting with 'IQ'.\n"
            "- If still tied, sort alphabetically.\n"
            "- A name containing no digit is dropped from the result entirely.\n"
            "Reply with the function in a single ```python code block and nothing else."
        ),
        "tests": """
assert rank_quants(['IQ3_XXS', 'Q8_0', 'Q4_K_M']) == ['Q8_0', 'Q4_K_M', 'IQ3_XXS']
assert rank_quants(['IQ4_XS', 'Q4_0']) == ['Q4_0', 'IQ4_XS']
assert rank_quants(['Q4_K_S', 'Q4_K_M']) == ['Q4_K_M', 'Q4_K_S']
# BF16's FIRST digit is 1, not 16 — so it ranks below Q2_K. Deliberately
# counter-intuitive: the rule as written is what counts, not what the name
# suggests. (This assertion was wrong when first written; the reference-solution
# test caught it.)
assert rank_quants(['BF16', 'nodigits', 'Q2_K']) == ['Q2_K', 'BF16']
assert rank_quants([]) == []
assert rank_quants(['nodigit']) == []
""",
    },
]


CODE_FENCE = re.compile(r"```(?:python|py)?\s*\n(.*?)```", re.S | re.I)


def _want_from_prompt(task):
    """The required function name, taken from the signature the prompt pins."""
    m = re.search(r"def\s+(\w+)\s*\(", task.get("prompt", ""))
    return m.group(1) if m else None

# ── Long-context padding ──────────────────────────────────────────────────────
#
# The tasks above are ~40-token prompts. A coding agent never sends that: it
# sends a system prompt plus files, routinely thousands of tokens. Prefill is
# what the user waits on (a 2.5k-token prompt cost 13.1 s to first token on the
# NPU lane), and the QAIRT bundles carry a hard 4096-token context -- so the
# short-prompt ranking says nothing about the case that actually matters.
#
# Padding is real source from this repo rather than lorem ipsum: the point is a
# realistic prefill and a realistic distraction, not a token count.

PAD_SOURCES = ["benchmark_openai_api.py", "bench_lanes.py", "inspect_gguf.py"]


def build_context(approx_tokens):
    """Return a context block of roughly `approx_tokens` tokens of real code.

    ~4 characters per token is a rule of thumb for source; the measured
    prompt_tokens reported by the server is what gets recorded, so the estimate
    only has to be close enough to hit the intended size band.
    """
    if not approx_tokens:
        return ""
    here = os.path.dirname(os.path.abspath(__file__))
    chunks = []
    for name in PAD_SOURCES:
        try:
            with open(os.path.join(here, name)) as f:
                chunks.append(f"# ---- {name} ----\n{f.read()}")
        except OSError:
            continue
    body = "\n\n".join(chunks)
    while len(body) < approx_tokens * 4 and chunks:
        body += "\n\n" + "\n\n".join(chunks)
    return body[: approx_tokens * 4]

# GenieX v0.5.0 stops generating at 2048 tokens regardless of max_tokens (which
# it ignores outright: max_tokens=3000 produced 642 tokens, max_tokens=500
# produced 1249). A reasoning model can spend that entire budget inside <think>
# and get cut off mid-function -- which grades as a SyntaxError and looks like
# incompetence. It is neither: it is an unmeasured task. Detected and reported
# apart from a genuine wrong answer, exactly as the correctness probe does.
GENERATION_CAP = int(os.environ.get("BENCH_GENERATION_CAP", "2048"))


def extract_code(text, want=None):
    """Pull the code out of a reply.

    Prefers the fenced block that DEFINES the required function (`want`), then
    any block containing a def, and only then the longest. Falls back to the
    first `def ...` onwards, because some models answer with bare code --
    refusing to grade that would measure formatting compliance rather than
    coding ability.
    """
    # Strip a reasoning block first: a discarded draft inside <think> must not
    # be graded instead of the real answer.
    if "</think>" in text:
        text = text.split("</think>")[-1]
    blocks = [b.strip() for b in CODE_FENCE.findall(text) if b.strip()]
    if blocks:
        # Longest-block was wrong: models routinely answer with a compact
        # function plus a longer usage/test block, and picking by length
        # extracted the demo — the function was never defined and the hidden
        # tests died with NameError, scoring a correct model as a failure.
        # Prefer a block that actually defines the required symbol.
        if want:
            defining = [b for b in blocks if re.search(rf"\bdef\s+{re.escape(want)}\s*\(", b)]
            if defining:
                return max(defining, key=len)
        with_def = [b for b in blocks if re.search(r"^\s*def\s+\w+\s*\(", b, re.M)]
        if with_def:
            return max(with_def, key=len)
        return max(blocks, key=len)
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


def check_forbidden(code, forbidden):
    """Reject a solution that ignores a constraint the prompt stated.

    A benchmark that states a rule and does not enforce it measures nothing:
    `return sorted(a + b)` satisfied every assertion of the merge task while
    doing exactly what the prompt forbade. Comments and strings are stripped
    first so that a model *mentioning* sorted() in a docstring is not punished
    for it.
    """
    if not forbidden:
        return None
    stripped = re.sub(r"#.*", "", code)
    stripped = re.sub(r'"""[\s\S]*?"""|\'\'\'[\s\S]*?\'\'\'', "", stripped)
    stripped = re.sub(r'"[^"\n]*"|\'[^\'\n]*\'', "", stripped)
    for token in forbidden:
        if token == "sorted":
            if re.search(r"\bsorted\s*\(", stripped):
                return "used sorted(), which the prompt forbids"
        elif token in stripped:
            return f"used {token}, which the prompt forbids"
    return None


def run_candidate(code, tests, timeout=15, forbidden=None):
    """Execute the generated function against the tests. Returns (ok, detail)."""
    if not code.strip():
        return False, "no code found in reply"
    violation = check_forbidden(code, forbidden)
    if violation:
        return False, violation
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
    """One streamed request. Returns (text, ttft_s, wall_s, chunks, prompt_tokens)."""
    body = json.dumps({
        "model": model, "stream": True, "max_tokens": max_tokens,
        "temperature": 0, "messages": [{"role": "user", "content": prompt}],
    }).encode()
    req = urllib.request.Request(f"{base_url}/v1/chat/completions", data=body,
                                 headers={"Content-Type": "application/json"})
    started = time.monotonic()
    ttft = None
    parts = []
    prompt_tokens = None
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
            if chunk.get("usage"):
                prompt_tokens = chunk["usage"].get("prompt_tokens")
            choices = chunk.get("choices") or []
            if choices:
                piece = choices[0].get("delta", {}).get("content")
                if piece:
                    if ttft is None:
                        ttft = time.monotonic() - started
                    parts.append(piece)
    text = "".join(parts)
    return text, ttft, time.monotonic() - started, len(parts), prompt_tokens


def evaluate(base_url, model, label, max_tokens, keep_output=False, repeats=1,
             context_tokens=0, warmup=True):
    """Run every task against one model. Returns a report dict.

    `repeats` matters more than it looks: GenieX honours neither `max_tokens`
    nor `temperature`, so the llama.cpp lanes SAMPLE even at temperature=0 --
    five identical requests to the 2B produced five different answers, four
    passing and one failing the same task. A single run therefore measures one
    draw, not the model. (The QAIRT/NPU path is deterministic: four identical
    requests, one unique output, so repeats there only cost time.)
    """
    if warmup:
        # Without this the FIRST task of each model carries its load time and
        # the ranking partly ranks load order: ~34s of the 27B's 128.7s total
        # was loading, 26% of its score-deciding number.
        try:
            ask(base_url, model, "Reply with the single word: ready.", 16, timeout=1800)
        except Exception as e:  # noqa: BLE001 — a failed warmup is not fatal
            print(f"    (warmup failed: {type(e).__name__}; first task may "
                  f"include model load time)", flush=True)

    context = build_context(context_tokens)
    if context:
        print(f"\n  === {label}  [+{context_tokens} tokens of context] ===", flush=True)
    else:
        print(f"\n  === {label} ===", flush=True)
    results = []
    for task in TASKS:
      for attempt in range(repeats):
        suffix = f" [{attempt+1}/{repeats}]" if repeats > 1 else ""
        prompt = task["prompt"]
        if context:
            prompt = ("Here is context from a repository, for style reference only:\n\n"
                      f"{context}\n\n---\n\nNow, independently of the above:\n" + prompt)
        try:
            text, ttft, wall, chunks, ptok = ask(base_url, model, prompt, max_tokens)
        except Exception as e:  # noqa: BLE001 — one dead task must not end the sweep
            print(f"    {task['name']:15s}{suffix} ERROR {type(e).__name__}: {e}", flush=True)
            # A transport failure is not evidence about the model; excluding it
            # keeps a dropped connection from permanently lowering the score.
            results.append({"task": task["name"], "attempt": attempt, "passed": False,
                            "errored": True,
                            "detail": f"request failed: {e}", "wall_s": None,
                            "prompt_tokens": None})
            continue
        code = extract_code(text, want=task.get("function") or _want_from_prompt(task))
        ok, detail = run_candidate(code, task["tests"],
                                   forbidden=task.get("forbidden"))
        truncated = (not ok) and looks_truncated(text, chunks, code)
        if truncated:
            detail = f"CUT OFF at {chunks} tokens (server cap) - not graded as wrong"
        think_share = 0.0
        if "</think>" in text:
            think_share = 1 - len(text.split("</think>")[-1]) / len(text)
        verdict = "PASS" if ok else ("CUT " if truncated else "FAIL")
        pt = f"  ptok={ptok:5d}" if ptok else ""
        print(f"    {task['name']:15s}{suffix} {verdict}  "
              f"{wall:6.1f}s  ttft={ttft or 0:5.2f}s{pt}  out={chunks:5d}  "
              f"think={100*think_share:3.0f}%  {'' if ok else detail}", flush=True)
        entry = {"task": task["name"], "attempt": attempt,
                 "passed": ok, "truncated": truncated, "detail": detail,
                 "wall_s": round(wall, 2), "ttft_s": round(ttft, 3) if ttft else None,
                 "tokens": chunks, "prompt_tokens": ptok,
                 "thinking_char_share": round(think_share, 3)}
        if keep_output:
            entry["code"] = code
        results.append(entry)

    done = [r for r in results if r["wall_s"] is not None]
    passed = sum(1 for r in results if r["passed"])
    cut = sum(1 for r in results if r.get("truncated"))
    errored = sum(1 for r in results if r.get("errored"))
    attempts = len(TASKS) * repeats - errored
    wrong = attempts - passed - cut
    total_wall = sum(r["wall_s"] for r in done)
    walls = [r["wall_s"] for r in done]

    # How many INDEPENDENT observations are behind that score? On a
    # deterministic endpoint repeats return the identical answer, so counting
    # them inflates the apparent sample without adding information. Determinism
    # is detected, not assumed: identical output for every repeat of a task.
    per_task_outcomes = {}
    for r in results:
        per_task_outcomes.setdefault(r["task"], set()).add(r["passed"])
    deterministic = repeats > 1 and all(len(v) == 1 for v in per_task_outcomes.values())
    effective_n = len(TASKS) if deterministic else attempts

    extra = f", {cut} cut off" if cut else ""
    if errored:
        extra += f", {errored} EXCLUDED (transport errors)"
    unit = "attempts" if repeats > 1 else "tasks"
    print(f"    -> {passed}/{attempts} {unit} pass{extra}, {total_wall:.1f}s total",
          flush=True)
    if walls:
        print(f"       per attempt: median {statistics.median(walls):.1f}s, "
              f"min {min(walls):.1f}s, max {max(walls):.1f}s"
              + (f", stdev {statistics.stdev(walls):.1f}s" if len(walls) > 1 else ""),
              flush=True)
    if deterministic:
        print(f"       NOTE: every repeat agreed — this endpoint looks "
              f"deterministic, so the effective sample is {effective_n} tasks, "
              f"not {attempts} attempts.", flush=True)
    return {"label": label, "model": model, "base_url": base_url,
            "passed": passed, "wrong": wrong, "truncated": cut,
            "total": attempts, "repeats": repeats, "tasks": len(TASKS),
            "errored": errored,
            "deterministic": deterministic, "effective_n": effective_n,
            "context_tokens": context_tokens,
            "total_wall_s": round(total_wall, 2),
            "avg_wall_s": round(total_wall / len(done), 2) if done else None,
            "median_wall_s": round(statistics.median(walls), 2) if walls else None,
            "stdev_wall_s": round(statistics.stdev(walls), 2) if len(walls) > 1 else None,
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
    ap.add_argument("--context-tokens", type=int, default=0,
                    help="Prepend roughly N tokens of real repository source before "
                         "each task. The short prompts above are not what an agent "
                         "sends; prefill and the QAIRT bundles' 4096-token ceiling "
                         "only show up under a realistic context.")
    ap.add_argument("--task-set", choices=("classic", "novel", "all"), default="classic",
                    help="'classic' = textbook problems (recall-prone); 'novel' = "
                         "tasks built from formats invented in this repo, fully "
                         "specified in the prompt, which cannot have been memorised. "
                         "Compare the two: a model much better on classic than on "
                         "novel is recalling rather than reasoning.")
    ap.add_argument("--no-warmup", action="store_true",
                    help="Skip the warmup request. The first task then carries the "
                         "model load time, which the ranking will attribute to the "
                         "model's speed.")
    ap.add_argument("--output", default=None)
    args = ap.parse_args()

    global TASKS
    if args.task_set == "novel":
        TASKS = NOVEL_TASKS
    elif args.task_set == "all":
        TASKS = TASKS + NOVEL_TASKS

    from bench_cli import resolve_candidates, write_report
    from benchmark_openai_api import resolve_backend

    candidates = resolve_candidates(args, resolve_backend)

    reports = [evaluate(url, model, label, args.max_tokens, args.keep_output,
                        repeats=args.repeats, context_tokens=args.context_tokens,
                        warmup=not args.no_warmup)
               for label, url, model in candidates]


    if args.output:
        write_report(args.output, "bench_coding",
                     {"max_tokens": args.max_tokens, "repeats": args.repeats,
                      "context_tokens": args.context_tokens,
                      "warmup": not args.no_warmup, "task_set": args.task_set},
                     reports, candidates[0][1] if candidates else None,
                     ("bench_coding.py", "bench_provenance.py"))
        print(f"  Report written to {args.output}")

    # Ranking last: it only prints, and a print must never be able to
    # destroy a completed measurement.

    if len(reports) > 1:
        print("\n" + "=" * 78)
        print("  RANKING — by tasks passed, then by time to a finished answer")
        print("=" * 78)
        ranked = sorted(reports, key=lambda r: (-r["passed"], r["total_wall_s"]))
        print(f"  {'model':34s} {'pass [95% CI]':>22s} {'wrong':>5s} {'cut':>4s} "
              f"{'total':>9s} {'avg/task':>9s}")
        from bench_stats import format_score
        for r in ranked:
            n = r.get("effective_n") or r["total"]
            k = round(r["passed"] * n / r["total"]) if r["total"] else 0
            print(f"  {r['label'][:34]:34s} {format_score(k, n):>22s} "
                  f"{r.get('wrong', 0):5d} {r.get('truncated', 0):4d} "
                  f"{r['total_wall_s']:8.1f}s {r['avg_wall_s'] or 0:8.1f}s")
        if any(r.get("truncated") for r in ranked):
            print("\n  'cut' = the server stopped generation at its 2048-token cap "
                  "before the model\n  finished. Those tasks are UNMEASURED, not failed "
                  "- a reasoning model can\n  spend the whole budget inside <think>.")
        print()


if __name__ == "__main__":
    main()
