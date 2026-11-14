#!/usr/bin/env bash
# dispatch-consumer-lanes.sh --tag TAG [--dry-run]: after TAG is published, run every consumer's lanes on it once. See docs/image-acceptance.md#after-a-publish-the-consumers-lanes-run-on-it
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
config="${CONSUMER_LANES_CONFIG:-${script_dir}/../../shared/config/image-consumer-lanes.json}"
tag=""
dry_run=0
while [ "$#" -gt 0 ]; do
  case "$1" in
    --tag) tag="${2:-}"; shift 2 ;;
    --dry-run) dry_run=1; shift ;;
    *) printf 'usage: dispatch-consumer-lanes.sh --tag TAG [--dry-run]\n' >&2; exit 2 ;;
  esac
done
[ -n "${tag}" ] || { printf 'dispatch-consumer-lanes.sh: --tag is required\n' >&2; exit 2; }

# One line per dispatch: repository, workflow, lane words (empty for a workflow without inputs).
plan="$(python3 - "${config}" "${tag}" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as handle:
    config = json.load(handle)
row = config["tags"].get(sys.argv[2])
if row is None:
    sys.exit(0)
for name in config["consumers"]:
    repo = f'{config["owner"]}/{name}'
    print(f'{repo}\ton-request.yml\t{row["lanes"]}')
    if row.get("linux_x64"):
        print(f'{repo}\tlinux-x64.yml\t')
PY
)"
if [ -z "${plan}" ]; then
  printf 'dispatch-consumer-lanes: no consumer lanes are declared for :%s; nothing to run\n' "${tag}"
  exit 0
fi
ref="$(python3 -c 'import json, sys; print(json.load(open(sys.argv[1]))["ref"])' "${config}")"

# A publish has already happened; a dispatch that cannot be sent is named with its command, so it can be sent by hand.
failed=0
while IFS=$'\t' read -r repo workflow lanes; do
  cmd=(gh workflow run "${workflow}" -R "${repo}" --ref "${ref}")
  [ -z "${lanes}" ] || cmd+=(-f "lanes=${lanes}")
  if [ "${dry_run}" -eq 1 ]; then
    printf 'would run: %s\n' "${cmd[*]}"
  elif "${cmd[@]}" >/dev/null 2>&1; then
    printf 'dispatched %s %s%s\n' "${repo}" "${workflow}" "${lanes:+ (${lanes})}"
  else
    printf 'FAILED to dispatch; run by hand: %s\n' "${cmd[*]}" >&2
    failed=$((failed + 1))
  fi
done <<< "${plan}"
[ "${failed}" -eq 0 ] || { printf 'dispatch-consumer-lanes: %d dispatch(es) failed\n' "${failed}" >&2; exit 1; }
