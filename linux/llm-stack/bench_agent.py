#!/usr/bin/env python3
"""End-to-end: drive the real agent against a real repository (P3.1).

Everything else in this suite measures an ENDPOINT. You run an AGENT. Nothing
connected the two, and the proxies have already disagreed twice in one session:
the coding winner was the tool-calling loser until a system prompt fixed it, and
a "model family" explanation survived two rounds of documentation before a
non-Qwen model refuted it.

So: give opencode a scratch git repository and a task with a *verifiable*
outcome, let it work, then check the repository — not the transcript. Success is
"the tests pass afterwards", which no amount of confident prose can fake.

Each task starts from a fresh copy of its fixture, so a run cannot be helped by
the previous one, and the verification command is run in that copy.

    python3 bench_agent.py --model geniex/qualcomm/Qwen3-4B-Instruct-2507:W4A16
    python3 bench_agent.py --list
"""

import argparse
import json
import os
import shutil
import subprocess
import sys
import tempfile
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

OPENCODE = os.path.expanduser("~/.opencode/bin/opencode")

# Tasks are deliberately small. This measures whether the LOOP works — read a
# file, decide, edit, stop — not whether the model is a strong engineer. A task
# a competent junior finishes in two minutes is the right size: if the loop is
# broken, it fails here too, and if the loop works, a harder task only measures
# the model again, which the other benchmarks already do.
TASKS = [
    {
        "name": "fix_failing_test",
        "prompt": ("The test suite in this repository fails. Run it, find the bug "
                   "in the source, fix it, and make the tests pass. Do not edit "
                   "the tests."),
        "files": {
            "calc.py": (
                "def average(values):\n"
                '    """Return the arithmetic mean, or 0.0 for an empty list."""\n'
                "    return sum(values) / len(values)\n"
            ),
            "test_calc.py": (
                "from calc import average\n\n\n"
                "def test_average():\n"
                "    assert average([1, 2, 3]) == 2\n\n\n"
                "def test_empty_returns_zero():\n"
                "    assert average([]) == 0.0\n"
            ),
        },
        # The bug: average([]) raises ZeroDivisionError. The docstring already
        # states the intended behaviour, so the task is unambiguous.
        "verify": ["python3", "-m", "pytest", "-q", "test_calc.py"],
    },
    {
        "name": "add_function_and_test",
        "prompt": ("Add a function `clamp(value, low, high)` to utils.py that "
                   "returns value limited to the range [low, high], and raises "
                   "ValueError if low > high. Then add tests for it in "
                   "test_utils.py covering both ends of the range and the error "
                   "case. Make sure the whole test suite passes."),
        "files": {
            "utils.py": (
                "def slugify(text):\n"
                '    """Lowercase and hyphenate."""\n'
                "    return text.strip().lower().replace(' ', '-')\n"
            ),
            "test_utils.py": (
                "from utils import slugify\n\n\n"
                "def test_slugify():\n"
                "    assert slugify('  Hello World ') == 'hello-world'\n"
            ),
        },
        # Verified by a check the agent never sees, so it cannot be satisfied by
        # writing a vacuous test.
        "verify": ["python3", "-c", (
            "import subprocess,sys;"
            "from utils import clamp;"
            "assert clamp(5,1,10)==5 and clamp(0,1,10)==1 and clamp(99,1,10)==10;"
            "\nexec('try:\\n clamp(1,10,1)\\n raise SystemExit(\"no ValueError\")\\n"
            "except ValueError:\\n pass')\n"
            "r=subprocess.run([sys.executable,'-m','pytest','-q'],capture_output=True);"
            "sys.exit(r.returncode)")],
    },
    {
        "name": "multi_file_rename",
        "prompt": ("The function `fetch_data` in client.py is misnamed — it does "
                   "not fetch anything, it formats a record. Rename it to "
                   "`format_record` everywhere it is used, including in the "
                   "tests, and make sure the tests still pass."),
        "files": {
            "client.py": (
                "def fetch_data(record):\n"
                "    return f\"{record['id']}: {record['name']}\"\n"
            ),
            "report.py": (
                "from client import fetch_data\n\n\n"
                "def build(records):\n"
                "    return [fetch_data(r) for r in records]\n"
            ),
            "test_report.py": (
                "from report import build\n"
                "from client import fetch_data\n\n\n"
                "def test_build():\n"
                "    assert build([{'id': 1, 'name': 'a'}]) == ['1: a']\n\n\n"
                "def test_direct():\n"
                "    assert fetch_data({'id': 2, 'name': 'b'}) == '2: b'\n"
            ),
        },
        # Requires touching three files. Verified on the NEW name, and the old
        # one must be gone: renaming in one place and aliasing in another is not
        # a rename.
        "verify": ["python3", "-c", (
            "import pathlib,subprocess,sys;"
            "from client import format_record;"
            "assert format_record({'id':3,'name':'c'})=='3: c';"
            "src=' '.join(p.read_text() for p in pathlib.Path('.').glob('*.py'));"
            "sys.exit(1) if 'fetch_data' in src else None;"
            "r=subprocess.run([sys.executable,'-m','pytest','-q'],capture_output=True);"
            "sys.exit(r.returncode)")],
    },
]


# What a correct agent would leave behind. These exist so the harness can prove
# ITSELF before it judges anything: with no strong control model reachable, a
# row of failures is otherwise unreadable -- broken fixture or weak model, no
# way to tell. --self-test applies these by hand and asserts the verification
# is red before and green after. Never shown to a model.
REFERENCE = {
    "fix_failing_test": {
        "calc.py": (
            "def average(values):\n"
            '    """Return the arithmetic mean, or 0.0 for an empty list."""\n'
            "    if not values:\n"
            "        return 0.0\n"
            "    return sum(values) / len(values)\n"
        ),
    },
    "add_function_and_test": {
        "utils.py": (
            "def slugify(text):\n"
            '    """Lowercase and hyphenate."""\n'
            "    return text.strip().lower().replace(' ', '-')\n\n\n"
            "def clamp(value, low, high):\n"
            "    if low > high:\n"
            "        raise ValueError('low > high')\n"
            "    return max(low, min(value, high))\n"
        ),
        "test_utils.py": (
            "import pytest\n"
            "from utils import slugify, clamp\n\n\n"
            "def test_slugify():\n"
            "    assert slugify('  Hello World ') == 'hello-world'\n\n\n"
            "def test_clamp():\n"
            "    assert clamp(5, 1, 10) == 5\n"
            "    assert clamp(0, 1, 10) == 1\n"
            "    assert clamp(99, 1, 10) == 10\n\n\n"
            "def test_clamp_bad_range():\n"
            "    with pytest.raises(ValueError):\n"
            "        clamp(1, 10, 1)\n"
        ),
    },
    "multi_file_rename": {
        "client.py": (
            "def format_record(record):\n"
            "    return f\"{record['id']}: {record['name']}\"\n"
        ),
        "report.py": (
            "from client import format_record\n\n\n"
            "def build(records):\n"
            "    return [format_record(r) for r in records]\n"
        ),
        "test_report.py": (
            "from report import build\n"
            "from client import format_record\n\n\n"
            "def test_build():\n"
            "    assert build([{'id': 1, 'name': 'a'}]) == ['1: a']\n\n\n"
            "def test_direct():\n"
            "    assert format_record({'id': 2, 'name': 'b'}) == '2: b'\n"
        ),
    },
}


def self_test():
    """Prove the fixtures and their verification, with no model involved.

    A task is only usable if it starts FAILING and its reference solution makes
    it PASS. A fixture that already passes measures nothing; one that fails even
    when solved correctly would blame every model for the harness's own bug.
    """
    ok = True
    for task in TASKS:
        ws = make_workspace(task)
        try:
            before, _ = verify(ws, task)
            for name, content in REFERENCE.get(task["name"], {}).items():
                with open(os.path.join(ws, name), "w") as f:
                    f.write(content)
            # Stale bytecode from the pre-fix import would mask the change.
            shutil.rmtree(os.path.join(ws, "__pycache__"), ignore_errors=True)
            after, detail = verify(ws, task)
            good = (not before) and after
            ok = ok and good
            print(f"    {task['name']:24s} {'OK' if good else 'BROKEN':8s} "
                  f"unsolved={'pass' if before else 'fail'} "
                  f"solved={'pass' if after else 'fail'}"
                  f"{'' if good else '  ' + detail[:80].replace(chr(10), ' ')}")
        finally:
            shutil.rmtree(ws, ignore_errors=True)
    print(f"\n  Harness {'validated' if ok else 'IS BROKEN -- fix before trusting any result'}")
    return ok


def make_workspace(task):
    """A fresh scratch repo. Fresh per run so nothing carries over."""
    path = tempfile.mkdtemp(prefix=f"agentbench-{task['name']}-")
    for name, content in task["files"].items():
        with open(os.path.join(path, name), "w") as f:
            f.write(content)
    subprocess.run(["git", "init", "-q"], cwd=path, check=False)
    subprocess.run(["git", "add", "-A"], cwd=path, check=False)
    subprocess.run(["git", "-c", "user.email=b@b", "-c", "user.name=b",
                    "commit", "-qm", "fixture"], cwd=path, check=False)
    return path


def run_agent(workspace, model, prompt, timeout):
    """One opencode session. Returns (events, wall_s, timed_out, stderr)."""
    cmd = [OPENCODE, "run", "--format", "json", "--dir", workspace]
    if model:
        cmd += ["-m", model]
    cmd += [prompt]
    def parse(stdout):
        out = []
        for line in (stdout or "").splitlines():
            line = line.strip()
            if line.startswith("{"):
                try:
                    out.append(json.loads(line))
                except json.JSONDecodeError:
                    continue
        return out

    def text(stream):
        if stream is None:
            return ""
        return stream.decode("utf-8", "replace") if isinstance(stream, bytes) else stream

    started = time.monotonic()
    try:
        proc = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout,
                              cwd=workspace)
    except subprocess.TimeoutExpired as e:
        # Keep what the run produced before the deadline. Discarding it would
        # report "0 tool calls" for an agent that made twenty and simply ran
        # long -- the difference between "it never started" and "it did not
        # finish", which is the whole reason to record a timeout separately.
        return (parse(text(e.stdout)), time.monotonic() - started, True,
                text(e.stderr)[-400:])
    return (parse(proc.stdout), time.monotonic() - started, False,
            (proc.stderr or "")[-400:])


def agent_errors(events):
    """Errors the agent itself hit, classified.

    "The tests still fail" and "the prompt never fit in the context" are both a
    FAIL by the only honest measure — the repository did not change — but they
    are not the same finding, and a benchmark that prints one number for both
    would have hidden the single most important result of this run.
    """
    out = []
    for e in events:
        if str(e.get("type", "")).lower() != "error":
            continue
        msg = json.dumps(e.get("error", {}))
        if "too long" in msg.lower() or "context" in msg.lower():
            out.append(("CONTEXT", "prompt exceeds the model's context"))
        elif "tool" in msg.lower():
            out.append(("TOOLS", "tool-call handling failed"))
        else:
            out.append(("ERROR", msg[:160]))
    return out


def summarise_events(events):
    """Turn and tool counts from the event stream, defensively.

    The event schema is opencode's, not ours, so anything unrecognised is
    counted as unknown rather than silently dropped — a zero here must mean
    "none happened", not "we could not tell".
    """
    tools, assistant_turns, unknown = 0, 0, 0
    for e in events:
        kind = e.get("type") or e.get("event") or ""
        if "tool" in str(kind).lower():
            tools += 1
        elif "message" in str(kind).lower() or "text" in str(kind).lower():
            assistant_turns += 1
        else:
            unknown += 1
    return {"tool_events": tools, "message_events": assistant_turns,
            "unrecognised_events": unknown, "total_events": len(events)}


def verify(workspace, task):
    """Did the repository actually change as required?

    Checked by running a command in the workspace, never by reading the
    transcript: an agent that says it fixed the bug and did not is the failure
    this whole benchmark exists to catch.
    """
    try:
        proc = subprocess.run(task["verify"], cwd=workspace, capture_output=True,
                              text=True, timeout=120)
        return proc.returncode == 0, (proc.stdout + proc.stderr)[-300:]
    except subprocess.TimeoutExpired:
        return False, "verification timed out"
    except Exception as e:  # noqa: BLE001
        return False, f"verification could not run: {e}"


def run_task(task, model, timeout, keep):
    workspace = make_workspace(task)
    try:
        events, wall, timed_out, stderr = run_agent(workspace, model,
                                                    task["prompt"], timeout)
        passed, detail = (False, "agent timed out") if timed_out else verify(workspace, task)
        counts = summarise_events(events)
        errors = agent_errors(events)
        if passed:
            status = "PASS"
        elif timed_out:
            status = "TIMEOUT"
        elif errors:
            # The first error is the one that derailed the run; later ones are
            # usually its echo.
            status = errors[0][0]
            detail = errors[0][1]
        else:
            status = "FAIL"
        print(f"    {task['name']:24s} {status:8s} {wall:7.1f}s  "
              f"events={counts['total_events']:4d} tools={counts['tool_events']:3d}  "
              f"{'' if passed else detail[:60].replace(chr(10), ' ')}", flush=True)
        return {"task": task["name"], "passed": passed, "timed_out": timed_out,
                "status": status, "wall_s": round(wall, 2), "detail": detail[:400],
                "errors": [e[0] for e in errors], "stderr": stderr[:200], **counts}
    finally:
        if keep:
            print(f"      workspace kept at {workspace}", flush=True)
        else:
            shutil.rmtree(workspace, ignore_errors=True)


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--model", default=None,
                    help="opencode model id, e.g. geniex/qualcomm/Qwen3-4B-Instruct-2507:W4A16")
    ap.add_argument("--label", default=None)
    ap.add_argument("--timeout", type=int, default=900,
                    help="Per-task ceiling in seconds (default 900)")
    ap.add_argument("--task", default=None, help="Run only this task")
    ap.add_argument("--keep", action="store_true",
                    help="Keep the scratch workspaces for inspection")
    ap.add_argument("--list", action="store_true")
    ap.add_argument("--self-test", action="store_true",
                    help="Verify the fixtures against known-good solutions; no model")
    ap.add_argument("--output", default=None)
    args = ap.parse_args()

    if args.list:
        for t in TASKS:
            print(f"  {t['name']:24s} {t['prompt'][:70]}...")
        return

    if args.self_test:
        raise SystemExit(0 if self_test() else 1)

    if not os.path.exists(OPENCODE):
        raise SystemExit(f"opencode not found at {OPENCODE}")

    tasks = [t for t in TASKS if not args.task or t["name"] == args.task]
    label = args.label or args.model or "default model"
    print(f"\n  === {label} ===", flush=True)
    results = [run_task(t, args.model, args.timeout, args.keep) for t in tasks]

    passed = sum(1 for r in results if r["passed"])
    wall = sum(r["wall_s"] for r in results)
    blocked = [r for r in results if r["status"] == "CONTEXT"]
    # A model that never received the task did not fail it. Blocked runs are
    # excluded from the denominator so the score cannot be read as a capability
    # verdict; with everything blocked this reports 0/0, which the stats layer
    # already renders as "n/a" rather than 0%.
    attempted = len(results) - len(blocked)
    print(f"    -> {passed}/{attempted} attempted tasks completed, {wall:.1f}s total",
          flush=True)
    if blocked:
        print(f"       {len(blocked)} never reached the model: the prompt did not fit "
              f"the context. Not a capability result -- excluded from the score.",
              flush=True)

    if args.output:
        from bench_cli import write_report
        write_report(args.output, "bench_agent",
                     {"model": args.model, "timeout": args.timeout},
                     [{"label": label, "model": args.model, "passed": passed,
                       "total": attempted, "tasks_run": len(results),
                       "blocked_on_context": len(blocked),
                       "total_wall_s": round(wall, 2), "results": results}],
                     None, ("bench_agent.py", "bench_provenance.py"))
        print(f"  Report written to {args.output}")


if __name__ == "__main__":
    main()
