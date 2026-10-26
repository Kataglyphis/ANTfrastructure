#!/usr/bin/env bash
# Streams a tar of the named paths straight into age, so no plaintext copy lands on any disk; see linux/ansible/README.md#backups-to-the-nas
set -euo pipefail

usage() {
  echo "usage: backup-secrets.sh --out FILE -r RECIPIENT [-r RECIPIENT...] [--remote USER@HOST [--ssh-config FILE] [--sudo]] ABSOLUTE_PATH..." >&2
  exit 2
}

out="" remote="" ssh_config="" sudo=""
recipients=()
while [ $# -gt 0 ]; do
  case "$1" in
    --out) out="${2:-}"; shift 2 || usage ;;
    -r) recipients+=(-r "${2:-}"); shift 2 || usage ;;
    --remote) remote="${2:-}"; shift 2 || usage ;;
    --ssh-config) ssh_config="${2:-}"; shift 2 || usage ;;
    --sudo) sudo="sudo -n"; shift ;;
    --) shift; break ;;
    -*) usage ;;
    *) break ;;
  esac
done
[ -n "${out}" ] && [ "${#recipients[@]}" -gt 0 ] && [ $# -gt 0 ] || usage

relative=()
for path in "$@"; do
  case "${path}" in
    /*) relative+=("${path#/}") ;;
    *) echo "backup-secrets.sh: ${path} is not absolute" >&2; exit 2 ;;
  esac
done

partial="${out}.partial"
listing="$(mktemp)"
trap 'rm -f "${partial}" "${listing}"' EXIT

# GNU tar writes its -v listing to stderr when the archive goes to stdout; a missing path is an error, not a warning.
tar_cmd=(tar --create --gzip --verbose --file - --directory / -- "${relative[@]}")
rc=0
if [ -n "${remote}" ]; then
  ssh_opts=(-o BatchMode=yes)
  [ -z "${ssh_config}" ] || ssh_opts+=(-F "${ssh_config}")
  ssh "${ssh_opts[@]}" "${remote}" "${sudo} $(printf '%q ' "${tar_cmd[@]}")" 2> "${listing}" |
    age "${recipients[@]}" -o "${partial}" || rc=$?
else
  ${sudo} "${tar_cmd[@]}" 2> "${listing}" | age "${recipients[@]}" -o "${partial}" || rc=$?
fi

if [ "${rc}" -ne 0 ] || grep -q -e '^tar: ' "${listing}"; then
  tail -n 20 "${listing}" >&2
  echo "backup-secrets.sh: the archive failed (rc ${rc}), nothing was written" >&2
  exit 1
fi
entries="$(grep -cv -e '^$' "${listing}" || true)"
[ "${entries}" -gt 0 ] || { echo "backup-secrets.sh: the archive is empty" >&2; exit 1; }
[ "$(head -c 21 "${partial}")" = "age-encryption.org/v1" ] || { echo "backup-secrets.sh: ${partial} is not an age file" >&2; exit 1; }

mv -f "${partial}" "${out}"
echo "entries=${entries} bytes=$(stat -c %s "${out}") file=${out}"
