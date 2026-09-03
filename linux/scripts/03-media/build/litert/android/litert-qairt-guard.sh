#!/usr/bin/env bash
# Neutralises upstream's unhashed ~1.5 GB QAIRT download. Sourced by both LiteRT
# lanes; under android/ because Dockerfile.android COPYs only that dir.
# docs/qnn-linux.md#no-staged-sdk-upstreams-unhashed-15-gb-download

# Android stages do not source logging.sh.
_litert_qairt_log() { printf '[%s] %s\n' "$1" "$2" >&2; }

# $1 = LiteRT tree root (default ${LITERT_SRC}). Idempotent; the marker is the guard.
_litert_disable_qairt_header_download() {
    local tree="${1:-${LITERT_SRC:-}}"
    local vendors="${tree}/litert/vendors/CMakeLists.txt"
    [ -f "${vendors}" ] || { _litert_qairt_log WARN "QAIRT download patch: ${vendors} not found -- upstream layout moved"; return 0; }
    if grep -q 'KATAGLYPHIS-NO-QAIRT-DOWNLOAD' "${vendors}"; then return 0; fi
    python3 - "${vendors}" <<'PY'
import re, sys
p = sys.argv[1]
s = open(p, encoding='utf-8').read()
needle = 'if(NOT QAIRT_HEADERS_DIR)'
if needle not in s:
    sys.exit("QAIRT download patch: anchor 'if(NOT QAIRT_HEADERS_DIR)' not found -- upstream changed")
s = s.replace(needle,
    '# KATAGLYPHIS-NO-QAIRT-DOWNLOAD: no staged SDK, so skip upstream\'s unhashed\n'
    '# ~1.5 GB file(DOWNLOAD) of QAIRT from softwarecenter.qualcomm.com. Qualcomm\n'
    '# dispatch stays OFF because QAIRT_HEADERS_DIR is never set.\n'
    'if(FALSE)', 1)
open(p, 'w', encoding='utf-8', newline='').write(s)
PY
    _litert_qairt_log INFO "LiteRT: no QAIRT SDK staged -- upstream's unhashed QAIRT download disabled (Qualcomm dispatch OFF)"
}
