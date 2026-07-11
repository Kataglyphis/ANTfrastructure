
# [LiteRTLM-winfix upb_generators] skip protoc-gen-upb/-upbdefs tools (never invoked by
# protobuf or litert-lm; they fail to link abseil under clang++/lld-link). libupb.a is
# still built by libupb.cmake, so the runtime library is unaffected.
set(_proot "${PROTO_SRC_DIR}/CMakeLists.txt")
if(EXISTS "${_proot}")
    file(READ "${_proot}" _pr)
    string(REPLACE
      [[include(${protobuf_SOURCE_DIR}/cmake/upb_generators.cmake)]]
      [[# [LiteRTLM-winfix] upb_generators tools skipped (unused; abseil/lld-link link failure)]]
      _pr "${_pr}")
    file(WRITE "${_proot}" "${_pr}")
    message(STATUS "[LiteRTLM] Skipped upb_generators.cmake include (protoc-gen-upb tools not built)")
endif()
# ...and stop install.cmake from installing the now-nonexistent protoc-gen-* targets by
# emptying its generator loop (protoc's own install stays intact).
set(_pinstall "${PROTO_SRC_DIR}/cmake/install.cmake")
if(EXISTS "${_pinstall}")
    file(READ "${_pinstall}" _pi)
    string(REPLACE [[foreach (generator upb upbdefs)]] [[foreach (generator)]] _pi "${_pi}")
    file(WRITE "${_pinstall}" "${_pi}")
    message(STATUS "[LiteRTLM] Patched install.cmake: drop protoc-gen-* install (targets not built)")
endif()
