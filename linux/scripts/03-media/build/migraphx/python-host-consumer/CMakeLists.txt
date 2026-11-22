cmake_minimum_required(VERSION 3.20)
project(MIGraphXPythonSelectionProbe LANGUAGES CXX)
include("${MIGRAPHX_SOURCE}/cmake/PythonModules.cmake")
list(LENGTH PYTHON_VERSIONS selected_count)
if(NOT
   selected_count
   EQUAL
   1)
  message(FATAL_ERROR "Expected exactly one selected Python ABI")
endif()
py_add_module(
  migraphx-python-probe
  main.cpp
  PYTHON_VERSION
  "${PYTHON_VERSIONS}"
  PYTHON_MODULE
  migraphx_python_probe)
target_compile_features(migraphx-python-probe PRIVATE cxx_std_17)
file(
  GENERATE
  OUTPUT "${CMAKE_BINARY_DIR}/module-file.txt"
  CONTENT "$<TARGET_FILE:migraphx-python-probe>\n")
