# [LiteRTLM-winfix] rustc builds the crate for x86_64-pc-windows-msvc and emits
# tokenizers_c.lib, but tokenizers-cpp's CMakeLists picks libtokenizers_c.a in its
# non-MSVC branch (our C++ compiler id is Clang), so its copy step can't find the output.
file(READ "${TK_SRC}/CMakeLists.txt" _c)
string(REPLACE "libtokenizers_c.a" "tokenizers_c.lib" _c "${_c}")
file(WRITE "${TK_SRC}/CMakeLists.txt" "${_c}")
message(STATUS "[LiteRTLM-winfix] tokenizers-cpp rust staticlib name -> tokenizers_c.lib")
