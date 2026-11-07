# MIGraphX EP binds a strided partition output onto ORT's dense buffer and corrupts it

Upstream: microsoft/onnxruntime, issue (bug report). **Status (2026-11-07): not to be filed**, see `PR.md`:
MIGraphX fixed the root cause (ROCm/AMDMIGraphX#5345) and the built-in EP is unmaintained.

## Title

MIGraphX EP: a partition output that MIGraphX returns as a strided view is bound to ORT's dense buffer; wrong, drifting results

## Body

**Describe the issue**

With the MIGraphX execution provider, a model whose graph is split into several partitions returns
wrong detections that differ from run to run. Running the same ONNX file through MIGraphX alone
(`migraphx.parse_onnx` + `compile` + `run`) matches the CPU provider (max abs diff 0.0025, three
identical runs), so the kernels are right; the EP's output binding is not.

The model is a DEIM / D-FINE-N COCO detector (`images` 1x3x640x640 float32). The EP leaves its six
`GridSample` ops and the stem's ceil-mode `MaxPool` on the CPU, so the graph becomes five MIGraphX
partitions. One of them is only a `Slice` followed by a `Reshape` that cuts the 40x40 level out of a
shared value tensor. For that partition MIGraphX returns the output `Reshape_3_output_0` as a view:
lens `[8, 16, 40, 40]`, strides `[32000, 2000, 40, 1]`, `standard() == false`.

`MIGraphXExecutionProvider::Compile`'s compute function binds every `#output_N` parameter straight
onto ORT's output tensor with MIGraphX's shape for it
(`onnxruntime/core/providers/migraphx/migraphx_execution_provider.cc`, the
`m.add(name, migraphx::argument(mgx_arg_shape, output_data))` line, around line 1580 in v1.31.0):

```cpp
auto mgx_arg_shape = param_shapes[name];
m.add(name, migraphx::argument(mgx_arg_shape, output_data));
```

So MIGraphX writes a strided layout into a buffer ORT then reads as dense: the dense reader sees the
strided bytes, and the write overruns the tensor's allocation (`mgx_arg_shape.bytes()` is larger than
the dense size), corrupting whatever ORT's arena placed after it. That is why run 1 differs from run 2
and why `enable_mem_pattern=False` makes the result deterministic but still wrong. Emulating the
strided write on the CPU reproduces ORT's GPU tensor to 6e-6 on the 80 % of elements the strided write
defines. `HIP_LAUNCH_BLOCKING=1` and `AMD_SERIALIZE_KERNEL/COPY` change nothing.

**To reproduce**

1. Any model where a MIGraphX partition ends in a `Slice` + `Reshape` whose result MIGraphX keeps as a
   view (the EP's op list lacks `GridSample`, so a DEIM/D-FINE detector produces one). We can share the
   cut single-partition ONNX (11 MB) on request.
2. Run the model on `CPUExecutionProvider` and on `MIGraphXExecutionProvider`, twice each, and compare
   the partition's output tensor: the GPU tensor differs from the CPU by far more than fp32 noise and
   between the two GPU runs.
3. `python -c 'import migraphx; p = migraphx.parse_onnx(MODEL); p.compile(migraphx.get_target("gpu")); print([(s.lens(), s.strides(), s.standard()) for s in p.get_output_shapes()])'`
   shows the output as a non-standard shape.

**Urgency**

Every result of this model on the MIGraphX EP is wrong; the CPU EP and plain MIGraphX are right.

**Platform** Linux (Ubuntu 26.04, native, not WSL)
**OS Version** Ubuntu 26.04
**ONNX Runtime Installation** Built from Source
**ONNX Runtime Version or Commit ID** v1.31.0 (`--use_migraphx`); the binding is unchanged in v1.31.1
**ONNX Runtime API** Python and C/C++
**Architecture** X64
**Execution Provider** MIGraphX
**Execution Provider Library Version** MIGraphX 2.18.0, ROCm 10.1 (TheRock), AMD Radeon RX 9070 XT (gfx1201)

**Proposed fixes** (we carry both as source patches in our image build,
https://github.com/Kataglyphis/ANTfrastructure/tree/develop/linux/scripts/patches/onnxruntime):

1. `004-migraphx-refuse-nonstandard-output.patch`: refuse a non-standard output shape in the compute
   function instead of binding it (fail loudly). The real fix is to run such an output through a
   contiguous scratch buffer and copy it into ORT's tensor, or to ask MIGraphX for a standard layout
   on its program outputs.
2. `003-migraphx-gridsample.patch`: add `GridSample` to the EP's supported-op list (MIGraphX parses
   and runs it: bilinear, zeros padding, align_corners). With it this model compiles as one partition
   and the view never reaches ORT.

With both applied, four packaged applications pass a CPU/GPU detection-parity check on the RX 9070 XT
(IoU >= 0.9, score difference <= 0.05 over two runs).

## Submit recipe

```bash
cd ~/ANTfrastructure
awk '/^## Body$/{p=1; next} /^## Submit recipe$/{p=0} p' linux/upstream/onnxruntime-migraphx-strided-output/ISSUE.md > /tmp/issue-body.md
gh issue create -R microsoft/onnxruntime --body-file /tmp/issue-body.md \
  --title "MIGraphX EP: a partition output that MIGraphX returns as a strided view is bound to ORT's dense buffer; wrong, drifting results"
```
