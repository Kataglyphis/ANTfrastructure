<!-- Index of the prepared Windows-lane upstream submissions. Grades and the
     full inventory (including what must NOT be filed) live in
     docs/upstream-windows-patches.md. -->

# Prepared upstream submissions — Windows lane

**Nothing below has been posted. Do not post anything without the owner saying so.**

Each directory holds one submission: a `git format-patch` generated against a
named upstream commit, and a `PR.md` with the description to paste, what was and
was not verified, and the submit recipe. The graded inventory of *every*
Windows-lane third-party change — including what must stay local and what
upstream has already fixed — is
[`docs/upstream-windows-patches.md`](../../docs/upstream-windows-patches.md).

`hcsshim-teardown-timeout/` is older and different: that PR **is** filed
(microsoft/hcsshim#2855). Its own README carries the status.

## Ready to send (12)

| Directory | Upstream | Branch | Where it goes | Grade |
|---|---|---|---|---|
| [`onnxruntime-cuda-softmax-alt-token`](onnxruntime-cuda-softmax-alt-token/PR.md) | microsoft/onnxruntime | `main` | GitHub PR | A |
| [`onnxruntime-tunable-error-macro`](onnxruntime-tunable-error-macro/PR.md) | microsoft/onnxruntime | `main` | GitHub PR | B |
| [`opencv-mlas-clangcl-forced-include`](opencv-mlas-clangcl-forced-include/PR.md) | opencv/opencv | `5.x` | GitHub PR | A |
| [`opencv-mlas-neon-clang`](opencv-mlas-neon-clang/PR.md) | opencv/opencv | `5.x` | GitHub PR | A |
| [`opencv-findonnx-imported-target`](opencv-findonnx-imported-target/PR.md) | opencv/opencv | **`4.x`** | GitHub PR | A |
| [`opencv-neon-probes-clang-cl`](opencv-neon-probes-clang-cl/PR.md) | opencv/opencv | **`4.x`** | GitHub PR | B |
| [`opencv-contrib-cudev-ulong-windows`](opencv-contrib-cudev-ulong-windows/PR.md) | opencv/opencv_contrib | `5.x` | GitHub PR | A |
| [`gstreamer-base-sse-cpu-family`](gstreamer-base-sse-cpu-family/PR.md) | gstreamer/gstreamer | `main` | **GitLab MR** | A |
| [`gstreamer-vulkan-host-libdir`](gstreamer-vulkan-host-libdir/PR.md) | gstreamer/gstreamer | `main` | **GitLab MR** | A |
| [`gstreamer-mediafoundation-msvc-gate`](gstreamer-mediafoundation-msvc-gate/PR.md) | gstreamer/gstreamer | `main` | **GitLab MR** | A |
| [`iree-elf-arch-x64-match`](iree-elf-arch-x64-match/PR.md) | iree-org/iree | `main` | GitHub PR | A |
| [`iree-ukernel-i8mm-linkage`](iree-ukernel-i8mm-linkage/PR.md) | iree-org/iree | `main` | GitHub PR | A |

Grades match `docs/upstreamable-patches.md`: **A** = file as it stands, **B** =
genuine defect but a maintainer has a design call to make first (each `PR.md`
says what the call is).

## Superseded — do NOT file (2)

| Directory | Why |
|---|---|
| [`onnxruntime-dml-clangcl-tokens`](onnxruntime-dml-clangcl-tokens/PR.md) | [onnxruntime#29741](https://github.com/microsoft/onnxruntime/pull/29741) already carries byte-identical hunks |
| [`onnxruntime-dml-abstractoperatordesc`](onnxruntime-dml-abstractoperatordesc/PR.md) | same PR, same out-of-line shape, same stated reason |

Both are kept as the record of what `onnxruntime/003-dml-clangcl-compat.patch`
carries and when it can be retired. The useful action there is a comment on
#29741 confirming an independent reproduction — not a competing PR.

## Five things that are easy to get wrong

1. **GStreamer does not take GitHub pull requests.** `github.com/gstreamer/gstreamer`
   is a mirror; merge requests go to
   <https://gitlab.freedesktop.org/gstreamer/gstreamer>.
2. **OpenCV wants the maintenance branch.** A defect present on `4.x` is fixed on
   `4.x` and merged forward; `5.x` is only correct when the code does not exist
   on `4.x` (which is the case for bundled MLAS and for the 5.x cudev). The PR
   template has a "The PR is proposed to the proper branch" checkbox, and the
   wiki FAQ is mostly about people getting it wrong.
3. **OpenCV asks automated agents to mark the PR title with 🤖🤖🤖.** Its PR
   template says so explicitly; `opencv_contrib`'s does not. These commits carry
   `Assisted-by: Claude (Anthropic)`, so the marker is the consistent reading —
   owner's call.
4. **IREE enforces DCO.** Both IREE patches carry `Signed-off-by`. Keep it across
   any rebase (`git commit --amend -s`).
5. **onnxruntime blocks commits on `lintrunner`.** The DML tree is exempt
   (`onnxruntime/core/providers/dml/.clang-format` sets `DisableFormat: true`),
   but `softmax.cc` and `tunable.h` are not — run
   `lintrunner --paths-cmd 'git diff --name-only HEAD~1'` before pushing those.

Microsoft (onnxruntime, hcsshim) and Google (IREE) each require a CLA, accepted
once per organisation via the bot that comments on the PR.

## Before filing any of these

Generated against the upstream commits named in each `PR.md`, on 2026-09-02:
`onnxruntime@cc3da295e336`, `opencv 5.x@ed61538c9077`,
`opencv 4.x@2ce3cbc2606e`, `opencv_contrib 5.x@17af220dd982`,
`gstreamer@23616d5ccb36`, `iree@9d485fc23e8d`.

Upstream moves. Re-run all three steps before sending — skipping step 2 is what
put two duplicates in this directory, and skipping step 1 is what produced
opencv#29788:

```sh
# 1. is the defect still there on the branch you are targeting?
curl -fsSL https://raw.githubusercontent.com/<org>/<repo>/<branch>/<path>

# 2. has someone already sent it?  (GitHub)
gh search prs --repo <org>/<repo> --state open '<symbol or file>'
#    ... and for GStreamer, GitLab - gh cannot see it:
curl -fsSL "https://gitlab.freedesktop.org/api/v4/projects/gstreamer%2Fgstreamer/merge_requests?state=opened&search=<term>"

# 3. does the patch still apply?
git apply --check -p1 <the .patch>
```

All 12 sendable submissions passed all three on 2026-09-02.
