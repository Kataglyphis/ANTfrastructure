cmake_minimum_required(VERSION 3.20)
project(MIGraphXCKHostConsumer LANGUAGES CXX)
find_package(
  composable_kernel_host
  ${CK_REQUIRED_VERSION}
  EXACT
  REQUIRED
  CONFIG
  PATHS
  "${CK_PREFIX}/lib/cmake/composable_kernel_host"
  NO_DEFAULT_PATH)
add_executable(ck-host-consumer main.cpp)
target_compile_features(ck-host-consumer PRIVATE cxx_std_20)
target_link_libraries(ck-host-consumer PRIVATE composable_kernel::ck_host)
file(
  GENERATE
  OUTPUT "${CMAKE_BINARY_DIR}/imported-library.txt"
  CONTENT "$<TARGET_FILE:composable_kernel::ck_host>\n")
