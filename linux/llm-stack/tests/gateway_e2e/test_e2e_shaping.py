"""What the lanes receive: the tools prompt (R2), T=0 and power_mode (R4), streams (R7).

The fake lanes record the body exactly as the gateway sent it, so these assert on
the lane side of the gateway rather than on what a reply happens to say.
"""
import json

import pytest
from gw_client import call
from gw_fake_lane import Received
from gw_harness import PROMPT, Gateway, JsonValue

TOOLS: JsonValue = [{"type": "function", "function": {"name": "get_weather", "description": "Weather in a city",
                                                       "parameters": {"type": "object",
                                                                      "properties": {"city": {"type": "string"}},
                                                                      "required": ["city"]}}}]
PROMPT_TEXT = PROMPT.decode()
type JsonObject = dict[str, JsonValue]


def request_body(req: Received) -> JsonObject:
    if not isinstance(req.body, dict):
        raise TypeError("lane request body must be a JSON object")
    return req.body


def first_message(req: Received) -> JsonObject:
    messages = request_body(req).get("messages")
    if not isinstance(messages, list) or not messages or not isinstance(messages[0], dict):
        raise AssertionError("lane request must contain a message object")
    return messages[0]


def test_the_prompt_is_added_only_when_tools_are_sent(gateway: Gateway) -> None:
    gateway.post("chat", tools=TOOLS)
    gateway.post("chat")
    gateway.post("chat", tools=[])
    with_tools, plain, empty = gateway.requests("npu")
    assert first_message(with_tools) == {"role": "system", "content": PROMPT_TEXT}
    with_tools_messages = request_body(with_tools)["messages"]
    assert isinstance(with_tools_messages, list) and len(with_tools_messages) == 2
    assert request_body(plain)["messages"] == [{"role": "user", "content": "hi"}]
    assert request_body(empty)["messages"] == [{"role": "user", "content": "hi"}]
    prompts = [line["prompt"] for line in gateway.log.lines(expect=3)]
    assert prompts == ["tool-disambiguation", "-", "-"]


def test_the_prompt_bytes_are_the_pinned_ones(gateway: Gateway) -> None:
    gateway.post("chat", tools=TOOLS)
    (req,) = gateway.requests("npu")
    content = first_message(req)["content"]
    assert isinstance(content, str)
    assert content.encode() == PROMPT, "CRLF included"


def test_the_prompt_goes_before_the_clients_own_system_message(gateway: Gateway) -> None:
    messages: JsonValue = [{"role": "system", "content": "be brief"},
                           {"role": "user", "content": "hi"}]
    gateway.post("chat", tools=TOOLS, messages=messages)
    (req,) = gateway.requests("npu")
    messages = request_body(req)["messages"]
    assert isinstance(messages, list)
    contents = []
    for message in messages:
        if not isinstance(message, dict):
            raise TypeError("lane request contains a non-object message")
        contents.append(message["content"])
    assert contents == [PROMPT_TEXT, "be brief", "hi"]


def test_a_request_that_already_carries_the_prompt_gets_no_second_copy(gateway: Gateway) -> None:
    messages: JsonValue = [{"role": "system", "content": PROMPT_TEXT},
                           {"role": "user", "content": "hi"}]
    gateway.post("chat", tools=TOOLS, messages=messages)
    (req,) = gateway.requests("npu")
    assert request_body(req)["messages"] == messages


@pytest.mark.parametrize("model, lane", [("chat-long", "gpu"), ("agent", "cpu"), ("raw-npu", "npu")])
def test_other_routes_add_no_prompt(gateway: Gateway, model: str, lane: str) -> None:
    gateway.post(model, tools=TOOLS)
    (req,) = gateway.requests(lane)
    assert request_body(req)["messages"] == [{"role": "user", "content": "hi"}]


def test_the_prompt_follows_the_alias_to_the_gpu(gateway: Gateway) -> None:
    gateway.post("chat", tools=TOOLS, max_tokens=3950)
    gateway.post("chat", tools=TOOLS, fake={"npu": "overflow"})
    presend, fallback = gateway.requests("gpu")
    (refused,) = gateway.requests("npu")
    for req in (presend, fallback, refused):
        assert first_message(req)["content"] == PROMPT_TEXT


@pytest.mark.parametrize("model, lane, rewritten", [
    ("chat", "npu", False), ("chat-long", "gpu", True), ("agent", "cpu", True),
    ("raw-npu", "npu", False), ("raw-gpu", "gpu", False), ("raw-cpu", "cpu", False)])
def test_t0_is_made_greedy_only_on_the_gguf_lanes(
    gateway: Gateway, model: str, lane: str, rewritten: bool,
) -> None:
    gateway.post(model, temperature=0)
    (req,) = gateway.requests(lane)
    if rewritten:
        body = request_body(req)
        assert (body["temperature"], body["top_k"]) == (0.01, 1)
    else:
        body = request_body(req)
        assert body["temperature"] == 0 and "top_k" not in body


def test_t0_follows_the_lane_after_an_overflow(gateway: Gateway) -> None:
    gateway.post("chat", temperature=0, fake={"npu": "overflow"})
    (npu,), (gpu,) = gateway.requests("npu"), gateway.requests("gpu")
    npu_body, gpu_body = request_body(npu), request_body(gpu)
    assert npu_body["temperature"] == 0 and "top_k" not in npu_body
    assert (gpu_body["temperature"], gpu_body["top_k"]) == (0.01, 1)


@pytest.mark.parametrize("model, lane", [("chat", "npu"), ("chat-long", "gpu")])
def test_a_nonzero_temperature_is_left_alone(gateway: Gateway, model: str, lane: str) -> None:
    gateway.post(model, temperature=0.7, top_k=40)
    (req,) = gateway.requests(lane)
    body = request_body(req)
    assert (body["temperature"], body["top_k"]) == (0.7, 40)


def test_power_mode_is_dropped_on_aliases_and_kept_on_raw_routes(gateway: Gateway) -> None:
    gateway.post("chat", power_mode="high")
    gateway.post("raw-npu", power_mode="high")
    alias, raw = gateway.requests("npu")
    assert "power_mode" not in request_body(alias)
    assert request_body(raw)["power_mode"] == "high"


def test_a_stream_is_forced_to_report_usage(gateway: Gateway) -> None:
    reply = gateway.post("chat", stream=True)
    (req,) = gateway.requests("npu")
    assert request_body(req)["stream_options"] == {"include_usage": True}
    usage = [e for e in reply.sse() if e != "[DONE]" and e.get("usage")]
    assert len(usage) == 1 and usage[0]["choices"] == []


def test_sse_passes_chunk_by_chunk_and_unchanged(gateway: Gateway) -> None:
    reply = gateway.post("chat", stream=True, fake={"npu": "gap=0.4"})
    assert reply.status == 200 and reply.error is None
    (sent,) = gateway.lanes["npu"].sent
    assert reply.body == sent, "the gateway forwards the lane's SSE bytes as they are"
    first_data = next(t for t, c in reply.chunks if b"data:" in c)
    assert reply.chunks[-1][0] - first_data > 2.0, "events arrive as they are made, not at the end"


def test_completions_ride_the_passthrough_with_the_lane_model(gateway: Gateway) -> None:
    reply = gateway.post("chat", path="/v1/completions", prompt="Say hi", messages=None)
    assert reply.status == 200
    (req,) = gateway.requests("npu")
    assert req.path in ("/v1/completions", "/v1/completions?"), "lua-resty-http appends a bare '?'"
    assert request_body(req)["model"] == gateway.lanes_models["npu"]


def test_tool_calls_come_back_untouched(gateway: Gateway) -> None:
    reply = gateway.post("chat", tools=TOOLS, fake={"npu": "toolcall"})
    call_ = reply.json()["choices"][0]["message"]["tool_calls"][0]
    assert call_["function"] == {"name": "get_weather", "arguments": "{\"city\":\"Berlin\"}"}
    (line,) = gateway.log.lines()
    assert line["tool_calls"] == "true" and line["tools"] == 1


def test_bodies_reach_the_lane_with_sorted_keys(gateway: Gateway) -> None:
    raw = json.dumps({"model": "raw-npu", "messages": [{"role": "user", "content": "hi"}],
                      "tools": [{"type": "function", "function": {"parameters": {}, "name": "z"}}]})
    call(gateway.port, "/v1/chat/completions", raw=raw.encode(), key=gateway.keys["lab"])
    (req,) = gateway.requests("npu")
    text = req.raw.decode()
    assert text.index('"messages"') < text.index('"model"') < text.index('"tools"')
    assert text.index('"name"') < text.index('"parameters"'), "raw-* is not byte-transparent"


def test_a_shaped_body_keeps_every_number_exact(gateway: Gateway) -> None:
    """geniex-shape re-encodes the body when it adds the prompt or drops power_mode."""
    gateway.post("chat", tools=TOOLS, power_mode="high", seed=123456789012345,
                 top_p=0.1234567890123457)
    (req,) = gateway.requests("npu")
    body = request_body(req)
    assert "power_mode" not in body and first_message(req)["content"] == PROMPT_TEXT
    assert body["seed"] == 123456789012345, req.raw
    assert body["top_p"] == 0.1234567890123457, req.raw


TOOL_DESCRIPTION = "Stellt einen Timer \u2013 \u00abminutes\u00bb \u2265 1"
RICH_TOOL: JsonValue = {"type": "function", "function": {
    "name": "set_timer", "description": TOOL_DESCRIPTION,
    "parameters": {"type": "object",
                   "properties": {"zeta": {"type": "number", "minimum": 1.0, "default": 2.5},
                                  "alpha": {"type": "string", "enum": ["b", "a"]},
                                  "opts": {"type": "object", "properties": {}}},
                   "required": []}}}


@pytest.mark.parametrize("model", ["raw-npu", "chat"])
def test_tool_definitions_keep_their_meaning_not_their_bytes(gateway: Gateway, model: str) -> None:
    """What Stage A has to control for: the lane sees the same tools, re-encoded."""
    gateway.post(model, tools=[RICH_TOOL])
    (req,) = gateway.requests("npu")
    assert request_body(req)["tools"] == [RICH_TOOL], "same meaning after a JSON decode"
    text = req.raw.decode()
    props = text[text.index('"properties"'):]
    assert props.index('"alpha"') < props.index('"opts"') < props.index('"zeta"'), "keys sorted"
    assert '"enum":["b","a"]' in text, "array order is kept"
    assert '"properties":{}' in text and '"required":[]' in text, "empty object and array survive"
    assert '"minimum":1,' in text, "a whole-number float loses its .0"
    assert TOOL_DESCRIPTION in text, "non-ASCII goes out as UTF-8"
