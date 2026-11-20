#!/usr/bin/env bash
# Fake child processes and ELF receipts prove preparation/dispatch failures, not actual ORT, NumPy or GPU behavior.
exec bash "$(dirname "${BASH_SOURCE[0]}")/test-onnx-webgpu-runtime.sh" --media "$@"
