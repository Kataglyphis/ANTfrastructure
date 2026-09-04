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

    def test_case_names_are_unique(self):
        from bench_tools import MULTI_CASES
        names = [c["name"] for c in CASES] + [c["name"] for c in MULTI_CASES]
        assert len(names) == len(set(names))

    def test_the_suite_is_large_enough_to_prove_a_regression(self):
        # The number that motivated the expansion: at 8 cases a real 8/8 -> 6/8
        # degradation was NOT provable. 27 brings the smallest provable drop to
        # roughly 100% -> 75%, which is the point of having a tripwire at all.
        from bench_stats import smallest_separable_rate
        from bench_tools import MULTI_CASES
        n = len(CASES) + len(MULTI_CASES)
        assert n >= 27, f"only {n} cases — too few to prove a 25-point drop"
        assert smallest_separable_rate(n) >= 0.70

    def test_several_tools_are_near_neighbours(self):
        # Selection is only tested if some tools are genuinely confusable;
        # with all-distinct tools a model can succeed by elimination.
        names = {t["function"]["name"] for t in TOOLS}
        for pair in (("write_file", "apply_patch"), ("git_status", "git_diff"),
                     ("read_file", "list_files")):
            assert set(pair) <= names, pair

    def test_restraint_is_measured_more_than_once(self):
        # One negative case out of 27 would let a tool-happy model score well.
        assert sum(1 for c in CASES if c["expect"] is None) >= 3


class TestMultiCaseShape:
    def test_every_multi_case_has_a_known_grader(self):
        from bench_tools import MULTI_CASES
        for case in MULTI_CASES:
            assert case["kind"] in ("use_result", "recover"), case["name"]

    def test_use_result_cases_state_what_must_appear(self):
        from bench_tools import MULTI_CASES
        for case in MULTI_CASES:
            if case["kind"] == "use_result":
                assert case.get("must_contain"), case["name"]
                # The token must actually be present in the tool result, or the
                # case is unpassable and every model looks broken.
                result = case["history"][-1]["content"]
                for token in case["must_contain"]:
                    assert token in result, f"{case['name']}: {token!r} not in the tool result"

    def test_recover_cases_feed_back_an_actual_error(self):
        from bench_tools import MULTI_CASES
        for case in MULTI_CASES:
            if case["kind"] == "recover":
                assert "error" in case["history"][-1]["content"].lower(), case["name"]

    def test_histories_are_well_formed(self):
        from bench_tools import MULTI_CASES
        for case in MULTI_CASES:
            roles = [m["role"] for m in case["history"]]
            assert roles == ["user", "assistant", "tool"], case["name"]
            call_id = case["history"][1]["tool_calls"][0]["id"]
            assert case["history"][2]["tool_call_id"] == call_id, case["name"]

    def test_both_kinds_are_represented(self):
        from bench_tools import MULTI_CASES
        kinds = {c["kind"] for c in MULTI_CASES}
        assert kinds == {"use_result", "recover"}


class TestMultiTurn:
    """Single-turn scores cannot see whether a model USES what a tool returned.
    A model that emits one perfect call and then ignores the result is useless
    in a loop, and that is the failure agents actually hit."""

    def test_uses_the_returned_value(self):
        from bench_tools import grade_followup
        ok, _ = grade_followup({"content": "The file contains version 9.4.1-rc2."},
                               ["9.4.1"])
        assert ok

    def test_ignoring_the_result_fails(self):
        from bench_tools import grade_followup
        ok, detail = grade_followup({"content": "I have read the file."}, ["9.4.1"])
        assert not ok and "does not mention" in detail

    def test_calling_another_tool_instead_of_answering_fails(self):
        from bench_tools import grade_followup
        ok, detail = grade_followup(
            {"content": None, "tool_calls": [{"id": "x", "type": "function",
                                              "function": {"name": "read_file",
                                                           "arguments": "{}"}}]},
            ["9.4.1"])
        assert not ok and "another tool" in detail

    def test_empty_reply_fails(self):
        from bench_tools import grade_followup
        ok, detail = grade_followup({"content": "  "}, ["9.4.1"])
        assert not ok and "empty" in detail

    def test_match_is_case_insensitive(self):
        from bench_tools import grade_followup
        assert grade_followup({"content": "VERSION 9.4.1-RC2"}, ["9.4.1"])[0]


class TestErrorRecovery:
    """A tool failed. Admitting it or retrying is fine; inventing the contents
    of a file that could not be read is the dangerous answer."""

    def test_admitting_the_failure_passes(self):
        from bench_tools import grade_error_recovery
        for reply in ("The file does not exist.", "I could not read it.",
                      "Error: no such file.", "Unable to open that path."):
            assert grade_error_recovery({"content": reply})[0], reply

    def test_retrying_with_another_call_passes(self):
        from bench_tools import grade_error_recovery
        ok, detail = grade_error_recovery(
            {"content": None, "tool_calls": [{"id": "y", "type": "function",
                                              "function": {"name": "list_files",
                                                           "arguments": "{}"}}]})
        assert ok and "retried" in detail

    def test_inventing_content_fails(self):
        # The failure that matters: answering as though the read had succeeded.
        from bench_tools import grade_error_recovery
        ok, detail = grade_error_recovery(
            {"content": "The config contains the database password and two API keys."})
        assert not ok and "ignored the error" in detail

    def test_empty_reply_fails(self):
        from bench_tools import grade_error_recovery
        ok, detail = grade_error_recovery({"content": ""})
        assert not ok and "empty" in detail


class TestTextJsonFallback:
    """Three models from three vendors emit the right tool name and arguments
    as prose. The fallback measures what an agent-side parser would recover —
    and must never manufacture a call the model did not actually describe."""

    def _msg(self, text):
        return {"content": text, "tool_calls": []}

    def test_recovers_a_parameters_shaped_call(self):
        m = self._msg('{"name": "read_file", "parameters": {"path": "README.md"}}')
        assert not grade(m, EXPECT_READ)[0], "off by default"
        ok, detail = grade(m, EXPECT_READ, accept_text_json=True)
        assert ok and "recovered from text" in detail

    def test_recovers_an_arguments_shaped_call(self):
        m = self._msg('{"name": "read_file", "arguments": {"path": "README.md"}}')
        assert grade(m, EXPECT_READ, accept_text_json=True)[0]

    def test_recovers_from_surrounding_prose(self):
        m = self._msg('Sure! I will call:\n{"name": "read_file", '
                      '"parameters": {"path": "README.md"}}\nLet me know.')
        assert grade(m, EXPECT_READ, accept_text_json=True)[0]

    def test_stringified_arguments_are_parsed(self):
        m = self._msg('{"name": "read_file", "arguments": "{\\"path\\": \\"README.md\\"}"}')
        assert grade(m, EXPECT_READ, accept_text_json=True)[0]

    def test_a_wrong_tool_in_text_is_still_wrong(self):
        # The fallback fixes the CHANNEL, never the answer.
        m = self._msg('{"name": "list_files", "parameters": {"directory": "."}}')
        assert not grade(m, EXPECT_READ, accept_text_json=True)[0]

    def test_wrong_arguments_in_text_are_still_wrong(self):
        m = self._msg('{"name": "read_file", "parameters": {"path": "LICENSE"}}')
        assert not grade(m, EXPECT_READ, accept_text_json=True)[0]

    def test_prose_without_json_recovers_nothing(self):
        m = self._msg("I would read README.md for you.")
        assert not grade(m, EXPECT_READ, accept_text_json=True)[0]

    def test_json_without_a_name_recovers_nothing(self):
        # Must not invent a call out of an unrelated JSON object.
        m = self._msg('{"path": "README.md"}')
        assert not grade(m, EXPECT_READ, accept_text_json=True)[0]

    def test_the_no_tool_case_is_unaffected(self):
        # A model that answers "4" must still pass, and one that describes a
        # call in text must still count as calling one.
        assert grade(self._msg("4"), None, accept_text_json=True)[0]
        assert not grade(self._msg('{"name": "run_tests", "parameters": {}}'),
                         None, accept_text_json=True)[0]
