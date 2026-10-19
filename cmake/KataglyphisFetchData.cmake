# kataglyphis_fetch_data: the hub's data-lock fetcher at configure or in cmake -P; docs/data-repositories.md#the-hubs-fetcher
include_guard(GLOBAL)

# Captured here: inside a function CMAKE_CURRENT_LIST_DIR is the caller's directory.
set(_KATAGLYPHIS_FETCH_DATA "${CMAKE_CURRENT_LIST_DIR}/../linux/scripts/lib/fetch-data-lock.py")

# kataglyphis_fetch_data(LOCK <file> [DEST <dir>] [EXTRACT] [ONLY <name>...]): any fetch error stops the configure.
function(kataglyphis_fetch_data)
  cmake_parse_arguments(
    ARG
    "EXTRACT"
    "LOCK;DEST"
    "ONLY"
    ${ARGN})
  if(NOT ARG_LOCK)
    message(FATAL_ERROR "kataglyphis_fetch_data: LOCK is required")
  endif()
  if(DEFINED Python3_EXECUTABLE)
    set(_python "${Python3_EXECUTABLE}")
  else()
    # Windows' python3 on PATH is often the Store stub, which only prints an install hint.
    if(CMAKE_HOST_WIN32)
      set(_names python python3)
    else()
      set(_names python3 python)
    endif()
    find_program(KATAGLYPHIS_FETCH_DATA_PYTHON NAMES ${_names} REQUIRED)
    set(_python "${KATAGLYPHIS_FETCH_DATA_PYTHON}")
  endif()
  set(_args --lock "${ARG_LOCK}")
  if(ARG_DEST)
    list(
      APPEND
      _args
      --dest
      "${ARG_DEST}")
  endif()
  if(ARG_EXTRACT)
    list(APPEND _args --extract)
  endif()
  foreach(_name IN LISTS ARG_ONLY)
    list(
      APPEND
      _args
      --only
      "${_name}")
  endforeach()
  execute_process(COMMAND "${_python}" -I "${_KATAGLYPHIS_FETCH_DATA}" ${_args} RESULT_VARIABLE _rc)
  if(NOT
     _rc
     EQUAL
     0)
    message(FATAL_ERROR "kataglyphis_fetch_data: ${ARG_LOCK} was not fetched (exit ${_rc}); the lines above say why.\n"
                        "Offline, put each file in the cache as <sha256>-<file>, or configure without the data.")
  endif()
  if(NOT CMAKE_SCRIPT_MODE_FILE)
    set_property(
      DIRECTORY
      APPEND
      PROPERTY CMAKE_CONFIGURE_DEPENDS "${ARG_LOCK}")
  endif()
endfunction()
