#!/usr/bin/env bash
# Share a configurable uv stub; tests still own their expected results.
t_uv_fixture_write() {
  mkdir -p "$1"
  cat > "$1/uv" <<'EOF'
#!/usr/bin/env bash
if [ -n "${UV_CALLS:-}" ]; then
  printf 'CALL:%s\n' "$*" >> "$UV_CALLS"
  printf 'ENV:%s:%s:%s:%s\n' "${UV_PYTHON-unset}" "${UV_PROJECT_ENVIRONMENT-unset}" "${UV_WORKING_DIR-unset}" "${UV_PROJECT-unset}" >> "$UV_CALLS"
fi
case "$1" in
  lock) printf 'version = 1\n[[package]]\nname = "demo"\nversion = "2.0"\n' > uv.lock; exit $? ;;
  export)
    [ "${FAIL_EXPORT:-0}" -eq 0 ] || exit "$FAIL_EXPORT"
    while [ "$#" -gt 0 ]; do
      if [ "$1" = --output-file ]; then
        [ "${EMPTY_EXPORT:-0}" = 1 ] || printf '%s\n' "${EXPORT_PACKAGE:-fixture}==1" > "$2"
        exit 0
      fi
      shift
    done ;;
  pip) exit "${FAIL_INSTALL:-0}" ;;
esac
exit 2
EOF
  chmod +x "$1/uv"
}
