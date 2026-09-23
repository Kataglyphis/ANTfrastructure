#!/usr/bin/env bash
# gst-onnx-ort.sh - gst-plugins-bad's onnx plugin compiles and links the chain ONNX Runtime only.
# Source-only (build-gstreamer-monorepo.sh), read off meson's build.ninja. NOT covered: run time.

# _gst_onnx_ninja_tokens <build.ninja> <output-regex>: one token per line of every statement
# (build line + indented variables) whose first output matches.
_gst_onnx_ninja_tokens() {
    GST_ONNX_RE="$2" awk '
        /^build / { o = $2; sub(/:$/, "", o); p = (o ~ ENVIRON["GST_ONNX_RE"]) }
        /^[^ ]/ && !/^build / { p = 0 }
        p { for (i = 1; i <= NF; i++) print $i }
    ' "$1" || true
}

# _gst_onnx_abs <path> <builddir>: <path> made absolute against meson's builddir, then resolved.
_gst_onnx_abs() {
    case "$1" in
        /*) readlink -f -- "$1" 2>/dev/null || true ;;
        *) readlink -f -- "$2/$1" 2>/dev/null || true ;;
    esac
}

# _gst_onnx_under <real> <root>...: 0 when <real> is one of the resolved roots or sits inside one.
_gst_onnx_under() {
    local real="$1" r
    shift
    for r in "$@"; do
        [ -n "${r}" ] || continue
        case "${real}" in "${r}"|"${r}"/*) return 0 ;; esac
    done
    return 1
}

# _gst_onnx_search <name> <builddir> <dir>...: the first dir that holds <name>, like ld's -L walk.
_gst_onnx_search() {
    local name="$1" bdir="$2" d
    shift 2
    for d in "$@"; do
        [ -n "${d}" ] || continue
        if [ -e "$(_gst_onnx_abs "${d}" "${bdir}")/${name}" ]; then
            _gst_onnx_abs "${d}/${name}" "${bdir}"
            return 0
        fi
    done
    return 0
}

# _gst_onnx_lib_findings <tokens> <builddir> <lib-root>...: every ORT library the link names, by path
# or by -l through -L then LIBRARY_PATH, must resolve into a chain lib dir; at least one must exist.
_gst_onnx_lib_findings() {
    local toks="$1" bdir="$2" t real refs=0 name prev=""
    shift 2
    local -a ldirs=() lpath=()
    while IFS= read -r t; do
        case "${prev}" in -L) ldirs+=("${t}") ;; esac
        case "${t}" in -L?*) ldirs+=("${t#-L}") ;; esac
        prev="${t}"
    done <<< "${toks}"
    IFS=':' read -r -a lpath <<< "${LIBRARY_PATH:-}"
    while IFS= read -r t; do
        name=""
        case "${t}" in
            -lonnxruntime) name="libonnxruntime.so" ;;
            -l:libonnxruntime*) name="${t#-l:}" ;;
            -*) continue ;;
            *libonnxruntime*.so*|*libonnxruntime*.a) real="$(_gst_onnx_abs "${t}" "${bdir}")" ;;
            *) continue ;;
        esac
        [ -z "${name}" ] || real="$(_gst_onnx_search "${name}" "${bdir}" "${ldirs[@]}" "${lpath[@]}")"
        refs=$((refs + 1))
        _gst_onnx_under "${real}" "$@" || echo "LIB ${t} -> '${real:-unresolved}' is not a chain ORT"
    done <<< "${toks}"
    [ "${refs}" -gt 0 ] || echo "LIB libgstonnx.so names no ONNX Runtime library at all"
}

# _gst_onnx_header_findings <tokens> <builddir> <include-root>...: every -I/-isystem/-idirafter dir
# that holds onnxruntime_c_api.h must be a chain include dir; at least one must.
_gst_onnx_header_findings() {
    local toks="$1" bdir="$2" t d prev="" hits=0
    shift 2
    while IFS= read -r t; do
        d=""
        case "${prev}" in -I|-isystem|-idirafter) d="${t}" ;; esac
        case "${t}" in -I?*) d="${t#-I}" ;; -isystem?*) d="${t#-isystem}" ;; -idirafter?*) d="${t#-idirafter}" ;; esac
        prev="${t}"
        [ -n "${d}" ] && [ -e "$(_gst_onnx_abs "${d}" "${bdir}")/onnxruntime_c_api.h" ] || continue
        hits=$((hits + 1))
        _gst_onnx_under "$(_gst_onnx_abs "${d}" "${bdir}")" "$@" \
            || echo "HDR ${d} provides onnxruntime_c_api.h but is not a chain include dir"
    done <<< "${toks}"
    [ "${hits}" -gt 0 ] || echo "HDR no include dir of the onnx plugin provides onnxruntime_c_api.h"
}

# gst_onnx_ort_findings <build.ninja> <builddir> <chain-root>...: one line per way the onnx plugin
# reaches an ORT outside the chain roots; no output = chain only. NOT covered: what loads at run time.
gst_onnx_ort_findings() {
    local ninja="$1" bdir="$2" r link comp
    shift 2
    local -a libs=() incs=()
    for r in "$@"; do
        libs+=("$(readlink -f -- "${r}/lib" 2>/dev/null || true)")
        incs+=("$(readlink -f -- "${r}/include" 2>/dev/null || true)")
    done
    [ -f "${ninja}" ] || { echo "no ${ninja}"; return 0; }
    link="$(_gst_onnx_ninja_tokens "${ninja}" '(^|/)libgstonnx\.so$')"
    comp="$(_gst_onnx_ninja_tokens "${ninja}" 'libgstonnx\.so\.p/[^/]*\.o$')"
    [ -n "${link}" ] || { echo "no link statement for libgstonnx.so in ${ninja}"; return 0; }
    [ -n "${comp}" ] || { echo "no compile statement for libgstonnx.so in ${ninja}"; return 0; }
    _gst_onnx_lib_findings "${link}" "${bdir}" "${libs[@]}"
    _gst_onnx_header_findings "${comp}" "${bdir}" "${incs[@]}"
}
