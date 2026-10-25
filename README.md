# hl-node-tools

Host tuning and operations scripts for running a **Hyperliquid node** (`hl-visor`
/ `hl-node`) on your own box.

Nothing here talks to the node's RPC, parses its data, or needs any software
beyond a shell and Python 3. It is the layer *underneath* the node: kernel
network settings, systemd unit shape, a connection ceiling in front of the gossip
port, disk retention, and the handful of operating-system behaviours that will
restart your node at the worst possible moment if you let them.

Every value in here traces to something we measured on production nodes
(bare-metal servers with high-clock desktop-class CPUs), and every setting carries a per-line
comment explaining what it does and why. Where we got something wrong first,
that is written down too — the wrong turns are usually more useful than the
final number.

> Not affiliated with Hyperliquid. No warranty. Read a script before you run it;
> several of them are one flag away from deleting files or changing your
> firewall.

## Tools

| Path | What it is | Run it when |
|---|---|---|
| [`sysctl/99-zz-hl-node-network.conf`](sysctl/) | Kernel network tuning: BBR + fq, 32 MiB socket-buffer ceilings, fast keepalive, deeper backlogs. Every line commented. | On every node box, before it starts pulling blocks. |
| [`sysctl/apply.sh`](sysctl/apply.sh) | Idempotent installer. `--dry-run`. Loads and persists the BBR module, shows before/after, and warns about any drop-in that would override you. | To apply or to reconcile a box. |
| [`sysctl/verify.sh`](sysctl/verify.sh) | Reads the **live** values back and grades them. Read-only, no root. | In monitoring, after a reboot, or any time you want evidence rather than intent. |
| [`systemd/hl-node-supervisor.service.example`](systemd/) | A commented unit for the node supervisor: restart policy, `LimitNOFILE`, the per-UID `LimitNPROC` trap, `TasksMax`, OOM protection, sandboxing. | Standing up a node as a service. |
| [`systemd/10-local-overrides.conf.example`](systemd/) | Drop-in template, including the "list directives append, they do not replace" trap. | Per-box overrides you do not want a unit update to eat. |
| [`systemd/safe-log-tail.py`](systemd/safe-log-tail.py) | Tails a unit's journal **without the unit name in argv** — see the self-scan trap below. | If you cannot set a neutral `SyslogIdentifier=`. |
| [`firewall/gossip-connection-ceiling.sh`](firewall/) | Global concurrent-connection ceiling on TCP/4001 (iptables). `--dry-run`, `--status`, `--remove`. | On any node that is reachable from the open internet. |
| [`firewall/ceiling.nft`](firewall/ceiling.nft) | Same rule in nftables. | If you run nftables. |
| [`disk/prune-node-data.sh`](disk/) | Age-based pruner for the node's `--write-*` output. **Dry run by default.** | On any node with write flags enabled. Which is most of them. |
| [`upgrade/preflight.sh`](upgrade/) | Grades a node box PASS/WARN/FAIL for surviving the next hardfork: supervisor present and current, release current (gpg + metadata hash verified), lag, freeze status, disk, restart hygiene. Read-only, `--json`. | Before every network upgrade, and in monitoring. |
| [`upgrade/fork-watch.sh`](upgrade/) | Every 30 s, classifies the node against a fork from its own files (`FORK_PENDING`, `BEHIND_AT_FREEZE`, `FROZEN_OLD_VERSION`, `RESTART_LOOP`, `RECOVERED`...). node_exporter metrics, webhook, opt-in auto-recover. | Always, from the timer in `upgrade/systemd/`. |
| [`upgrade/recover.sh`](upgrade/) | Installs the current signed release (and supervisor) into the supervisor's layout and restarts the unit once; guides a state reset. **Dry run by default.** | When a node missed a fork or is stuck at the freeze height. |
| [`host/apply-restart-hygiene.sh`](host/) | Stops apt/needrestart from restarting your node, and stops a brute-force flood from permanently latching sshd. Debian/Ubuntu. | Once, on a new box. |

## Quick start on a fresh node box

```bash
git clone <this repo> /opt/hl-node-tools && cd /opt/hl-node-tools

sudo ./sysctl/apply.sh --dry-run     # read it
sudo ./sysctl/apply.sh
./sysctl/verify.sh

sudo ./host/apply-restart-hygiene.sh              # status only
sudo ./host/apply-restart-hygiene.sh --apply

sudo ./firewall/gossip-connection-ceiling.sh --dry-run
sudo ./firewall/gossip-connection-ceiling.sh --apply

./disk/prune-node-data.sh --dry-run               # then wire it to a timer
```

## What these numbers are based on

All figures below were measured on production Hyperliquid nodes — bare-metal
servers with high-clock desktop-class CPUs, plus some rented virtual machines.
They are reported here in generic terms. Your
rates will differ; the *shape* of each result is what transfers.

**The TCP send window is the single highest-leverage setting.** Sending a 5.2 GB
bulk transfer to a peer roughly 250 ms away failed at 12–14 MB/s on every
attempt, because the **sending** box's `tcp_wmem` maximum was 4 MB. Raising the
send window to 32 MiB made the same transfer complete in 93 s at a ~65 MB/s peak.
Nothing else changed. Throughput on one TCP connection is bounded by
`window / RTT`; 4 MiB over 250 ms is about 16 MB/s no matter how much bandwidth
you have paid for. A second operator hit and fixed the same thing independently
on the receiving end. **The effective window is the minimum of the two ends**, so
tuning one side can fix nothing.

**We initially "ruled out buffers" by checking the receiver only.** The sender's
4 MB send window went unexamined for weeks while we looked elsewhere. Check both
directions on both ends.

**BBR is for stability, not for distance.** A ~245 ms bulk path with BBR and
16 MiB buffers on *both* ends moved 400 MB in 55.3 s — 7 MB/s, statistically
identical to the same path untuned. Bandwidth-delay-product and loss set that
number; congestion control does not. If a bulk copy over a long path is slow,
the fix is a closer source. BBR still earns its place: it holds connections
together under loss far better than cubic, which is what you want from a gossip
peer 200 ms away.

**A rate limit does not protect an accept queue.** The gossip listener's accept
queue is small and fixed — 128 in at least one common implementation, and
`net.core.somaxconn` does **not** raise it (we confirmed somaxconn at 4096 while
`ss -ltn` still showed Send-Q 128). Roughly 3,700 connections admitted over time,
each perfectly within a per-source rate limit, pinned that queue at 129/128 on a
box that was bootstrapping and therefore not calling `accept()` at all. The queue
is a *concurrency* resource and needs a *concurrency* rule. See `firewall/`.

**Never blanket-block the gossip port.** Your upstream peers probe your port
before they will keep serving you. A blanket DROP does not restrict who may
consume from you, it restricts who is willing to keep feeding you — and it
reproduces the exact wedge you were trying to repair.

**Sysctl drop-in order is a real bug, not a style point.** `/etc/sysctl.d/*.conf`
is applied in lexical order and the last write wins. We carried a 32 MiB window
in a `90-` file that was silently reverted to 16 MiB by a `99-` file on every
`sysctl --system`; the live value read 32 MiB only because someone had applied it
by hand afterwards. That box was one reboot from being quietly wrong for months.
Hence the `99-zz-` filename here, and hence `verify.sh` checking for anything
that sorts after it.

**An unplanned restart is expensive.** A node restarted while far enough behind
discards state and takes a full bootstrap: ~1 GB on the wire, 1,534 retries, and
3h45m blind in the case we measured. It was caused by a routine glibc upgrade,
30 seconds after the daily apt timer fired. See `host/`.

**Disk fills faster than you estimate.** One output stream sized from a
17–26 GB/h estimate measured 30–41 GB/h at a market open; five hours of it
reached 130 GB and took the root filesystem to 82%. Measure, do not estimate.

## 🔴 The trap that will bite you first

**The node scans `/proc` at startup and panics if any other running process has
its program name in argv.** It is looking for a stale copy of itself. That means

```bash
journalctl -u hl-visor -f      # ← this is such a process
pgrep -af hl-visor             # ← and this
systemctl restart hl-visor     # ← and this
```

A terminal left following the logs will make the node panic and restart-loop the
next time it starts, and the logs you are watching will tell you nothing useful
about why. We burned six spurious crash-loops learning it.

The cheapest fix is one line in the unit:

```ini
SyslogIdentifier=hlsup
```

then tail by identifier — `journalctl -t hlsup -f` — whose argv contains no
forbidden literal. `systemd/safe-log-tail.py` is the alternative if you cannot
change the unit. Details in [`systemd/README.md`](systemd/).

## Once the host is tuned: finding peers

These tools make the box ready to peer. Choosing who to peer with is the next
step, and the same team publishes three things for it:

- **The network map:** [hypervisor.gg/network](https://hypervisor.gg/network)
  draws the public gossip network live, as a globe or as a tier view (distance
  from the sentries). How to read it:
  [docs/network-map](https://hypervisor.gg/docs/network-map).
- **The Peer API and its clients:**
  [HypervisorLabs/hl-peers](https://github.com/HypervisorLabs/hl-peers) queries
  that same graph (tier-1 peers, peers in a country that serve the mempool,
  peers that are not full) in Elixir, TypeScript, Rust or Python, and writes a
  validated `override_gossip_config.json` for your node. Anonymous use works
  without a key. Docs: [docs/peer-api](https://hypervisor.gg/docs/peer-api/overview).
- **Relay peering, our paid service:** if you would rather not depend on
  whoever happens to have a free slot, connect your node to our relays instead:
  [hypervisor.gg/peering](https://hypervisor.gg/peering).

Run the tuning above before you peer with anyone, us included: the send-window
result applies to every peer, not just ours.

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md). Short version: a number without a
measurement behind it does not go in.

## License

MIT — see [LICENSE](LICENSE).
