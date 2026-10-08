# Host hygiene

```bash
./apply-restart-hygiene.sh              # report what is missing, change nothing
sudo ./apply-restart-hygiene.sh --apply
```

Debian/Ubuntu. Stops the operating system from restarting your node behind your
back, and stops a brute-force flood from permanently locking you out of your own
box.

An unplanned node restart is not a blip: a node restarted while far enough behind
discards state and takes a full bootstrap — ~1 GB on the wire, 1,534 retries and
3h45m blind, in the event we measured. It was caused by a routine glibc upgrade
about 30 seconds after the daily apt timer fired. No amount of care inside the
node can see that coming, because apt owns that restart.

The script covers four things, each with its rationale inline:

1. A `needrestart` exemption, so a library upgrade does not auto-restart the
   node. (Merged as a single key — assigning the whole hash would discard the
   distro defaults and let `needrestart` bounce dbus, which is worse than doing
   nothing.)
2. **Masking** — not disabling — the apt timers. A postinst re-enables a disabled
   timer on the next upgrade and you will never notice; a mask is a symlink to
   `/dev/null` that `enable` cannot overwrite.
3. Zeroing the `APT::Periodic` keys, so even a manually started `apt-daily` is a
   no-op.
4. Clearing systemd's start rate limit on `sshd`. An openssh upgrade restarting
   into a live brute-force flood trips the limiter; systemd then removes the
   unit's `RuntimeDirectory`, every later `sshd -t` exits 255, and
   `RestartPreventExitStatus=255` latches the unit permanently failed. Cost us a
   box for 13 hours.

## The trade-off, stated plainly

**You are now responsible for patching.** The exempted processes keep running
against upgraded-out library files until you deliberately restart them, and
automatic security updates are off. Audit what is owed a restart — restarting
nothing — with:

```bash
sudo needrestart -b -r l
```

and pick your own window. The point is that *you* choose the moment, not that
the box never gets patched.

The script restarts nothing, by design.
