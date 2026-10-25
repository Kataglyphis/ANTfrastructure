"""A fake GenieX lane: an OpenAI-compatible server the gateway e2e tests point at.

It records every request it receives (path, headers, parsed body) and answers the
way the request's `X-Fake-<Lane>` header asks, so one request can make the NPU
refuse an overflow while the GPU answers normally. Directives, comma-separated:

  ok (default)   a chat or completion reply; SSE when the body says stream:true
  overflow       400 context_length_exceeded, streamed request or not
  badreq         400 with some other error code
  status=N       an N error with a JSON body
  reset          read the request, then drop the connection without a reply
  hold=S         wait S seconds before the first byte
  crash=N        stream N events (or half a JSON body), then drop the connection
  gap=S          seconds between SSE events (default 0.05)
  toolcall       answer with a tool call
"""
from __future__ import annotations

import json
import socket
import struct
import threading
import time
from collections.abc import Mapping
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

from gw_harness import JsonValue

type JsonObject = dict[str, JsonValue]
type Directive = str | bool

OVERFLOW: JsonObject = {"error": {"message": "This model's maximum context length is 4096 tokens. "
                                           "However, your messages resulted in 5120 tokens.",
                                "type": "invalid_request_error", "param": "messages",
                                "code": "context_length_exceeded"}}
BADREQ: JsonObject = {"error": {"message": "temperature must be between 0 and 2",
                                "type": "invalid_request_error", "param": "temperature", "code": "invalid_value"}}


def parse_directives(value: str | None) -> dict[str, Directive]:
    out: dict[str, Directive] = {}
    for part in (value or "").split(","):
        part = part.strip()
        if part:
            key, _, arg = part.partition("=")
            out[key] = arg or True
    return out


class Received:
    method: str
    path: str
    headers: dict[str, str]
    raw: bytes
    body: JsonValue | None
    at: float

    def __init__(self, method: str, path: str, headers: Mapping[str, str], raw: bytes) -> None:
        self.method, self.path, self.raw = method, path, raw
        self.headers = {k.lower(): v for k, v in headers.items()}
        try:
            self.body = json.loads(raw) if raw else None
        except ValueError:
            self.body = None
        self.at = time.monotonic()


class FakeLane:
    name: str
    requests: list[Received]
    sent: list[bytes]
    lock: threading.Lock
    server: ThreadingHTTPServer
    port: int
    thread: threading.Thread

    def __init__(self, name: str) -> None:
        self.name = name
        self.requests = []
        self.sent = []
        self.lock = threading.Lock()
        self.server = ThreadingHTTPServer(("127.0.0.1", 0), _handler_for(self))
        self.server.daemon_threads = True
        self.port = self.server.server_address[1]
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)

    def start(self) -> FakeLane:
        self.thread.start()
        return self

    def stop(self) -> None:
        self.server.shutdown()
        self.server.server_close()

    def reset(self) -> None:
        with self.lock:
            self.requests.clear()
            self.sent.clear()

    def record(self, received: Received) -> int:
        with self.lock:
            self.requests.append(received)
            return len(self.requests)

    def completions(self) -> list[Received]:
        with self.lock:
            return [r for r in self.requests if r.method == "POST"]


def _chat_reply(lane: FakeLane, n: int, body: JsonObject,
                directives: dict[str, Directive]) -> JsonObject:
    message: JsonObject = {"role": "assistant", "content": f"lane={lane.name} n={n}"}
    if "toolcall" in directives:
        message = {"role": "assistant", "content": None, "tool_calls": [{
            "id": f"call_{n}", "type": "function",
            "function": {"name": "get_weather", "arguments": "{\"city\":\"Berlin\"}"}}]}
    usage: JsonObject = {"prompt_tokens": 40 + n, "completion_tokens": 3, "total_tokens": 43 + n}
    return {"id": f"fake-{lane.name}-{n}", "object": "chat.completion", "created": 0,
            "model": body.get("model"), "choices": [{"index": 0, "message": message,
                                                     "finish_reason": "stop"}], "usage": usage}


def _completion_reply(lane: FakeLane, n: int, body: JsonObject) -> JsonObject:
    return {"id": f"fake-{lane.name}-{n}", "object": "text_completion", "created": 0,
            "model": body.get("model"), "choices": [{"index": 0, "text": f" lane={lane.name}",
                                                     "finish_reason": "stop"}],
            "usage": {"prompt_tokens": 5, "completion_tokens": 3, "total_tokens": 8}}


def _sse_events(lane: FakeLane, n: int, body: JsonObject) -> list[bytes]:
    base: JsonObject = {"id": f"fake-{lane.name}-{n}", "object": "chat.completion.chunk", "created": 0,
                        "model": body.get("model")}
    deltas: list[JsonObject] = [{"role": "assistant", "content": ""}]
    deltas.extend({"content": f"tok{i} "} for i in range(3))
    events: list[JsonObject] = [dict(base, choices=[{"index": 0, "delta": d, "finish_reason": None}])
                                for d in deltas]
    events.append(dict(base, choices=[{"index": 0, "delta": {}, "finish_reason": "stop"}]))
    stream_options = body.get("stream_options")
    if isinstance(stream_options, dict) and stream_options.get("include_usage"):
        events.append(dict(base, choices=[], usage={"prompt_tokens": 40 + n, "completion_tokens": 3,
                                                    "total_tokens": 43 + n}))
    return [b"data: " + json.dumps(e).encode() + b"\n\n" for e in events] + [b"data: [DONE]\n\n"]


class _FakeLaneHandler(BaseHTTPRequestHandler):
    lane: FakeLane
    protocol_version = "HTTP/1.1"

    def log_message(self, format: str, *args: object) -> None:
        pass

    def do_GET(self) -> None:
        self.lane.record(Received("GET", self.path, dict(self.headers), b""))
        self._json(404, {"error": {"message": "the fake lane expects no GET", "code": "no_get"}})

    def do_POST(self) -> None:
        raw = self.rfile.read(int(self.headers.get("Content-Length") or 0))
        received = Received("POST", self.path, dict(self.headers), raw)
        n = self.lane.record(received)
        directives = parse_directives(self.headers.get(f"X-Fake-{self.lane.name.capitalize()}"))
        body = received.body
        try:
            self._answer(n, body if isinstance(body, dict) else {}, directives)
        except (BrokenPipeError, ConnectionResetError):
            pass

    def _answer(self, n: int, body: JsonObject, directives: dict[str, Directive]) -> None:
        if "hold" in directives:
            time.sleep(float(directives["hold"]))
        if "reset" in directives:
            self._drop()
            return
        if "overflow" in directives:
            return self._json(400, OVERFLOW)
        if "badreq" in directives:
            return self._json(400, BADREQ)
        if "status" in directives:
            return self._json(int(directives["status"]), {"error": {"message": "fake failure"}})
        if body.get("stream"):
            return self._stream(n, body, directives)
        reply = (_completion_reply(self.lane, n, body) if self.path.endswith("/v1/completions")
                 else _chat_reply(self.lane, n, body, directives))
        return self._json(200, reply, crash="crash" in directives)

    def _json(self, status: int, obj: JsonValue, crash: bool = False) -> None:
        data = json.dumps(obj).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        if crash:
            self.wfile.write(data[: len(data) // 2])
            self._drop()
            return
        self.wfile.write(data)

    def _stream(self, n: int, body: JsonObject, directives: dict[str, Directive]) -> None:
        events = _sse_events(self.lane, n, body)
        gap = float(directives.get("gap", 0.05))
        crash = int(directives["crash"]) if "crash" in directives else None
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("Transfer-Encoding", "chunked")
        self.end_headers()
        sent = []
        for i, event in enumerate(events):
            if crash is not None and i >= crash:
                self._drop()
                return
            self.wfile.write(b"%x\r\n%s\r\n" % (len(event), event))
            sent.append(event)
            time.sleep(gap)
        self.wfile.write(b"0\r\n\r\n")
        with self.lane.lock:
            self.lane.sent.append(b"".join(sent))

    def _drop(self) -> None:
        self.close_connection = True
        try:
            self.connection.setsockopt(socket.SOL_SOCKET, socket.SO_LINGER, struct.pack("ii", 1, 0))
            self.connection.shutdown(socket.SHUT_RDWR)
        except OSError:
            pass


def _handler_for(lane: FakeLane) -> type[BaseHTTPRequestHandler]:
    class Handler(_FakeLaneHandler):
        pass

    Handler.lane = lane
    return Handler
