#!/usr/bin/env bash
set -euo pipefail
# verify-ubuntu-mirror-consistency.sh - Check that every Dockerfile has the
# canonical Ubuntu mirror ARGs, and that Dockerfile.base has the mirror RUN.
# ALSO asserts the mirror SCHEME outcome (APT-HTTP, 2026-08-24): the original
# check only proved use-fast-ubuntu-mirror.sh was *referenced*, which is
# exactly how the bootstrap-ca http downgrade shipped with no restore for
# custom mirrors and nobody noticed. Referenced != restored — so this gate now
# runs the real downgrade+restore pipeline against a fixture and requires the
# sources to END on https, and requires bootstrap_ca to call the restore AFTER
# the ca-certificates install.

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
errors=0

echo "=== Ubuntu mirror consistency check ==="

DOCKERFILES=(
  linux/Dockerfile.base
  linux/Dockerfile.toolchain
  linux/Dockerfile.sdk
  linux/Dockerfile.media
  linux/Dockerfile.android
  linux/Dockerfile.package
  linux/Dockerfile.torch
)

REQUIRED_ARGS=(
  "USE_FAST_UBUNTU_MIRROR"
  "FAST_UBUNTU_MIRROR_URL"
  "FAST_UBUNTU_PORTS_MIRROR_URL"
)

for df in "${DOCKERFILES[@]}"; do
  df_path="${REPO_ROOT}/${df}"
  [ -f "$df_path" ] || continue

  for arg in "${REQUIRED_ARGS[@]}"; do
    if ! grep -q "ARG ${arg}" "$df_path"; then
      echo "ERROR: ${df} is missing ARG ${arg}" >&2
      errors=$((errors + 1))
    fi
  done

  # Mirror RUN is only required in Dockerfile.base (downstream images inherit it)
  if [ "${df}" = "linux/Dockerfile.base" ]; then
    if ! grep -q 'use-fast-ubuntu-mirror.sh' "$df_path"; then
      echo "ERROR: ${df} is missing use-fast-ubuntu-mirror.sh RUN" >&2
      errors=$((errors + 1))
    fi
  fi
done

# --- SCHEME outcome (APT-HTTP) ------------------------------------------
BASE_IMAGE_SH="${REPO_ROOT}/linux/scripts/01-core/base-image.sh"
FAST_MIRROR_SH="${REPO_ROOT}/linux/scripts/01-core/use-fast-ubuntu-mirror.sh"

# (1) Wiring: bootstrap_ca must call restore_mirror_https_scheme, and the call
# must come after the ca-certificates install line — a working-but-unwired
# restore function is exactly the failure mode this gate exists to catch.
# NB: `|| true` on the grep pipelines — a no-match grep would otherwise abort
# the whole gate under set -eo pipefail WITHOUT printing the ERROR line
# (observed in mutation testing: rc=1 but silent).
bootstrap_body="$(awk '/^bootstrap_ca\(\)/,/^}/' "${BASE_IMAGE_SH}")"
install_ln="$(printf '%s\n' "${bootstrap_body}" | { grep -n 'apt-get install -y --no-install-recommends ca-certificates' || true; } | head -1 | cut -d: -f1)"
restore_ln="$(printf '%s\n' "${bootstrap_body}" | { grep -n '^  restore_mirror_https_scheme$' || true; } | head -1 | cut -d: -f1)"
if [ -z "${restore_ln}" ]; then
  echo "ERROR: bootstrap_ca does not call restore_mirror_https_scheme — the CA-bootstrap http downgrade is never undone" >&2
  errors=$((errors + 1))
elif [ -z "${install_ln}" ] || [ "${restore_ln}" -le "${install_ln}" ]; then
  echo "ERROR: restore_mirror_https_scheme must run AFTER the ca-certificates install in bootstrap_ca (restore@${restore_ln:-?} vs install@${install_ln:-?})" >&2
  errors=$((errors + 1))
fi

# (2) Outcome: run the REAL pipeline on a fixture — bootstrap-style downgrade
# via use-fast-ubuntu-mirror.sh, then the restore subcommand — and assert the
# sources end on https with no downgraded http entry left.
fixture_root="$(mktemp -d)"
trap 'rm -rf "${fixture_root}"' EXIT
mkdir -p "${fixture_root}/etc/apt/sources.list.d"
printf 'Types: deb\nURIs: http://archive.ubuntu.com/ubuntu/\nSuites: resolute\nComponents: main\n' \
  > "${fixture_root}/etc/apt/sources.list.d/ubuntu.sources"

USE_FAST_UBUNTU_MIRROR=true \
FAST_UBUNTU_MIRROR_URL=http://mirror.invalid/ubuntu/ \
UBUNTU_SOURCES_ROOT="${fixture_root}" \
  bash "${FAST_MIRROR_SH}" >/dev/null

if ! grep -q '^URIs: http://mirror.invalid/ubuntu/$' "${fixture_root}/etc/apt/sources.list.d/ubuntu.sources"; then
  echo "ERROR: fixture precondition failed — bootstrap-style downgrade did not land (use-fast-ubuntu-mirror.sh behavior changed?)" >&2
  errors=$((errors + 1))
elif ! USE_FAST_UBUNTU_MIRROR=true \
       FAST_UBUNTU_MIRROR_URL=https://mirror.invalid/ubuntu/ \
       UBUNTU_SOURCES_ROOT="${fixture_root}" \
       bash "${BASE_IMAGE_SH}" restore-mirror-scheme >/dev/null; then
  echo "ERROR: base-image.sh restore-mirror-scheme failed on the fixture" >&2
  errors=$((errors + 1))
else
  if ! grep -q '^URIs: https://mirror.invalid/ubuntu/$' "${fixture_root}/etc/apt/sources.list.d/ubuntu.sources" \
     || grep -q 'http://mirror.invalid' "${fixture_root}/etc/apt/sources.list.d/ubuntu.sources"; then
    echo "ERROR: mirror SCHEME not restored — after downgrade+restore the fixture sources are:" >&2
    sed 's/^/    /' "${fixture_root}/etc/apt/sources.list.d/ubuntu.sources" >&2
    errors=$((errors + 1))
  fi
fi

# --- (3) POCKET SYMMETRY -------------------------------------------------
# Host and ports sources must expose the SAME suite set. An amd64 stanza
# written without -security while ports had it made every Multi-Arch:same
# library uninstallable for the foreign arch (VK2, 2026-09-08) -- and each
# file is perfectly valid on its own, so only the pair can be checked.
# docs/cross-build-verification.md#host-and-target-apt-sources-must-expose-the-same-pockets

# shellcheck source=/dev/null
. "${REPO_ROOT}/linux/scripts/01-core/ubuntu-mirror.sh"
_fixture_suites() {
  ubuntu_write_deb822_source "${fixture_root}/$1.sources" "https://$1.invalid/" resolute "$2" 1
  sed -n 's/^Suites: //p' "${fixture_root}/$1.sources"
}
_fixture_suites host amd64    > "${fixture_root}/host.suites"
_fixture_suites ports riscv64 > "${fixture_root}/ports.suites"
if ! cmp -s "${fixture_root}/host.suites" "${fixture_root}/ports.suites" \
   || ! [ -s "${fixture_root}/host.suites" ]; then
  echo "ERROR: ubuntu_write_deb822_source is asymmetric for equal flags (host vs ports):" >&2
  diff -u "${fixture_root}/host.suites" "${fixture_root}/ports.suites" | sed 's/^/    /' >&2
  errors=$((errors + 1))
fi

# Shipped call sites must agree on that flag. Tests and this file are excluded
# on purpose: their calls are fixtures, free to be deliberately skewed.
if ! _flag_report="$(python3 - "${REPO_ROOT}/linux" <<'PYEOF'
import pathlib
import re
import shlex
import sys

root = pathlib.Path(sys.argv[1])
sites, unparsable = {}, []
for path in sorted(root.rglob("*")):
    if not path.is_file() or "scripts/tests/" in path.as_posix():
        continue
    if path.name == "verify-ubuntu-mirror-consistency.sh":
        continue
    if not (path.name.startswith("Dockerfile") or path.suffix == ".sh"):
        continue
    try:
        text = path.read_text(encoding="utf-8")
    except (OSError, UnicodeDecodeError):
        continue
    if "ubuntu_write_deb822_source " not in text:
        continue
    joined, start, buffer = [], 0, ""
    for lineno, raw in enumerate(text.splitlines(), 1):
        if not buffer:
            start = lineno
        if raw.endswith("\\"):
            buffer += raw[:-1] + " "
            continue
        joined.append((start, buffer + raw))
        buffer = ""
    if buffer:
        joined.append((start, buffer))
    for lineno, line in joined:
        if line.lstrip().startswith("#"):
            continue
        for chunk in re.split(r"[;&|]", line):
            if "ubuntu_write_deb822_source" not in chunk:
                continue
            try:
                tokens = shlex.split(chunk, posix=True)
            except ValueError:
                unparsable.append(f"{path.relative_to(root)}:{lineno}")
                continue
            if "ubuntu_write_deb822_source" not in tokens:
                continue
            args = tokens[tokens.index("ubuntu_write_deb822_source") + 1:]
            flag = args[4] if len(args) >= 5 else "1"
            sites.setdefault(flag, []).append(f"{path.relative_to(root)}:{lineno}")

if unparsable:
    print("UNPARSABLE " + " ".join(unparsable))
    sys.exit(1)
if not sites:
    print("NOSITES")
    sys.exit(1)
if len(sites) > 1:
    print("SKEW " + "  ".join(
        f"{flag}={','.join(where)}" for flag, where in sorted(sites.items())))
    sys.exit(1)
print("OK " + next(iter(sites)))
PYEOF
)"; then
  echo "ERROR: ubuntu_write_deb822_source call sites do not agree on the -security flag: ${_flag_report}" >&2
  errors=$((errors + 1))
fi

if [ "$errors" -gt 0 ]; then
  echo "FAILED: ${errors} mirror consistency errors" >&2
  exit 1
fi
echo "PASSED: Ubuntu mirror pattern consistent across all Dockerfiles; CA-bootstrap downgrade provably restored to https"
