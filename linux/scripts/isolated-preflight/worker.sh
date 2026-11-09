#!/usr/bin/env bash
# Empty selection knobs keep the complete gate list and mutation registry in the proof.
set -euo pipefail
task_source="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
test "$UID" -ne 0
test "$(git -C "${task_source}" rev-parse HEAD)" = "${ISOLATED_PREFLIGHT_REVISION:?}"
test "${PREFLIGHT_ONLY:-}" = ''
test "${PREFLIGHT_SKIP:-}" = ''
test "${PREFLIGHT_MUTATION_SHARD:-}" = ''
ln -s /evidence "${task_source}/logs"
cd "${task_source}"
printf 'preflight revision=%s uid=%s\n' "$(git rev-parse HEAD)" "$UID"
for task_tool in jq shellcheck rsync ps cc readelf ldconfig patchelf pytest uv pwsh node chromium; do command -v "${task_tool}"; done
python3 -I -c 'import importlib.metadata, pathlib, sysconfig; print("pip", importlib.metadata.version("pip")); assert pathlib.Path(sysconfig.get_paths()["include"], "Python.h").is_file()'
exec make preflight
