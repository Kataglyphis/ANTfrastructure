
# [LiteRTLM-winfix sentencepiece-fpic] clang's id is not MSVC, so -fPIC lands on windows-msvc; the spm CLI tools cannot link.
include("${CMAKE_CURRENT_LIST_DIR}/patch-assert.cmake")
file(READ "${SENTENCE_SRC_DIR}/src/CMakeLists.txt" _sp_src)
patch_replace_required(_sp_src "-O0 -Wall -fPIC -coverage" "-O0 -Wall -coverage" "sentencepiece: strip -fPIC from the debug flags")
patch_replace_required(_sp_src "-O3 -Wall -fPIC" "-O3 -Wall" "sentencepiece: strip -fPIC from the release flags")
patch_replace_required(_sp_src "add_executable(spm_encode spm_encode_main.cc)" "if(FALSE) # LiteRTLM-winfix: skip unused spm CLI tools (abseil-flags/protobuf link failure)\nadd_executable(spm_encode spm_encode_main.cc)" "sentencepiece: open if(FALSE) around the spm CLI tools")
patch_replace_required(_sp_src "list(APPEND SPM_INSTALLTARGETS" "endif() # LiteRTLM-winfix: end skip spm CLI tools\nif(FALSE) # LiteRTLM-winfix: exclude spm tools from install\nlist(APPEND SPM_INSTALLTARGETS" "sentencepiece: close the tools block and open the install-exclude block")
patch_replace_required(_sp_src "  spm_encode spm_decode spm_normalize spm_train spm_export_vocab)" "  spm_encode spm_decode spm_normalize spm_train spm_export_vocab)\nendif() # LiteRTLM-winfix" "sentencepiece: close the install-exclude block")
file(WRITE "${SENTENCE_SRC_DIR}/src/CMakeLists.txt" "${_sp_src}")
message(STATUS "[LiteRTLM] Patched sentencepiece src/CMakeLists.txt: stripped -fPIC + skipped spm CLI tools")

# [LiteRTLM-winfix] absl_log_flags already defines minloglevel; the duplicate aborts litert_lm_main.exe on every run.
file(READ "${SENTENCE_SRC_DIR}/src/error.cc" _sp_err)
patch_regex_replace_required(_sp_err "ABSL_FLAG\\(int32, minloglevel, 0,[^;]*;" "/* [LiteRTLM-winfix] dropped duplicate ABSL_FLAG(minloglevel); abseil absl_log_flags provides it (ODR fix) */" "sentencepiece error.cc: drop the duplicate ABSL_FLAG(minloglevel) -- THE fix for the litert_lm_main.exe startup ODR abort")
file(WRITE "${SENTENCE_SRC_DIR}/src/error.cc" "${_sp_err}")
message(STATUS "[LiteRTLM] Patched sentencepiece error.cc: dropped duplicate ABSL_FLAG(minloglevel) -> fixes abseil flag ODR abort")
