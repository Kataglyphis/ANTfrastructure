# Copyright (c) 2025 Kataglyphis
# SPDX-License-Identifier: MIT

# Pinned because auto-detection varies between clang-cl calls in one build and a .pcm then mismatches; tracks this repo's image VC Tools.
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

# CMake's Debug defaults carry /RTC1, which is incompatible with optimisation and ASan.
macro(myproject_strip_msvc_debug_runtime_flags)
  foreach(_myproject_flag_var IN ITEMS CMAKE_CXX_FLAGS_DEBUG CMAKE_C_FLAGS_DEBUG)
    myproject_strip_flag_from_var(${_myproject_flag_var} "/RTC1")
    myproject_strip_flag_from_var(${_myproject_flag_var} "-RTC1")
  endforeach()
endmacro()

# clang-cl ASan needs the release CRT; a leftover /MDd links both and the binary dies at startup.
macro(myproject_strip_clang_cl_asan_debug_runtime_flags)
  foreach(_myproject_flag_var IN ITEMS CMAKE_CXX_FLAGS_DEBUG CMAKE_C_FLAGS_DEBUG)
    myproject_strip_flag_from_var(${_myproject_flag_var} "/MDd")
    myproject_strip_flag_from_var(${_myproject_flag_var} "-MDd")
  endforeach()
endmacro()

# Applies Debug/Release/RelWithDebInfo flags (the *-Profile presets resolve to RelWithDebInfo).
#   myproject_apply_compiler_build_flags(${myproject_ENABLE_SANITIZER_ADDRESS})  # ASan tells clang-cl to strip /MDd
macro(myproject_apply_compiler_build_flags enable_sanitizer_address)
  if(MSVC AND NOT (CMAKE_CXX_COMPILER_ID STREQUAL "Clang"))
    myproject_strip_msvc_debug_runtime_flags()
    set(CMAKE_CXX_FLAGS_DEBUG "${CMAKE_CXX_FLAGS_DEBUG} /DEBUG /Od /std:c++23preview")
    set(CMAKE_CXX_FLAGS_RELEASE "${CMAKE_CXX_FLAGS_RELEASE} /O2 /std:c++23preview")
    set(CMAKE_CXX_FLAGS_RELWITHDEBINFO "${CMAKE_CXX_FLAGS_RELWITHDEBINFO} /O2 /std:c++23preview")
  elseif(CMAKE_CXX_COMPILER_ID STREQUAL "GNU")
    set(CMAKE_CXX_FLAGS_DEBUG "${CMAKE_CXX_FLAGS_DEBUG} -g -O0 -std=c++23 -ggdb")
    set(CMAKE_CXX_FLAGS_RELEASE "${CMAKE_CXX_FLAGS_RELEASE} -O3 -std=c++23 -DNDEBUG")
    set(CMAKE_CXX_FLAGS_RELWITHDEBINFO "${CMAKE_CXX_FLAGS_RELWITHDEBINFO} -O3 -std=c++23 -DNDEBUG")
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
    set(CMAKE_CXX_FLAGS_RELWITHDEBINFO
        "${CMAKE_CXX_FLAGS_RELWITHDEBINFO} /O2 -DNDEBUG ${_MYPROJECT_CLANG_CL_SAFE_WARNINGS}")
  elseif(CMAKE_CXX_COMPILER_ID STREQUAL "Clang")
    set(CMAKE_CXX_FLAGS_DEBUG "${CMAKE_CXX_FLAGS_DEBUG} -O0 -g -ggdb -std=c++23 -fcolor-diagnostics")
    set(CMAKE_CXX_FLAGS_RELEASE "${CMAKE_CXX_FLAGS_RELEASE} -O3 -DNDEBUG -std=c++23 -fcolor-diagnostics")
    set(CMAKE_CXX_FLAGS_RELWITHDEBINFO "${CMAKE_CXX_FLAGS_RELWITHDEBINFO} -O3 -DNDEBUG -std=c++23 -fcolor-diagnostics")
  endif()
endmacro()
