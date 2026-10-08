#!/usr/bin/env bash
#
# apply.sh — install and apply the Hyperliquid node network tuning.
#
# Idempotent: re-running reconciles a box rather than changing it again. Safe to
# run from configuration management on every pass.
#
#   ./apply.sh --dry-run     show exactly what would change, touch nothing
#   sudo ./apply.sh          apply
#
# Do NOT keep a hand-maintained list of which boxes have been tuned. That list
# is always wrong eventually; we shipped a production box on cubic + 208 KiB
# buffers for months because it was missing from one.

# -e: stop on the first failed command. -u: an unset variable is an error rather
# than an empty string (an empty path in an `rm` is how boxes die). -o pipefail:
# a failure anywhere in a pipeline fails the pipeline, not just the last stage.
set -euo pipefail

# Resolve this script's own directory so the .conf is found regardless of the
# caller's working directory.
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source and destination. The `99-zz-` prefix is load-bearing — see the long
# comment at the top of the .conf file. Anything that sorts after this file in
# /etc/sysctl.d/ silently overrides it.
CONF_NAME="99-zz-hl-node-network.conf"
CONF_SRC="$HERE/$CONF_NAME"
CONF_DST="/etc/sysctl.d/$CONF_NAME"

# The keys this file claims ownership of. verify.sh uses the same list, and the
# conflict check below greps other drop-ins for exactly these.
KEYS=(
  net.core.rmem_max
  net.core.wmem_max
  net.ipv4.tcp_rmem
  net.ipv4.tcp_wmem
  net.ipv4.tcp_congestion_control
  net.core.default_qdisc
  net.core.somaxconn
  net.ipv4.tcp_max_syn_backlog
  net.core.netdev_max_backlog
)

DRY_RUN=0
for arg in "$@"; do
  case "$arg" in
    --dry-run|-n) DRY_RUN=1 ;;
    -h|--help) sed -n '2,15p' "$0"; exit 0 ;;
    *) echo "unknown argument: $arg" >&2; exit 2 ;;
  esac
done

say()  { printf '      %s\n' "$*"; }
ok()   { printf '\033[32mOK  \033[0m %s\n' "$*"; }
warn() { printf '\033[33mWARN\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[31mFAIL\033[0m %s\n' "$*" >&2; exit 1; }

# run — the single mutation gate. Every state-changing command in this script
# goes through it, so --dry-run is a faithful rehearsal of the real pass rather
# than a separate, untested code path.
run() {
  if [ "$DRY_RUN" -eq 1 ]; then
    printf '\033[90m  would run:\033[0m %s\n' "$*"
  else
    printf '\033[36m  $\033[0m %s\n' "$*"
    "$@"
  fi
}

[ -f "$CONF_SRC" ] || die "missing $CONF_SRC"
if [ "$DRY_RUN" -eq 0 ] && [ "$(id -u)" -ne 0 ]; then
  die "must run as root (or use --dry-run). Try: sudo $0"
fi

# ---------------------------------------------------------------------------
# 0. Before/after readback — capture the live values first.
# ---------------------------------------------------------------------------
# Read the values as the kernel currently reports them. `sysctl -n` prints only
# the value; a missing key prints nothing and exits non-zero, which the `||`
# turns into a readable placeholder instead of aborting under `set -e`.
printf '\n== before ==\n'
declare -A BEFORE=()
for k in "${KEYS[@]}"; do
  v="$(sysctl -n "$k" 2>/dev/null || echo '<unset>')"
  BEFORE["$k"]="$v"
  printf '  %-34s %s\n' "$k" "$v"
done

# ---------------------------------------------------------------------------
# 1. BBR is a module. Load it and persist it BEFORE applying the sysctl.
# ---------------------------------------------------------------------------
# If tcp_bbr is not loaded when systemd-sysctl processes the file, the
# tcp_congestion_control line is rejected and you silently stay on cubic. There
# is no warning in any log you will think to read.
printf '\n== congestion control module ==\n'
if grep -qw bbr /proc/sys/net/ipv4/tcp_available_congestion_control; then
  ok "tcp_bbr already available"
else
  say "tcp_bbr not yet available — loading"
  run modprobe tcp_bbr
fi

# Persist across reboots. /etc/modules-load.d/ is read by systemd-modules-load
# at boot, well before systemd-sysctl applies /etc/sysctl.d/.
if [ -f /etc/modules-load.d/bbr.conf ] && grep -qx tcp_bbr /etc/modules-load.d/bbr.conf; then
  ok "/etc/modules-load.d/bbr.conf already persists tcp_bbr"
else
  if [ "$DRY_RUN" -eq 1 ]; then
    printf '\033[90m  would run:\033[0m write tcp_bbr to /etc/modules-load.d/bbr.conf\n'
  else
    echo tcp_bbr > /etc/modules-load.d/bbr.conf
    ok "persisted tcp_bbr in /etc/modules-load.d/bbr.conf"
  fi
fi

# ---------------------------------------------------------------------------
# 2. Conflict check — find any drop-in that would override us.
# ---------------------------------------------------------------------------
# Lexical order decides, and the last write wins. A file sorting AFTER ours that
# sets any of our keys makes this whole exercise a no-op on the next reboot. We
# report it rather than deleting it: it may be there on purpose, and silently
# removing another team's file is worse than telling you about it.
printf '\n== drop-in precedence ==\n'
conflicts=""
# Build an alternation of our keys with the dots escaped, so `net.core.rmem_max`
# cannot also match `netXcoreYrmem_max`. Pure parameter expansion — no sed.
key_re=""
for k in "${KEYS[@]}"; do
  key_re="${key_re}|${k//./\\.}"
done
key_re="${key_re#|}"

# `2>/dev/null || true` so a box with no other drop-ins (grep exit 1) does not
# abort the script under `set -e`. `read -r` in a while loop rather than `for f in
# $(...)`: filenames with spaces stay intact.
while IFS= read -r f; do
  [ -n "$f" ] || continue
  base="$(basename "$f")"
  # Skip ourselves. Compare basenames with the same collation sysctl uses.
  [ "$base" = "$CONF_NAME" ] && continue
  # A file in /etc/sysctl.d with a name sorting after ours overrides us.
  if [ "$(printf '%s\n%s\n' "$base" "$CONF_NAME" | LC_ALL=C sort | tail -1)" = "$base" ]; then
    conflicts="$conflicts $f"
    warn "$f sorts AFTER $CONF_NAME and sets one of our keys — it WILL override this tuning"
  else
    say "$f also sets one of our keys but sorts before us (harmless, still worth deleting)"
  fi
done < <(grep -lE "^[[:space:]]*(${key_re})[[:space:]]*=" \
           /etc/sysctl.conf /etc/sysctl.d/*.conf /usr/lib/sysctl.d/*.conf 2>/dev/null || true)
[ -z "$conflicts" ] && ok "nothing in /etc/sysctl.d sorts after $CONF_NAME for our keys"

# ---------------------------------------------------------------------------
# 3. Install the drop-in and apply it.
# ---------------------------------------------------------------------------
printf '\n== install ==\n'
# cmp -s: identical content means nothing to do. Avoiding a pointless rewrite
# keeps the mtime stable, which matters if anything on the box grades config
# freshness by mtime.
if [ -f "$CONF_DST" ] && cmp -s "$CONF_SRC" "$CONF_DST"; then
  ok "$CONF_DST already up to date"
else
  run install -m 0644 -o root -g root "$CONF_SRC" "$CONF_DST"
fi

# `sysctl --system` reprocesses EVERY drop-in in order, which is deliberate: it
# is the same code path a reboot takes, so if another file is going to clobber us
# it clobbers us here, in front of you, rather than in three weeks.
run sysctl --system

# ---------------------------------------------------------------------------
# 4. After readback and grade.
# ---------------------------------------------------------------------------
printf '\n== after ==\n'
failed=0
for k in "${KEYS[@]}"; do
  v="$(sysctl -n "$k" 2>/dev/null || echo '<unset>')"
  # Normalise the tab-separated multi-value keys (tcp_rmem/tcp_wmem) to spaces.
  v="$(echo "$v" | tr -s '[:space:]' ' ' | sed 's/ $//')"
  b="$(echo "${BEFORE[$k]}" | tr -s '[:space:]' ' ' | sed 's/ $//')"
  if [ "$v" = "$b" ]; then
    printf '  %-34s %s\n' "$k" "$v"
  else
    printf '  %-34s \033[32m%s\033[0m  (was: %s)\n' "$k" "$v" "$b"
  fi
done

# The two settings most likely to have silently failed: congestion control (the
# module) and the window ceiling (a later drop-in). Grade them explicitly.
cc="$(sysctl -n net.ipv4.tcp_congestion_control)"
wmax="$(sysctl -n net.core.wmem_max)"
printf '\n== grade ==\n'
[ "$cc" = bbr ] || { warn "tcp_congestion_control is '$cc', expected bbr"; failed=1; }
[ "$wmax" -ge 16777216 ] || { warn "wmem_max is $wmax, expected >= 16777216"; failed=1; }
if [ "$DRY_RUN" -eq 1 ]; then
  say "dry run — nothing was changed"
elif [ "$failed" -eq 0 ]; then
  ok "network tuning applied and verified"
else
  die "tuning did not take effect as expected — see warnings above"
fi
