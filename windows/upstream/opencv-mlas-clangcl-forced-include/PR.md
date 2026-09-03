# 3rdparty/mlas: use /FI instead of -include under clang-cl

| | |
|---|---|
| Target | `opencv/opencv` `5.x` — GitHub PR |
| Base | `ed61538c9077`, 2026-09-01 |
| Patch | [`0001-3rdparty-mlas-use-FI-instead-of-include-under-clang-.patch`](0001-3rdparty-mlas-use-FI-instead-of-include-under-clang-.patch) |
| Gates | no CLA/DCO · **title needs 🤖🤖🤖** if filed as an automated agent (their PR template) |

The commit message is the description. Worth adding in the PR:

> MLAS has a bigger problem on Windows beyond this flag: the vendored kernels
> are GAS/ELF-only and there is no MASM/COFF port, so with clang-cl — which
> *is* a working GAS assembler, unlike MSVC — the `.S` files get past
> `check_language(ASM)` and then fail in the integrated assembler. Separate
> question (skip MLAS on Windows as the Android path does, or port the
> kernels), not this PR.

## Checked

- Applies clean at `ed61538c9077`.
- `opencv_dnn_mlas` fails on its first TU with clang-cl before the change and
  compiles after (OpenCV 5.0.0).
- `5.x` is the right branch: `3rdparty/mlas/` is 404 on `4.x`, so there is no
  maintenance branch below it.
- `CMAKE_CXX_COMPILER_FRONTEND_VARIANT` has been set for Clang since CMake 3.14.
- No open PR for it (`gh search prs`, `clang-cl mlas`, 2026-09-02).

## Submit

```sh
gh repo fork opencv/opencv --clone
cd opencv && git checkout -b mlas-clang-cl-forced-include origin/5.x
git am /path/to/0001-*.patch
```
