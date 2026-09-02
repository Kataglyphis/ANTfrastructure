# cmake/checks: accept clang-cl in the NEON dotprod and fp16 probes

| | |
|---|---|
| Target | `opencv/opencv` **`4.x`** — GitHub PR |
| Base | `2ce3cbc2606e`, 2026-09-02 |
| Patch | [`0001-cmake-checks-accept-clang-cl-in-the-NEON-dotprod-and.patch`](0001-cmake-checks-accept-clang-cl-in-the-NEON-dotprod-and.patch) |
| Gates | no CLA/DCO · **title needs 🤖🤖🤖** if filed as an automated agent |
| Related | [#25052](https://github.com/opencv/opencv/issues/25052) |

The commit message is the description. This one re-opens a case that was
switched off deliberately, so it needs a maintainer to agree with the reasoning:
#25052 is about MSVC's `arm_neon.h`, and this only enables clang.

## Checked

- Applies clean at `4.x` `2ce3cbc2606e`.
- **Branch:** both files carry the identical guard on `4.x` and `5.x`, so this
  goes to `4.x` and merges forward.
- Both probes compile and link with clang-cl targeting
  `aarch64-pc-windows-msvc` (LLVM 23.1.0), and NEON_DOTPROD/NEON_FP16 then show
  up in the dispatch list. Measured on 5.0.0; the probe sources are identical.
- **Not** verified with MSVC, which this leaves disabled.
- A plain aarch64 clang build is unaffected — `_M_ARM64` is not defined there.
- `cpu_neon_bf16.cpp` already enables its `_MSC_VER && _M_ARM64` branch; not
  touched.
- No open PR for it (`gh search prs`, `cpu_neon_dotprod`, 2026-09-02).

## Submit

```sh
gh repo fork opencv/opencv --clone
cd opencv && git checkout -b neon-probes-clang-cl origin/4.x
git am /path/to/0001-*.patch
```
