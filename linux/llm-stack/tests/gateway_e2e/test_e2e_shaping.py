"""What the lanes receive: the tools prompt (R2), T=0 and power_mode (R4), streams (R7).

The fake lanes record the body exactly as the gateway sent it, so these assert on
the lane side of the gateway rather than on what a reply happens to say.
"""
import json

import pytest
from gw_client import call
from gw_harness import PROMPT

TOOLS = [{"type": "function", "function": {"name": "get_weather", "description": "Weather in a city",
                                            "parameters": {"type": "object",
                                                           "properties": {"city": {"type": "string"}},
                                                           "required": ["city"]}}}]
PROMPT_TEXT = PROMPT.decode()


def first_message(req):
    return req.body["messages"][0]


def test_the_prompt_is_added_only_when_tools_are_sent(gateway):
    gateway.post("chat", tools=TOOLS)
    gateway.post("chat")
    gateway.post("chat", tools=[])
    with_tools, plain, empty = gateway.requests("npu")
    assert first_message(with_tools) == {"role": "system", "content": PROMPT_TEXT}
    assert len(with_tools.body["messages"]) == 2
    assert plain.body["messages"] == [{"role": "user", "content": "hi"}]
    assert empty.body["messages"] == [{"role": "user", "content": "hi"}]
    prompts = [line["prompt"] for line in gateway.log.lines(expect=3)]
    assert prompts == ["tool-disambiguation", "-", "-"]


def test_the_prompt_bytes_are_the_pinned_ones(gateway):
    gateway.post("chat", tools=TOOLS)
    (req,) = gateway.requests("npu")
    assert first_message(req)["content"].encode() == PROMPT, "CRLF included"


def test_the_prompt_goes_before_the_clients_own_system_message(gateway):
    messages = [{"role": "system", "content": "be brief"}, {"role": "user", "content": "hi"}]
    gateway.post("chat", tools=TOOLS, messages=messages)
    (req,) = gateway.requests("npu")
    assert [m["content"] for m in req.body["messages"]] == [PROMPT_TEXT, "be brief", "hi"]


def test_a_request_that_already_carries_the_prompt_gets_no_second_copy(gateway):
    messages = [{"role": "system", "content": PROMPT_TEXT}, {"role": "user", "content": "hi"}]
    gateway.post("chat", tools=TOOLS, messages=messages)
    (req,) = gateway.requests("npu")
    assert req.body["messages"] == messages


@pytest.mark.parametrize("model, lane", [("chat-long", "gpu"), ("agent", "cpu"), ("raw-npu", "npu")])
def test_other_routes_add_no_prompt(gateway, model, lane):
    gateway.post(model, tools=TOOLS)
    (req,) = gateway.requests(lane)
    assert req.body["messages"] == [{"role": "user", "content": "hi"}]


def test_the_prompt_follows_the_alias_to_the_gpu(gateway):
    gateway.post("chat", tools=TOOLS, max_tokens=3950)
    gateway.post("chat", tools=TOOLS, fake={"npu": "overflow"})
    presend, fallback = gateway.requests("gpu")
    (refused,) = gateway.requests("npu")
    for req in (presend, fallback, refused):
        assert first_message(req)["content"] == PROMPT_TEXT


@pytest.mark.parametrize("model, lane, rewritten", [
    ("chat", "npu", False), ("chat-long", "gpu", True), ("agent", "cpu", True),
    ("raw-npu", "npu", False), ("raw-gpu", "gpu", False), ("raw-cpu", "cpu", False)])
def test_t0_is_made_greedy_only_on_the_gguf_lanes(gateway, model, lane, rewritten):
    gateway.post(model, temperature=0)
    (req,) = gateway.requests(lane)
    if rewritten:
        assert (req.body["temperature"], req.body["top_k"]) == (0.01, 1)
    else:
        assert req.body["temperature"] == 0 and "top_k" not in req.body


def test_t0_follows_the_lane_after_an_overflow(gateway):
    gateway.post("chat", temperature=0, fake={"npu": "overflow"})
    (npu,), (gpu,) = gateway.requests("npu"), gateway.requests("gpu")
    assert npu.body["temperature"] == 0 and "top_k" not in npu.body
    assert (gpu.body["temperature"], gpu.body["top_k"]) == (0.01, 1)


@pytest.mark.parametrize("model, lane", [("chat", "npu"), ("chat-long", "gpu")])
def test_a_nonzero_temperature_is_left_alone(gateway, model, lane):
    gateway.post(model, temperature=0.7, top_k=40)
    (req,) = gateway.requests(lane)
    assert (req.body["temperature"], req.body["top_k"]) == (0.7, 40)


def test_power_mode_is_dropped_on_aliases_and_kept_on_raw_routes(gateway):
    gateway.post("chat", power_mode="high")
    gateway.post("raw-npu", power_mode="high")
    alias, raw = gateway.requests("npu")
    assert "power_mode" not in alias.body
    assert raw.body["power_mode"] == "high"


def test_a_stream_is_forced_to_report_usage(gateway):
    reply = gateway.post("chat", stream=True)
    (req,) = gateway.requests("npu")
    assert req.body["stream_options"] == {"include_usage": True}
    usage = [e for e in reply.sse() if e != "[DONE]" and e.get("usage")]
    assert len(usage) == 1 and usage[0]["choices"] == []


def test_sse_passes_chunk_by_chunk_and_unchanged(gateway):
    reply = gateway.post("chat", stream=True, fake={"npu": "gap=0.4"})
    assert reply.status == 200 and reply.error is None
    (sent,) = gateway.lanes["npu"].sent
    assert reply.body == sent, "the gateway forwards the lane's SSE bytes as they are"
    first_data = next(t for t, c in reply.chunks if b"data:" in c)
    assert reply.chunks[-1][0] - first_data > 2.0, "events arrive as they are made, not at the end"


def test_completions_ride_the_passthrough_with_the_lane_model(gateway):
    reply = gateway.post("chat", path="/v1/completions", prompt="Say hi", messages=None)
    assert reply.status == 200
    (req,) = gateway.requests("npu")
    assert req.path in ("/v1/completions", "/v1/completions?"), "lua-resty-http appends a bare '?'"
    assert req.body["model"] == gateway.lanes_models["npu"]


def test_tool_calls_come_back_untouched(gateway):
    reply = gateway.post("chat", tools=TOOLS, fake={"npu": "toolcall"})
    call_ = reply.json()["choices"][0]["message"]["tool_calls"][0]
    assert call_["function"] == {"name": "get_weather", "arguments": "{\"city\":\"Berlin\"}"}
    (line,) = gateway.log.lines()
    assert line["tool_calls"] == "true" and line["tools"] == 1


def test_bodies_reach_the_lane_with_sorted_keys(gateway):
    raw = json.dumps({"model": "raw-npu", "messages": [{"role": "user", "content": "hi"}],
                      "tools": [{"type": "function", "function": {"parameters": {}, "name": "z"}}]})
    call(gateway.port, "/v1/chat/completions", raw=raw.encode(), key=gateway.keys["lab"])
    (req,) = gateway.requests("npu")
    text = req.raw.decode()
    assert text.index('"messages"') < text.index('"model"') < text.index('"tools"')
    assert text.index('"name"') < text.index('"parameters"'), "raw-* is not byte-transparent"
