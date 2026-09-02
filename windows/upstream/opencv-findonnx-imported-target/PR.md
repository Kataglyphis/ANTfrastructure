# FindONNX: use add_library for the imported target

| | |
|---|---|
| Target | `opencv/opencv` **`4.x`** — GitHub PR |
| Base | `2ce3cbc2606e`, 2026-09-02 |
| Patch | [`0001-FindONNX-use-add_library-for-the-imported-target.patch`](0001-FindONNX-use-add_library-for-the-imported-target.patch) |
| Gates | no CLA/DCO · **title needs 🤖🤖🤖** if filed as an automated agent |

The commit message is the description. Nothing to add.

## Checked

- Applies clean at `4.x` `2ce3cbc2606e`.
- **Branch:** the same call is on `4.x` (line 52) and `5.x` (line 147), and
  `ocv_add_library` is identical on both, so this goes to `4.x` and reaches
  `5.x` through the forward merge. Do not open a second PR.
- Hit configuring with `WITH_ONNX=ON` and CUDA as a first-class language.
- Non-CUDA builds only reach the failing call through
  `_ocv_append_target_includes()`, which is conditional on
  `OCV_TARGET_INCLUDE_DIRS_onnxruntime` — which is why default CI misses it.
- No open PR for it (`gh search prs`, `FindONNX` / `ocv_add_library IMPORTED`,
  2026-09-02).

## Submit

```sh
gh repo fork opencv/opencv --clone
cd opencv && git checkout -b findonnx-imported-target origin/4.x
git am /path/to/0001-*.patch
```
