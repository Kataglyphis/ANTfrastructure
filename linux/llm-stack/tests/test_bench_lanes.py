"""Unit tests for the concurrency probes (LB4 + LB5).

Runs against a throwaway HTTP server in-process: no model, no GPU, no network
beyond loopback. What is worth testing here is the JUDGEMENT, not the plumbing
-- specifically that "the second request only started after the first
finished" is reported as serialised, because that verdict decides whether you
buy throughput with more clients or with more servers.
"""

import json
import os
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

import pytest

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from bench_lanes import parse_lane, probe_batching, stream_once  # noqa: E402


def make_server(*, serialise, tokens=5, delay=0.02):
    """A tiny SSE endpoint. If serialise=True it holds a lock for the whole
    response, so a second request cannot start until the first has finished --
    exactly the behaviour the probe must detect."""
    lock = threading.Lock()

    class Handler(BaseHTTPRequestHandler):
        # HTTP/1.0 + Connection: close means the body is delimited by EOF, so
        # the stream needs no chunk framing and no Content-Length. Declaring
        # "chunked" without actually framing the chunks breaks the client.
        protocol_version = "HTTP/1.0"

        def do_POST(self):
            length = int(self.headers.get("Content-Length", 0))
            self.rfile.read(length)
            self.send_response(200)
            self.send_header("Content-Type", "text/event-stream")
            self.send_header("Connection", "close")
            self.end_headers()

            def emit():
                for _ in range(tokens):
                    time.sleep(delay)
                    # No space after "data:" on purpose -- the spec allows it
                    # and at least one real server does exactly this.
                    chunk = json.dumps({"choices": [{"delta": {"content": "x"}}]})
                    self.wfile.write(f"data:{chunk}\n\n".encode())
                    self.wfile.flush()
                self.wfile.write(b"data:[DONE]\n\n")
                self.wfile.flush()

            try:
                if serialise:
                    with lock:
                        emit()
                else:
                    emit()
            except BrokenPipeError:
                pass  # client hung up early; nothing to do

        def log_message(self, *a):
            pass

    # ThreadingHTTPServer, otherwise the SERVER serialises regardless of the
    # handler and the "overlapping" case could never be expressed.
    srv = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    threading.Thread(target=srv.serve_forever, daemon=True).start()
    return srv, f"http://127.0.0.1:{srv.server_port}"


class TestStreamOnce:
    def test_parses_sse_without_space_after_data(self):
        srv, url = make_server(serialise=False, tokens=4)
        try:
            r = stream_once(url, "m", "hi", max_tokens=16)
        finally:
            srv.shutdown()
        assert r["tokens"] == 4
        assert r["ttft_s"] is not None and r["ttft_s"] > 0

    def test_unreachable_endpoint_reports_error_not_raise(self):
        # A dead lane must not kill a multi-lane run.
        r = stream_once("http://127.0.0.1:1", "m", "hi", timeout=2)
        assert "error" in r
        assert "wall_s" in r


class TestBatchingVerdict:
    def test_detects_serialised_server(self):
        srv, url = make_server(serialise=True, tokens=8, delay=0.05)
        try:
            report = probe_batching(url, "m", "hi", 16)
        finally:
            srv.shutdown()
        assert report["serialised"] is True
        assert "SERIALISED" in report["verdict"]

    def test_detects_overlapping_server(self):
        srv, url = make_server(serialise=False, tokens=8, delay=0.05)
        try:
            report = probe_batching(url, "m", "hi", 16)
        finally:
            srv.shutdown()
        assert report["serialised"] is False
        assert "OVERLAPPED" in report["verdict"]


class TestLaneSpecParsing:
    def test_parses_name_url_model(self):
        name, url, model = parse_lane("npu=http://127.0.0.1:18181,model=org/Model:Q4")
        assert (name, url, model) == ("npu", "http://127.0.0.1:18181", "org/Model:Q4")

    def test_strips_trailing_slash(self):
        _, url, _ = parse_lane("cpu=http://h:1/,model=m")
        assert url == "http://h:1"

    def test_model_name_may_contain_commas_after_the_marker(self):
        _, _, model = parse_lane("a=http://h:1,model=some,weird:name")
        assert model == "some,weird:name"

    def test_rejects_malformed_spec(self):
        with pytest.raises(Exception):
            parse_lane("this-is-not-a-lane")


class TestLaneResolution:
    """A bare backend name must work as a lane, and a typo must not be
    silently turned into something plausible."""

    def test_bare_backend_name_resolves_from_registry(self):
        from bench_lanes import resolve_lane
        name, url, model = resolve_lane("geniex-npu")
        assert name == "geniex-npu"
        assert url.startswith("http://")
        assert model  # the registry supplies the default model

    def test_full_spec_still_works(self):
        from bench_lanes import resolve_lane
        assert resolve_lane("x=http://h:1,model=m") == ("x", "http://h:1", "m")

    def test_unknown_name_is_rejected_with_the_known_list(self):
        import argparse

        from bench_lanes import resolve_lane
        with pytest.raises(argparse.ArgumentTypeError) as e:
            resolve_lane("not-a-backend")
        assert "not-a-backend" in str(e.value)
        assert "geniex-npu" in str(e.value) or "ollama" in str(e.value)

    def test_backend_without_a_default_model_explains_itself(self):
        # 'ollama' has no pinned model: the error must say how to supply one
        # rather than fail with a KeyError deep inside the run.
        import argparse

        from bench_lanes import resolve_lane
        with pytest.raises(argparse.ArgumentTypeError) as e:
            resolve_lane("ollama")
        assert "model=" in str(e.value)
