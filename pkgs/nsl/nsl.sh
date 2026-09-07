# nsl - run and enter the Linux distributions declared in nsl.machines
specdir=/etc/nsl/machines

usage() {
  cat <<'USAGE'
usage: nsl <command> [arguments]

  list                     machines declared on this host and their state
  shell <name> [cmd ...]   enter a machine as yourself, starting it if needed
  root <name> [cmd ...]    the same, as root
  run <name> -- cmd ...    run a command non-interactively, passing on its exit code
  start|stop|restart <name>
  status <name>            systemd status of the machine
  logs <name> [args ...]   the machine's journal (accepts journalctl arguments)
  reset <name>             delete a machine's filesystem so it is rebuilt from scratch
  images [distro]          images the configured server currently offers

Machines are declared in your NixOS configuration under nsl.machines.
USAGE
}

die() { echo "nsl: $*" >&2; exit 1; }

spec_of() {
  [ -r "$specdir/$1.json" ] || die "no machine named '$1'. Try: nsl list"
  printf '%s\n' "$specdir/$1.json"
}

field() { jq -r --arg k "$2" '.[$k] // empty' "$(spec_of "$1")"; }

names() {
  [ -d "$specdir" ] || return 0
  for f in "$specdir"/*.json; do
    [ -e "$f" ] || continue
    b=${f##*/}
    printf '%s\n' "${b%.json}"
  done
}

state_of() {
  if [ "$(systemctl is-active "systemd-nspawn@$1.service" 2>/dev/null)" = active ]; then
    if [ -e "/var/lib/nsl/$1/bootstrapped" ]; then echo running; else echo starting; fi
  elif [ -e "/var/lib/nsl/$1/bootstrapped" ]; then
    echo stopped
  else
    echo "not installed"
  fi
}

# The bootstrap only ever runs once, so a machine whose declaration changed
# afterwards is not what the configuration now says it is.
drifted() {
  marker=/var/lib/nsl/$1/spec-hash
  [ -e "$marker" ] || return 1
  [ "$(cat "$marker")" != "$(field "$1" specHash)" ]
}

cmd_list() {
  found=
  printf '%-16s %-12s %-14s %s\n' NAME DISTRO STATE USER
  for n in $(names); do
    found=1
    note=
    if drifted "$n"; then note=" (declaration changed, nsl reset to apply)"; fi
    printf '%-16s %-12s %-14s %s%s\n' \
      "$n" "$(field "$n" distro)/$(field "$n" release)" "$(state_of "$n")" \
      "$(field "$n" user)" "$note"
  done
  [ -n "$found" ] || echo "no machines declared; add some under nsl.machines"
}

wait_running() {
  n=$1
  i=0
  while [ "$(systemctl show -p SubState --value "systemd-nspawn@$n.service" 2>/dev/null)" != running ]; do
    systemctl is-failed --quiet "systemd-nspawn@$n.service" &&
      die "$n failed to start. See: nsl status $n"
    i=$((i + 1))
    [ "$i" -gt 600 ] && die "$n did not come up within 10 minutes"
    sleep 1
  done
  # machinectl needs the machine registered before it can open a shell in it.
  i=0
  while ! machinectl show "$n" >/dev/null 2>&1; do
    i=$((i + 1))
    [ "$i" -gt 60 ] && die "$n did not register with systemd-machined"
    sleep 1
  done
}

ensure_running() {
  n=$1
  [ "$(systemctl show -p SubState --value "systemd-nspawn@$n.service" 2>/dev/null)" = running ] && return 0
  if [ ! -e "/var/lib/nsl/$n/bootstrapped" ]; then
    echo "nsl: installing $(field "$n" distro) $(field "$n" release), this happens once" >&2
  fi
  systemctl start "systemd-nspawn@$n.service" &
  starter=$!
  if [ ! -e "/var/lib/nsl/$n/bootstrapped" ]; then
    journalctl -f -n 0 -o cat -u "nsl-bootstrap-$n.service" &
    follower=$!
    trap 'kill $follower 2>/dev/null || true' EXIT INT TERM
  fi
  wait "$starter" || die "could not start $n. See: nsl logs $n"
  if [ -n "${follower:-}" ]; then
    kill "$follower" 2>/dev/null || true
    trap - EXIT INT TERM
  fi
  wait_running "$n"
}

cmd_shell() {
  n=${1:?usage: nsl shell <name> [command ...]}
  shift
  user=$(field "$n" user)
  [ -n "$user" ] || user=root
  ensure_running "$n"
  # machinectl swallows the exit status, so anything scripted should use `nsl run`.
  exec machinectl shell --setenv=LANG="${LANG:-C.UTF-8}" "$user@$n" "$@"
}

cmd_root() {
  n=${1:?usage: nsl root <name> [command ...]}
  shift
  ensure_running "$n"
  exec machinectl shell "root@$n" "$@"
}

cmd_run() {
  n=${1:?usage: nsl run <name> -- command ...}
  shift
  [ "${1:-}" = -- ] && shift
  [ $# -gt 0 ] || die "nsl run needs a command"
  user=$(field "$n" user)
  ensure_running "$n"
  set -- --machine="$n" --pipe --wait --quiet --collect ${user:+--uid="$user"} -- "$@"
  exec systemd-run "$@"
}

cmd_start() {
  n=${1:?usage: nsl start <name>}
  spec_of "$n" >/dev/null
  ensure_running "$n"
  echo "nsl: $n is running"
}

cmd_stop() {
  n=${1:?usage: nsl stop <name>}
  spec_of "$n" >/dev/null
  systemctl stop "systemd-nspawn@$n.service"
}

cmd_restart() {
  n=${1:?usage: nsl restart <name>}
  spec_of "$n" >/dev/null
  systemctl restart "systemd-nspawn@$n.service"
  wait_running "$n"
}

cmd_status() {
  n=${1:?usage: nsl status <name>}
  spec_of "$n" >/dev/null
  systemctl status --no-pager "systemd-nspawn@$n.service" || true
  [ -e "/var/lib/nsl/$n/bootstrapped" ] ||
    systemctl status --no-pager "nsl-bootstrap-$n.service" || true
}

cmd_logs() {
  n=${1:?usage: nsl logs <name> [journalctl arguments]}
  shift
  spec_of "$n" >/dev/null
  if [ -e "/var/lib/nsl/$n/bootstrapped" ]; then
    exec journalctl -M "$n" "$@"
  else
    exec journalctl -u "nsl-bootstrap-$n.service" "$@"
  fi
}

cmd_reset() {
  yes=
  case ${1:-} in
    -y | --yes) yes=1; shift ;;
  esac
  n=${1:?usage: nsl reset [--yes] <name>}
  spec_of "$n" >/dev/null
  if [ "$(id -u)" != 0 ]; then
    exec sudo "$0" reset ${yes:+--yes} "$n"
  fi
  if [ -z "$yes" ]; then
    printf 'Delete everything inside machine %s and install it again? [y/N] ' "$n"
    read -r reply
    case $reply in
      y | Y | yes) ;;
      *) die "cancelled" ;;
    esac
  fi
  systemctl stop "systemd-nspawn@$n.service" 2>/dev/null || true
  # Some systems mark files immutable (NixOS does, for /var/empty), which stops
  # any recursive delete until the flag is cleared.
  chattr -R -f -i "/var/lib/machines/$n" 2>/dev/null || true
  machinectl remove "$n" 2>/dev/null || rm -rf --one-file-system "/var/lib/machines/$n"
  rm -rf "/var/lib/nsl/$n"
  echo "nsl: $n will be installed again on next start"
}

cmd_images() {
  distro=${1:-}
  server=$(jq -r '.imageServer' "$(spec_of "$(names | head -n 1)")" 2>/dev/null) ||
    server=https://images.linuxcontainers.org
  arch=$(jq -r '.arch' "$(spec_of "$(names | head -n 1)")" 2>/dev/null) || arch=amd64
  curl -fsSL "$server/meta/1.0/index-system" |
    awk -F';' -v d="$distro" -v a="$arch" \
      'BEGIN { printf "%-14s %-14s %-10s %s\n", "DISTRO", "RELEASE", "VARIANT", "BUILT" }
       $3 == a && (d == "" || $1 == d) { printf "%-14s %-14s %-10s %s\n", $1, $2, $4, $5 }' |
    sort -u -k1,1 -k2,2
}

command=${1:-list}
[ $# -gt 0 ] && shift
case $command in
  list | ls) cmd_list "$@" ;;
  shell | enter) cmd_shell "$@" ;;
  root) cmd_root "$@" ;;
  run) cmd_run "$@" ;;
  start) cmd_start "$@" ;;
  stop) cmd_stop "$@" ;;
  restart) cmd_restart "$@" ;;
  status) cmd_status "$@" ;;
  logs | log) cmd_logs "$@" ;;
  reset) cmd_reset "$@" ;;
  images) cmd_images "$@" ;;
  -h | --help | help) usage ;;
  *) usage >&2; exit 2 ;;
esac
