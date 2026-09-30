# [LiteRTLM-winfix] rustc emits tokenizers_c.lib, but the non-MSVC branch (compiler id Clang) expects libtokenizers_c.a.
include("${CMAKE_CURRENT_LIST_DIR}/patch-assert.cmake")
file(READ "${TK_SRC}/CMakeLists.txt" _c)
patch_replace_required(_c "libtokenizers_c.a" "tokenizers_c.lib" "tokenizers-cpp: rust staticlib name -> tokenizers_c.lib")
file(WRITE "${TK_SRC}/CMakeLists.txt" "${_c}")
message(STATUS "[LiteRTLM-winfix] tokenizers-cpp rust staticlib name -> tokenizers_c.lib")
