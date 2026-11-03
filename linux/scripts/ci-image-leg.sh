#!/usr/bin/env bash
# ci-image-leg.sh pinned|pinnedt <venv-dir> <cmd...> - runs cmd with uv bound to a fresh venv of the family image's X.Y or X.Yt, and refuses anywhere else.
set -euo pipefail

_LEG_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_leg_usage() { printf 'usage: ci-image-leg.sh pinned|pinnedt <venv-dir> <command...>\n' >&2; exit 2; }

mm="${PYTHON_MAJOR_MINOR:-}"
case "${1:-}" in
  pinned) leg="${mm}" ;;
  pinnedt) leg="${mm}t" ;;
  *) _leg_usage ;;
esac
[ "$#" -ge 3 ] && [ -n "$2" ] || _leg_usage
venv="$2"
shift 2
# Anywhere but the image, uv would download an interpreter the family does not pin.
if [ -z "${mm}" ] || ! command -v "python${leg}" >/dev/null 2>&1; then
  printf 'ci-image-leg.sh runs in the family Linux image, which ships python%s\n' "${leg:-X.Y}" >&2
  exit 2
fi

# shellcheck source=linux/scripts/01-core/python_uv.sh
source "${_LEG_DIR}/01-core/python_uv.sh"
# A fresh venv, never /opt/venv: its packages would leak into the project's run.
uv_venv_create "${venv}" "${leg}"
export UV_PYTHON_DOWNLOADS=never UV_PROJECT_ENVIRONMENT="${venv}" UV_PYTHON="${venv}/bin/python"
exec "$@"
