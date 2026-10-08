# Firewall

```bash
./gossip-connection-ceiling.sh --dry-run
sudo ./gossip-connection-ceiling.sh --apply
./gossip-connection-ceiling.sh --status      # rules, counters, real queue depth
```

A **global concurrent-connection ceiling** on TCP/4001, the node's gossip port.
`ceiling.nft` is the same rule for nftables. The full reasoning is in the header
of `gossip-connection-ceiling.sh`; the three things to take away:

1. **A rate limit does not protect an accept queue.** The queue is small (128 in
   at least one common implementation) and `somaxconn` does not raise it. A
   per-source rate limit bounds arrivals and bounds *nothing* about how many
   connections are simultaneously outstanding — ~3,700 connections admitted over
   time, all within the rate limit, pinned a 128-slot queue on a box that was
   bootstrapping and therefore not calling `accept()`.
2. **Reject with a TCP reset, never DROP.** A shed peer must fail fast rather
   than sit on your port until its admission deadline expires.
3. **Never blanket-block the port, and never touch TCP/4002.** Your upstreams
   probe your gossip port before they will keep serving *you*; blackholing it
   costs you your feeds, not your load. And a peer you have never met dials 4002
   to admit you, inside a hard deadline — any rule there breaks admission for
   every new peer while existing peers keep working, which is close to
   undetectable.

## Position matters, and it will be undone

The rule must be **first** in the chain. Anything above it that accepts traffic
to the port — an allowlist jump, a blanket trusted-subnet accept — means the
ceiling is evaluated for nobody who can actually reach you. It still shows up in
`iptables -S` and passes any existence check while protecting nothing. We shipped
exactly that: another firewall script re-inserted its own jump at position 1 on
every start and quietly demoted the ceiling below it.

Anything that rebuilds your chains (a firewall unit, `ufw reload`, fail2ban,
docker) will demote it again. Re-run `--apply` after such an event, check
`--status` for the rule's position, and confirm the counters actually climb.
