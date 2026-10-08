# Contributing

Issues and pull requests welcome, especially measurements from node setups
unlike ours.

**The one rule: a number needs a measurement behind it.** If you change a value
or add a setting, say in the commit message what you ran, on what kind of box,
and what the before/after numbers were. "The docs say" and "this is a common
tuning" are not enough — most of the settings here look sensible in either
direction, which is exactly why they are easy to get wrong for a long time
without noticing.

The same goes for removing something. If a setting here does nothing on your
hardware, that is a useful finding; say how you established it.

**Style**

- Shell and Python 3.10+ only. Python: standard library only (the one exception,
  `systemd/safe-log-tail.py`, documents its dependency and its dependency-free
  alternative).
- Bash scripts: `set -euo pipefail`, `shellcheck` clean, and a `--dry-run` or
  report-only default for anything that mutates a box.
- Comment *why*, not *what*. A line saying `# set rmem_max to 32 MiB` is noise;
  the reason 32 MiB rather than 16 is the part a reader cannot reconstruct.
- Traps and wrong turns are content. If you fixed something that looked correct
  for weeks, write down what made it look correct.

**Scope**

Host-level operation of a Hyperliquid node: kernel, systemd, firewall, disk,
and the OS behaviours around them. Not: indexers, trading code, API clients, or
anything that needs a database.
