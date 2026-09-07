# Copyright (c) 2025 Kataglyphis
# SPDX-License-Identifier: MIT
#
# Per-configuration compiler flags, plus the flag-stripping helpers needed to
# undo CMake's own defaults where they conflict.
#
# Extracted from a consumer's ProjectOptions.cmake on 2026-08-07. The clang-cl
# section in particular belongs HERE rather than in any one consumer: the
# MSVC-compatibility version it pins is a property of the VC Tools shipped in
# THIS repo's Windows image, so the pin and the toolchain that motivates it now
# live in the same repo and move together.

# The MSVC-compatibility version clang-cl embeds into every object file and
# C++20 module interface (.pcm).
#
# Left to auto-detection this value has been observed to differ between
# clang-cl invocations within the SAME build (e.g. 19.51.36248 vs 19.51.36252)
# even though only one VC Tools version (14.51.36231) is installed, which makes
# clang-cl reject a module's .pcm as version-mismatched against whatever a
# sibling translation unit picked up moments later - "Microsoft Visual C/C++
# Version differs in precompiled file ... configuration mismatch" (observed
# 2026-08-01, reproduced across independent container builds).
#
# Pinning removes the ambiguity: every translation unit requests the identical,
# explicit version instead of relying on per-invocation detection. Override this
# when building against a different VC Tools than the image ships.
set(MYPROJECT_CLANG_CL_MS_COMPATIBILITY_VERSION
    "19.51.36231"
    CACHE STRING "MSVC compatibility version clang-cl is pinned to (-fms-compatibility-version)")

macro(myproject_strip_flag_from_var variable_name flag)
  string(
    REPLACE "${flag}"
            ""
            _myproject_updated_value
            "${${variable_name}}")
  set(${variable_name} "${_myproject_updated_value}")
endmacro()

# /RTC1 (MSVC runtime checks) is incompatible with optimisation and with ASan;
# CMake puts it in the default Debug flags, so it has to be removed rather than
# simply not added.
macro(myproject_strip_msvc_debug_runtime_flags)
  foreach(_myproject_flag_var IN ITEMS CMAKE_CXX_FLAGS_DEBUG CMAKE_C_FLAGS_DEBUG)
    myproject_strip_flag_from_var(${_myproject_flag_var} "/RTC1")
    myproject_strip_flag_from_var(${_myproject_flag_var} "-RTC1")
  endforeach()
endmacro()

# clang-cl + ASan needs the release CRT (/MD, set via CMAKE_MSVC_RUNTIME_LIBRARY);
# a leftover /MDd from the Debug defaults links both and the binary dies at startup.
macro(myproject_strip_clang_cl_asan_debug_runtime_flags)
  foreach(_myproject_flag_var IN ITEMS CMAKE_CXX_FLAGS_DEBUG CMAKE_C_FLAGS_DEBUG)
    myproject_strip_flag_from_var(${_myproject_flag_var} "/MDd")
    myproject_strip_flag_from_var(${_myproject_flag_var} "-MDd")
  endforeach()
endmacro()

# Applies Debug/Release/Profile flags for the detected compiler.
#
# Call with the consuming project's ASan option so the clang-cl branch knows
# whether it must strip /MDd, e.g.
#   myproject_apply_compiler_build_flags(${myproject_ENABLE_SANITIZER_ADDRESS})
macro(myproject_apply_compiler_build_flags enable_sanitizer_address)
  if(MSVC AND NOT (CMAKE_CXX_COMPILER_ID STREQUAL "Clang"))
    myproject_strip_msvc_debug_runtime_flags()
    set(CMAKE_CXX_FLAGS_DEBUG "${CMAKE_CXX_FLAGS_DEBUG} /DEBUG /Od /std:c++23preview")
    set(CMAKE_CXX_FLAGS_RELEASE "${CMAKE_CXX_FLAGS_RELEASE} /O2 /std:c++23preview")
    set(CMAKE_CXX_FLAGS_PROFILE "${CMAKE_CXX_FLAGS_PROFILE} /O2 /std:c++23preview")
  elseif(CMAKE_CXX_COMPILER_ID STREQUAL "GNU")
    set(CMAKE_CXX_FLAGS_DEBUG "${CMAKE_CXX_FLAGS_DEBUG} -g -O0 -std=c++23 -ggdb")
    set(CMAKE_CXX_FLAGS_RELEASE "${CMAKE_CXX_FLAGS_RELEASE} -O3 -std=c++23 -DNDEBUG")
    set(CMAKE_CXX_FLAGS_PROFILE "${CMAKE_CXX_FLAGS_PROFILE} -O3 -std=c++23 -DNDEBUG")
  elseif(CMAKE_CXX_COMPILER_ID STREQUAL "Clang" AND MSVC)
    set(_MYPROJECT_CLANG_CL_SAFE_WARNINGS
        "-fms-compatibility-version=${MYPROJECT_CLANG_CL_MS_COMPATIBILITY_VERSION} -fcolor-diagnostics -Wno-error=unused-command-line-argument -Wno-error=character-conversion -Wno-unknown-warning-option -Wno-error=unknown-warning-option"
    )
    myproject_strip_msvc_debug_runtime_flags()
    if(${enable_sanitizer_address})
      myproject_strip_clang_cl_asan_debug_runtime_flags()
    endif()
    set(CMAKE_CXX_FLAGS_DEBUG "${CMAKE_CXX_FLAGS_DEBUG} /Od ${_MYPROJECT_CLANG_CL_SAFE_WARNINGS}")
    set(CMAKE_CXX_FLAGS_RELEASE "${CMAKE_CXX_FLAGS_RELEASE} /O2 -DNDEBUG ${_MYPROJECT_CLANG_CL_SAFE_WARNINGS}")
    set(CMAKE_CXX_FLAGS_PROFILE "${CMAKE_CXX_FLAGS_PROFILE} /O2 -DNDEBUG ${_MYPROJECT_CLANG_CL_SAFE_WARNINGS}")
  elseif(CMAKE_CXX_COMPILER_ID STREQUAL "Clang")
    set(CMAKE_CXX_FLAGS_DEBUG "${CMAKE_CXX_FLAGS_DEBUG} -O0 -g -ggdb -std=c++23 -fcolor-diagnostics")
    set(CMAKE_CXX_FLAGS_RELEASE "${CMAKE_CXX_FLAGS_RELEASE} -O3 -DNDEBUG -std=c++23 -fcolor-diagnostics")
    set(CMAKE_CXX_FLAGS_PROFILE "${CMAKE_CXX_FLAGS_PROFILE} -O3 -DNDEBUG -std=c++23 -fcolor-diagnostics")
  endif()
endmacro()
