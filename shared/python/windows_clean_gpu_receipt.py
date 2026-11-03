#!/usr/bin/env python3
# Copyright (c) 2026 Kataglyphis. All rights reserved.
# SPDX-License-Identifier: MIT
"""Run a trusted Windows check against a digest-bound GPU artifact."""

from __future__ import annotations

import argparse
import importlib
import os
import shutil
import sys
import tempfile
import zipfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
receipt = importlib.import_module("gpu_artifact_receipt")
prepare = importlib.import_module("prepare_gpu_artifact")
stage = importlib.import_module("stage_gpu_artifact")
process = importlib.import_module("windows_gpu_process")


def validate_evidence(directory: Path, *, empty: bool) -> None:
    """Require a real empty directory first, then nonempty regular evidence files."""
    if receipt.is_link(directory) or not directory.is_dir():
        raise ValueError("GPU evidence must be a real directory")
    entries = list(directory.rglob("*"))
    if empty:
        if entries:
            raise ValueError("GPU evidence directory must start empty")
        return
    if not entries or not any(item.is_file() for item in entries):
        raise ValueError("GPU profile produced no evidence files")
    if any(
        receipt.is_link(item) or not (item.is_file() or item.is_dir())
        for item in entries
    ):
        raise ValueError("GPU evidence must contain only real directories and files")


def check(args: argparse.Namespace) -> None:
    """Check the same immutable package bytes before and after the caller's script."""
    identity = {key: getattr(args, key) for key in receipt.IDENTITY if key != "check"}
    receipt.validate_identity({**identity, "check": "before-check"})
    if identity["platform"] != "windows":
        raise ValueError("the clean-host action only accepts Windows packages")
    names = receipt.validate_files(args.file)
    output = Path(args.receipt)
    script = Path(args.script)
    work = Path(args.work)
    check_name = getattr(args, "check", "clean-host-inference")
    evidence_value = getattr(args, "evidence_dir", None)
    if check_name not in {"clean-host-inference", "gpu-model-inference"}:
        raise ValueError("unsupported Windows GPU check")
    if (check_name == "gpu-model-inference") != bool(evidence_value):
        raise ValueError("GPU profiling requires its own evidence directory")
    if (
        not output.is_absolute()
        or os.path.lexists(output)
        or receipt.is_link(work)
        or not work.is_dir()
        or output.resolve().is_relative_to(work.resolve())
    ):
        raise ValueError("receipt must be new and work directory must be real")
    if evidence_value:
        evidence = Path(evidence_value)
        if not evidence.is_absolute() or evidence.resolve().is_relative_to(
            work.resolve()
        ):
            raise ValueError("GPU evidence must be outside package scratch")
        validate_evidence(evidence, empty=True)
    if (
        receipt.is_link(script)
        or not script.is_file()
        or script.suffix.lower() != ".ps1"
    ):
        raise ValueError("the trusted check must be a regular PowerShell script")
    with (
        stage.open_regular(Path(args.archive)) as source,
        zipfile.ZipFile(source) as archive,
    ):
        entries = stage.archive_entries(
            archive, names, args.max_uncompressed_bytes, args.max_compression_ratio
        )
        expanded = sum(item.file_size for item in entries)
    if (
        args.floor < 0
        or args.cushion < 0
        or shutil.disk_usage(work).free - expanded < args.floor + args.cushion
    ):
        raise ValueError("insufficient disk space for the installer archive")
    with tempfile.TemporaryDirectory(
        prefix="windows-gpu-clean-", dir=work
    ) as temporary:
        root = Path(temporary)
        packages = root / "packages"
        before = root / "before.json"
        prepare.prepare(
            argparse.Namespace(
                **identity,
                archive=args.archive,
                output=str(packages),
                before_receipt=str(before),
                file=names,
                max_uncompressed_bytes=args.max_uncompressed_bytes,
                max_compression_ratio=args.max_compression_ratio,
            )
        )
        receipt.execute(
            argparse.Namespace(
                **identity,
                check="producer-verified",
                file=names,
                receipt=args.producer_receipt,
                directory=str(packages),
                operation="verify",
            )
        )
        env = os.environ.copy()
        env.update(GPU_PACKAGE_DIR=str(packages), GPU_VENDOR=identity["vendor"])
        if evidence_value:
            env["GPU_EVIDENCE_DIR"] = str(evidence)
        process.run_process(
            [args.pwsh, "-NoProfile", "-NonInteractive", "-File", str(script)],
            timeout=args.timeout,
            env=env,
        )
        if evidence_value:
            validate_evidence(evidence, empty=False)
            if shutil.disk_usage(work).free < args.floor:
                raise ValueError("GPU profile crossed the required disk floor")
        passed = root / "passed.json"
        for receipt_check, path, operation in (
            ("before-check", before, "verify"),
            (check_name, passed, "create"),
        ):
            receipt.execute(
                argparse.Namespace(
                    **identity,
                    check=receipt_check,
                    file=names,
                    receipt=str(path),
                    directory=str(packages),
                    operation=operation,
                )
            )
        data = passed.read_bytes()
    stream = output.open("xb")
    try:
        with stream:
            stream.write(data)
    except OSError:
        output.unlink(missing_ok=True)
        raise


def main() -> int:
    """Accept trusted workflow identity and the caller-owned check script."""
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ("archive", "receipt", "producer-receipt", "script", "work", "pwsh"):
        parser.add_argument("--" + name, required=True)
    parser.add_argument("--file", action="append", required=True)
    parser.add_argument(
        "--check",
        choices=("clean-host-inference", "gpu-model-inference"),
        default="clean-host-inference",
    )
    parser.add_argument("--evidence-dir")
    for name in (
        "max-uncompressed-bytes",
        "max-compression-ratio",
        "floor",
        "cushion",
        "timeout",
    ):
        parser.add_argument("--" + name, type=int, required=True)
    for key in receipt.IDENTITY:
        if key != "check":
            parser.add_argument("--" + key.replace("_", "-"), required=True)
    try:
        args = parser.parse_args()
        if args.timeout < 1:
            raise ValueError("timeout must be positive")
        check(args)
    except (OSError, ValueError, TypeError, RuntimeError, zipfile.BadZipFile) as exc:
        print(f"Windows clean-host receipt: {exc}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
