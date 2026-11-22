# Copyright (c) 2026 Kataglyphis
# SPDX-License-Identifier: MIT
"""Check synthetic image original transport and refusal; no actual image, package or complete licence acceptance."""

from __future__ import annotations

import hashlib
import json
import os
import shutil
import subprocess
import sys
import unittest
from pathlib import Path

from gstreamer_notice_tests import SourceNoticeFixture


class ImageOriginalFixture(SourceNoticeFixture):
    def setUp(self) -> None:
        super().setUp()
        self.image = self.root / "image prefix"
        self.gst_root = self.image / "share/licenses/gstreamer-source-build"
        for kind, name in (("monorepo", "monorepo"), ("rust", "rust-standalone")):
            self.output = self.gst_root / name
            result = self.run_stage(kind)
            self.assertEqual(result.returncode, 0, result.stderr)
        self.output = self.root / "bundle originals"
        self.packager = (
            self.subject.parents[4] / "06-packaging/stage-image-source-originals.py"
        )
        self.gcc_root = self.image / "share/licenses/gcc-runtime"
        self.gcc_root.mkdir(parents=True)
        self.gcc_policy = self.packager.with_name("gcc-runtime-originals.json")
        policy = json.loads(self.gcc_policy.read_text())
        for name in policy["files"]:
            data = b"synthetic original\r\n\xff " + name.encode() + b"\n"
            (self.gcc_root / name).write_bytes(data)
            policy["files"][name] = hashlib.sha256(data).hexdigest()
        (self.gcc_root / "source.sha512").write_text(
            policy["archive_sha512"] + "  gcc-16.2.0.tar.xz\n"
        )
        (self.gcc_root / "source.url").write_text(
            "https://gcc.gnu.org/pub/gcc/releases/gcc-16.2.0/gcc-16.2.0.tar.xz\n"
        )
        self.gcc_policy = self.root / "gcc-policy.json"
        self.gcc_policy.write_text(json.dumps(policy))

    def transport(self, *extra: str) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            [
                sys.executable,
                "-B",
                str(self.packager),
                "--destination",
                str(self.output),
                "--gcc-prefix",
                str(self.image),
                "--gcc-version",
                "16.2.0",
                "--gcc-policy",
                str(self.gcc_policy),
                "--gstreamer-prefix",
                str(self.image),
                "--gstreamer-version",
                "1.29.2",
                "--gstreamer-policy",
                str(self.policy_file),
                *extra,
            ],
            text=True,
            capture_output=True,
            check=False,
        )

    def deny(self, *extra: str) -> None:
        result = self.transport(*extra)
        self.assertNotEqual(result.returncode, 0, result.stdout)
        self.assertIn("Image source original staging refused:", result.stderr)
        self.assertFalse(self.output.exists())

    def change_record(self, field: str, value: object, kind: str = "monorepo") -> None:
        path = self.gst_root / kind / "source-record.json"
        record = json.loads(path.read_text())
        record[field] = value
        path.write_text(json.dumps(record))


class ImageOriginalTests(ImageOriginalFixture):
    def test_exact_transport_and_empty_patch(self) -> None:
        result = self.transport()
        self.assertEqual(result.returncode, 0, result.stderr)
        expected = {}
        for root, name in (
            (self.gcc_root, "gcc-runtime"),
            (self.gst_root, "gstreamer-source-build"),
        ):
            for path in root.rglob("*"):
                if path.is_file():
                    relative = name + "/" + path.relative_to(root).as_posix()
                    data = path.read_bytes()
                    self.assertEqual((self.output / relative).read_bytes(), data)
                    expected[relative] = {
                        "sha256": hashlib.sha256(data).hexdigest(),
                        "bytes": len(data),
                    }
        record = json.loads((self.output / "source-originals.json").read_text())
        self.assertEqual(record["files"], expected)
        self.assertFalse(
            record["binary_linkage_or_complete_license_source_closure_proven"]
        )

    def test_policies_match_current_pins(self) -> None:
        policy = json.loads(
            self.packager.with_name("gcc-runtime-originals.json").read_text()
        )
        pins = (
            (self.subject.parents[4] / "01-core/versions.env").read_text().splitlines()
        )
        self.assertIn("GCC_VERSION=" + policy["release"], pins)
        self.assertEqual(set(policy["files"]), {"COPYING3", "COPYING.RUNTIME"})

    def test_single_component_selections(self) -> None:
        for component, version, policy in (
            ("gcc", "16.2.0", self.gcc_policy),
            ("gstreamer", "1.29.2", self.policy_file),
        ):
            output = self.root / component
            result = subprocess.run(
                [
                    sys.executable,
                    "-B",
                    str(self.packager),
                    "--destination",
                    str(output),
                    "--" + component + "-prefix",
                    str(self.image),
                    "--" + component + "-version",
                    version,
                    "--" + component + "-policy",
                    str(policy),
                ],
                capture_output=True,
                check=False,
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(
                {path.name for path in output.iterdir()},
                {
                    "source-originals.json",
                    "gcc-runtime" if component == "gcc" else "gstreamer-source-build",
                },
            )

    def test_no_selected_component(self) -> None:
        result = subprocess.run(
            [
                sys.executable,
                "-B",
                str(self.packager),
                "--destination",
                str(self.output),
            ],
            capture_output=True,
            check=False,
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(self.output.exists())

    def test_destination_inside_image(self) -> None:
        self.output = self.image / "output"
        self.deny()

    def test_required_gst_companion(self) -> None:
        relative = "03-media/build/gstreamer/common/stage-original-notices.py"
        scripts = self.mirror_scripts(
            relative,
            "01-core/source_originals.py",
            "06-packaging/stage-image-source-originals.py",
        )
        companion = scripts / relative
        original = companion.read_text()
        for changed, expected in (
            (original, 0),
            (
                original.replace(
                    "GSTREAMER_SOURCE_NOTICES_API = 1",
                    "GSTREAMER_SOURCE_NOTICES_API = 0",
                ),
                1,
            ),
            (original + "\nrust_package = None\n", 1),
        ):
            companion.write_text(changed)
            result = subprocess.run(
                [
                    sys.executable,
                    "-B",
                    str(scripts / "06-packaging/stage-image-source-originals.py"),
                    "--help",
                ],
                capture_output=True,
                check=False,
            )
            self.assertEqual(result.returncode, expected, result.stderr)

    def test_changed_gcc_notice(self) -> None:
        (self.gcc_root / "COPYING3").write_bytes(b"replacement\n")
        self.deny()

    def test_gcc_version(self) -> None:
        self.deny("--gcc-version", "16.2.999")

    def test_gcc_policy_release(self) -> None:
        policy = json.loads(self.gcc_policy.read_text())
        policy["release"] = "16.2.999"
        self.gcc_policy.write_text(json.dumps(policy))
        self.deny()

    def test_gcc_checksum(self) -> None:
        (self.gcc_root / "source.sha512").write_text(
            "0" * 128 + "  gcc-16.2.0.tar.xz\n"
        )
        self.deny()

    def test_gcc_url(self) -> None:
        (self.gcc_root / "source.url").write_text(
            "https://example.invalid/gcc.tar.xz\n"
        )
        self.deny()

    def test_missing_gcc_notice(self) -> None:
        (self.gcc_root / "COPYING.RUNTIME").unlink()
        self.deny()

    def test_unknown_gcc_member(self) -> None:
        (self.gcc_root / "unexpected").write_text("surprise\n")
        self.deny()

    def test_changed_gst_original(self) -> None:
        notice = self.gst_root / "monorepo/LICENSE"
        notice.write_bytes(b"x" * len(notice.read_bytes()))
        self.deny()

    def test_gst_record_identity(self) -> None:
        self.change_record("source_commit", "0" * 40)
        self.deny()

    def test_gst_record_scope(self) -> None:
        self.change_record(
            "binary_linkage_or_complete_license_source_closure_proven", True
        )
        self.deny()

    def test_gst_original_record(self) -> None:
        record = json.loads((self.gst_root / "monorepo/source-record.json").read_text())
        record["files"]["LICENSE"]["bytes"] += 1
        self.change_record("files", record["files"])
        self.deny()

    def test_gst_working_hash(self) -> None:
        (self.gst_root / "rust-standalone/working-context/Cargo.toml").write_text(
            "changed\n"
        )
        self.deny()

    def test_gst_working_gtk_record(self) -> None:
        self.change_record("gtk4_package", {}, "rust-standalone")
        self.deny()

    def test_gst_working_paths(self) -> None:
        self.change_record("working_context_sha256", {}, "rust-standalone")
        self.deny()

    def test_gst_original_paths(self) -> None:
        self.change_record("files", {})
        self.deny()

    def test_extra_gst_record_path(self) -> None:
        record = json.loads((self.gst_root / "monorepo/source-record.json").read_text())
        record["files"]["unselected"] = {}
        self.change_record("files", record["files"])
        self.deny()

    def test_changed_patch(self) -> None:
        (self.gst_root / "monorepo/source.patch").write_bytes(b"changed patch\n")
        self.deny()

    def test_oversized_patch(self) -> None:
        patch = b"x" * (8 * 1024 * 1024 + 1)
        (self.gst_root / "monorepo/source.patch").write_bytes(patch)
        self.change_record("source_patch_sha256", hashlib.sha256(patch).hexdigest())
        self.deny()

    def test_unknown_gst_member(self) -> None:
        (self.gst_root / "monorepo/unexpected").write_text("surprise\n")
        self.deny()

    def test_ambiguous_rust_source(self) -> None:
        shutil.copytree(
            self.gst_root / "rust-standalone", self.gst_root / "rust-monorepo"
        )
        self.deny()

    def test_missing_rust_source(self) -> None:
        shutil.rmtree(self.gst_root / "rust-standalone")
        self.deny()

    def test_linked_notice(self) -> None:
        notice = self.gcc_root / "COPYING3"
        notice.rename(self.root / "elsewhere")
        notice.symlink_to(self.root / "elsewhere")
        self.deny()

    def test_hardlinked_notice(self) -> None:
        os.link(self.gcc_root / "COPYING3", self.root / "shared-notice")
        self.deny()

    def test_linked_tree(self) -> None:
        source = self.gst_root / "monorepo"
        source.rename(self.root / "elsewhere")
        source.symlink_to(self.root / "elsewhere", target_is_directory=True)
        self.deny()

    def test_reused_output(self) -> None:
        self.output.mkdir()
        result = self.transport()
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(list(self.output.iterdir()), [])

    def test_duplicate_record_keys(self) -> None:
        path = self.gst_root / "monorepo/source-record.json"
        path.write_text(
            path.read_text().replace(
                '"kind": "monorepo"', '"kind": "monorepo", "kind": "monorepo"'
            )
        )
        self.deny()

    def test_unpaired_selection(self) -> None:
        result = subprocess.run(
            [
                sys.executable,
                "-B",
                str(self.packager),
                "--destination",
                str(self.output),
                "--gcc-version",
                "16.2.0",
                "--gstreamer-prefix",
                str(self.image),
                "--gstreamer-version",
                "1.29.2",
                "--gstreamer-policy",
                str(self.policy_file),
            ],
            capture_output=True,
            check=False,
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(self.output.exists())


if __name__ == "__main__":
    ImageOriginalTests.subject, ImageOriginalTests.fixture = map(Path, sys.argv[1:3])
    unittest.main(argv=[sys.argv[0]], verbosity=2)
