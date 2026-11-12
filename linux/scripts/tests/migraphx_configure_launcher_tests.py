"""Protocol doubles verify immutable-source unit arguments and raw statuses, not actual SDK or cleanup."""

import argparse
import hashlib
import json
import os
import runpy
import shlex
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from types import SimpleNamespace
from unittest import mock


class MigraphxConfigureLauncherTests(unittest.TestCase):
    """Source preparation cannot start through an unsafe or stale unit transport."""

    def setUp(self) -> None:
        temporary = tempfile.TemporaryDirectory(prefix="mgx launcher ")
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.script = Path(__file__).resolve().parents[1] / "launch-migraphx-configure-proof.py"
        with mock.patch("sys.path", [str(self.script.parent), *sys.path]):
            self.api = runpy.run_path(str(self.script))
        self.globals = self.api["main"].__globals__
        self.args = argparse.Namespace(
            output=self.root / "new output", archive=self.root / "migraphx archive",
            rocm_cmake_archive=self.root / "rocm archive", msgpack_archive=self.root / "msgpack archive",
            compiler_cache=self.root / "cache directory", unit="fixture-configure.service",
            image="fixture-image:immutable", engine="/engine with spaces", mode="configure",
            deps_prefix=None, original_header=None, original_source=None,
        )
        for path in (self.args.archive, self.args.rocm_cmake_archive, self.args.msgpack_archive):
            path.write_bytes(b"fixture archive")
        self.args.compiler_cache.mkdir()

    def test_payload_has_bounded_isolated_owned_transport(self) -> None:
        args = self.api["payload"](self.args, self.root / "frozen source", "a" * 32)
        for flag, expected in (("--pull", "never"), ("--network", "none"), ("--memory", "6g"),
                               ("--cpus", "2"), ("--user", "0:0")):
            self.assertEqual(args[args.index(flag) + 1], expected)
        self.assertIn("--init", args)
        self.assertNotIn("--entrypoint", args)
        self.assertEqual(args[args.index("--security-opt") + 1], "apparmor=unconfined")
        self.assertEqual(args[args.index("--label") + 1],
                         "org.kataglyphis.migraphx-configure=" + "a" * 32)
        self.assertIn(f"{self.args.archive}:/source.tar.gz:ro", args)
        self.assertIn(f"{self.args.rocm_cmake_archive}:/rocm-cmake.tar.gz:ro", args)
        self.assertIn(f"{self.args.msgpack_archive}:/msgpack.tar.gz:ro", args)
        self.assertIn(f"{self.args.compiler_cache}:/cache", args)
        self.assertEqual(args[-3:], [
            "fixture-image:immutable", "/bin/bash",
            "/hub/linux/scripts/03-media/build/migraphx/configure-proof.sh",
        ])

    def test_parser_build_requires_exact_two_archives_and_long_bounded_transport(self) -> None:
        argv = [*self.common_consumer_argv(), "--mode", "parsers",
                "--archive", str(self.args.archive), "--protobuf-archive", str(self.args.msgpack_archive)]
        with mock.patch("sys.argv", argv):
            args = self.api["arguments"]()
        payload = self.api["payload"](args, self.root / "frozen", "e" * 32)
        self.assertEqual(payload[-1], "parsers")
        self.assertIn(f"{self.args.archive}:/abseil.tar.gz:ro", payload)
        self.assertIn(f"{self.args.msgpack_archive}:/protobuf.tar.gz:ro", payload)
        self.assertFalse(any(":/rocm-cmake.tar.gz:" in value for value in payload))
        command = self.api["unit_command"](args, self.root / "frozen", "e" * 32)
        self.assertIn("TimeoutStartSec=3600", command)
        self.assertIn("TimeoutStopSec=180", command)
        self.assertIn("RemainAfterExit=yes", command)
        self.assertEqual(payload[payload.index("--memory") + 1], "6g")
        for invalid in [argv[:-2], [*argv[:-1], str(self.args.compiler_cache)], argv[:-4]]:
            with mock.patch("sys.argv", invalid), mock.patch("sys.stderr"), self.assertRaises(SystemExit):
                self.api["arguments"]()

    def test_vendor_disk_uses_both_exact_bytes_and_canonical_free_probe(self) -> None:
        namespace = self.api["require_build_disk"].__globals__
        for free, canonical, expected in [(193273528320, "180", True), (193273528319, "180", False),
                                          (400000000000, "179", False), (400000000000, "", False),
                                          (400000000000, "unknown", False)]:
            with (mock.patch.object(namespace["shutil"], "disk_usage", return_value=SimpleNamespace(free=free)),
                  mock.patch.dict(namespace, checked_output=mock.Mock(return_value=canonical))):
                if expected:
                    fact = self.api["require_build_disk"](self.root)
                    self.assertEqual(fact["available_bytes"], free)
                    self.assertEqual(fact["required_bytes"], 193273528320)
                    self.assertFalse(fact["reclaim_performed"])
                    call = namespace["checked_output"].call_args.args[0]
                    self.assertIn("_disk_guard_free_gb", call[4])
                    self.assertEqual(call[-1], str(self.root))
                else:
                    with self.assertRaisesRegex(ValueError, "180GiB"):
                        self.api["require_build_disk"](self.root)

    def test_vendor_disk_raw_probe_or_filesystem_failure_is_fatal(self) -> None:
        namespace = self.api["require_build_disk"].__globals__
        with (mock.patch.object(namespace["shutil"], "disk_usage", side_effect=OSError("disk probe failed")),
              self.assertRaisesRegex(OSError, "disk probe failed")):
            self.api["require_build_disk"](self.root)
        with (mock.patch.object(namespace["shutil"], "disk_usage", return_value=SimpleNamespace(free=400000000000)),
              mock.patch.dict(namespace, checked_output=mock.Mock(side_effect=RuntimeError("canonical probe failed"))),
              self.assertRaisesRegex(RuntimeError, "canonical probe failed")):
            self.api["require_build_disk"](self.root)

    def test_vendor_disk_refusal_prevents_freezing_and_launch(self) -> None:
        self.args.protobuf_archive = self.args.msgpack_archive
        for mode in ["parsers", "rocmlir-build"]:
            self.args.mode = mode
            for failure in [ValueError("180GiB reserve"), RuntimeError("admission probe failed")]:
                frozen, launch = self.install_main_doubles(raw=0)
                with (self.subTest(mode=mode, failure=failure),
                      mock.patch.dict(self.globals, require_build_disk=mock.Mock(side_effect=failure)),
                      self.assertRaises(type(failure))):
                    self.api["main"]()
                frozen.assert_not_called()
                launch.assert_not_called()
                self.assertFalse((self.args.output / "invocation.json").exists())

    def test_rocmlir_build_profile_keeps_ordinary_isolation_and_four_compilers(self) -> None:
        self.args.mode = "rocmlir-build"
        payload = self.api["payload"](self.args, self.root / "frozen", "e" * 32)
        self.assertEqual(payload[-1], "rocmlir-build")
        for flag, expected in [("--memory", "12g"), ("--cpus", "4"), ("--network", "none"), ("--pull", "never")]:
            self.assertEqual(payload[payload.index(flag) + 1], expected)
        self.assertIn("--init", payload)
        self.assertNotIn("--entrypoint", payload)
        command = self.api["unit_command"](self.args, self.root / "frozen", "e" * 32)
        self.assertIn("TimeoutStartSec=7200", command)
        self.assertIn("TimeoutStopSec=180", command)
        self.assertIn("RemainAfterExit=yes", command)
        fact = {"available_bytes": 300000000000, "canonical_free_gib": 279,
                "required_bytes": 193273528320, "reclaim_performed": False}
        _frozen, launch = self.install_main_doubles(raw=0)
        with mock.patch.dict(self.globals, require_build_disk=mock.Mock(return_value=fact)) as namespace:
            self.assertEqual(self.api["main"](), 0)
            namespace["require_build_disk"].assert_called_once_with(self.args.output.parent)
        record = json.loads((self.args.output / "invocation.json").read_text())
        self.assertEqual(record["resource_admission"], fact)
        self.assertEqual(record["command"], launch.call_args.args[0])

    def test_parser_admission_is_recorded_with_the_actual_launch(self) -> None:
        self.args.mode = "parsers"
        self.args.protobuf_archive = self.args.msgpack_archive
        fact = {"available_bytes": 300000000000, "canonical_free_gib": 279,
                "required_bytes": 193273528320, "reclaim_performed": False}
        _frozen, launch = self.install_main_doubles(raw=0)
        admission = mock.Mock(return_value=fact)
        with mock.patch.dict(self.globals, require_build_disk=admission):
            self.assertEqual(self.api["main"](), 0)
        admission.assert_called_once_with(self.args.output.parent)
        record = json.loads((self.args.output / "invocation.json").read_text())
        self.assertEqual(record["resource_admission"], fact)
        self.assertEqual(record["command"], launch.call_args.args[0])

    def test_sdk_mode_needs_no_archives_and_is_forwarded(self) -> None:
        argv = ["launcher", "--mode", "sdk", "--output", str(self.args.output),
                "--compiler-cache", str(self.args.compiler_cache), "--unit", self.args.unit,
                "--image", self.args.image]
        with mock.patch("sys.argv", argv):
            args = self.api["arguments"]()
        self.assertIsNone(args.archive)
        payload = self.api["payload"](args, self.root / "frozen", "d" * 32)
        self.assertEqual(payload[-1], "sdk")
        self.assertFalse(any(":/source.tar.gz:" in value for value in payload))
        self.assertFalse(any(":/rocm-cmake.tar.gz:" in value for value in payload))
        with mock.patch("sys.argv", [*argv, "--mode", "invalid"]), self.assertRaises(SystemExit):
            self.api["arguments"]()


    def test_ck_mode_requires_its_two_archives_and_omits_msgpack(self) -> None:
        for mode in ["ck", "rocmlir", "rocmlir-build"]:
            argv = ["launcher", "--mode", mode, "--output", str(self.args.output),
                    "--compiler-cache", str(self.args.compiler_cache), "--unit", self.args.unit,
                    "--image", self.args.image, "--archive", str(self.args.archive),
                    "--rocm-cmake-archive", str(self.args.rocm_cmake_archive)]
            with mock.patch("sys.argv", argv):
                args = self.api["arguments"]()
            payload = self.api["payload"](args, self.root / "frozen", "e" * 32)
            self.assertEqual(payload[-1], mode)
            self.assertIn(f"{args.archive}:/source.tar.gz:ro", payload)
            self.assertIn(f"{args.rocm_cmake_archive}:/rocm-cmake.tar.gz:ro", payload)
            self.assertFalse(any(":/msgpack.tar.gz:" in value for value in payload))
            with (mock.patch("sys.argv", argv[:-2]), mock.patch("sys.stderr"),
                  self.assertRaises(SystemExit) as error):
                self.api["arguments"]()
            self.assertEqual(error.exception.code, 2)



    def test_consumer_prefix_and_original_header_are_required_and_readonly(self) -> None:
        prefix = self.root / "supplied CK prefix"
        prefix.mkdir()
        header = self.root / "original header.hpp"
        header.write_text("original")
        common = self.common_consumer_argv()
        argv = [*common, "--mode", "ck-consumer", "--deps-prefix", str(prefix),
                "--original-header", str(header)]
        with mock.patch("sys.argv", argv):
            args = self.api["arguments"]()
        payload = self.api["payload"](args, self.root / "frozen", "f" * 32)
        self.assertIn(f"{prefix}:/deps-prefix:ro", payload)
        self.assertIn(f"{header}:/ck-original-header.hpp:ro", payload)
        self.assertIn("MIGRAPHX_DEPS_PREFIX=/deps-prefix", payload)
        self.assertEqual(payload[-1], "ck-consumer")
        for invalid in [argv[:-2], argv[:-4], [*argv[:-1], str(prefix)], [*common, "--mode", "sdk", "--original-header", str(header)],
                        [*common, "--mode", "sdk", "--deps-prefix", str(header)]]:
            with (self.subTest(argv=invalid), mock.patch("sys.argv", invalid), mock.patch("sys.stderr"),
                  self.assertRaises(SystemExit) as error):
                self.api["arguments"]()
            self.assertEqual(error.exception.code, 2)
        with mock.patch("sys.argv", [*common, "--mode", "sdk", "--deps-prefix", str(prefix)]):
            sdk = self.api["arguments"]()
        self.assertIsNone(sdk.archive)
        self.assertIn(f"{prefix}:/deps-prefix:ro", self.api["payload"](sdk, self.root / "frozen", "f" * 32))

    def test_unit_keeps_deadlines_and_exact_cleanup_owner(self) -> None:
        source = self.root / "frozen source"
        command = self.api["unit_command"](self.args, source, "b" * 32)
        self.assertIn("--expand-environment=no", command)
        self.assertIn("--unit=fixture-configure.service", command)
        self.assertIn("Type=oneshot", command)
        self.assertIn("RemainAfterExit=yes", command)
        self.assertIn("TimeoutStartSec=300", command)
        self.assertIn("TimeoutStopSec=180", command)
        cleanup = next(value.split("=", 1)[1] for value in command if value.startswith("ExecStopPost="))
        expected = [
            "/usr/bin/python3", str(source / "linux/scripts/cleanup-owned-containers.py"),
            "--engine", "/engine with spaces", "--owner-label", "org.kataglyphis.migraphx-configure",
            "--run-id", "b" * 32, "--cidfile", str(self.args.output / "container.cid"),
            "--output", str(self.args.output / "cleanup.json"),
        ]
        self.assertEqual(shlex.split(cleanup), expected)

    def install_main_doubles(self, state: str = "not-found", raw: int = 37) -> tuple[mock.Mock, mock.Mock]:
        """A fake freezer owns only a disposable test directory; no real Git or unit runs."""
        def freeze(_revision: str, output: Path) -> tuple[Path, str]:
            output.mkdir()
            source = output / "source"
            source.mkdir()
            return source, "c" * 40
        freezer = mock.Mock(side_effect=freeze)
        launch = mock.Mock(return_value=raw)
        patcher = mock.patch.dict(self.globals, {
            "arguments": lambda: self.args, "checked_output": mock.Mock(return_value=state),
            "runpy": SimpleNamespace(run_path=mock.Mock(return_value={"freeze_source": freezer})),
            "subprocess": SimpleNamespace(
                check_output=mock.Mock(return_value=b"exact staged patch"),
                run=mock.Mock(return_value=subprocess.CompletedProcess([], 0)),
            ), "run_logged": launch,
        })
        patcher.start()
        self.addCleanup(patcher.stop)
        return freezer, launch

    def test_busy_unit_refuses_before_freezing_or_launching(self) -> None:
        freezer, launch = self.install_main_doubles("loaded")
        with self.assertRaisesRegex(ValueError, "preserve the existing unit"):
            self.api["main"]()
        freezer.assert_not_called()
        launch.assert_not_called()
        self.assertFalse(self.args.output.exists())

    def test_launch_failure_remains_raw_and_metadata_preserved(self) -> None:
        _freezer, launch = self.install_main_doubles()
        self.assertEqual(self.api["main"](), 37)
        record = json.loads((self.args.output / "invocation.json").read_text())
        self.assertEqual(record["patch_sha256"], hashlib.sha256(b"exact staged patch").hexdigest())
        self.assertEqual(record["head"], "c" * 40)
        self.assertEqual(len(record["run_id"]), 32)
        self.assertEqual(record["command"], launch.call_args.args[0])

    def test_failed_patch_never_starts_a_unit(self) -> None:
        _freezer, launch = self.install_main_doubles()
        self.globals["subprocess"].run.side_effect = subprocess.CalledProcessError(23, ["git"])
        with self.assertRaises(subprocess.CalledProcessError):
            self.api["main"]()
        launch.assert_not_called()
        self.assertFalse((self.args.output / "invocation.json").exists())

    def test_invalid_unit_and_archive_type_refuse(self) -> None:
        argv = [
            str(self.script), "--output", str(self.args.output), "--archive", str(self.args.archive),
            "--rocm-cmake-archive", str(self.args.rocm_cmake_archive),
            "--msgpack-archive", str(self.args.msgpack_archive),
            "--compiler-cache", str(self.args.compiler_cache), "--image", self.args.image,
            "--unit", "fixture.service;unsafe",
        ]
        with (mock.patch("sys.argv", argv), mock.patch("sys.stderr"),
              self.assertRaises(SystemExit) as error):
            self.api["arguments"]()
        self.assertEqual(error.exception.code, 2)
        argv[-1] = "fixture.service"
        argv[argv.index("--archive") + 1] = str(self.args.compiler_cache)
        with (mock.patch("sys.argv", argv), mock.patch("sys.stderr"),
              self.assertRaises(SystemExit) as error):
            self.api["arguments"]()
        self.assertEqual(error.exception.code, 2)


    def test_worker_cleanup_retains_status_and_ownership_failures(self) -> None:
        helper = self.script.parent / "03-media/build/migraphx/proof-cleanup.sh"
        for name, command_status, failing, import_status, expected in [
            ("ok", 0, "", 0, 0), ("child", 37, "", 0, 37),
            ("first", 0, "/first", 0, 1), ("last", 0, "/last", 0, 1),
            ("import", 0, "", 17, 17),
        ]:
            directory = self.root / name
            directory.mkdir()
            (directory / "bind-mount-ownership.sh").write_text(
                "fix_bind_mount_ownership() { printf '%s\\n' \"$1\" >> \"$EVENT_LOG\"; [[ \"$1\" != \"$FAIL_PATH\" ]]; }\n"
                + f"return {import_status}\n"
            )
            call = shlex.join(["migraphx_proof_finish", str(command_status), str(directory), str(directory), "/first", "/last"])
            body = "set -euo pipefail\nsource " + shlex.quote(str(helper)) + "\n" + call + " || exit 99\n"
            result = subprocess.run(["bash", "-c", body], capture_output=True, text=True, check=False, timeout=10,
                                    env=dict(os.environ, LC_ALL="C", EVENT_LOG=str(directory / "events"), FAIL_PATH=failing))
            self.assertEqual(result.returncode, expected, result.stdout + result.stderr)
            self.assertEqual((directory / "command-status.txt").read_text(), str(command_status) + "\n")
            events = directory / "events"
            self.assertEqual(events.read_text().splitlines() if events.exists() else [],
                             [] if import_status else (["/first"] if failing == "/first" else ["/first", "/last"]))

    def test_workers_keep_shared_cleanup_and_container_mount_layout(self) -> None:
        scripts = self.script.parent / "03-media/build/migraphx"
        for name, paths in [("configure-proof.sh", "/proof /cache"), ("source-proof.sh", "/workspace /proof /cache /quality-cache")]:
            text = (scripts / name).read_text()
            self.assertIn('source "${SCRIPT_DIR}/proof-cleanup.sh"', text)
            self.assertIn('trap \'migraphx_proof_finish "$?" /proof /hub/linux/scripts/01-core ' + paths + "' EXIT", text)


    def test_cleanup_cannot_pass_when_status_receipt_cannot_be_written(self) -> None:
        helper = self.script.parent / "03-media/build/migraphx/proof-cleanup.sh"
        absent = self.root / "missing evidence directory"
        (self.root / "bind-mount-ownership.sh").write_text("fix_bind_mount_ownership() { return 0; }\n")
        body = "set -euo pipefail\nsource " + shlex.quote(str(helper)) + "\n"
        body += shlex.join(["migraphx_proof_finish", "0", str(absent), str(self.root), "/first"]) + " || exit 99\n"
        result = subprocess.run(["bash", "-c", body], capture_output=True, text=True, check=False, timeout=10)
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertFalse(absent.exists())


    def common_consumer_argv(self) -> list[str]:
        return ["launcher", "--output", str(self.args.output), "--compiler-cache", str(self.args.compiler_cache),
                "--unit", self.args.unit, "--image", self.args.image]

    def test_python_consumer_requires_one_readonly_source_without_archives(self) -> None:
        source = self.root / "MIGraphX original source"
        source.mkdir()
        common = self.common_consumer_argv()
        argv = [*common, "--mode", "python-consumer", "--original-source", str(source)]
        with mock.patch("sys.argv", argv):
            args = self.api["arguments"]()
        payload = self.api["payload"](args, self.root / "frozen", "d" * 32)
        self.assertEqual(payload[-1], "python-consumer")
        self.assertIn(f"{source}:/migraphx-original-source:ro", payload)
        self.assertFalse(any(":/source.tar.gz:" in value for value in payload))
        for bad in [argv[:-2], [*argv[:-1], str(self.args.archive)],
                    [*argv, "--deps-prefix", str(self.args.compiler_cache)],
                    [*argv, "--original-header", str(self.args.archive)]]:
            with (mock.patch("sys.argv", bad), mock.patch("sys.stderr"), self.assertRaises(SystemExit) as error):
                self.api["arguments"]()
            self.assertEqual(error.exception.code, 2)

    def test_rocmlir_consumer_requires_both_readonly_inputs_without_archives(self) -> None:
        prefix = self.root / "rocmlir prefix"
        source = self.root / "rocmlir original source"
        prefix.mkdir()
        source.mkdir()
        common = self.common_consumer_argv()
        argv = [*common, "--mode", "rocmlir-consumer", "--deps-prefix", str(prefix), "--original-source", str(source)]
        with mock.patch("sys.argv", argv):
            args = self.api["arguments"]()
        payload = self.api["payload"](args, self.root / "frozen", "f" * 32)
        self.assertEqual(payload[-1], "rocmlir-consumer")
        self.assertIn(f"{prefix}:/deps-prefix:ro", payload)
        self.assertIn(f"{source}:/rocmlir-original-source:ro", payload)
        self.assertFalse(any(":/source.tar.gz:" in value for value in payload))
        for bad in [argv[:-2], [*common, "--mode", "rocmlir-consumer", "--original-source", str(source)],
                    [*argv[:-1], str(self.args.archive)],
                    [*common, "--mode", "sdk", "--original-source", str(source)],
                    [*common, "--mode", "rocmlir-consumer", "--deps-prefix", str(prefix),
                     "--original-source", str(source), "--original-header", str(self.args.archive)]]:
            with (mock.patch("sys.argv", bad), mock.patch("sys.stderr"), self.assertRaises(SystemExit) as error):
                self.api["arguments"]()
            self.assertEqual(error.exception.code, 2)


if __name__ == "__main__":
    unittest.main()
