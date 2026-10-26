"""The RUN instructions of a Dockerfile, for the structural suites."""

from collections.abc import Iterator


def dockerfile_runs(path: str) -> Iterator[tuple[int, str]]:
    """Yield (1-based line, text) of each RUN with its backslash continuations and interleaved comments."""
    with open(path, encoding="utf-8") as handle:
        lines = handle.read().split("\n")
    i = 0
    while i < len(lines):
        if lines[i].startswith("RUN"):
            start = i
            while i + 1 < len(lines) and (lines[i].rstrip().endswith("\\") or lines[i].lstrip().startswith("#")):
                i += 1
            yield start + 1, "\n".join(lines[start:i + 1])
        i += 1
