#!/usr/bin/env bash
# Both entry points use the same fixture lifecycle; this selects cache controls rather than compiler passes.
exec bash "$(dirname "${BASH_SOURCE[0]}")/test-onnx-wasm-passes.sh" --cache "$@"
