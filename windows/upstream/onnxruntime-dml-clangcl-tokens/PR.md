# SUPERSEDED — do not file

[onnxruntime#29741](https://github.com/microsoft/onnxruntime/pull/29741)
("Support building ONNX runtime with clang on Windows for Windows ML", open
since 2026-07-16) already carries these hunks, byte-identical to ours — down to
the two spaces realigning the `CASE_PROTO` backslash. Verified 2026-09-02.

Kept as the record of what `windows/scripts/patches/onnxruntime/003-dml-clangcl-compat.patch`
carries and when it can be dropped. The patch here applies clean at
`cc3da295e336`, but **do not send it**.

The two defects, for reference: `initializer.##Z()` pastes onto nothing (MSVC
drops the `##`, conforming preprocessors reject it), and `Dispatch` declares the
`std::array` bound as `uint32_t` where it is `size_t`.

**Instead:** if #29741 goes stale (last touched 2026-07-23), comment on it
confirming an independent reproduction — clang-cl 23.1.0, `--use_dml`, ORT
v1.27–v1.29. When it merges, drop the matching hunks from our local patch.
