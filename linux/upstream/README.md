# Prepared upstream submissions — Linux lane

Each directory holds one submission: the text to post (`ISSUE.md` for a bug report, `PR.md` for a
patch), what was and was not verified, and where the evidence lives. The source patches themselves
stay under `linux/scripts/patches/`, applied by the image build. The Windows lane's index is
[`windows/upstream/README.md`](../../windows/upstream/README.md).

| Directory | Upstream | Kind | Status |
|---|---|---|---|
| [`onnxruntime-migraphx-strided-output`](onnxruntime-migraphx-strided-output/ISSUE.md) | microsoft/onnxruntime | issue | prepared 2026-11-07, not posted: the agent sandbox refuses to create a public issue, the owner posts it with the command in the file (BACKLOG CON225); evidence in `~/gpu/work` on the build host |
