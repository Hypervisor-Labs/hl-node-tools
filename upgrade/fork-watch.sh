#!/usr/bin/env bash
#
# fork-watch.sh: classify this node's position relative to a hardfork, every
# 30 s, from the node's own files. Designed for a systemd timer (see
# upgrade/systemd/). One run takes well under a second and spawns nothing that
# carries the node's program names.
#
#   ./upgrade/fork-watch.sh                                  print one classification
#   ./upgrade/fork-watch.sh --textfile /var/lib/node_exporter/textfile/hl_upgrade.prom
#   ./upgrade/fork-watch.sh --webhook https://example.invalid/hook
#   sudo ./upgrade/fork-watch.sh --auto-recover              opt-in, see README
#
# Options:
#   --unit NAME --home DIR --chain mainnet|testnet   override discovery
#   --node-bin PATH --visor-bin PATH   binaries under non-default names
#   --state FILE        state file (default /var/lib/hl-fork-watch/state.json, or
#                       ~/.cache/hl-fork-watch/state.json when not root)
#   --textfile FILE     node_exporter textfile; written to a temp file and renamed.
#                       Must be a regular file path: device paths are refused.
#   --webhook URL       POST the classification as JSON when it changes
#   --webhook-always    POST on every run, not only on change
#   --auto-recover      run recover.sh --apply when FROZEN_OLD_VERSION or
#                       RESTART_LOOP persists (--auto-after-min, default 10);
#                       at most once per fork, with a lock and a backoff
#   --auto-reset-state  also let that recover.sh move a pre-fork state aside
#   --behind-blocks N --frozen-min N --loop-restarts N --loop-window-min N
#   --auto-after-min N --auto-backoff-min N   classifier thresholds
#   --json              print the full result as JSON
#   --record FILE       append each raw observation (one JSON line) to FILE, so a
#                       sequence can be replayed through the classifier later
#
# Classes: OK, FORK_PENDING, BEHIND_AT_FREEZE, FROZEN_OLD_VERSION, RESTART_LOOP,
# RECOVERING, RECOVERED, UNKNOWN. What each means: upgrade/README.md.
# Exit: 0 OK/FORK_PENDING/RECOVERED/RECOVERING, 1 UNKNOWN, 2 a bad class.

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
. "$HERE/lib/common.sh"
argv_guard

UNIT="${UNIT:-}"; HOME_DIR="${HOME_DIR:-}"; CHAIN="${CHAIN:-}"
STATE=""; TEXTFILE=""; RECORD=""; WEBHOOK=""; WEBHOOK_ALWAYS=0; AUTO=0; AUTO_RESET=0; JSON=0
PARAMS=()
while [ $# -gt 0 ]; do
  case "$1" in
    --unit) UNIT="$2"; shift ;;
    --home) HOME_DIR="$2"; shift ;;
    --chain) CHAIN="$2"; shift ;;
    --node-bin) NODE_BIN_OPT="$2"; shift ;;
    --visor-bin) VISOR_BIN_OPT="$2"; shift ;;
    --state) STATE="$2"; shift ;;
    --textfile) TEXTFILE="$2"; shift ;;
    --webhook) WEBHOOK="$2"; shift ;;
    --webhook-always) WEBHOOK_ALWAYS=1 ;;
    --auto-recover) AUTO=1 ;;
    --auto-reset-state) AUTO_RESET=1 ;;
    --behind-blocks|--frozen-min|--loop-restarts|--loop-window-min|--auto-after-min|--auto-backoff-min)
      k="${1#--}"; PARAMS+=("\"${k//-/_}\": $2"); shift ;;
    --json) JSON=1 ;;
    --record) RECORD="$2"; shift ;;
    -h|--help) sed -n '2,/^[^#]/{/^#/p}' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 64 ;;
  esac
  shift
done

if [ -z "$STATE" ]; then
  if [ "$(id -u)" -eq 0 ]; then STATE=/var/lib/hl-fork-watch/state.json
  else STATE="${XDG_CACHE_HOME:-$HOME/.cache}/hl-fork-watch/state.json"; fi
fi
mkdir -p "$(dirname "$STATE")"
LOCK="$STATE.lock"

discover
if [ -z "${HOME_DIR:-}" ]; then
  echo "fork-watch: cannot find the node's home directory; pass --home" >&2
  exit 1
fi

# One run at a time per state file: the timer must never stack runs if one is
# slow (e.g. a recover in progress), and two writers would corrupt the state.
exec 9>"$LOCK"
if ! flock -n 9; then
  echo "fork-watch: previous run still holds $LOCK; skipping this tick" >&2
  exit 0
fi

now="$(date +%s)"
abci="$(hlup abci "$DATA_DIR/visor_abci_state.json")"
# Supervisor restarts as systemd counts them (a bare unit restarting the node,
# or the supervisor itself crashing) ...
nr="null"
if [ -n "${UNIT:-}" ]; then
  v="$(unit_prop "$UNIT" NRestarts)"
  [[ "$v" =~ ^[0-9]+$ ]] && nr="$v"
fi
# ... plus child respawns inside the supervisor, which systemd never sees.
starts="$(hlup child-starts "$HOME_DIR/hl/data/visor_child_stderr")"
obs="{\"ts\": $now, \"abci\": $abci, \"nrestarts\": $nr, \"child_start_times\": $starts}"
params="{$(IFS=,; echo "${PARAMS[*]:-}")}"
[ -n "$RECORD" ] && printf '%s\n' "$obs" | tr -d '\n' >>"$RECORD" && printf '\n' >>"$RECORD"

result="$(hlup classify --state "$STATE" --obs "$obs" --params "$params")"
field() { printf '%s' "$result" | python3 -I -c 'import json,sys; v=json.load(sys.stdin).get(sys.argv[1]); print("" if v is None else v)' "$1"; }
cls="$(field class)"; changed="$(field changed)"

if [ -n "$TEXTFILE" ]; then
  hlup textfile --path "$TEXTFILE" --result "$result"
fi

if [ -n "$WEBHOOK" ] && { [ "$changed" = True ] || [ "$WEBHOOK_ALWAYS" = 1 ]; }; then
  hlup webhook --url "$WEBHOOK" --result "$result" >/dev/null || true
fi

if [ "$JSON" = 1 ]; then printf '%s\n' "$result"
else printf '%s %s: %s\n' "$(date -u +%FT%TZ)" "$cls" "$(field reason)"; fi

# --- opt-in auto-recover ------------------------------------------------------
# Safety argument (README): recover.sh can only install a binary that Hyperliquid
# published and signed, verified exactly as the supervisor verifies it, and it
# restarts the unit only when it changed something. The classifier allows one
# attempt per fork (keyed on the freeze height) and a backoff between attempts;
# the attempt is recorded BEFORE recover runs, so a crash mid-recover cannot
# turn into a retry loop.
if [ "$AUTO" = 1 ] && [ "$(field auto_recover_due)" = True ]; then
  key="$(field fork_key)"
  hlup mark-attempt --state "$STATE" --key "$key" --rc -1
  args=(--apply --yes --unit "$UNIT" --home "$HOME_DIR")
  [ -n "${CHAIN:-}" ] && args+=(--chain "$CHAIN")
  [ -n "$NODE_BIN_OPT" ] && args+=(--node-bin "$NODE_BIN_OPT")
  [ -n "$VISOR_BIN_OPT" ] && args+=(--visor-bin "$VISOR_BIN_OPT")
  [ "$AUTO_RESET" = 1 ] && args+=(--reset-state)
  echo "fork-watch: auto-recover for $key ($cls): recover.sh ${args[*]}" >&2
  set +e
  # Relative path on purpose: the kit's own directory may contain the node's
  # program name (the repository is called hl-node-tools), and an absolute path
  # would put it in recover.sh's argv (README: "the kit's own path").
  # recover.sh's report goes to stderr: stdout is the classification stream.
  (cd "$HERE" && exec bash ./recover.sh "${args[@]}") >&2
  rc=$?
  set -e
  hlup mark-attempt --state "$STATE" --key "$key" --rc "$rc"
  if [ -n "$WEBHOOK" ]; then
    r2="$(printf '%s' "$result" | python3 -I -c 'import json,sys; d=json.load(sys.stdin); d["auto_recover_rc"]=int(sys.argv[1]); d["event"]="auto_recover"; print(json.dumps(d))' "$rc")"
    hlup webhook --url "$WEBHOOK" --result "$r2" >/dev/null || true
  fi
fi

case "$cls" in
  OK|FORK_PENDING|RECOVERED|RECOVERING) exit 0 ;;
  UNKNOWN) exit 1 ;;
  *) exit 2 ;;
esac
