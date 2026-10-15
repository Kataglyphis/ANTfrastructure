#!/usr/bin/env bash
# Tests for publish-github-release.sh against fake repos and a stand-in gh that records what it is asked.
set -u
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PUBLISH="${TESTS_DIR}/../06-packaging/publish-github-release.sh"
source "${TESTS_DIR}/test-harness.sh"

work="$(mktemp -d)"
trap 'rm -rf "${work}"' EXIT
mkdir -p "${work}/bin" "${work}/pkgs" "${work}/empty" "${work}/flutter" "${work}/rust"

# "gh release view" answers like GitHub: found when released-<tag> exists, else "release not found"; GH_DOWN fails it.
cat > "${work}/bin/gh" <<GH
#!/usr/bin/env bash
if [ "\$1 \$2" = "release view" ]; then
  [ -z "\${GH_DOWN:-}" ] || { echo "HTTP 401: Bad credentials" >&2; exit 1; }
  [ -e "${work}/released-\$3" ] && { echo "{\"tagName\":\"\$3\"}"; exit 0; }
  echo "release not found" >&2; exit 1
fi
printf '%s\n' "\$@" > "${work}/gh-args"
for a in "\$@"; do [ "\${prev:-}" = "--notes-file" ] && cp "\$a" "${work}/gh-notes"; prev="\$a"; done
GH
chmod +x "${work}/bin/gh"

# A Flutter repo: pubspec.yaml, a CHANGELOG with plain headings and a near-miss version.
printf 'name: app\nversion: 2.1.0+3\n' > "${work}/flutter/pubspec.yaml"
printf '# Changelog\n\n## Unreleased\n\nNot yet.\n\n## 2.1.01 — not this one\n\nNear miss.\n\n## 2.1.0+3 — 2026-10-15\n\nVisit statistics.\n\n## 2.0.0+2\n\nOlder.\n' > "${work}/flutter/CHANGELOG.md"
# A Rust workspace: Cargo.toml and a Keep a Changelog file.
printf '[package]\nname = "oxidant"\nversion.workspace = true\n\n[workspace.package]\nversion = "2.3.4"\n' > "${work}/rust/Cargo.toml"
printf '# Changelog\n\n## [Unreleased]\n\nNext.\n\n## [2.3.4] - 2026-10-16\n\nOne version.\n\n## 2026-08-07\n\nDated.\n' > "${work}/rust/CHANGELOG.md"
for repo in flutter rust; do git -C "${work}/${repo}" init -q && t_git_commit "${work}/${repo}"; done
printf 'deb' > "${work}/pkgs/app_2.1.0_arm64.deb"
printf 'msi' > "${work}/pkgs/app-2.1.0-x64.msi"

# run <repo> <args...>: the script in that repo's root with the stand-in gh; output in ${work}/log.
run() {
  local repo="$1"; shift
  (cd "${work}/${repo}" && PATH="${work}/bin:${PATH}" bash "${PUBLISH}" "$@") > "${work}/log" 2>&1
}
flutter_args=(--version-file pubspec.yaml --changelog CHANGELOG.md --name App)

t_case "--check passes pubspec's version with its section and no release, and creates nothing"
t_assert_ok run flutter "${flutter_args[@]}" --check
t_assert_contains "$(cat "${work}/log")" "v2.1.0 is not released yet"
t_assert_fails test -e "${work}/gh-args"

t_case "publishing tags HEAD v<version> with every file, a SHA256SUMS and the section as notes"
t_assert_ok run flutter "${flutter_args[@]}" --assets "${work}/pkgs"
t_assert_eq "release create v2.1.0" "$(sed -n 1,3p "${work}/gh-args" | tr '\n' ' ' | sed 's/ $//')"
t_assert_contains "$(cat "${work}/gh-args")" "$(git -C "${work}/flutter" rev-parse HEAD)"
t_assert_contains "$(cat "${work}/gh-args")" "app_2.1.0_arm64.deb"
t_assert_contains "$(cat "${work}/gh-args")" "/SHA256SUMS"
t_assert_ok bash -c "cd '${work}/pkgs' && sha256sum -c --quiet SHA256SUMS"
t_assert_fails grep -q SHA256SUMS "${work}/pkgs/SHA256SUMS"
t_assert_eq "Visit statistics." "$(grep -v '^$' "${work}/gh-notes")"

t_case "a Cargo.toml version and a Keep a Changelog heading"
rm -f "${work}/gh-args"
t_assert_ok run rust --version-file Cargo.toml --changelog CHANGELOG.md --name OxidANT --assets "${work}/pkgs"
t_assert_contains "$(cat "${work}/gh-args")" "OxidANT 2.3.4"
t_assert_eq "One version." "$(grep -v '^$' "${work}/gh-notes")"

# refused <message> <repo> <args...>: the script fails, says why, and asks GitHub for no release.
refused() {
  local message="$1"; shift
  rm -f "${work}/gh-args"
  t_assert_fails run "$@"
  t_assert_contains "$(cat "${work}/log")" "$message"
  t_assert_fails test -e "${work}/gh-args"
}

t_case "a released version is neither checked through nor published again"
touch "${work}/released-v2.1.0"
refused "already released" flutter "${flutter_args[@]}" --check
refused "already released" flutter "${flutter_args[@]}" --assets "${work}/pkgs"
rm -f "${work}/released-v2.1.0"

t_case "a GitHub that does not answer is not 'not released'"
t_assert_fails env GH_DOWN=1 bash -c "cd '${work}/flutter' && PATH='${work}/bin:${PATH}' bash '${PUBLISH}' ${flutter_args[*]} --check"

t_case "a version the CHANGELOG has no section for"
sed -i 's/^version: .*/version: 2.2.0+4/' "${work}/flutter/pubspec.yaml"
refused "has no section for 2.2.0" flutter "${flutter_args[@]}" --check
sed -i 's/^version: .*/version: 2.1.0+3/' "${work}/flutter/pubspec.yaml"

t_case "a version file that states no version"
refused "states no version" rust --version-file CHANGELOG.md --changelog CHANGELOG.md --name X --check

t_case "an empty directory"
refused "no files in" flutter "${flutter_args[@]}" --assets "${work}/empty"

t_case "notes over GitHub's 125000 characters stop the check, not the release run's end"
cp "${work}/rust/CHANGELOG.md" "${work}/rust/CHANGELOG.keep"
{ printf '# Changelog\n\n## [2.3.4]\n\n'; head -c 130000 /dev/zero | tr '\0' 'x'; printf '\n'; } > "${work}/rust/CHANGELOG.md"
refused "over GitHub's 125000" rust --version-file Cargo.toml --changelog CHANGELOG.md --name OxidANT --check
mv "${work}/rust/CHANGELOG.keep" "${work}/rust/CHANGELOG.md"

t_case "missing arguments are a usage error"
run flutter --version-file pubspec.yaml --name App --check
t_assert_eq "2" "$?"

t_summary
