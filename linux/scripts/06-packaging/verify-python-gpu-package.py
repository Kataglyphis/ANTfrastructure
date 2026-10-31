#!/usr/bin/env python3
"""Prove a finished Python GPU package preserves one wheel's ORT provider set."""
from __future__ import annotations

import argparse
import hashlib
import json
import re
import subprocess
import sys
import tarfile
import tempfile
from pathlib import Path, PurePosixPath
from typing import BinaryIO

PROVIDER = re.compile(r"libonnxruntime_providers_[A-Za-z0-9_]+\.so(?:\.[0-9]+)*\Z")
KINDS = {"CUDAExecutionProvider": "cuda", "MIGraphXExecutionProvider": "migraphx"}


def sha(stream: BinaryIO) -> tuple[str, int]:
    value = hashlib.sha256()
    size = 0
    while chunk := stream.read(1024 * 1024):
        size += len(chunk)
        value.update(chunk)
    return value.hexdigest(), size


def regular(path: Path, root: Path) -> None:
    if not path.is_file() or not path.resolve().is_relative_to(root):
        raise ValueError(f"missing, linked or escaping package file: {path}")
    current = root
    for part in path.relative_to(root).parts:
        current /= part
        if current.is_symlink():
            raise ValueError(f"linked package path: {current}")
    if path.stat().st_size == 0:
        raise ValueError(f"empty package file: {path}")


def source_libraries(root: Path, kind: str) -> tuple[Path, list[Path], set[str]]:
    capis = list((root / "runtime").glob("lib*/python*/site-packages/onnxruntime/capi"))
    if len(capis) != 1 or not capis[0].is_dir() or not capis[0].resolve().is_relative_to(root):
        raise ValueError("GPU bundle must contain exactly one in-bundle ORT capi directory")
    capi = capis[0]
    candidates = [p for p in capi.iterdir() if p.name.startswith("libonnxruntime_providers_")]
    if any(not PROVIDER.fullmatch(p.name) for p in candidates):
        raise ValueError("invalid ORT provider filename")
    providers = {p.name for p in candidates}
    if not {"libonnxruntime_providers_shared.so", f"libonnxruntime_providers_{kind}.so"} <= providers:
        raise ValueError("required ORT provider or shared bridge is missing")
    cores = list(capi.glob("libonnxruntime.so.*"))
    if len(cores) != 1:
        raise ValueError("GPU bundle must contain exactly one ORT core")
    return capi, cores + candidates, providers


def source_inventory(bundle: Path) -> tuple[Path, dict[str, tuple[str, int]], set[str]]:
    root = bundle.resolve(strict=True)
    manifest_path = root / "bundle.json"
    regular(manifest_path, root)
    manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    if not isinstance(manifest, dict):
        raise ValueError("GPU bundle manifest must be an object")
    provider = manifest.get("required_provider")
    kind = KINDS.get(provider) if isinstance(provider, str) else None
    if kind is None:
        raise ValueError("GPU bundle must name the CUDA or MIGraphX provider")
    capi, source, providers = source_libraries(root, kind)
    requirements = root / "REQUIRES-GPU-RUNTIME.txt"
    if manifest.get("host_gpu_sonames") and not requirements.is_file():
        raise ValueError("host GPU bundle is missing its runtime requirements")
    if requirements.exists() or requirements.is_symlink():
        source.append(requirements)
    source.append(manifest_path)
    for path in source:
        regular(path, root)
    hashes = {}
    for path in source:
        with path.open("rb") as stream:
            hashes[path.relative_to(root).as_posix()] = sha(stream)
    return capi, hashes, providers


def prove_wheel(capi: Path, wheels: Path, scratch: Path) -> None:
    libraries = sorted(capi.glob("libonnxruntime.so.*")) + sorted(capi.glob("libonnxruntime_providers_*.so*"))
    command = [sys.executable, str(Path(__file__).with_name("stage-ort-wheel-licenses.py")),
               "--wheel-dir", str(wheels), "--destination", str(scratch), "--strip", "strip", "--require-unstripped"]
    for library in libraries:
        command.extend(("--library", str(library)))
    subprocess.run(command, check=True)


def safe_name(name: str) -> str:
    while name.startswith("./"):
        name = name[2:]
    if (not name or name.startswith("/") or "\\" in name or any(ord(c) < 32 for c in name) or
            any(part in ("", ".", "..") for part in name.rstrip("/").split("/"))):
        raise ValueError(f"unsafe archive member: {name!r}")
    return name.rstrip("/")


def check_tar_member(archive: tarfile.TarFile, entry: tarfile.TarInfo, targets: dict[str, tuple[str, int]],
                     provider_dir: str, parents: set[str], seen: set[str], actual_providers: set[str]) -> None:
    if entry.name in ("", ".", "./") and entry.isdir():
        return
    name = safe_name(entry.name)
    if name in parents and not entry.isdir():
        raise ValueError(f"linked or non-directory package parent: {name}")
    if name.startswith(provider_dir) and "/" not in name[len(provider_dir):]:
        base = name[len(provider_dir):]
        if base.startswith("libonnxruntime_providers_"):
            if base in actual_providers:
                raise ValueError(f"duplicate provider: {name}")
            actual_providers.add(base)
    if name not in targets:
        return
    if name in seen or not entry.isfile() or entry.size != targets[name][1]:
        raise ValueError(f"duplicate or non-regular package member: {name}")
    seen.add(name)
    content = archive.extractfile(entry)
    if content is None or sha(content) != targets[name]:
        raise ValueError(f"package member differs from proven bundle: {name}")


def check_tar(stream: BinaryIO, prefix: str, expected: dict[str, tuple[str, int]], providers: set[str], capi: str) -> None:
    targets = {f"{prefix}/{name}": value for name, value in expected.items()}
    provider_dir = f"{prefix}/{capi}/"
    parents = {str(parent) for name in targets for parent in PurePosixPath(name).parents if str(parent) != "."}
    seen: set[str] = set()
    actual_providers: set[str] = set()
    with tarfile.open(fileobj=stream, mode="r|*") as archive:
        for entry in archive:
            check_tar_member(archive, entry, targets, provider_dir, parents, seen, actual_providers)
    if seen != targets.keys() or actual_providers != providers:
        raise ValueError("finished package has missing members or a different ORT provider set")


def check_directory(root: Path, prefix: str, expected: dict[str, tuple[str, int]], providers: set[str], capi: str) -> None:
    root = root.resolve(strict=True)
    base = root / prefix
    provider_dir = base / capi
    if not provider_dir.is_dir() or not provider_dir.resolve().is_relative_to(root):
        raise ValueError("AppImage ORT directory is missing or escapes its root")
    actual = {p.name for p in provider_dir.iterdir() if p.name.startswith("libonnxruntime_providers_")}
    if actual != providers:
        raise ValueError("AppImage has a different ORT provider set")
    for relative, wanted in expected.items():
        path = base / relative
        regular(path, root)
        with path.open("rb") as stream:
            if sha(stream) != wanted:
                raise ValueError(f"AppImage member differs from proven bundle: {relative}")


def check_artifact(artifact: Path, prefix: str, expected: dict[str, tuple[str, int]], providers: set[str], capi: str) -> None:
    if artifact.name.endswith(".tar.gz"):
        with artifact.open("rb") as stream:
            check_tar(stream, prefix, expected, providers, capi)
    elif artifact.suffix == ".deb":
        with tempfile.TemporaryFile() as errors:
            process = subprocess.Popen(["dpkg-deb", "--fsys-tarfile", str(artifact)], stdout=subprocess.PIPE, stderr=errors)
            assert process.stdout is not None
            try:
                check_tar(process.stdout, prefix, expected, providers, capi)
                while process.stdout.read(1024 * 1024):
                    pass
            except BaseException:
                process.kill()
                process.wait()
                raise
            finally:
                process.stdout.close()
            if process.wait() != 0:
                raise ValueError("dpkg-deb could not read the finished package")
    elif artifact.suffix == ".AppImage":
        with tempfile.TemporaryDirectory(prefix="python-gpu-appimage-") as temporary:
            subprocess.run([str(artifact.resolve()), "--appimage-extract"], cwd=temporary, check=True, stdout=subprocess.DEVNULL)
            check_directory(Path(temporary) / "squashfs-root", prefix, expected, providers, capi)
    else:
        raise ValueError("unsupported GPU package format")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--bundle", type=Path, required=True)
    parser.add_argument("--wheel-dir", type=Path, required=True)
    parser.add_argument("--artifact", type=Path, required=True)
    parser.add_argument("--prefix", required=True)
    args = parser.parse_args()
    try:
        prefix = safe_name(args.prefix)
        if prefix != args.prefix:
            raise ValueError("package prefix must be canonical")
        capi, hashes, providers = source_inventory(args.bundle)
        with tempfile.TemporaryDirectory(prefix="python-gpu-wheel-") as temporary:
            prove_wheel(capi, args.wheel_dir, Path(temporary))
        capi_relative = capi.relative_to(args.bundle.resolve()).as_posix()
        check_artifact(args.artifact, prefix, hashes, providers, capi_relative)
        _, after, after_providers = source_inventory(args.bundle)
        if after != hashes or after_providers != providers:
            raise ValueError("GPU bundle changed during finished-package verification")
    except (OSError, ValueError, tarfile.TarError, json.JSONDecodeError, subprocess.CalledProcessError) as exc:
        print(f"FAIL: {exc}", file=sys.stderr)
        return 1
    print(f"PASS: {args.artifact}: wheel-proven ORT provider set and metadata match")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
