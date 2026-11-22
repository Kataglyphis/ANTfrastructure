#!/usr/bin/env python3
"""Exercise synthetic origin/PID refusals; fixtures do not prove GPU execution, file bytes or one ORT session."""

import hashlib
import json
import re
import runpy
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

from ort_profile_fixture import profile_node, profile_runs

SCRIPT = Path(__file__).resolve().parents[1] / "verify_ort_loader_trace.py"
PLUGIN = "libmigraphx-ep.so"
CORE = "libonnxruntime.so.1"


class LoaderTraceTest(unittest.TestCase):
    def setUp(self) -> None:
        temporary = tempfile.TemporaryDirectory(prefix="loader origins ")
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.bundle = self.root / "bundle lib"
        self.bundle.mkdir()
        self.prefix = self.root / "loader"
        self.profile = self.root / "profile.json"
        self.trace = self.root / "loader.1"
        self.write_profile()
        self.write_trace()

    def write_profile(self, provider: str = "MIGraphX", pid: int = 1, name: str = "Conv") -> None:
        events = profile_runs(pid=pid) + [profile_node(start, provider, name, pid) for start in (12, 32)]
        self.profile.write_text(json.dumps(events))

    def write_trace(self, paths: list[str] | None = None, pid: int = 1) -> None:
        if paths is None:
            paths = [str(self.bundle / CORE), str(self.bundle / PLUGIN)]
        self.trace.write_text("".join(f"{pid}:\tcalling init: {path}\n" for path in paths))

    def run_check(self, *extra: str, script: Path = SCRIPT) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            [sys.executable, "-I", str(script), "--trace-prefix", str(self.prefix),
             "--runtime-root", str(self.bundle), *extra],
            capture_output=True, text=True, check=False, timeout=20, cwd="/",
        )

    def gpu_check(self, *extra: str, script: Path = SCRIPT) -> subprocess.CompletedProcess[str]:
        return self.run_check("--profile", str(self.profile), "--device", "migraphx-plugin",
                              "--plugin", PLUGIN, *extra, script=script)

    def assert_refused(self, result: subprocess.CompletedProcess[str]) -> None:
        self.assertNotEqual(result.returncode, 0, result.stdout)
        self.assertNotIn("Traceback", result.stderr)

    def test_real_profile_api_binds_library_trace_to_process(self) -> None:
        result = self.gpu_check()
        self.assertEqual(result.returncode, 0, result.stderr)
        record = json.loads(result.stdout)
        self.assertEqual(record["profile_pid"], 1)
        self.assertEqual(record["profile_sha256"], hashlib.sha256(self.profile.read_bytes()).hexdigest())
        self.assertEqual(record["loaded"][PLUGIN], [str(self.bundle / PLUGIN)])
        self.write_profile("CPUExecutionProvider")
        result = self.run_check("--profile", str(self.profile), "--device", "cpu")
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_unbound_legacy_api_makes_no_profile_claim(self) -> None:
        result = self.run_check()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIsNone(json.loads(result.stdout)["profile_pid"])
        api = runpy.run_path(str(SCRIPT))["verify_loader_traces"]
        paths = api([self.trace], re.compile(re.escape(str(self.bundle))))
        self.assertEqual(paths["libonnxruntime.so"], [str(self.bundle / CORE)])

    def test_foreign_core_or_plugin_and_second_foreign_alias_fail(self) -> None:
        for library in (CORE, PLUGIN):
            with self.subTest(library=library):
                paths = [str(self.bundle / CORE), str(self.bundle / PLUGIN), f"/host/lib/{library}"]
                self.write_trace(paths)
                self.assert_refused(self.gpu_check())

    def test_both_required_libraries_must_be_observed(self) -> None:
        for library in (CORE, PLUGIN):
            with self.subTest(library=library):
                self.write_trace([str(self.bundle / library)])
                self.assert_refused(self.gpu_check())

    def test_other_process_cannot_supply_expected_origins(self) -> None:
        shutil.copyfile(self.trace, self.root / "loader.2")
        self.write_trace([f"/host/lib/{CORE}", f"/host/lib/{PLUGIN}"])
        self.assert_refused(self.gpu_check())
        self.trace.unlink()
        self.assert_refused(self.gpu_check())

    def test_content_pid_must_match_profile_and_trace_filename(self) -> None:
        self.write_trace(pid=2)
        self.assert_refused(self.gpu_check())
        self.write_trace()
        self.write_profile(pid=2)
        self.assert_refused(self.gpu_check())

    def test_unrelated_child_libraries_do_not_change_selected_process(self) -> None:
        with self.trace.open("a") as output:
            output.write("2:\tcalling init: /opt/rocm/lib/libamdhip64.so.7\n")
        result = self.gpu_check()
        self.assertEqual(result.returncode, 0, result.stderr)
        record = json.loads(result.stdout)
        self.assertEqual(record["profile_pid"], 1)
        self.assertEqual(set(record["loaded"]), {"libonnxruntime.so", PLUGIN})

    def test_foreign_or_malformed_selected_pid_fails_even_with_parent_records(self) -> None:
        for library in (CORE, PLUGIN):
            for prefix in ("2:", "", "1x:", "1: extra"):
                with self.subTest(library=library, prefix=prefix):
                    self.write_trace()
                    with self.trace.open("a") as output:
                        output.write(f"{prefix}\tcalling init: {self.bundle / library}\n")
                    self.assert_refused(self.gpu_check())

    def test_unrelated_child_cannot_replace_required_parent_library(self) -> None:
        for library in (CORE, PLUGIN):
            with self.subTest(library=library):
                self.write_trace([str(self.bundle / library)])
                with self.trace.open("a") as output:
                    output.write("2:\tcalling init: /opt/rocm/lib/libamdhip64.so.7\n")
                self.assert_refused(self.gpu_check())

    def test_profile_requires_every_sequential_run_on_requested_provider(self) -> None:
        self.write_profile("CPUExecutionProvider")
        self.assert_refused(self.gpu_check())
        self.write_profile(name="MemcpyFromHost")
        self.assert_refused(self.gpu_check())
        self.profile.write_text(json.dumps(profile_runs() + [profile_node(12, "MIGraphX")]))
        self.assert_refused(self.gpu_check())

    def test_registration_alone_is_not_inference(self) -> None:
        self.profile.write_text('[{"cat":"Session","args":{"provider":"MIGraphX"}}]')
        self.assert_refused(self.gpu_check())

    def test_lexical_escape_and_malformed_soname_fail(self) -> None:
        for path in (
            f"{self.bundle}/../{CORE}", f"{self.bundle}/./{CORE}",
            f"{self.bundle}//{CORE}", f"{self.bundle}/sub\\dir/{CORE}",
            f"{self.bundle}/libonnxruntime.so.wrong", CORE,
        ):
            with self.subTest(path=path):
                self.write_trace([path, str(self.bundle / PLUGIN)])
                self.assert_refused(self.gpu_check())

    def test_appimage_requires_exact_nonce_root_and_payload_subdir(self) -> None:
        expected = self.bundle / ("appimage_extracted_" + "a" * 32) / "usr/lib/oxidant/lib"
        extra = ("--appimage-subdir", "usr/lib/oxidant/lib")
        self.write_trace([str(expected / CORE), str(expected / PLUGIN)])
        result = self.gpu_check(*extra)
        self.assertEqual(result.returncode, 0, result.stderr)
        for folder in ("appimage_extracted_a/usr/lib/oxidant/lib",
                       "appimage_extracted_" + "a" * 32 + "/usr/lib/foreign/lib",
                       "extra/appimage_extracted_" + "a" * 32 + "/usr/lib/oxidant/lib"):
            self.write_trace([str(self.bundle / folder / CORE), str(self.bundle / folder / PLUGIN)])
            self.assert_refused(self.gpu_check(*extra))

    def test_linked_missing_empty_or_invalid_utf8_trace_fails(self) -> None:
        target = self.root / "saved trace"
        self.trace.rename(target)
        self.trace.symlink_to(target)
        self.assert_refused(self.gpu_check())
        self.trace.unlink()
        self.assert_refused(self.gpu_check())
        self.trace.write_bytes(b"")
        self.assert_refused(self.gpu_check())
        self.trace.write_bytes(b"\xff")
        self.assert_refused(self.gpu_check())

    def test_optional_live_resolution_checks_symlink_escape(self) -> None:
        outside = self.root / "foreign core"
        outside.write_bytes(b"ELF fixture only")
        (self.bundle / CORE).symlink_to(outside)
        (self.bundle / PLUGIN).write_bytes(b"ELF fixture only")
        self.assert_refused(self.gpu_check("--resolve-root", str(self.bundle)))
        (self.bundle / CORE).unlink()
        (self.bundle / CORE).write_bytes(outside.read_bytes())
        result = self.gpu_check("--resolve-root", str(self.bundle))
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_selected_profile_mode_requires_canonical_companion(self) -> None:
        copied = self.root / SCRIPT.name
        shutil.copyfile(SCRIPT, copied)
        self.assert_refused(self.gpu_check(script=copied))
        shutil.copyfile(SCRIPT.with_name("verify_ort_profile.py"), self.root / "verify_ort_profile.py")
        result = self.gpu_check(script=copied)
        self.assertEqual(result.returncode, 0, result.stderr)

    def parent_trace(self) -> None:
        (self.root / "bin").mkdir()
        for name in (CORE, PLUGIN):
            (self.bundle / name).write_bytes(b"ELF fixture only")
        self.write_trace([f"{self.root}/bin/../{self.bundle.name}/{name}" for name in (CORE, PLUGIN)])

    def test_parent_segments_require_live_resolution_and_retain_raw_paths(self) -> None:
        self.parent_trace()
        self.assert_refused(self.gpu_check())
        result = self.gpu_check("--resolve-root", str(self.bundle))
        self.assertEqual(result.returncode, 0, result.stderr)
        record = json.loads(result.stdout)
        self.assertEqual(record["loaded"]["libonnxruntime.so"],
                         [f"{self.root}/bin/../{self.bundle.name}/{CORE}"])
        (self.bundle / CORE).unlink()
        self.assert_refused(self.gpu_check("--resolve-root", str(self.bundle)))

    def test_parent_segments_cannot_hide_a_symlink_escape(self) -> None:
        self.parent_trace()
        outside = self.root / "outside"
        (outside / "bin").mkdir(parents=True)
        (outside / self.bundle.name).mkdir()
        for name in (CORE, PLUGIN):
            (outside / self.bundle.name / name).write_bytes(b"foreign ELF fixture only")
        (self.root / "bin").rmdir()
        (self.root / "bin").symlink_to(outside / "bin", target_is_directory=True)
        self.assert_refused(self.gpu_check("--resolve-root", str(self.bundle)))

    def test_bad_option_combinations_and_paths_are_refused(self) -> None:
        for extra in (("--profile", str(self.profile)), ("--device", "cpu"),
                      ("--min-runs", "0"), ("--plugin", "../outside.so"),
                      ("--plugin", PLUGIN, "--plugin", PLUGIN),
                      ("--runtime-root", "relative"), ("--appimage-subdir", "../escape")):
            with self.subTest(extra=extra):
                self.assert_refused(self.run_check(*extra))


if __name__ == "__main__":
    unittest.main()
