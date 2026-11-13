"""Synthetic compiler responses test strict admission, never real compilers, shipped ELF ISA or GPU behavior."""
from __future__ import annotations

import argparse
import contextlib
import io
import json
import subprocess
import sys
import tempfile
import unittest
from collections.abc import Generator
from pathlib import Path
from types import ModuleType
from typing import cast
from unittest.mock import patch

g = cast(ModuleType, globals()["g"])
GNU = ("gcc", "g++", "cc", "c++")
LLVM = ("clang", "clang++")
EXPECTED = {"gcc": "16.2.0", "llvm": "23.1.5"}


def response(stdout: str) -> dict:
    return {"argv": [], "returncode": 0, "timed_out": False, "stdout": stdout, "stderr": ""}


def payload() -> dict:
    tools = {}
    for name in GNU:
        tools[name] = {"binary": "/fixture/" + name, "resolved_binary": "/fixture/" + name,
                       "version": response("16.2.0\n"), "machine": response("x86_64-pc-linux-gnu\n"),
                       "defaults": response("  -march=          x86-64-v3\n  -mtune=          generic\n"),
                       "macros": response("#define __AVX2__ 1\n#define __FMA__ 1\n#define __BMI2__ 1\n")}
    for name in LLVM:
        tools[name] = {"binary": "/fixture/" + name, "resolved_binary": "/fixture/" + name,
                       "version": response("clang version 23.1.5\nInstalledDir: /fixture/llvm-23.1.5/bin\n")}
    return {"schema_version": 1, "expected": EXPECTED, "host": {"system": "Linux", "machine": "x86_64"}, "tools": tools}


NATIVE_TOOLS = ("clang", "clang++", "llvm-config", "llvm-ar", "llvm-ranlib",
                "llvm-tblgen", "clang-tblgen", "lld", "ld.lld")


@contextlib.contextmanager
def native_fixture() -> Generator[Path]:
    with tempfile.TemporaryDirectory() as temporary:
        prefix = Path(temporary) / "source LLVM"
        (prefix / "bin").mkdir(parents=True)
        for name in (*NATIVE_TOOLS, "cc", "notes"):
            path = prefix / "bin" / name
            path.write_text("fixture")
            path.chmod(0o644 if name == "notes" else 0o755)
        with (patch.object(g.shutil, "which", side_effect=lambda name: str(prefix / "bin" / name)),
              patch.object(g, "command", return_value=response("23.1.5\n"))):
            yield prefix


class CompilerDefaultsTests(unittest.TestCase):
    def test_every_default_alias_has_full_pins_target_tuning_and_v3_macros(self) -> None:
        result = g.validate(payload(), EXPECTED)
        self.assertEqual(set(result), {*GNU, *LLVM})
        for name in GNU:
            self.assertEqual(result[name]["version"], "16.2.0")
            self.assertEqual(result[name]["march"], "x86-64-v3")
            self.assertEqual(result[name]["mtune"], "generic")
            self.assertEqual(result[name]["v3_defines"], ["AVX2", "FMA", "BMI2"])
        for name in LLVM:
            self.assertEqual(result[name]["version"], "23.1.5")

    def test_source_schema_host_and_complete_alias_set_are_required(self) -> None:
        for key, value in (("schema_version", 2), ("schema_version", True), ("expected", {}),
                           ("host", {"system": "Darwin", "machine": "x86_64"}),
                           ("host", {"system": "Linux", "machine": "aarch64"})):
            subject = payload()
            subject[key] = value
            with self.subTest(key=key, value=value), self.assertRaises(ValueError):
                g.validate(subject, EXPECTED)
        for name in (*GNU, *LLVM):
            subject = payload()
            del subject["tools"][name]
            with self.subTest(missing=name), self.assertRaises(ValueError):
                g.validate(subject, EXPECTED)
        subject = payload()
        subject["tools"]["foreign"] = {}
        with self.assertRaises(ValueError):
            g.validate(subject, EXPECTED)

    def test_full_gcc_and_llvm_patch_versions_never_accept_a_channel_or_prerelease(self) -> None:
        for name in GNU:
            for version in ("", "16.2", "16.2.1", "16.2.0-rc1"):
                subject = payload()
                subject["tools"][name]["version"]["stdout"] = version
                with self.subTest(name=name, version=version), self.assertRaises(ValueError):
                    g.validate(subject, EXPECTED)
        for name in LLVM:
            for version in ("", "clang version 23.1.3", "Ubuntu clang version 23.1.6", "clang version 23.10.5",
                            "clang version 23.1.50", "clang version 23.1.5-rc1",
                            "clang version 23.1.3\nInstalledDir: /fixture/llvm-23.1.5/bin"):
                subject = payload()
                subject["tools"][name]["version"]["stdout"] = version
                with self.subTest(name=name, version=version), self.assertRaises(ValueError):
                    g.validate(subject, EXPECTED)

    def test_every_gnu_alias_requires_unambiguous_v3_generic_defaults(self) -> None:
        for name in GNU:
            for text in ("", " -march= x86-64\n -mtune= generic\n",
                         " -march= x86-64-v3\n -mtune= znver4\n",
                         " -march= x86-64-v3\n -march= x86-64-v3\n -mtune= generic\n"):
                subject = payload()
                subject["tools"][name]["defaults"]["stdout"] = text
                with self.subTest(name=name, text=text), self.assertRaises(ValueError):
                    g.validate(subject, EXPECTED)
            subject = payload()
            subject["tools"][name]["machine"]["stdout"] = "aarch64-linux-gnu"
            with self.assertRaises(ValueError):
                g.validate(subject, EXPECTED)

    def test_each_v3_macro_is_exactly_one_literal_one_for_every_gnu_alias(self) -> None:
        for name in GNU:
            for macro in ("AVX2", "FMA", "BMI2"):
                wanted = "#define __" + macro + "__ 1\n"
                for replacement in ("", wanted + wanted, wanted.replace(" 1", " 0")):
                    subject = payload()
                    text = subject["tools"][name]["macros"]["stdout"]
                    subject["tools"][name]["macros"]["stdout"] = text.replace(wanted, replacement)
                    with self.subTest(name=name, macro=macro, replacement=replacement), self.assertRaises(ValueError):
                        g.validate(subject, EXPECTED)

    def test_child_failure_timeout_and_bounded_text_are_fatal_despite_valid_version(self) -> None:
        for key, value in (("returncode", 47), ("returncode", False), ("timed_out", True),
                           ("stdout", None), ("stderr", "x" * (2 * 1024 * 1024 + 1))):
            subject = payload()
            subject["tools"]["clang"]["version"][key] = value
            with self.subTest(key=key), self.assertRaises(ValueError):
                g.validate(subject, EXPECTED)

    def test_collection_never_injects_an_isa_or_tuning_flag(self) -> None:
        def completed(argv: list[str], **kwargs: object) -> subprocess.CompletedProcess[str]:
            self.assertEqual(kwargs["input"], "")
            self.assertEqual(kwargs["timeout"], 20)
            self.assertTrue(kwargs["capture_output"])
            self.assertFalse(any(arg.startswith(("-march", "-mtune")) for arg in argv))
            record = payload()["tools"][argv[0]]
            field = {"-dumpfullversion": "version", "-dumpmachine": "machine", "-Q": "defaults",
                     "-dM": "macros", "--version": "version"}[argv[1]]
            return subprocess.CompletedProcess(argv, 0, record[field]["stdout"], "")
        with (patch.object(g.subprocess, "run", side_effect=completed) as runner,
              patch.object(g.platform, "system", return_value="Linux"),
              patch.object(g.platform, "machine", return_value="x86_64")):
            subject = g.collect(EXPECTED)
        self.assertEqual(runner.call_count, 18)
        g.validate(subject, EXPECTED)
        for name in GNU:
            calls = [call.args[0] for call in runner.call_args_list if call.args[0][0] == name]
            self.assertIn([name, "-Q", "--help=target"], calls)
            language = "c++" if name.endswith("++") else "c"
            self.assertIn([name, "-dM", "-E", "-x", language, "-"], calls)

    def test_raw_status_missing_executable_and_both_timeout_stream_types_survive(self) -> None:
        with patch.object(g.subprocess, "run", return_value=subprocess.CompletedProcess([], 47, "raw output", "raw error")):
            record = g.command("fixture", ["--version"])
        self.assertEqual((record["returncode"], record["stdout"], record["stderr"]), (47, "raw output", "raw error"))
        for value in (b"timed out bytes", "timed out text", None):
            with patch.object(g.subprocess, "run", side_effect=subprocess.TimeoutExpired([], 20, output=value, stderr=value)):
                record = g.command("fixture", [])
            self.assertIsNone(record["returncode"])
            self.assertTrue(record["timed_out"])
            self.assertIsInstance(record["stdout"], str)
        with patch.object(g.subprocess, "run", side_effect=FileNotFoundError("absent compiler")):
            record = g.command("fixture", [])
        self.assertEqual(record["returncode"], 127)
        self.assertIn("absent compiler", record["stderr"])

    def test_cli_emits_raw_failed_payload_and_requires_full_explicit_pins(self) -> None:
        subject = payload()
        subject["tools"]["clang"]["version"]["returncode"] = 47
        buffer = io.StringIO()
        with (patch.object(sys, "argv", ["probe", "--gcc-version", "16.2.0", "--llvm-version", "23.1.5"]),
              patch.object(g, "collect", return_value=subject), contextlib.redirect_stdout(buffer)):
            self.assertEqual(g.main(), 1)
        data = json.loads(buffer.getvalue())
        self.assertEqual(data["status"], "failed")
        self.assertEqual(data["tools"]["clang"]["version"]["returncode"], 47)
        for value in ("23.1", "v23.1.5", "23.1.5-rc1"):
            with self.subTest(value=value), self.assertRaises(argparse.ArgumentTypeError):
                g.pin(value)


class NativeLlvmTests(unittest.TestCase):
    def test_every_executable_source_tool_wins_and_gnu_aliases_are_excluded(self) -> None:
        with native_fixture() as prefix:
            record = g.collect_native_llvm(prefix, "23.1.5")
            facts = g.validate_native_llvm(record, prefix, "23.1.5")
            self.assertEqual({"native_prefix": str(prefix), "native_tool_count": 9, "llvm_config_version": "23.1.5"}, facts)
            self.assertEqual(set(NATIVE_TOOLS), {row["name"] for row in record["tools"]})
            for row in record["tools"]:
                self.assertEqual(str(prefix / "bin" / row["name"]), row["source"])
                self.assertEqual(row["source"], row["selected"])
            g.command.assert_called_once_with("llvm-config", ["--version"])

    def test_any_missing_or_distro_selected_tool_fails(self) -> None:
        with native_fixture() as prefix:
            for name in NATIVE_TOOLS:
                for selected in (None, "/usr/lib/llvm-23/bin/" + name):
                    record = g.collect_native_llvm(prefix, "23.1.5")
                    row = next(row for row in record["tools"] if row["name"] == name)
                    row["selected"] = selected
                    with self.subTest(name=name, selected=selected), self.assertRaises(ValueError):
                        g.validate_native_llvm(record, prefix, "23.1.5")

    def test_source_symlinks_cannot_escape_the_owning_prefix(self) -> None:
        with native_fixture() as prefix:
            record = g.collect_native_llvm(prefix, "23.1.5")
            record["tools"][0].update(source="/usr/lib/llvm-23/bin/clang", selected="/usr/lib/llvm-23/bin/clang")
            with self.assertRaises(ValueError):
                g.validate_native_llvm(record, prefix, "23.1.5")

    def test_required_inventory_and_unique_names_are_mandatory(self) -> None:
        with native_fixture() as prefix:
            for name in NATIVE_TOOLS:
                record = g.collect_native_llvm(prefix, "23.1.5")
                record["tools"] = [row for row in record["tools"] if row["name"] != name]
                with self.subTest(missing=name), self.assertRaises(ValueError):
                    g.validate_native_llvm(record, prefix, "23.1.5")
            record = g.collect_native_llvm(prefix, "23.1.5")
            record["tools"].append(record["tools"][0])
            with self.assertRaises(ValueError):
                g.validate_native_llvm(record, prefix, "23.1.5")

    def test_native_scope_and_full_config_pin_are_required(self) -> None:
        with native_fixture() as prefix:
            for key, value in (("schema_version", True), ("schema_version", 2),
                               ("prefix", str(prefix / "other")), ("expected", "23.1.6")):
                record = g.collect_native_llvm(prefix, "23.1.5")
                record[key] = value
                with self.subTest(key=key), self.assertRaises(ValueError):
                    g.validate_native_llvm(record, prefix, "23.1.5")
            for version in ("23.1.6", "23.1.50", "23.1.5-rc1", ""):
                record = g.collect_native_llvm(prefix, "23.1.5")
                record["version"]["stdout"] = version
                with self.subTest(version=version), self.assertRaises(ValueError):
                    g.validate_native_llvm(record, prefix, "23.1.5")

    def test_native_cli_retains_failed_child_and_separate_scope(self) -> None:
        with native_fixture() as prefix:
            for status in (0, 47):
                with (patch.object(g, "command", return_value={**response("23.1.5"), "returncode": status}),
                      patch.object(sys, "argv", ["probe", "--llvm-version", "23.1.5", "--native-llvm-prefix", str(prefix)]),
                      contextlib.redirect_stdout(io.StringIO()) as buffer):
                    self.assertEqual(0 if status == 0 else 1, g.main())
                result = json.loads(buffer.getvalue())
                self.assertEqual(status, result["version"]["returncode"])
                if status == 0:
                    self.assertEqual("passed-native-llvm-tool-selection-only", result["status"])
                    self.assertEqual(9, result["facts"]["native_tool_count"])
                else:
                    self.assertEqual("failed", result["status"])

    def test_native_cli_rejects_mixed_relative_or_missing_modes(self) -> None:
        for args in (["--llvm-version", "23.1.5"], ["--llvm-version", "23.1.5", "--native-llvm-prefix", "relative"],
                     ["--llvm-version", "23.1.5", "--gcc-version", "16.2.0", "--native-llvm-prefix", "/fixture"]):
            with (self.subTest(args=args), patch.object(sys, "argv", ["probe", *args]),
                  contextlib.redirect_stderr(io.StringIO()), self.assertRaises(SystemExit) as error):
                g.main()
            self.assertEqual(2, error.exception.code)


if __name__ == "__main__":
    unittest.main(argv=[__file__], verbosity=2)
