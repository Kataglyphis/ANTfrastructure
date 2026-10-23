#!/usr/bin/env bash
# Source in the driver so positional arguments and scope retain their original shell.
# shellcheck source=lint-root.sh
. "${REPO_ROOT}/linux/scripts/01-core/lint-root.sh" || return 1
lint_scope_begin SCAN_ROOT "${REPO_ROOT}" "$@" || exit 1
set -- ${LINT_ROOT_REST[@]+"${LINT_ROOT_REST[@]}"}
