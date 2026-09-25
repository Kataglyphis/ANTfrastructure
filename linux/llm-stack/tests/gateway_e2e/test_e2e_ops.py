"""Operating the gateway: the log line and metrics (R9), serve-stack.sh's status,
validation gate and reload (R12), and the hot-reload environment trap.
"""
import json
import os
import shutil
import time
import urllib.request

import pytest
from gw_client import call

FIELDS = {"ts", "consumer", "route_id", "alias", "lane", "rerouted", "prompt", "status",
          "upstream", "upstream_status", "model", "prompt_tokens", "completion_tokens",
          "ttft_ms", "upstream_ms", "request_s", "stream", "tools", "tool_calls", "aborted",
          "method", "uri"}


def test_one_log_line_per_request_with_its_fields(gateway):
    gateway.post("chat", stream=True)
    (line,) = gateway.log.lines()
    assert FIELDS <= set(line), sorted(FIELDS - set(line))
    assert (line["consumer"], line["route_id"], line["alias"], line["lane"]) == ("lab", "chat", "chat", "npu")
    assert (line["rerouted"], line["prompt"], line["status"], line["aborted"]) == ("no", "-", 200, "-")
    assert line["upstream"] == f"127.0.0.1:{gateway.lanes['npu'].port}"
    assert line["model"] == gateway.lanes_models["npu"]
    assert line["stream"] == "true" and int(line["completion_tokens"]) == 3
    assert isinstance(line["est_tokens"], int)


def test_a_fallback_is_one_line_naming_both_attempts(gateway):
    gateway.post("chat", fake={"npu": "overflow"})
    (line,) = gateway.log.lines()
    npu, gpu = (f"127.0.0.1:{gateway.lanes[n].port}" for n in ("npu", "gpu"))
    assert (line["lane"], line["rerouted"], line["status"]) == ("gpu", "overflow", 200)
    assert [a.strip() for a in line["upstream"].split(",")] == [npu, gpu]
    assert [s.strip() for s in str(line["upstream_status"]).split(",")] == ["503", "200"]


def test_static_routes_log_without_lane_fields(gateway):
    call(gateway.port, "/v1/models", method="GET")
    (line,) = gateway.log.lines()
    assert line["route_id"] == "models" and "lane" not in line


def _metric_lines(gateway, prefix, timeout=35):
    """The exporter refreshes its cache every 15 s, so a fresh series can take that long."""
    url = f"http://127.0.0.1:{gateway.metrics_port}/apisix/prometheus/metrics"
    deadline = time.monotonic() + timeout
    while True:
        text = urllib.request.urlopen(url, timeout=5).read().decode()
        found = [m for m in text.splitlines() if m.startswith(prefix)]
        if found or time.monotonic() > deadline:
            return found
        time.sleep(1)


def test_metrics_carry_the_lane_as_node(gateway):
    # APISIX skips a latency of 0 ms, and the fake would answer within one.
    gateway.post("chat-long", fake={"gpu": "hold=0.2"})
    latency = _metric_lines(gateway, "apisix_llm_latency_count{")
    assert any('node="gpu"' in m and 'consumer="lab"' in m and 'route_id="chat-long"' in m
               for m in latency), latency
    tokens = _metric_lines(gateway, "apisix_llm_prompt_tokens{")
    assert any('node="gpu"' in m for m in tokens), tokens


def test_status_reports_in_sync(gateway):
    status = gateway.serve("status")
    assert status.returncode == 0, status.stdout + status.stderr
    assert "in sync" in status.stdout


def test_validation_passes_the_live_bundle(gateway, tmp_path):
    bundle = tmp_path / "bundle"
    shutil.copytree(os.path.join(gateway.state, "live"), bundle,
                    ignore=shutil.ignore_patterns("runtime.env", "*.prev"))
    ok = gateway.serve("validate", str(bundle))
    assert ok.returncode == 0, ok.stdout + ok.stderr


@pytest.mark.parametrize("break_it, symptom", [
    (lambda doc: doc["routes"][2]["plugins"]["ai-proxy-multi"].update(timeout="soon"),
     "failed to check item data"),
    (lambda doc: doc["routes"][2]["plugins"]["geniex-shape"].update(tag="sometimes"),
     "failed to check item data"),
])
def test_validation_refuses_a_bundle_apisix_would_half_load(gateway, tmp_path, break_it, symptom):
    bundle = tmp_path / "bundle"
    shutil.copytree(os.path.join(gateway.state, "live"), bundle,
                    ignore=shutil.ignore_patterns("runtime.env", "*.prev"))
    doc = json.loads((bundle / "apisix.json").read_text())
    break_it(doc)
    (bundle / "apisix.json").write_text(json.dumps(doc))
    bad = gateway.serve("validate", str(bundle))
    assert bad.returncode != 0
    assert symptom in bad.stderr


def test_reload_swaps_routing_in_place_and_keys_survive_it(gateway):
    before = gateway.info()["config_sha256"]
    medium = [{"role": "user", "content": "y" * 4000}]
    assert gateway.post("chat", messages=medium).headers["x-gw-lane"] == "npu"
    gateway.write_registry(budget=1000)
    try:
        reload_ = gateway.serve("reload")
        assert reload_.returncode == 0, reload_.stdout + reload_.stderr
        assert gateway.info()["config_sha256"] != before
        assert gateway.post("chat", messages=medium).headers["x-gw-lane"] == "gpu"
        assert gateway.post("chat", key=None).status == 401
        for client in ("webui", "lab", "agent"):
            assert gateway.post("chat", key=client).status == 200, client
    finally:
        gateway.write_registry()
        back = gateway.serve("reload")
    assert back.returncode == 0, back.stdout + back.stderr
    assert gateway.info()["config_sha256"] == before


def test_reload_refuses_a_change_that_needs_a_restart(gateway):
    before = gateway.info()["config_sha256"]
    gateway.write_registry(listen="127.0.0.1:1")
    try:
        refused = gateway.serve("reload")
    finally:
        gateway.write_registry()
    assert refused.returncode != 0
    assert "needs a restart" in refused.stderr
    assert gateway.info()["config_sha256"] == before
