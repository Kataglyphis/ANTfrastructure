#!/usr/bin/env bash
# Register QEMU user-mode emulators for rootless containerd + BuildKit — NO sudo.
# `tonistiigi/binfmt --install` does NOT work here: it registers inside a throwaway
# namespace that --rm destroys. buildkitd shares containerd's rootlesskit namespace,
# so registering QEMU there fixes both run and build.
# Flags "POCF": P preserves argv[0]; F opens the interpreter fd at registration so
# it is inherited into nested namespaces where the qemu path is not mounted.
# Registration dies with the namespace (reboot/containerd restart) — re-run or use --install-service.
set -euo pipefail
IFS=$'\n\t'

ARCHES="arm64,riscv64"
QDIR="${BINFMT_QEMU_DIR:-${HOME}/.local/lib/binfmt}"
BINFMT_IMAGE="${BINFMT_IMAGE:-tonistiigi/binfmt}"
NERDCTL="${NERDCTL_BIN:-nerdctl}"
FORCE=0
INSTALL_SERVICE=0
VERIFY_ONLY=0
BINFMT_NS_WAIT_SECS="${BINFMT_NS_WAIT_SECS:-90}"

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
# Leak-on-error guard: host /tmp accumulates otherwise (EXIT-scoped trap).
  trap 'rm -rf "${tmp}"' EXIT
  # image save only reads the LOCAL store — pull first or a fresh host dies with 'image not found'.
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

# Wait for the rootlesskit namespace: After= orders only unit start, not the
# namespace unshare. On fresh boot nsenter dies with 'No such file' for child_pid.
# See AGENTS.md § Prerequisites.
wait_for_namespace() {
  local pidfile="/run/user/$(id -u)/containerd-rootless/child_pid"
  local waited=0
  while [ ! -s "${pidfile}" ]; do
    if [ "${waited}" -ge "${BINFMT_NS_WAIT_SECS}" ]; then
      echo "[wait] namespace pid file never appeared: ${pidfile}" >&2
      echo "       is the rootless containerd running? (systemctl --user status containerd)" >&2
      return 1
    fi
    sleep 1
    waited=$((waited + 1))
  done
  # The file can exist a moment before the namespace is joinable.
  while ! containerd-rootless-setuptool.sh nsenter -- true 2>/dev/null; do
    if [ "${waited}" -ge "${BINFMT_NS_WAIT_SECS}" ]; then
      echo "[wait] namespace present but not joinable after ${waited}s" >&2
      return 1
    fi
    sleep 1
    waited=$((waited + 1))
  done
  [ "${waited}" -gt 0 ] && echo "[wait] rootlesskit namespace ready after ${waited}s"
  return 0
}

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
# PartOf is load-bearing: After=/Wants= order startup only, not restarts.
# Without it, oneshot+RemainAfterExit makes systemd consider this satisfied
# while the namespace registration dies on every containerd restart.
PartOf=containerd.service

[Service]
Type=oneshot
RemainAfterExit=yes
# Belt-and-braces for the boot race: wait_for_namespace() already polls, but if
# containerd is slower than BINFMT_NS_WAIT_SECS we retry rather than leaving the
# machine with no emulators (on-failure is the one Restart= mode oneshot allows).
Restart=on-failure
RestartSec=10
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
  wait_for_namespace
  register
  verify
  echo "OK: rootless QEMU emulation registered for [${ARCHES}] with flags POCF."
  echo "    Test: ${NERDCTL} run --rm --platform linux/arm64 ubuntu:26.04 uname -m   # -> aarch64"
  if [ "${INSTALL_SERVICE}" = 1 ]; then install_service; fi
}
main
