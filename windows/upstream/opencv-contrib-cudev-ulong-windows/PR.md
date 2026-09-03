# cudev: define ulong on Windows

| | |
|---|---|
| Target | `opencv/opencv_contrib` `5.x` — GitHub PR |
| Base | `17af220dd982`, 2026-08-14 |
| Patch | [`0001-cudev-define-ulong-on-Windows.patch`](0001-cudev-define-ulong-on-Windows.patch) |
| Gates | no CLA/DCO. `opencv_contrib`'s PR template has **no** automated-agent marker (opencv/opencv's does) |

The commit message is the description. Worth adding in the PR:

> Related gap, not fixed here: cudev instantiates `MakeVec`/`VecTraits` for
> `long` and `ulong` and stops. That covers 64-bit elements on LP64, but on
> Windows LLP64 `long` is 32-bit, so 64-bit element types have no vector traits
> at all. Adding them is a behaviour change rather than a build fix, so it is
> left out. Happy to follow up.

## Checked

- Applies clean at `17af220dd982`.
- `ulong` appears in exactly one file across all 76 headers under
  `modules/cudev/include` (`vec_traits.hpp`, twice), so those two
  instantiations are the complete set of uses.
- Hit building `opencv_cudev` with clang-cl on Windows x64.
- `5.x` is the right branch: `4.x`'s cudev has no
  `CV_CUDEV_MAKE_VEC_INST(ulong)` at all, so the defect arrived with 5.x.
- No open PR for it (`gh search prs`, `cudev ulong`, 2026-09-02).

## Submit

```sh
gh repo fork opencv/opencv_contrib --clone
cd opencv_contrib && git checkout -b cudev-ulong-windows origin/5.x
git am /path/to/0001-*.patch
```
