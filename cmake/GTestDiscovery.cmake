# Copyright (c) 2025 Kataglyphis
# SPDX-License-Identifier: MIT

# WORKING_DIRECTORY is opt-in: CMAKE_SOURCE_DIR changes meaning when a consumer builds as another's subproject.

include_guard(GLOBAL)

include(GoogleTest)

# Registers a GoogleTest executable with CTest; KATAGLYPHIS_ENABLE_GTEST_DISCOVERY=OFF forces the add_test fallback.
#   kataglyphis_register_gtest_target(<target> [WORKING_DIRECTORY <absolute dir>] [DISCOVERY_TIMEOUT <seconds, default 300>])
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

  # clang-cl ASan/UBSan binaries die with 0xc0000135 in the discovery run, outside CTest's environment.
  if(WIN32
     AND CMAKE_CXX_COMPILER_ID STREQUAL "Clang"
     AND MSVC)
    set(_kataglyphis_use_discovery OFF)
  endif()

  if(_kataglyphis_use_discovery)
    message(STATUS "kataglyphis_register_gtest_target: gtest_discover_tests for ${test_target}.")

    # PRE_TEST discovers in the ctest phase, not as a build step, which Windows runtime paths and ASan need.
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

  # Otherwise Windows needs the binary's own directory, where its sibling DLLs live.
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
    # The loader searches PATH; the ASan runtime DLLs ship next to clang-cl.exe.
    get_filename_component(_kataglyphis_compiler_dir "${CMAKE_CXX_COMPILER}" DIRECTORY)
    set_tests_properties(
      ${test_target}
      PROPERTIES
        ENVIRONMENT
        "PATH=$<TARGET_FILE_DIR:${test_target}>;${CMAKE_BINARY_DIR}/bin;${CMAKE_BINARY_DIR}/lib;${_kataglyphis_compiler_dir};$ENV{PATH}"
    )
  endif()
endfunction()
