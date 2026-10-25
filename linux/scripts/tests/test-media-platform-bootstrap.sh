#!/usr/bin/env bash
# Isolated bootstrap snippets check source precedence and required-symbol failure; no ELF scan, apt operation or image build runs.
set -u
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${TESTS_DIR}/test-harness.sh"
BOOTSTRAP="${1:-${TESTS_DIR}/../01-core/module-bootstrap.sh}"
VALIDATOR="${2:-${TESTS_DIR}/../03-media/runtime/validate-media-runtime.sh}"
TORCH="${3:-${TESTS_DIR}/../06-packaging/setup-torch-venv.sh}"
WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT
mkdir -p "${WORK}/packaging" "${WORK}/core" "${WORK}/linux/scripts/01-core" "${WORK}/linux/scripts/03-media/runtime" "${WORK}/linux/scripts/06-packaging" "${WORK}/poison/01-core"
if [ -f "${BOOTSTRAP}" ]; then
  cp "${BOOTSTRAP}" "${WORK}/core/module-bootstrap.sh"
  cp "${BOOTSTRAP}" "${WORK}/linux/scripts/01-core/module-bootstrap.sh"
fi
cp "${TESTS_DIR}/../06-packaging/package-image-wiring.sh" "${WORK}/packaging/package-image-wiring.sh"
cp "${TESTS_DIR}/../06-packaging/package-image-wiring.sh" "${WORK}/linux/scripts/06-packaging/package-image-wiring.sh"
cp "${TESTS_DIR}/../01-core/wheelhouse-manifest.sh" "${WORK}/core/wheelhouse-manifest.sh"
cp "${TESTS_DIR}/../01-core/wheelhouse-manifest.sh" "${WORK}/linux/scripts/01-core/wheelhouse-manifest.sh"
printf 'echo POISON\nelf_unresolved_needed() { :; }\n' > "${WORK}/poison/01-core/platform.sh"
write_platform() {
  printf 'echo "%s"\nelf_unresolved_needed() { :; }\n' "$2" > "$1"
}
run_bootstrap() {
  local scenario="$1" source="$2" output="$3" destination="$4" status=0
  rm -f "${WORK}/core/platform.sh" "${WORK}/linux/scripts/01-core/platform.sh"
  case "${scenario}" in
    installed|incomplete|failed) write_platform "${WORK}/core/platform.sh" installed ;;
  esac
  case "${scenario}" in
    installed|repo|incomplete|failed) write_platform "${WORK}/linux/scripts/01-core/platform.sh" repo ;;
  esac
  case "${scenario}" in
    incomplete) printf 'echo incomplete\n' > "${WORK}/core/platform.sh" ;;
    failed) printf 'echo failed\nreturn 7\n' > "${WORK}/core/platform.sh" ;;
  esac
  sed -n '/^# Hard-require platform.sh/,/^ARTIFACTS=\|^cross_skip()/p' "${source}" | sed '$d' \
    | sed -e "s|/opt/scripts/core/|${WORK}/core/|g" -e "s|/opt/scripts/packaging/|${WORK}/packaging/|g" > "${destination}"
  if [ "${scenario}" = preloaded ]; then
    printf '\necho completed\n' >> "${destination}"
    SCRIPTS_ROOT="${WORK}/poison" SCRIPT_DIR="${WORK}/poison" bash -euo pipefail -c 'elf_unresolved_needed() { :; }; source "$1"' _ "${destination}" > "${output}" 2>&1 || status=$?
  else
    printf '\necho completed\n' >> "${destination}"
    SCRIPTS_ROOT="${WORK}/poison" SCRIPT_DIR="${WORK}/poison" bash -euo pipefail "${destination}" > "${output}" 2>&1 || status=$?
  fi
  printf '%s' "${status}"
}
for caller in validator torch; do
  source="${VALIDATOR}"; destination="${WORK}/linux/scripts/03-media/runtime/validate-media-runtime.sh"
  if [ "${caller}" = torch ]; then source="${TORCH}"; destination="${WORK}/linux/scripts/06-packaging/setup-torch-venv.sh"; fi
  for scenario in installed repo incomplete missing preloaded failed; do
    t_case "${caller}: ${scenario} platform bootstrap"
    status="$(run_bootstrap "${scenario}" "${source}" "${WORK}/output" "${destination}")"
    out="$(cat "${WORK}/output")"
    case "${scenario}" in
      installed|repo|preloaded)
        t_assert_eq 0 "${status}"
        t_assert_contains "${out}" completed
        if [ "${scenario}" != preloaded ]; then t_assert_contains "${out}" "${scenario}"; fi ;;
      incomplete|missing)
        t_assert_eq 1 "${status}"
        t_assert_contains "${out}" 'FATAL: platform.sh ('
        t_assert_rc 1 grep -Eq '^completed$' "${WORK}/output" ;;
      failed)
        t_assert_eq 7 "${status}"
        t_assert_contains "${out}" failed
        t_assert_rc 1 grep -Eq '^completed$' "${WORK}/output" ;;
    esac
    t_assert_rc 1 grep -Eq '^POISON$' "${WORK}/output"
    if [ "${scenario}" = installed ] || [ "${scenario}" = incomplete ]; then t_assert_rc 1 grep -Eq '^repo$' "${WORK}/output"; fi
  done
done
t_case 'Torch explicitly ships the bootstrap beside its required platform and logging companions'
t_assert_ok python3 - "${TESTS_DIR}/../../Dockerfile.torch" <<'PY'
import shlex
import sys
from pathlib import Path

for line in Path(sys.argv[1]).read_text().splitlines():
    if not line.startswith('COPY '): continue
    fields = shlex.split(line)
    if (
        fields
        and fields[0] == 'COPY'
        and fields[-1] == '/opt/scripts/core/'
        and {'linux/scripts/01-core/module-bootstrap.sh', 'linux/scripts/01-core/platform.sh', 'linux/scripts/01-core/logging.sh'} <= set(fields)
    ):
        break
else:
    raise SystemExit('Torch core COPY lacks its required bootstrap closure')
PY
t_summary
