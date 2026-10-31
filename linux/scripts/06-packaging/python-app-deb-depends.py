#!/usr/bin/env python3
"""Compute DEB dependencies without accepting incomplete ELF or cache output."""
from __future__ import annotations

import json
import os
import re
import struct
import subprocess
import sys
from functools import cache
from pathlib import Path

VERSION_NEED = 0x6FFFFFFE
VERSION_NEED_NUM = 0x6FFFFFFF
SECTION_NEED = 0x6FFFFFFE
SECTION_DYNAMIC = 6
SECTION_STRTAB = 3
LIMIT = 128 * 1024 * 1024
SITE_CUSTOMIZE = '''# Written by python-app-bundle.sh: loads what the protected chain ORT needs from runtime/lib, so its sonames resolve.
import ctypes
import os
import sys

_lib = os.path.join(sys.prefix, "lib")
_list = os.path.join(_lib, "preload.list")
if os.path.exists(_list):
    with open(_list) as _f:
        for _name in _f.read().split():
            ctypes.CDLL(os.path.join(_lib, _name), mode=ctypes.RTLD_GLOBAL)
'''


class ElfSections:
    """Read bounded ELF section data, including both ELF classes and byte orders."""

    def __init__(self, path: Path) -> None:
        self.path = path
        self.size = path.stat().st_size
        self.stream = path.open("rb")
        ident = self.read(0, 16)
        if ident[:4] != b"\x7fELF" or ident[4] not in (1, 2) or ident[5] not in (1, 2):
            raise ValueError(f"invalid ELF identity: {path}")
        self.bits = ident[4]
        self.endian = "<" if ident[5] == 1 else ">"
        header = self.read(0, 64 if self.bits == 2 else 52)
        if self.bits == 2:
            offset = self.unpack("Q", header, 40)[0]
            entry_size, count = self.unpack("HH", header, 58)
            program_offset = self.unpack("Q", header, 32)[0]
            program_size, program_count = self.unpack("HH", header, 54)
            minimum = 64
        else:
            offset = self.unpack("I", header, 32)[0]
            entry_size, count = self.unpack("HH", header, 46)
            program_offset = self.unpack("I", header, 28)[0]
            program_size, program_count = self.unpack("HH", header, 42)
            minimum = 40
        if not offset or entry_size < minimum:
            raise ValueError(f"ELF section headers missing or invalid: {path}")
        first = self.section(offset, entry_size)
        count = count or first[2]  # ELF extended section count in section zero.
        if not count or count > 65536:
            raise ValueError(f"invalid ELF section count: {path}")
        self.sections = [self.section(offset + i * entry_size, entry_size) for i in range(count)]
        if program_count == 0xFFFF:
            program_count = first[4]
        self.section_table = offset
        self.section_size = entry_size
        self.load_segments: list[tuple[int, int, int]] = []
        self.dynamic_addresses: list[int] = []
        self.has_interpreter = False
        self.dynamic_segments = self.program_dynamic(program_offset, program_size, program_count)

    def program_dynamic(self, offset: int, size: int, count: int) -> list[tuple[int, int]]:
        minimum = 56 if self.bits == 2 else 32
        if count and (not offset or size < minimum or count > 65536):
            raise ValueError(f"invalid ELF program table: {self.path}")
        segments = []
        for index in range(count):
            data = self.read(offset + index * size, size)
            kind = self.unpack("I", data)[0]
            if self.bits == 2:
                start = self.unpack("Q", data, 8)[0]
                length = self.unpack("Q", data, 32)[0]
                address, memory = self.unpack("Q", data, 16)[0], self.unpack("Q", data, 40)[0]
            else:
                start = self.unpack("I", data, 4)[0]
                length = self.unpack("I", data, 16)[0]
                address, memory = self.unpack("I", data, 8)[0], self.unpack("I", data, 20)[0]
            if kind == 1:  # PT_LOAD
                if length > memory or start + length > self.size:
                    raise ValueError(f"invalid ELF load segment: {self.path}")
                self.load_segments.append((address, address + length, start))
            if kind == 2:  # PT_DYNAMIC
                segments.append((start, length))
                self.dynamic_addresses.append(address)
            if kind == 3:  # PT_INTERP
                self.register_interpreter(start, length)
        return segments

    def register_interpreter(self, offset: int, length: int) -> None:
        if self.has_interpreter or not length or length > 4096:
            raise ValueError(f"invalid ELF interpreter: {self.path}")
        value = self.read(offset, length)
        if not value.endswith(b"\0") or b"\0" in value[:-1]:
            raise ValueError(f"invalid ELF interpreter path: {self.path}")
        self.has_interpreter = True

    def read(self, offset: int, size: int) -> bytes:
        if offset < 0 or size < 0 or size > LIMIT or offset + size > self.size:
            raise ValueError(f"invalid ELF bounds: {self.path}")
        self.stream.seek(offset)
        result = self.stream.read(size)
        if len(result) != size:
            raise ValueError(f"short ELF read: {self.path}")
        return result

    def unpack(self, fmt: str, data: bytes, offset: int = 0) -> tuple:
        try:
            return struct.unpack_from(self.endian + fmt, data, offset)
        except struct.error as error:
            raise ValueError(f"truncated ELF structure: {self.path}") from error

    def section(self, offset: int, size: int) -> tuple[int, int, int, int, int]:
        data = self.read(offset, size)
        kind = self.unpack("I", data, 4)[0]
        if self.bits == 2:
            start, length = self.unpack("QQ", data, 24)
            link, info = self.unpack("II", data, 40)
        else:
            start, length, link, info = self.unpack("IIII", data, 16)
        return kind, start, length, link, info

    def data(self, section: tuple[int, int, int, int, int]) -> bytes:
        return self.read(section[1], section[2])

    def section_address(self, index: int) -> int:
        header = self.read(self.section_table + index * self.section_size, self.section_size)
        return self.unpack("Q" if self.bits == 2 else "I", header, 16 if self.bits == 2 else 12)[0]

    def loader_bytes(self, address: int, size: int) -> bytes:
        if size > LIMIT:
            raise ValueError(f"oversized ELF loader data: {self.path}")
        result = bytearray()
        while len(result) < size:
            cursor = address + len(result)
            matches = [segment for segment in self.load_segments if segment[0] <= cursor < segment[1]]
            if len(matches) != 1:
                raise ValueError(f"ambiguous ELF loader mapping: {self.path}")
            begin, end, offset = matches[0]
            length = min(end - cursor, size - len(result))
            for start, _, _ in self.load_segments:
                if cursor < start < cursor + length:
                    length = start - cursor
            result.extend(self.read(offset + cursor - begin, length))
        return bytes(result)


def checked_dynamic_strings(elf: ElfSections, entries: list[tuple[int, int]], section: tuple[int, int, int, int, int]) -> bytes:
    strings = elf.data(elf.sections[section[3]])
    address = [value for tag, value in entries if tag == 5]
    sizes = [value for tag, value in entries if tag == 10]
    if len(address) != 1 or sizes != [len(strings)] or address[0] != elf.section_address(section[3]):
        raise ValueError(f"invalid ELF dynamic string table: {elf.path}")
    if elf.loader_bytes(address[0], len(strings)) != strings:
        raise ValueError(f"ELF dynamic strings differ from loader mapping: {elf.path}")
    return strings


def dynamic_entries(elf: ElfSections) -> tuple[list[tuple[int, int]], bytes]:
    sections = [item for item in elf.sections if item[0] == SECTION_DYNAMIC]
    if len(sections) > 1 or [(item[1], item[2]) for item in sections] != elf.dynamic_segments:
        raise ValueError(f"ELF dynamic sections do not match program headers: {elf.path}")
    if not sections:
        return [], b""
    section = sections[0]
    if (len(elf.dynamic_addresses) != 1 or elf.dynamic_addresses[0] != elf.section_address(elf.sections.index(section)) or
            elf.loader_bytes(elf.dynamic_addresses[0], section[2]) != elf.data(section)):
        raise ValueError(f"ELF dynamic entries differ from loader mapping: {elf.path}")
    if section[3] >= len(elf.sections) or elf.sections[section[3]][0] != SECTION_STRTAB:
        raise ValueError(f"invalid ELF dynamic string table: {elf.path}")
    data = elf.data(section)
    fmt = "qQ" if elf.bits == 2 else "iI"
    size = struct.calcsize(fmt)
    if len(data) % size:
        raise ValueError(f"invalid ELF dynamic entries: {elf.path}")
    entries = []
    for offset in range(0, len(data), size):
        tag, value = elf.unpack(fmt, data, offset)
        if tag == 0:
            return entries, checked_dynamic_strings(elf, entries, section)
        entries.append((tag, value))
    raise ValueError(f"ELF dynamic section is missing DT_NULL: {elf.path}")


def dynamic_version_count(elf: ElfSections) -> int:
    tags: dict[int, int] = {}
    entries, _ = dynamic_entries(elf)
    for tag, value in entries:
        if tag in (VERSION_NEED, VERSION_NEED_NUM):
            if tag in tags:
                raise ValueError(f"duplicate ELF version tag: {elf.path}")
            tags[tag] = value
    if bool(VERSION_NEED in tags) != bool(VERSION_NEED_NUM in tags):
        raise ValueError(f"incomplete ELF version tags: {elf.path}")
    return tags.get(VERSION_NEED_NUM, 0)


def version_name(elf: ElfSections, strings: bytes, offset: int) -> str:
    if offset >= len(strings) or (end := strings.find(b"\0", offset)) < 0:
        raise ValueError(f"invalid ELF version name: {elf.path}")
    return strings[offset:end].decode("utf-8")


def needed_versions(elf: ElfSections, section: tuple[int, int, int, int, int]) -> list[str]:
    _, _, _, link, count = section
    if link >= len(elf.sections) or elf.sections[link][0] != SECTION_STRTAB:
        raise ValueError(f"invalid ELF version string table: {elf.path}")
    strings = elf.data(elf.sections[link])
    data = elf.data(section)
    versions: list[str] = []
    offset = 0
    for index in range(count):
        version, aux_count, file_name, aux, following = elf.unpack("HHIII", data, offset)
        if version != 1 or not aux_count or not aux:
            raise ValueError(f"invalid ELF version needs record: {elf.path}")
        version_name(elf, strings, file_name)
        aux_offset = offset + aux
        for aux_index in range(aux_count):
            _, _, _, name, next_aux = elf.unpack("IHHII", data, aux_offset)
            versions.append(version_name(elf, strings, name))
            if (aux_index + 1 < aux_count) != bool(next_aux) or (next_aux and next_aux < 16):
                raise ValueError(f"incomplete ELF version auxiliary records: {elf.path}")
            aux_offset += next_aux
        if (index + 1 < count) != bool(following) or (following and following < 16):
            raise ValueError(f"incomplete ELF version needs records: {elf.path}")
        offset += following
    return versions


def glibc_versions(path: Path, *, require_host: bool = True) -> list[tuple[int, int]]:
    elf = ElfSections(path)
    try:
        sections = [item for item in elf.sections if item[0] == SECTION_NEED]
        if sum(item[4] for item in sections) != dynamic_version_count(elf):
            raise ValueError(f"ELF version sections do not match dynamic tags: {path}")
        entries, strings = dynamic_entries(elf)
        if sections:
            address = [value for tag, value in entries if tag == VERSION_NEED]
            if (len(sections) != 1 or len(address) != 1 or
                    address[0] != elf.section_address(elf.sections.index(sections[0])) or
                    elf.loader_bytes(address[0], sections[0][2]) != elf.data(sections[0])):
                raise ValueError(f"ELF version needs differ from loader mapping: {path}")
            if sections[0][3] >= len(elf.sections) or elf.data(elf.sections[sections[0][3]]) != strings:
                raise ValueError(f"ELF version needs use different strings: {path}")
        versions = [name for item in sections for name in needed_versions(elf, item)]
        return glibc_requirements(path, versions, entries, require_host=require_host)
    finally:
        elf.stream.close()


def glibc_requirements(path: Path, versions: list[str], entries: list[tuple[int, int]], *, require_host: bool = True) -> list[tuple[int, int]]:
    result = [(int(match.group(1)), int(match.group(2))) for name in versions
              if (match := re.fullmatch(r"GLIBC_(\d+)\.(\d+)(?:\.\d+)*", name))]
    for name in versions:
        if name.startswith("GLIBC_ABI_"):
            if name != "GLIBC_ABI_DT_RELR" and require_host:
                raise ValueError(f"unknown glibc ABI version {name}: {path}")
            if name == "GLIBC_ABI_DT_RELR":
                result.append((2, 36))
    relr = [tag for tag, _ in entries if tag in (35, 36, 37)]
    if relr:
        if sorted(relr) != [35, 36, 37]:
            raise ValueError(f"invalid ELF DT_RELR entries: {path}")
        result.append((2, 36))
    return result


def needed(path: Path) -> list[str]:
    helper = Path(__file__).with_name("elf-needed.sh")
    command = 'source "$1"; elf_dynamic_needed "$2"'
    result = subprocess.run(["bash", "-c", command, "_", str(helper), str(path)],
                            text=True, capture_output=True, check=True)
    return result.stdout.splitlines()


def elf_search_paths(path: Path, expected: list[str]) -> list[str]:
    elf = ElfSections(path)
    try:
        entries, strings = dynamic_entries(elf)
        binary_needed = [version_name(elf, strings, value) for tag, value in entries if tag == 1]
        if binary_needed != expected:
            raise ValueError(f"ELF dynamic entries disagree with readelf: {path}")
        runpath = [version_name(elf, strings, value) for tag, value in entries if tag == 29]
        rpath = [version_name(elf, strings, value) for tag, value in entries if tag == 15]
        if len(runpath) > 1 or len(rpath) > 1:
            raise ValueError(f"duplicate ELF search paths: {path}")
        return (runpath or rpath or [""])[0].split(":")
    finally:
        elf.stream.close()


def bundled_file(path: Path, bundle: Path) -> bool:
    try:
        return path.is_file() and path.resolve(strict=True).is_relative_to(bundle)
    except OSError:
        return False


def real_bundled_file(path: Path, bundle: Path) -> bool:
    return bundled_file(path, bundle) and path.resolve(strict=True) == path


def elf_needs_launcher(path: Path, bundle: Path) -> bool:
    with path.open("rb") as stream:
        if stream.read(4) != b"\x7fELF":
            return False
    elf = ElfSections(path)
    try:
        kind = elf.unpack("H", elf.read(16, 2))[0]
        if kind == 3 and ".so" in path.name and path.is_relative_to(bundle / "runtime/lib"):
            entries, _ = dynamic_entries(elf)
            if any(tag == 14 for tag, _ in entries):
                return False
        exposed = ".so" not in path.name and any(path.is_relative_to(bundle / directory) for directory in
                                                 ("bin", "runtime/bin", "runtime/libexec"))
        return bool(elf.dynamic_segments) and (elf.has_interpreter or kind == 2 or (kind == 3 and exposed))
    finally:
        elf.stream.close()


def wrapped_executable(binary: Path, bundle: Path, require_external: bool) -> bool:
    if not binary.name.endswith(".bin") or not bundled_file(binary, bundle):
        return False
    launcher = binary.with_name(binary.name[:-4])
    if not real_bundled_file(launcher, bundle):
        return False
    lines = launcher.read_text(encoding="utf-8").splitlines()
    if len(lines) not in (11, 17) or (require_external and len(lines) != 17):
        return False
    if lines[0] != "#!/bin/bash" or not lines[1].startswith("# Starts "):
        return False
    if lines[2] != 'here="$(cd -- "$(dirname -- "$(readlink -f -- "$0")")" && pwd)"':
        return False
    loader = re.match(r'^exec "\$here/\./([A-Za-z0-9_.+-]+)" --library-path ', lines[-1])
    if loader is None or not bundled_file(binary.parent / loader.group(1), bundle):
        return False
    relative_lib = os.path.relpath(bundle / "runtime/lib", binary.parent)
    if len(lines) == 17:
        external = ['external_library_path=""', 'IFS=: read -r -a external_library_dirs <<< "${LD_LIBRARY_PATH:-}"',
                    'for external_library_dir in "${external_library_dirs[@]}"; do',
                    '  [ -z "${external_library_dir}" ] || external_library_path="${external_library_path}:${external_library_dir}"',
                    'done', f'export LD_LIBRARY_PATH="$here/{relative_lib}${{external_library_path}}"']
        if lines[3:9] != external:
            return False
    return interpreter_tail_ready(lines[9 if len(lines) == 17 else 3:], launcher.name, len(lines) == 17, relative_lib)


def all_executables_wrapped(bundle: Path, require_external: bool) -> bool:
    def walk_error(error: OSError) -> None:
        raise error

    for root, directories, files in os.walk(bundle, onerror=walk_error):
        for name in directories:
            directory = Path(root) / name
            if directory.is_symlink() and not directory.resolve(strict=True).is_relative_to(bundle):
                return False
        for name in files:
            path = Path(root) / name
            if not path.is_symlink() and elf_needs_launcher(path, bundle) and not wrapped_executable(path, bundle, require_external):
                return False
    return True


def gpu_launcher_ready(bundle: Path) -> bool:
    python = bundle / "runtime/bin/python3"
    if not bundled_file(python, bundle):
        return False
    wrapper = python.resolve(strict=True)
    return (wrapped_executable(wrapper.with_name(wrapper.name + ".bin"), bundle, True) and
            all_executables_wrapped(bundle, True))


def isolated_entry_ready(bundle: Path, name: str) -> bool:
    if not re.fullmatch(r"[A-Za-z0-9_][A-Za-z0-9_.-]*", name):
        return False
    launcher = bundle / "bin" / name
    if not real_bundled_file(launcher, bundle):
        return False
    lines = launcher.read_text(encoding="utf-8").splitlines()
    if len(lines) not in (7, 10) or lines[:1] != ["#!/bin/sh"] or not lines[1].startswith("# "):
        return False
    if lines[2:4] != ['here=$(dirname "$(readlink -f "$0")")', 'root=$(dirname "$here")']:
        return False
    if not re.fullmatch(r'export [A-Za-z_][A-Za-z0-9_]*="\$root/[A-Za-z0-9_./-]+"', lines[4]):
        return False
    if len(lines) == 10:
        gst = ['export GST_PLUGIN_PATH="$root/runtime/lib/gstreamer-1.0" GST_PLUGIN_SYSTEM_PATH= GST_PLUGIN_SYSTEM_PATH_1_0= GST_REGISTRY_FORK=no',
               'copy=$(printf %s "$root" | cksum | cut -d\' \' -f1)',
               'export PATH="$root/runtime/libexec/gstreamer:$PATH"']
        if lines[5:7] != gst[:2] or lines[8] != gst[2]:
            return False
        if not re.fullmatch(r'export GST_REGISTRY="\$\{XDG_CACHE_HOME:-\$\{HOME:-/tmp\}/\.cache\}/[A-Za-z0-9_.-]+/gstreamer-\$copy\.bin"', lines[7]):
            return False
    elif lines[5]:
        return False
    command = rf'exec "\$root/runtime/bin/python3" -I -B -c \'import sys; sys\.argv\[0\] = "{re.escape(name)}"; from [A-Za-z0-9_.]+ import [A-Za-z0-9_]+ as _entry; sys\.exit\(_entry\(\)\)\' "\$@"'
    return re.fullmatch(command, lines[-1]) is not None


def interpreter_tail_ready(tail: list[str], name: str, external: bool, relative_lib: str = "../lib") -> bool:
    if len(tail) != 8 or not tail[0].startswith("# Not read < <("):
        return False
    sed = r"'1s/.*release version \([0-9][0-9]*\)\.\([0-9][0-9]*\).*/\1 \2/p'"
    if not re.fullmatch(r'''host_glibc="\$\("/[A-Za-z0-9_./+-]+" --version 2>/dev/null \| sed -n ''' + re.escape(sed) + r'''\)"''', tail[1]):
        return False
    if tail[2:4] != ['read -r host_major host_minor <<< "$host_glibc"',
                     'if [ -z "${KATAGLYPHIS_BUNDLED_GLIBC:-}" ] && [ -n "${host_minor:-}" ] &&']:
        return False
    if not re.fullmatch(r'  \{ \[ "\$host_major" -gt [0-9]+ \] \|\| \{ \[ "\$host_major" -eq [0-9]+ \] && \[ "\$host_minor" -ge [0-9]+ \]; \}; \}; then', tail[4]):
        return False
    if tail[5:7] != [f'  exec -a "$0" "$here/./{name}.bin" "$@"', 'fi']:
        return False
    suffix = '${external_library_path}' if external else ''
    location = re.escape(relative_lib)
    return re.fullmatch(rf'exec "\$here/\./[A-Za-z0-9_.+-]+" --library-path "\$here/{location}/glibc:\$here/{location}{re.escape(suffix)}" --argv0 "\$0" "\$here/\./{re.escape(name)}\.bin" "\$@"', tail[7]) is not None


def isolated_interpreter_ready(bundle: Path) -> bool:
    interpreter = bundle / "runtime/bin/python3"
    if not bundled_file(interpreter, bundle):
        return False
    interpreter = interpreter.resolve(strict=True)
    name = interpreter.name
    if interpreter.parent != (bundle / "runtime/bin").resolve(strict=True):
        return False
    if not re.fullmatch(r"python3(?:\.[0-9]+)?", name) or not bundled_file(interpreter.with_name(name + ".bin"), bundle):
        return False
    lines = interpreter.read_text(encoding="utf-8").splitlines()
    if len(lines) not in (11, 17) or lines[0] != "#!/bin/bash" or not lines[1].startswith("# Starts "):
        return False
    if lines[2] != 'here="$(cd -- "$(dirname -- "$(readlink -f -- "$0")")" && pwd)"':
        return False
    offset = 3
    if len(lines) == 17:
        external = ['external_library_path=""', 'IFS=: read -r -a external_library_dirs <<< "${LD_LIBRARY_PATH:-}"',
                    'for external_library_dir in "${external_library_dirs[@]}"; do',
                    '  [ -z "${external_library_dir}" ] || external_library_path="${external_library_path}:${external_library_dir}"',
                    'done', 'export LD_LIBRARY_PATH="$here/../lib${external_library_path}"']
        if lines[3:9] != external:
            return False
        offset = 9
    return interpreter_tail_ready(lines[offset:], name, len(lines) == 17)


def passive_pth(path: Path, bundle: Path) -> bool:
    if not bundled_file(path, bundle):
        return False
    try:
        return not any(line.startswith(("import ", "import\t"))
                       for line in path.read_text(encoding="utf-8-sig").splitlines())
    except UnicodeError:
        return False


def mapped_soname(path: Path) -> str:
    with path.open("rb") as stream:
        if stream.read(4) != b"\x7fELF":
            return ""
    elf = ElfSections(path)
    try:
        entries, strings = dynamic_entries(elf)
        names = [version_name(elf, strings, value) for tag, value in entries if tag == 14]
        if len(names) > 1:
            raise ValueError(f"multiple ELF sonames: {path}")
        return names[0] if names else ""
    finally:
        elf.stream.close()


def mapped_preloads_ready(bundle: Path, paths: list[str]) -> bool:
    preload_file = bundle / "runtime/lib/preload.list"
    names = preload_file.read_text(encoding="utf-8").split() if preload_file.is_file() else []
    expected = {name: (bundle / "runtime/lib" / name).resolve(strict=True) for name in names}
    mapped = {Path(path).resolve(strict=True) for path in paths}
    if any(not path.is_relative_to(bundle) or path not in mapped for path in expected.values()):
        return False
    if any(mapped_soname(path) != name for name, path in expected.items()):
        return False
    for path in mapped:
        soname = mapped_soname(path)
        if soname in expected and path != expected[soname]:
            return False
    return True


def python_probe_mode(bundle: Path, code: str, bundled: bool) -> bool:
    try:
        environment = os.environ.copy()
        if bundled:
            environment["KATAGLYPHIS_BUNDLED_GLIBC"] = "1"
        else:
            environment.pop("KATAGLYPHIS_BUNDLED_GLIBC", None)
        result = subprocess.run([str(bundle / "runtime/bin/python3"), "-I", "-B", "-c", code],
                                capture_output=True, text=True, timeout=60, check=True, env=environment)
        prefix, customize, isolated, no_site, no_bytecode, paths, mapped = json.loads(result.stdout)
        runtime = (bundle / "runtime").resolve(strict=True)
        name = (bundle / "runtime/bin/python3").resolve(strict=True).name
        expected = runtime / "lib" / name / "site-packages/sitecustomize.py"
        return (Path(prefix).resolve(strict=True) == runtime and
                Path(customize).resolve(strict=True) == expected.resolve(strict=True) and
                isolated == 1 and no_site == 0 and no_bytecode == 1 and isinstance(paths, list) and
                all(Path(path).resolve().is_relative_to(runtime) for path in paths) and
                isinstance(mapped, list) and mapped_preloads_ready(bundle, mapped))
    except (OSError, ValueError, TypeError, subprocess.SubprocessError):
        return False


def isolated_python_probe(bundle: Path) -> bool:
    code = ('import json,site,sitecustomize,sys; '
            'maps=[line.split(None,5)[-1].strip() for line in open("/proc/self/maps") '
            'if len(line.split(None,5))==6 and line.split(None,5)[-1].startswith("/")]; '
            'print(json.dumps([sys.prefix,sitecustomize.__file__,sys.flags.isolated,'
            'sys.flags.no_site,sys.flags.dont_write_bytecode,site.getsitepackages(),maps]))')
    return all(python_probe_mode(bundle, code, bundled) for bundled in (False, True))


@cache
def preload_startup_ready(bundle: Path) -> bool:
    manifest = json.loads((bundle / "bundle.json").read_text(encoding="utf-8"))
    scripts = manifest.get("scripts", [])
    if not isinstance(scripts, list) or not scripts or not all(isinstance(name, str) and isolated_entry_ready(bundle, name) for name in scripts):
        return False
    if not isolated_interpreter_ready(bundle):
        return False
    if not all_executables_wrapped(bundle, False):
        return False
    def walk_error(error: OSError) -> None:
        raise error

    for root, directories, files in os.walk(bundle / "runtime", onerror=walk_error):
        if any((Path(root) / name).is_symlink() for name in directories):
            return False
        if any(name.endswith(".pth") and not passive_pth(Path(root) / name, bundle) for name in files):
            return False
    return isolated_python_probe(bundle)


def python_preloads_active(bundle: Path, path: Path) -> bool:
    if "site-packages" not in path.parts or ".so" not in path.name:
        return False
    site = Path(*path.parts[:path.parts.index("site-packages") + 1])
    runtime_lib = bundle / "runtime/lib"
    if (site.parent.parent != runtime_lib or site.parent.name != (bundle / "runtime/bin/python3").resolve().name or
            any(item.is_symlink() for item in (site, site.parent, runtime_lib))):
        return False
    customize = site / "sitecustomize.py"
    if not bundled_file(customize, bundle):
        return False
    return customize.read_text(encoding="utf-8") == SITE_CUSTOMIZE and preload_startup_ready(bundle)


def bundled_import(bundle: Path, path: Path, name: str, search: list[str], gpu_host: bool, preloads: set[str]) -> bool:
    origin = str(path.parent)
    if "/" in name:
        expanded = name.replace("${ORIGIN}", origin).replace("$ORIGIN", origin)
        return expanded.startswith("/") and bundled_file(Path(expanded), bundle)
    for item in search:
        expanded = item.replace("${ORIGIN}", origin).replace("$ORIGIN", origin)
        if expanded.startswith("/") and bundled_file(Path(expanded) / name, bundle):
            return True
    runtime_lib = bundle / "runtime/lib" / name
    runtime = bundle / "runtime"
    python_library = path.is_relative_to(runtime / "lib")
    python_binary = path.parent == runtime / "bin" and path.name.startswith("python") and path.name.endswith(".bin")
    if gpu_host and (python_library or python_binary) and bundled_file(runtime_lib, bundle):
        return True
    return name in preloads and python_preloads_active(bundle, path) and bundled_file(runtime_lib, bundle)


def ldconfig_cache() -> dict[str, str]:
    output = subprocess.run(["ldconfig", "-p"], capture_output=True, check=True, text=True,
                            env={**os.environ, "LC_ALL": "C"}).stdout.splitlines()
    header = re.fullmatch(r"(\d+) libs found in cache .+", output[0]) if output else None
    if header is None:
        raise ValueError("invalid or empty ldconfig cache output")
    rows: list[tuple[str, str]] = []
    lines = output[1:]
    if lines and lines[-1].startswith("Cache generated by: ldconfig "):
        lines = lines[:-1]
    for line in lines:
        match = re.fullmatch(r"\s*(\S+) \([^\n]*\) => (/\S+)\s*", line)
        if match is None:
            raise ValueError("invalid ldconfig cache row")
        rows.append((match.group(1), match.group(2)))
    if len(rows) != int(header.group(1)):
        raise ValueError("incomplete ldconfig cache output")
    return dict(reversed(rows))  # Preserve ldconfig's first preferred match.


def package_owner(path: str) -> str:
    candidates = [path, "/usr" + path if path.startswith("/lib") else "", os.path.realpath(path)]
    for candidate in filter(None, candidates):
        found = subprocess.run(["dpkg", "-S", candidate], capture_output=True, check=False, text=True)
        if found.returncode != 0:
            continue
        for line in found.stdout.splitlines():
            owners, separator, named_path = line.partition(": ")
            owner = owners.split(",", 1)[0].split(":", 1)[0]
            if separator and named_path == candidate and re.fullmatch(r"[a-z0-9][a-z0-9+.-]+", owner):
                return owner
    return ""


def resolve_packages(imports: set[str]) -> set[str]:
    cache = ldconfig_cache()
    packages, missing = set(), []
    for name in sorted(imports):
        owner = package_owner(cache[name]) if name in cache else ""
        if owner:
            packages.add(owner)
        else:
            missing.append(name)
    if missing:
        raise ValueError("no installed package provides " + ", ".join(missing))
    packages.discard("libc6")
    return packages


def dependencies(bundle: Path) -> str:
    bundle = bundle.resolve(strict=True)
    manifest = json.loads((bundle / "bundle.json").read_text(encoding="utf-8"))
    waived = set(manifest.get("unresolved_allowed", []))
    gpu_host = bool(manifest.get("host_gpu_sonames")) and gpu_launcher_ready(bundle)
    preload_file = bundle / "runtime/lib/preload.list"
    preloads = set(preload_file.read_text(encoding="utf-8").split()) if preload_file.is_file() else set()
    imports, glibc = set(), (2, 17)
    def walk_error(error: OSError) -> None:
        raise error

    for root, _, files in os.walk(bundle, onerror=walk_error):
        for name in files:
            path = Path(root) / name
            if path.is_symlink():
                continue
            with path.open("rb") as stream:
                if stream.read(4) != b"\x7fELF":
                    continue
            direct = needed(path)
            search = elf_search_paths(path, direct)
            imports.update(value for value in direct if value not in waived and
                           not bundled_import(bundle, path, value, search, gpu_host, preloads))
            versions = glibc_versions(path, require_host=not manifest.get("glibc"))
            if not manifest.get("glibc"):
                glibc = max([glibc, *versions])
    packages = resolve_packages(imports)
    libc = "libc6" if manifest.get("glibc") else f"libc6 (>= {glibc[0]}.{glibc[1]})"
    return ", ".join([libc] + sorted(packages))


if __name__ == "__main__":
    try:
        print(dependencies(Path(sys.argv[1])))
    except (OSError, ValueError, UnicodeError, subprocess.CalledProcessError) as error:
        print(f"cannot derive Debian dependencies: {error}", file=sys.stderr)
        sys.exit(1)
