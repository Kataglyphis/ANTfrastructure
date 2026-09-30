#!/usr/bin/env bash
# Renders host-config templates against the prefix the live units name: docs/linux-host-setup.md#b3c-install-rootless-into-homelocal-no-sudo

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
