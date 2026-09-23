# Copyright (c) 2025 Kataglyphis
# SPDX-License-Identifier: MIT

# Included by OpenCV via OPENCV_CMAKE_HOOKS_DIR (Build-OpencvFromSource.ps1). dml_ep.cpp hard-links these four
# DLLs; delay-load them as ORT does for the same set, so opencv_gapi still loads where dxcore.dll is absent.
if(MSVC AND HAVE_ONNX AND HAVE_ONNX_DML AND HAVE_DIRECTML)
  target_link_options(${the_module} PRIVATE
    "/DELAYLOAD:dxcore.dll" "/DELAYLOAD:d3d12.dll" "/DELAYLOAD:dxgi.dll" "/DELAYLOAD:DirectML.dll")
  target_link_libraries(${the_module} PRIVATE delayimp.lib)
  message(STATUS "antfrastructure hook: ${the_module} delay-loads dxcore.dll d3d12.dll dxgi.dll DirectML.dll")
endif()
