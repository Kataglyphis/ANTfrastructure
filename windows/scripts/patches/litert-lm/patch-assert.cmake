# Backlog #56: replace-with-verification for the LiteRT-LM source patchers.
#
# WHY THIS EXISTS
# ---------------
# The patchers in this directory rewrite upstream sources with bare
# string(REPLACE ...) and then unconditionally print "Patched ...". If upstream
# reformats the text a pattern targets, the replace silently does NOTHING, the
# success message still prints, and the defect the patch existed to fix comes
# back — after a full media-litert build.
#
# That is not hypothetical. sentencepiece's duplicate ABSL_FLAG(minloglevel)
# collides with abseil's own definition and makes litert_lm_main.exe abort on
# EVERY invocation; /FORCE:MULTIPLE hides it at link time so it only surfaces at
# runtime. The exe was link-clean and unusable. A silently no-op'd regex would
# restore exactly that, while the log kept claiming "fixes abseil flag ODR abort".
#
# These are MACROS, not functions: they assign to the caller's variable, and a
# CMake function would need PARENT_SCOPE gymnastics for every call site.
#
# Use *_required when the patch MUST apply (the normal case — a no-op means the
# build is shipping a known-broken artifact). Use *_optional only when upstream
# legitimately may or may not carry the text, and say why at the call site.

macro(patch_replace_required _pa_var _pa_match _pa_replacement _pa_label)
    set(_pa_before "${${_pa_var}}")
    string(REPLACE "${_pa_match}" "${_pa_replacement}" ${_pa_var} "${${_pa_var}}")
    if(_pa_before STREQUAL "${${_pa_var}}")
        message(FATAL_ERROR
            "[patch-assert] NO-OP: ${_pa_label}\n"
            "  The literal below was not found, so the patch did nothing. Upstream almost\n"
            "  certainly changed the text. Do NOT ignore this: the build would otherwise\n"
            "  succeed and ship the defect this patch exists to fix.\n"
            "  Searched for: ${_pa_match}")
    endif()
endmacro()

macro(patch_regex_replace_required _pa_var _pa_regex _pa_replacement _pa_label)
    set(_pa_before "${${_pa_var}}")
    string(REGEX REPLACE "${_pa_regex}" "${_pa_replacement}" ${_pa_var} "${${_pa_var}}")
    if(_pa_before STREQUAL "${${_pa_var}}")
        message(FATAL_ERROR
            "[patch-assert] NO-OP: ${_pa_label}\n"
            "  The regex below matched nothing, so the patch did nothing. Upstream almost\n"
            "  certainly reformatted the statement.\n"
            "  Pattern: ${_pa_regex}")
    endif()
endmacro()
