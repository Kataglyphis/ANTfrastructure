# [LiteRTLM-winfix] rustc builds the crate for x86_64-pc-windows-msvc and emits
# tokenizers_c.lib, but tokenizers-cpp's CMakeLists picks libtokenizers_c.a in its
# non-MSVC branch (our C++ compiler id is Clang), so its copy step can't find the output.
include("${CMAKE_CURRENT_LIST_DIR}/patch-assert.cmake")
file(READ "${TK_SRC}/CMakeLists.txt" _c)
patch_replace_required(_c "libtokenizers_c.a" "tokenizers_c.lib" "tokenizers-cpp: rust staticlib name -> tokenizers_c.lib")
file(WRITE "${TK_SRC}/CMakeLists.txt" "${_c}")
message(STATUS "[LiteRTLM-winfix] tokenizers-cpp rust staticlib name -> tokenizers_c.lib")
