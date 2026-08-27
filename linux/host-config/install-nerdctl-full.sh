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
#   - Backs up the current bin/ binaries AND the lib/systemd/system units the
#     bundle rewrites, so --rollback puts both back (it stops the rootful
#     services first and runs a system daemon-reload). SCOPE: the bundle also
#     ships libexec/ (CNI) and share/, and those stay at the NEW version after a
#     rollback, which is fine for the build path (nerdctl/buildkitd/containerd/
#     runc all live in bin/) but is not a full restore. To go all the way back,
#     re-run with NERDCTL_VERSION=<previous> instead.
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
  [ -f "${BACKUP_DIR}/VERSION" ] && log "backup was taken at: $(tr '\n' ' ' < "${BACKUP_DIR}/VERSION")"
  _rb_rootful=""
  for _u in containerd.service buildkit.service; do
    systemctl is-active --quiet "${_u}" 2>/dev/null && _rb_rootful="${_rb_rootful:+${_rb_rootful} }${_u}"
  done
  if [ -n "${_rb_rootful}" ]; then
    log "stopping rootful ${_rb_rootful} first (sudo) so they do not keep the old inode"
    # shellcheck disable=SC2086  # deliberate split: unit LIST
    sudo systemctl stop ${_rb_rootful} || warn "could not stop ${_rb_rootful}"
  fi
  log "restoring bin/ binaries (+ lib/systemd/system units, if backed up) from ${BACKUP_DIR}"
  log "note: libexec/ (CNI) and share/ stay at the installed version;"
  log "      for a full downgrade re-run with NERDCTL_VERSION=<previous> instead"
  systemctl --user stop buildkit.service containerd.service 2>/dev/null || true
  sudo cp -a "${BACKUP_DIR}/bin/." "${PREFIX}/bin/" \
    || err "restore failed — binaries may be inconsistent, re-run the installer"
  if [ -d "${BACKUP_DIR}/lib/systemd/system" ]; then
    sudo cp -a "${BACKUP_DIR}/lib/systemd/system/." "${PREFIX}/lib/systemd/system/" \
      && sudo systemctl daemon-reload \
      || warn "unit files not restored"
  fi
  systemctl --user start containerd.service buildkit.service 2>/dev/null || true
  if [ -n "${_rb_rootful}" ]; then
    # shellcheck disable=SC2086  # deliberate split: unit LIST
    sudo systemctl start ${_rb_rootful} || warn "could not restart ${_rb_rootful}"
  fi
  log "rolled back. Installed now: $(nerdctl --version 2>/dev/null || echo '?')"
  exit 0
fi

# ── refuse while a build runs ────────────────────────────────────────────────
# Own-process filter: this script's own command line contains the pattern.
# Widened after audit (2026-08-26): the original pattern matched only `nerdctl
# build` and the chain script, so a solve driven by `buildctl build` — or one
# where the client already exited while buildkitd keeps solving — looked idle.
# The cost of a miss is a killed multi-hour run, so this errs toward refusing.
_BUSY_PAT='nerdctl[^ ]* build|buildctl[^ ]* build|build-cross-chain\.sh'
_busy_procs() { pgrep -af "${_BUSY_PAT}" 2>/dev/null | grep -v 'install-nerdctl-full' || true; }

# The repo's own lifecycle pidfile is authoritative when it exists
# (linux/scripts/01-core/chain-lifecycle.sh:58). Read it defensively: an empty
# or garbage file must not become `kill -0 0`, which targets our own process
# group and would refuse every run.
_pidfile="${CROSS_CHAIN_PIDFILE:-${TMPDIR:-/tmp}/kata-cross-chain.pid}"
if [ -f "${_pidfile}" ]; then
  _chain_pid="$(tr -dc '0-9' < "${_pidfile}" 2>/dev/null || true)"
  if [ -n "${_chain_pid}" ] && [ "${_chain_pid}" -gt 1 ] 2>/dev/null \
     && kill -0 "${_chain_pid}" 2>/dev/null; then
    err "cross-chain pidfile ${_pidfile} names live pid ${_chain_pid} — refusing (stop it with linux/scripts/stop-cross-chain.sh)"
  fi
fi

if [ "$(_busy_procs | grep -c . || true)" -gt 0 ]; then
  _busy_procs | head -3 >&2
  err "a build is running — refusing (stop it with linux/scripts/stop-cross-chain.sh first)"
fi

# ── rootful coexistence ──────────────────────────────────────────────────────
# This host runs the ROOTLESS stack (systemd --user) and, from the SAME
# ${PREFIX}, a ROOTFUL containerd + buildkitd. Extracting the bundle replaces
# those root daemons' binaries AND their unit files under
# ${PREFIX}/lib/systemd/system out from under them. Measured here: GNU tar 1.35
# and `cp -a` BOTH unlink-and-recreate, so there is no ETXTBSY and no error —
# the running root daemons just keep executing the now-deleted old inode. Since
# both units are Restart=always, the real version jump then lands at some
# arbitrary unattended moment instead of in the window you picked. Refusing by
# default forces that to be a conscious choice.
_rootful_active=""
for _u in containerd.service buildkit.service; do
  if systemctl is-active --quiet "${_u}" 2>/dev/null; then
    _rootful_active="${_rootful_active:+${_rootful_active} }${_u}"
  fi
done

# ── resolve versions ─────────────────────────────────────────────────────────
CURRENT="$(nerdctl --version 2>/dev/null | awk '{print $NF}' || echo none)"
CUR_BUILDCTL="$(buildctl --version 2>/dev/null | grep -oE 'v[0-9]+\.[0-9]+\.[0-9]+' | head -1 || echo '?')"
# DAEMON-reported versions, captured BEFORE the swap. The on-disk client
# version proves only that tar ran; these prove the daemons actually restarted
# onto the new code, which is the thing that can silently not happen.
_bk_daemon_before="$(buildctl debug info 2>/dev/null | awk '/^BuildKit:/{print $3}' | head -1 || true)"
_cd_daemon_before="$(nerdctl info 2>/dev/null | awk -F': *' '/Server Version/{print $2}' | head -1 || true)"

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

# `nerdctl --version` prints "nerdctl version 2.3.4" — NO leading v — so the
# original `[ "${CURRENT}" = "v${TARGET}" ]` was never true: dead code. That
# mattered beyond a wasted re-install: a second run would re-do the upgrade and
# overwrite the backup with the ALREADY-NEW binaries, silently destroying the
# only path back to the previous release.
if [ "${CURRENT#v}" = "${TARGET#v}" ] && [ "${NERDCTL_FORCE:-0}" != "1" ]; then
  log "already on v${TARGET#v} — nothing to do (NERDCTL_FORCE=1 re-installs; note that doing so replaces the rollback backup)"
  exit 0
fi

# ── cache-mount census BEFORE (they must be untouched) ───────────────────────
# Same primitive prune-safe.sh uses: the type FILTER, not a text match on
# `buildctl du` (whose default output has no description column at all — an
# earlier version of this script grepped for "cached mount" and always got 0).
# Note `grep -c` prints 0 AND exits 1 on no match, so it takes `|| true`, never
# `|| echo 0` — the latter prints a SECOND zero.
# ── rootful decision ─────────────────────────────────────────────────────────
_rootful_plan=""; _rootful_reload=""
if [ -n "${_rootful_active}" ]; then
  _rootful_reload=" + system"
  if [ "${NERDCTL_INCLUDE_ROOTFUL:-0}" = "1" ]; then
    _rootful_plan=" + sudo systemctl stop ${_rootful_active}"
    log "rootful units active and INCLUDED: ${_rootful_active}"
  elif [ "${NERDCTL_IGNORE_ROOTFUL:-0}" = "1" ]; then
    warn "rootful units active and IGNORED: ${_rootful_active} — they keep executing the replaced (deleted) binaries until something restarts them"
  else
    # Block the ACT, not the look: a dry run must still be able to show the
    # plan and the choice, otherwise you cannot find out what you need to pick.
    _rootful_msg="rootful ${_rootful_active} run from ${PREFIX} and would be replaced underneath them. Pick one deliberately: NERDCTL_INCLUDE_ROOTFUL=1 (stop, upgrade and restart them together — no version skew) or NERDCTL_IGNORE_ROOTFUL=1 (accept that they keep running the old deleted inode until they restart, which under Restart=always happens unattended)."
    [ "${CONFIRM}" = "1" ] && err "${_rootful_msg}"
    warn "${_rootful_msg}"
    _rootful_plan=" + <BLOCKED: choose NERDCTL_INCLUDE_ROOTFUL=1 or NERDCTL_IGNORE_ROOTFUL=1>"
  fi
fi

# Readiness POLL, not a fixed sleep: buildkitd takes a variable few seconds and
# the old `sleep 3` could hand a not-yet-listening daemon to the verify block,
# where it reads as "0 cache mounts" and "not active".
_wait_ready() {
  local _label="$1" _timeout="$2"; shift 2
  local _end=$(( SECONDS + _timeout ))
  while [ "${SECONDS}" -lt "${_end}" ]; do
    if "$@" >/dev/null 2>&1; then return 0; fi
    sleep 2
  done
  warn "${_label} did not become ready within ${_timeout}s"
  return 1
}

# Two corrections found by audit (2026-08-26), both verified on this host:
#  1. `buildctl du` prints a HEADER row ("ID  RECLAIMABLE  SIZE  LAST ACCESSED"),
#     so `grep -c .` was counting it: the census over-reported by exactly one,
#     and a fully WIPED store would have read 1 rather than 0.
#  2. A daemon that is not answering also yields 0. Reported as a count, that is
#     indistinguishable from "the caches are gone" — and if the BEFORE count is
#     0, the after>=before comparison can never fail. So: unreachable is a
#     non-zero RETURN, never a count.
_count_cachemounts() {
  local _out
  _out="$(buildctl du --filter type==exec.cachemount 2>/dev/null)" || return 1
  printf '%s\n' "${_out}" | tail -n +2 | grep -c . || true
}
if ! _mounts_before="$(_count_cachemounts)"; then
  if [ "${NERDCTL_SKIP_CACHE_CENSUS:-0}" = "1" ]; then
    warn "buildkitd not answering on ${BUILDKIT_HOST}; continuing without a cache baseline (NERDCTL_SKIP_CACHE_CENSUS=1)"
    _mounts_before=-1
  else
    err "buildkitd is not answering on ${BUILDKIT_HOST} — refusing without a measurable cache baseline. Start it, or set NERDCTL_SKIP_CACHE_CENSUS=1 to accept the blind spot."
  fi
fi
if [ "${_mounts_before}" -ge 0 ]; then
  log "buildkit cache-mount records right now: ${_mounts_before} (upgrade must not change this)"
else
  log "buildkit cache-mount census: SKIPPED — the after-check cannot detect cache loss this run"
fi

if [ "${CONFIRM}" != "1" ]; then
  cat <<EOF
[nerdctl-full] DRY RUN — set NERDCTL_INSTALL_CONFIRM=1 to perform:
  1. download ${BASE_URL}/${TARBALL} + SHA256SUMS, verify the checksum
  2. back up ${PREFIX}/bin (+ lib/systemd/system if present) to ${BACKUP_DIR}
  3. systemctl --user stop buildkit.service containerd.service${_rootful_plan}
  4. sudo tar -C ${PREFIX} -xzf <tarball>     (bundle is root-owned)
  5. daemon-reload (user${_rootful_reload}) && start containerd, buildkit
  6. prove: buildkitd answers + lists a worker, daemon versions MOVED off
     (buildkit ${_bk_daemon_before:-?} / containerd ${_cd_daemon_before:-?}),
     cache-mount count still ${_mounts_before}
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
# The bundle also ships the ROOTFUL unit files, and tar rewrites them in place.
# Backing them up is what makes --rollback able to restore the root services'
# definitions instead of stranding the host on the new ones.
if [ -d "${PREFIX}/lib/systemd/system" ]; then
  mkdir -p "${BACKUP_DIR}/lib/systemd/system"
  cp -a "${PREFIX}/lib/systemd/system/." "${BACKUP_DIR}/lib/systemd/system/" 2>/dev/null || true
fi
# Record WHAT was backed up, so --rollback can say where it takes you.
printf 'nerdctl=%s\nbuildctl=%s\nbacked_up_from=%s\n' \
  "${CURRENT}" "${CUR_BUILDCTL}" "${PREFIX}" > "${BACKUP_DIR}/VERSION"
log "backed up $(find "${BACKUP_DIR}/bin" -type f | wc -l) binary/ies + $(find "${BACKUP_DIR}/lib" -name '*.service' 2>/dev/null | wc -l) unit(s) (nerdctl ${CURRENT})"

# ── stop, extract, start ─────────────────────────────────────────────────────
_ok=1

log "stopping user services"
systemctl --user stop buildkit.service containerd.service 2>/dev/null || true
if [ -n "${_rootful_active}" ] && [ "${NERDCTL_INCLUDE_ROOTFUL:-0}" = "1" ]; then
  log "stopping rootful ${_rootful_active} (sudo)"
  # shellcheck disable=SC2086  # deliberate split: _rootful_active is a unit LIST
  sudo systemctl stop ${_rootful_active} || warn "could not stop ${_rootful_active}"
fi
sleep 2

log "extracting into ${PREFIX} (sudo)"
if ! sudo tar -C "${PREFIX}" -xzf "${WORK}/${TARBALL}"; then
  warn "extraction failed — attempting restore from ${BACKUP_DIR}"
  # Do NOT swallow this: the old code sent the restore to /dev/null and then
  # announced "binaries restored from backup" whether or not it had worked.
  _restored=1
  sudo cp -a "${BACKUP_DIR}/bin/." "${PREFIX}/bin/" || _restored=0
  systemctl --user start containerd.service buildkit.service 2>/dev/null || true
  [ "${_restored}" = "1" ] && err "extraction failed; ${PREFIX}/bin restored from backup"
  err "extraction failed AND the restore failed too — ${PREFIX}/bin is INCONSISTENT. Recover with: bash $0 --rollback"
fi

log "starting services"
systemctl --user daemon-reload 2>/dev/null || true
# The bundle rewrote ${PREFIX}/lib/systemd/system/*.service. Without a SYSTEM
# daemon-reload those live root units keep an in-memory definition that no
# longer matches disk, and the change lands at whatever unrelated reload comes
# next (an apt install will do it). Do it here, in the window that was chosen.
if [ -d "${PREFIX}/lib/systemd/system" ]; then
  sudo systemctl daemon-reload || warn "system daemon-reload failed — root units may report NeedDaemonReload=yes"
fi
systemctl --user start containerd.service 2>/dev/null || warn "containerd.service did not start"
_wait_ready "containerd (rootless)" 60 nerdctl images || _ok=0
systemctl --user start buildkit.service 2>/dev/null || warn "buildkit.service did not start"
_wait_ready "buildkitd" 90 buildctl debug workers || _ok=0
if [ -n "${_rootful_active}" ] && [ "${NERDCTL_INCLUDE_ROOTFUL:-0}" = "1" ]; then
  log "starting rootful ${_rootful_active} (sudo)"
  # shellcheck disable=SC2086  # deliberate split: _rootful_active is a unit LIST
  sudo systemctl start ${_rootful_active} || warn "could not restart ${_rootful_active}"
fi

# ── prove it works ───────────────────────────────────────────────────────────
NEW="$(nerdctl --version 2>/dev/null | awk '{print $NF}' || echo '?')"
NEW_BUILDCTL="$(buildctl --version 2>/dev/null | grep -oE 'v[0-9]+\.[0-9]+\.[0-9]+' | head -1 || echo '?')"
log "now installed: nerdctl ${NEW} (buildctl ${NEW_BUILDCTL})"

systemctl --user is-active buildkit.service >/dev/null 2>&1 || { warn "buildkit.service not active"; _ok=0; }
nerdctl images >/dev/null 2>&1 || { warn "nerdctl cannot reach containerd"; _ok=0; }

# DAEMON-side proof. The on-disk client versions above only prove tar ran; a
# daemon that failed to restart keeps serving the old code from a deleted inode
# and would otherwise sail through this block.
_bk_daemon_after="$(buildctl debug info 2>/dev/null | awk '/^BuildKit:/{print $3}' | head -1 || true)"
_cd_daemon_after="$(nerdctl info 2>/dev/null | awk -F': *' '/Server Version/{print $2}' | head -1 || true)"
log "daemon versions: buildkit ${_bk_daemon_before:-?} → ${_bk_daemon_after:-?}, containerd ${_cd_daemon_before:-?} → ${_cd_daemon_after:-?}"
if [ -n "${_bk_daemon_before}" ] && [ "${_bk_daemon_before}" = "${_bk_daemon_after}" ]; then
  warn "buildkitd STILL reports ${_bk_daemon_after} — it did not restart onto the new binary"
  _ok=0
fi

# A buildkitd can answer and still have no usable worker; that passes
# `is-active` and fails every build. Assert the worker exists.
_workers="$(buildctl debug workers 2>/dev/null | tail -n +2 | grep -c . || true)"
log "buildkitd workers: ${_workers}"
if [ "${_workers:-0}" -lt 1 ]; then
  warn "buildkitd answers but lists NO worker — builds would fail"
  _ok=0
fi

# Cache-mount census. This used to only WARN, so an upgrade that ate hours of
# ccache/sccache still exited 0 and printed "done." It now fails the run.
if [ "${_mounts_before}" -ge 0 ]; then
  if ! _mounts_after="$(_count_cachemounts)"; then
    warn "buildkitd not answering for the after-census — cache state UNKNOWN"
    _ok=0
  else
    log "cache-mount records after: ${_mounts_after} (before: ${_mounts_before})"
    if [ "${_mounts_after}" -lt "${_mounts_before}" ]; then
      warn "cache-mount count DROPPED ${_mounts_before} → ${_mounts_after} — compile caches were lost (hours of ccache/sccache/cerbero). See linux/host-config/prune-safe.sh and the rebuild-disk-management notes."
      _ok=0
    fi
  fi
fi

if [ -n "${_rootful_active}" ] && [ "${NERDCTL_IGNORE_ROOTFUL:-0}" = "1" ]; then
  warn "rootful ${_rootful_active} were NOT restarted: they still execute the old, now-deleted binaries. Restart them deliberately (sudo systemctl restart ${_rootful_active}) rather than letting Restart=always do it unattended."
fi

if [ "${_ok}" != "1" ]; then
  warn "the stack did not come up cleanly. Roll back with: bash $0 --rollback"
  exit 1
fi

# ── QEMU binfmt: restarting the rootless stack DESTROYS it ────────────────────
# Learned the expensive way on 2026-08-27. Restarting containerd/buildkit
# rebuilds the rootlesskit namespace, and the QEMU binfmt registration lives
# INSIDE that namespace -- so it goes with it. Nothing complains: cross-compiled
# stages (media, android) never touch an emulator and ran green for 5.5 hours.
# The runtime stage then builds each wrapper ON its target platform, and both
# the arm64 and riscv64 builds died with a BuildKit step that emitted no output
# at all:
#   #8 ERROR: process "/dev/.buildkit_qemu_emulator bash -lc ..." exit code: 1
# Checking the HOST's /proc/sys/fs/binfmt_misc does not reveal this -- the
# registration is not there even on a perfectly healthy machine.
_binfmt_missing=""
for _h in qemu-aarch64 qemu-riscv64; do
  grep -qs '^enabled' "/proc/sys/fs/binfmt_misc/${_h}" 2>/dev/null && continue
  if [ -n "${_SETUPTOOL:-$(command -v containerd-rootless-setuptool.sh 2>/dev/null)}" ]; then
    "${_SETUPTOOL:-containerd-rootless-setuptool.sh}" nsenter -- \
      grep -qs '^enabled' "/proc/sys/fs/binfmt_misc/${_h}" 2>/dev/null && continue
  fi
  _binfmt_missing="${_binfmt_missing:+${_binfmt_missing} }${_h}"
done
if [ -n "${_binfmt_missing}" ]; then
  warn "QEMU binfmt handlers are GONE after the restart: ${_binfmt_missing}"
  warn "  Foreign-arch builds (the runtime stage) will fail with an EMPTY BuildKit error."
  warn "  Re-register now -- no sudo needed:"
  warn "      bash linux/scripts/setup-rootless-binfmt.sh"
else
  log "QEMU binfmt handlers survived the restart (or were never registered here)."
fi

log "done. Re-run linux/host-config/verify-host-config.sh and preflight.sh before the next chain."
