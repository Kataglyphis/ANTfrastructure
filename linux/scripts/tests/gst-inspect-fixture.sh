#!/usr/bin/env bash
# Tests stub gst-inspect with element membership and bundled-plugin path checks.

# t_write_gst_inspect_stub <path> [--with-name]
t_write_gst_inspect_stub() {
  local target="${1:?Stub path required}" mode="${2:-}"
  if [ "$#" -gt 2 ] || { [ -n "$mode" ] && [ "$mode" != --with-name ]; }; then
    printf 'gst-inspect fixture: expected <path> [--with-name]\n' >&2
    return 2
  fi
  mkdir -p "$(dirname "$target")" || return
  cat > "$target" <<'STUB'
#!/usr/bin/env bash
[ "${GST_PLUGIN_SYSTEM_PATH-unset}" = "" ] && [ "${GST_PLUGIN_SYSTEM_PATH_1_0-unset}" = "" ] || exit 3
[ -z "${GST_PLUGIN_PATH_1_0+x}" ] || exit 3
case " ${STUB_ELEMENTS} " in *" $1 "*) ;; *) exit 255 ;; esac
printf 'Plugin Details:\n'
STUB
  if [ "$mode" = --with-name ]; then
    cat >> "$target" <<'STUB'
printf '  Name                     stub\n'
STUB
  fi
  cat >> "$target" <<'STUB'
printf '  Filename                 %s/libgststub.so\n' "${STUB_DIR:-${GST_PLUGIN_PATH}}"
STUB
  chmod +x "$target"
}
