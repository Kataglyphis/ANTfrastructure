#!/usr/bin/env python3
"""Launch the ordinary local ROCm amd64 runtime from verified native Android; no publication or FINAL acceptance."""

import argparse
from pathlib import Path

from android_handoff_profile import android_layout, load_android
from runtime_launch_profile import launch_runtime


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ('compiler-plan', 'android-invocation', 'parent-proof', 'output'):
        parser.add_argument('--' + name, required=True, type=Path)
    for name in ('unit', 'image-prefix', 'app-ref'):
        parser.add_argument('--' + name, required=True)
    parser.add_argument('--runtime-source', type=Path)
    parser.add_argument('--runtime-source-proof', type=Path)
    args = parser.parse_args()
    plan, invocation, media = load_android(args.compiler_plan, args.android_invocation)
    parent, context = android_layout(args.parent_proof, args.android_invocation, invocation, media)
    return launch_runtime(plan, invocation, args.android_invocation, parent, context, args.parent_proof,
                          args.output.resolve(), args.unit, args.image_prefix, args.app_ref,
                          selected_source=args.runtime_source, source_proof=args.runtime_source_proof)


if __name__ == '__main__':
    raise SystemExit(main())
