"""Routing through the real gateway: aliases, keys, the static routes, R3 and R5-R6.

Every test starts with empty fake lanes, so a count is exactly what the gateway sent.
"""
import pytest
from gw_client import call

BIG = "x" * 12000  # ~4000 tokens at 3 bytes/token: over the 3900 budget on its own


def test_models_is_static_open_and_touches_no_lane(gateway):
    reply = call(gateway.port, "/v1/models", method="GET")
    assert reply.status == 200
    assert [m["id"] for m in reply.json()["data"]] == ["chat", "chat-long", "agent"]
    assert gateway.counts() == {"npu": 0, "gpu": 0, "cpu": 0}
    assert all(not lane.requests for lane in gateway.lanes.values()), "a lane was probed"


def test_gateway_info_reports_what_is_mounted(gateway):
    info = call(gateway.port, "/gateway/info", method="GET").json()
    rendered = gateway.live("render.json")
    for key in ("config_sha256", "restart_sha256", "boot_config_sha256", "lua_sha256", "image"):
        assert info[key] == rendered[key], key
    assert "@sha256:" in info["image"]
    assert set(info["lua_sha256"]) == {"geniex_hook.lua", "apisix/plugins/geniex-shape.lua"}
    assert list(info["prompts_sha256"]) == ["tool-disambiguation"]


def test_an_unknown_model_is_an_openai_404(gateway):
    reply = gateway.post("nope")
    assert reply.status == 404
    assert reply.json()["error"]["code"] == "model_not_found"
    no_type = call(gateway.port, "/v1/chat/completions", raw=b'{"model":"chat"}',
                   key=gateway.keys["lab"], content_type="text/plain")
    assert no_type.status == 404, "post_arg.model needs Content-Type: application/json"
    assert gateway.counts() == {"npu": 0, "gpu": 0, "cpu": 0}


@pytest.mark.parametrize("key, status", [(None, 401), ("not-a-key-at-all-0000", 401),
                                         ("webui", 200), ("lab", 200), ("agent", 200)])
def test_every_client_has_its_own_key(gateway, key, status):
    reply = gateway.post("chat", key=key)
    assert reply.status == status
    assert gateway.counts()["npu"] == (1 if status == 200 else 0)
    if status == 200:
        lines = gateway.log.lines()
        assert [line["consumer"] for line in lines] == [key]


def test_the_lane_never_sees_the_client_key(gateway):
    gateway.post("chat")
    (req,) = gateway.requests("npu")
    assert req.headers.get("authorization") == "Bearer unused"
    assert gateway.keys["lab"] not in str(req.headers)
    assert req.headers.get("x-consumer-username") == "lab", "key-auth names the client upstream"


def test_raw_routes_are_for_the_lab_key_only(gateway):
    assert gateway.post("raw-npu", key="webui").status == 403
    assert gateway.counts()["npu"] == 0
    reply = gateway.post("raw-npu")
    assert reply.status == 200 and reply.headers["x-gw-lane"] == "npu"


@pytest.mark.parametrize("model, lane", [("chat", "npu"), ("chat-long", "gpu"), ("agent", "cpu"),
                                         ("raw-npu", "npu"), ("raw-gpu", "gpu"), ("raw-cpu", "cpu")])
def test_each_alias_goes_to_its_lane_once(gateway, model, lane):
    reply = gateway.post(model)
    assert reply.status == 200
    assert reply.headers["x-gw-lane"] == lane
    assert reply.headers["x-gw-rerouted"] == "no"
    expect = {"npu": 0, "gpu": 0, "cpu": 0}
    expect[lane] = 1
    assert gateway.counts() == expect
    (req,) = gateway.requests(lane)
    assert req.path in ("/v1/chat/completions", "/v1/chat/completions?")
    assert req.body["model"] == gateway.lanes_models[lane], "options.model pins the lane's model"
    assert reply.json()["model"] == gateway.lanes_models[lane], "replies carry the lane's model id"


def test_a_route_above_the_stock_600s_cap_loads(gateway):
    assert gateway.route("agent")["plugins"]["ai-proxy-multi"]["timeout"] == 1800000
    assert gateway.post("agent").status == 200


def test_a_large_request_goes_to_the_gpu_before_anything_is_sent(gateway):
    reply = gateway.post("chat", messages=[{"role": "user", "content": BIG}], max_tokens=100)
    assert reply.status == 200
    assert (reply.headers["x-gw-lane"], reply.headers["x-gw-rerouted"]) == ("gpu", "presend")
    assert gateway.counts() == {"npu": 0, "gpu": 1, "cpu": 0}
    (line,) = gateway.log.lines()
    assert (line["route_id"], line["lane"], line["rerouted"]) == ("chat-presend", "gpu", "presend")
    assert line["est_tokens"] > 3900


def test_the_estimate_counts_the_reply_reserve(gateway):
    small = gateway.post("chat", max_tokens=100)
    assert small.headers["x-gw-lane"] == "npu"
    big_reply = gateway.post("chat", max_tokens=3950)
    assert big_reply.headers["x-gw-lane"] == "gpu"
    assert gateway.counts() == {"npu": 1, "gpu": 1, "cpu": 0}


@pytest.mark.parametrize("stream", [False, True])
def test_an_npu_overflow_goes_to_the_gpu_exactly_once(gateway, stream):
    reply = gateway.post("chat", stream=stream, fake={"npu": "overflow"})
    assert reply.status == 200
    assert (reply.headers["x-gw-lane"], reply.headers["x-gw-rerouted"]) == ("gpu", "overflow")
    assert gateway.counts() == {"npu": 1, "gpu": 1, "cpu": 0}
    if stream:
        assert reply.headers["content-type"].startswith("text/event-stream")
        assert reply.sse()[-1] == "[DONE]"
    (line,) = gateway.log.lines()
    assert (line["lane"], line["rerouted"], line["status"]) == ("gpu", "overflow", 200)


def test_a_second_overflow_is_not_retried(gateway):
    reply = gateway.post("chat", fake={"npu": "overflow", "gpu": "overflow"})
    assert reply.status == 400
    assert reply.json()["error"]["code"] == "context_length_exceeded"
    assert gateway.counts() == {"npu": 1, "gpu": 1, "cpu": 0}


def test_another_npu_400_reaches_the_client_unchanged(gateway):
    reply = gateway.post("chat", fake={"npu": "badreq"})
    assert reply.status == 400
    assert reply.json()["error"]["code"] == "invalid_value"
    assert gateway.counts() == {"npu": 1, "gpu": 0, "cpu": 0}


def test_an_overflow_on_the_raw_route_is_not_rerouted(gateway):
    reply = gateway.post("raw-npu", fake={"npu": "overflow"})
    assert reply.status == 400
    assert gateway.counts() == {"npu": 1, "gpu": 0, "cpu": 0}


@pytest.mark.parametrize("fault", ["reset", "status=500", "crash"])
def test_a_failed_npu_before_the_reply_starts_falls_back_once(gateway, fault):
    reply = gateway.post("chat", fake={"npu": fault})
    assert reply.status == 200
    assert (reply.headers["x-gw-lane"], reply.headers["x-gw-rerouted"]) == ("gpu", "fallback")
    assert gateway.counts() == {"npu": 1, "gpu": 1, "cpu": 0}


def test_a_lane_that_dies_mid_stream_is_not_retried(gateway):
    reply = gateway.post("chat", stream=True, fake={"npu": "crash=2"})
    assert reply.status == 200 and reply.headers["x-gw-lane"] == "npu"
    events = reply.sse()
    assert events and "[DONE]" not in events, "the client sees the cut, not a second answer"
    assert gateway.counts() == {"npu": 1, "gpu": 0, "cpu": 0}
    (line,) = gateway.log.lines()
    assert line["aborted"] == "read_error"


def test_the_npu_times_out_at_its_own_timeout_and_is_not_retried(gateway):
    reply = gateway.post("chat", fake={"npu": "hold=3.5"})
    assert reply.status == 504
    assert 1.8 < reply.elapsed < 3.2, "the NPU's 2 s, not the route's 6 s"
    assert gateway.counts() == {"npu": 1, "gpu": 0, "cpu": 0}


def test_the_gpu_waits_out_a_long_first_byte(gateway):
    reply = gateway.post("chat-long", fake={"gpu": "hold=4"})
    assert reply.status == 200
    assert reply.elapsed > 3.9
    assert gateway.counts() == {"npu": 0, "gpu": 1, "cpu": 0}
