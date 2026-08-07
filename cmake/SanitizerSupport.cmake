# Copyright (c) 2025 Kataglyphis
# SPDX-License-Identifier: MIT
#
# Which sanitizers this toolchain can actually run, and which ones a Debug
# build should switch on by itself.
#
# Extracted from a consumer's ProjectOptions.cmake on 2026-08-07. The knowledge
# encoded here is about COMPILERS, not about any project: every consumer that
# re-derives it re-learns the same platform quirks the hard way.

# Sets SUPPORTS_ASAN / SUPPORTS_UBSAN for the current toolchain.
macro(myproject_supports_sanitizers)
  set(_MYPROJECT_IS_CLANG_CL OFF)
  if(CMAKE_CXX_COMPILER_ID STREQUAL "Clang" AND MSVC)
    set(_MYPROJECT_IS_CLANG_CL ON)
  endif()

  if((CMAKE_CXX_COMPILER_ID MATCHES ".*Clang.*" OR CMAKE_CXX_COMPILER_ID MATCHES ".*GNU.*") AND NOT WIN32)
    # GCC 15 ICEs on UBSan + C++20 modules. Narrow version window on purpose:
    # re-enable automatically once the consumer moves to GCC 16 rather than
    # leaving a permanent opt-out behind.
    if(CMAKE_CXX_COMPILER_ID STREQUAL "GNU"
       AND CMAKE_CXX_COMPILER_VERSION VERSION_GREATER_EQUAL 15.0
       AND CMAKE_CXX_COMPILER_VERSION VERSION_LESS 16.0)
      message(WARNING "Disabling UBSan for GCC 15 due to compiler ICE with C++ modules.")
      set(SUPPORTS_UBSAN OFF)
    else()
      set(SUPPORTS_UBSAN ON)
    endif()
  elseif(_MYPROJECT_IS_CLANG_CL)
    set(SUPPORTS_UBSAN ON)
  else()
    set(SUPPORTS_UBSAN OFF)
  endif()

  if(MSVC OR ((CMAKE_CXX_COMPILER_ID MATCHES ".*Clang.*" OR CMAKE_CXX_COMPILER_ID MATCHES ".*GNU.*") AND NOT WIN32))
    set(SUPPORTS_ASAN ON)
  else()
    set(SUPPORTS_ASAN OFF)
  endif()
endmacro()

# Sets DEFAULT_ASAN / DEFAULT_UBSAN - the defaults for the sanitizer options,
# ON only when a Debug configuration is actually being built AND the toolchain
# supports it. Requires myproject_supports_sanitizers() to have run.
#
# Handles both generator shapes: multi-config (CMAKE_CONFIGURATION_TYPES) and
# single-config (CMAKE_BUILD_TYPE). Checking only the latter silently disables
# the defaults under Visual Studio and Ninja Multi-Config.
macro(myproject_default_debug_sanitizers)
  set(DEFAULT_ASAN OFF)
  set(DEFAULT_UBSAN OFF)

  set(_MYPROJECT_HAS_DEBUG_CONFIG OFF)
  if(CMAKE_CONFIGURATION_TYPES)
    foreach(_myproject_config IN LISTS CMAKE_CONFIGURATION_TYPES)
      if(_myproject_config STREQUAL "Debug")
        set(_MYPROJECT_HAS_DEBUG_CONFIG ON)
        break()
      endif()
    endforeach()
  elseif(CMAKE_BUILD_TYPE STREQUAL "Debug")
    set(_MYPROJECT_HAS_DEBUG_CONFIG ON)
  endif()

  if(_MYPROJECT_HAS_DEBUG_CONFIG AND SUPPORTS_ASAN)
    if(CMAKE_SYSTEM_NAME STREQUAL "Linux" OR MSVC)
      set(DEFAULT_ASAN ON)
    endif()
  endif()

  if(_MYPROJECT_HAS_DEBUG_CONFIG AND SUPPORTS_UBSAN)
    if(CMAKE_SYSTEM_NAME STREQUAL "Linux" OR (CMAKE_CXX_COMPILER_ID STREQUAL "Clang" AND MSVC))
      set(DEFAULT_UBSAN ON)
    endif()
  endif()
endmacro()
