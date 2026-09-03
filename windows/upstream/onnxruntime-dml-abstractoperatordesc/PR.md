# SUPERSEDED — do not file

[onnxruntime#29741](https://github.com/microsoft/onnxruntime/pull/29741) already
does this, in the same shape: the same seven special members, the same four
tensor accessors and the same `GetTensors()` template declared in the class and
defined out of line, for the same stated reason. Verified 2026-09-02.

Kept as the record of what `windows/scripts/patches/onnxruntime/003-dml-clangcl-compat.patch`
carries. The patch here applies clean at `cc3da295e336`, but **do not send it**.

The defect, for reference: `AbstractOperatorDesc` holds a
`std::vector<OperatorField>` while `OperatorField` is incomplete, and defines
its special members inline. `precomp.h` includes `AbstractOperatorDesc.h` before
`GeneratedSchemaTypes.h`, so `std::optional<AbstractOperatorDesc>` instantiates
the vector's destructor and move operations against the incomplete type. MSVC
defers that to end of TU; clang-cl does not.

One difference: ours puts the definitions at the end of `GeneratedSchemaTypes.h`,
#29741 keeps them in `AbstractOperatorDesc.h`. Both work because `precomp.h`
fixes the order; theirs keeps the class in one file, which is tidier.

**Instead:** comment on #29741 confirming an independent reproduction, if it
needs the push.
