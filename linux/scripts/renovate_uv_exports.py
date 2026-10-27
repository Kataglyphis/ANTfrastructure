"""Validate declared uv compatibility exports inside a Renovate target."""

import json
from pathlib import Path

CONFIG = ".github/renovate-uv-exports.json"


def _relative(value: object, *, project: bool) -> str:
    if not isinstance(value, str) or not value or any(c in value for c in "\\\t\r\n|"):
        raise ValueError("uv export paths must be nonempty portable relative paths")
    if value == "." and project:
        return value
    if value.startswith("/") or ":" in value or any(part in ("", ".", "..") for part in value.split("/")):
        raise ValueError(f"invalid uv export path: {value!r}")
    return value


def _inside(root: Path, relative: str) -> Path:
    path = root / relative
    parts = Path(relative).parts
    has_symlink = any(root.joinpath(*parts[:index]).is_symlink() for index in range(1, len(parts) + 1))
    if not path.resolve().is_relative_to(root) or has_symlink or not path.is_file():
        raise ValueError(f"uv export input or output is missing or outside the repository: {relative}")
    return path


def rows(root: str) -> list[tuple[str, str]]:
    """Return validated project/output pairs; absent configuration declares no exports."""
    base = Path(root).resolve()
    config = base / CONFIG
    if not config.exists() and not config.is_symlink():
        return []
    _inside(base, CONFIG)
    data = json.loads(config.read_text(encoding="utf-8"))
    if not isinstance(data, dict) or set(data) != {"exports"} or not isinstance(data["exports"], list):
        raise ValueError("uv export configuration must contain only an exports array")
    result: list[tuple[str, str]] = []
    outputs: set[str] = set()
    inputs = {CONFIG}
    for entry in data["exports"]:
        if not isinstance(entry, dict) or set(entry) != {"project", "output"}:
            raise ValueError("each uv export needs exactly project and output")
        project = _relative(entry["project"], project=True)
        output = _relative(entry["output"], project=False)
        prefix = "" if project == "." else f"{project}/"
        _inside(base, f"{prefix}pyproject.toml")
        _inside(base, f"{prefix}uv.lock")
        _inside(base, output)
        inputs.update((f"{prefix}pyproject.toml", f"{prefix}uv.lock"))
        if output in outputs:
            raise ValueError(f"duplicate or unsafe uv export output: {output}")
        outputs.add(output)
        result.append((project, output))
    if outputs & inputs:
        raise ValueError(f"uv export output overlaps a configured input: {sorted(outputs & inputs)}")
    return result
