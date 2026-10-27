#!/usr/bin/env bash
# Dockerfile.android copies <lib>/android/ one level shallower than the repo, so a relative 01-core source needs its /opt/scripts/core twin; not covered: a source built from variables.
set -u
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${TESTS_DIR}/test-harness.sh"

# _relative_only <build dir>: each Android script and core file it sources only by a relative path.
_relative_only() {
  python3 - "$1" <<'PY'
import pathlib, re, sys
for f in sorted(pathlib.Path(sys.argv[1]).glob("*/android/*.sh")):
    text = f.read_text()
    for leaf in sorted(set(re.findall(r'(?:\.\./)+01-core/([\w.-]+\.sh)', text))):
        if f"/opt/scripts/core/{leaf}" not in text:
            print(f"{f.parent.parent.name}/android/{f.name}: 01-core/{leaf}")
PY
}

t_case "every relative 01-core source in an Android build script also names the image's /opt/scripts/core copy"
t_assert_eq "" "$(_relative_only "${TESTS_DIR}/../03-media/build")" "a relative-only core source fails in the image layout"

t_case "the check sees a relative-only source"
fix="$(mktemp -d)"
mkdir -p "${fix}/demo/android"
# shellcheck disable=SC2016  # the fixture is the literal source line
printf '. "$(dirname "${BASH_SOURCE[0]}")/../../../../01-core/logging.sh"\n' > "${fix}/demo/android/build-android.sh"
t_assert_eq "demo/android/build-android.sh: 01-core/logging.sh" "$(_relative_only "${fix}")"
rm -rf "${fix}"

t_summary
