"""Tests for provenance capture.

A result without provenance cannot be compared against a later one, which makes
regression detection impossible -- and an old number that looks authoritative
but cannot be reproduced is worse than no number.
"""

import os
import sys

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from bench_provenance import collect, compare, tool_fingerprint  # noqa: E402


class TestCollect:
    def test_records_the_fields_a_rerun_needs(self):
        p = collect()
        for key in ("schema_version", "timestamp_utc", "host", "os",
                    "architecture", "python", "git_sha", "git_dirty"):
            assert key in p, key

    def test_names_missing_fields_instead_of_omitting_them(self):
        # LB9's lesson: a silent gap is worse than a visible one.
        p = collect()
        assert isinstance(p["incomplete"], list)

    def test_unreachable_server_is_recorded_as_null_not_an_exception(self):
        p = collect(base_url="http://127.0.0.1:1")
        assert p["server_models"] is None

    def test_extra_fields_are_merged(self):
        p = collect(extra={"lane": "npu"})
        assert p["lane"] == "npu"


class TestToolFingerprint:
    def test_hashes_the_benchmark_source(self):
        assert tool_fingerprint("bench_provenance.py")

    def test_same_files_same_hash_regardless_of_order(self):
        a = tool_fingerprint("bench_provenance.py", "bench_tools.py")
        b = tool_fingerprint("bench_tools.py", "bench_provenance.py")
        assert a == b

    def test_different_files_differ(self):
        assert tool_fingerprint("bench_tools.py") != tool_fingerprint("bench_coding.py")

    def test_missing_file_yields_none(self):
        assert tool_fingerprint("does-not-exist.py") is None


class TestCompare:
    def test_two_identical_clean_runs_report_nothing(self):
        p = collect(extra={"git_dirty": False})
        assert compare(p, p) == []

    def test_a_dirty_run_is_flagged_even_against_itself(self):
        # Deliberate, not a quirk: with a dirty tree the recorded SHA does not
        # describe what actually ran, so the caveat belongs on every comparison
        # the run takes part in -- including with itself.
        p = collect(extra={"git_dirty": True})
        assert any("dirty working tree" in n for n in compare(p, p))

    def test_a_changed_grader_is_called_out_first(self):
        # The trap this exists for: the ranking moved because the BENCHMARK
        # changed, which is indistinguishable from a model regression without it.
        old = collect(extra={"tool_sha256": "aaaa"})
        new = collect(extra={"tool_sha256": "bbbb"})
        notes = compare(old, new)
        assert notes and "BENCHMARK SOURCE CHANGED" in notes[0]

    def test_different_served_models_are_flagged(self):
        old = collect(extra={"server_models": ["a"]})
        new = collect(extra={"server_models": ["b"]})
        assert any("served models differ" in n for n in compare(old, new))

    def test_a_dirty_tree_is_flagged(self):
        old = collect(extra={"git_dirty": False})
        new = collect(extra={"git_dirty": True})
        assert any("dirty working tree" in n for n in compare(old, new))

    def test_a_moved_repository_is_flagged(self):
        old = collect(extra={"git_sha": "1" * 40, "git_dirty": False})
        new = collect(extra={"git_sha": "2" * 40, "git_dirty": False})
        assert any("repository moved" in n for n in compare(old, new))
