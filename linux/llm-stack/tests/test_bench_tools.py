"""Tests for the tool-calling grader.

Same reasoning as the coding grader: a wrong grader makes every number it
produces worthless. These cases are the ones that would silently distort a
ranking -- arguments arriving as a JSON string vs a dict, a model that answers
in prose instead of calling, and a model that calls a tool when it should not.
"""

import os
import sys

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from bench_tools import CASES, TOOLS, grade  # noqa: E402

EXPECT_READ = {"name": "read_file", "args": {"path": "README.md"}}


def msg(name, arguments, content=None):
    """Build a message the way an OpenAI-compatible server returns one."""
    return {"content": content,
            "tool_calls": [{"id": "call_1", "type": "function",
                            "function": {"name": name, "arguments": arguments}}]}


class TestHappyPath:
    def test_correct_call_with_json_string_arguments(self):
        ok, _ = grade(msg("read_file", '{"path": "README.md"}'), EXPECT_READ)
        assert ok

    def test_arguments_may_arrive_as_a_dict(self):
        # Not every server stringifies them; grading must not depend on that.
        ok, _ = grade(msg("read_file", {"path": "README.md"}), EXPECT_READ)
        assert ok

    def test_tolerates_a_leading_dot_slash(self):
        # "./README.md" is the same file; blaming the model for it would
        # measure formatting, not capability.
        ok, _ = grade(msg("read_file", '{"path": "./README.md"}'), EXPECT_READ)
        assert ok

    def test_tool_with_no_required_arguments(self):
        ok, _ = grade(msg("run_tests", "{}"), {"name": "run_tests", "args": {}})
        assert ok


class TestFailures:
    def test_wrong_tool_is_caught(self):
        ok, detail = grade(msg("list_files", '{"directory": "."}'), EXPECT_READ)
        assert not ok and "expected 'read_file'" in detail

    def test_missing_required_argument(self):
        ok, detail = grade(msg("read_file", "{}"), EXPECT_READ)
        assert not ok and "missing argument" in detail

    def test_wrong_argument_value(self):
        ok, detail = grade(msg("read_file", '{"path": "LICENSE"}'), EXPECT_READ)
        assert not ok and "expected" in detail

    def test_invalid_json_arguments(self):
        ok, detail = grade(msg("read_file", '{"path": '), EXPECT_READ)
        assert not ok and "not valid JSON" in detail

    def test_prose_instead_of_a_call(self):
        # The classic failure: the model describes the call instead of making it.
        ok, detail = grade({"content": "I would call read_file with README.md",
                            "tool_calls": []}, EXPECT_READ)
        assert not ok and "no tool call" in detail

    def test_several_calls_when_one_was_expected(self):
        m = msg("read_file", '{"path": "README.md"}')
        m["tool_calls"].append(m["tool_calls"][0])
        ok, detail = grade(m, EXPECT_READ)
        assert not ok and "2 tool calls" in detail

    def test_boolean_argument_must_match_exactly(self):
        expect = {"name": "search_code", "args": {"query": "Foo", "case_sensitive": True}}
        ok, _ = grade(msg("search_code", '{"query": "Foo", "case_sensitive": false}'), expect)
        assert not ok


class TestNoToolExpected:
    def test_answering_directly_is_correct(self):
        ok, _ = grade({"content": "4", "tool_calls": []}, None)
        assert ok

    def test_calling_a_tool_anyway_is_wrong(self):
        # Over-eager tool use burns a round trip and can spin an agent loop.
        ok, detail = grade(msg("run_tests", "{}"), None)
        assert not ok and "when none was needed" in detail


class TestSuiteShape:
    def test_every_expected_tool_exists_in_the_advertised_set(self):
        names = {t["function"]["name"] for t in TOOLS}
        for case in CASES:
            if case["expect"]:
                assert case["expect"]["name"] in names, case["name"]

    def test_the_suite_includes_a_negative_case(self):
        assert any(c["expect"] is None for c in CASES), \
            "without a 'no tool needed' case, over-eager calling goes unmeasured"
