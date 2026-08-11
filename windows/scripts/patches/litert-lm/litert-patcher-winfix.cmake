
# [LiteRTLM-winfix dynamic-loading] narrow std::filesystem::path uses for Windows (see
# build-litert-lm-from-source.ps1). setenv is supplied by the Windows <unistd.h> shim.
patch_file_content("${LITERT_SRC_DIR}/core/dynamic_loading.cc" "access(path.c_str(), R_OK)" "access(path.string().c_str(), R_OK)" FALSE)
patch_file_content("${LITERT_SRC_DIR}/core/dynamic_loading.cc" "results.push_back(path);" "results.push_back(path.string());" FALSE)
patch_file_content("${LITERT_SRC_DIR}/core/dynamic_loading.cc" "FindLiteRtSharedLibsHelper(path, lib_pattern, full_match, results)" "FindLiteRtSharedLibsHelper(path.string(), lib_pattern, full_match, results)" FALSE)
message(STATUS "[LiteRTLM-winfix] narrowed std::filesystem::path uses in core/dynamic_loading.cc")

# The C API's SHARED LiteRt.dll (litert_runtime_c_api_shared_lib) is built unconditionally, but
# litert-lm's target map links only the STATIC liblitert_c_api.a, so nothing needs the DLL. Its
# link is broken under clang++/lld-link (GNU --whole-archive/--start-group are ignored and it
# looks for the MSVC-named litert_cc_options.lib). EXCLUDE_FROM_ALL doesn't stop it (litert
# builds the default `all`), so flip it SHARED->STATIC: a static archive of empty.cc records
# its PUBLIC deps only as usage requirements and never links, so the litert_cc_options.lib
# resolution simply doesn't happen. Nothing depends on it, and litert isn't installed
# (INSTALL_COMMAND ""), so the leftover libLiteRt.a is harmless.
patch_file_content("${LITERT_SRC_DIR}/c/CMakeLists.txt" "add_library(litert_runtime_c_api_shared_lib SHARED empty.cc)" "add_library(litert_runtime_c_api_shared_lib STATIC empty.cc)" FALSE)
message(STATUS "[LiteRTLM-winfix] shared LiteRt.dll -> STATIC (avoids lld-link of GNU-named static deps; litert-lm links static c_api)")

# The per-vendor NPU dispatch plugins (dispatch_api_<VENDOR>_so -> LiteRtDispatch_<VENDOR>.dll,
# defined by _litert_add_dispatch_so in vendors/CMakeLists.txt) are SHARED and hit the SAME
# broken lld-link path as LiteRt.dll (GNU --whole-archive/-Wl,-soname ignored; MSVC-named
# litert_cc_options.lib not found). They're runtime-dlopen'd NPU backends, not in litert-lm's
# target map and useless on a Windows desktop (no such NPU). One SHARED->STATIC on the shared
# add_library covers every vendor at once. (The escaped \${TGT}/\${DISPATCH_SRCS} keep the
# literal CMake variable names so string(REPLACE) matches the un-expanded source line.)
patch_file_content("${LITERT_SRC_DIR}/vendors/CMakeLists.txt" "add_library(\${TGT} SHARED \${DISPATCH_SRCS})" "add_library(\${TGT} STATIC \${DISPATCH_SRCS})" FALSE)
message(STATUS "[LiteRTLM-winfix] vendor dispatch LiteRtDispatch_*.dll -> STATIC (NPU plugins unused on Windows)")

# Qualcomm defines its dispatch + compiler-plugin as their OWN explicit SHARED add_library
# (not via the _litert_add_dispatch_so helper), so they need separate SHARED->STATIC patches.
# Both are runtime-dlopen'd NPU plugins, absent from litert-lm's target map, and fail the same
# lld-link path (they link the now-STATIC litert_runtime_c_api_shared_lib and want the
# MSVC-named litert_cc_options.lib). qnn_compiler_plugin is distinct from litert-lm's mapped
# litert::compiler_plugin (the generic static liblitert_compiler_plugin.a), so this is safe.
patch_file_content("${LITERT_SRC_DIR}/vendors/qualcomm/dispatch/CMakeLists.txt" "add_library(dispatch_api_qualcomm_so SHARED)" "add_library(dispatch_api_qualcomm_so STATIC)" FALSE)
patch_file_content("${LITERT_SRC_DIR}/vendors/qualcomm/compiler/CMakeLists.txt" "add_library(qnn_compiler_plugin SHARED" "add_library(qnn_compiler_plugin STATIC" FALSE)
message(STATUS "[LiteRTLM-winfix] Qualcomm dispatch + qnn_compiler_plugin SHARED -> STATIC")

# litert/tools builds standalone exes (run_model, analyze_model, apply_plugin_main) that are
# NOT gated by LITERT_BUILD_TOOLS. They link abseil flags/log/str_format via bare CMake target
# names, which under lld-link leaves those symbols undefined (litert-lm's abseil reaches
# litert_lm_main only through the full-path local_aggregate, not these tools). litert-lm's
# target map wants the tool LIBRARIES (liblitert_apply_plugin.a, etc.), not these exes, so
# EXCLUDE_FROM_ALL them (nothing links an executable, so unlike LiteRt.dll the exclusion holds;
# the install(TARGETS ...) is a no-op since litert's INSTALL_COMMAND is "").
patch_file_content("${LITERT_SRC_DIR}/tools/CMakeLists.txt" "add_executable(run_model" "add_executable(run_model EXCLUDE_FROM_ALL" FALSE)
patch_file_content("${LITERT_SRC_DIR}/tools/CMakeLists.txt" "add_executable(analyze_model" "add_executable(analyze_model EXCLUDE_FROM_ALL" FALSE)
patch_file_content("${LITERT_SRC_DIR}/tools/CMakeLists.txt" "add_executable(apply_plugin_main" "add_executable(apply_plugin_main EXCLUDE_FROM_ALL" FALSE)
message(STATUS "[LiteRTLM-winfix] litert tool exes (run_model/analyze_model/apply_plugin_main) EXCLUDE_FROM_ALL")

# litert @3cb830ad (the bazel-truth pin, staleness-#3 bump) adds
# tensor/examples/{segmentation,gemma3} UNCONDITIONALLY (guarded only by
# `if(EXISTS .../CMakeLists.txt)`, no option); gemma3's CMakeLists does
# find_package(Protobuf REQUIRED) and killed the litert_external CONFIGURE
# (runs 17-20, 2026-08-11). A patch_file_content string-replace of the
# add_subdirectory lines silently NO-OPED (run 20: the message printed but
# gemma3 still configured - the helper's replace never matched). Use the
# upstream guard itself instead: REMOVE the example trees, the EXISTS
# check then skips them - immune to string-form drift.
file(REMOVE_RECURSE "${LITERT_SRC_DIR}/tensor/examples")
if(EXISTS "${LITERT_SRC_DIR}/tensor/examples")
    message(WARNING "[LiteRTLM-winfix] tensor/examples still present after REMOVE_RECURSE - gemma3 will kill the configure")
else()
    message(STATUS "[LiteRTLM-winfix] tensor/examples REMOVED (gemma3's find_package(Protobuf REQUIRED) cannot fire)")
endif()
