# Macros, not functions, so they assign the caller's variable; see docs/windows-build-invariants.md § Never rewrite upstream sources with a bare string(REPLACE)

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
