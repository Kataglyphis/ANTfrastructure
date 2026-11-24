#!/usr/bin/env bash
# Sentinel engines prove fixture prune isolation, not real daemon behavior or reclaim amounts.
set -u
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${TESTS_DIR}/test-harness.sh"
workdir="$(t_mktemp -d)"
mkdir -p "${workdir}/bin"
export LIFECYCLE_ENGINE_LOG="${workdir}/engine.log"
cat > "${workdir}/engine-sentinel" <<'STUB'
#!/usr/bin/env bash
case "${0##*/}:${1:-}" in
  buildctl:du)
    case "$*" in *--format*) printf '[]\n' ;; esac
    exit 0
    ;;
  nerdctl:images) exit 0 ;;
esac
case "$*" in
  *prune*|*rmi*|*restart*|*stop*)
    printf '%s %s\n' "${0##*/}" "$*" >> "${LIFECYCLE_ENGINE_LOG}"
    ;;
esac
exit 97
STUB
for engine in buildctl nerdctl docker systemctl; do
  cp "${workdir}/engine-sentinel" "${workdir}/bin/${engine}"
  chmod +x "${workdir}/bin/${engine}"
done

t_case 'engine sentinels allow reachable empty store queries'
t_assert_rc 0 "${workdir}/bin/buildctl" du
t_assert_eq '[]' "$("${workdir}/bin/buildctl" du --format '{{json .}}')"
t_assert_rc 0 "${workdir}/bin/nerdctl" images

t_case 'engine sentinels retain attempted pruning and reject execution'
t_assert_rc 97 "${workdir}/bin/buildctl" prune --filter type==regular
t_assert_contains "$(cat "${LIFECYCLE_ENGINE_LOG}")" 'buildctl prune --filter type==regular'
: > "${LIFECYCLE_ENGINE_LOG}"

t_case 'lifecycle fixture disables both inherited host prune permissions'
rc=0
PATH="${workdir}/bin:${PATH}" CROSS_BUILDKIT_PRUNE=1 CROSS_IMAGE_PRUNE=1 \
  bash "${TESTS_DIR}/test-chain-lifecycle.sh" > "${workdir}/suite.log" 2>&1 || rc=$?
t_assert_eq 0 "${rc}" "$(tail -n 8 "${workdir}/suite.log")"
t_assert_eq '' "$(cat "${LIFECYCLE_ENGINE_LOG}")" 'lifecycle fixture attempted host pruning or service maintenance'
t_summary
