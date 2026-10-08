#!/usr/bin/env bash
#
# apply-restart-hygiene.sh — stop the operating system from restarting your node
# behind your back.
#
#   ./apply-restart-hygiene.sh --status     report only (default)
#   sudo ./apply-restart-hygiene.sh --apply
#
# Debian/Ubuntu specific. Read every section before applying: this deliberately
# stops automatic security updates, and you are taking on the job of applying
# them deliberately instead.
#
# WHY
# ---
# An unplanned node restart is not a blip. If the node is far enough behind the
# chain when it is restarted, it discards local state and takes a full state
# bootstrap from a peer. We measured one such event at ~1 GB on the wire, 1,534
# retries, and 3 hours 45 minutes of the node being useless — triggered by a
# routine library upgrade about 30 seconds after the daily apt timer fired.
# Nothing in the node's own supervision can see this coming: apt owns that
# restart, not your monitoring.
#
# Three distinct mechanisms can do this to you, and they need three fixes.

set -euo pipefail

MODE=status
for arg in "$@"; do
  case "$arg" in
    --apply)  MODE=apply ;;
    --status) MODE=status ;;
    -h|--help) sed -n '2,25p' "$0"; exit 0 ;;
    *) echo "unknown argument: $arg" >&2; exit 2 ;;
  esac
done

ok()   { printf '\033[32mOK  \033[0m %s\n' "$*"; }
warn() { printf '\033[33mTODO\033[0m %s\n' "$*"; }
say()  { printf '      %s\n' "$*"; }

run() {
  if [ "$MODE" = apply ]; then
    printf '\033[36m  $\033[0m %s\n' "$*"
    "$@"
  else
    printf '\033[90m  would run:\033[0m %s\n' "$*"
  fi
}

if [ "$MODE" = apply ] && [ "$(id -u)" -ne 0 ]; then
  echo "must run as root to apply. Try: sudo $0 --apply" >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# 1. needrestart — the mechanism that actually pulls the trigger
# ---------------------------------------------------------------------------
# needrestart runs non-interactively as part of the daily apt upgrade. With no
# terminal to prompt at, it falls back to AUTO-RESTARTING every daemon whose
# mapped libraries were upgraded. A glibc bump therefore restarts everything.
#
# 🔴 MERGE A KEY, DO NOT ASSIGN THE HASH. /etc/needrestart/needrestart.conf
# defines %nrconf with distro defaults (dbus, NetworkManager, display managers)
# and only sources conf.d/ afterwards. Writing `%nrconf = (...)` in a conf.d file
# REPLACES those defaults and lets needrestart bounce dbus — strictly worse than
# doing nothing. Use the `->{...} = ` arrow form to merge a single key.
#
# The trade-off, stated plainly: the exempted processes keep running against
# upgraded-out library files until YOU restart them. That is the point — you
# choose the moment — but a security fix in a shared library is not live in those
# processes until you do. Audit what is owed a restart, restarting nothing:
#     sudo needrestart -b -r l
printf '\n== 1. needrestart auto-restart exemption ==\n'
NR_CONF=/etc/needrestart/conf.d/90-hl-node.conf
if [ ! -d /etc/needrestart ]; then
  say "needrestart is not installed on this box — nothing to do"
elif [ -f "$NR_CONF" ]; then
  ok "$NR_CONF present"
else
  warn "$NR_CONF missing"
  if [ "$MODE" = apply ]; then
    # `override_rc` maps a unit-name regex to 0 = never auto-restart. Adjust the
    # regexes to your own unit names.
    cat > "$NR_CONF" <<'CONF'
# Installed by hl-node-tools/host/apply-restart-hygiene.sh
# Never let needrestart auto-restart the node or its sidecars after a library
# upgrade. Merge individual keys — never assign %nrconf wholesale, that would
# discard the distro defaults.
$nrconf{override_rc}->{qr(^hl-)} = 0;
$nrconf{override_rc}->{qr(^hlsup)} = 0;
CONF
    ok "wrote $NR_CONF"
  else
    say "would write an override_rc exemption for ^hl- units"
  fi
fi

# ---------------------------------------------------------------------------
# 2. The apt timers — the thing that fires the mechanism
# ---------------------------------------------------------------------------
# Exempting needrestart blunts the impact; masking the timers removes the
# trigger. MASK, do not disable: a package postinst re-enables a disabled timer
# on the next upgrade, and you will never notice. A mask is a symlink to
# /dev/null that `systemctl enable` cannot overwrite.
printf '\n== 2. unattended apt timers ==\n'
for unit in apt-daily.timer apt-daily-upgrade.timer unattended-upgrades.service; do
  # Ask the DISK whether the unit exists. Once masked, `systemctl is-enabled`
  # reports "masked" — and it also reports "masked" for a unit that was never
  # there, so systemctl alone cannot distinguish "we did this" from "nothing
  # here". Check for the vendor unit file first.
  if ! ls /lib/systemd/system/"$unit" /usr/lib/systemd/system/"$unit" >/dev/null 2>&1; then
    say "$unit: not present on this host"
    continue
  fi
  state="$(systemctl is-enabled "$unit" 2>/dev/null || true)"
  if [ "$state" = masked ]; then
    ok "$unit: masked"
  else
    warn "$unit: $state"
    run systemctl mask "$unit"
  fi
done

# Belt and braces: even a manually started apt-daily does nothing with these at
# zero. apt-config reads the merged configuration, so this is the effective
# value, not just the contents of one file.
printf '\n== 3. APT::Periodic keys ==\n'
APT_CONF=/etc/apt/apt.conf.d/99-hl-node-no-auto-updates
if command -v apt-config >/dev/null 2>&1; then
  for key in Update-Package-Lists Download-Upgradeable-Packages Unattended-Upgrade; do
    val="$(apt-config dump "APT::Periodic::$key" 2>/dev/null | sed -n 's/.*"\(.*\)";$/\1/p' | tail -1)"
    if [ "${val:-1}" = "0" ]; then ok "APT::Periodic::$key = 0"; else warn "APT::Periodic::$key = ${val:-<unset>} (want 0)"; fi
  done
  if [ ! -f "$APT_CONF" ] && [ "$MODE" = apply ]; then
    cat > "$APT_CONF" <<'CONF'
// Installed by hl-node-tools/host/apply-restart-hygiene.sh
APT::Periodic::Update-Package-Lists "0";
APT::Periodic::Download-Upgradeable-Packages "0";
APT::Periodic::Unattended-Upgrade "0";
CONF
    ok "wrote $APT_CONF"
  fi
else
  say "apt-config not found — not a Debian-family box, skipping"
fi

# ---------------------------------------------------------------------------
# 4. sshd start-limit latch — how you lose remote access entirely
# ---------------------------------------------------------------------------
# Unrelated to the node, and the most expensive thing on this page if it bites.
# An openssh upgrade restarts ssh. If that restart lands during an internet
# brute-force flood, socket-activated start attempts trip systemd's start rate
# limiter; systemd then tears down the unit's RuntimeDirectory (/run/sshd); every
# later `sshd -t` pre-start check exits 255; and RestartPreventExitStatus=255
# latches the unit PERMANENTLY FAILED. The flood is survivable. The rate limiter
# turning it into a permanent latch is not. We lost remote access to a box for 13
# hours to exactly this.
printf '\n== 4. sshd start-limit latch ==\n'
SSH_UNIT=ssh.service
systemctl list-unit-files ssh.service >/dev/null 2>&1 || SSH_UNIT=sshd.service
SSH_DROPIN="/etc/systemd/system/${SSH_UNIT}.d/99-no-start-limit.conf"
if [ -f "$SSH_DROPIN" ]; then
  ok "$SSH_DROPIN present"
else
  warn "$SSH_DROPIN missing"
  if [ "$MODE" = apply ]; then
    mkdir -p "$(dirname "$SSH_DROPIN")"
    cat > "$SSH_DROPIN" <<'CONF'
# Installed by hl-node-tools/host/apply-restart-hygiene.sh
# Remove systemd's start rate limit from sshd. A flood must not be able to latch
# the unit permanently failed and lock you out of your own box.
[Unit]
StartLimitIntervalSec=0
StartLimitBurst=0
CONF
    ok "wrote $SSH_DROPIN"
    # daemon-reload is enough — this changes no running state and restarts
    # nothing. Deliberately NOT restarting sshd here.
    run systemctl daemon-reload
  fi
fi

printf '\n'
if [ "$MODE" = status ]; then
  echo "status only — nothing was changed. Re-run with --apply (as root) to fix the TODOs."
else
  echo "applied. Nothing was restarted by this script, by design."
  echo "Remember: you now own patching. Check what is owed a restart with:  needrestart -b -r l"
fi
