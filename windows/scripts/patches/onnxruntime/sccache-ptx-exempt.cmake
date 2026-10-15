# sccache aborts nvcc output that is PTX only for an arch (mozilla/sccache#2862), so only targets with a -virtual arch lose the launcher.

function(_kg_sccache_ptx_exempt_dir dir)
  get_property(_targets DIRECTORY "${dir}" PROPERTY BUILDSYSTEM_TARGETS)
  foreach(_target IN LISTS _targets)
    get_target_property(_archs "${_target}" CUDA_ARCHITECTURES)
    if(_archs MATCHES "-virtual")
      set_property(TARGET "${_target}" PROPERTY CUDA_COMPILER_LAUNCHER "")
      set_property(GLOBAL APPEND PROPERTY KG_SCCACHE_PTX_EXEMPT "${_target}")
    endif()
  endforeach()
  get_property(_subdirs DIRECTORY "${dir}" PROPERTY SUBDIRECTORIES)
  foreach(_subdir IN LISTS _subdirs)
    _kg_sccache_ptx_exempt_dir("${_subdir}")
  endforeach()
endfunction()

function(_kg_sccache_ptx_exempt)
  _kg_sccache_ptx_exempt_dir("${CMAKE_SOURCE_DIR}")
  get_property(_exempt GLOBAL PROPERTY KG_SCCACHE_PTX_EXEMPT)
  if(_exempt)
    message(STATUS "sccache-ptx-exempt: nvcc stays bare for ${_exempt}; every other CUDA target keeps the launcher")
  else()
    message(STATUS "sccache-ptx-exempt: no target has a -virtual CUDA arch; every CUDA target keeps the launcher")
  endif()
endfunction()

# Deferred to the end of the top-level directory, when every target and its CUDA_ARCHITECTURES exist.
cmake_language(DEFER CALL _kg_sccache_ptx_exempt)
