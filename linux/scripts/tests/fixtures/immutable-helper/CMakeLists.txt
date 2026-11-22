cmake_minimum_required(VERSION 3.25)
project(
  ImmutableHelperFixture
  VERSION 1.0
  LANGUAGES CXX)
include(GNUInstallDirs)
list(PREPEND CMAKE_MODULE_PATH "${HUB_CMAKE}")
include(CPackCommon)
if(CORRUPT_CLOSURE)
  set(_KATAGLYPHIS_ELF_CLOSURE "${CMAKE_CURRENT_SOURCE_DIR}/corrupt-closure.sh")
endif()
add_library(immutable_support SHARED support.cpp)
set_target_properties(immutable_support PROPERTIES SOVERSION 1)
add_library(external_helper SHARED external.cpp)
add_executable(immutable_worker helper.cpp)
target_compile_features(immutable_worker PRIVATE cxx_std_17)
target_compile_options(
  immutable_worker
  PRIVATE -O3
          -Wall
          -Wextra
          -Werror)
target_link_libraries(immutable_worker PRIVATE immutable_support ${CMAKE_DL_LIBS})
set_target_properties(
  immutable_worker
  PROPERTIES OUTPUT_NAME "helper worker"
             BUILD_WITH_INSTALL_RPATH TRUE
             INSTALL_RPATH "$ORIGIN/original-path")
install(TARGETS immutable_support LIBRARY DESTINATION "${CMAKE_INSTALL_LIBDIR}/fixture")
install(TARGETS immutable_worker RUNTIME DESTINATION libexec)
set(_options)
set(_loader LOADER)
if(NO_LOADER)
  set(_loader)
endif()
if(EXTERNAL_PATHS)
  list(
    APPEND
    _options
    EXTERNAL_LIBRARY_PATH
    PRESERVE_ORT_IN_APPIMAGE)
endif()
kataglyphis_install_linux_closure(
  ${_loader}
  PRIVATE_DIR
  fixture
  TARGETS
  immutable_support
  IMMUTABLE_HELPERS
  "libexec/helper worker"
  ${EXTRA_HELPERS}
  ${_options})
file(WRITE "${CMAKE_BINARY_DIR}/patchelf-path" "${CPACK_APPIMAGE_PATCHELF_EXECUTABLE}")
set(CPACK_GENERATOR "TGZ;DEB")
set(CPACK_PACKAGE_CONTACT "fixture@example.invalid")
set(CPACK_PACKAGING_INSTALL_PREFIX /usr)
set(CPACK_DEBIAN_PACKAGE_DEPENDS libc6)
set(CPACK_DEBIAN_COMPRESSION_TYPE gzip)
include(CPack)
