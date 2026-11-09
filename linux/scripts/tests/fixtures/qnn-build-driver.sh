#!/usr/bin/env bash
# Keep retry failures observable without invoking a compiler or the network.
set -euo pipefail
case "${!#}" in
  --update)
    printf 'update\n' >> "${QNN_FIXTURE_RUN}/updates"
    attempt="$(wc -l < "${QNN_FIXTURE_RUN}/updates")"
    printf '%s\0' "$@" > "${QNN_FIXTURE_RUN}/update-argv"
    printf 'configure attempt %s\n' "${attempt}"
    printf 'fetch diagnostic %s\n' "${attempt}" >&2
    if [ "${attempt}" -le "${QNN_FIXTURE_FAIL_UNTIL}" ]; then exit "${QNN_FIXTURE_STATUS}"; fi
    ;;
  --build)
    printf 'build\n' >> "${QNN_FIXTURE_RUN}/builds"
    printf 'build invocation\n'
    exit "${QNN_FIXTURE_BUILD_STATUS}"
    ;;
  *) exit 99 ;;
esac
exit 0
