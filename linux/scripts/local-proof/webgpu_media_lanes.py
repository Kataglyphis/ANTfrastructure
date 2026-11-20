"""Prepare six Media command profiles; no launch, OCI/source ancestry, compiled products or hardware acceptance."""

from __future__ import annotations

import re
from pathlib import Path
from typing import TYPE_CHECKING

from normal_stage_launch import stage_inputs

if TYPE_CHECKING:
    from proof_types import Json

LANES = (('default', 'amd64'), ('default', 'arm64'), ('default', 'riscv64'),
         ('rocm', 'amd64'), ('nvidia', 'amd64'), ('nvidia', 'arm64'))


def media_inputs(source: Path, output: Path, repo: str, variant: str, arch: str,
                 parent_stage: str, context: Path, reference: str) -> Json:
    assert (variant, arch) in LANES, 'Unreviewed WebGPU Media lane'
    expected_parent = 'sdk' if variant == 'default' else 'gpu'
    assert parent_stage == expected_parent, 'Media parent stage differs from its variant'
    assert re.fullmatch(r'ant-local/webgpu-[a-z0-9][a-z0-9._/-]*', repo), 'Local Media candidate repository required'
    assert re.fullmatch(r'ant-local/webgpu-[a-z0-9][a-z0-9._/-]*@sha256:[0-9a-f]{64}', reference), 'Immutable local Media parent required'
    assert all(path.is_absolute() for path in (source, output, context)), 'Media paths must be absolute'
    image, environment, driver = stage_inputs(source, output, repo, 'media', arch, context, reference,
                                              '' if variant == 'default' else variant)
    environment += ['CROSS_BUILD_PLATFORM=linux/amd64']
    environment += ['ORT_ENABLE_WEBGPU=true', 'ORT_WEBGPU_ALLOW_CROSS=true']
    environment += ['ENABLE_AMD=' + ('true' if variant == 'rocm' else 'false'),
                    'ENABLE_NVIDIA=' + ('true' if variant == 'nvidia' else 'false')]
    if variant == 'default':
        environment += ['CROSS_VARIANT=']
    if (variant, arch) == ('nvidia', 'arm64'):
        environment += ['CROSS_NVIDIA_SBSA=1']
    return {'variant':variant, 'target_arch':arch, 'parent_stage':parent_stage, 'image':image,
            'environment':environment, 'driver':driver, 'publication':False,
            'parent_ancestry_verified':False, 'launched':False, 'scope':__doc__}
