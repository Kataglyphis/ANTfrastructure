
# [LiteRTLM-winfix dynamic-loading] std::filesystem::path is wide on Windows; setenv comes from the <unistd.h> shim.
patch_file_content("${LITERT_SRC_DIR}/core/dynamic_loading.cc" "access(path.c_str(), R_OK)" "access(path.string().c_str(), R_OK)" FALSE)
patch_file_content("${LITERT_SRC_DIR}/core/dynamic_loading.cc" "results.push_back(path);" "results.push_back(path.string());" FALSE)
patch_file_content("${LITERT_SRC_DIR}/core/dynamic_loading.cc" "FindLiteRtSharedLibsHelper(path, lib_pattern, full_match, results)" "FindLiteRtSharedLibsHelper(path.string(), lib_pattern, full_match, results)" FALSE)
message(STATUS "[LiteRTLM-winfix] narrowed std::filesystem::path uses in core/dynamic_loading.cc")

# Nothing needs LiteRt.dll and its lld-link is broken; EXCLUDE_FROM_ALL cannot stop it, so it becomes a static archive.
patch_file_content("${LITERT_SRC_DIR}/c/CMakeLists.txt" "add_library(litert_runtime_c_api_shared_lib SHARED empty.cc)" "add_library(litert_runtime_c_api_shared_lib STATIC empty.cc)" FALSE)
message(STATUS "[LiteRTLM-winfix] shared LiteRt.dll -> STATIC (avoids lld-link of GNU-named static deps; litert-lm links static c_api)")

# The vendor NPU dispatch DLLs hit the same broken link and are unused on Windows; \${TGT} matches the unexpanded line.
patch_file_content("${LITERT_SRC_DIR}/vendors/CMakeLists.txt" "add_library(\${TGT} SHARED \${DISPATCH_SRCS})" "add_library(\${TGT} STATIC \${DISPATCH_SRCS})" FALSE)
message(STATUS "[LiteRTLM-winfix] vendor dispatch LiteRtDispatch_*.dll -> STATIC (NPU plugins unused on Windows)")

# Qualcomm's plugins are their own SHARED add_library calls; qnn_compiler_plugin is not litert-lm's litert::compiler_plugin.
patch_file_content("${LITERT_SRC_DIR}/vendors/qualcomm/dispatch/CMakeLists.txt" "add_library(dispatch_api_qualcomm_so SHARED)" "add_library(dispatch_api_qualcomm_so STATIC)" FALSE)
patch_file_content("${LITERT_SRC_DIR}/vendors/qualcomm/compiler/CMakeLists.txt" "add_library(qnn_compiler_plugin SHARED" "add_library(qnn_compiler_plugin STATIC" FALSE)
message(STATUS "[LiteRTLM-winfix] Qualcomm dispatch + qnn_compiler_plugin SHARED -> STATIC")

# The tool exes ignore LITERT_BUILD_TOOLS and leave abseil undefined under lld-link; only their libraries are needed.
patch_file_content("${LITERT_SRC_DIR}/tools/CMakeLists.txt" "add_executable(run_model" "add_executable(run_model EXCLUDE_FROM_ALL" FALSE)
patch_file_content("${LITERT_SRC_DIR}/tools/CMakeLists.txt" "add_executable(analyze_model" "add_executable(analyze_model EXCLUDE_FROM_ALL" FALSE)
patch_file_content("${LITERT_SRC_DIR}/tools/CMakeLists.txt" "add_executable(apply_plugin_main" "add_executable(apply_plugin_main EXCLUDE_FROM_ALL" FALSE)
message(STATUS "[LiteRTLM-winfix] litert tool exes (run_model/analyze_model/apply_plugin_main) EXCLUDE_FROM_ALL")

# Upstream's if(EXISTS) skips removed examples (gemma3 needs Protobuf); tensor/ sits at the repo root, beside LITERT_SRC_DIR.
get_filename_component(_LITERTLM_REPO_ROOT "${LITERT_SRC_DIR}" DIRECTORY)
file(REMOVE_RECURSE "${_LITERTLM_REPO_ROOT}/tensor/examples")
if(EXISTS "${_LITERTLM_REPO_ROOT}/tensor/examples")
    message(WARNING "[LiteRTLM-winfix] ${_LITERTLM_REPO_ROOT}/tensor/examples still present after REMOVE_RECURSE - gemma3 will kill the configure")
else()
    message(STATUS "[LiteRTLM-winfix] ${_LITERTLM_REPO_ROOT}/tensor/examples REMOVED (gemma3's find_package(Protobuf REQUIRED) cannot fire)")
endif()
