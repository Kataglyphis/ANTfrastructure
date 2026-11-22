#!/usr/bin/env bash
# Imports stay in the entry shell so module declarations and compiler setup keep their caller scope.
source "${SCRIPT_DIR}/../../core/common.sh" || return
media_common_init "${SCRIPT_DIR}" || return
source_module cross-gcc.sh || return
declare -F gcc_toolchain_resolve_prefix >/dev/null || { printf 'Missing GCC toolchain resolver\n' >&2; return 1; }
source "${SCRIPT_DIR}/source-common.sh"
