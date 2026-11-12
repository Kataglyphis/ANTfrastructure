# Package resolution checks development metadata, not binary ABI, compilation or GPU inference.
set(PYBIND11_NOPYTHON ON)

function(migraphx_sdk_find mgx_package mgx_version)
  if(NOT
     "${mgx_version}"
     STREQUAL
     "")
    find_package(
      ${mgx_package}
      "${mgx_version}"
      QUIET
      CONFIG)
  else()
    find_package(${mgx_package} QUIET CONFIG)
  endif()
  set(mgx_found
      "${${mgx_package}_FOUND}"
      PARENT_SCOPE)
endfunction()

set(missing)
foreach(
  dependency IN
  ITEMS hip
        hsa-runtime64
        miopen
        rocblas
        hipblaslt
        hipblas
        hiprtc
        SQLite3
        pybind11
        "composable_kernel_host@1.0.0"
        "rocMLIR@1.0.0")
  string(
    REPLACE "@"
            ";"
            fields
            "${dependency}")
  list(
    GET
    fields
    0
    package)
  list(LENGTH fields count)
  set(version "")
  if(count GREATER 1)
    list(
      GET
      fields
      1
      version)
  endif()
  migraphx_sdk_find("${package}" "${version}")
  if(mgx_found)
    message(STATUS "MIGRAPHX SDK found ${package}: ${${package}_DIR}")
  else()
    list(APPEND missing "${dependency}")
    message(STATUS "MIGRAPHX SDK missing ${dependency}")
  endif()
endforeach()
if(missing)
  list(
    JOIN
    missing
    ", "
    diagnostic)
  message(FATAL_ERROR "MIGraphX SDK development packages missing: ${diagnostic}")
endif()
