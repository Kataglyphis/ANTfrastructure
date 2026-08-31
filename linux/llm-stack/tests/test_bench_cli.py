"""Tests for the shared CLI front end.

This code had NO coverage before it was extracted: nothing in tests/ imports
either tool's main(), so candidate resolution — the code deciding WHICH
endpoint gets measured — was untested in both copies. That is how a None label
survived long enough to crash a ranking print after a full run and before the
report was written.
"""

import json
import os
import sys
import types

import pytest

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from bench_cli import resolve_candidates, write_report  # noqa: E402


def stub_backend(pinned_model=None):
    """Stands in for resolve_backend without needing a server."""
    def _resolve(backend, base_url):
        if base_url:
            return base_url.rstrip("/"), None, "--base-url"
        return f"http://{backend or 'default'}:1", pinned_model, f"backend {backend!r}"
    return _resolve


def args(**kw):
    base = {"compare": None, "backend": None, "base_url": None,
            "model": None, "label": None}
    base.update(kw)
    return types.SimpleNamespace(**base)


class TestSingleRun:
    def test_explicit_label_wins(self):
        c = resolve_candidates(args(backend="npu", model="org/M", label="mine"),
                               stub_backend())
        assert c == [("mine", "http://npu:1", "org/M")]

    def test_model_is_the_label_when_none_given(self):
        c = resolve_candidates(args(backend="npu", model="org/M"), stub_backend())
        assert c[0][0] == "org/M"

    def test_a_backend_pinned_model_is_used(self):
        c = resolve_candidates(args(backend="npu"), stub_backend("pinned/M"))
        assert c[0] == ("pinned/M", "http://npu:1", "pinned/M")

    def test_label_never_ends_up_none(self):
        # The defect this whole module exists for: with no label, no --model and
        # a backend that pins nothing, the label used to be None and the ranking
        # print crashed AFTER the run and BEFORE the report was written.
        c = resolve_candidates(args(backend="ollama"), stub_backend(None))
        assert c[0][0] is not None and c[0][0] != ""

    def test_label_never_none_even_with_no_backend_at_all(self):
        c = resolve_candidates(args(), stub_backend(None))
        assert c[0][0]


class TestCompareFile:
    def _file(self, tmp_path, entries):
        p = tmp_path / "cands.json"
        p.write_text(json.dumps(entries))
        return str(p)

    def test_reads_every_entry(self, tmp_path):
        f = self._file(tmp_path, [{"backend": "a", "model": "m1"},
                                  {"backend": "b", "model": "m2"}])
        c = resolve_candidates(args(compare=f), stub_backend())
        assert [x[2] for x in c] == ["m1", "m2"]

    def test_entries_without_label_or_model_still_get_a_label(self, tmp_path):
        # Exactly the reproduction from the audit.
        f = self._file(tmp_path, [{"backend": "geniex-npu"}, {"backend": "geniex-cpu"}])
        c = resolve_candidates(args(compare=f), stub_backend(None))
        assert all(x[0] for x in c), c

    def test_explicit_base_url_overrides_the_backend(self, tmp_path):
        f = self._file(tmp_path, [{"base_url": "http://elsewhere:9/", "model": "m"}])
        c = resolve_candidates(args(compare=f), stub_backend())
        assert c[0][1] == "http://elsewhere:9"

    def test_a_non_list_file_fails_loudly(self, tmp_path):
        p = tmp_path / "bad.json"
        p.write_text('{"backend": "a"}')
        with pytest.raises(SystemExit):
            resolve_candidates(args(compare=str(p)), stub_backend())


class TestWriteReport:
    def test_writes_the_shared_envelope(self, tmp_path):
        out = str(tmp_path / "r.json")
        write_report(out, "bench_tools", {"repeats": 1}, [{"label": "m"}],
                     None, ("bench_cli.py",))
        d = json.load(open(out))
        assert d["benchmark"] == "bench_tools"
        assert d["config"] == {"repeats": 1}
        assert d["reports"] == [{"label": "m"}]
        assert "provenance" in d

    def test_the_write_is_atomic(self, tmp_path):
        # A Ctrl-C mid-write used to be able to leave a truncated JSON that a
        # later comparison would silently misread.
        out = str(tmp_path / "r.json")
        write_report(out, "b", {}, [], None, ("bench_cli.py",))
        assert not os.path.exists(out + ".tmp")
        json.load(open(out))  # parses

    def test_this_module_is_not_in_the_fingerprint(self):
        # tool_sha256 means "the GRADER moved". Folding plumbing into it would
        # fire that alarm on every --compare-schema edit while the grader is
        # provably unchanged.
        for tool in ("bench_coding.py", "bench_tools.py"):
            src = open(os.path.join(os.path.dirname(os.path.dirname(
                os.path.abspath(__file__))), tool)).read()
            i = src.index("write_report(")
            call = src[i:i + 400]
            assert "bench_cli.py" not in call, f"{tool} hashes bench_cli.py"
