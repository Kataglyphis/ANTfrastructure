# Injected via -DCMAKE_PROJECT_INCLUDE= for every project() in the IREE
# super-build (in-tree LLVM/MLIR included).
#
# Why: MLIR's nanobind python-binding targets use try/catch but end up with NO
# /EH flag under clang-cl -- upstream only adds /EHsc for compiler-id MSVC, and
# cl.exe tolerates flag-less try (warning C4530) where clang-cl hard-errors
# ("cannot use 'try' with exceptions disabled"). A global CMAKE_CXX_FLAGS gets
# stripped by LLVM's HandleLLVMOptions, and a CCC_OVERRIDE_OPTIONS driver
# injection leaks into the freshly-built plain clang.exe that cross-compiles
# ukernel bitcode (spike rounds 3-7).
#
# Directory-scope COMPILE_OPTIONS survive the CMAKE_CXX_FLAGS stripping, come
# BEFORE target-level flags (so targets that explicitly pass /EHs-c- keep
# exceptions off -- last flag wins), and never affect custom commands (the
# ukernel bitcode cross-clang stays untouched).
if(MSVC)
  add_compile_options($<$<COMPILE_LANGUAGE:CXX>:/EHsc>)
endif()
