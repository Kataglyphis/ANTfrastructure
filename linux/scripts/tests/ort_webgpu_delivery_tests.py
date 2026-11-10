"""Exercise actual strip/RPATH rewrites and reject code replacement; no ORT factory or GPU executes."""
from __future__ import annotations

import hashlib
import importlib.util
import json
import shutil
import subprocess
import sys
import unittest
import zipfile
from pathlib import Path
from unittest.mock import patch

import ort_webgpu_build_proof_tests as fixture
from dockerfile_runs import dockerfile_runs

DELIVERY = Path(sys.argv[4]).resolve()
spec = importlib.util.spec_from_file_location("delivery_proof", DELIVERY)
assert spec is not None and spec.loader is not None
proof = importlib.util.module_from_spec(spec)
spec.loader.exec_module(proof)


class DeliveryTests(unittest.TestCase):
    def setUp(self) -> None:
        self.built = fixture.BuildProofTests()
        self.built.setUp()
        self.addCleanup(self.built.doCleanups)
        self.root, self.prefix = self.built.root, self.built.prefix
        self.built.passed()
        self.built.wheel("free-threaded")
        self.built.passed("free-threaded")
        self.stores = {}
        self.elf_differences = {}
        for phase, folder, manifest in (("gil", "wheels", "ort-provenance.sha256"),
                                        ("free-threaded", "wheels-free-threaded", "ort-provenance-free-threaded.sha256")):
            store = self.root / ("collected " + phase)
            store.mkdir()
            wheel = next((self.prefix / folder).glob("*.whl"))
            self.manifest = self.prefix / manifest
            self.manifest.write_text(self.manifest_line(wheel))
            shutil.move(wheel, store / wheel.name)
            self.stores[phase] = (store, self.manifest)
        self.runtime = DELIVERY.parent
        self.worker = self.root / "manifest-worker.sh"
        harness = fixture.COMMON.parents[5] / "tests/test-harness.sh"
        source = self.runtime / "repair-wheels.sh"
        emitted = subprocess.run(["bash", "-c", 'source "$1"; t_fn_src "$2" ort_manifest_rows',
                                  "fixture", str(harness), str(source)], capture_output=True, text=True, check=True)
        self.worker.write_text('set -euo pipefail\n_SCRIPT_DIR="$1"; shift\n' + emitted.stdout + '\nort_manifest_rows "$@"\n')

    def manifest_line(self, wheel: Path) -> str:
        with zipfile.ZipFile(wheel) as archive:
            members = [name for name in archive.namelist() if "onnxruntime_pybind11_state" in name]
            self.assertEqual(len(members), 1)
            member = members[0]
            return f"{hashlib.sha256(archive.read(member)).hexdigest()}  {wheel.name}!{member}\n"

    def run_rows(self, mode: str, phase: str = "gil", *, passed: bool = True) -> subprocess.CompletedProcess[str]:
        store, manifest = self.stores[phase]
        receipt = self.prefix / fixture.RECEIPT
        before = (manifest.read_bytes(), receipt.read_bytes())
        result = subprocess.run(["bash", str(self.worker), str(self.runtime), mode, str(store), str(manifest)],
                                capture_output=True, text=True, check=False, timeout=30)
        if passed:
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr + json.dumps(self.elf_differences))
        else:
            self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertEqual((manifest.read_bytes(), receipt.read_bytes()), before)
        return result

    def rewritten(self, phase: str = "gil", *, strip: bool = False, rpath: bool = False,
                  foreign: bool = False, symbol: bool = False, code: bool = False, needed: bool = False, masked: bool = False, sectionless: bool = False, foreign_machine: bool = False) -> Path:
        store, _ = self.stores[phase]
        old = next(store.glob("*.whl"))
        with zipfile.ZipFile(old) as archive:
            member = archive.namelist()[0]
            payload = archive.read(member)
        library = self.root / "rewritten.so"
        library.write_bytes(payload)
        before = dict(proof.allocated_payload(library)[1])
        if strip:
            subprocess.run(["strip", "--strip-all", str(library)], check=True, capture_output=True)
        if rpath:
            subprocess.run(["patchelf", "--set-rpath", "/a/longer/delivery/library/path", str(library)], check=True, capture_output=True)
        if needed:
            subprocess.run(["patchelf", "--replace-needed", "libc.so.6", "libc-repaired.so.6", str(library)],
                           check=True, capture_output=True)
        if code:
            self.mutate_section(library, ".text")
        if foreign:
            self.mutate_section(library, ".rodata", b"webgpu fixture", b"foreign object")
        if symbol:
            self.mutate_section(library, ".dynstr", b"banner\0", b"bannex\0")
        if masked:
            self.hide_loaded_change(library)
        if foreign_machine:
            data = bytearray(library.read_bytes())
            data[18] ^= 1
            library.write_bytes(data)
        if sectionless:
            data = bytearray(library.read_bytes())
            data[40:48] = bytes(8)
            library.write_bytes(data)
        after = dict(proof.allocated_payload(library)[1]) if not (masked or sectionless) else {}
        self.elf_differences = {bytes.fromhex(name).decode(): [before.get(name), after.get(name)]
                                for name in before.keys() | after.keys() if before.get(name) != after.get(name)}
        target = old.with_name(old.name.replace("linux_x86_64", "manylinux_2_39_x86_64"))
        old.unlink()
        with zipfile.ZipFile(target, "w") as archive:
            archive.writestr(member, library.read_bytes())
        return target

    def mutate_section(self, library: Path, name: str, original: bytes = b"", replacement: bytes = b"") -> None:
        section = self.root / "section.bin"
        subprocess.run(["objcopy", "--dump-section", f"{name}={section}", str(library)], capture_output=True, check=True)
        data = section.read_bytes()
        if original:
            self.assertIn(original, data)
            changed = data.replace(original, replacement)
        else:
            self.assertTrue(data)
            changed = bytes([data[0] ^ 1]) + data[1:]
        section.write_bytes(changed)
        subprocess.run(["objcopy", "--update-section", f"{name}={section}", str(library)], capture_output=True, check=True)

    def hide_loaded_change(self, library: Path) -> None:
        elf = proof.elf_api().ElfSections(library)
        try:
            names = proof.section_names(elf)
            index = next(i for i in range(len(elf.sections)) if proof.section_identity(elf, i, names)[0] == b".rodata")
            section = elf.sections[index]
            original = elf.data(section)
            position = section[1] + original.index(b"webgpu fixture")
            header_offset = elf.section_table + index * elf.section_size + (24 if elf.bits == 2 else 16)
            width = 8 if elf.bits == 2 else 4
            data = bytearray(library.read_bytes())
            data[position] ^= 1
            data[header_offset:header_offset + width] = len(data).to_bytes(width, "little" if elf.endian == "<" else "big")
            data.extend(original)
            library.write_bytes(data)
        finally:
            elf.stream.close()

    def receipt(self) -> dict:
        return json.loads((self.prefix / fixture.RECEIPT).read_text())

    def test_actual_stripping_and_rpath_changes_retain_compiled_product(self) -> None:
        for phase in ("gil", "free-threaded"):
            with self.subTest(phase=phase):
                self.run_rows("check", phase)
                self.rewritten(phase, strip=True, rpath=True)
                self.run_rows("follow", phase)
                record = self.receipt()["phases"][phase]
                self.assertNotIn("delivery_pending", record)
                hop = record["wheel_delivery"][0]
                self.assertNotEqual(hop["from"]["sha256"], hop["to"]["sha256"])
                self.assertEqual(hop["to"]["sha256"], self.stores[phase][1].read_text().split()[0])
                self.assertEqual(record["products"][-1]["sha256"], hop["from"]["sha256"])

    def test_needed_library_rewriting_retains_compiled_product(self) -> None:
        self.run_rows("check")
        self.rewritten(needed=True)
        self.run_rows("follow")

    def test_native_only_disabled_mode_cannot_become_a_python_proof(self) -> None:
        self.built.write_config("OFF")
        self.built.passed(mode="OFF", without_wheel=True)
        self.run_rows("check", passed=False)
        store, manifest = self.stores["gil"]
        for wheel in store.glob("*.whl"):
            wheel.unlink()
        manifest.write_text("")
        self.run_rows("check")
        self.run_rows("follow")
        self.assertIsNone(self.receipt()["phases"]["gil"]["wheel_delivery"][0]["to"])

    def test_unchanged_wheel_is_also_a_checked_delivery(self) -> None:
        self.run_rows("check")
        self.run_rows("follow")
        hop = self.receipt()["phases"]["gil"]["wheel_delivery"][0]
        self.assertEqual(hop["from"], hop["to"])

    def test_follow_without_precheck_cannot_invent_delivery(self) -> None:
        result = self.run_rows("follow", passed=False)
        self.assertIn("no matching successful precheck", result.stderr)

    def test_foreign_bytes_after_precheck_fail_without_publishing_anything(self) -> None:
        self.run_rows("check")
        self.rewritten(foreign=True)
        result = self.run_rows("follow", passed=False)
        self.assertIn("changed allocated ORT code or data", result.stderr)

    def test_changed_executable_code_after_precheck_fails(self) -> None:
        self.run_rows("check")
        self.rewritten(code=True)
        result = self.run_rows("follow", passed=False)
        self.assertIn("changed allocated ORT code or data", result.stderr)

    def test_section_only_copy_cannot_hide_changed_loaded_data(self) -> None:
        self.run_rows("check")
        self.rewritten(masked=True)
        result = self.run_rows("follow", passed=False)
        self.assertIn("differs from loaded bytes", result.stderr)

    def test_missing_section_evidence_cannot_become_a_delivery(self) -> None:
        self.run_rows("check")
        self.rewritten(sectionless=True)
        result = self.run_rows("follow", passed=False)
        self.assertIn("section headers missing or invalid", result.stderr)

    def test_changed_dynamic_symbol_names_are_not_loader_metadata(self) -> None:
        self.run_rows("check")
        self.rewritten(symbol=True)
        result = self.run_rows("follow", passed=False)
        self.assertIn("changed allocated ORT code or data", result.stderr)

    def test_foreign_machine_identity_cannot_pass_with_identical_sections(self) -> None:
        self.run_rows("check")
        self.rewritten(foreign_machine=True)
        self.run_rows("follow", passed=False)

    def test_invalid_mode_and_source_identity_fail_before_rewrite(self) -> None:
        path = self.prefix / fixture.RECEIPT
        original = self.receipt()
        receipt = self.receipt()
        receipt["phases"]["gil"]["configured_flags"]["onnxruntime_USE_EP_API_ADAPTERS"] = "OFF"
        path.write_text(json.dumps(receipt))
        self.run_rows("check", passed=False)
        original["source"]["revision"] = "short"
        path.write_text(json.dumps(original))
        self.run_rows("check", passed=False)

    def test_duplicate_manifest_binding_fails(self) -> None:
        manifest = self.stores["gil"][1]
        manifest.write_bytes(manifest.read_bytes() * 2)
        self.run_rows("check", passed=False)

    def test_pending_product_cannot_change_after_precheck(self) -> None:
        self.run_rows("check")
        receipt = self.receipt()
        receipt["phases"]["gil"]["delivery_pending"]["product"]["sha256"] = "0" * 64
        (self.prefix / fixture.RECEIPT).write_text(json.dumps(receipt))
        self.run_rows("follow", passed=False)

    def test_changed_build_flags_after_precheck_fail(self) -> None:
        self.run_rows("check")
        receipt = self.receipt()
        receipt["phases"]["gil"]["configured_flags"] = dict.fromkeys(fixture.FLAGS, "OFF")
        (self.prefix / fixture.RECEIPT).write_text(json.dumps(receipt))
        self.run_rows("follow", passed=False)

    def test_source_core_manifest_and_wheelhouse_cannot_change_during_rewrite(self) -> None:
        self.run_rows("check")
        original = self.built.library.read_bytes()
        self.built.library.write_bytes(original + b"changed core")
        self.run_rows("follow", passed=False)
        self.built.library.write_bytes(original)
        store, manifest = self.stores["gil"]
        original_manifest = manifest.read_bytes()
        manifest.write_bytes(original_manifest + b"\n")
        self.run_rows("follow", passed=False)
        manifest.write_bytes(original_manifest)
        relocated = self.root / "another store"
        shutil.copytree(store, relocated)
        self.stores["gil"] = (relocated, manifest)
        self.run_rows("follow", passed=False)

    def test_missing_or_corrupt_build_receipt_and_pending_check_fail(self) -> None:
        path = self.prefix / fixture.RECEIPT
        original = path.read_bytes()
        path.unlink()
        result = subprocess.run(["bash", str(self.worker), str(self.runtime), "check", str(self.stores["gil"][0]),
                                 str(self.stores["gil"][1])], capture_output=True, text=True, check=False)
        self.assertNotEqual(result.returncode, 0)
        path.write_bytes(original)
        self.run_rows("check")
        self.run_rows("check", passed=False)

    def test_history_accepts_another_checked_retag_without_losing_original_build_bytes(self) -> None:
        self.run_rows("check")
        self.rewritten(strip=True)
        self.run_rows("follow")
        self.run_rows("check")
        self.run_rows("follow")
        hops = self.receipt()["phases"]["gil"]["wheel_delivery"]
        self.assertEqual(len(hops), 2)
        self.assertEqual(hops[1]["from"], hops[0]["to"])
        receipt = self.receipt()
        receipt["phases"]["gil"]["wheel_delivery"][0]["from"]["sha256"] = "0" * 64
        (self.prefix / fixture.RECEIPT).write_text(json.dumps(receipt))
        self.run_rows("check", passed=False)

    def test_incompatible_required_canonical_companion_fails(self) -> None:
        companion = self.root / "module.py"
        companion.write_text("value = 1\n")
        with patch.object(proof, "ROOT", self.root):
            proof.source_api.cache_clear()
            with self.assertRaisesRegex(ValueError, "incompatible proof companion"):
                proof.source_api("module.py", ("required",))
        proof.source_api.cache_clear()

    def test_producer_and_package_carry_the_required_companions(self) -> None:
        parser = proof.source_api("verify_dockerfile_context_paths.py", ("mount_sources", "copy_sources", "logical_lines"))
        root = DELIVERY.parents[4]
        media = root / "linux/Dockerfile.media"
        package = root / "linux/Dockerfile.package"
        run = next(text for _, text in dockerfile_runs(str(media)) if "runtime/finalize-media.sh" in text)
        mounts = {dict(parser.MOUNT_KV.findall(value))["source"]: dict(parser.MOUNT_KV.findall(value))
                  for value in parser.BIND_MOUNT.findall(run) if "source=" in value}
        companions = ("03-media/build/onnxruntime/build/lib/ort-webgpu-build-proof.py",
                      "06-packaging/python-app-deb-depends.py", "06-packaging/python_app_deb_symbols.py")
        lines = [line for _, line in parser.logical_lines(package.read_text())]
        for relative in companions:
            with self.subTest(companion=relative):
                source = "linux/scripts/" + relative
                self.assertIn(source, mounts)
                self.assertEqual(mounts[source].get("target"), "/opt/scripts/" + relative)
                destination = "/opt/scripts/" + (relative if relative.startswith("03-media/") else "06-packaging/")
                self.assertTrue(any(source in parser.copy_sources(line) and line.endswith(destination) for line in lines))

    def test_missing_required_canonical_companion_fails(self) -> None:
        with patch.object(proof, "ROOT", self.root / "missing"):
            proof.source_api.cache_clear()
            with self.assertRaises(FileNotFoundError):
                proof.build_api()
        proof.source_api.cache_clear()


if __name__ == "__main__":
    unittest.main(argv=[__file__], verbosity=2)
