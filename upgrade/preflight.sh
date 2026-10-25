#!/usr/bin/env bash
#
# preflight.sh: will this node survive the next hardfork? Read-only.
#
#   ./upgrade/preflight.sh                    auto-detect unit, home and chain
#   ./upgrade/preflight.sh --chain testnet    force the chain
#   ./upgrade/preflight.sh --json             machine-readable
#   ./upgrade/preflight.sh --offline          skip the CDN checks
#
# Options: --unit NAME  --home DIR  --chain mainnet|testnet  --json  --offline
#          --node-bin PATH  --visor-bin PATH  (binaries under non-default names)
#          --pubkey FILE (Hyperliquid's pub_key.asc, instead of fetching it)
#          --min-free-gib N (default 100)  --warn-free-gib N (default 300)
#          --full   also check the release's keccak-256 against its metadata
#                   (~2-5 min of CPU in pure Python; recover.sh always does it)
#
# Changes nothing. Runs as any user; as root (or the node's user) it can also
# check the supervisor's gpg keyring. Downloads the published supervisor and node
# into a temp dir to verify them, then deletes them.
#
# Exit: 0 all PASS, 1 at least one WARN, 2 at least one FAIL.
#
# WHAT IT CHECKS AND WHY (details in upgrade/README.md)
# - supervision: a bare unit restarting the node directly has no updater. At the
#   freeze height the node stops, systemd restarts the same old binary, and it
#   stops again: forever, or until someone notices.
# - supervisor current: an outdated supervisor may not understand the current
#   release manifest, so it cannot verify the new release and keeps the old node
#   running into the freeze height.
# - node current, lag, disk, restart hygiene, freeze status: see each check.

set -uo pipefail   # not -e: every check runs and reports

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
. "$HERE/lib/common.sh"
argv_guard

JSON=0; OFFLINE=0; FULL=0; PUBKEY=""; MIN_FREE=100; WARN_FREE=300
UNIT="${UNIT:-}"; HOME_DIR="${HOME_DIR:-}"; CHAIN="${CHAIN:-}"
export NODE_BIN_OPT VISOR_BIN_OPT   # read by lib/common.sh
while [ $# -gt 0 ]; do
  case "$1" in
    --unit) UNIT="$2"; shift ;;
    --home) HOME_DIR="$2"; shift ;;
    --chain) CHAIN="$2"; shift ;;
    --node-bin) NODE_BIN_OPT="$2"; shift ;;
    --visor-bin) VISOR_BIN_OPT="$2"; shift ;;
    --json) JSON=1 ;;
    --offline) OFFLINE=1 ;;
    --full) FULL=1 ;;
    --pubkey) PUBKEY="$2"; shift ;;
    --min-free-gib) MIN_FREE="$2"; shift ;;
    --warn-free-gib) WARN_FREE="$2"; shift ;;
    -h|--help) sed -n '2,/^[^#]/{/^#/p}' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 64 ;;
  esac
  shift
done

RESULTS=()   # "GRADE|check|reason" rows
grade() {
  RESULTS+=("$1|$2|$3")
  if [ "$JSON" = 0 ]; then
    case "$1" in
      PASS) printf '\033[32mPASS\033[0m %-20s %s\n' "$2" "$3" ;;
      WARN) printf '\033[33mWARN\033[0m %-20s %s\n' "$2" "$3" ;;
      FAIL) printf '\033[31mFAIL\033[0m %-20s %s\n' "$2" "$3" ;;
      *)    printf 'INFO %-20s %s\n' "$2" "$3" ;;
    esac
  fi
}

discover
[ "$JSON" = 0 ] && printf '== node: unit=%s home=%s chain=%s supervision=%s ==\n' \
  "${UNIT:-?}" "${HOME_DIR:-?}" "${CHAIN:-?}" "$SUPERVISION"

# --- 1. supervision ---------------------------------------------------------
# The supervisor is the only thing that swaps the binary at a fork. The node has
# no self-update path.
case "$SUPERVISION" in
  visor)
    if [ -n "$NODE_PID" ] && [ "$(ppid_of "$NODE_PID")" = "$VISOR_PID" ]; then
      grade PASS supervision "unit ${UNIT:-?} runs the supervisor (pid $VISOR_PID) and it runs the node (pid $NODE_PID)"
    elif [ -n "$VISOR_PID" ]; then
      grade WARN supervision "supervisor running (pid $VISOR_PID) but no node child right now"
    else
      grade FAIL supervision "unit ${UNIT:-?} is set up for the supervisor but it is not running"
    fi ;;
  bare)
    grade FAIL supervision "unit ${UNIT:-?} runs the node binary directly: nothing will install the new release at the next freeze height, the node will stop there and restart into the same old binary. Run it under the supervisor (systemd/ example), or keep recover.sh ready" ;;
  *)
    grade FAIL supervision "no supervisor or node process found and no unit for either (pass --unit / --home)" ;;
esac

ABCI_JSON=""
STATE_HV=""
if [ -n "${HOME_DIR:-}" ]; then
  ABCI_JSON="$(hlup abci "$DATA_DIR/visor_abci_state.json")"
  STATE_HV="$(printf '%s' "$ABCI_JSON" | python3 -I -c 'import json,sys; v=json.load(sys.stdin).get("hardfork_version"); print("" if v is None else v)')"
fi

# Which hardfork does this node think it is on? The state file says it; when the
# node dies before writing one (an old binary refusing a newer state does exactly
# that), the release metadata it was installed with is the next best answer.
LOCAL_HV="$STATE_HV"
if [ -z "$LOCAL_HV" ] && [ -n "${HOME_DIR:-}" ]; then
  LOCAL_HV="$(python3 -I -c 'import json,sys; print(json.load(open(sys.argv[1]))["hvs"]["c"]["NodeMetadata"]["hv"])' "$DATA_DIR/node_metadata.json" 2>/dev/null || true)"
fi

# --- 2/3. supervisor and node match the published releases -------------------
TMP=""
# shellcheck disable=SC2329  # invoked by the EXIT trap
cleanup() { [ -n "$TMP" ] && rm -rf "$TMP"; }
trap cleanup EXIT
if [ "$OFFLINE" = 1 ]; then
  grade INFO cdn "skipped (--offline)"
elif [ -z "${CHAIN:-}" ]; then
  grade FAIL chain "could not detect the chain (no visor.json, no --chain on the command line); pass --chain mainnet|testnet"
else
  TMP="$(mktemp -d -t hlup-preflight.XXXXXX)"
  PK=(); [ -n "$PUBKEY" ] && PK=(--pubkey "$PUBKEY")

  # Supervisor: published unversioned with a detached gpg signature. Skipped for a
  # bare unit (nothing to compare; the supervision check already failed it).
  vres='{"reason":"skipped: no supervisor in use"}'; vrc=0
  [ "$SUPERVISION" != bare ] && { vres="$(hlup fetch --chain "$CHAIN" --what visor --dest "$TMP/visor" "${PK[@]}")"; vrc=$?; }
  vsha="$(printf '%s' "$vres" | python3 -I -c 'import json,sys; print(json.load(sys.stdin).get("sha256",""))')"
  vwhy="$(printf '%s' "$vres" | python3 -I -c 'import json,sys; print(json.load(sys.stdin).get("reason",""))')"
  if [ "$vrc" -ne 0 ]; then
    grade FAIL visor-published "could not fetch+verify the published supervisor: $vwhy"
  elif [ "$SUPERVISION" = bare ]; then
    :
  elif [ ! -r "$VISOR_BIN" ]; then
    if [ "$SUPERVISION" = visor ]; then grade WARN visor-current "cannot read $VISOR_BIN to compare"
    else grade INFO visor-current "no supervisor binary at $VISOR_BIN (published sha256 ${vsha:0:12})"; fi
  else
    lsha="$(printf '%s\n' "$VISOR_BIN" | hlup hash --sha256 -)"
    if [ "$lsha" = "$vsha" ]; then
      grade PASS visor-current "matches the published, gpg-verified supervisor (sha256 ${vsha:0:12})"
    else
      grade FAIL visor-current "local supervisor sha256 ${lsha:0:12} != published ${vsha:0:12}: an outdated supervisor may be unable to verify the next release and will keep the old node running into the freeze. recover.sh installs the published one"
    fi
  fi

  # Node: index, metadata, gpg and the metadata's binary hash (keccak-256; ~2 min
  # in pure Python). Then compare the local binary by sha256 against the verified copy.
  SH=(); [ -n "$STATE_HV" ] && SH=(--state-hv "$STATE_HV")
  [ "$FULL" = 0 ] && SH+=(--skip-keccak)
  nres="$(hlup fetch --chain "$CHAIN" --what node --dest "$TMP/node" "${PK[@]}" "${SH[@]}")"; nrc=$?
  read -r nidx nhv nsha nwhy < <(printf '%s' "$nres" | python3 -I -c '
import json,sys; d=json.load(sys.stdin)
print(d.get("index","?"), d.get("hv","?"), d.get("sha256","-"), d.get("reason","").replace(" ","_"))')
  if [ "$nrc" -ne 0 ]; then
    grade FAIL node-published "could not fetch+verify the published node release: ${nwhy//_/ }"
  elif [ ! -r "$NODE_BIN" ]; then
    grade WARN node-current "cannot read $NODE_BIN to compare (published index $nidx, hardfork $nhv)"
  else
    lsha="$(printf '%s\n' "$NODE_BIN" | hlup hash --sha256 -)"
    SFH="$(printf '%s' "$ABCI_JSON" | python3 -I -c 'import json,sys; v=json.load(sys.stdin).get("scheduled_freeze_height"); print("" if v is None else v)' 2>/dev/null)"
    if [ "$lsha" = "$nsha" ]; then
      grade PASS node-current "local node = published release $nidx (hardfork $nhv), gpg-verified$( [ "$FULL" = 1 ] && echo ', metadata hash checked')"
    elif [ -n "$SFH" ] && [ -n "$STATE_HV" ] && [ "$nhv" -gt "$STATE_HV" ] 2>/dev/null; then
      # Expected during a fork window: the supervisor deliberately waits for the
      # freeze height before downloading the new release.
      grade WARN node-current "release $nidx (hardfork $nhv) is published for the fork at $SFH; the supervisor should swap it in at the freeze"
    elif [ -n "$LOCAL_HV" ] && [ "$nhv" -gt "$LOCAL_HV" ] 2>/dev/null; then
      grade FAIL node-current "the network is on hardfork $nhv (release $nidx) but this node is on $LOCAL_HV and its binary is not the release: it missed the fork. Run recover.sh"
    else
      grade WARN node-current "local node sha256 ${lsha:0:12} differs from published release $nidx (${nsha:0:12})"
    fi
    # A binary replaced on disk but not restarted is still the old code in memory.
    rexe="$( [ -n "$NODE_PID" ] && readlink "/proc/$NODE_PID/exe" 2>/dev/null)"
    if [ -n "$rexe" ] && [ "$rexe" != "$NODE_BIN" ]; then
      grade WARN node-running "the running node is $rexe, not $NODE_BIN (replaced on disk, not restarted?)"
    fi
  fi
fi

# --- release metadata the node itself checks at startup ----------------------
# The node reads hl/hyperliquid_data/node_metadata.json (written by the supervisor)
# and refuses to start if it is missing or names another hardfork than its state.
if [ -n "${HOME_DIR:-}" ]; then
  mrow="$(python3 -I -c '
import json,sys
try: m=json.load(open(sys.argv[1]))["hvs"]
except Exception as e: print("FAIL|metadata|cannot read %s: %s" % (sys.argv[1], e)); sys.exit()
hv=m["c"]["NodeMetadata"]["hv"]; st=sys.argv[2]
if st and int(st)!=hv: print("FAIL|metadata|names release %s hardfork %s but the state is hardfork %s: the node will refuse to start" % (m["hyperliquid_index"], hv, st))
else: print("PASS|metadata|release %s, hardfork %s" % (m["hyperliquid_index"], hv))' "$DATA_DIR/node_metadata.json" "$STATE_HV")"
  IFS='|' read -r g c r <<<"$mrow"; grade "$g" "$c" "$r"
fi

# --- gpg prerequisites of the supervisor ------------------------------------
# The supervisor shells out to curl and to `gpg --verify` with ITS OWN keyring.
# gpg installed but Hyperliquid's key never imported is a verify failure at the
# worst moment: it keeps the old node running into the freeze.
for tool in curl gpg; do
  if command -v "$tool" >/dev/null 2>&1; then grade PASS "tool-$tool" "$(command -v "$tool")"
  else grade FAIL "tool-$tool" "$tool not installed; the supervisor needs it to download/verify releases"; fi
done
if [ -n "${UNIT:-}" ] && [ "$SUPERVISION" = visor ]; then
  GH="$(unit_prop "$UNIT" Environment | tr ' ' '\n' | sed -n 's/^GNUPGHOME=//p' | head -n1)"
  GH="${GH:-$HOME_DIR/.gnupg}"
  if [ -r "$GH" ] && [ -x "$GH" ]; then
    if GNUPGHOME="$GH" gpg --batch --list-keys CF2C2EA3DC3E8F042A55FB6503254A9349F1820B >/dev/null 2>&1; then
      grade PASS supervisor-keyring "Hyperliquid's release key is in $GH"
    else
      grade FAIL supervisor-keyring "Hyperliquid's release key is NOT in $GH: the supervisor's gpg verify will fail. Import pub_key.asc from the hyperliquid-dex/node repository as $UNIT_USER"
    fi
  else
    grade WARN supervisor-keyring "cannot read $GH (run as root or $UNIT_USER to check)"
  fi
fi

# --- 4. lag and 7. freeze status (one file, written by the node) -----------
if [ -n "$ABCI_JSON" ]; then
  while IFS='|' read -r g c r; do grade "$g" "$c" "$r"; done < <(printf '%s' "$ABCI_JSON" | python3 -I -c '
import json,sys
d=json.load(sys.stdin)
if not d.get("present"):
    print("FAIL|abci-state|cannot read %s: %s" % (d["path"], d.get("error"))); sys.exit()
lag=d.get("lag_s"); age=d.get("age_s"); h=d.get("height"); sfh=d.get("scheduled_freeze_height"); hv=d.get("hardfork_version")
if age is not None and age > 120:
    print("FAIL|lag|state file not written for %.0f s: the node is not applying blocks" % age)
elif lag is None:
    print("WARN|lag|no consensus/wall time in the state file")
elif lag <= 5:   print("PASS|lag|%.1f s behind (consensus vs wall clock, node-local)" % lag)
elif lag <= 60:  print("WARN|lag|%.1f s behind" % lag)
else:            print("FAIL|lag|%.0f s behind: a node this far back when a freeze lands is the brick case" % lag)
if sfh is None:
    print("PASS|freeze|no freeze scheduled (hardfork %s, height %s)" % (hv, h))
elif h is not None and h < sfh and sfh - h > 1600:
    print("FAIL|freeze|freeze at %s but the node is %d blocks below it: more than ~1,600 behind when the release appears means the supervisor swaps anyway and the new binary panics on pre-fork state. Catch up NOW" % (sfh, sfh - h))
elif h is not None and h < sfh:
    print("WARN|freeze|fork pending: freeze at %s, %d blocks to go (hardfork %s)" % (sfh, sfh - h, hv))
else:
    print("WARN|freeze|at the freeze height %s on hardfork %s: the supervisor should be swapping now" % (sfh, hv))
')
fi

# --- 5. disk headroom ------------------------------------------------------
# A recovery that needs a fresh state bootstrap writes a full new state next to
# the old one; a fork week is also when output streams spike.
if [ -n "${HOME_DIR:-}" ] && [ -d "$HOME_DIR" ]; then
  read -r avail pct < <(df -P -BG "$HOME_DIR" | awk 'NR==2{gsub("G","",$4); gsub("%","",$5); print $4, $5}')
  if [ "${avail:-0}" -lt "$MIN_FREE" ]; then grade FAIL disk "${avail} GiB free on the node filesystem (${pct}% used); keep >= ${MIN_FREE} GiB for a bootstrap"
  elif [ "${avail:-0}" -lt "$WARN_FREE" ]; then grade WARN disk "${avail} GiB free (${pct}% used)"
  else grade PASS disk "${avail} GiB free (${pct}% used)"; fi
fi

# --- 6. apt / needrestart hazards (reuses host/apply-restart-hygiene.sh) ----
HYG="$HERE/../host/apply-restart-hygiene.sh"
if [ -x "$HYG" ] || [ -r "$HYG" ]; then
  todos="$(bash "$HYG" --status 2>/dev/null | sed -n 's/\x1b\[[0-9;]*m//g; s/^TODO *//p' | paste -sd ';' -)"
  if [ -z "$todos" ]; then grade PASS restart-hygiene "apt timers masked, needrestart exempted (host/apply-restart-hygiene.sh)"
  else grade WARN restart-hygiene "something can still restart the node behind your back: $todos (fix: sudo host/apply-restart-hygiene.sh --apply)"; fi
fi

# --- summary -----------------------------------------------------------------
worst=0
for row in "${RESULTS[@]}"; do
  case "${row%%|*}" in WARN) [ $worst -lt 1 ] && worst=1 ;; FAIL) worst=2 ;; esac
done
if [ "$JSON" = 1 ]; then
  printf '%s\n' "${RESULTS[@]}" | python3 -I -c '
import json,sys
rows=[l.rstrip("\n").split("|",2) for l in sys.stdin if l.strip()]
print(json.dumps({"unit":sys.argv[1],"home":sys.argv[2],"chain":sys.argv[3],"supervision":sys.argv[4],
  "worst":["PASS","WARN","FAIL"][int(sys.argv[5])],
  "checks":[{"grade":g,"check":c,"reason":r} for g,c,r in rows]}, indent=1))' \
  "${UNIT:-}" "${HOME_DIR:-}" "${CHAIN:-}" "$SUPERVISION" "$worst"
else
  printf '== worst: %s ==\n' "$(echo PASS WARN FAIL | cut -d' ' -f$((worst+1)))"
fi
exit "$worst"
