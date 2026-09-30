#!/usr/bin/env bash
# Installs or upgrades nerdctl-full, dry run unless NERDCTL_INSTALL_CONFIRM=1: docs/linux-host-setup.md#b3b-install-or-upgrade-nerdctl-full
set -euo pipefail

UNIT_DIR="${NERDCTL_UNIT_DIR:-${HOME}/.config/systemd/user}"

# The live units' ExecStart is the authority on the prefix: installing elsewhere replaces binaries no unit launches.
_unit_execstart_prefix() {
  local u p
  for u in containerd.service buildkit.service; do
    [ -f "${UNIT_DIR}/${u}" ] || continue
    p="$(sed -n 's/^ExecStart="\{0,1\}\([^" ]*\)\/bin\/.*/\1/p' "${UNIT_DIR}/${u}" | head -1)"
    [ -n "${p}" ] && { printf '%s\n' "${p}"; return 0; }
  done
  return 1
}
DETECTED_PREFIX="$(_unit_execstart_prefix || true)"

if [ -n "${NERDCTL_ROOTLESS:-}" ]; then
  ROOTLESS="${NERDCTL_ROOTLESS}"
elif [ -n "${DETECTED_PREFIX}" ] && [ "${DETECTED_PREFIX#"${HOME}"}" != "${DETECTED_PREFIX}" ]; then
  ROOTLESS=1
else
  ROOTLESS=0
fi

if [ "${ROOTLESS}" = "1" ]; then
  PREFIX="${NERDCTL_PREFIX:-${DETECTED_PREFIX:-${HOME}/.local}}"
else
  PREFIX="${NERDCTL_PREFIX:-/usr/local}"
fi

# Rootless targets are user-owned; requiring sudo there made unattended runs impossible.
_as_root() { if [ "${ROOTLESS}" = "1" ]; then "$@"; else sudo "$@"; fi; }
_daemon_reload() {
  if [ "${ROOTLESS}" = "1" ]; then systemctl --user daemon-reload
  else sudo systemctl daemon-reload; fi
}

BACKUP_DIR="${NERDCTL_BACKUP_DIR:-${HOME}/.cache/nerdctl-full-backup}"
CONFIRM="${NERDCTL_INSTALL_CONFIRM:-0}"
REPO="containerd/nerdctl"
# Without the rootless socket the cache census reads 0 and can never fail.
export BUILDKIT_HOST="${BUILDKIT_HOST:-unix:///run/user/$(id -u)/buildkit/buildkitd.sock}"

log()  { printf '[nerdctl-full] %s\n' "$*"; }
warn() { printf '[nerdctl-full] WARNING: %s\n' "$*" >&2; }
err()  { printf '[nerdctl-full] ERROR: %s\n' "$*" >&2; exit 1; }

# Units keep their absolute ExecStart, and containerd-rootless.sh finds its helpers via PATH, so both follow the prefix.
_repoint_unit() { # _repoint_unit <unit-file>
  local f="$1" before
  [ -f "${f}" ] || { warn "no ${f} — nothing to repoint (run containerd-rootless-setuptool.sh install first)"; return 0; }
  before="$(cat "${f}")"
  UNIT_PREFIX="${PREFIX}" python3 - "${f}" <<'PY'
import os, re, sys
p, pref = sys.argv[1], os.environ["UNIT_PREFIX"]
t = open(p).read()
# [^"\s] not [^" ] — a bare space class still matches NEWLINES, so the first
# version of this ate the following ExecReload= line and produced
# `ExecStart=<prefix>/bin/kill -s HUP $MAINPID` (status=203/EXEC, 2026-09-08).
t = re.sub(r'(?m)^(ExecStart="?)/[^"\s]*/bin/', lambda m: m.group(1) + pref + "/bin/", t)
def path(m):
    keep = [e for e in m.group(1).split(":") if e and e != pref + "/bin"]
    return "Environment=PATH=" + ":".join([pref + "/bin"] + keep)
t = re.sub(r'(?m)^Environment=PATH=(.*)$', path, t)
open(p, "w").write(t)
PY
  [ "${before}" = "$(cat "${f}")" ] && return 0
  log "repointed $(basename "${f}") -> ${PREFIX}/bin"
}

_repoint_user_units() {
  local u
  for u in containerd.service buildkit.service; do
    _repoint_unit "${UNIT_DIR}/${u}"
  done
  _daemon_reload || warn "user daemon-reload failed"
}

# A drop-in ExecStart wins over the unit's, so a stale override.conf silently reverts buildkitd's prefix.
_check_dropin_prefix() {
  local d="${UNIT_DIR}/buildkit.service.d/override.conf"
  [ -f "${d}" ] || return 0
  grep -q "ExecStart=\"\{0,1\}${PREFIX}/bin/" "${d}" && return 0
  warn "${d} pins an ExecStart outside ${PREFIX} — it OVERRIDES the unit file. Re-run: bash linux/host-config/apply-host-config.sh"
  return 1
}

# Rollback: bin/ and units only; libexec/ and share/ stay new, so a full downgrade reinstalls NERDCTL_VERSION=<previous>
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
  _as_root cp -a "${BACKUP_DIR}/bin/." "${PREFIX}/bin/" \
    || err "restore failed — binaries may be inconsistent, re-run the installer"
  if [ -d "${BACKUP_DIR}/lib/systemd/system" ]; then
    _as_root cp -a "${BACKUP_DIR}/lib/systemd/system/." "${PREFIX}/lib/systemd/system/" \
      && _daemon_reload \
      || warn "unit files not restored"
  fi
  if [ -d "${BACKUP_DIR}/systemd-user" ]; then
    cp -a "${BACKUP_DIR}/systemd-user/." "${UNIT_DIR}/" && systemctl --user daemon-reload \
      || warn "systemd --user units not restored"
  fi
  systemctl --user start containerd.service buildkit.service 2>/dev/null || true
  if [ -n "${_rb_rootful}" ]; then
    # shellcheck disable=SC2086  # deliberate split: unit LIST
    sudo systemctl start ${_rb_rootful} || warn "could not restart ${_rb_rootful}"
  fi
  log "rolled back. Installed now: $(nerdctl --version 2>/dev/null || echo '?')"
  exit 0
fi

# Refuse while a build runs: a miss kills a multi-hour run, so the pattern errs toward refusing.
_BUSY_PAT='nerdctl[^ ]* build|buildctl[^ ]* build|build-cross-chain\.sh'
_busy_procs() { pgrep -af "${_BUSY_PAT}" 2>/dev/null | grep -v 'install-nerdctl-full' || true; }

# chain-lifecycle.sh's pidfile is authoritative; a garbage file must not become `kill -0 0`, our own process group.
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

# Rootful daemons on the same prefix keep running deleted inodes after extraction; not reachable from a rootless prefix.
_rootful_active=""
if [ "${ROOTLESS}" != "1" ]; then
  for _u in containerd.service buildkit.service; do
    if systemctl is-active --quiet "${_u}" 2>/dev/null; then
      _rootful_active="${_rootful_active:+${_rootful_active} }${_u}"
    fi
  done
fi

# Resolve versions
CURRENT="$(nerdctl --version 2>/dev/null | awk '{print $NF}' || echo none)"
CUR_BUILDCTL="$(buildctl --version 2>/dev/null | grep -oE 'v[0-9]+\.[0-9]+\.[0-9]+' | head -1 || echo '?')"
# Daemon-reported versions: the client version only proves tar ran, not that the daemons restarted.
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
if [ "${ROOTLESS}" = "1" ]; then
  log "mode      : ROOTLESS, prefix ${PREFIX} (no sudo anywhere)"
else
  log "mode      : root-owned prefix ${PREFIX} (extraction needs sudo)"
fi
[ -n "${DETECTED_PREFIX}" ] && [ "${DETECTED_PREFIX}" != "${PREFIX}" ] \
  && warn "the systemd --user units currently name ${DETECTED_PREFIX}, not ${PREFIX} — installing here cannot move the running daemons unless the units are repointed"

# Compare without the v: a re-run of the same version would overwrite the backup with the new binaries.
if [ "${CURRENT#v}" = "${TARGET#v}" ] && [ -x "${PREFIX}/bin/nerdctl" ] && [ "${NERDCTL_FORCE:-0}" != "1" ]; then
  # Units left on another prefix only need a repoint; kept out of the guard so it cannot re-trigger a full install.
  if [ "${ROOTLESS}" = "1" ] && [ "${DETECTED_PREFIX}" != "${PREFIX}" ]; then
    if [ "${CONFIRM}" != "1" ]; then
      log "already on v${TARGET#v}, but the units name ${DETECTED_PREFIX:-<none>} — NERDCTL_INSTALL_CONFIRM=1 repoints them (no re-extract)"
      exit 0
    fi
    log "already on v${TARGET#v}; repointing units ${DETECTED_PREFIX:-<none>} -> ${PREFIX}"
    systemctl --user stop buildkit.service containerd.service 2>/dev/null || true
    _repoint_user_units
    systemctl --user start containerd.service 2>/dev/null || true
    systemctl --user start buildkit.service 2>/dev/null || true
    _check_dropin_prefix || true
    exit 0
  fi
  log "already on v${TARGET#v} — nothing to do (NERDCTL_FORCE=1 re-installs; note that doing so replaces the rollback backup)"
  exit 0
fi

# Rootful decision
_rootful_plan=""; _rootful_reload=""
if [ -n "${_rootful_active}" ]; then
  _rootful_reload=" + system"
  if [ "${NERDCTL_INCLUDE_ROOTFUL:-0}" = "1" ]; then
    _rootful_plan=" + sudo systemctl stop ${_rootful_active}"
    log "rootful units active and INCLUDED: ${_rootful_active}"
  elif [ "${NERDCTL_IGNORE_ROOTFUL:-0}" = "1" ]; then
    warn "rootful units active and IGNORED: ${_rootful_active} — they keep executing the replaced (deleted) binaries until something restarts them"
  else
    # Block the act, not the look: a dry run still shows the plan and the choice.
    _rootful_msg="rootful ${_rootful_active} run from ${PREFIX} and would be replaced underneath them. Pick one deliberately: NERDCTL_INCLUDE_ROOTFUL=1 (stop, upgrade and restart them together — no version skew) or NERDCTL_IGNORE_ROOTFUL=1 (accept that they keep running the old deleted inode until they restart, which under Restart=always happens unattended)."
    [ "${CONFIRM}" = "1" ] && err "${_rootful_msg}"
    warn "${_rootful_msg}"
    _rootful_plan=" + <BLOCKED: choose NERDCTL_INCLUDE_ROOTFUL=1 or NERDCTL_IGNORE_ROOTFUL=1>"
  fi
fi

# Poll, not sleep: a not-yet-listening buildkitd reads as "0 cache mounts" and "not active".
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

# Skips `buildctl du`'s header row; an unreachable daemon returns non-zero, never a count of 0.
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

if [ "${ROOTLESS}" = "1" ]; then
  _extract_desc="tar -C ${PREFIX} -xzf <tarball>          (user-owned, NO sudo)
  4b. repoint ${UNIT_DIR}/{containerd,buildkit}.service at ${PREFIX}/bin"
else
  _extract_desc="sudo tar -C ${PREFIX} -xzf <tarball>     (bundle is root-owned)"
fi

if [ "${CONFIRM}" != "1" ]; then
  cat <<EOF
[nerdctl-full] DRY RUN — set NERDCTL_INSTALL_CONFIRM=1 to perform:
  1. download ${BASE_URL}/${TARBALL} + SHA256SUMS, verify the checksum
  2. back up ${PREFIX}/bin (+ lib/systemd/system if present) to ${BACKUP_DIR}
  3. systemctl --user stop buildkit.service containerd.service${_rootful_plan}
  4. ${_extract_desc}
  5. daemon-reload (user${_rootful_reload}) && start containerd, buildkit
  6. prove: buildkitd answers + lists a worker, daemon versions MOVED off
     (buildkit ${_bk_daemon_before:-?} / containerd ${_cd_daemon_before:-?}),
     cache-mount count still ${_mounts_before}
Rollback afterwards: bash \$0 --rollback
EOF
  exit 0
fi

# Download and verify
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

# Backup: only the files the bundle ships, so it restores like-for-like
log "backing up current binaries → ${BACKUP_DIR}"
rm -rf "${BACKUP_DIR}"; mkdir -p "${BACKUP_DIR}/bin"
tar -tzf "${WORK}/${TARBALL}" | grep '^bin/' | sed 's|^bin/||' | while read -r f; do
  [ -f "${PREFIX}/bin/${f}" ] && cp -a "${PREFIX}/bin/${f}" "${BACKUP_DIR}/bin/" || true
done
# tar rewrites the rootful unit files in place; --rollback needs their old versions.
if [ -d "${PREFIX}/lib/systemd/system" ]; then
  mkdir -p "${BACKUP_DIR}/lib/systemd/system"
  cp -a "${PREFIX}/lib/systemd/system/." "${BACKUP_DIR}/lib/systemd/system/" 2>/dev/null || true
fi
# Rootless mode rewrites the systemd --user units, so their pre-image is backed up too.
if [ "${ROOTLESS}" = "1" ]; then
  mkdir -p "${BACKUP_DIR}/systemd-user"
  for _u in containerd.service buildkit.service; do
    [ -f "${UNIT_DIR}/${_u}" ] && cp -a "${UNIT_DIR}/${_u}" "${BACKUP_DIR}/systemd-user/" || true
  done
fi
# Lets --rollback say where it takes you.
printf 'nerdctl=%s\nbuildctl=%s\nbacked_up_from=%s\n' \
  "${CURRENT}" "${CUR_BUILDCTL}" "${PREFIX}" > "${BACKUP_DIR}/VERSION"
log "backed up $(find "${BACKUP_DIR}/bin" -type f | wc -l) binary/ies + $(find "${BACKUP_DIR}/lib" -name '*.service' 2>/dev/null | wc -l) unit(s) (nerdctl ${CURRENT})"

# Stop, extract, start
_ok=1

log "stopping user services"
systemctl --user stop buildkit.service containerd.service 2>/dev/null || true
if [ -n "${_rootful_active}" ] && [ "${NERDCTL_INCLUDE_ROOTFUL:-0}" = "1" ]; then
  log "stopping rootful ${_rootful_active} (sudo)"
  # shellcheck disable=SC2086  # deliberate split: _rootful_active is a unit LIST
  sudo systemctl stop ${_rootful_active} || warn "could not stop ${_rootful_active}"
fi
sleep 2

log "extracting into ${PREFIX} ($([ "${ROOTLESS}" = "1" ] && echo "no sudo" || echo "sudo"))"
if ! _as_root tar -C "${PREFIX}" -xzf "${WORK}/${TARBALL}"; then
  warn "extraction failed — attempting restore from ${BACKUP_DIR}"
  # Report the restore's real outcome.
  _restored=1
  _as_root cp -a "${BACKUP_DIR}/bin/." "${PREFIX}/bin/" || _restored=0
  systemctl --user start containerd.service buildkit.service 2>/dev/null || true
  [ "${_restored}" = "1" ] && err "extraction failed; ${PREFIX}/bin restored from backup"
  err "extraction failed AND the restore failed too — ${PREFIX}/bin is INCONSISTENT. Recover with: bash $0 --rollback"
fi

if [ "${ROOTLESS}" = "1" ]; then
  _repoint_user_units
fi

log "starting services"
systemctl --user daemon-reload 2>/dev/null || true
# Reload now, or the rewritten root units change at whatever unrelated reload comes next.
if [ -d "${PREFIX}/lib/systemd/system" ]; then
  _daemon_reload || warn "system daemon-reload failed — root units may report NeedDaemonReload=yes"
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

# Prove it works
NEW="$(nerdctl --version 2>/dev/null | awk '{print $NF}' || echo '?')"
NEW_BUILDCTL="$(buildctl --version 2>/dev/null | grep -oE 'v[0-9]+\.[0-9]+\.[0-9]+' | head -1 || echo '?')"
log "now installed: nerdctl ${NEW} (buildctl ${NEW_BUILDCTL})"

systemctl --user is-active buildkit.service >/dev/null 2>&1 || { warn "buildkit.service not active"; _ok=0; }
nerdctl images >/dev/null 2>&1 || { warn "nerdctl cannot reach containerd"; _ok=0; }

# A daemon that failed to restart keeps serving old code from a deleted inode.
_bk_daemon_after="$(buildctl debug info 2>/dev/null | awk '/^BuildKit:/{print $3}' | head -1 || true)"
_cd_daemon_after="$(nerdctl info 2>/dev/null | awk -F': *' '/Server Version/{print $2}' | head -1 || true)"
log "daemon versions: buildkit ${_bk_daemon_before:-?} → ${_bk_daemon_after:-?}, containerd ${_cd_daemon_before:-?} → ${_cd_daemon_after:-?}"
# A same-version prefix relocation cannot move versions, so it proves the daemons' executable path instead.
if [ "${CURRENT#v}" != "${TARGET#v}" ]; then
  if [ -n "${_bk_daemon_before}" ] && [ "${_bk_daemon_before}" = "${_bk_daemon_after}" ]; then
    warn "buildkitd STILL reports ${_bk_daemon_after} — it did not restart onto the new binary"
    _ok=0
  fi
else
  log "same version as before — proving the daemons execute from ${PREFIX}/bin instead"
  _wrong_exe=""
  for _p in $(pgrep -f 'containerd$|buildkitd' 2>/dev/null || true); do
    _exe="$(readlink -f "/proc/${_p}/exe" 2>/dev/null || true)"
    case "${_exe}" in
      "${PREFIX}/bin/"*|"") : ;;
      *) _wrong_exe="${_wrong_exe:+${_wrong_exe} }${_exe}" ;;
    esac
  done
  if [ -n "${_wrong_exe}" ]; then
    warn "daemons still executing outside ${PREFIX}/bin: ${_wrong_exe}"
    _ok=0
  else
    log "daemons execute from ${PREFIX}/bin"
  fi
fi

# A buildkitd with no worker passes `is-active` and fails every build.
_workers="$(buildctl debug workers 2>/dev/null | tail -n +2 | grep -c . || true)"
log "buildkitd workers: ${_workers}"
if [ "${_workers:-0}" -lt 1 ]; then
  warn "buildkitd answers but lists NO worker — builds would fail"
  _ok=0
fi

# Rootless nerdctl looks for CNI plugins under its own default, not ${PREFIX}: docs/linux-host-setup.md#b3c-install-rootless-into-homelocal-no-sudo
_cni_dir="$(nerdctl info --format '{{.CNIPath}}' 2>/dev/null || true)"
[ -n "${_cni_dir}" ] || _cni_dir="${HOME}/.local/libexec/cni"
_cni_n="$(find "${_cni_dir}" -maxdepth 1 -type f ! -name 'LICENSE' ! -name 'README.md' 2>/dev/null | wc -l)"
log "CNI plugins: ${_cni_n} in ${_cni_dir}"
if [ "${_cni_n}" -lt 1 ]; then
  warn "no CNI plugins where nerdctl looks (${_cni_dir}) — container networking will fail. Install with NERDCTL_PREFIX=${_cni_dir%/libexec/cni}, or set CNI_PATH=${PREFIX}/libexec/cni."
  _ok=0
fi

_check_dropin_prefix || _ok=0

# A tree in the other prefix drifts at the next upgrade and shadows this one when PATH prefers it.
_other="/usr/local"; [ "${PREFIX}" = "/usr/local" ] && _other="${HOME}/.local"
if [ -x "${_other}/bin/nerdctl" ]; then
  log "note: ${_other}/bin also holds a nerdctl ($("${_other}/bin/nerdctl" --version 2>/dev/null | awk '{print $NF}')) — this run did not touch it"
fi
_resolved="$(command -v nerdctl 2>/dev/null || true)"
if [ -n "${_resolved}" ] && [ "${_resolved}" != "${PREFIX}/bin/nerdctl" ]; then
  warn "PATH resolves nerdctl to ${_resolved}, not ${PREFIX}/bin/nerdctl — put ${PREFIX}/bin first or you will keep driving the other install"
  _ok=0
fi

# Lost cache mounts fail the run.
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

# The restart dropped the QEMU binfmt registration with the rootlesskit namespace: docs/failure-modes.md#exec-format-error-on-a-foreign-arch-build
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
