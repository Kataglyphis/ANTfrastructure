"""Gateway log reads wait for the request a test actually made."""
import importlib.util
import json
import pathlib
import threading
import time

import pytest

CLIENT = pathlib.Path(__file__).parent / "gateway_e2e" / "gw_client.py"
SPEC = importlib.util.spec_from_file_location("gw_client", CLIENT)
assert SPEC is not None and SPEC.loader is not None
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)
LogTail = MODULE.LogTail


def test_logtail_waits_past_a_previous_request(tmp_path):
    path = tmp_path / "requests.jsonl"
    tail = LogTail(str(path))
    path.write_text(json.dumps({"alias": "chat"}) + "\n", encoding="utf-8")

    def append_current():
        time.sleep(0.2)
        with path.open("a", encoding="utf-8") as stream:
            stream.write(json.dumps({"alias": "chat-long", "aborted": "client_disconnect"}) + "\n")

    worker = threading.Thread(target=append_current)
    worker.start()
    try:
        lines = tail.lines(timeout=3, settle=0, predicate=lambda line: line.get("alias") == "chat-long")
    finally:
        worker.join(timeout=1)
    assert not worker.is_alive()
    assert lines == [{"alias": "chat-long", "aborted": "client_disconnect"}]


def test_logtail_keeps_duplicate_matching_requests_visible(tmp_path):
    path = tmp_path / "requests.jsonl"
    path.write_text('{"alias":"chat-long"}\n{"alias":"chat-long"}\n', encoding="utf-8")
    tail = LogTail(str(path))
    lines = tail.lines(settle=0, predicate=lambda line: line.get("alias") == "chat-long")
    assert len(lines) == 2
    with pytest.raises(ValueError, match="too many values"):
        (line,) = lines
