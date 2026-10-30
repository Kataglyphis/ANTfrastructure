# Copyright (c) 2026 Kataglyphis
# SPDX-License-Identifier: MIT

# The handler compiles into each executable, so it shares that target's runtime library and defines.

include_guard(GLOBAL)

set(_KATAGLYPHIS_CRASH_DUMP_SOURCE "${CMAKE_CURRENT_LIST_DIR}/crash_dump/kataglyphis_crash_dump.cpp")

# KATAGLYPHIS_CRASH_DUMP_DIR at run time turns an unhandled exception into a minidump and its frames on stderr.
function(kataglyphis_add_crash_dump target)
  if(NOT TARGET "${target}")
    message(FATAL_ERROR "kataglyphis_add_crash_dump: '${target}' is not a target.")
  endif()
  get_target_property(_type "${target}" TYPE)
  if(NOT
     _type
     STREQUAL
     "EXECUTABLE")
    message(FATAL_ERROR "kataglyphis_add_crash_dump: '${target}' is a ${_type}, not an executable.")
  endif()
  if(NOT WIN32)
    return()
  endif()
  if(NOT MSVC)
    message(WARNING "kataglyphis_add_crash_dump: '${target}' gets no crash reporter; it needs cl or clang-cl.")
    return()
  endif()
  target_sources("${target}" PRIVATE "${_KATAGLYPHIS_CRASH_DUMP_SOURCE}")
  # The consumer's warning, lint, unity and module policies are for its own code.
  set_source_files_properties(
    "${_KATAGLYPHIS_CRASH_DUMP_SOURCE}" TARGET_DIRECTORY "${target}"
    PROPERTIES COMPILE_OPTIONS "/w"
               SKIP_LINTING ON
               SKIP_PRECOMPILE_HEADERS ON
               SKIP_UNITY_BUILD_INCLUSION ON
               CXX_SCAN_FOR_MODULES OFF)
  # Release links no PDB by default; one with public symbols names the module+RVA frames.
  target_link_options("${target}" PRIVATE "$<$<CONFIG:Release,MinSizeRel>:/DEBUG;/OPT:REF;/OPT:ICF>")
endfunction()
