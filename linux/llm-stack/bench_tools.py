#!/usr/bin/env python3
"""Measure tool/function calling — the capability an agent actually lives on.

A model that writes flawless code but cannot emit a valid tool call is useless
inside a coding agent: it never gets to read a file, run a test, or apply a
patch. Neither the speed benchmarks nor the coding benchmark touch this.

What is graded, per case:
  * did it call a tool at all when it should have (and NOT when it should not)
  * did it pick the right tool from several plausible ones
  * are the arguments valid JSON
  * do the required arguments carry the right values

The "no tool needed" case is deliberate. Over-eager tool calling is a real
failure mode: a model that reaches for a tool on every turn burns a round trip
and, in an agent loop, can spin.

Usage:
    python3 bench_tools.py --backend geniex-npu
    python3 bench_tools.py --compare candidates.json --repeats 3
"""

import argparse
import json
import os
import sys
import time
import urllib.request

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

TOOLS = [
    {"type": "function", "function": {
        "name": "read_file",
        "description": "Read the full contents of one file.",
        "parameters": {"type": "object", "properties": {
            "path": {"type": "string", "description": "Path to the file"}},
            "required": ["path"]}}},
    {"type": "function", "function": {
        "name": "list_files",
        "description": "List the files in a directory.",
        "parameters": {"type": "object", "properties": {
            "directory": {"type": "string", "description": "Directory to list"}},
            "required": ["directory"]}}},
    {"type": "function", "function": {
        "name": "search_code",
        "description": "Search the repository for a string.",
        "parameters": {"type": "object", "properties": {
            "query": {"type": "string", "description": "Text to search for"},
            "case_sensitive": {"type": "boolean", "description": "Match case exactly"}},
            "required": ["query"]}}},
    {"type": "function", "function": {
        "name": "run_tests",
        "description": "Run the test suite and return the results.",
        "parameters": {"type": "object", "properties": {
            "path": {"type": "string", "description": "Optional path to a test file"}},
            "required": []}}},
]

# expect=None means: the model must NOT call a tool.
CASES = [
    {"name": "simple_read",
     "prompt": "Show me the contents of README.md.",
     "expect": {"name": "read_file", "args": {"path": "README.md"}}},
    {"name": "pick_from_several",
     "prompt": "Which files are in the directory src?",
     "expect": {"name": "list_files", "args": {"directory": "src"}}},
    {"name": "argument_extraction",
     "prompt": "Search the repository for the string merge_sorted.",
     "expect": {"name": "search_code", "args": {"query": "merge_sorted"}}},
    {"name": "optional_argument",
     "prompt": "Search for the exact string Foo, matching case exactly.",
     "expect": {"name": "search_code", "args": {"query": "Foo", "case_sensitive": True}}},
    {"name": "no_args_tool",
     "prompt": "Run the test suite.",
     "expect": {"name": "run_tests", "args": {}}},
    {"name": "no_tool_needed",
     "prompt": "What is 2 + 2? Answer directly, do not use any tool.",
     "expect": None},
]


def call(base_url, model, prompt, timeout=900, system=None):
    messages = ([{"role": "system", "content": system}] if system else []) + \
               [{"role": "user", "content": prompt}]
    body = json.dumps({
        "model": model, "temperature": 0, "max_tokens": 600,
        "tools": TOOLS, "tool_choice": "auto",
        "messages": messages,
    }).encode()
    req = urllib.request.Request(f"{base_url}/v1/chat/completions", data=body,
                                 headers={"Content-Type": "application/json"})
    started = time.monotonic()
    with urllib.request.urlopen(req, timeout=timeout) as r:
        data = json.load(r)
    wall = time.monotonic() - started
    choice = data["choices"][0]
    return choice.get("message", {}), choice.get("finish_reason"), wall


def grade(message, expect):
    """Returns (ok, detail). Kept strict on names and required values, lenient
    on formatting the model cannot be blamed for (a ./ prefix, a trailing /)."""
    calls = message.get("tool_calls") or []

    if expect is None:
        if calls:
            return False, f"called {calls[0]['function']['name']} when none was needed"
        return True, "correctly answered without a tool"

    if not calls:
        content = (message.get("content") or "")[:60]
        return False, f"no tool call; replied with text: {content!r}"
    if len(calls) > 1:
        return False, f"{len(calls)} tool calls, expected 1"

    fn = calls[0].get("function", {})
    if fn.get("name") != expect["name"]:
        return False, f"called {fn.get('name')!r}, expected {expect['name']!r}"

    raw = fn.get("arguments")
    if isinstance(raw, str):
        try:
            args = json.loads(raw) if raw.strip() else {}
        except json.JSONDecodeError as e:
            return False, f"arguments are not valid JSON: {e}"
    elif isinstance(raw, dict):
        args = raw
    else:
        args = {}

    for key, want in expect["args"].items():
        if key not in args:
            return False, f"missing argument {key!r}"
        got = args[key]
        if isinstance(want, str):
            if str(got).strip().strip("./").rstrip("/") != want.strip("./").rstrip("/"):
                return False, f"{key}={got!r}, expected {want!r}"
        elif got != want:
            return False, f"{key}={got!r}, expected {want!r}"
    return True, "correct tool and arguments"


def evaluate(base_url, model, label, repeats=1, system=None):
    tag = "  [+system prompt]" if system else ""
    print(f"\n  === {label}{tag} ===", flush=True)
    results = []
    for case in CASES:
        for attempt in range(repeats):
            suffix = f" [{attempt+1}/{repeats}]" if repeats > 1 else ""
            try:
                message, finish, wall = call(base_url, model, case["prompt"],
                                             system=system)
            except Exception as e:  # noqa: BLE001
                print(f"    {case['name']:20s}{suffix} ERROR {type(e).__name__}", flush=True)
                results.append({"case": case["name"], "passed": False,
                                "detail": f"request failed: {e}", "wall_s": None})
                continue
            ok, detail = grade(message, case["expect"])
            print(f"    {case['name']:20s}{suffix} {'PASS' if ok else 'FAIL'}  "
                  f"{wall:6.2f}s  finish={finish or '?':10s} {'' if ok else detail[:70]}",
                  flush=True)
            results.append({"case": case["name"], "attempt": attempt, "passed": ok,
                            "detail": detail, "wall_s": round(wall, 2),
                            "finish_reason": finish})
    done = [r for r in results if r["wall_s"] is not None]
    passed = sum(1 for r in results if r["passed"])
    total = len(CASES) * repeats
    wall = sum(r["wall_s"] for r in done)
    print(f"    -> {passed}/{total} tool calls correct, {wall:.1f}s total", flush=True)
    return {"label": label, "model": model, "passed": passed, "total": total,
            "total_wall_s": round(wall, 2),
            "avg_wall_s": round(wall / len(done), 2) if done else None,
            "results": results}


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--backend", default=None)
    ap.add_argument("--base-url", default=None)
    ap.add_argument("--model", default=None)
    ap.add_argument("--label", default=None)
    ap.add_argument("--repeats", type=int, default=1)
    ap.add_argument("--system", default=None,
                    help="Path to a system-prompt file prepended to every case. "
                         "Agents that cannot override a runtime's built-in tool "
                         "DESCRIPTIONS (opencode among them) can still disambiguate "
                         "the tools this way — measure whether it actually helps "
                         "before shipping it.")
    ap.add_argument("--compare", default=None)
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

    system = None
    if args.system:
        with open(args.system) as f:
            system = f.read()
    reports = [evaluate(url, model, label, args.repeats, system)
               for label, url, model in candidates]

    if len(reports) > 1:
        print("\n" + "=" * 70)
        print("  RANKING — correct tool calls, then time")
        print("=" * 70)
        for r in sorted(reports, key=lambda x: (-x["passed"], x["total_wall_s"])):
            print(f"  {r['label'][:44]:44s} {r['passed']}/{r['total']:<4d} {r['total_wall_s']:8.1f}s")
        print()

    if args.output:
        with open(args.output, "w") as f:
            json.dump(reports, f, indent=2)
        print(f"  Report written to {args.output}")


if __name__ == "__main__":
    main()
