#!/usr/bin/env python3

from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path


START_MARKER = "<!-- generated:version-snapshot:start -->"
END_MARKER = "<!-- generated:version-snapshot:end -->"

REPO_ROOT = Path(__file__).resolve().parents[2]


def read_repo_file(relative_path: str) -> str:
    return (REPO_ROOT / relative_path).read_text(encoding="utf-8")


def extract(pattern: str, text: str, description: str) -> str:
    match = re.search(pattern, text, re.MULTILINE)
    if not match:
        raise ValueError(f"Could not find {description}")
    return match.group(1)


def collect_versions() -> dict[str, str]:
    linux_base = read_repo_file("linux/Dockerfile.base")
    linux_webserver = read_repo_file("linux/webserver/Dockerfile")
    linux_common = read_repo_file("linux/scripts/01-core/common.sh")
    linux_android = read_repo_file("linux/Dockerfile.android")
    windows_dockerfile = read_repo_file("windows/Dockerfile")
    windows_vs = read_repo_file("windows/scripts/setup-vs.ps1")

    return {
        "linux_ubuntu": extract(r"^FROM ubuntu:([^\s]+)$", linux_base, "Linux Ubuntu version"),
        "linux_cmake": extract(r"^ARG CMAKE_VERSION=([^\s]+)$", linux_base, "Linux CMake version"),
        "linux_vulkan": extract(r"^ARG VULKAN_VERSION=([^\s]+)$", linux_base, "Linux Vulkan version"),
        "linux_llvm": extract(
            r'LLVM_WANTED="\$\{LLVM_RELEASE:-([^}]+)\}"',
            linux_common,
            "Linux LLVM version",
        ),
        "linux_gcc": extract(
            r'GCC_WANTED="\$\{GCC_VERSION:-([^}]+)\}"',
            linux_common,
            "Linux GCC version",
        ),
        "android_sdk": extract(r"^ARG ANDROID_SDK_VERSION=([^\s]+)$", linux_android, "Android SDK version"),
        "android_ndk": extract(r"^ARG ANDROID_NDK_VERSION=([^\s]+)$", linux_android, "Android NDK version"),
        "android_cmake": extract(r"^ARG ANDROID_CMAKE_VERSION=([^\s]+)$", linux_android, "Android CMake version"),
        "webserver_ubuntu": extract(r"^FROM ubuntu:([^\s]+)$", linux_webserver, "Webserver Ubuntu version"),
        "windows_ltsc": extract(
            r"^FROM mcr\.microsoft\.com/windows/servercore:ltsc([^\s]+)$",
            windows_dockerfile,
            "Windows LTSC version",
        ),
        "windows_vulkan": extract(r"^ARG VULKAN_VERSION=([^\s]+)$", windows_dockerfile, "Windows Vulkan version"),
        "windows_gstreamer": extract(r"^ARG GST_VERSION=([^\s]+)$", windows_dockerfile, "Windows GStreamer version"),
        "windows_cuda": extract(r"^ARG CUDA_VERSION=([^\s]+)$", windows_dockerfile, "Windows CUDA version"),
        "windows_onnx": extract(r"^ARG ONNX_VERSION=([^\s]+)$", windows_dockerfile, "Windows ONNX version"),
        "windows_vs": extract(
            r"Visual Studio\\([0-9]+)\\BuildTools",
            windows_vs,
            "Visual Studio Build Tools major version",
        ),
    }


def render_snapshot() -> str:
    versions = collect_versions()
    return "\n".join(
        [
            START_MARKER,
            "## Source-Controlled Version Snapshot",
            "",
            "This block is generated from the Dockerfiles and setup scripts by `python3 docs/scripts/sync_versions.py --write`.",
            "",
            "| Target | Source-controlled defaults |",
            "| --- | --- |",
            (
                "| Linux base image | "
                f"Ubuntu {versions['linux_ubuntu']}, LLVM/Clang {versions['linux_llvm']}, "
                f"GCC {versions['linux_gcc']}, CMake {versions['linux_cmake']}, "
                f"Vulkan SDK {versions['linux_vulkan']} |"
            ),
            (
                "| Android layer | "
                f"Android SDK {versions['android_sdk']}, NDK {versions['android_ndk']}, "
                f"CMake {versions['android_cmake']} |"
            ),
            f"| Webserver image | Ubuntu {versions['webserver_ubuntu']} |",
            (
                "| Windows build image | "
                f"Windows Server Core LTSC {versions['windows_ltsc']}, "
                f"Visual Studio Build Tools {versions['windows_vs']}, "
                f"Vulkan SDK {versions['windows_vulkan']}, "
                f"GStreamer {versions['windows_gstreamer']}, "
                f"CUDA {versions['windows_cuda']}, "
                f"ONNX Runtime {versions['windows_onnx']} |"
            ),
            END_MARKER,
        ]
    )


def update_marked_block(file_path: Path, replacement: str) -> bool:
    original = file_path.read_text(encoding="utf-8")
    pattern = re.compile(re.escape(START_MARKER) + r".*?" + re.escape(END_MARKER), re.DOTALL)
    if not pattern.search(original):
        raise ValueError(f"Markers not found in {file_path}")
    updated = pattern.sub(replacement, original, count=1)
    if updated == original:
        return False
    file_path.write_text(updated, encoding="utf-8")
    return True


def is_marked_block_current(file_path: Path, replacement: str) -> bool:
    original = file_path.read_text(encoding="utf-8")
    pattern = re.compile(re.escape(START_MARKER) + r".*?" + re.escape(END_MARKER), re.DOTALL)
    if not pattern.search(original):
        raise ValueError(f"Markers not found in {file_path}")
    updated = pattern.sub(replacement, original, count=1)
    return updated == original


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Sync generated documentation version snapshots.")
    parser.add_argument("--check", action="store_true", help="Fail if generated sections are out of date.")
    parser.add_argument("--write", action="store_true", help="Rewrite generated sections in place.")
    return parser.parse_args()


def target_files() -> list[Path]:
    return [REPO_ROOT / "README.md", REPO_ROOT / "docs/overview.md"]


def check_snapshot(replacement: str) -> int:
    stale_files = [
        str(path.relative_to(REPO_ROOT))
        for path in target_files()
        if not is_marked_block_current(path, replacement)
    ]
    if stale_files:
        print("Generated version snapshot is out of date in:", file=sys.stderr)
        for path in stale_files:
            print(f"- {path}", file=sys.stderr)
        print("Run: python3 docs/scripts/sync_versions.py --write", file=sys.stderr)
        return 1
    print("Generated version snapshot is up to date.")
    return 0


def write_snapshot(replacement: str) -> int:
    changed_files = [
        str(path.relative_to(REPO_ROOT))
        for path in target_files()
        if update_marked_block(path, replacement)
    ]
    if changed_files:
        print("Updated generated version snapshot in:")
        for path in changed_files:
            print(f"- {path}")
    else:
        print("Generated version snapshot already up to date.")
    return 0


def determine_mode(args: argparse.Namespace) -> str:
    if args.check and args.write:
        raise ValueError("Use either --check or --write, not both.")
    return "check" if args.check or not args.write else "write"


def main() -> int:
    args = parse_args()
    try:
        mode = determine_mode(args)
    except ValueError as error:
        print(str(error), file=sys.stderr)
        return 2

    replacement = render_snapshot()
    if mode == "check":
        return check_snapshot(replacement)
    return write_snapshot(replacement)


if __name__ == "__main__":
    raise SystemExit(main())