# Deferred binding lets the real ORT target own the probe's compiler and linked C API.
include_guard(GLOBAL)

function(ant_ort_webgpu_factory_probe)
  if(NOT TARGET onnxruntime_webassembly)
    message(FATAL_ERROR "The owning ORT WebAssembly target is required")
  endif()
  if(NOT
     CMAKE_SYSTEM_NAME
     STREQUAL
     "Emscripten"
     OR NOT onnxruntime_USE_WEBGPU
     OR NOT onnxruntime_USE_EP_API_ADAPTERS
     OR NOT onnxruntime_WEBGPU_STATIC_PLUGIN
     OR onnxruntime_USE_EXTERNAL_DAWN)
    message(FATAL_ERROR "The WASM factory probe requires the integrated-Dawn static plugin")
  endif()
  get_filename_component(header "${CMAKE_SOURCE_DIR}/../include/onnxruntime/core/session/onnxruntime_c_api.h" ABSOLUTE)
  if(NOT EXISTS "${header}")
    message(FATAL_ERROR "The owning WASM C API header is required")
  endif()
  target_sources(onnxruntime_webassembly PRIVATE "${CMAKE_CURRENT_FUNCTION_LIST_DIR}/probe.c")
  target_compile_definitions(onnxruntime_webassembly PRIVATE WEBGPU_PROBE_LINKED_CORE
                                                             WEBGPU_ORT_C_API_HEADER="${header}")
  target_compile_features(onnxruntime_webassembly PRIVATE c_std_11)
endfunction()

cmake_language(DEFER CALL ant_ort_webgpu_factory_probe)
