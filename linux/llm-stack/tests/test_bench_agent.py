"""Tests for bench_agent — the end-to-end agent harness.

The harness's own correctness matters more here than anywhere else in the
suite: with no strong control model reachable, a row of failures is only
readable if the fixtures and the verification are known-good.
"""

import json
import os
import shutil
import subprocess
import sys

import pytest

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))

import bench_agent as ba


class TestFixtures:
    def test_every_task_has_a_reference_solution(self):
        # Without one, --self-test silently skips the task and reports OK for a
        # fixture it never actually solved.
        for task in ba.TASKS:
            assert task["name"] in ba.REFERENCE, f"{task['name']} has no reference"

    def test_reference_only_touches_files_in_the_fixture(self):
        for name, files in ba.REFERENCE.items():
            task = next(t for t in ba.TASKS if t["name"] == name)
            for fname in files:
                assert fname in task["files"], f"{name}: {fname} is not in the fixture"

    def test_task_names_are_unique(self):
        names = [t["name"] for t in ba.TASKS]
        assert len(names) == len(set(names))

    def test_prompt_never_contains_the_solution(self):
        # A prompt that names the fix measures transcription, not engineering.
        for task in ba.TASKS:
            for content in ba.REFERENCE.get(task["name"], {}).values():
                body = [ln.strip() for ln in content.splitlines()
                        if ln.strip() and not ln.strip().startswith(('"', "#"))]
                for line in body:
                    if len(line) > 25:
                        assert line not in task["prompt"], \
                            f"{task['name']} leaks its solution"


class TestWorkspace:
    def test_workspace_gets_the_fixture_files_and_a_git_repo(self, tmp_path):
        task = ba.TASKS[0]
        ws = ba.make_workspace(task)
        try:
            for name in task["files"]:
                assert os.path.exists(os.path.join(ws, name))
            assert os.path.isdir(os.path.join(ws, ".git"))
        finally:
            shutil.rmtree(ws, ignore_errors=True)

    def test_workspaces_are_independent(self):
        task = ba.TASKS[0]
        a, b = ba.make_workspace(task), ba.make_workspace(task)
        try:
            assert a != b
            with open(os.path.join(a, list(task["files"])[0]), "w") as f:
                f.write("# clobbered\n")
            other = open(os.path.join(b, list(task["files"])[0])).read()
            assert "clobbered" not in other
        finally:
            shutil.rmtree(a, ignore_errors=True)
            shutil.rmtree(b, ignore_errors=True)


class TestVerification:
    """The load-bearing part: verification decides every reported result."""

    @pytest.mark.parametrize("task", ba.TASKS, ids=lambda t: t["name"])
    def test_unsolved_fixture_fails(self, task):
        ws = ba.make_workspace(task)
        try:
            passed, _ = ba.verify(ws, task)
            assert not passed, "fixture passes untouched -- it measures nothing"
        finally:
            shutil.rmtree(ws, ignore_errors=True)

    @pytest.mark.parametrize("task", ba.TASKS, ids=lambda t: t["name"])
    def test_reference_solution_passes(self, task):
        ws = ba.make_workspace(task)
        try:
            for name, content in ba.REFERENCE[task["name"]].items():
                with open(os.path.join(ws, name), "w") as f:
                    f.write(content)
            shutil.rmtree(os.path.join(ws, "__pycache__"), ignore_errors=True)
            passed, detail = ba.verify(ws, task)
            assert passed, f"correct solution rejected: {detail}"
        finally:
            shutil.rmtree(ws, ignore_errors=True)

    def test_rename_task_rejects_an_alias(self):
        # Keeping the old name as an alias satisfies the tests but is not the
        # rename that was asked for.
        task = next(t for t in ba.TASKS if t["name"] == "multi_file_rename")
        ws = ba.make_workspace(task)
        try:
            for name, content in ba.REFERENCE[task["name"]].items():
                with open(os.path.join(ws, name), "w") as f:
                    f.write(content)
            with open(os.path.join(ws, "client.py"), "a") as f:
                f.write("\n\nfetch_data = format_record\n")
            shutil.rmtree(os.path.join(ws, "__pycache__"), ignore_errors=True)
            passed, _ = ba.verify(ws, task)
            assert not passed, "an alias was accepted as a rename"
        finally:
            shutil.rmtree(ws, ignore_errors=True)

    def test_clamp_task_rejects_a_vacuous_test(self):
        # The verification runs its own assertions, so writing `assert True` in
        # test_utils.py must not earn a pass.
        task = next(t for t in ba.TASKS if t["name"] == "add_function_and_test")
        ws = ba.make_workspace(task)
        try:
            with open(os.path.join(ws, "utils.py"), "a") as f:
                f.write("\n\ndef clamp(value, low, high):\n    return value\n")
            with open(os.path.join(ws, "test_utils.py"), "a") as f:
                f.write("\n\ndef test_clamp():\n    assert True\n")
            shutil.rmtree(os.path.join(ws, "__pycache__"), ignore_errors=True)
            passed, _ = ba.verify(ws, task)
            assert not passed, "a clamp that does not clamp was accepted"
        finally:
            shutil.rmtree(ws, ignore_errors=True)

    def test_missing_command_is_a_failure_not_a_crash(self, tmp_path):
        bogus = {"name": "x", "verify": ["definitely-not-a-real-binary-xyz"]}
        passed, detail = ba.verify(str(tmp_path), bogus)
        assert not passed
        assert "could not run" in detail


class TestErrorClassification:
    def test_context_overflow_is_not_a_capability_result(self):
        events = [{"type": "error", "error": {"data": {
            "message": 'Value: {"error":"SDKError(Input prompt too long)"}'}}}]
        assert ba.agent_errors(events)[0][0] == "CONTEXT"

    def test_plain_errors_keep_their_message(self):
        events = [{"type": "error", "error": {"data": {"message": "kaboom"}}}]
        kind, detail = ba.agent_errors(events)[0]
        assert kind == "ERROR" and "kaboom" in detail

    def test_no_errors_is_empty(self):
        assert ba.agent_errors([{"type": "step_start"}]) == []

    def test_non_error_events_are_never_classified(self):
        # A tool result mentioning "context" must not read as a context overflow.
        events = [{"type": "tool", "error": {"message": "prompt too long"}}]
        assert ba.agent_errors(events) == []


class TestEventSummary:
    def test_unrecognised_events_are_counted_not_dropped(self):
        # A zero must mean "none happened", never "we could not tell".
        c = ba.summarise_events([{"type": "wat"}, {"type": "tool_call"}])
        assert c["unrecognised_events"] == 1
        assert c["tool_events"] == 1
        assert c["total_events"] == 2

    def test_counts_add_up(self):
        events = [{"type": "tool"}, {"type": "message"}, {"type": "zzz"}]
        c = ba.summarise_events(events)
        assert (c["tool_events"] + c["message_events"]
                + c["unrecognised_events"]) == c["total_events"]


class TestCli:
    def test_self_test_passes(self):
        # The gate that makes every other row in a report readable.
        r = subprocess.run([sys.executable, "bench_agent.py", "--self-test"],
                           cwd=os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."),
                           capture_output=True, text=True, timeout=300)
        assert r.returncode == 0, r.stdout + r.stderr
        assert "Harness validated" in r.stdout

    def test_list_needs_no_server(self):
        r = subprocess.run([sys.executable, "bench_agent.py", "--list"],
                           cwd=os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."),
                           capture_output=True, text=True, timeout=60)
        assert r.returncode == 0
        for task in ba.TASKS:
            assert task["name"] in r.stdout


class TestScoreExcludesBlockedRuns:
    """A model that never received the task did not fail it.

    This is the difference between "0% — it cannot code" and "not measurable on
    this lane", and the whole point of the run that produced it.
    """

    def test_stats_layer_renders_nothing_measured_as_na(self):
        import bench_stats as bs
        assert bs.format_score(0, 0) == "n/a"
        lo, hi = bs.wilson_interval(0, 0)
        assert (lo, hi) == (0.0, 1.0), "no data must mean no information"

    def test_report_denominator_omits_context_blocked_tasks(self, tmp_path):
        out = tmp_path / "r.json"
        r = subprocess.run(
            [sys.executable, "bench_agent.py", "--model", "nonexistent/model",
             "--task", "fix_failing_test", "--timeout", "45",
             "--output", str(out)],
            cwd=os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."),
            capture_output=True, text=True, timeout=180)
        if not out.exists():
            pytest.skip("opencode unavailable")
        cand = json.load(open(out))["reports"][0]
        assert cand["total"] == cand["tasks_run"] - cand["blocked_on_context"]


class TestTimeoutKeepsEvidence:
    """A timed-out run must still report what it managed to do.

    Reporting "0 tool calls" for an agent that made twenty and merely ran long
    is worse than reporting nothing: it reads as "it never started".
    """

    def test_partial_output_survives_a_timeout(self, monkeypatch, tmp_path):
        partial = ('{"type":"step_start"}\n'
                   '{"type":"tool","name":"read"}\n'
                   '{"type":"tool","name":"edit"}\n')

        def fake_run(*a, **kw):
            raise subprocess.TimeoutExpired(cmd="opencode", timeout=1,
                                            output=partial, stderr="")

        monkeypatch.setattr(ba.subprocess, "run", fake_run)
        events, _, timed_out, _ = ba.run_agent(str(tmp_path), "m", "p", 1)
        assert timed_out
        assert ba.summarise_events(events)["tool_events"] == 2

    def test_bytes_streams_are_decoded(self, monkeypatch, tmp_path):
        def fake_run(*a, **kw):
            raise subprocess.TimeoutExpired(cmd="opencode", timeout=1,
                                            output=b'{"type":"tool"}\n',
                                            stderr=b"boom")

        monkeypatch.setattr(ba.subprocess, "run", fake_run)
        events, _, timed_out, stderr = ba.run_agent(str(tmp_path), "m", "p", 1)
        assert timed_out and stderr == "boom"
        assert ba.summarise_events(events)["tool_events"] == 1

    def test_no_output_at_all_is_still_safe(self, monkeypatch, tmp_path):
        def fake_run(*a, **kw):
            raise subprocess.TimeoutExpired(cmd="opencode", timeout=1)

        monkeypatch.setattr(ba.subprocess, "run", fake_run)
        events, _, timed_out, stderr = ba.run_agent(str(tmp_path), "m", "p", 1)
        assert timed_out and events == [] and stderr == ""
