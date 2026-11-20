#!/usr/bin/env python3
"""Launch ordinary ROCm amd64 Android from its verified native Media parent; no runtime or FINAL acceptance."""

import argparse
from pathlib import Path

from media_handoff_profile import load_media, media_layout
from normal_stage_launch import downstream_record, launch_stage


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ('compiler-plan', 'media-invocation', 'parent-proof', 'output'):
        parser.add_argument('--' + name, required=True, type=Path)
    parser.add_argument('--unit', required=True)
    parser.add_argument('--image-repo', required=True)
    args = parser.parse_args()
    plan, invocation, gpu = load_media(args.compiler_plan, args.media_invocation)
    parent, context = media_layout(args.parent_proof, args.media_invocation, invocation, gpu)
    record = downstream_record(invocation, args.media_invocation, args.parent_proof, parent, 'Media')
    record.update(stage='android', variant='rocm', Media_layers_rehashed=parent['layers'],
                  GPU_layers_matched=gpu['layers'], scope=__doc__, GPU_or_FINAL_acceptance=False)
    reference = invocation['image'].rsplit(':', 1)[0] + '@' + parent['manifest']
    return launch_stage(Path(invocation['source']), args.output.resolve(), args.unit, args.image_repo, 'android', 'amd64',
                        context, reference, plan['required_bytes'], record, variant='rocm')


if __name__ == '__main__':
    raise SystemExit(main())
