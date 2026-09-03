# Use || instead of the alternative token "or" in softmax.cc

| | |
|---|---|
| Target | `microsoft/onnxruntime` `main` — GitHub PR |
| Base | `cc3da295e336`, 2026-09-02 |
| Patch | [`0001-Use-instead-of-the-alternative-token-or-in-softmax.c.patch`](0001-Use-instead-of-the-alternative-token-or-in-softmax.c.patch) |
| Gates | Microsoft CLA · `lintrunner` — **this file is clang-format enforced** |

The commit message is the description. Nothing to add.

## Checked

- Applies clean at `cc3da295e336`.
- Hit building the CUDA EP with clang-cl (LLVM 23.1.0, CUDA 13.3).
- Same operator, same precedence, so GCC/clang builds are unaffected.
- Not a duplicate of [#29741](https://github.com/microsoft/onnxruntime/pull/29741)
  ("Support building ONNX runtime with clang on Windows") — that PR does not
  touch `softmax.cc`.

## Before pushing

```sh
lintrunner --paths-cmd 'git diff --name-only HEAD~1'
```

`ColumnLimit` is 0 and one token changes, so no reformatting is expected — but
ORT blocks the commit on this hook.

## Submit

```sh
gh repo fork microsoft/onnxruntime --clone
cd onnxruntime && git checkout -b softmax-alt-token
git am /path/to/0001-*.patch
```
