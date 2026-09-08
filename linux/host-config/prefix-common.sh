#!/usr/bin/env bash
# prefix-common.sh — resolve the nerdctl prefix this host actually runs, and
# render the canonical host-config templates against it. Sourced by
# apply-host-config.sh and verify-host-config.sh.
#
# The canonical drop-in carries @NERDCTL_PREFIX@ rather than a literal path,
# and the live systemd --user units are the authority on what to put there —
# the same rule install-nerdctl-full.sh follows, for the reason recorded in
# docs/linux-host-setup.md#b3c-install-rootless-into-homelocal-no-sudo

# Print the prefix named by the live rootless units, e.g. /usr/local.
nerdctl_host_prefix() {
  local u p
  for u in containerd.service buildkit.service; do
    p="$(sed -n 's/^ExecStart="\{0,1\}\([^"[:space:]]*\)\/bin\/.*/\1/p' \
          "${HOME}/.config/systemd/user/${u}" 2>/dev/null | head -1)"
    if [ -n "${p}" ]; then printf '%s\n' "${p}"; return 0; fi
  done
  printf '%s\n' "${NERDCTL_PREFIX:-/usr/local}"
}

# render_host_config <repo-file> <out-file>
render_host_config() {
  sed "s|@NERDCTL_PREFIX@|$(nerdctl_host_prefix)|g" "$1" > "$2"
}
