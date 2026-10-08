# Kernel network tuning

```bash
sudo ./apply.sh --dry-run    # see exactly what would change
sudo ./apply.sh              # apply (idempotent)
./verify.sh                  # grade the live values; read-only, no root
```

`99-zz-hl-node-network.conf` is the whole configuration, and every line in it
carries its own rationale. Read it — it is the documentation.

## Three things worth knowing before you apply it

**The filename prefix is load-bearing.** `/etc/sysctl.d/*.conf` is applied in
lexical order and the last assignment to a key wins. A file that sorts after
yours silently reverts your tuning on the next `sysctl --system` or reboot, and
until then the live value looks correct. `99-zz-` sorts after essentially
everything; `verify.sh` re-checks that nothing sorts after it. Keep all the keys
in this one file — splitting "tuning" and "the big window" across two files is
what creates the trap.

**BBR is a kernel module.** If `tcp_bbr` is not loaded, the
`tcp_congestion_control = bbr` line is silently ignored and you stay on cubic
with no error anywhere. `apply.sh` loads it and persists it in
`/etc/modules-load.d/`. Always read the value back.

**`somaxconn` raises a ceiling, not a listener's backlog.** A server that calls
`listen()` with a hardcoded 128 stays at 128 forever. Read the `Send-Q` column of
`ss -ltn` on the listening socket to see the real depth. `verify.sh` prints it.
The real protection for a shallow accept queue is the connection ceiling in
[`../firewall/`](../firewall/).

## Applying it to an existing box

`apply.sh` is safe to re-run. It does not restart anything, and the settings take
effect immediately on new connections. Existing connections keep the buffer sizes
they negotiated, so a long-lived peer connection will not benefit until it
reconnects — which is fine, and is not a reason to bounce the node.
