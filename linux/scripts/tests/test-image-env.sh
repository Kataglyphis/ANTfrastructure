#!/usr/bin/env bash
# No build-host setting in a published image's environment, on both lanes: the static
# pass of lint-dockerfiles.sh, the image-env gate in build-runtime-manifest.sh, and the
# case file that also grades the Windows twin (WindowsImageEnv.Common.psm1).
# docs/build-cache-tiers.md#the-shipped-image-carries-no-build-host-setting
set -u
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${TESTS_DIR}/test-harness.sh"
REPO_ROOT="$(cd "${TESTS_DIR}/../../.." && pwd)"
PY="${PREFLIGHT_PYTHON:-python3}"
CASES="${TESTS_DIR}/image-env-cases.json"
GATE="${REPO_ROOT}/linux/scripts/verify_image_env.py"
MANIFEST="${REPO_ROOT}/linux/scripts/build-runtime-manifest.sh"

_work="$(mktemp -d)"
trap 'rm -rf "${_work}"' EXIT

# _df <name> <content> -> path of a fixture Dockerfile
_df() { printf '%s\n' "$2" > "${_work}/$1"; printf '%s' "${_work}/$1"; }
_lint() { "${PY}" "${GATE}" --dockerfile "$@"; }

t_case "gate exists and parses"
t_assert_ok test -f "${GATE}"
t_assert_ok "${PY}" -c "import ast,sys; ast.parse(open(sys.argv[1]).read())" "${GATE}"

t_case "every case of the shared fixture gets its recorded verdict"
_mismatch="$("${PY}" - "${REPO_ROOT}/linux/scripts" "${CASES}" <<'PY'
import json, sys
sys.path.insert(0, sys.argv[1])
import verify_image_env as g
cases = json.load(open(sys.argv[2], encoding="utf-8"))
bad = [c for c in cases if bool(g.leak_reasons(c["name"], c["value"])) != c["leak"]]
print(len(cases), len([c for c in cases if c["leak"]]))
for c in bad:
    print("MISMATCH %s=%s (%s)" % (c["name"], c["value"], c["why"]))
PY
)"
_counts="$(printf '%s\n' "${_mismatch}" | head -1)"
t_assert_eq "" "$(printf '%s\n' "${_mismatch}" | grep -e MISMATCH || true)" "the fixture disagrees with the matcher"
_total="${_counts%% *}"; _leaks="${_counts##* }"
t_assert_ok test "${_total}" -ge 20
t_assert_ok test "${_leaks}" -ge 8
t_assert_ok test "$((_total - _leaks))" -ge 8

# --- --env-file: the publish gate's own mode ---------------------------------
t_case "the 2026-09-23 value fails and the finding names it"
printf 'PATH=/usr/bin\nSCCACHE_WEBDAV_ENDPOINT=http://192.168.188.116:5000\n' > "${_work}/leak.env"
t_assert_eq "1" "$(t_rc "${PY}" "${GATE}" --env-file "${_work}/leak.env")"
_out="$(t_out "${PY}" "${GATE}" --env-file "${_work}/leak.env" --label img:x)"
t_assert_contains "${_out}" "LEAK img:x: SCCACHE_WEBDAV_ENDPOINT=http://192.168.188.116:5000"
t_assert_contains "${_out}" "RFC1918/link-local address 192.168.188.116"

t_case "local defaults pass, and the count read is printed"
printf 'PATH=/usr/bin\nSCCACHE_DIR=/var/cache/sccache\nSCCACHE_CACHE_SIZE=30G\n' > "${_work}/clean.env"
t_assert_eq "0" "$(t_rc "${PY}" "${GATE}" --env-file "${_work}/clean.env")"
t_assert_contains "$(t_out "${PY}" "${GATE}" --env-file "${_work}/clean.env")" "3 variable(s)"

t_case "an environment that was never read is a failure, not a pass"
: > "${_work}/empty.env"
t_assert_eq "1" "$(t_rc "${PY}" "${GATE}" --env-file "${_work}/empty.env")"
t_assert_contains "$(t_out "${PY}" "${GATE}" --env-file "${_work}/empty.env")" "never read"

t_case "stdin works, as the wrapper gate could pipe it"
t_assert_eq "1" "$(printf 'SCCACHE_BUCKET=b\n' | t_rc "${PY}" "${GATE}" --env-file -)"

t_case "every versions.env key passes (the Windows base bakes them all into the Machine env)"
grep -E '^[A-Za-z_][A-Za-z0-9_]*=' "${REPO_ROOT}/linux/scripts/01-core/versions.env" \
  | sed 's/[[:space:]]#.*$//' > "${_work}/versions.env"
t_assert_ok test -s "${_work}/versions.env"
t_assert_ok "${PY}" "${GATE}" --env-file "${_work}/versions.env" --min-vars 100

# --- --dockerfile: the static pass ---------------------------------------------
t_case "an ENV continued with the Windows escape character still carries the endpoint"
_f="$(_df win-env '# escape=`
FROM scratch
ARG SCCACHE_WEBDAV_ENDPOINT
ENV SCCACHE_DIR="C:\sccache\v2" `
    SCCACHE_WEBDAV_ENDPOINT="${SCCACHE_WEBDAV_ENDPOINT}"')"
t_assert_eq "1" "$(t_rc _lint "${_f}")"
t_assert_contains "$(t_out _lint "${_f}")" "ENV SCCACHE_WEBDAV_ENDPOINT -- build-host sccache setting"

t_case "an ENV that expands the endpoint ARG under another name is still a leak"
_f="$(_df alias 'FROM scratch
ARG SCCACHE_WEBDAV_ENDPOINT
ENV MY_CACHE=${SCCACHE_WEBDAV_ENDPOINT}')"
t_assert_eq "1" "$(t_rc _lint "${_f}")"
t_assert_contains "$(t_out _lint "${_f}")" 'expands the build-host ARG ${SCCACHE_WEBDAV_ENDPOINT}'

t_case "a LAN literal in an ENV or an ARG default fails; the ARG-only endpoint passes"
_f="$(_df lan-env 'FROM scratch
ENV PIP_INDEX_URL=http://10.0.0.5:3141/root/pypi')"
t_assert_eq "1" "$(t_rc _lint "${_f}")"
_f="$(_df lan-arg 'FROM scratch
ARG MIRROR=http://192.168.1.2:8080')"
t_assert_eq "1" "$(t_rc _lint "${_f}")"
_f="$(_df arg-only 'FROM scratch
ARG SCCACHE_WEBDAV_ENDPOINT
ARG CUDA_WINDOWS_ARM64_CURAND_VERSION=10.4.4.72
ENV SCCACHE_DIR=/var/cache/sccache')"
t_assert_eq "0" "$(t_rc _lint "${_f}")"

# A compile RUN mounts both caches; either one alone is a probe that starts no server.
_cache='--mount=type=cache,target=C:\sccache,id=a,sharing=shared'
_logs='--mount=type=cache,target=C:\sccache-logs,id=b,sharing=shared'
_compile_run="RUN ${_cache} \`
    ${_logs} \`
    echo compile"
t_case "a compiling RUN whose stage never declares the endpoint ARG fails"
_f="$(_df no-arg "# escape=\`
FROM scratch
${_compile_run}")"
t_assert_eq "1" "$(t_rc _lint "${_f}")"
t_assert_contains "$(t_out _lint "${_f}")" "declares no ARG SCCACHE_WEBDAV_ENDPOINT"

t_case "the ARG must be in the RUN's OWN stage: scope resets at FROM"
_f="$(_df prior-stage "# escape=\`
FROM scratch AS one
ARG SCCACHE_WEBDAV_ENDPOINT
FROM scratch AS two
${_compile_run}")"
t_assert_eq "1" "$(t_rc _lint "${_f}")"
_f="$(_df own-stage "# escape=\`
FROM scratch AS two
ARG SCCACHE_WEBDAV_ENDPOINT
${_compile_run}")"
t_assert_eq "0" "$(t_rc _lint "${_f}")"

t_case "a RUN with only one of the two mounts is a probe, not a compile"
for _probe in "${_cache}" "${_logs}"; do
  _f="$(_df probe "FROM scratch
RUN ${_probe} echo probe")"
  t_assert_eq "0" "$(t_rc _lint "${_f}")"
done

t_case "no mode is a usage error, and a target that is not a file fails"
t_assert_eq "2" "$(t_rc "${PY}" "${GATE}")"
t_assert_eq "1" "$(t_rc _lint /nonexistent/Dockerfile.nope)"

t_case "every Dockerfile on disk is clean (the Windows lane's leak is gone)"
mapfile -t _tree < <(cd "${REPO_ROOT}" && ls -1 linux/Dockerfile.* linux/webserver/Dockerfile \
                       linux/llm-stack/Dockerfile windows/Dockerfile windows/Dockerfile.*)
t_assert_ok test "${#_tree[@]}" -ge 20
t_assert_eq "" "$(cd "${REPO_ROOT}" && _lint "${_tree[@]}" 2>&1 >/dev/null)" "a Dockerfile carries a build-host setting"

t_case "lint-dockerfiles.sh runs the gate (an orphaned gate proves nothing)"
t_assert_ok grep -q -e 'python3 linux/scripts/verify_image_env.py --dockerfile "${DOCKERFILES\[@\]}" || FAILED=1' \
  "${REPO_ROOT}/linux/scripts/lint-dockerfiles.sh"

# --- build-runtime-manifest.sh: the Linux publish gate -------------------------
# The gate lifted out with its collaborators stubbed; a fake nerdctl serves each
# arch's config ENV from ${FAKE_ENV_DIR}/<arch>.env and fails when there is none.
_fk="${_work}/bin"
mkdir -p "${_fk}" "${_work}/envs"
cat > "${_fk}/nerdctl" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${FAKE_LOG}"
case "$1" in
  image)
    arch="" prev=""
    for a in "$@"; do [ "${prev}" = "--platform" ] && arch="${a#linux/}"; prev="${a}"; done
    [ -n "${arch}" ] && [ -f "${FAKE_ENV_DIR}/${arch}.env" ] || exit 1
    cat "${FAKE_ENV_DIR}/${arch}.env" ;;
  *) exit 0 ;;
esac
SH
chmod +x "${_fk}/nerdctl"
_env_fn="$(t_fn_src "${MANIFEST}" _manifest_image_env_gate)" || exit 1

# _env_gate -> the gate's output and RC=<rc>, over TARGET_ARCHES (default amd64,arm64).
# FAKE_PRESENT=0 makes every wrapper tag missing locally.
_env_gate() {
  (
    set +e
    TARGET_ARCHES="${TARGET_ARCHES:-amd64,arm64}"
    NERDCTL_BIN="${_fk}/nerdctl" FAKE_ENV_DIR="${_work}/envs" FAKE_LOG="${_work}/nerdctl.log"
    export FAKE_ENV_DIR FAKE_LOG NERDCTL_BIN
    eval "${_env_fn}"
    arch_list_to_words() { printf '%s' "${1//,/ }"; }
    runtime_wrapper_tag() { printf 'img:latest-%s' "$1"; }
    image_exists() { [ "${FAKE_PRESENT:-1}" = "1" ]; }
    run() { "$@"; }
    warn() { printf 'WARN %s\n' "$*"; }
    python3() { command "${PY}" "$@"; }
    _manifest_image_env_gate
    printf 'RC=%s\n' "$?"
  ) 2>&1
}

t_case "the manifest gate passes clean wrappers and reads each arch's config for its own platform"
cp "${_work}/clean.env" "${_work}/envs/amd64.env"; cp "${_work}/clean.env" "${_work}/envs/arm64.env"
: > "${_work}/nerdctl.log"
_out="$(_env_gate)"
t_assert_contains "${_out}" "RC=0" "the fake wrappers must be able to pass, or every red below proves nothing"
t_assert_contains "${_out}" "3 variable(s) in img:latest-arm64"
t_assert_contains "$(cat "${_work}/nerdctl.log")" "--platform linux/amd64"
t_assert_contains "$(cat "${_work}/nerdctl.log")" "--platform linux/arm64"

t_case "one leaking arch fails the index, and the finding names the wrapper and the variable"
cp "${_work}/leak.env" "${_work}/envs/arm64.env"
_out="$(_env_gate)"
t_assert_contains "${_out}" "RC=1"
t_assert_contains "${_out}" "LEAK img:latest-arm64: SCCACHE_WEBDAV_ENDPOINT"
t_assert_contains "${_out}" "the ENV of [arm64]"

t_case "a wrapper whose config cannot be read fails closed"
rm -f "${_work}/envs/arm64.env"
t_assert_contains "$(_env_gate)" "RC=1"
cp "${_work}/clean.env" "${_work}/envs/arm64.env"

t_case "a wrapper missing locally is pulled for its platform first; a present one never is"
: > "${_work}/nerdctl.log"
t_assert_contains "$(FAKE_PRESENT=0 _env_gate)" "RC=0"
t_assert_contains "$(cat "${_work}/nerdctl.log")" "pull -q --platform linux/arm64 img:latest-arm64"
: > "${_work}/nerdctl.log"
_env_gate >/dev/null
t_assert_eq "" "$(grep -e '^pull' "${_work}/nerdctl.log" || true)" "an existing tag was re-pointed by a pull"

t_case "create_manifest runs the gate first, unconditionally: no switch, and --manifest-only reaches it"
_create="$(t_fn_src "${MANIFEST}" create_manifest)" || exit 1
t_assert_ok grep -q -e '^  _manifest_image_env_gate || err ' <<< "${_create}"
_gate_line="$(grep -n -e '_manifest_image_env_gate' <<< "${_create}" | head -1 | cut -d: -f1)"
_first_switch="$(grep -n -e 'RUNTIME_MANIFEST_' <<< "${_create}" | head -1 | cut -d: -f1)"
t_assert_ok test "${_gate_line:-999}" -lt "${_first_switch:-0}"
_main="$(t_fn_src "${MANIFEST}" main)" || exit 1
t_assert_ok grep -q -e '^  if \[ "${CREATE_MANIFEST}" -eq 1 \]; then$' <<< "${_main}"
t_assert_eq "" "$(t_fn_src "${MANIFEST}" _manifest_build_and_smoke | grep -e 'verify_image_env\|image_env_gate' || true)" \
  "the env gate is behind RUNTIME_IMAGE_SMOKE again"

t_summary
