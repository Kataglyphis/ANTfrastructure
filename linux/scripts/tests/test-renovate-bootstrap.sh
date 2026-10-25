#!/usr/bin/env bash
# Stubbed registry/install proves preflight order and failure handling; real npm resolution and runtime need a live smoke.
set -u
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${TESTS_DIR}/test-harness.sh"
SCRIPTS="$(cd "${TESTS_DIR}/.." && pwd)"
LOCK="${SCRIPTS}/renovate-npm/package-lock.json"

w="$(mktemp -d)"
trap 'rm -rf "${w}"' EXIT
mkdir -p "${w}/bin" "${w}/repo"
git -C "${w}/repo" init -q
want="$(sed -n 's/^RENOVATE_VERSION=//p' "${SCRIPTS}/01-core/tool-pins.env")"
export STUB_RENOVATE_LATEST="${want}" STUB_NPM_LOG="${w}/npm.log"
export STUB_BOOTSTRAP_PY="${SCRIPTS}/renovate_bootstrap.py"
export STUB_CI_FAIL=0 STUB_INSTALL_FAIL=0 STUB_LOCK_BAD=0 STUB_VIEW_FAIL=0 STUB_VIEW_INVALID=0
: > "${STUB_NPM_LOG}"

cat > "${w}/bin/node" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = --version ]; then
  if [ "$0" = "$(dirname "${STUB_NPM_LOG}")/bin/node" ] && [ -s "$(dirname "${STUB_NPM_LOG}")/old-node-version" ]; then
    cat "$(dirname "${STUB_NPM_LOG}")/old-node-version"
  else
    printf 'v24.21.0\n'
  fi
  exit 0
fi
if [ "${2:-}" = --version ]; then
  sed -n 's/.*"version": "\([^"]*\)".*/\1/p' "$(dirname "$1")/../package.json"
  exit 0
fi
exit 3
SH
cat > "${w}/bin/npm" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${STUB_NPM_LOG}"
case "$1" in
  --version) printf '11.0.0\n' ;;
  view)
    [ "$(node --version)" != v24.0.0 ] || exit 9
    [ "${STUB_VIEW_FAIL:-0}" = 0 ] || exit 4
    if [ "${STUB_VIEW_INVALID:-0}" = 1 ]; then printf 'invalid json\n'; else printf '"%s"\n' "${STUB_RENOVATE_LATEST}"; fi
    ;;
  install)
    [ "${STUB_INSTALL_FAIL:-0}" = 0 ] || exit 5
    version="$(python3 "${STUB_BOOTSTRAP_PY}" manifest-version package.json)" || exit 9
    integrity=sha512-stub
    [ "${STUB_LOCK_BAD:-0}" = 1 ] && integrity=""
    printf '{"packages":{"node_modules/renovate":{"version":"%s","integrity":"%s"}}}\n' \
      "${version}" "${integrity}" > package-lock.json
    ;;
  ci)
    [ "${STUB_CI_FAIL:-0}" = 0 ] || exit 6
    [ -f package.json ] && [ -f package-lock.json ] || exit 7
    version="$(python3 "${STUB_BOOTSTRAP_PY}" lock-version package-lock.json)" || exit 9
    mkdir -p node_modules/renovate/dist
    printf '{"version": "%s"}\n' "${version}" > node_modules/renovate/package.json
    : > node_modules/renovate/dist/renovate.js
    printf 'added 1 package\n'
    ;;
  *) exit 8 ;;
esac
SH
chmod +x "${w}/bin/node" "${w}/bin/npm"

printf 'stub node archive\n' > "${w}/node.tar.xz"
export STUB_NODE_ARCHIVE="${w}/node.tar.xz" STUB_GOOD_NODE="${w}/bin/node" STUB_GOOD_NPM="${w}/bin/npm"
cat > "${w}/bin/curl" <<'SH'
#!/usr/bin/env bash
while [ "$#" -gt 0 ]; do
  if [ "$1" = -o ]; then cp "${STUB_NODE_ARCHIVE}" "$2"; exit; fi
  shift
done
exit 9
SH
cat > "${w}/bin/tar" <<'SH'
#!/usr/bin/env bash
while [ "$#" -gt 0 ]; do
  if [ "$1" = -C ]; then target="$2"; break; fi
  shift
done
[ -n "${target:-}" ] || exit 9
mkdir -p "${target}/bin"
cp "${STUB_GOOD_NODE}" "${target}/bin/node"
[ "${STUB_TAR_FAIL:-0}" = 0 ] || exit 8
cp "${STUB_GOOD_NPM}" "${target}/bin/npm"
SH
chmod +x "${w}/bin/curl" "${w}/bin/tar"

print_bin() {
  (cd "${w}/repo" && env -u RENOVATE_VERSION PATH="${w}/bin:${PATH}" RENOVATE_LOCAL_CACHE="${w}/cache" "$@" \
    bash "${SCRIPTS}/renovate-local.sh" --print-bin > "${w}/out" 2> "${w}/err")
}
npm_count() { grep -c "^$1 " "${STUB_NPM_LOG}" || true; }

t_case "the committed lock installs the pinned Renovate with npm ci after a latest check"
t_assert_eq "${want}" "$(tr -d '\r' < "${LOCK}" | sed -n '/"node_modules\/renovate": {/{n;s/.*"version": "\([^"]*\)".*/\1/p;}')"
t_assert_ok print_bin
prefix="${w}/cache/renovate-${want}-$(sha256sum "${LOCK}" | cut -c1-12)"
t_assert_eq "${prefix}/node_modules/renovate/dist/renovate.js" "$(cat "${w}/out")"
t_assert_eq 1 "$(npm_count view)"
t_assert_eq 0 "$(npm_count install)"
t_assert_eq 1 "$(npm_count ci)"
t_assert_eq "" "$(cmp "${LOCK}" "${prefix}/package-lock.json" 2>&1)" "the committed lock stays byte-identical"

t_case "a second invocation checks latest again and reuses the verified installed version"
t_assert_ok print_bin
t_assert_eq 2 "$(npm_count view)"
t_assert_eq 1 "$(npm_count ci)"

t_case "a newer dist-tag gets its own integrity lock and installs before Renovate runs"
newer=44.999.1
t_assert_ok print_bin STUB_RENOVATE_LATEST="${newer}"
new_prefix="${w}/cache/renovate-${newer}-$(sha256sum "${SCRIPTS}/renovate-npm/package.json" | cut -c1-12)"
t_assert_eq "${new_prefix}/node_modules/renovate/dist/renovate.js" "$(cat "${w}/out")"
t_assert_eq "${newer}" "$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["dependencies"]["renovate"])' "${new_prefix}/package.json")"
t_assert_eq "15.0.3" "$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["overrides"]["markdown-it"])' "${new_prefix}/package.json")"
t_assert_eq 1 "$(npm_count install)"
t_assert_eq 2 "$(npm_count ci)"
t_assert_eq "" "$(git -C "${w}/repo" status --porcelain)" "the target tree stays read-only"
t_assert_ok print_bin STUB_RENOVATE_LATEST="${newer}"
t_assert_eq 1 "$(npm_count install)"
t_assert_eq 2 "$(npm_count ci)"

t_case "a registry failure or invalid latest response prevents install and scanning"
t_assert_fails print_bin STUB_VIEW_FAIL=1
t_assert_contains "$(cat "${w}/err")" "cannot check npm's latest Renovate version"
t_assert_fails print_bin STUB_VIEW_INVALID=1
t_assert_contains "$(cat "${w}/err")" "invalid latest Renovate version"
t_assert_eq 1 "$(npm_count install)"
t_assert_eq 2 "$(npm_count ci)"

t_case "a failed update leaves no published cache and succeeds on retry"
failed=44.999.2
t_assert_fails print_bin STUB_RENOVATE_LATEST="${failed}" STUB_CI_FAIL=1
failed_prefix="${w}/cache/renovate-${failed}-$(sha256sum "${SCRIPTS}/renovate-npm/package.json" | cut -c1-12)"
t_assert_fails test -e "${failed_prefix}"
t_assert_contains "$(cat "${w}/err")" "npm ci of renovate@${failed} failed"
t_assert_ok print_bin STUB_RENOVATE_LATEST="${failed}"
t_assert_eq "${failed_prefix}/node_modules/renovate/dist/renovate.js" "$(cat "${w}/out")"

t_case "a lock without integrity is refused before npm ci"
before="$(npm_count ci)"
t_assert_fails print_bin STUB_RENOVATE_LATEST=44.999.3 STUB_LOCK_BAD=1
t_assert_contains "$(cat "${w}/err")" "with integrity"
t_assert_eq "${before}" "$(npm_count ci)"

t_case "an installed version mismatch is repaired from the locked cache recipe"
python3 - "${new_prefix}/node_modules/renovate/package.json" <<'PY'
import json
import sys

with open(sys.argv[1], "w", encoding="utf-8") as target:
    json.dump({"version": "0.0.0"}, target)
PY
before="$(npm_count ci)"
t_assert_ok print_bin STUB_RENOVATE_LATEST="${newer}"
t_assert_eq "$((before + 1))" "$(npm_count ci)"

t_case "a prerelease latest tag is accepted, but path characters are rejected"
prerelease=45.0.0-rc.1+meta.2
t_assert_ok print_bin STUB_RENOVATE_LATEST="${prerelease}"
t_assert_contains "$(cat "${w}/out")" "renovate-${prerelease}-"
t_assert_fails print_bin STUB_RENOVATE_LATEST=45.0.0/escape
t_assert_contains "$(cat "${w}/err")" "invalid latest Renovate version"

t_case "a mismatched committed pin still refuses before npm is consulted"
before="$(wc -l < "${STUB_NPM_LOG}" | tr -d ' ')"
t_assert_fails print_bin RENOVATE_VERSION=0.0.1
t_assert_contains "$(cat "${w}/err")" "installs renovate ${want}, tool-pins.env pins 0.0.1"
t_assert_eq "${before}" "$(wc -l < "${STUB_NPM_LOG}" | tr -d ' ')"
t_case "Node below the pinned minor release falls back to the verified cached toolchain"
cached_node="${w}/cache/node-24.21.0"
mkdir -p "${cached_node}/bin"
cp "${STUB_GOOD_NODE}" "${cached_node}/bin/node"
cp "${STUB_GOOD_NPM}" "${cached_node}/bin/npm"
printf 'v24.0.0\n' > "${w}/old-node-version"
t_assert_ok print_bin
t_assert_ok test -x "${cached_node}/bin/npm"

t_case "an interrupted Node extraction leaves no stage and a partial cache is repaired"
rm -f "${cached_node}/bin/npm"
printf 'v22.0.0\n' > "${w}/old-node-version"
archive_sha="$(sha256sum "${STUB_NODE_ARCHIVE}" | cut -d' ' -f1)"
t_assert_fails print_bin \
  STUB_TAR_FAIL=1 RENOVATE_NODE_LINUX_X64_SHA256="${archive_sha}" RENOVATE_NODE_LINUX_ARM64_SHA256="${archive_sha}"
t_assert_eq 0 "$(find "${w}/cache" -maxdepth 1 -name '.node-install.*' | wc -l | tr -d ' ')"
t_assert_ok print_bin \
  RENOVATE_NODE_LINUX_X64_SHA256="${archive_sha}" RENOVATE_NODE_LINUX_ARM64_SHA256="${archive_sha}"
t_assert_ok test -x "${cached_node}/bin/npm"
t_assert_eq 0 "$(find "${w}/cache" -maxdepth 1 -name '.node-install.*' | wc -l | tr -d ' ')"

t_summary
