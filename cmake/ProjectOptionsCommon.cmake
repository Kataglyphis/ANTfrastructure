# Copyright (c) 2025 Kataglyphis
# SPDX-License-Identifier: MIT

# Option names and dispatch only, values arrive as arguments; SanitizerSupport stays out until the consumers agree on it.

include_guard(GLOBAL)

include(CheckCXXCompilerFlag)

# Bump on any macro change, so a consumer can detect a stale same-named file in its own cmake/, which wins silently.
set(MYPROJECT_PROJECT_OPTIONS_COMMON_VERSION 1)

# Option declarations

# Declares the core options; the four defaults the consumers disagree on are required, so none silently becomes OFF.
#   myproject_define_core_options(ASAN_DEFAULT <ON|OFF> UBSAN_DEFAULT <ON|OFF> TSAN_DEFAULT <ON|OFF> CPPCHECK_DEFAULT <ON|OFF>)
function(myproject_define_core_options)
  cmake_parse_arguments(
    _MPCO
    ""
    "ASAN_DEFAULT;UBSAN_DEFAULT;TSAN_DEFAULT;CPPCHECK_DEFAULT"
    ""
    ${ARGN})

  if(_MPCO_UNPARSED_ARGUMENTS)
    message(FATAL_ERROR "myproject_define_core_options: unexpected argument(s): ${_MPCO_UNPARSED_ARGUMENTS}")
  endif()

  # An empty value would reach option() as a missing default and silently become OFF.
  foreach(
    _mpco_required IN
    ITEMS ASAN_DEFAULT
          UBSAN_DEFAULT
          TSAN_DEFAULT
          CPPCHECK_DEFAULT)
    if(NOT DEFINED _MPCO_${_mpco_required} OR "${_MPCO_${_mpco_required}}" STREQUAL "")
      message(FATAL_ERROR "myproject_define_core_options: ${_mpco_required} is required and must not be empty. "
                          "Pass an explicit ON/OFF - an empty value would silently default the option to OFF.")
    endif()
  endforeach()

  option(myproject_ENABLE_IPO "Enable IPO/LTO" ON)
  option(myproject_ENABLE_STATIC_ANALYZER "Enable Static Analyzer" OFF)
  option(myproject_WARNINGS_AS_ERRORS "Treat Warnings As Errors" OFF)
  option(myproject_ENABLE_SANITIZER_ADDRESS "Enable address sanitizer" ${_MPCO_ASAN_DEFAULT})
  option(myproject_ENABLE_SANITIZER_LEAK "Enable leak sanitizer" OFF)
  option(myproject_ENABLE_SANITIZER_UNDEFINED "Enable undefined sanitizer" ${_MPCO_UBSAN_DEFAULT})
  option(myproject_ENABLE_SANITIZER_THREAD "Enable thread sanitizer" ${_MPCO_TSAN_DEFAULT})
  option(myproject_ENABLE_SANITIZER_MEMORY "Enable memory sanitizer" OFF)
  option(myproject_ENABLE_UNITY_BUILD "Enable unity builds" OFF)
  option(myproject_ENABLE_CLANG_TIDY "Enable clang-tidy" OFF)
  option(myproject_ENABLE_CPPCHECK "Enable cpp-check analysis" ${_MPCO_CPPCHECK_DEFAULT})
  option(myproject_ENABLE_PCH "Enable precompiled headers" OFF)
  option(myproject_ENABLE_CACHE "Enable ccache" ON)
  option(myproject_ENABLE_IWYU "Enable IWYU" ON)
endfunction()

# Hides the core options when built as a subproject; extra option names may be appended.
function(myproject_mark_core_options_advanced)
  if(PROJECT_IS_TOP_LEVEL)
    return()
  endif()

  mark_as_advanced(
    myproject_ENABLE_IPO
    myproject_ENABLE_STATIC_ANALYZER
    myproject_WARNINGS_AS_ERRORS
    myproject_ENABLE_SANITIZER_ADDRESS
    myproject_ENABLE_SANITIZER_LEAK
    myproject_ENABLE_SANITIZER_UNDEFINED
    myproject_ENABLE_SANITIZER_THREAD
    myproject_ENABLE_SANITIZER_MEMORY
    myproject_ENABLE_UNITY_BUILD
    myproject_ENABLE_CLANG_TIDY
    myproject_ENABLE_CPPCHECK
    myproject_ENABLE_COVERAGE
    myproject_ENABLE_PCH
    myproject_ENABLE_CACHE
    ${ARGN})
endfunction()

# Toolchain probes

# Sets myproject_CPP_MODULES_SUPPORTED; what to do on an unsupported toolchain is the consumer's policy.
macro(myproject_cpp_modules_supported)
  set(myproject_CPP_MODULES_SUPPORTED OFF)
  if(CMAKE_VERSION VERSION_GREATER_EQUAL 3.28)
    # Clang family (incl. AppleClang, clang-cl)
    if(CMAKE_CXX_COMPILER_ID MATCHES ".*Clang.*")
      if(CMAKE_CXX_COMPILER_VERSION VERSION_GREATER_EQUAL 17)
        set(myproject_CPP_MODULES_SUPPORTED ON)
      endif()
      # MSVC (excluding clang-cl which is handled above)
    elseif(MSVC)
      if(MSVC_VERSION GREATER_EQUAL 1934)
        set(myproject_CPP_MODULES_SUPPORTED ON)
      endif()
      # GCC
    elseif(CMAKE_CXX_COMPILER_ID STREQUAL "GNU")
      # CMake's module scanning support for GCC is still evolving; keep a conservative floor.
      if(CMAKE_CXX_COMPILER_VERSION VERSION_GREATER_EQUAL 14)
        set(myproject_CPP_MODULES_SUPPORTED ON)
      endif()
    endif()
  endif()
endmacro()

# Global (directory-scope) settings

# Side by side in the build root, so a Windows executable finds its DLLs without PATH changes.
macro(myproject_set_output_directories)
  set(CMAKE_ARCHIVE_OUTPUT_DIRECTORY ${PROJECT_BINARY_DIR})
  set(CMAKE_LIBRARY_OUTPUT_DIRECTORY ${PROJECT_BINARY_DIR})
  set(CMAKE_RUNTIME_OUTPUT_DIRECTORY ${PROJECT_BINARY_DIR})
endmacro()

# Link-what-you-use everywhere except Release, and IPO everywhere except Debug.
macro(myproject_configure_lwyu_and_ipo)
  if(CMAKE_BUILD_TYPE STREQUAL "Release")
    set(CMAKE_LINK_WHAT_YOU_USE FALSE)
  else()
    set(CMAKE_LINK_WHAT_YOU_USE TRUE)
  endif()

  if(myproject_ENABLE_IPO)
    include(InterproceduralOptimization)
    if(NOT (CMAKE_BUILD_TYPE STREQUAL "Debug"))
      myproject_enable_ipo()
    endif()
  endif()
endmacro()

# The two INTERFACE targets everything else hangs off

# Creates myproject_warnings and myproject_options, the targets every macro below takes.
macro(myproject_create_option_targets)
  if(PROJECT_IS_TOP_LEVEL)
    include(StandardProjectSettings)
  endif()

  add_library(myproject_warnings INTERFACE)
  add_library(myproject_options INTERFACE)

  target_compile_features(myproject_options INTERFACE cxx_std_${CMAKE_CXX_STANDARD})

  include(CompilerWarnings)
  myproject_set_project_warnings(
    myproject_warnings
    ${myproject_WARNINGS_AS_ERRORS}
    ""
    ""
    ""
    "")
endmacro()

# Per-target application of the options

# CPU profiling for RelWithDebInfo on non-Windows GCC/Clang: gperftools if installed, else -pg.
macro(myproject_enable_profiling target)
  if(CMAKE_BUILD_TYPE STREQUAL "RelWithDebInfo"
     AND (CMAKE_CXX_COMPILER_ID STREQUAL "GNU" OR CMAKE_CXX_COMPILER_ID STREQUAL "Clang")
     AND NOT WIN32)

    find_library(PROFILER_LIB profiler)

    if(PROFILER_LIB)
      message(STATUS "Enabling CPU profiling with gperftools (libprofiler)")
      message(STATUS "Found libprofiler: ${PROFILER_LIB}")
      # The absolute path, not -lprofiler, does not depend on the linker's search path.
      target_link_libraries(${target} INTERFACE ${PROFILER_LIB})
    else()
      message(WARNING "libprofiler not found, falling back to gprof (-pg)")
      target_compile_options(${target} INTERFACE -pg)
      target_link_libraries(${target} INTERFACE -pg)
    endif()

  elseif(myproject_ENABLE_GPROF)
    message(STATUS "GProf should only be used with GCC on Linux using -DCMAKE_BUILD_TYPE=RelWithDebInfo")
  endif()
endmacro()

# Callers wanting sanitizers only in some build types wrap the call, not this macro.
macro(myproject_apply_sanitizers target)
  include(Sanitizers)
  myproject_enable_sanitizers(
    ${target}
    ${myproject_ENABLE_SANITIZER_ADDRESS}
    ${myproject_ENABLE_SANITIZER_LEAK}
    ${myproject_ENABLE_SANITIZER_UNDEFINED}
    ${myproject_ENABLE_SANITIZER_THREAD}
    ${myproject_ENABLE_SANITIZER_MEMORY})
endmacro()

# Unity build, precompiled headers and the compiler cache.
macro(myproject_apply_unity_pch_cache target)
  set_target_properties(${target} PROPERTIES UNITY_BUILD ${myproject_ENABLE_UNITY_BUILD})

  if(myproject_ENABLE_PCH)
    target_precompile_headers(
      ${target}
      INTERFACE
      <vector>
      <string>
      <utility>)
  endif()

  if(myproject_ENABLE_CACHE)
    include(Cache)
    myproject_enable_cache()
  endif()
endmacro()

# clang-tidy, cppcheck and coverage; an optional 2nd argument is the --header-filter regex (empty defers to .clang-tidy).
macro(myproject_apply_static_analysis target)
  set(_MYPROJECT_TIDY_HEADER_FILTER "")
  if(${ARGC} GREATER 1)
    set(_MYPROJECT_TIDY_HEADER_FILTER "${ARGV1}")
  endif()

  include(StaticAnalyzers)
  if(myproject_ENABLE_CLANG_TIDY)
    myproject_enable_clang_tidy(${target} ${myproject_WARNINGS_AS_ERRORS} "${_MYPROJECT_TIDY_HEADER_FILTER}")
  endif()

  if(myproject_ENABLE_CPPCHECK)
    myproject_enable_cppcheck(${myproject_WARNINGS_AS_ERRORS} "" # override cppcheck options
    )
  endif()

  if(myproject_ENABLE_COVERAGE)
    include(Tests)
    myproject_enable_coverage(${target})
  endif()
endmacro()

# Only probes -Wl,--fatal-warnings for consumers: applying it did not behave consistently.
macro(myproject_apply_warnings_as_errors_linker_check)
  if(myproject_WARNINGS_AS_ERRORS)
    check_cxx_compiler_flag("-Wl,--fatal-warnings" LINKER_FATAL_WARNINGS)
    if(LINKER_FATAL_WARNINGS)
      # -Wl,--fatal-warnings is deliberately not applied: it fired inconsistently.
    endif()
  endif()
endmacro()

# include-what-you-use, Clang only.
macro(myproject_apply_iwyu target)
  if(myproject_ENABLE_IWYU)
    if(CMAKE_CXX_COMPILER_ID STREQUAL "Clang")
      find_program(IWYU_PATH NAMES include-what-you-use iwyu)
      if(IWYU_PATH)
        set_target_properties(${target} PROPERTIES CXX_INCLUDE_WHAT_YOU_USE "${IWYU_PATH}")
        message(STATUS "Include-What-You-Use found: ${IWYU_PATH}")
      else()
        message(STATUS "Include-What-You-Use not found!")
      endif()
    endif()
  endif()
endmacro()

# The compiler's own static analyzer (/analyze, -fanalyzer).
macro(myproject_apply_static_analyzer_flags target)
  if(myproject_ENABLE_STATIC_ANALYZER)
    if(MSVC)
      target_compile_options(${target} INTERFACE /analyze)
    elseif(CMAKE_CXX_COMPILER_ID STREQUAL "GNU")
      target_compile_options(${target} INTERFACE -fanalyzer)
    elseif(CMAKE_CXX_COMPILER_ID STREQUAL "Clang" AND MSVC)
      # Clang's --analyze is not applied (https://clang.llvm.org/docs/ClangCommandLineReference.html).
    elseif(CMAKE_CXX_COMPILER_ID STREQUAL "Clang")
      # Clang's --analyze is not applied here either.
    endif()
  endif()
endmacro()
