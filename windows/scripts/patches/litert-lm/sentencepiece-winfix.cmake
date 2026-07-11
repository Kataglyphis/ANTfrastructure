
# [LiteRTLM-winfix sentencepiece-fpic] clang++ targets x86_64-pc-windows-msvc but its
# compiler id is Clang (not MSVC), so sentencepiece's `if(NOT MSVC)` branch injects -fPIC,
# a hard error on the windows-msvc target. Strip it (PIC is meaningless on Windows).
# Also skip the spm_* CLI tools (spm_encode/decode/normalize/train/export_vocab +
# compile_charsmap): litert-lm only needs the sentencepiece-static library, and those
# standalone executables fail to link abseil-flags/protobuf under clang++/lld-link. Wrap
# the exe region and its install-append each in if(FALSE); the library + its install stay.
file(READ "${SENTENCE_SRC_DIR}/src/CMakeLists.txt" _sp_src)
string(REPLACE "-O0 -Wall -fPIC -coverage" "-O0 -Wall -coverage" _sp_src "${_sp_src}")
string(REPLACE "-O3 -Wall -fPIC" "-O3 -Wall" _sp_src "${_sp_src}")
string(REPLACE "add_executable(spm_encode spm_encode_main.cc)" "if(FALSE) # LiteRTLM-winfix: skip unused spm CLI tools (abseil-flags/protobuf link failure)\nadd_executable(spm_encode spm_encode_main.cc)" _sp_src "${_sp_src}")
string(REPLACE "list(APPEND SPM_INSTALLTARGETS" "endif() # LiteRTLM-winfix: end skip spm CLI tools\nif(FALSE) # LiteRTLM-winfix: exclude spm tools from install\nlist(APPEND SPM_INSTALLTARGETS" _sp_src "${_sp_src}")
string(REPLACE "  spm_encode spm_decode spm_normalize spm_train spm_export_vocab)" "  spm_encode spm_decode spm_normalize spm_train spm_export_vocab)\nendif() # LiteRTLM-winfix" _sp_src "${_sp_src}")
file(WRITE "${SENTENCE_SRC_DIR}/src/CMakeLists.txt" "${_sp_src}")
message(STATUS "[LiteRTLM] Patched sentencepiece src/CMakeLists.txt: stripped -fPIC + skipped spm CLI tools")

# [LiteRTLM-winfix] sentencepiece's src/error.cc defines ABSL_FLAG(int32, minloglevel, ...)
# under _USE_EXTERNAL_ABSL as a "naive workaround" assuming external abseil does not provide
# it. But litert-lm links abseil's FULL absl_log_flags.lib, which DOES define minloglevel, so
# the two collide: duplicate FLAGS_minloglevel / FLAGS_nominloglevel are both registered at
# static init and abseil aborts EVERY invocation ("Inconsistency between flag object and
# registration for flag 'minloglevel'"). /FORCE:MULTIPLE hides it at link time, so it only
# surfaces at runtime. Drop sentencepiece's duplicate ([^;]* spans the two-line statement,
# eol-agnostic) so abseil's definition stands alone; litert_lm_main still links absl_log_flags
# so the symbol resolves. This is THE fix for the litert_lm_main.exe startup ODR abort.
file(READ "${SENTENCE_SRC_DIR}/src/error.cc" _sp_err)
string(REGEX REPLACE "ABSL_FLAG\\(int32, minloglevel, 0,[^;]*;" "/* [LiteRTLM-winfix] dropped duplicate ABSL_FLAG(minloglevel); abseil absl_log_flags provides it (ODR fix) */" _sp_err "${_sp_err}")
file(WRITE "${SENTENCE_SRC_DIR}/src/error.cc" "${_sp_err}")
message(STATUS "[LiteRTLM] Patched sentencepiece error.cc: dropped duplicate ABSL_FLAG(minloglevel) -> fixes abseil flag ODR abort")
