#!/usr/bin/env python3
"""Tail a systemd unit's journal WITHOUT putting the unit name in argv.

WHY THIS EXISTS
---------------
The Hyperliquid node performs a scan over /proc/<pid>/cmdline when it starts and
aborts if it finds more than one live process whose argv contains its program
name (it is looking for a stale copy of itself). A shell running

    journalctl -u <supervisor-unit> -f

is such a process, because the unit name contains the program name. Leaving that
tail open across a node restart makes the node panic on startup and restart-loop
until you close your terminal. We burned six spurious crash-loops learning this,
and the same trap catches `pgrep -af <name>`, `systemctl restart <name>`, and any
`bash -c '... <name> ...'` wrapper: the wrapper's own argv holds the literal.

The scan only runs at node STARTUP, so a tail is harmless in steady state — but a
FOLLOWING tail is precisely the thing that is still open when a restart happens.

THE TWO FIXES, IN ORDER OF PREFERENCE
-------------------------------------
1. NO TOOLING REQUIRED — give the unit a neutral SyslogIdentifier (the example
   unit in this directory sets `SyslogIdentifier=hlsup`) and tail by
   identifier instead of by unit:

       journalctl -t hlsup -f

   That argv contains neither program name, so it can never trip the scan. If
   you can edit the unit, do this and you do not need this script at all.

2. THIS SCRIPT — read the journal through libsystemd, so the unit name lives in
   an environment variable and Python objects only and never reaches argv.

PORTABILITY
-----------
Requires the `systemd` Python bindings, which are a distro package and NOT part
of the standard library:

    Debian/Ubuntu:  sudo apt install python3-systemd
    Fedora/RHEL:    sudo dnf install python3-systemd

If you cannot install it, use fix 1 above. Do not "work around" this by running
journalctl with the unit name in a variable — the variable is expanded by the
shell before exec, so the literal is in the child's argv either way.

USAGE
-----
    SAFE_TAIL_UNIT=hl-visor.service ./safe-log-tail.py            # follow, last 100
    SAFE_TAIL_UNIT=hl-visor.service ./safe-log-tail.py -n 500
    SAFE_TAIL_UNIT=hl-visor.service ./safe-log-tail.py --no-follow

The unit name is taken from the environment DELIBERATELY: passing it as a command
line argument would defeat the entire purpose of this script.
"""

import argparse
import os
import select
import sys

try:
    from systemd import journal
except ImportError:  # pragma: no cover - environment dependent
    sys.exit(
        "python3-systemd is not installed.\n"
        "  Debian/Ubuntu: sudo apt install python3-systemd\n"
        "  Fedora/RHEL:   sudo dnf install python3-systemd\n"
        "Or set SyslogIdentifier= on the unit and use `journalctl -t <id> -f`."
    )


def main() -> int:
    ap = argparse.ArgumentParser(
        description="Follow a systemd unit's journal without the unit name in argv."
    )
    ap.add_argument("-n", "--lines", type=int, default=100,
                    help="how many recent lines to print before following")
    ap.add_argument("--no-follow", action="store_true",
                    help="print the recent lines and exit instead of following")
    args = ap.parse_args()

    # The unit name comes from the environment so that it never appears in this
    # process's /proc/<pid>/cmdline. Anyone reading the trap above should not be
    # tempted to add a positional argument here.
    unit = os.environ.get("SAFE_TAIL_UNIT")
    if not unit:
        return ("set SAFE_TAIL_UNIT to the unit name, e.g. "
                "SAFE_TAIL_UNIT=my-node.service %s" % sys.argv[0])

    reader = journal.Reader()
    # _SYSTEMD_UNIT is a trusted journal field stamped by the journal daemon; it
    # cannot be forged by the logging process, unlike SYSLOG_IDENTIFIER.
    reader.add_match(_SYSTEMD_UNIT=unit)
    reader.seek_tail()

    # seek_tail() positions AFTER the last entry, so step back N entries to
    # provide scrollback. get_previous() returns {} at the start of the journal.
    backlog = []
    for _ in range(max(args.lines, 0)):
        entry = reader.get_previous()
        if not entry:
            break
        backlog.append(entry)
    for entry in reversed(backlog):
        print(entry.get("MESSAGE", ""))
    sys.stdout.flush()

    if args.no_follow:
        return 0

    # Re-seek to the tail so following starts after what we just printed.
    reader.seek_tail()
    reader.get_previous()

    # poll() on the journal's own fd: no busy loop, no polling interval to tune.
    poller = select.poll()
    poller.register(reader, reader.get_events())
    try:
        while True:
            poller.poll()
            # process() tells us whether the journal actually advanced (APPEND)
            # or merely rotated/invalidated; only APPEND has new entries to read.
            if reader.process() != journal.APPEND:
                continue
            for entry in reader:
                print(entry.get("MESSAGE", ""))
            sys.stdout.flush()
    except KeyboardInterrupt:
        return 0
    except BrokenPipeError:
        # Piping into `head` closes our stdout; exit quietly rather than dumping
        # a traceback over the user's terminal.
        return 0


if __name__ == "__main__":
    sys.exit(main())
