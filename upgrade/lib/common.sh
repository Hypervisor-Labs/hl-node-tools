# shellcheck shell=bash
# shellcheck disable=SC2034  # variables are used by the scripts that source this
# common.sh: node discovery shared by upgrade/*.sh. Sourced, never run.
#
# 🔴 THE PROGRAM NAMES ARE NEVER WRITTEN INTO A COMMAND LINE. The node and its
# supervisor scan /proc at startup and panic if any other process has either
# program name in its argv (see the top-level README). A watcher on a 30 s timer
# that ran `pgrep -f <name>` would be such a process twice a minute, and the
# supervisor has been seen panicking on its OWN pgrep helper too. So:
#   - the names are assembled at runtime and compared in-shell against
#     /proc/<pid>/comm, which reads a file and spawns nothing;
#   - every action goes through a systemd unit name, never through a pattern.

VISOR_NAME="hl-""visor"
NODE_NAME="hl-""node"
# Operators may run the binaries under other names/paths (--node-bin/--visor-bin,
# or NODE_BIN_OPT/VISOR_BIN_OPT in the environment). A renamed binary carries no
# forbidden token in its own argv, which is how you run a second (scratch) node
# on a box whose production supervisor would otherwise trip over it at startup.
# Process matching then uses the renamed file's comm (first 15 bytes of its name).
NODE_BIN_OPT="${NODE_BIN_OPT:-}"
VISOR_BIN_OPT="${VISOR_BIN_OPT:-}"
set_comms() {
  local n="${NODE_BIN_OPT##*/}" v="${VISOR_BIN_OPT##*/}"
  NODE_COMM="${n:-$NODE_NAME}"; NODE_COMM="${NODE_COMM:0:15}"
  VISOR_COMM="${v:-$VISOR_NAME}"; VISOR_COMM="${VISOR_COMM:0:15}"
}
set_comms
LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# 🪤 THE KIT'S OWN PATH. This repository is called hl-node-tools, and that name
# CONTAINS the node's program name. The /proc scan matches substrings of the
# whole command line, so `/opt/hl-node-tools/upgrade/fork-watch.sh` on a 30 s
# timer is exactly the process it panics on. Two defences:
#   - hlup() runs the helper by a RELATIVE path from inside lib/, so no python
#     process we start carries the install path;
#   - argv_guard refuses to run when THIS script was started by a path that
#     contains either name. Start it from the repo root with a relative path, or
#     with WorkingDirectory= in a unit (upgrade/systemd/ does this).
hlup() { (cd "$LIB_DIR" && exec python3 -I hlup.py "$@"); }   # -I: ignore cwd/env imports

argv_guard() {
  local me
  me="$(tr '\0' ' ' <"/proc/$$/cmdline" 2>/dev/null)"
  case "$me" in
    *"$VISOR_NAME"*|*"$NODE_NAME"*)
      echo "refusing to run: this process's command line contains the node's program name:" >&2
      echo "  $me" >&2
      echo "The node panics at startup if any other process carries that name in argv." >&2
      echo "Run it by a relative path from the repository root, e.g.  cd <repo> && ./upgrade/$(basename "$0")" >&2
      echo "or install the upgrade/ directory under a neutral path (see upgrade/README.md)." >&2
      exit 64 ;;
  esac
}

# pids_by_comm NAME -> PIDs whose comm is exactly NAME (no subprocess involved)
pids_by_comm() {
  local want="$1" p c
  for p in /proc/[0-9]*; do
    c=""
    read -r c 2>/dev/null <"$p/comm" || continue
    [ "$c" = "$want" ] && printf '%s\n' "${p#/proc/}"
  done
  return 0
}

# unit_of_pid PID -> the .service that owns PID (from its cgroup path)
unit_of_pid() {
  local line
  line="$(tail -n1 "/proc/$1/cgroup" 2>/dev/null)" || return 1
  line="${line##*/}"
  case "$line" in *.service) printf '%s\n' "$line" ;; *) return 1 ;; esac
}

ppid_of() { awk '/^PPid:/{print $2}' "/proc/$1/status" 2>/dev/null; }

# Units are addressed over D-Bus by their ESCAPED object path, never by name on
# a command line: a unit called after the supervisor (a common choice) would put
# the forbidden name in `systemctl restart <unit>`'s argv, and that systemctl is
# still alive when the supervisor starts and scans /proc. In the object path every
# non-alphanumeric byte is _xx hex, so the name never appears.
unit_path() {
  local u="$1" out="" i ch
  for ((i = 0; i < ${#u}; i++)); do
    ch="${u:i:1}"
    if [[ "$ch" =~ [A-Za-z0-9] ]] && { [ $i -gt 0 ] || [[ ! "$ch" =~ [0-9] ]]; }; then out+="$ch"
    else out+="$(printf '_%02x' "'$ch")"; fi
  done
  printf '/org/freedesktop/systemd1/unit/%s' "$out"
}

# unit_prop UNIT PROP -> value, read over D-Bus (no root needed)
unit_prop() {
  local iface=org.freedesktop.systemd1.Service raw
  case "$2" in ActiveState|SubState|LoadState|Id) iface=org.freedesktop.systemd1.Unit ;; esac
  raw="$(busctl get-property org.freedesktop.systemd1 "$(unit_path "$1")" "$iface" "$2" 2>/dev/null)" || return 0
  case "$raw" in
    s\ *) raw="${raw#s }"; raw="${raw#\"}"; printf '%s\n' "${raw%\"}" ;;
    u\ *|i\ *|t\ *) printf '%s\n' "${raw#* }" ;;
    as\ *) printf '%s\n' "$raw" | grep -o '"[^"]*"' | tr -d '"' | paste -sd ' ' - ;;
    *) printf '%s\n' "$raw" ;;
  esac
}

# exec_path UNIT -> the binary path of the unit's ExecStart (first quoted string)
exec_path() {
  busctl get-property org.freedesktop.systemd1 "$(unit_path "$1")" org.freedesktop.systemd1.Service ExecStart 2>/dev/null \
    | grep -o '"[^"]*"' | head -n1 | tr -d '"'
}

# exec_argv UNIT -> the ExecStart argv, space-joined
exec_argv() {
  busctl get-property org.freedesktop.systemd1 "$(unit_path "$1")" org.freedesktop.systemd1.Service ExecStart 2>/dev/null \
    | grep -o '"[^"]*"' | tail -n +2 | tr -d '"' | paste -sd ' ' -
}

# unit_job UNIT Restart|Stop|Start -> queue the job and return (no blocking)
unit_job() {
  busctl call org.freedesktop.systemd1 "$(unit_path "$1")" org.freedesktop.systemd1.Unit "$2" s replace >/dev/null
}

# wait_state UNIT STATE SECONDS -> 0 when ActiveState reaches STATE
wait_state() {
  local i
  for ((i = 0; i < $3; i++)); do
    [ "$(unit_prop "$1" ActiveState)" = "$2" ] && return 0
    sleep 1
  done
  return 1
}

# find_unit_by_exec -> first loaded service whose ExecStart binary is the
# supervisor (preferred) or the node. Used when nothing is running.
find_unit_by_exec() {
  local u p best=""
  while read -r u _; do
    p="$(exec_path "$u")"
    case "${p##*/}" in
      "$VISOR_NAME"|"${VISOR_BIN_OPT##*/}") [ -n "${p##*/}" ] && { printf '%s\n' "$u"; return 0; } ;;
      "$NODE_NAME"|"${NODE_BIN_OPT##*/}") [ -z "$best" ] && best="$u" ;;
    esac
  done < <(systemctl list-units --type=service --all --no-legend --plain 2>/dev/null)
  [ -n "$best" ] && printf '%s\n' "$best"
  return 0
}

# discover: fills UNIT HOME_DIR DATA_DIR CHAIN SUPERVISION VISOR_PID NODE_PID
# NODE_BIN VISOR_BIN UNIT_USER. Honours pre-set UNIT / HOME_DIR / CHAIN.
discover() {
  set_comms
  VISOR_PID="$(pids_by_comm "$VISOR_COMM" | head -n1)"
  NODE_PID=""
  local p
  # Prefer the node that is the supervisor's child; otherwise any node process.
  for p in $(pids_by_comm "$NODE_COMM"); do
    if [ -n "$VISOR_PID" ] && [ "$(ppid_of "$p")" = "$VISOR_PID" ]; then NODE_PID="$p"; break; fi
    [ -z "$NODE_PID" ] && NODE_PID="$p"
  done

  if [ -z "${UNIT:-}" ]; then
    if [ -n "$VISOR_PID" ]; then UNIT="$(unit_of_pid "$VISOR_PID" || true)"
    elif [ -n "$NODE_PID" ]; then UNIT="$(unit_of_pid "$NODE_PID" || true)"
    fi
    [ -z "${UNIT:-}" ] && UNIT="$(find_unit_by_exec)"
  fi
  # Only processes INSIDE the chosen unit count. A box can run two nodes (e.g. a
  # production one and a renamed test one); the other unit's processes must never
  # be inspected, compared or reported as ours.
  if [ -n "${UNIT:-}" ]; then
    [ -n "$VISOR_PID" ] && [ "$(unit_of_pid "$VISOR_PID" 2>/dev/null)" != "$UNIT" ] && VISOR_PID=""
    NODE_PID=""
    for p in $(pids_by_comm "$NODE_COMM"); do
      [ "$(unit_of_pid "$p" 2>/dev/null)" = "$UNIT" ] || continue
      if [ -n "$VISOR_PID" ] && [ "$(ppid_of "$p")" = "$VISOR_PID" ]; then NODE_PID="$p"; break; fi
      [ -z "$NODE_PID" ] && NODE_PID="$p"
    done
  fi

  local xp="" uhome=""
  if [ -n "${UNIT:-}" ]; then
    xp="$(exec_path "$UNIT")"
    UNIT_USER="$(unit_prop "$UNIT" User)"
    uhome="$(unit_prop "$UNIT" Environment | tr ' ' '\n' | sed -n 's/^HOME=//p' | head -n1)"
    [ -z "$uhome" ] && [ -n "$UNIT_USER" ] && uhome="$(getent passwd "$UNIT_USER" | cut -d: -f6)"
  fi
  UNIT_USER="${UNIT_USER:-root}"
  # The supervisor resolves everything (the node binary, hl/ data) under $HOME,
  # which on a normal install is also the directory holding the binaries.
  if [ -z "${HOME_DIR:-}" ]; then
    if [ -n "$uhome" ]; then HOME_DIR="$uhome"
    elif [ -n "$xp" ]; then HOME_DIR="$(dirname "$xp")"
    fi
  fi
  DATA_DIR="${HOME_DIR:-}/hl/hyperliquid_data"

  local xb="${xp##*/}"
  if [ -n "$xb" ] && { [ "$xb" = "$VISOR_NAME" ] || [ "$xb" = "${VISOR_BIN_OPT##*/}" ]; }; then xb=VISOR
  elif [ -n "$xb" ] && { [ "$xb" = "$NODE_NAME" ] || [ "$xb" = "${NODE_BIN_OPT##*/}" ]; }; then xb=NODE; fi
  case "$xb" in
    VISOR) SUPERVISION=visor ;;
    NODE) SUPERVISION=bare ;;
    *) if [ -n "$VISOR_PID" ]; then SUPERVISION=visor
       elif [ -n "$NODE_PID" ]; then SUPERVISION=bare
       else SUPERVISION=none; fi ;;
  esac
  VISOR_BIN="${VISOR_BIN_OPT:-${HOME_DIR:-}/$VISOR_NAME}"
  if [ -n "$NODE_BIN_OPT" ]; then NODE_BIN="$NODE_BIN_OPT"
  elif [ "$SUPERVISION" = bare ] && [ -n "$xp" ]; then NODE_BIN="$xp"
  else NODE_BIN="${HOME_DIR:-}/$NODE_NAME"; fi

  if [ -z "${CHAIN:-}" ] && [ -r "${HOME_DIR:-}/visor.json" ]; then
    CHAIN="$(python3 -I -c 'import json,sys; print(json.load(open(sys.argv[1])).get("chain",""))' "$HOME_DIR/visor.json" 2>/dev/null)"
  fi
  if [ -z "${CHAIN:-}" ] && [ -n "$NODE_PID" ] && [ -r "/proc/$NODE_PID/cmdline" ]; then
    CHAIN="$(tr '\0' '\n' <"/proc/$NODE_PID/cmdline" | sed -n '/^--chain$/{n;p;q}')"
  fi
  if [ -z "${CHAIN:-}" ] && [ -n "${UNIT:-}" ]; then
    CHAIN="$(exec_argv "$UNIT" | sed -n 's/.*--chain \([A-Za-z]*\).*/\1/p' | head -n1)"
  fi
  case "${CHAIN:-}" in
    mainnet|Mainnet) CHAIN=Mainnet ;;
    testnet|Testnet) CHAIN=Testnet ;;
  esac
  return 0
}
