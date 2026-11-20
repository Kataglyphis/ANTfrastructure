"""Complete synthetic intervals for profile checks; these events establish no real inference."""


def profile_runs(starts: tuple[int, ...] = (10, 30), pid: int = 1) -> list[dict[str, object]]:
    return [
        {"name": "model_run", "cat": "Session", "ph": "X", "pid": pid, "ts": start, "dur": 10}
        for start in starts
    ]


def profile_node(
    start: int, provider: str = "CUDAExecutionProvider", name: str = "Conv", pid: int = 1,
) -> dict[str, object]:
    return {"cat": "Node", "ph": "X", "pid": pid, "ts": start, "dur": 2,
            "args": {"provider": provider, "op_name": name}}
