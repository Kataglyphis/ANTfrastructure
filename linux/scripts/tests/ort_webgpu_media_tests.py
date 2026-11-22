"""Fake subprocesses and valid receipt fixtures cover transport, not an installed ORT factory or GPU."""
from __future__ import annotations

import argparse
import json
import shutil
import subprocess
import sys
import unittest
from pathlib import Path
from unittest.mock import patch

import ort_webgpu_runtime_tests as fixture

media = fixture.runtime.delivery.source_api("03-media/runtime/ort_webgpu_media.py", ("prove_media", "main"))


class MediaTests(unittest.TestCase):
    def setUp(self) -> None:
        self.built = fixture.RuntimeTests()
        self.built.setUp()
        self.addCleanup(self.built.doCleanups)
        self.root, self.prefix = self.built.root, self.built.prefix
        self.calls: list[list[str]] = []
        self.args = argparse.Namespace(prefix=[self.prefix], gil_python=Path("/gil interpreter"),
            ft_python=Path("/ft interpreter"), gil_wheels=self.root / "collected GIL", ft_wheels=self.root / "collected FT",
            numpy_version="2.5.4", source_ref="v1.31.1", work_dir=self.root / "retained proof", uv="test-uv",
            timeout=30, allow_network=False)
        for phase, pool in (("gil", self.args.gil_wheels), ("free-threaded", self.args.ft_wheels)):
            pool.mkdir()
            original = self.prefix / ("wheels" if phase == "gil" else "wheels-free-threaded")
            for wheel in original.glob("*.whl"):
                shutil.move(str(wheel), pool)
        self.original_run_logged = media.run_logged
        self.runner = self.enterContext(patch.object(media, "run_logged", side_effect=self.child))

    def child(self, command: list[str], log: Path, timeout: int) -> str:
        self.calls.append(command)
        if "--phase" in command:
            phase = command[command.index("--phase") + 1]
            return "WEBGPU-FACTORY OK: " + json.dumps({"phase": phase})
        return ""

    def test_every_phase_uses_canonical_child_and_its_collected_wheel(self) -> None:
        result = media.prove_media(self.args)
        self.assertEqual([row["phase"] for row in result["phases"]], ["native", "gil", "free-threaded"])
        children = [c for c in self.calls if "--phase" in c]
        self.assertTrue(all(c[1] == "-I" and c[2] == str(Path(media.runtime.__file__).resolve()) for c in children))
        self.assertTrue(all(c[c.index("--source-ref") + 1] == "v1.31.1" for c in children))
        self.assertTrue(all(c[c.index("--prefix") + 1] == str(self.prefix) for c in children))
        venvs = [c for c in self.calls if c[:2] == ["test-uv", "venv"]]
        self.assertEqual([c[3] for c in venvs], ["/gil interpreter", "/ft interpreter"])
        for phase, command in zip(("gil", "free-threaded"), [c for c in self.calls if "install" in c], strict=True):
            self.assertIn("--offline", command)
            self.assertIn("--no-deps", command)
            self.assertIn("--only-binary=:all:", command)
            self.assertIn("numpy==2.5.4", command)
            pool = self.args.gil_wheels if phase == "gil" else self.args.ft_wheels
            self.assertEqual(Path(command[-1]).parent, pool)
        self.assertTrue((self.args.work_dir / "receipt.json").is_file())

    def test_existing_output_is_refused_without_changing_its_evidence(self) -> None:
        self.args.work_dir.mkdir()
        saved = self.args.work_dir / "receipt.json"
        saved.write_text("previous evidence")
        with self.assertRaises(FileExistsError):
            media.prove_media(self.args)
        self.assertEqual(saved.read_text(), "previous evidence")
        self.runner.assert_not_called()

    def test_no_missing_or_unfinished_delivery_may_select_a_wheel(self) -> None:
        receipt = self.built.receipt()
        receipt["phases"]["gil"]["delivery_pending"] = {}
        self.built.save(receipt)
        with self.assertRaisesRegex(ValueError, "pending"):
            media.selected_wheel(self.prefix, self.args.gil_wheels, "gil", self.args.source_ref)
        with (patch.object(media.runtime, "completed_product", return_value=None),
              self.assertRaisesRegex(ValueError, "missing delivered")):
            media.selected_wheel(self.prefix, self.args.gil_wheels, "gil", self.args.source_ref)

    def test_foreign_source_or_missing_pool_does_not_fall_back_to_build_wheels(self) -> None:
        with self.assertRaisesRegex(ValueError, "source ref"):
            media.selected_wheel(self.prefix, self.args.gil_wheels, "gil", "foreign")
        with self.assertRaises(FileNotFoundError):
            media.selected_wheel(self.prefix, self.root / "absent", "gil", self.args.source_ref)

    def test_pending_delivery_prevents_install_and_a_final_receipt(self) -> None:
        receipt = self.built.receipt()
        receipt["phases"]["gil"]["delivery_pending"] = {}
        self.built.save(receipt)
        with self.assertRaisesRegex(ValueError, "pending"):
            media.prove_media(self.args)
        self.assertFalse(any("install" in command for command in self.calls))
        self.assertFalse((self.args.work_dir / "receipt.json").exists())

    def test_delivered_names_and_links_cannot_escape_the_selected_pool(self) -> None:
        for name in ("../foreign.whl", "/foreign.whl", "foreign.zip"):
            with (self.subTest(name=name), patch.object(media.runtime, "completed_product", return_value={"wheel": name}),
                  self.assertRaisesRegex(ValueError, "basename")):
                media.selected_wheel(self.prefix, self.args.gil_wheels, "gil", self.args.source_ref)
        wheel = next(self.args.gil_wheels.glob("*.whl"))
        other = self.root / wheel.name
        wheel.rename(other)
        wheel.symlink_to(other)
        with self.assertRaises(ValueError):
            media.selected_wheel(self.prefix, self.args.gil_wheels, "gil", self.args.source_ref)

    def test_zero_exit_without_one_matching_phase_verdict_is_not_success(self) -> None:
        for output in ("", 'WEBGPU-FACTORY OK: {}', 'WEBGPU-FACTORY OK: {"phase":"other"}',
                       'WEBGPU-FACTORY OK: {"phase":"native"}\nWEBGPU-FACTORY FAIL: bad',
                       'WEBGPU-FACTORY OK: {"phase":"native"}\nWEBGPU-FACTORY OK: {"phase":"native"}'):
            with (self.subTest(output=output), patch.object(media, "run_logged", return_value=output),
                  self.assertRaises(ValueError)):
                media.child_proof(Path(sys.executable), self.prefix, "native", self.args, self.root)

    def test_failed_child_keeps_partial_proof_and_raw_status_without_final_receipt(self) -> None:
        def failing(command: list[str], log: Path, timeout: int) -> str:
            if "--phase" in command and command[command.index("--phase") + 1] == "free-threaded":
                raise subprocess.CalledProcessError(42, command)
            return self.child(command, log, timeout)
        self.runner.side_effect = failing
        with patch.object(media, "arguments", return_value=self.args):
            self.assertEqual(media.main(), 42)
        self.assertTrue((self.args.work_dir / "0-native/proof.json").is_file())
        self.assertTrue((self.args.work_dir / "0-gil/proof.json").is_file())
        self.assertFalse((self.args.work_dir / "receipt.json").exists())

    def test_only_explicit_network_opt_in_removes_offline(self) -> None:
        self.args.allow_network = True
        media.prove_media(self.args)
        self.assertTrue(all("--offline" not in c for c in self.calls if "install" in c))

    def test_unpinned_dependencies_refuse_before_any_child(self) -> None:
        for value in ("", ">=2", "2.5.4 numpy", "2.5.4; extra"):
            self.args.numpy_version = value
            with self.subTest(value=value), self.assertRaisesRegex(ValueError, "exact NumPy"):
                media.prove_media(self.args)
        self.runner.assert_not_called()

    def test_unbounded_timeout_refuses_before_any_child(self) -> None:
        self.args.timeout = 0
        with self.assertRaisesRegex(ValueError, "positive"):
            media.prove_media(self.args)
        self.runner.assert_not_called()

    def test_real_child_failure_retains_both_streams_and_exact_argv(self) -> None:
        command = [sys.executable, "-c", "import sys;print('out');print('err',file=sys.stderr);sys.exit(42)"]
        log = self.root / "raw child"
        with self.assertRaises(subprocess.CalledProcessError) as failure:
            self.original_run_logged(command, log, 30)
        self.assertEqual(failure.exception.returncode, 42)
        self.assertEqual(log.with_suffix(".stdout.log").read_text(), "out\n")
        self.assertEqual(log.with_suffix(".stderr.log").read_text(), "err\n")
        self.assertEqual(json.loads(log.with_suffix(".argv.json").read_text()), command)

    def test_timeout_preserves_partial_streams_after_the_child_is_reaped(self) -> None:
        command = [sys.executable, "-c", "import sys,time;print('out',flush=True);print('err',file=sys.stderr,flush=True);time.sleep(5)"]
        log = self.root / "timed child"
        with self.assertRaises(subprocess.TimeoutExpired):
            self.original_run_logged(command, log, 1)
        self.assertEqual(log.with_suffix(".stdout.log").read_text(), "out\n")
        self.assertEqual(log.with_suffix(".stderr.log").read_text(), "err\n")


if __name__ == "__main__":
    unittest.main(argv=[sys.argv[0]])
