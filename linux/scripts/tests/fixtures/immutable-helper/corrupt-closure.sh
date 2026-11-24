#!/usr/bin/env bash
# A successful closure with changed helper bytes must fail the later install proof.
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../../.." && pwd)"
bash "${root}/linux/scripts/06-packaging/elf-closure.sh" "$@"
while [[ "$1" != --lib-dir ]]; do shift; done
printf 'changed after the closure\n' >>"$2/helper worker-bin"
