# MLIR's nanobind targets get no /EH under clang-cl; directory scope survives LLVM's flag stripping and skips custom commands.
if(MSVC)
  add_compile_options($<$<COMPILE_LANGUAGE:CXX>:/EHsc>)

  # STL4037 (std::complex<APInt> in MLIR) comes from the STL headers, so only this define silences it, not a -Wno- flag.
  add_compile_definitions($<$<COMPILE_LANGUAGE:CXX>:_SILENCE_NONFLOATING_COMPLEX_DEPRECATION_WARNING>)
endif()
