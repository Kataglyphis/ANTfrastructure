# Copyright (c) 2025 Kataglyphis
# SPDX-License-Identifier: MIT
#
# The build-options MECHANISM shared by every consumer: which options exist,
# and the machinery that turns them into target properties.
#
# Hoisted on 2026-09-09 from two consumers whose ProjectOptions.cmake had drifted
# into near-copies of each other:
#
#   BeschleunigerBallett/cmake/ProjectOptions.cmake            (326 lines)
#   AccelerANTgine/cmake/ProjectOptions.cmake                  (472 lines)
#
# The line this module sits on is the one CPackCommon.cmake already draws (see
# cmake/README.md, "What does NOT belong here"): the branch structure is here,
# every project-specific VALUE arrives as an argument. Concretely:
#
#   here    the option NAMES - because they are the interface the other modules
#           in this directory read (Sanitizers, StaticAnalyzers, Cache, Tests,
#           InterproceduralOptimization all key off myproject_ENABLE_*), and the
#           dispatch that feeds them
#   there   every DEFAULT that the two consumers disagree on (passed in), the
#           language standard, the exceptions policy, whether C++ modules are
#           mandatory, the build-type gating, the hardening policy, and the
#           per-compiler flag blocks
#
# Deliberately NOT here: myproject_supports_sanitizers / the Debug sanitizer
# defaults. Those live in SanitizerSupport.cmake, which the two consumers do not
# yet agree on - AccelerANTgine still carries its own copy of the first macro.
# Reconciling that is a separate change, and pulling SanitizerSupport in from
# here would silently pick a winner between two live definitions.

include_guard(GLOBAL)

include(CheckCXXCompilerFlag)

# Bumped when a macro is added or its signature changes, so a consumer can
# assert it did not load a stale same-named file from its own cmake/ directory
# (which is first on CMAKE_MODULE_PATH and would therefore win silently).
set(MYPROJECT_PROJECT_OPTIONS_COMMON_VERSION 1)

# ---------------------------------------------------------------------------
# Option declarations
# ---------------------------------------------------------------------------

# The core option set. Every default that both consumers already agreed on is
# baked in; the four they disagree on are REQUIRED keyword arguments, so a
# caller cannot get a silent OFF by forgetting one.
#
#   myproject_define_core_options(
#     ASAN_DEFAULT     ${DEFAULT_ASAN}
#     UBSAN_DEFAULT    ${DEFAULT_UBSAN}
#     TSAN_DEFAULT     OFF
#     CPPCHECK_DEFAULT ON)
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

  # An empty value here would reach option() as a missing third argument and
  # quietly become OFF, which is exactly the silent regression this module has
  # to be incapable of. Fail instead.
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

# Hide the core options in a consumer that is being built as a subproject.
# Extra project-specific option names can be appended as arguments.
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

# ---------------------------------------------------------------------------
# Toolchain probes
# ---------------------------------------------------------------------------

# Sets myproject_CPP_MODULES_SUPPORTED for the current toolchain.
#
# Knowledge about COMPILERS, like SanitizerSupport.cmake. What a project DOES
# about an unsupported toolchain - hard error, or fall back to headers - is
# policy and stays in the consumer.
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

# ---------------------------------------------------------------------------
# Global (directory-scope) settings
# ---------------------------------------------------------------------------

# Put archives, libraries and runtimes side by side in the build root, so a
# Windows executable finds its DLLs without PATH surgery.
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

# ---------------------------------------------------------------------------
# The two INTERFACE targets everything else hangs off
# ---------------------------------------------------------------------------

# Creates myproject_warnings and myproject_options and applies the shared
# warning set. Every macro below takes one of these targets as its argument.
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

# ---------------------------------------------------------------------------
# Per-target application of the options
# ---------------------------------------------------------------------------

# CPU profiling for RelWithDebInfo on non-Windows GCC/Clang: gperftools when it
# is installed, plain -pg otherwise.
macro(myproject_enable_profiling target)
  # Only when building with -DCMAKE_BUILD_TYPE=RelWithDebInfo,
  # on non-Windows and using GCC or Clang
  if(CMAKE_BUILD_TYPE STREQUAL "RelWithDebInfo"
     AND (CMAKE_CXX_COMPILER_ID STREQUAL "GNU" OR CMAKE_CXX_COMPILER_ID STREQUAL "Clang")
     AND NOT WIN32)

    find_library(PROFILER_LIB profiler)

    if(PROFILER_LIB)
      message(STATUS "Enabling CPU profiling with gperftools (libprofiler)")
      message(STATUS "Found libprofiler: ${PROFILER_LIB}")
      # The resolved absolute path, not -lprofiler: the find_library result does
      # not depend on the linker's search path being right.
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

# Applies the selected sanitizer set. Callers that only want sanitizers in some
# build types wrap the call, not this macro.
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

# clang-tidy, cppcheck and coverage. Optional 2nd argument is the clang-tidy
# --header-filter regex; empty or absent leaves the decision to .clang-tidy.
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

# Probes -Wl,--fatal-warnings so LINKER_FATAL_WARNINGS is available to a
# consumer that wants it. Applying it is still commented out in both consumers
# because it did not behave consistently; the probe is kept so the finding does
# not have to be rediscovered.
macro(myproject_apply_warnings_as_errors_linker_check)
  if(myproject_WARNINGS_AS_ERRORS)
    check_cxx_compiler_flag("-Wl,--fatal-warnings" LINKER_FATAL_WARNINGS)
    if(LINKER_FATAL_WARNINGS)
      # This is not working consistently, so disabling for now
      # target_link_options(myproject_options INTERFACE -Wl,--fatal-warnings)
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
      # https://clang.llvm.org/docs/UsersManual.html
    elseif(CMAKE_CXX_COMPILER_ID STREQUAL "Clang" AND MSVC)
      #target_compile_options(${target} INTERFACE --analyze)
      # https://clang.llvm.org/docs/ClangCommandLineReference.html
    elseif(CMAKE_CXX_COMPILER_ID STREQUAL "Clang")
      #target_compile_options(${target} INTERFACE --analyze --analyzer-output html)
    endif()
  endif()
endmacro()
