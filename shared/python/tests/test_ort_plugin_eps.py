"""Prove registration, argument and concurrency policy using fake bindings, not real ORT or GPU inference."""

import os
import sys
import tempfile
import time
import unittest
from concurrent.futures import ThreadPoolExecutor
from dataclasses import dataclass
from pathlib import Path
from unittest.mock import patch

from shared.python import ort_plugin_eps as plugin


@dataclass(frozen=True)
class Device:
    ep_name: str


class Binding:
    def __init__(self, module: Path) -> None:
        self.__file__ = str(module)
        self.calls: list[tuple[str, str]] = []
        self.devices: list[Device] = []
        self.device_calls = 0
        self.failures = 0
        self.delay = 0.0

    def register_execution_provider_library(self, name: str, path: str) -> None:
        self.calls.append((name, path))
        time.sleep(self.delay)
        if self.failures:
            self.failures -= 1
            raise RuntimeError("native registration failed")

    def get_ep_devices(self) -> list[Device]:
        self.device_calls += 1
        return self.devices

    def get_available_providers(self) -> list[str]:
        raise AssertionError("compile-time providers do not discover plugin devices")


class RegistrationTest(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory(prefix="ort plugin fixture ")
        self.root = Path(self.temporary.name).resolve()
        module = self.root / "bundle" / "onnxruntime" / "__init__.py"
        module.parent.mkdir(parents=True)
        module.write_text("")
        self.binding = Binding(module)
        self.image = self.root / "image root"
        self.settings = {plugin.MIGRAPHX.root_variable: str(self.image)}

    def tearDown(self) -> None:
        self.temporary.cleanup()

    def image_library(self, windows: bool | None = None) -> Path:
        windows = sys.platform == "win32" if windows is None else windows
        relative = Path("migraphx-ep.dll") if windows else Path("lib/libmigraphx-ep.so")
        path = self.image / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(b"fake library for argument tests")
        return path.resolve()

    def bundled_library(self) -> Path:
        filename = (
            plugin.MIGRAPHX.windows_filename
            if sys.platform == "win32"
            else plugin.MIGRAPHX.linux_filename
        )
        path = Path(self.binding.__file__).parent / "capi" / filename
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(b"fake bundled library")
        return path.resolve()

    def test_absent_and_empty_root_leave_cpu_binding_untouched(self) -> None:
        for settings in ({}, {plugin.MIGRAPHX.root_variable: ""}):
            with self.subTest(settings=settings):
                self.assertIsNone(
                    plugin.register_plugin_library(self.binding, environ=settings)
                )
                self.assertIsNone(
                    plugin.select_plugin_device(self.binding, environ=settings)
                )
        self.assertEqual(self.binding.calls, [])
        self.assertEqual(self.binding.device_calls, 0)
        self.assertEqual(plugin.registered_plugin_names(self.binding), ())

    def test_explicit_root_wins_over_bundle(self) -> None:
        expected = self.image_library()
        self.bundled_library()
        self.assertEqual(
            plugin.register_plugin_library(self.binding, environ=self.settings),
            expected,
        )
        self.assertEqual(self.binding.calls, [("MIGraphX", str(expected))])
        self.assertEqual(plugin.registered_plugin_names(self.binding), ("MIGraphX",))
        self.assertEqual(self.binding.device_calls, 0)

    def test_bundle_is_registered_without_image_environment(self) -> None:
        expected = self.bundled_library()
        self.assertEqual(
            plugin.register_plugin_library(self.binding, environ={}), expected
        )
        self.assertEqual(self.binding.calls, [("MIGraphX", str(expected))])

    def test_default_environment_uses_the_same_explicit_contract(self) -> None:
        expected = self.image_library()
        with patch.dict(os.environ, self.settings, clear=True):
            self.assertEqual(plugin.register_plugin_library(self.binding), expected)
        self.assertEqual(self.binding.calls, [("MIGraphX", str(expected))])

    def test_both_image_layouts_preserve_absolute_paths_with_spaces(self) -> None:
        for platform in ("linux", "win32"):
            with (
                self.subTest(platform=platform),
                patch.object(plugin.sys, "platform", platform),
            ):
                expected = self.image_library(windows=platform == "win32")
                self.assertEqual(
                    plugin.plugin_library_path(self.binding, environ=self.settings),
                    expected,
                )

    def test_missing_advertised_root_never_uses_bundled_fallback(self) -> None:
        self.bundled_library()
        with self.assertRaises(FileNotFoundError):
            plugin.register_plugin_library(self.binding, environ=self.settings)
        self.assertEqual(self.binding.calls, [])

    def test_missing_advertised_library_never_uses_bundled_fallback(self) -> None:
        self.bundled_library()
        self.image.mkdir()
        with self.assertRaises(FileNotFoundError):
            plugin.register_plugin_library(self.binding, environ=self.settings)
        self.assertEqual(plugin.registered_plugin_names(self.binding), ())

    def test_relative_advertisement_refuses_before_registering(self) -> None:
        self.bundled_library()
        with self.assertRaisesRegex(ValueError, "absolute directory"):
            plugin.register_plugin_library(
                self.binding, environ={plugin.MIGRAPHX.root_variable: "relative root"}
            )
        self.assertEqual(self.binding.calls, [])

    def test_file_cannot_be_an_advertised_root(self) -> None:
        self.image.write_bytes(b"not a directory")
        with self.assertRaisesRegex(
            NotADirectoryError, "ORT_AMDGPU_EP_ROOT is not a directory"
        ):
            plugin.register_plugin_library(self.binding, environ=self.settings)
        self.assertEqual(self.binding.calls, [])

    def test_directory_cannot_be_a_plugin_module(self) -> None:
        path = self.image_library()
        path.unlink()
        path.mkdir()
        with self.assertRaises(FileNotFoundError):
            plugin.register_plugin_library(self.binding, environ=self.settings)
        self.assertEqual(self.binding.calls, [])

    def test_relative_binding_path_refuses_bundle_discovery(self) -> None:
        self.binding.__file__ = "onnxruntime/__init__.py"
        with self.assertRaisesRegex(ValueError, "module path must be absolute"):
            plugin.register_plugin_library(self.binding, environ={})

    def test_missing_api_cannot_create_a_successful_registration(self) -> None:
        self.image_library()
        with (
            patch.object(self.binding, "register_execution_provider_library", None),
            self.assertRaisesRegex(TypeError, "cannot register MIGraphX"),
        ):
            plugin.register_plugin_library(self.binding, environ=self.settings)
        self.assertEqual(plugin.registered_plugin_names(self.binding), ())

    def test_failed_native_call_is_not_cached_and_can_retry(self) -> None:
        expected = self.image_library()
        self.binding.failures = 1
        with self.assertRaisesRegex(RuntimeError, "native registration failed"):
            plugin.register_plugin_library(self.binding, environ=self.settings)
        self.assertEqual(plugin.registered_plugin_names(self.binding), ())
        for _ in range(2):
            self.assertEqual(
                plugin.register_plugin_library(self.binding, environ=self.settings),
                expected,
            )
        self.assertEqual(self.binding.calls, [("MIGraphX", str(expected))] * 2)

    def test_concurrent_repeated_sessions_register_once(self) -> None:
        expected = self.image_library()
        self.binding.delay = 0.01

        def register(_: int) -> Path | None:
            return plugin.register_plugin_library(self.binding, environ=self.settings)

        with ThreadPoolExecutor(max_workers=8) as workers:
            self.assertEqual(list(workers.map(register, range(64))), [expected] * 64)
        self.assertEqual(self.binding.calls, [("MIGraphX", str(expected))])

    def test_caches_are_separate_for_the_owning_bindings(self) -> None:
        expected = self.image_library()
        other = Binding(Path(self.binding.__file__))
        for binding in (self.binding, other):
            plugin.register_plugin_library(binding, environ=self.settings)
            self.assertEqual(binding.calls, [("MIGraphX", str(expected))])

    def test_same_name_cannot_silently_change_registered_module(self) -> None:
        original = self.image_library()
        plugin.register_plugin_library(self.binding, environ=self.settings)
        self.image = self.root / "different image"
        self.image_library()
        with self.assertRaisesRegex(RuntimeError, "already registered"):
            plugin.register_plugin_library(
                self.binding, environ={plugin.MIGRAPHX.root_variable: str(self.image)}
            )
        self.assertEqual(self.binding.calls, [("MIGraphX", str(original))])

    def test_each_registration_name_is_tracked_independently(self) -> None:
        self.image_library()
        another = plugin.PluginLibrary(
            "Other",
            plugin.MIGRAPHX.root_variable,
            plugin.MIGRAPHX.linux_filename,
            plugin.MIGRAPHX.windows_filename,
        )
        for specification in (plugin.MIGRAPHX, another, plugin.MIGRAPHX):
            plugin.register_plugin_library(
                self.binding, specification, environ=self.settings
            )
        self.assertEqual(
            [name for name, _ in self.binding.calls], ["MIGraphX", "Other"]
        )
        self.assertEqual(
            plugin.registered_plugin_names(self.binding), ("MIGraphX", "Other")
        )

    def test_device_selection_uses_the_registered_name_and_requested_index(
        self,
    ) -> None:
        self.image_library()
        first, second = Device("MIGraphX"), Device("MIGraphX")
        self.binding.devices = [
            Device("CPUExecutionProvider"),
            first,
            Device("MIGraphXExecutionProvider"),
            second,
        ]
        self.assertIs(
            plugin.select_plugin_device(self.binding, 1, environ=self.settings), second
        )
        self.assertIs(
            plugin.select_plugin_device(self.binding, 0, environ=self.settings), first
        )
        self.assertEqual(len(self.binding.calls), 1)
        self.assertEqual(self.binding.device_calls, 2)

    def test_device_index_bounds_remain_explicit(self) -> None:
        self.image_library()
        with self.assertRaisesRegex(ValueError, "non-negative"):
            plugin.select_plugin_device(self.binding, -1, environ=self.settings)
        self.assertEqual(self.binding.calls, [])
        self.binding.devices = [Device("MIGraphX")]
        with self.assertRaisesRegex(RuntimeError, "index 1 is unavailable"):
            plugin.select_plugin_device(self.binding, 1, environ=self.settings)

    def test_unavailable_device_does_not_cache_failed_availability(self) -> None:
        self.image_library()
        with self.assertRaisesRegex(RuntimeError, "found 0"):
            plugin.select_plugin_device(self.binding, environ=self.settings)
        device = Device("MIGraphX")
        self.binding.devices = [device]
        self.assertIs(
            plugin.select_plugin_device(self.binding, environ=self.settings), device
        )
        self.assertEqual(len(self.binding.calls), 1)
        self.assertEqual(self.binding.device_calls, 2)


if __name__ == "__main__":
    unittest.main()
