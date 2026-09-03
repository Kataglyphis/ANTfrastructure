# tunable.h: undefine the Windows ERROR and VERBOSE macros

| | |
|---|---|
| Target | `microsoft/onnxruntime` `main` — GitHub PR |
| Base | `cc3da295e336`, 2026-09-02 |
| Patch | [`0001-tunable.h-undefine-the-Windows-ERROR-and-VERBOSE-mac.patch`](0001-tunable.h-undefine-the-Windows-ERROR-and-VERBOSE-mac.patch) |
| Gates | Microsoft CLA · `lintrunner` — **this file is clang-format enforced** |

The commit message is the description. Worth adding in the PR, since this is a
"where should it be fixed" question as much as a fix:

> Three other places this could live, if you prefer one: make `LOGS_DEFAULT`
> robust so a macro-expanded severity cannot paste (general, but it touches the
> logging layer everyone uses); fix the include hygiene that lets `wingdi.h` in
> despite `NOGDI` (right in principle, but a moving target across CUDA and
> Windows SDK versions); or a bare `#undef` without the push/pop, which is
> smaller but would silently drop `ERROR` for everything included after this
> header.

## Checked

- Applies clean at `cc3da295e336`.
- First seen on ORT v1.28.0 + CUDA 13.3 at the `LOGS_DEFAULT(ERROR)` line
  reached from `triton_kernel.cu`; the header compiles with the change and
  fails without it.
- `push_macro`/`pop_macro` work on MSVC, clang and GCC; the block compiles out
  entirely off Windows.
- Not a duplicate of [#29741](https://github.com/microsoft/onnxruntime/pull/29741) —
  that PR does not touch `core/framework/tunable.h`.

## Before pushing

```sh
lintrunner --paths-cmd 'git diff --name-only HEAD~1'
```

## Submit

```sh
gh repo fork microsoft/onnxruntime --clone
cd onnxruntime && git checkout -b tunable-error-macro-collision
git am /path/to/0001-*.patch
```
