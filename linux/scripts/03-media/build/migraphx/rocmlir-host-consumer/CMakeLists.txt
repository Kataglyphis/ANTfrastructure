cmake_minimum_required(VERSION 3.20)
project(MIGraphXRocmlirHostConsumer LANGUAGES CXX)
find_package(
  rocMLIR
  ${ROCMLIR_REQUIRED_VERSION}
  EXACT
  REQUIRED
  CONFIG
  PATHS
  "${ROCMLIR_PREFIX}/lib/cmake/rocmlir"
  NO_DEFAULT_PATH)
if(NOT TARGET rocMLIR::rockCompiler)
  message(FATAL_ERROR "Missing installed rocMLIR::rockCompiler target")
endif()
get_target_property(rocmlir_links rocMLIR::rockCompiler INTERFACE_LINK_LIBRARIES)
get_target_property(rocmlir_includes rocMLIR::rockCompiler INTERFACE_INCLUDE_DIRECTORIES)
if(NOT
   rocmlir_links
   STREQUAL
   "${ROCMLIR_PREFIX}/lib/librockCompiler.a")
  message(FATAL_ERROR "Unexpected rocMLIR archive selection: ${rocmlir_links}")
endif()
if(NOT
   rocmlir_includes
   STREQUAL
   "${ROCMLIR_PREFIX}/include/rocmlir;${ROCMLIR_PREFIX}/include/rocmlir/external/include")
  message(FATAL_ERROR "Unexpected rocMLIR header selection: ${rocmlir_includes}")
endif()
add_executable(rocmlir-host-consumer main.cpp)
target_compile_features(rocmlir-host-consumer PRIVATE cxx_std_17)
target_compile_definitions(rocmlir-host-consumer PRIVATE ROCMLIR_REQUIRED_API_VERSION=${ROCMLIR_REQUIRED_API_VERSION})
target_link_libraries(rocmlir-host-consumer PRIVATE rocMLIR::rockCompiler)
file(
  GENERATE
  OUTPUT "${CMAKE_BINARY_DIR}/imported-library.txt"
  CONTENT "${rocmlir_links}\n")
