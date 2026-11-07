# Prepared upstream submissions — Linux lane

Each directory holds one submission: the text to post (`ISSUE.md` for a bug report, `PR.md` for a
patch), what was and was not verified, and where the evidence lives. The source patches themselves
stay under `linux/scripts/patches/`, applied by the image build. The Windows lane's index is
[`windows/upstream/README.md`](../../windows/upstream/README.md).

| Directory | Upstream | Kind | Status |
|---|---|---|---|
| [`onnxruntime-migraphx-strided-output`](onnxruntime-migraphx-strided-output/PR.md) | microsoft/onnxruntime | PR (patch + test) and the issue text (`ISSUE.md`) | **not to be filed** (2026-11-07): the built-in EP is unmaintained (onnxruntime#32571) and MIGraphX fixed the root cause (AMDMIGraphX#5345); kept as the documented alternative for MIGraphX ≤ 2.18, mechanism proved by `proof.cc`, evidence in `~/gpu/work` on the build host. Follow-up: BACKLOG CON231 |
| [`onnxruntime-migraphx-gridsample`](onnxruntime-migraphx-gridsample/PR.md) | microsoft/onnxruntime | PR (one line) | **not to be filed**: the plugin EP lists every op MIGraphX parses, GridSample included |
