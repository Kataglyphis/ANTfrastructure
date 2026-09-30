#!/usr/bin/env bash
# APP_REF resolves to one commit per run, fetched as itself; a stub git replaces the remote. See docs/linux-cross-builds.md#the-app-the-wrapper-builds
set -u
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${TESTS_DIR}/test-harness.sh"
SCRIPTS="${TESTS_DIR}/.."
_RESOLVE="$(t_fn_src "${SCRIPTS}/01-core/runtime-build-fns.sh" runtime_resolve_app_ref)" || exit 1
_FETCH="$(t_fn_src "${SCRIPTS}/03-media/runtime/assemble-torch-app.sh" fetch_app_tree)" || exit 1

_bin="$(mktemp -d)"
trap 'rm -rf "${_bin}"' EXIT
_log="${_bin}/argv"
_ls="${_bin}/ls-remote.out"
H=1111111111111111111111111111111111111111  # a branch head
T=2222222222222222222222222222222222222222  # an annotated tag object
P=3333333333333333333333333333333333333333  # the commit that tag peels to

# Logs every call; ls-remote prints the canned refs, or fails like an unreachable remote.
cat > "${_bin}/git" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${STUB_LOG}"
if [ "$1" = ls-remote ]; then
  [ -z "${LS_FAIL:-}" ] || { echo 'fatal: unable to access' >&2; exit 128; }
  cat "${LS_OUT}"
fi
exit 0
STUB
chmod +x "${_bin}/git"

# _resolve <APP_REF> -> output, APP_REF=<result>, rc=<n>; prefix assignments (LS_FAIL, DRY_RUN) reach it via env.
_resolve() {
  : > "${_log}"
  env STUB_LOG="${_log}" LS_OUT="${_ls}" PATH="${_bin}:${PATH}" APP_REF="$1" bash -c '
    log() { echo "LOG $*"; }; warn() { echo "WARN $*"; }; err() { echo "ERR $*"; exit 1; }
    is_dry_run() { [ "${DRY_RUN:-0}" = 1 ]; }
    '"${_RESOLVE}"'
    runtime_resolve_app_ref
    echo "APP_REF=${APP_REF}"' 2>&1
  echo "rc=$?"
}

t_case "a branch resolves to the commit at its head"
printf '%s\trefs/heads/develop\n' "${H}" > "${_ls}"
_out="$(_resolve develop)"
t_assert_contains "${_out}" "APP_REF=${H}" "the build arg is the commit, so the layer moves when the branch does"
t_assert_contains "${_out}" "rc=0" "and the run goes on"

t_case "an annotated tag resolves to the commit it peels to, not the tag object"
printf '%s\trefs/tags/v1.0\n%s\trefs/tags/v1.0^{}\n' "${T}" "${P}" > "${_ls}"
t_assert_contains "$(_resolve v1.0)" "APP_REF=${P}" "a tag object is not a commit git can fetch into a tree"

t_case "a branch wins over a same-named tag"
printf '%s\trefs/tags/both\n%s\trefs/heads/both\n' "${T}" "${H}" > "${_ls}"
t_assert_contains "$(_resolve both)" "APP_REF=${H}" "tracking a branch is the point of the key"

t_case "a commit is built as given, and the remote is never asked"
_out="$(_resolve "${P}")"
t_assert_contains "${_out}" "APP_REF=${P}" "a 40-hex ref is already what the layer keys on"
t_assert_eq "" "$(cat "${_log}")" "no ls-remote for a ref that needs no resolving"

t_case "a ref the remote does not have stops the run"
: > "${_ls}"
_out="$(_resolve no-such-branch)"
t_assert_contains "${_out}" "ERR APP_REF=no-such-branch names no branch or tag" "and says which ref"
t_assert_contains "${_out}" "rc=1" "never a build of whatever the Dockerfile default names"

t_case "an unreachable remote stops a real run, and only warns a dry one"
printf '%s\trefs/heads/develop\n' "${H}" > "${_ls}"
_out="$(LS_FAIL=1 _resolve develop)"
t_assert_contains "${_out}" "ERR cannot resolve APP_REF=develop" "a run cannot build an app it cannot name"
t_assert_contains "${_out}" "rc=1" "with a failing status"
_out="$(LS_FAIL=1 DRY_RUN=1 _resolve develop)"
t_assert_contains "${_out}" "WARN [DRY RUN]" "a dry run says what it could not resolve"
t_assert_contains "${_out}" "APP_REF=develop" "and keeps the name"
t_assert_contains "${_out}" "rc=0" "without failing"

t_case "an empty APP_REF is refused"
t_assert_contains "$(_resolve '')" "rc=1" "versions.env must name a ref"

t_case "both entry points resolve the ref once, before the per-arch loop"
for _entry in build-runtime-manifest.sh build-runtime-artifacts.sh; do
  t_assert_ok grep -q -e '^  runtime_resolve_app_ref$' "${SCRIPTS}/${_entry}"
done

# _fetch <APP_REF> -> every git call fetch_app_tree made
_fetch() {
  : > "${_log}"
  env STUB_LOG="${_log}" PATH="${_bin}:${PATH}" APP_REF="$1" APP_DIR=/opt/app \
    bash -c "${_FETCH}"$'\n''fetch_app_tree' >/dev/null 2>&1
  cat "${_log}"
}

t_case "assemble fetches a commit as itself"
_calls="$(_fetch "${P}")"
t_assert_contains "${_calls}" "-C /opt/app fetch -q --depth 1 https://github.com/Kataglyphis/OrchestrANT.git ${P}" \
  "clone --branch takes names only"
t_assert_contains "${_calls}" "-C /opt/app checkout -q --detach FETCH_HEAD" "and checks out exactly that commit"
t_assert_fails grep -q -e 'clone' <<<"${_calls}"

t_case "assemble still clones a name, for a plain docker build"
t_assert_contains "$(_fetch develop)" "clone --branch develop --depth 1 https://github.com/Kataglyphis/OrchestrANT.git /opt/app" \
  "the Dockerfile default is the branch itself"

t_summary
