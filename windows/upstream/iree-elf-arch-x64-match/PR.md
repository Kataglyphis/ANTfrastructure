# [hal/local/elf] Only build the x86_64 MASM trampoline for x64

| | |
|---|---|
| Target | `iree-org/iree` `main` — GitHub PR |
| Base | `9d485fc23e8d`, 2026-09-02 |
| Patch | [`0001-hal-local-elf-Only-build-the-x86_64-MASM-trampoline-.patch`](0001-hal-local-elf-Only-build-the-x86_64-MASM-trampoline-.patch) |
| Gates | Google CLA · **DCO** — the patch already carries `Signed-off-by`, keep it across any rebase |

The commit message is the description. One thing worth saying in the PR:

> There is a second problem three lines below — the custom command invokes a
> literal `ml64`, which is not overridable and is missing from a clang-only
> toolchain. Left out of this PR: it needs a decision on which variable should
> name the assembler (`CMAKE_ASM_MASM_COMPILER`?). Happy to follow up.

## Checked

- Applies clean at `9d485fc23e8d`.
- IREE v3.11.0 for `windows/arm64` with clang-cl: the archive step fails on the
  machine-type conflict before, succeeds after.
- x64 re-checked on the same lane, unchanged (`MSVC_C_ARCHITECTURE_ID` is `x64`,
  which both the old and new condition accept).
- No open PR for it (`gh search prs`, `MSVC_C_ARCHITECTURE_ID`, 2026-09-02).

## Submit

```sh
gh repo fork iree-org/iree --clone
cd iree && git checkout -b elf-arch-x64-exact-match
git am /path/to/0001-*.patch
git log -1 --pretty=%B | grep Signed-off-by   # DCO
```
