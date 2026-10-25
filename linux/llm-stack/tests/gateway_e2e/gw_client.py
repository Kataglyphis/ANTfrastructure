"""Client helpers for the gateway e2e tests: one request, read chunk by chunk, and the log tail."""
import http.client
import json
import os
import time


class Reply:
    def __init__(self, status, headers, chunks, error, elapsed) -> None:
        self.status = status
        self.headers = {k.lower(): v for k, v in headers}
        self.chunks = chunks
        self.body = b"".join(c for _, c in chunks)
        self.error = error
        self.elapsed = elapsed

    def json(self):
        return json.loads(self.body)

    def sse(self):
        """The data: payloads of an SSE body, [DONE] included as a string."""
        out = []
        for line in self.body.decode().splitlines():
            if line.startswith("data: "):
                data = line[len("data: "):]
                out.append(data if data == "[DONE]" else json.loads(data))
        return out


def call(port, path, body=None, key=None, headers=None, method="POST", timeout=30,
         raw=None, content_type="application/json"):
    conn = http.client.HTTPConnection("127.0.0.1", port, timeout=timeout)
    sent = {}
    data = raw if raw is not None else (json.dumps(body).encode() if body is not None else None)
    if data is not None and content_type:
        sent["Content-Type"] = content_type
    if key:
        sent["Authorization"] = f"Bearer {key}"
    sent.update(headers or {})
    t0 = time.monotonic()
    conn.request(method, path, body=data, headers=sent)
    resp = conn.getresponse()
    chunks, error = [], None
    try:
        while True:
            piece = resp.read1(65536)
            if not piece:
                break
            chunks.append((time.monotonic() - t0, piece))
    except (http.client.IncompleteRead, ConnectionError, OSError) as exc:
        error = exc
    conn.close()
    return Reply(resp.status, resp.getheaders(), chunks, error, time.monotonic() - t0)


class LogTail:
    """New lines of the gateway's JSON request log since the last mark()."""

    def __init__(self, path) -> None:
        self.path = path
        self.offset = 0

    def _size(self) -> int:
        return os.path.getsize(self.path) if os.path.exists(self.path) else 0

    def mark(self):
        self.offset = self._size()

    def lines(self, expect=1, timeout=5.0, settle=0.4, *, predicate=None):
        def matching() -> list[dict[str, object]]:
            lines = self._read()
            return [line for line in lines if predicate(line)] if predicate else lines

        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline and len(matching()) < expect:
            time.sleep(0.1)
        time.sleep(settle)
        return matching()

    def _read(self) -> list[dict[str, object]]:
        if not os.path.exists(self.path):
            return []
        with open(self.path, "rb") as fh:
            fh.seek(self.offset)
            text = fh.read().decode()
        return [json.loads(line) for line in text.splitlines() if line.strip()]
