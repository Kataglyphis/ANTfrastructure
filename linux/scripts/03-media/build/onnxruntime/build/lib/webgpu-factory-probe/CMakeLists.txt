cmake_minimum_required(VERSION 3.25)

# The probe must use its core's configured target compiler, not a fresh host default.
set(compiler_settings CMAKE_C_COMPILER CMAKE_C_COMPILER_ARG1 CMAKE_C_COMPILER_TARGET
    CMAKE_C_COMPILER_EXTERNAL_TOOLCHAIN CMAKE_TOOLCHAIN_FILE CMAKE_SYSTEM_NAME
    CMAKE_SYSTEM_PROCESSOR CMAKE_SYSROOT CMAKE_SYSROOT_COMPILE CMAKE_SYSROOT_LINK
    CMAKE_C_FLAGS CMAKE_C_FLAGS_DEBUG CMAKE_C_FLAGS_RELEASE CMAKE_C_FLAGS_RELWITHDEBINFO
    CMAKE_C_FLAGS_MINSIZEREL CMAKE_EXE_LINKER_FLAGS CMAKE_BUILD_TYPE)
if(NOT EXISTS "${ORT_CONFIG_DIR}/CMakeCache.txt")
  message(FATAL_ERROR "The owning ORT configured cache is required")
endif()
load_cache("${ORT_CONFIG_DIR}" READ_WITH_PREFIX CORE_ ${compiler_settings})
if(NOT CORE_CMAKE_C_COMPILER)
  message(FATAL_ERROR "The owning ORT C compiler is required")
endif()
foreach(setting IN LISTS compiler_settings)
  if(DEFINED CORE_${setting})
    if(setting STREQUAL "CMAKE_EXE_LINKER_FLAGS" AND DEFINED CMAKE_EXE_LINKER_FLAGS)
      continue()
    endif()
    set(${setting} "${CORE_${setting}}" CACHE STRING "Owning ORT compiler configuration" FORCE)
  endif()
endforeach()
project(ort_webgpu_factory_probe LANGUAGES C)
if(NOT EXISTS "${ORT_INCLUDE_DIR}/onnxruntime_c_api.h")
  message(FATAL_ERROR "The owning ORT C API header is required")
endif()
add_executable(ort-webgpu-factory-probe probe.c)
# Absolute inclusion keeps ambient include paths from selecting another core header.
target_include_directories(ort-webgpu-factory-probe PRIVATE "${ORT_INCLUDE_DIR}")
target_compile_definitions(ort-webgpu-factory-probe PRIVATE
    WEBGPU_ORT_C_API_HEADER="${ORT_INCLUDE_DIR}/onnxruntime_c_api.h")
target_compile_features(ort-webgpu-factory-probe PRIVATE c_std_11)
target_compile_options(ort-webgpu-factory-probe PRIVATE -Wall -Wextra -Werror)
target_link_libraries(ort-webgpu-factory-probe PRIVATE ${CMAKE_DL_LIBS})
install(TARGETS ort-webgpu-factory-probe RUNTIME DESTINATION bin)
