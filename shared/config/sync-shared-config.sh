#!/usr/bin/env bash
# Copyright (c) 2025 Kataglyphis
# SPDX-License-Identifier: MIT
#
# Bash twin of Sync-SharedConfig.ps1. Same two manifests, same verdicts, same
# output lines, same exit codes - 0 in sync, 1 MISSING or DRIFTED, 2 broken
# input. It exists because none of the hub's Linux images ship pwsh, so the
# PowerShell script can only ever run on Windows or a hosted runner.
#
# See README.md next to this file for the manifest format and the WHY.

set -euo pipefail

_SSC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_SSC_REGISTRY="${_SSC_DIR}/shared-assets.manifest"
_SSC_HUB_ROOT="$(cd "${_SSC_DIR}/../.." && pwd)"
_SSC_LEGACY_NAMES=(.clang-format .clang-tidy .cmake-format.yaml gcovr.cfg .pre-commit-config.yaml)
# bash 5.3 does not apply ANSI-C quoting to a $'..' that sits inside a ${x%..}
# inside an array-element assignment, so the CR has to live in a variable.
_SSC_CR=$'\r'

declare -a SSC_IDS=()
declare -A SSC_CANONICAL=() SSC_DEFAULT=() SSC_MODE=() SSC_KNOBS=()

_ssc_die() {
    printf '%s\n' "$1" >&2
    exit 2
}

_ssc_trim() {
    local s="$1"
    s="${s#"${s%%[![:space:]]*}"}"
    printf '%s' "${s%"${s##*[![:space:]]}"}"
}

# A manifest data row: not blank, not a '#' comment. Both manifests use this.
_ssc_is_data_row() {
    local s
    s="$(_ssc_trim "$1")"
    [ -n "$s" ] && [ "${s#\#}" = "$s" ]
}

_ssc_join() {
    local out
    out="$(printf '%s, ' "$@")"
    printf '%s' "${out%, }"
}

_ssc_contains() {
    local needle="$1" item
    shift
    for item in "$@"; do
        if [ "$item" = "$needle" ]; then return 0; fi
    done
    return 1
}

# Split a ';'-separated knob field into SSC_KNOB_LIST. No word splitting and no
# globbing: a knob prefix is a literal such as `: "${KATAGLYPHIS_...:=`.
_ssc_split_knobs() {
    local rest="$1" part
    SSC_KNOB_LIST=()
    while [ -n "$rest" ]; do
        part="${rest%%;*}"
        if [ -n "$part" ]; then SSC_KNOB_LIST+=("$part"); fi
        if [ "$part" = "$rest" ]; then break; fi
        rest="${rest#*;}"
    done
}

_ssc_register_row() {
    local id="$1" canon="$2" def="$3" mode="$4" knobs="$5"
    if [ -z "$mode" ] || [ -z "$canon" ] || [ -z "$def" ]; then
        _ssc_die "shared-assets.manifest row '${id}' needs id|canonical|default|mode[|knobs]."
    fi
    case "$mode" in
        exact | body) ;;
        *) _ssc_die "Unknown mode '${mode}' for asset '${id}'." ;;
    esac
    SSC_IDS+=("$id")
    SSC_CANONICAL["$id"]="$canon"
    SSC_DEFAULT["$id"]="$def"
    SSC_MODE["$id"]="$mode"
    SSC_KNOBS["$id"]="$knobs"
}

# The OWNER side: every file this repo is the source of truth for.
ssc_load_registry() {
    if [ ! -f "$_SSC_REGISTRY" ]; then
        _ssc_die "Asset registry '${_SSC_REGISTRY}' is missing; nothing can be checked."
    fi
    local row id canon def mode knobs
    _ssc_read_data_rows "$_SSC_REGISTRY"
    for row in "${SSC_ROWS[@]}"; do
        IFS='|' read -r id canon def mode knobs <<<"$row"
        _ssc_register_row "$(_ssc_trim "$id")" "$(_ssc_trim "${canon:-}")" \
            "$(_ssc_trim "${def:-}")" "$(_ssc_trim "${mode:-}")" "$(_ssc_trim "${knobs:-}")"
    done
}

# A missing CANONICAL file is a defect in THIS repo and has to say so loudly,
# or --check blames the CONSUMER for a file that is actually missing here.
# Scoped to what the consumer DECLARED: an asset nobody takes is nobody's
# failure, which is the same rule this script applies on the consumer side.
ssc_assert_canonical_present() {
    local id
    for id in "${SSC_DECL_ID[@]}"; do
        if [ -e "${_SSC_HUB_ROOT}/${SSC_CANONICAL[$id]}" ]; then continue; fi
        _ssc_die "Canonical file '${SSC_CANONICAL[$id]}' for asset '${id}' is missing from ${_SSC_HUB_ROOT}. Add the file, or remove the row from shared/config/shared-assets.manifest."
    done
}

# Header prose: a blank line, or a comment. '#' covers sh, ps1 and yaml alike.
_ssc_is_prose_line() {
    local s
    s="$(_ssc_trim "$1")"
    [ -z "$s" ] || [ "${s#\#}" != "$s" ]
}

SSC_MASKED=""
_ssc_mask_knobs() {
    local line="$1" knob stripped
    SSC_MASKED="$line"
    if [ ${#SSC_KNOB_LIST[@]} -eq 0 ]; then return 0; fi
    stripped="${line#"${line%%[![:space:]]*}"}"
    for knob in "${SSC_KNOB_LIST[@]}"; do
        if [ "${stripped#"$knob"}" != "$stripped" ]; then
            SSC_MASKED="<knob> ${knob}"
            return 0
        fi
    done
}

_ssc_read_lines() {
    local path="$1" line
    SSC_LINES=()
    while IFS= read -r line || [ -n "$line" ]; do
        SSC_LINES+=("${line%"${_SSC_CR}"}")
    done <"$path"
    # Trailing blank lines are dropped so a file with and without a final
    # newline compare equal - the PowerShell twin's TrimEnd does the same.
    while [ ${#SSC_LINES[@]} -gt 0 ] && [ -z "${SSC_LINES[-1]}" ]; do
        unset 'SSC_LINES[-1]'
    done
}

# Both manifests are read through here: comments and blank lines gone, CR gone.
_ssc_read_data_rows() {
    local line
    _ssc_read_lines "$1"
    SSC_ROWS=()
    for line in "${SSC_LINES[@]}"; do
        if _ssc_is_data_row "$line"; then SSC_ROWS+=("$line"); fi
    done
}

_ssc_first_code_line() {
    local path="$1" first=0
    while [ "$first" -lt ${#SSC_LINES[@]} ] && _ssc_is_prose_line "${SSC_LINES[$first]}"; do
        first=$((first + 1))
    done
    if [ "$first" -ge ${#SSC_LINES[@]} ]; then
        _ssc_die "'${path}' has no code line; a body-mode file cannot be all prose."
    fi
    printf '%s' "$first"
}

# The text the gate actually compares, into SSC_CMP. Line endings normalised; in
# 'body' mode the leading prose is dropped and knob lines are masked.
ssc_comparable() {
    local path="$1" mode="$2" first=0 i joined="" started=0
    _ssc_split_knobs "$3"
    _ssc_read_lines "$path"
    if [ "$mode" = body ]; then first="$(_ssc_first_code_line "$path")"; fi
    for ((i = first; i < ${#SSC_LINES[@]}; i++)); do
        _ssc_mask_knobs "${SSC_LINES[$i]}"
        if [ "$started" -eq 0 ]; then
            joined="$SSC_MASKED"
            started=1
        else
            joined="${joined}"$'\n'"${SSC_MASKED}"
        fi
    done
    SSC_CMP="$joined"
}

# The CONSUMER side: 'id [local-path]' rows into SSC_DECL_ID / SSC_DECL_PATH.
ssc_load_declared() {
    local path="$1" row id local_path known
    SSC_DECL_ID=()
    SSC_DECL_PATH=()
    known="$(_ssc_join "${SSC_IDS[@]}")"
    _ssc_read_data_rows "$path"
    for row in "${SSC_ROWS[@]}"; do
        read -r id local_path <<<"$row"
        if [ -z "${SSC_MODE[$id]:-}" ]; then
            _ssc_die "${path} declares '${id}', which ContainerHub does not own. Known ids: ${known}."
        fi
        SSC_DECL_ID+=("$id")
        SSC_DECL_PATH+=("${local_path:-${SSC_DEFAULT[$id]}}")
    done
}

# No manifest: the five shared/config names at the consumer root, minus --ignore.
ssc_load_legacy() {
    local name id
    SSC_DECL_ID=()
    SSC_DECL_PATH=()
    for name in "${_SSC_LEGACY_NAMES[@]}"; do
        if _ssc_contains "$name" "${SSC_SKIPPED[@]}"; then continue; fi
        for id in "${SSC_IDS[@]}"; do
            if [ "${SSC_DEFAULT[$id]}" != "$name" ]; then continue; fi
            SSC_DECL_ID+=("$id")
            SSC_DECL_PATH+=("$name")
            break
        done
    done
}

# --ignore accepts a comma-separated list, like the PowerShell -Ignore.
ssc_expand_ignore() {
    local rest="$1" head name
    while [ -n "$rest" ]; do
        head="${rest%%,*}"
        name="$(_ssc_trim "$head")"
        if [ -n "$name" ]; then
            if ! _ssc_contains "$name" "${_SSC_LEGACY_NAMES[@]}"; then
                _ssc_die "--ignore names nothing this script manages: ${name}. Valid names: $(_ssc_join "${_SSC_LEGACY_NAMES[@]}")"
            fi
            SSC_SKIPPED+=("$name")
        fi
        if [ "$head" = "$rest" ]; then break; fi
        rest="${rest#*,}"
    done
}

# --write is a verbatim copy, so it only serves 'exact' assets. Splicing a
# canonical body under a consumer's own header while keeping its knob values is
# a merge, not a copy; getting that silently wrong would defeat this gate.
ssc_write_copy() {
    local id="$1" local_rel="$2" canonical="$3" target="$4"
    if [ "${SSC_MODE[$id]}" = body ]; then
        _ssc_die "Cannot --write '${local_rel}': asset '${id}' is body-mode. Copy ${SSC_CANONICAL[$id]} from its first code line down, keeping this repo's header prose and its knob values, then re-run --check."
    fi
    cp -f "$canonical" "$target"
}

# Under --check, file the verdict in <bucket>; under --write, copy instead.
_ssc_verdict_or_write() {
    local bucket="$1" id="$2" local_rel="$3" canonical="$4" target="$5"
    if [ "$SSC_WRITE" -eq 0 ]; then
        local -n _bucket_ref="$bucket"
        _bucket_ref+=("$local_rel")
        return 0
    fi
    ssc_write_copy "$id" "$local_rel" "$canonical" "$target"
    SSC_WRITTEN+=("$local_rel")
}

ssc_compare_one() {
    local id="$1" local_rel="$2" canonical="$3" target="$4" a
    if [ ! -e "$target" ]; then
        _ssc_verdict_or_write SSC_MISSING "$@"
        return 0
    fi
    ssc_comparable "$canonical" "${SSC_MODE[$id]}" "${SSC_KNOBS[$id]}"
    a="$SSC_CMP"
    ssc_comparable "$target" "${SSC_MODE[$id]}" "${SSC_KNOBS[$id]}"
    if [ "$a" = "$SSC_CMP" ]; then
        SSC_OK+=("$local_rel")
        return 0
    fi
    _ssc_verdict_or_write SSC_DRIFTED "$@"
}

_ssc_print_list() {
    local prefix="$1" n
    shift
    for n in "$@"; do printf '  %s %s\n' "$prefix" "$n"; done
}

ssc_report_missing() {
    echo ''
    echo 'DECLARED but not present. Either this repo stopped carrying the file, and its'
    echo 'line leaves the manifest - or the copy was lost and has to be restored.'
}

ssc_report_drifted() {
    echo ''
    echo 'DECLARED and present, but the content differs from the canonical copy.'
    echo 'Edit the file UPSTREAM (in ContainerHub), then refresh here with:'
    echo '  pwsh -File third_party/ContainerHub/shared/config/Sync-SharedConfig.ps1 -RepoRoot . -Write'
    echo '  bash third_party/ContainerHub/shared/config/sync-shared-config.sh --repo-root . --write'
    echo 'If this project genuinely owns the file, drop its line from the manifest instead.'
}

ssc_report() {
    local n
    for n in "${SSC_SKIPPED[@]}"; do printf '  SKIP  %s (project-owned override)\n' "$n"; done
    _ssc_print_list 'WROTE' "${SSC_WRITTEN[@]}"
    if [ "$SSC_WRITE" -eq 1 ]; then
        if [ ${#SSC_WRITTEN[@]} -eq 0 ]; then echo 'Shared config already up to date.'; fi
        return 0
    fi
    _ssc_print_list 'OK     ' "${SSC_OK[@]}"
    _ssc_print_list 'MISSING' "${SSC_MISSING[@]}"
    _ssc_print_list 'DRIFTED' "${SSC_DRIFTED[@]}"
    if [ ${#SSC_MISSING[@]} -gt 0 ]; then ssc_report_missing; fi
    if [ ${#SSC_DRIFTED[@]} -gt 0 ]; then ssc_report_drifted; fi
}

ssc_parse_args() {
    while [ $# -gt 0 ]; do
        case "$1" in
            --repo-root | -RepoRoot) SSC_ROOT="${2:?--repo-root needs a path}"; shift 2 ;;
            --manifest | -Manifest) SSC_MANIFEST="${2:?--manifest needs a path}"; shift 2 ;;
            --ignore | -Ignore) SSC_IGNORE_RAW="${SSC_IGNORE_RAW:+${SSC_IGNORE_RAW},}${2:?--ignore needs a list}"; shift 2 ;;
            --check | -Check) SSC_WRITE=0; shift ;;
            --write | -Write) SSC_WRITE=1; shift ;;
            *) _ssc_die "Unknown argument '$1'. Usage: sync-shared-config.sh --repo-root <path> [--check|--write] [--manifest <path>] [--ignore <names>]" ;;
        esac
    done
    if [ -z "$SSC_ROOT" ]; then _ssc_die 'Missing --repo-root <path>.'; fi
    if [ ! -d "$SSC_ROOT" ]; then _ssc_die "--repo-root '${SSC_ROOT}' is not a directory."; fi
    SSC_ROOT="$(cd "$SSC_ROOT" && pwd)"
}

ssc_resolve_declarations() {
    if [ -z "$SSC_MANIFEST" ] && [ -f "${SSC_ROOT}/.containerhub-shared.manifest" ]; then
        SSC_MANIFEST="${SSC_ROOT}/.containerhub-shared.manifest"
    fi
    if [ -n "$SSC_MANIFEST" ]; then
        if [ ! -f "$SSC_MANIFEST" ]; then _ssc_die "Manifest '${SSC_MANIFEST}' does not exist."; fi
        if [ -n "$SSC_IGNORE_RAW" ]; then
            _ssc_die "--ignore and a manifest cannot be combined: the manifest already says what this repo takes, and a stale --ignore would silently override a declaration. Drop --ignore, or delete ${SSC_MANIFEST}."
        fi
        ssc_load_declared "$SSC_MANIFEST"
        return 0
    fi
    if [ -n "$SSC_IGNORE_RAW" ]; then ssc_expand_ignore "$SSC_IGNORE_RAW"; fi
    ssc_load_legacy
    echo '  NOTE  no consumer manifest; using the legacy -Ignore list.'
}

ssc_main() {
    SSC_ROOT=""
    SSC_MANIFEST=""
    SSC_IGNORE_RAW=""
    SSC_WRITE=0
    SSC_SKIPPED=()
    SSC_OK=()
    SSC_MISSING=()
    SSC_DRIFTED=()
    SSC_WRITTEN=()
    ssc_parse_args "$@"
    ssc_load_registry
    ssc_resolve_declarations
    ssc_assert_canonical_present
    local i id rel
    for i in "${!SSC_DECL_ID[@]}"; do
        id="${SSC_DECL_ID[$i]}"
        rel="${SSC_DECL_PATH[$i]}"
        ssc_compare_one "$id" "$rel" "${_SSC_HUB_ROOT}/${SSC_CANONICAL[$id]}" "${SSC_ROOT}/${rel}"
    done
    ssc_report
    if [ "$SSC_WRITE" -eq 1 ]; then return 0; fi
    if [ ${#SSC_MISSING[@]} -gt 0 ] || [ ${#SSC_DRIFTED[@]} -gt 0 ]; then return 1; fi
    echo 'Shared config in sync.'
    return 0
}

ssc_main "$@"
