#!/usr/bin/env bash
# Real local Git repositories prove pin selection, fallback and commit verification; GitHub fork availability is not covered.
set -u
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${TESTS_DIR}/test-harness.sh"
HELPER="${TESTS_DIR}/../03-media/build/onnxruntime/build/lib/source-fetch.sh"

export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 GIT_TERMINAL_PROMPT=0
ROOT="$(t_mktemp -d)" || exit 1
UPSTREAM="${ROOT}/upstream"
FORK="${ROOT}/fork"
git init -q "${UPSTREAM}" || exit 1
printf 'one\n' > "${UPSTREAM}/file"
t_git_commit "${UPSTREAM}" || exit 1
COMMIT_A="$(git -C "${UPSTREAM}" rev-parse HEAD)"
printf 'two\n' > "${UPSTREAM}/file"
t_git_commit "${UPSTREAM}" || exit 1
COMMIT_B="$(git -C "${UPSTREAM}" rev-parse HEAD)"
git -C "${UPSTREAM}" tag v1.0.0 "${COMMIT_A}" || exit 1
git -C "${UPSTREAM}" tag v9.9.9 "${COMMIT_B}" || exit 1
git clone -q --no-tags "file://${UPSTREAM}" "${FORK}" || exit 1
git -C "${FORK}" config uploadpack.allowAnySHA1InWant true || exit 1
git -C "${UPSTREAM}" config uploadpack.allowAnySHA1InWant true || exit 1
MISSING=0123456789abcdef0123456789abcdef01234567

# <pins-text> <command...>: runs the helper copy beside its own pins without real sleeps.
_fetch() {
  local lib
  lib="$(mktemp -d "${ROOT}/lib.XXXXXX")" || return 1
  cp "${HELPER}" "${lib}/source-fetch.sh" || return 1
  printf '%s\n' "$1" > "${lib}/source-pins.txt" || return 1
  shift
  bash -c 'sleep() { :; }; source "$1/source-fetch.sh"; shift; "$@"' _ "${lib}" "$@" 2>&1
}

_section_primary() {
  t_case "a matching upstream tag is cloned and verified"
  local out
  out="$(_fetch "demo|v1.0.0|${COMMIT_A}|file://${FORK}" ort_source_fetch demo v1.0.0 "file://${UPSTREAM}" "${ROOT}/primary")"
  t_assert_eq 0 "$?" "primary fetch status"
  t_assert_eq "${COMMIT_A}" "$(git -C "${ROOT}/primary" rev-parse HEAD)" "primary HEAD"
  t_assert_contains "${out}" "verified from file://${UPSTREAM}"
}

_section_fallback() {
  t_case "a dead upstream falls back to the pinned commit in a fork and keeps the tag name"
  local out
  out="$(_fetch "demo|v1.0.0|${COMMIT_A}|file://${ROOT}/absent file://${FORK}" ort_source_fetch demo v1.0.0 "file://${ROOT}/gone" "${ROOT}/fallback")"
  t_assert_eq 0 "$?" "fallback status"
  t_assert_eq "${COMMIT_A}" "$(git -C "${ROOT}/fallback" rev-parse HEAD)" "fallback HEAD"
  t_assert_eq "${COMMIT_A}" "$(git -C "${ROOT}/fallback" rev-parse 'v1.0.0^{commit}')" "fallback tag"
  t_assert_contains "${out}" "primary fetch attempt 3/3"
  t_assert_contains "${out}" "verified from file://${FORK}"
}

# <pins> <version> <primary> <dir> <message>: the fetch must refuse with status 1 and say why; REFUSED keeps the output.
_refused() {
  local rc=0
  REFUSED="$(_fetch "$1" ort_source_fetch demo "$2" "$3" "$4")" || rc=$?
  t_assert_eq 1 "${rc}" "refusal status for $4"
  t_assert_contains "${REFUSED}" "$5"
}

_absent() { t_assert_eq absent "$([ -e "$1" ] && echo present || echo absent)" "no checkout left at $1"; }

_section_moved_tag() {
  t_case "an upstream tag at another commit is fatal and never falls back"
  _refused "demo|v9.9.9|${COMMIT_A}|file://${FORK}" v9.9.9 "file://${UPSTREAM}" "${ROOT}/moved" "not the pinned ${COMMIT_A}"
  case "${REFUSED}" in *"falling back"*) t_assert_eq "no fallback" "fallback attempted" ;; *) t_assert_eq 1 1 ;; esac
}

_section_unavailable() {
  t_case "a commit absent everywhere fails and removes the partial checkout"
  _refused "demo|v1.0.0|${MISSING}|file://${FORK}" v1.0.0 "file://${ROOT}/gone" "${ROOT}/missing" "is unavailable from"
  _absent "${ROOT}/missing"
}

_section_stale_pin() {
  t_case "a version bump without a new pin fails before any fetch"
  _refused "demo|v1.0.0|${COMMIT_A}|" v2.0.0 "file://${UPSTREAM}" "${ROOT}/stale" "pin is for v1.0.0 but the build asks for v2.0.0"
  _absent "${ROOT}/stale"
}

_section_bad_pins() {
  t_case "duplicate, missing and short pins are refused"
  local rc=0
  _fetch "$(printf 'demo|v1|%s|\ndemo|v1|%s|' "${COMMIT_A}" "${COMMIT_A}")" ort_source_pin demo >/dev/null || rc=$?
  t_assert_eq 1 "${rc}" "duplicate pin"
  rc=0; _fetch "other|v1|${COMMIT_A}|" ort_source_pin demo >/dev/null || rc=$?
  t_assert_eq 1 "${rc}" "missing pin"
  rc=0; _fetch "demo|v1|${COMMIT_A:0:12}|" ort_source_pin demo >/dev/null || rc=$?
  t_assert_eq 1 "${rc}" "short commit"
}

_section_commit_only() {
  t_case "a commit-only pin fetches the commit from its primary"
  local out
  out="$(_fetch "demo|-|${COMMIT_B}|" ort_source_fetch demo - "file://${UPSTREAM}" "${ROOT}/commit-only")"
  t_assert_eq 0 "$?" "commit-only status"
  t_assert_eq "${COMMIT_B}" "$(git -C "${ROOT}/commit-only" rev-parse HEAD)" "commit-only HEAD"
  t_assert_contains "${out}" "verified from file://${UPSTREAM}"
  t_case "a failed commit-only primary leaves an empty repository yet still falls back"
  out="$(_fetch "demo|-|${COMMIT_B}|file://${FORK}" ort_source_fetch demo - "file://${ROOT}/gone" "${ROOT}/commit-fallback")"
  t_assert_eq 0 "$?" "commit-only fallback status"
  t_assert_eq "${COMMIT_B}" "$(git -C "${ROOT}/commit-fallback" rev-parse HEAD)" "commit-only fallback HEAD"
  t_assert_contains "${out}" "verified from file://${FORK}"
}

_section_deps() {
  t_case "deps.txt must name the pinned commit"
  local deps="${ROOT}/deps.txt" out rc=0
  printf '#name;url;commit\nother;https://x;%s\ndemo_dep;https://example/dep.git;%s\n' "${COMMIT_B}" "${COMMIT_A}" > "${deps}"
  out="$(_fetch "demo|-|${COMMIT_A}|" ort_source_dep_url "${deps}" demo_dep demo)"
  t_assert_eq 0 "$?" "deps match status"
  t_assert_eq "https://example/dep.git" "${out}" "deps url"
  out="$(_fetch "demo|-|${COMMIT_B}|" ort_source_dep_url "${deps}" demo_dep demo)" || rc=$?
  t_assert_eq 1 "${rc}" "deps mismatch status"
  t_assert_contains "${out}" "but source-pins.txt has ${COMMIT_B}"
}

_section_shipped_pins() {
  t_case "the shipped pins match versions.env tags and carry full commits with fallbacks"
  local pins versions name tag commit fallbacks
  pins="$(dirname "${HELPER}")/source-pins.txt"
  versions="${TESTS_DIR}/../01-core/versions.env"
  while IFS='|' read -r name tag commit fallbacks; do
    case "${name}" in '' | '#'*) continue ;; esac
    t_assert_ok bash -c '[[ "$1" =~ ^[0-9a-f]{40}$ ]]' _ "${commit}"
    t_assert_ok test -n "${fallbacks}"
    case "${name}" in
      onnxruntime) t_assert_grep "${versions}" "^ONNXRUNTIME_VERSION=${tag}\$" ;;
      onnxruntime-genai) t_assert_grep "${versions}" "^ONNXRUNTIME_GENAI_VERSION=${tag}\$" ;;
      *) t_assert_eq - "${tag}" "${name} is commit-only" ;;
    esac
  done < "${pins}"
}

_section_wiring() {
  t_case "Media, GenAI and Android consume the verified checkouts"
  local ort="${TESTS_DIR}/../03-media/build/onnxruntime" android_docker="${TESTS_DIR}/../../Dockerfile.android"
  t_assert_grep "${ort}/build/20-fetch.sh" '^source "\$\{SCRIPT_DIR\}/lib/source-fetch\.sh"$'
  t_assert_grep "${ort}/build/20-fetch.sh" 'ort_source_fetch "\$pin" "\$version" "\$repository" "\$directory" \|\| err '
  t_assert_grep "${ort}/build/20-fetch.sh" 'onnxruntime-extensions - "\$\{_genai_extensions_url\}" "\$\(genai_extensions_src_dir\)"$'
  t_assert_grep "${ort}/build/60-build-genai.sh" '^_genai_extensions_src="\$\(genai_extensions_src_dir\)"$'
  t_assert_grep "${ort}/build/60-build-genai.sh" '^\[ -d "\$\{_genai_extensions_src\}/\.git" \] \|\| err '
  t_assert_grep "${ort}/build/60-build-genai.sh" '^GENAI_BASE_ARGS\+=\(--cmake_extra_defines "FETCHCONTENT_SOURCE_DIR_ONNXRUNTIME_EXTENSIONS=\$\{_genai_extensions_src\}"\)$'
  t_assert_grep "${ort}/android/build-android.sh" '^ort_source_fetch onnxruntime "\$\{ORT_VERSION\}" "https://github\.com/microsoft/onnxruntime\.git" /opt/onnxruntime-android$'
  t_assert_no_grep "${ort}/android/build-android.sh" 'android_clone_shallow'
  t_assert_grep "${ort}/android/build-android.sh" '^_ort_source_fetch_lib=/opt/scripts/03-media/onnxruntime/source-fetch\.sh$'
  t_assert_grep "${android_docker}" '^COPY --chmod=644 linux/scripts/03-media/build/onnxruntime/build/lib/source-fetch\.sh /opt/scripts/03-media/onnxruntime/source-fetch\.sh$'
  t_assert_grep "${android_docker}" '^COPY --chmod=644 linux/scripts/03-media/build/onnxruntime/build/lib/source-pins\.txt /opt/scripts/03-media/onnxruntime/source-pins\.txt$'
}

t_sections _section_primary _section_fallback _section_moved_tag _section_unavailable _section_stale_pin \
  _section_bad_pins _section_commit_only _section_deps _section_shipped_pins _section_wiring -- "$@"
t_summary
