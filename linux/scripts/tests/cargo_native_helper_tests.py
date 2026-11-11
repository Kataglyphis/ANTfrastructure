#!/usr/bin/env python3
"""Cargo selection/header/copy controls cannot prove a runnable target binary, linkage, package or GPU."""
from __future__ import annotations

import argparse
import copy
import importlib.util
import json
import os
import stat
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from typing import Any
from unittest.mock import patch

PACK = Path(__file__).resolve().parent.parent / "06-packaging"
sys.path.insert(0, str(PACK))
SPEC = importlib.util.spec_from_file_location("cargo_native_helper", PACK / "stage-cargo-native-helper.py")
assert SPEC is not None and SPEC.loader is not None
STAGER = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(STAGER)


class CargoNativeHelperTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory(prefix="cargo helper ")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name).resolve()
        self.out = self.root / "profile/build/package/out"
        self.out.mkdir(parents=True)
        self.destination = self.root / "bundle"
        self.destination.mkdir()
        self.base = Path(os.environ["TEST_CARGO_NATIVE_ELF"]).read_bytes()
        self.module = self.root / "libfixture.so"
        self.module.write_bytes(self.base)
        self.helper = self.out / "native-helper"
        self.helper.write_bytes(self.base)
        self.helper.chmod(0o755)
        self.package = "path+file:///fixture/helper#helper@1.0.0"
        self.rows: list[Any] = [
            {"reason": "build-script-executed", "package_id": self.package, "out_dir": str(self.out),
             "env": [["HELPER_NAME", self.helper.name], ["HELPER_PATH", str(self.helper)]]},
            {"reason": "compiler-artifact", "filenames": [str(self.module)], "profile": {"test": False}},
            {"reason": "build-finished", "success": True},
        ]
        self.messages = self.root / "cargo.jsonl"
        self.args = argparse.Namespace(messages=self.messages, module=self.module, destination=self.destination,
                                       package_id=self.package, name_env="HELPER_NAME", path_env="HELPER_PATH",
                                       target="x86_64-unknown-linux-gnu")

    def save(self) -> None:
        self.messages.write_text("".join(json.dumps(row) + "\n" for row in self.rows))

    def refuse(self, pattern: str) -> None:
        self.save()
        with self.assertRaisesRegex((ValueError, OSError, TypeError), pattern):
            STAGER.run(self.args)
        self.assertEqual(list(self.destination.iterdir()), [])

    def test_exact_helper_and_cli_name_with_spaces(self) -> None:
        self.save()
        command = [sys.executable, str(PACK / "stage-cargo-native-helper.py")]
        for key, value in vars(self.args).items():
            command.extend(["--" + key.replace("_", "-"), str(value)])
        result = subprocess.run(command, capture_output=True, text=True, check=False)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, "native-helper\n")
        target = self.destination / self.helper.name
        self.assertEqual(target.read_bytes(), self.base)
        self.assertEqual(stat.S_IMODE(target.stat().st_mode), 0o755)
        self.assertEqual([p.name for p in self.destination.iterdir()], [self.helper.name])

    def test_unrelated_stale_helper_is_never_selected(self) -> None:
        (self.root / self.helper.name).write_bytes(b"stale")
        self.save()
        self.assertEqual(STAGER.run(self.args), self.helper.name)
        self.assertEqual((self.destination / self.helper.name).read_bytes(), self.base)

    def test_failed_incomplete_empty_and_repeated_builds(self) -> None:
        valid = copy.deepcopy(self.rows)
        cases = [[], valid[:-1], [*valid, valid[-1]], [*valid, {"reason": "compiler-message"}]]
        failed = copy.deepcopy(valid)
        failed[-1]["success"] = False
        cases.append(failed)
        for rows in cases:
            with self.subTest(rows=rows):
                self.rows = rows
                self.refuse("successful build")

    def test_malformed_json_is_not_ignored(self) -> None:
        self.messages.write_text("not JSON\n")
        with self.assertRaises(ValueError):
            STAGER.run(self.args)
        self.assertEqual(list(self.destination.iterdir()), [])

    def test_message_schema_is_required(self) -> None:
        for row in (None, [], {"reason": 42}):
            with self.subTest(row=row):
                self.rows = [row]
                self.refuse("Invalid Cargo message")

    def test_one_exact_package_is_required(self) -> None:
        self.rows[0]["package_id"] += "-other"
        self.refuse("helper build script")

    def test_duplicate_build_script_is_refused(self) -> None:
        self.rows.insert(1, copy.deepcopy(self.rows[0]))
        self.refuse("helper build script")

    def test_one_exact_module_is_required(self) -> None:
        self.rows[1]["filenames"] = [str(self.root / "other.so")]
        self.refuse("selected native artifact")

    def test_duplicate_module_is_refused(self) -> None:
        self.rows.insert(2, copy.deepcopy(self.rows[1]))
        self.refuse("selected native artifact")

    def test_test_artifacts_cannot_be_packaged(self) -> None:
        self.rows[1]["profile"]["test"] = True
        self.refuse("test artifact")

    def test_duplicate_environment_is_refused(self) -> None:
        self.rows[0]["env"].append(["HELPER_NAME", self.helper.name])
        self.refuse("Duplicate Cargo helper environment")

    def test_invalid_environment_is_refused(self) -> None:
        self.rows[0]["env"] = [["HELPER_NAME", 42]]
        self.refuse("Invalid Cargo helper environment")

    def test_basenames_cannot_escape_destination(self) -> None:
        for name in ("", "../helper", "..", "/helper", "a\\helper"):
            with self.subTest(name=name):
                self.rows[0]["env"][0][1] = name
                self.refuse("Invalid native helper basename")

    def test_path_must_match_the_reported_out_dir(self) -> None:
        self.rows[0]["env"][1][1] = str(self.root / self.helper.name)
        self.refuse("exact OUT_DIR")

    def test_out_dir_must_be_absolute(self) -> None:
        self.rows[0]["out_dir"] = "profile/build/out"
        self.refuse("canonical and absolute")

    def test_missing_or_empty_helper_is_refused(self) -> None:
        self.helper.write_bytes(b"")
        self.refuse("empty native file")
        self.helper.unlink()
        self.refuse("No such file")

    def test_helper_symlink_is_refused(self) -> None:
        self.helper.unlink()
        self.helper.symlink_to(self.module)
        self.refuse("linked or empty")

    def test_module_symlink_is_refused(self) -> None:
        self.module.unlink()
        self.module.symlink_to(self.helper)
        self.refuse("linked or empty")

    def test_helper_must_be_executable(self) -> None:
        self.helper.chmod(0o644)
        self.refuse("not executable")

    def test_target_header_and_type_are_required(self) -> None:
        for offset, value in ((0, 0), (4, 1), (5, 2), (16, 1), (18, 183)):
            with self.subTest(offset=offset):
                data = bytearray(self.base)
                data[offset] = value
                self.helper.write_bytes(data)
                self.refuse("ELF")

    def test_selected_module_target_must_match(self) -> None:
        data = bytearray(self.base)
        data[18] = 183
        self.module.write_bytes(data)
        self.refuse("ELF target")

    def test_existing_target_is_never_overwritten(self) -> None:
        target = self.destination / self.helper.name
        target.write_bytes(b"preserved")
        self.save()
        with self.assertRaises(FileExistsError):
            STAGER.run(self.args)
        self.assertEqual(target.read_bytes(), b"preserved")
        self.assertEqual(list(self.destination.iterdir()), [target])

    def test_linked_destination_is_refused(self) -> None:
        alias = self.root / "alias"
        alias.symlink_to(self.destination, target_is_directory=True)
        self.args.destination = alias
        self.refuse("canonical directory")

    def test_changed_copy_and_source_bytes_are_refused(self) -> None:
        self.save()
        for values in (("original", "changed"), ("original", "original", "changed")):
            with self.subTest(values=values), patch.object(STAGER, "file_sha", side_effect=values):
                with self.assertRaisesRegex(ValueError, "bytes changed"):
                    STAGER.run(self.args)
                self.assertEqual(list(self.destination.iterdir()), [])

    def test_copy_failure_cleans_temporary_file(self) -> None:
        self.save()
        with (patch.object(STAGER.shutil, "copyfileobj", side_effect=OSError("copy failed")),
              self.assertRaisesRegex(OSError, "copy failed")):
            STAGER.run(self.args)
        self.assertEqual(list(self.destination.iterdir()), [])


if __name__ == "__main__":
    unittest.main()
