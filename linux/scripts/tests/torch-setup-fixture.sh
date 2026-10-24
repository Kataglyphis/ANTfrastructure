#!/usr/bin/env bash
# Setup functions run with fake imports and apt tools while real temporary files expose marker and cleanup effects.
source "$(dirname "${BASH_SOURCE[0]}")/test-harness.sh"
TORCH_SETUP_SUBJECT="${1:-${_T_SCRIPTS}/06-packaging/setup-torch-venv.sh}"
export TORCH_SETUP_RECEIPT="${2:-}"
TORCH_SETUP_WORK="$(mktemp -d)"
trap 'rm -rf "$TORCH_SETUP_WORK"' EXIT
t_source_functions "${_T_SCRIPTS}/06-packaging/package-image-wiring.sh" clear_unmounted_apt_lists
for name in _torch_write_missing_marker _torch_clear_unmounted_apt_lists; do
  if grep -q "^${name}()" "$TORCH_SETUP_SUBJECT"; then t_source_functions "$TORCH_SETUP_SUBJECT" "$name"; fi
done
t_source_functions "$TORCH_SETUP_SUBJECT" torch_wheel_missing_fallback verify_torch_import_or_fail setup_torch_deps install_riscv64_runtime_libs cross_skip venv_site_packages

torch_setup_plant() {
  mkdir -p "$TORCH_CASE/venv/bin" "$TORCH_CASE/venv/lib/python3.99/site-packages" "$TORCH_CASE/apt/lists" "$TORCH_CASE/cwd" "$TORCH_CASE/opt/opencv5/lib/python3.99/cv2"
  printf payload > "$TORCH_CASE/opt/opencv5/lib/python3.99/cv2/payload"
  printf wheel > "$TORCH_CASE/opencv.whl"
  touch "$TORCH_CASE/apt/lists/first list" "$TORCH_CASE/apt/lists/second"
  : > "$TORCH_CASE/trace"
  cat > "$TORCH_CASE/venv/bin/python" <<'BASH'
#!/usr/bin/env bash
printf 'python|cwd=%q|' "$PWD" >> "$TORCH_CASE/trace"
printf '%q ' "$@" >> "$TORCH_CASE/trace"
printf '\n' >> "$TORCH_CASE/trace"
case "$2" in
  *cv2*) printf 'cv2 5.fixture\n'; printf 'cv2 stderr\n' >&2; exit "$CV2_STATUS" ;;
  *print*) if [ "$IMPORT_STATUS" = 0 ]; then printf '2.fixture\n'; else printf 'import failed\n' >&2; fi ;;
  *) printf 'import failed\n' >&2 ;;
esac
exit "$IMPORT_STATUS"
BASH
  cat > "$TORCH_CASE/venv/bin/pip" <<'BASH'
#!/usr/bin/env bash
printf 'pip|' >> "$TORCH_CASE/trace"; printf '%q ' "$@" >> "$TORCH_CASE/trace"; printf '\n' >> "$TORCH_CASE/trace"
printf 'pip stdout\n'; printf 'pip stderr\n' >&2
exit "$PIP_STATUS"
BASH
  chmod +x "$TORCH_CASE/venv/bin/python" "$TORCH_CASE/venv/bin/pip"
  cat > "$TORCH_CASE/worker.sh" <<'BASH'
set -euo pipefail
work=$TORCH_CASE
export VENV="$work/venv"
LD_LIBRARY_PATH=initial-libs
trace_call() { builtin printf '%s|' "$1" >> "$work/trace"; shift; builtin printf '%q ' "$@" >> "$work/trace"; builtin printf '\n' >> "$work/trace"; }
printf() {
  local printf_pid=$BASHPID
  if [ "$PRINTF_STATUS" != 0 ] && [ "$(readlink "/proc/$printf_pid/fd/1")" = "$VENV/.torch-missing" ]; then return "$PRINTF_STATUS"; fi
  builtin printf "$@"
}
mkdir() { trace_call mkdir "$@"; [ "$MKDIR_STATUS" = 0 ] || return "$MKDIR_STATUS"; /bin/mkdir "$@"; }
ls() { trace_call ls "$@"; if [ "$CV2_SOURCE" = wheel ]; then builtin printf '%s\n' "$work/opencv.whl"; else return 2; fi; }
[() {
  case "${1:-}:${2:-}" in
    -d:/opt/opencv5/lib) if [ "$CV2_SOURCE" = source ]; then return 0; else return 1; fi ;;
    *) builtin '[' "$@" ;;
  esac
}
find() { case "$1" in /opt/opencv5/lib) trace_call find "$@"; shift; /usr/bin/find "$work/opt/opencv5/lib" "$@" ;; *) /usr/bin/find "$@" ;; esac; }
cp() { trace_call cp "$@"; [ "$CP_STATUS" = 0 ] || return "$CP_STATUS"; /bin/cp "$@"; }
apt-get() { trace_call apt "$@"; echo "apt $1"; case "$1" in update) return "$UPDATE_STATUS" ;; install) return "$INSTALL_STATUS" ;; esac; }
mountpoint() { trace_call mountpoint "$@"; return "$MOUNT_STATUS"; }
rm() { trace_call rm "$@"; [ "$RM_STATUS" = 0 ] || return "$RM_STATUS"; /bin/rm "$@"; }
_install_cv2_runtime_apt() { trace_call cv2-deps; }
_install_ffmpeg_runtime_codecs() { trace_call ffmpeg-deps; }
_assert_ffmpeg_so_closure() { trace_call closure; return "$CLOSURE_STATUS"; }
BASH
  t_emit_optional_functions clear_unmounted_apt_lists _torch_write_missing_marker _torch_clear_unmounted_apt_lists torch_wheel_missing_fallback verify_torch_import_or_fail setup_torch_deps install_riscv64_runtime_libs cross_skip venv_site_packages \
    | sed 's|/var/lib/apt/lists/|"${work}/apt/lists/"|g' >> "$TORCH_CASE/worker.sh"
  cat >> "$TORCH_CASE/worker.sh" <<'BASH'
trap 'builtin printf %s "$LD_LIBRARY_PATH" > "$work/ld"' EXIT
cd "$work/cwd"
case "$ACTION" in
  fallback) torch_wheel_missing_fallback fixture-arch ;;
  verify) verify_torch_import_or_fail fixture-arch ;;
  deps) setup_torch_deps ;;
  riscv) install_riscv64_runtime_libs ;;
esac
BASH
}

torch_setup_import_scenario() {
  local scenario="$1"
  case "$scenario" in
    ready) import_status=0; printf previous > "$TORCH_CASE/venv/.torch-missing" ;;
    allow) allow=1 ;;
    mkdir-failure) allow=1; mkdir_status=5 ;;
    write-failure) allow=1; printf_status=7 ;;
    marker-directory) allow=1; mkdir "$TORCH_CASE/venv/.torch-missing" ;;
    wheel) cv2_source=wheel ;;
    source) cv2_source=source ;;
    copy-failure) cv2_source=source; cp_status=9; cv2_status=1 ;;
    pip-failure) cv2_source=wheel; pip_status=9 ;;
  esac
}

torch_setup_apt_scenario() {
  local scenario="$1"
  case "$scenario" in
    mounted) mount_status=0 ;;
    mount-error) mount_status=2 ;;
    rm-failure) rm_status=11 ;;
    update-failure) update_status=17 ;;
    install-failure) install_status=19 ;;
    closure-failure) closure_status=23 ;;
    cross) mode=cross ;;
  esac
}

torch_setup_run() {
  local action="$1" scenario="$2"
  export TORCH_CASE="$TORCH_SETUP_WORK/$action $scenario"
  torch_setup_plant
  local import_status=13 cv2_source=none cv2_status=0 allow=0 mkdir_status=0 printf_status=0 cp_status=0 pip_status=0 mount_status=1 rm_status=0 update_status=0 install_status=0 closure_status=0 mode=native
  torch_setup_import_scenario "$scenario"
  torch_setup_apt_scenario "$scenario"
  export TORCH_STATUS=0
  env ACTION="$action" IMPORT_STATUS="$import_status" CV2_SOURCE="$cv2_source" CV2_STATUS="$cv2_status" ALLOW_TORCHLESS_RUNTIME="$allow" MKDIR_STATUS="$mkdir_status" PRINTF_STATUS="$printf_status" CP_STATUS="$cp_status" PIP_STATUS="$pip_status" MOUNT_STATUS="$mount_status" RM_STATUS="$rm_status" UPDATE_STATUS="$update_status" INSTALL_STATUS="$install_status" CLOSURE_STATUS="$closure_status" BUILD_MODE="$mode" \
    bash "$TORCH_CASE/worker.sh" > "$TORCH_CASE/out" 2> "$TORCH_CASE/err" || TORCH_STATUS=$?
}

torch_setup_bytes() {
  sed "s|$TORCH_SETUP_WORK|@WORK@|g" "$1" | sed -E 's|worker.sh: line [0-9]+:|worker.sh: line @LINE@:|g' | od -An -v -tx1 | tr -d ' \n'
}
