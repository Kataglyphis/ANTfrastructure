# Copyright (c) 2026 Kataglyphis
# SPDX-License-Identifier: MIT
"""Check synthetic finished archive bytes and native extraction transport; no actual application or complete licence acceptance."""

from __future__ import annotations

import hashlib
import json
import os
import platform
import shutil
import subprocess
import sys
import unittest
from pathlib import Path

from image_source_original_tests import ImageOriginalFixture
from package_archive_fixture import write_tar, write_zip


class PackageOriginalTests(ImageOriginalFixture):
    def setUp(self) -> None:
        super().setUp()
        result = self.transport()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.originals = self.output
        self.prefix = "app/licenses/image-source-originals"
        self.verifier = self.packager.with_name("verify-image-source-originals.py")
        self.package = self.root / "package with space.zip"
        self.env = dict(os.environ)
        self.repack()

    def entries(self) -> list[tuple[str, bytes]]:
        return [
            (
                self.prefix + "/" + path.relative_to(self.originals).as_posix(),
                path.read_bytes(),
            )
            for path in self.originals.rglob("*")
            if path.is_file()
        ]

    def repack(self) -> None:
        write_zip(self.package, self.entries())

    def record(self, **changes: object) -> None:
        path = self.originals / "source-originals.json"
        value = json.loads(path.read_text())
        value.update(changes)
        path.write_text(json.dumps(value))
        self.repack()

    def update_file(
        self, name: str, data: bytes, *, bytes_value: int | bool | None = None
    ) -> None:
        (self.originals / name).write_bytes(data)
        path = self.originals / "source-originals.json"
        value = json.loads(path.read_text())
        value["files"][name] = {
            "sha256": hashlib.sha256(data).hexdigest(),
            "bytes": len(data) if bytes_value is None else bytes_value,
        }
        self.record(files=value["files"])

    def check_package(self, *extra: str) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            [
                sys.executable,
                "-B",
                str(self.verifier),
                str(self.package),
                "--originals",
                str(self.originals),
                "--prefix",
                self.prefix,
                *extra,
            ],
            env=self.env,
            capture_output=True,
            text=True,
            check=False,
        )

    def reject(self, *extra: str, status: int = 1) -> None:
        result = self.check_package(*extra)
        self.assertEqual(result.returncode, status, result.stdout + result.stderr)
        self.assertNotIn(
            '"status": "selected-source-original-package-bytes-match"', result.stdout
        )

    def test_zip_exact_originals_and_empty_patch(self) -> None:
        result = self.check_package()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn(
            '"status": "selected-source-original-package-bytes-match"', result.stdout
        )

    def test_tar_exact_originals(self) -> None:
        self.package = self.root / "originals.tar.gz"
        write_tar(self.package, self.entries())
        result = self.check_package()
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_real_deb_payload(self) -> None:
        if shutil.which("dpkg-deb") is None:
            self.skipTest("dpkg-deb is required for this synthetic DEB")
        tree = self.root / "deb-tree"
        shutil.copytree(self.originals, tree / self.prefix)
        (tree / "DEBIAN").mkdir()
        (tree / "DEBIAN/control").write_text(
            "Package: source-original-fixture\nVersion: 1\nArchitecture: all\nMaintainer: Fixture <fixture@example.invalid>\nDescription: Synthetic originals\n"
        )
        self.package = self.root / "originals.deb"
        subprocess.run(
            [
                "dpkg-deb",
                "--root-owner-group",
                "-Zgzip",
                "--build",
                str(tree),
                str(self.package),
            ],
            capture_output=True,
            check=True,
        )
        result = self.check_package()
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_missing_empty_patch(self) -> None:
        member = self.prefix + "/gstreamer-source-build/monorepo/source.patch"
        write_zip(
            self.package,
            [(name, data) for name, data in self.entries() if name != member],
        )
        self.reject()

    def test_changed_delivered_empty_patch(self) -> None:
        member = self.prefix + "/gstreamer-source-build/monorepo/source.patch"
        write_zip(
            self.package,
            [
                (name, b"changed" if name == member else data)
                for name, data in self.entries()
            ],
        )
        self.reject()

    def test_missing_delivered_source_record(self) -> None:
        member = self.prefix + "/source-originals.json"
        write_zip(
            self.package,
            [(name, data) for name, data in self.entries() if name != member],
        )
        self.reject()

    def test_text_normalization_does_not_excuse_changed_bytes(self) -> None:
        member = self.prefix + "/gcc-runtime/COPYING3"
        write_zip(
            self.package,
            [
                (name, data.replace(b"\r\n", b"\n") if name == member else data)
                for name, data in self.entries()
            ],
        )
        self.reject()

    def test_staged_hash_is_independent_of_package_equality(self) -> None:
        path = self.originals / "gcc-runtime/COPYING3"
        path.write_bytes(b"x" * path.stat().st_size)
        self.repack()
        self.reject()

    def test_empty_license_cannot_use_patch_permission(self) -> None:
        self.update_file("gcc-runtime/COPYING3", b"")
        self.reject()

    def test_boolean_byte_count_is_not_an_integer_record(self) -> None:
        self.update_file("gcc-runtime/COPYING3", b"x", bytes_value=True)
        self.reject()

    def test_oversized_recorded_patch(self) -> None:
        self.update_file(
            "gstreamer-source-build/monorepo/source.patch", b"x" * (8 * 1024 * 1024 + 1)
        )
        self.reject()

    def test_record_identity(self) -> None:
        self.record(status="unrelated")
        self.reject()

    def test_record_scope(self) -> None:
        self.record(binary_linkage_or_complete_license_source_closure_proven=True)
        self.reject()

    def test_empty_file_record(self) -> None:
        for path in sorted(self.originals.rglob("*"), reverse=True):
            if path.is_file() and path.name != "source-originals.json":
                path.unlink()
        self.record(files={})
        self.reject()

    def test_unlisted_staged_member(self) -> None:
        (self.originals / "unexpected").write_bytes(b"unlisted")
        self.repack()
        self.reject()

    def test_unsafe_prefix(self) -> None:
        self.prefix = "../escape"
        self.reject()

    def appimage(self) -> None:
        if sys.platform != "linux" or platform.machine() not in ("x86_64", "aarch64"):
            self.skipTest("native Linux amd64/arm64 extraction transport")
        tree = self.root / "appimage-tree"
        shutil.copytree(self.originals, tree / self.prefix)
        fixtures = Path(__file__).with_name("fixtures")
        self.package = self.root / "fixture.AppImage"
        shutil.copyfile(fixtures / "appimage-source-tree.sh", self.package)
        self.package.chmod(0o755)
        self.env.update(
            APPIMAGE_SOURCE_TREE=str(tree),
            APPIMAGE_SELECTED_FILE_FIXTURE=str(fixtures / "appimage-selected-file.sh"),
            APPIMAGE_TRACE=str(self.root / "trace"),
        )

    def test_native_appimage_selected_files(self) -> None:
        self.appimage()
        result = self.check_package("--appimage-arch", platform.machine())
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_native_appimage_raw_failure(self) -> None:
        self.appimage()
        self.env["APPIMAGE_FIXTURE"] = "fail"
        self.reject("--appimage-arch", platform.machine(), status=15)

    def test_native_appimage_missing_empty_patch(self) -> None:
        self.appimage()
        (
            Path(self.env["APPIMAGE_SOURCE_TREE"])
            / self.prefix
            / "gstreamer-source-build/monorepo/source.patch"
        ).unlink()
        self.reject("--appimage-arch", platform.machine())

    def test_native_appimage_changed_source_record(self) -> None:
        self.appimage()
        (
            Path(self.env["APPIMAGE_SOURCE_TREE"])
            / self.prefix
            / "source-originals.json"
        ).write_text("changed\n")
        self.reject("--appimage-arch", platform.machine())

    def test_required_verification_companions(self) -> None:
        relative = "06-packaging/verify-image-source-originals.py"
        scripts = self.mirror_scripts(
            relative,
            "06-packaging/stage-image-source-originals.py",
            "03-media/build/gstreamer/common/stage-original-notices.py",
            "01-core/source_originals.py",
            "verify_package_binary.py",
            "verify_package_license.py",
        )
        stager = scripts / "06-packaging/stage-image-source-originals.py"
        binary = scripts / "verify_package_binary.py"
        original_stager, original_binary = stager.read_text(), binary.read_text()
        for staged, checked, expected in (
            (original_stager, original_binary, 0),
            (
                original_stager.replace(
                    "IMAGE_SOURCE_ORIGINALS_API = 1", "IMAGE_SOURCE_ORIGINALS_API = 0"
                ),
                original_binary,
                1,
            ),
            (
                original_stager,
                original_binary.replace(
                    "PACKAGE_BINARY_EMPTY_API = 1", "PACKAGE_BINARY_EMPTY_API = 0"
                ),
                1,
            ),
            (original_stager, original_binary + "\nexact_name = None\n", 1),
        ):
            stager.write_text(staged)
            binary.write_text(checked)
            result = subprocess.run(
                [sys.executable, "-B", str(scripts / relative), "--help"],
                capture_output=True,
                check=False,
            )
            self.assertEqual(result.returncode, expected, result.stderr)

    def flatpak(self) -> None:
        tools = self.root / "tools"
        tools.mkdir()
        fixture = Path(__file__).with_name("fixtures") / "flatpak-package-tool.sh"
        for name in ("flatpak", "ostree"):
            shutil.copyfile(fixture, tools / name)
            (tools / name).chmod(0o755)
        tree = self.root / "flatpak-tree"
        shutil.copytree(self.originals, tree / self.prefix)
        self.package = self.root / "fixture.flatpak"
        self.package.write_bytes(b"controlled import")
        self.env.update(
            PATH=str(tools) + os.pathsep + self.env["PATH"], FAKE_FLATPAK_TREE=str(tree)
        )

    def test_flatpak_uses_the_shared_private_checkout(self) -> None:
        self.flatpak()
        result = self.check_package()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_flatpak_import_failure(self) -> None:
        self.flatpak()
        self.env["FAKE_FLATPAK_RC"] = "7"
        self.reject()

    def test_flatpak_ambiguous_refs(self) -> None:
        self.flatpak()
        self.env["FAKE_REF"] = "app/a/x/stable\napp/b/x/stable"
        self.reject()

    def test_flatpak_checkout_failure(self) -> None:
        self.flatpak()
        self.env["FAKE_OSTREE_CHECKOUT_RC"] = "19"
        self.reject()


if __name__ == "__main__":
    PackageOriginalTests.subject, PackageOriginalTests.fixture = map(
        Path, sys.argv[1:3]
    )
    unittest.main(argv=[sys.argv[0]], verbosity=2)
