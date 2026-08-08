#!/usr/bin/env bash
# Register QEMU user-mode emulators for rootless containerd + BuildKit — NO sudo.
#
# Why this exists (and why `tonistiigi/binfmt --install` alone does NOT work here):
#   A rootless `nerdctl run --privileged --rm tonistiigi/binfmt --install all`
#   registers binfmt_misc inside that throwaway container's OWN user namespace,
#   which is destroyed on `--rm`. It never reaches the namespace where containers
#   and builds actually run, so foreign-arch execs fail with "exec format error"
#   even though the installer prints "arch OK".
#
#   In this rootless setup, buildkitd is launched *nsenter'd into containerd's
#   rootlesskit namespace* (see `systemctl --user cat buildkit.service`:
#   `ExecStart=... containerd-rootless-setuptool.sh nsenter -- buildkitd ...`), so
#   `nerdctl run` (containerd) and `nerdctl build` (BuildKit) SHARE one persistent
#   rootless namespace. Registering QEMU *once* in that shared namespace makes both
#   emulate correctly — fully rootless.
#
# What it does:
#   1. Extracts static qemu-<arch> emulators from the tonistiigi/binfmt image to a
#      stable host path (no `nerdctl cp`, which rejects stopped rootless containers).
#   2. Enters the shared rootlesskit namespace via `containerd-rootless-setuptool.sh
#      nsenter` and, if the propagated host binfmt_misc there is read-only, overmounts
#      a fresh, namespace-owned (writable) binfmt_misc.
#   3. Registers each emulator with flags "POCF":
#        P = preserve-argv[0]  (REQUIRED — without it qemu drops argv[1]; e.g.
#            `sh -c CMD` loses `-c` and dash treats CMD as a filename)
#        O = open-binary as fd (works when the target isn't on the interpreter's path)
#        C = credentials (setuid/setgid handling)
#        F = fix-binary (kernel opens the interpreter fd at registration time, so it
#            is inherited into nested build/run namespaces where the qemu path is
#            not mounted)
#
# The registration lives in the rootlesskit namespace and persists until that
# namespace exits (containerd.service restart / reboot). Re-run this script after a
# reboot, or install it as a systemd --user unit with `--install-service`.
#
# Usage:
#   linux/scripts/setup-rootless-binfmt.sh [--arches arm64,riscv64] [--force]
#                                          [--install-service] [--verify]
set -euo pipefail
IFS=$'\n\t'

ARCHES="arm64,riscv64"
QDIR="${BINFMT_QEMU_DIR:-${HOME}/.local/lib/binfmt}"
BINFMT_IMAGE="${BINFMT_IMAGE:-tonistiigi/binfmt}"
NERDCTL="${NERDCTL_BIN:-nerdctl}"
FORCE=0
INSTALL_SERVICE=0
VERIFY_ONLY=0

while [ $# -gt 0 ]; do
  case "$1" in
    --arches) ARCHES="$2"; shift 2 ;;
    --force) FORCE=1; shift ;;
    --install-service) INSTALL_SERVICE=1; shift ;;
    --verify) VERIFY_ONLY=1; shift ;;
    -h|--help)
      sed -n '2,40p' "$0"; exit 0 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done

# arch -> qemu binary name, ELF e_machine magic + mask (little-endian, offset 0)
qemu_bin_for()  { case "$1" in arm64) echo qemu-aarch64 ;; riscv64) echo qemu-riscv64 ;; arm) echo qemu-arm ;; *) return 1 ;; esac; }
elf_magic_for() {
  # \x7fELF, EI_CLASS=2 (64-bit), EI_DATA=1 (LE), e_type=2 (EXEC) at 0x10, e_machine at 0x12
  case "$1" in
    arm64)   printf '\\x7f\\x45\\x4c\\x46\\x02\\x01\\x01\\x00\\x00\\x00\\x00\\x00\\x00\\x00\\x00\\x00\\x02\\x00\\xb7\\x00' ;;
    riscv64) printf '\\x7f\\x45\\x4c\\x46\\x02\\x01\\x01\\x00\\x00\\x00\\x00\\x00\\x00\\x00\\x00\\x00\\x02\\x00\\xf3\\x00' ;;
    *) return 1 ;;
  esac
}
elf_mask() { printf '\\xff\\xff\\xff\\xff\\xff\\xff\\xff\\x00\\xff\\xff\\xff\\xff\\xff\\xff\\xff\\xff\\xfe\\xff\\xff\\xff'; }

command -v containerd-rootless-setuptool.sh >/dev/null 2>&1 || {
  echo "ERROR: containerd-rootless-setuptool.sh not found — this script targets rootless containerd/BuildKit." >&2
  exit 1
}

# ---------------------------------------------------------------------------
# 1. Extract the static qemu emulators from the tonistiigi/binfmt image.
# ---------------------------------------------------------------------------
extract_emulators() {
  mkdir -p "${QDIR}"
  local need=0 a qb
  IFS=',' read -ra _arr <<< "${ARCHES}"
  for a in "${_arr[@]}"; do
    qb="$(qemu_bin_for "${a}")" || { echo "unsupported arch: ${a}" >&2; exit 2; }
    [ -x "${QDIR}/${qb}" ] || need=1
  done
  if [ "${need}" = 0 ] && [ "${FORCE}" = 0 ]; then
    echo "[extract] emulators already present in ${QDIR} (use --force to refresh)"
    return 0
  fi
  echo "[extract] pulling + unpacking ${BINFMT_IMAGE} (amd64) to ${QDIR}"
  local tmp; tmp="$(mktemp -d)"
  # `image save` only reads the LOCAL store — pull first or a fresh host dies
  # with 'image not found' (bit us 2026-08-08 after image GC).
  "${NERDCTL}" image inspect "${BINFMT_IMAGE}" >/dev/null 2>&1 \
    || "${NERDCTL}" pull --platform linux/amd64 "${BINFMT_IMAGE}"
  "${NERDCTL}" image save --platform linux/amd64 "${BINFMT_IMAGE}" -o "${tmp}/img.tar"
  mkdir -p "${tmp}/img"; tar -xf "${tmp}/img.tar" -C "${tmp}/img"
  local blob
  for blob in "${tmp}"/img/blobs/sha256/*; do
    # grep (not -q) drains the listing fully — `grep -q` exits at first match,
    # tar dies of SIGPIPE (141) and pipefail turns the match into a skip.
    tar -tf "${blob}" 2>/dev/null | grep 'usr/bin/qemu-' >/dev/null || continue
    # extract every qemu-* plus the binfmt helper, flattening usr/bin/
    tar -xf "${blob}" -C "${QDIR}" --strip-components=2 --wildcards \
      'usr/bin/qemu-*' 'usr/bin/binfmt' 2>/dev/null || true
  done
  rm -rf "${tmp}"
  chmod +x "${QDIR}"/qemu-* "${QDIR}/binfmt" 2>/dev/null || true
  ls -la "${QDIR}"
}

# ---------------------------------------------------------------------------
# 2 + 3. Register in the shared rootlesskit namespace (via nsenter).
# ---------------------------------------------------------------------------
register() {
  local a qb magic mask
  IFS=',' read -ra _arr <<< "${ARCHES}"
  # Build the in-namespace script.
  local script='set -e
# If the propagated host binfmt_misc is not writable by this namespace, overmount a fresh one.
if ! : 2>/dev/null > /proc/sys/fs/binfmt_misc/register; then
  mount -t binfmt_misc none /proc/sys/fs/binfmt_misc
fi
'
  for a in "${_arr[@]}"; do
    qb="$(qemu_bin_for "${a}")"
    magic="$(elf_magic_for "${a}")"
    mask="$(elf_mask)"
    script+="
[ -f /proc/sys/fs/binfmt_misc/${qb} ] && echo -1 > /proc/sys/fs/binfmt_misc/${qb} 2>/dev/null || true
printf ':%s:M::%s:%s:%s:POCF\n' '${qb}' '${magic}' '${mask}' '${QDIR}/${qb}' > /proc/sys/fs/binfmt_misc/register
echo \"registered ${qb} -> ${QDIR}/${qb}\"
"
  done
  containerd-rootless-setuptool.sh nsenter -- bash -c "${script}"
}

verify() {
  local a qb ok=1
  IFS=',' read -ra _arr <<< "${ARCHES}"
  for a in "${_arr[@]}"; do
    qb="$(qemu_bin_for "${a}")"
    if containerd-rootless-setuptool.sh nsenter -- sh -c "grep -q '^enabled' /proc/sys/fs/binfmt_misc/${qb} 2>/dev/null"; then
      echo "[verify] ${qb}: enabled"
    else
      echo "[verify] ${qb}: NOT registered" >&2; ok=0
    fi
  done
  [ "${ok}" = 1 ] || return 1
}

install_service() {
  local unit_dir="${HOME}/.config/systemd/user"
  mkdir -p "${unit_dir}"
  local self; self="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"
  cat > "${unit_dir}/rootless-binfmt.service" <<EOF
[Unit]
Description=Register QEMU binfmt emulators in the rootless containerd/BuildKit namespace
After=containerd.service buildkit.service
Wants=containerd.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/bin/env bash ${self} --arches ${ARCHES}

[Install]
WantedBy=default.target
EOF
  systemctl --user daemon-reload
  systemctl --user enable --now rootless-binfmt.service
  echo "[service] installed + enabled rootless-binfmt.service (runs on login/boot)"
}

# ---------------------------------------------------------------------------
main() {
  if [ "${VERIFY_ONLY}" = 1 ]; then verify; exit $?; fi
  extract_emulators
  register
  verify
  echo "OK: rootless QEMU emulation registered for [${ARCHES}] with flags POCF."
  echo "    Test: ${NERDCTL} run --rm --platform linux/arm64 ubuntu:26.04 uname -m   # -> aarch64"
  if [ "${INSTALL_SERVICE}" = 1 ]; then install_service; fi
}
main
