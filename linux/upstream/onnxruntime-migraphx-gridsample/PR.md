# PR: [MIGraphX EP] Add GridSample to the supported ops

Upstream: microsoft/onnxruntime, branch `main`. Patch: `0001-MIGraphX-EP-Add-GridSample-to-the-supported-ops.patch`,
one line in the EP's supported-op list, generated against `main` at `1f84d530` (2026-11-07).

## Description

MIGraphX parses and runs ONNX `GridSample` (bilinear, zeros padding, `align_corners`; checked with
2.18.0), but the provider's op list omits it, so every `GridSample` stays on the CPU and splits the
graph around it. With the op on the list a DEIM/D-FINE detector with six of them compiles as one
partition instead of five.

## Motivation and Context

Fewer partitions mean fewer CPU round trips and no partition that ends in a bare view; it is the
companion of the strided-output fix (`../onnxruntime-migraphx-strided-output/PR.md`), which stays
necessary on its own.

## Verified

- Carried as a source patch in our image build since 2026-11-05: the detector's six `GridSample` ops run
  on MIGraphX, and four packaged applications pass a CPU/GPU detection-parity check on an RX 9070 XT.

## Not verified

- Other `GridSample` modes (`nearest`, `bicubic`, `border`/`reflection` padding) were not exercised;
  a mode MIGraphX rejects would fail the partition's compile, as any unsupported attribute does today.
- Not built in an ORT checkout on this host.

## Submit recipe

```bash
git clone --depth 50 https://github.com/microsoft/onnxruntime.git && cd onnxruntime
git checkout -b migraphx-gridsample origin/main
git am ~/ANTfrastructure/linux/upstream/onnxruntime-migraphx-gridsample/0001-*.patch
git push -u <fork> migraphx-gridsample
gh pr create -R microsoft/onnxruntime --base main --title "[MIGraphX EP] Add GridSample to the supported ops" --body-file <(sed -n '/^## Description/,/^## Submit recipe/p' PR.md | sed '$d')
```
