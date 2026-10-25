#!/usr/bin/env python3
"""Tests for upgrade/: the fork-watch classifier against recorded observation
sequences, plus the helpers it depends on. No node, no network, no root.

    python3 -m unittest discover -s tests -v

Fixture format (tests/fixtures/fork-watch/*.json):
  {"description": ..., "params": {...classifier overrides...},
   "steps": [{"t": seconds from start, "abci": <hlup.py abci output>, "nrestarts": N,
              "child_starts": [seconds from start, ...], "expect": "CLASS",
              "expect_due": true|false (optional)}]}
Recorded fixtures (tests/fixtures/fork-watch/recorded/*.ndjson) are raw lines written
by `fork-watch.sh --record` on a real testnet node; their expected classes sit in the
matching *.expect.json.
"""

import glob
import importlib.util
import json
import os
import tempfile
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
spec = importlib.util.spec_from_file_location("hlup", os.path.join(HERE, "..", "upgrade", "lib", "hlup.py"))
hlup = importlib.util.module_from_spec(spec)
spec.loader.exec_module(hlup)

T0 = 1_800_000_000
FIX = os.path.join(HERE, "fixtures", "fork-watch")


def run_sequence(steps, params, start=T0):
    """Feed observations through the classifier like fork-watch.sh does, recording an
    auto-recover attempt whenever one is due (as the caller would)."""
    state, out = {}, []
    for s in steps:
        obs = {"ts": start + s["t"], "abci": s["abci"], "nrestarts": s.get("nrestarts"),
               "child_start_times": [start + c for c in s.get("child_starts", [])]}
        state, r = hlup.classify(state, obs, params)
        if r["auto_recover_due"]:
            state = hlup.mark_attempt(state, r["fork_key"], 0, obs["ts"])
        out.append(r)
    return out


class FixtureSequences(unittest.TestCase):
    def test_synthetic_fixtures(self):
        files = sorted(glob.glob(os.path.join(FIX, "*.json")))
        self.assertGreaterEqual(len(files), 7)
        for path in files:
            with open(path) as f:
                fx = json.load(f)
            with self.subTest(fixture=os.path.basename(path)):
                res = run_sequence(fx["steps"], fx.get("params", {}))
                for i, (s, r) in enumerate(zip(fx["steps"], res)):
                    self.assertEqual(r["class"], s["expect"],
                                     f"{os.path.basename(path)} step {i} t={s['t']}: {r['reason']}")
                    if "expect_due" in s:
                        self.assertEqual(r["auto_recover_due"], s["expect_due"],
                                         f"{os.path.basename(path)} step {i}: {r['auto_recover_note']}")

    def test_recorded_fixtures(self):
        for path in sorted(glob.glob(os.path.join(FIX, "recorded", "*.ndjson"))):
            exp_path = path[:-len(".ndjson")] + ".expect.json"
            with open(exp_path) as f:
                exp = json.load(f)
            with open(path) as f:
                obs = [json.loads(line) for line in f if line.strip()]
            with self.subTest(fixture=os.path.basename(path)):
                state, classes = {}, []
                for o in obs:
                    state, r = hlup.classify(state, o, exp.get("params", {}))
                    if r["auto_recover_due"]:
                        state = hlup.mark_attempt(state, r["fork_key"], 0, o["ts"])
                    classes.append(r["class"])
                # Recorded runs are long; compare the ordered list of distinct classes
                # (the transitions) plus the final class.
                trans = [c for i, c in enumerate(classes) if i == 0 or classes[i - 1] != c]
                self.assertEqual(trans, exp["transitions"], f"{os.path.basename(path)}")


class AutoRecoverPolicy(unittest.TestCase):
    def frozen_steps(self, minutes, sfh=1000, hv=4):
        steps = [{"t": 0, "abci": {"present": True, "height": sfh - 10, "hardfork_version": hv,
                                   "scheduled_freeze_height": sfh, "lag_s": 1, "age_s": 0}}]
        for i in range(1, minutes * 2 + 1):
            steps.append({"t": i * 30, "abci": {"present": True, "height": sfh, "hardfork_version": hv,
                                                "scheduled_freeze_height": sfh, "lag_s": i * 30, "age_s": i * 30}})
        return steps

    def test_once_per_fork(self):
        res = run_sequence(self.frozen_steps(60), {})
        due = [r for r in res if r["auto_recover_due"]]
        self.assertEqual(len(due), 1, "exactly one attempt per fork, however long it stays frozen")
        self.assertEqual(due[0]["fork_key"], "freeze:1000")
        self.assertIn("already attempted", res[-1]["auto_recover_note"])

    def test_waits_for_persistence(self):
        res = run_sequence(self.frozen_steps(60), {"frozen_min": 5, "auto_after_min": 10})
        first_frozen = next(r for r in res if r["class"] == "FROZEN_OLD_VERSION")
        first_due = next(r for r in res if r["auto_recover_due"])
        self.assertGreaterEqual(first_due["ts"] - first_frozen["ts"], 600)

    def test_backoff_across_forks(self):
        # Fork A frozen -> attempt; then a NEW freeze height shortly after: backoff holds it.
        steps = self.frozen_steps(20, sfh=1000)
        t = steps[-1]["t"]
        for i in range(1, 60):
            steps.append({"t": t + i * 30, "abci": {"present": True, "height": 2000, "hardfork_version": 4,
                                                    "scheduled_freeze_height": 2000, "lag_s": 5, "age_s": i * 30}})
        res = run_sequence(steps, {"auto_backoff_min": 60})
        due = [r for r in res if r["auto_recover_due"]]
        self.assertEqual(len(due), 1)
        self.assertTrue(any("backoff" in r["auto_recover_note"] for r in res if r["fork_key"] == "freeze:2000"))

    def test_behind_is_never_auto(self):
        steps = [{"t": i * 30, "abci": {"present": True, "height": 1000 + i, "hardfork_version": 1,
                                        "scheduled_freeze_height": 10000, "lag_s": 900}} for i in range(100)]
        res = run_sequence(steps, {})
        self.assertTrue(all(r["class"] == "BEHIND_AT_FREEZE" for r in res))
        self.assertFalse(any(r["auto_recover_due"] for r in res))


class Helpers(unittest.TestCase):
    def test_keccak_vectors(self):
        self.assertEqual(hlup.keccak256_bytes(b"").hex(),
                         "c5d2460186f7233c927e7db2dcc703c0e500b653ca82273b7bfad8045d85a470")
        self.assertEqual(hlup.keccak256_bytes(b"abc").hex(),
                         "4e03657aea45a94fc7d47ba826c8d667c0d1e6e33a64a036ec44f58fa12d6c45")
        # one byte short of a block: the 0x01 and 0x80 pad bytes collide into 0x81
        self.assertEqual(len(hlup.keccak256_bytes(b"a" * 135)), 32)

    def test_read_abci_lag(self):
        with tempfile.TemporaryDirectory() as d:
            p = os.path.join(d, "visor_abci_state.json")
            with open(p, "w") as f:
                json.dump({"hardfork_version": 1553, "initial_height": 747507700, "height": 748137301,
                           "scheduled_freeze_height": None,
                           "consensus_time": "2026-10-25T19:53:40.106145492",
                           "wall_clock_time": "2026-10-25T19:53:40.599979362"}, f)
            r = hlup.read_abci(p)
            self.assertTrue(r["present"])
            self.assertAlmostEqual(r["lag_s"], 0.494, places=3)
            self.assertIsNone(r["scheduled_freeze_height"])
            self.assertFalse(hlup.read_abci(os.path.join(d, "missing.json"))["present"])

    def test_textfile_refuses_device_paths(self):
        for bad in ("/dev/null", "/dev/stdout", "/proc/self/fd/1"):
            ok, _why = hlup.safe_target(bad)
            self.assertFalse(ok, bad)
        with tempfile.TemporaryDirectory() as d:
            p = os.path.join(d, "hl_upgrade.prom")
            r = {"class": "OK", "ts": T0, "class_since_s": 1, "height": 5, "hardfork_version": 2,
                 "scheduled_freeze_height": None, "lag_s": 0.3, "state_age_s": 0.1,
                 "restarts_in_window": 0, "auto_recover_attempts": 0}
            hlup.atomic_write(p, hlup.metrics_text(r))
            text = open(p).read()
            self.assertIn('hl_upgrade_class{class="OK"} 1', text)
            self.assertIn('hl_upgrade_class{class="RESTART_LOOP"} 0', text)
            self.assertEqual(os.listdir(d), ["hl_upgrade.prom"], "no temp file left behind")

    def test_child_starts_parses_names(self):
        with tempfile.TemporaryDirectory() as d:
            sub = os.path.join(d, "20261114", "1259")
            os.makedirs(sub)
            for n in ("2026-10-25T08:02:16Z", "2026-10-25T08:30:00Z", "not-a-start"):
                open(os.path.join(sub, n), "w").close()
            now = hlup.parse_node_time("2026-10-25T09:00:00")
            self.assertEqual(len(hlup.child_starts(d, since_s=7200, now=now)), 2)
            self.assertEqual(len(hlup.child_starts(d, since_s=1900, now=now)), 1)

    def test_names_never_literal_in_scripts(self):
        """The program names must be assembled at runtime in our own code, so that
        grepping a command line can never find them (see upgrade/README.md)."""
        root = os.path.join(HERE, "..", "upgrade")
        bad = ("hl-" "node", "hl-" "visor")
        for path in glob.glob(os.path.join(root, "*.sh")) + glob.glob(os.path.join(root, "lib", "*")):
            if not os.path.isfile(path):
                continue
            for n, line in enumerate(open(path), 1):
                code = line.split("#", 1)[0]
                if path.endswith(".py") and '"""' in line:
                    continue
                for b in bad:
                    self.assertNotIn(b, code, f"{os.path.basename(path)}:{n} has the literal {b!r} in code")


if __name__ == "__main__":
    unittest.main()
