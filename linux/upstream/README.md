# Prepared upstream submissions — Linux lane

Each directory holds one submission: the text to post (`ISSUE.md` for a bug report, `PR.md` for a
patch), what was and was not verified, and where the evidence lives. The source patches themselves
stay under `linux/scripts/patches/`, applied by the image build. The Windows lane's index is
[`windows/upstream/README.md`](../../windows/upstream/README.md).

| Directory | Upstream | Kind | Status |
|---|---|---|---|
| (none) | | | |

## Not filed, and why

- **MIGraphX EP: strided partition output bound to ORT's dense buffer** (2026-11-07). The built-in MIGraphX EP in
  microsoft/onnxruntime is unmaintained (AMD on onnxruntime#32571: "move to the plugin EP repo"); MIGraphX fixed the
  root cause in ROCm/AMDMIGraphX#5345 (`standardize_outputs`, not in `rocm-10.1`), and the plugin EP
  `onnxruntime/onnxruntime-ep-amdgpu` sets that option and refuses a non-standard output otherwise. The prepared
  patch (a cached one-op `contiguous` program per strided output, with a unit test) and its standalone proof were
  removed the same day at the owner's request; they live in git history at 2a819d85. Our image kept
  `004-migraphx-refuse-nonstandard-output.patch` until 2026-11-08, when the in-tree EP left with CON231 step 3.
- **MIGraphX EP: `GridSample` in the op list**: the plugin EP lists every op `migraphx::get_onnx_operators()`
  returns, so nothing to file; `003-migraphx-gridsample.patch` left with the built-in EP on 2026-11-08 (CON231).
