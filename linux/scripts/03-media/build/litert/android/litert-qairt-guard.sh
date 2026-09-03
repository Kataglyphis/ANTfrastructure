#!/usr/bin/env bash
# Neutralises upstream's unhashed ~1.5 GB QAIRT download.
# docs/qnn-linux.md#no-staged-sdk-upstreams-unhashed-15-gb-download
#
# Under android/ for the same reason as litert-eigen-fetch.sh: Dockerfile.android
# COPYs only that dir, while Dockerfile.media mounts all of litert/. Moving it up
# breaks the android build.
# Sourced by build-litert.sh and android/build-android.sh; never executed.
#
# Logs without info()/warn(): the android stages do not source logging.sh.
_litert_qairt_log() { printf '[%s] %s\n' "$1" "$2" >&2; }

# Upstream's litert/vendors/CMakeLists.txt file(DOWNLOAD)s the QAIRT SDK whenever
# QAIRT_HEADERS_DIR is empty -- ~1.5 GB from softwarecenter.qualcomm.com, with no
# EXPECTED_HASH and no STATUS check, and NOT gated on LITERT_ENABLE_QUALCOMM, so it
# fires even on builds that want no NPU at all. We cannot dodge it by pointing
# QAIRT_HEADERS_DIR at a stub: any non-empty value force-enables Qualcomm (:331-334)
# with headers we do not have. So short-circuit the guard itself.
# Idempotent; the marker comment is the guard. Fails loudly if the anchor moves.
# $1 = LiteRT tree root (default: ${LITERT_SRC}, which the cross lane sets).
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
