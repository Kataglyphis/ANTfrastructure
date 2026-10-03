# shellcheck shell=bash
# Sourced helper: reads ansible_host/ansible_user from a gitignored host_vars file.
read_hostvars() {
  local hv="$1"
  [ -f "$hv" ] || { echo "missing $hv (fill it from the .example first)" >&2; return 1; }
  ADDR=$(sed -n 's/^ansible_host:[[:space:]]*//p' "$hv" | head -1)
  USER=$(sed -n 's/^ansible_user:[[:space:]]*//p' "$hv" | head -1)
  if [ -z "$ADDR" ] || [ -z "$USER" ]; then
    echo "ansible_host/ansible_user not set in $hv" >&2
    return 1
  fi
  return 0
}
