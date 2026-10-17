#!/usr/bin/env python3
# Copyright (c) 2026 Kataglyphis
# SPDX-License-Identifier: MIT
"""A tracked data file over 500 KiB (binary, or a document, media, model or scene format)
belongs in ModelANT or AssetANT, or it is frozen in large-files.allow with its size and a reason.
docs/data-repositories.md#keeping-data-out-of-the-code-repositories"""

import argparse
import os
import subprocess
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from quality_allow import check_counts, load_counts  # noqa: E402
import gate_scope  # noqa: E402

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))
ALLOW = os.path.join(HERE, "large-files.allow")
LIMIT_KIB = 500
REGULAR = ("100644", "100755")
FMT = "<path> | <KiB> | <reason>"
# git's own test: a NUL byte in the first 8000 bytes makes a file binary.
SNIFF = 8000
# Data whatever its bytes: a PDF can open without a NUL, and .obj/.gltf scenes are text.
DATA_EXT = frozenset("""
    .pdf .obj .mtl .gltf .glb .ply .stl .fbx .dae .blend .usd .usda .usdc .usdz
    .onnx .pt .pth .tflite .gguf .safetensors .npy .npz .csv .tsv
    .png .jpg .jpeg .gif .webp .bmp .tga .dds .ktx .ktx2 .hdr .exr .mp4 .webm .mov .mp3 .wav
    .zip .gz .xz .7z .tar .whl .exe .dll .so .a .lib
""".split())


def is_data(path):
    if os.path.splitext(path)[1].lower() in DATA_EXT:
        return True
    with open(path, "rb") as fh:
        return b"\0" in fh.read(SNIFF)


def large_data(root):
    """[((rel,), KiB)] for every tracked regular data file over the limit; source text (lockfiles, generated code) is not data."""
    out = subprocess.run(["git", "-C", root, "ls-files", "-s", "-z"], capture_output=True, text=True, encoding="utf-8")
    if out.returncode != 0:
        raise gate_scope.ScopeError("%s is not a git checkout; --root must be one" % root)
    found, missing = [], []
    for entry in filter(None, out.stdout.split("\0")):
        meta, rel = entry.split("\t", 1)
        # Symlinks (120000) and gitlinks (160000) are paths, not data: one into an absent submodule must not fail the tree.
        if meta.split()[0] not in REGULAR or rel.split("/", 1)[0] in gate_scope.EXCLUDE:
            continue
        path = os.path.join(root, rel)
        if not os.path.isfile(path):
            missing.append(rel)
            continue
        kib = os.path.getsize(path) // 1024
        if kib > LIMIT_KIB and is_data(path):
            found.append(((rel,), kib))
    if missing:
        raise gate_scope.ScopeError("%d tracked file(s) are not on disk, so this gate would grade a partial tree: %s"
                                    % (len(missing), ", ".join(sorted(missing)[:5])))
    return found


def main():
    ap = argparse.ArgumentParser(description="Keep big binary data out of the code repositories.")
    ap.add_argument("--root", default=None, help="the tree to grade (default: this repo)")
    ap.add_argument("--allow", default=None,
                    help="the freeze file (default: large-files.allow beside this script for "
                         "the hub, <root>/large-files.allow otherwise)")
    args = ap.parse_args()
    try:
        root = gate_scope.resolve_root(args.root, ROOT)
        found = large_data(root)
    except gate_scope.ScopeError as exc:
        return gate_scope.die(exc)
    # A consumer's freeze lives in the consumer, where its own diff shows it.
    allow = args.allow or (ALLOW if gate_scope.is_hub(root, ROOT) else os.path.join(root, "large-files.allow"))
    print("=== large data files (over %d KiB) ===" % LIMIT_KIB)
    print("  root:  %s\n  allow: %s" % (root, allow))
    rc = check_counts("files", found, load_counts(allow, 1, FMT), LIMIT_KIB,
                      os.path.basename(allow), unit="KiB")
    if rc:
        sys.stderr.write("A model, scene, document or media file goes to ModelANT or AssetANT and is "
                         "fetched by lock (docs/data-repositories.md); freeze it only if the repo must "
                         "track it.\n")
    else:
        print("OK: no new, grown or shrunk large data files")
    return rc


if __name__ == "__main__":
    sys.exit(main())
