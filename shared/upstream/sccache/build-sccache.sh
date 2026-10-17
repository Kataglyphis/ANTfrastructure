#!/usr/bin/env bash
# Builds the hub's sccache (upstream at SCCACHE_SOURCE_REV + patches/) for one target into OUT_DIR, upstream's archive layout: README.md
set -euo pipefail

TARGET="${1:?usage: build-sccache.sh <rust-target> <out-dir>}"
OUT_DIR="${2:?usage: build-sccache.sh <rust-target> <out-dir>}"
mkdir -p "${OUT_DIR}"
OUT_DIR="$(cd "${OUT_DIR}" && pwd)"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../../../linux/scripts/01-core/load-versions-env.sh
source "${HERE}/../../../linux/scripts/01-core/load-versions-env.sh"
load_versions_env "${HERE}/../../../linux/scripts/01-core/versions.env"

: "${SCCACHE_SOURCE_REPO:?versions.env names no SCCACHE_SOURCE_REPO}"
: "${SCCACHE_SOURCE_REV:?versions.env names no SCCACHE_SOURCE_REV}"
: "${SCCACHE_BUILD_ID:?versions.env names no SCCACHE_BUILD_ID}"
WORK="${SCCACHE_BUILD_WORK:-$(mktemp -d)}"
SRC="${WORK}/sccache"

rm -rf "${SRC}"
git init -q "${SRC}"
git -C "${SRC}" fetch -q --depth 1 "${SCCACHE_SOURCE_REPO}" "${SCCACHE_SOURCE_REV}"
git -C "${SRC}" -c advice.detachedHead=false checkout -q FETCH_HEAD
# git am keeps each patch's upstream author; the identity only signs the applying commits.
git -C "${SRC}" -c user.name=ANTfrastructure -c user.email=noreply@kataglyphis.invalid am -q "${HERE}"/patches/*.patch

# The build says which one it is: sccache --version prints 0.18.0+<rev>.<patches>.
upstream="$(sed -n 's/^version = "\(.*\)"$/\1/p' "${SRC}/Cargo.toml" | head -n 1)"
stamp="${upstream}+${SCCACHE_BUILD_ID#"${upstream}"-}"
stamp="${stamp//-/.}"
sed -i "0,/^version = \"${upstream}\"$/s//version = \"${stamp}\"/" "${SRC}/Cargo.toml"
# Cargo.lock repeats the package's version; --locked refuses a stale one. Git Bash's python3 can be the Store stub.
py=python3
"${py}" -c pass 2>/dev/null || py=python
"${py}" - "${SRC}/Cargo.lock" "${upstream}" "${stamp}" <<'EOF'
import re, sys
path, old, new = sys.argv[1:]
text = open(path).read()
text, n = re.subn(r'(\[\[package\]\]\nname = "sccache"\nversion = )"%s"' % re.escape(old), r'\1"%s"' % new, text)
if n != 1:
    sys.exit("Cargo.lock: expected one sccache package entry at %s, found %d" % (old, n))
open(path, "w").write(text)
EOF

cargo build --manifest-path "${SRC}/Cargo.toml" --release --locked --target "${TARGET}"

case "${TARGET}" in *windows*) exe=sccache.exe ext=zip ;; *) exe=sccache ext=tar.gz ;; esac
name="sccache-v${SCCACHE_BUILD_ID}-${TARGET}"
mkdir -p "${WORK}/${name}"
cp "${SRC}/target/${TARGET}/release/${exe}" "${SRC}/LICENSE" "${SRC}/README.md" "${WORK}/${name}/"
if [ "${ext}" = zip ]; then
  (cd "${WORK}" && 7z a -tzip -bd "${OUT_DIR}/${name}.zip" "${name}" >/dev/null)
else
  tar -C "${WORK}" -czf "${OUT_DIR}/${name}.tar.gz" "${name}"
fi
printf 'built %s/%s.%s (%s)\n' "${OUT_DIR}" "${name}" "${ext}" "${stamp}"
