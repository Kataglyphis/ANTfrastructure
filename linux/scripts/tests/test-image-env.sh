#!/usr/bin/env bash
# No build-host setting in a published image's environment, on both lanes: the static
# pass of lint-dockerfiles.sh, the publish check in verify-shipped-wrapper.sh, and the
# case file that also grades the Windows twin (WindowsImageEnv.Common.psm1).
# docs/build-cache-tiers.md#the-shipped-image-carries-no-build-host-setting
set -u
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${TESTS_DIR}/test-harness.sh"
REPO_ROOT="$(cd "${TESTS_DIR}/../../.." && pwd)"
PY="${PREFLIGHT_PYTHON:-python3}"
CASES="${TESTS_DIR}/image-env-cases.json"
GATE="${REPO_ROOT}/linux/scripts/verify_image_env.py"
WRAPPER="${REPO_ROOT}/linux/scripts/verify-shipped-wrapper.sh"

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

# --- verify-shipped-wrapper.sh: the Linux publish gate -------------------------
# A fake nerdctl serves the rootfs listing the content checks need and the config ENV.
_fk="${_work}/bin"
mkdir -p "${_fk}" "${_work}/root/opt/ffmpeg/lib" "${_work}/root/usr/local/lib"
cat > "${_fk}/nerdctl" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${FAKE_LOG}"
case "$1" in
  image)
    for a in "$@"; do
      if [ "${a}" = "--format" ]; then
        [ -n "${FAKE_ENV_FILE:-}" ] && [ -f "${FAKE_ENV_FILE}" ] || exit 1
        cat "${FAKE_ENV_FILE}"; exit 0
      fi
    done
    exit 0 ;;
  create) echo fakecid ;;
  export) tar -cf - -C "${FAKE_ROOTFS}" . ;;
  *) exit 0 ;;
esac
SH
chmod +x "${_fk}/nerdctl"
t_fake_elf "${_work}/root/opt/ffmpeg/lib/libavcodec.so.62.1.100" 62
: > "${_work}/root/usr/local/lib/libonnxruntime.so.1"
printf 'FFMPEG_ENABLE_TF=0\n' > "${_work}/versions-tf-off.env"

# _wrapper <env-file|""> [extra env...] -> runs the gate against the fake image
_wrapper() {
  local envf="$1"; shift
  env NERDCTL_BIN="${_fk}/nerdctl" VERSIONS_ENV="${_work}/versions-tf-off.env" \
      FAKE_ROOTFS="${_work}/root" FAKE_LOG="${_work}/nerdctl.log" FAKE_ENV_FILE="${envf}" "$@" \
      bash "${WRAPPER}" img:tag amd64
}
_wrapper_rc() { _wrapper "$@" >/dev/null 2>&1; echo $?; }

t_case "the wrapper gate passes a clean image and reads its config for the right platform"
: > "${_work}/nerdctl.log"
t_assert_eq "0" "$(_wrapper_rc "${_work}/clean.env")" "the fake image must be able to pass, or every red below proves nothing"
t_assert_contains "$(_wrapper "${_work}/clean.env" 2>&1)" "ok: image env (3 variable(s) in img:tag"
t_assert_contains "$(cat "${_work}/nerdctl.log")" "--platform linux/amd64"

t_case "the wrapper gate fails an image whose ENV carries the endpoint"
t_assert_eq "1" "$(_wrapper_rc "${_work}/leak.env")"
t_assert_contains "$(_wrapper "${_work}/leak.env" 2>&1)" "LEAK img:tag: SCCACHE_WEBDAV_ENDPOINT"

t_case "WRAPPER_CONTENT_GATE=0 waives content, never the ENV check"
t_assert_eq "1" "$(_wrapper_rc "${_work}/leak.env" WRAPPER_CONTENT_GATE=0)"

t_case "an image whose config cannot be read fails closed"
t_assert_eq "1" "$(_wrapper_rc "")"

t_summary
