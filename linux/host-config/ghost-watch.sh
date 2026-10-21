#!/usr/bin/env bash
# Reports this user's orphaned processes that burn CPU or memory or look like test leftovers ([--min-age-min=N] [--notify] | --install | --uninstall): docs/linux-host-setup.md#b10-ghost-watch
set -uo pipefail

MIN_AGE_MIN=60
NOTIFY=0
MODE=report
ALLOW_FILE="${GHOST_WATCH_ALLOW:-${XDG_CONFIG_HOME:-${HOME}/.config}/kataglyphis/ghost-watch.allow}"
UNIT_DIR="${XDG_CONFIG_HOME:-${HOME}/.config}/systemd/user"
# Long-lived by design on the family's hosts; a host adds its own in ALLOW_FILE, one ERE per line.
DEFAULT_ALLOW='systemd|gnome-|gsd-|Xwayland|pipewire|wireplumber|dbus|at-spi|ibus|evolution|tracker|xdg-|gvfs|goa-|containerd|buildkitd|rootlesskit|slirp4netns|zellij|tmux|ssh-agent|opencode serve|ollama|rustdesk|build-cross-chain\.sh'
# What leaked on the build host: headless Chrome, harness fixtures, scripts run from a mktemp tree.
GHOST_PATTERN='chrome --headless|chromium.*--headless|bash \./t\.sh|mutation-gate-|/tmp/tmp\.[A-Za-z0-9]+/'
CPU_PCT=25
RSS_MB=1024

die() { printf 'ghost-watch: %s\n' "$*" >&2; exit 2; }

for arg in "$@"; do
  case "${arg}" in
    --min-age-min=*) MIN_AGE_MIN="${arg#*=}" ;;
    --notify) NOTIFY=1 ;;
    --install) MODE=install ;;
    --uninstall) MODE=uninstall ;;
    -h|--help) MODE=help ;;
    *) die "no such option: ${arg} (see --help)" ;;
  esac
done
case "${MIN_AGE_MIN}" in ''|*[!0-9]*) die "--min-age-min takes whole minutes, got '${MIN_AGE_MIN}'" ;; esac

# Writes an hourly user timer that runs this script with --notify; it only reports, it never kills.
install_timer() {
  local self
  self="$(readlink -f "$0")"
  mkdir -p "${UNIT_DIR}"
  printf '[Unit]\nDescription=Report orphaned processes (ghost-watch)\n\n[Service]\nType=oneshot\nExecStart=%s --notify\n' \
    "${self}" > "${UNIT_DIR}/ghost-watch.service"
  printf '[Unit]\nDescription=Hourly ghost-watch\n\n[Timer]\nOnCalendar=hourly\nPersistent=true\n\n[Install]\nWantedBy=timers.target\n' \
    > "${UNIT_DIR}/ghost-watch.timer"
  systemctl --user daemon-reload || return 1
  systemctl --user enable --now ghost-watch.timer
}

case "${MODE}" in
  help) sed -n '2p' "$0"; exit 0 ;;
  install) install_timer; exit $? ;;
  uninstall)
    systemctl --user disable --now ghost-watch.timer 2>/dev/null || true
    rm -f "${UNIT_DIR}/ghost-watch.service" "${UNIT_DIR}/ghost-watch.timer"
    systemctl --user daemon-reload
    exit 0 ;;
esac

# Orphans reparent to PID 1 or, under a desktop session, to the user's systemd (a subreaper).
manager="${GHOST_WATCH_MANAGER_PID:-$(pgrep -u "$(id -u)" -x systemd 2>/dev/null | head -1)}"
allow="${DEFAULT_ALLOW}"
if [ -r "${ALLOW_FILE}" ]; then
  extra="$(grep -vE '^[[:space:]]*(#|$)' "${ALLOW_FILE}" | paste -sd'|' -)"
  [ -z "${extra}" ] || allow="${allow}|${extra}"
fi

ps_out() {
  if [ -n "${GHOST_WATCH_PS_FILE:-}" ]; then cat "${GHOST_WATCH_PS_FILE}"
  else ps -u "$(id -u)" -o pid=,ppid=,etimes=,pcpu=,rss=,args=
  fi
}

# The regexes go through ENVIRON: gawk rewrites backslash escapes in -v values and warns on `\.`.
ghosts="$(ps_out | GW_ALLOW="${allow}" GW_GHOST="${GHOST_PATTERN}" awk -v mgr="${manager:-0}" \
  -v min_s="$((MIN_AGE_MIN * 60))" -v cpu="${CPU_PCT}" -v rss="$((RSS_MB * 1024))" '
  BEGIN { allow = ENVIRON["GW_ALLOW"]; ghost = ENVIRON["GW_GHOST"] }
  {
    cmd = $6; for (i = 7; i <= NF; i++) cmd = cmd " " $i
    if (($2 != 1 && $2 != mgr) || $3 < min_s || cmd ~ allow) next
    if ($4 >= cpu || $5 >= rss || cmd ~ ghost)
      printf "%s\t%dh%02dm\t%s%%\t%d MB\t%s\n", $1, $3 / 3600, ($3 % 3600) / 60, $4, $5 / 1024, substr(cmd, 1, 120)
  }')"

[ -n "${ghosts}" ] || exit 0
count="$(printf '%s\n' "${ghosts}" | wc -l)"
printf 'ghost-watch: %s orphaned process(es) older than %s min (pid, age, cpu, rss, command):\n%s\n' \
  "${count}" "${MIN_AGE_MIN}" "${ghosts}"
printf 'end one with: kill <pid>; a whole tree: kill -- -<pgid> (ps -o pgid= -p <pid>)\n'
if [ "${NOTIFY}" -eq 1 ] && command -v notify-send >/dev/null 2>&1; then
  notify-send -u critical "ghost-watch: ${count} orphaned process(es)" "$(printf '%s\n' "${ghosts}" | cut -f1,2,5 | head -5)" || true
fi
exit 1
