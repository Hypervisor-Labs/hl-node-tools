# upgrade/: get a node through a hardfork

Three tools for the one day a Hyperliquid node is most likely to break: a network
upgrade (hardfork). They run on your own box, use only bash and Python 3, and act
only through systemd.

| Tool | What it does | Changes anything? |
|---|---|---|
| [`preflight.sh`](preflight.sh) | Grades the box PASS/WARN/FAIL for surviving the next fork. `--json`. | No |
| [`fork-watch.sh`](fork-watch.sh) | Every 30 s, classifies the node relative to a fork from its own files. node_exporter metrics, optional webhook, optional auto-recover. | Only with `--auto-recover` |
| [`recover.sh`](recover.sh) | Installs the current signed release (and supervisor), restarts the unit, guides a state reset. Dry run by default. | Only with `--apply` |
| [`systemd/`](systemd/) | Timer + service for fork-watch every 30 s. | - |

## How an upgrade works

An upgrade is coordinated on **chain height**, not on the clock:

1. The node writes a `scheduled_freeze_height` into
   `~/hl/hyperliquid_data/visor_abci_state.json`. We have seen it appear only
   **20 to 80 seconds** before the chain stops, even when the upgrade was announced
   hours earlier for a different time.
2. Hyperliquid publishes the new node release on its CDN, signed.
3. Every node stops at exactly the freeze height.
4. The **supervisor** (`hl-visor`) downloads the new release, verifies it, swaps
   the binary and restarts its child. `hardfork_version` goes up by one and the
   chain resumes. Measured stoppage: one to two minutes.

The node binary has no self-update path. **The supervisor is the only thing that
moves a node across a fork.** Every failure below is a way that step 4 does not
happen.

## The failure modes, in plain words

**1. No supervisor.** A unit that runs the node binary directly (systemd
`Restart=always` and nothing else) stops at the freeze height. systemd restarts the
same old binary, which stops again. It can sit there for hours, still answering
status queries, looking alive. *fork-watch: `FROZEN_OLD_VERSION`, or
`RESTART_LOOP` if systemd keeps restarting it. preflight: `supervision` FAIL.*

**2. The supervisor cannot install the new release.** The supervisor downloads
with `curl` and verifies with `gpg` using its own keyring, plus a signed metadata
file. If any part fails, it logs *"download or verify quorum failed, keeping child
running"* and keeps the OLD node running, which then freezes as in case 1. Causes
we have seen or can see coming:
- an **outdated supervisor**: an older build verified releases with a file
  (`signature_quorum.json`) that Hyperliquid no longer publishes, so it cannot
  verify any new release;
- `gpg` installed but Hyperliquid's public key never imported into the
  supervisor user's keyring;
- `curl` missing, DNS or the CDN unreachable from the box at that minute.

*fork-watch: `FROZEN_OLD_VERSION`. preflight: `visor-current`, `supervisor-keyring`,
`tool-gpg`/`tool-curl`.*

**3. Behind at the freeze.** The supervisor prefers to wait until its child reaches
the freeze height, but only for 60 seconds after it sees the new release. Then it
swaps anyway. A node that was still more than roughly **1,600 blocks** below the
freeze loads its pre-fork state into the new binary, which panics on the first
post-fork block (`assertion left == right failed: ... Hardfork{version: N+1} ...
Hardfork{version: N}`). From then on it loops until someone resets its state.
*fork-watch: `BEHIND_AT_FREEZE` before the freeze (the only warning you get),
`RESTART_LOOP` after. preflight: `lag` and `freeze`.*

**4. Old binary, fresh bootstrap: the expensive loop.** A node on the old binary
that restarts far behind discards its state and bootstraps a fresh one from a
peer. The peer serves the CURRENT, post-fork state, and the old binary cannot use
it. Reproduced on testnet with the previous release: it received the state, then
panicked at startup with `failed to validate hardfork version: unexpected state
hardfork version: N+1, expected hardfork version: N`, and systemd restarted it
every ~30 seconds. It dies before it writes `visor_abci_state.json`, so nothing
in that file ever looks wrong; only the restart count does. When every cycle is a
full state transfer the cost lands on the peer serving it: one node in this loop
pulled roughly 1.5 TB in five hours, and never recovered on its own.
*fork-watch: `RESTART_LOOP`.*

**The node checks the release metadata itself.** At startup the node reads
`hl/hyperliquid_data/node_metadata.json` (the supervisor writes it) and refuses to
start if the file is missing (`failed to validate hardfork version: missing file`)
or names a different hardfork than its state. A hand-rolled install that copies
only the binary therefore fails too. recover.sh always installs the matching
metadata; preflight checks it.

## What each tool does about it

| Failure | preflight (before) | fork-watch (during) | recover (after) |
|---|---|---|---|
| 1. no supervisor | FAIL `supervision` | `FROZEN_OLD_VERSION` / `RESTART_LOOP` | installs the release at the unit's binary path, restarts; tells you to move to the supervisor |
| 2. supervisor cannot install | FAIL `visor-current`, `supervisor-keyring`, tools | `FROZEN_OLD_VERSION` | installs release + current supervisor + the release metadata, restarts |
| 3. behind at freeze | FAIL `lag` / `freeze` | `BEHIND_AT_FREEZE` | `--reset-state`: moves the pre-fork state aside, fresh bootstrap |
| 4. old binary bootstrap loop | FAIL `node-current` | `RESTART_LOOP` | installs the release, restarts once |

### fork-watch classes

| Class | Meaning |
|---|---|
| `OK` | no freeze scheduled |
| `FORK_PENDING` | freeze scheduled, node close enough to reach it |
| `BEHIND_AT_FREEZE` | freeze scheduled, node > 1,600 blocks below it AND lagging in time: brick risk |
| `FROZEN_OLD_VERSION` | at the freeze height on the old hardfork version for > 5 min (a healthy swap takes 1-2) |
| `RESTART_LOOP` | >= 3 supervisor restarts or child respawns in 30 min and not steadily healthy; counted even when the state file is missing (`fork_context` says whether a fork was seen in the last 24 h) |
| `RECOVERING` | was in a bad class; no longer, but not yet following the chain |
| `RECOVERED` | was in a bad class; now on the new version, lag < 30 s for 3 samples in a row (held 30 min) |
| `UNKNOWN` | `visor_abci_state.json` missing or unreadable |

Inputs, all node-local: `visor_abci_state.json` (height, hardfork version, freeze
height, and `consensus_time` vs `wall_clock_time`, which is lag measured against
nothing but the node itself), systemd's `NRestarts` for the unit, and the
supervisor's `hl/data/visor_child_stderr/` files (one per child start, named by its
start time), which count child respawns that systemd never sees. Thresholds are
flags (`--behind-blocks`, `--frozen-min`, `--loop-restarts`, `--loop-window-min`).

Metrics (`--textfile`): `hl_upgrade_class{class=...}` one-hot, plus
`hl_upgrade_height`, `_hardfork_version`, `_scheduled_freeze_height`,
`_lag_seconds`, `_state_age_seconds`, `_restarts_in_window`,
`_class_since_seconds`, `_auto_recover_attempts`, `_last_run_timestamp_seconds`.
A useful alert: `hl_upgrade_class{class=~"BEHIND_AT_FREEZE|FROZEN_OLD_VERSION|RESTART_LOOP"} == 1`.

`--record FILE` appends every raw observation; the test suite replays such
recordings through the classifier (`tests/fixtures/fork-watch/recorded/`).

## How the release is verified

`recover.sh` and `preflight.sh` verify a release the way the supervisor does:

1. `GET {cdn}/active` gives the release index;
   `{cdn}/{index}/node_metadata.json` names its hardfork version (`hv`) and the
   binary's hash (`bh`).
2. The binary's detached signature (`.asc`) must verify with **Hyperliquid's
   release key**, fetched from the `hyperliquid-dex/node` repository into a
   throwaway keyring, with its fingerprint **pinned**
   (`CF2C2EA3DC3E8F042A55FB6503254A9349F1820B`). Any other key is refused.
3. The metadata index must equal the active index, and **keccak-256** of the binary
   must equal `bh` (it is keccak-256, not sha256: checked against several releases).
   Python's hashlib has no keccak-256, so the helper carries a small implementation
   (two to five minutes of CPU for a node binary; it uses pycryptodome if
   installed). preflight skips this step unless you pass `--full`; recover.sh
   always does it.
4. The release's hardfork version must not be older than the local state's.

Not re-checked: the secp256k1 signature quorum inside `node_metadata.json`. Its
signed-message encoding is not public, and we would rather say so than pretend.
Steps 2-3 already bind the binary to Hyperliquid's key and the metadata to the
binary; the supervisor runs its own full check when it next downloads.

The supervisor itself is published unversioned at `{cdn}/hl-visor` with a `.asc`;
gpg is its whole check.

`cdn` is `https://binaries.hyperliquid.xyz/Mainnet` or
`https://binaries.hyperliquid-testnet.xyz/Testnet`.

## Opt-in auto mode, and why it is safe

`fork-watch.sh --auto-recover` (as root) runs `recover.sh --apply` when
`FROZEN_OLD_VERSION` or `RESTART_LOOP` has persisted for 10 minutes
(`--auto-after-min`). It never acts on `BEHIND_AT_FREEZE`: before the freeze there
is nothing to install, and a running catch-up must not be interrupted.

The argument:
- **It can only install what Hyperliquid published and signed.** recover.sh
  refuses on any verification failure and changes nothing. There is no flag to skip
  verification.
- **At most one attempt per fork**, keyed on the freeze height, plus a 60-minute
  backoff between any two attempts (`--auto-backoff-min`). The attempt is recorded
  before recover.sh runs, so a crash mid-recover cannot become a retry loop. A lock
  stops two runs overlapping.
- **It restarts only when it changed something.** When the installed binaries are
  already the verified release, the running process is that binary and the state is
  usable, recover.sh exits without touching the unit. Running it twice is a no-op.
- **It never resets state unless you add `--auto-reset-state`.** Without it, a
  pre-fork state is reported, not moved.
- It acts through the unit (`systemctl` jobs over D-Bus), never by process name.

## Quick start

```bash
cd /opt/hl-node-tools            # wherever you cloned it; see "the kit's own path"

./upgrade/preflight.sh                       # read-only, any user
./upgrade/fork-watch.sh                      # one classification
sudo ./upgrade/recover.sh                    # dry run: verifies, prints the plan

# every 30 s, metrics only (edit @REPO@ first)
sudo cp upgrade/systemd/hl-fork-watch.service.example /etc/systemd/system/hl-fork-watch.service
sudo cp upgrade/systemd/hl-fork-watch.timer.example /etc/systemd/system/hl-fork-watch.timer
sudo systemctl daemon-reload && sudo systemctl enable --now hl-fork-watch.timer
```

Discovery is automatic: the supervisor/node process (matched by `/proc/<pid>/comm`,
never by `pgrep`), its unit, `$HOME` from the unit, the chain from `visor.json`.
Override with `--unit`, `--home`, `--chain mainnet|testnet`.

**Binaries under other names: `--node-bin PATH` / `--visor-bin PATH`.** All three
tools accept them (or `NODE_BIN_OPT` / `VISOR_BIN_OPT` in the environment). Process
matching then uses the renamed file's name, and recover.sh installs to that path.
The main use is a second node on a box that already runs one: a production
supervisor panics at startup if any other process carries the node's name in its
argv, so a test node run as e.g. `/opt/scratch/bin/tnode` under a bare unit cannot
trip it. (A supervisor always starts its child as `$HOME/<node name>`, so only a
bare-unit node can be renamed this way.)

When a fork goes wrong:

```bash
sudo ./upgrade/recover.sh                    # what would it do?
sudo ./upgrade/recover.sh --apply            # install + restart once
sudo ./upgrade/recover.sh --apply --reset-state   # only if it says the state is pre-fork
```

## 🔴 Traps

**The /proc self-scan.** The node and the supervisor scan `/proc` at startup and
panic if any OTHER process has either program name anywhere in its command line
(top-level README). The supervisor has even been seen panicking on its own `pgrep`
helper. So these tools never put either name in an argv: names are assembled at
runtime and compared against `/proc/<pid>/comm`; units are addressed over D-Bus by
their escaped object path (a unit named after the supervisor would otherwise put the
name in `systemctl restart <unit>`); staged downloads use neutral file names.
`tests/test_upgrade.py` fails the build if a literal name appears in the code.

**The kit's own path.** This repository is called `hl-node-tools`, and that name
contains the node's program name. Run `/opt/hl-node-tools/upgrade/fork-watch.sh`
from a timer and every run puts the name in argv. The scripts refuse to run when
started that way. Start them by a relative path from the repo root (as above), or
with `WorkingDirectory=` and `bash upgrade/fork-watch.sh` in a unit (the example
does this), or copy `upgrade/` to a neutral path.

**Device paths as output files.** `--textfile` is written to a temp file and
renamed over the target. Renamed over `/dev/null`, that replaces a device node the
whole box depends on (we crashed a node child exactly this way). fork-watch refuses
`/dev`, `/proc` and `/sys` targets and anything that exists but is not a regular
file.

**A slow peer cannot finish a bootstrap.** The node gives a peer about 60 seconds
to deliver the whole state greeting and then moves on to the next one. On testnet
the greeting is ~340 MB, and distant peers served it at ~1 MB/s, so attempt after
attempt timed out partway (one reached 284 of 338 MB). A nearby peer delivered it
in 18 seconds. If a fresh bootstrap keeps logging `abci_stream ... timed out`, put
a nearby, well-connected node first in `root_node_ips` of
`override_gossip_config.json`.

**The bootstrap after a state reset.** A bootstrapping node stops calling
`accept()` on its gossip port. On a box that many peers already dial, the listen
backlog fills in minutes; the serving peer's 5-second dial-back probe of your port
then fails, and it refuses you. A fresh, unknown box bootstraps fine; an
established one took 38 minutes in one case and hours in others. Before a reset,
put [`firewall/gossip-connection-ceiling.sh`](../firewall/) in front of the port
(it caps concurrency instead of blocking). Never blanket-DROP the port: that turns
a slow retry lottery into a deadlock. Do not restart a node that is mid-bootstrap
or paging blocks.

**A frozen node can look alive.** At the freeze height on the old version, the node
can keep answering status queries. Only the height, the hardfork version and the
lag tell the truth. Watch those, not the process.

## Testing

`python3 -m unittest discover -s tests -v` replays synthetic and recorded
observation sequences through the classifier and checks the helpers (keccak
vectors, lag parsing, metrics file safety, the no-literal-names rule). No node, no
network, no root.

Live-tested on a scratch testnet node (a bare unit running a renamed binary) on
2026-10-25, against the previous release (hardfork 1552) while the network was on
1553:
- the old binary's restart loop, classified `RESTART_LOOP` by fork-watch, with the
  webhook firing;
- `recover.sh --apply` installing the verified release; the node followed the
  chain again (lag < 1 s) about 14 minutes later;
- `fork-watch --auto-recover` doing the same with no operator: one attempt,
  `RECOVERED`, webhooks for each change;
- preflight against the broken node (FAIL) and the healthy one;
- running everything twice: the second `recover.sh --apply` changed and restarted
  nothing;
- the `--reset-state` file list: with those entries moved aside the node logs
  `using local AbciState: missing` and bootstraps fresh.

Two of those recordings are replayed in `tests/fixtures/fork-watch/recorded/`.

Fixture-only (not reproduced live): `BEHIND_AT_FREEZE`, `FROZEN_OLD_VERSION`, a
supervisor that cannot download (the supervisor always starts its child under the
standard name, so a supervisor-managed test node could not run beside another node
without tripping the /proc scan), and whether a current binary discards a full
pre-fork state by itself. A pre-fork state file alone, without its EVM database,
was ignored and the node bootstrapped; the full case stays untested.
