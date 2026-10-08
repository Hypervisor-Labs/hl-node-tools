# systemd

- `hl-node-supervisor.service.example` — a commented unit for the node
  supervisor. Substitute `@NODE_USER@` / `@NODE_HOME@` and your own flag set.
- `10-local-overrides.conf.example` — drop-in template for per-box settings.
- `safe-log-tail.py` — journal tail that keeps the unit name out of argv.

## 🔴 The `/proc` self-scan trap

The node scans `/proc/<pid>/cmdline` **when it starts** and aborts if it finds
more than one live process whose argv contains its own program name — it is
looking for a stale copy of itself. Any of these is such a process:

```bash
journalctl -u hl-visor -f
journalctl -fu hl-visor
pgrep -af hl-visor
pgrep -x hl-node
systemctl restart hl-visor
bash -c '... hl-visor ...'        # the wrapper's own argv holds the literal
```

A following tail left open in a terminal is the dangerous one, because it is
still running the next time the node starts. We produced six consecutive
spurious crash-loops this way before realising the tail was the cause, and the
node booted cleanly the instant no offending argv existed.

The scan only runs at node **startup**, so these commands are harmless in steady
state. That is what makes it so hard to attribute: everything works for days, and
then a restart fails for reasons that have nothing to do with the restart.

### Fix 1 (preferred, no tooling): a neutral syslog identifier

```ini
[Service]
SyslogIdentifier=hlsup
```

then

```bash
journalctl -t hlsup -f
journalctl -t hlsup -n 200 --no-pager
```

Neither command's argv contains a forbidden literal.

### Fix 2: `safe-log-tail.py`

Reads the journal through libsystemd, taking the unit name from an environment
variable so it never reaches argv:

```bash
sudo apt install python3-systemd
SAFE_TAIL_UNIT=hl-visor.service ./safe-log-tail.py -n 200
```

### Checking unit state safely

`systemctl show` on a hyphenated unit name does put the literal in a child's
argv, but that child exits in well under a second, so it is only a hazard if it
races a node startup. If you need to be certain, split the literal:

```bash
u=hl-vis; systemctl show "${u}or.service" -p ActiveState -p SubState -p NRestarts
```

And to check liveness without `pgrep`, ask the node's own info port instead:

```bash
timeout 3 bash -c 'exec 3<>/dev/tcp/127.0.0.1/3001' && echo "info port open"
```

## Grading a unit

Grade the **service**, never the timer. A timer showing `NEXT —` is normal while
its triggered service is still active, and a timer that fired successfully tells
you nothing about whether the service accomplished anything. Likewise
`ActiveState=active` and a frozen `NRestarts` are compatible with a process that
has been completely dead for hours — especially if the supervisor is alive and
its child is not. Grade on output: a file's mtime advancing, a height counter
increasing, a socket that answers.
