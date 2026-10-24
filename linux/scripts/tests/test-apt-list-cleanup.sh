#!/usr/bin/env bash
# Cleanup probes use private apt-list fixtures and fake deletion; import/COPY checks cover companion wiring, not images.
set -u
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${TESTS_DIR}/test-workspace-fixture.sh"
# shellcheck source=linux/scripts/tests/gate-tree.sh
source "${TESTS_DIR}/gate-tree.sh"
declare WORK REPO_ROOT
t_fixture_workspace_init WORK REPO_ROOT || exit 1
OWNER="${1:-${TESTS_DIR}/../06-packaging/package-image-wiring.sh}"
TORCH="${2:-${TESTS_DIR}/../06-packaging/setup-torch-venv.sh}"
FIXTURE_APT="$WORK/apt lists"
mkdir -p "$FIXTURE_APT/lists"
: > "$FIXTURE_APT/lists/first list"
: > "$FIXTURE_APT/lists/second"
source_text="$(t_fn_src "$OWNER" clear_unmounted_apt_lists)" || exit 1
source_text="$(printf '%s\n' "$source_text" | sed 's|/var/lib/apt|"${FIXTURE_APT}"|g')"
_cleanup_case() (
  local mount_status="$1" remove_status="$2"
  eval "$source_text"
  mountpoint() { printf 'mount:%s\n' "$*" >> "$WORK/trace"; return "$mount_status"; }
  rm() { printf 'delete:%s\n' "$@" >> "$WORK/trace"; return "$remove_status"; }
  clear_unmounted_apt_lists
)
t_case "mounted apt lists are preserved without calling deletion"
: > "$WORK/trace"
t_assert_rc 0 _cleanup_case 0 11
t_assert_rc 1 grep -q '^delete:' "$WORK/trace"
t_case "unmounted apt lists retain glob expansion and spaced filenames"
: > "$WORK/trace"
t_assert_rc 0 _cleanup_case 1 0
t_assert_ok grep -Fxq "delete:$FIXTURE_APT/lists/first list" "$WORK/trace"
t_assert_ok grep -Fxq "delete:$FIXTURE_APT/lists/second" "$WORK/trace"
t_case "failed deletion retains its failing status"
t_assert_rc 11 _cleanup_case 1 11

fixture_root="$(gate_tree_here "$WORK" "$OWNER" 'copied torch/package-image-wiring.sh')"
bundle="$fixture_root/copied torch"
guard="$(awk '/^source_required_symbol clear_unmounted_apt_lists / { print; getline; print }' "$TORCH")"
t_case "Torch emits the mandatory companion import"
t_assert_contains "$guard" 'source_required_symbol clear_unmounted_apt_lists'
printf 'set -euo pipefail\nsource %q\n' "$TESTS_DIR/../01-core/module-bootstrap.sh" > "$bundle/worker.sh"
printf '%s\n' "$guard" | sed "s|/opt/scripts/packaging/package-image-wiring.sh|\"${bundle}/absent.sh\"|g" >> "$bundle/worker.sh"
printf 'declare -F clear_unmounted_apt_lists >/dev/null\n' >> "$bundle/worker.sh"
t_case "a standalone copy imports its actual helper companion"
t_assert_ok bash "$bundle/worker.sh"
rm "$bundle/package-image-wiring.sh"
t_case "a missing companion fails closed rather than supplying a private fallback"
t_assert_rc 1 bash "$bundle/worker.sh"
t_case "Docker copies the executable companion before running Torch setup"
t_assert_ok python3 - "$REPO_ROOT/linux/Dockerfile.torch" <<'PY'
from pathlib import Path
import sys
lines = Path(sys.argv[1]).read_text().splitlines()
copy = lines.index("COPY --chmod=755 linux/scripts/06-packaging/package-image-wiring.sh /opt/scripts/packaging/package-image-wiring.sh")
execute = next(i for i, line in enumerate(lines) if "bash /opt/scripts/packaging/setup-torch-venv.sh" in line)
assert copy < execute
PY
t_case "package cleanup retains cache-first ordering and shared list cleanup"
_package_cleanup_order() {
  case "$1" in
    *'mountpoint -q /var/cache/apt || apt-get clean'*'clear_unmounted_apt_lists'*) return 0 ;;
    *) return 1 ;;
  esac
}
t_assert_ok _package_cleanup_order "$(t_fn_src "$TESTS_DIR/../06-packaging/setup-package-image.sh" main)"

t_summary
