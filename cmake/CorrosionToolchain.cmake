# Copyright (c) 2026 Kataglyphis
# SPDX-License-Identifier: MIT
include_guard(GLOBAL)

function(kataglyphis_configure_corrosion_target rust_target)
  cmake_parse_arguments(
    PARSE_ARGV
    1
    ARG
    ""
    "ADDRESS_SANITIZER"
    "")
  if(ARG_UNPARSED_ARGUMENTS OR NOT TARGET ${rust_target})
    message(
      FATAL_ERROR "kataglyphis_configure_corrosion_target needs a Rust target and optional ADDRESS_SANITIZER value")
  endif()
  set(rust_cc "${CMAKE_C_COMPILER}")
  set(rust_cxx "${CMAKE_CXX_COMPILER}")
  if(NOT rust_cc)
    set(rust_cc cc)
  endif()
  if(NOT rust_cxx)
    set(rust_cxx c++)
  endif()
  if(WIN32)
    target_link_libraries(
      ${rust_target}
      INTERFACE kernel32
                ntdll
                userenv
                ws2_32
                dbghelp)
    set(debug_cflags "/MDd /D_DEBUG")
    set(debug_cxxflags "/MDd /D_DEBUG /D_ITERATOR_DEBUG_LEVEL=2")
    # clang-cl ASan uses the release CRT in both languages.
    if(MSVC
       AND CMAKE_CXX_COMPILER_ID STREQUAL "Clang"
       AND ARG_ADDRESS_SANITIZER)
      set(debug_cflags /MD)
      set(debug_cxxflags "/MD /D_ITERATOR_DEBUG_LEVEL=0")
    endif()
    set(cflags "$<$<CONFIG:Debug>:${debug_cflags}>$<$<NOT:$<CONFIG:Debug>>:/MD /DNDEBUG>")
    set(cxxflags
        "/EHsc $<$<CONFIG:Debug>:${debug_cxxflags}>$<$<NOT:$<CONFIG:Debug>>:/MD /DNDEBUG /D_ITERATOR_DEBUG_LEVEL=0>")
    corrosion_set_env_vars(
      ${rust_target}
      "CC=${rust_cc}"
      "CXX=${rust_cxx}"
      "CFLAGS=${cflags}"
      "CXXFLAGS=${cxxflags}")
  else()
    # The image's compiler config already selects the matching native GCC.
    string(STRIP "$ENV{CXXFLAGS} -fexceptions" cxxflags)
    corrosion_set_env_vars(
      ${rust_target}
      "CC=${rust_cc}"
      "CXX=${rust_cxx}"
      "CXXFLAGS=${cxxflags}")
  endif()
endfunction()
