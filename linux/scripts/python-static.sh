#!/usr/bin/env bash
# Grades tracked Python with the hub's locked Ruff and ty; it does not install caller dependencies or run tests.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HUB_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
ROOT="${HUB_ROOT}"
SCOPE=.
MODE=report-only
ROOT_GIVEN=0
PATH_GIVEN=0
MODE_GIVEN=0
REPORT_DIR=""
SELECTED=()

usage() {
  cat <<'EOF'
Usage: bash linux/scripts/python-static.sh [--root DIR] [--path FILE_OR_DIR] [--report-only|--strict]

Only tracked .py files in the caller checkout are checked. The path is relative to that checkout;
the default '.' selects every tracked .py file. Findings are advisory in report-only mode, but
setup and scanner failures remain fatal. Strict mode fails on Ruff or ty findings. Reports stay
under the caller's ignored logs/code-quality/python-static/ directory.
EOF
}

die() { printf 'python-static: %s\n' "$*" >&2; exit 2; }

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --root|--path)
        [[ $# -gt 1 && -n "$2" ]] || die "$1 needs a value"
        if [[ "$1" == --root ]]; then
          [[ "$ROOT_GIVEN" -eq 0 ]] || die "--root was given twice"
          ROOT="$2"; ROOT_GIVEN=1
        else
          [[ "$PATH_GIVEN" -eq 0 ]] || die "--path was given twice"
          SCOPE="$2"; PATH_GIVEN=1
        fi
        shift 2
        ;;
      --report-only|--strict)
        [[ "$MODE_GIVEN" -eq 0 ]] || die "choose one mode"
        MODE="${1#--}"; MODE_GIVEN=1
        shift
        ;;
      -h|--help) usage; exit 0 ;;
      *) die "unknown argument: $1" ;;
    esac
  done
}

validate_root_scope() {
  [[ -f "$SCRIPT_DIR/01-core/lint-root.sh" ]] || die "the hub's tracked-file helper is missing"
  # shellcheck source=01-core/lint-root.sh
  source "$SCRIPT_DIR/01-core/lint-root.sh"
  lint_root_begin "$HUB_ROOT" --root "$ROOT" || die "target root is missing or not a Git checkout"
  ROOT="$LINT_ROOT_PATH"
  [[ -z "$(git -C "$ROOT" rev-parse --show-prefix)" ]] || die "--root must be the Git checkout top"
  git -C "$ROOT" check-ignore -q --no-index -- logs/code-quality/python-static/probe \
    || die "logs/code-quality/ must be ignored by the caller"
  [[ "$SCOPE" == . ]] && return 0
  SCOPE="${SCOPE%/}"
  case "$SCOPE" in
    ''|/*|./*|../*|*/../*|*/..|*/./*|*/.|*//*|*\\*) die "--path must be a canonical caller-relative path" ;;
  esac
  [[ ! -L "$ROOT/$SCOPE" && ( -d "$ROOT/$SCOPE" || -f "$ROOT/$SCOPE" ) ]] \
    || die "--path is missing or a symlink: $SCOPE"
}

select_files() {
  local file
  lint_root_tracked "$ROOT" '*.py' > "$REPORT_DIR/tracked-files.z" \
    || die "cannot enumerate tracked Python files"
  while IFS= read -r -d '' file; do
    if [[ "$SCOPE" == . || "$file" == "$SCOPE" || "$file" == "$SCOPE/"* ]]; then
      [[ -f "$ROOT/$file" && ! -L "$ROOT/$file" ]] || die "tracked Python file is missing or a symlink: $file"
      SELECTED+=("$file")
    fi
  done < "$REPORT_DIR/tracked-files.z"
  [[ "${#SELECTED[@]}" -gt 0 ]] || die "no tracked Python files under $SCOPE"
}

resolve_tool_bins() {
  local bin
  if [[ -x "$UV_PROJECT_ENVIRONMENT/bin/ruff" && -x "$UV_PROJECT_ENVIRONMENT/bin/ty" ]]; then
    bin="$UV_PROJECT_ENVIRONMENT/bin"
    RUFF_BIN="$bin/ruff"; TY_BIN="$bin/ty"
  elif [[ -x "$UV_PROJECT_ENVIRONMENT/Scripts/ruff.exe" && -x "$UV_PROJECT_ENVIRONMENT/Scripts/ty.exe" ]]; then
    bin="$UV_PROJECT_ENVIRONMENT/Scripts"
    RUFF_BIN="$bin/ruff.exe"; TY_BIN="$bin/ty.exe"
  else
    die "locked quality environment has no Ruff or ty executable"
  fi
}

check_tool_versions() {
  local version
  version="$("$RUFF_BIN" --version)" || die "Ruff version probe failed"
  [[ "$version" == "ruff $RUFF_VERSION" ]] || die "Ruff version differs from tool-pins.env: $version"
  version="$("$TY_BIN" --version)" || die "ty version probe failed"
  [[ "$version" == "ty $TY_VERSION"* ]] || die "ty version differs from tool-pins.env: $version"
}

setup_tools() {
  command -v uv >/dev/null 2>&1 || die "uv is required"
  [[ -f "$HUB_ROOT/quality/uv.lock" && -f "$HUB_ROOT/quality/pyproject.toml" ]] \
    || die "the hub's locked quality project is missing"
  [[ -f "$SCRIPT_DIR/01-core/tool-pins.env" && -f "$SCRIPT_DIR/01-core/load-versions-env.sh" ]] \
    || die "the hub's tool pins are missing"
  # shellcheck source=01-core/load-versions-env.sh
  source "$SCRIPT_DIR/01-core/load-versions-env.sh"
  unset RUFF_VERSION TY_VERSION
  load_versions_env "$SCRIPT_DIR/01-core/tool-pins.env"
  [[ -n "${RUFF_VERSION:-}" && -n "${TY_VERSION:-}" ]] || die "Ruff or ty pin is missing"
  export UV_PROJECT_ENVIRONMENT="$REPORT_DIR/.venv"
  uv sync --project "$HUB_ROOT/quality" --locked --python 3.14 > "$REPORT_DIR/setup.txt" 2>&1 \
    || { cat "$REPORT_DIR/setup.txt" >&2; die "locked quality setup failed"; }
  resolve_tool_bins
  check_tool_versions
}

run_scanner() {
  local name="$1" status=0
  shift
  "$@" > "$REPORT_DIR/$name.txt" 2>&1 || status=$?
  printf '%s exit=%s; full report: %s\n' "$name" "$status" "$REPORT_DIR/$name.txt"
  tail -n 8 "$REPORT_DIR/$name.txt"
  return "$status"
}

finding_count() {
  local tool="$1" kind count
  kind=error
  [[ "$tool" == ty ]] && kind=diagnostic
  count="$(awk -v kind="$kind" '$1 == "Found" && $3 ~ "^" kind { n=$2 } END { if (n != "") print n }' \
    "$REPORT_DIR/$tool.txt")" || die "cannot read $tool report"
  if [[ -n "$count" ]]; then printf '%s\n' "$count"; return 0; fi
  if grep -Fqx 'All checks passed!' "$REPORT_DIR/$tool.txt"; then printf '0\n'; return 0; fi
  printf 'unknown\n'
}

main() {
  local ruff_status=0 ty_status=0 ruff_findings ty_diagnostics
  local -a ruff_flags=() ty_flags=()
  parse_args "$@"
  validate_root_scope
  REPORT_DIR="$ROOT/logs/code-quality/python-static"
  mkdir -p "$REPORT_DIR" || die "cannot create report directory"
  select_files
  setup_tools
  [[ "$MODE" == strict ]] || { ruff_flags+=(--exit-zero); ty_flags+=(--exit-zero); }
  cd "$ROOT" || die "cannot enter target root"
  run_scanner ruff "$RUFF_BIN" check --no-fix --no-unsafe-fixes --output-format concise \
    "${ruff_flags[@]}" -- "${SELECTED[@]}" || ruff_status=$?
  run_scanner ty "$TY_BIN" check --project "$ROOT" --output-format concise --no-progress \
    "${ty_flags[@]}" -- "${SELECTED[@]}" || ty_status=$?
  ruff_findings="$(finding_count ruff)"
  ty_diagnostics="$(finding_count ty)"
  printf 'mode=%s path=%s files=%s\nruff-findings=%s ruff-exit=%s\nty-diagnostics=%s ty-exit=%s\n' \
    "$MODE" "$SCOPE" "${#SELECTED[@]}" "$ruff_findings" "$ruff_status" \
    "$ty_diagnostics" "$ty_status" | tee "$REPORT_DIR/summary.txt"
  [[ "$ruff_status" -eq 0 && "$ty_status" -eq 0 ]] || die "Python static analysis failed; see $REPORT_DIR"
}

main "$@"
