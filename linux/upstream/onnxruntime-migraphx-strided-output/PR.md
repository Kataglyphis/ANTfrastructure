# PR: [MIGraphX EP] Make a strided partition output dense before ORT reads it

Upstream: microsoft/onnxruntime, branch `main`. Patch: `0001-MIGraphX-EP-Make-a-strided-partition-output-dense-be.patch`,
generated against the file contents of `main` at `1f84d530` (2026-11-07); it applies to v1.31.0 and v1.31.1
unchanged (the compute function is identical there).

**Status (2026-11-07): not to be filed.** AMD declared the built-in MIGraphX EP unmaintained
(microsoft/onnxruntime#32571, 2026-09-24: "Changes to this code are not maintained anymore. Please move to the
plugin EP repo"). The successor, `onnxruntime/onnxruntime-ep-amdgpu`, compiles with MIGraphX's
`standardize_outputs` option (ROCm/AMDMIGraphX#5345, merged 2026-10-01) and its `compile_program` refuses a
non-standard output loudly where MIGraphX ignores the option. The patch stays here as the documented
alternative for the built-in EP on a MIGraphX that predates #5345 (ROCm 10.1's 2.18.0 does); BACKLOG CON231
moves our image to the plugin EP.

## Description

MIGraphX can return a partition output as a strided view, for example when the partition ends in
`Slice` + `Reshape`. `MIGraphXExecutionProvider::Compile`'s compute function bound that `#output_N`
parameter straight onto ORT's dense output tensor with MIGraphX's shape. The view's span is larger than
the dense tensor (`shape.bytes()` vs. element count), so the write overran the allocation and ORT read
the strided bytes as dense: wrong results that changed between runs.

An output whose parameter shape is not `standard()` is now staged in a scratch buffer from the kernel
context's allocator and copied into ORT's tensor by a one-op `contiguous` program compiled for the same
target. The helper program is cached per output parameter in `MIGraphXFuncState` and dropped when the
program is recompiled. Standard outputs are bound as before, so nothing changes for them.

New test `MIGraphXExecutionProviderTest.StridedPartitionOutputIsDense`: `Add -> Slice -> Reshape` on the
MIGraphX EP, run twice, compared with the expected values.

## Motivation and Context

Found with a DEIM/D-FINE-N detector on an RX 9070 XT (gfx1201, ROCm 10.1, MIGraphX 2.18.0, ORT v1.31.0):
the EP leaves its `GridSample` ops on the CPU, the graph splits into five partitions, and the one that is
only `Slice` + `Reshape` returns `[8, 16, 40, 40]` with strides `[32000, 2000, 40, 1]`. The CPU provider
and MIGraphX alone (`migraphx.parse_onnx` + `compile` + `run`) agree to 0.0025; the EP returned three
drifting detections where the CPU finds five. Emulating the strided write on the CPU reproduces the EP's
tensor to 6e-6 on the elements the write defines. `enable_mem_pattern=False` made it deterministic but
still wrong; `HIP_LAUNCH_BLOCKING` and `AMD_SERIALIZE_*` changed nothing.

## Verified

- The mechanism, standalone against MIGraphX 2.18.0 on gfx1201: a `contiguous` program over the view
  above compiles in ~200 ms, its output parameter (`main:#output_0`) is standard, one run takes 0.2 ms,
  and all 204800 elements match (`proof.cc` beside this file; build it against MIGraphX's C API headers
  and link `libmigraphx_c`). The EP finds that parameter by the `#output_` substring, as it does for the
  model's own outputs.
- The same two fixes carried as source patches (refuse-instead-of-bind, plus GridSample) in our image
  build: four packaged applications pass a CPU/GPU detection-parity check on the RX 9070 XT.
- `clang-format` (ORT's `.clang-format`, 21.1.0) reports the three files clean.

## Not verified

- Not built or run inside an ORT checkout: this host has no ORT build tree. The new test needs a
  MIGraphX build (`--use_migraphx`) and an AMD GPU; review the three files once on such a host.
- The pre-existing fallback for outputs that are not parameters (`hipMemcpyWithStream` of
  `res_shape.bytes()`) has the same assumption for a strided result and is left as is.

## Related

- microsoft/onnxruntime#32571 (closed, not merged): the maintainer's statement above; it touched the same
  `#output_` name parsing (`main:#output_:00010` from index 10 on).
- microsoft/onnxruntime#26092 (merged 2025-12-09): the output-binding loop this patch changes.
- microsoft/onnxruntime#27551 (merged 2026-03-09): the EP's allocation fix.
- microsoft/onnxruntime#31986 (closed): wrong `Resize` results on the EP, a MIGraphX layout bug
  (ROCm/AMDMIGraphX#4713), not this class.
- ROCm/AMDMIGraphX#5345 (merged 2026-10-01): `auto_contiguous.standardize_outputs`, the root-cause fix;
  absent from the `rocm-10.1` tag.
- onnxruntime/onnxruntime-ep-amdgpu `src/migraphx/mgx_program_ops.cc` at `58afd43b`: `compile_program` sets
  the option and throws `MIGraphX compiled a non-standard output for ONNX Runtime` otherwise.

## Submit recipe

```bash
git clone --depth 50 https://github.com/microsoft/onnxruntime.git && cd onnxruntime
git checkout -b migraphx-strided-output origin/main
git am ~/ANTfrastructure/linux/upstream/onnxruntime-migraphx-strided-output/0001-*.patch
# build with --use_migraphx on an AMD host and run:
#   onnxruntime_test_all --gtest_filter='MIGraphXExecutionProviderTest.StridedPartitionOutputIsDense'
git push -u <fork> migraphx-strided-output
gh pr create -R microsoft/onnxruntime --base main --title "[MIGraphX EP] Make a strided partition output dense before ORT reads it" --body-file <(sed -n '/^## Description/,/^## Submit recipe/p' PR.md | sed '$d')
```
