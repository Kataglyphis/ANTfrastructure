#!/usr/bin/env python3
"""Bind installed files and selected original notice bytes; this does not prove ABI, complete licences or GPU acceptance."""

import argparse
import hashlib
import json
import re
import runpy
import shutil
import sys
import sysconfig
import tarfile
from pathlib import Path

LIBRARIES = ("migraphx", "migraphx_c", "migraphx_gpu", "migraphx_ref",
             "migraphx_onnx", "migraphx_tf", "migraphx_py")
PAYLOADS = ("include/migraphx/migraphx.h", "lib/cmake/migraphx/migraphx-config.cmake")
COMPONENTS = ("msgpack", "rocm-cmake", "abseil", "protobuf", "utf8_range", "ck", "rocmlir")
NOTICE_NAMES = {"msgpack/COPYING", "msgpack/LICENSE_1_0.txt",
                *(component + "/LICENSE" for component in COMPONENTS if component != "msgpack")}
POLICY_DIR = Path(__file__).resolve().parent
ELF_TARGET = runpy.run_path(str(POLICY_DIR.parents[2] / "06-packaging/ort_census_probe.py"))["elf_target"]


def digest(path: Path) -> str:
    with path.open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


def require(condition: object, message: str) -> None:
    if not condition:
        raise ValueError(message)


def check_prefix(prefix: Path) -> None:
    require(prefix.is_absolute(), "The backend install prefix must be absolute")
    require(not prefix.is_symlink() and not prefix.exists(), "Refusing an existing backend install prefix")
    require(not prefix.resolve().exists(), "The resolved backend install prefix already exists")


def installed_files(prefix: Path, manifest: Path, version: str) -> dict[str, dict[str, str]]:
    root = prefix.resolve(strict=True)
    require(not prefix.is_symlink() and root.is_dir(), "Installed backend prefix is not a regular directory")
    rows = manifest.read_text().splitlines()
    records = {}
    for value in rows:
        path = Path(value)
        require(path.is_absolute() and path.is_file() and path.stat().st_size > 0, "Invalid installed file: " + value)
        relative = path.relative_to(prefix.absolute()).as_posix()
        require(path.resolve().is_relative_to(root), "Installed file escapes the selected prefix")
        require(relative not in records, "Repeated normalized install path")
        records[relative] = {"sha256": digest(path)}
        if path.is_symlink():
            records[relative]["symlink"] = str(path.readlink())
    actual = {path.relative_to(root).as_posix() for path in root.rglob("*") if path.is_symlink() or not path.is_dir()}
    require(actual == set(records), "Install manifest does not enumerate the complete installed tree")
    for name in PAYLOADS:
        require(name in records, "Missing selected backend payload: " + name)
    modules = [name for name in records if re.fullmatch(r".*/migraphx(?:\.[^/]+)?\.so", name)]
    expected_module = "migraphx" + sysconfig.get_config_var("EXT_SUFFIX")
    require(len(modules) == 1 and Path(modules[0]).name == expected_module,
            "Python extension does not match exactly the selected interpreter ABI")
    with Path(sys.executable).open("rb") as stream:
        native = ELF_TARGET(stream.read(20))
    for name in [*("lib/lib" + library + ".so" for library in LIBRARIES), *modules]:
        with (root / name).open("rb") as stream:
            require(ELF_TARGET(stream.read(20)) == native, "Installed backend ELF identity differs from the native builder")
    header = (root / "include/migraphx/version.h").read_text()
    parts = []
    for field in ("MAJOR", "MINOR", "PATCH"):
        found = re.findall(r"(?m)^#define MIGRAPHX_VERSION_" + field + r"\s+(\d+)\s*$", header)
        require(len(found) == 1, "Missing or repeated installed version field")
        parts.append(found[0])
    require(".".join(parts) == version, "Installed MIGraphX version differs from the selected pin")
    return records


def notice_sources(work: Path, dependencies: str) -> dict[str, Path]:
    roots = [work / "host-tools"]
    values = dependencies.split(";")
    require(all(values) and len(set(values)) == len(values), "Empty or repeated dependency prefixes")
    roots.extend(Path(value) for value in values)
    require(all(root.is_absolute() and root.is_dir() for root in roots), "Missing absolute dependency prefix")
    selected = {}
    for component in COMPONENTS:
        matches = [root / "share/licenses" / component for root in roots if (root / "share/licenses" / component).exists()]
        require(len(matches) == 1, "Missing or ambiguous original notice component: " + component)
        selected[component] = matches[0]
    return selected


def checked_notice_files(sources: dict[str, Path], policy: Path) -> dict[str, Path]:
    expected = {}
    for line in policy.read_text().splitlines():
        if not line or line.startswith("#"):
            continue
        sha256, name = line.split()
        require(re.fullmatch(r"[0-9a-f]{64}", sha256) and not Path(name).is_absolute()
                and ".." not in Path(name).parts, "Invalid backend original-notice policy")
        component, relative = name.split("/", 1)
        require(name not in expected and component in sources, "Invalid original-notice component or duplicate")
        file = sources[component] / relative
        require(not file.is_symlink() and file.is_file() and digest(file) == sha256, "Original notice bytes differ: " + name)
        expected[name] = file
    require(set(expected) == NOTICE_NAMES, "Incomplete backend original-notice policy")
    return expected


def original_backend_license(work: Path, expected_archive: str) -> Path:
    archive = work / "source.tar.gz"
    require(digest(archive) == expected_archive, "Backend source archive differs from its recorded pin")
    with tarfile.open(archive) as source:
        members = [member for member in source.getmembers()
                   if len(Path(member.name).parts) == 2 and Path(member.name).name == "LICENSE"]
        require(len(members) == 1 and members[0].isfile(), "Missing unique original archive licence")
        stream = source.extractfile(members[0])
        if stream is None:
            raise ValueError("Original archive licence cannot be read")
        with stream:
            expected = hashlib.sha256(stream.read()).hexdigest()
    license_file = work / "source/LICENSE"
    require(not license_file.is_symlink() and license_file.is_file() and license_file.stat().st_size > 0
            and digest(license_file) == expected, "Original backend licence differs from the pinned archive")
    return license_file


def write_backend_receipt(args: argparse.Namespace, files: dict[str, dict[str, str]], notices: dict[str, Path]) -> None:
    destination = args.prefix / "share/licenses/migraphx-source-build"
    require(not destination.exists() and not destination.is_symlink(), "Refusing an earlier backend notice receipt")
    notices["migraphx/applied.patch"] = args.patch
    notices["migraphx/python-selection.patch"] = args.python_patch
    notice_hashes = {name: digest(file) for name, file in notices.items()}
    record = {"schema_version": 1, "version": args.version, "source_commit": args.source_commit,
              "source_archive_sha256": args.source_sha256, "patch_sha256": digest(args.patch),
              "python_selection_patch_sha256": digest(args.python_patch),
              "installed_files": files, "original_notices": notice_hashes,
              "complete_binary_licence_review": False, "scope": __doc__}
    destination.mkdir(parents=True)
    for name, source in notices.items():
        target = destination / name
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(source, target)
        require(digest(target) == notice_hashes[name] == digest(source), "Original notice changed during staging")
    for name, expected in files.items():
        file = args.prefix / name
        require(digest(file) == expected["sha256"], "Installed file changed while staging original notices")
        require((str(file.readlink()) if file.is_symlink() else None) == expected.get("symlink"), "Installed symlink changed")
    (destination / "build-provenance.json").write_text(json.dumps(record, indent=2) + "\n")


def stage(args: argparse.Namespace) -> None:
    require(re.fullmatch(r"[0-9a-f]{40}", args.source_commit) and re.fullmatch(r"[0-9a-f]{64}", args.source_sha256),
            "Missing pinned backend source identity")
    files = installed_files(args.prefix, args.work / "build/install_manifest.txt", args.version)
    sources = notice_sources(args.work, args.deps_prefix)
    notices = checked_notice_files(sources, POLICY_DIR / "backend-source-notices.sha256")
    rocmlir_policy = POLICY_DIR / "rocmlir-source-notices.sha256"
    rocmlir = sources["rocmlir"]
    require((rocmlir / "SOURCE-NOTICE-SHA256SUMS").read_bytes() == rocmlir_policy.read_bytes(), "rocMLIR notice policy differs")
    for line in rocmlir_policy.read_text().splitlines():
        if line and not line.startswith("#"):
            sha256, relative = line.split()
            file = rocmlir / relative
            require(not file.is_symlink() and file.is_file() and digest(file) == sha256, "rocMLIR original notice differs")
            notices["rocmlir/" + relative] = file
    notices["migraphx/LICENSE"] = original_backend_license(args.work, args.source_sha256)
    write_backend_receipt(args, files, notices)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=("check-prefix", "stage"))
    parser.add_argument("--prefix", required=True, type=Path)
    parser.add_argument("--work", type=Path)
    parser.add_argument("--deps-prefix")
    parser.add_argument("--version")
    parser.add_argument("--source-commit")
    parser.add_argument("--source-sha256")
    parser.add_argument("--patch", type=Path)
    parser.add_argument("--python-patch", type=Path)
    args = parser.parse_args()
    try:
        if args.action == "check-prefix":
            check_prefix(args.prefix)
        else:
            require(all(getattr(args, name) is not None for name in
                        ("work", "deps_prefix", "version", "source_commit", "source_sha256", "patch", "python_patch")), "Incomplete backend stage arguments")
            stage(args)
    except (OSError, TypeError, ValueError, tarfile.TarError) as error:
        print("MIGraphX install refused: " + str(error), file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
