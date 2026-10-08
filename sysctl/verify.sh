#!/usr/bin/env bash
#
# verify.sh — read the LIVE kernel values back and grade them.
#
# Read-only. Changes nothing, needs no root. Exit 0 = all green, 1 = at least
# one setting is not what a tuned node box should have.
#
# Why a separate verifier at all: every setting in this directory has a silent
# failure mode. BBR without its module is ignored. A window ceiling is reverted
# by a later drop-in on the next reboot. somaxconn looks raised while the actual
# listener is still at 128. "I applied the config" is not evidence; the live
# value is.

set -uo pipefail   # deliberately NOT -e: we want every check to run and report,
                   # not to abort at the first red line.

CONF_NAME="99-zz-hl-node-network.conf"
FAILED=0

pass() { printf '\033[32mPASS\033[0m %-34s %s\n' "$1" "$2"; }
fail() { printf '\033[31mFAIL\033[0m %-34s %s\n' "$1" "$2"; FAILED=1; }
info() { printf '     %-34s %s\n' "$1" "$2"; }

# check <key> <test> <expected-description>
#   test is an arithmetic or string condition evaluated against $v.
check_ge() {
  local key="$1" want="$2" v
  v="$(sysctl -n "$key" 2>/dev/null || echo '')"
  if [ -z "$v" ]; then fail "$key" "unset"; return; fi
  # Multi-value keys (tcp_rmem/tcp_wmem): grade the LAST field, the maximum.
  local last; last="$(echo "$v" | awk '{print $NF}')"
  if [ "$last" -ge "$want" ] 2>/dev/null; then
    pass "$key" "$v"
  else
    fail "$key" "$v  (want max >= $want)"
  fi
}

check_eq() {
  local key="$1" want="$2" v
  v="$(sysctl -n "$key" 2>/dev/null || echo '')"
  if [ "$v" = "$want" ]; then pass "$key" "$v"; else fail "$key" "${v:-<unset>}  (want $want)"; fi
}

printf '== live kernel values ==\n'

# 16 MiB is the floor for a node that only consumes gossip. 32 MiB is required
# on any box that pushes a multi-GB transfer to a peer >100 ms away — see the
# .conf. We grade against the 16 MiB floor so a consumer-only box passes.
check_ge net.core.rmem_max 16777216
check_ge net.core.wmem_max 16777216
check_ge net.ipv4.tcp_rmem 16777216
check_ge net.ipv4.tcp_wmem 16777216

check_eq net.ipv4.tcp_congestion_control bbr
check_eq net.core.default_qdisc fq

check_ge net.core.somaxconn 4096
check_ge net.ipv4.tcp_max_syn_backlog 4096
check_ge net.core.netdev_max_backlog 5000

check_eq net.ipv4.tcp_keepalive_time 300
check_ge net.ipv4.tcp_keepalive_probes 3

printf '\n== module ==\n'
# A tcp_congestion_control of bbr with tcp_bbr unavailable cannot happen (the
# write would have been rejected), but the reverse — available now, not
# persisted, gone after reboot — happens constantly.
if grep -qw bbr /proc/sys/net/ipv4/tcp_available_congestion_control; then
  pass "tcp_bbr available" "yes"
else
  fail "tcp_bbr available" "no — tcp_congestion_control=bbr is being ignored"
fi
if grep -rqx tcp_bbr /etc/modules-load.d/ 2>/dev/null; then
  pass "tcp_bbr persisted" "/etc/modules-load.d"
else
  fail "tcp_bbr persisted" "not in /etc/modules-load.d — will be lost on reboot"
fi

printf '\n== drop-in precedence ==\n'
# The trap this whole directory exists to prevent: a file sorting AFTER ours
# re-defines a key, so the live value is right today and wrong after the next
# `sysctl --system` or reboot. This check is the only thing that catches a box
# whose runtime is correct only because someone applied a file by hand.
later=""
for f in /etc/sysctl.conf /etc/sysctl.d/*.conf /usr/lib/sysctl.d/*.conf; do
  [ -r "$f" ] || continue
  base="$(basename "$f")"
  [ "$base" = "$CONF_NAME" ] && continue
  grep -qE '^[[:space:]]*net\.(core\.(r|w)mem_max|ipv4\.tcp_(r|w)mem|ipv4\.tcp_congestion_control)[[:space:]]*=' "$f" || continue
  if [ "$(printf '%s\n%s\n' "$base" "$CONF_NAME" | LC_ALL=C sort | tail -1)" = "$base" ]; then
    later="$later $f"
  else
    info "$f" "also sets a window key, sorts before us (harmless)"
  fi
done
if [ -n "$later" ]; then
  for f in $later; do fail "$f" "sorts AFTER $CONF_NAME — will override on next sysctl --system"; done
else
  pass "precedence" "nothing sorts after $CONF_NAME for the window keys"
fi

printf '\n== listener reality check (informational) ==\n'
# somaxconn is a CEILING. What a listener actually got is its own listen(2)
# backlog, visible as Send-Q on a LISTEN socket. A server using a stdlib bind()
# that hardcodes 128 stays at 128 no matter what somaxconn says. This is not a
# pass/fail — it is the number people assume they raised and did not.
if command -v ss >/dev/null 2>&1; then
  ss -ltn 2>/dev/null | awk 'NR==1 || $4 ~ /:(4001|4002|3001)$/ {printf "     %s\n", $0}'
  info "note" "Send-Q on a LISTEN row is the real accept-queue depth, not somaxconn"
else
  info "ss" "not installed — skipping"
fi

printf '\n'
if [ "$FAILED" -eq 0 ]; then
  printf '\033[32mAll checks passed.\033[0m\n'
else
  printf '\033[31mOne or more checks failed — see FAIL lines above.\033[0m\n'
fi
exit "$FAILED"
