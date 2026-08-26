#!/usr/bin/env bash
# ==============================================================================
# install-nerdctl-full.sh — install/upgrade the nerdctl-full bundle on this host.
#
# nerdctl-full ships nerdctl TOGETHER WITH the whole stack it drives: containerd,
# BuildKit (buildkitd + buildctl), runc, CNI plugins, the snapshotters and the
# rootless helpers. That coupling is the point — upgrading buildkitd on this host
# means upgrading the bundle, because the pieces are version-matched.
#
# WHY A SCRIPT (2026-08-26): the chain hit BKD1 (buildkitd session rot: export
# hangs, "no active session", a lost layer blob) THREE times in one rebuild,
# costing hours each. Upstream has no fix for the rot itself, but newer releases
# carry adjacent concurrency fixes — and this host builds three arches in
# parallel, which is exactly that load class. Upgrading by hand is a sequence of
# stop-services / extract-over-/usr/local / restart steps that is easy to get
# half-right, and a half-extracted bundle fails much later with a confusing
# symptom (see docs/linux-host-setup.md B4).
#
# SAFETY MODEL
#   - REFUSES while a build is running. Extracting over live binaries mid-chain
#     would kill hours of work; this host regularly builds for 10+ hours.
#   - DRY RUN by default: prints the version delta and the exact plan.
#     NERDCTL_INSTALL_CONFIRM=1 performs it.
#   - Verifies the release SHA256 before touching anything.
#   - Backs up the current binaries so a bad upgrade is reversible (--rollback).
#   - Stops the user services first and restarts them after, then PROVES the
#     stack answers (nerdctl version / buildctl du) instead of assuming.
#   - Cache mounts live in buildkit's state dir (~/.local/share/buildkit), NOT
#     in /usr/local, so an upgrade does not touch ccache/sccache/cerbero caches.
#     The script still counts them before and after and says so.
#
# USAGE
#   bash linux/host-config/install-nerdctl-full.sh              # dry run
#   NERDCTL_INSTALL_CONFIRM=1 bash .../install-nerdctl-full.sh  # do it
#   NERDCTL_VERSION=2.3.5 ... (default: latest release)
#   bash .../install-nerdctl-full.sh --rollback                 # restore backup
#
# Requires sudo for the extraction into /usr/local (the bundle is root-owned).
# ==============================================================================
set -euo pipefail

PREFIX="${NERDCTL_PREFIX:-/usr/local}"
BACKUP_DIR="${NERDCTL_BACKUP_DIR:-${HOME}/.cache/nerdctl-full-backup}"
CONFIRM="${NERDCTL_INSTALL_CONFIRM:-0}"
REPO="containerd/nerdctl"
# buildctl needs the rootless socket like prune-safe.sh:30 does — without it the
# census silently reads 0 and the "did the upgrade eat my caches?" check becomes
# a gate that cannot fail.
export BUILDKIT_HOST="${BUILDKIT_HOST:-unix:///run/user/$(id -u)/buildkit/buildkitd.sock}"

log()  { printf '[nerdctl-full] %s\n' "$*"; }
warn() { printf '[nerdctl-full] WARNING: %s\n' "$*" >&2; }
err()  { printf '[nerdctl-full] ERROR: %s\n' "$*" >&2; exit 1; }

# ── rollback ─────────────────────────────────────────────────────────────────
if [ "${1:-}" = "--rollback" ]; then
  [ -d "${BACKUP_DIR}" ] || err "no backup at ${BACKUP_DIR}"
  log "restoring binaries from ${BACKUP_DIR}"
  systemctl --user stop buildkit.service containerd.service 2>/dev/null || true
  sudo cp -a "${BACKUP_DIR}/bin/." "${PREFIX}/bin/" \
    || err "restore failed — binaries may be inconsistent, re-run the installer"
  systemctl --user start containerd.service buildkit.service 2>/dev/null || true
  log "rolled back. Installed now: $(nerdctl --version 2>/dev/null || echo '?')"
  exit 0
fi

# ── refuse while a build runs ────────────────────────────────────────────────
# Own-process filter: this script's own command line contains the pattern.
_busy="$(pgrep -af 'nerdctl build|build-cross-chain\.sh' 2>/dev/null \
         | grep -v "install-nerdctl-full" | grep -vc '^$' || true)"
if [ "${_busy:-0}" -gt 0 ]; then
  pgrep -af 'nerdctl build|build-cross-chain\.sh' | grep -v install-nerdctl-full | head -3 >&2
  err "a build is running — refusing (stop it with linux/scripts/stop-cross-chain.sh first)"
fi

# ── resolve versions ─────────────────────────────────────────────────────────
CURRENT="$(nerdctl --version 2>/dev/null | awk '{print $NF}' || echo none)"
CUR_BUILDCTL="$(buildctl --version 2>/dev/null | grep -oE 'v[0-9]+\.[0-9]+\.[0-9]+' | head -1 || echo '?')"

if [ -n "${NERDCTL_VERSION:-}" ]; then
  TARGET="${NERDCTL_VERSION#v}"
else
  TARGET="$(curl -fsSL --connect-timeout 15 \
             "https://api.github.com/repos/${REPO}/releases/latest" 2>/dev/null \
            | python3 -c 'import sys,json;print(json.load(sys.stdin)["tag_name"].lstrip("v"))' 2>/dev/null || true)"
  [ -n "${TARGET}" ] || err "could not resolve the latest release (set NERDCTL_VERSION=x.y.z)"
fi

ARCH="$(uname -m)"
case "${ARCH}" in
  x86_64)  REL_ARCH=amd64 ;;
  aarch64) REL_ARCH=arm64 ;;
  riscv64) REL_ARCH=riscv64 ;;
  *) err "unsupported host arch ${ARCH}" ;;
esac

TARBALL="nerdctl-full-${TARGET}-linux-${REL_ARCH}.tar.gz"
BASE_URL="https://github.com/${REPO}/releases/download/v${TARGET}"

log "installed : nerdctl ${CURRENT} (buildctl ${CUR_BUILDCTL})"
log "target    : nerdctl v${TARGET} → ${TARBALL}"

if [ "${CURRENT}" = "v${TARGET}" ]; then
  log "already on v${TARGET} — nothing to do (set NERDCTL_VERSION to force a specific release)"
  exit 0
fi

# ── cache-mount census BEFORE (they must be untouched) ───────────────────────
# Same primitive prune-safe.sh uses: the type FILTER, not a text match on
# `buildctl du` (whose default output has no description column at all — an
# earlier version of this script grepped for "cached mount" and always got 0).
# Note `grep -c` prints 0 AND exits 1 on no match, so it takes `|| true`, never
# `|| echo 0` — the latter prints a SECOND zero.
_count_cachemounts() {
  buildctl du --filter type==exec.cachemount 2>/dev/null | grep -c . || true
}
_mounts_before="$(_count_cachemounts)"
log "buildkit cache-mount records right now: ${_mounts_before} (upgrade must not change this)"

if [ "${CONFIRM}" != "1" ]; then
  cat <<EOF
[nerdctl-full] DRY RUN — set NERDCTL_INSTALL_CONFIRM=1 to perform:
  1. download ${BASE_URL}/${TARBALL} + SHA256SUMS, verify the checksum
  2. back up ${PREFIX}/bin binaries to ${BACKUP_DIR}
  3. systemctl --user stop buildkit.service containerd.service
  4. sudo tar -C ${PREFIX} -xzf <tarball>     (bundle is root-owned)
  5. systemctl --user daemon-reload && start containerd, buildkit
  6. verify: nerdctl version, buildctl du, cache-mount count == ${_mounts_before}
Rollback afterwards: bash \$0 --rollback
EOF
  exit 0
fi

# ── download + verify ────────────────────────────────────────────────────────
WORK="$(mktemp -d)"; trap 'rm -rf "${WORK}"' EXIT
log "downloading ${TARBALL} …"
curl -fSL --retry 3 --retry-all-errors --connect-timeout 20 \
  -o "${WORK}/${TARBALL}" "${BASE_URL}/${TARBALL}" || err "download failed"
curl -fsSL --retry 3 --connect-timeout 20 \
  -o "${WORK}/SHA256SUMS" "${BASE_URL}/SHA256SUMS" \
  || err "could not fetch SHA256SUMS — refusing to install unverified bytes"

_want="$(awk -v f="${TARBALL}" '$2 == f || $2 == "*"f {print $1}' "${WORK}/SHA256SUMS" | head -1)"
[ -n "${_want}" ] || err "no checksum for ${TARBALL} in SHA256SUMS — refusing"
_have="$(sha256sum "${WORK}/${TARBALL}" | awk '{print $1}')"
[ "${_want}" = "${_have}" ] || err "CHECKSUM MISMATCH (want ${_want}, have ${_have}) — refusing"
log "checksum OK (${_have})"

# ── backup ───────────────────────────────────────────────────────────────────
log "backing up current binaries → ${BACKUP_DIR}"
rm -rf "${BACKUP_DIR}"; mkdir -p "${BACKUP_DIR}/bin"
# Only the files the bundle actually ships, so the backup restores like-for-like.
tar -tzf "${WORK}/${TARBALL}" | grep '^bin/' | sed 's|^bin/||' | while read -r f; do
  [ -f "${PREFIX}/bin/${f}" ] && cp -a "${PREFIX}/bin/${f}" "${BACKUP_DIR}/bin/" || true
done
log "backed up $(find "${BACKUP_DIR}/bin" -type f | wc -l) binary/ies"

# ── stop, extract, start ─────────────────────────────────────────────────────
log "stopping user services"
systemctl --user stop buildkit.service containerd.service 2>/dev/null || true
sleep 2

log "extracting into ${PREFIX} (sudo)"
sudo tar -C "${PREFIX}" -xzf "${WORK}/${TARBALL}" || {
  warn "extraction failed — attempting rollback"
  sudo cp -a "${BACKUP_DIR}/bin/." "${PREFIX}/bin/" 2>/dev/null || true
  systemctl --user start containerd.service buildkit.service 2>/dev/null || true
  err "extraction failed; binaries restored from backup"
}

log "starting user services"
systemctl --user daemon-reload 2>/dev/null || true
systemctl --user start containerd.service 2>/dev/null || warn "containerd.service did not start"
sleep 2
systemctl --user start buildkit.service 2>/dev/null || warn "buildkit.service did not start"
sleep 3

# ── prove it works ───────────────────────────────────────────────────────────
NEW="$(nerdctl --version 2>/dev/null | awk '{print $NF}' || echo '?')"
NEW_BUILDCTL="$(buildctl --version 2>/dev/null | grep -oE 'v[0-9]+\.[0-9]+\.[0-9]+' | head -1 || echo '?')"
log "now installed: nerdctl ${NEW} (buildctl ${NEW_BUILDCTL})"

_ok=1
systemctl --user is-active buildkit.service >/dev/null 2>&1 || { warn "buildkit.service not active"; _ok=0; }
nerdctl images >/dev/null 2>&1 || { warn "nerdctl cannot reach containerd"; _ok=0; }
_mounts_after="$(_count_cachemounts)"
log "cache-mount records after: ${_mounts_after} (before: ${_mounts_before})"
[ "${_mounts_after}" -ge "${_mounts_before}" ] \
  || warn "cache-mount count DROPPED — compile caches may have been lost (see rebuild-disk-management notes)"

if [ "${_ok}" != "1" ]; then
  warn "the stack did not come up cleanly. Roll back with: bash $0 --rollback"
  exit 1
fi
log "done. Re-run linux/host-config/verify-host-config.sh and preflight.sh before the next chain."
