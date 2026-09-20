# Hailo Dataflow Compiler (DFC) drop point — Linux x86_64

This directory is the **opt-in** drop point for the Hailo Dataflow Compiler
wheel. The DFC compiles ONNX/TFLite models to `.hef`, the only format Hailo
devices execute.

## Why a manual drop

The DFC is **login-gated** (Hailo Developer Zone account) and EULA-bound, so it
cannot be downloaded by the build. Same contract as `linux/qnn-sdk/` and the
Windows TensorRT zip: you stage it, the build installs it.

## What to stage

The wheel from the Hailo Developer Zone, for example
`hailo_dataflow_compiler-<version>-py3-none-linux_x86_64.whl`.

`linux/Dockerfile.torch` installs every `*.whl` staged here into `/opt/venv` of
the **amd64** runtime image; aarch64 and riscv64 skip it, because Hailo ships
the DFC for x86_64 only. The runtime image needs no DFC to *run* a model — this
drop is for a development image that compiles on the board.

## Model Zoo

The [Hailo Model Zoo](https://github.com/hailo-ai/hailo_model_zoo) (MIT) is a
**host-side** tool: it drives the DFC (`hailomz compile ...`) and needs the
`hailo` CLI on PATH. It is not installed into the image; install it on the host
that runs the DFC, per its README.
