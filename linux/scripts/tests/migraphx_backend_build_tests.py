"""Installed-tree and shell lifecycle controls use a tiny native DSO, not a built MIGraphX or GPU backend."""

import argparse
import hashlib
import io
import json
import os
import runpy
import shutil
import subprocess
import sys
import sysconfig
import tarfile
import tempfile
import unittest
from pathlib import Path
from types import SimpleNamespace
from unittest import mock

ROOT = Path(__file__).resolve().parents[3]
LIB = ROOT / "linux/scripts/03-media/build/migraphx"


class MigraphxBackendInstallTests(unittest.TestCase):
    """Required outputs and original notices have independent inputs and failure controls."""

    @classmethod
    def setUpClass(cls) -> None:
        temporary = tempfile.TemporaryDirectory(prefix="backend native fixture ")
        cls.addClassCleanup(temporary.cleanup)
        cls.native = Path(temporary.name) / "libfixture.so"
        compiler = shutil.which("cc")
        if compiler is None:
            raise AssertionError("A native fixture compiler is required")
        result = subprocess.run([compiler, "-shared", "-fPIC", "-x", "c", "-", "-o", str(cls.native)],
                                input=b"int backend_fixture(void) { return 1; }\n",
                                capture_output=True, check=False, timeout=30)
        if result.returncode:
            raise AssertionError(result.stderr.decode())

    def setUp(self) -> None:
        temporary = tempfile.TemporaryDirectory(prefix="backend install case ")
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.api = runpy.run_path(str(LIB / "stage-backend-install.py"))
        self.prefix = self.root / "installed prefix"
        self.work = self.root / "work"
        (self.work / "build").mkdir(parents=True)
        (self.prefix / "lib/cmake/migraphx").mkdir(parents=True)
        (self.prefix / "include/migraphx").mkdir(parents=True)
        self.libraries = ("migraphx", "migraphx_c", "migraphx_gpu", "migraphx_ref",
                          "migraphx_onnx", "migraphx_tf", "migraphx_py")
        self.payloads = ["include/migraphx/migraphx.h", "include/migraphx/version.h",
                         "lib/cmake/migraphx/migraphx-config.cmake"]
        for name in self.payloads:
            (self.prefix / name).write_text("fixture payload\n")
        version = "#define MIGRAPHX_VERSION_MAJOR 2\n#define MIGRAPHX_VERSION_MINOR 18\n#define MIGRAPHX_VERSION_PATCH 0\n"
        (self.prefix / "include/migraphx/version.h").write_text(version)
        shutil.copy2(self.native, self.prefix / "lib/native-fixture.so")
        for name in self.libraries:
            (self.prefix / ("lib/lib" + name + ".so")).symlink_to("native-fixture.so")
        self.module_name = "lib/migraphx" + sysconfig.get_config_var("EXT_SUFFIX")
        shutil.copy2(self.native, self.prefix / self.module_name)
        self.manifest = self.work / "build/install_manifest.txt"
        self.refresh_manifest()
        self.dependencies = [self.root / "parser deps", self.root / "kernel deps", self.root / "rocMLIR deps"]
        self.policy = self.root / "notice policies"
        self.policy.mkdir()
        self.prepare_notices()
        self.pybind_distribution = SimpleNamespace(version="3.1.0", files=[self.pybind_entry], locate_file=lambda value: self.pybind_root / value)
        self.api["stage"].__globals__["distribution"] = mock.Mock(return_value=self.pybind_distribution)
        self.args = argparse.Namespace(prefix=self.prefix, work=self.work, deps_prefix=";".join(map(str, self.dependencies)),
                                       version="2.18.0", pybind_version="3.1.0", source_commit="a" * 40, source_sha256="", patch=self.root / "fix.patch", python_patch=self.root / "python-selector.patch")
        self.args.patch.write_text("original tracked modification\n")
        self.args.python_patch.write_text("selected interpreter patch\n")
        self.archive_license(b"original backend notice\r\n")
        self.api["stage"].__globals__["POLICY_DIR"] = self.policy
        self.destination = self.prefix / "share/licenses/migraphx-source-build"

    def refresh_manifest(self) -> None:
        files = [str(path) for path in self.prefix.rglob("*") if path.is_symlink() or path.is_file()]
        self.manifest.write_text("\n".join(files) + "\n")

    def prepare_notices(self) -> None:
        components = {"msgpack": self.work / "host-tools", "rocm-cmake": self.work / "host-tools",
                      "abseil": self.dependencies[0], "protobuf": self.dependencies[0], "utf8_range": self.dependencies[0],
                      "ck": self.dependencies[1], "rocmlir": self.dependencies[2]}
        self.pybind_root = self.root / "selected Python site-packages"
        self.pybind_entry = Path("pybind11-3.1.0.dist-info/licenses/LICENSE")
        cmake_dir = self.pybind_root / "pybind11/share/cmake/pybind11"
        cmake_dir.mkdir(parents=True)
        (cmake_dir / "pybind11Config.cmake").write_text("selected package")
        (self.work / "build/CMakeCache.txt").write_text(f"pybind11_DIR:PATH={cmake_dir}\n")
        names = ["abseil/LICENSE", "protobuf/LICENSE", "utf8_range/LICENSE", "ck/LICENSE",
                 "rocmlir/LICENSE", "rocm-cmake/LICENSE", "msgpack/COPYING", "msgpack/LICENSE_1_0.txt"]
        rows = []
        for name in names:
            component, relative = name.split("/", 1)
            file = components[component] / "share/licenses" / component / relative
            file.parent.mkdir(parents=True, exist_ok=True)
            file.write_bytes(("original " + name + "\r\n").encode())
            rows.append(hashlib.sha256(file.read_bytes()).hexdigest() + "  " + name)
        notice = self.pybind_root / self.pybind_entry
        notice.parent.mkdir(parents=True)
        notice.write_bytes(b"original pybind11 notice\r\n")
        rows.append(hashlib.sha256(notice.read_bytes()).hexdigest() + "  pybind11/LICENSE")
        (self.policy / "backend-source-notices.sha256").write_text("\n".join(rows) + "\n")
        rocmlir = components["rocmlir"] / "share/licenses/rocmlir"
        rows = []
        for name in ["LICENSE", "external/llvm-project/LICENSE.TXT", "external/triton/LICENSE"]:
            file = rocmlir / name
            file.parent.mkdir(parents=True, exist_ok=True)
            if not file.exists():
                file.write_bytes(("original " + name + "\r\n").encode())
            rows.append(hashlib.sha256(file.read_bytes()).hexdigest() + "  " + name)
        policy = "\n".join(rows) + "\n"
        (self.policy / "rocmlir-source-notices.sha256").write_text(policy)
        (rocmlir / "SOURCE-NOTICE-SHA256SUMS").write_text(policy)

    def archive_license(self, raw: bytes) -> None:
        (self.work / "source").mkdir(exist_ok=True)
        (self.work / "source/LICENSE").write_bytes(raw)
        with tarfile.open(self.work / "source.tar.gz", "w:gz") as archive:
            member = tarfile.TarInfo("pinned-source/LICENSE")
            member.size = len(raw)
            archive.addfile(member, io.BytesIO(raw))
        self.args.source_sha256 = hashlib.sha256((self.work / "source.tar.gz").read_bytes()).hexdigest()

    def test_fresh_absolute_prefix_only_and_alias_refusals(self) -> None:
        check = self.api["check_prefix"]
        check(self.root / "fresh target")
        broken = self.root / "broken alias"
        broken.symlink_to(self.root / "missing")
        for path in [Path("relative"), self.prefix, Path("/"), broken, self.root / "absent/../installed prefix"]:
            with self.subTest(path=path), self.assertRaises(ValueError):
                check(path)

    def test_complete_install_stages_exact_originals_patch_and_false_review_verdict(self) -> None:
        self.api["stage"](self.args)
        proof = json.loads((self.destination / "build-provenance.json").read_text())
        self.assertEqual(proof["version"], "2.18.0")
        self.assertEqual(proof["source_commit"], "a" * 40)
        self.assertEqual(proof["source_archive_sha256"], self.args.source_sha256)
        self.assertFalse(proof["complete_binary_licence_review"])
        self.assertEqual(proof["pybind11_version"], "3.1.0")
        self.assertEqual((self.destination / "pybind11/LICENSE").read_bytes(), (self.pybind_root / self.pybind_entry).read_bytes())
        self.assertEqual(proof["python_selection_patch_sha256"],
                         hashlib.sha256(self.args.python_patch.read_bytes()).hexdigest())
        self.assertEqual((self.destination / "migraphx/python-selection.patch").read_bytes(),
                         self.args.python_patch.read_bytes())
        self.assertEqual(len(proof["installed_files"]), 12)
        for name, expected in proof["original_notices"].items():
            self.assertEqual(hashlib.sha256((self.destination / name).read_bytes()).hexdigest(), expected)
        self.assertEqual((self.destination / "migraphx/LICENSE").read_bytes(), (self.work / "source/LICENSE").read_bytes())
        self.assertEqual((self.destination / "migraphx/applied.patch").read_bytes(), self.args.patch.read_bytes())
        original = (self.destination / "build-provenance.json").read_bytes()
        with self.assertRaises(ValueError):
            self.api["stage"](self.args)
        self.assertEqual((self.destination / "build-provenance.json").read_bytes(), original)

    def test_pybind_version_files_and_cmake_origin_are_required(self) -> None:
        package = self.pybind_distribution
        original = package.files
        cache = self.work / "build/CMakeCache.txt"
        raw = cache.read_text()
        for field, value in [("version", "3.0.0"), ("files", []), ("files", original * 2),
                             ("files", [Path("../") / original[0]])]:
            with self.subTest(field=field, value=value), mock.patch.object(package, field, value), self.assertRaises(ValueError):
                self.api["stage"](self.args)
            self.assertFalse(self.destination.exists())
        for text in ["", raw + raw, "pybind11_DIR:PATH=/foreign/package\n"]:
            cache.write_text(text)
            with self.subTest(cache=text), self.assertRaises(ValueError):
                self.api["stage"](self.args)
            self.assertFalse(self.destination.exists())
        cache.write_text(raw)
        (self.pybind_root / "pybind11/share/cmake/pybind11/pybind11Config.cmake").unlink()
        with self.assertRaises(ValueError):
            self.api["stage"](self.args)
        self.assertFalse(self.destination.exists())

    def test_pybind_notice_traversal_refuses_even_matching_external_original_bytes(self) -> None:
        outside = self.pybind_root.parent / self.pybind_entry
        outside.parent.mkdir(parents=True)
        outside.write_bytes((self.pybind_root / self.pybind_entry).read_bytes())
        with (mock.patch.object(self.pybind_distribution, "files", [Path("..") / self.pybind_entry]),
              self.assertRaisesRegex(ValueError, "Invalid pybind11 notice path")):
            self.api["stage"](self.args)
        self.assertFalse(self.destination.exists())

    def test_production_pybind_notice_policy_matches_original_fixture(self) -> None:
        fixture = ROOT / "linux/scripts/tests/fixtures/pybind11-license"
        source = json.loads((fixture / "source.json").read_text())
        digest = hashlib.sha256((fixture / "LICENSE.txt").read_bytes()).hexdigest()
        self.assertEqual(digest, source["sha256"])
        pins = (ROOT / "linux/scripts/01-core/versions.env").read_text()
        self.assertIn("PY_PYBIND11_VERSION=" + source["version"] + "\n", pins)
        rows = [line.split() for line in (LIB / "backend-source-notices.sha256").read_text().splitlines()
                if line and not line.startswith("#")]
        self.assertEqual([row[0] for row in rows if row[1] == "pybind11/LICENSE"], [digest])

    def test_pybind_missing_package_notice_and_symlink_are_rejected(self) -> None:
        require_notice = self.api["pybind_notice_root"]
        namespace = require_notice.__globals__
        with (mock.patch.dict(namespace, distribution=mock.Mock(side_effect=namespace["PackageNotFoundError"]("pybind11"))),
              self.assertRaisesRegex(ValueError, "no pybind11 distribution")):
            require_notice(self.work, "3.1.0")
        notice = self.pybind_root / self.pybind_entry
        raw = notice.read_bytes()
        notice.unlink()
        with self.assertRaises(ValueError):
            require_notice(self.work, "3.1.0")
        external = self.root / "external notice"
        external.write_bytes(raw)
        notice.symlink_to(external)
        with self.assertRaises(ValueError):
            require_notice(self.work, "3.1.0")
        with self.assertRaises(ValueError):
            self.api["stage"](self.args)
        self.assertFalse(self.destination.exists())

    def test_every_selected_payload_and_python_extension_is_required(self) -> None:
        for name in [*self.payloads, *("lib/lib" + name + ".so" for name in self.libraries), self.module_name]:
            file = self.prefix / name
            link = file.readlink() if file.is_symlink() else None
            raw = file.read_bytes()
            file.unlink()
            self.refresh_manifest()
            with self.subTest(name=name), self.assertRaises((ValueError, OSError)):
                self.api["installed_files"](self.prefix, self.manifest, "2.18.0")
            if link is None:
                file.write_bytes(raw)
            else:
                file.symlink_to(link)
        self.refresh_manifest()

    def test_python_extension_rejects_foreign_or_additional_ABIs(self) -> None:
        native = self.prefix / self.module_name
        foreign = self.prefix / "lib/migraphx.foreign-abi.so"
        native.rename(foreign)
        self.refresh_manifest()
        with self.assertRaises(ValueError):
            self.api["installed_files"](self.prefix, self.manifest, "2.18.0")
        shutil.copy2(foreign, native)
        self.refresh_manifest()
        with self.assertRaises(ValueError):
            self.api["installed_files"](self.prefix, self.manifest, "2.18.0")

    def test_selected_header_and_config_cannot_be_empty(self) -> None:
        for name in ["include/migraphx/migraphx.h", "lib/cmake/migraphx/migraphx-config.cmake"]:
            file = self.prefix / name
            raw = file.read_bytes()
            file.write_bytes(b"")
            with self.assertRaises(ValueError):
                self.api["installed_files"](self.prefix, self.manifest, "2.18.0")
            file.write_bytes(raw)

    def test_manifest_empty_repeated_relative_foreign_or_incomplete_refuses(self) -> None:
        original = self.manifest.read_text()
        foreign = self.root / "foreign file"
        foreign.write_text("foreign")
        for manifest in ["", original + original.splitlines()[0] + "\n", "relative\n", original + str(foreign) + "\n",
                         "\n".join(original.splitlines()[1:]) + "\n"]:
            self.manifest.write_text(manifest)
            with self.subTest(manifest=manifest), self.assertRaises(ValueError):
                self.api["installed_files"](self.prefix, self.manifest, "2.18.0")

    def test_unlisted_files_and_directory_links_and_foreign_library_links_refuse(self) -> None:
        for path in [self.prefix / "unexpected", self.prefix / "alias"]:
            if path.name == "alias":
                path.symlink_to(self.root, target_is_directory=True)
            else:
                path.write_text("extra")
            with self.assertRaises(ValueError):
                self.api["installed_files"](self.prefix, self.manifest, "2.18.0")
            path.unlink()
        file = self.prefix / "lib/libmigraphx_gpu.so"
        file.unlink()
        file.symlink_to(self.native)
        with self.assertRaises(ValueError):
            self.api["installed_files"](self.prefix, self.manifest, "2.18.0")

    def test_bad_empty_or_foreign_ELF_and_wrong_missing_or_duplicate_version_refuse(self) -> None:
        library = self.prefix / "lib/native-fixture.so"
        raw = library.read_bytes()
        foreign = bytearray(raw)
        foreign[18:20] = (183 if int.from_bytes(raw[18:20], "little") != 183 else 62).to_bytes(2, "little")
        for value in [b"", b"not ELF", bytes(foreign)]:
            library.write_bytes(value)
            with self.subTest(value=value[:20]), self.assertRaises(ValueError):
                self.api["installed_files"](self.prefix, self.manifest, "2.18.0")
        library.write_bytes(raw)
        file = self.prefix / "include/migraphx/version.h"
        original = file.read_text()
        for header in [original.replace("MINOR 18", "MINOR 17"), original.replace("#define MIGRAPHX_VERSION_PATCH 0\n", ""),
                       original + "#define MIGRAPHX_VERSION_MAJOR 2\n"]:
            file.write_text(header)
            with self.assertRaises(ValueError):
                self.api["installed_files"](self.prefix, self.manifest, "2.18.0")

    def test_missing_ambiguous_or_empty_dependency_prefixes_refuse(self) -> None:
        lookup = self.api["notice_sources"]
        for value in ["", self.args.deps_prefix + ";", self.args.deps_prefix + ";" + str(self.dependencies[0]),
                      "relative", str(self.root / "missing")]:
            with self.subTest(value=value), self.assertRaises(ValueError):
                lookup(self.work, value)
        relative = ";".join(os.path.relpath(value) for value in self.dependencies)
        with self.assertRaises(ValueError):
            lookup(self.work, relative)
        unused = self.root / "unused dependency prefix"
        unused.mkdir()
        with self.assertRaises(ValueError):
            lookup(self.work, self.args.deps_prefix + ";" + str(unused) + ";" + str(unused))
        source = self.dependencies[1] / "share/licenses/ck"
        shutil.copytree(source, self.dependencies[0] / "share/licenses/ck")
        with self.assertRaises(ValueError):
            lookup(self.work, self.args.deps_prefix)

    def test_every_known_original_notice_rejects_corruption_or_symlinks(self) -> None:
        selected = self.api["notice_sources"](self.work, self.args.deps_prefix)
        selected["pybind11"] = (self.pybind_root / self.pybind_entry).parent
        policy = self.policy / "backend-source-notices.sha256"
        for line in policy.read_text().splitlines():
            _sha, name = line.split()
            component, relative = name.split("/", 1)
            file = selected[component] / relative
            raw = file.read_bytes()
            file.write_text("foreign original")
            with self.subTest(name=name), self.assertRaises(ValueError):
                self.api["stage"](self.args)
            self.assertFalse(self.destination.exists())
            file.unlink()
            external = self.root / "external notice"
            external.write_bytes(raw)
            file.symlink_to(external)
            with self.assertRaises(ValueError):
                self.api["stage"](self.args)
            file.unlink()
            file.write_bytes(raw)

    def test_policy_duplicates_traversal_bad_hash_or_missing_named_notice_refuses(self) -> None:
        policy = self.policy / "backend-source-notices.sha256"
        raw = policy.read_text()
        bad = [raw + raw.splitlines()[0] + "\n", "a" * 64 + "  ../LICENSE\n", "bad  ck/LICENSE\n"]
        bad.extend("\n".join(row for row in raw.splitlines() if row != omitted) + "\n" for omitted in raw.splitlines())
        for value in bad:
            policy.write_text(value)
            with self.subTest(value=value), self.assertRaises((ValueError, FileNotFoundError)):
                self.api["stage"](self.args)
            self.assertFalse(self.destination.exists())

    def test_rocmlir_policy_and_original_per_file_notices_remain_required(self) -> None:
        root = self.dependencies[2] / "share/licenses/rocmlir"
        policy = root / "SOURCE-NOTICE-SHA256SUMS"
        raw = policy.read_bytes()
        policy.write_text("different policy")
        with self.assertRaises(ValueError):
            self.api["stage"](self.args)
        policy.write_bytes(raw)
        for name in ["external/llvm-project/LICENSE.TXT", "external/triton/LICENSE"]:
            file = root / name
            original = file.read_bytes()
            file.write_text("foreign text")
            with self.subTest(name=name), self.assertRaises(ValueError):
                self.api["stage"](self.args)
            self.assertFalse(self.destination.exists())
            file.write_bytes(original)

    def test_archive_pin_primary_notice_and_source_identity_must_match(self) -> None:
        self.args.source_commit = "short"
        with self.assertRaises(ValueError):
            self.api["stage"](self.args)
        self.args.source_commit = "a" * 40
        expected = self.args.source_sha256
        self.args.source_sha256 = "b" * 64
        with self.assertRaises(ValueError):
            self.api["stage"](self.args)
        self.args.source_sha256 = expected
        (self.work / "source/LICENSE").write_text("modified notice")
        with self.assertRaises(ValueError):
            self.api["stage"](self.args)
        self.assertFalse(self.destination.exists())

    def test_ambiguous_archive_primary_and_symlinked_original_notice_refuse(self) -> None:
        raw = (self.work / "source/LICENSE").read_bytes()
        with tarfile.open(self.work / "source.tar.gz", "w:gz") as archive:
            for name in ["one/LICENSE", "two/LICENSE"]:
                member = tarfile.TarInfo(name)
                member.size = len(raw)
                archive.addfile(member, io.BytesIO(raw))
        expected = hashlib.sha256((self.work / "source.tar.gz").read_bytes()).hexdigest()
        with self.assertRaises(ValueError):
            self.api["original_backend_license"](self.work, expected)
        self.archive_license(raw)
        file = self.work / "source/LICENSE"
        file.unlink()
        external = self.root / "external original notice"
        external.write_bytes(raw)
        file.symlink_to(external)
        with self.assertRaises(ValueError):
            self.api["stage"](self.args)
        self.assertFalse(self.destination.exists())

    def test_notice_or_symlink_drift_during_copy_never_publishes_receipt(self) -> None:
        original_copy = shutil.copy2
        def mutate_notice(source: Path, target: Path) -> None:
            original_copy(source, target)
            source.write_bytes(b"notice changed during copy")
        with mock.patch.object(shutil, "copy2", side_effect=mutate_notice), self.assertRaises(ValueError):
            self.api["stage"](self.args)
        self.assertFalse((self.destination / "build-provenance.json").exists())

    def test_copy_failures_and_changed_installed_bytes_never_publish_receipt(self) -> None:
        globals_ = self.api["stage"].__globals__
        original_copy = shutil.copy2
        with mock.patch.object(globals_["shutil"], "copy2", side_effect=OSError("copy refused")), self.assertRaises(OSError):
            self.api["stage"](self.args)
        self.assertFalse((self.destination / "build-provenance.json").exists())
        shutil.rmtree(self.destination)
        def corrupt(source: Path, target: Path) -> None:
            original_copy(source, target)
            (self.prefix / "lib/native-fixture.so").write_bytes(b"changed during notice copy")
        with mock.patch.object(globals_["shutil"], "copy2", side_effect=corrupt), self.assertRaises(ValueError):
            self.api["stage"](self.args)
        self.assertFalse((self.destination / "build-provenance.json").exists())


    def test_stager_cli_checks_before_writes_and_requires_complete_stage_arguments(self) -> None:
        script = LIB / "stage-backend-install.py"
        target = self.root / "fresh CLI prefix"
        result = subprocess.run([sys.executable, str(script), "check-prefix", "--prefix", str(target)],
                                capture_output=True, text=True, check=False, timeout=10)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse(target.exists())
        for argv in [["check-prefix", "--prefix", str(self.prefix)], ["stage", "--prefix", str(target)]]:
            result = subprocess.run([sys.executable, str(script), *argv], capture_output=True,
                                    text=True, check=False, timeout=10)
            self.assertEqual(result.returncode, 2, result.stderr)
            self.assertFalse(target.exists())

        complete = ["stage", "--prefix", str(self.prefix), "--work", str(self.work),
                    "--deps-prefix", self.args.deps_prefix, "--version", "2.18.0",
                    "--source-commit", self.args.source_commit, "--source-sha256", self.args.source_sha256,
                    "--patch", str(self.args.patch), "--python-patch", str(self.args.python_patch)]
        result = subprocess.run([sys.executable, str(script), *complete], capture_output=True,
                                text=True, check=False, timeout=10)
        self.assertEqual(result.returncode, 2)
        self.assertIn("Incomplete backend stage arguments", result.stderr)
        self.assertFalse(self.destination.exists())


BACKEND_CLI = r"""
[[ "$#" -eq 7 && "$2" == 5 ]] || return 2
SCRIPT_DIR="$FIXTURE_SCRIPTS"
work="$3"
python3() {
  [[ "$#" -eq 4 && "$1" == "$SCRIPT_DIR/stage-backend-install.py" && "$2" == check-prefix && "$3" == --prefix ]] || return 98
  [[ "$4" == "$MIGRAPHX_SOURCE_PREFIX" ]] || return 99
  printf 'prefix\n' >> "$EVENT_LOG"
  [[ "$FAIL_PHASE" != prefix ]] || return 29
}
"""

BACKEND_PREPARATION = r"""
printf 'prepare\n' >> "$EVENT_LOG"
printf '%s\0' "$@" > "$PREPARE_ARGV"
[[ "$FAIL_PHASE" != prepare ]] || return 23
work="$1"
mkdir -p "$work/source"
cp "$ORIGINAL_NOTICE" "$work/source/LICENSE"
printf 'original archive input\n' > "$work/input.bin"
sha256sum "$work/input.bin" > "$work/source-inputs.sha256"
[[ "$FAIL_PHASE" != no-notice ]] || unlink "$work/source/LICENSE"
CMAKE_COMPILER_CACHE_PIN='/selected cache'
[[ "$FAIL_PHASE" != no-cache ]] || CMAKE_COMPILER_CACHE_PIN=''
HOST_PYTHON_BIN=stage_python JOBS=7 PY_PYBIND11_VERSION=3.1.0
MIGRAPHX_DEPS_PREFIX="$DEPS_PREFIX"
MIGRAPHX_VERSION=2.18.0 MIGRAPHX_WINDOWS_COMMIT=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
MIGRAPHX_WINDOWS_SOURCE_SHA256=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
patch_file="$FIXTURE_PATCH"
python_patch_file="$FIXTURE_PYTHON_PATCH"
compute_cpp_heavy_jobs() {
  printf 'jobs\n' >> "$EVENT_LOG"
  printf '%s\n' "$1" > "$JOBS_LOG"
  [[ "$FAIL_PHASE" != jobs ]] || return 31
  printf '2\n'
}
cmake() {
  local phase="${1#--}"
  printf '%s\n' "$phase" >> "$EVENT_LOG"
  printf '%s\0' "$@" > "$CMAKE_ARGV.$phase"
  [[ "$FAIL_PHASE" != "$phase" ]] || return 37
  if [[ "$phase" == build && "$FAIL_PHASE" == source-drift ]]; then
    printf 'changed source notice\n' > "$work/source/LICENSE"
  fi
}
stage_python() {
  printf 'stage\n' >> "$EVENT_LOG"
  printf '%s\0' "$@" > "$STAGE_ARGV"
  [[ "$FAIL_PHASE" != stage ]] || return 41
}
"""


class MigraphxBackendLifecycleTests(unittest.TestCase):
    """The full entry invokes the prepared path; explicit doubles retain order, argument boundaries and raw failures."""

    def setUp(self) -> None:
        temporary = tempfile.TemporaryDirectory(prefix="backend lifecycle ")
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.scripts = self.root / "scripts"
        self.scripts.mkdir()
        shutil.copy2(LIB / "build-source-backend.sh", self.scripts)
        (self.scripts / "cli-common.sh").write_text(BACKEND_CLI)
        (self.scripts / "prepare-source-build.sh").write_text(BACKEND_PREPARATION)
        self.original = self.root / "original notice"
        self.original.write_bytes(b"original upstream text\r\n")
        self.patch = self.root / "patch with spaces"
        self.patch.write_text("tracked patch")
        self.python_patch = self.root / "python selection patch"
        self.python_patch.write_text("tracked Python selector")
        self.calls = 0

    def run_build(self, phase: str = "") -> tuple[subprocess.CompletedProcess[str], Path, list[str]]:
        self.calls += 1
        work = self.root / ("work " + str(self.calls))
        events = self.root / ("events " + str(self.calls))
        argv = [str(work), "source archive", "ROCm CMake archive", "msgpack archive", "/ROCm with spaces"]
        env = dict(os.environ, LC_ALL="C", FAIL_PHASE=phase, FIXTURE_SCRIPTS=str(self.scripts),
                   ORIGINAL_NOTICE=str(self.original), FIXTURE_PATCH=str(self.patch), FIXTURE_PYTHON_PATCH=str(self.python_patch), EVENT_LOG=str(events),
                   PREPARE_ARGV=str(self.root / "prepare.nul"), JOBS_LOG=str(self.root / "jobs"),
                   CMAKE_ARGV=str(self.root / "cmake"), STAGE_ARGV=str(self.root / "stage.nul"),
                   MIGRAPHX_SOURCE_PREFIX=str(self.root / "new install prefix"),
                   DEPS_PREFIX="/parser deps;/CK deps;/rocMLIR deps")
        result = subprocess.run(["bash", str(self.scripts / "build-source-backend.sh"), *argv],
                                capture_output=True, text=True, check=False, timeout=15, env=env)
        return result, work, argv

    def test_same_shell_preparation_jobs_install_and_notice_stage_arguments(self) -> None:
        result, work, argv = self.run_build()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("MIGRAPHX SOURCE BUILT:", result.stdout)
        self.assertEqual((self.root / "events 1").read_text().splitlines(), ["prefix", "prepare", "jobs", "build", "install", "stage"])
        self.assertEqual((self.root / "prepare.nul").read_bytes().split(b"\0")[:-1], [arg.encode() for arg in argv])
        self.assertEqual((self.root / "jobs").read_text(), "7\n")
        self.assertEqual((self.root / "cmake.build").read_bytes().split(b"\0")[:-1],
                         [b"--build", str(work / "build").encode(), b"--parallel", b"2"])
        self.assertEqual((self.root / "cmake.install").read_bytes().split(b"\0")[:-1],
                         [b"--install", str(work / "build").encode()])
        stage = (self.root / "stage.nul").read_bytes().split(b"\0")[:-1]
        self.assertEqual(stage[:2], [str(self.scripts / "stage-backend-install.py").encode(), b"stage"])
        for flag, expected in [(b"--work", str(work).encode()), (b"--deps-prefix", b"/parser deps;/CK deps;/rocMLIR deps"),
                               (b"--version", b"2.18.0"), (b"--pybind-version", b"3.1.0"), (b"--patch", str(self.patch).encode()),
                               (b"--python-patch", str(self.python_patch).encode()),
                               (b"--source-commit", b"a" * 40), (b"--source-sha256", b"b" * 64)]:
            self.assertEqual(stage[stage.index(flag) + 1], expected)
        self.assertIn(b"source/LICENSE", (work / "source-inputs.sha256").read_bytes())

    def test_prefix_prepare_jobs_build_install_and_stage_failures_remain_raw(self) -> None:
        for phase, status in [("prefix", 29), ("prepare", 23), ("jobs", 31), ("build", 37), ("install", 37), ("stage", 41)]:
            result, _work, _argv = self.run_build(phase)
            self.assertEqual(result.returncode, status, (phase, result.stdout, result.stderr))
            self.assertNotIn("MIGRAPHX SOURCE BUILT:", result.stdout)

    def test_missing_cache_original_notice_or_changed_inputs_cannot_pass(self) -> None:
        for phase in ["no-cache", "no-notice", "source-drift"]:
            result, _work, _argv = self.run_build(phase)
            self.assertNotEqual(result.returncode, 0, (phase, result.stdout, result.stderr))
            self.assertNotIn("MIGRAPHX SOURCE BUILT:", result.stdout)
            self.assertFalse((self.root / "stage.nul").exists())

    def test_real_builder_bad_arity_refuses_before_prefix_or_build(self) -> None:
        for argv in [[], ["work"], ["work", "archive", "tools", "msgpack"], ["work"] * 6]:
            result = subprocess.run(["bash", str(LIB / "build-source-backend.sh"), *argv],
                                    capture_output=True, text=True, check=False, timeout=10, env=dict(os.environ, LC_ALL="C"))
            self.assertEqual(result.returncode, 2, result.stdout + result.stderr)


if __name__ == "__main__":
    unittest.main()
