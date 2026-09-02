# 3rdparty/mlas: skip the MSVC neon_* aliases under clang

| | |
|---|---|
| Target | `opencv/opencv` `5.x` — GitHub PR |
| Base | `ed61538c9077`, 2026-09-01 |
| Patch | [`0001-3rdparty-mlas-skip-the-MSVC-neon_-aliases-under-clan.patch`](0001-3rdparty-mlas-skip-the-MSVC-neon_-aliases-under-clan.patch) |
| Gates | no CLA/DCO · **title needs 🤖🤖🤖** if filed as an automated agent |

The commit message is the description. Nothing to add.

## Checked

- Applies clean at `ed61538c9077`.
- Hit cross-building OpenCV 5.0.0 for Windows ARM64 with clang-cl.
- MSVC on ARM64 is unaffected — `__clang__` is not defined there, so the block
  is entered exactly as before.
- `5.x` is the right branch: `3rdparty/mlas/lib/mlasi.h` is 404 on `4.x`.

## Submit

```sh
gh repo fork opencv/opencv --clone
cd opencv && git checkout -b mlas-neon-clang-guard origin/5.x
git am /path/to/0001-*.patch
```
