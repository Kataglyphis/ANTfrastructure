"""Synthetic wheels and fake children cover refusal/transport, not NumPy execution or target hardware."""
from __future__ import annotations

import argparse
import json
import os
import re
import shutil
import struct
import subprocess
import sys
import tempfile
import unittest
import zipfile
from pathlib import Path
from types import ModuleType
from typing import cast
from unittest.mock import patch

g = cast(ModuleType, globals()["g"])
MODULE_FILE = g.__file__
if MODULE_FILE is None:
    raise ValueError("probe dependency fixture module has no source file")
SCRIPTS = Path(MODULE_FILE).resolve().parent.parent


class ProbeDependencyTests(unittest.TestCase):
    def setUp(self) -> None:
        self.root = Path(self.enterContext(tempfile.TemporaryDirectory()))
        self.lock = json.loads(g.LOCK.read_text())
        self.original_lock = self.lock.copy()
        self.pool = self.root / "pool"
        self.pool.mkdir()
        self.wheel = self.pool / "numpy-2.5.4-cp315-cp315t-linux_x86_64.whl"
        self.members = {"numpy-2.5.4.dist-info/METADATA": b"Name: numpy\nVersion: 2.5.4\n",
                        "numpy-2.5.4.dist-info/licenses/LICENSE.txt": b"synthetic license fixture\n",
                        "numpy/_core/array.so": Path(os.environ["T_FT_ELF"]).read_bytes()}
        self.write_wheel()
        lock_path = self.root / "lock.json"
        self.lock["artifacts"]["amd64"] = {"filename": self.wheel.name, "sha256": g.digest(self.wheel),
            "url": "https://files.pythonhosted.org/packages/fixture/" + self.wheel.name}
        lock_path.write_text(json.dumps(self.lock))
        self.enterContext(patch.object(g, "LOCK", lock_path))
        self.record = {"numpy_version": "2.5.4", "arch": "amd64", "python_tag": "cp315",
                       "artifact": self.lock["artifacts"]["amd64"], "wheel": self.wheel.name,
                       "wheel_sha256": g.digest(self.wheel)}
        self.save_record()
        self.args = argparse.Namespace(pool=self.root / "output", cache=self.root / "cache", core=self.root / "core",
                                       numpy_version="2.5.4", arch="amd64", action="build")

    def write_wheel(self) -> None:
        with zipfile.ZipFile(self.wheel, "w") as archive:
            for name, value in self.members.items():
                archive.writestr(name, value)

    def save_record(self) -> None:
        (self.pool / "receipt.json").write_text(json.dumps(self.record))

    def verify(self) -> Path:
        return g.verify_pool(self.pool, "2.5.4", "amd64", "cp315")

    def test_native_pool_checks_original_artifact_and_wheel(self) -> None:
        self.assertEqual(self.verify(), self.wheel)
        with self.assertRaisesRegex(ValueError, "drifted"):
            g.artifact("2.5.5", "amd64", "cp315")
        with self.assertRaisesRegex(ValueError, "drifted"):
            g.artifact("2.5.4", "amd64", "cp316")

    def test_riscv_has_a_pinned_source_instead_of_a_foreign_wheel(self) -> None:
        row = g.artifact("2.5.4", "riscv64", "cp315")
        self.assertEqual(row["filename"], "numpy-2.5.4.tar.gz")
        self.assertEqual(row["sha256"], "9a94cf751c9ad8ebaa835bcd3d40dacf8534ad086b88c38029b65123c7999d2a")
        self.assertIn("aarch64", g.artifact("2.5.4", "arm64", "cp315")["filename"])

    def test_invalid_locked_filename_url_or_hash_refuses(self) -> None:
        row = self.lock["artifacts"]["amd64"]
        for field, value in (("filename", "../foreign.whl"), ("url", "http://files.pythonhosted.org/packages/" + self.wheel.name),
                             ("url", "https://files.pythonhosted.org/packages/foreign.whl"), ("sha256", "not a digest")):
            with self.subTest(field=field), patch.dict(row, {field: value}):
                g.LOCK.write_text(json.dumps(self.lock))
                with self.assertRaisesRegex(ValueError, "invalid pinned"):
                    g.artifact("2.5.4", "amd64", "cp315")
        row.update(filename="..", url="https://files.pythonhosted.org/packages/..")
        g.LOCK.write_text(json.dumps(self.lock))
        with self.assertRaisesRegex(ValueError, "invalid pinned"):
            g.artifact("2.5.4", "amd64", "cp315")

    def test_lock_matches_the_existing_image_version_pins(self) -> None:
        versions = (SCRIPTS / "01-core/versions.env").read_text()
        pins = dict(re.findall(r"^(PY_NUMPY_VERSION|PYTHON_VERSION)=([^\n]+)$", versions, re.MULTILINE))
        self.assertEqual(self.original_lock["numpy_version"], pins["PY_NUMPY_VERSION"])
        self.assertEqual(self.original_lock["python_tag"], "cp" + "".join(pins["PYTHON_VERSION"].split(".")[:2]))

    def test_corrupted_artifact_or_recorded_wheel_hash_refuses(self) -> None:
        self.wheel.write_bytes(self.wheel.read_bytes() + b"changed")
        self.record["wheel_sha256"] = g.digest(self.wheel)
        self.save_record()
        with self.assertRaisesRegex(ValueError, "hashes"):
            self.verify()
        self.write_wheel()
        self.record["wheel_sha256"] = "0" * 64
        self.save_record()
        with self.assertRaisesRegex(ValueError, "hashes"):
            self.verify()

    def test_receipt_identity_and_wheel_paths_refuse(self) -> None:
        for field, value in (("arch", "arm64"), ("numpy_version", "2.5.5"), ("python_tag", "cp316"),
                             ("artifact", {}), ("wheel", "../escape.whl"), ("wheel", "other.zip")):
            with self.subTest(field=field), patch.dict(self.record, {field: value}):
                self.save_record()
                with self.assertRaises(ValueError):
                    self.verify()

    def test_extra_payload_and_symlink_refuse(self) -> None:
        other = self.pool / "extra.whl"
        other.write_text("unrecorded")
        with self.assertRaisesRegex(ValueError, "unexpected"):
            self.verify()

        other.unlink()
        moved = self.root / self.wheel.name
        self.wheel.rename(moved)
        self.wheel.symlink_to(moved)
        with self.assertRaisesRegex(ValueError, "unexpected"):
            self.verify()

    def test_linked_pool_root_refuses(self) -> None:
        alias = self.root / "alias"
        alias.symlink_to(self.pool, target_is_directory=True)
        with self.assertRaisesRegex(ValueError, "regular directory"):
            g.verify_pool(alias, "2.5.4", "amd64", "cp315")

    def test_escape_to_matching_external_wheel_is_refused(self) -> None:
        shutil.copyfile(self.wheel, self.root / self.wheel.name)
        self.record["wheel"] = "../" + self.wheel.name
        self.save_record()
        with self.assertRaises(ValueError):
            self.verify()

    def test_wheel_metadata_license_native_code_and_machine_refuse(self) -> None:
        mutations = [("numpy-2.5.4.dist-info/METADATA", b"Name: foreign\nVersion: 2.5.4\n"),
                     ("numpy-2.5.4.dist-info/licenses/LICENSE.txt", b""),
                     ("numpy/_core/array.so", b"not native code")]
        foreign = bytearray(self.members["numpy/_core/array.so"])
        struct.pack_into("<H", foreign, 18, 183)
        mutations.append(("numpy/_core/array.so", bytes(foreign)))
        for member, value in mutations:
            with self.subTest(member=member), patch.dict(self.members, {member: value}):
                self.write_wheel()
                with self.assertRaises(ValueError):
                    g.wheel_identity(self.wheel, "2.5.4", "amd64", "cp315")

    def test_wheel_filename_cannot_change_version_abi_or_machine(self) -> None:
        for name in ("numpy-2.5.5-cp315-cp315t-linux_x86_64.whl", "numpy-2.5.4-cp315-cp315-linux_x86_64.whl",
                     "numpy-2.5.4-cp315-cp315t-linux_aarch64.whl"):
            with self.subTest(name=name), self.assertRaises(ValueError):
                g.wheel_identity(self.pool / name, "2.5.4", "amd64", "cp315")

    def test_running_gil_or_wrong_architecture_is_not_a_target_proof(self) -> None:
        with patch.object(g.sysconfig, "get_config_var", return_value=0), self.assertRaisesRegex(ValueError, "GIL off"):
            g.target()
        with (patch.object(g.sysconfig, "get_config_var", return_value=1),
              patch.object(g.sys, "_is_gil_enabled", return_value=True, create=True),
              self.assertRaisesRegex(ValueError, "GIL off")):
            g.target()
        with (patch.object(g, "target", return_value=("arm64", "cp315")), patch.object(g, "arguments", return_value=self.args),
              patch.object(g, "build") as build):
            self.assertEqual(g.main(), 1)
            build.assert_not_called()

    def test_install_is_exact_offline_and_has_no_dependency_resolver(self) -> None:
        with patch.object(g.subprocess, "run") as run:
            g.install(self.wheel, "/target python")
        self.assertEqual(run.call_args.args[0], ["uv", "pip", "install", "--offline", "--no-index", "--no-deps",
                                               "--python", "/target python", str(self.wheel)])
        self.assertTrue(run.call_args.kwargs["check"])

    def test_normal_numpy_import_and_both_gil_checks_execute_in_fresh_venv(self) -> None:
        with patch.object(g.subprocess, "run") as run:
            g.prove_import(self.wheel, "2.5.4", self.root)
        commands = [call.args[0] for call in run.call_args_list]
        self.assertEqual(commands[0][:4], ["uv", "venv", "--python", sys.executable])
        self.assertIn("import numpy", commands[2][3])
        self.assertEqual(commands[2][3].count("assert not sys._is_gil_enabled()"), 2)
        self.assertIn("numpy.__version__ == sys.argv[1]", commands[2][3])

    def test_cache_reuse_still_checks_bytes_and_runs_import(self) -> None:
        self.args.cache.mkdir()
        cached = self.args.cache / "numpy-2.5.4-cp315t-amd64"
        shutil.copytree(self.pool, cached)
        with patch.object(g, "populate") as populate, patch.object(g, "prove_import") as prove:
            g.build(self.args, "amd64", "cp315")
            populate.assert_not_called()
            prove.assert_called_once()
        self.assertEqual(g.verify_pool(self.args.pool, "2.5.4", "amd64", "cp315").read_bytes(), self.wheel.read_bytes())
        shutil.rmtree(self.args.pool)
        (cached / self.wheel.name).write_text("changed")
        with patch.object(g, "prove_import") as prove, self.assertRaises(ValueError):
            g.build(self.args, "amd64", "cp315")
        prove.assert_not_called()
        self.assertFalse(self.args.pool.exists())

    def test_existing_output_and_failed_import_never_publish(self) -> None:
        self.args.pool.mkdir()
        with self.assertRaises(FileExistsError):
            g.build(self.args, "amd64", "cp315")
        self.args.pool.rmdir()
        def populate(args: argparse.Namespace, pool: Path, arch: str, tag: str) -> None:
            shutil.copytree(self.pool, pool)
        with (patch.object(g, "populate", side_effect=populate),
              patch.object(g, "prove_import", side_effect=subprocess.CalledProcessError(42, ["numpy import"])),
              self.assertRaises(subprocess.CalledProcessError)):
            g.build(self.args, "amd64", "cp315")
        self.assertFalse(self.args.pool.exists())
        self.assertFalse((self.args.cache / "numpy-2.5.4-cp315t-amd64").exists())

    def test_raw_child_failure_reaches_cli(self) -> None:
        with (patch.object(g, "arguments", return_value=self.args), patch.object(g, "target", return_value=("amd64", "cp315")),
              patch.object(g, "build", side_effect=subprocess.CalledProcessError(42, ["build"]))):
            self.assertEqual(g.main(), 42)

    def test_verified_source_build_uses_the_running_target_interpreter(self) -> None:
        row = {"filename": "numpy-2.5.4.tar.gz", "url": "https://files.pythonhosted.org/packages/fixture/numpy-2.5.4.tar.gz",
               "sha256": g.hashlib.sha256(b"source fixture").hexdigest()}
        pool = self.root / "source pool"
        def child(command: list[str], **kwargs: object) -> None:
            self.assertTrue(kwargs["check"])
            if command[0] == "bash":
                (pool / row["filename"]).write_bytes(b"source fixture")
            else:
                # uv leaves its sdist extraction under --out-dir, as uv 0.13.7 did on riscv64.
                out = Path(command[command.index("--out-dir") + 1])
                (out / ".tmpfixture/numpy-2.5.4").mkdir(parents=True)
                shutil.copyfile(self.wheel, out / self.wheel.name)
        with patch.object(g, "artifact", return_value=row), patch.object(g.subprocess, "run", side_effect=child) as run:
            g.populate(self.args, pool, "riscv64", "cp315")
        download, compile_wheel = [call.args[0] for call in run.call_args_list]
        self.assertIn("download_verified_cached", download[2])
        self.assertEqual(compile_wheel[:7], ["uv", "build", "--wheel", "--no-python-downloads", "--python", sys.executable, "--out-dir"])
        self.assertEqual(compile_wheel[-1], str(pool / row["filename"]))
        self.assertEqual({p.name for p in pool.iterdir()}, {row["filename"], self.wheel.name, "receipt.json"},
                         "the pool holds only the source, the wheel and the receipt")
        self.assertFalse(pool.with_name(f"{pool.name}-dist").exists())

    def test_failed_verified_download_preserves_status_without_receipt(self) -> None:
        pool = self.root / "failed pool"
        with (patch.object(g.subprocess, "run", side_effect=subprocess.CalledProcessError(43, ["download"])),
              self.assertRaises(subprocess.CalledProcessError) as failure):
            g.populate(self.args, pool, "amd64", "cp315")
        self.assertEqual(failure.exception.returncode, 43)
        self.assertFalse((pool / "receipt.json").exists())

    def test_download_hash_is_checked_before_any_build_or_receipt(self) -> None:
        pool = self.root / "corrupt pool"
        def child(command: list[str], **kwargs: object) -> None:
            (pool / self.wheel.name).write_bytes(b"wrong download")
        with (patch.object(g.subprocess, "run", side_effect=child) as run,
              self.assertRaisesRegex(ValueError, "before build")):
            g.populate(self.args, pool, "amd64", "cp315")
        run.assert_called_once()
        self.assertFalse((pool / "receipt.json").exists())

    def test_runtime_layer_carries_the_lock_and_calls_the_pinned_builder(self) -> None:
        dockerfile = (SCRIPTS.parent / "Dockerfile.torch").read_text()
        self.assertIn("COPY linux/scripts/06-packaging/free-threaded-probe-deps.json /opt/scripts/packaging/free-threaded-probe-deps.json", dockerfile)
        self.assertIn('TARGETARCH="${TARGETARCH}" bash /opt/scripts/packaging/build-free-threaded-probe-deps.sh', dockerfile)
        builder = (SCRIPTS / "06-packaging/build-free-threaded-probe-deps.sh").read_text()
        self.assertIn('--numpy-version "${PY_NUMPY_VERSION:?missing NumPy pin}" --arch "${arch}" --core "${core}"', builder)
        self.assertIn('export CC="${launcher} ${CC:-gcc}" CXX="${launcher} ${CXX:-g++}"', builder)
        self.assertIn('compiler_cache_stats_for_launcher "${launcher}"', builder)


if __name__ == "__main__":
    unittest.main(argv=[__file__])
