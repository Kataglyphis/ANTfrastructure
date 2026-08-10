#!/usr/bin/env bash
# Tests for generate_pkgconfig_file (01-core/common.sh) — backlog T5.
#
# Pins the fix for the historical stray-`}` bug: the tempting one-liner
# `libs="${6:--L\${libdir}}"` ends the `:-` default at the FIRST `}`, so the
# emitted Libs line lost `${libdir}`'s closing brace and a stray literal `}`
# landed in the .pc file (the LiteRT tensorflow-lite.pc trailing-brace bug,
# worked around in build-gstreamer-monorepo.sh for years — see the NOTE
# comment above the function). These assertions make that regression loud.
set -u
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${TESTS_DIR}/test-harness.sh"
COMMON_SH="${TESTS_DIR}/../01-core/common.sh"

# Source ONLY the function under test: full common.sh pulls versions.env plus
# five sibling modules at source time (same reason test-cross-fallback-parity
# extracts instead of sourcing). generate_pkgconfig_file is self-contained
# (locals + mkdir + cat), so an awk block extraction is safe.
_fn_src="$(awk '/^generate_pkgconfig_file\(\) \{/,/^\}/' "${COMMON_SH}")"

t_case "generate_pkgconfig_file is extractable from common.sh"
t_assert_contains "${_fn_src}" 'cat >"${pc_path}"' \
  "extraction must capture the whole heredoc body (did the function move?)"
eval "${_fn_src}"

tmpdir="$(mktemp -d)"
trap 'rm -rf "${tmpdir}"' EXIT

# Count '}' characters that are NOT part of a ${var} pkg-config reference —
# the exact artifact the historical bug emitted. Must be 0.
_stray_braces() {
  sed 's/\${[A-Za-z_][A-Za-z_0-9]*}//g' "$1" | grep -n '}' || true
}

# ---------------------------------------------------------------------------
t_case "defaults: Libs/Cflags emitted as UNEXPANDED pkg-config variables"
generate_pkgconfig_file "${tmpdir}/default.pc" testlib "Test library" 1.2.3 /usr/local
t_assert_ok grep -qxF 'Libs: -L${libdir}' "${tmpdir}/default.pc"
t_assert_ok grep -qxF 'Cflags: -I${includedir}' "${tmpdir}/default.pc"
t_assert_ok grep -qxF 'prefix=/usr/local' "${tmpdir}/default.pc"
t_assert_ok grep -qxF 'exec_prefix=${prefix}' "${tmpdir}/default.pc"
t_assert_ok grep -qxF 'libdir=${prefix}/lib' "${tmpdir}/default.pc"
t_assert_ok grep -qxF 'Name: testlib' "${tmpdir}/default.pc"
t_assert_ok grep -qxF 'Version: 1.2.3' "${tmpdir}/default.pc"

t_case "defaults: no stray '}' on any line (the historical :- default bug)"
t_assert_eq "" "$(_stray_braces "${tmpdir}/default.pc")" \
  "a '}' outside a \${var} reference is the tensorflow-lite.pc bug"

t_case "defaults: optional Requires/Libs.private lines are ABSENT"
t_assert_fails grep -q '^Requires:' "${tmpdir}/default.pc"
t_assert_fails grep -q '^Libs\.private:' "${tmpdir}/default.pc"

# ---------------------------------------------------------------------------
t_case "full args: explicit libs/cflags plus Requires and Libs.private lines"
generate_pkgconfig_file "${tmpdir}/full.pc" foo "Foo library" 2.0 /opt/foo \
  '-L${libdir} -lfoo' '-I${includedir}/foo' 'zlib >= 1.2' '-lm -lpthread'
t_assert_ok grep -qxF 'Libs: -L${libdir} -lfoo' "${tmpdir}/full.pc"
t_assert_ok grep -qxF 'Cflags: -I${includedir}/foo' "${tmpdir}/full.pc"
t_assert_ok grep -qxF 'Requires: zlib >= 1.2' "${tmpdir}/full.pc"
t_assert_ok grep -qxF 'Libs.private: -lm -lpthread' "${tmpdir}/full.pc"

t_case "full args: still no stray '}' anywhere"
t_assert_eq "" "$(_stray_braces "${tmpdir}/full.pc")"

t_summary
