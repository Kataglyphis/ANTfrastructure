"""Bind trusted wheel rewrites to unchanged allocated ORT code/data, not loader metadata or inference."""
from __future__ import annotations

import hashlib
import importlib.util
import json
import re
import shutil
import tempfile
import zipfile
from collections.abc import Callable
from functools import cache
from pathlib import Path
from types import ModuleType
from typing import Protocol

ROOT = Path(__file__).resolve().parents[2]
MUTABLE_METADATA = {b".dynamic": 6, b".dynstr": 3, b".gnu.version_r": 0x6FFFFFFE}
RELOCATABLE_METADATA = {7, 5, 11, 0x6FFFFFF6}
PHASES = {"ort-provenance.sha256": "gil", "ort-provenance-free-threaded.sha256": "free-threaded"}


class ElfView(Protocol):
    bits: int
    sections: list[tuple[int, int, int, int, int]]
    section_table: int
    section_size: int

    def read(self, offset: int, size: int) -> bytes: ...
    def unpack(self, fmt: str, data: bytes, offset: int = 0) -> tuple: ...
    def data(self, section: tuple[int, int, int, int, int]) -> bytes: ...
    def section_address(self, index: int) -> int: ...
    def loader_bytes(self, address: int, size: int) -> bytes: ...


@cache
def source_api(relative: str, exports: tuple[str, ...]) -> ModuleType:
    """Required canonical companions never fall back to a private implementation."""
    path = ROOT / relative
    spec = importlib.util.spec_from_file_location("_webgpu_" + path.stem, path)
    if spec is None or spec.loader is None:
        raise ValueError(f"cannot load required proof companion: {path}")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    if not all(callable(getattr(module, name, None)) for name in exports):
        raise ValueError(f"incompatible proof companion: {path}")
    return module


def build_api() -> ModuleType:
    return source_api("03-media/build/onnxruntime/build/lib/ort-webgpu-build-proof.py",
                      ("native_product", "write_receipt"))


def elf_api() -> ModuleType:
    return source_api("06-packaging/python-app-deb-depends.py", ("ElfSections", "dynamic_entries"))


def section_names(elf: ElfView) -> bytes:
    """Use the shared bounded section reader, including extended string-table indices."""
    index = elf.unpack("H", elf.read(62 if elf.bits == 2 else 50, 2))[0]
    if index == 0xFFFF:
        index = elf.sections[0][3]
    if not 0 < index < len(elf.sections) or elf.sections[index][0] != 3:
        raise ValueError("invalid ELF section name table")
    return elf.data(elf.sections[index])


def table_string(table: bytes, offset: int) -> bytes:
    end = table.find(b"\0", offset)
    if offset >= len(table) or end < 0:
        raise ValueError("invalid ELF table string")
    return table[offset:end]


def symbol_target(elf: ElfView, names: bytes, section: int, value: int, kind: int) -> tuple:
    if section in (0, 0xFFF1, 0xFFF2):
        return section, value
    if not 0 < section < len(elf.sections):
        raise ValueError("unsupported ELF dynamic symbol section")
    name, _, address = section_identity(elf, section, names)
    return name.hex(), value if kind == 6 else value - address


def dynamic_symbol_fingerprint(elf: ElfView, index: int, names: bytes) -> str:
    section = elf.sections[index]
    dynamic, strings = elf_api().dynamic_entries(elf)
    entry_size = 24 if elf.bits == 2 else 16
    header = elf.read(elf.section_table + index * elf.section_size, elf.section_size)
    declared = elf.unpack("Q" if elf.bits == 2 else "I", header, 56 if elf.bits == 2 else 36)[0]
    if (declared != entry_size or section[2] % entry_size or [v for t, v in dynamic if t == 6] != [elf.section_address(index)]
            or [v for t, v in dynamic if t == 11] != [entry_size]):
        raise ValueError("invalid ELF dynamic symbol table")
    digest = hashlib.sha256()
    for offset in range(0, section[2], entry_size):
        data = elf.read(section[1] + offset, entry_size)
        if elf.bits == 2:
            name, info, other, target, value, size = elf.unpack("IBBHQQ", data)
        else:
            name, value, size, info, other, target = elf.unpack("IIIBBH", data)
        identity = [table_string(strings, name).hex(), info, other,
                    symbol_target(elf, names, target, value, info & 15), size]
        digest.update(json.dumps(identity, separators=(",", ":")).encode() + b"\n")
    return digest.hexdigest()


def section_identity(elf: ElfView, index: int, names: bytes) -> tuple[bytes, int, int]:
    header = elf.read(elf.section_table + index * elf.section_size, elf.section_size)
    offset = elf.unpack("I", header)[0]
    flags = elf.unpack("Q" if elf.bits == 2 else "I", header, 8)[0]
    return table_string(names, offset), flags, elf.section_address(index)


def section_fingerprint(elf: ElfView, section: tuple[int, int, int, int, int], address: int) -> str:
    kind, offset, size, *_ = section
    digest = hashlib.sha256()
    if kind != 8:
        for position in range(0, size, 1024 * 1024):
            length = min(1024 * 1024, size - position)
            data = elf.read(offset + position, length)
            if data != elf.loader_bytes(address + position, length):
                raise ValueError("ELF section differs from loaded bytes")
            digest.update(data)
    return digest.hexdigest()


def elf_identity(elf: ElfView) -> tuple:
    header = elf.read(0, 64 if elf.bits == 2 else 52)
    return (header[4:9].hex(), elf.unpack("HH", header, 16),
            elf.unpack("Q" if elf.bits == 2 else "I", header, 24),
            elf.unpack("I", header, 48 if elf.bits == 2 else 36))


def allocated_payload(path: Path) -> list:
    """Protect allocated bytes/addresses except three typed dynamic-metadata sections."""
    elf = elf_api().ElfSections(path)
    try:
        elf_api().dynamic_entries(elf)
        names = section_names(elf)
        identity = elf_identity(elf)
        sections = {}
        executable = False
        for index, section in enumerate(elf.sections):
            name, flags, address = section_identity(elf, index, names)
            if not flags & 2:
                continue
            if not name or name in sections:
                raise ValueError("empty or duplicate allocated ELF section name")
            kind, _, size, *_ = section
            mutable = MUTABLE_METADATA.get(name) == kind and not flags & 4
            digest = section_fingerprint(elf, section, address)
            if mutable:
                continue
            fingerprint = dynamic_symbol_fingerprint(elf, index, names) if kind == 11 else digest
            if kind in RELOCATABLE_METADATA and not flags & 4:
                address = 0
            sections[name] = (kind, flags, address, size, fingerprint)
            executable |= bool(flags & 4 and size)
        if not executable:
            raise ValueError("no allocated executable ELF sections")
        body = [identity, [(name.hex(), value) for name, value in sorted(sections.items())]]
        return body
    finally:
        elf.stream.close()


def allocated_fingerprint(path: Path) -> str:
    return hashlib.sha256(json.dumps(allocated_payload(path), separators=(",", ":")).encode()).hexdigest()


def member_fingerprint(wheels: Path, product: dict) -> str:
    """Read the exact checked wheel member through a disposable bounded ELF file."""
    with zipfile.ZipFile(wheels / product["wheel"]) as archive:
        matches = [item for item in archive.infolist() if item.filename == product["member"]]
        if len(matches) != 1 or not 0 < matches[0].file_size <= build_api().MAX_PRODUCT_BYTES:
            raise ValueError("missing, duplicate or oversized delivery member")
        with tempfile.TemporaryDirectory(prefix="ort-webgpu-elf-") as directory:
            path = Path(directory) / "product.so"
            with archive.open(matches[0]) as source, path.open("wb") as target:
                shutil.copyfileobj(source, target, length=1024 * 1024)
            return allocated_fingerprint(path)


def load_receipt(prefix: Path) -> dict:
    receipt = json.loads((prefix / build_api().RECEIPT).read_text(encoding="utf-8"))
    if receipt.get("schema_version") != 1 or receipt.get("provider") != "WebGpuExecutionProvider":
        raise ValueError("invalid WebGPU build receipt")
    source = receipt.get("source", {})
    if not source.get("ref") or not re.fullmatch(r"[a-f0-9]{40}", source.get("revision", "")):
        raise ValueError("invalid WebGPU source binding")
    if build_api().native_product(prefix) not in receipt["phases"]["gil"]["products"]:
        raise ValueError("native core changed after its WebGPU build proof")
    return receipt


def build_binding(receipt: dict) -> str:
    immutable = {name: {key: phase[key] for key in ("configured_flags", "cmake_cache_sha256", "products")}
                 for name, phase in receipt["phases"].items()}
    body = [receipt["source"], immutable]
    return hashlib.sha256(json.dumps(body, sort_keys=True, separators=(",", ":")).encode()).hexdigest()


def original_product(receipt: dict, phase: str) -> dict | None:
    record = receipt["phases"][phase]
    flags = record["configured_flags"]
    if flags not in (dict.fromkeys(build_api().FLAGS, "ON"), dict.fromkeys(build_api().FLAGS, "OFF")):
        raise ValueError("invalid native WebGPU mode binding")
    products = record["products"]
    kinds = [product["kind"] for product in products]
    allowed = (["native-core"], ["native-core", "python-gil"]) if phase == "gil" else (["python-free-threaded"],)
    if kinds not in allowed:
        raise ValueError("invalid WebGPU linker-product set")
    python = [p for p in products if p["kind"] == f"python-{phase}"]
    return {key: python[0][key] for key in ("wheel", "member", "sha256")} if python else None


def current_product(receipt: dict, phase: str) -> dict | None:
    current = original_product(receipt, phase)
    for hop in receipt["phases"][phase].get("wheel_delivery", []):
        if hop["from"] != current or hop["build_binding_sha256"] != build_binding(receipt):
            raise ValueError("broken WebGPU delivery history")
        current = hop["to"]
    return current


def mapped_product(current: dict | None, rows: list, lines: list[str], stem: Callable[[str], str]) -> dict | None:
    if current is None:
        if rows or lines:
            raise ValueError("native-only WebGPU build acquired a Python wheel")
        return None
    label = current["wheel"] + "!" + current["member"]
    matches = [index for index, row in enumerate(rows) if (row[0], row[1].strip()) == (current["sha256"], label)]
    if len(matches) != 1 or len(rows) != len(lines):
        raise ValueError("manifest does not retain the bound WebGPU Python product")
    sha, target = lines[matches[0]].split(None, 1)
    wheel, separator, member = target.strip().partition("!")
    if separator != "!" or member != current["member"] or stem(wheel) != stem(current["wheel"]):
        raise ValueError("delivery changed the WebGPU wheel identity")
    return {"wheel": wheel, "member": member, "sha256": sha}


def prepare_delivery(mode: str, manifest: Path, rows: list, lines: list[str], wheels: Path,
                     stem: Callable[[str], str], updates: dict[Path, dict]) -> None:
    phase = PHASES[manifest.name]
    prefix = manifest.parent
    if prefix not in updates:
        updates[prefix] = load_receipt(prefix)
    receipt = updates[prefix]
    record = receipt["phases"][phase]
    before = current_product(receipt, phase)
    after = mapped_product(before, rows, lines, stem)
    manifest_sha = hashlib.sha256(manifest.read_bytes()).hexdigest()
    binding = build_binding(receipt)
    if mode == "check":
        if "delivery_pending" in record:
            raise ValueError("WebGPU wheel rewrite already has a pending check")
        record["delivery_pending"] = {
            "manifest_sha256": manifest_sha, "build_binding_sha256": binding,
            "directory": str(wheels.resolve()), "product": before,
            "allocated_sha256": member_fingerprint(wheels, before) if before is not None else None,
        }
        return
    pending = record.get("delivery_pending")
    if (pending is None or pending["manifest_sha256"] != manifest_sha or pending["product"] != before
            or pending["build_binding_sha256"] != binding or pending["directory"] != str(wheels.resolve())):
        raise ValueError("WebGPU wheel rewrite has no matching successful precheck")
    allocated = member_fingerprint(wheels, after) if after is not None else None
    if allocated != pending["allocated_sha256"]:
        raise ValueError("wheel rewrite changed allocated ORT code or data")
    record.setdefault("wheel_delivery", []).append({
        "from": before, "to": after, "before_manifest_sha256": manifest_sha,
        "after_manifest_sha256": hashlib.sha256("".join(lines).encode()).hexdigest(),
        "allocated_sha256": allocated, "build_binding_sha256": binding,
    })
    del record["delivery_pending"]


def publish_deliveries(updates: dict[Path, dict]) -> None:
    for prefix, receipt in updates.items():
        build_api().write_receipt(prefix, receipt)
