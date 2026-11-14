"""Real staging bytes, namespace refusals and deterministic outputs do not prove BuildKit hits, compiler builds or GPU/image acceptance."""

import hashlib
import json
import os
import runpy
import stat
import subprocess
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[3]
MODULE = runpy.run_path(str(ROOT / "linux/scripts/script_closure.py"))


class ScriptClosureTests(unittest.TestCase):
    """Independent fixtures grade selected source files and raw refusals rather than a generated expected plan."""

    def setUp(self) -> None:
        temporary = tempfile.TemporaryDirectory(prefix="Selected script closure ")
        self.addCleanup(temporary.cleanup)
        self.work = Path(temporary.name)
        self.root = self.work / "input"
        self.profiles = self.root / "script-closures"
        self.profiles.mkdir(parents=True)
        (self.root / "core.sh").write_bytes(b"printf core\\n\n")
        (self.root / "data.txt").write_bytes(b"original source data\n")
        (self.root / "unused.txt").write_bytes(b"not selected\n")
        (self.profiles / "shared.txt").write_text("core.sh|core/core.sh\n")
        (self.profiles / "sample.txt").write_text("@shared\ndata.txt|config/data.txt\n")
        self.number = 0

    def stage(self, profile: str = "sample") -> Path:
        self.number += 1
        output = self.work / ("output" + str(self.number))
        MODULE["stage"](self.root, profile, output)
        return output

    def snapshot(self, output: Path) -> dict[str, tuple[bytes, int, int]]:
        result = {}
        for path in [output, *output.rglob("*")]:
            details = path.stat()
            result[path.relative_to(output).as_posix()] = (
                b"" if path.is_dir() else path.read_bytes(), details.st_mode, details.st_mtime_ns)
        return result

    def test_inherited_selection_preserves_exact_files_bytes_modes_and_receipt(self) -> None:
        output = self.stage()
        files = {p.relative_to(output).as_posix() for p in output.rglob("*") if p.is_file()}
        self.assertEqual(files, {"core/core.sh", "config/data.txt", "SCRIPT-CLOSURE.json"})
        record = json.loads((output / "SCRIPT-CLOSURE.json").read_text())
        self.assertEqual(record["schema_version"], 1)
        self.assertEqual(record["profile"], "sample")
        for target, original, mode in (("core/core.sh", "core.sh", 0o755), ("config/data.txt", "data.txt", 0o644)):
            source = (self.root / original).read_bytes()
            self.assertEqual((output / target).read_bytes(), source)
            self.assertEqual(stat.S_IMODE((output / target).stat().st_mode), mode)
            self.assertEqual(record["files"][target], {"source": original, "sha256": hashlib.sha256(source).hexdigest(),
                                                       "size": len(source), "mode": format(mode, "o")})
        for path in [output, *output.rglob("*")]:
            self.assertEqual(path.stat().st_mtime_ns, 0)
            if path.is_dir():
                self.assertEqual(stat.S_IMODE(path.stat().st_mode), 0o755)

    def test_unselected_bytes_and_plan_comments_leave_the_complete_output_identical(self) -> None:
        expected = self.snapshot(self.stage())
        (self.root / "unused.txt").write_bytes(b"changed but still unselected")
        (self.profiles / "sample.txt").write_text("# comment only\ndata.txt|config/data.txt\n@shared\n")
        self.assertEqual(self.snapshot(self.stage()), expected)
        (self.root / "core.sh").write_bytes(b"changed selected source")
        self.assertNotEqual(self.snapshot(self.stage()), expected)

    def test_selected_input_modes_and_umask_do_not_change_published_modes(self) -> None:
        (self.root / "core.sh").chmod(0o600)
        (self.root / "data.txt").chmod(0o755)
        previous = os.umask(0o077)
        try:
            output = self.stage()
        finally:
            os.umask(previous)
        self.assertEqual(stat.S_IMODE((output / "core/core.sh").stat().st_mode), 0o755)
        self.assertEqual(stat.S_IMODE((output / "config/data.txt").stat().st_mode), 0o644)
        self.assertEqual(stat.S_IMODE(output.stat().st_mode), 0o755)

    def test_invalid_and_recursive_and_empty_profiles_refuse(self) -> None:
        (self.profiles / "cycle.txt").write_text("@cycle\n")
        (self.profiles / "empty.txt").write_text("# no selected files\n")
        (self.profiles / "bad_profile.txt").write_text("core.sh|core/core.sh\n")
        for profile in ("../sample", "", "cycle", "empty", "bad_profile"):
            with self.subTest(profile=profile), self.assertRaises(ValueError):
                self.stage(profile)

    def test_relative_path_gate_rejects_absolute_parent_and_empty_names(self) -> None:
        for value in ("", ".", "/absolute/source", "../outside", "inside/../../outside", r"core\file"):
            with self.subTest(value=value), self.assertRaisesRegex(ValueError, "relative"):
                MODULE["relative_path"](value)

    def test_existing_symlink_and_foreign_parent_and_directory_sources_refuse(self) -> None:
        (self.root / "leaf.sh").symlink_to("core.sh")
        foreign = self.work / "foreign"
        foreign.mkdir()
        (foreign / "valid.sh").write_text("actual existing foreign bytes\n")
        (self.root / "parent").symlink_to(foreign, target_is_directory=True)
        for value in ("leaf.sh", "parent/valid.sh", "script-closures"):
            with self.subTest(value=value), self.assertRaisesRegex(ValueError, "regular file"):
                MODULE["selected_file"](self.root, value)

    def test_duplicate_normalized_or_inherited_targets_refuse(self) -> None:
        for target in ("core/core.sh", "core/./core.sh"):
            (self.profiles / "duplicate.txt").write_text("@shared\ndata.txt|" + target + "\n")
            with self.subTest(target=target), self.assertRaisesRegex(ValueError, "Repeated"):
                self.stage("duplicate")

    def test_reserved_receipt_target_and_descendants_refuse(self) -> None:
        for target in ("SCRIPT-CLOSURE.json", "SCRIPT-CLOSURE.json/child"):
            (self.profiles / "reserved.txt").write_text("data.txt|" + target + "\n")
            with self.subTest(target=target), self.assertRaisesRegex(ValueError, "reserved"):
                self.stage("reserved")

    def test_missing_source_refuses_before_allocating_output(self) -> None:
        (self.profiles / "missing.txt").write_text("absent.sh|core/missing.sh\n")
        with self.assertRaises(FileNotFoundError):
            self.stage("missing")
        self.assertFalse((self.work / "output1").exists())

    def test_existing_output_is_never_overwritten(self) -> None:
        output = self.stage()
        previous = self.snapshot(output)
        with self.assertRaises(FileExistsError):
            MODULE["stage"](self.root, "sample", output)
        self.assertEqual(self.snapshot(output), previous)

    def test_write_failure_never_creates_a_complete_receipt(self) -> None:
        with patch.object(Path, "write_bytes", side_effect=OSError("required write failed")), self.assertRaisesRegex(OSError, "required write failed"):
            self.stage()
        self.assertFalse((self.work / "output1/SCRIPT-CLOSURE.json").exists())

    def test_cli_success_marker_follows_completed_staging(self) -> None:
        output = self.work / "cli-success"
        result = subprocess.run(["python3", str(ROOT / "linux/scripts/stage-script-closure.py"),
                                 "sample", "--root", str(self.root), "--output", str(output)],
                                capture_output=True, text=True, check=False, timeout=10)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, "SCRIPT_CLOSURE_STAGED sample\n")
        self.assertTrue((output / "SCRIPT-CLOSURE.json").is_file())

    def test_cli_failure_is_nonzero_and_keeps_the_diagnostic(self) -> None:
        result = subprocess.run(["python3", str(ROOT / "linux/scripts/stage-script-closure.py"),
                                 "missing", "--root", str(self.root), "--output", str(self.work / "cli-output")],
                                capture_output=True, text=True, check=False, timeout=10)
        self.assertEqual(result.returncode, 2)
        self.assertIn("Script closure refused:", result.stderr)
        self.assertFalse((self.work / "cli-output").exists())

    def test_dockerfile_contract_requires_one_literal_profile(self) -> None:
        dockerfile = self.work / "Dockerfile"
        for value in ("COPY --from=hub-scripts / /opt/scripts/\n",
                      "LABEL org.kataglyphis.build-script-closure=bad_profile\n",
                      "LABEL org.kataglyphis.build-script-closure=sample\nLABEL org.kataglyphis.build-script-closure=sample\n"):
            dockerfile.write_text(value)
            with self.subTest(value=value), self.assertRaisesRegex(ValueError, "Exactly one"):
                MODULE["profile_for"](dockerfile)
        dockerfile.write_text("FROM base\n")
        self.assertIsNone(MODULE["profile_for"](dockerfile))
        dockerfile.write_text("LABEL org.kataglyphis.build-script-closure=sample\n")
        self.assertEqual(MODULE["profile_for"](dockerfile), "sample")

    def test_profile_query_checks_inputs_without_allocating_output(self) -> None:
        dockerfile = self.work / "Dockerfile"
        dockerfile.write_text("LABEL org.kataglyphis.build-script-closure=sample\n")
        command = ["python3", str(ROOT / "linux/scripts/stage-script-closure.py"),
                   "--profile-for", str(dockerfile), "--root", str(self.root)]
        result = subprocess.run(command, capture_output=True, text=True, check=False, timeout=10)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, "sample\n")
        (self.root / "core.sh").unlink()
        result = subprocess.run(command, capture_output=True, text=True, check=False, timeout=10)
        self.assertEqual(result.returncode, 2)
        self.assertEqual(result.stdout, "")

    def test_addressed_context_binds_the_full_receipt_and_preserves_flat_bytes(self) -> None:
        flat = self.stage()
        output = self.work / "addressed"
        key = MODULE["stage_context"](self.root, "sample", output)
        expected = hashlib.sha256((flat / "SCRIPT-CLOSURE.json").read_bytes()).hexdigest()
        self.assertEqual(key, expected)
        self.assertRegex(key, r"^[0-9a-f]{64}$")
        self.assertEqual([path.name for path in output.iterdir()], [key])
        self.assertFalse((output / "files").exists())
        self.assertEqual(self.snapshot(output / key / "files"), self.snapshot(flat))
        (self.root / "data.txt").write_bytes(b"changed selected data\n")
        second = self.work / "second-addressed"
        changed = MODULE["stage_context"](self.root, "sample", second)
        self.assertNotEqual(changed, key)
        self.assertEqual([path.name for path in second.iterdir()], [changed])

    def test_addressed_context_cli_prints_only_the_validated_key(self) -> None:
        output = self.work / "cli-addressed"
        result = subprocess.run(["python3", str(ROOT / "linux/scripts/stage-script-closure.py"),
                                 "sample", "--context", "--root", str(self.root), "--output", str(output)],
                                capture_output=True, text=True, check=False, timeout=10)
        self.assertEqual(result.returncode, 0, result.stderr)
        key = result.stdout.strip()
        self.assertRegex(key, r"^[0-9a-f]{64}$")
        self.assertEqual(key, hashlib.sha256((output / key / "files/SCRIPT-CLOSURE.json").read_bytes()).hexdigest())
        before = self.snapshot(output)
        with self.assertRaises(FileExistsError):
            MODULE["stage_context"](self.root, "sample", output)
        self.assertEqual(self.snapshot(output), before)

    def test_context_namespace_survives_unselected_changes_but_changes_on_equal_size_bytes(self) -> None:
        first = self.work / "first-context"
        key = MODULE["stage_context"](self.root, "sample", first)
        (self.root / "unused.txt").write_bytes(b"changed outside the selection")
        (self.profiles / "sample.txt").write_text("# plan comment\n@shared\ndata.txt|config/data.txt\n")
        warm = self.work / "warm-context"
        self.assertEqual(MODULE["stage_context"](self.root, "sample", warm), key)
        self.assertEqual(self.snapshot(first), self.snapshot(warm))
        selected = self.root / "data.txt"
        before = selected.read_bytes()
        selected.write_bytes(before.swapcase())
        self.assertEqual(len(before), selected.stat().st_size)
        changed = self.work / "changed-context"
        new_key = MODULE["stage_context"](self.root, "sample", changed)
        self.assertNotEqual(new_key, key)
        old_receipt = first / key / "files/SCRIPT-CLOSURE.json"
        new_receipt = changed / new_key / "files/SCRIPT-CLOSURE.json"
        self.assertEqual(old_receipt.stat().st_size, new_receipt.stat().st_size)
        self.assertEqual(old_receipt.stat().st_mtime_ns, new_receipt.stat().st_mtime_ns)
        self.assertNotEqual(old_receipt.read_bytes(), new_receipt.read_bytes())

    def test_context_and_profile_query_modes_cannot_be_combined(self) -> None:
        dockerfile = self.work / "Dockerfile"
        dockerfile.write_text("LABEL org.kataglyphis.build-script-closure=sample\n")
        output = self.work / "query-output"
        result = subprocess.run(["python3", str(ROOT / "linux/scripts/stage-script-closure.py"), "--context",
                                 "--profile-for", str(dockerfile), "--root", str(self.root), "--output", str(output)],
                                capture_output=True, text=True, check=False, timeout=10)
        self.assertEqual(result.returncode, 2)
        self.assertEqual(result.stdout, "")
        self.assertFalse(output.exists())

    def test_real_sdk_and_migraphx_profiles_share_the_same_core_sources(self) -> None:
        scripts = ROOT / "linux/scripts"
        shared = MODULE["read_profile"](scripts, "core-common")
        self.assertEqual(len(shared), 21)
        manifests: set[Path] = set()
        for profile, count in (("sdk-core", 24), ("migraphx-image", 80)):
            selected = MODULE["read_profile"](scripts, profile, manifests=manifests)
            self.assertEqual(len(selected), count)
            self.assertTrue(shared.items() <= selected.items())
        self.assertIn(scripts / "script-closures/core-common.txt", manifests)


if __name__ == "__main__":
    unittest.main()
