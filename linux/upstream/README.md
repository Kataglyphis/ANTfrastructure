# Prepared upstream submissions — Linux lane

Each directory holds one submission: the text to post (`ISSUE.md` for a bug report, `PR.md` for a
patch), what was and was not verified, and where the evidence lives. The source patches themselves
stay under `linux/scripts/patches/`, applied by the image build. The Windows lane's index is
[`windows/upstream/README.md`](../../windows/upstream/README.md).

| Directory | Upstream | Kind | Status |
|---|---|---|---|
| [`onnxruntime-migraphx-strided-output`](onnxruntime-migraphx-strided-output/PR.md) | microsoft/onnxruntime | PR (patch + test) and the issue text (`ISSUE.md`) | prepared 2026-11-07, not posted; the owner files it (BACKLOG CON225). Evidence in `~/gpu/work` on the build host, the mechanism proved by `proof.cc` |
| [`onnxruntime-migraphx-gridsample`](onnxruntime-migraphx-gridsample/PR.md) | microsoft/onnxruntime | PR (one line) | prepared 2026-11-07, not posted; companion of the strided-output fix |
