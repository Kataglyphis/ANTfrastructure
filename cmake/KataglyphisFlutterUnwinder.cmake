# Copyright (c) 2026 Kataglyphis
# SPDX-License-Identifier: MIT

# See docs/failure-modes.md#a-flutter-350-linux-app-aborts-at-its-first-c-exception

include_guard(GLOBAL)

# Flutter 3.50's engine exports a second _Unwind_*, so libgcc_s.so.1 must lead the runner's NEEDED list; call before flutter.
function(kataglyphis_flutter_unwinder_first target)
  if(NOT TARGET "${target}")
    message(FATAL_ERROR "kataglyphis_flutter_unwinder_first: '${target}' is not a target.")
  endif()
  get_target_property(_type "${target}" TYPE)
  if(NOT
     _type
     STREQUAL
     "EXECUTABLE")
    message(FATAL_ERROR "kataglyphis_flutter_unwinder_first: '${target}' is a ${_type}, not an executable.")
  endif()
  # Only an ELF runner has a NEEDED list; the Windows and macOS runners load no libgcc_s.
  if(NOT
     CMAKE_SYSTEM_NAME
     STREQUAL
     "Linux")
    return()
  endif()
  get_target_property(_libs "${target}" LINK_LIBRARIES)
  if(NOT _libs)
    set(_libs "")
  endif()
  foreach(_lib IN LISTS _libs)
    if(_lib STREQUAL "flutter" OR _lib MATCHES "libflutter_linux_gtk\\.so$")
      message(
        FATAL_ERROR
          "kataglyphis_flutter_unwinder_first: '${target}' already links ${_lib}, so libgcc_s would come after "
          "Flutter's unwinder. Call it before target_link_libraries(${target} PRIVATE flutter).")
    endif()
  endforeach()
  # --no-as-needed keeps the entry: the runner itself calls no _Unwind_* function.
  target_link_libraries("${target}" PRIVATE "-Wl,--push-state,--no-as-needed" gcc_s "-Wl,--pop-state")
endfunction()
