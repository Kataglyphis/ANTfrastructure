#!/usr/bin/env bash
# The in-image probes run against fake tools and the runtime Dockerfiles' COPY lines; no image is built or run.
set -u
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${TESTS_DIR}/test-harness.sh"
SCRIPTS="${TESTS_DIR}/.."
LINUX="${SCRIPTS}/.."

_section_cargo_subcommands() {
  t_case "the cargo QA probe asks each tool through cargo, as cargo-mutants requires"
  local bin out
  bin="$(t_mktemp -d)" || return
  printf '#!/bin/sh\ncase "$1 $2" in\n  "audit --version") echo "cargo-audit-audit 0.22.2" ;;\n  "deny --version") echo "cargo-deny 0.20.2" ;;\n  "tarpaulin --version") echo "cargo-tarpaulin-tarpaulin 0.37.5" ;;\n  "mutants --version") echo "cargo-mutants 27.1.0" ;;\n  *) exit 2 ;;\nesac\n' > "${bin}/cargo"
  printf '#!/bin/sh\necho "error: unexpected argument --version found" >&2\nexit 2\n' > "${bin}/cargo-mutants"
  chmod +x "${bin}/cargo" "${bin}/cargo-mutants"
  out="$(PATH="${bin}:/usr/bin:/bin" bash -c "$(sed -n "/^_consumer_test_runtimes_probe() {/,/^PROBE\$/p" "${SCRIPTS}/06-packaging/smoke-runtime-image.sh" | sed -n '/^_qa=""$/,/^printf .FACT cargo-qa-tools-versions/p')")"
  t_assert_contains "${out}" "FACT cargo-qa-tools-versions cargo-audit=0.22.2 cargo-deny=0.20.2 cargo-tarpaulin=0.37.5 cargo-mutants=27.1.0"
}

# Emits "<source> <destination>" for each build-context COPY of the runtime Dockerfiles.
_copy_pairs() {
  local line source
  local -a words
  while IFS= read -r line; do
    read -r -a words <<< "${line#COPY }"
    for source in "${words[@]:0:${#words[@]}-1}"; do
      [ "${source#--}" = "${source}" ] && printf '%s %s\n' "${source}" "${words[${#words[@]}-1]}"
    done
  done < <(cat "${LINUX}/Dockerfile.package" "${LINUX}/Dockerfile.torch" | grep -E '^COPY ' | grep -v -e '--from=')
  return 0
}

# <path>: 0 when a runtime COPY delivers exactly that file, named or inside a copied directory.
_copied() {
  local path="$1" source destination
  while read -r source destination; do
    case "${source}|${destination}" in
      */\|*/) [ -f "${LINUX}/../${source}${path#"${destination}"}" ] && [ "${path#"${destination}"}" != "${path}" ] && return 0 ;;
      *\|*/) [ "${path}" = "${destination}${source##*/}" ] && return 0 ;;
      *) [ "${path}" = "${destination}" ] && return 0 ;;
    esac
  done < <(_copy_pairs)
  return 1
}

_section_ft_probe_inputs() {
  t_case "every /opt/scripts file the free-threaded store probe reads ships in the runtime image"
  local probe path checked=0
  # shellcheck source=../06-packaging/check-free-threaded-wheels.sh
  source "${SCRIPTS}/06-packaging/check-free-threaded-wheels.sh"
  probe="$(ft_store_probe_script)"
  while IFS= read -r path; do
    checked=$((checked + 1))
    if _copied "${path}"; then t_assert_eq 1 1; else t_assert_eq "copied" "missing" "${path} is not copied by Dockerfile.package or Dockerfile.torch"; fi
  done < <(printf '%s\n' "${probe}" | grep -oE '/opt/scripts/[A-Za-z0-9_./-]+\.(sh|py|txt)' | sort -u)
  t_assert_ok test "${checked}" -ge 4
  path="/opt/scripts/03-media/free-threaded-twins.txt"
  if _copied "${path}"; then t_assert_eq 1 1; else t_assert_eq "copied" "missing" "${path}, the table the sourced library reads beside itself"; fi
}

t_sections _section_cargo_subcommands _section_ft_probe_inputs -- "$@"
t_summary
