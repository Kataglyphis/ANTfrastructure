# Copyright (c) 2025 Kataglyphis
# SPDX-License-Identifier: MIT
#
# One registration entry point for GoogleTest executables, owning the union of
# what two consumers had grown independently:
#
#   BeschleunigerBallett/Test/cmake/CommonTestBuild.cmake
#     gtest_discover_tests(... WORKING_DIRECTORY ${CMAKE_SOURCE_DIR}) so a test
#     binary resolves the same relative resource paths as the main executable.
#
#   AccelerANTgine/Test/cmake/CommonTestBuild.cmake
#     a clang-cl opt-OUT of discovery entirely (the ASan/UBSan executables die
#     during the discovery run with the Windows loader error 0xc0000135) plus an
#     add_test fallback that hands the test an explicit PATH so the loader finds
#     the runtime DLLs it could not find during discovery either.
#
# Both defined a function named kataglyphis_configure_gtest_discovery, and both
# repos also define kataglyphis_configure_common_test_target with INCOMPATIBLE
# arity (1 argument vs 3), so AccelerANTgine building as OmniAccelerANT's
# subproject cannot simply inherit the other's copy. This module therefore uses
# a NEW name that collides with neither, so a consumer can adopt it before it
# has finished deleting its local definition.
#
# WORKING_DIRECTORY is deliberately OPT-IN rather than defaulted to
# CMAKE_SOURCE_DIR. That variable does not mean the same thing in both repos:
# in a standalone AccelerANTgine build it is AccelerANTgine's root, and in an
# OmniAccelerANT build it is OmniAccelerANT's root - so defaulting it on would
# silently move the working directory of the tests that currently rely on
# CTest's default (the build directory) whenever the nesting changes. A caller
# that wants the behaviour asks for it by name.

include_guard(GLOBAL)

# The module owns its own dependency: a consumer that includes this file must
# not also have to remember include(GoogleTest) before it.
include(GoogleTest)

# Registers a GoogleTest executable with CTest.
#
#   kataglyphis_register_gtest_target(<target>
#                                     [WORKING_DIRECTORY <dir>]
#                                     [DISCOVERY_TIMEOUT <seconds>])
#
# WORKING_DIRECTORY   run the tests from <dir> instead of CTest's default.
#                     Opt-in; pass an absolute path (e.g. ${PROJECT_SOURCE_DIR})
#                     when the test binary resolves resources relatively.
# DISCOVERY_TIMEOUT   seconds allowed for the discovery run (default 300).
#
# Set KATAGLYPHIS_ENABLE_GTEST_DISCOVERY=OFF to force the add_test fallback for
# every target; clang-cl forces it off regardless (see below).
function(kataglyphis_register_gtest_target test_target)
  set(_kataglyphis_options "")
  set(_kataglyphis_one_value_args WORKING_DIRECTORY DISCOVERY_TIMEOUT)
  set(_kataglyphis_multi_value_args "")
  cmake_parse_arguments(
    KATAGLYPHIS_GTEST
    "${_kataglyphis_options}"
    "${_kataglyphis_one_value_args}"
    "${_kataglyphis_multi_value_args}"
    ${ARGN})

  if(KATAGLYPHIS_GTEST_UNPARSED_ARGUMENTS)
    message(FATAL_ERROR "kataglyphis_register_gtest_target(${test_target}): unexpected argument(s) "
                        "'${KATAGLYPHIS_GTEST_UNPARSED_ARGUMENTS}'")
  endif()

  if(NOT TARGET ${test_target})
    message(FATAL_ERROR "kataglyphis_register_gtest_target: '${test_target}' is not a target.")
  endif()

  if(NOT DEFINED KATAGLYPHIS_GTEST_DISCOVERY_TIMEOUT)
    set(KATAGLYPHIS_GTEST_DISCOVERY_TIMEOUT 300)
  endif()

  # A cache/user setting wins as the starting point; unset means ON.
  if(NOT DEFINED KATAGLYPHIS_ENABLE_GTEST_DISCOVERY)
    set(_kataglyphis_use_discovery ON)
  else()
    set(_kataglyphis_use_discovery ${KATAGLYPHIS_ENABLE_GTEST_DISCOVERY})
  endif()

  # clang-cl: the discovery run loads the freshly linked executable outside the
  # environment CTest would give it, and an ASan/UBSan build then dies with
  # 0xc0000135 (STATUS_DLL_NOT_FOUND) before printing a single test name. There
  # is nothing to configure around it - discovery has to be skipped.
  if(WIN32
     AND CMAKE_CXX_COMPILER_ID STREQUAL "Clang"
     AND MSVC)
    set(_kataglyphis_use_discovery OFF)
  endif()

  if(_kataglyphis_use_discovery)
    message(STATUS "kataglyphis_register_gtest_target: gtest_discover_tests for ${test_target}.")

    # PRE_TEST keeps discovery inside the ctest phase instead of running the
    # binary as a build step, which is what makes Windows runtime-path handling
    # (and ASan builds) survivable at all.
    set(_kataglyphis_discover_args
        ${test_target}
        DISCOVERY_TIMEOUT
        ${KATAGLYPHIS_GTEST_DISCOVERY_TIMEOUT}
        DISCOVERY_MODE
        PRE_TEST)
    if(KATAGLYPHIS_GTEST_WORKING_DIRECTORY)
      list(
        APPEND
        _kataglyphis_discover_args
        WORKING_DIRECTORY
        "${KATAGLYPHIS_GTEST_WORKING_DIRECTORY}")
    endif()

    gtest_discover_tests(${_kataglyphis_discover_args})
    return()
  endif()

  message(STATUS "kataglyphis_register_gtest_target: discovery off - add_test fallback for ${test_target}.")
  add_test(NAME ${test_target} COMMAND $<TARGET_FILE:${test_target}>)

  # An explicit WORKING_DIRECTORY always wins. Otherwise Windows still needs the
  # binary's own directory, because that is where its sibling DLLs live.
  if(KATAGLYPHIS_GTEST_WORKING_DIRECTORY)
    set(_kataglyphis_test_workdir "${KATAGLYPHIS_GTEST_WORKING_DIRECTORY}")
  elseif(WIN32)
    set(_kataglyphis_test_workdir "$<TARGET_FILE_DIR:${test_target}>")
  else()
    set(_kataglyphis_test_workdir "")
  endif()

  if(_kataglyphis_test_workdir)
    set_tests_properties(${test_target} PROPERTIES WORKING_DIRECTORY "${_kataglyphis_test_workdir}")
  endif()

  if(WIN32)
    # The loader searches PATH, so the fallback has to reconstruct what the
    # discovery run could not find: the target's own directory, the build tree's
    # bin/lib, and the compiler's directory (clang_rt.asan_dynamic-*.dll ships
    # next to clang-cl.exe).
    get_filename_component(_kataglyphis_compiler_dir "${CMAKE_CXX_COMPILER}" DIRECTORY)
    set_tests_properties(
      ${test_target}
      PROPERTIES
        ENVIRONMENT
        "PATH=$<TARGET_FILE_DIR:${test_target}>;${CMAKE_BINARY_DIR}/bin;${CMAKE_BINARY_DIR}/lib;${_kataglyphis_compiler_dir};$ENV{PATH}"
    )
  endif()
endfunction()
