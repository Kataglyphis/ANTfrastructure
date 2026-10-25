#!/usr/bin/env bash
# Build-time ty checks one probe against the assembled venv; runtime imports and foreign-arch packages remain smoke-tested separately.
set -euo pipefail

venv="${1:?assembled venv path required}"
probe="${2:?probe path required}"
pins="${3:?tool pin file required}"

[ -x "${venv}/bin/python" ] || { echo "ty venv probe: missing interpreter at ${venv}/bin/python" >&2; exit 2; }
[ -f "${probe}" ] || { echo "ty venv probe: missing source at ${probe}" >&2; exit 2; }
[ -f "${pins}" ] || { echo "ty venv probe: missing tool pins at ${pins}" >&2; exit 2; }
# shellcheck source=linux/scripts/01-core/load-ty-tool.sh
source "$(dirname "${BASH_SOURCE[0]}")/load-ty-tool.sh"
load_ty_tool "${pins}"

uvx "ty@${TY_VERSION}" check --python "${venv}/bin/python" --python-platform linux \
  --output-format concise "${probe}"
