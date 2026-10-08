#!/usr/bin/env bash
#
# gossip-connection-ceiling.sh — put a GLOBAL concurrent-connection ceiling in
# front of the node's gossip listener on TCP/4001.
#
#   ./gossip-connection-ceiling.sh --dry-run          show the rules, change nothing
#   sudo ./gossip-connection-ceiling.sh --apply       install (iptables)
#   sudo ./gossip-connection-ceiling.sh --apply --forward   also cover FORWARD
#   ./gossip-connection-ceiling.sh --status           show the installed rules + counters
#   sudo ./gossip-connection-ceiling.sh --remove      take it back out
#
# THE PROBLEM THIS SOLVES
# -----------------------
# The gossip listener's accept queue is finite and, in at least one widely used
# implementation, it is 128 — a Rust `TcpListener::bind()` takes no backlog
# argument and uses the standard library default. Raising net.core.somaxconn does
# NOT raise it: we confirmed somaxconn at 4096 while `ss -ltn` still reported
# Send-Q 128 on the listener. While the node is bootstrapping it is not calling
# accept() at all, so that queue fills and every further inbound connection —
# including from the peers you actually want — is dropped by the kernel.
#
# We measured ~3,700 connections admitted over time pinning a 128-deep queue at
# 129/128 on a box that was trying to bootstrap. The node could not be reached by
# anyone, and nothing in its logs said so.
#
# 🔴 A RATE LIMIT CANNOT FIX THIS. A per-source rate limit (hashlimit, recent,
# nft limit) bounds the ARRIVAL RATE and bounds nothing at all about how many
# connections are simultaneously outstanding. A box admitting 6 new connections
# per hour per source still ends up with thousands of live sockets. The accept
# queue is a CONCURRENCY resource and has to be guarded by a CONCURRENCY rule.
# That is what `connlimit` is.
#
# WHY --connlimit-mask 0
# ----------------------
# connlimit normally counts connections per source address (mask 32). `--mask 0`
# collapses every source into one bucket, i.e. ONE GLOBAL CEILING. That is the
# point: we are protecting a queue with a fixed number of slots, not being fair
# between peers. A per-source limit of N with 200 sources still overruns a
# 128-slot queue.
#
# WHY REJECT --reject-with tcp-reset AND NEVER DROP
# -------------------------------------------------
# A shed peer must fail FAST. Peers admit each other inside a short handshake
# deadline (a few seconds). A silent DROP makes the peer sit there until that
# deadline expires; a TCP reset makes it give up immediately and try elsewhere.
#
# 🔴🔴 NEVER INSTALL A BLANKET REJECT/DROP ON 4001 — not even "just while I
# restart". Your upstream peers probe YOUR 4001 before they will keep serving
# YOU. Blackholing the port does not restrict who may consume from you; it
# restricts who is willing to keep feeding you, and the peers that survive are
# the ones you least need. We reproduced the exact wedge we were trying to repair
# this way. If you must scaffold a rule to prove a hook point is on-path, install
# it, watch the counters climb, swap it for this ceiling, and only THEN restart.
#
# 🔴 LEAVE TCP/4002 COMPLETELY ALONE. A peer you have never met dials your 4002
# as part of admitting you, inside a hard deadline that starts at TCP accept.
# Any rule there — even a rate limit — silently breaks admission for every NEW
# peer while every existing peer keeps working, which is the hardest class of
# fault to notice.
#
# NAMESPACES: if your node runs inside a network namespace with its traffic
# DNAT'd in from the host, host-side inbound traverses FORWARD and never the
# host's INPUT. Use --forward in that case (it installs into both chains). A
# namespace has its OWN netfilter tables, so a rule inside the namespace's INPUT
# does cover the node — before declaring a guard missing, check which namespace's
# table you are reading.

set -euo pipefail

# ---------------------------------------------------------------------------
# Tunables
# ---------------------------------------------------------------------------

# The gossip port. Only the port number matters for this rule.
PORT="${GOSSIP_PORT:-4001}"

# The global ceiling on simultaneously-open inbound connections to $PORT.
#
# HOW TO CHOOSE IT: it must be comfortably BELOW the listener's accept-queue
# depth (read the Send-Q column of `ss -ltn` for the listening socket — NOT
# somaxconn), and comfortably ABOVE the number of peers you actually expect,
# counting the fact that a single peer may hold more than one connection to you.
# With a 128-slot queue and a couple of dozen real peers, 24 leaves the queue
# ~5x headroom over the ceiling. Raise it only after you have read the real
# queue depth.
CEILING="${GOSSIP_CONN_CEILING:-24}"

MODE=status
CHAINS=(INPUT)

for arg in "$@"; do
  case "$arg" in
    --apply)    MODE=apply ;;
    --dry-run)  MODE=dryrun ;;
    --status)   MODE=status ;;
    --remove)   MODE=remove ;;
    --forward)  CHAINS=(INPUT FORWARD) ;;
    -h|--help)  sed -n '2,12p' "$0"; exit 0 ;;
    *) echo "unknown argument: $arg" >&2; exit 2 ;;
  esac
done

command -v iptables >/dev/null 2>&1 || {
  echo "iptables not found. See ceiling.nft in this directory for the nftables form." >&2
  exit 1
}

# The rule body, shared by insert, delete and match. Kept in one array so the
# rule that is REMOVED is byte-identical to the one that was INSERTED — a
# mismatched delete is how half-removed rules accumulate.
rule_args=(
  -p tcp --syn --dport "$PORT"
  -m connlimit --connlimit-above "$CEILING" --connlimit-mask 0
  -m comment --comment "hl-node gossip concurrency ceiling"
  -j REJECT --reject-with tcp-reset
)

run() {
  if [ "$MODE" = apply ] || [ "$MODE" = remove ]; then
    printf '  $ %s\n' "$*"
    "$@"
  else
    printf '  would run: %s\n' "$*"
  fi
}

case "$MODE" in
  status)
    for chain in "${CHAINS[@]}"; do
      printf '== %s (packet/byte counters, rule order matters) ==\n' "$chain"
      # -L with -v -n shows counters and does not resolve DNS. --line-numbers so
      # you can see whether the ceiling is actually FIRST.
      iptables -L "$chain" -v -n --line-numbers | grep -E "dpt:$PORT|Chain|num " || true
    done
    printf '\n== listener accept queue (Send-Q is the real depth) ==\n'
    ss -ltn 2>/dev/null | awk -v p=":$PORT" 'NR==1 || $4 ~ p"$"'
    ;;

  dryrun|apply)
    for chain in "${CHAINS[@]}"; do
      printf '== %s ==\n' "$chain"
      # Purge any existing copy first so a re-run cannot stack duplicates. The
      # `|| true` absorbs the exit 1 from a delete that matched nothing.
      while iptables -C "$chain" "${rule_args[@]}" 2>/dev/null; do
        run iptables -D "$chain" "${rule_args[@]}" || true
      done
      # 🔴 POSITION 1, ALWAYS. If anything above this rule ACCEPTs traffic to
      # $PORT — an allowlist jump, a conntrack ESTABLISHED,RELATED accept, a
      # blanket "trusted subnet" accept — the ceiling is evaluated for nobody who
      # can actually reach you. It will still show up in `iptables -S` and pass
      # any existence check, while protecting nothing. We shipped exactly that:
      # a firewall script re-inserted its own jump at position 1 on every start
      # and quietly demoted the ceiling below it.
      #
      # ⚠ Anything that rebuilds this chain (a firewall unit, ufw reload,
      # fail2ban, docker) will demote this rule again. Re-run with --apply after
      # any such event, or have that tool install the ceiling itself.
      run iptables -I "$chain" 1 "${rule_args[@]}"
    done
    if [ "$MODE" = apply ]; then
      printf '\nInstalled. Verify it is FIRST and that its counters climb:\n'
      printf '  %s --status\n' "$0"
      printf '\nRules are NOT persistent across reboot. Persist them with your\n'
      printf 'distro mechanism (iptables-persistent / netfilter-persistent), and\n'
      printf 're-assert position 1 after anything else rebuilds the chain.\n'
    fi
    ;;

  remove)
    for chain in "${CHAINS[@]}"; do
      while iptables -C "$chain" "${rule_args[@]}" 2>/dev/null; do
        run iptables -D "$chain" "${rule_args[@]}" || true
      done
    done
    echo "removed (if present)"
    ;;
esac
