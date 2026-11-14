"""Identify reviewed read-only cache readers; a matching command does not authenticate a build or classify cache errors."""

import re

PHASE_MARKERS = {'gcc':'dockerfile-gcc', 'llvm':'dockerfile-llvm',
                 'rust':'/opt/scripts/toolchain/install-rust.sh', 'python':'/opt/scripts/python/build_python.sh',
                 'migraphx':'bash /opt/scripts/03-media/build/migraphx/build-image.sh '}


def validate_capture_unit(unit: str, phase: str) -> None:
    assert phase in PHASE_MARKERS, 'Unknown cache capture phase'
    owner = 'gpu' if phase == 'migraphx' else 'compiler'
    assert re.fullmatch(r'webgpu-' + owner + r'[0-9]+-' + phase + r'-error-capture-[0-9-]+\.service', unit), 'Cache capture unit and phase differ'
