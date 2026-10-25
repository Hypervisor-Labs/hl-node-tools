#!/usr/bin/env bash
#
# recover.sh: bring a node that missed (or is about to miss) a hardfork onto the
# current release, using only binaries Hyperliquid published and signed.
#
#   sudo ./upgrade/recover.sh                 dry run: verify, then print the plan
#   sudo ./upgrade/recover.sh --apply         do it
#   sudo ./upgrade/recover.sh --apply --reset-state
#                                             also move a pre-fork state aside so
#                                             the node takes a fresh bootstrap
#
# Options: --unit NAME --home DIR --chain mainnet|testnet --pubkey FILE
#          --node-bin PATH --visor-bin PATH   binaries under non-default names
#          --yes (no prompt with --apply)  --no-restart  --wait-s N (default 180)
#
# Steps:
#   1. fetch the current node release (and the supervisor, if the local one is
#      stale) from Hyperliquid's CDN into a staging dir next to the node;
#   2. verify it the way the supervisor does (gpg with Hyperliquid's pinned key,
#      metadata index, keccak-256 of the binary == the metadata's hash, hardfork
#      version not older than the state's). ANY failure: refuse, change nothing;
#   3. install into the supervisor's layout ($HOME/<node>, $HOME/<supervisor>,
#      $HOME/hl/hyperliquid_data/node_metadata.json), old binaries backed up;
#   4. restart the unit through systemd (never pkill: see README);
#   5. if the local state is pre-fork and NOT at the freeze height, it is unusable
#      by the new binary: explain, or with --reset-state move it aside.
#
# Safe to run twice: when the installed binaries already match the verified
# release, the running process is that binary and the state is usable, it
# changes nothing and restarts nothing.
#
# Exit: 0 done or nothing to do, 10 dry run with actions pending,
#       3 verification refused, 4 download failed, 5 other error.

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
. "$HERE/lib/common.sh"
argv_guard

APPLY=0; YES=0; RESET=0; RESTART=1; PUBKEY=""; WAIT_S=180
UNIT="${UNIT:-}"; HOME_DIR="${HOME_DIR:-}"; CHAIN="${CHAIN:-}"
export NODE_BIN_OPT VISOR_BIN_OPT   # read by lib/common.sh
while [ $# -gt 0 ]; do
  case "$1" in
    --apply) APPLY=1 ;;
    --yes) YES=1 ;;
    --reset-state) RESET=1 ;;
    --no-restart) RESTART=0 ;;
    --unit) UNIT="$2"; shift ;;
    --home) HOME_DIR="$2"; shift ;;
    --chain) CHAIN="$2"; shift ;;
    --node-bin) NODE_BIN_OPT="$2"; shift ;;
    --visor-bin) VISOR_BIN_OPT="$2"; shift ;;
    --pubkey) PUBKEY="$2"; shift ;;
    --wait-s) WAIT_S="$2"; shift ;;
    -h|--help) sed -n '2,/^[^#]/{/^#/p}' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 64 ;;
  esac
  shift
done

say()  { printf '%s\n' "$*"; }
step() { printf '\n== %s ==\n' "$*"; }
die()  { printf 'recover: %s\n' "$2" >&2; exit "$1"; }
jget() { python3 -I -c 'import json,sys; v=json.load(sys.stdin).get(sys.argv[1]); print("" if v is None else v)' "$1"; }

if [ "$APPLY" = 1 ] && [ "$(id -u)" -ne 0 ]; then
  die 5 "--apply must run as root (it replaces binaries and restarts a unit). Dry run works as any user."
fi

discover
[ -n "${HOME_DIR:-}" ] || die 5 "cannot find the node's home directory; pass --home"
[ -n "${UNIT:-}" ] || die 5 "cannot find the node's systemd unit; pass --unit"
[ -n "${CHAIN:-}" ] || die 5 "cannot detect the chain; pass --chain mainnet|testnet"
say "unit=$UNIT home=$HOME_DIR chain=$CHAIN supervision=$SUPERVISION user=$UNIT_USER"
[ "$SUPERVISION" = none ] && die 5 "unit $UNIT runs neither the supervisor nor the node"

KIT="$HOME_DIR/.upgrade-kit"
STAGE="$KIT/stage"
mkdir -p "$KIT" 2>/dev/null || { [ "$APPLY" = 0 ] && KIT="$(mktemp -d -t hlup-recover.XXXXXX)" && STAGE="$KIT/stage"; }
# One recover at a time (fork-watch's auto mode and an operator could collide).
exec 8>"$KIT/recover.lock"
flock -n 8 || die 5 "another recover.sh holds $KIT/recover.lock"
rm -rf "$STAGE"; mkdir -p "$STAGE"
trap 'rm -rf "$STAGE"' EXIT

# --- state first: the hardfork version the release must not be older than ---
abci="$(hlup abci "$DATA_DIR/visor_abci_state.json")"
S_HV="$(printf '%s' "$abci" | jget hardfork_version)"
S_H="$(printf '%s' "$abci" | jget height)"
S_SFH="$(printf '%s' "$abci" | jget scheduled_freeze_height)"
FREEZE_FILE=""
[ -r "$DATA_DIR/freeze_abci_height" ] && FREEZE_FILE="$(tr -dc 0-9 <"$DATA_DIR/freeze_abci_height")"
say "local state: hardfork=${S_HV:-?} height=${S_H:-?} scheduled_freeze=${S_SFH:-none} freeze_file=${FREEZE_FILE:-none}"

# --- 1+2. fetch and verify ---------------------------------------------------
step "1-2. fetch + verify the current release"
PK=(); [ -n "$PUBKEY" ] && PK=(--pubkey "$PUBKEY")
SH=(); [ -n "$S_HV" ] && SH=(--state-hv "$S_HV")
set +e
nres="$(hlup fetch --chain "$CHAIN" --what node --dest "$STAGE/node" "${PK[@]}" "${SH[@]}")"; nrc=$?
set -e
say "node: $(printf '%s' "$nres" | python3 -I -c 'import json,sys; d=json.load(sys.stdin); print("index=%s hardfork=%s sha256=%s keccak=%s gpg=%s -> %s" % (d.get("index"), d.get("hv"), str(d.get("sha256"))[:12], str(d.get("keccak"))[:12], d.get("gpg"), d.get("reason")))')"
[ "$nrc" -eq 3 ] && die 3 "REFUSING: the published node release did not verify. Nothing was changed."
[ "$nrc" -ne 0 ] && die 4 "could not download the release (CDN unreachable?). Nothing was changed."
P_IDX="$(printf '%s' "$nres" | jget index)"
P_HV="$(printf '%s' "$nres" | jget hv)"
P_SHA="$(printf '%s' "$nres" | jget sha256)"

NEED_NODE=0; NEED_VISOR=0; NEED_RESTART=0; STATE_BAD=0
L_SHA="$(printf '%s\n' "$NODE_BIN" | hlup hash --sha256 - || true)"
if [ "$L_SHA" = "$P_SHA" ]; then say "installed node already = release $P_IDX"
else say "installed node sha256 ${L_SHA:0:12} != release ${P_SHA:0:12}: will install"; NEED_NODE=1; fi
L_MIDX="$(python3 -I -c 'import json,sys; print(json.load(open(sys.argv[1]))["hvs"]["hyperliquid_index"])' "$DATA_DIR/node_metadata.json" 2>/dev/null || true)"
if [ "$L_MIDX" != "$P_IDX" ]; then
  say "node_metadata.json names release ${L_MIDX:-<missing>}, not $P_IDX: will install it (the node checks it at startup)"; NEED_NODE=1
fi

if [ "$SUPERVISION" = visor ]; then
  set +e
  vres="$(hlup fetch --chain "$CHAIN" --what visor --dest "$STAGE/visor" "${PK[@]}")"; vrc=$?
  set -e
  say "supervisor: $(printf '%s' "$vres" | python3 -I -c 'import json,sys; d=json.load(sys.stdin); print("sha256=%s gpg=%s -> %s" % (str(d.get("sha256"))[:12], d.get("gpg"), d.get("reason")))')"
  [ "$vrc" -eq 3 ] && die 3 "REFUSING: the published supervisor did not verify. Nothing was changed."
  [ "$vrc" -ne 0 ] && die 4 "could not download the published supervisor. Nothing was changed."
  V_SHA="$(printf '%s' "$vres" | jget sha256)"
  LV_SHA="$(printf '%s\n' "$VISOR_BIN" | hlup hash --sha256 - || true)"
  if [ "$LV_SHA" = "$V_SHA" ]; then say "installed supervisor already = published"
  else say "installed supervisor sha256 ${LV_SHA:0:12} != published ${V_SHA:0:12}: will install"; NEED_VISOR=1; fi
fi

# A binary replaced on disk is not running until the process restarts. Compare
# what is RUNNING (needs root to read another user's /proc/<pid>/exe).
discover   # fresh PIDs: fetching and hashing above takes minutes, and a looping node changes PID
for pair in "node:$NODE_PID:$NODE_BIN" "supervisor:$VISOR_PID:$VISOR_BIN"; do
  IFS=: read -r what pid bin <<<"$pair"
  [ -n "$pid" ] || continue
  rexe="$(readlink "/proc/$pid/exe" 2>/dev/null || true)"
  if [ -z "$rexe" ]; then say "running $what (pid $pid): cannot read its executable (not root?)"
  elif [ "$rexe" != "$bin" ]; then say "running $what is $rexe, not $bin: needs a restart"; NEED_RESTART=1
  fi
done
if [ -z "$NODE_PID" ] && [ "$(unit_prop "$UNIT" ActiveState)" != active ]; then
  say "unit $UNIT is $(unit_prop "$UNIT" ActiveState): will (re)start it"; NEED_RESTART=1
fi

# --- 5. is the local state usable by the new release? ----------------------
# A state written by an older hardfork is fine EXACTLY at the freeze height: that
# is the normal upgrade, the new binary continues from it. Below the freeze it is
# the brick case: the new binary loads it and panics on the first post-fork block.
# (Recent node builds can also notice "local height is from stale hardfork" and
# bootstrap by themselves; older ones did not, so we do not rely on it.)
step "5. state check"
if [ -n "$S_HV" ] && [ -n "$P_HV" ] && [ "$S_HV" -lt "$P_HV" ]; then
  at_freeze=0
  { [ -n "$S_SFH" ] && [ -n "$S_H" ] && [ "$S_H" -ge "$S_SFH" ]; } && at_freeze=1
  { [ -n "$FREEZE_FILE" ] && [ "$FREEZE_FILE" = "$S_H" ]; } && at_freeze=1
  if [ "$at_freeze" = 1 ]; then
    say "state is hardfork $S_HV at the freeze height $S_H: usable, the new release continues from it"
  elif recent="$(find "$KIT" -maxdepth 1 -name 'stale-state-*' -mmin -180 2>/dev/null | head -n1)" && [ -n "$recent" ]; then
    # Idempotence: a reset already happened and the node is bootstrapping. A
    # second reset would throw away the bootstrap in progress.
    say "a state reset was already done ($recent); the node is bootstrapping. Not resetting again: wait, and follow the lag."
  else
    STATE_BAD=1
    say "state is hardfork $S_HV (release is $P_HV) and NOT at a freeze height (height ${S_H:-?}, freeze ${S_SFH:-unknown}): the new binary cannot continue from it. It needs a fresh state bootstrap."
  fi
else
  say "state hardfork ${S_HV:-?} vs release $P_HV: nothing to reset"
fi

# --- plan ---------------------------------------------------------------------
step "plan"
ACTIONS=0
[ "$NEED_NODE" = 1 ] && { say "- install node release $P_IDX at $NODE_BIN (backup in $KIT/backup/)"; ACTIONS=1; }
[ "$NEED_VISOR" = 1 ] && { say "- install the published supervisor at $VISOR_BIN"; ACTIONS=1; }
if [ "$STATE_BAD" = 1 ]; then
  if [ "$RESET" = 1 ]; then say "- stop $UNIT, move the pre-fork state aside to $KIT/stale-state-<ts>/, start (fresh bootstrap)"; ACTIONS=1
  else say "- state reset NOT requested: re-run with --reset-state to move the pre-fork state aside (see the bootstrap notes below)"; fi
fi
if [ "$RESTART" = 1 ] && { [ "$NEED_NODE" = 1 ] || [ "$NEED_VISOR" = 1 ] || [ "$NEED_RESTART" = 1 ]; } \
   && { [ "$RESET" = 0 ] || [ "$STATE_BAD" = 0 ]; }; then
  say "- restart $UNIT once via systemd"; ACTIONS=1
fi
if [ "$SUPERVISION" = bare ]; then
  say "! unit $UNIT runs the node directly. This fixes today; at the NEXT fork it stops again. Move it under the supervisor (the unit example in systemd/)."
fi
if [ "$STATE_BAD" = 1 ]; then cat <<'NOTE'

  Bootstrap notes (read before --reset-state):
  - A bootstrapping node stops calling accept() on its gossip port. On a box that
    many peers already dial, the listen backlog fills within minutes, the serving
    peer's 5 s dial-back probe of your port then fails, and it refuses you. A fresh,
    unknown box bootstraps fine; an established one can take 40 minutes to hours.
  - Before you start: put firewall/gossip-connection-ceiling.sh in front of the port
    (it caps concurrency instead of blocking, which keeps the probes working).
    Never blanket-DROP the port: that turns a slow retry lottery into a deadlock.
  - Do not restart a node that is mid-bootstrap or paging blocks: each restart
    starts the lottery again. Watch the lag with fork-watch.sh instead.
NOTE
fi

if [ "$ACTIONS" = 0 ]; then
  if [ "$STATE_BAD" = 1 ]; then
    say "binaries are the verified release and running, but the state needs --reset-state (above)."
    if [ "$APPLY" = 1 ]; then exit 0; else exit 10; fi
  fi
  say "nothing to do: binaries are the verified release and running, state usable."
  exit 0
fi
if [ "$APPLY" = 0 ]; then
  say ""; say "dry run: nothing changed. Re-run with --apply to do the above."
  exit 10
fi
if [ "$YES" = 0 ]; then
  read -r -p "apply this plan to $UNIT? [y/N] " ans
  [ "$ans" = y ] || [ "$ans" = Y ] || die 5 "aborted"
fi

# --- 3+4. apply ------------------------------------------------------------------
TS="$(date -u +%Y%m%dT%H%M%SZ)"
BK="$KIT/backup/$TS"
install_one() {   # what src dst [meta_src meta_dst]
  python3 -I -c 'import json,sys; print(json.dumps(dict(zip(["src","dst","backup_dir","owner","meta_src","meta_dst"], sys.argv[1:]))))' \
    "$2" "$3" "$BK" "$UNIT_USER" "${4:-}" "${5:-}" | hlup install
}

if [ "$STATE_BAD" = 1 ] && [ "$RESET" = 1 ]; then
  step "stop $UNIT"
  unit_job "$UNIT" Stop
  wait_state "$UNIT" inactive 120 || wait_state "$UNIT" failed 5 || die 5 "unit did not stop within 120 s; nothing moved"
fi

if [ "$NEED_NODE" = 1 ]; then
  step "3. install node release $P_IDX"
  # The release's metadata goes where the supervisor keeps it, in BOTH layouts:
  # - the node itself reads hl/hyperliquid_data/node_metadata.json at startup and
  #   panics ("failed to validate hardfork version") when it is missing or names a
  #   different hardfork than the state (seen live on testnet with a bare unit);
  # - under a supervisor, it marks this index as downloaded, so a CDN problem at
  #   the supervisor's next start cannot leave it without the binary we verified.
  install_one node "$STAGE/node/node.bin" "$NODE_BIN" "$STAGE/node/node_metadata.json" "$DATA_DIR/node_metadata.json"
fi
if [ "$NEED_VISOR" = 1 ]; then
  step "3. install the published supervisor"
  install_one visor "$STAGE/visor/visor.bin" "$VISOR_BIN"
fi

if [ "$STATE_BAD" = 1 ] && [ "$RESET" = 1 ]; then
  step "5. move the pre-fork state aside"
  python3 -I -c 'import json,sys; print(json.dumps({"data_dir": sys.argv[1], "to_dir": sys.argv[2]}))' \
    "$DATA_DIR" "$KIT/stale-state-$TS" | hlup move-aside
  say "delete $KIT/stale-state-$TS once the node follows the chain again"
  step "4. start $UNIT"
  unit_job "$UNIT" Start
elif [ "$RESTART" = 1 ]; then
  step "4. restart $UNIT"
  unit_job "$UNIT" Restart
fi

if [ "$RESTART" = 1 ] || [ "$RESET" = 1 ]; then
  if wait_state "$UNIT" active "$WAIT_S"; then
    sleep 5
    say "unit $UNIT active; node pid(s): $(pids_by_comm "$NODE_COMM" | paste -sd ' ' -)"
  else
    die 5 "unit $UNIT not active after ${WAIT_S}s; check its journal (by SyslogIdentifier, see README)"
  fi
fi
say "done. Watch it with: upgrade/fork-watch.sh --home $HOME_DIR"
