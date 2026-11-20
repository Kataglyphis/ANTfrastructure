#!/usr/bin/env bash
# Synthetic delivered products and a fake Node prove refusal and orchestration, not compiled ORT or hardware.
exec bash "$(dirname "${BASH_SOURCE[0]}")/test-onnx-webgpu-runtime.sh" --acceptance "$@"
