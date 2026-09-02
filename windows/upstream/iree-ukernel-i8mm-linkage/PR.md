# [ukernel] Drop inline from the s8s4s32 1x8x16 i8mm tile

| | |
|---|---|
| Target | `iree-org/iree` `main` — GitHub PR |
| Base | `9d485fc23e8d`, 2026-09-02 |
| Patch | [`0001-ukernel-Drop-inline-from-the-s8s4s32-1x8x16-i8mm-til.patch`](0001-ukernel-Drop-inline-from-the-s8s4s32-1x8x16-i8mm-til.patch) |
| Gates | Google CLA · **DCO** — already signed off |

The commit message is the description. Nothing to add.

## Checked

- Applies clean at `9d485fc23e8d`.
- IREE v3.11.0 for `windows/arm64` with clang-cl: the runtime compiles and every
  tool fails to link on exactly this symbol; with the change they link.
- `-fgnu89-inline` on that TU was tried first and did **not** produce the symbol,
  which is what pointed at the declaration mismatch rather than a dialect flag.
- Not re-measured on a GNU-driver arm64 build; the prototype already required an
  external definition there, so this is a no-op for it.
- No open PR for it (`gh search prs`, `mmt4d_arm_64_i8mm`, 2026-09-02).

## Submit

```sh
gh repo fork iree-org/iree --clone
cd iree && git checkout -b ukernel-i8mm-s8s4s32-linkage
git am /path/to/0001-*.patch
```
