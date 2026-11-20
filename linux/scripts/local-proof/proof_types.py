"""Describe dynamic JSON receipts and the canonical probe callbacks at their shared boundary."""

from collections.abc import Callable
from typing import Any

Json = dict[str, Any]
Helpers = dict[str, Callable[..., Any]]
NativeLayout = tuple[str, Json, Json]
Edit = Callable[[Json], object]
