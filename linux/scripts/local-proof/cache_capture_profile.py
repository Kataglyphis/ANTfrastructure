"""Identify reviewed read-only cache readers; a matching command does not authenticate a build or classify cache errors."""

import re

MEDIA_PHASE_MARKERS = {
    'ort-cpu': 'bash /opt/scripts/03-media/build/onnxruntime/build/build-onnxruntime.sh --step cpu;',
    'ort-gpu': 'bash /opt/scripts/03-media/build/onnxruntime/build/build-onnxruntime.sh --step gpu;',
    'ort-web': 'bash /opt/scripts/03-media/build/onnxruntime/build/web-wasm-cache.sh;',
    'opencv': 'bash /opt/scripts/03-media/build/opencv/build-opencv.sh ',
    'app-wheelhouse': 'bash /opt/scripts/frameworks/torch/build-app-wheelhouse.sh;',
}

PHASE_MARKERS = {'gcc':'dockerfile-gcc', 'llvm':'dockerfile-llvm',
                 'rust':'/opt/scripts/toolchain/install-rust.sh', 'python':'/opt/scripts/python/build_python.sh',
                 'migraphx':'bash /opt/scripts/03-media/build/migraphx/build-image.sh ', **MEDIA_PHASE_MARKERS}


def validate_capture_unit(unit: str, phase: str) -> None:
    assert phase in PHASE_MARKERS, 'Unknown cache capture phase'
    owner = 'media' if phase in MEDIA_PHASE_MARKERS else ('gpu' if phase == 'migraphx' else 'compiler')
    assert re.fullmatch(r'webgpu-' + owner + r'[0-9]+-' + phase + r'-error-capture-[0-9-]+\.service', unit), 'Cache capture unit and phase differ'
