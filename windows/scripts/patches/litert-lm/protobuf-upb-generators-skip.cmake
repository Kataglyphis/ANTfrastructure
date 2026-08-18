
# [LiteRTLM-winfix upb_generators] skip protoc-gen-upb/-upbdefs tools (never invoked by
# protobuf or litert-lm; they fail to link abseil under clang++/lld-link). libupb.a is
# still built by libupb.cmake, so the runtime library is unaffected.
include("${CMAKE_CURRENT_LIST_DIR}/patch-assert.cmake")
set(_proot "${PROTO_SRC_DIR}/CMakeLists.txt")
if(EXISTS "${_proot}")
    file(READ "${_proot}" _pr)
    # The if(EXISTS) above stays permissive (upstream may drop the file), but
    # once the file IS there a non-matching pattern is a defect, not a variant.
    patch_replace_required(_pr
      [[include(${protobuf_SOURCE_DIR}/cmake/upb_generators.cmake)]]
      [[# [LiteRTLM-winfix] upb_generators tools skipped (unused; abseil/lld-link link failure)]]
      "protobuf: drop the upb_generators.cmake include")
    file(WRITE "${_proot}" "${_pr}")
    message(STATUS "[LiteRTLM] Skipped upb_generators.cmake include (protoc-gen-upb tools not built)")
endif()
# ...and stop install.cmake from installing the now-nonexistent protoc-gen-* targets by
# emptying its generator loop (protoc's own install stays intact).
set(_pinstall "${PROTO_SRC_DIR}/cmake/install.cmake")
if(EXISTS "${_pinstall}")
    file(READ "${_pinstall}" _pi)
    patch_replace_required(_pi [[foreach (generator upb upbdefs)]] [[foreach (generator)]] "protobuf install.cmake: empty the protoc-gen-* generator loop")
    file(WRITE "${_pinstall}" "${_pi}")
    message(STATUS "[LiteRTLM] Patched install.cmake: drop protoc-gen-* install (targets not built)")
endif()
