#!/usr/bin/env python3
"""hlup.py: the shared helper behind upgrade/*.sh. Python 3.10+, standard library only.

The shell scripts do the parts that belong in shell (systemd, gpg, file moves);
this file does the parts that do not: JSON, hashing, HTTP, the fork-watch
classifier and the metrics/webhook writers.

Subcommands (all print JSON on stdout unless noted):

  abci PATH                         read visor_abci_state.json, add lag and age
  published --chain C               what the CDN currently publishes for chain C
  fetch --chain C --what node|visor --dest DIR [--pubkey FILE] [--state-hv N]
                                    download a release into DIR and verify it the
                                    way the supervisor does; exit 3 on any verify
                                    failure, 4 when the download itself failed
  hash --sha256|--keccak FILE|-     print one hash (hex); - reads the path from stdin
  install / move-aside              JSON spec on stdin (recover.sh uses these)
  child-starts DIR                  epoch times of child starts recorded by the
                                    supervisor under DIR (visor_child_stderr)
  classify --state F --obs JSON     fork-watch classifier: update state file F
  mark-attempt --state F --key K --rc N
                                    record an auto-recover attempt in F
  textfile --path P --result JSON   write node_exporter metrics atomically
  webhook --url U --result JSON     POST the classification (best effort)

Nothing here ever puts the node or supervisor program names on a command line:
they are assembled at runtime (NODE / VISOR below). See upgrade/README.md for why.
"""

import argparse
import datetime as _dt
import hashlib
import json
import os
import shutil
import struct
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.request

# Assembled, never literal in an argv we create: the node scans /proc at startup
# and panics if another process carries either name in its command line.
NODE = "hl-" + "node"
VISOR = "hl-" + "visor"

CDN = {
    "Mainnet": "https://binaries.hyperliquid.xyz/Mainnet",
    "Testnet": "https://binaries.hyperliquid-testnet.xyz/Testnet",
}
# Hyperliquid's release-signing key, as published in the hyperliquid-dex/node
# repository. The fingerprint is pinned: a key fetched from anywhere that does
# not carry exactly this fingerprint is refused, whatever it calls itself.
HL_KEY_URL = "https://raw.githubusercontent.com/hyperliquid-dex/node/main/pub_key.asc"
HL_KEY_FPR = "CF2C2EA3DC3E8F042A55FB6503254A9349F1820B"

UA = "upgrade-kit/1"


# ---------------------------------------------------------------------------
# small utilities
# ---------------------------------------------------------------------------

def out(obj):
    print(json.dumps(obj, sort_keys=True))


def parse_node_time(s):
    """The node writes naive UTC timestamps with nanoseconds; datetime takes micro."""
    if not s:
        return None
    s = s.rstrip("Z")
    if "." in s:
        head, frac = s.split(".", 1)
        s = head + "." + frac[:6]
    try:
        return _dt.datetime.fromisoformat(s).replace(tzinfo=_dt.timezone.utc).timestamp()
    except ValueError:
        return None


def read_abci(path, now=None):
    now = time.time() if now is None else now
    res = {"present": False, "path": path}
    try:
        st = os.stat(path)
        with open(path) as f:
            d = json.load(f)
    except (OSError, ValueError) as e:
        res["error"] = str(e)
        return res
    res["present"] = True
    res["age_s"] = round(now - st.st_mtime, 1)
    for k in ("hardfork_version", "height", "initial_height", "scheduled_freeze_height",
              "consensus_time", "wall_clock_time"):
        res[k] = d.get(k)
    ct, wt = parse_node_time(d.get("consensus_time")), parse_node_time(d.get("wall_clock_time"))
    # Both stamps are written by the node at the same instant, so their difference
    # is how far behind the node is against nothing but itself: no peer, no median.
    res["lag_s"] = round(wt - ct, 3) if ct is not None and wt is not None else None
    return res


def http_get(url, timeout=30, dest=None):
    req = urllib.request.Request(url, headers={"User-Agent": UA})
    with urllib.request.urlopen(req, timeout=timeout) as r:
        if dest is None:
            return r.read()
        with open(dest, "wb") as f:
            shutil.copyfileobj(r, f, 1 << 20)
        return None


def sha256_file(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for blk in iter(lambda: f.read(1 << 20), b""):
            h.update(blk)
    return h.hexdigest()


# ---------------------------------------------------------------------------
# keccak-256 (the hash the release metadata uses for the binary)
# ---------------------------------------------------------------------------
# The published node_metadata.json carries `bh`, the keccak-256 of the binary
# (checked against several releases: it is not sha256, sha3-256 or blake2).
# hashlib has sha3_256, whose padding differs, but no keccak-256, so this is a
# plain implementation. The permutation is generated unrolled at import time;
# that runs at roughly 1 MB/s, i.e. ~2 minutes for a node binary. If the
# optional pycryptodome package is installed we use it instead.

_M64 = (1 << 64) - 1
_RC = [0x0000000000000001, 0x0000000000008082, 0x800000000000808A, 0x8000000080008000,
       0x000000000000808B, 0x0000000080000001, 0x8000000080008081, 0x8000000000008009,
       0x000000000000008A, 0x0000000000000088, 0x0000000080008009, 0x000000008000000A,
       0x000000008000808B, 0x800000000000008B, 0x8000000000008089, 0x8000000000008003,
       0x8000000000008002, 0x8000000000000080, 0x000000000000800A, 0x800000008000000A,
       0x8000000080008081, 0x8000000000008080, 0x0000000080000001, 0x8000000080008008]
_ROT = [0, 1, 62, 28, 27, 36, 44, 6, 55, 20, 3, 10, 43, 25, 39, 41, 45, 15, 21, 8, 18, 2, 61, 56, 14]


def _gen_keccak_f():
    L = ["def _kf(s):", "    " + ", ".join(f"a{i}" for i in range(25)) + " = s", "    for rc in _RC:"]
    for x in range(5):
        L.append(f"        c{x} = a{x} ^ a{x+5} ^ a{x+10} ^ a{x+15} ^ a{x+20}")
    for x in range(5):
        L.append(f"        d{x} = c{(x-1) % 5} ^ (((c{(x+1) % 5} << 1) | (c{(x+1) % 5} >> 63)) & _M64)")
    for x in range(5):
        for y in range(5):
            i, r, j = x + 5 * y, _ROT[x + 5 * y], y + 5 * ((2 * x + 3 * y) % 5)
            if r:
                L.append(f"        t = a{i} ^ d{x}; b{j} = ((t << {r}) | (t >> {64 - r})) & _M64")
            else:
                L.append(f"        b{j} = a{i} ^ d{x}")
    for y in range(5):
        for x in range(5):
            i = x + 5 * y
            L.append(f"        a{i} = b{i} ^ ((~b{(x+1) % 5 + 5*y}) & b{(x+2) % 5 + 5*y})")
    L.append("        a0 ^= rc")
    L.append("    return [" + ", ".join(f"a{i}" for i in range(25)) + "]")
    ns = {"_RC": _RC, "_M64": _M64}
    exec("\n".join(L), ns)
    return ns["_kf"]


_kf = _gen_keccak_f()
_U17 = struct.Struct("<17Q").unpack_from


def keccak256_bytes(data):
    rate = 136
    padlen = rate - (len(data) % rate)
    data = data + (b"\x81" if padlen == 1 else b"\x01" + b"\x00" * (padlen - 2) + b"\x80")
    s = [0] * 25
    mv = memoryview(data)
    for off in range(0, len(data), rate):
        w = _U17(mv, off)
        for i in range(17):
            s[i] ^= w[i]
        s = _kf(s)
    return b"".join(s[i].to_bytes(8, "little") for i in range(4))


def keccak256_file(path):
    try:
        from Crypto.Hash import keccak as _k  # optional fast path (pycryptodome)
        h = _k.new(digest_bits=256)
        with open(path, "rb") as f:
            for blk in iter(lambda: f.read(1 << 20), b""):
                h.update(blk)
        return h.hexdigest()
    except ImportError:
        with open(path, "rb") as f:
            return keccak256_bytes(f.read()).hex()


# ---------------------------------------------------------------------------
# CDN: what is published, and verify-as-the-supervisor-does
# ---------------------------------------------------------------------------
# What the current supervisor does when it upgrades the node (from its own
# strings and from watching it work):
#   1. GET {cdn}/active                      -> the current release index
#   2. GET {cdn}/{index}/node_metadata.json  -> {hvs:{hyperliquid_index, c:{NodeMetadata:{hv, bh}}}, a:[sigs], b:[sigs]}
#   3. GET {cdn}/{index}/<node> and .asc
#   4. checks: metadata index == active index, gpg signature good, binary hash == bh,
#      signature quorum on the metadata, and that the state's hardfork version is
#      not newer than the binary's (hv).
# We reproduce 1-4 except the metadata signature quorum: those are secp256k1
# signatures over a message whose exact encoding Hyperliquid has not published,
# so we cannot recompute it honestly. What we do check binds the same things:
# the gpg signature proves Hyperliquid's release key signed THIS binary, and
# keccak(binary) == bh proves the metadata (hv, index) describes this binary.
# The supervisor re-runs its own full check the next time it downloads.
#
# The supervisor itself is published unversioned at {cdn}/<visor> with a .asc
# beside it; gpg is the whole check there.
#
# The OLD verification manifest (signature_quorum.json next to each release) is
# no longer published. A supervisor build that still looks for it cannot verify
# any new release, and keeps running the old node, which then stops at the next
# fork's freeze height. That is the most likely way an outdated supervisor fails.


def gpg_verify(bin_path, asc_path, pubkey_path=None, timeout=60):
    """Verify against Hyperliquid's key in a throwaway keyring. Returns (ok, detail)."""
    if not shutil.which("gpg"):
        return False, "gpg not installed (the supervisor needs it too)"
    gh = tempfile.mkdtemp(prefix="hlup-gnupg-")
    try:
        os.chmod(gh, 0o700)
        if pubkey_path is None:
            pubkey_path = os.path.join(gh, "pub_key.asc")
            try:
                http_get(HL_KEY_URL, timeout=30, dest=pubkey_path)
            except Exception as e:  # noqa: BLE001
                return False, f"could not fetch Hyperliquid's public key: {e}"
        env = dict(os.environ, GNUPGHOME=gh)
        r = subprocess.run(["gpg", "--batch", "--quiet", "--import", pubkey_path],
                           capture_output=True, text=True, env=env, timeout=timeout)
        if r.returncode != 0:
            return False, "key import failed: " + r.stderr.strip()[:200]
        r = subprocess.run(["gpg", "--batch", "--with-colons", "--fingerprint"],
                           capture_output=True, text=True, env=env, timeout=timeout)
        fprs = [ln.split(":")[9] for ln in r.stdout.splitlines() if ln.startswith("fpr:")]
        if HL_KEY_FPR not in fprs:
            return False, f"key fingerprint mismatch: got {fprs}, want {HL_KEY_FPR}"
        # --status-fd gives machine-readable results; we require VALIDSIG with the
        # pinned primary fingerprint, not merely "exit 0".
        r = subprocess.run(["gpg", "--batch", "--status-fd", "1", "--verify", asc_path, bin_path],
                           capture_output=True, text=True, env=env, timeout=timeout)
        valid = [ln for ln in r.stdout.splitlines() if ln.startswith("[GNUPG:] VALIDSIG")]
        if r.returncode == 0 and valid and HL_KEY_FPR in valid[0].split():
            return True, "good signature from " + HL_KEY_FPR
        bad = [ln for ln in r.stdout.splitlines() if "BADSIG" in ln or "ERRSIG" in ln]
        return False, "signature did not verify: " + (bad[0] if bad else r.stderr.strip()[:200])
    finally:
        shutil.rmtree(gh, ignore_errors=True)


def published(chain, timeout=30):
    base = CDN[chain]
    res = {"chain": chain, "base": base}
    idx = int(http_get(f"{base}/active", timeout).decode().strip())
    res["index"] = idx
    meta = json.loads(http_get(f"{base}/{idx}/node_metadata.json", timeout))
    md = meta["hvs"]["c"]["NodeMetadata"]
    res["metadata_index"] = meta["hvs"]["hyperliquid_index"]
    res["hv"] = md["hv"]
    res["bh"] = md["bh"].lower().removeprefix("0x")
    res["metadata"] = meta
    return res


def fetch(chain, what, dest, pubkey=None, state_hv=None, timeout=300, skip_keccak=False):
    """Download one artifact into dest and verify it. Returns (exit_code, result)."""
    base = CDN[chain]
    os.makedirs(dest, exist_ok=True)
    res = {"chain": chain, "what": what, "dest": dest, "ok": False}
    try:
        if what == "node":
            pub = published(chain)
            idx = pub["index"]
            res.update(index=idx, hv=pub["hv"], bh=pub["bh"])
            url = f"{base}/{idx}/{NODE}"
            # Staged under a neutral name: gpg gets the path on its command line,
            # and the real name must never appear in an argv (module docstring).
            binp = os.path.join(dest, "node.bin")
            metap = os.path.join(dest, "node_metadata.json")
            with open(metap, "w") as f:
                json.dump(pub["metadata"], f, indent=4)
            res["metadata_path"] = metap
        else:
            url = f"{base}/{VISOR}"
            binp = os.path.join(dest, "visor.bin")
        http_get(url, timeout, dest=binp)
        http_get(url + ".asc", timeout, dest=binp + ".asc")
    except Exception as e:  # noqa: BLE001
        res["reason"] = f"download failed: {e}"
        return 4, res
    res["bin_path"] = binp
    res["sha256"] = sha256_file(binp)
    ok, detail = gpg_verify(binp, binp + ".asc", pubkey)
    res["gpg"] = detail
    if not ok:
        res["reason"] = "gpg: " + detail
        return 3, res
    if what == "node":
        if res["index"] != pub["metadata_index"]:
            res["reason"] = f"metadata index {pub['metadata_index']} != active index {res['index']}"
            return 3, res
        kh = None if skip_keccak else keccak256_file(binp)
        res["keccak"] = kh if kh else "skipped"
        if kh is not None and kh != res["bh"]:
            res["reason"] = f"binary hash mismatch: keccak {kh} != metadata bh {res['bh']}"
            return 3, res
        if state_hv is not None and int(state_hv) > int(res["hv"]):
            res["reason"] = f"state hardfork version {state_hv} is newer than binary hardfork version {res['hv']}"
            return 3, res
    os.chmod(binp, 0o755)
    res["ok"] = True
    res["reason"] = "verified"
    return 0, res


# ---------------------------------------------------------------------------
# supervisor bookkeeping
# ---------------------------------------------------------------------------

def child_starts(stderr_dir, since_s=7200, now=None):
    """The supervisor opens one stderr file per child start, named by its start time
    (visor_child_stderr/<day>/<index>/<YYYY-MM-DDTHH:MM:SSZ>). Counting the names is a
    restart counter that survives the supervisor's own restarts and needs no journal."""
    now = time.time() if now is None else now
    times = []
    if not os.path.isdir(stderr_dir):
        return times
    for root, _dirs, files in os.walk(stderr_dir):
        for fn in files:
            try:
                t = _dt.datetime.strptime(fn, "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=_dt.timezone.utc).timestamp()
            except ValueError:
                continue
            if now - t <= since_s:
                times.append(int(t))
    return sorted(times)


# ---------------------------------------------------------------------------
# the fork-watch classifier (pure: state + observation -> state + result)
# ---------------------------------------------------------------------------

CLASSES = ["OK", "FORK_PENDING", "BEHIND_AT_FREEZE", "FROZEN_OLD_VERSION", "RESTART_LOOP",
           "RECOVERING", "RECOVERED", "UNKNOWN"]
BAD = {"BEHIND_AT_FREEZE", "FROZEN_OLD_VERSION", "RESTART_LOOP"}
AUTO_CLASSES = {"FROZEN_OLD_VERSION", "RESTART_LOOP"}

DEFAULTS = {
    # Measured: a node more than ~1,600 blocks below the freeze height when the new
    # release appears is swapped anyway by the supervisor's 60 s grace timer, loads
    # its pre-fork state and panics on the first post-fork block.
    "behind_blocks": 1600,
    # A healthy swap takes ~1-2 minutes from the freeze; 5 minutes at the freeze
    # height on the old version is not a slow swap, it is no swap.
    "frozen_min": 5.0,
    # One restart is what a fork swap looks like. Three inside 30 minutes is a loop.
    "loop_restarts": 3,
    "loop_window_min": 30.0,
    # How long after a fork event restarts are attributed to the fork.
    "fork_context_h": 24.0,
    # Lag under which a node counts as following the chain again.
    "lag_ok_s": 30.0,
    "healthy_samples": 3,
    "recovered_hold_min": 30.0,
    # Auto-recover: how long a recoverable class must persist, and the minimum gap
    # between two attempts (attempts are also capped at one per fork).
    "auto_after_min": 10.0,
    "auto_backoff_min": 60.0,
}


def classify(state, obs, params=None):
    p = dict(DEFAULTS)
    p.update(params or {})
    st = json.loads(json.dumps(state or {}))  # deep copy, JSON-shaped
    now = obs["ts"]
    ab = obs.get("abci") or {}
    hist = st.setdefault("hist", [])
    fork = st.setdefault("fork", {})
    auto = st.setdefault("auto", {"attempts": {}, "last_ts": None})
    events = st.setdefault("restart_events", [])

    # --- restart events: supervisor restarts (NRestarts deltas) + child starts ---
    nr = obs.get("nrestarts")
    if nr is not None:
        prev = st.get("nrestarts")
        if prev is not None and nr > prev:
            events.extend([now] * min(nr - prev, 50))
        st["nrestarts"] = nr
    for t in obs.get("child_start_times") or []:
        if t not in st.setdefault("child_seen", []):
            st["child_seen"].append(t)
            events.append(t)
    horizon = now - max(p["loop_window_min"] * 60, 7200)
    st["child_seen"] = [t for t in st.get("child_seen", []) if t >= horizon]
    events[:] = sorted(t for t in events if t >= horizon)
    window = [t for t in events if t >= now - p["loop_window_min"] * 60]

    present = bool(ab.get("present"))
    hv, h = ab.get("hardfork_version"), ab.get("height")
    sfh = ab.get("scheduled_freeze_height")
    lag = ab.get("lag_s")

    # --- fork bookkeeping ---
    last = hist[-1] if hist else None
    if present:
        if sfh is not None and fork.get("freeze_height") != sfh:
            fork.clear()
            fork.update(freeze_height=sfh, hv_before=hv, seen_ts=now)
        if last and last.get("hv") is not None and hv is not None and hv != last["hv"]:
            fork["hv_change_ts"] = now
            fork["hv_after"] = hv
            fork.setdefault("hv_before", last["hv"])
        if fork.get("freeze_height") is not None and h is not None and h >= fork["freeze_height"] \
                and hv == fork.get("hv_before") and "reached_ts" not in fork:
            fork["reached_ts"] = now
    fork_ts = max([t for t in (fork.get("seen_ts"), fork.get("hv_change_ts")) if t] or [0])
    fork_context = sfh is not None or (now - fork_ts) <= p["fork_context_h"] * 3600
    advancing = bool(last and present and h is not None and last.get("h") is not None and h > last["h"])
    new_events = any(t > (last["ts"] if last else now - 60) for t in events)
    healthy = bool(present and lag is not None and lag <= p["lag_ok_s"] and advancing and not new_events)
    st["healthy_streak"] = st.get("healthy_streak", 0) + 1 if healthy else 0
    # A looping node can look healthy for one sample between restarts; three in a row
    # (90 s at the 30 s cadence) with no new restart is not a loop any more.
    steady = st["healthy_streak"] >= p["healthy_samples"]

    reason = ""
    cls = "OK"
    # Restarts first: a node that dies during startup (e.g. an old binary refusing a
    # newer state) never writes visor_abci_state.json, and must still read as a loop.
    if len(window) >= p["loop_restarts"] and not steady:
        cls = "RESTART_LOOP"
        reason = (f"{len(window)} restarts in {p['loop_window_min']:g} min"
                  + (" after a fork" if fork_context else " (no fork in context)")
                  + ("" if present else "; the node never got far enough to write its state file"))
    elif not present:
        cls, reason = "UNKNOWN", "no readable visor_abci_state.json: " + str(ab.get("error", "missing"))
    elif fork.get("reached_ts") and hv == fork.get("hv_before") and h is not None \
            and h >= fork["freeze_height"] and now - fork["reached_ts"] >= p["frozen_min"] * 60:
        cls = "FROZEN_OLD_VERSION"
        reason = (f"at freeze height {fork['freeze_height']} on hardfork {hv} for "
                  f"{(now - fork['reached_ts']) / 60:.1f} min; the new release was not started")
    elif sfh is not None and h is not None and h < sfh and sfh - h > p["behind_blocks"] \
            and (lag is None or lag > p["lag_ok_s"]):
        # Both halves: far below the freeze in blocks AND behind in time. A synced
        # node can see a freeze scheduled a couple of thousand blocks ahead; it is
        # the lagging one that cannot reach it inside the supervisor's 60 s grace.
        cls = "BEHIND_AT_FREEZE"
        reason = (f"{sfh - h} blocks below freeze height {sfh} and {lag if lag is None else round(lag)} s behind "
                  f"(brick risk above {p['behind_blocks']} blocks)")
    elif sfh is not None:
        cls = "FORK_PENDING"
        reason = f"freeze scheduled at {sfh}" + (f", {sfh - h} blocks to go" if h is not None and h < sfh else ", at the freeze height")
    else:
        bad_hv = st.get("bad_hv")
        if st.get("bad_since"):
            healed = (bad_hv is None or (hv is not None and hv > bad_hv) or st.get("bad_class") != "FROZEN_OLD_VERSION")
            if healed and steady:
                cls = "RECOVERED"
                reason = f"following the chain again on hardfork {hv} (lag {lag:.1f} s)"
                st["recovered_ts"] = now
                st.pop("bad_since", None)
            else:
                cls = "RECOVERING"
                reason = f"was {st.get('bad_class')}; hardfork {hv}, lag {lag if lag is None else round(lag, 1)} s"
        elif st.get("recovered_ts") and now - st["recovered_ts"] < p["recovered_hold_min"] * 60:
            cls = "RECOVERED"
            reason = f"recovered {(now - st['recovered_ts']) / 60:.0f} min ago"
        else:
            reason = "no fork scheduled"
            if lag is not None and lag > p["lag_ok_s"]:
                reason += f"; lag {lag:.0f} s"

    if cls in BAD:
        if not st.get("bad_since"):
            st["bad_since"] = now
            st["bad_hv"] = hv if cls == "FROZEN_OLD_VERSION" else fork.get("hv_before", hv)
        st["bad_class"] = cls
        st.pop("recovered_ts", None)

    if cls != st.get("class"):
        st["prev_class"] = st.get("class")
        st["class"] = cls
        st["class_since"] = now
    since = now - st.get("class_since", now)

    # --- auto-recover decision (the caller acts; this only decides) ---
    fork_key = (f"freeze:{fork['freeze_height']}" if fork.get("freeze_height") is not None
                else f"hv:{hv}")
    due, why = False, ""
    if cls in AUTO_CLASSES:
        if since < p["auto_after_min"] * 60:
            why = f"waiting: {cls} for {since / 60:.1f} of {p['auto_after_min']:g} min"
        elif fork_key in auto["attempts"]:
            why = f"already attempted for {fork_key}"
        elif auto.get("last_ts") and now - auto["last_ts"] < p["auto_backoff_min"] * 60:
            why = "backoff after the previous attempt"
        else:
            due, why = True, f"{cls} persisted {since / 60:.1f} min"

    hist.append({"ts": now, "h": h, "hv": hv, "sfh": sfh, "lag": lag, "cls": cls})
    del hist[:-120]

    result = {
        "ts": now, "class": cls, "prev_class": st.get("prev_class"), "class_since_s": round(since, 1),
        "changed": since == 0, "reason": reason, "height": h, "hardfork_version": hv,
        "scheduled_freeze_height": sfh, "lag_s": lag, "state_age_s": ab.get("age_s"),
        "restarts_in_window": len(window), "fork_context": bool(fork_context),
        "fork_key": fork_key, "auto_recover_due": due, "auto_recover_note": why,
        "auto_recover_attempts": len(auto["attempts"]),
    }
    return st, result


def mark_attempt(state, key, rc, now):
    auto = state.setdefault("auto", {"attempts": {}, "last_ts": None})
    auto["attempts"][key] = {"ts": now, "rc": rc}
    auto["last_ts"] = now
    return state


# ---------------------------------------------------------------------------
# install / move-aside (paths come in as JSON on stdin, never on argv)
# ---------------------------------------------------------------------------

def _chown(path, owner):
    if owner and os.geteuid() == 0:
        shutil.chown(path, owner, owner)


def install(spec):
    """spec: {src, dst, backup_dir, owner, meta_src?, meta_dst?}. Back the old binary
    up, then rename the verified one over it. rename() is atomic and does not hit
    ETXTBSY: a running process keeps its old inode until it is restarted."""
    src, dst = spec["src"], spec["dst"]
    res = {"dst": dst}
    if os.path.exists(dst):
        os.makedirs(spec["backup_dir"], exist_ok=True)
        bk = os.path.join(spec["backup_dir"], os.path.basename(dst))
        shutil.copy2(dst, bk)
        res["backup"] = bk
    tmp = dst + ".hlup-new"
    shutil.copy2(src, tmp)
    os.chmod(tmp, 0o755)
    _chown(tmp, spec.get("owner"))
    os.replace(tmp, dst)
    res["sha256"] = sha256_file(dst)
    if spec.get("meta_src") and spec.get("meta_dst"):
        mtmp = spec["meta_dst"] + ".hlup-new"
        shutil.copy2(spec["meta_src"], mtmp)
        _chown(mtmp, spec.get("owner"))
        os.replace(mtmp, spec["meta_dst"])
        res["metadata"] = spec["meta_dst"]
    return res


# What the node loads as its local state. Moving these aside (a rename on the same
# filesystem: instant, reversible) makes the next start take a fresh bootstrap.
# Verified on a live testnet node: with these gone the node logs "using local
# AbciState: missing" and bootstraps; it does NOT fall back to the copies under
# data/periodic_abci_states. node_metadata.json and node_artifact_2.json stay.
# visor_abci_state.json moves too: left behind, it would keep describing the OLD
# state while the bootstrap runs, and a second recover.sh would act on it.
STATE_ENTRIES = ["abci_state.rmp", "evm_db_hub_fast", "evm_db_hub_slow", "freeze_abci_height",
                 "visor_abci_state.json"]


def move_aside(spec):
    """spec: {data_dir, to_dir}. Returns what moved and its size."""
    os.makedirs(spec["to_dir"], exist_ok=True)
    moved, size, seen = [], 0, set()
    for name in STATE_ENTRIES:
        p = os.path.join(spec["data_dir"], name)
        if not os.path.lexists(p):
            continue
        # Disk actually used, like du: allocated blocks, each hard-linked inode once
        # (the state file is a hard link into periodic_abci_states, rocksdb links too).
        for root, _d, files in os.walk(p) if os.path.isdir(p) else [("", [], [p])]:
            for fn in files:
                try:
                    st = os.lstat(os.path.join(root, fn) if root else fn)
                except OSError:
                    continue
                if (st.st_dev, st.st_ino) not in seen:
                    seen.add((st.st_dev, st.st_ino))
                    size += st.st_blocks * 512
        os.replace(p, os.path.join(spec["to_dir"], name))
        moved.append(name)
    return {"moved": moved, "to": spec["to_dir"], "bytes": size}


# ---------------------------------------------------------------------------
# outputs
# ---------------------------------------------------------------------------

def safe_target(path):
    """Refuse anything that is not (or would not become) a regular file. Writers here
    rename a temp file over the target; renamed over /dev/null, that replaces a device
    node every process on the box relies on."""
    real = os.path.realpath(path)
    if real.startswith(("/dev/", "/proc/", "/sys/", "/run/udev")):
        return False, f"refusing to write metrics to {real}"
    if os.path.lexists(path) and not os.path.isfile(real):
        return False, f"refusing: {path} exists and is not a regular file"
    if not os.path.isdir(os.path.dirname(real) or "."):
        return False, f"directory for {path} does not exist"
    return True, real


def atomic_write(path, text):
    ok, real = safe_target(path)
    if not ok:
        raise SystemExit(real)
    d = os.path.dirname(real) or "."
    fd, tmp = tempfile.mkstemp(prefix=".hlup-", dir=d)
    try:
        with os.fdopen(fd, "w") as f:
            f.write(text)
        os.chmod(tmp, 0o644)
        os.replace(tmp, real)
    except BaseException:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        raise


def metrics_text(r):
    def g(v):
        return "NaN" if v is None else str(v)
    L = ["# HELP hl_upgrade_class 1 for the current fork-watch classification.",
         "# TYPE hl_upgrade_class gauge"]
    for c in CLASSES:
        L.append(f'hl_upgrade_class{{class="{c}"}} {1 if r["class"] == c else 0}')
    rows = [
        ("hl_upgrade_class_since_seconds", r.get("class_since_s"), "Seconds in the current classification."),
        ("hl_upgrade_height", r.get("height"), "Height from visor_abci_state.json."),
        ("hl_upgrade_hardfork_version", r.get("hardfork_version"), "Hardfork version of the local state."),
        ("hl_upgrade_scheduled_freeze_height", r.get("scheduled_freeze_height") or 0, "Scheduled freeze height, 0 when none."),
        ("hl_upgrade_lag_seconds", r.get("lag_s"), "wall_clock_time - consensus_time, written by the node."),
        ("hl_upgrade_state_age_seconds", r.get("state_age_s"), "Age of visor_abci_state.json."),
        ("hl_upgrade_restarts_in_window", r.get("restarts_in_window"), "Supervisor restarts + child starts in the loop window."),
        ("hl_upgrade_auto_recover_attempts", r.get("auto_recover_attempts"), "Auto-recover attempts recorded in the state file."),
        ("hl_upgrade_last_run_timestamp_seconds", int(r["ts"]), "When fork-watch last ran."),
    ]
    for name, v, help_ in rows:
        L += [f"# HELP {name} {help_}", f"# TYPE {name} gauge", f"{name} {g(v)}"]
    return "\n".join(L) + "\n"


def webhook(url, r, timeout=10):
    body = dict(r)
    body["host"] = os.uname().nodename
    req = urllib.request.Request(url, data=json.dumps(body).encode(), method="POST",
                                 headers={"Content-Type": "application/json", "User-Agent": UA})
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            return resp.status
    except (urllib.error.URLError, OSError) as e:
        return f"error: {e}"


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------

def load_json_arg(s):
    if s == "-":
        return json.load(sys.stdin)
    if os.path.isfile(s):
        with open(s) as f:
            return json.load(f)
    return json.loads(s)


def main(argv=None):
    ap = argparse.ArgumentParser(prog="hlup.py")
    sp = ap.add_subparsers(dest="cmd", required=True)
    a = sp.add_parser("abci"); a.add_argument("path")
    a = sp.add_parser("published"); a.add_argument("--chain", required=True, choices=list(CDN))
    a = sp.add_parser("fetch")
    a.add_argument("--chain", required=True, choices=list(CDN))
    a.add_argument("--what", required=True, choices=["node", "visor"])
    a.add_argument("--dest", required=True)
    a.add_argument("--pubkey")
    a.add_argument("--state-hv", type=int)
    a.add_argument("--skip-keccak", action="store_true",
                   help="preflight only: gpg + index suffice to compare; recover always hashes")
    a = sp.add_parser("hash"); g = a.add_mutually_exclusive_group(required=True)
    g.add_argument("--sha256", action="store_true"); g.add_argument("--keccak", action="store_true")
    a.add_argument("path", help="a path, or - to read the path from stdin (keeps it off argv)")
    sp.add_parser("install", help="JSON spec on stdin")
    sp.add_parser("move-aside", help="JSON spec on stdin")
    a = sp.add_parser("child-starts"); a.add_argument("dir"); a.add_argument("--since-s", type=int, default=7200)
    a = sp.add_parser("classify")
    a.add_argument("--state", required=True); a.add_argument("--obs", required=True)
    a.add_argument("--params", default="{}")
    a = sp.add_parser("mark-attempt")
    a.add_argument("--state", required=True); a.add_argument("--key", required=True)
    a.add_argument("--rc", type=int, required=True)
    a = sp.add_parser("textfile"); a.add_argument("--path", required=True); a.add_argument("--result", required=True)
    a = sp.add_parser("webhook"); a.add_argument("--url", required=True); a.add_argument("--result", required=True)
    args = ap.parse_args(argv)

    if args.cmd == "abci":
        out(read_abci(args.path))
    elif args.cmd == "published":
        try:
            r = published(args.chain)
        except Exception as e:  # noqa: BLE001
            out({"ok": False, "reason": str(e)}); return 4
        r.pop("metadata", None); out(r)
    elif args.cmd == "fetch":
        rc, r = fetch(args.chain, args.what, args.dest, args.pubkey, args.state_hv,
                      skip_keccak=args.skip_keccak)
        out(r); return rc
    elif args.cmd == "hash":
        path = sys.stdin.readline().rstrip("\n") if args.path == "-" else args.path
        if not os.path.isfile(path):
            print(""); return 1
        print(sha256_file(path) if args.sha256 else keccak256_file(path))
    elif args.cmd == "install":
        out(install(json.load(sys.stdin)))
    elif args.cmd == "move-aside":
        out(move_aside(json.load(sys.stdin)))
    elif args.cmd == "child-starts":
        out(child_starts(args.dir, args.since_s))
    elif args.cmd == "classify":
        try:
            with open(args.state) as f:
                state = json.load(f)
        except (OSError, ValueError):
            state = {}
        st, r = classify(state, load_json_arg(args.obs), load_json_arg(args.params))
        atomic_write(args.state, json.dumps(st))
        out(r)
    elif args.cmd == "mark-attempt":
        try:
            with open(args.state) as f:
                state = json.load(f)
        except (OSError, ValueError):
            state = {}
        atomic_write(args.state, json.dumps(mark_attempt(state, args.key, args.rc, time.time())))
    elif args.cmd == "textfile":
        atomic_write(args.path, metrics_text(load_json_arg(args.result)))
    elif args.cmd == "webhook":
        out({"status": webhook(args.url, load_json_arg(args.result))})
    return 0


if __name__ == "__main__":
    sys.exit(main())
