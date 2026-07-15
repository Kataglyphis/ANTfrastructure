
# [LiteRTLM-winfix rust-lib-stage] stage the MSVC-named rust staticlib + cxxbridge C++ glue under the
# GNU lib*.a names that _cxxbridge_paths references (rustc/clang-cl emit <name>.lib on windows-msvc).
foreach(_winfix_pair "litert_lm_deps.lib|liblitert_lm_deps.a" "litertlm_cxx_bridge.lib|liblitertlm_cxx_bridge.a")
    string(REPLACE "|" ";" _winfix_kv "${_winfix_pair}")
    list(GET _winfix_kv 0 _winfix_src_name)
    list(GET _winfix_kv 1 _winfix_dst_name)
    file(GLOB_RECURSE _winfix_found "${CMAKE_BINARY_DIR}/${_winfix_src_name}")
    if(_winfix_found)
        list(GET _winfix_found 0 _winfix_src)
        file(COPY_FILE "${_winfix_src}" "${CMAKE_BINARY_DIR}/${_winfix_dst_name}")
        message(STATUS "[LiteRTLM-winfix] staged ${_winfix_src} -> ${_winfix_dst_name}")
    else()
        message(WARNING "[LiteRTLM-winfix] rust lib ${_winfix_src_name} not found under ${CMAKE_BINARY_DIR}")
    endif()
endforeach()
