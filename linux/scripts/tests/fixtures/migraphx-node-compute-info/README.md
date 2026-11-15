# MIGraphX ownership fixtures

The source slices are from `onnxruntime/onnxruntime-ep-amdgpu` commit
`58afd43bc4c2ddc7582712e1d75cbfd4c3bb03fc`, files `src/migraphx/mgx_ep.h`,
`src/migraphx/mgx_ep.cc`, `src/migraphx/mgx_factory.h` and `src/migraphx/mgx_factory.cc`,
under their original MIT SPDX headers.

The shared fixture applies both real patches before extracting and compiling declarations.
The node case checks C ABI callback adjustment, both node types and null cleanup, and requires
the original type mismatch to fail ASan. The factory case keeps source member order, tests
retry, reuse and concurrent creation, and requires the original registry leak to fail LSan.
These minimal C ABI/SDK fixtures are not real SDK, GPU or packaged inference proofs. Keep
those checks separate and preserve the recorded source context when updating the pin.
