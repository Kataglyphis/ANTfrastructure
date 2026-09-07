function(myproject_enable_coverage project_name)
  if(NOT
     CMAKE_BUILD_TYPE
     STREQUAL
     "Release")
    if(CMAKE_CXX_COMPILER_ID STREQUAL "GNU")
      message(" -- ** Enabling coverage reporting**")
      target_compile_options(${project_name} INTERFACE --coverage -O0 -g)
      target_link_libraries(${project_name} INTERFACE --coverage)
    elseif(CMAKE_CXX_COMPILER_ID MATCHES ".*Clang")
      message(" -- ** Enabling coverage reporting**")
      if(MSVC)
        # clang-cl: lld-link rejects the coverage driver flags, so compile via
        # /clang:-prefixed flags and link clang_rt.profile explicitly.
        target_compile_options(${project_name} INTERFACE /clang:-fprofile-instr-generate /clang:-fcoverage-mapping)
        execute_process(
          COMMAND ${CMAKE_CXX_COMPILER} --print-resource-dir
          RESULT_VARIABLE _cov_resource_dir_rc
          OUTPUT_VARIABLE _cov_clang_resource_dir
          OUTPUT_STRIP_TRAILING_WHITESPACE)
        if(NOT
           _cov_resource_dir_rc
           EQUAL
           0
           OR "${_cov_clang_resource_dir}" STREQUAL "")
          message(FATAL_ERROR "Coverage was requested, but '${CMAKE_CXX_COMPILER} --print-resource-dir' failed "
                              "(exit ${_cov_resource_dir_rc}); cannot locate the clang profile runtime to link.")
        endif()
        set(_cov_profile_lib "${_cov_clang_resource_dir}/lib/windows/clang_rt.profile-x86_64.lib")
        if(NOT EXISTS "${_cov_profile_lib}")
          message(FATAL_ERROR "Coverage was requested, but the clang-cl profile runtime is missing: "
                              "${_cov_profile_lib}")
        endif()
        target_link_directories(${project_name} INTERFACE "${_cov_clang_resource_dir}/lib/windows")
        target_link_libraries(${project_name} INTERFACE clang_rt.profile-x86_64)
      else()
        target_compile_options(${project_name} INTERFACE -fprofile-instr-generate -fcoverage-mapping)
        target_link_options(
          ${project_name}
          INTERFACE
          -fprofile-instr-generate
          -fcoverage-mapping)
      endif()
    else()
      message(" -- ** Coverage reporting not supported for this compiler/platform **")
    endif()
  else()
    message("We do not enable coverage on release builds.")
  endif()
endfunction()
