# Disk retention

A Hyperliquid node with `--write-*` flags enabled writes continuously and deletes
nothing. On mainnet the raw book-diff stream alone is multiple GB per hour. The
disk fills in days, and a full disk stops the node — which, if the node is
behind, can cost a full state bootstrap to get back.

- `prune-node-data.sh` — age-based pruner. **Dry run by default**; `--apply` to
  actually delete. Deletes files only, never directories, only under the
  configured data directory, only matching a configured pattern.
- `retention.example.conf` — the rule file. Read its comments before picking
  numbers: measure your own throughput, and make sure retention outlives whatever
  consumes the files.

## Running it on a timer

```ini
# /etc/systemd/system/hl-node-prune.service
[Unit]
Description=Prune Hyperliquid node data files

[Service]
Type=oneshot
User=<node-user>
Environment=HL_DATA_DIR=/home/<node-user>/hl/data
ExecStart=/opt/hl-node-tools/disk/prune-node-data.sh --apply --config /etc/hl-node-retention.conf
```

```ini
# /etc/systemd/system/hl-node-prune.timer
[Unit]
Description=Prune Hyperliquid node data files every 10 minutes

[Timer]
OnBootSec=5min
OnUnitActiveSec=10min
# Prevents every box you run from firing at the same instant.
RandomizedDelaySec=60

[Install]
WantedBy=timers.target
```

`sudo systemctl enable --now hl-node-prune.timer`, then check the **service**,
not the timer: a timer showing `NEXT —` is normal while its service is running,
and a timer that ran successfully tells you nothing about whether the service did
anything useful. `journalctl -u hl-node-prune.service -n 50`.

## Before you arm it

Run `--dry-run` first, on the real config, on the real box. Every code path
except the `rm` itself runs identically, so it is a faithful rehearsal. Read the
file counts and sizes it reports and make sure you recognise them.
