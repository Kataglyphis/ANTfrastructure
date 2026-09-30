
# [LiteRTLM-winfix upb_generators] protoc-gen-upb/-upbdefs fail to link abseil and nothing runs them; libupb.a still builds.
include("${CMAKE_CURRENT_LIST_DIR}/patch-assert.cmake")
set(_proot "${PROTO_SRC_DIR}/CMakeLists.txt")
if(EXISTS "${_proot}")
    file(READ "${_proot}" _pr)
    # Upstream may drop the file, but a present file that does not match is a defect.
    patch_replace_required(_pr
      [[include(${protobuf_SOURCE_DIR}/cmake/upb_generators.cmake)]]
      [[# [LiteRTLM-winfix] upb_generators tools skipped (unused; abseil/lld-link link failure)]]
      "protobuf: drop the upb_generators.cmake include")
    file(WRITE "${_proot}" "${_pr}")
    message(STATUS "[LiteRTLM] Skipped upb_generators.cmake include (protoc-gen-upb tools not built)")
endif()
# install.cmake would install the protoc-gen-* targets that no longer exist; protoc's own install stays.
set(_pinstall "${PROTO_SRC_DIR}/cmake/install.cmake")
if(EXISTS "${_pinstall}")
    file(READ "${_pinstall}" _pi)
    patch_replace_required(_pi [[foreach (generator upb upbdefs)]] [[foreach (generator)]] "protobuf install.cmake: empty the protoc-gen-* generator loop")
    file(WRITE "${_pinstall}" "${_pi}")
    message(STATUS "[LiteRTLM] Patched install.cmake: drop protoc-gen-* install (targets not built)")
endif()
