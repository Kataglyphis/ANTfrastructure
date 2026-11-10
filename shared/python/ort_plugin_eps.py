"""Register optional ORT plugin libraries in their owning Python binding."""

from __future__ import annotations

import os
import sys
import threading
import weakref
from collections.abc import Mapping, Sequence
from dataclasses import dataclass
from pathlib import Path
from typing import Protocol


class PluginDevice(Protocol):
    """A device reported by ORT's plugin enumeration."""

    @property
    def ep_name(self) -> str:
        """The registered factory's execution-provider name."""
        ...


class RuntimeBinding(Protocol):
    """The owning ONNX Runtime module, passed rather than imported implicitly."""

    __file__: str

    def register_execution_provider_library(
        self, name: str, library_path: str, /
    ) -> None:
        """Register a library in this binding's environment."""
        ...

    def get_ep_devices(self) -> Sequence[PluginDevice]:
        """Enumerate devices from the registered factories."""
        ...


@dataclass(frozen=True)
class PluginLibrary:
    """One plugin's image contract and its bundled library filename."""

    name: str
    root_variable: str
    linux_filename: str
    windows_filename: str


MIGRAPHX = PluginLibrary(
    "MIGraphX", "ORT_AMDGPU_EP_ROOT", "libmigraphx-ep.so", "migraphx-ep.dll"
)
_LOCK = threading.RLock()
_REGISTERED: weakref.WeakKeyDictionary[RuntimeBinding, dict[str, Path]] = (
    weakref.WeakKeyDictionary()
)


def plugin_library_path(
    binding: RuntimeBinding,
    plugin: PluginLibrary = MIGRAPHX,
    *,
    environ: Mapping[str, str] | None = None,
) -> Path | None:
    """Prefer an advertised image root; otherwise use the module beside bundled ORT."""
    settings = os.environ if environ is None else environ
    windows = sys.platform == "win32"
    filename = plugin.windows_filename if windows else plugin.linux_filename
    root_value = settings.get(plugin.root_variable, "")
    if root_value:
        root = Path(root_value)
        if not root.is_absolute():
            raise ValueError(
                f"{plugin.root_variable} must be an absolute directory: {root}"
            )
        root = root.resolve(strict=True)
        if not root.is_dir():
            raise NotADirectoryError(
                f"{plugin.root_variable} is not a directory: {root}"
            )
        path = root / filename if windows else root / "lib" / filename
        path = path.resolve(strict=True)
        if not path.is_file():
            raise FileNotFoundError(f"{plugin.name} plugin is not a file: {path}")
        return path
    module_file = getattr(binding, "__file__", None)
    if not module_file:
        return None
    module = Path(module_file)
    if not module.is_absolute():
        raise ValueError(
            f"The owning ONNX Runtime module path must be absolute: {module}"
        )
    path = module.resolve().parent / "capi" / filename
    if not path.exists() and not path.is_symlink():
        return None
    path = path.resolve(strict=True)
    if not path.is_file():
        raise FileNotFoundError(f"{plugin.name} bundled plugin is not a file: {path}")
    return path


def register_plugin_library(
    binding: RuntimeBinding,
    plugin: PluginLibrary = MIGRAPHX,
    *,
    environ: Mapping[str, str] | None = None,
) -> Path | None:
    """Register once per binding and name; failed calls remain retryable."""
    path = plugin_library_path(binding, plugin, environ=environ)
    if path is None:
        return None
    with _LOCK:
        previous = _REGISTERED.get(binding, {}).get(plugin.name)
        if previous is not None:
            if previous != path:
                raise RuntimeError(
                    f"{plugin.name} is already registered from {previous}, refusing {path}"
                )
            return previous
        register = getattr(binding, "register_execution_provider_library", None)
        if not callable(register):
            raise TypeError(
                f"The owning ONNX Runtime binding cannot register {plugin.name}"
            )
        register(plugin.name, str(path))
        _REGISTERED.setdefault(binding, {})[plugin.name] = path
    return path


def registered_plugin_names(binding: RuntimeBinding) -> tuple[str, ...]:
    """Report only libraries this helper successfully registered in this binding."""
    with _LOCK:
        return tuple(sorted(_REGISTERED.get(binding, {})))


def select_plugin_device(
    binding: RuntimeBinding,
    device_index: int = 0,
    plugin: PluginLibrary = MIGRAPHX,
    *,
    environ: Mapping[str, str] | None = None,
) -> PluginDevice | None:
    """Select one matching runtime-enumerated device, without caching availability."""
    if device_index < 0:
        raise ValueError(f"GPU device index must be non-negative: {device_index}")
    if register_plugin_library(binding, plugin, environ=environ) is None:
        return None
    devices = [
        device for device in binding.get_ep_devices() if device.ep_name == plugin.name
    ]
    if device_index >= len(devices):
        raise RuntimeError(
            f"{plugin.name} device index {device_index} is unavailable; found {len(devices)}"
        )
    return devices[device_index]
